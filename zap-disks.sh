# this will wipe out all of the identifying info on the the listed devices
# these are the 'Rook' raw devices that are used in CEPH
# mounted on the 'host' 'host'
DISKA=(
    "/dev/disk/by-id/ata-ST2000DM008-2FR102_ZFL32CQR" 
    "/dev/disk/by-id/ata-ST2000DM008-2FR102_ZFL32BZX" 
    "/dev/disk/by-id/ata-ST2000DM008-2FR102_ZFL32BA2" 
    "/dev/disk/by-id/ata-ST2000DM008-2FR102_ZFL34JEA"
)

# Also include the OS/Data NVMe partitions for a deep clean if requested
# Note: These are different from the Rook SATA disks above.
VM_NVME=(
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362996-part1"
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362996-part2"
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362935-part1"
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362935-part2"
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part1"
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part2"
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984-part1"
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984-part2"
)

# Combine them for the loop
ALL_DISKS=("${DISKA[@]}" "${VM_NVME[@]}")

for disk in "${ALL_DISKS[@]}";
do
  
	MOUNTED=$(lsblk -nlo MOUNTPOINT "$disk" | grep -v '^$')
	HOLDERS=$(lsblk -nlo TYPE "$disk" | grep -v -E '^(disk|part)$')

	if [ -n "$MOUNTED" ] || [ -n "$HOLDERS" ]; then
		echo "Skipping disk ${disk} - it appears to be in use:"
		[ -n "$MOUNTED" ] && echo "  Mounted at: ${MOUNTED}"
		[ -n "$HOLDERS" ] && echo "  Has active holders of type: ${HOLDERS}"
		continue
	fi

	echo "zapping disk - ${disk}"
	# Zap the disk to a fresh, usable state (zap-all is important, b/c MBR has to be clean)
	parted $disk mklabel gpt

	# Wipe a large portion of the beginning of the disk to remove more LVM metadata that may be present
	dd if=/dev/zero of="$disk" bs=1M count=1000 oflag=direct,dsync

	# SSDs may be better cleaned with blkdiscard instead of dd
	blkdiscard $disk

	# Inform the OS of partition table changes
	partprobe $disk

done



