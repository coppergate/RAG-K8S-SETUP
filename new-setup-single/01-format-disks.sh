#!/bin/bash

# Script to format NVMe partitions on 'hierophant' and set specific UUIDs
# to match the requirements of the VM build scripts.
#
# NVMe Role Assignment (redesigned for dedicated IO isolation):
#   nvme-362996 (233GB) → Control plane only:
#       p1=70GB (control-0 OS), p2=70GB (control-1 OS), p3=70GB (control-2 OS)
#   nvme-362935 (233GB) → Inference only:
#       p1=80GB (inference-0 OS), p2=150GB (inference model storage)
#   nvme-362830 (233GB) → Workers 0+1:
#       p1=30GB (worker-0 OS), p2=70GB (worker-0 bluestore DB),
#       p3=30GB (worker-1 OS), p4=100GB (worker-1 bluestore DB)
#   nvme-362984 (233GB) → Workers 2+3:
#       p1=30GB (worker-2 OS), p2=70GB (worker-2 bluestore DB),
#       p3=30GB (worker-3 OS), p4=100GB (worker-3 bluestore DB)

set -e

# 1. Host verification
echo "Verifying host environment..."
if ! ip link show enp5s0 &>/dev/null || ! ip link show eno1 &>/dev/null; then
    echo "WARNING: This script is intended to run on the target host (hierophant)."
    read -p "Do you want to continue anyway? (yes/no): " host_resp
    if [[ ! "$host_resp" =~ ^[Yy][Ee][Ss]|[Yy]$ ]]; then
        if [ -z "$FRESH_INSTALL" ]; then
            exit 1
        fi
    fi
fi

# 2. Define the mapping of partitions to their intended UUIDs
# UUIDs for OS partitions are used by Talos to identify the boot disk.
# Bluestore DB partitions are left raw (no filesystem); they appear in the
# mapping only to ensure they are wiped/zeroed before use.
declare -A DISK_MAPPING

# --- Control plane nodes (nvme-362996, dedicated) ---
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362996-part1"]="c0000000-0000-0000-0000-000000000000" # control-0 OS (70GB)
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362996-part2"]="c0000001-0000-0000-0000-000000000001" # control-1 OS (70GB)
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362996-part3"]="c0000002-0000-0000-0000-000000000002" # control-2 OS (70GB)

# --- Inference node (nvme-362935, dedicated) ---
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362935-part1"]="bd96c5b2-4854-449b-bd0f-dc7e46c97ef9" # inference-0 OS (80GB)
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362935-part2"]="af731adb-3f5c-4f5f-8490-1422449de699" # inference-0 model storage (150GB)

# --- Workers 0+1 OS partitions (nvme-362830) ---
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part1"]="e50b52ce-1d58-46f0-af4b-f196f17d4392" # worker-0 OS (30GB)
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part3"]="372dd2ac-5950-439e-861c-2bd679599a9e" # worker-1 OS (30GB)

# --- Workers 0+1 Ceph bluestore DB partitions (raw, nvme-362830) ---
# These are wiped but NOT formatted with ext4; Ceph bluestore manages them directly.
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part2"]="ce0a0000-0000-0000-0000-000000000000" # worker-0 bluestore DB (70GB)
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part4"]="ce0a0001-0000-0000-0000-000000000001" # worker-1 bluestore DB (100GB)

# --- Workers 2+3 OS partitions (nvme-362984) ---
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984-part1"]="eec4057c-4c3c-4a6d-8f32-377bcc1a78f9" # worker-2 OS (30GB)
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984-part3"]="9b6d8f8c-a33d-4f71-8062-af449d320557" # worker-3 OS (30GB)

# --- Workers 2+3 Ceph bluestore DB partitions (raw, nvme-362984) ---
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984-part2"]="ce0a0002-0000-0000-0000-000000000002" # worker-2 bluestore DB (70GB)
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984-part4"]="ce0a0003-0000-0000-0000-000000000003" # worker-3 bluestore DB (100GB)

# Set of bluestore DB partitions that must remain raw (wipe only, no ext4)
declare -A BLUESTORE_DB_PARTS
BLUESTORE_DB_PARTS["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part2"]=1
BLUESTORE_DB_PARTS["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part4"]=1
BLUESTORE_DB_PARTS["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984-part2"]=1
BLUESTORE_DB_PARTS["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984-part4"]=1

echo "=========================================="
echo "NVMe Partition Formatting Script"
echo "=========================================="
echo "This script will partition and format the following devices with specific UUIDs:"

# 3. Partitioning Step for all NVMe drives
echo "Step 3: Checking and creating partitions for all NVMe drives..."

# --- Control plane drive: 3x 70GB partitions ---
echo "  - Partitioning nvme-362996 (3x 70GB for control plane nodes)..."
CP_DRIVE="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362996"
if [ -b "$CP_DRIVE" ]; then
    sudo wipefs -a "$CP_DRIVE"
    sudo parted -s "$CP_DRIVE" mklabel gpt
    sudo parted -s "$CP_DRIVE" mkpart primary ext4  1MiB  70GiB
    sudo parted -s "$CP_DRIVE" mkpart primary ext4 70GiB 140GiB
    sudo parted -s "$CP_DRIVE" mkpart primary ext4 140GiB 210GiB
    sleep 2
