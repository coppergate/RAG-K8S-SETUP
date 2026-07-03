#!/bin/bash

# This script performs a safe, one-by-one drain and restart of the cluster VMs on hierophant.
# It is designed to preserve ROOK/Ceph stability and cluster health.

echo "Starting sequenced drain and restoration of cluster VMs on hierophant..."

# 1. Define groups
CONTROL_VMS=("control-0" "control-1" "control-2")
WORKER_VMS=("worker-0" "worker-1" "worker-2" "worker-3")
OTHER_VMS=()

# Check if kubectl is available
KUBECTL_PATH="/home/k8s/kube"
if [ ! -f "$KUBECTL_PATH" ]; then
    # Fallback to PATH if not at specific location
    if command -v kubectl &> /dev/null; then
        KUBECTL_PATH=$(command -v kubectl)
        KUBECTL_AVAILABLE=true
    else
        echo "WARNING: kubectl not found at $KUBECTL_PATH or in PATH. Kubernetes-level draining will be skipped."
        KUBECTL_AVAILABLE=false
    fi
else
    KUBECTL_AVAILABLE=true
fi

# Function to drain a node
drain_node() {
    local vm=$1
    if [ "$KUBECTL_AVAILABLE" = true ]; then
        echo "  Draining node: $vm..."
        # We use --ignore-daemonsets and --delete-emptydir-data as is standard for ROOK/maintenance
        # --force is used to handle pods not managed by a controller if necessary
        sudo "$KUBECTL_PATH" drain "$vm" --ignore-daemonsets --delete-emptydir-data --force --timeout=120s
        if [ $? -ne 0 ]; then
            echo "  ERROR: Drain failed for $vm. Aborting to protect the cluster."
            return 1
        fi
    else
        echo "  ERROR: kubectl is not available. Cannot drain $vm. Aborting."
        return 1
    fi
    return 0
}

# Function to uncordon a node
uncordon_node() {
    local vm=$1
    if [ "$KUBECTL_AVAILABLE" = true ]; then
        echo "  Uncordoning node: $vm..."
        sudo "$KUBECTL_PATH" uncordon "$vm"
    fi
}

# Function to wait for node to be Ready
wait_for_ready() {
    local vm=$1
    if [ "$KUBECTL_AVAILABLE" = true ]; then
        echo "  Waiting for node $vm to reach 'Ready' status..."
        for i in {1..30}; do
            STATUS=$(sudo "$KUBECTL_PATH" get node "$vm" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
            if [ "$STATUS" = "True" ]; then
                echo "  Node $vm is Ready."
                return 0
            fi
            sleep 10
        done
        echo "  Warning: Timeout waiting for $vm to become Ready."
        return 1
    fi
    return 0
}

# Function to safely restart a single VM
restart_vm_safely() {
    local vm=$1
    local is_worker=$2

    echo "=== Processing VM: $vm ==="
    
    # Check if running
    if sudo virsh list --name --state-running | grep -q "^$vm$"; then
        if ! drain_node "$vm"; then
            echo "  Aborting restoration for $vm and subsequent nodes."
            exit 1
        fi
        
        echo "  Gracefully shutting down $vm..."
        sudo virsh shutdown "$vm"
        
        # Wait for shutdown
        for i in {1..12}; do
            if ! sudo virsh list --name --state-running | grep -q "^$vm$"; then
                echo "  $vm has shut down."
                break
            fi
            if [ $i -eq 12 ]; then
                echo "  $vm did not shut down gracefully, forcing destroy..."
                sudo virsh destroy "$vm"
            fi
            sleep 5
        done
    else
        echo "  $vm is not running. Starting it..."
    fi

    echo "  Starting VM: $vm"
    sudo virsh start "$vm"
    
    echo "  Waiting for boot and network initialization (45s)..."
    sleep 45

    wait_for_ready "$vm"
    uncordon_node "$vm"

    if [ "$is_worker" = true ]; then
        echo "  Allowing ROOK/Ceph to stabilize (60s)..."
        sleep 60
    else
        echo "  Allowing Control Plane to stabilize (20s)..."
        sleep 20
    fi
}

# Execution Order

echo "1. Restarting Control Plane VMs one by one..."
for vm in "${CONTROL_VMS[@]}"; do
    restart_vm_safely "$vm" false
done

echo "2. Restarting Worker VMs (ROOK) one by one..."
for vm in "${WORKER_VMS[@]}"; do
    restart_vm_safely "$vm" true
done

echo "3. Restarting remaining VMs..."
for vm in "${OTHER_VMS[@]}"; do
    restart_vm_safely "$vm" false
done

echo "Full restoration complete. All nodes have been drained, restarted, and uncordoned."
bridge link show | grep -E 'br-app|talos-bridge'
