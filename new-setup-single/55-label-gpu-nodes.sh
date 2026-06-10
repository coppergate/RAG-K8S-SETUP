#!/bin/bash
set -euo pipefail

# Ensure SETUP_ROOT is set
if [ -z "${SETUP_ROOT:-}" ]; then
  export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
fi

NEW_SETUP_DIR="${SETUP_ROOT}/new-setup-single"
source "${NEW_SETUP_DIR}/config-env.sh"

# Per environment guidelines, always use these exact paths on hierophant
KUBECTL="/home/k8s/kube/kubectl"
export KUBECONFIG="${KUBE_CONFIG}/kubeconfig"

if [ ! -x "${KUBECTL}" ]; then
  echo "ERROR: kubectl not found at ${KUBECTL}. Run 03-ensure-kubectl.sh first." >&2
  exit 1
fi

echo "[GPU LABEL] Ensuring inference nodes carry gpu and gpu-count labels"

# Configurable defaults (override via env if needed)
GPU_DEFAULT_COUNT="${GPU_DEFAULT_COUNT:-1}"

# Optional per-node override (export before running if needed)
INFERENCE_0_GPU_COUNT="${INFERENCE_0_GPU_COUNT:-}"

node_ready() {
  local node=$1
  local status
  status=$(${KUBECTL} get node "$node" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)
  [ "${status}" = "True" ]
}

wait_for_ready() {
  local node=$1
  local timeout=${2:-300}
  local elapsed=0
  echo -n "[GPU LABEL] Waiting for node $node to be Ready "
  until node_ready "$node" || [ $elapsed -ge $timeout ]; do
    printf "."
    sleep 5
    elapsed=$((elapsed+5))
  done
  echo
  if ! node_ready "$node"; then
    echo "WARNING: Node $node is not Ready after ${timeout}s; proceeding to label anyway." >&2
  fi
}

detect_gpu_count() {
  local node=$1
  # Prefer Kubernetes allocatable value from NVIDIA device plugin if present
  local cnt
  cnt=$(${KUBECTL} get node "$node" -o jsonpath="{.status.allocatable['nvidia.com/gpu']}" 2>/dev/null || true)
  if [ -n "${cnt}" ]; then
    echo "${cnt}"
    return 0
  fi
  # Fallback to per-node override or default
  if [ "$node" = "inference-0" ] && [ -n "${INFERENCE_0_GPU_COUNT}" ]; then
    echo "${INFERENCE_0_GPU_COUNT}"; return 0
  fi
  echo "${GPU_DEFAULT_COUNT}"
}

label_node() {
  local node=$1
  local count=$2
  echo "[GPU LABEL] Labeling $node with gpu=true gpu-count=${count}"
  ${KUBECTL} label node "$node" gpu=true --overwrite
  ${KUBECTL} label node "$node" gpu-count="${count}" --overwrite
}

# Discover inference nodes by name (set by hostname-* configs)
nodes=$(${KUBECTL} get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -E '^inference-[0-9]+$' || true)

if [ -z "${nodes}" ]; then
  echo "WARNING: No inference nodes found (names matching 'inference-<n>'). Nothing to label."
  exit 0
fi

for n in ${nodes}; do
  wait_for_ready "$n" 300
  c=$(detect_gpu_count "$n")
  # Normalize empty to default
  if [ -z "${c}" ]; then c="${GPU_DEFAULT_COUNT}"; fi
  label_node "$n" "$c"
done

echo "[GPU LABEL] Summary:"
${KUBECTL} get nodes -L gpu,gpu-count | (grep inference- || true)

echo "[GPU LABEL] Done."
