#!/bin/bash
set -e

# Ensure SETUP_ROOT is set
if [ -z "${SETUP_ROOT}" ]; then
    export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
fi

source "${SETUP_ROOT}/new-setup/config-env.sh" 
source "${SETUP_ROOT}/new-setup/config-endpoints.sh"

echo "Applying configuration to worker nodes (BASICS MODE)"
# In basics mode, we apply the shared worker.yaml which includes registry mirrors.
for ip in "${WORKER_IP_0}" "${WORKER_IP_1}" "${WORKER_IP_2}" "${WORKER_IP_3}"; do
    if [ -n "$ip" ]; then
        echo "Applying to $ip..."
        sudo -E ${TALOS_ROOT}/talosctl apply-config --insecure --talosconfig "${TALOSCONFIG}" --nodes "$ip" --endpoints "$ip" --file "${TALOS_CONFIG}/worker.yaml"
    fi
done
