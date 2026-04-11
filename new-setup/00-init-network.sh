#!/bin/bash
# ==============================================================================
# NETWORK INITIALIZATION SCRIPT (NON-INTERACTIVE & IDEMPOTENT)
# MUST be executed on 'hierophant'
# ==============================================================================
# This script ensures the bridges (br-app), IPTables rules, and sysctl settings
# required for the cluster's external routing are correctly configured.
# It is designed to be safe to run multiple times and before cluster startup.

echo "[NETWORK-INIT] Verifying host environment..."
if ! ip link show enp5s0 &>/dev/null || ! ip link show eno1 &>/dev/null; then
    echo "ERROR: Expected interfaces 'enp5s0' and 'eno1' not found on this host."
    exit 1
fi

echo "[NETWORK-INIT] Ensuring physical interfaces are managed..."
# enp5s0 (Management & Uplink)
if ! nmcli connection show enp5s0 &>/dev/null; then
    sudo nmcli connection add type ethernet con-name enp5s0 ifname enp5s0 ipv4.method manual ipv4.addresses 192.168.1.101/24 ipv4.gateway 192.168.1.1 ipv4.dns "192.168.1.210,1.1.1.1,8.8.8.8" ipv4.dns-search "hierocracy,hierocracy.home"
fi
sudo nmcli connection up enp5s0 || true

# eno1 (Physical base for VLAN)
if ! nmcli connection show eno1 &>/dev/null; then
    sudo nmcli connection add type ethernet con-name eno1 ifname eno1 ipv4.method disabled ipv6.method disabled
fi
sudo nmcli connection up eno1 || true

echo "[NETWORK-INIT] Configuring 'application' bridge (br-app) and VLAN 20..."
# Create bridge if missing
if ! nmcli connection show br-app &>/dev/null; then
    sudo nmcli connection add type bridge con-name br-app ifname br-app bridge.stp no
    sudo nmcli connection modify br-app ipv4.method manual ipv4.addresses 172.20.0.1/16 ipv6.method disabled
fi

# Create VLAN sub-interface on eno1 if missing
if ! nmcli connection show eno1.20 &>/dev/null; then
    sudo nmcli connection add type vlan con-name eno1.20 dev eno1 id 20 master br-app slave-type bridge
fi

sudo nmcli connection up br-app || true
sudo nmcli connection up eno1.20 || true

echo "[NETWORK-INIT] Configuring static routes..."
# Route to 'hegemon' host's internal VM network
sudo ip route replace 172.16.0.0/16 via 192.168.1.100 dev enp5s0 2>/dev/null || \
sudo ip route add 172.16.0.0/16 via 192.168.1.100 dev enp5s0

echo "[NETWORK-INIT] Applying sysctl optimizations..."
cat <<SYSCTL | sudo tee /etc/sysctl.d/98-network-optimization.conf > /dev/null
net.ipv4.conf.all.arp_ignore=1
net.ipv4.conf.all.arp_announce=2
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.arp_ignore=1
net.ipv4.conf.default.arp_announce=2
net.ipv4.conf.default.rp_filter=0
net.ipv4.conf.enp5s0.arp_ignore=1
net.ipv4.conf.enp5s0.arp_announce=2
net.ipv4.conf.enp5s0.rp_filter=0
net.ipv4.conf.br-app.arp_ignore=1
net.ipv4.conf.br-app.arp_announce=2
net.ipv4.conf.br-app.rp_filter=0
net.ipv4.ip_forward=1
SYSCTL
sudo sysctl -p /etc/sysctl.d/98-network-optimization.conf

echo "[NETWORK-INIT] Applying IPTables FORWARD and NAT rules..."
# Helper function for idempotent IPTables rules
ensure_iptables() {
    local table="$1"
    local chain="$2"
    shift 2
    # Use -C to check if the rule exists. If not, add it with -A.
    sudo iptables -t "$table" -C "$chain" "$@" 2>/dev/null || sudo iptables -t "$table" -A "$chain" "$@"
}

# NAT rules for external access and asymmetric routing
ensure_iptables nat POSTROUTING -s 10.0.0.0/24 ! -d 10.0.0.0/24 -j MASQUERADE
ensure_iptables nat POSTROUTING -s 172.20.0.0/16 ! -d 172.20.0.0/16 -j MASQUERADE
ensure_iptables nat POSTROUTING -o br-app -j MASQUERADE

# FORWARD chain rules
for subnet in 10.0.0.0/24 172.20.0.0/16; do
    # Use -I for FORWARD rules to ensure they are at the top and avoid conflicts.
    sudo iptables -C FORWARD -s "$subnet" -j ACCEPT 2>/dev/null || sudo iptables -I FORWARD -s "$subnet" -j ACCEPT
    sudo iptables -C FORWARD -d "$subnet" -j ACCEPT 2>/dev/null || sudo iptables -I FORWARD -d "$subnet" -j ACCEPT
done

ensure_iptables filter FORWARD -i br-app -o enp5s0 -j ACCEPT
ensure_iptables filter FORWARD -i enp5s0 -o br-app -m state --state RELATED,ESTABLISHED -j ACCEPT
ensure_iptables filter FORWARD -i enp5s0 -o br-app -s 192.168.0.0/16 -j ACCEPT

# Disable bridge-nf-call-iptables (prevents host filter from blocking bridged VM traffic)
if [ -f /proc/sys/net/bridge/bridge-nf-call-iptables ]; then
    sudo sysctl -w net.bridge.bridge-nf-call-iptables=0 >/dev/null
    sudo sysctl -w net.bridge.bridge-nf-call-arptables=0 >/dev/null
fi

echo "[NETWORK-INIT] Complete."
