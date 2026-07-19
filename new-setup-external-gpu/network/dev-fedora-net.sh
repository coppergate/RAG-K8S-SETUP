#!/usr/bin/env bash
# ==============================================================================
# DEV-FEDORA NETWORK — new-setup-external-gpu (flat LAN)
#
# Run INSIDE the dev-fedora VM after its NIC has been bridged onto the LAN
# (see hegemon-host-net.sh). Gives the VM a static LAN address and installs the
# kubeconfig + talosconfig so kubectl/talosctl reach the cluster VIP directly —
# no routes, no NAT, no relay.
#
#   VM IP    : 192.168.1.50/16   Gateway: 192.168.0.1   DNS: 192.168.1.210
#   Cluster  : https://192.168.5.10:6443 (VIP, aka k8s-api.hierocracy.home)
#
# Usage: bash dev-fedora-net.sh
#   Override the NIC autodetect with: LAN_IFACE=enp1s0 bash dev-fedora-net.sh
# ==============================================================================
set -euo pipefail

VM_IP="192.168.1.50/16"
GATEWAY="192.168.0.1"
DNS="192.168.1.210,1.1.1.1,8.8.8.8"
DNS_SEARCH="hierocracy,hierocracy.home"

HIEROPHANT="192.168.1.101"
SSH_USER="junie"
SSH_KEY="$HOME/.ssh/id_hierophant_access"
KUBECONFIG_SRC="/home/k8s/kube/config/kubeconfig"
TALOSCONFIG_SRC="/home/k8s/talos/config/talosconfig"
KUBECONFIG_DEST="$HOME/.kube/config-talos"
TALOSCONFIG_DEST="$HOME/.talos/config"
BASHRC="$HOME/.bashrc"

# ── Static LAN address ───────────────────────────────────────────────────────
IFACE="${LAN_IFACE:-$(nmcli -t -g DEVICE,TYPE device status \
        | awk -F: '$2=="ethernet"{print $1; exit}')}"
if [ -z "${IFACE}" ]; then
    echo "ERROR: could not autodetect a LAN ethernet device. Set LAN_IFACE=..." >&2
    exit 1
fi
echo "[DEV-NET] Using interface: ${IFACE}"

CON="$(nmcli -t -g GENERAL.CONNECTION device show "${IFACE}" 2>/dev/null | head -n1)"
if [ -z "${CON}" ] || [ "${CON}" = "--" ]; then
    CON="lan-static"
    sudo nmcli connection add type ethernet con-name "${CON}" ifname "${IFACE}"
fi
echo "[DEV-NET] Configuring connection '${CON}' -> ${VM_IP}..."
sudo nmcli connection modify "${CON}" \
    ipv4.method manual ipv4.addresses "${VM_IP}" ipv4.gateway "${GATEWAY}" \
    ipv4.dns "${DNS}" ipv4.dns-search "${DNS_SEARCH}" ipv6.method disabled
# Drop the stale Talos route from the old relay design, if present.
sudo nmcli connection modify "${CON}" -ipv4.routes "10.0.0.0/24 172.16.1.1" 2>/dev/null || true
sudo nmcli connection up "${CON}"

# ── kubeconfig + talosconfig ─────────────────────────────────────────────────
echo "[DEV-NET] Fetching kubeconfig and talosconfig from hierophant..."
mkdir -p "$(dirname "${KUBECONFIG_DEST}")" "$(dirname "${TALOSCONFIG_DEST}")"
scp -o BatchMode=yes -i "${SSH_KEY}" "${SSH_USER}@${HIEROPHANT}:${KUBECONFIG_SRC}"  "${KUBECONFIG_DEST}"
scp -o BatchMode=yes -i "${SSH_KEY}" "${SSH_USER}@${HIEROPHANT}:${TALOSCONFIG_SRC}" "${TALOSCONFIG_DEST}"
chmod 600 "${KUBECONFIG_DEST}" "${TALOSCONFIG_DEST}"

# ── Shell exports ────────────────────────────────────────────────────────────
add_export() {
    local line="$1"
    grep -qF "$line" "${BASHRC}" 2>/dev/null || {
        printf '%s\n' "$line" >> "${BASHRC}"
        echo "[DEV-NET] Added to ${BASHRC}: $line"
    }
}
add_export "export KUBECONFIG=${KUBECONFIG_DEST}"
add_export "export TALOSCONFIG=${TALOSCONFIG_DEST}"

# ── Verify ───────────────────────────────────────────────────────────────────
echo ""
echo "[DEV-NET] Verifying cluster access (VIP 192.168.5.10)..."
if command -v kubectl >/dev/null 2>&1; then
    KUBECONFIG="${KUBECONFIG_DEST}" kubectl get nodes || \
        echo "  (kubectl could not reach the cluster yet — is it up?)"
else
    echo "  kubectl not installed; kubeconfig saved to ${KUBECONFIG_DEST}"
fi
echo ""
echo "[DEV-NET] Done. Open a new shell or: source ${BASHRC}"
