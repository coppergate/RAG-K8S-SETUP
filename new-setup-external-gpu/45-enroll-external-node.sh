#!/bin/bash
set -e

# ==============================================================================
# ENROLL EXTERNAL GPU NODE — new-setup-external-gpu
#
# Full enrollment workflow for the external physical GPU inference node.
# Run this after the cluster is up (control-plane + workers healthy).
#
# Steps performed:
#   1. Verify the cluster is reachable via the VIP (172.20.0.15).
#   2. Verify the inference node is reachable in maintenance mode.
#   3. Apply Talos configuration (calls 40-apply-inference-config.sh).
#   4. Wait for the node to reboot, install, and rejoin.
#   5. Wait for the node to appear in kubectl as Ready.
#   6. Approve any pending kubelet CSRs.
#   7. Print GPU operator install reminder.
#
# Prerequisites:
#   - inference_0_mac set in 05-MAC-addresses.sh
#   - GPU node booted from Talos USB and in maintenance mode
#   - 07-config-vm-net.sh has been run (dnsmasq lease active)
#   - Cluster is healthy (./20-bootstrap-cp.sh and ./35-apply-worker-config.sh done)
#
# IMPORTANT: Run on hierophant.
# ==============================================================================

if [ -z "${SETUP_ROOT}" ]; then
    export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
fi

source "${SETUP_ROOT}/new-setup-external-gpu/config-env.sh"
source "${SETUP_ROOT}/new-setup-external-gpu/config-endpoints.sh"

KUBECTL="/home/k8s/kube/kubectl"
export KUBECONFIG="${KUBE_CONFIG}/kubeconfig"

MAX_RETRIES=40
RETRY_INTERVAL=15

# ---------------------------------------------------------------------------
# Step 1: Verify cluster API is reachable via VIP
# ---------------------------------------------------------------------------
echo "[1/5] Verifying cluster API is reachable at ${CP_VIP}..."
if ! sudo -E ${TALOS_ROOT}/talosctl --talosconfig "${TALOSCONFIG}" \
        health --nodes "${CP_IP_0}" --endpoints "${CP_VIP}" \
        --wait-timeout 60s 2>/dev/null; then
    echo "  Cluster API check timed out — verifying via kubectl instead..."
fi
if ! ${KUBECTL} cluster-info &>/dev/null; then
    echo "ERROR: Cluster is not reachable. Ensure the control-plane is healthy before enrolling." >&2
    exit 1
fi
echo "  [✓] Cluster API reachable."

# ---------------------------------------------------------------------------
# Step 2: Verify inference node is in maintenance mode
# ---------------------------------------------------------------------------
echo "[2/5] Verifying inference node at ${INFERENCE_IP_0} is in maintenance mode..."
for i in $(seq 1 10); do
    if sudo -E ${TALOS_ROOT}/talosctl \
            --talosconfig "${TALOSCONFIG}" \
            get machinestatus \
            --nodes "${INFERENCE_IP_0}" \
            --endpoints "${INFERENCE_IP_0}" \
            --insecure &>/dev/null; then
        echo "  [✓] Inference node is reachable at ${INFERENCE_IP_0}."
        break
    fi
    if [ $i -eq 10 ]; then
        echo "ERROR: Cannot reach inference node at ${INFERENCE_IP_0}." >&2
        echo "  Ensure the node is booted from the Talos USB and has received its DHCP lease." >&2
        echo "  Check dnsmasq log: sudo cat /var/log/dnsmasq-br-app-enrollment.log" >&2
        exit 1
    fi
    echo "  [!] Not yet reachable (attempt $i/10). Retrying in 15s..."
    sleep 15
done

# ---------------------------------------------------------------------------
# Step 3: Apply Talos configuration
# ---------------------------------------------------------------------------
echo "[3/5] Applying Talos configuration to inference node..."
"${SETUP_ROOT}/new-setup-external-gpu/40-apply-inference-config.sh"

# ---------------------------------------------------------------------------
# Step 4: Wait for node to reboot, install, and re-appear in Talos
# ---------------------------------------------------------------------------
echo "[4/5] Waiting for inference node to install Talos and reboot..."
echo "  (This typically takes 3–8 minutes for SSD install)"
sleep 60

for i in $(seq 1 $MAX_RETRIES); do
    echo "  [Talos ready check] Attempt $i of $MAX_RETRIES..."
    if sudo -E ${TALOS_ROOT}/talosctl \
            --talosconfig "${TALOSCONFIG}" \
            get members \
            --nodes "${CP_IP_0}" \
            --endpoints "${CP_VIP}" 2>/dev/null | grep -q "inference-0"; then
        echo "  [✓] inference-0 has joined the cluster."
        break
    fi
    if [ $i -eq $MAX_RETRIES ]; then
        echo "ERROR: inference-0 did not appear in cluster members after $MAX_RETRIES attempts." >&2
        exit 1
    fi
    sleep ${RETRY_INTERVAL}
done

# ---------------------------------------------------------------------------
# Step 5: Wait for node to be Ready in Kubernetes
# ---------------------------------------------------------------------------
echo "[5/5] Waiting for inference-0 to become Ready in Kubernetes..."
for i in $(seq 1 $MAX_RETRIES); do
    STATUS=$(${KUBECTL} get node inference-0 --no-headers 2>/dev/null | awk '{print $2}' || echo "NotFound")
    echo "  [K8s node status] Attempt $i: ${STATUS}"
    if [ "${STATUS}" = "Ready" ]; then
        echo "  [✓] inference-0 is Ready."
        break
    fi
    if [ $i -eq $MAX_RETRIES ]; then
        echo "ERROR: inference-0 did not reach Ready state." >&2
        exit 1
    fi
    sleep ${RETRY_INTERVAL}
done

# Approve any pending CSRs (kubelet server certificates)
echo "Approving pending kubelet CSRs..."
${KUBECTL} get csr --no-headers 2>/dev/null | \
    grep "Pending" | \
    awk '{print $1}' | \
    xargs -r ${KUBECTL} certificate approve

echo ""
echo "======================================================="
echo " External GPU node enrollment complete!"
echo "======================================================="
echo " Node     : inference-0"
echo " IP       : ${INFERENCE_IP_0}"
echo " Network  : lb-net (172.20.x.x) — reachable from hierophant and cluster"
echo ""
echo " Next steps:"
echo "   ./52-install-gpu-operator.sh   — Install NVIDIA GPU Operator"
echo "   ./55-label-gpu-nodes.sh        — Label inference-0 with GPU node role"
echo "======================================================="
