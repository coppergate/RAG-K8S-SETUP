#!/bin/bash
set -euo pipefail

# Purpose: Install NVIDIA GPU Operator with Talos managing kernel drivers (driver.disabled)
# Requirements (per project guidelines):
# - Run on host 'hierophant'
# - Use kubectl at /home/k8s/kube/kubectl with kubeconfig at /home/k8s/kube/config/kubeconfig
# - Non-interactive, idempotent, safe to re-run

# Configurable via env:
#   GPU_OPERATOR_CHART_VERSION  -> Helm chart version (optional; default latest)
#   HELM_VERSION                -> Helm version to install if helm is missing (default v3.14.4)
#   TIMEOUT_SECS                -> rollout timeout (default 600)

KUBE_ROOT="/home/k8s/kube"
export KUBECONFIG="${KUBE_ROOT}/config/kubeconfig"
KUBECTL="${KUBE_ROOT}/kubectl"

HELM_DIR="${KUBE_ROOT}/helm"
HELM_BIN="${HELM_DIR}/helm"
HELM_VERSION="${HELM_VERSION:-v3.14.4}"
CHART_VERSION_FLAG=""
NAMESPACE="gpu-operator"
RELEASE_NAME="gpu-operator"
TIMEOUT_SECS="${TIMEOUT_SECS:-600}"

if [ -n "${GPU_OPERATOR_CHART_VERSION:-}" ]; then
  CHART_VERSION_FLAG="--version ${GPU_OPERATOR_CHART_VERSION}"
fi

# ---------------------------------------------------------------------------
# Heterogeneous GPU inventory — inference-0 holds THREE GPUs of TWO models:
#
#   idx  UUID                                      model            mem      PCI
#   0    GPU-ce06ba79-6e2e-b16e-e326-3ba4747c6ecb  Tesla V100 32GB  32768MB  05:00.0
#   1    GPU-6a3e90b5-542c-4189-8385-62224608c4fa  Tesla P4          7680MB  81:00.0
#   2    GPU-d5cfa048-3ff2-dcec-f9bc-d0c7797dfbb5  Tesla P4          7680MB  82:00.0
#
# Only the V100 is advertised as nvidia.com/gpu. GPU Feature Discovery assumes a
# homogeneous node: it derives nvidia.com/gpu.product, .memory and .compute.* from
# a single device and applies them node-wide. Advertising all three would label
# the node "Tesla V100 / 32GB / sm_70" while two of the three are actually P4s at
# 8GB / sm_61 — so a pod scheduled by those labels could land on a P4 and fail on
# either memory or CUDA arch.
#
# HOW THIS IS ENFORCED — named resources, matched on product name.
#
# NOTE: NVIDIA_VISIBLE_DEVICES does NOT work for this. The GPU operator runs the
# device plugin and GFD as privileged containers, so /dev/nvidia* is mounted
# wholesale and NVML enumerates every GPU regardless of that variable — it only
# governs what the runtime hook injects into an UNPRIVILEGED container. Setting it
# was tried and had no effect; GFD still reported all three and collapsed the node
# to "Tesla-P4, count=2", hiding the V100. Do not reintroduce it.
#
# What does work is the device plugin's resources.gpus list: each entry maps a
# product-name glob to a resource name, first match wins. The V100 claims
# nvidia.com/gpu; the P4s are split off under their own name so they stay usable
# without ever being mistaken for the V100.
#
#   nvidia.com/gpu       -> 1   (Tesla V100 32GB)
#   nvidia.com/tesla-p4  -> 2   (Tesla P4 8GB)
#
# Product names must match what NVML reports (nvidia-smi --query-gpu=name), not
# GFD's dash-sanitized label form: "Tesla P4", not "Tesla-P4".
#
# To re-derive names/UUIDs after a hardware change (nvidia-smi is not directly
# runnable on Talos, so this goes through a throwaway pod on the node):
#
#   kubectl run gpu-probe --restart=Never --rm -i \
#     --image=hierophant.hierocracy.home:5000/nvcr.io/nvidia/k8s-device-plugin:v0.18.1 \
#     --overrides='{"spec":{"nodeName":"inference-0"}}' \
#     --env=NVIDIA_VISIBLE_DEVICES=all --env=NVIDIA_DRIVER_CAPABILITIES=utility \
#     -- nvidia-smi --query-gpu=index,uuid,name,memory.total,pci.bus_id --format=csv
# ---------------------------------------------------------------------------
V100_PRODUCT_PATTERN="${V100_PRODUCT_PATTERN:-Tesla PG500-216}"
P4_PRODUCT_PATTERN="${P4_PRODUCT_PATTERN:-Tesla P4}"
P4_RESOURCE_NAME="${P4_RESOURCE_NAME:-nvidia.com/tesla-p4}"

