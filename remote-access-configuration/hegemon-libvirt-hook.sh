#!/usr/bin/env bash
# hegemon-libvirt-hook.sh
# Installed to /etc/libvirt/hooks/network on hegemon.
#
# Libvirt calls this after each network starts. After the agent-link network
# starts, libvirt regenerates the ip libvirt_network nftables table. This hook
# re-applies the custom rules needed to forward traffic from dev-fedora
# (172.16.1.10 on virbr-agent) to the Talos cluster (10.0.0.0/24) via
# hierophant (192.168.1.101).
#
# Rules added:
#   guest_output: accept virbr-agent → 10.0.0.0/24 (forward out)
#   guest_input:  accept 10.0.0.0/24 → virbr-agent (return traffic in)
#   guest_nat:    masquerade 172.16.0.0/16 → 10.0.0.0/24
#                 (src becomes 192.168.1.100 so Talos can route the reply)

NETWORK="$1"
ACTION="$2"

[ "$ACTION" = "started" ] || exit 0
[ "$NETWORK" = "agent-link" ] || exit 0

log() { logger -t libvirt-hook-network "hegemon agent-link: $*"; }

log "applying Talos cluster forwarding rules"

# Wait briefly for nftables table to be fully populated by libvirt
sleep 0.5

# guest_output: allow new outbound forwarding from virbr-agent to 10.0.0.0/24
if ! nft list chain ip libvirt_network guest_output 2>/dev/null \
        | grep -q 'iif "virbr-agent".*10.0.0.0/24.*accept'; then
    nft insert rule ip libvirt_network guest_output \
        iif "virbr-agent" ip daddr 10.0.0.0/24 accept
    log "added guest_output accept rule"
fi

# guest_input: allow return traffic from 10.0.0.0/24 back to virbr-agent
if ! nft list chain ip libvirt_network guest_input 2>/dev/null \
        | grep -q 'oif "virbr-agent".*10.0.0.0/24.*accept'; then
    nft insert rule ip libvirt_network guest_input \
        oif "virbr-agent" ip saddr 10.0.0.0/24 accept
    log "added guest_input accept rule"
fi

# guest_nat: masquerade dev-fedora traffic to Talos network
# Source-based match is used because iif is unreliable in postrouting.
if ! nft list chain ip libvirt_network guest_nat 2>/dev/null \
        | grep -q '172.16.0.0/16.*10.0.0.0/24.*masquerade'; then
    nft add rule ip libvirt_network guest_nat \
        ip saddr 172.16.0.0/16 ip daddr 10.0.0.0/24 masquerade
    log "added guest_nat masquerade rule"
fi

log "done"
