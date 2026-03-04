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

# Ensure storage pool exists
sudo -n virsh pool-info CONTROLLER >/dev/null 2>&1 || {
    echo "Creating CONTROLLER storage pool..."
    sudo -n mkdir -p /var/lib/libvirt/storage-pools/CONTROLLER
    sudo -n virsh pool-define-as --name CONTROLLER --target /var/lib/libvirt/storage-pools/CONTROLLER --type dir
    sudo -n virsh pool-build CONTROLLER
    sudo -n virsh pool-start CONTROLLER
    sudo -n virsh pool-autostart CONTROLLER
}

# Disks for control plane (control-0 on qcow2, 1 and 2 on NVMe)
CONTROL_1_DISK="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part1"
CONTROL_2_DISK="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984-part1"

echo "--- BUILDING VM: control-0 ---"
sudo -n virsh destroy control-0 >/dev/null 2>&1 || true
sudo -n virsh undefine control-0 --remove-all-storage >/dev/null 2>&1 || true
sudo -n virsh vol-delete --pool CONTROLLER "control-0-disk.qcow2" >/dev/null 2>&1 || true

echo "Creating 60GB disk for control-0..."
sudo -n virsh vol-create-as CONTROLLER "control-0-disk.qcow2" 60G --format qcow2

echo "Running virt-install for control-0..."
sudo -n virt-install \
  --virt-type kvm \
  --name control-0 \
  --ram 8192 \
  --vcpus 4 \
  --disk vol=CONTROLLER/control-0-disk.qcow2,bus=virtio \
  --cdrom "${CONTROL_NODE_IMAGE}" \
  --os-variant=linux2024 \
  --network network=talos-nat,mac="${control_0_mac}" \
  --network network=lb-net,mac="${control_0_extern_mac}" \
  --boot hd,cdrom --noautoconsole

echo "--- BUILDING VM: control-1 ---"
sudo -n virsh destroy control-1 >/dev/null 2>&1 || true
sudo -n virsh undefine control-1 --remove-all-storage >/dev/null 2>&1 || true
sudo -n virt-install \
  --virt-type kvm \
  --name control-1 \
  --ram 8192 \
  --vcpus 4 \
  --disk path="${CONTROL_1_DISK}",bus=virtio \
  --cdrom "${CONTROL_NODE_IMAGE}" \
  --os-variant=linux2024 \
  --network network=talos-nat,mac="${control_1_mac}" \
  --network network=lb-net,mac="${control_1_extern_mac}" \
  --boot hd,cdrom --noautoconsole

echo "--- BUILDING VM: control-2 ---"
sudo -n virsh destroy control-2 >/dev/null 2>&1 || true
sudo -n virsh undefine control-2 --remove-all-storage >/dev/null 2>&1 || true
sudo -n virt-install \
  --virt-type kvm \
  --name control-2 \
  --ram 8192 \
  --vcpus 4 \
  --disk path="${CONTROL_2_DISK}",bus=virtio \
  --cdrom "${CONTROL_NODE_IMAGE}" \
  --os-variant=linux2024 \
  --network network=talos-nat,mac="${control_2_mac}" \
  --network network=lb-net,mac="${control_2_extern_mac}" \
  --boot hd,cdrom --noautoconsole

echo ""
echo "Waiting for control plane to obtain IPs (60s)..."
sleep 60
echo "Control Plane IPs:"
sudo virsh domifaddr control-0
sudo virsh domifaddr control-1
sudo virsh domifaddr control-2
