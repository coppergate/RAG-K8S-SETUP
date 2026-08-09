# External GPU Node Setup Guide

> **Ownership note (2026-08-09).** The NVIDIA GPU Operator is no longer installed
> from this repo. `52-install-gpu-operator.sh` and `55-label-gpu-nodes.sh` were
> **deleted**; their logic now lives in
> **`complete-build/infrastructure/nvidia-operator.sh`**, which runs automatically
> as Step 1.9 of `setup-complete.sh` — before the RAG stack, because it publishes
> the `gpu=true` and `hierocracy.home/gpu-*-uuid` node labels that Ollama pins
> against.
>
> The split is: **this repo owns Talos-level node provisioning** (machine config,
> kernel modules, driver extensions, enrolment); **complete-build owns every
> Kubernetes object** (operator Helm release, RuntimeClass, device-plugin
> ConfigMap, validation-fix DaemonSet, GPU node labels).
>
> The analysis below — heterogeneous GPU handling, the two approaches that failed,
> the Talos validator layout — is still accurate and is why the operator is
> configured the way it is. Only the script names have moved. Where the text says
> `52-install-gpu-operator.sh`, read `complete-build/infrastructure/nvidia-operator.sh`.

This document covers the steps specific to enrolling the physical GPU inference node
into the `new-setup-external-gpu` cluster. The base cluster (control-plane + workers)
is set up by `config-cluster.sh` first. For the overall network design see
[`network/README.md`](network/README.md).

---

## Network Topology

The cluster runs on a **flat LAN** (`192.168.0.0/16`). The GPU node is just another
physical host on that LAN — no VLANs, no trunks, no NAT.

```
        192.168.0.0/16  (router / DHCP / gateway @ 192.168.0.1)
                     │  (single switched L2 — everything plugged in)
   ┌─────────────────┼───────────────────────┬─────────────────┐
 hierophant        hegemon                GPU node
 br-lan/enp5s0     br-lan/eno1            bare-metal Talos
 192.168.1.101/16  192.168.1.100/16       eth0: 192.168.5.31/16
   ├─ control-0/1/2   └─ dev-fedora VM     GW:  192.168.0.1
   └─ worker-0..3        192.168.1.50/16
```

### Switch Configuration Requirements

None beyond plugging the GPU node into the same LAN. There is **no VLAN** — the GPU
node's NIC is an ordinary access port on the flat LAN, and Talos configures a plain
static IP (`192.168.5.31/16`) on it, matched by MAC.

---

## Pre-Enrollment Checklist

- [ ] `inference_0_mac` set in `05-MAC-addresses.sh` to the GPU node's actual NIC MAC
- [ ] `deviceSelector.hardwareAddr` in `configs/patch-inference-0.yaml` matches the same MAC
- [ ] Install disk confirmed (see "Identifying the Disk" below)
- [ ] Installer image confirmed in registry (see "Talos Image" below)
- [ ] Cluster is healthy (`kubectl get nodes` shows control-plane + workers Ready)
- [ ] GPU node is booted from Talos USB and in maintenance mode

### Finding the GPU Node's MAC Address
Options (before Talos boot):
- Check the NIC's physical label or the motherboard BIOS/UEFI → Network section
- Boot a live Linux USB, run: `ip link show`

Options (after Talos USB boot, in maintenance mode):
- The Talos console UI shows the interface MAC and its DHCP-assigned IP
- From hierophant, once you know the MAC, resolve the maintenance IP via ARP:
  ```bash
  # prime the neighbour table, then look up the MAC on br-lan
  for i in $(seq 2 254); do ping -c1 -W1 192.168.0.$i >/dev/null 2>&1 & done; wait
  ip neigh show dev br-lan | grep -i "<gpu-node-mac>"
  ```
  `45-enroll-external-node.sh` performs this discovery automatically.

---

## Identifying the Install Disk

After the GPU node boots from the Talos USB (maintenance mode) it gets a temporary
`192.168.0.x` DHCP lease from the router. Using that maintenance IP:

```bash
sudo /home/k8s/talos/talosctl disks \
    --insecure \
    --nodes <maintenance-ip> \
    --endpoints <maintenance-ip>
```

Update `configs/patch-inference-0.yaml` with the correct device:
- Single SATA SSD: `/dev/sda`
- NVMe SSD: `/dev/nvme0n1`

---

## Talos Image for the GPU Node

The GPU node requires a Talos installer image built with the NVIDIA system extensions
(kernel modules, container toolkit, etc.). This is different from the standard
`installer-control-worker` image used by VMs on hierophant.

### Seeded Automatically (default)

`08-setup-bootstrap-registry.sh` seeds `siderolabs/installer-gpu:v1.12.4` into the
registry alongside the standard installers, pulling from the Talos Image Factory
schematic `4b03bd8a24f08b4e9a58d122191901bf5e8751eb03e0fc489e59416ab7fb597f`
(NVIDIA `nonfree-kmod-nvidia` + `nvidia-container-toolkit`). No manual build is
required unless you need a different schematic or Talos version. The sections below
are only needed to change extensions or the Talos version.

### Using an Existing Image

If you already have a GPU installer image in the registry, update `patch-inference-0.yaml`:

```yaml
  install:
    image: hierophant.hierocracy.home:5000/siderolabs/installer-gpu:v1.12.4
```

Verify the image exists:
```bash
curl -sk https://hierophant.hierocracy.home:5000/v2/siderolabs/installer-gpu/tags/list
```

### Building a New GPU Installer Image (Image Factory)

Use the Talos Image Factory to generate a custom installer with NVIDIA extensions:

1. **Identify required extensions** for your GPU and Talos version:
   - `siderolabs/nonfree-kmod-nvidia` — NVIDIA kernel modules (non-free)
   - `siderolabs/nvidia-container-toolkit` — NVIDIA container runtime
   - `siderolabs/nvidia-fabricmanager` — (optional, for NVLink/multi-GPU)

2. **Generate a schematic** at https://factory.talos.dev — select:
   - Talos version: `v1.12.4`
   - Extensions: `nonfree-kmod-nvidia`, `nvidia-container-toolkit`
   - Copy the generated schematic ID

3. **Download and push the installer** to the local registry:
   ```bash
   SCHEMATIC_ID="<your-schematic-id>"
   TALOS_VERSION="v1.12.4"

   # Pull from Talos Image Factory (metal-installer — bare-metal platform, v1.12.4)
   podman pull \
       "factory.talos.dev/metal-installer/${SCHEMATIC_ID}:${TALOS_VERSION}"

   # Retag and push to local registry
   podman tag \
       "factory.talos.dev/metal-installer/${SCHEMATIC_ID}:${TALOS_VERSION}" \
       "hierophant.hierocracy.home:5000/siderolabs/installer-gpu:${TALOS_VERSION}"

   podman push \
       --tls-verify=false \
       "hierophant.hierocracy.home:5000/siderolabs/installer-gpu:${TALOS_VERSION}"
   ```

4. **Alternatively, using talosctl gen extension-image:**
   ```bash
   # List available extension images
   /home/k8s/talos/talosctl images default

   # Generate custom installer with extensions
   /home/k8s/talos/talosctl gen extension-image \
       --version v1.12.4 \
       siderolabs/nonfree-kmod-nvidia \
       siderolabs/nvidia-container-toolkit
   ```

---

## PXE/TFTP Boot (Future Reference)

For automated GPU node provisioning without a USB drive, set up PXE boot. On the flat
LAN the node PXE-boots against a TFTP server reachable on `192.168.0.0/16`.

### Prerequisites
- A TFTP server on hierophant (or a dedicated machine) reachable on the LAN
- The GPU node's NIC configured to PXE boot (BIOS setting)
- A DHCP `next-server`/`filename` option pointing PXE clients at the TFTP server.
  The LAN router (`192.168.0.1`) is the DHCP authority — either set PXE options
  there, or run a helper `dnsmasq --enable-tftp --dhcp-boot=...` bound to `br-lan`
  on hierophant that answers only the GPU node's MAC (`--dhcp-host`).

