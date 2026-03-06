#!/bin/bash
set -e

# Ensure SETUP_ROOT is set
if [ -z "${SETUP_ROOT}" ]; then
    export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
fi

source "${SETUP_ROOT}/new-setup/config-env.sh" 
source "${SETUP_ROOT}/new-setup/config-endpoints.sh"

echo "generating the configurations (BASICS MODE)"
INSTALLER_IMAGE="hierophant.hierocracy.home:5000/siderolabs/installer-control-worker:v1.12.4"
REGISTRY="hierophant.hierocracy.home:5000"

# Clean old configs to ensure fresh start
sudo rm -rf "${TALOS_CONFIG}"
sudo mkdir -p "${TALOS_CONFIG}"

# Generate (using the IP of the first node for the cluster endpoint as a basic fallback)
sudo -E ${TALOS_ROOT}/talosctl gen config local-cluster "https://${CP_IP_0}:6443" \
--install-disk /dev/vda \
--install-image "${INSTALLER_IMAGE}" \
--output "${TALOS_CONFIG}" \
--force 

echo "Updating talosconfig with endpoints and nodes..."
sudo -E ${TALOS_ROOT}/talosctl --talosconfig "${TALOSCONFIG}" config endpoint "${CP_IP_0}" "${CP_IP_1}" "${CP_IP_2}"
sudo -E ${TALOS_ROOT}/talosctl --talosconfig "${TALOSCONFIG}" config node "${CP_IP_0}" "${CP_IP_1}" "${CP_IP_2}"

echo "Applying global patches (machine-patches.yaml and cluster-patches.yaml) to controlplane.yaml and worker.yaml..."
for f in "controlplane.yaml" "worker.yaml"; do
    # Strip any extra documents (like HostnameConfig) that cause validation conflicts with static hostnames
    sudo sed -n '1,/^---$/p' "${TALOS_CONFIG}/$f" | grep -v '^---$' > "/tmp/$f.stripped"
    sudo mv "/tmp/$f.stripped" "${TALOS_CONFIG}/$f"
    
    # Apply global site configurations (NTP, nameservers, VIP, registry mirrors, extra manifests, etc.)
    # machine-patches.yaml: Site-wide machine settings
    # cluster-patches.yaml: Site-wide cluster settings (VIP, manifests)
    sudo -E ${TALOS_ROOT}/talosctl machineconfig patch "${TALOS_CONFIG}/$f" \
        --patch @${SETUP_ROOT}/configs/machine-patches.yaml \
        --patch @${SETUP_ROOT}/configs/cluster-patches.yaml \
        -o "${TALOS_CONFIG}/$f.patched"
    sudo mv "${TALOS_CONFIG}/$f.patched" "${TALOS_CONFIG}/$f"
done

echo "Applying the configurations to control plane nodes..."
# Apply node-specific patches (hostname, VIP, etc.) on top of the generic controlplane.yaml
i=0
for ip in "${CP_IP_0}" "${CP_IP_1}" "${CP_IP_2}"; do
    if [ -n "$ip" ]; then
        echo "Applying to $ip (with node patch configs/patch-control-${i}.yaml)..."
        sudo -E ${TALOS_ROOT}/talosctl apply-config --insecure --talosconfig "${TALOSCONFIG}" --nodes "$ip" --file "${TALOS_CONFIG}/controlplane.yaml" --config-patch "@${SETUP_ROOT}/configs/patch-control-${i}.yaml"
        i=$((i+1))
    fi
done

echo ""
echo "=== BASICS CONFIG APPLIED ==="
echo "Monitor installation on control-0 with:"
echo "talosctl --talosconfig ${TALOSCONFIG} logs -n ${CP_IP_0} --endpoints ${CP_IP_0} installer"
echo ""
echo "Once all nodes are 'Ready' or in 'Maintenance' (after install reboot), you can try to bootstrap the first node:"
echo "talosctl --talosconfig ${TALOSCONFIG} bootstrap -n ${CP_IP_0} --endpoints ${CP_IP_0}"
