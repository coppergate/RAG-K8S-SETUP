#!/bin/bash

# Diagnostic script for hierophant network and VM status
echo "=== Host Network Interfaces ==="
ip addr show enp5s0
ip addr show br-app
ip addr show talos-bridge

echo -e "\n=== Bridge Membership ==="
bridge link show

echo -e "\n=== ARP/Neighbor Table (172.20.x.x) ==="
ip neigh show dev br-app

echo -e "\n=== VM Status ==="
sudo virsh list --all

echo -e "\n=== Libvirt Network Status ==="
sudo virsh net-list --all

echo -e "\n=== IPTables Forwarding Rules (Counters) ==="
sudo iptables -nvL FORWARD | grep -E 'br-app|talos-bridge|172.20|10.0.0'

echo -e "\n=== Routing Table ==="
ip route show

echo -e "\n=== Checking for Martian Packets (RP Filter drops) ==="
sudo dmesg | grep -i "martian" | tail -n 20

echo -e "\n=== Connectivity Test from Host ==="
echo "Pinging br-app gateway (172.20.0.1)..."
ping -c 1 172.20.0.1 > /dev/null && echo "  SUCCESS" || echo "  FAILED"
echo "Pinging a known VM IP (if ARP exists)..."
# Try to ping the first 172.20.1.x IP found in ARP
TARGET_IP=$(ip neigh show dev br-app | grep -m 1 "172.20" | awk '{print $1}')
if [ -z "$TARGET_IP" ]; then
    echo "  No 172.20.x.x neighbors found in ARP table."
else
    echo "  Pinging $TARGET_IP..."
    ping -c 2 "$TARGET_IP"
fi
