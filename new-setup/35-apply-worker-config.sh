#!/bin/bash
set -e

# Ensure SETUP_ROOT is set
if [ -z "${SETUP_ROOT}" ]; then
    export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
fi

source "${SETUP_ROOT}/new-setup/config-env.sh" 
source "${SETUP_ROOT}/new-setup/config-endpoints.sh"

echo "Applying configuration to worker nodes"

sudo -E ${TALOS_ROOT}/talosctl apply-config --insecure --talosconfig ${TALOSCONFIG} --nodes "${WORKER_IP_0}" --endpoints "${WORKER_IP_0}" --file "${TALOS_CONFIG}/worker.yaml" --config-patch @"${SETUP_ROOT}/configs/patch-worker-0.yaml" --mode reboot
sudo -E ${TALOS_ROOT}/talosctl apply-config --insecure --talosconfig ${TALOSCONFIG} --nodes "${WORKER_IP_1}" --endpoints "${WORKER_IP_1}" --file "${TALOS_CONFIG}/worker.yaml" --config-patch @"${SETUP_ROOT}/configs/patch-worker-1.yaml" --mode reboot
sudo -E ${TALOS_ROOT}/talosctl apply-config --insecure --talosconfig ${TALOSCONFIG} --nodes "${WORKER_IP_2}" --endpoints "${WORKER_IP_2}" --file "${TALOS_CONFIG}/worker.yaml" --config-patch @"${SETUP_ROOT}/configs/patch-worker-2.yaml" --mode reboot
sudo -E ${TALOS_ROOT}/talosctl apply-config --insecure --talosconfig ${TALOSCONFIG} --nodes "${WORKER_IP_3}" --endpoints "${WORKER_IP_3}" --file "${TALOS_CONFIG}/worker.yaml" --config-patch @"${SETUP_ROOT}/configs/patch-worker-3.yaml" --mode reboot
