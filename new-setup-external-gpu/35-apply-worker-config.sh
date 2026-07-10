#!/bin/bash
set -e

# ==============================================================================
# APPLY WORKER CONFIG — new-setup-external-gpu
#
# Uses BOOT_WORKER_IP_* (10.0.0.x talos-nat DHCP) for initial apply-config
# since workers are in maintenance mode at that point.
# After reboot, workers use their static 172.20.0.x IPs (eth1/lb-net).
# ==============================================================================

if [ -z "${SETUP_ROOT}" ]; then
    export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
fi

source "${SETUP_ROOT}/new-setup-external-gpu/config-env.sh"
source "${SETUP_ROOT}/new-setup-external-gpu/config-endpoints.sh"

echo "Applying configuration to worker nodes via boot-time IPs (10.0.0.x)..."
BOOT_WORKER_IPS=("${BOOT_WORKER_IP_0}" "${BOOT_WORKER_IP_1}" "${BOOT_WORKER_IP_2}" "${BOOT_WORKER_IP_3}")
i=0
for ip in "${BOOT_WORKER_IPS[@]}"; do
    if [ -n "$ip" ]; then
        echo "  Applying to ${ip} (patch: configs/patch-worker-${i}.yaml)..."
        sudo -E ${TALOS_ROOT}/talosctl apply-config --insecure \
            --talosconfig "${TALOSCONFIG}" \
            --nodes "$ip" \
            --endpoints "$ip" \
            --file "${TALOS_CONFIG}/worker.yaml" \
            --config-patch "@${SETUP_ROOT}/new-setup-external-gpu/configs/patch-worker-${i}.yaml"
        i=$((i+1))
    fi
done

echo ""
echo "Worker config applied. Nodes will reboot and come up on 172.20.0.110-113 (lb-net)."
