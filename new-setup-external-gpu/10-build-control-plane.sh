#!/bin/bash
set -e

# Ensure SETUP_ROOT is set
if [ -z "${SETUP_ROOT}" ]; then
    export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
fi

source "${SETUP_ROOT}/new-setup-external-gpu/config-env.sh"
source "${SETUP_ROOT}/new-setup-external-gpu/05-MAC-addresses.sh"
source "${SETUP_ROOT}/new-setup-external-gpu/utils.sh"

CONTROL_NODE_IMAGE="/var/lib/libvirt/images/talos-metal-f1d3-v1.12.4.iso"

echo "[CP ISO] Using ISO at ${CONTROL_NODE_IMAGE}"

# Each control plane node is on a different physical NVMe drive for HA:
#   control-0 → nvme-362996-part1  (shares drive with NVMe OSD, different partition)
#   control-1 → nvme-362830-part1  (shares drive with workers 0+1)
#   control-2 → nvme-362984-part1  (shares drive with workers 2+3)
# Single-drive failure only loses 1 of 3 etcd members — quorum maintained.
# Resources: 4 vCPU, 16GB RAM each.
# NUMA node 0 pinning — same node as SAS HBA and GPU.
# Layout: worker-3 uses CPUs 0-13 (14 vCPU, NUMA 0)
#         control-plane uses CPUs 28-39 (3×4=12 vCPU)
#         CPUs 40-41 reserved for host (2 per NUMA node).
CONTROL_0_DISK="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362996-part1"
CONTROL_1_DISK="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part1"
CONTROL_2_DISK="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984-part1"

echo "--- BUILDING VM: control-0 ---"
sudo -n virsh destroy control-0 >/dev/null 2>&1 || true
sudo -n virsh undefine control-0 --remove-all-storage >/dev/null 2>&1 || true
echo "Wiping NVMe partition for control-0..."
sudo -n dd if=/dev/zero of="${CONTROL_0_DISK}" bs=1M count=10 conv=fsync || true
sudo -n virt-install \
  --virt-type kvm \
  --name control-0 \
  --ram 16384 \
  --vcpus 4 \
  --cpuset "28-31" \
  --disk path="${CONTROL_0_DISK}",bus=virtio \
  --cdrom "${CONTROL_NODE_IMAGE}" \
  --os-variant=linux2024 \
  --network network=lan,mac="${control_0_mac}" \
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
  --vcpus 4 \
  --cpuset "32-35" \
  --disk path="${CONTROL_1_DISK}",bus=virtio \
  --cdrom "${CONTROL_NODE_IMAGE}" \
  --os-variant=linux2024 \
  --network network=lan,mac="${control_1_mac}" \
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
  --vcpus 4 \
  --cpuset "36-39" \
  --disk path="${CONTROL_2_DISK}",bus=virtio \
  --cdrom "${CONTROL_NODE_IMAGE}" \
  --os-variant=linux2024 \
  --network network=lan,mac="${control_2_mac}" \
  --boot cdrom,hd --noautoconsole

echo ""
echo "Waiting for control plane to obtain IPs (60s)..."
sleep 60
echo "Control Plane IPs:"
sudo virsh domifaddr control-0
sudo virsh domifaddr control-1
sudo virsh domifaddr control-2
