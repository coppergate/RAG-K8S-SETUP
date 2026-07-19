
# ==============================================================================
# ENDPOINT CONFIGURATION — new-setup-external-gpu (flat LAN design)
#
# ADDRESSING
# ----------
# All nodes live on the flat physical LAN (192.168.0.0/16, gateway 192.168.0.1,
# DNS 192.168.1.210). The router's DHCP only allocates 192.168.0.2-254, so the
# cluster uses static addresses in 192.168.5.x (well clear of the DHCP pool).
#
# Phase 1 — Boot/install time:
#   Nodes boot the Talos ISO into maintenance mode and DHCP a temporary
#   192.168.0.x lease from the router. Used ONLY for the initial
#   'talosctl apply-config --insecure'. Discovered via getNodeIP (ARP-based;
#   see utils.sh) since a pure bridge has no libvirt DHCP leases.
#
# Phase 2 — Ongoing management:
#   After config is applied and nodes reboot, eth0 gets its static 192.168.5.x
#   address. These are the permanent management addresses and what talosconfig
#   endpoints point to. The control-plane VIP (192.168.5.10) floats on eth0 of
#   whichever control-plane node is leader.
#
# The external GPU inference node (192.168.5.31) is a physical machine on the
# same flat LAN — nothing special about its network path.
# ==============================================================================

source ${SETUP_ROOT}/new-setup-external-gpu/config-env.sh
source ${SETUP_ROOT}/new-setup-external-gpu/utils.sh

# ---------------------------------------------------------------------------
# Phase 2: Static management IPs on the flat LAN (192.168.5.x)
# These are the authoritative addresses for all ongoing cluster operations.
# ---------------------------------------------------------------------------

# Control plane VIP — floating IP on eth0 of whichever CP node is leader.
# Also resolvable as k8s-api.hierocracy.home.
CP_VIP="192.168.5.10"
export CP_VIP

# Control plane node static IPs (eth0)
CP_IP_0="192.168.5.11"
export CP_IP_0
CP_IP_1="192.168.5.12"
export CP_IP_1
CP_IP_2="192.168.5.13"
export CP_IP_2

# Worker node static IPs (eth0)
WORKER_IP_0="192.168.5.21"
export WORKER_IP_0
WORKER_IP_1="192.168.5.22"
export WORKER_IP_1
WORKER_IP_2="192.168.5.23"
export WORKER_IP_2
WORKER_IP_3="192.168.5.24"
export WORKER_IP_3

# External GPU inference node static IP (physical NIC).
INFERENCE_IP_0="192.168.5.31"
export INFERENCE_IP_0

# ---------------------------------------------------------------------------
# Phase 1: Boot-time DHCP IPs (192.168.0.x from the router)
# Used ONLY for initial 'talosctl apply-config --insecure' in maintenance mode.
# Resolved via getNodeIP (ARP-based MAC lookup on br-lan; see utils.sh).
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
echo "=== Management IPs (static, 192.168.5.x / flat LAN) ==="
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
echo "=== Boot-time IPs (192.168.0.x DHCP, for initial apply-config) ==="
echo "BOOT_IP_0        : ${BOOT_IP_0}"
echo "BOOT_IP_1        : ${BOOT_IP_1}"
echo "BOOT_IP_2        : ${BOOT_IP_2}"
echo "BOOT_WORKER_IP_0 : ${BOOT_WORKER_IP_0}"
echo "BOOT_WORKER_IP_1 : ${BOOT_WORKER_IP_1}"
echo "BOOT_WORKER_IP_2 : ${BOOT_WORKER_IP_2}"
echo "BOOT_WORKER_IP_3 : ${BOOT_WORKER_IP_3}"
echo "----|||||-------|||||----"
