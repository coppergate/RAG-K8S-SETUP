#!/bin/bash
set -e

# Ensure SETUP_ROOT is set
if [ -z "${SETUP_ROOT}" ]; then
    export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
fi

source "${SETUP_ROOT}/new-setup/config-env.sh" 
source "${SETUP_ROOT}/new-setup/config-endpoints.sh"

echo "Applying configuration to inference nodes"

sudo -E ${TALOS_ROOT}/talosctl apply-config --insecure --nodes "${INFERENCE_IP_0}" --endpoints "${INFERENCE_IP_0}" --file ${TALOS_CONFIG}/worker.yaml --config-patch @${SETUP_ROOT}/configs/patch-inference-0.yaml  --talosconfig ${TALOSCONFIG} 
sudo -E ${TALOS_ROOT}/talosctl apply-config --insecure --nodes "${INFERENCE_IP_1}" --endpoints "${INFERENCE_IP_1}" --file ${TALOS_CONFIG}/worker.yaml --config-patch @${SETUP_ROOT}/configs/patch-inference-1.yaml  --talosconfig ${TALOSCONFIG}