### Setup on hierophant

1. **Install TFTP server:**
   ```bash
   sudo dnf install -y tftp-server syslinux
   sudo systemctl enable --now tftp.socket
   ```

2. **Download Talos PXE assets** for your GPU installer schematic:
   ```bash
   SCHEMATIC_ID="<your-schematic-id>"
   TALOS_VERSION="v1.12.4"

   mkdir -p /var/lib/tftpboot/talos

   # Kernel
   curl -L "https://factory.talos.dev/image/${SCHEMATIC_ID}/${TALOS_VERSION}/kernel-amd64" \
       -o /var/lib/tftpboot/talos/vmlinuz

   # Initramfs
   curl -L "https://factory.talos.dev/image/${SCHEMATIC_ID}/${TALOS_VERSION}/initramfs-amd64.xz" \
       -o /var/lib/tftpboot/talos/initramfs.xz
   ```

3. **Create PXE menu** (`/var/lib/tftpboot/pxelinux.cfg/default`):
   ```
   DEFAULT talos
   LABEL talos
     KERNEL talos/vmlinuz
     INITRD talos/initramfs.xz
     APPEND ip=dhcp talos.config=none
   ```

4. **Firewall:** Allow TFTP (port 69/UDP) on the `br-lan` interface:
   ```bash
   sudo firewall-cmd --add-port=69/udp --zone=trusted --permanent
   sudo firewall-cmd --reload
   ```

---

## Enrollment Steps (Summary)

```bash
# On hierophant:
cd /mnt/hegemon-share/share/code/kubernetes-setup/new-setup-external-gpu

# 1. Set the GPU node MAC (after finding it via console or BIOS)
vi 05-MAC-addresses.sh             # set inference_0_mac
vi configs/patch-inference-0.yaml  # set deviceSelector.hardwareAddr, confirm disk

# 2. Boot GPU node from Talos USB — it gets a temporary 192.168.0.x lease from
#    the router. 45-enroll discovers that maintenance IP by MAC (ARP).

# 3. Run full enrollment. This applies the config (node reboots onto static
#    192.168.5.31), then applies the GPU post-boot patch and reboots a SECOND
#    time to load the NVIDIA kernel modules. Expect two reboots.
./45-enroll-external-node.sh
#    If the MAC isn't set, pass the maintenance IP explicitly:
#    INFERENCE_MAINT_IP=192.168.0.NN ./45-enroll-external-node.sh

# 4. Install the GPU Operator and label the node.
#    Owned by complete-build; runs automatically as Step 1.9 of setup-complete.sh.
#    To run it on its own:
bash /mnt/hegemon-share/share/code/complete-build/infrastructure/nvidia-operator.sh
```

### The GPU post-boot patch (step 6 of enrollment)

`configs/post-inference-talos.yaml` is applied by `45-enroll-external-node.sh`
*after* the node has joined and gone Ready, with `--mode=reboot`. It sets the
`nvidia`, `nvidia_uvm`, `nvidia_drm` and `nvidia_modeset` kernel modules, the
`net.core.bpf_jit_harden` sysctl, and containerd's `default_runtime_name =
"nvidia"`.

It cannot be merged into `patch-inference-0.yaml`: kernel modules load at boot,
so the node has to already be running Talos-from-disk before they can take
effect.

**Symptom if this step is skipped or fails** — `ext-nvidia-persistenced`
registers as a service but never reaches `up`. The installer image ships the
NVIDIA extensions, so the service exists; `nvidia-persistenced` just cannot open
an NVIDIA device with no `nvidia` module loaded. The GPU operator's driver
validator then loops and `ClusterPolicy` stays not-ready.

Verify by hand:

```bash
source ./config-env.sh
source ./config-endpoints.sh

