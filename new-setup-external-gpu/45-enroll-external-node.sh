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
#   6. Apply the GPU post-boot patch (NVIDIA kernel modules + containerd
#      runtime) and reboot; wait for the node to come back Ready.
#   7. Approve any pending kubelet CSRs.
#   8. Print GPU operator install reminder.
#
# Step 6 is not optional. The installer-gpu image ships the NVIDIA extensions,
# but kernel modules load only at boot, so they cannot be set in the initial
# apply-config. Skip it and 'ext-nvidia-persistenced' will register as a service
# and hang short of 'up' — nvidia-persistenced cannot open an NVIDIA device with
# no nvidia module loaded — which in turn stalls the GPU operator's driver
# validator and leaves ClusterPolicy not-ready.
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
echo "[1/8] Verifying cluster API is reachable at ${CP_VIP}..."
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
echo "[2/8] Determining inference node maintenance IP..."
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
echo "[3/8] Applying Talos configuration to inference node..."
"${SETUP_ROOT}/new-setup-external-gpu/40-apply-inference-config.sh"

# ---------------------------------------------------------------------------
# Step 4: Wait for node to reboot, install, and re-appear in Talos
# ---------------------------------------------------------------------------
echo "[4/8] Waiting for inference node to install Talos and reboot..."
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
echo "[5/8] Waiting for inference-0 to become Ready in Kubernetes..."
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

# ---------------------------------------------------------------------------
# Step 6: Apply the GPU post-boot patch (NVIDIA kernel modules) and reboot
# ---------------------------------------------------------------------------
# Kernel modules are loaded at boot, so this cannot be folded into the initial
# apply-config in step 3 — the node has to already be running Talos-from-disk.
# --mode=reboot writes the machine config and restarts the node in one shot.
echo "[6/8] Applying GPU post-boot patch (NVIDIA kernel modules + containerd runtime)..."
GPU_PATCH="${SETUP_ROOT}/new-setup-external-gpu/configs/post-inference-talos.yaml"
if [ ! -f "${GPU_PATCH}" ]; then
    echo "ERROR: GPU post-boot patch not found: ${GPU_PATCH}" >&2
    exit 1
fi

if [ "${SKIP_GPU_PATCH:-false}" = "true" ]; then
    echo "  SKIP_GPU_PATCH=true — skipping. NVIDIA modules will NOT be loaded."
else
    sudo -E ${TALOS_ROOT}/talosctl \
        --talosconfig "${TALOSCONFIG}" \
        --nodes "${INFERENCE_IP_0}" \
        --endpoints "${CP_VIP}" \
        patch machineconfig \
        --patch "@${GPU_PATCH}" \
        --mode=reboot

    echo "  [✓] Patch applied — node is rebooting to load the NVIDIA modules."
    echo "  Waiting 45s before probing for the node's return..."
    sleep 45

    wait_for_talos "${INFERENCE_IP_0}" 300

    echo "  Waiting for inference-0 to be Ready again after the GPU reboot..."
    for i in $(seq 1 $MAX_RETRIES); do
        STATUS=$(${KUBECTL} get node inference-0 --no-headers 2>/dev/null | awk '{print $2}' || echo "NotFound")
        echo "  [K8s node status] Attempt $i: ${STATUS}"
        if [ "${STATUS}" = "Ready" ]; then
            echo "  [✓] inference-0 is Ready after the GPU reboot."
            break
        fi
        if [ $i -eq $MAX_RETRIES ]; then
            echo "ERROR: inference-0 did not return to Ready after the GPU patch reboot." >&2
            exit 1
        fi
        sleep ${RETRY_INTERVAL}
    done

    # Verify the modules actually loaded. If this fails, the GPU Operator
    # (complete-build/infrastructure/nvidia-operator.sh) will stall in driver
    # validation, so surface it here rather than 10 minutes later.
    echo "  Verifying NVIDIA kernel modules are loaded..."
    if sudo -E ${TALOS_ROOT}/talosctl \
            --talosconfig "${TALOSCONFIG}" \
            --nodes "${INFERENCE_IP_0}" \
            --endpoints "${CP_VIP}" \
            read /proc/modules 2>/dev/null | grep -q "^nvidia"; then
        echo "  [✓] NVIDIA kernel modules loaded."
    else
        echo "  [!] WARNING: no 'nvidia' entry in /proc/modules." >&2
        echo "      Check that machine.install.image is the installer-gpu image and" >&2
        echo "      that the node actually rebooted:" >&2
        echo "        talosctl --nodes ${INFERENCE_IP_0} --endpoints ${CP_VIP} services" >&2
        echo "        talosctl --nodes ${INFERENCE_IP_0} --endpoints ${CP_VIP} dmesg | grep -i nvidia" >&2
    fi

    # ext-nvidia-persistenced is the extension service that hangs when the
    # modules are missing — report its state explicitly.
    echo "  Extension service state:"
    sudo -E ${TALOS_ROOT}/talosctl \
        --talosconfig "${TALOSCONFIG}" \
        --nodes "${INFERENCE_IP_0}" \
        --endpoints "${CP_VIP}" \
        services 2>/dev/null | grep -i "nvidia" || \
        echo "    (no nvidia extension services reported)"
fi

# ---------------------------------------------------------------------------
# Step 7: Approve any pending CSRs (kubelet server certificates)
# ---------------------------------------------------------------------------
echo "[7/8] Approving pending kubelet CSRs..."
${KUBECTL} get csr --no-headers 2>/dev/null | \
    grep "Pending" | \
    awk '{print $1}' | \
    xargs -r ${KUBECTL} certificate approve

# ---------------------------------------------------------------------------
# Step 8: Summary
# ---------------------------------------------------------------------------
echo ""
echo "[8/8] Enrollment summary"
echo "======================================================="
echo " External GPU node enrollment complete!"
echo "======================================================="
echo " Node     : inference-0"
echo " IP       : ${INFERENCE_IP_0}"
echo " Network  : flat LAN (192.168.5.x) — reachable from every host and the cluster"
echo " GPU patch: $([ "${SKIP_GPU_PATCH:-false}" = "true" ] && echo "SKIPPED (SKIP_GPU_PATCH=true)" || echo "applied + rebooted")"
echo ""
echo " Next steps:"
echo "   The GPU Operator is no longer installed from this repo. It moved to"
echo "   complete-build/infrastructure/nvidia-operator.sh and runs automatically"
echo "   as Step 1.9 of setup-complete.sh (before the RAG stack, because it"
echo "   publishes the gpu=true and hierocracy.home/gpu-*-uuid node labels that"
echo "   Ollama pins against). To run it on its own:"
echo "     bash complete-build/infrastructure/nvidia-operator.sh"
echo "======================================================="
