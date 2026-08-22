#!/bin/bash
# ==============================================================================
# HEGEMON HOST NETWORK — new-setup-external-gpu (flat LAN)
#
# Puts hegemon on the flat LAN with a single Linux bridge (br-lan) over eno1,
# and defines a libvirt 'lan' network so the dev-fedora VM can attach directly
# to the LAN (no NAT, no relay).
#
# Retires the old cross-host access path entirely:
#   - the 'agent-link' libvirt NAT network (172.16.0.0/16)
#   - the /etc/libvirt/hooks/network nftables hook (masquerade → 10.0.0.0/24)
#
#   Host IP  : 192.168.1.100/16   Gateway: 192.168.0.1   DNS: 192.168.1.210
#
# ⚠  CUTOVER: moving the host IP onto br-lan briefly drops connectivity on
#    eno1. Run from console, or detached:
#        sudo nohup bash hegemon-host-net.sh &>/tmp/host-net.log &
#
# MUST be run on hegemon (as root / with sudo).
# ==============================================================================
set -e

BRIDGE="br-lan"
UPLINK="eno1"
HOST_IP="192.168.1.100/16"
GATEWAY="192.168.0.1"
DNS="192.168.1.210,1.1.1.1,8.8.8.8"
DNS_SEARCH="hierocracy,hierocracy.home"
SLAVE_CON="${BRIDGE}-${UPLINK}"

echo "[HOST-NET] Verifying uplink interface '${UPLINK}' exists..."
if ! ip link show "${UPLINK}" &>/dev/null; then
    echo "ERROR: expected uplink '${UPLINK}' not found on this host." >&2
    exit 1
fi

# --- Retire the old dev-fedora relay ----------------------------------------
echo "[HOST-NET] Removing legacy 'agent-link' libvirt network..."
sudo virsh net-destroy  agent-link 2>/dev/null || true
sudo virsh net-undefine agent-link 2>/dev/null || true

HOOK="/etc/libvirt/hooks/network"
if [ -f "${HOOK}" ] && grep -q "hegemon agent-link" "${HOOK}" 2>/dev/null; then
    echo "[HOST-NET] Removing our libvirt network hook (${HOOK})..."
    sudo mv "${HOOK}" "${HOOK}.retired.$(date +%s 2>/dev/null || echo bak)" 2>/dev/null \
        || sudo rm -f "${HOOK}"
fi

# --- Build the LAN bridge ----------------------------------------------------
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
sudo nmcli connection delete "${UPLINK}" 2>/dev/null || true
if ! nmcli connection show "${SLAVE_CON}" &>/dev/null; then
    sudo nmcli connection add type ethernet con-name "${SLAVE_CON}" ifname "${UPLINK}" \
        master "${BRIDGE}" slave-type bridge
fi

sudo nmcli connection up "${BRIDGE}" || true
sudo nmcli connection up "${SLAVE_CON}" || true

# --- Define the libvirt 'lan' network so dev-fedora can bridge to the LAN ----
echo "[HOST-NET] Defining libvirt 'lan' network (bridge ${BRIDGE})..."
cat > /tmp/lan-net.xml <<EOF
<network>
  <name>lan</name>
  <forward mode='bridge'/>
  <bridge name='${BRIDGE}'/>
</network>
EOF
sudo virsh net-destroy  lan 2>/dev/null || true
sudo virsh net-undefine lan 2>/dev/null || true
sudo virsh net-define   /tmp/lan-net.xml
sudo virsh net-start     lan
sudo virsh net-autostart lan
rm -f /tmp/lan-net.xml

echo ""
echo "[HOST-NET] Done. hegemon is on the flat LAN; libvirt 'lan' network ready."
echo "  Bridge : ${BRIDGE}  ->  ${HOST_IP} (gw ${GATEWAY})"
echo ""
echo "Point the dev-fedora VM at the LAN, then reboot it:"
echo "  sudo virsh detach-interface dev-fedora network --config   # (repeat for old NICs)"
echo "  sudo virsh attach-interface dev-fedora network lan --model virtio --config"
echo "  sudo virsh reboot dev-fedora"
echo "Then run network/dev-fedora-net.sh inside the VM."