else
    echo "  - Warning: $CP_DRIVE not found. Skipping."
fi

# --- Inference drive: 80GB OS + 150GB model storage ---
echo "  - Partitioning nvme-362935 (80GB inference OS, 150GB model storage)..."
INF_DRIVE="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362935"
if [ -b "$INF_DRIVE" ]; then
    sudo wipefs -a "$INF_DRIVE"
    sudo parted -s "$INF_DRIVE" mklabel gpt
    sudo parted -s "$INF_DRIVE" mkpart primary ext4  1MiB  80GiB
    sudo parted -s "$INF_DRIVE" mkpart primary ext4 80GiB 230GiB
    sleep 2
else
    echo "  - Warning: $INF_DRIVE not found. Skipping."
fi

# --- Worker 0+1 drive: 30GB OS, 70GB DB, 30GB OS, 100GB DB ---
echo "  - Partitioning nvme-362830 (worker-0/1: 30GB OS, 70GB bluestore DB each)..."
W01_DRIVE="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830"
if [ -b "$W01_DRIVE" ]; then
    sudo wipefs -a "$W01_DRIVE"
    sudo parted -s "$W01_DRIVE" mklabel gpt
    sudo parted -s "$W01_DRIVE" mkpart primary ext4   1MiB  30GiB  # worker-0 OS
    sudo parted -s "$W01_DRIVE" mkpart primary ext4  30GiB 100GiB  # worker-0 bluestore DB
    sudo parted -s "$W01_DRIVE" mkpart primary ext4 100GiB 130GiB  # worker-1 OS
    sudo parted -s "$W01_DRIVE" mkpart primary ext4 130GiB 230GiB  # worker-1 bluestore DB
    sleep 2
else
    echo "  - Warning: $W01_DRIVE not found. Skipping."
fi

# --- Worker 2+3 drive: 30GB OS, 70GB DB, 30GB OS, 100GB DB ---
echo "  - Partitioning nvme-362984 (worker-2/3: 30GB OS, 70GB bluestore DB each)..."
W23_DRIVE="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984"
if [ -b "$W23_DRIVE" ]; then
    sudo wipefs -a "$W23_DRIVE"
    sudo parted -s "$W23_DRIVE" mklabel gpt
    sudo parted -s "$W23_DRIVE" mkpart primary ext4   1MiB  30GiB  # worker-2 OS
    sudo parted -s "$W23_DRIVE" mkpart primary ext4  30GiB 100GiB  # worker-2 bluestore DB
    sudo parted -s "$W23_DRIVE" mkpart primary ext4 100GiB 130GiB  # worker-3 OS
    sudo parted -s "$W23_DRIVE" mkpart primary ext4 130GiB 230GiB  # worker-3 bluestore DB
    sleep 2
else
    echo "  - Warning: $W23_DRIVE not found. Skipping."
fi

echo "=========================================="
echo "Formatting partitions..."
for part in "${!DISK_MAPPING[@]}"; do
    echo "  - $part -> UUID: ${DISK_MAPPING[$part]}"
done
echo "=========================================="
echo "WARNING: ALL DATA ON THESE PARTITIONS WILL BE LOST!"
if [ -z "$FRESH_INSTALL" ]; then
    read -p "Are you sure you want to proceed? (yes/no): " response
else
    response="yes"
fi
echo ""

if [[ ! "$response" =~ ^[Yy][Ee][Ss]|[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# 4. Format and Reset partitions
for part in "${!DISK_MAPPING[@]}"; do
    uuid="${DISK_MAPPING[$part]}"

    # Check if partition exists
    if [ ! -b "$part" ]; then
        echo "Error: Partition $part not found. Skipping."
        continue
    fi

    # Check if mounted
    if mount | grep -q "^$part "; then
        echo "Error: Partition $part is mounted. Skipping."
        continue
    fi

    echo "Resetting $part (UUID $uuid)..."

    echo "  - Wiping signatures..."
    sudo wipefs -a "$part"

    echo "  - Clearing start of partition..."
    sudo dd if=/dev/zero of="$part" bs=1M count=100 oflag=direct status=none

    # Bluestore DB partitions: wipe only, do NOT apply a filesystem.
    # Ceph bluestore manages these raw block devices directly.
    if [[ -n "${BLUESTORE_DB_PARTS[$part]}" ]]; then
        echo "  - Bluestore DB partition: left raw (no filesystem applied)."
        echo "✓ Wiped (raw): $part"
    else
        echo "  - Applying ext4 filesystem with UUID $uuid..."
        sudo mkfs.ext4 -F -U "$uuid" "$part"
        echo "✓ Success: $part formatted."
    fi
done

echo ""
echo "=========================================="
echo "Final Verification"
echo "=========================================="
lsblk -o NAME,SIZE,TYPE,UUID,PARTUUID,MOUNTPOINT | grep -E "nvme|NAME"
echo "=========================================="
echo "Formatting complete. You can now proceed with building the cluster."
