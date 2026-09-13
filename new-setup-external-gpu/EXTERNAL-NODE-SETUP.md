# External GPU Node Setup Guide

> **Ownership note (2026-08-09).** The NVIDIA GPU Operator is no longer installed
> from this repo. `52-install-gpu-operator.sh` and `55-label-gpu-nodes.sh` were
> **deleted**; their logic now lives in
> **`complete-build/infrastructure/nvidia-operator.sh`**, which runs automatically
> as Step 1.9 of `setup-complete.sh` — before the RAG stack, because it installs
> the device plugin that advertises `nvidia.com/gpu`. GPU workloads request that
> resource, so deploying the RAG stack first leaves them `Pending`.
>
> The split is: **this repo owns Talos-level node provisioning** (machine config,
> kernel modules, driver extensions, enrolment); **complete-build owns every
> Kubernetes object** (operator Helm release, RuntimeClass, device-plugin
> ConfigMap, validation-fix DaemonSet, GPU node labels).
>
> Where any text below says `52-install-gpu-operator.sh`, read
> `complete-build/infrastructure/nvidia-operator.sh`.

> **Hardware change (2026-09-13).** The 2x Tesla P4 8GB cards were removed and a
> second V100 32GB added. `inference-0` is now a **uniform two-card V100 32GB
> node**, workloads request `nvidia.com/gpu: 1` normally, and the per-card UUID
> pinning this guide used to document is **retired** — the labels are gone and
> `nvidia-operator.sh` actively unsets them.
>
> The mixed-pool analysis, including the two approaches that failed, is preserved
> verbatim in **Appendix A** because its three core findings are still true. Read
> it before reintroducing UUID pinning or adding a non-matching card.

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
- [ ] Install disk confirmed and written as a `diskSelector` (see
      "Identifying the Install Disk" below). Do NOT use a `/dev/sdX` name.
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

> **Do not name the install disk by device path.** This is how the node was
> repeatedly installed onto its own boot stick (see the failure note at the end
> of this section).

After the GPU node boots from the Talos USB (maintenance mode) it gets a temporary
`192.168.0.x` DHCP lease from the router. Using that maintenance IP:

```bash
cd /mnt/hegemon-share/share/code/kubernetes-setup/new-setup-external-gpu
INFERENCE_MAINT_IP=<maintenance-ip> ./40-apply-inference-config.sh --list-disks
```

This applies nothing. It prints every block device with its transport, size,
model and serial, positively identifies the Talos boot medium, and emits a
ready-to-paste `diskSelector` block, e.g.:

```yaml
    diskSelector:
      serial: "S5Y2NG0R512345K"
```

Paste that under `machine.install` in `configs/patch-inference-0.yaml`,
replacing the `REPLACE_ME` placeholder. Then run the apply with no arguments.

If you want the raw resource instead, the command is:

```bash
/home/k8s/talos/talosctl get disks \
    --insecure \
    --nodes <maintenance-ip> \
    --endpoints <maintenance-ip>
```

> Note: earlier revisions of this document said `talosctl disks`. That
> subcommand **does not exist in Talos v1.12** — it was removed in favour of the
> `get disks` resource query above. Anyone following the old instruction got
> "unknown command" and moved on without confirming the disk, which is part of
> why the wrong-disk install went unnoticed.

### Why not `/dev/sda`

This node has no stable device names at install time. It boots from a USB stick,
and the stick is a USB-attached SCSI device, so the kernel gives it the **first**
`sd*` name — `/dev/sda`. The internal SATA SSD becomes `/dev/sdb`; an NVMe SSD is
not an `sd*` device at all. `configs/patch-inference-0.yaml` used to say
`disk: /dev/sda` with `wipe: true`, so the installer targeted the medium it was
running from rather than the local drive.