# Node-inventory labels. Custom domain prefix so they cannot be confused with,
# or overwritten by, the nvidia.com/* labels GFD manages. GFD cannot describe a
# mixed node coherently — it publishes one product/memory/compute triple for the
# whole node — so these carry the truth instead.
GPU_INVENTORY_LABELS=(
  "hierocracy.home/gpu-advertised=tesla-v100-32gb"
  "hierocracy.home/gpu-advertised-count=1"
  "hierocracy.home/gpu-p4-present=true"
  "hierocracy.home/gpu-p4-count=2"
  "hierocracy.home/gpu-p4-resource=nvidia.com_tesla-p4"
  "hierocracy.home/gpu-total-count=3"
  "hierocracy.home/gpu-heterogeneous=true"
)

echo "[GPU-OP] Ensuring kubectl path and KUBECONFIG..."
if [ ! -x "${KUBECTL}" ]; then
  echo "ERROR: kubectl not found at ${KUBECTL}" >&2
  exit 1
fi
if [ ! -f "${KUBECONFIG}" ]; then
  echo "ERROR: kubeconfig not found at ${KUBECONFIG}" >&2
  exit 1
fi

echo "[GPU-OP] Checking API availability..."
if ! ${KUBECTL} version >/dev/null 2>&1; then
  echo "ERROR: Kubernetes API not reachable with configured KUBECONFIG." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Preflight: ensure the 'role' node labels this chart selects on actually exist.
#
# The values below pin the operator controller and the node-feature-discovery
# master to role=storage-node, and the NFD worker to role=inference-node. If no
# node carries those labels every one of those pods stays Pending and the
# 'helm upgrade --install --wait' below burns TIMEOUT_SECS and then fails.
#
# On a fresh build these come from Talos machine.nodeLabels (configs/patch-
# worker-*.yaml and configs/patch-inference-0.yaml). This block is the safety
# net for clusters built before those patches existed, and is idempotent.
# ---------------------------------------------------------------------------
echo "[GPU-OP] Ensuring 'role' node labels exist (required by the chart's nodeSelectors)..."
label_by_pattern() {
  local pattern=$1
  local label=$2
  local nodes
  nodes="$(${KUBECTL} get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
             | grep -E "${pattern}" || true)"
  if [ -z "${nodes}" ]; then
    echo "  WARN: no nodes matching '${pattern}' — nothing to label ${label}." >&2
    return 0
  fi
  for n in ${nodes}; do
    echo "  - ${n} -> ${label}"
    ${KUBECTL} label node "${n}" "${label}" --overwrite >/dev/null
  done
}
label_by_pattern '^worker-[0-9]+$'    'role=storage-node'
label_by_pattern '^inference-[0-9]+$' 'role=inference-node'

# 'gpu=true' also comes from Talos machine.nodeLabels, but is re-asserted here for
# the same reason: the device plugin, GFD, DCGM exporter and the validation-fix
# DaemonSet all select on it, and a node missing it silently gets no GPU pods.
label_by_pattern '^inference-[0-9]+$' 'gpu=true'

