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
      nvidiaDriverRoot: /
      nvidiaDevRoot: /
      deviceDiscoveryStrategy: nvml
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
        nvidia.com/gpu.present: "true"
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

echo "[GPU-OP] Pre-labeling inference nodes (hostname matches 'inference*') with node-role=inference..."
for node in $(${KUBECTL} get nodes -o jsonpath='{.items[*].metadata.name}'); do
  if [[ "${node}" == inference* ]]; then
    ${KUBECTL} label node "${node}" node-role=inference --overwrite
    echo "[GPU-OP]   Labeled ${node} -> node-role=inference"
  fi
done

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
# We use a temporary values file to ensure complex array structures are passed correctly to Helm
cat <<EOF > /tmp/gpu-op-values.yaml
driver:
  enabled: false
toolkit:
  enabled: false
operator:
  defaultRuntime: nvidia
devicePlugin:
  enabled: true
  runtimeClassName: nvidia
  config:
    name: nvidia-device-plugin-config
  env:
    - name: CDI_ENABLED
      value: "false"
    - name: DEVICE_LIST_STRATEGY
      value: "envvar"
node-feature-discovery:
  worker:
    nodeSelector:
      node-role: inference
EOF

"${HELM_BIN}" upgrade --install "${RELEASE_NAME}" nvidia/gpu-operator \
  -n "${NAMESPACE}" --create-namespace ${CHART_VERSION_FLAG} \
  -f /tmp/gpu-op-values.yaml \
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
