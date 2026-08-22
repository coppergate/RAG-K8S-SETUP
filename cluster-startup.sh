#!/bin/bash
# ==============================================================================
# CLUSTER STARTUP SCRIPT
# Version: 2.4.0
# MUST be executed on 'hierophant'
# Usage: ./cluster-startup.sh [--no-gpu]
#   --no-gpu  Skip the host GPU PCI detach step
#
# Brings back the cluster VMs hierophant HOSTS, then restores cluster state.
# Counterpart to cluster-shutdown.sh v2.4.0 and mirrors its behaviour: the VM
# list is DISCOVERED from libvirt, not hardcoded.
#
# v2.4.0 — fixes the same drift that affected the shutdown script. The old
#   hardcoded lists omitted worker-3 (present in the 4-worker layout) and tried
#   to start inference-0/inference-1 as VMs, although inference-0 is now an
#   external physical machine that this host cannot power on at all.
#   The GPU PCI detach is also now conditional: pci_0000_04_00_0 / _84_00_0 were
#   hierophant's own GPUs being passed through to inference VMs. That layout no
#   longer applies here — the GPUs live in the external node — so the detach is
#   attempted only for devices that actually exist on this host. Variants that
#   still passthrough host GPUs are unaffected.
# ==============================================================================
# Ensure we have kubectl and kubeconfig
KUBECTL="/home/k8s/kube/kubectl"
export KUBECONFIG="/home/k8s/kube/config/kubeconfig"
if [ ! -f "$KUBECTL" ]; then
    echo "Error: $KUBECTL not found."
    exit 1
fi
ROOK_NS="rook-ceph"
REPLICA_FILE="/home/k8s/kube/cluster-replicas.state"

# --- Argument parsing ---
SKIP_GPU="${SKIP_GPU:-false}"
for arg in "$@"; do
  case "$arg" in
    --no-gpu) SKIP_GPU=true ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

# 1. Start the cluster VMs hosted on this machine
echo "Step 1: Starting cluster VMs hosted on hierophant..."

# Same discovery contract as cluster-shutdown.sh — keep the two in step.
CLUSTER_VM_PATTERN="${CLUSTER_VM_PATTERN:-^(control|worker|inference)-[0-9]+$}"

# Host GPUs to hand to inference VMs via passthrough. Only devices that actually
# exist on this host are detached, so this is a no-op on builds where the GPUs
# live in an external node. Override to match a different passthrough layout.
GPU_PCI_DEVICES="${GPU_PCI_DEVICES:-pci_0000_04_00_0 pci_0000_84_00_0}"

if [[ "$SKIP_GPU" == "true" ]]; then
    echo "  --no-gpu: skipping host GPU PCI detach."
else
    for dev in ${GPU_PCI_DEVICES}; do
        if sudo virsh nodedev-info "$dev" &>/dev/null; then
            echo "  Detaching host GPU $dev for passthrough..."
            sudo virsh nodedev-detach "$dev" 2>/dev/null || \
                echo "    WARN: detach failed for $dev (already detached?)"
        fi
    done
fi

# Discover rather than assume. Physical nodes are not domains, so they are
# naturally absent — this host cannot start them in any case.
mapfile -t VMS < <(sudo virsh list --all --name 2>/dev/null \
                     | grep -E "${CLUSTER_VM_PATTERN}" | sort)

