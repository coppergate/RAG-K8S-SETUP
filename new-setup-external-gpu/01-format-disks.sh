#!/bin/bash

# Script to format NVMe partitions on 'hierophant' and set specific UUIDs
# to match the requirements of the VM build scripts.
#
# NVMe Role Assignment (1 control plane node per NVMe for HA etcd quorum):
#
#   nvme-362996 (233GB):
#       p1 =  30GB  control-0 OS
#       p2 = 195GB  NVMe-only Ceph OSD (fast storage tier → worker-0 vdd)
#
#   nvme-362830 (233GB):
#       p1 =  30GB  control-1 OS
#       p2 =  30GB  worker-0 OS
#       p3 =  70GB  worker-0 bluestore DB (raw)
#       p4 =  30GB  worker-1 OS
#       p5 =  70GB  worker-1 bluestore DB (raw)
#
#   nvme-362984 (233GB):
#       p1 =  30GB  control-2 OS
#       p2 =  30GB  worker-2 OS
#       p3 =  70GB  worker-2 bluestore DB (raw)
#       p4 =  30GB  worker-3 OS
#       p5 =  70GB  worker-3 bluestore DB (raw)
#
#   nvme-362935 (233GB):
#       p1 =  30GB  worker-3 OS
#       p2 = 195GB  NVMe OSD data (fast storage tier → worker-3 vdb)

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

# 2. Define the mapping of partitions to their intended UUIDs.
# OS partitions get ext4 + UUID (used by Talos to identify the boot disk).
# Ceph partitions (bluestore DB and OSD data) are wiped raw — no filesystem.
declare -A DISK_MAPPING

# --- Control plane OS partitions (one per NVMe drive for HA) ---
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362996-part1"]="c0000000-0000-0000-0000-000000000000" # control-0 OS (30GB)
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part1"]="c0000001-0000-0000-0000-000000000001" # control-1 OS (30GB)
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984-part1"]="c0000002-0000-0000-0000-000000000002" # control-2 OS (30GB)

# --- Worker OS partitions ---
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part2"]="e50b52ce-1d58-46f0-af4b-f196f17d4392" # worker-0 OS (30GB)
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part4"]="372dd2ac-5950-439e-861c-2bd679599a9e" # worker-1 OS (30GB)
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984-part2"]="eec4057c-4c3c-4a6d-8f32-377bcc1a78f9" # worker-2 OS (30GB)
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984-part4"]="9b6d8f8c-a33d-4f71-8062-af449d320557" # worker-3 OS (30GB)

# --- Worker-3 OS partition (nvme-362935) ---
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362935-part1"]="d3a72f1e-5c84-4b97-a0e5-2cf1b8354e67" # worker-3 OS (30GB)

# --- Ceph partitions (wipe only, no filesystem) ---
# Worker bluestore DB partitions (NVMe metadata acceleration for HDD OSDs)
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part3"]="ce0a0000-0000-0000-0000-000000000000" # worker-0 bluestore DB (70GB)
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part5"]="ce0a0001-0000-0000-0000-000000000001" # worker-1 bluestore DB (70GB)
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984-part3"]="ce0a0002-0000-0000-0000-000000000002" # worker-2 bluestore DB (70GB)
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984-part5"]="ce0a0003-0000-0000-0000-000000000003" # worker-3 bluestore DB (70GB)
# NVMe-only OSD for fast storage tier (attached to worker-0 as vdd)
DISK_MAPPING["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362996-part2"]="ce0a0004-0000-0000-0000-000000000004" # NVMe OSD data (195GB)

# Set of Ceph-managed partitions: wipe only, do NOT format with ext4.
declare -A CEPH_RAW_PARTS
CEPH_RAW_PARTS["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part3"]=1
CEPH_RAW_PARTS["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part5"]=1
CEPH_RAW_PARTS["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984-part3"]=1
CEPH_RAW_PARTS["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984-part5"]=1
CEPH_RAW_PARTS["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362996-part2"]=1
CEPH_RAW_PARTS["/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362935-part2"]=1

echo "=========================================="
echo "NVMe Partition Formatting Script"
echo "=========================================="
echo "This script will partition and format the following devices with specific UUIDs:"

# 3. Partitioning Step for all NVMe drives
echo "Step 3: Checking and creating partitions for all NVMe drives..."

# nvme-362996: control-0 OS (30GB) + NVMe OSD data (195GB)
echo "  - Partitioning nvme-362996 (30GB ctrl-0 OS + 195GB NVMe OSD)..."
CP0_DRIVE="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362996"
if [ -b "$CP0_DRIVE" ]; then
    sudo wipefs -a "$CP0_DRIVE"
    sudo parted -s "$CP0_DRIVE" mklabel gpt
    sudo parted -s "$CP0_DRIVE" mkpart primary ext4   1MiB  30GiB  # control-0 OS
    sudo parted -s "$CP0_DRIVE" mkpart primary ext4  30GiB 225GiB  # NVMe OSD data (~195GB)
    sleep 2
