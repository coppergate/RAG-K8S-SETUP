#!/bin/bash
set -e

# Ensure SETUP_ROOT is set
if [ -z "${SETUP_ROOT}" ]; then
    export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
fi

source "${SETUP_ROOT}/new-setup/config-env.sh" 
source "${SETUP_ROOT}/new-setup/05-MAC-addresses.sh"
source "${SETUP_ROOT}/new-setup/utils.sh"

# Use the Talos v1.12.4 Factory installer ISO for boot with net.ifnames=0.
# Hash: f1d36a4599ff60d0e94a2a86311470fbc0da2895bef4ba9b2c0288803986a846
CONTROL_NODE_IMAGE_URL="https://factory.talos.dev/image/f1d36a4599ff60d0e94a2a86311470fbc0da2895bef4ba9b2c0288803986a846/v1.12.4/metal-amd64.iso"
CONTROL_NODE_IMAGE="/var/lib/libvirt/images/talos-metal-f1d3-v1.12.4.iso"

echo "[CP ISO] Boot ISO (Talos v1.12.4 Factory): ${CONTROL_NODE_IMAGE_URL}"
echo "[CP ISO] Local path: ${CONTROL_NODE_IMAGE}"

if [ ! -f "${CONTROL_NODE_IMAGE}" ]; then
  echo "[CP ISO] Downloading Talos v1.12.4 boot ISO..."
  tmpfile=$(mktemp)
  if curl -fL "${CONTROL_NODE_IMAGE_URL}" -o "${tmpfile}"; then
    sudo mkdir -p /var/lib/libvirt/images
    sudo install -m 0644 "${tmpfile}" "${CONTROL_NODE_IMAGE}"
    rm -f "${tmpfile}"
  else
    echo "ERROR: Failed to download ${CONTROL_NODE_IMAGE_URL}" >&2
    rm -f "${tmpfile}"
    exit 1
  fi
else
  echo "[CP ISO] Using existing ISO at ${CONTROL_NODE_IMAGE}"
fi

# set up the storage pools
sudo mkdir -p /var/lib/libvirt/storage-pools/CONTROLLER
sudo virsh pool-define-as --name CONTROLLER --target /var/lib/libvirt/storage-pools/CONTROLLER --type dir || true
sudo virsh pool-build CONTROLLER || true
sudo virsh pool-autostart CONTROLLER || true
sudo virsh pool-start CONTROLLER || true

# Disks for control plane (control-0 remains on qcow2, 1 and 2 on NVMe)
CONTROL_1_DISK="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part1"
CONTROL_2_DISK="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984-part1"

# establish control plane nodes
echo "control-0"
sudo virsh vol-create-as CONTROLLER control-0-disk.qcow2 60G --format qcow2 || true
sudo virt-install \
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
  
echo "control-1"
sudo virt-install \
  --virt-type kvm \
  --name control-1 \
  --ram 8192 \
  --vcpus 4 \
  --disk path="${CONTROL_1_DISK}",bus=virtio \
  --cdrom "${CONTROL_NODE_IMAGE}" \
  --network network=talos-nat,mac="${control_1_mac}" \
  --network network=lb-net,mac="${control_1_extern_mac}" \
  --os-variant=linux2024 \
  --boot hd,cdrom --noautoconsole

echo "control-2"
sudo virt-install \
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

echo "waiting for control plane to obtain IPs"
sleep 30
sudo virsh domifaddr control-0
sudo virsh domifaddr control-1
sudo virsh domifaddr control-2
