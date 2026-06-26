
echo "Stopping VMs..."
for vm in worker-0 worker-1 worker-2 inference-0 inference-1 control-0 control-1 control-2 ; do
    if sudo virsh dominfo "$vm" &>/dev/null; then
        echo "  stopping VM: $vm"
        sudo virsh shutdown "$vm" --mode initctl 2>/dev/null || true
    fi
done


sleep 300;

echo "Starting VMs..."

for vm in control-0 control-1 control-2 worker-0 worker-1 worker-2 inference-0 inference-1; do
    if sudo virsh dominfo "$vm" &>/dev/null; then
        echo "  starting VM: $vm"
        sudo virsh start "$vm" 2>/dev/null || true
    fi
done