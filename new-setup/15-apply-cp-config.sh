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

echo "Creating minimal registry patch (matching test-build)..."
cat > /tmp/basic-patch.yaml <<EOF
machine:
  registries:
    mirrors:
      "*":
        endpoints:
          - http://${REGISTRY}
EOF

echo "Applying minimal registry patch to controlplane.yaml..."
sudo -E ${TALOS_ROOT}/talosctl machineconfig patch "${TALOS_CONFIG}/controlplane.yaml" --patch @/tmp/basic-patch.yaml -o "${TALOS_CONFIG}/controlplane.yaml.patched"
sudo mv "${TALOS_CONFIG}/controlplane.yaml.patched" "${TALOS_CONFIG}/controlplane.yaml"

echo "Applying the configurations to control plane nodes..."
# Note: In basics mode, we apply the same controlplane.yaml to all, 
# and they will keep their DHCP IPs from talos-nat.
for ip in "${CP_IP_0}" "${CP_IP_1}" "${CP_IP_2}"; do
    if [ -n "$ip" ]; then
        echo "Applying to $ip..."
        sudo -E ${TALOS_ROOT}/talosctl apply-config --insecure --talosconfig "${TALOSCONFIG}" --nodes "$ip" --endpoints "$ip" --file "${TALOS_CONFIG}/controlplane.yaml"
    fi
done

echo ""
echo "=== BASICS CONFIG APPLIED ==="
echo "Monitor installation on control-0 with:"
echo "talosctl --talosconfig ${TALOSCONFIG} logs -n ${CP_IP_0} --endpoints ${CP_IP_0} installer"
echo ""
echo "Once all nodes are 'Ready' or in 'Maintenance' (after install reboot), you can try to bootstrap the first node:"
echo "talosctl --talosconfig ${TALOSCONFIG} bootstrap -n ${CP_IP_0} --endpoints ${CP_IP_0}"
