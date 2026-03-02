#!/bin/bash

# Destroy script for basic-setup.sh
# This script tears down all virsh objects created by basic-setup.sh

set -e

echo "=========================================="
echo "WARNING: This will destroy all VMs and storage"
echo "=========================================="
read -p "Are you sure you want to proceed? (yes/no): " response
echo ""

case "$response" in
    [Yy][Ee][Ss]|[Yy])
        echo "Proceeding with destruction..."
        ;;
    *)
        echo "Aborted."
        exit 0
        ;;
esac

# Destroy and undefine VMs
echo "Destroying VMs..."
for vm in control-0 control-1 control-2 worker-0 worker-1 worker-2 worker-3 inference-0 inference-1; do
    if sudo virsh dominfo "$vm" &>/dev/null; then
        echo "  Destroying VM: $vm"
        sudo virsh destroy "$vm" 2>/dev/null || true
        sudo virsh undefine "$vm" --remove-all-storage 2>/dev/null || true
    fi
done

# Stop and undefine networks
echo "Stopping and removing networks..."
for net in talos-nat talos-br mgmt-net lb-net; do
    if sudo virsh net-info "$net" &>/dev/null; then
        echo "  Removing network: $net"
        sudo virsh net-destroy "$net" 2>/dev/null || true
        sudo virsh net-undefine "$net" 2>/dev/null || true
    fi
done

# Remove physical bridges via nmcli
echo "Removing physical bridges..."
for br in br-mgmt br-app; do
    if nmcli connection show "$br" &>/dev/null; then
        echo "  Deleting bridge: $br"
        sudo nmcli connection delete "$br" 2>/dev/null || true
    fi
done

# Explicitly remove the VM application route if it exists
sudo ip route del 172.20.0.0/16 2>/dev/null || true
sudo ip route del 172.16.0.0/16 2>/dev/null || true

echo "Restoring management IP to physical interface enp5s0..."
# Ensure the physical interface is restored to its standalone state
sudo nmcli connection add type ethernet con-name enp5s0 ifname enp5s0 ipv4.method manual ipv4.addresses 192.168.1.101/24 ipv4.gateway 192.168.1.1 ipv4.dns "192.168.1.210,1.1.1.1,8.8.8.8" ipv4.dns-search "hierocracy,hierocracy.home" 2>/dev/null || \
sudo nmcli connection modify enp5s0 ipv4.method manual ipv4.addresses 192.168.1.101/24 ipv4.gateway 192.168.1.1 ipv4.dns "192.168.1.210,1.1.1.1,8.8.8.8" ipv4.dns-search "hierocracy,hierocracy.home"
sudo nmcli connection up enp5s0 || true

# Also ensure eno1 is available (though typically unconfigured by us)
echo "Restoring eno1 to managed state..."
sudo nmcli connection delete eno1 2>/dev/null || true
sudo nmcli connection add type ethernet con-name eno1 ifname eno1 ipv4.method disabled ipv6.method disabled 2>/dev/null || true
sudo nmcli connection up eno1 || true

# Cleanup legacy/previous bridge names if they exist
for br in br-master br-lb; do
    if nmcli connection show "$br" &>/dev/null; then
        echo "  Deleting legacy bridge: $br"
        sudo nmcli connection delete "$br" 2>/dev/null || true
    fi
done

echo "Removing veth and VLAN connections..."
for con in veth-mgmt-master veth-lb-master eno1.20; do
    if nmcli connection show "$con" &>/dev/null; then
        echo "  Deleting connection: $con"
        sudo nmcli connection delete "$con" 2>/dev/null || true
    fi
done

for slave in enp5s0-slave eno1-slave eno1.20-slave veth-mgmt-master-slave veth-mgmt-slave veth-lb-master-slave veth-lb-slave eno0-slave; do
    if nmcli connection show "$slave" &>/dev/null; then
        echo "  Deleting bridge slave: $slave"
        sudo nmcli connection delete "$slave" 2>/dev/null || true
    fi
