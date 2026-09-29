#!/bin/bash
set -e

# Ensure SETUP_ROOT is set
if [ -z "${SETUP_ROOT}" ]; then
    export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
fi

source "${SETUP_ROOT}/new-setup-external-gpu/config-env.sh"
source "${SETUP_ROOT}/new-setup-external-gpu/05-MAC-addresses.sh"
source "${SETUP_ROOT}/new-setup-external-gpu/utils.sh"

CONTROL_NODE_IMAGE="/var/lib/libvirt/images/talos-metal-f1d3-v1.12.4.iso"

echo "[CP ISO] Using ISO at ${CONTROL_NODE_IMAGE}"

# Each control plane node is on a different physical NVMe drive for HA:
#   control-0 → nvme-362996-part1  (shares drive with NVMe OSD, different partition)
#   control-1 → nvme-362830-part1  (shares drive with workers 0+1)
#   control-2 → nvme-362984-part1  (shares drive with workers 2+3)
# Single-drive failure only loses 1 of 3 etcd members — quorum maintained.
# Resources: 4 vCPU, 16GB RAM each.
# NUMA node 0 pinning — same node as SAS HBA and GPU.
# Layout: worker-3 uses CPUs 0-13 (14 vCPU, NUMA 0)
#         control-plane uses CPUs 28-39 (3×4=12 vCPU)
#         CPUs 40-41 reserved for host (2 per NUMA node).
CONTROL_0_DISK="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362996-part1"
CONTROL_1_DISK="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part1"
CONTROL_2_DISK="/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984-part1"

# ── CPU PINNING — DEDICATED PHYSICAL CORES (revised 2026-09-29) ──────────────
#
# Host: 2x Xeon E5-2680 v4, 14 cores/socket, 2 threads/core, 56 CPUs.
# Sibling offset is 28: CPU n and CPU n+28 are the SAME physical core.
#   NUMA 0 = cores 0-13  -> CPUs 0-13  + 28-41
#   NUMA 1 = cores 14-27 -> CPUs 14-27 + 42-55
#
# WHY THIS CHANGED. The control planes were pinned to 28-31 / 32-35 / 36-39,
# which are thread 1 of cores 0-11 -- and worker-3 holds "0-13", thread 0 of
# those same cores. So EVERY ONE of the 12 control-plane vCPUs was a hyperthread
# sibling of a worker-3 vCPU, sharing L1/L2 and execution units.
#
# That is not theoretical. Measured 2026-09-29: worker-3 drawing 6347m (54% of
# it Ceph -- mgr-b 1208m, osd-3 1161m, osd-5 443m), while ALL THREE
# kube-controller-managers and ALL THREE kube-schedulers sat in crash loops of
# ~380-412 restarts each, exiting with:
#
#     E0929 controllermanager.go:368] "leaderelection lost"
#
# This is the etcd-slow-ops -> lease-timeout -> controller-crash-loop path that
# complete-build/documentation/OPERATIONS.md 1.10 predicted.
#
# Now each control plane owns TWO WHOLE CORES (both threads), shared with
# nothing:
#
#   control-0  cores  8,9    CPUs  8,9,36,37
#   control-1  cores 10,11   CPUs 10,11,38,39
#   control-2  cores 12,13   CPUs 12,13,40,41
#   worker-3   cores  0-7    CPUs 0-7,28-35   (see 30-build-all-workers.sh)
#
# Their 4 vCPUs now map 1:1 onto 4 uncontended threads. Measured demand is
# 1388m / 1411m / 2355m, so 2 dedicated cores each is strictly more capacity
# than they were actually getting before.
#
# NUMA 1 IS DELIBERATELY UNTOUCHED. An earlier draft moved all three control
# planes there and cut workers 0-2 to 2 cores apiece. Rejected: Kaniko build
# jobs request cpu 2 / limit cpu 4 and are scheduled onto role=storage-node,
# so that would have throttled the build pipeline. Confining the change to
# NUMA 0 fixes the contention without touching build capacity.
#
# The host loses its NUMA 0 reservation (40,41 -> control-2) but keeps
# 26,27,54,55 on NUMA 1.
#
# RAM is left at 16384. The control planes only use ~2.4 GiB each, so 8192
# would free 24 GiB, but NUMA 0 fits either way (worker-3 64 + CPs 48 = 112 GiB
# against ~125 GiB/socket) and shrinking it is not needed to fix the crash loop.
# ─────────────────────────────────────────────────────────────────────────────

echo "--- BUILDING VM: control-0 ---"
sudo -n virsh destroy control-0 >/dev/null 2>&1 || true
sudo -n virsh undefine control-0 --remove-all-storage >/dev/null 2>&1 || true
echo "Wiping NVMe partition for control-0..."
sudo -n dd if=/dev/zero of="${CONTROL_0_DISK}" bs=1M count=10 conv=fsync || true
sudo -n virt-install \
  --virt-type kvm \
  --name control-0 \
  --ram 16384 \
  --vcpus 4 \
  --cpuset "8,9,36,37" \
  --disk path="${CONTROL_0_DISK}",bus=virtio \
  --cdrom "${CONTROL_NODE_IMAGE}" \
  --os-variant=linux2024 \
  --network network=lan,mac="${control_0_mac}" \
  --boot cdrom,hd --noautoconsole

echo "--- BUILDING VM: control-1 ---"
sudo -n virsh destroy control-1 >/dev/null 2>&1 || true
sudo -n virsh undefine control-1 --remove-all-storage >/dev/null 2>&1 || true
echo "Wiping NVMe partition for control-1..."
sudo -n dd if=/dev/zero of="${CONTROL_1_DISK}" bs=1M count=10 conv=fsync || true
sudo -n virt-install \
  --virt-type kvm \
  --name control-1 \
  --ram 16384 \
  --vcpus 4 \
  --cpuset "10,11,38,39" \
  --disk path="${CONTROL_1_DISK}",bus=virtio \
  --cdrom "${CONTROL_NODE_IMAGE}" \
  --os-variant=linux2024 \
  --network network=lan,mac="${control_1_mac}" \
  --boot cdrom,hd --noautoconsole

echo "--- BUILDING VM: control-2 ---"
sudo -n virsh destroy control-2 >/dev/null 2>&1 || true
sudo -n virsh undefine control-2 --remove-all-storage >/dev/null 2>&1 || true
echo "Wiping NVMe partition for control-2..."
sudo -n dd if=/dev/zero of="${CONTROL_2_DISK}" bs=1M count=10 conv=fsync || true
sudo -n virt-install \
  --virt-type kvm \
  --name control-2 \
  --ram 16384 \
  --vcpus 4 \
  --cpuset "12,13,40,41" \
  --disk path="${CONTROL_2_DISK}",bus=virtio \
  --cdrom "${CONTROL_NODE_IMAGE}" \
  --os-variant=linux2024 \
  --network network=lan,mac="${control_2_mac}" \
  --boot cdrom,hd --noautoconsole

echo ""
echo "Waiting for control plane to obtain IPs (60s)..."
sleep 60
echo "Control Plane IPs:"
sudo virsh domifaddr control-0
sudo virsh domifaddr control-1
sudo virsh domifaddr control-2
