#!/bin/bash
set -e

# Configuration for Test VM
VM_NAME="test-vm"
RAM=8192
VCPUS=4
DISK_SIZE="60G"
ISO_PATH="/var/lib/libvirt/images/talos-metal-f1d3-v1.12.4.iso"
MAC_ADDR="6A:69:11:AA:00:FF"
VM_IP="10.0.0.150"
TALOS_VERSION="v1.12.4"
REGISTRY="hierophant.hierocracy.home:5000"
INSTALLER_IMAGE="${REGISTRY}/siderolabs/installer-control-worker:${TALOS_VERSION}"
TALOS_BIN="/home/k8s/talos/talosctl"
SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"

# Check for non-interactive sudo capability
check_sudo() {
    if ! sudo -n true 2>/dev/null; then
        echo "WARNING: Passwordless sudo is not available for all commands. Some steps may fail."
    fi
}
check_sudo

echo "=== BUILDING TEST VM: ${VM_NAME} ==="

# 0. Ensure Network is setup
echo "[0/4] Checking libvirt networks..."

# Ensure host bridge for lb-net exists if not already present
if ! ip link show br-app >/dev/null 2>&1; then
    echo "Creating host bridge br-app..."
    sudo -n ip link add br-app type bridge || true
    sudo -n ip addr add 172.20.0.1/16 dev br-app || true
    sudo -n ip link set br-app up || true
    # If lb-net was already active, it might need to be restarted to recognize the new bridge
    sudo -n virsh net-destroy lb-net >/dev/null 2>&1 || true
fi

if ! sudo -n virsh net-info talos-nat >/dev/null 2>&1; then
    echo "Defining talos-nat network..."
    if [ -f "${SETUP_ROOT}/new-setup/talos-nat.xml" ]; then
        sudo -n virsh net-define "${SETUP_ROOT}/new-setup/talos-nat.xml"
    else
        echo "Creating basic talos-nat.xml..."
        cat > /tmp/talos-nat.xml <<EOF
<network>
  <name>talos-nat</name>
  <bridge name="talos-bridge" stp="on" delay="0"/>
  <ip address="10.0.0.1" netmask="255.255.255.0">
    <dhcp>
      <range start="10.0.0.20" end="10.0.0.30"/>
    </dhcp>
  </ip>
</network>
EOF
        sudo -n virsh net-define /tmp/talos-nat.xml
        rm /tmp/talos-nat.xml
    fi
fi
if [ "$(sudo -n virsh net-info talos-nat | grep 'Active' | awk '{print $2}')" != "yes" ]; then
    echo "Starting talos-nat network..."
    sudo -n virsh net-start talos-nat
fi

if ! sudo -n virsh net-info lb-net >/dev/null 2>&1; then
    echo "Defining lb-net network..."
    if [ -f "${SETUP_ROOT}/new-setup/lb-net.xml" ]; then
        sudo -n virsh net-define "${SETUP_ROOT}/new-setup/lb-net.xml"
    else
        echo "Creating basic lb-net.xml..."
        cat > /tmp/lb-net.xml <<EOF
<network>
  <name>lb-net</name>
  <forward mode='bridge'/>
  <bridge name='br-app'/>
</network>
EOF
        sudo -n virsh net-define /tmp/lb-net.xml
        rm /tmp/lb-net.xml
    fi
fi
if [ "$(sudo -n virsh net-info lb-net | grep 'Active' | awk '{print $2}')" != "yes" ]; then
    echo "Starting lb-net network..."
    sudo -n virsh net-start lb-net
fi

# Add our test VM to the network DHCP if not already there
if sudo -n virsh net-dumpxml talos-nat | grep -q "${MAC_ADDR}"; then
    echo "test-vm entry already exists in talos-nat DHCP."
else
    echo "Updating talos-nat DHCP with test-vm entry..."
    cat > /tmp/test-vm-net.xml <<EOF
<host mac='${MAC_ADDR}' name='${VM_NAME}' ip='${VM_IP}'/>
EOF
    sudo -n virsh net-update talos-nat add ip-dhcp-host /tmp/test-vm-net.xml --live --config || true
    rm /tmp/test-vm-net.xml
fi

