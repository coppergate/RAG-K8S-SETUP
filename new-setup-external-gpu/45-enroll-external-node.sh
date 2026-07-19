#!/bin/bash
set -e

# ==============================================================================
# ENROLL EXTERNAL GPU NODE — new-setup-external-gpu
#
# Full enrollment workflow for the external physical GPU inference node.
# Run this after the cluster is up (control-plane + workers healthy).
#
# Steps performed:
#   1. Verify the cluster is reachable via the VIP (192.168.5.10).
#   2. Verify the inference node is reachable in maintenance mode.
#   3. Apply Talos configuration (calls 40-apply-inference-config.sh).
#   4. Wait for the node to reboot, install, and rejoin.
#   5. Wait for the node to appear in kubectl as Ready.
#   6. Approve any pending kubelet CSRs.
#   7. Print GPU operator install reminder.
#
# Prerequisites:
#   - inference_0_mac set in 05-MAC-addresses.sh (or export INFERENCE_MAINT_IP)
#   - GPU node booted from Talos USB and in maintenance mode (DHCP from the LAN
#     router); its maintenance IP is discovered via ARP by this script
#   - Cluster is healthy (./20-bootstrap-cp.sh and ./35-apply-worker-config.sh done)
#
# IMPORTANT: Run on hierophant.
# ==============================================================================

if [ -z "${SETUP_ROOT}" ]; then
    export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
fi

source "${SETUP_ROOT}/new-setup-external-gpu/config-env.sh"
source "${SETUP_ROOT}/new-setup-external-gpu/config-endpoints.sh"
source "${SETUP_ROOT}/new-setup-external-gpu/05-MAC-addresses.sh"
source "${SETUP_ROOT}/new-setup-external-gpu/utils.sh"

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
# Step 2: Discover the GPU node's maintenance IP and verify maintenance mode
# ---------------------------------------------------------------------------
# On the flat LAN the node boots the Talos USB and DHCPs a temporary
# 192.168.0.x lease from the router. Resolve it by MAC (ARP), unless the
# operator provided INFERENCE_MAINT_IP explicitly (e.g. read from the console).
echo "[2/5] Determining inference node maintenance IP..."
if [ -n "${INFERENCE_MAINT_IP}" ]; then
    echo "  Using operator-provided INFERENCE_MAINT_IP=${INFERENCE_MAINT_IP}"
elif [ -n "${inference_0_mac}" ] && [ "${inference_0_mac}" != "00:00:00:00:00:00" ]; then
    echo "  Discovering via ARP for MAC ${inference_0_mac}..."
    INFERENCE_MAINT_IP="$(getIPByMac "${inference_0_mac}")"
    if [ -z "${INFERENCE_MAINT_IP}" ]; then
        prime_arp_cache; sleep 1
        INFERENCE_MAINT_IP="$(getIPByMac "${inference_0_mac}")"
    fi
fi
if [ -z "${INFERENCE_MAINT_IP}" ]; then
    echo "ERROR: Could not determine the GPU node's maintenance IP." >&2
    echo "  Set inference_0_mac in 05-MAC-addresses.sh, or export INFERENCE_MAINT_IP" >&2
    echo "  to the address shown on the node's console, then re-run." >&2
    exit 1
fi
export INFERENCE_MAINT_IP
echo "  Maintenance IP: ${INFERENCE_MAINT_IP} (final static will be ${INFERENCE_IP_0})"

echo "  Verifying node at ${INFERENCE_MAINT_IP} is in maintenance mode..."
for i in $(seq 1 10); do
    if sudo -E ${TALOS_ROOT}/talosctl \
            --talosconfig "${TALOSCONFIG}" \
            get machinestatus \
            --nodes "${INFERENCE_MAINT_IP}" \
            --endpoints "${INFERENCE_MAINT_IP}" \
            --insecure &>/dev/null; then
        echo "  [✓] Inference node is reachable at ${INFERENCE_MAINT_IP}."
        break
    fi
    if [ $i -eq 10 ]; then
        echo "ERROR: Cannot reach inference node at ${INFERENCE_MAINT_IP}." >&2
        echo "  Ensure the node is booted from the Talos USB and has a DHCP lease." >&2
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
echo " Network  : flat LAN (192.168.5.x) — reachable from every host and the cluster"
echo ""
echo " Next steps:"
echo "   ./52-install-gpu-operator.sh   — Install NVIDIA GPU Operator"
echo "   ./55-label-gpu-nodes.sh        — Label inference-0 with GPU node role"
echo "======================================================="