`machine.install.diskSelector` matches on hardware attributes instead
(`serial`, `wwid`, `model`, `size`, `type`, `busPath`). Per the Talos v1.12
configuration reference it *"Always has priority over `disk`"*, so it also
overrides the `disk: /dev/vda` that `configs/machine-patches.yaml` sets for the
libvirt VMs. Prefer `serial` — it is unique per drive.

`40-apply-inference-config.sh` re-resolves the selector against the node's live
inventory immediately before applying, and refuses to proceed if it resolves to
the boot medium, a CD-ROM, a read-only device, nothing, or more than one disk.
Override with `ALLOW_UNSAFE_INSTALL_DISK=true` only if you mean it.

### After the install: pull the stick

Once the config is applied the node reboots to install. If the BIOS boot order
still prefers USB and the stick is still inserted, the machine boots the ISO
again and returns to **maintenance mode** — which looks exactly like the install
having failed. Remove the stick (or fix the boot order) before that first reboot.

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
vi configs/patch-inference-0.yaml  # set deviceSelector.hardwareAddr

# 1b. Identify the install disk (node must be booted into maintenance mode).
#     Prints the inventory and the diskSelector block to paste. Applies nothing.
INFERENCE_MAINT_IP=192.168.0.NN ./40-apply-inference-config.sh --list-disks

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
 ${TALOS_ROOT}/talosctl --talosconfig "${TALOSCONFIG}" \
  --nodes "${INFERENCE_IP_0}" --endpoints "${CP_VIP}" \
  read /proc/modules | grep nvidia

# Expect ext-nvidia-persistenced in a Running/OK state
 ${TALOS_ROOT}/talosctl --talosconfig "${TALOSCONFIG}" \
  --nodes "${INFERENCE_IP_0}" --endpoints "${CP_VIP}" \
  services
```

To re-apply on an already-enrolled node without re-running enrollment:

```bash
 ${TALOS_ROOT}/talosctl --talosconfig "${TALOSCONFIG}" \
  --nodes "${INFERENCE_IP_0}" --endpoints "${CP_VIP}" \
  patch machineconfig \
  --patch "@configs/post-inference-talos.yaml" \
  --mode=reboot
```

### GPU pool — two identical V100 32GB cards

**Verified on the live node 2026-09-13.** `inference-0` holds two identical GPUs:

| idx | UUID | Reported name | Memory | Compute | PCI |
|---|---|---|---|---|---|
| 0 | `GPU-ce06ba79-…47c6ecb` | `GV100GL [Tesla PG500-216]` | 32768 MiB | `7.0` | `05:00.0` |
| 1 | `GPU-1b623f18-…f03761e5` | `GV100GL [Tesla PG500-216]` | 32768 MiB | `7.0` | `81:00.0` |

Driver `580.126.16`. The **2x Tesla P4 8GB cards have been physically removed**,
and with them the entire heterogeneous workaround this guide used to document.
That material is preserved in
[Appendix A — Historical: the mixed V100+P4 pool (through 2026-09)](#appendix-a--historical-the-mixed-v100p4-pool-through-2026-09);
read it before reintroducing any of it.

> **`Tesla PG500-216` is a board code, not a marketing name.** The driver falls
> back to it when it has no SKU string, which is why `nvidia-smi` never prints
> "V100" on this node. **Do not match on the name** — classify on memory and
> compute capability. `nvidia-operator.sh` does exactly that, and the node label
> it publishes is deliberately called `gpu-32gb-count` rather than
> `gpu-v100-count` for the same reason.

Because the pool is uniform, `nvidia.com/gpu` is now an honest, fungible
resource: `allocatable` is 2 and the scheduler cannot hand a workload the "wrong"
card. GFD's `nvidia.com/gpu.*` labels should also be truthful again — but
**record them, do not gate on them**; they were observed lying on this node while
the pool was mixed (Appendix A).

#### Interconnect: `SYS`, no NVLink

`nvidia-smi topo -m`, same probe:

```text
        GPU0  GPU1  CPU Affinity   NUMA Affinity
