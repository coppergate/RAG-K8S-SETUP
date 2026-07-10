#!/bin/bash
set -e

# ==============================================================================
# APPLY INFERENCE NODE CONFIG — new-setup-external-gpu
#
# Applies Talos configuration to the external GPU inference node.
# The node is a PHYSICAL MACHINE (not a libvirt VM) connected to the
# 172.20.x.x network (lb-net / br-app / eno1 VLAN 20).
#
# Prerequisites:
#   1. GPU node is booted from Talos USB installer and in maintenance mode.
#   2. GPU node received its DHCP lease (172.20.1.120) from the br-app dnsmasq
#      started by 07-config-vm-net.sh.
#      If the MAC was not set, find the node's IP via the console display.
#   3. The TALOS_CONFIG directory has been populated by 15-apply-cp-config.sh.
#
# The install disk (/dev/sda assumed for SSD) must be confirmed before running.
# See EXTERNAL-NODE-SETUP.md for disk identification steps.
#
# NOTE: 50-inference-gpu-setup.sh (PCI passthrough) does NOT apply here.
#       The GPU is natively attached to the physical node.
#       Run 52-install-gpu-operator.sh and 55-label-gpu-nodes.sh after enrollment.
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

echo "Applying Talos configuration to external GPU inference node..."
echo "  Target IP  : ${INFERENCE_IP_0}"
echo "  Patch file : $(basename ${PATCH_FILE})"
echo "  Config dir : ${TALOS_CONFIG}"
echo ""

sudo -E ${TALOS_ROOT}/talosctl apply-config --insecure \
    --talosconfig "${TALOSCONFIG}" \
    --nodes "${INFERENCE_IP_0}" \
    --endpoints "${INFERENCE_IP_0}" \
    --file "${TALOS_CONFIG}/worker.yaml" \
    --config-patch "@${PATCH_FILE}"

echo ""
echo "=== INFERENCE CONFIG APPLIED ==="
echo "The node will now reboot and install Talos to its SSD."
echo "After reboot it will come up as 'inference-0' at ${INFERENCE_IP_0}."
echo ""
echo "Next steps:"
echo "  1. Wait for the node to join the cluster (check: kubectl get nodes)"
echo "  2. Run: ./52-install-gpu-operator.sh"
echo "  3. Run: ./55-label-gpu-nodes.sh"
