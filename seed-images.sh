#!/bin/bash
export REGISTRY='10.0.0.1:5000'
seed_image() {
    local src=$1
    local dest_name=$2
    echo "  - Seeding ${dest_name}..."
    podman pull "${src}" >/dev/null 2>&1
    podman tag  "${src}" "${REGISTRY}/${dest_name}"
    podman push --tls-verify=false "${REGISTRY}/${dest_name}" >/dev/null 2>&1
    if [ $? -eq 0 ]; then echo "    [✓] ${dest_name} seeded."; else echo "    [!] ${dest_name} FAILED."; fi
}
seed_image 'registry.k8s.io/etcd:v3.6.7' 'etcd:v3.6.7'
seed_image 'registry.k8s.io/kube-apiserver:v1.35.0' 'kube-apiserver:v1.35.0'
seed_image 'registry.k8s.io/kube-controller-manager:v1.35.0' 'kube-controller-manager:v1.35.0'
seed_image 'registry.k8s.io/kube-scheduler:v1.35.0' 'kube-scheduler:v1.35.0'
seed_image 'registry.k8s.io/kube-proxy:v1.35.0' 'kube-proxy:v1.35.0'
seed_image 'ghcr.io/siderolabs/kubelet:v1.35.0' 'siderolabs/kubelet:v1.35.0'
seed_image 'registry.k8s.io/pause:3.10' 'pause:3.10'
seed_image 'ghcr.io/siderolabs/flannel:v0.27.4' 'siderolabs/flannel:v0.27.4'
seed_image 'registry.k8s.io/coredns/coredns:v1.13.2' 'coredns/coredns:v1.13.2'
seed_image 'ghcr.io/siderolabs/installer:v1.12.4' 'siderolabs/installer:v1.12.4'
seed_image 'ghcr.io/siderolabs/talos:v1.12.4' 'siderolabs/talos:v1.12.4'
