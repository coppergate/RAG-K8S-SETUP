#!/bin/bash
# ==============================================================================
# HIEROPHANT LIBVIRT NETWORK — new-setup-external-gpu (flat LAN)
#
# Defines a single libvirt network 'lan' that is a pure bridge onto br-lan
# (the flat-LAN host bridge created by hierophant-host-net.sh). All cluster VMs
# attach to this network and get LAN addresses directly.
#
# Replaces the old talos-nat (NAT) + lb-net (VLAN bridge) networks, which are
# destroyed/undefined here if present.
#
# MUST be run on hierophant (as root / with sudo), AFTER hierophant-host-net.sh.
# ==============================================================================
set -e

BRIDGE="br-lan"

echo "[LIBVIRT-NET] Verifying host bridge '${BRIDGE}' exists..."
if ! ip link show "${BRIDGE}" &>/dev/null; then
    echo "ERROR: '${BRIDGE}' not found. Run hierophant-host-net.sh first." >&2
    exit 1
fi

echo "[LIBVIRT-NET] Removing legacy libvirt networks (talos-nat, lb-net)..."
for net in talos-nat lb-net; do
    sudo virsh net-destroy  "$net" 2>/dev/null || true
    sudo virsh net-undefine "$net" 2>/dev/null || true
done

echo "[LIBVIRT-NET] Defining the flat-LAN network 'lan' (bridge ${BRIDGE})..."
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
echo "[LIBVIRT-NET] Done. Cluster VMs attach with: --network network=lan"
sudo virsh net-list
