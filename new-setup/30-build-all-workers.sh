#!/bin/bash
set -e

# Ensure SETUP_ROOT is set
if [ -z "${SETUP_ROOT}" ]; then
    export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
fi

source "${SETUP_ROOT}/new-setup/config-env.sh" 
source "${SETUP_ROOT}/new-setup/05-MAC-addresses.sh"
source "${SETUP_ROOT}/new-setup/utils.sh"

# Use the official Talos v1.12.4 generic installer ISO for boot (maintenance mode).
# Extensions are preserved by install.image in per-node patches.
WORKER_NODE_IMAGE_URL="https://github.com/siderolabs/talos/releases/download/v1.12.4/metal-amd64.iso"
WORKER_NODE_IMAGE="/var/lib/libvirt/images/talos-metal-amd64-v1.12.4.iso"

# Inference nodes boot the same generic ISO; extensions come from install.image
INFERENCE_NODE_IMAGE_URL="https://github.com/siderolabs/talos/releases/download/v1.12.4/metal-amd64.iso"
INFERENCE_NODE_IMAGE="/var/lib/libvirt/images/talos-metal-amd64-v1.12.4.iso"

echo "[WK ISO] Boot ISO (Talos v1.12.4 generic): ${WORKER_NODE_IMAGE_URL}"
echo "[WK ISO] Local path: ${WORKER_NODE_IMAGE}"
if [ ! -f "${WORKER_NODE_IMAGE}" ]; then
  echo "[WK ISO] Downloading Talos v1.12.4 worker ISO..."
  tmpfile=$(mktemp)
  if curl -fL "${WORKER_NODE_IMAGE_URL}" -o "${tmpfile}"; then
    sudo mkdir -p /var/lib/libvirt/images
    sudo install -m 0644 "${tmpfile}" "${WORKER_NODE_IMAGE}"
    rm -f "${tmpfile}"
  else
    echo "ERROR: Failed to download ${WORKER_NODE_IMAGE_URL}" >&2
    rm -f "${tmpfile}"
    exit 1
  fi
else
  echo "[WK ISO] Using existing ISO at ${WORKER_NODE_IMAGE}"
fi

echo "[INF ISO] Boot ISO (Talos v1.12.4 generic): ${INFERENCE_NODE_IMAGE_URL}"
echo "[INF ISO] Local path: ${INFERENCE_NODE_IMAGE}"
if [ ! -f "${INFERENCE_NODE_IMAGE}" ]; then
  echo "[INF ISO] Downloading Talos v1.12.4 inference ISO..."
  tmpfile=$(mktemp)
  if curl -fL "${INFERENCE_NODE_IMAGE_URL}" -o "${tmpfile}"; then
    sudo mkdir -p /var/lib/libvirt/images
    sudo install -m 0644 "${tmpfile}" "${INFERENCE_NODE_IMAGE}"
    rm -f "${tmpfile}"
  else
    echo "ERROR: Failed to download ${INFERENCE_NODE_IMAGE_URL}" >&2
    rm -f "${tmpfile}"
    exit 1
  fi
else
  echo "[INF ISO] Using existing ISO at ${INFERENCE_NODE_IMAGE}"
fi

# Disks for workers
WORKER_0_DISK="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362996-part1"
WORKER_1_DISK="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362996-part2"
WORKER_2_DISK="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362935-part1"
WORKER_3_DISK="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362935-part2"

# Ceph Metadata disks for workers (on NVMe)
WORKER_0_META="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362996-part3"
WORKER_1_META="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362996-part4"
WORKER_2_META="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362935-part3"
WORKER_3_META="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362935-part4"

# attachable disks for storage<
STORAGE_0_DISK="/dev/disk/by-id/ata-ST2000DM008-2FR102_ZFL32CQR" 
STORAGE_1_DISK="/dev/disk/by-id/ata-ST2000DM008-2FR102_ZFL32BZX" 
STORAGE_2_DISK="/dev/disk/by-id/ata-ST2000DM008-2FR102_ZFL32BA2" 
STORAGE_3_DISK="/dev/disk/by-id/ata-ST2000DM008-2FR102_ZFL34JEA"


