#!/bin/bash
# ==============================================================================
# NEW CLUSTER CONFIGURATION ORCHESTRATION
# IMPORTANT: This script MUST be executed on the host machine 'hierophant'.
# This uses a new order of installation as requested.
# ==============================================================================
set -e

export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
NEW_SETUP_DIR="${SETUP_ROOT}/new-setup-no-gpu"

source "${SETUP_ROOT}/new-setup-single/config-env.sh"
source "${NEW_SETUP_DIR}/scripts/journal-helper.sh"

init_journal

echo "Starting NEW cluster installation process..."

if ! is_step_done "format-disks"; then
    echo "[1/7] Formatting disks..."
    ${NEW_SETUP_DIR}/01-format-disks.sh
    mark_step_done "format-disks"
fi

if ! is_step_done "setup-network"; then
    echo "[2/7] Setting up network..."
    ${NEW_SETUP_DIR}/00-init-network.sh
    ${NEW_SETUP_DIR}/02-setup-network.sh
    ${NEW_SETUP_DIR}/07-config-vm-net.sh
    mark_step_done "setup-network"
fi

if ! is_step_done "setup-registry"; then
    echo "[2.5/7] Setting up bootstrap registry..."
    ${NEW_SETUP_DIR}/08-setup-bootstrap-registry.sh
    mark_step_done "setup-registry"
fi

if ! is_step_done "build-cp-vms"; then
    echo "[3/7] Building Control Plane VMs..."
    ${NEW_SETUP_DIR}/10-build-control-plane.sh
    echo "Waiting for Control Plane VMs to boot into maintenance mode..."
    sleep 10
    mark_step_done "build-cp-vms"
fi

if ! is_step_done "apply-cp-config"; then
    echo "[4/7] Applying Control Plane configuration..."
    ${NEW_SETUP_DIR}/15-apply-cp-config.sh
    echo "Waiting for Control Plane nodes to reboot and apply configuration..."
    sleep 120
    mark_step_done "apply-cp-config"
fi

if ! is_step_done "bootstrap-cp"; then
    echo "[5/7] Bootstrapping Control Plane..."
    ${NEW_SETUP_DIR}/20-bootstrap-cp.sh
    echo "Waiting for Control Plane to stabilize after bootstrap..."
    sleep 15
    mark_step_done "bootstrap-cp"
fi

if ! is_step_done "ensure-kubectl"; then
    echo "[5b/7] Ensuring kubectl matches cluster version..."
    ${NEW_SETUP_DIR}/03-ensure-kubectl.sh || true
    mark_step_done "ensure-kubectl"
fi

if ! is_step_done "build-worker-vms"; then
    echo "[6/7] Building all Worker VMs..."
    ${NEW_SETUP_DIR}/30-build-all-workers.sh
    echo "Waiting for Worker VMs to boot into maintenance mode..."
    sleep 20
    mark_step_done "build-worker-vms"
fi

if ! is_step_done "apply-worker-config"; then
    echo "[7/7] Applying Worker configuration..."
    ${NEW_SETUP_DIR}/35-apply-worker-config.sh
    echo "Waiting for Worker nodes to reboot..."
    sleep 120
    mark_step_done "apply-worker-config"
fi


clear_journal

echo "==============================================================="
echo "NEW Cluster Installation Complete!"
echo "==============================================================="
