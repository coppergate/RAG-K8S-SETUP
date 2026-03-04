#!/bin/bash
set -e

# Ensure SETUP_ROOT is set
if [ -z "${SETUP_ROOT}" ]; then
    export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
fi

source "${SETUP_ROOT}/new-setup/config-env.sh" 
source "${SETUP_ROOT}/new-setup/config-endpoints.sh"

echo "Applying configuration to inference nodes (BASICS MODE)"
INF_INSTALLER="hierophant.hierocracy.home:5000/siderolabs/installer-inference:v1.12.4"

# Create a minimal patch to use the NVIDIA-enabled installer
cat > /tmp/inf-patch.yaml <<EOF
machine:
  install:
    image: ${INF_INSTALLER}
EOF

for ip in "${INFERENCE_IP_0}" "${INFERENCE_IP_1}"; do
    if [ -n "$ip" ]; then
        echo "Applying to $ip (with inference installer patch)..."
        sudo -E ${TALOS_ROOT}/talosctl apply-config --insecure --talosconfig "${TALOSCONFIG}" --nodes "$ip" --endpoints "$ip" --file "${TALOS_CONFIG}/worker.yaml" --config-patch @/tmp/inf-patch.yaml
    fi
done