else
    echo "  - Warning: $CP0_DRIVE not found. Skipping."
fi

# nvme-362830: control-1 OS (30GB) + worker-0/1 OS + bluestore DB
echo "  - Partitioning nvme-362830 (30GB ctrl-1 + w0: 30GB OS / 70GB DB + w1: 30GB OS / 70GB DB)..."
W01_DRIVE="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830"
if [ -b "$W01_DRIVE" ]; then
    sudo wipefs -a "$W01_DRIVE"
    sudo parted -s "$W01_DRIVE" mklabel gpt
    sudo parted -s "$W01_DRIVE" mkpart primary ext4   1MiB  30GiB  # control-1 OS
    sudo parted -s "$W01_DRIVE" mkpart primary ext4  30GiB  60GiB  # worker-0 OS
    sudo parted -s "$W01_DRIVE" mkpart primary ext4  60GiB 130GiB  # worker-0 bluestore DB
    sudo parted -s "$W01_DRIVE" mkpart primary ext4 130GiB 160GiB  # worker-1 OS
    sudo parted -s "$W01_DRIVE" mkpart primary ext4 160GiB 230GiB  # worker-1 bluestore DB
    sleep 2
else
    echo "  - Warning: $W01_DRIVE not found. Skipping."
fi

# nvme-362984: control-2 OS (30GB) + worker-2/3 OS + bluestore DB
echo "  - Partitioning nvme-362984 (30GB ctrl-2 + w2: 30GB OS / 70GB DB + w3: 30GB OS / 70GB DB)..."
W23_DRIVE="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984"
if [ -b "$W23_DRIVE" ]; then
    sudo wipefs -a "$W23_DRIVE"
    sudo parted -s "$W23_DRIVE" mklabel gpt
    sudo parted -s "$W23_DRIVE" mkpart primary ext4   1MiB  30GiB  # control-2 OS
    sudo parted -s "$W23_DRIVE" mkpart primary ext4  30GiB  60GiB  # worker-2 OS
    sudo parted -s "$W23_DRIVE" mkpart primary ext4  60GiB 130GiB  # worker-2 bluestore DB
    sudo parted -s "$W23_DRIVE" mkpart primary ext4 130GiB 160GiB  # worker-3 OS
    sudo parted -s "$W23_DRIVE" mkpart primary ext4 160GiB 230GiB  # worker-3 bluestore DB
    sleep 2
else
    echo "  - Warning: $W23_DRIVE not found. Skipping."
fi

# nvme-362935: worker-3 OS (30GB) + NVMe OSD data (~195GB)
echo "  - Partitioning nvme-362935 (30GB worker-3 OS + ~195GB NVMe OSD)..."
W3_DRIVE="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362935"
if [ -b "$W3_DRIVE" ]; then
    sudo wipefs -a "$W3_DRIVE"
    sudo parted -s "$W3_DRIVE" mklabel gpt
    sudo parted -s "$W3_DRIVE" mkpart primary ext4   1MiB  30GiB  # worker-3 OS
    sudo parted -s "$W3_DRIVE" mkpart primary ext4  30GiB 225GiB  # NVMe OSD data (~195GB)
    sleep 2
else
    echo "  - Warning: $W3_DRIVE not found. Skipping."
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

    if [ ! -b "$part" ]; then
        echo "Error: Partition $part not found. Skipping."
        continue
    fi

    if mount | grep -q "^$part "; then
        echo "Error: Partition $part is mounted. Skipping."
        continue
    fi

    echo "Resetting $part (UUID $uuid)..."

    echo "  - Wiping signatures..."
    sudo wipefs -a "$part"

    echo "  - Clearing start of partition..."
    sudo dd if=/dev/zero of="$part" bs=1M count=100 oflag=direct status=none

    # Ceph-managed partitions: wipe only, no filesystem.
    if [[ -n "${CEPH_RAW_PARTS[$part]}" ]]; then
        echo "  - Ceph raw partition: left raw (no filesystem applied)."
        echo "✓ Wiped (raw): $part"
    else
        echo "  - Applying ext4 filesystem with UUID $uuid..."
        sudo mkfs.ext4 -F -U "$uuid" "$part"
        echo "✓ Formatted: $part"
    fi
done

echo ""
echo "=========================================="
echo "Final Verification"
echo "=========================================="
lsblk -o NAME,SIZE,TYPE,UUID,PARTUUID,MOUNTPOINT | grep -E "nvme|NAME"
echo "=========================================="
echo "Formatting complete. You can now proceed with building the cluster."
