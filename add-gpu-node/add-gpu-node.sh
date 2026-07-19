#!/bin/bash
# ==============================================================================
# ADD-GPU-NODE.SH
# Add a bare-metal GPU node to an existing Talos cluster.
#
# Pre-requisites:
#   - Node is booted from Talos metal ISO (maintenance mode, reachable via NODE_IP)
#   - Bootstrap registry is running on hierophant (or will be started by this script)
#   - Cluster is healthy (control plane reachable via VIP 10.0.0.15)
#   - worker.yaml has already been generated (by 15-apply-cp-config.sh)
#
# Usage:
#   NODE_IP=<ip> [OPTIONS] ./add-gpu-node.sh [FLAGS]
#
# Required:
#   NODE_IP                  Current IP of the node booted in maintenance mode
#
# Optional env vars:
#   NODE_NAME                Hostname to assign (default: inference-0)
#   NODE_ETH1_IP             Static IP for the br-app/VLAN20 interface (default: 172.20.0.120)
#   NODE_ETH1_PREFIX         Prefix length for eth1 IP (default: 16)
#   NODE_ETH0_IFACE          Cluster-facing interface name (default: eth0)
#   NODE_ETH1_IFACE          App/external interface name (default: eth1)
#   GPU_FACTORY_IMAGE_HASH   Factory image hash for NVIDIA-enabled Talos installer.
#                            Get from: https://factory.talos.dev (select NVIDIA system extension)
#                            Leave unset to skip seeding (assumes image already in registry).
#   GPU_INSTALLER_TAG        Registry tag for the GPU installer (default: siderolabs/installer-inference:v1.12.4)
#
# Flags:
#   --no-gpu                 Skip GPU patches and operator (configure as plain worker)
#   --skip-gpu-operator      Apply GPU patches but skip Helm GPU operator install
# ==============================================================================
set -euo pipefail

if [ -z "${SETUP_ROOT:-}" ]; then
    export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
fi

source "${SETUP_ROOT}/new-setup-single/config-env.sh"
source "${SETUP_ROOT}/new-setup-single/utils.sh"

# --- Argument parsing ---
SKIP_GPU=false
SKIP_GPU_OPERATOR=false
for arg in "$@"; do
    case "$arg" in
        --no-gpu)            SKIP_GPU=true ;;
        --skip-gpu-operator) SKIP_GPU_OPERATOR=true ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

# --- Configuration ---
NODE_IP="${NODE_IP:?NODE_IP must be set to the node IP in Talos maintenance mode}"
NODE_NAME="${NODE_NAME:-inference-0}"
NODE_ETH1_IP="${NODE_ETH1_IP:-172.20.0.120}"
NODE_ETH1_PREFIX="${NODE_ETH1_PREFIX:-16}"
NODE_ETH0_IFACE="${NODE_ETH0_IFACE:-eth0}"
NODE_ETH1_IFACE="${NODE_ETH1_IFACE:-eth1}"

GPU_INSTALLER_TAG="${GPU_INSTALLER_TAG:-siderolabs/installer-inference:v1.12.4}"
GPU_FACTORY_IMAGE_HASH="${GPU_FACTORY_IMAGE_HASH:-}"

# Control plane VIP — used as endpoint for post-install talosctl commands
CP_ENDPOINT="${CP_ENDPOINT:-10.0.0.15}"

KUBECTL="${KUBE_ROOT}/kubectl"
export KUBECONFIG="${KUBE_CONFIG}/kubeconfig"

echo "================================================================"
echo "  Add Physical GPU Node to Cluster"
echo "  NODE_IP:      ${NODE_IP}"
echo "  NODE_NAME:    ${NODE_NAME}"
echo "  ETH1 IP:      ${NODE_ETH1_IP}/${NODE_ETH1_PREFIX}"
echo "  GPU:          $([ "$SKIP_GPU" = "true" ] && echo "disabled (plain worker)" || echo "enabled")"
echo "  GPU Operator: $([ "$SKIP_GPU_OPERATOR" = "true" ] || [ "$SKIP_GPU" = "true" ] && echo "skip" || echo "install")"
echo "================================================================"
echo ""

