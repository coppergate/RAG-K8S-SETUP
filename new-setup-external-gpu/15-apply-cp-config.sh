#!/bin/bash
set -e

# ==============================================================================
# APPLY CONTROL PLANE CONFIG — new-setup-external-gpu (flat LAN)
#
# TWO-PHASE APPROACH:
#   Phase 1 — Initial apply uses BOOT_IP_* (192.168.0.x, router DHCP in
#              maintenance mode; discovered via ARP by getNodeIP).
#   Phase 2 — talosconfig endpoints are updated to CP_IP_* (192.168.5.x, the
#              permanent static management addresses on the flat LAN).
#
# The cluster endpoint (in cluster-patches.yaml) is https://192.168.5.10:6443
# (the VIP on eth0). This is baked into the generated config.
# ==============================================================================

if [ -z "${SETUP_ROOT}" ]; then
    export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
fi

source "${SETUP_ROOT}/new-setup-external-gpu/config-env.sh"
source "${SETUP_ROOT}/new-setup-external-gpu/config-endpoints.sh"

echo "Generating configurations (BASICS MODE)"
INSTALLER_IMAGE="${INSTALLER_IMAGE_BASE}/installer-control-worker:v1.12.4"

# Clean old configs to ensure fresh start
sudo rm -rf "${TALOS_CONFIG}"
sudo mkdir -p "${TALOS_CONFIG}"

# Generate base config. The URL here is a placeholder — the real cluster endpoint
# (https://192.168.5.10:6443) is set by configs/cluster-patches.yaml below.
sudo -E ${TALOS_ROOT}/talosctl gen config local-cluster "https://${CP_VIP}:6443" \
    --install-disk /dev/vda \
    --install-image "${INSTALLER_IMAGE}" \
    --output "${TALOS_CONFIG}" \
    --force

# Set talosconfig endpoints and nodes to the permanent static IPs (192.168.5.x)
echo "Updating talosconfig with management endpoints (192.168.5.x)..."
sudo -E ${TALOS_ROOT}/talosctl --talosconfig "${TALOSCONFIG}" \
    config endpoint "${CP_IP_0}" "${CP_IP_1}" "${CP_IP_2}"
sudo -E ${TALOS_ROOT}/talosctl --talosconfig "${TALOSCONFIG}" \
    config node "${CP_IP_0}" "${CP_IP_1}" "${CP_IP_2}"

echo "Applying global patches to controlplane.yaml and worker.yaml..."
for f in "controlplane.yaml" "worker.yaml"; do
    # Strip any extra documents (e.g. HostnameConfig) that conflict with static hostnames
    sudo sed -n '1,/^---$/p' "${TALOS_CONFIG}/$f" | grep -v '^---$' > "/tmp/$f.stripped"
    sudo mv "/tmp/$f.stripped" "${TALOS_CONFIG}/$f"

    # Apply global patches:
    #   machine-patches.yaml     — site-wide machine settings (DNS, NTP, kubelet, etc.)
    #   cluster-patches.yaml     — sets cluster endpoint to https://192.168.5.10:6443
    #   talos-registry-patch.yaml — registry mirrors (registry.hierocracy.home:5000)
    sudo -E ${TALOS_ROOT}/talosctl machineconfig patch "${TALOS_CONFIG}/$f" \
        --patch @${SETUP_ROOT}/new-setup-external-gpu/configs/machine-patches.yaml \
        --patch @${SETUP_ROOT}/new-setup-external-gpu/configs/cluster-patches.yaml \
        --patch @${SETUP_ROOT}/new-setup-external-gpu/configs/talos-registry-patch.yaml \
        -o "${TALOS_CONFIG}/$f.patched"
    sudo mv "${TALOS_CONFIG}/$f.patched" "${TALOS_CONFIG}/$f"
done

# ---------------------------------------------------------------------------
# Phase 1: Apply config using BOOT_IPs (192.168.0.x router DHCP, maintenance mode)
# ---------------------------------------------------------------------------
echo "Applying configurations to control-plane nodes via boot-time IPs (192.168.0.x)..."
BOOT_IPS=("${BOOT_IP_0}" "${BOOT_IP_1}" "${BOOT_IP_2}")
i=0
for ip in "${BOOT_IPS[@]}"; do
    if [ -n "$ip" ]; then
        echo "  Applying to ${ip} (patch: configs/patch-control-${i}.yaml)..."
        sudo -E ${TALOS_ROOT}/talosctl apply-config --insecure \
            --talosconfig "${TALOSCONFIG}" \
            --nodes "$ip" \
            --file "${TALOS_CONFIG}/controlplane.yaml" \
            --config-patch "@${SETUP_ROOT}/new-setup-external-gpu/configs/patch-control-${i}.yaml"
        i=$((i+1))
    fi
done

echo ""
echo "=== CONTROL PLANE CONFIG APPLIED ==="
echo "Talosconfig endpoints set to: ${CP_IP_0} ${CP_IP_1} ${CP_IP_2} (192.168.5.x / flat LAN)"
echo "Cluster VIP: ${CP_VIP} (eth0, applied via patch-control-*.yaml)"
echo ""
echo "Monitor installation on control-0 with:"
echo "  talosctl --talosconfig ${TALOSCONFIG} logs -n ${CP_IP_0} --endpoints ${CP_IP_0} installer"
echo ""
echo "After nodes reboot and apply config, bootstrap the cluster:"
echo "  ./20-bootstrap-cp.sh"
