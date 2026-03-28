# Operations Manual

## Cluster Installation
- All installation scripts MUST be executed on the host machine **hierophant**.
- The main entry point is `new-setup/config-cluster.sh`.

## kubectl Version Synchronization
- The script `new-setup/03-ensure-kubectl.sh` ensures the local `kubectl` client matches the cluster's server version.
- It prioritizes using the `talos/kubectl` binary if it matches.
- It can extract the binary from a container image if available in the local registry (`hierophant.hierocracy.home:5000/kubectl:<version>`).
- It falls back to `https://dl.k8s.io` if no local source is found.
- If a specific version is required, set `KUBECTL_VERSION` (e.g., `v1.31.4`) before running the script.

## Talos Configuration
- Machine configs are generated to `/home/k8s/talos/config/`.
- Global patches are applied from `configs/machine-patches.yaml` and `configs/cluster-patches.yaml`.

## GPU Setup
- The NVIDIA GPU Operator is installed via `new-setup/52-install-gpu-operator.sh`.
- Node labeling is done via `new-setup/55-label-gpu-nodes.sh`.
