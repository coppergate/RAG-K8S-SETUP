#!/bin/bash

# This script performs a clean restart of the cluster VMs on hierophant.
# Use this when VMs lose track of their network interfaces after host-level bridge changes.

echo "Starting cluster VM restoration on hierophant..."

# 1. Define groups for careful restart
CONTROL_VMS=("control-0" "control-1" "control-2")
WORKER_VMS=("worker-0" "worker-1" "worker-2")
OTHER_VMS=("inference-0" "inference-1")

# Function to stop a VM carefully
stop_vm() {
    local vm=$1
    if [[ " ${WORKER_VMS[@]} " =~ " ${vm} " ]]; then
        echo "  Gracefully shutting down worker node (ROOK): $vm..."
        sudo virsh shutdown "$vm"
        # Wait up to 60 seconds for shutdown
        for i in {1..12}; do
            if ! sudo virsh list --name --state-running | grep -q "^$vm$"; then
                echo "  $vm has shut down."
                return 0
            fi
            sleep 5
        done
        echo "  $vm did not shut down gracefully, forcing destroy..."
        sudo virsh destroy "$vm"
    else
        echo "  Stopping VM: $vm (destroying)..."
        sudo virsh destroy "$vm"
    fi
}

# 2. Get list of running VMs
RUNNING_VMS=$(sudo virsh list --name --state-running)

if [ -z "$RUNNING_VMS" ]; then
    echo "No running VMs found. Starting all defined VMs in sequence..."
    # Start Control Plane
    for vm in "${CONTROL_VMS[@]}"; do
        echo "  Starting Control VM: $vm"
        sudo virsh start "$vm" 2>/dev/null
    done
    sleep 10
    # Start Workers one by one for ROOK stability
    for vm in "${WORKER_VMS[@]}"; do
        echo "  Starting Worker VM (ROOK): $vm"
        sudo virsh start "$vm" 2>/dev/null
        sleep 15 # Wait between workers
    done
    # Start Others
    for vm in "${OTHER_VMS[@]}"; do
        echo "  Starting VM: $vm"
        sudo virsh start "$vm" 2>/dev/null
    done
else
    echo "Stopping running VMs carefully..."
    for vm in $RUNNING_VMS; do
        stop_vm "$vm"
    done

    echo "Waiting for interfaces to clear..."
    sleep 5

    echo "Restarting VMs in sequence..."
    # Start Control Plane
    for vm in "${CONTROL_VMS[@]}"; do
        if [[ $RUNNING_VMS =~ $vm ]]; then
            echo "  Starting Control VM: $vm"
            sudo virsh start "$vm"
        fi
    done
    
    echo "Waiting for control plane to stabilize..."
    sleep 200

    # Start Workers one by one
    for vm in "${WORKER_VMS[@]}"; do
        if [[ $RUNNING_VMS =~ $vm ]]; then
            echo "  Starting Worker VM (ROOK): $vm"
            sudo virsh start "$vm"
            echo "  Waiting for $vm to initialize ROOK..."
            sleep 30
        fi
    done

    # Start remaining
    for vm in $RUNNING_VMS; do
        if [[ ! " ${CONTROL_VMS[@]} " =~ " ${vm} " ]] && [[ ! " ${WORKER_VMS[@]} " =~ " ${vm} " ]]; then
             echo "  Starting VM: $vm"
             sudo virsh start "$vm"
        fi
    done
fi

echo "Waiting for VMs to boot and negotiate network (120s)..."
sleep 120

echo "Checking bridge membership..."
bridge link show | grep -E 'br-app|talos-bridge'

echo "Restoration complete. Please try pinging 172.20.1.x from hierophant again."
