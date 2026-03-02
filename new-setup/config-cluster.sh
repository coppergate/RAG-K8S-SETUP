#!/bin/bash
# ==============================================================================
# NEW CLUSTER CONFIGURATION ORCHESTRATION
# IMPORTANT: This script MUST be executed on the host machine 'hierophant'.
# This uses a new order of installation as requested.
# ==============================================================================
set -e

export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
NEW_SETUP_DIR="${SETUP_ROOT}/new-setup"

source "${NEW_SETUP_DIR}/config-env.sh" 

echo "Starting NEW cluster installation process..."

echo "[1/9] Formatting disks..."
${NEW_SETUP_DIR}/01-format-disks.sh

echo "[2/9] Setting up network..."
${NEW_SETUP_DIR}/02-setup-network.sh
${NEW_SETUP_DIR}/07-config-vm-net.sh

echo "[3/9] Building Control Plane VMs..."
${NEW_SETUP_DIR}/10-build-control-plane.sh

echo "Waiting for Control Plane VMs to boot into maintenance mode..."
sleep 10

echo "[4/9] Applying Control Plane configuration..."
${NEW_SETUP_DIR}/15-apply-cp-config.sh

echo "Waiting for Control Plane nodes to reboot and apply configuration..."
sleep 120

echo "[5/9] Bootstrapping Control Plane..."
${NEW_SETUP_DIR}/20-bootstrap-cp.sh

echo "Waiting for Control Plane to stabilize after bootstrap..."
sleep 15

echo "[5b/9] Ensuring kubectl matches cluster version..."
${NEW_SETUP_DIR}/03-ensure-kubectl.sh || true

echo "[6/9] Building all Worker and Inference VMs..."
${NEW_SETUP_DIR}/30-build-all-workers.sh

echo "Waiting for Worker/Inference VMs to boot into maintenance mode..."
sleep 20

echo "[7/9] Applying Worker configuration..."
${NEW_SETUP_DIR}/35-apply-worker-config.sh

echo "Waiting for Worker nodes to reboot..."
sleep 120

echo "[8/9] Applying Inference configuration..."
${NEW_SETUP_DIR}/40-apply-inference-config.sh

echo "Waiting for Inference nodes to reboot..."
sleep 120

echo "[9/9] Setting up GPUs and cycling Inference nodes..."
${NEW_SETUP_DIR}/50-inference-gpu-setup.sh

echo "[9a/9] Installing NVIDIA GPU Operator (driver managed by Talos)..."
${NEW_SETUP_DIR}/52-install-gpu-operator.sh || true

echo "[9b/9] Labeling GPU inference nodes (gpu-count)..."
${NEW_SETUP_DIR}/55-label-gpu-nodes.sh || true

echo "==============================================================="
echo "NEW Cluster Installation Complete!"
echo "==============================================================="
