#!/bin/bash
set -e

# ==============================================================================
# APPLY INFERENCE NODE CONFIG — new-setup-external-gpu
#
# Applies Talos configuration to the external GPU inference node.
# The node is a PHYSICAL MACHINE (not a libvirt VM) on the flat LAN.
#
# Prerequisites:
#   1. GPU node is booted from Talos USB installer and in maintenance mode.
#   2. GPU node received a DHCP lease (192.168.0.x) from the LAN router. The
#      apply targets that maintenance IP; after reboot it comes up static at
#      192.168.5.31. Find the maintenance IP via the console display or the
#      ARP lookup in 45-enroll-external-node.sh (INFERENCE_MAINT_IP).
#   3. The TALOS_CONFIG directory has been populated by 15-apply-cp-config.sh.
#
# The install disk (/dev/sda assumed for SSD) must be confirmed before running.
# See EXTERNAL-NODE-SETUP.md for disk identification steps.
#
# NOTE: 50-inference-gpu-setup.sh (PCI passthrough) does NOT apply here.
#       The GPU is natively attached to the physical node.
#       The GPU Operator is owned by complete-build, not this repo:
#       complete-build/infrastructure/nvidia-operator.sh (Step 1.9 of setup-complete.sh).
# ==============================================================================

if [ -z "${SETUP_ROOT}" ]; then
    export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
fi

source "${SETUP_ROOT}/new-setup-external-gpu/config-env.sh"
source "${SETUP_ROOT}/new-setup-external-gpu/config-endpoints.sh"

PATCH_FILE="${SETUP_ROOT}/new-setup-external-gpu/configs/patch-inference-0.yaml"

if [ ! -f "${PATCH_FILE}" ]; then
    echo "ERROR: Patch file not found: ${PATCH_FILE}" >&2
    exit 1
fi

if [ -z "${INFERENCE_IP_0}" ]; then
    echo "ERROR: INFERENCE_IP_0 is not set. Check config-endpoints.sh." >&2
    exit 1
fi

# The node is in maintenance mode at a temporary router DHCP address
# (192.168.0.x), NOT yet at its final static 192.168.5.31. Apply to the
# maintenance IP; the patch then assigns the static address on reboot.
# INFERENCE_MAINT_IP is normally exported by 45-enroll-external-node.sh
# (ARP-discovered). Falls back to INFERENCE_IP_0 if the two are equal
# (e.g. a router DHCP reservation was set up for the node's MAC).
MAINT_IP="${INFERENCE_MAINT_IP:-${INFERENCE_IP_0}}"

echo "Applying Talos configuration to external GPU inference node..."
echo "  Maintenance IP : ${MAINT_IP}"
echo "  Final IP       : ${INFERENCE_IP_0} (after reboot)"
echo "  Patch file     : $(basename ${PATCH_FILE})"
echo "  Config dir     : ${TALOS_CONFIG}"
echo ""

sudo -E ${TALOS_ROOT}/talosctl apply-config --insecure \
    --talosconfig "${TALOSCONFIG}" \
    --nodes "${MAINT_IP}" \
    --endpoints "${MAINT_IP}" \
    --file "${TALOS_CONFIG}/worker.yaml" \
    --config-patch "@${PATCH_FILE}"

echo ""
echo "=== INFERENCE CONFIG APPLIED ==="
echo "The node will now reboot and install Talos to its SSD."
echo "After reboot it will come up as 'inference-0' at ${INFERENCE_IP_0}."
echo ""
echo "Next steps:"
echo "  1. Wait for the node to join the cluster (check: kubectl get nodes)"
echo "  2. Apply the GPU post-boot patch and reboot (loads the NVIDIA kernel"
echo "     modules — the GPU operator cannot validate without them):"
echo "       talosctl --nodes ${INFERENCE_IP_0} --endpoints ${CP_VIP} \\"
echo "         patch machineconfig --mode=reboot \\"
echo "         --patch @configs/post-inference-talos.yaml"
echo "  3. GPU Operator: owned by complete-build, not this repo. It runs as"
echo "     Step 1.9 of setup-complete.sh, or standalone with:"
echo "       bash complete-build/infrastructure/nvidia-operator.sh"
echo ""
echo "NOTE: 45-enroll-external-node.sh performs steps 1-2 automatically."
echo "      This script is normally invoked by it, not run standalone."
