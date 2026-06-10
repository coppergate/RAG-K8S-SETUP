#!/bin/bash
set -e

# Ensure SETUP_ROOT is set
if [ -z "${SETUP_ROOT}" ]; then
    export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
fi

source "${SETUP_ROOT}/new-setup-single/config-env.sh" 
source "${SETUP_ROOT}/new-setup-single/05-MAC-addresses.sh"
source "${SETUP_ROOT}/new-setup-single/utils.sh"

# Use the Talos v1.12.4 Factory installer ISO for workers with net.ifnames=0.
# Hash: f1d36a4599ff60d0e94a2a86311470fbc0da2895bef4ba9b2c0288803986a846
WORKER_NODE_IMAGE_URL="https://factory.talos.dev/image/f1d36a4599ff60d0e94a2a86311470fbc0da2895bef4ba9b2c0288803986a846/v1.12.4/metal-amd64.iso"
WORKER_NODE_IMAGE="/var/lib/libvirt/images/talos-metal-f1d3-v1.12.4.iso"
LOCAL_WORKER_ISO="${SETUP_ROOT}/talos/iso-images/v1.12.4/talos-metal-f1d3-v1.12.4.iso"

# Use the Talos v1.12.4 Factory installer ISO for inference nodes with NVIDIA and net.ifnames=0.
# Hash: f0248d1e8abaffdec12ddc54bae270982f3ab5a70e3c7b0b11c11ca0fb1708d9
INFERENCE_NODE_IMAGE_URL="https://factory.talos.dev/image/f0248d1e8abaffdec12ddc54bae270982f3ab5a70e3c7b0b11c11ca0fb1708d9/v1.12.4/metal-amd64.iso"
INFERENCE_NODE_IMAGE="/var/lib/libvirt/images/talos-metal-f024-v1.12.4.iso"
LOCAL_INF_ISO="${SETUP_ROOT}/talos/iso-images/v1.12.4/talos-metal-f024-v1.12.4.iso"

echo "[WK ISO] Boot ISO: ${WORKER_NODE_IMAGE}"
if [ ! -f "${WORKER_NODE_IMAGE}" ]; then
  if [ -f "${LOCAL_WORKER_ISO}" ]; then
    echo "[WK ISO] Copying from local store: ${LOCAL_WORKER_ISO}"
    sudo cp "${LOCAL_WORKER_ISO}" "${WORKER_NODE_IMAGE}"
    sudo chmod 0644 "${WORKER_NODE_IMAGE}"
  else
    echo "[WK ISO] Not found locally, downloading from ${WORKER_NODE_IMAGE_URL}..."
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
  fi
else
  echo "[WK ISO] Using existing ISO at ${WORKER_NODE_IMAGE}"
fi

echo "[INF ISO] Boot ISO: ${INFERENCE_NODE_IMAGE}"
if [ ! -f "${INFERENCE_NODE_IMAGE}" ]; then
  if [ -f "${LOCAL_INF_ISO}" ]; then
    echo "[INF ISO] Copying from local store: ${LOCAL_INF_ISO}"
    sudo cp "${LOCAL_INF_ISO}" "${INFERENCE_NODE_IMAGE}"
    sudo chmod 0644 "${INFERENCE_NODE_IMAGE}"
  else
    echo "[INF ISO] Not found locally, downloading from ${INFERENCE_NODE_IMAGE_URL}..."
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
  fi
else
  echo "[INF ISO] Using existing ISO at ${INFERENCE_NODE_IMAGE}"
fi

# Ensure storage pool exists
sudo -n virsh pool-info CONTROLLER >/dev/null 2>&1 || {
    echo "Creating CONTROLLER storage pool..."
    sudo -n mkdir -p /var/lib/libvirt/storage-pools/CONTROLLER
    sudo -n virsh pool-define-as --name CONTROLLER --target /var/lib/libvirt/storage-pools/CONTROLLER --type dir
    sudo -n virsh pool-build CONTROLLER
    sudo -n virsh pool-start CONTROLLER
    sudo -n virsh pool-autostart CONTROLLER
}

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

