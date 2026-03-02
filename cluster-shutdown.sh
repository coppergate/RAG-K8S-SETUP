#!/bin/bash

# ==============================================================================
# CLUSTER SHUTDOWN SCRIPT
# MUST be executed on 'hierophant'
# ==============================================================================

# Ensure we have kubectl and kubeconfig
KUBECTL="/home/k8s/kube/kubectl"
export KUBECONFIG="/home/k8s/kube/config/kubeconfig"
if [ ! -f "$KUBECTL" ]; then
    echo "Error: $KUBECTL not found."
    exit 1
fi

REPLICA_FILE="cluster-replicas.state"
echo "Saving current replica counts to $REPLICA_FILE..."
rm -f "$REPLICA_FILE"

# Function to wait for resources to scale to 0
wait_for_scale_zero() {
    local ns=$1
    local res=$2
    local timeout=60
    local elapsed=0
    
    echo "Waiting for $res in namespace $ns to scale to 0..."
    while [ $elapsed -lt $timeout ]; do
        local current_replicas
        if [[ "$res" =~ "clusters.postgresql.cnpg.io" ]]; then
            current_replicas=$($KUBECTL get "$res" -n "$ns" -o jsonpath='{.status.instances}' 2>/dev/null)
        else
            current_replicas=$($KUBECTL get "$res" -n "$ns" -o jsonpath='{.status.replicas}' 2>/dev/null)
        fi
        if [ -z "$current_replicas" ] || [ "$current_replicas" -eq 0 ]; then
            echo "$res scaled to 0."
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    echo "Warning: Timeout waiting for $res to scale to 0."
    return 1
}

# 1. Identify and scale down non-rook-ceph CRs
echo "Step 1: Scaling down non-rook-ceph resources..."

# Get all namespaces except rook-ceph and kube-system
NAMESPACES=$($KUBECTL get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -vE 'rook-ceph|kube-system')

for ns in $NAMESPACES; do
    # Find all Deployments, StatefulSets, and CNPG Clusters in this namespace
    RESOURCES=$($KUBECTL get deployments,statefulsets,clusters.postgresql.cnpg.io -n "$ns" -o name 2>/dev/null)
    
    for res in $RESOURCES; do
        REPLICAS=""
        if [[ "$res" =~ "clusters.postgresql.cnpg.io" ]]; then
            REPLICAS=$($KUBECTL get "$res" -n "$ns" -o jsonpath='{.spec.instances}')
        else
            REPLICAS=$($KUBECTL get "$res" -n "$ns" -o jsonpath='{.spec.replicas}')
        fi
        if [ -n "$REPLICAS" ] && [ "$REPLICAS" -gt 0 ]; then
            echo "$ns $res $REPLICAS" >> "$REPLICA_FILE"
            echo "Scaling down $res in namespace $ns (current: $REPLICAS)..."
            $KUBECTL scale "$res" -n "$ns" --replicas=0
            wait_for_scale_zero "$ns" "$res"
        fi
    done
done

# 2. Scale down rook-ceph resources
echo "Step 2: Scaling down rook-ceph resources..."

ROOK_NS="rook-ceph"

