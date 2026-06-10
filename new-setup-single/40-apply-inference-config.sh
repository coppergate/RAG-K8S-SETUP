#!/bin/bash
set -e

# Ensure SETUP_ROOT is set
if [ -z "${SETUP_ROOT}" ]; then
    export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
fi

source "${SETUP_ROOT}/new-setup-single/config-env.sh" 
source "${SETUP_ROOT}/new-setup-single/config-endpoints.sh"

echo "Applying configuration to single inference node (with node-specific patch)"
if [ -n "${INFERENCE_IP_0}" ]; then
    echo "Applying to ${INFERENCE_IP_0} (with patch configs/patch-inference-0.yaml)..."
    sudo -E ${TALOS_ROOT}/talosctl apply-config --insecure --talosconfig "${TALOSCONFIG}" --nodes "${INFERENCE_IP_0}" --endpoints "${INFERENCE_IP_0}" --file "${TALOS_CONFIG}/worker.yaml" --config-patch "@${SETUP_ROOT}/configs/patch-inference-0.yaml"
fi
