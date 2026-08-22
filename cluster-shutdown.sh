#!/bin/bash
# ==============================================================================
# CLUSTER SHUTDOWN SCRIPT
# Version: 2.4.0
# MUST be executed on 'hierophant'
#
# Purpose: bring every cluster node hierophant HOSTS down cleanly so the host can
# be rebooted. Nodes that are not libvirt domains on this host (e.g. the external
# physical GPU node inference-0) are drained but deliberately left running — this
# script cannot power them off and does not try.
#
# v2.4.0 — the VM list is now DISCOVERED from libvirt rather than hardcoded.
#   The previous hardcoded list read:
#     worker-0 worker-1 worker-2 inference-0 inference-1 control-0..2
#   which was wrong in two ways on the current build: worker-3 was missing
#   entirely (it exists in the 4-worker layout and was left running through a
#   host reboot), and inference-0/-1 were listed as VMs when inference-0 is now
#   an external physical machine. Both failures were SILENT — the completion
#   check only looked at that same list, so it reported "All VMs shut down
#   successfully" while a worker was still running.
#   Discovery also keeps this script correct across the other setup variants,
#   where inference-0 IS a VM: whatever libvirt reports is what gets stopped.
# ==============================================================================
# Ensure we have kubectl and kubeconfig
KUBECTL="/home/k8s/kube/kubectl"
export KUBECONFIG="/home/k8s/kube/config/kubeconfig"
if [ ! -f "$KUBECTL" ]; then
    echo "Error: $KUBECTL not found."
    exit 1
fi

REPLICA_FILE="/home/k8s/kube/cluster-replicas.state"
TEMP_REPLICA_FILE="/tmp/cluster-replicas.state.$$"

echo "Scanning for active replicas (saving to $TEMP_REPLICA_FILE)..."
rm -f "$TEMP_REPLICA_FILE"

# 0. Cleanup admission controllers that might block restart
echo "Step 0: Cleaning up admission controllers..."
$KUBECTL delete mutatingwebhookconfiguration k8tz --ignore-not-found

# Function to wait for resources to scale to 0
wait_for_scale_zero() {
    local ns=$1
    local res=$2
    local timeout=60
    local elapsed=0
    until [ $($KUBECTL get "$res" -n "$ns" -o jsonpath='{.status.replicas // 0}' 2>/dev/null) -eq 0 ] || [ $elapsed -ge $timeout ]; do
        sleep 2
        elapsed=$((elapsed + 2))
    done
}

# Function to wait for all pods in a namespace to be gone
wait_for_ns_pods_gone() {
    local ns=$1
    local timeout=120
    local elapsed=0
    echo "Waiting for all pods in namespace $ns to terminate..."
    until [ $($KUBECTL get pods -n "$ns" --no-headers 2>/dev/null | wc -l) -eq 0 ] || [ $elapsed -ge $timeout ]; do
        sleep 5
        elapsed=$((elapsed + 5))
    done
}

# 1. Identify and scale down non-rook-ceph resources (Priority Order: Apps -> Bus -> Infrastructure)
echo "Step 1: Identifying and scaling down resources..."
# We exclude system namespaces and rook-ceph (handled separately)
EXCLUDE_PATTERN="kube-system|talos-system|rook-ceph|monitoring|k8tz|container-registry"
ALL_NS=$($KUBECTL get namespaces -o name | cut -d'/' -f2)

# Priority 1: Apps & DBs
APPS_NS="rag-system timescaledb qdrant"
# Priority 2: Message Bus
BUS_NS="apache-pulsar"
# Priority 3: Infrastructure (Others)
FINAL_NS_LIST="$APPS_NS $BUS_NS"
REMAINING_NS=$(echo "$ALL_NS" | grep -vE "$EXCLUDE_PATTERN|rag-system|timescaledb|qdrant|apache-pulsar")
FINAL_NS_LIST="$FINAL_NS_LIST $REMAINING_NS"

for ns in $FINAL_NS_LIST; do
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
            echo "$ns $res $REPLICAS" >> "$TEMP_REPLICA_FILE"
            echo "Scaling down $res in namespace $ns (current: $REPLICAS)..."
            $KUBECTL scale "$res" -n "$ns" --replicas=0
            wait_for_scale_zero "$ns" "$res"
        fi
    done

    # Ensure pods are actually terminated to trigger unmounts while storage is still up
    wait_for_ns_pods_gone "$ns"
done

# 2. Quiesce Ceph and Drain Nodes
echo "Step 2: Quiescing Ceph and Draining nodes..."
ROOK_NS="rook-ceph"

