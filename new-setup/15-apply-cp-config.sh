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
--config-patch @"${SETUP_ROOT}/configs/patchall.yaml" \
--force  \
--registry-mirror "'*'=http://hierophant.hierocracy.home:5000"

echo "config endpoint"
sudo -E ${TALOS_ROOT}/talosctl config endpoint "${CP_VIP}"

echo "config node"
sudo -E ${TALOS_ROOT}/talosctl config node "${CP_IP_0}"

echo "applying the control configs"
sudo -E ${TALOS_ROOT}/talosctl apply-config --insecure --talosconfig ${TALOSCONFIG} --nodes "${CP_IP_0}" --file "${TALOS_CONFIG}/controlplane.yaml" --config-patch @"${SETUP_ROOT}/configs/patch-control-0.yaml"
sudo -E ${TALOS_ROOT}/talosctl apply-config --insecure --talosconfig ${TALOSCONFIG} --nodes "${CP_IP_1}" --file "${TALOS_CONFIG}/controlplane.yaml" --config-patch @"${SETUP_ROOT}/configs/patch-control-1.yaml"
sudo -E ${TALOS_ROOT}/talosctl apply-config --insecure --talosconfig ${TALOSCONFIG} --nodes "${CP_IP_2}" --file "${TALOS_CONFIG}/controlplane.yaml" --config-patch @"${SETUP_ROOT}/configs/patch-control-2.yaml"
