# Remote Access Configuration

Enables direct `kubectl` access and native Go E2E test execution from `dev-fedora`
to the Talos Kubernetes cluster, without SSH to `junie@hierophant` or Podman.

## Network Topology

```
dev-fedora (VM on hegemon)
  enp8s0: 172.16.1.10/16  ←→  virbr-agent bridge on hegemon (172.16.1.1)
  enp2s0: 192.168.122.147  ←→  virbr0 NAT bridge on hegemon (default route)

hegemon (bare metal)
  eno1:    192.168.1.100    ←→  LAN
  virbr-agent: 172.16.1.1  ←→  agent-link bridge (dev-fedora lives here)

hierophant (bare metal, management host)
  enp5s0:  192.168.1.101   ←→  LAN
  talos-bridge: 10.0.0.1   ←→  Talos node network

Talos cluster VIP: 10.0.0.15:6443 (kube-apiserver)
```

## Packet Path: dev-fedora → Kubernetes API

```
dev-fedora (172.16.1.10)
  → route 10.0.0.0/24 via 172.16.1.1 (enp8s0)
  → hegemon virbr-agent bridge
  → nftables: accept forward (guest_output) + masquerade src to 192.168.1.100
  → route 10.0.0.0/24 via 192.168.1.101 (eno1) on hegemon
  → hierophant enp5s0 (192.168.1.100 → 10.0.0.15)
  → nftables: accept new connections into talos-bridge (guest_input) on hierophant
  → talos-bridge → 10.0.0.15:6443
```

Return path is symmetric: 10.0.0.15 → 10.0.0.1 (hierophant) → 172.16.0.0/16 route
→ hegemon (192.168.1.100) → conntrack un-NAT → virbr-agent → dev-fedora.

## Files

| File | Run on | Purpose |
|---|---|---|
| `dev-fedora-setup.sh` | dev-fedora | Persist route + kubeconfig |
| `hegemon-setup.sh` | hegemon | Persist route + install libvirt hook |
| `hegemon-libvirt-hook.sh` | hegemon (via setup) | nftables rules on network start |
| `hierophant-setup.sh` | hierophant | Install libvirt hook |
| `hierophant-libvirt-hook.sh` | hierophant (via setup) | nftables rules on network start |

## Installation

Run each setup script once with sudo on the appropriate host:

```bash
# On dev-fedora (no sudo needed for nmcli, but sudo for mkdir if needed):
bash dev-fedora-setup.sh

# On hegemon:
sudo bash hegemon-setup.sh

# On hierophant:
sudo bash hierophant-setup.sh
```

## kubeconfig

`dev-fedora-setup.sh` copies the kubeconfig from hierophant and writes
`~/.kube/config-talos`. It also appends an export to `~/.bashrc` so kubectl
picks it up automatically in new shells.

To use immediately in the current shell:
```bash
export KUBECONFIG=~/.kube/config-talos
kubectl cluster-info
```

## Persistence

- **Routes**: Persisted via NetworkManager (`nmcli connection modify`).
  Active on next boot without any manual step.

- **nftables rules**: Libvirt regenerates `ip libvirt_network` table on every
  network start. Custom rules are re-applied via libvirt network hooks
  (`/etc/libvirt/hooks/network`), which fire with action `started` after
  libvirt finishes configuring the network.

## Removing junie dependency

With this configuration in place:
- `kubectl` runs directly on dev-fedora with `~/.kube/config-talos`
- Go E2E driver runs with `go run .` (no Podman container)
- `run-e2e-on-hierophant.sh` kubectl paths need updating to use local kubectl
  and `KUBECONFIG=~/.kube/config-talos`

The `junie` user on hierophant is no longer required for test execution.