# attachable disks for storage
STORAGE_0_DISK="/dev/disk/by-id/ata-ST2000DM008-2FR102_ZFL32CQR" 
STORAGE_1_DISK="/dev/disk/by-id/ata-ST2000DM008-2FR102_ZFL32BZX" 
STORAGE_2_DISK="/dev/disk/by-id/ata-ST2000DM008-2FR102_ZFL32BA2" 
STORAGE_3_DISK="/dev/disk/by-id/ata-ST2000DM008-2FR102_ZFL34JEA"

# Disk for single inference node (boot disk from former inference-0 partition)
INFERENCE_0_DISK="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part2"
# Additional storage disk attached to the single inference node (former inference-1 partition)
INFERENCE_EXTRA_DISK="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984-part2"

echo "BUILDING WORKER NODES"
for i in {0..3}; do
  mac_var="data_${i}_mac"
  extern_mac_var="data_${i}_extern_mac"
  disk_var="WORKER_${i}_DISK"
  name="worker-${i}"
  
  echo "--- BUILDING VM: $name ---"
  sudo -n virsh destroy "$name" >/dev/null 2>&1 || true
  sudo -n virsh undefine "$name" --remove-all-storage >/dev/null 2>&1 || true

  echo "Wiping NVMe partition for $name..."
  sudo -n dd if=/dev/zero of="${!disk_var}" bs=1M count=10 conv=fsync || true

  echo "Running virt-install for $name..."
  sudo -E virt-install \
    --virt-type kvm \
    --name "$name" \
    --ram 36864 \
    --vcpus 7 \
    --disk path="${!disk_var}",bus=virtio \
    --cdrom "${WORKER_NODE_IMAGE}" \
    --os-variant=linux2024 \
    --network network=talos-nat,mac="${!mac_var}" \
    --network network=lb-net,mac="${!extern_mac_var}" \
    --boot cdrom,hd --noautoconsole
done

echo "Attach extra disks to workers (Storage and Ceph Metadata)"
for i in {0..3}; do
  name="worker-${i}"
  storage_disk_var="STORAGE_${i}_DISK"
  meta_disk_var="WORKER_${i}_META"
  
  echo "Attaching disks to $name..."
  sudo -n virsh attach-disk "$name" "${!storage_disk_var}" vdb --driver qemu --subdriver raw --sourcetype block --targetbus virtio --cache none --io native --persistent --config
  sudo -n virsh attach-disk "$name" "${!meta_disk_var}" vdc --driver qemu --subdriver raw --sourcetype block --targetbus virtio --cache none --io native --persistent --config
done

echo "BUILDING INFERENCE NODE (single combined node)"
echo "--- BUILDING VM: inference-0 ---"
sudo -n virsh destroy "inference-0" >/dev/null 2>&1 || true
sudo -n virsh undefine "inference-0" --remove-all-storage >/dev/null 2>&1 || true

echo "Wiping NVMe partition for inference-0..."
sudo -n dd if=/dev/zero of="${INFERENCE_0_DISK}" bs=1M count=10 conv=fsync || true

sudo -E virt-install \
  --virt-type kvm \
  --name "inference-0" \
  --ram 65536 \
  --vcpus 16 \
  --cpuset "0-27,42-55" \
  --disk path="${INFERENCE_0_DISK}",bus=virtio \
  --cdrom "${INFERENCE_NODE_IMAGE}" \
  --os-variant=linux2024 \
  --network network=talos-nat,mac="${inference_0_mac}" \
  --network network=lb-net,mac="${inference_0_extern_mac}" \
  --boot cdrom,hd --noautoconsole

echo "Attaching extra storage disk to inference-0 (former inference-1 partition)..."
sudo -n virsh attach-disk "inference-0" "${INFERENCE_EXTRA_DISK}" vdb \
  --driver qemu --subdriver raw --sourcetype block \
  --targetbus virtio --cache none --io native --persistent --config

echo "waiting for nodes to obtain IPs"
sleep 60
for i in {0..3}; do
  sudo virsh domifaddr "worker-${i}";
done

sudo virsh domifaddr inference-0
