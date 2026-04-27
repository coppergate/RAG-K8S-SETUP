# GPU Operator + Talos Notes

## Context
During Talos image upgrades, `gpu-operator` validators can get stuck in `Init:0/4` with repeating driver validation retries, even though GPUs are present and device-plugin/DCGM pods are running.

## Root Cause
GPU Operator validator logic expects driver assets in container-style locations under:
- `/run/nvidia/driver/usr/bin`
- `/run/nvidia/driver/usr/lib64`

On Talos with NVIDIA system extensions, key files are exposed under:
- `/usr/local/bin` (for `nvidia-smi`)
- `/usr/local/glibc/usr/lib` (for `libnvidia-ml.so.1`, etc.)

Without mapping these Talos paths into `/run/nvidia/driver`, `driver-validation` loops and `ClusterPolicy` can stay not-ready (`state-operator-validation`).

## Scripted Fix (in `52-install-gpu-operator.sh`)
`nvidia-talos-validation-fix` DaemonSet now continuously:
1. Ensures `/run/nvidia/validations` markers exist (`driver-ready`, `toolkit-ready`, `cuda-ready`).
2. Creates/refreshes symlinks:
   - `/run/nvidia/driver/usr/bin -> /host/usr/local/bin`
   - `/run/nvidia/driver/usr/lib64 -> /host/usr/local/glibc/usr/lib`
3. Repeats every 30 seconds so node reboots/restarts do not regress.

## Additional Conflict Guard
Before installing/upgrading `gpu-operator`, the script now removes legacy standalone Helm releases (best effort):
- `nvidia-device-plugin`
- `dcgm-exporter`

This prevents duplicate DaemonSets and conflicting behavior when migrating to GPU Operator-managed components.