# Function to run ceph command
run_ceph_cmd() {
    local cmd=$1
    local WJONES_PLUGIN="/home/wjones/.krew/bin/kubectl-rook_ceph"

    if $KUBECTL rook-ceph --help >/dev/null 2>&1; then
        $KUBECTL rook-ceph ceph -n "$ROOK_NS" $cmd
        return $?
    elif [ -x "$WJONES_PLUGIN" ] && [ "$(/usr/bin/id -u)" -eq 0 ]; then
        $KUBECTL rook-ceph ceph -n "$ROOK_NS" $cmd --plugin-path="/home/wjones/.krew/bin"
        return $?
    fi
    local TOOLBOX_POD=$($KUBECTL -n "$ROOK_NS" get pod -l app=rook-ceph-tools -o name | head -n 1)
    if [ -n "$TOOLBOX_POD" ]; then
        $KUBECTL -n "$ROOK_NS" exec "$TOOLBOX_POD" -- ceph --conf /etc/ceph/ceph.conf $cmd
        return $?
    fi
    local op_pod=$($KUBECTL -n "$ROOK_NS" get pod -l app=rook-ceph-operator -o name | head -n 1)
    if [ -n "$op_pod" ]; then
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

# Set flags to prevent rebalancing and data movement during shutdown
echo "Freezing Ceph state (noout, nobackfill, norecover, noscrub, nodeep-scrub)..."
for flag in noout nobackfill norecover noscrub nodeep-scrub; do
    run_ceph_cmd "osd set $flag"
done

# Drain nodes
echo "Draining all nodes..."
NODES=$($KUBECTL get nodes -o name)
for node in $NODES; do
    echo "Draining $node..."
    $KUBECTL drain "$node" --ignore-daemonsets --delete-emptydir-data --force --timeout=180s || echo "Warning: Drain failed for $node. Proceeding anyway."
done

# 3. Scale down rook-ceph resources
echo "Step 3: Scaling down rook-ceph resources..."
ROOK_DEPLOYS=$($KUBECTL get deployments -n "$ROOK_NS" -o name)
ROOK_STATEFULSETS=$($KUBECTL get statefulsets -n "$ROOK_NS" -o name)

# Save all rook replicas first (only if > 0)
for res in $ROOK_DEPLOYS $ROOK_STATEFULSETS; do
    REPLICAS=$($KUBECTL get "$res" -n "$ROOK_NS" -o jsonpath='{.spec.replicas}')
    if [ -n "$REPLICAS" ] && [ "$REPLICAS" -gt 0 ]; then
        echo "$ROOK_NS $res $REPLICAS" >> "$TEMP_REPLICA_FILE"
    fi
done

# Finalize replica state file BEFORE scaling down rook
if [ -s "$TEMP_REPLICA_FILE" ]; then
    echo "Updating $REPLICA_FILE with new replica state..."
    [ -f "$REPLICA_FILE" ] && cp "$REPLICA_FILE" "$REPLICA_FILE.bak" 2>/dev/null
    mv "$TEMP_REPLICA_FILE" "$REPLICA_FILE"
else
    echo "Warning: No running replicas found. Existing $REPLICA_FILE preserved (if any)."
    rm -f "$TEMP_REPLICA_FILE"
fi

# 3b. Now scale down rook components
# Order: others -> osd -> mon
echo "Scaling down other rook components..."
for res in $ROOK_DEPLOYS $ROOK_STATEFULSETS; do
    if [[ ! "$res" =~ "mon" ]] && [[ ! "$res" =~ "osd" ]] && [[ ! "$res" =~ "operator" ]]; then
        echo "Scaling down rook component: $res..."
        $KUBECTL scale "$res" -n "$ROOK_NS" --replicas=0
        wait_for_scale_zero "$ROOK_NS" "$res"
    fi
done

echo "Scaling down OSDs..."
for res in $ROOK_DEPLOYS $ROOK_STATEFULSETS; do
    if [[ "$res" =~ "osd" ]]; then
        echo "Scaling down rook component: $res..."
        $KUBECTL scale "$res" -n "$ROOK_NS" --replicas=0
        wait_for_scale_zero "$ROOK_NS" "$res"
    fi
done

sleep 5

echo "Scaling down Mons..."
for res in $ROOK_DEPLOYS $ROOK_STATEFULSETS; do
    if [[ "$res" =~ "mon" ]]; then
        echo "Scaling down rook component: $res..."
        $KUBECTL scale "$res" -n "$ROOK_NS" --replicas=0
        wait_for_scale_zero "$ROOK_NS" "$res"
    fi
done

echo "Scaling down rook-ceph-operator..."
$KUBECTL scale deployment.apps/rook-ceph-operator -n "$ROOK_NS" --replicas=0 2>/dev/null

# 4. Stop the cluster VMs hosted on this machine
echo "Step 4: Stopping cluster VMs hosted on hierophant..."

# Names that count as cluster nodes. Anything else on this host (dev-fedora, etc.)
# is left strictly alone. Override to widen/narrow the match if node naming changes.
CLUSTER_VM_PATTERN="${CLUSTER_VM_PATTERN:-^(control|worker|inference)-[0-9]+$}"

# Discover from libvirt rather than assuming. A physical node is simply not a
# domain here, so it never enters this list.
mapfile -t VMS < <(sudo virsh list --all --name 2>/dev/null \
                     | grep -E "${CLUSTER_VM_PATTERN}" | sort)

# Cross-check against Kubernetes so anything we CANNOT power off is called out
# rather than silently ignored.
K8S_NODES=$($KUBECTL get nodes -o name 2>/dev/null | cut -d'/' -f2 | sort)
NON_VM_NODES=()
if [ -z "${K8S_NODES}" ]; then
    echo "  WARNING: could not list Kubernetes nodes (API already down?)." >&2
    echo "  Skipping the VM-vs-node cross-check — any node this host does not" >&2
    echo "  own will NOT be reported below. Verify by hand before rebooting." >&2
else
    for n in $K8S_NODES; do
        printf '%s\n' "${VMS[@]}" | grep -qx "$n" || NON_VM_NODES+=("$n")
    done
fi

echo "  Cluster VMs on this host : ${VMS[*]:-<none>}"
if [ ${#NON_VM_NODES[@]} -gt 0 ]; then
    echo ""
    echo "  NOTE: these Kubernetes nodes are NOT libvirt domains on hierophant:"
    for n in "${NON_VM_NODES[@]}"; do
        echo "        - $n"
    done
    echo "        They have been drained but will KEEP RUNNING after this script"
    echo "        finishes. Power them down separately if that is what you want,"
    echo "        e.g. talosctl -n <ip> shutdown"
    echo ""
fi

if [ ${#VMS[@]} -eq 0 ]; then
    echo "  WARNING: no cluster VMs found on this host. Nothing to stop." >&2
    echo "  If that is unexpected, check: sudo virsh list --all" >&2
fi

for vm in "${VMS[@]}"; do
    if sudo virsh list --name | grep -qx "$vm"; then
        echo "  Stopping VM: $vm"
        sudo virsh shutdown "$vm"
    else
        echo "  $vm is already stopped."
    fi
done

echo "Waiting for VMs to shut down (max 5 minutes)..."
MAX_WAIT=300
ELAPSED=0
STILL_RUNNING=()
while [ $ELAPSED -lt $MAX_WAIT ]; do
    STILL_RUNNING=()
    for vm in "${VMS[@]}"; do
        if sudo virsh list --name | grep -qx "$vm"; then
            STILL_RUNNING+=("$vm")
        fi
    done

    if [ ${#STILL_RUNNING[@]} -eq 0 ]; then
        break
    fi

    echo "Still waiting for: ${STILL_RUNNING[*]} ($ELAPSED/$MAX_WAIT)..."
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

if [ ${#STILL_RUNNING[@]} -gt 0 ]; then
    echo "Error: these VMs did not shut down gracefully after ${MAX_WAIT}s." >&2
    for vm in "${STILL_RUNNING[@]}"; do
        echo "  Forcing shutdown of $vm..." >&2
        sudo virsh destroy "$vm"
    done
    sleep 5
fi

# Final verification — never claim success without re-checking libvirt.
FAILED=()
for vm in "${VMS[@]}"; do
    sudo virsh list --name | grep -qx "$vm" && FAILED+=("$vm")
done

echo ""
if [ ${#FAILED[@]} -gt 0 ]; then
    echo "=============================================================" >&2
    echo " SHUTDOWN INCOMPLETE — DO NOT REBOOT THE HOST" >&2
    echo " Still running: ${FAILED[*]}" >&2
    echo " Rebooting now would kill these mid-write." >&2
    echo "=============================================================" >&2
    exit 1
fi

echo "============================================================="
echo " All ${#VMS[@]} cluster VMs on hierophant are stopped."
echo " Safe to: sudo reboot"
if [ ${#NON_VM_NODES[@]} -gt 0 ]; then
    echo ""
    echo " Still running elsewhere (not touched): ${NON_VM_NODES[*]}"
fi
echo "============================================================="
