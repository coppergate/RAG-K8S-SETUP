# ==============================================================================
# ENVIRONMENT CONFIGURATION
# IMPORTANT: These scripts MUST be executed on the host machine 'hierophant'.
# This configuration assumes paths and permissions as seen from 'hierophant'.
# ==============================================================================
export CONFIGURATION_ROOT="/home/k8s"
export TALOS_ROOT="${CONFIGURATION_ROOT}/talos"
export KUBE_ROOT="${CONFIGURATION_ROOT}/kube"
export TALOS_CONFIG="${TALOS_ROOT}/config"
export KUBE_CONFIG="${KUBE_ROOT}/config"
export TALOSCONFIG="${TALOS_CONFIG}/talosconfig"
export REGISTRY="hierophant.hierocracy.home:5000"
export INSTALLER_IMAGE_BASE="${REGISTRY}/siderolabs"

#############################################
# Assert talosctl client version is v1.12.4 #
#############################################
TALOSCTL_BIN="${TALOS_ROOT}/talosctl"
REQUIRED_TALOSCTL_VERSION="v1.12.4"

if [ ! -x "${TALOSCTL_BIN}" ]; then
  echo "ERROR: talosctl not found at ${TALOSCTL_BIN}. Please install ${REQUIRED_TALOSCTL_VERSION}." >&2
  exit 1
fi

# Get raw output (short preferred), then extract the first semantic version like v1.12.4
_ver_raw="$(${TALOSCTL_BIN} version --client --short 2>/dev/null || ${TALOSCTL_BIN} version --client 2>/dev/null || true)"
_ver_short="$(printf '%s\n' "${_ver_raw}" | grep -Eo 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
if [ -z "${_ver_short}" ]; then
  _ver_short="unknown"
fi

if [ "${_ver_short}" != "${REQUIRED_TALOSCTL_VERSION}" ]; then
  echo "ERROR: talosctl client version is '${_ver_raw}', but '${REQUIRED_TALOSCTL_VERSION}' is required." >&2
  echo "Path: ${TALOSCTL_BIN}" >&2
  exit 1
fi

echo "*********"
echo " SETUP_ROOT=${SETUP_ROOT}"
echo " CONFIGURATION_ROOT=${CONFIGURATION_ROOT}"
echo " TALOS_ROOT=${TALOS_ROOT}"
echo " KUBE_ROOT=${KUBE_ROOT}"
echo " TALOS_CONFIG=${TALOS_CONFIG}"
echo " KUBE_CONFIG=${KUBE_CONFIG}"
echo " TALOSCONFIG=${TALOSCONFIG}"
echo " talosctl=${TALOSCTL_BIN} (${_ver_short})"
echo "*********"