done

# Delete volumes and destroy storage pools
echo "Destroying storage pools and volumes..."
# We only destroy the directory-based pools. Physical NVMe disks/partitions 
# are managed directly by UUID and don't need pool cleanup.
# HOWEVER, we should wipe the start of the partitions used by VMs to ensure
# they are seen as clean upon next build.
VM_NVME_PARTITIONS=(
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362996-part1" # worker-0
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362996-part2" # worker-1
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362996-part3" # worker-0-meta
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362996-part4" # worker-1-meta
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362935-part1" # worker-2
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362935-part2" # worker-3
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362935-part3" # worker-2-meta
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362935-part4" # worker-3-meta
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part1" # control-1
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362830-part2" # inference-0
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984-part1" # control-2
    "/dev/disk/by-id/nvme-Netac_NVMe_SSD_250GB_AA20250805250G362984-part2" # inference-1
)

echo "Wiping VM NVMe partitions..."
for part in "${VM_NVME_PARTITIONS[@]}"; do
    if [ -b "$part" ]; then
        echo "  Wiping $part..."
        sudo dd if=/dev/zero of="$part" bs=1M count=100 oflag=direct status=none || true
    fi
done

for pool in CONTROLLER; do
    if sudo virsh pool-info "$pool" &>/dev/null; then
        echo "  Removing pool: $pool"
        # Delete all volumes in the pool
        sudo virsh vol-list "$pool" 2>/dev/null | tail -n +3 | awk '{print $1}' | while read vol; do
            if [ -n "$vol" ]; then
                echo "    Deleting volume: $vol"
                sudo virsh vol-delete "$vol" --pool "$pool" 2>/dev/null || true
            fi
        done
        # Destroy and undefine the pool
        sudo virsh pool-destroy "$pool" 2>/dev/null || true
        sudo virsh pool-undefine "$pool" 2>/dev/null || true
    fi
done

# Clean up generated XML files
echo "Removing generated XML files..."
rm -f talos-nat.xml talos-br.xml mgmt-net.xml lb-net.xml

# Clean up NAT and Forwarding rules
for subnet in 10.0.0.0/24 172.20.0.0/16; do
    sudo iptables -t nat -D POSTROUTING -s "$subnet" ! -d "$subnet" -j MASQUERADE 2>/dev/null || true
    sudo iptables -D FORWARD -s "$subnet" -j ACCEPT 2>/dev/null || true
    sudo iptables -D FORWARD -d "$subnet" -j ACCEPT 2>/dev/null || true
done

# Clean up specific interface forwarding rules
for iface in br-app talos-bridge; do
    sudo iptables -D FORWARD -i "$iface" -o enp5s0 -j ACCEPT 2>/dev/null || true
    sudo iptables -D FORWARD -i enp5s0 -o "$iface" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
done

echo "Removing persistent sysctl configurations..."
sudo rm -f /etc/sysctl.d/98-network-optimization.conf /etc/sysctl.d/98-arp-optimization.conf /etc/sysctl.d/99-ip-forward.conf /etc/sysctl.d/99-k8s-routing.conf /etc/sysctl.d/99-bridge-nf.conf

# Revert runtime sysctl settings (optional, but good for completeness)
for iface in all default enp5s0 eno1 br-app; do
    sudo sysctl -w net.ipv4.conf.${iface}.arp_ignore=0 2>/dev/null || true
    sudo sysctl -w net.ipv4.conf.${iface}.arp_announce=0 2>/dev/null || true
    sudo sysctl -w net.ipv4.conf.${iface}.rp_filter=1 2>/dev/null || true
    sudo sysctl -w net.ipv4.conf.${iface}.arp_filter=0 2>/dev/null || true
done

echo ""
echo "=========================================="
echo "Cleanup complete!"
echo "=========================================="