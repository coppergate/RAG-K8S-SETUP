#!/bin/bash
set -e

# Ensure SETUP_ROOT is set
if [ -z "${SETUP_ROOT}" ]; then
    export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
fi

source "${SETUP_ROOT}/new-setup-single/config-env.sh"
source "${SETUP_ROOT}/new-setup-single/05-MAC-addresses.sh"
source "${SETUP_ROOT}/new-setup-single/utils.sh"

CONTROL_NODE_IMAGE="/var/lib/libvirt/images/talos-metal-f1d3-v1.12.4.iso"

echo "[CP ISO] Using ISO at ${CONTROL_NODE_IMAGE}"

# All three control plane nodes use dedicated partitions on nvme-362996.
# This drive is reserved exclusively for the control plane — no Ceph IO contention.
# Resources: 6 vCPU, 16GB RAM each (upgraded from 4 vCPU / 8GB for etcd stability).
CONTROL_0_DISK="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362996-part1"
CONTROL_1_DISK="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362996-part2"
CONTROL_2_DISK="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362996-part3"

echo "--- BUILDING VM: control-0 ---"
sudo -n virsh destroy control-0 >/dev/null 2>&1 || true
sudo -n virsh undefine control-0 --remove-all-storage >/dev/null 2>&1 || true
echo "Wiping NVMe partition for control-0..."
sudo -n dd if=/dev/zero of="${CONTROL_0_DISK}" bs=1M count=10 conv=fsync || true
sudo -n virt-install \
  --virt-type kvm \
  --name control-0 \
  --ram 16384 \
  --vcpus 6 \
  --disk path="${CONTROL_0_DISK}",bus=virtio \
  --cdrom "${CONTROL_NODE_IMAGE}" \
  --os-variant=linux2024 \
  --network network=talos-nat,mac="${control_0_mac}" \
  --network network=lb-net,mac="${control_0_extern_mac}" \
  --boot cdrom,hd --noautoconsole

echo "--- BUILDING VM: control-1 ---"
sudo -n virsh destroy control-1 >/dev/null 2>&1 || true
sudo -n virsh undefine control-1 --remove-all-storage >/dev/null 2>&1 || true
echo "Wiping NVMe partition for control-1..."
sudo -n dd if=/dev/zero of="${CONTROL_1_DISK}" bs=1M count=10 conv=fsync || true
sudo -n virt-install \
  --virt-type kvm \
  --name control-1 \
  --ram 16384 \
  --vcpus 6 \
  --disk path="${CONTROL_1_DISK}",bus=virtio \
  --cdrom "${CONTROL_NODE_IMAGE}" \
  --os-variant=linux2024 \
  --network network=talos-nat,mac="${control_1_mac}" \
  --network network=lb-net,mac="${control_1_extern_mac}" \
  --boot cdrom,hd --noautoconsole

echo "--- BUILDING VM: control-2 ---"
sudo -n virsh destroy control-2 >/dev/null 2>&1 || true
sudo -n virsh undefine control-2 --remove-all-storage >/dev/null 2>&1 || true
echo "Wiping NVMe partition for control-2..."
sudo -n dd if=/dev/zero of="${CONTROL_2_DISK}" bs=1M count=10 conv=fsync || true
sudo -n virt-install \
  --virt-type kvm \
  --name control-2 \
  --ram 16384 \
  --vcpus 6 \
  --disk path="${CONTROL_2_DISK}",bus=virtio \
  --cdrom "${CONTROL_NODE_IMAGE}" \
  --os-variant=linux2024 \
  --network network=talos-nat,mac="${control_2_mac}" \
  --network network=lb-net,mac="${control_2_extern_mac}" \
  --boot cdrom,hd --noautoconsole

echo ""
echo "Waiting for control plane to obtain IPs (60s)..."
sleep 60
echo "Control Plane IPs:"
sudo virsh domifaddr control-0
sudo virsh domifaddr control-1
sudo virsh domifaddr control-2
