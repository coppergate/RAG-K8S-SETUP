#!/usr/bin/env bash
# hierophant-libvirt-hook.sh
# Installed to /etc/libvirt/hooks/network on hierophant.
#
# Libvirt calls this after each network starts. After the network that manages
# talos-bridge starts, libvirt regenerates the ip libvirt_network nftables
# table. This hook re-applies the rule that allows new connections from
# hegemon (192.168.1.100) through enp5s0 into talos-bridge for the Talos
# cluster network (10.0.0.0/24).
#
# Without this rule, libvirt's default guest_input chain only accepts
# established/related connections into talos-bridge, silently dropping new
# TCP connections (SYN packets) from outside the 10.0.0.0/24 network.

NETWORK="$1"
ACTION="$2"

[ "$ACTION" = "started" ] || exit 0

log() { logger -t libvirt-hook-network "hierophant $NETWORK: $*"; }

# Only act if talos-bridge exists on this system
if ! ip link show talos-bridge &>/dev/null; then
    exit 0
fi

# Only act if the libvirt_network nftables table is present
if ! nft list table ip libvirt_network &>/dev/null; then
    exit 0
fi

log "applying Talos cluster guest_input rule"

# Wait briefly for libvirt to finish populating its nftables rules
sleep 0.5

# guest_input: allow new connections from hegemon (192.168.1.100) on enp5s0
# into talos-bridge for the Talos cluster network.
# The default rule only permits established/related; this adds NEW connections.
if ! nft list chain ip libvirt_network guest_input 2>/dev/null \
        | grep -q '192.168.1.100.*10.0.0.0/24.*accept'; then
    nft insert rule ip libvirt_network guest_input \
        iifname "enp5s0" oif "talos-bridge" \
        ip daddr 10.0.0.0/24 ip saddr 192.168.1.100 accept
    log "added guest_input accept rule for hegemon → talos-bridge"
fi

log "done"
