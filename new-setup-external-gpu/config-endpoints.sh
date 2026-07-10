
# ==============================================================================
# ENDPOINT CONFIGURATION — new-setup-external-gpu
#
# TWO-PHASE ADDRESSING
# --------------------
# Phase 1 — Boot/install time:
#   Nodes get 10.0.0.x IPs via DHCP on talos-nat (libvirt NAT network).
#   These are used ONLY for the initial 'talosctl apply-config --insecure'
#   calls (maintenance mode contact) before nodes have their static IPs.
#   Resolved dynamically via virsh domifaddr.
#
# Phase 2 — Ongoing management:
#   After config is applied and nodes reboot, eth1 (lb-net / br-app) gets
#   static 172.20.x.x IPs. These are the permanent management addresses
#   and are what talosconfig endpoints point to.
#   The control-plane VIP (172.20.0.15) lives on eth1 of control-plane nodes.
#
# The external GPU inference node (172.20.1.120) has NO talos-nat interface —
# it is a physical machine on the 172.20.x.x network only.
# ==============================================================================

source ${SETUP_ROOT}/new-setup-external-gpu/config-env.sh
source ${SETUP_ROOT}/new-setup-external-gpu/utils.sh

# ---------------------------------------------------------------------------
# Phase 2: Static management IPs on lb-net (172.20.x.x)
# These are the authoritative addresses for all ongoing cluster operations.
# ---------------------------------------------------------------------------

# Control plane VIP — floating IP on eth1 of whichever CP node is leader
CP_VIP="172.20.0.15"
export CP_VIP

# Control plane node static IPs on lb-net (eth1)
CP_IP_0="172.20.0.100"
export CP_IP_0
CP_IP_1="172.20.0.101"
export CP_IP_1
CP_IP_2="172.20.0.102"
export CP_IP_2

# Worker node static IPs on lb-net (eth1)
WORKER_IP_0="172.20.0.110"
export WORKER_IP_0
WORKER_IP_1="172.20.0.111"
export WORKER_IP_1
WORKER_IP_2="172.20.0.112"
export WORKER_IP_2
WORKER_IP_3="172.20.0.113"
export WORKER_IP_3

# External GPU inference node static IP on lb-net (physical NIC)
# This is a physical machine — it has no talos-nat interface.
INFERENCE_IP_0="172.20.1.120"
export INFERENCE_IP_0

# ---------------------------------------------------------------------------
# Phase 1: Boot-time DHCP IPs on talos-nat (10.0.0.x)
# Used ONLY for initial 'talosctl apply-config --insecure' in maintenance mode.
# Resolved via virsh domifaddr (DHCP leases assigned in 07-config-vm-net.sh).
# ---------------------------------------------------------------------------

BOOT_IP_0=$(getNodeIP "control-0")
export BOOT_IP_0
BOOT_IP_1=$(getNodeIP "control-1")
export BOOT_IP_1
BOOT_IP_2=$(getNodeIP "control-2")
export BOOT_IP_2

BOOT_WORKER_IP_0=$(getNodeIP "worker-0")
export BOOT_WORKER_IP_0
BOOT_WORKER_IP_1=$(getNodeIP "worker-1")
export BOOT_WORKER_IP_1
BOOT_WORKER_IP_2=$(getNodeIP "worker-2")
export BOOT_WORKER_IP_2
BOOT_WORKER_IP_3=$(getNodeIP "worker-3")
export BOOT_WORKER_IP_3

echo "----|||||-------|||||----"
echo "=== Management IPs (172.20.x.x / lb-net) ==="
echo "CP_VIP      : ${CP_VIP}"
echo "CP_IP_0     : ${CP_IP_0}"
echo "CP_IP_1     : ${CP_IP_1}"
echo "CP_IP_2     : ${CP_IP_2}"
echo "WORKER_IP_0 : ${WORKER_IP_0}"
echo "WORKER_IP_1 : ${WORKER_IP_1}"
echo "WORKER_IP_2 : ${WORKER_IP_2}"
echo "WORKER_IP_3 : ${WORKER_IP_3}"
echo "INFERENCE_IP_0 : ${INFERENCE_IP_0}"
echo ""
echo "=== Boot-time IPs (10.0.0.x / talos-nat, for initial apply-config) ==="
echo "BOOT_IP_0        : ${BOOT_IP_0}"
echo "BOOT_IP_1        : ${BOOT_IP_1}"
echo "BOOT_IP_2        : ${BOOT_IP_2}"
echo "BOOT_WORKER_IP_0 : ${BOOT_WORKER_IP_0}"
echo "BOOT_WORKER_IP_1 : ${BOOT_WORKER_IP_1}"
echo "BOOT_WORKER_IP_2 : ${BOOT_WORKER_IP_2}"
echo "BOOT_WORKER_IP_3 : ${BOOT_WORKER_IP_3}"
echo "----|||||-------|||||----"