# --- Validate required binaries ---
if [ ! -x "${KUBECTL}" ]; then
    echo "ERROR: kubectl not found at ${KUBECTL}. Run 03-ensure-kubectl.sh first." >&2
    exit 1
fi
if [ ! -f "${TALOS_CONFIG}/worker.yaml" ]; then
    echo "ERROR: ${TALOS_CONFIG}/worker.yaml not found." >&2
    echo "       The cluster must already be bootstrapped (15-apply-cp-config.sh must have run)." >&2
    exit 1
fi

# ==============================================================================
# STEP 1 — Ensure bootstrap registry is running
# ==============================================================================
echo "[1/7] Verifying bootstrap registry at https://${REGISTRY}/v2/ ..."
if ! curl -sk "https://${REGISTRY}/v2/" > /dev/null 2>&1; then
    echo "  Registry not responding. Starting it..."
    sudo bash "${SETUP_ROOT}/new-setup-no-gpu/08-setup-bootstrap-registry.sh"
else
    echo "  [✓] Registry is up."
fi

# ==============================================================================
# STEP 2 — Seed GPU installer image into the registry
# ==============================================================================
echo ""
echo "[2/7] Seeding GPU installer image..."
if [ "$SKIP_GPU" = "true" ]; then
    echo "  --no-gpu: using standard installer, skipping GPU image seed."
elif [ -n "${GPU_FACTORY_IMAGE_HASH}" ]; then
    GPU_INSTALLER_SRC="factory.talos.dev/metal-installer/${GPU_FACTORY_IMAGE_HASH}:v1.12.4"
    DEST_TAG="${REGISTRY}/${GPU_INSTALLER_TAG}"
    # Check if already present to avoid re-pulling
    if sudo -n podman manifest inspect "${DEST_TAG}" > /dev/null 2>&1 || \
       sudo -n podman image exists "${DEST_TAG}" > /dev/null 2>&1; then
        echo "  [✓] GPU installer already in registry: ${DEST_TAG}"
    else
        echo "  Pulling ${GPU_INSTALLER_SRC} ..."
        sudo -n podman pull "${GPU_INSTALLER_SRC}"
        sudo -n podman tag  "${GPU_INSTALLER_SRC}" "${DEST_TAG}"
        sudo -n podman push --tls-verify=false "${DEST_TAG}"
        echo "  [✓] GPU installer seeded: ${DEST_TAG}"
    fi
else
    echo "  WARN: GPU_FACTORY_IMAGE_HASH not set."
    echo "        Assuming '${REGISTRY}/${GPU_INSTALLER_TAG}' is already in the registry."
    echo "        To seed it, get your NVIDIA-enabled factory image hash from:"
    echo "          https://factory.talos.dev  (add the 'nonfree-kmod-nvidia' extension)"
    echo "        Then re-run with:  GPU_FACTORY_IMAGE_HASH=<hash> ./add-gpu-node.sh"
fi

# ==============================================================================
# STEP 3 — Generate node-specific patch
# ==============================================================================
echo ""
echo "[3/7] Generating node-specific patch..."
PATCH_FILE="${SETUP_ROOT}/configs/patch-${NODE_NAME}-physical.yaml"

if [ "$SKIP_GPU" = "true" ]; then
    INSTALLER_IMAGE="${INSTALLER_IMAGE_BASE}/installer-control-worker:v1.12.4"
else
    INSTALLER_IMAGE="${REGISTRY}/${GPU_INSTALLER_TAG}"
fi

cat > "${PATCH_FILE}" <<EOF
machine:
  network:
    hostname: ${NODE_NAME}
    interfaces:
    - interface: ${NODE_ETH0_IFACE}
      dhcp: true
    - interface: ${NODE_ETH1_IFACE}
      dhcp: false
      addresses:
      - ${NODE_ETH1_IP}/${NODE_ETH1_PREFIX}
  install:
    image: ${INSTALLER_IMAGE}
EOF
echo "  [✓] Patch written: ${PATCH_FILE}"
echo "  Installer: ${INSTALLER_IMAGE}"

# ==============================================================================
# STEP 4 — Apply Talos config to the node (maintenance mode)
# ==============================================================================
echo ""
echo "[4/7] Applying Talos config to ${NODE_IP} ..."
wait_for_talos "${NODE_IP}" 120
preflight_check_version "${NODE_IP}"

