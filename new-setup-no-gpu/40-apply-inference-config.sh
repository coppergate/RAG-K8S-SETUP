#!/bin/bash
set -e

# Ensure SETUP_ROOT is set
if [ -z "${SETUP_ROOT}" ]; then
    export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
fi

source "${SETUP_ROOT}/new-setup-single/config-env.sh"
source "${SETUP_ROOT}/new-setup-single/config-endpoints.sh"

# --- Argument parsing ---
SKIP_GPU="${SKIP_GPU:-false}"
for arg in "$@"; do
  case "$arg" in
    --no-gpu) SKIP_GPU=true ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

echo "Applying configuration to single inference node (with node-specific patch)"
if [ -n "${INFERENCE_IP_0}" ]; then
    if [[ "$SKIP_GPU" == "true" ]]; then
        PATCH_FILE="${SETUP_ROOT}/configs/patch-inference-0-no-gpu.yaml"
        echo "  --no-gpu: using standard worker image (no NVIDIA extensions)"
    else
        PATCH_FILE="${SETUP_ROOT}/configs/patch-inference-0.yaml"
    fi
    echo "Applying to ${INFERENCE_IP_0} (patch: $(basename $PATCH_FILE))..."
    sudo -E ${TALOS_ROOT}/talosctl apply-config --insecure --talosconfig "${TALOSCONFIG}" --nodes "${INFERENCE_IP_0}" --endpoints "${INFERENCE_IP_0}" --file "${TALOS_CONFIG}/worker.yaml" --config-patch "@${PATCH_FILE}"
fi
