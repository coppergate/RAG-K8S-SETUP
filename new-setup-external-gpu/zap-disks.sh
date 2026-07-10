#!/bin/bash

# Wipe all raw Ceph devices and NVMe VM partitions to a fresh state.
# Run this before re-creating the cluster to ensure clean OSDs.
#
# CEPH HDD disks (vdb on each worker): full zap — wipe, relabel GPT, blkdiscard.
# NVMe VM partitions: wipe signatures + first 1GB only (partitions, not full drives).

set -e

# Ceph HDD data disks — one per worker (workers 0-3)
DISKA=(
    "/dev/disk/by-id/ata-ST2000DM008-2FR102_ZFL32CQR"  # worker-0 vdb
    "/dev/disk/by-id/ata-ST2000DM008-2FR102_ZFL32BZX"  # worker-1 vdb
    "/dev/disk/by-id/ata-ST2000DM008-2FR102_ZFL32BA2"  # worker-2 vdb
    "/dev/disk/by-id/ata-ST2000DM008-2FR102_ZFL34JEA"  # worker-3 vdb
)

# NVMe partitions used by VMs (OS, bluestore DB, NVMe OSD)
# Layout: 1 CP per NVMe drive, workers 0-2 on 362830/362984, worker-3 on 362935.
VM_NVME=(
    # nvme-362996: control-0 OS + NVMe fast OSD (worker-0 vdd)
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362996-part1"
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362996-part2"
    # nvme-362830: control-1 + workers 0+1
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part1"
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part2"
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part3"
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part4"
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part5"
    # nvme-362984: control-2 + worker-2 + worker-3 bluestore DB (p5)
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984-part1"
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984-part2"
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984-part3"
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984-part5"
    # nvme-362935: worker-3 OS + NVMe OSD (vdd)
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362935-part1"
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362935-part2"
)

echo "=========================================="
echo "Zapping Ceph HDD disks (full wipe)..."
echo "=========================================="
for disk in "${DISKA[@]}"; do
    MOUNTED=$(lsblk -nlo MOUNTPOINT "$disk" 2>/dev/null | grep -v '^$' || true)
    HOLDERS=$(lsblk -nlo TYPE "$disk" 2>/dev/null | grep -v -E '^(disk|part)$' || true)

    if [ -n "$MOUNTED" ] || [ -n "$HOLDERS" ]; then
        echo "Skipping $disk — in use:"
        [ -n "$MOUNTED" ] && echo "  Mounted at: ${MOUNTED}"
        [ -n "$HOLDERS" ] && echo "  Has active holders: ${HOLDERS}"
        continue
    fi

    if [ ! -b "$disk" ]; then
        echo "  Not found: $disk — skipping."
        continue
    fi

    echo "Zapping $disk..."
    sudo parted "$disk" mklabel gpt
    sudo dd if=/dev/zero of="$disk" bs=1M count=1000 oflag=direct,dsync
    sudo blkdiscard "$disk" 2>/dev/null || true
    sudo partprobe "$disk"
    echo "  ✓ Zapped: $disk"
done

echo ""
echo "=========================================="
echo "Wiping NVMe VM partitions (signatures + first 1GB)..."
echo "=========================================="
for part in "${VM_NVME[@]}"; do
    MOUNTED=$(lsblk -nlo MOUNTPOINT "$part" 2>/dev/null | grep -v '^$' || true)
    HOLDERS=$(lsblk -nlo TYPE "$part" 2>/dev/null | grep -v -E '^(disk|part)$' || true)

    if [ -n "$MOUNTED" ] || [ -n "$HOLDERS" ]; then
        echo "Skipping $part — in use:"
        [ -n "$MOUNTED" ] && echo "  Mounted at: ${MOUNTED}"
        [ -n "$HOLDERS" ] && echo "  Has active holders: ${HOLDERS}"
        continue
    fi

    if [ ! -b "$part" ]; then
        echo "  Not found: $part — skipping."
        continue
    fi

    echo "Wiping $part..."
    sudo wipefs -a "$part"
    sudo dd if=/dev/zero of="$part" bs=1M count=1000 oflag=direct status=none
    echo "  ✓ Wiped: $part"
done

echo ""
echo "=========================================="
echo "Zap complete. Run 01-format-disks.sh next."
echo "=========================================="
