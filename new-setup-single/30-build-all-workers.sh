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

# 3-worker layout: workers 0-2 only. Worker-3 eliminated to reduce vCPU contention.
# Worker OS disks: partition layout is ctrl(p1) + w-OS(p2) + w-DB(p3) + w-OS(p4) + w-DB(p5)
# on each of nvme-362830 (workers 0+1) and nvme-362984 (worker 2).
WORKER_0_DISK="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part2"
WORKER_1_DISK="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part4"
WORKER_2_DISK="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984-part2"

# Ceph bluestore DB partitions (NVMe, raw) — NVMe metadata acceleration for HDD OSDs.
WORKER_0_BLUESTORE_DB="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part3"
WORKER_1_BLUESTORE_DB="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part5"
WORKER_2_BLUESTORE_DB="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984-part3"

# Ceph data (HDD) disks — one 1.8TB spinning disk per worker (vdb), used for OSD data.
STORAGE_0_DISK="/dev/disk/by-id/ata-ST2000DM008-2FR102_ZFL32CQR"
STORAGE_1_DISK="/dev/disk/by-id/ata-ST2000DM008-2FR102_ZFL32BZX"
STORAGE_2_DISK="/dev/disk/by-id/ata-ST2000DM008-2FR102_ZFL32BA2"

# NVMe-only fast-tier OSD: 195GB partition on nvme-362996-part2, attached to worker-0 as vdd.
# This is on a separate physical NVMe from worker-0's OS (362830), so no IO contention.
NVME_OSD_DISK="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362996-part2"

# Inference node: dedicated NVMe (nvme-362935).
# p1 = OS (80GB), p2 = model storage (150GB, attached as vdb).
INFERENCE_0_DISK="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362935-part1"
INFERENCE_MODEL_DISK="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362935-part2"

# NUMA node 1 CPU pinning for workers (NVMe drives are on NUMA 1).
# Each worker gets 8 vCPUs: 4 physical cores + 4 HT siblings on NUMA 1.
# CPUs 26-27 reserved for host kernel and NVMe IRQ processing (2 per NUMA node).
WORKER_CPUSETS=("14-17,42-45" "18-21,46-49" "22-25,50-53")

echo "BUILDING WORKER NODES (3 workers)"
for i in {0..2}; do
  mac_var="data_${i}_mac"
  extern_mac_var="data_${i}_extern_mac"
  disk_var="WORKER_${i}_DISK"
  name="worker-${i}"
  cpuset="${WORKER_CPUSETS[$i]}"

  echo "--- BUILDING VM: $name (cpuset: $cpuset) ---"
  sudo -n virsh destroy "$name" >/dev/null 2>&1 || true
  sudo -n virsh undefine "$name" --remove-all-storage >/dev/null 2>&1 || true

  echo "Wiping NVMe partition for $name..."
  sudo -n dd if=/dev/zero of="${!disk_var}" bs=1M count=10 conv=fsync || true

  echo "Running virt-install for $name..."
  sudo -E virt-install \
    --virt-type kvm \
    --name "$name" \
    --ram 28672 \
    --vcpus 8 \
    --cpuset "$cpuset" \
    --disk path="${!disk_var}",bus=virtio \
    --cdrom "${WORKER_NODE_IMAGE}" \
    --os-variant=linux2024 \
    --network network=talos-nat,mac="${!mac_var}" \
    --network network=lb-net,mac="${!extern_mac_var}" \
    --boot cdrom,hd --noautoconsole
done

echo "Attach extra disks to workers (HDD data disk + NVMe bluestore DB)"
for i in {0..2}; do
  name="worker-${i}"
  storage_disk_var="STORAGE_${i}_DISK"
  bluestore_db_var="WORKER_${i}_BLUESTORE_DB"

  echo "Attaching disks to $name..."
  sudo -n virsh attach-disk "$name" "${!storage_disk_var}" vdb \
    --driver qemu --subdriver raw --sourcetype block \
    --targetbus virtio --cache none --io native --persistent --config
  sudo -n virsh attach-disk "$name" "${!bluestore_db_var}" vdc \
    --driver qemu --subdriver raw --sourcetype block \
    --targetbus virtio --cache none --io native --persistent --config
done

echo "Attaching NVMe fast-tier OSD to worker-0 (vdd)..."
sudo -n virsh attach-disk "worker-0" "${NVME_OSD_DISK}" vdd \
  --driver qemu --subdriver raw --sourcetype block \
  --targetbus virtio --cache none --io native --persistent --config

