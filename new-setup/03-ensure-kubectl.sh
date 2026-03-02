#!/bin/bash
# ============================================================================
# Ensure kubectl client matches the cluster's Kubernetes version
# MUST be executed on the host machine 'hierophant'. Non-interactive/idempotent.
# ----------------------------------------------------------------------------
# Behavior:
# - Detect current server version via existing kubectl and the configured kubeconfig
# - If kubectl is missing or version mismatch, download the exact matching version
#   to /home/k8s/kube/kubectl.<version> and atomically update the symlink
# - Paths follow project guidelines
# - Optional override: set KUBECTL_VERSION to pin a specific version (e.g., v1.31.4)
# ============================================================================
set -euo pipefail

# Resolve setup roots (as seen from hierophant)
if [ -z "${SETUP_ROOT:-}" ]; then
  export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
fi
NEW_SETUP_DIR="${SETUP_ROOT}/new-setup"

# Load env for path conventions (does version check for talosctl only)
if [ -f "${NEW_SETUP_DIR}/config-env.sh" ]; then
  # shellcheck disable=SC1090
  source "${NEW_SETUP_DIR}/config-env.sh"
fi

# Path constants per guidelines
KUBE_ROOT="${KUBE_ROOT:-/home/k8s/kube}"
KUBECONFIG_PATH="${KUBE_CONFIG:-/home/k8s/kube/config}/kubeconfig"
mkdir -p "${KUBE_ROOT}"

export KUBECONFIG="${KUBECONFIG_PATH}"

echo "[kubectl-sync] Using kubeconfig: ${KUBECONFIG}"

# Helper: get server Kubernetes version (vX.Y.Z) using any available kubectl
get_server_version() {
  local bin
  local out server

  for bin in "/home/k8s/kube/kubectl" $(command -v kubectl 2>/dev/null || true); do
    [ -x "$bin" ] || continue
    # Try short output first
    out=$("$bin" version --short --kubeconfig "${KUBECONFIG}" 2>/dev/null || true)
    server=$(printf "%s" "$out" | grep -Eo 'Server Version: v[0-9]+\.[0-9]+\.[0-9]+' | awk '{print $3}' | head -n1)
    if [ -n "$server" ]; then
      printf "%s" "$server"
      return 0
    fi
    # Fallback to JSON parse without jq
    out=$("$bin" version -o json --kubeconfig "${KUBECONFIG}" 2>/dev/null || true)
    server=$(printf "%s" "$out" | tr -d '\n' | sed -E 's/.*"serverVersion"\s*:\s*\{[^}]*"gitVersion"\s*:\s*"(v[0-9]+\.[0-9]+\.[0-9]+)".*/\1/' )
    if printf "%s" "$server" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
      printf "%s" "$server"
      return 0
    fi
  done
  return 1
}

# Helper: get current client version from a candidate kubectl
get_client_version() {
  local bin="$1"
  [ -x "$bin" ] || return 1
  "$bin" version --client --short 2>/dev/null | sed -n 's/^Client Version: \(v[0-9]\+\.[0-9]\+\.[0-9]\+\).*$/\1/p'
}

DESIRED_VERSION="${KUBECTL_VERSION:-}"
if [ -z "$DESIRED_VERSION" ]; then
  if server_ver=$(get_server_version); then
    DESIRED_VERSION="$server_ver"
  fi
fi

if ! printf "%s" "$DESIRED_VERSION" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "[kubectl-sync] Unable to determine desired kubectl version."
  echo "[kubectl-sync] You may set KUBECTL_VERSION (e.g., v1.31.4) and rerun. Skipping."
  exit 0
fi

CURRENT_BIN="${KUBE_ROOT}/kubectl"
CURRENT_VERSION=""
if [ -x "$CURRENT_BIN" ]; then
  CURRENT_VERSION=$(get_client_version "$CURRENT_BIN" || true)
fi

if [ "$CURRENT_VERSION" = "$DESIRED_VERSION" ]; then
  echo "[kubectl-sync] kubectl is already ${CURRENT_VERSION}. Nothing to do."
  exit 0
fi

echo "[kubectl-sync] Installing kubectl ${DESIRED_VERSION} (current: ${CURRENT_VERSION:-none})"

TMP_FILE=$(mktemp)
TARGET_FILE="${KUBE_ROOT}/kubectl.${DESIRED_VERSION}"
URL="https://dl.k8s.io/release/${DESIRED_VERSION}/bin/linux/amd64/kubectl"

echo "[kubectl-sync] Downloading: ${URL}"
if ! curl -fL --retry 3 --connect-timeout 10 -o "$TMP_FILE" "$URL"; then
  echo "ERROR: failed to download kubectl ${DESIRED_VERSION} from ${URL}" >&2
  rm -f "$TMP_FILE"
  exit 1
fi

install -m 0755 "$TMP_FILE" "$TARGET_FILE"
rm -f "$TMP_FILE"

# Atomically switch the symlink to new version
ln -sfn "$TARGET_FILE" "$CURRENT_BIN"

echo "[kubectl-sync] Installed at: $TARGET_FILE"
"$CURRENT_BIN" version --client --short || true

exit 0