# 2a. Stop rook-ceph osd (set flags) BEFORE scaling down components
echo "Setting ceph maintenance flags..."
# Function to run ceph command (prefer kubectl rook-ceph plugin)
run_ceph_cmd() {
    local cmd=$1
    # 1. Prefer user-installed krew plugin if available (check common locations)
    # The plugin is often in ~/.krew/bin which might not be in the path for root/junie.
    # We check /home/wjones/.krew/bin/kubectl-rook_ceph as it's known to be there.
    local WJONES_PLUGIN="/home/wjones/.krew/bin/kubectl-rook_ceph"
    
    if $KUBECTL rook-ceph --help >/dev/null 2>&1; then
        $KUBECTL rook-ceph ceph -n "$ROOK_NS" $cmd
        return $?
    elif [ -x "$WJONES_PLUGIN" ] && [ "$(/usr/bin/id -u)" -eq 0 ]; then
        # If we are root and have the plugin path, try using it via kubectl
        $KUBECTL rook-ceph ceph -n "$ROOK_NS" $cmd --plugin-path="/home/wjones/.krew/bin"
        return $?
    fi

    # 2. Fallback to exec into toolbox pod
    local TOOLBOX_POD=$($KUBECTL -n "$ROOK_NS" get pod -l app=rook-ceph-tools -o name | head -n 1)
    if [ -n "$TOOLBOX_POD" ]; then
        $KUBECTL -n "$ROOK_NS" exec "$TOOLBOX_POD" -- ceph --conf /etc/ceph/ceph.conf $cmd
        return $?
    fi

    # 3. Fallback to exec into operator pod
    local op_pod=$($KUBECTL -n "$ROOK_NS" get pod -l app=rook-ceph-operator -o name | head -n 1)
    if [ -n "$op_pod" ]; then
        # The operator pod needs a specific config path and container
        $KUBECTL -n "$ROOK_NS" exec "$op_pod" -c rook-ceph-operator -- ceph --conf /var/lib/rook/rook-ceph/rook-ceph.config $cmd 2>/dev/null || \
        $KUBECTL -n "$ROOK_NS" exec "$op_pod" -c rook-ceph-operator -- ceph $cmd
        return $?
    fi
    return 1
}

# Check Ceph Health
echo "Checking Ceph health before shutdown..."
CEPH_HEALTH=$(run_ceph_cmd "health")
echo "Current Ceph status: $CEPH_HEALTH"

if [[ "$CEPH_HEALTH" == *"HEALTH_ERR"* ]]; then
    echo "Warning: Ceph is in HEALTH_ERR state. Shutdown might be risky."
    echo "!!! PROCEEDING WITH CAUTION !!!"
fi

# Check for PGs
echo "Checking for clean PGs..."
PG_STATUS=$(run_ceph_cmd "pg stat")
echo "PG Status: $PG_STATUS"
if [[ "$PG_STATUS" != *"active+clean"* ]] && [[ "$PG_STATUS" != *"active+clean+scrubbing"* ]]; then
    echo "Warning: Not all PGs are active+clean. Waiting 30s for any immediate recovery..."
    sleep 30
fi

# Quiesce IO: Check for active watchers (indicates clients still connected)
echo "Checking for active Ceph clients/watchers..."
for pool in $(run_ceph_cmd "osd pool ls"); do
    WATCHERS=$(run_ceph_cmd "osd dump" | grep "pool $pool" -A 5 | grep "watcher")
    if [ -n "$WATCHERS" ]; then
        echo "Warning: Active watchers detected on pool $pool. Applications might still be closing handles."
    fi
done

# Set flags to prevent rebalancing and data movement during shutdown
echo "Freezing Ceph state (noout, nobackfill, norecover, noscrub, nodeep-scrub)..."
for flag in noout nobackfill norecover noscrub nodeep-scrub; do
    run_ceph_cmd "osd set $flag"
done

# 2b. Now scale down rook components
# Order: others -> osd -> mon
ROOK_DEPLOYS=$($KUBECTL get deployments -n "$ROOK_NS" -o name)
ROOK_STATEFULSETS=$($KUBECTL get statefulsets -n "$ROOK_NS" -o name)

# Save all rook replicas first
for res in $ROOK_DEPLOYS $ROOK_STATEFULSETS; do
    REPLICAS=$($KUBECTL get "$res" -n "$ROOK_NS" -o jsonpath='{.spec.replicas}')
    echo "$ROOK_NS $res $REPLICAS" >> "$REPLICA_FILE"
done

# Scale down "others" (not mon, osd, or operator)
for res in $ROOK_DEPLOYS $ROOK_STATEFULSETS; do
    if [[ ! "$res" =~ "mon" ]] && [[ ! "$res" =~ "osd" ]] && [[ ! "$res" =~ "operator" ]]; then
        echo "Scaling down rook component: $res..."
        $KUBECTL scale "$res" -n "$ROOK_NS" --replicas=0
        wait_for_scale_zero "$ROOK_NS" "$res"
    fi
done

# Scale down OSDs
for res in $ROOK_DEPLOYS $ROOK_STATEFULSETS; do
    if [[ "$res" =~ "osd" ]]; then
        echo "Scaling down rook component: $res..."
        $KUBECTL scale "$res" -n "$ROOK_NS" --replicas=0
        wait_for_scale_zero "$ROOK_NS" "$res"
    fi