if [ ${#VMS[@]} -eq 0 ]; then
    echo "ERROR: no cluster VMs found on this host. Nothing to start." >&2
    echo "  Check: sudo virsh list --all" >&2
    echo "  If your nodes are named differently, set CLUSTER_VM_PATTERN." >&2
    exit 1
fi
echo "  Cluster VMs on this host: ${VMS[*]}"

for vm in "${VMS[@]}"; do
    if sudo virsh list --name | grep -qx "$vm"; then
        echo "  $vm is already running."
    else
        echo "  Starting VM: $vm"
        sudo virsh start "$vm" || echo "    WARN: failed to start $vm" >&2
    fi
done

echo "Waiting for Kubernetes API to be available..."
MAX_API_WAIT=300
API_ELAPSED=0
until $KUBECTL get nodes &>/dev/null || [ $API_ELAPSED -ge $MAX_API_WAIT ]; do
    echo -n "."
    sleep 5
    API_ELAPSED=$((API_ELAPSED + 5))
done

if [ $API_ELAPSED -ge $MAX_API_WAIT ]; then
    echo "Error: Kubernetes API did not become available after $MAX_API_WAIT seconds."
    exit 1
fi
echo " API is up."

# 1.5. Prevent admission controller deadlock (k8tz)
echo "Step 1.5: Removing potentially blocking admission controllers..."
$KUBECTL delete mutatingwebhookconfiguration k8tz --ignore-not-found

# Wait for the VMs we started to report Ready.
# Previously this waited for a hardcoded ">= 3 Ready" with no timeout, which both
# under-counted the cluster and could hang forever.
echo "Waiting for ${#VMS[@]} VM-backed nodes to be Ready..."
MAX_NODE_WAIT=420
NODE_ELAPSED=0
READY_VMS=0
while [ $NODE_ELAPSED -lt $MAX_NODE_WAIT ]; do
    READY_VMS=0
    for vm in "${VMS[@]}"; do
        st=$($KUBECTL get node "$vm" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null)
        [ "$st" = "True" ] && READY_VMS=$((READY_VMS + 1))
    done
    [ $READY_VMS -ge ${#VMS[@]} ] && break
    echo "  ${READY_VMS}/${#VMS[@]} Ready (${NODE_ELAPSED}/${MAX_NODE_WAIT}s)..."
    sleep 10
    NODE_ELAPSED=$((NODE_ELAPSED + 10))
done

if [ $READY_VMS -lt ${#VMS[@]} ]; then
    echo "WARNING: only ${READY_VMS}/${#VMS[@]} VM-backed nodes are Ready after ${MAX_NODE_WAIT}s." >&2
    echo "  Continuing, but storage restore below may fail or hang." >&2
else
    echo "  All ${#VMS[@]} VM-backed nodes are Ready."
fi

# Report cluster nodes this host does not own — e.g. the external GPU node, which
# cluster-shutdown.sh drains but leaves running and which nothing here can boot.
NON_VM_NODES=()
for n in $($KUBECTL get nodes -o name 2>/dev/null | cut -d'/' -f2 | sort); do
    printf '%s\n' "${VMS[@]}" | grep -qx "$n" || NON_VM_NODES+=("$n")
done
if [ ${#NON_VM_NODES[@]} -gt 0 ]; then
    echo ""
    echo "Kubernetes nodes NOT hosted on hierophant (not started by this script):"
    for n in "${NON_VM_NODES[@]}"; do
        st=$($KUBECTL get node "$n" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null)
        if [ "$st" = "True" ]; then
            echo "  - $n : Ready"
        else
            echo "  - $n : NOT Ready — power it on manually, then re-run step 2 below" >&2
        fi
    done
    echo ""
fi

# 2. Uncordon nodes
echo "Step 2: Uncordoning nodes..."
for node in $($KUBECTL get nodes -o name 2>/dev/null); do
    if $KUBECTL uncordon "$node" 2>/dev/null; then
        echo "  Uncordoned $node"
    else
        echo "  WARN: could not uncordon $node (unreachable?)" >&2
    fi
done

# 3. Restore original scale values
echo "Step 3: Restoring original scale values..."
if [ -f "$REPLICA_FILE" ] && [ -s "$REPLICA_FILE" ]; then
    # Order of restoration:
    # For Rook-Ceph: mon -> osd -> others
    # Then everything else

    # 3a. Rook Mons
    echo "Restoring Rook Mons..."
    grep "$ROOK_NS" "$REPLICA_FILE" | grep "mon" | while read -r ns res count; do
        echo "Restoring $res in $ns to $count..."
        $KUBECTL scale "$res" -n "$ns" --replicas="$count"
    done

    # Wait for Mons to be available
    echo "Waiting for Mons to be ready..."
    sleep 30

    # 3b. Rook OSDs
    echo "Restoring Rook OSDs..."
    grep "$ROOK_NS" "$REPLICA_FILE" | grep "osd" | while read -r ns res count; do
        echo "Restoring $res in $ns to $count..."
        $KUBECTL scale "$res" -n "$ns" --replicas="$count"
    done

    echo "Waiting for OSDs to initialize..."
    sleep 60

    # 3c. Unset ceph maintenance flags
    echo "Step 3c: Unsetting ceph maintenance flags..."
    
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

    # Wait for Operator pod to be available
    echo "Waiting for Rook Operator to be ready..."
    $KUBECTL wait --for=condition=ready pod -l app=rook-ceph-operator -n "$ROOK_NS" --timeout=120s 2>/dev/null

    echo "Waiting for Ceph health to become available..."
    MAX_HEALTH_WAIT=120
    HEALTH_ELAPSED=0
    until run_ceph_cmd "health" &>/dev/null || [ $HEALTH_ELAPSED -ge $MAX_HEALTH_WAIT ]; do
        echo -n "."
        sleep 5
        HEALTH_ELAPSED=$((HEALTH_ELAPSED + 5))
    done
    echo "Unfreezing Ceph state (unsetting noout, nobackfill, norecover, noscrub, nodeep-scrub)..."
    for flag in noout nobackfill norecover noscrub nodeep-scrub; do
        run_ceph_cmd "osd unset $flag"
    done

    # 3d. Other Rook components
    echo "Restoring other Rook components..."
    grep "$ROOK_NS" "$REPLICA_FILE" | grep -v "mon" | grep -v "osd" | while read -r ns res count; do
        echo "Restoring $res in $ns to $count..."
        $KUBECTL scale "$res" -n "$ns" --replicas="$count"
    done

    # 3e. Everything else (Restore in REVERSE order of shutdown)
    echo "Restoring all other resources..."
    grep -v "$ROOK_NS" "$REPLICA_FILE" | tac | while read -r ns res count; do
        echo "Restoring $res in $ns to $count..."
        $KUBECTL scale "$res" -n "$ns" --replicas="$count"
    done

    # Final Ceph health check
    echo "Final Ceph health check..."
    sleep 30
    run_ceph_cmd "health"
else
    echo "Warning: $REPLICA_FILE not found or empty. Skipping scale restoration."
fi

# 4. Final adjustments
echo "Step 4: Final adjustments..."
if command -v helm &> /dev/null; then
    echo "Restoring k8tz admission controller..."
    helm upgrade --install k8tz k8tz/k8tz --set timezone=Europe/London --namespace default
else
    echo "Warning: helm not found. Cannot restore k8tz admission controller."
fi
echo "Cluster startup complete."
