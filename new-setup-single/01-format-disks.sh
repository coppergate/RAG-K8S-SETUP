#!/bin/bash

# Script to format NVMe partitions on 'hierophant' and set specific UUIDs
# to match the requirements of the VM build scripts.

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
# We use stable serial-based IDs to identify the disks, as PCI paths 
# may change and filesystem UUIDs are lost when Talos Linux installs.
declare -A DISK_MAPPING
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362996-part1"]="e50b52ce-1d58-46f0-af4b-f196f17d4392" # worker-0
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362996-part2"]="372dd2ac-5950-439e-861c-2bd679599a9e" # worker-1
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362935-part1"]="eec4057c-4c3c-4a6d-8f32-377bcc1a78f9" # worker-2
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362935-part2"]="9b6d8f8c-a33d-4f71-8062-af449d320557" # worker-3

# Ceph Metadata partitions (Raw partitions, but we list them here to ensure they are wiped)
# We won't apply ext4 to these in the format loop to keep them raw for Ceph if possible, 
# or we just let the loop format them and Ceph will wipe them again.
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362996-part3"]="ce0a0000-0000-0000-0000-000000000000" # worker-0-meta
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362996-part4"]="ce0a0001-0000-0000-0000-000000000000" # worker-1-meta
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362935-part3"]="ce0a0002-0000-0000-0000-000000000000" # worker-2-meta
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362935-part4"]="ce0a0003-0000-0000-0000-000000000000" # worker-3-meta

# Special handling for shared CP/Inference NVMe drives
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part1"]="5b96f19d-4b63-49f9-88bd-2319435281cc" # control-1 (60GB)
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part2"]="bd96c5b2-4854-449b-bd0f-dc7e46c97ef9" # inference-0 (remainder)
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984-part1"]="734bfeb7-bf07-414f-9ecd-8151f8963d66" # control-2 (60GB)
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984-part2"]="af731adb-3f5c-4f5f-8490-1422449de699" # inference-1 (remainder)

echo "=========================================="
echo "NVMe Partition Formatting Script"
echo "=========================================="
echo "This script will partition and format the following devices with specific UUIDs:"

# 3. Partitioning Step for all NVMe drives
echo "Step 3: Checking and creating partitions for all NVMe drives..."

# Partitioning for Worker drives (90GB OS x2, 20GB Meta x2)
WORKER_DRIVES=(
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362996"
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362935"
)

for drive in "${WORKER_DRIVES[@]}"; do
    if [ -b "$drive" ]; then
        echo "  - Partitioning $drive (2x 90GB for Workers, 2x 20GB for Ceph Meta)..."
        sudo wipefs -a "$drive"
        sudo parted -s "$drive" mklabel gpt
        sudo parted -s "$drive" mkpart primary ext4 1MiB 90GiB
        sudo parted -s "$drive" mkpart primary ext4 90GiB 180GiB
        sudo parted -s "$drive" mkpart primary ext4 180GiB 200GiB
        sudo parted -s "$drive" mkpart primary ext4 200GiB 220GiB
        sleep 2
    else
        echo "  - Warning: $drive not found. Skipping partitioning."
    fi
done

# Partitioning for shared CP/Inference drives
SHARED_DRIVES=(
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830"
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984"
)

for drive in "${SHARED_DRIVES[@]}"; do
    if [ -b "$drive" ]; then
        echo "  - Partitioning $drive (60GB for CP, remainder for Inference)..."
        # Wipe existing partition table
        sudo wipefs -a "$drive"
        # Create GPT partition table
        sudo parted -s "$drive" mklabel gpt
        # Create 60GB partition
        sudo parted -s "$drive" mkpart primary ext4 1MiB 60GiB
        # Create remainder partition
        sudo parted -s "$drive" mkpart primary ext4 60GiB 100%
        # Wait for device nodes
        sleep 2
    else
        echo "  - Warning: $drive not found. Skipping partitioning."
    fi
done

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

    echo "Resetting and Formatting $part with UUID $uuid..."
    
    # 1. Wipe all filesystem/partition table signatures from the partition
    echo "  - Wiping signatures..."
    sudo wipefs -a "$part"

    # 2. Re-create the partition to ensure Talos doesn't see old data
    # Note: Since we are dealing with partitions of a physical disk, 
    # we wipe the first 100MB of the partition itself to be sure.
    echo "  - Clearing start of partition..."
    sudo dd if=/dev/zero of="$part" bs=1M count=100 oflag=direct status=none

    # 3. Force format with ext4 and set the specific UUID
    echo "  - Applying ext4 filesystem with UUID $uuid..."
    sudo mkfs.ext4 -F -U "$uuid" "$part"
    echo "✓ Success: $part reset and formatted."
done

echo ""
echo "=========================================="
echo "Final Verification"
echo "=========================================="
lsblk -o NAME,SIZE,TYPE,UUID,PARTUUID,MOUNTPOINT | grep -E "nvme|NAME"
echo "=========================================="
echo "Formatting complete. You can now proceed with building the cluster."
