#!/bin/bash

# This script resets the network configuration on hierophant and manages the VMs network state.
# It targets:
# 1. nmcli connections (physical, vlan, bridges)
# 2. iptables rules
# 3. sysctl network optimizations
# 4. libvirt virtual networks

echo "Starting full network reset on hierophant..."

# 1. Libvirt Network Reset
echo "Stopping and undefining libvirt networks..."
for net in talos-nat lb-net default; do
    sudo virsh net-destroy "$net" 2>/dev/null
    sudo virsh net-undefine "$net" 2>/dev/null
done

# 2. Virtual Machine Reset
echo "Stopping all running VMs to release virtual interfaces..."
# We don't undefine them, just stop them so the bridges/taps can be cleaned up.
running_vms=$(sudo virsh list --name --state-running)
if [ -n "$running_vms" ]; then
    for vm in $running_vms; do
        echo "Stopping VM: $vm"
        sudo virsh destroy "$vm" 2>/dev/null
    done
fi

# 3. NMCLI Connection Cleanup
echo "Cleaning up nmcli connections..."
# Comprehensive list of connections used in setup and previous iterations
for con in br-mgmt br-app enp5s0-slave eno1-slave eno1 br-master br-lb veth-mgmt-master veth-mgmt-slave veth-lb-master veth-lb-slave eno0-slave eno1.20 eno1.20-slave enp5s0; do
    sudo nmcli connection delete "$con" 2>/dev/null && echo "Deleted connection: $con" || true
done

# 4. Bridge and Interface cleanup (forced)
echo "Forcing removal of bridges if they still exist..."
for br in br-app talos-bridge virbr0; do
    sudo ip link set "$br" down 2>/dev/null
    sudo ip link delete "$br" type bridge 2>/dev/null && echo "Removed bridge: $br" || true
done

# 5. IPTables Reset
echo "Resetting iptables to default (ACCEPT all)..."
sudo iptables -P INPUT ACCEPT
sudo iptables -P FORWARD ACCEPT
sudo iptables -P OUTPUT ACCEPT
sudo iptables -t nat -F
sudo iptables -t mangle -F
sudo iptables -F
sudo iptables -X

# 6. Sysctl Reset
echo "Removing persistent network optimizations..."
sudo rm -f /etc/sysctl.d/98-network-optimization.conf
sudo rm -f /etc/sysctl.d/99-k8s-routing.conf
sudo rm -f /etc/sysctl.d/99-bridge-nf.conf

# Re-apply default sysctl settings (minimal reset)
sudo sysctl -w net.ipv4.ip_forward=0
sudo sysctl -w net.ipv4.conf.all.rp_filter=1
sudo sysctl -w net.ipv4.conf.default.rp_filter=1

# 7. Restore basic management connectivity
echo "Restoring basic management connection on enp5s0..."
# This ensures the user doesn't lose access to the host if they are on SSH.
sudo nmcli connection add type ethernet con-name enp5s0 ifname enp5s0 ipv4.method manual ipv4.addresses 192.168.1.101/24 ipv4.gateway 192.168.1.1 ipv4.dns "192.168.1.210,1.1.1.1,8.8.8.8"
sudo nmcli connection up enp5s0

echo "Reset complete."
echo "Note: Virtual machines have been stopped. Use 07-config-vm-net.sh and your VM start scripts to restore the environment."