done

# Wait a bit for OSDs to terminate
sleep 5

# Scale down Mons
for res in $ROOK_DEPLOYS $ROOK_STATEFULSETS; do
    if [[ "$res" =~ "mon" ]]; then
        echo "Scaling down rook component: $res..."
        $KUBECTL scale "$res" -n "$ROOK_NS" --replicas=0
        wait_for_scale_zero "$ROOK_NS" "$res"
    fi
done

# 3. Drain all nodes
echo "Step 3: Draining all nodes..."

# Handle PDBs that might block draining during shutdown
echo "Temporarily deleting non-system PDBs to prevent drain blocks..."
PDBS=$($KUBECTL get pdb -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' | grep -vE 'kube-system|talos-system|rook-ceph')
while read -r ns name; do
    if [ -n "$ns" ] && [ -n "$name" ]; then
        echo "Deleting PDB $name in namespace $ns..."
        $KUBECTL delete pdb "$name" -n "$ns" --timeout=10s
    fi
done <<< "$PDBS"

NODES=$($KUBECTL get nodes -o name)
for node in $NODES; do
    echo "Draining $node..."
    # Increase timeout and handle daemonsets more aggressively if needed
    if ! $KUBECTL drain "$node" --ignore-daemonsets --delete-emptydir-data --force --timeout=180s; then
        echo "Warning: Drain failed for $node. Checking for remaining pods..."
        # List remaining pods for debugging
        $KUBECTL get pods --all-namespaces --field-selector spec.nodeName=${node#node/}
        
        # If there are still pods, try force deleting them (except for daemonsets)
        echo "Attempting to force delete remaining pods on $node (excluding daemonsets)..."
        REMAINING_PODS=$($KUBECTL get pods --all-namespaces --field-selector spec.nodeName=${node#node/} -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.metadata.ownerReferences[0].kind}{"\n"}{end}' | grep -v "DaemonSet")
        while read -r pns pname pkind; do
            if [ -n "$pns" ] && [ -n "$pname" ]; then
                echo "Force deleting pod $pname in $pns..."
                $KUBECTL delete pod "$pname" -n "$pns" --force --grace-period=0 --timeout=10s
            fi
        done <<< "$REMAINING_PODS"

        echo "Proceeding with VM shutdown anyway."
    fi
done

# 5. Stop all VMs
echo "Step 5: Stopping all cluster VMs..."
VMS=("worker-0" "worker-1" "worker-2" "worker-3" "inference-0" "inference-1" "control-0" "control-1" "control-2")
for vm in "${VMS[@]}"; do
    if sudo virsh dominfo "$vm" &>/dev/null; then
        echo "  Stopping VM: $vm"
        sudo virsh shutdown "$vm"
    fi
done

# Finally scale down the operator pod so it's not running when we stop the node
echo "Scaling down rook-ceph-operator..."
$KUBECTL scale deployment.apps/rook-ceph-operator -n "$ROOK_NS" --replicas=0 2>/dev/null

echo "Waiting for VMs to shut down (max 5 minutes)..."
MAX_WAIT=300
ELAPSED=0
while [ $ELAPSED -lt $MAX_WAIT ]; do
    STILL_RUNNING=()
    for vm in "${VMS[@]}"; do
        if sudo virsh list --name | grep -q "^$vm$"; then
            STILL_RUNNING+=("$vm")
        fi
    done
    
    if [ ${#STILL_RUNNING[@]} -eq 0 ]; then
        echo "All VMs shut down successfully."
        break
    fi
    
    echo "Still waiting for: ${STILL_RUNNING[*]} ($ELAPSED/$MAX_WAIT)..."
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

if [ $ELAPSED -ge $MAX_WAIT ]; then
    echo "Error: Some VMs failed to shut down gracefully after $MAX_WAIT seconds."
    for vm in "${STILL_RUNNING[@]}"; do
        echo "  Forcing shutdown of $vm..."
        sudo virsh destroy "$vm"
    done
fi

echo "Cluster shutdown complete."
