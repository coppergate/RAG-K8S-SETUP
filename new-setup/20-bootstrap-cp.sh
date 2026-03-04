#!/bin/bash
set -e

# Ensure SETUP_ROOT is set
if [ -z "${SETUP_ROOT}" ]; then
    export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
fi

source "${SETUP_ROOT}/new-setup/config-env.sh" 
source "${SETUP_ROOT}/new-setup/config-endpoints.sh"
source "${SETUP_ROOT}/new-setup/utils.sh"

echo "BOOTSTRAPPING CLUSTER"
# Wait for the node to be reachable and API to be up (even if in maintenance mode)

MAX_RETRIES=40
RETRY_INTERVAL=15
for i in $(seq 1 $MAX_RETRIES); do
    echo "[Bootstrap] Attempt $i of $MAX_RETRIES..."
    # Capture both stdout and stderr to check for AlreadyExists error
    if BOOTSTRAP_OUT=$(sudo -E ${TALOS_ROOT}/talosctl -n "${CP_IP_0}" bootstrap --endpoints "${CP_IP_0}" --talosconfig "${TALOSCONFIG}" 2>&1); then
        echo "[✓] Bootstrap command accepted."
        break
    else
        if echo "${BOOTSTRAP_OUT}" | grep -q "AlreadyExists"; then
            echo "[✓] Bootstrap already in progress or completed (AlreadyExists)."
            break
        fi
        
        echo "[!] Bootstrap error: ${BOOTSTRAP_OUT}"
        if [ $i -eq $MAX_RETRIES ]; then
            echo "[!] Bootstrap failed after $MAX_RETRIES attempts."
            exit 1
        fi
        echo "[!] Bootstrap attempt failed. Retrying in ${RETRY_INTERVAL}s..."
        sleep ${RETRY_INTERVAL}
    fi
done

echo "waiting for bootstrap to complete..."
sleep 150

echo "checking cluster members"
sudo -E ${TALOS_ROOT}/talosctl -n "${CP_IP_0}" get members --talosconfig "${TALOSCONFIG}"

echo "WRITING kubeconfig"
for i in $(seq 1 $MAX_RETRIES); do
    echo "[Kubeconfig] Attempt $i of $MAX_RETRIES..."
    if sudo -E ${TALOS_ROOT}/talosctl kubeconfig "${KUBE_CONFIG}/kubeconfig" --nodes "${CP_VIP}" --talosconfig "${TALOSCONFIG}" --force; then
        echo "[✓] Kubeconfig written successfully."
        break
    else
        if [ $i -eq $MAX_RETRIES ]; then
            echo "[!] Failed to fetch kubeconfig after $MAX_RETRIES attempts."
            exit 1
        fi
        echo "[!] Kubeconfig fetch failed. Retrying in ${RETRY_INTERVAL}s..."
        sleep ${RETRY_INTERVAL}
    fi
done
export KUBECONFIG="${KUBE_CONFIG}/kubeconfig"
echo "KUBECONFIG: ${KUBECONFIG}"
