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

# Define file paths
REGISTRY_USER="junie"
REGISTRY_HOME="/home/${REGISTRY_USER}"
QUADLET_DIR="${REGISTRY_HOME}/.config/containers/systemd"
REGISTRY_CONFIG_DIR="/mnt/storage/registry-config"
REGISTRY_DATA_DIR="/mnt/storage/registry-data"

# Ensure directories exist
mkdir -p "${QUADLET_DIR}"
sudo -n mkdir -p "${REGISTRY_CONFIG_DIR}" "${REGISTRY_DATA_DIR}"
sudo -n chown -R ${REGISTRY_USER}:${REGISTRY_USER} "${REGISTRY_CONFIG_DIR}" "${REGISTRY_DATA_DIR}"

# 1.1 Create Registry Configuration if missing
if [ ! -f "${REGISTRY_CONFIG_DIR}/config.yml" ]; then
    echo "  - Creating registry config.yml..."
    cat <<EOF | sudo -n tee "${REGISTRY_CONFIG_DIR}/config.yml" > /dev/null
version: 0.1
log:
  fields:
    service: registry
storage:
  cache:
    blobdescriptor: inmemory
  filesystem:
    rootdirectory: /var/lib/registry
http:
  addr: :5000
  headers:
    X-Content-Type-Options: [nosniff]
  tls:
    certificate: /etc/docker/registry/tls.crt
    key: /etc/docker/registry/tls.key
health:
  storagedriver:
    enabled: true
    interval: 10s
    threshold: 3
EOF
fi

# 1.2 Generate TLS certificates if missing
if [ ! -f "${REGISTRY_CONFIG_DIR}/tls.crt" ]; then
    echo "  - Generating self-signed TLS certificates for the registry..."
    # Using '10.0.0.1' and 'hierophant.hierocracy.home' in SANs
    sudo -n openssl req -x509 -newnodes -days 3650 -newkey rsa:4096 \
        -keyout "${REGISTRY_CONFIG_DIR}/tls.key" \
        -out "${REGISTRY_CONFIG_DIR}/tls.crt" \
        -subj "/C=US/ST=CO/L=Denver/O=coppergate/CN=hierophant.hierocracy.home" \
        -addext "subjectAltName=DNS:hierophant.hierocracy.home,DNS:localhost,IP:10.0.0.1,IP:127.0.0.1"
fi
sudo -n chown ${REGISTRY_USER}:${REGISTRY_USER} "${REGISTRY_CONFIG_DIR}/tls.key" "${REGISTRY_CONFIG_DIR}/tls.crt"

# 1.3 Create Quadlet file
echo "  - Creating Quadlet file: ${QUADLET_DIR}/registry.container"
cat <<EOF > "${QUADLET_DIR}/registry.container"
[Container]
Image=registry:2
ContainerName=registry
PublishPort=5000:5000
Volume=${REGISTRY_DATA_DIR}:/var/lib/registry
Volume=${REGISTRY_CONFIG_DIR}/config.yml:/etc/docker/registry/config.yml
Volume=${REGISTRY_CONFIG_DIR}/tls.crt:/etc/docker/registry/tls.crt
Volume=${REGISTRY_CONFIG_DIR}/tls.key:/etc/docker/registry/tls.key
Environment=REGISTRY_HTTP_ADDR=0.0.0.0:5000
PodmanArgs=--security-opt=label=disable
[Service]
Restart=always
[Install]
WantedBy=default.target
EOF

# 1.4 Ensure firewall allows port 5000 from the talos-bridge
echo "  - Ensuring host firewall allows port 5000 on talos-bridge..."
sudo -n iptables -I INPUT -i talos-bridge -p tcp --dport 5000 -j ACCEPT 2>/dev/null || true

# 1.5 Manage systemd user bus accessibility (handles non-interactive/sudo/root runs)
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

# 2. Seed Required Images
# These are required for the nodes to install Talos Linux and start the Control Plane.
# Talos mirrors (like registry.k8s.io) will append the path, e.g.,
# registry.k8s.io/etcd:v3.6.7 -> 10.0.0.1:5000/registry.k8s.io/etcd:v3.6.7
echo "[REGISTRY] Seeding required images..."

