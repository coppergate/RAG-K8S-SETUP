#!/bin/bash
# ==============================================================================
# 08-SETUP-BOOTSTRAP-REGISTRY.SH
# Ensure the bootstrap registry is running and seeded with installer images.
# MUST be executed on 'hierophant'.
# ==============================================================================
set -e

# Ensure SETUP_ROOT is set
if [ -z "${SETUP_ROOT}" ]; then
    export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
fi

source "${SETUP_ROOT}/new-setup/config-env.sh"

# 1. Ensure the registry container is running (via Quadlet/systemd)
echo "[REGISTRY] Ensuring bootstrap registry service is running..."
# Quadlet file should be at /home/junie/.config/containers/systemd/registry.container

# Ensure systemd user bus accessibility (handles non-interactive/sudo/root runs)
REGISTRY_USER="junie"
REGISTRY_UID=$(id -u ${REGISTRY_USER} 2>/dev/null || id -u)

if [ "$(id -u)" -eq 0 ]; then
    # Running as root: Manage junie's user service
    echo "[REGISTRY] Running systemctl --user as ${REGISTRY_USER}..."
    runuser -l ${REGISTRY_USER} -c "export XDG_RUNTIME_DIR=/run/user/${REGISTRY_UID}; export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${REGISTRY_UID}/bus; systemctl --user daemon-reload; systemctl --user enable --now registry.service" || true
else
    # Running as non-root (hopefully junie)
    # Ensure environment is set even if in a non-interactive/broken session
    if [ -z "$XDG_RUNTIME_DIR" ] || [ ! -d "$XDG_RUNTIME_DIR" ]; then
        export XDG_RUNTIME_DIR="/run/user/$(id -u)"
        export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
    fi
    systemctl --user daemon-reload || true
    systemctl --user enable --now registry.service || true
fi

# Check if it's actually responding
echo "[REGISTRY] Verifying registry connectivity..."
if ! curl -sk https://10.0.0.1:5000/v2/ >/dev/null; then
    echo "WARNING: Registry at 10.0.0.1:5000 is not responding yet. Waiting 5s..."
    sleep 5
    if ! curl -sk https://10.0.0.1:5000/v2/ >/dev/null; then
        echo "ERROR: Registry at 10.0.0.1:5000 is not available."
        exit 1
    fi
fi

# 2. Seed Talos Installer Images
# These are required for the nodes to install Talos Linux.
echo "[REGISTRY] Seeding Talos installer images..."

# Control-Worker installer
echo "  - Mirroring control-worker installer..."
podman pull factory.talos.dev/metal-installer/f1d36a4599ff60d0e94a2a86311470fbc0da2895bef4ba9b2c0288803986a846:v1.12.4
podman tag  factory.talos.dev/metal-installer/f1d36a4599ff60d0e94a2a86311470fbc0da2895bef4ba9b2c0288803986a846:v1.12.4 \
            "${REGISTRY}/siderolabs/installer-control-worker:v1.12.4"
podman push --tls-verify=false "${REGISTRY}/siderolabs/installer-control-worker:v1.12.4"

# Inference installer (NVIDIA)
echo "  - Mirroring inference installer..."
podman pull factory.talos.dev/metal-installer/f0248d1e8abaffdec12ddc54bae270982f3ab5a70e3c7b0b11c11ca0fb1708d9:v1.12.4
podman tag  factory.talos.dev/metal-installer/f0248d1e8abaffdec12ddc54bae270982f3ab5a70e3c7b0b11c11ca0fb1708d9:v1.12.4 \
            "${REGISTRY}/siderolabs/installer-inference:v1.12.4"
podman push --tls-verify=false "${REGISTRY}/siderolabs/installer-inference:v1.12.4"

# 3. Ensure Boot ISOs are present in the shared directory
ISO_DIR="${SETUP_ROOT}/talos/iso-images/v1.12.4"
mkdir -p "${ISO_DIR}"

CP_ISO_URL="https://factory.talos.dev/image/f1d36a4599ff60d0e94a2a86311470fbc0da2895bef4ba9b2c0288803986a846/v1.12.4/metal-amd64.iso"
INF_ISO_URL="https://factory.talos.dev/image/f0248d1e8abaffdec12ddc54bae270982f3ab5a70e3c7b0b11c11ca0fb1708d9/v1.12.4/metal-amd64.iso"

if [ ! -f "${ISO_DIR}/talos-metal-f1d3-v1.12.4.iso" ]; then
    echo "[REGISTRY] Downloading Control Plane / Worker ISO..."
    curl -L "${CP_ISO_URL}" -o "${ISO_DIR}/talos-metal-f1d3-v1.12.4.iso"
fi

if [ ! -f "${ISO_DIR}/talos-metal-f024-v1.12.4.iso" ]; then
    echo "[REGISTRY] Downloading Inference (NVIDIA) ISO..."
    curl -L "${INF_ISO_URL}" -o "${ISO_DIR}/talos-metal-f024-v1.12.4.iso"
fi

echo "[REGISTRY] Bootstrap registry setup complete and seeded."