GPU0     X    SYS   0-11,24-35     0
GPU1    SYS    X    12-23,36-47    1
```

`SYS` means the path between the cards traverses PCIe **and** the cross-socket
interconnect (QPI/UPI) — the two cards sit on different NUMA nodes. There is no
NVLink. This shapes what is worth running:

- **One card per pod is the right topology.** It is what the RAG stack uses.
- **Tensor parallelism is penalised here.** A TP job all-reduces activations
  every layer across that link. Avoid it on this hardware.
- **Layer-split across both cards is fine.** llama.cpp/Ollama's default split
  mode passes activations across the boundary once per split point — a small
  transfer that this link handles comfortably. This is the supported route to a
  model larger than 32 GB: give one pod `nvidia.com/gpu: 2` and set
  `OLLAMA_SCHED_SPREAD=1`. Nothing does this today.

`SYS` rather than `NODE`/`PHB` is also worth a glance at the physical build — if
both cards can be moved onto host bridges under one socket, do it during a
maintenance window.

### Requesting a GPU

Request it the ordinary way. **Do not pin cards by UUID** (see Appendix A for
what that was and why it is gone):

```yaml
resources:
  limits:
    nvidia.com/gpu: 1
runtimeClassName: nvidia
nodeSelector:
  role: inference-node
tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
```

Four things all have to be right, and three of them fail silently:

| Item | Why |
|---|---|
| `nvidia.com/gpu` in **`limits`** | It is an *extended resource*: Kubernetes copies the limit into `requests`, and the two may not differ. Setting only `requests` is invalid. |
| `runtimeClassName: nvidia` | Selects the NVIDIA container runtime, which maps the device and driver libraries in. Talos sets containerd's `default_runtime_name=nvidia` too, but naming it is explicit and survives that changing. |
| `nodeSelector: role=inference-node` | Expresses intent. |
| the **toleration** | `inference-0` is tainted `nvidia.com/gpu=present:NoSchedule` by `complete-build/scripts/setup-node-labels.sh`. Without a toleration the pod is simply never scheduled there. |

There are **no `hierocracy.home/gpu-*-uuid` labels** to read.
`nvidia-operator.sh` actively unsets them, because dropping a label from a script
does not remove it from a live Node.

### GPU smoke test

`nvidia-smi` cannot be run directly on Talos, so probe through a throwaway pod.

**Run it in a namespace that permits privileged pods.** The `default` namespace
is admitted at PodSecurity `baseline` on this cluster, which rejects
`privileged`, `hostPID` and `hostPath` — `kube-system` or `gpu-operator` work.
(This exact mistake sat undetected in `nvidia-operator.sh`'s own probe until
2026-09-13: it omitted `-n`, so discovery had never once succeeded and the script
silently used hardcoded fallbacks.)

```bash
# Inventory: expect TWO rows, 32768 MiB and compute_cap 7.0 on both
/home/k8s/kube/kubectl run gpu-probe -n kube-system --rm -i --restart=Never \
  --image=hierophant.hierocracy.home:5000/busybox:1.36 \
  --overrides='{"spec":{"nodeName":"inference-0","hostPID":true,
    "tolerations":[{"operator":"Exists"}],
    "containers":[{"name":"p","image":"hierophant.hierocracy.home:5000/busybox:1.36",
      "command":["chroot","/host","/usr/local/bin/nvidia-smi",
        "--query-gpu=index,uuid,name,memory.total,compute_cap,driver_version,pci.bus_id",
        "--format=csv"],
      "securityContext":{"privileged":true},
      "volumeMounts":[{"name":"h","mountPath":"/host"}]}],
    "volumes":[{"name":"h","hostPath":{"path":"/"}}]}}'
