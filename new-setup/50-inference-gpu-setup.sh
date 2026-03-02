#!/bin/bash
set -e

# Ensure SETUP_ROOT is set
if [ -z "${SETUP_ROOT}" ]; then
    export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
fi

source "${SETUP_ROOT}/new-setup/config-env.sh" 
source "${SETUP_ROOT}/new-setup/config-endpoints.sh"

echo "attaching GPU devices"
sudo virsh nodedev-detach pci_0000_04_00_0 || true
sudo virsh attach-device --domain inference-0 --file ${SETUP_ROOT}/configs/nvidia-host-dev-patch-1.xml --persistent --config --live

sudo virsh nodedev-detach pci_0000_84_00_0 || true
sudo virsh attach-device --domain inference-1 --file ${SETUP_ROOT}/configs/nvidia-host-dev-patch-2.xml --persistent --config --live

echo "waiting for devices..."
sleep 30


echo "applying post setup inference patch"
sudo -E ${TALOS_ROOT}/talosctl patch machineconfig --nodes ${INFERENCE_IP_0} --endpoints ${CP_IP_0} --patch @${SETUP_ROOT}/configs/post-inference-talos.yaml --mode=reboot --talosconfig ${TALOSCONFIG}
sudo -E ${TALOS_ROOT}/talosctl patch machineconfig --nodes ${INFERENCE_IP_1} --endpoints ${CP_IP_0} --patch @${SETUP_ROOT}/configs/post-inference-talos.yaml --mode=reboot --talosconfig ${TALOSCONFIG}

echo "waiting for patch and reboot..."
sleep 45

echo "rebooting inference nodes (shutdown then start)"
sudo -E virsh shutdown inference-0 || true
sudo -E virsh shutdown inference-1 || true

echo "waiting for inference nodes to shut down"
while sudo virsh list --all | grep -E 'inference-0|inference-1' | grep -q 'running'; do
    printf "."
    sleep 2
done
echo -e "\n[✓] Inference nodes shut down."

echo "starting inference nodes"
sudo -E virsh start inference-0
sudo -E virsh start inference-1

echo "waiting for final availability..."
sleep 30