# node-role.kubernetes.io/* CANNOT be set via Talos machine.nodeLabels — the
# NodeRestriction admission plugin rejects kubelet self-assignment of that prefix,
# and because Talos submits nodeLabels as one patch, including it there silently
# discards every other label on the node. Applying it here works because kubectl
# uses admin credentials rather than the kubelet's.
label_by_pattern '^inference-[0-9]+$' 'node-role.kubernetes.io/inference='

# Inventory labels recording what is physically on the node vs what is offered to
# the scheduler. These document the P4s without letting GFD misdescribe the V100.
for lbl in "${GPU_INVENTORY_LABELS[@]}"; do
  label_by_pattern '^inference-[0-9]+$' "${lbl}"
done

if [ -z "$(${KUBECTL} get nodes -l role=storage-node -o name 2>/dev/null)" ]; then
  echo "ERROR: No node carries role=storage-node. The gpu-operator controller and" >&2
  echo "       node-feature-discovery master cannot schedule, and the Helm install" >&2
  echo "       below would hang for ${TIMEOUT_SECS}s and fail." >&2
  exit 1
fi

echo "[GPU-OP] Ensuring namespace '${NAMESPACE}' exists and has Pod Security set to privileged..."
# Create namespace if it doesn't exist
if ! ${KUBECTL} get ns "${NAMESPACE}" >/dev/null 2>&1; then
  ${KUBECTL} create ns "${NAMESPACE}"
fi
# Apply Pod Security Admission labels
${KUBECTL} label ns "${NAMESPACE}" \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged \
  --overwrite

# ---------------------------------------------------------------------------
# RuntimeClass 'nvidia'.
#
# The values below set devicePlugin.runtimeClassName=nvidia, and a pod naming a
# RuntimeClass that does not exist is rejected outright. Normally the operator
# creates this object as part of toolkit installation — but toolkit.enabled=false
# here, because on Talos the container runtime comes from the
# nvidia-container-toolkit system extension instead. Nothing else creates it, so
# it is created explicitly.
#
# The 'nvidia' handler is registered in containerd by that extension.
# post-inference-talos.yaml additionally makes it the node's default runtime.
# ---------------------------------------------------------------------------
echo "[GPU-OP] Ensuring RuntimeClass 'nvidia' exists..."
${KUBECTL} apply -f - <<EOF
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
EOF

# WARNING: do NOT set nvidiaDriverRoot/nvidiaDevRoot here. An earlier version of
# this ConfigMap pinned nvidiaDriverRoot to "/", but the key was never consumed
# (devicePlugin.config.default was missing below, so the operator ignored the whole
# file) and the plugin ran on its default /run/nvidia/driver — which is the layout
# the nvidia-talos-validation-fix DaemonSet builds. Now that the ConfigMap IS
# consumed, reinstating that override would point the plugin at a path that does
# not exist on Talos and break driver validation.
echo "[GPU-OP] Applying Talos-specific ConfigMap for NVIDIA Device Plugin..."
${KUBECTL} apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: nvidia-device-plugin-config
data:
  config.yaml: |
    version: v1
    flags:
      failOnInitError: true
      # 'none' — neither the V100 nor the P4 supports MIG. Leaving this at the
      # chart default of 'single' makes GFD log "Multiple device types detected"
      # on this node and pick one product to describe all three GPUs.
      migStrategy: none
      deviceDiscoveryStrategy: nvml
    resources:
      # First match wins. Patterns are globs over the NVML product name.
      gpus:
      - pattern: "${V100_PRODUCT_PATTERN}"
        name: nvidia.com/gpu
      - pattern: "${P4_PRODUCT_PATTERN}"
        name: ${P4_RESOURCE_NAME}
    sharing:
      timeSlicing: {}
EOF