```

```bash
# Interconnect
/home/k8s/kube/kubectl run gpu-topo -n kube-system --rm -i --restart=Never \
  --image=hierophant.hierocracy.home:5000/busybox:1.36 \
  --overrides='{"spec":{"nodeName":"inference-0","hostPID":true,
    "tolerations":[{"operator":"Exists"}],
    "containers":[{"name":"p","image":"hierophant.hierocracy.home:5000/busybox:1.36",
      "command":["chroot","/host","/usr/local/bin/nvidia-smi","topo","-m"],
      "securityContext":{"privileged":true},
      "volumeMounts":[{"name":"h","mountPath":"/host"}]}],
    "volumes":[{"name":"h","hostPath":{"path":"/"}}]}}'
```

Then check what Kubernetes believes:

```bash
# Expect 2
/home/k8s/kube/kubectl get node inference-0 \
  -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}'

# Expect gpu-total-count=2, gpu-32gb-count=2, gpu-inventory-rev=2,
# and NO gpu-p4-* / gpu-heterogeneous / gpu-pool-mixed / gpu-*-uuid labels
/home/k8s/kube/kubectl get node inference-0 -o json | python3 -c '
import json,sys
l = json.load(sys.stdin)["metadata"]["labels"]
for k in sorted(l):
    if "gpu" in k.lower(): print(f"{k}={l[k]}")'
```

**If `allocatable` reads 0 while the device-plugin pods are `Running`**, suspect
an empty `sharing: timeSlicing: {}` block in the device-plugin ConfigMap — it
fails config parsing with "no resources specified" and the plugin refuses to
start. See `complete-build/infrastructure/nvidia-operator.sh`.
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

---

## Appendix A — Historical: the mixed V100+P4 pool (through 2026-09)

> **ARCHIVED 2026-09-13. None of this describes the current cluster.**
>
> `inference-0` ran 1x Tesla V100 32GB (`sm_70`) + 2x Tesla P4 8GB (`sm_61`) as a
> single untyped `nvidia.com/gpu` pool of 3. Because a plain resource request
> could hand a 32B model an 8 GB card, workloads pinned a specific card by UUID
> via `NVIDIA_VISIBLE_DEVICES` and deliberately requested **no** resource —
> which bypassed scheduler accounting entirely.
>
> **The P4s were physically removed and replaced by a second V100 32GB.** The
> pool is uniform, ordinary `nvidia.com/gpu: 1` requests are correct, and the
> UUID labels are gone and actively unset. The serving stack stayed on Ollama
> (see `complete-build/documentation/OPERATIONS.md` §4.4.2).
>
> **This is kept, not deleted, for three findings that remain true and are each
> worth a day of rediscovery:**
>
> 1. **`NVIDIA_VISIBLE_DEVICES` cannot restrict the operator's own DaemonSets.**
>    They run privileged and NVML enumerates every device regardless.
> 2. **The device plugin's named `resources:` field is unimplemented** (v0.19.3
>    logs `Customizing the 'resources' field is not yet supported in the config.
>    Ignoring...`). Per-product resource names are therefore impossible; a mixed
>    pool *cannot* be split above the plugin.
> 3. **GFD models a mixed node as one product/memory/compute triple** and will
>    describe all cards with whichever it picks — observed reporting
>    `Tesla-P4 / 7680 MiB / 6.1` and hiding the V100 even with
>    `MIG_STRATEGY=none` correctly set. This is why `nvidia.com/gpu.*` labels
>    are still treated as *recorded, not authoritative* on this node.
>
> If a non-uniform card is ever added back, start here — and note that
> `nvidia-operator.sh` warns loudly when `gpu-32gb-count` differs from
> `gpu-total-count`, which is the signal that this appendix has become relevant
> again.

### Historical: heterogeneous GPUs — a mixed, untyped pool

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

#### Historical: if you do want a V100-only pool

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

### Historical: targeting a specific GPU by UUID

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

#### Historical: which card for which job

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

### Historical: GPU smoke test (mixed pool)

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
