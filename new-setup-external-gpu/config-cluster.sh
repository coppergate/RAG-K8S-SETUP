#!/bin/bash
# ==============================================================================
# CLUSTER INSTALLATION ORCHESTRATION — new-setup-external-gpu
#
# Installs a 3-control-plane + 4-worker cluster on hierophant (via libvirt VMs)
# with management on the 172.20.0.0/16 network (lb-net / br-app / eno1 VLAN 20).
#
# The external GPU inference node is NOT part of this automated flow.
# Enroll it separately after the cluster is healthy:
#   ./45-enroll-external-node.sh
#
# Usage:
#   FRESH_INSTALL=true ./config-cluster.sh    # wipe journal and start fresh
#   ./config-cluster.sh                        # resume from last completed step
#
# IMPORTANT: Run on hierophant.
# ==============================================================================
set -e

export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
NEW_SETUP_DIR="${SETUP_ROOT}/new-setup-external-gpu"

source "${SETUP_ROOT}/new-setup-external-gpu/config-env.sh"
source "${NEW_SETUP_DIR}/scripts/journal-helper.sh"

init_journal

echo "Starting new-setup-external-gpu cluster installation..."
echo "  Management network : 172.20.0.0/16 (lb-net / br-app)"
echo "  Control plane VIP  : 172.20.0.15"
echo "  Cluster endpoint   : https://172.20.0.15:6443"
echo ""

# ---------------------------------------------------------------------------
# Step 1: Format disks (hierophant NVMe drives)
# ---------------------------------------------------------------------------
if ! is_step_done "format-disks"; then
    echo "[1/8] Formatting disks..."
    ${NEW_SETUP_DIR}/01-format-disks.sh
    mark_step_done "format-disks"
fi

# ---------------------------------------------------------------------------
# Step 2: Network setup
# ---------------------------------------------------------------------------
if ! is_step_done "setup-network"; then
    echo "[2/8] Setting up network..."
    ${NEW_SETUP_DIR}/00-init-network.sh
    ${NEW_SETUP_DIR}/02-setup-network.sh
    ${NEW_SETUP_DIR}/07-config-vm-net.sh
    mark_step_done "setup-network"
fi

# ---------------------------------------------------------------------------
# Step 2.5: Bootstrap registry
# ---------------------------------------------------------------------------
if ! is_step_done "setup-registry"; then
    echo "[2.5/8] Setting up bootstrap registry..."
    ${NEW_SETUP_DIR}/08-setup-bootstrap-registry.sh
    mark_step_done "setup-registry"
fi

# ---------------------------------------------------------------------------
# Step 3: Build control-plane VMs
# ---------------------------------------------------------------------------
if ! is_step_done "build-cp-vms"; then
    echo "[3/8] Building Control Plane VMs..."
    ${NEW_SETUP_DIR}/10-build-control-plane.sh
    echo "Waiting for Control Plane VMs to boot into maintenance mode..."
    sleep 30
    mark_step_done "build-cp-vms"
fi

# ---------------------------------------------------------------------------
# Step 4: Apply control-plane config (Phase 1: via 10.0.0.x DHCP boot IPs)
# ---------------------------------------------------------------------------
if ! is_step_done "apply-cp-config"; then
    echo "[4/8] Applying Control Plane configuration..."
    echo "  NOTE: Using boot-time 10.0.0.x IPs for initial apply."
    echo "        talosconfig endpoints will be set to 172.20.0.x after this step."
    ${NEW_SETUP_DIR}/15-apply-cp-config.sh
    echo "Waiting for Control Plane nodes to reboot and apply configuration..."
    sleep 120
    mark_step_done "apply-cp-config"
fi

# ---------------------------------------------------------------------------
# Step 5: Bootstrap cluster
# ---------------------------------------------------------------------------
if ! is_step_done "bootstrap-cp"; then
    echo "[5/8] Bootstrapping Control Plane..."
    ${NEW_SETUP_DIR}/20-bootstrap-cp.sh
    echo "Waiting for Control Plane to stabilize after bootstrap..."
    sleep 15
    mark_step_done "bootstrap-cp"
fi

# ---------------------------------------------------------------------------
# Step 5b: Ensure kubectl version matches cluster
# ---------------------------------------------------------------------------
if ! is_step_done "ensure-kubectl"; then
    echo "[5b/8] Ensuring kubectl matches cluster version..."
    ${NEW_SETUP_DIR}/03-ensure-kubectl.sh || true
    mark_step_done "ensure-kubectl"
fi

# ---------------------------------------------------------------------------
# Step 6: Build worker VMs
# ---------------------------------------------------------------------------
if ! is_step_done "build-worker-vms"; then
    echo "[6/8] Building all Worker VMs..."
    ${NEW_SETUP_DIR}/30-build-all-workers.sh
    echo "Waiting for Worker VMs to boot into maintenance mode..."
    sleep 20
    mark_step_done "build-worker-vms"
fi

# ---------------------------------------------------------------------------
# Step 7: Apply worker config (Phase 1: via 10.0.0.x DHCP boot IPs)
# ---------------------------------------------------------------------------
if ! is_step_done "apply-worker-config"; then
    echo "[7/8] Applying Worker configuration..."
    ${NEW_SETUP_DIR}/35-apply-worker-config.sh
    echo "Waiting for Worker nodes to reboot..."
    sleep 120
    mark_step_done "apply-worker-config"
fi

clear_journal

echo "==============================================================="
echo " Cluster Installation Complete!"
echo "==============================================================="
echo " Control plane VIP : 172.20.0.15"
echo " Worker nodes      : 172.20.0.110 — 172.20.0.113"
echo ""
echo " GPU inference node enrollment (run separately after verifying"
echo " cluster health):"
echo "   1. Boot GPU node from Talos USB"
echo "   2. Verify MAC in 05-MAC-addresses.sh (inference_0_mac)"
echo "   3. Run: ${NEW_SETUP_DIR}/45-enroll-external-node.sh"
echo "   4. Run: ${NEW_SETUP_DIR}/52-install-gpu-operator.sh"
echo "   5. Run: ${NEW_SETUP_DIR}/55-label-gpu-nodes.sh"
echo "==============================================================="