# NOTE: The 'nvidia-talos-validation-fix' DaemonSet is REQUIRED on Talos Linux.
# Why:
# 1) GPU Operator validators look for readiness files in /run/nvidia/validations.
# 2) Driver validation expects binaries/libs under /run/nvidia/driver (container-style layout).
# 3) On Talos (with system extensions), NVIDIA userspace lives under /usr/local
#    (e.g. /usr/local/bin/nvidia-smi and /usr/local/glibc/usr/lib/libnvidia-ml.so.1).
#
# To avoid validator loops after Talos image upgrades, this DaemonSet continuously:
# - maintains *-ready marker files under /run/nvidia/validations
# - maps Talos host paths into /run/nvidia/driver via symlinks:
#     /run/nvidia/driver/usr/bin   -> /host/usr/local/bin
#     /run/nvidia/driver/usr/lib64 -> /host/usr/local/glibc/usr/lib

echo "[GPU-OP] Applying Talos-specific Validation Fix DaemonSet..."
${KUBECTL} apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvidia-talos-validation-fix
  labels:
    app: nvidia-talos-validation-fix
spec:
  selector:
    matchLabels:
      name: nvidia-talos-validation-fix
  template:
    metadata:
      labels:
        name: nvidia-talos-validation-fix
    spec:
      nodeSelector:
        gpu: "true"
      hostPID: true
      tolerations:
      - operator: Exists
      containers:
      - name: validation-fix
        image: busybox
        command:
        - sh
        - -c
        - |
          while true; do
            mkdir -p /run/nvidia/validations /run/nvidia/driver/usr
            ln -sfn /host/usr/local/bin /run/nvidia/driver/usr/bin
            ln -sfn /host/usr/local/glibc/usr/lib /run/nvidia/driver/usr/lib64
            touch /run/nvidia/validations/driver-ready
            touch /run/nvidia/validations/toolkit-ready
            touch /run/nvidia/validations/cuda-ready
            sleep 30
          done
        volumeMounts:
        - name: run-nvidia
          mountPath: /run/nvidia
        - name: host-root
          mountPath: /host
          readOnly: true
      volumes:
      - name: run-nvidia
        hostPath:
          path: /run/nvidia
          type: DirectoryOrCreate
      - name: host-root
        hostPath:
          path: /
EOF

# If a standalone 'node-feature-discovery' namespace exists, relax PSA there as well (best-effort)
if ${KUBECTL} get ns node-feature-discovery >/dev/null 2>&1; then
  ${KUBECTL} label ns node-feature-discovery \
    pod-security.kubernetes.io/enforce=privileged \
    pod-security.kubernetes.io/enforce-version=latest \
    pod-security.kubernetes.io/audit=privileged \
    pod-security.kubernetes.io/warn=privileged \
    --overwrite || true
fi

echo "[GPU-OP] Ensuring Helm ${HELM_VERSION} is available..."
if [ ! -x "${HELM_BIN}" ]; then
  mkdir -p "${HELM_DIR}"
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' EXIT
  url="https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
  echo "[GPU-OP] Downloading Helm from ${url} ..."
  curl -fL "${url}" -o "${tmpdir}/helm.tgz"
  tar -C "${tmpdir}" -xzf "${tmpdir}/helm.tgz"
  install -m 0755 "${tmpdir}/linux-amd64/helm" "${HELM_BIN}"
  echo "[GPU-OP] Helm installed at ${HELM_BIN}"
else
  echo "[GPU-OP] Using existing Helm at ${HELM_BIN}"
fi

echo "[GPU-OP] Adding/updating NVIDIA Helm repo..."
"${HELM_BIN}" repo add nvidia https://nvidia.github.io/gpu-operator >/dev/null 2>&1 || true
"${HELM_BIN}" repo update >/dev/null 2>&1 || true

