# External GPU Node Setup Guide

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

# 4. Install GPU Operator and label the node
./52-install-gpu-operator.sh
./55-label-gpu-nodes.sh
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

### Heterogeneous GPUs — only the V100 is advertised

`inference-0` holds three GPUs of two different models:

| idx | UUID | Model | Memory | PCI | Advertised |
|---|---|---|---|---|---|
| 0 | `GPU-ce06ba79-…c6ecb` | Tesla V100 32GB (`sm_70`) | 32768 MiB | `05:00.0` | **yes** |
| 1 | `GPU-6a3e90b5-…08c4fa` | Tesla P4 (`sm_61`) | 7680 MiB | `81:00.0` | no |
| 2 | `GPU-d5cfa048-…7dfbb5` | Tesla P4 (`sm_61`) | 7680 MiB | `82:00.0` | no |

**Why not all three.** GPU Feature Discovery models a node as having one kind of
GPU: it publishes a single `nvidia.com/gpu.product`, `.memory` and
`.compute.major/minor` derived from one device and applies them node-wide. With a
mixed node those labels are wrong for two of the three GPUs — the node would
advertise "Tesla V100 / 32GB / sm_70" three times over, and a pod scheduled on
those labels could land on a P4 and fail on either memory or CUDA arch.

So `nvidia.com/gpu` reports **1**, and it is genuinely the V100.

**How — named resources, matched on product name.** The device plugin's
`resources.gpus` list maps a product-name glob to a resource name, first match
wins:

```yaml
resources:
  gpus:
  - pattern: "Tesla PG500-216"
    name: nvidia.com/gpu
  - pattern: "Tesla P4"
    name: nvidia.com/tesla-p4
```

Giving `nvidia.com/gpu: 1` (the V100) and `nvidia.com/tesla-p4: 2`. Patterns match
the NVML product name (`nvidia-smi --query-gpu=name`), **not** GFD's
dash-sanitized label form — `Tesla P4`, not `Tesla-P4`. Override via
`V100_PRODUCT_PATTERN`, `P4_PRODUCT_PATTERN` and `P4_RESOURCE_NAME`.

> ⚠ **`NVIDIA_VISIBLE_DEVICES` does not work for this.** The operator runs the
> device plugin and GFD as **privileged** containers, so `/dev/nvidia*` is mounted
> wholesale and NVML enumerates every GPU regardless — that variable only governs
> what the runtime hook injects into an *unprivileged* container. It was tried:
> GFD still saw all three and collapsed the node to `gpu.product=Tesla-P4`,
> `gpu.count=2`, hiding the V100 entirely. Don't reintroduce it.

Two further requirements, both easy to miss:

- `devicePlugin.config.default: config.yaml` must be set in the Helm values, or
  the operator ignores the ConfigMap wholesale and the plugin runs on chart
  defaults. This was the original failure.
- The ConfigMap must **not** set `nvidiaDriverRoot`/`nvidiaDevRoot`. The plugin's
  default `/run/nvidia/driver` is the layout `nvidia-talos-validation-fix` builds;
  overriding it to `/` points at a path that doesn't exist on Talos.

`dcgmExporter` is deliberately unrestricted — the P4s are unschedulable under
`nvidia.com/gpu` but still driver-managed, so temperature, power and utilization
for all three still reach Grafana.

**The P4s are still there.** Driver-managed, `/dev/nvidia1` and `/dev/nvidia2`,
addressable via `nvidia.com/tesla-p4`. They are recorded on the node as:

```text
hierocracy.home/gpu-advertised=tesla-v100-32gb
hierocracy.home/gpu-advertised-count=1
hierocracy.home/gpu-p4-present=true
hierocracy.home/gpu-p4-count=2
hierocracy.home/gpu-total-count=3
hierocracy.home/gpu-heterogeneous=true
```

The custom domain prefix keeps them clear of the `nvidia.com/*` namespace GFD
owns. To use a P4 deliberately, request its own resource — no UUID juggling:

```yaml
resources:
  limits:
    nvidia.com/tesla-p4: 1
```

Note that GFD's node-level `nvidia.com/gpu.product`, `.memory` and `.compute.*`
labels still describe only one of the two models — GFD has no way to express a
mixed node. Schedule on the resource names and the `hierocracy.home/gpu-*` labels
above; do not trust `nvidia.com/gpu.product` on this node.

### GPU smoke test

`nvidia/cuda:12.3.1-base-ubuntu22.04` is seeded in the bootstrap registry for
this. Confirm each pool binds the hardware you expect:

```bash
# Should report the V100 (32768 MiB)
/home/k8s/kube/kubectl run gpu-test-v100 --restart=Never --rm -i \
  --image=hierophant.hierocracy.home:5000/nvidia/cuda:12.3.1-base-ubuntu22.04 \
  --overrides='{"spec":{"containers":[{"name":"c","image":"hierophant.hierocracy.home:5000/nvidia/cuda:12.3.1-base-ubuntu22.04","command":["nvidia-smi","--query-gpu=name,memory.total","--format=csv"],"resources":{"limits":{"nvidia.com/gpu":1}}}]}}'

# Should report a Tesla P4 (7680 MiB)
/home/k8s/kube/kubectl run gpu-test-p4 --restart=Never --rm -i \
  --image=hierophant.hierocracy.home:5000/nvidia/cuda:12.3.1-base-ubuntu22.04 \
  --overrides='{"spec":{"containers":[{"name":"c","image":"hierophant.hierocracy.home:5000/nvidia/cuda:12.3.1-base-ubuntu22.04","command":["nvidia-smi","--query-gpu=name,memory.total","--format=csv"],"resources":{"limits":{"nvidia.com/tesla-p4":1}}}]}}'
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
is rejected outright, `52-install-gpu-operator.sh` creates it explicitly.

### Node `role` labels

`52-install-gpu-operator.sh` pins the operator controller and the
node-feature-discovery master to `role=storage-node`, and the NFD worker to
`role=inference-node`. These come from Talos `machine.nodeLabels`:

| Label | Set in |
|---|---|
| `role=storage-node` | `configs/patch-worker-0..3.yaml` |
| `role=inference-node` | `configs/patch-inference-0.yaml` |

`52-install-gpu-operator.sh` also applies them with `kubectl` as a preflight, so
clusters built before those patches existed still work. Without the labels the
Helm install hangs on Pending pods until it times out.
