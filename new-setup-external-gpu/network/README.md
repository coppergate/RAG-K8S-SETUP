# Flat-LAN networking — new-setup-external-gpu

Everything the cluster needs lives on the physical LAN (`192.168.0.0/16`). Every
node, host, and the dev VM is a first-class LAN citizen, so `talosctl`/`kubectl`
reach the cluster from anywhere with **no routes, NAT, VLANs, or libvirt hooks.**

## Topology

```
                 192.168.0.0/16   (router / DHCP / gateway @ 192.168.0.1)
                           │   DHCP pool: 192.168.0.2 – 192.168.0.254
                           │   (single switch — everything plugged in)
   ┌───────────────────────┼──────────────────────────┬────────────────────┐
 hierophant              hegemon                   GPU server         (other LAN
 br-lan over enp5s0      br-lan over eno1          bare-metal Talos     clients)
 host 192.168.1.101/16   host 192.168.1.100/16    eth0 192.168.5.31/16
   ├─ control-0/1/2        └─ dev-fedora VM
   └─ worker-0..3             192.168.1.50/16
   (libvirt net 'lan')     (libvirt net 'lan')
```

`eno1` on hierophant is left idle (spare / future bond).

## Addressing (all /16, gateway 192.168.0.1)

| Role | Address |
|---|---|
| router / gateway / DHCP | `192.168.0.1` |
| DNS server | `192.168.1.210` |
| hierophant | `192.168.1.101` |
| hegemon | `192.168.1.100` |
| dev-fedora | `192.168.1.50` |
| **CP VIP (kube-apiserver)** | `192.168.5.10` |
| control-0 / 1 / 2 | `192.168.5.11 / .12 / .13` |
| worker-0 / 1 / 2 / 3 | `192.168.5.21 / .22 / .23 / .24` |
| inference-0 (GPU) | `192.168.5.31` |
| PureLB / LoadBalancer pool | `192.168.5.200 – 192.168.5.250` |

The router's DHCP only hands out `192.168.0.x`, so the static `192.168.1.x` and
`192.168.5.x` ranges never collide with it.

## Boot/maintenance addressing

Nodes boot the Talos ISO into maintenance mode and DHCP a temporary
`192.168.0.x` lease from the router. The setup scripts discover that address by
MAC via ARP (`getNodeIP` in `utils.sh`), apply the config, and the node reboots
onto its static `192.168.5.x` address. No second DHCP server is needed.

## Run order

This runs in three phases. The key subtleties: the two hierophant network
scripts are **also invoked by `../config-cluster.sh`** (step 2), and the
dev-fedora step must come **after** the cluster exists (it pulls the kubeconfig).

### Phase 1 — hierophant, then build the cluster

Run from the **console/IPMI, not SSH** — the host IP moves onto `br-lan` and the
link briefly drops.

```bash
cd /mnt/hegemon-share/share/code/kubernetes-setup/new-setup-external-gpu
sudo bash network/hierophant-host-net.sh      # br-lan over enp5s0 (brief blip)
sudo bash network/hierophant-libvirt-net.sh   # libvirt 'lan' network

sudo FRESH_INSTALL=true bash ./config-cluster.sh
```

You *can* skip the two manual calls — `config-cluster.sh` runs them itself
(idempotently) in step 2. But doing `hierophant-host-net.sh` from the console
**first** performs the IP-onto-bridge cutover cleanly, so the build isn't what
drops your session; the in-script re-run is then a no-op.

### Phase 2 — hegemon (management access; can run in parallel with the build)

Also from the console — hegemon's host IP moves onto `br-lan` too.

```bash
sudo bash network/hegemon-host-net.sh

# Point the dev-fedora VM at the LAN and reboot it (also printed by the script):
sudo virsh attach-interface dev-fedora network lan --model virtio --config
sudo virsh reboot dev-fedora
```

### Phase 3 — dev-fedora (AFTER the cluster is bootstrapped)

Run inside the dev-fedora VM. This `scp`s the kubeconfig/talosconfig off
hierophant and verifies `kubectl get nodes`, so the control plane must be up.

```bash
bash network/dev-fedora-net.sh
```

### Summary

| Phase | Host | Action |
|---|---|---|
| 1 | hierophant | `hierophant-host-net.sh` → `hierophant-libvirt-net.sh` → `config-cluster.sh` |
| 2 | hegemon | `hegemon-host-net.sh` + `virsh` attach dev-fedora NIC to `lan` + reboot VM |
| 3 | dev-fedora | `dev-fedora-net.sh` (after the cluster is up) |

> ⚠ The host-net scripts move the host IP onto the bridge, briefly dropping the
> link — run them from a console/IPMI session, or detached with `nohup`.
>
> The GPU inference node is **not** part of `config-cluster.sh`; enroll it
> separately with `../45-enroll-external-node.sh` after setting `inference_0_mac`.

## DNS records for `hierocracy.home`

Reconcile these against what already exists in the zone on `192.168.1.210`:

```
; --- infra hosts ---
router.hierocracy.home.        A  192.168.0.1
ns.hierocracy.home.            A  192.168.1.210
hierophant.hierocracy.home.    A  192.168.1.101
hegemon.hierocracy.home.       A  192.168.1.100
dev-fedora.hierocracy.home.    A  192.168.1.50

; --- cluster API + registry ---
k8s-api.hierocracy.home.       A  192.168.5.10     ; CP VIP (kube/talos endpoint)
registry.hierocracy.home.      A  192.168.1.101    ; bootstrap registry :5000

; --- cluster nodes ---
control-0.hierocracy.home.     A  192.168.5.11
control-1.hierocracy.home.     A  192.168.5.12
control-2.hierocracy.home.     A  192.168.5.13
worker-0.hierocracy.home.      A  192.168.5.21
worker-1.hierocracy.home.      A  192.168.5.22
worker-2.hierocracy.home.      A  192.168.5.23
worker-3.hierocracy.home.      A  192.168.5.24
inference-0.hierocracy.home.   A  192.168.5.31

; --- ingress wildcard (services use *.hierocracy.home) ---
*.hierocracy.home.             A  192.168.5.200    ; Traefik / PureLB ingress IP
```

`192.168.5.200` is the first address of the PureLB pool — point the wildcard at
whatever address Traefik's `LoadBalancer` Service actually takes.

## What this replaces

The old design used three private subnets (`talos-nat` 10.0.0.0/24, `lb-net`
172.20.0.0/16 over eno1 VLAN 20, `agent-link` 172.16.0.0/16) plus a
hegemon↔hierophant nftables relay to reach the cluster from dev-fedora. All of
that — NAT, VLAN, `br-app`, the `arp_ignore`/`rp_filter` tuning, the enrollment
`dnsmasq`, and the `remote-access-configuration/` relay — is gone.