echo "[GPU-OP] Removing legacy NVIDIA standalone releases to avoid duplicate DaemonSets (best effort)..."
for legacy_release in nvidia-device-plugin dcgm-exporter; do
  if "${HELM_BIN}" -n "${NAMESPACE}" status "${legacy_release}" >/dev/null 2>&1; then
    "${HELM_BIN}" -n "${NAMESPACE}" uninstall "${legacy_release}" || true
  fi
done

echo "[GPU-OP] Installing/Upgrading GPU Operator (Talos-aware: driver.enabled=false, toolkit.enabled=false)..."
set -x
# Use mktemp so the file is owned by the current user — /tmp/gpu-op-values.yaml can be
# owned by a different user from a prior run and cause "Permission denied" on write.
GPU_OP_VALUES=$(mktemp /tmp/gpu-op-values.XXXXXX.yaml)
trap 'rm -f "$GPU_OP_VALUES"' EXIT
cat <<EOF > "$GPU_OP_VALUES"
driver:
  enabled: false
toolkit:
  enabled: false
operator:
  defaultRuntime: nvidia
  # Run the operator controller on a worker node, not control plane.
  nodeSelector:
    role: storage-node
node-feature-discovery:
  # NFD workers run on EVERY node by default, including all control plane nodes.
  # Restrict to inference nodes only — GPUs will only ever be on inference nodes.
  # 'role=inference-node' comes from Talos machine.nodeLabels in
  # configs/patch-inference-0.yaml, with the preflight block above as a fallback
  # for clusters built before that patch existed.
  worker:
    nodeSelector:
      role: inference-node
  master:
    nodeSelector:
      role: storage-node
devicePlugin:
  enabled: true
  runtimeClassName: nvidia
  nodeSelector:
    gpu: "true"
  config:
    name: nvidia-device-plugin-config
    # REQUIRED. Without 'default' naming the key, the operator ignores the entire
    # ConfigMap and the plugin silently runs on chart defaults — which is what
    # advertised all three GPUs as a single nvidia.com/gpu pool.
    default: config.yaml
  env:
    - name: CDI_ENABLED
      value: "false"
    - name: DEVICE_LIST_STRATEGY
      value: "envvar"
gfd:
  enabled: true
  nodeSelector:
    gpu: "true"
dcgmExporter:
  enabled: true
  nodeSelector:
    gpu: "true"
  # Not restricted, and cannot usefully be: the P4s are unschedulable under
  # nvidia.com/gpu but still driver-managed, so temperature, power and utilization
  # for all three GPUs continue to reach Grafana.
EOF

"${HELM_BIN}" upgrade --install "${RELEASE_NAME}" nvidia/gpu-operator \
  -n "${NAMESPACE}" --create-namespace ${CHART_VERSION_FLAG} \
  -f "$GPU_OP_VALUES" \
  --wait --timeout ${TIMEOUT_SECS}s
set +x

echo "[GPU-OP] Waiting for NVIDIA device plugin DaemonSet to be Ready..."
# Try known DS name first
DS_NAME="nvidia-device-plugin-daemonset"
if ! ${KUBECTL} -n "${NAMESPACE}" get ds "${DS_NAME}" >/dev/null 2>&1; then
  # Discover DS name by label (covers operator variations)
  DS_NAME="$(${KUBECTL} -n "${NAMESPACE}" get ds -l app.kubernetes.io/name=nvidia-device-plugin -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
fi

if [ -n "${DS_NAME}" ]; then
  ${KUBECTL} -n "${NAMESPACE}" rollout status ds/"${DS_NAME}" --timeout=${TIMEOUT_SECS}s || true
else
  echo "[GPU-OP] WARN: Could not determine device plugin DS name; proceeding to node allocatable check." >&2
fi

echo "[GPU-OP] Checking node allocatable for nvidia.com/gpu (expect non-empty on GPU nodes)..."
${KUBECTL} get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' || true

echo "[GPU-OP] GPU Operator installation step completed."