# Attach the former worker-3 storage to worker-0 as a second OSD pair.
# This reclaims the 1.8TB SATA drive and 70GB NVMe BlueStore DB freed by eliminating worker-3.
STORAGE_3_DISK="/dev/disk/by-id/ata-ST2000DM008-2FR102_ZFL34JEA"
WORKER_3_BLUESTORE_DB="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984-part5"
echo "Attaching former worker-3 SATA HDD to worker-0 (vde)..."
sudo -n virsh attach-disk "worker-0" "${STORAGE_3_DISK}" vde \
  --driver qemu --subdriver raw --sourcetype block \
  --targetbus virtio --cache none --io native --persistent --config
echo "Attaching former worker-3 NVMe BlueStore DB to worker-0 (vdf)..."
sudo -n virsh attach-disk "worker-0" "${WORKER_3_BLUESTORE_DB}" vdf \
  --driver qemu --subdriver raw --sourcetype block \
  --targetbus virtio --cache none --io native --persistent --config

echo "Configuring IO threads for worker VMs (2 per worker: SATA + NVMe)"
# virt-xml --edit --iothreads doesn't work for adding new iothreads to a domain.
# Use dumpxml + sed + define to inject the <iothreads> element, then virt-xml for
# per-disk iothread assignments.
for i in {0..2}; do
  name="worker-${i}"
  tmpxml="/tmp/${name}-iothread.xml"
  echo "Adding iothreads to $name..."

  # Export inactive domain XML and inject <iothreads>2</iothreads> after </vcpu>
  sudo -n virsh dumpxml "$name" --inactive > "$tmpxml"
  if ! grep -q '<iothreads>' "$tmpxml"; then
    sed -i '/<\/vcpu>/a\  <iothreads>2</iothreads>' "$tmpxml"
  fi
  sudo -n virsh define "$tmpxml"
  rm -f "$tmpxml"

  # Assign iothread 1 → vdb (SATA HDD OSD data)
  # Assign iothread 2 → vdc (NVMe BlueStore DB)
  sudo -n virt-xml "$name" --edit target=vdb --disk driver.iothread=1
  sudo -n virt-xml "$name" --edit target=vdc --disk driver.iothread=2
done

echo "Assigning NVMe fast-tier iothread on worker-0 (vdd → iothread 2)..."
sudo -n virt-xml "worker-0" --edit target=vdd --disk driver.iothread=2

echo "Assigning SATA iothread on worker-0 (vde → iothread 1, shares with vdb)..."
sudo -n virt-xml "worker-0" --edit target=vde --disk driver.iothread=1

echo "Assigning NVMe iothread on worker-0 (vdf → iothread 2, shares with vdc)..."
sudo -n virt-xml "worker-0" --edit target=vdf --disk driver.iothread=2

echo "BUILDING INFERENCE NODE (single combined node)"
echo "--- BUILDING VM: inference-0 ---"
sudo -n virsh destroy "inference-0" >/dev/null 2>&1 || true
sudo -n virsh undefine "inference-0" --remove-all-storage >/dev/null 2>&1 || true

echo "Wiping NVMe partition for inference-0..."
sudo -n dd if=/dev/zero of="${INFERENCE_0_DISK}" bs=1M count=10 conv=fsync || true

# NUMA node 0 pinning for inference (GPU V100 is on NUMA 0, PCIe bus 04).
# 14 vCPUs on CPUs 0-13. CPUs 40-41 reserved for host on NUMA 0.
sudo -E virt-install \
  --virt-type kvm \
  --name "inference-0" \
  --ram 65536 \
  --vcpus 14 \
  --cpuset "0-13" \
  --disk path="${INFERENCE_0_DISK}",bus=virtio \
  --cdrom "${INFERENCE_NODE_IMAGE}" \
  --os-variant=linux2024 \
  --network network=talos-nat,mac="${inference_0_mac}" \
  --network network=lb-net,mac="${inference_0_extern_mac}" \
  --boot cdrom,hd --noautoconsole

echo "Attaching model storage disk to inference-0..."
sudo -n virsh attach-disk "inference-0" "${INFERENCE_MODEL_DISK}" vdb \
  --driver qemu --subdriver raw --sourcetype block \
  --targetbus virtio --cache none --io native --persistent --config

echo "waiting for nodes to obtain IPs"
sleep 60
for i in {0..2}; do
  sudo virsh domifaddr "worker-${i}"
done

sudo virsh domifaddr inference-0