# 1. Create Disk
echo "[1/4] Preparing disk volume in CONTROLLER pool..."
# Ensure pool exists
sudo -n virsh pool-info CONTROLLER >/dev/null 2>&1 || {
    sudo -n mkdir -p /var/lib/libvirt/storage-pools/CONTROLLER
    sudo -n virsh pool-define-as --name CONTROLLER --target /var/lib/libvirt/storage-pools/CONTROLLER --type dir
    sudo -n virsh pool-build CONTROLLER
    sudo -n virsh pool-start CONTROLLER
    sudo -n virsh pool-autostart CONTROLLER
}
# Delete existing volume if it exists to be idempotent
sudo -n virsh vol-delete --pool CONTROLLER "${VM_NAME}-disk.qcow2" >/dev/null 2>&1 || true
sudo -n virsh vol-create-as CONTROLLER "${VM_NAME}-disk.qcow2" "${DISK_SIZE}" --format qcow2

# 2. Start VM
echo "[2/4] Starting VM ${VM_NAME}..."
# Remove existing VM if it exists
sudo -n virsh destroy "${VM_NAME}" >/dev/null 2>&1 || true
sudo -n virsh undefine "${VM_NAME}" >/dev/null 2>&1 || true

sudo -n virt-install \
  --virt-type kvm \
  --name "${VM_NAME}" \
  --ram "${RAM}" \
  --vcpus "${VCPUS}" \
  --disk vol=CONTROLLER/"${VM_NAME}-disk.qcow2",bus=virtio \
  --cdrom "${ISO_PATH}" \
  --os-variant=linux2024 \
  --network network=talos-nat,mac="${MAC_ADDR}" \
  --network network=lb-net \
  --boot hd,cdrom --noautoconsole

echo "Waiting for VM to boot (approx 60s)..."
sleep 60

# 3. Verify IP
echo "[3/4] Verifying VM IP..."
ACTUAL_IP=$(sudo -n virsh domifaddr "${VM_NAME}" | grep -E '/' | awk '{print $4}' | cut -d/ -f1 | head -n 1)
if [ -z "$ACTUAL_IP" ]; then
    echo "WARNING: Could not find IP via domifaddr. Trying ping to ${VM_IP}..."
    if ping -c 1 -W 5 "${VM_IP}" >/dev/null 2>&1; then
        ACTUAL_IP="${VM_IP}"
    else
        echo "ERROR: VM ${VM_IP} is not reachable."
        exit 1
    fi
fi
echo "VM IP identified: ${ACTUAL_IP}"

# 4. Generate & Apply Config
echo "[4/4] Generating and applying Talos config..."
CONFIG_DIR="/home/junie/test-build-config"
mkdir -p "${CONFIG_DIR}"

echo "Generating config with installer: ${INSTALLER_IMAGE}"
"${TALOS_BIN}" gen config test-cluster "https://${ACTUAL_IP}:6443" \
  --install-disk /dev/vda \
  --install-image "${INSTALLER_IMAGE}" \
  --output "${CONFIG_DIR}" \
  --force

# Apply a patch to ensure it uses our local registry for other images too
cat > "${CONFIG_DIR}/patch.yaml" <<EOF
machine:
  registries:
    mirrors:
      "*":
        endpoints:
          - http://${REGISTRY}
EOF

"${TALOS_BIN}" machineconfig patch "${CONFIG_DIR}/controlplane.yaml" \
  --patch @"${CONFIG_DIR}/patch.yaml" \
  -o "${CONFIG_DIR}/controlplane.yaml.patched"
mv "${CONFIG_DIR}/controlplane.yaml.patched" "${CONFIG_DIR}/controlplane.yaml"

echo "Applying config to ${ACTUAL_IP}..."
"${TALOS_BIN}" apply-config --insecure --nodes "${ACTUAL_IP}" --endpoints "${ACTUAL_IP}" --file "${CONFIG_DIR}/controlplane.yaml"

echo ""
echo "=== TEST VM CONFIG APPLIED ==="
echo "Monitor installation with:"
echo "${TALOS_BIN} --talosconfig ${CONFIG_DIR}/talosconfig logs -n ${ACTUAL_IP} --endpoints ${ACTUAL_IP} installer"
echo ""
echo "Wait for the node to finish installing and reboot. Once the node is back up (ping reachable),"
echo "bootstrap the cluster with:"
echo "${TALOS_BIN} --talosconfig ${CONFIG_DIR}/talosconfig bootstrap -n ${ACTUAL_IP} -e ${ACTUAL_IP}"