# Expect nvidia, nvidia_uvm, nvidia_drm, nvidia_modeset
sudo -E ${TALOS_ROOT}/talosctl --talosconfig "${TALOSCONFIG}" \
  --nodes "${INFERENCE_IP_0}" --endpoints "${CP_VIP}" \
  read /proc/modules | grep nvidia

# Expect ext-nvidia-persistenced in a Running/OK state
sudo -E ${TALOS_ROOT}/talosctl --talosconfig "${TALOSCONFIG}" \
  --nodes "${INFERENCE_IP_0}" --endpoints "${CP_VIP}" \
  services
```

To re-apply on an already-enrolled node without re-running enrollment:

```bash
sudo -E ${TALOS_ROOT}/talosctl --talosconfig "${TALOSCONFIG}" \
  --nodes "${INFERENCE_IP_0}" --endpoints "${CP_VIP}" \
  patch machineconfig \
  --patch "@configs/post-inference-talos.yaml" \
  --mode=reboot
```

### Heterogeneous GPUs — a mixed, untyped pool

`inference-0` holds three GPUs of two different models:

| idx | UUID | Model | Memory | Compute | PCI | PCI ID |
|---|---|---|---|---|---|---|
| 0 | `GPU-ce06ba79-…c6ecb` | Tesla V100 32GB | 32768 MiB | `sm_70` | `05:00.0` | — |
| 1 | `GPU-6a3e90b5-…08c4fa` | Tesla P4 | 7680 MiB | `sm_61` | `81:00.0` | `10de:1bb3` |
| 2 | `GPU-d5cfa048-…7dfbb5` | Tesla P4 | 7680 MiB | `sm_61` | `82:00.0` | `10de:1bb3` |

> ⚠ **`nvidia.com/gpu` on this node is 3, and it is NOT typed.** The GFD labels
> describe the V100 only. A pod that selects on `nvidia.com/gpu.memory=32768` or
> `compute.major=7` can still be handed a P4 with 8 GB and `sm_61`, and will fail
> on memory or CUDA arch. Until the P4s are hidden from the driver, treat
> `nvidia.com/gpu` here as "some NVIDIA GPU" and pin critical work explicitly.

**Advertising only the V100 is not achievable through the device plugin.** Two
approaches were tried against the live cluster and both failed:

1. **`NVIDIA_VISIBLE_DEVICES` pinned to the V100 UUID** on the device plugin and
   GFD. No effect — the operator runs both as **privileged** containers, so
   `/dev/nvidia*` is mounted wholesale and NVML enumerates everything regardless.
   That variable only governs what the runtime hook injects into an *unprivileged*
   container. It made things worse: GFD collapsed the node to
   `gpu.product=Tesla-P4, count=2`, hiding the V100.

2. **Named resources** (`resources.gpus` mapping product globs to distinct
   resource names). Rejected by the plugin outright:

   ```text
   W config.go:88] Customizing the 'resources' field is not yet supported
                   in the config. Ignoring...
   ```

   The field parses but is unimplemented in plugin **v0.19.3**. Every GPU lands in
   one `nvidia.com/gpu` pool.

**What `mig.strategy=none` did fix.** The chart default `single` asserts the node
is uniform; under it GFD logged `Multiple device types detected` and described all
three GPUs as Tesla P4 / 7680 MiB / `sm_61`. With `none`, GFD now reports the V100
truthfully:

```text
nvidia.com/gpu.product=Tesla-PG500-216   memory=32768
nvidia.com/gpu.compute.major=7 minor=0   family=volta   count=1
```

Note this surfaces on the containers as `MIG_STRATEGY`, and the plugin resolves
**env above its config file** — setting `migStrategy` in the ConfigMap has no
effect. It must be set as the Helm value `mig.strategy`.

**Inventory labels.** Because the pool is mixed and GFD cannot say so, the truth
is carried separately:

```text
hierocracy.home/gpu-total-count=3
hierocracy.home/gpu-v100-count=1
hierocracy.home/gpu-p4-count=2
hierocracy.home/gpu-heterogeneous=true
hierocracy.home/gpu-pool-mixed=true            # nvidia.com/gpu is NOT uniform
hierocracy.home/gpu-labels-describe=tesla-v100-32gb
```

#### If you do want a V100-only pool

The restriction has to happen below the device plugin, by keeping the NVIDIA
driver from claiming the P4s at all. Both P4s share PCI ID `10de:1bb3`, which the
V100 does not, so they can be targeted as a pair via a Talos kernel argument:

```yaml
machine:
  install:
    extraKernelArgs:
      - vfio-pci.ids=10de:1bb3