sudo -E "${TALOS_ROOT}/talosctl" apply-config \
    --insecure \
    --talosconfig "${TALOSCONFIG}" \
    --nodes    "${NODE_IP}" \
    --endpoints "${NODE_IP}" \
    --file "${TALOS_CONFIG}/worker.yaml" \
    --config-patch "@${PATCH_FILE}"

echo "  [✓] Config applied. Node is installing Talos and will reboot."

# ==============================================================================
# STEP 5 — Wait for the node to appear in Kubernetes
# ==============================================================================
echo ""
echo "[5/7] Waiting for ${NODE_NAME} to join the cluster (up to 10 min)..."
ELAPSED=0
TIMEOUT=600
until ${KUBECTL} get node "${NODE_NAME}" >/dev/null 2>&1 || [ $ELAPSED -ge $TIMEOUT ]; do
    printf "."
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done
echo ""

if ! ${KUBECTL} get node "${NODE_NAME}" >/dev/null 2>&1; then
    echo "  ERROR: Node '${NODE_NAME}' did not appear in cluster after ${TIMEOUT}s." >&2
    echo "  Debug:" >&2
    echo "    talosctl --talosconfig ${TALOSCONFIG} health --nodes <new-node-ip>" >&2
    echo "    talosctl --talosconfig ${TALOSCONFIG} logs --nodes <new-node-ip> installer" >&2
    exit 1
fi
echo "  [✓] Node ${NODE_NAME} joined the cluster."

echo "  Waiting for ${NODE_NAME} to become Ready..."
${KUBECTL} wait node "${NODE_NAME}" --for=condition=Ready --timeout=300s || \
    echo "  WARN: Node not Ready within 300s; proceeding anyway."

# ==============================================================================
# STEP 6 — Apply GPU post-boot patches (NVIDIA kernel modules + containerd runtime)
# ==============================================================================
echo ""
if [ "$SKIP_GPU" = "true" ]; then
    echo "[6/7] Skipping GPU post-boot patches (--no-gpu)."
else
    echo "[6/7] Applying GPU post-boot Talos patches (nvidia modules + containerd config)..."

    # Resolve current in-cluster IP for talosctl (may differ from maintenance mode IP)
    NODE_CURRENT_IP=$(${KUBECTL} get node "${NODE_NAME}" \
        -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
    echo "  Node cluster IP: ${NODE_CURRENT_IP}"

    sudo -E "${TALOS_ROOT}/talosctl" patch machineconfig \
        --nodes    "${NODE_CURRENT_IP}" \
        --endpoints "${CP_ENDPOINT}" \
        --talosconfig "${TALOSCONFIG}" \
        --patch "@${SETUP_ROOT}/configs/post-inference-talos.yaml" \
        --mode=reboot

    echo "  [✓] GPU patch applied — node is rebooting to load NVIDIA modules."

    echo "  Waiting 45s before checking for node return..."
    sleep 45

    wait_for_talos "${NODE_CURRENT_IP}" 240

    echo "  Waiting for ${NODE_NAME} to be Ready after GPU reboot..."
    ${KUBECTL} wait node "${NODE_NAME}" --for=condition=Ready --timeout=300s || \
        echo "  WARN: Node not Ready within 300s; proceeding anyway."

    echo "  [✓] Node is back after GPU patch reboot."
fi

# ==============================================================================
# STEP 7 — Install GPU operator and label the node
# ==============================================================================
echo ""
echo "[7/7] Installing GPU operator and labeling node..."
if [ "$SKIP_GPU" = "true" ] || [ "$SKIP_GPU_OPERATOR" = "true" ]; then
    echo "  Skipping GPU operator install."
else
    echo "  Running 52-install-gpu-operator.sh..."
    bash "${SETUP_ROOT}/new-setup-single/52-install-gpu-operator.sh"
fi

echo "  Running 55-label-gpu-nodes.sh..."
bash "${SETUP_ROOT}/new-setup-single/55-label-gpu-nodes.sh"

# ==============================================================================
# Done
# ==============================================================================
echo ""
echo "================================================================"
echo "  [✓] Physical GPU node '${NODE_NAME}' setup complete."
echo ""
${KUBECTL} get nodes -o wide
echo "================================================================"
