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

echo "=== BUILDING TEST VM: ${VM_NAME} ==="

# 0. Ensure Network is setup
echo "[0/4] Checking libvirt networks..."
if ! sudo virsh net-info talos-nat >/dev/null 2>&1; then
    echo "Defining talos-nat network..."
    if [ -f "${SETUP_ROOT}/new-setup/talos-nat.xml" ]; then
        sudo virsh net-define "${SETUP_ROOT}/new-setup/talos-nat.xml"
    else
        echo "Creating basic talos-nat.xml..."
        cat > /tmp/talos-nat.xml <<EOF
<network>
  <name>talos-nat</name>
  <bridge name="talos-bridge" stp="on" delay="0"/>
  <forward mode="nat">
    <nat/>
  </forward>
  <ip address="10.0.0.1" netmask="255.255.255.0">
    <dhcp>
      <range start="10.0.0.20" end="10.0.0.30"/>
    </dhcp>
  </ip>
</network>
EOF
        sudo virsh net-define /tmp/talos-nat.xml
        rm /tmp/talos-nat.xml
    fi
fi
if [ "$(sudo virsh net-info talos-nat | grep 'Active' | awk '{print $2}')" != "yes" ]; then
    echo "Starting talos-nat network..."
    sudo virsh net-start talos-nat
fi

if ! sudo virsh net-info lb-net >/dev/null 2>&1; then
    echo "Defining lb-net network..."
    if [ -f "${SETUP_ROOT}/new-setup/lb-net.xml" ]; then
        sudo virsh net-define "${SETUP_ROOT}/new-setup/lb-net.xml"
    else
        echo "Creating basic lb-net.xml..."
        cat > /tmp/lb-net.xml <<EOF
<network>
  <name>lb-net</name>
  <forward mode='bridge'/>
  <bridge name='br-app'/>
</network>
EOF
        sudo virsh net-define /tmp/lb-net.xml
        rm /tmp/lb-net.xml
    fi
fi
if [ "$(sudo virsh net-info lb-net | grep 'Active' | awk '{print $2}')" != "yes" ]; then
    echo "Starting lb-net network..."
    sudo virsh net-start lb-net
fi

# Add our test VM to the network DHCP if not already there
if sudo virsh net-dumpxml talos-nat | grep -q "${MAC_ADDR}"; then
    echo "test-vm entry already exists in talos-nat DHCP."
else
    echo "Updating talos-nat DHCP with test-vm entry..."
    cat > /tmp/test-vm-net.xml <<EOF
<host mac='${MAC_ADDR}' name='${VM_NAME}' ip='${VM_IP}'/>
EOF
    sudo virsh net-update talos-nat add ip-dhcp-host /tmp/test-vm-net.xml --live --config || true
    rm /tmp/test-vm-net.xml
fi

# 1. Create Disk
echo "[1/4] Creating disk volume in CONTROLLER pool..."
# Ensure pool exists
sudo virsh pool-info CONTROLLER >/dev/null 2>&1 || {
    sudo mkdir -p /var/lib/libvirt/storage-pools/CONTROLLER
    sudo virsh pool-define-as --name CONTROLLER --target /var/lib/libvirt/storage-pools/CONTROLLER --type dir
    sudo virsh pool-build CONTROLLER
    sudo virsh pool-start CONTROLLER
    sudo virsh pool-autostart CONTROLLER
}
sudo virsh vol-create-as CONTROLLER "${VM_NAME}-disk.qcow2" "${DISK_SIZE}" --format qcow2 || echo "Volume might already exist, proceeding..."

# 2. Start VM
echo "[2/4] Starting VM ${VM_NAME}..."
# Remove existing VM if it exists
sudo virsh destroy "${VM_NAME}" >/dev/null 2>&1 || true
sudo virsh undefine "${VM_NAME}" --remove-all-storage >/dev/null 2>&1 || true

# Re-create disk since we might have just deleted it
sudo virsh vol-create-as CONTROLLER "${VM_NAME}-disk.qcow2" "${DISK_SIZE}" --format qcow2 || true

sudo virt-install \
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
ACTUAL_IP=$(sudo virsh domifaddr "${VM_NAME}" | grep -E '/' | awk '{print $4}' | cut -d/ -f1 | head -n 1)
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
mkdir -p "${SETUP_ROOT}/test-build/config"

echo "Generating config with installer: ${INSTALLER_IMAGE}"
"${TALOS_BIN}" gen config test-cluster "https://${ACTUAL_IP}:6443" \
  --install-disk /dev/vda \
  --install-image "${INSTALLER_IMAGE}" \
  --output "${SETUP_ROOT}/test-build/config" \
  --force

# Apply a patch to ensure it uses our local registry for other images too
cat > "${SETUP_ROOT}/test-build/config/patch.yaml" <<EOF
machine:
  registries:
    mirrors:
      "*":
        endpoints:
          - http://${REGISTRY}
EOF

"${TALOS_BIN}" machineconfig patch "${SETUP_ROOT}/test-build/config/controlplane.yaml" \
  --patch @"${SETUP_ROOT}/test-build/config/patch.yaml" \
  -o "${SETUP_ROOT}/test-build/config/controlplane.yaml.patched"
mv "${SETUP_ROOT}/test-build/config/controlplane.yaml.patched" "${SETUP_ROOT}/test-build/config/controlplane.yaml"

echo "Applying config to ${ACTUAL_IP}..."
"${TALOS_BIN}" --insecure apply-config --nodes "${ACTUAL_IP}" --endpoints "${ACTUAL_IP}" --file "${SETUP_ROOT}/test-build/config/controlplane.yaml"

echo ""
echo "=== TEST VM CONFIG APPLIED ==="
echo "Monitor installation with:"
echo "${TALOS_BIN} --insecure logs -n ${ACTUAL_IP} --endpoints ${ACTUAL_IP} installer"
