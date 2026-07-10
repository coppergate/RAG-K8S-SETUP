# External GPU Node Setup Guide

This document covers the steps specific to enrolling the physical GPU inference node
into the `new-setup-external-gpu` cluster. The base cluster (control-plane + workers)
is set up by `config-cluster.sh` first.

---

## Network Topology

```
                    ┌─────────────────────────────┐
                    │  hierophant                  │
                    │  enp5s0: 192.168.1.101/24    │
                    │  eno1.20 → br-app            │
                    │  br-app: 172.20.0.1/16       │
                    └────────┬────────────────┬────┘
                             │ enp5s0         │ eno1 (VLAN 20 tagged)
                             │                │
                        ─────┴──────    ──────┴──────
                          Switch 1       Switch 1
                        (192.168.1.x)  (trunk VLAN 20)
                             │                │
                        ─────┘       ─────────┴─────────
                                       inter-switch trunk
                                       (VLAN 20 allowed)
                                     ─────────┴─────────
                                           Switch 2
                                      (access port VLAN 20)
                                           │
                                     ──────┴──────
                                       GPU node
                                     NIC: 172.20.1.120/16
                                     GW:  192.168.1.1
```

### Switch Configuration Requirements

**Switch 1 (main, connected to hierophant):**
| Port | Config |
|------|--------|
| Port connected to `eno1` | Trunk, VLAN 20 allowed (tagged) |
| Inter-switch uplink to Switch 2 | Trunk, VLAN 20 allowed (tagged) |

**Switch 2 (secondary, connected to GPU node):**
| Port | Config |
|------|--------|
| Inter-switch uplink from Switch 1 | Trunk, VLAN 20 allowed (tagged) |
| Port connected to GPU node NIC | **Access port, VLAN 20 (untagged)** |

> With an access port on VLAN 20 for the GPU node, no VLAN configuration is needed
> in Talos. The node just configures a plain IP (172.20.1.120) on its physical NIC.

---

## Pre-Enrollment Checklist

- [ ] `inference_0_mac` set in `05-MAC-addresses.sh` to GPU node's actual NIC MAC
- [ ] `hardwareAddr` in `configs/patch-inference-0.yaml` matches the same MAC
- [ ] Install disk confirmed (see "Identifying the Disk" below)
- [ ] Installer image confirmed in registry (see "Talos Image" below)
- [ ] Cluster is healthy (`kubectl get nodes` shows control-plane + workers Ready)
- [ ] GPU node is booted from Talos USB and in maintenance mode

### Finding the GPU Node's MAC Address
Options (before Talos boot):
- Check the NIC's physical label or the motherboard BIOS/UEFI → Network section
- Boot a live Linux USB, run: `ip link show`

Options (after Talos USB boot, in maintenance mode):
- The Talos console UI shows the interface MAC address
- From hierophant, query via dnsmasq lease log:
  ```bash
  sudo cat /var/log/dnsmasq-br-app-enrollment.log | grep DHCP
  ```

---

## Identifying the Install Disk

After the GPU node boots from the Talos USB (maintenance mode), find its disk:

```bash
sudo /home/k8s/talos/talosctl disks \
    --insecure \
    --nodes 172.20.1.120 \
    --endpoints 172.20.1.120
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

For automated GPU node provisioning without a USB drive, set up PXE boot:

### Prerequisites
- A TFTP server on hierophant (or a dedicated machine)
- The GPU node's NIC configured to PXE boot (BIOS setting)
- The inter-switch trunk must allow the VLAN 20 PXE broadcast through

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

4. **Add dnsmasq PXE options** to `/etc/dnsmasq.d/br-app-enrollment.conf`:
   ```
   # Enable PXE boot
   dhcp-boot=pxelinux.0
   enable-tftp
   tftp-root=/var/lib/tftpboot
   ```

5. **Firewall:** Allow TFTP (port 69/UDP) on the `br-app` interface:
   ```bash
   sudo firewall-cmd --add-port=69/udp --zone=trusted --permanent
   sudo firewall-cmd --reload
   ```

> **Note:** PXE boot broadcasts are confined to the VLAN segment. The GPU node
> on Switch 2 VLAN 20 access port will broadcast DHCP/PXE requests that traverse
> the VLAN 20 trunk to hierophant's br-app dnsmasq.

---

## Enrollment Steps (Summary)

```bash
# On hierophant:
cd /mnt/hegemon-share/share/code/kubernetes-setup/new-setup-external-gpu

# 1. Set the GPU node MAC (after finding it via console or BIOS)
vi 05-MAC-addresses.sh          # set inference_0_mac
vi configs/patch-inference-0.yaml  # set hardwareAddr, confirm disk

# 2. Refresh the br-app dnsmasq with the correct MAC
sudo ./07-config-vm-net.sh

# 3. Boot GPU node from Talos USB — it should get 172.20.1.120 via DHCP

# 4. Run full enrollment
./45-enroll-external-node.sh

# 5. Install GPU Operator and label the node
./52-install-gpu-operator.sh
./55-label-gpu-nodes.sh
```
