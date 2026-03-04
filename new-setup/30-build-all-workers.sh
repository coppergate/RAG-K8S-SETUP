#!/bin/bash
set -e

# Ensure SETUP_ROOT is set
if [ -z "${SETUP_ROOT}" ]; then
    export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
fi

source "${SETUP_ROOT}/new-setup/config-env.sh" 
source "${SETUP_ROOT}/new-setup/05-MAC-addresses.sh"
source "${SETUP_ROOT}/new-setup/utils.sh"

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

echo "BUILDING WORKER NODES (BASICS MODE)"
for i in {0..3}; do
  mac_var="data_${i}_mac"
  extern_mac_var="data_${i}_extern_mac"
  name="worker-${i}"
  
  echo "--- BUILDING VM: $name ---"
  # Clean up existing VM and volume if any
  sudo -n virsh destroy "$name" >/dev/null 2>&1 || true
  sudo -n virsh undefine "$name" --remove-all-storage >/dev/null 2>&1 || true
  sudo -n virsh vol-delete --pool CONTROLLER "${name}-disk.qcow2" >/dev/null 2>&1 || true
  
  echo "Creating 60GB disk for $name..."
  sudo -n virsh vol-create-as CONTROLLER "${name}-disk.qcow2" 60G --format qcow2
  
  echo "Running virt-install for $name..."
  sudo -E virt-install \
    --virt-type kvm \
    --name "$name" \
    --ram 32768 \
    --vcpus 5 \
    --disk vol=CONTROLLER/"${name}-disk.qcow2",bus=virtio \
    --cdrom "${WORKER_NODE_IMAGE}" \
    --os-variant=linux2024 \
    --network network=talos-nat,mac="${!mac_var}" \
    --network network=lb-net,mac="${!extern_mac_var}" \
    --boot hd,cdrom --noautoconsole
done

# Note: Extra disks (vdb, vdc) attachment removed for BASICS mode simplicity
# It can be added back once core install is verified.

echo "BUILDING INFERENCE NODES (BASICS MODE)"
# Inference nodes use specialized ISO but same storage pattern
for i in {0..1}; do
  mac_var="inference_${i}_mac"
  extern_mac_var="inference_${i}_extern_mac"
  name="inference-${i}"
  cpuset="0-13,28-41" # Fallback cpuset
  [ "$i" -eq 1 ] && cpuset="14-27,42-55"

  echo "--- BUILDING VM: $name ---"
  sudo -n virsh destroy "$name" >/dev/null 2>&1 || true
  sudo -n virsh undefine "$name" --remove-all-storage >/dev/null 2>&1 || true
  sudo -n virsh vol-delete --pool CONTROLLER "${name}-disk.qcow2" >/dev/null 2>&1 || true
  
  sudo -n virsh vol-create-as CONTROLLER "${name}-disk.qcow2" 60G --format qcow2
  
  sudo -E virt-install \
    --virt-type kvm \
    --name "$name" \
    --ram 32768 \
    --vcpus 9 \
    --cpuset "$cpuset" \
    --disk vol=CONTROLLER/"${name}-disk.qcow2",bus=virtio \
    --cdrom "${INFERENCE_NODE_IMAGE}" \
    --os-variant=linux2024 \
    --network network=talos-nat,mac="${!mac_var}" \
    --network network=lb-net,mac="${!extern_mac_var}" \
    --boot hd,cdrom --noautoconsole
done

echo "waiting for nodes to obtain IPs"
sleep 60
for i in {0..3}; do 
  sudo virsh domifaddr "worker-${i}"; 
done

sudo virsh domifaddr inference-0
sudo virsh domifaddr inference-1