# Disks for inference
INFERENCE_0_DISK="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part2"
INFERENCE_1_DISK="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984-part2"

echo "BUILDING WORKER NODES"
for i in {0..3}; do
  mac_var="data_${i}_mac"
  extern_mac_var="data_${i}_extern_mac"
  disk_var="WORKER_${i}_DISK"
  
  echo "worker-${i}"
  sudo -E virt-install \
    --virt-type kvm \
    --name "worker-${i}" \
    --ram 32768 \
    --vcpus 5 \
    --disk path="${!disk_var}",bus=virtio \
    --cdrom "${WORKER_NODE_IMAGE}" \
    --os-variant=linux2024 \
    --network network=talos-nat,mac="${!mac_var}" \
    --network network=lb-net,mac="${!extern_mac_var}" \
    --boot hd,cdrom --noautoconsole
done

echo "Attach extra disks to workers (Storage and Ceph Metadata)"
sudo virsh attach-disk worker-0 ${STORAGE_0_DISK} vdb --driver qemu --subdriver raw --sourcetype block --targetbus virtio --cache none --io native --persistent --config
sudo virsh attach-disk worker-0 ${WORKER_0_META} vdc --driver qemu --subdriver raw --sourcetype block --targetbus virtio --cache none --io native --persistent --config

sudo virsh attach-disk worker-1 ${STORAGE_1_DISK} vdb --driver qemu --subdriver raw --sourcetype block --targetbus virtio --cache none --io native --persistent --config
sudo virsh attach-disk worker-1 ${WORKER_1_META} vdc --driver qemu --subdriver raw --sourcetype block --targetbus virtio --cache none --io native --persistent --config

sudo virsh attach-disk worker-2 ${STORAGE_2_DISK} vdb --driver qemu --subdriver raw --sourcetype block --targetbus virtio --cache none --io native --persistent --config
sudo virsh attach-disk worker-2 ${WORKER_2_META} vdc --driver qemu --subdriver raw --sourcetype block --targetbus virtio --cache none --io native --persistent --config

sudo virsh attach-disk worker-3 ${STORAGE_3_DISK} vdb --driver qemu --subdriver raw --sourcetype block --targetbus virtio --cache none --io native --persistent --config
sudo virsh attach-disk worker-3 ${WORKER_3_META} vdc --driver qemu --subdriver raw --sourcetype block --targetbus virtio --cache none --io native --persistent --config

echo "BUILDING INFERENCE NODES"
echo "inference-0 (Pinned to NUMA 0)"
sudo -E virt-install \
  --virt-type kvm \
  --name inference-0 \
  --ram 32768 \
  --vcpus 9 \
  --cpuset 0-13,28-41 \
  --disk path="${INFERENCE_0_DISK}",bus=virtio \
  --cdrom "${INFERENCE_NODE_IMAGE}" \
  --os-variant=linux2024 \
  --network network=talos-nat,mac="${inference_0_mac}" \
  --network network=lb-net,mac="${inference_0_extern_mac}" \
  --boot hd,cdrom --noautoconsole

echo "inference-1 (Pinned to NUMA 1)"
sudo -E virt-install \
  --virt-type kvm \
  --name inference-1 \
  --ram 32768 \
  --vcpus 9 \
  --cpuset 14-27,42-55 \
  --disk path="${INFERENCE_1_DISK}",bus=virtio \
  --cdrom "${INFERENCE_NODE_IMAGE}" \
  --os-variant=linux2024 \
  --network network=talos-nat,mac="${inference_1_mac}" \
  --network network=lb-net,mac="${inference_1_extern_mac}" \
  --boot hd,cdrom --noautoconsole

echo "waiting for nodes to obtain IPs"
sleep 60
for i in {0..3}; do 
  sudo virsh domifaddr "worker-${i}"; 
done

sudo virsh domifaddr inference-0
sudo virsh domifaddr inference-1
