#!/bin/bash

# This script cycles (takes down and brings up) all network interfaces and bridges on hierophant.
# It is intended to help cluster nodes (VMs) re-recognize their attached network devices.

echo "Starting network interface cycling on hierophant..."

# 1. Identify interfaces
BRIDGES=("br-app" "talos-bridge" "virbr0")
PHYSICAL_INTERFACES=("eno1.20" "eno1" "enp5s0")

# Get all vnet interfaces (VM taps)
VNET_INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep '^vnet')

echo "Found bridges: ${BRIDGES[*]}"
echo "Found physical/VLAN interfaces: ${PHYSICAL_INTERFACES[*]}"
echo "Found VM interfaces: ${VNET_INTERFACES//$'\n'/ }"

# 2. Bring DOWN VM interfaces first
echo "Taking down VM (vnet) interfaces..."
for iface in $VNET_INTERFACES; do
    sudo ip link set "$iface" down 2>/dev/null && echo "  $iface DOWN" || true
done

# 3. Bring DOWN bridges
echo "Taking down bridges..."
for br in "${BRIDGES[@]}"; do
    sudo ip link set "$br" down 2>/dev/null && echo "  $br DOWN" || true
done

# 4. Cycle physical/VLAN interfaces (NMCLI to preserve config)
echo "Cycling physical/VLAN interfaces via nmcli..."
for iface in "${PHYSICAL_INTERFACES[@]}"; do
    echo "  Cycling $iface..."
    sudo nmcli connection down "$iface" 2>/dev/null || sudo ip link set "$iface" down 2>/dev/null
done

sleep 2

# 5. Bring UP physical/VLAN interfaces
echo "Bringing up physical/VLAN interfaces..."
for iface in "${PHYSICAL_INTERFACES[@]}"; do
    sudo nmcli connection up "$iface" 2>/dev/null || sudo ip link set "$iface" up 2>/dev/null
    echo "  $iface UP"
done

# 6. Bring UP bridges
echo "Bringing up bridges..."
for br in "${BRIDGES[@]}"; do
    sudo ip link set "$br" up 2>/dev/null && echo "  $br UP" || true
done

# 7. Bring UP VM interfaces
echo "Bringing up VM (vnet) interfaces..."
for iface in $VNET_INTERFACES; do
    sudo ip link set "$iface" up 2>/dev/null && echo "  $iface UP" || true
done

# 8. Verification
echo "Current bridge status:"
bridge link show

echo "Network cycling complete."
