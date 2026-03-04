#!/bin/bash
set -e

# Ensure SETUP_ROOT is set
if [ -z "${SETUP_ROOT}" ]; then
    export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
fi

source "${SETUP_ROOT}/new-setup/config-env.sh" 
source "${SETUP_ROOT}/new-setup/05-MAC-addresses.sh"
source "${SETUP_ROOT}/new-setup/utils.sh"

CONTROL_NODE_IMAGE="/var/lib/libvirt/images/talos-metal-f1d3-v1.12.4.iso"

echo "[CP ISO] Using ISO at ${CONTROL_NODE_IMAGE}"

# Ensure storage pool exists (basics mode)
sudo -n virsh pool-info CONTROLLER >/dev/null 2>&1 || {
    echo "Creating CONTROLLER storage pool..."
    sudo -n mkdir -p /var/lib/libvirt/storage-pools/CONTROLLER
    sudo -n virsh pool-define-as --name CONTROLLER --target /var/lib/libvirt/storage-pools/CONTROLLER --type dir
    sudo -n virsh pool-build CONTROLLER
    sudo -n virsh pool-start CONTROLLER
    sudo -n virsh pool-autostart CONTROLLER
}

# Function to build a VM (basics mode: all on qcow2, minimal flags)
build_vm() {
    local name=$1
    local mac=$2
    local ext_mac=$3
    
    echo "--- BUILDING VM: $name ---"
    # Clean up existing VM and volume if any (idempotency like in test-build)
    sudo -n virsh destroy "$name" >/dev/null 2>&1 || true
    sudo -n virsh undefine "$name" --remove-all-storage >/dev/null 2>&1 || true
    sudo -n virsh vol-delete --pool CONTROLLER "${name}-disk.qcow2" >/dev/null 2>&1 || true
    
    echo "Creating 60GB disk for $name..."
    sudo -n virsh vol-create-as CONTROLLER "${name}-disk.qcow2" 60G --format qcow2

    echo "Running virt-install for $name..."
    sudo -n virt-install \
      --virt-type kvm \
      --name "$name" \
      --ram 8192 \
      --vcpus 4 \
      --disk vol=CONTROLLER/"${name}-disk.qcow2",bus=virtio \
      --cdrom "${CONTROL_NODE_IMAGE}" \
      --os-variant=linux2024 \
      --network network=talos-nat,mac="$mac" \
      --network network=lb-net,mac="$ext_mac" \
      --boot hd,cdrom --noautoconsole
}

# Build the 3 control plane nodes
build_vm "control-0" "${control_0_mac}" "${control_0_extern_mac}"
build_vm "control-1" "${control_1_mac}" "${control_1_extern_mac}"
build_vm "control-2" "${control_2_mac}" "${control_2_extern_mac}"

echo ""
echo "Waiting for control plane to obtain IPs (60s)..."
sleep 60
echo "Control Plane IPs:"
sudo virsh domifaddr control-0
sudo virsh domifaddr control-1
sudo virsh domifaddr control-2
