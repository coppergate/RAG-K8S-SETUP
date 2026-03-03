#!/bin/bash
set -e

# Ensure SETUP_ROOT is set
if [ -z "${SETUP_ROOT}" ]; then
    export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
fi

source "${SETUP_ROOT}/new-setup/config-env.sh" 
source "${SETUP_ROOT}/new-setup/config-endpoints.sh"

echo "generating the configurations"
sudo -E ${TALOS_ROOT}/talosctl gen config local-cluster "https://${CP_IP_0}:6443" \
--install-disk /dev/vda \
--output "${TALOS_CONFIG}" \
--force 

echo "Applying node patches..."
# Use machineconfig patch to apply the node-patches to generated machine configs.
# This avoids issues where gen config tries to apply machine-specific patches to talosconfig.
for f in "${TALOS_CONFIG}/controlplane.yaml" "${TALOS_CONFIG}/worker.yaml"; do
    if [ -f "$f" ]; then
        sudo -E ${TALOS_ROOT}/talosctl machineconfig patch "$f" --patch @"${SETUP_ROOT}/configs/node-patches.yaml" -o "$f.patched"
        sudo mv "$f.patched" "$f"
    fi
done

echo "Removing conflicting HostnameConfig from generated files..."
# Talos v1.12.4 gen config adds a HostnameConfig document that conflicts with node patches.
# We strip it using python3 as it is standard on the host.
for f in "${TALOS_CONFIG}/controlplane.yaml" "${TALOS_CONFIG}/worker.yaml"; do
    if [ -f "$f" ]; then
        sudo python3 -c '
import sys
docs = sys.stdin.read().split("---\n")
filtered = [d for d in docs if "kind: HostnameConfig" not in d]
sys.stdout.write("---\n".join(filtered))
' < "$f" | sudo tee "$f.tmp" > /dev/null && sudo mv "$f.tmp" "$f"
    fi
done

echo "config endpoint"
sudo -E ${TALOS_ROOT}/talosctl config endpoint "${CP_VIP}"

echo "config node"
sudo -E ${TALOS_ROOT}/talosctl config node "${CP_IP_0}"

echo "applying the control configs"
sudo -E ${TALOS_ROOT}/talosctl apply-config --insecure --talosconfig ${TALOSCONFIG} --nodes "${CP_IP_0}" --file "${TALOS_CONFIG}/controlplane.yaml" --config-patch @"${SETUP_ROOT}/configs/patch-control-0.yaml"
sudo -E ${TALOS_ROOT}/talosctl apply-config --insecure --talosconfig ${TALOSCONFIG} --nodes "${CP_IP_1}" --file "${TALOS_CONFIG}/controlplane.yaml" --config-patch @"${SETUP_ROOT}/configs/patch-control-1.yaml"
sudo -E ${TALOS_ROOT}/talosctl apply-config --insecure --talosconfig ${TALOSCONFIG} --nodes "${CP_IP_2}" --file "${TALOS_CONFIG}/controlplane.yaml" --config-patch @"${SETUP_ROOT}/configs/patch-control-2.yaml"
