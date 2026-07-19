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

   # Pull from Talos Image Factory
   podman pull \
       "factory.talos.dev/installer/${SCHEMATIC_ID}:${TALOS_VERSION}"

   # Retag and push to local registry
   podman tag \
       "factory.talos.dev/installer/${SCHEMATIC_ID}:${TALOS_VERSION}" \
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

# 3. Run full enrollment (applies config; node reboots onto static 192.168.5.31)
./45-enroll-external-node.sh
#    If the MAC isn't set, pass the maintenance IP explicitly:
#    INFERENCE_MAINT_IP=192.168.0.NN ./45-enroll-external-node.sh

# 4. Install GPU Operator and label the node
./52-install-gpu-operator.sh
./55-label-gpu-nodes.sh
```