# Helper function to pull, tag and push
seed_image() {
    local src=$1
    local dest_name=$2
    echo "  - Seeding ${dest_name}..."
    podman pull "${src}"
    podman tag  "${src}" "${REGISTRY}/${dest_name}"
    podman push --tls-verify=false "${REGISTRY}/${dest_name}"
}

# 2.1 Talos Installers
seed_image "factory.talos.dev/metal-installer/f1d36a4599ff60d0e94a2a86311470fbc0da2895bef4ba9b2c0288803986a846:v1.12.4" "siderolabs/installer-control-worker:v1.12.4"
seed_image "factory.talos.dev/metal-installer/f0248d1e8abaffdec12ddc54bae270982f3ab5a70e3c7b0b11c11ca0fb1708d9:v1.12.4" "siderolabs/installer-inference:v1.12.4"

# 2.2 Kubernetes Control Plane Images (v1.35.0)
# We seed both the full path and the short path to handle different client behaviors.
# Talos mirrors (like registry.k8s.io) will append the path, e.g.,
# registry.k8s.io/etcd:v3.6.7 -> 10.0.0.1:5000/registry.k8s.io/etcd:v3.6.7
# However, some components (like kubelet) might try short paths with ?ns=...
seed_image "registry.k8s.io/etcd:v3.6.7" "registry.k8s.io/etcd:v3.6.7"
seed_image "registry.k8s.io/etcd:v3.6.7" "etcd:v3.6.7"

seed_image "registry.k8s.io/kube-apiserver:v1.35.0" "registry.k8s.io/kube-apiserver:v1.35.0"
seed_image "registry.k8s.io/kube-apiserver:v1.35.0" "kube-apiserver:v1.35.0"

seed_image "registry.k8s.io/kube-controller-manager:v1.35.0" "registry.k8s.io/kube-controller-manager:v1.35.0"
seed_image "registry.k8s.io/kube-controller-manager:v1.35.0" "kube-controller-manager:v1.35.0"

seed_image "registry.k8s.io/kube-scheduler:v1.35.0" "registry.k8s.io/kube-scheduler:v1.35.0"
seed_image "registry.k8s.io/kube-scheduler:v1.35.0" "kube-scheduler:v1.35.0"

seed_image "registry.k8s.io/kube-proxy:v1.35.0" "registry.k8s.io/kube-proxy:v1.35.0"
seed_image "registry.k8s.io/kube-proxy:v1.35.0" "kube-proxy:v1.35.0"

seed_image "ghcr.io/siderolabs/kubelet:v1.35.0" "ghcr.io/siderolabs/kubelet:v1.35.0"
seed_image "ghcr.io/siderolabs/kubelet:v1.35.0" "siderolabs/kubelet:v1.35.0"

seed_image "registry.k8s.io/pause:3.10" "registry.k8s.io/pause:3.10"
seed_image "registry.k8s.io/pause:3.10" "pause:3.10"

# 2.3 Core Networking and DNS
seed_image "ghcr.io/siderolabs/flannel:v0.27.4" "ghcr.io/siderolabs/flannel:v0.27.4"
seed_image "ghcr.io/siderolabs/flannel:v0.27.4" "siderolabs/flannel:v0.27.4"

seed_image "registry.k8s.io/coredns/coredns:v1.13.2" "registry.k8s.io/coredns/coredns:v1.13.2"
seed_image "registry.k8s.io/coredns/coredns:v1.13.2" "coredns/coredns:v1.13.2"

# 2.4 Talos System Images (Required for early boot/install)
seed_image "ghcr.io/siderolabs/installer:v1.12.4" "ghcr.io/siderolabs/installer:v1.12.4"
seed_image "ghcr.io/siderolabs/installer:v1.12.4" "siderolabs/installer:v1.12.4"

seed_image "ghcr.io/siderolabs/talos:v1.12.4" "ghcr.io/siderolabs/talos:v1.12.4"
seed_image "ghcr.io/siderolabs/talos:v1.12.4" "siderolabs/talos:v1.12.4"

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
