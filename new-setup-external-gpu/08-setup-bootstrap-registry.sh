#!/bin/bash
# ==============================================================================
# 08-SETUP-BOOTSTRAP-REGISTRY.SH
# Ensure the bootstrap registry is running and seeded with installer images.
# MUST be executed on 'hierophant' as root (or via sudo).
# Uses a system-level Quadlet so no specific user account is required.
# ==============================================================================
set -e

# Ensure SETUP_ROOT is set
if [ -z "${SETUP_ROOT}" ]; then
    export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
fi

source "${SETUP_ROOT}/new-setup-external-gpu/config-env.sh"

echo "[REGISTRY] Ensuring bootstrap registry service is running..."

QUADLET_DIR="/etc/containers/systemd"
REGISTRY_CONFIG_DIR="/mnt/storage/registry-config"
REGISTRY_DATA_DIR="/mnt/storage/registry-data"

# Ensure directories exist
sudo -n mkdir -p "${QUADLET_DIR}" "${REGISTRY_CONFIG_DIR}" "${REGISTRY_DATA_DIR}"

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
    sudo -n openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
        -keyout "${REGISTRY_CONFIG_DIR}/tls.key" \
        -out "${REGISTRY_CONFIG_DIR}/tls.crt" \
        -subj "/C=US/ST=CO/L=Denver/O=coppergate/CN=hierophant.hierocracy.home" \
        -addext "subjectAltName=DNS:hierophant.hierocracy.home,DNS:registry.hierocracy.home,DNS:localhost,IP:192.168.1.101,IP:127.0.0.1"
fi

# 1.3 Ensure registry:2 image is available in the root podman store.
# Pull with full docker.io path and no TLS verify to avoid mirror loops
# (the bootstrap registry itself isn't up yet at this point).
if ! sudo -n podman image exists docker.io/library/registry:2; then
    echo "  - Pulling registry:2 image (bypassing mirrors)..."
    sudo -n podman pull --tls-verify=false docker.io/library/registry:2
fi

# 1.4 Create system-level Quadlet file
echo "  - Creating system Quadlet: ${QUADLET_DIR}/registry.container"
cat <<EOF | sudo -n tee "${QUADLET_DIR}/registry.container" > /dev/null
[Container]
Image=registry:2
ContainerName=registry
Network=host
Volume=${REGISTRY_DATA_DIR}:/var/lib/registry
Volume=${REGISTRY_CONFIG_DIR}/config.yml:/etc/docker/registry/config.yml
Volume=${REGISTRY_CONFIG_DIR}/tls.crt:/etc/docker/registry/tls.crt
Volume=${REGISTRY_CONFIG_DIR}/tls.key:/etc/docker/registry/tls.key
Environment=REGISTRY_HTTP_ADDR=0.0.0.0:5000
PodmanArgs=--security-opt=label=disable

[Service]
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# 1.5 Ensure firewall allows port 5000
echo "  - Ensuring host firewall allows port 5000..."
sudo -n iptables -C INPUT -p tcp --dport 5000 -j ACCEPT 2>/dev/null || \
    sudo -n iptables -I INPUT -p tcp --dport 5000 -j ACCEPT

# 1.6 Clear any stale container that may be holding port 5000
if sudo -n podman ps -q --filter name=registry 2>/dev/null | grep -q .; then
    echo "  - Stopping stale registry container(s)..."
    sudo -n podman ps -q --filter name=registry | xargs sudo -n podman rm -f
fi

# 1.7 Reload systemd and start the service
echo "[REGISTRY] Reloading systemd and starting registry service..."
sudo -n systemctl daemon-reload
sudo -n systemctl start registry.service

# 1.7 Verify connectivity
echo "[REGISTRY] Verifying registry connectivity..."
if ! curl -sk https://${REGISTRY}/v2/ >/dev/null; then
    echo "WARNING: Registry at ${REGISTRY} is not responding yet. Waiting 5s..."
    sleep 5
    if ! curl -sk https://${REGISTRY}/v2/ >/dev/null; then
        echo "ERROR: Registry at ${REGISTRY} is not available."
        echo "Check: sudo systemctl status registry.service"
        echo "Logs:  sudo journalctl -xeu registry.service"
        exit 1
    fi
fi

echo "[REGISTRY] Registry is up at https://${REGISTRY}/v2/"

# 2. Seed Required Images
echo "[REGISTRY] Seeding required images..."

seed_image() {
    local src=$1
    local dest_name=$2
    echo "  - Seeding ${dest_name}..."
    sudo -n podman pull "${src}"
    sudo -n podman tag  "${src}" "${REGISTRY}/${dest_name}"
    sudo -n podman push --tls-verify=false "${REGISTRY}/${dest_name}"
}

# 2.1 Talos Installers
seed_image "factory.talos.dev/metal-installer/f1d36a4599ff60d0e94a2a86311470fbc0da2895bef4ba9b2c0288803986a846:v1.12.4" "siderolabs/installer-control-worker:v1.12.4"

# GPU installer for the external inference node (schematic adds NVIDIA extensions:
# nonfree-kmod-nvidia + nvidia-container-toolkit). Consumed by
# configs/patch-inference-0.yaml -> machine.install.image. See EXTERNAL-NODE-SETUP.md.
seed_image "factory.talos.dev/metal-installer/4b03bd8a24f08b4e9a58d122191901bf5e8751eb03e0fc489e59416ab7fb597f:v1.12.4" "siderolabs/installer-gpu:v1.12.4"

# 2.2 Kubernetes Control Plane Images (v1.35.0)
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

# 2.4 Talos System Images
seed_image "ghcr.io/siderolabs/installer:v1.12.4" "ghcr.io/siderolabs/installer:v1.12.4"
seed_image "ghcr.io/siderolabs/installer:v1.12.4" "siderolabs/installer:v1.12.4"

seed_image "ghcr.io/siderolabs/talos:v1.12.4" "ghcr.io/siderolabs/talos:v1.12.4"
seed_image "ghcr.io/siderolabs/talos:v1.12.4" "siderolabs/talos:v1.12.4"

# 3. Ensure Boot ISOs are present
ISO_DIR="${SETUP_ROOT}/talos/iso-images/v1.12.4"
mkdir -p "${ISO_DIR}"

CP_ISO_URL="https://factory.talos.dev/image/f1d36a4599ff60d0e94a2a86311470fbc0da2895bef4ba9b2c0288803986a846/v1.12.4/metal-amd64.iso"

if [ ! -f "${ISO_DIR}/talos-metal-f1d3-v1.12.4.iso" ]; then
    echo "[REGISTRY] Downloading Control Plane / Worker ISO..."
    curl -L "${CP_ISO_URL}" -o "${ISO_DIR}/talos-metal-f1d3-v1.12.4.iso"
fi

echo "[REGISTRY] Bootstrap registry setup complete and seeded."