```

Applied with `--mode=reboot`, NVML would then see only the V100 and
`nvidia.com/gpu` would become 1, with the GFD labels already correct.

> **Untested here, and it is a real trade-off:** the P4s become unavailable to
> CUDA entirely — bound to `vfio-pci` and usable only for passthrough. Verify on
> a maintenance window, not in place. The alternative is to leave the pool mixed
> and schedule defensively using the labels above.

### Targeting a specific GPU (the model this node uses)

Workloads on `inference-0` **pin a card by UUID** rather than requesting
`nvidia.com/gpu`. This is verified working: an unprivileged pod that sets
`NVIDIA_VISIBLE_DEVICES` to a UUID sees exactly that GPU and nothing else.

```text
NVIDIA_VISIBLE_DEVICES=GPU-ce06ba79…   → 0, Tesla PG500-216, 32768 MiB
NVIDIA_VISIBLE_DEVICES=GPU-6a3e90b5…   → 0, Tesla P4,          7680 MiB
NVIDIA_VISIBLE_DEVICES=<v100>,<p4>     → 0, Tesla PG500-216 / 1, Tesla P4
```

(The privileged-container caveat elsewhere in this document applies only to the
GPU operator's own DaemonSets, not to your workloads.)

The UUIDs are published as node labels, so manifests need not hardcode them:

| Label | Card |
|---|---|
| `hierocracy.home/gpu-v100-uuid` | Tesla V100 32GB, `05:00.0` |
| `hierocracy.home/gpu-p4-0-uuid` | Tesla P4, `81:00.0` |
| `hierocracy.home/gpu-p4-1-uuid` | Tesla P4, `82:00.0` |

```bash
/home/k8s/kube/kubectl get node inference-0 \
  -o jsonpath='{.metadata.labels.hierocracy\.home/gpu-v100-uuid}'
```

**Pod spec:**

```yaml
spec:
  nodeSelector:
    gpu: "true"
  containers:
  - name: inference
    image: <your-image>
    env:
    - name: NVIDIA_VISIBLE_DEVICES
      value: "GPU-ce06ba79-6e2e-b16e-e326-3ba4747c6ecb"   # V100
    - name: NVIDIA_DRIVER_CAPABILITIES
      value: "utility,compute"
    # deliberately NO resources.limits['nvidia.com/gpu']
