#!/bin/bash
# ==============================================================================
# HIEROPHANT HOST NETWORK — new-setup-external-gpu (flat LAN)
#
# Puts hierophant on the flat LAN with a single Linux bridge (br-lan) over
# enp5s0. The host IP moves onto the bridge; all cluster VMs attach to the same
# bridge (via the libvirt 'lan' network — see hierophant-libvirt-net.sh). eno1
# is left idle (spare / future bond).
#
# There is NO NAT, routing, VLAN, or ARP tuning on hierophant anymore — every
# node is a first-class LAN citizen. This script is idempotent and doubles as
# reboot-recovery for the host network.
#
#   Host IP  : 192.168.1.101/16   Gateway: 192.168.0.1   DNS: 192.168.1.210
#
# ⚠  CUTOVER: moving the host IP onto br-lan briefly drops connectivity on
#    enp5s0. Run this from the physical/IPMI console, or detached:
#        sudo nohup bash hierophant-host-net.sh &>/tmp/host-net.log &
#
# MUST be run on hierophant (as root / with sudo).
# ==============================================================================
set -e

BRIDGE="br-lan"
UPLINK="enp5s0"
HOST_IP="192.168.1.101/16"
GATEWAY="192.168.0.1"
DNS="192.168.1.210,1.1.1.1,8.8.8.8"
DNS_SEARCH="hierocracy,hierocracy.home"
SLAVE_CON="${BRIDGE}-${UPLINK}"

echo "[HOST-NET] Verifying uplink interface '${UPLINK}' exists..."
if ! ip link show "${UPLINK}" &>/dev/null; then
    echo "ERROR: expected uplink '${UPLINK}' not found on this host." >&2
    exit 1
fi

echo "[HOST-NET] Removing legacy connections from the old VLAN/NAT design..."
for con in br-app eno1.20 br-mgmt br-lb veth-mgmt-master veth-mgmt-slave \
           veth-lb-master veth-lb-slave; do
    sudo nmcli connection delete "$con" 2>/dev/null || true
done

echo "[HOST-NET] Removing legacy sysctl drop-ins (arp/rp_filter/NAT hacks)..."
for f in 98-network-optimization.conf 99-k8s-routing.conf 99-bridge-nf.conf; do
    sudo rm -f "/etc/sysctl.d/$f"
done

echo "[HOST-NET] Creating/updating LAN bridge '${BRIDGE}' (host IP ${HOST_IP})..."
if ! nmcli connection show "${BRIDGE}" &>/dev/null; then
    sudo nmcli connection add type bridge con-name "${BRIDGE}" ifname "${BRIDGE}" \
        bridge.stp no \
        ipv4.method manual ipv4.addresses "${HOST_IP}" ipv4.gateway "${GATEWAY}" \
        ipv4.dns "${DNS}" ipv4.dns-search "${DNS_SEARCH}" ipv6.method disabled
else
    sudo nmcli connection modify "${BRIDGE}" \
        bridge.stp no \
        ipv4.method manual ipv4.addresses "${HOST_IP}" ipv4.gateway "${GATEWAY}" \
        ipv4.dns "${DNS}" ipv4.dns-search "${DNS_SEARCH}" ipv6.method disabled
fi

echo "[HOST-NET] Enslaving '${UPLINK}' to '${BRIDGE}'..."
# Drop the uplink's standalone profile (its IP relocates to the bridge) and
# recreate it as a bridge port. This is the brief cutover blip.
sudo nmcli connection delete "${UPLINK}" 2>/dev/null || true
if ! nmcli connection show "${SLAVE_CON}" &>/dev/null; then
    sudo nmcli connection add type ethernet con-name "${SLAVE_CON}" ifname "${UPLINK}" \
        master "${BRIDGE}" slave-type bridge
fi

echo "[HOST-NET] Bringing the bridge up..."
sudo nmcli connection up "${BRIDGE}" || true
sudo nmcli connection up "${SLAVE_CON}" || true

echo ""
echo "[HOST-NET] Done. hierophant is on the flat LAN."
echo "  Bridge : ${BRIDGE}  ->  ${HOST_IP} (gw ${GATEWAY})"
echo "  Uplink : ${UPLINK} (bridge port)"
echo "  eno1   : left idle (spare / future bond)"
ip -brief addr show "${BRIDGE}" 2>/dev/null || true