```

Inside the container GPUs are renumbered `0..N-1` in the order listed, so
`CUDA_VISIBLE_DEVICES=0` refers to the first UUID you named — not to host index 0.

> ⚠ **Pinning bypasses scheduler accounting.** A pinned pod does not consume
> `nvidia.com/gpu`, so Kubernetes does not know the card is busy. Two pods pinned
> to the same UUID will happily co-schedule and fight over VRAM.
>
> Don't mix the two models. Because the plugin still advertises 3, a pod that
> *requests* `nvidia.com/gpu: 1` can be handed a card a pinned job already holds.
> **Nothing on this node should request `nvidia.com/gpu`.** Track assignment by
> convention — one workload per UUID.
>
> To remove the hazard entirely, re-run with the device plugin off:
>
> ```bash
> DEVICE_PLUGIN_ENABLED=false bash complete-build/infrastructure/nvidia-operator.sh
> ```
>
> This deletes `nvidia.com/gpu` from the node. DCGM metrics, GFD labels and the
> driver are unaffected.

#### Which card for which job

| | V100 32GB (`sm_70`) | Tesla P4 8GB (`sm_61`) |
|---|---|---|
| Tensor cores | yes — FP16 / mixed precision | **none** |
| Suited to | training, larger models, anything FP16 | small INT8 / FP32 inference |
| Constraint | — | 8 GB ceiling, no autocast speedup |

Recent framework builds have been dropping Pascal support. Before committing a
workload to the P4s, confirm the image actually ships `sm_61` kernels:

```bash
python -c "import torch; print(torch.cuda.get_arch_list())"
```

If `sm_61` is missing, PyTorch either JITs from PTX (slow first run) or fails.
The V100's `sm_70` is safe across current builds.

### GPU smoke test

`nvidia/cuda:12.3.1-base-ubuntu22.04` is seeded in the bootstrap registry for
this. Requesting `nvidia.com/gpu: 1` gives you **whichever** of the three the
plugin hands out — run it a few times and you will see both models:

```bash
/home/k8s/kube/kubectl run gpu-test --restart=Never --rm -i \
  --image=hierophant.hierocracy.home:5000/nvidia/cuda:12.3.1-base-ubuntu22.04 \
  --overrides='{"spec":{"containers":[{"name":"c","image":"hierophant.hierocracy.home:5000/nvidia/cuda:12.3.1-base-ubuntu22.04","command":["nvidia-smi","--query-gpu=name,memory.total","--format=csv"],"resources":{"limits":{"nvidia.com/gpu":1}}}]}}'
```

To pin a *specific* card, skip the resource request and name the UUID directly —
this bypasses the device plugin, so it does no accounting and can double-book a
GPU another pod holds. Use it for diagnostics, not production scheduling:

```bash
/home/k8s/kube/kubectl run gpu-test-v100 --restart=Never --rm -i \
  --image=hierophant.hierocracy.home:5000/nvidia/cuda:12.3.1-base-ubuntu22.04 \
  --overrides='{"spec":{"nodeName":"inference-0"}}' \
  --env=NVIDIA_VISIBLE_DEVICES=GPU-ce06ba79-6e2e-b16e-e326-3ba4747c6ecb \
  --env=NVIDIA_DRIVER_CAPABILITIES=utility \
  -- nvidia-smi --query-gpu=name,memory.total --format=csv
```

Re-derive the UUIDs after a hardware change (`nvidia-smi` cannot be run directly
on Talos, so this goes through a throwaway pod):

```bash
/home/k8s/kube/kubectl run gpu-probe --restart=Never --rm -i \
  --image=hierophant.hierocracy.home:5000/nvcr.io/nvidia/k8s-device-plugin:v0.18.1 \
  --overrides='{"spec":{"nodeName":"inference-0"}}' \
  --env=NVIDIA_VISIBLE_DEVICES=all \
  --env=NVIDIA_DRIVER_CAPABILITIES=utility \
  -- nvidia-smi --query-gpu=index,uuid,name,memory.total,pci.bus_id --format=csv
```

### RuntimeClass `nvidia`

`toolkit.enabled=false` on Talos (the runtime comes from the
`nvidia-container-toolkit` system extension), which means the GPU operator never
creates the `nvidia` RuntimeClass it normally would. Since the values set
`devicePlugin.runtimeClassName: nvidia`, and a pod naming a missing RuntimeClass
is rejected outright, `complete-build/infrastructure/nvidia-operator.sh` creates it explicitly.

### Node `role` labels

`complete-build/infrastructure/nvidia-operator.sh` pins the operator controller and the
node-feature-discovery master to `role=storage-node`, and the NFD worker to
`role=inference-node`. These come from Talos `machine.nodeLabels`:

| Label | Set in |
|---|---|
| `role=storage-node` | `configs/patch-worker-0..3.yaml` |
| `role=inference-node` | `configs/patch-inference-0.yaml` |

`complete-build/scripts/setup-node-labels.sh` applies them with `kubectl`, so
clusters built before those patches existed still work. Without the labels the
Helm install hangs on Pending pods until it times out.
