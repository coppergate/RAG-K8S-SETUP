#!/usr/bin/env bash
# hegemon-setup.sh
# Run once on hegemon (as root or with sudo) to:
#   1. Persist the route to the Talos cluster via hierophant
#   2. Install the libvirt network hook for nftables rules
#
# Usage: sudo bash hegemon-setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SRC="$SCRIPT_DIR/hegemon-libvirt-hook.sh"
HOOK_DEST="/etc/libvirt/hooks/network"
NM_CONNECTION="eno1"
ROUTE="10.0.0.0/24 192.168.1.101"

if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] Run as root: sudo bash $0"
    exit 1
fi

# ── Route ────────────────────────────────────────────────────────────────────

echo "[INFO] Adding persistent route $ROUTE on $NM_CONNECTION..."

# Find the actual NM connection name for eno1 if it differs
NM_CONN_NAME=$(nmcli -g NAME,DEVICE connection show --active \
               | awk -F: '$2=="eno1"{print $1; exit}')

if [ -z "$NM_CONN_NAME" ]; then
    # Fallback: eno1 may not be active or named differently
    NM_CONN_NAME=$(nmcli -g NAME,DEVICE connection show \
                   | awk -F: '$2=="eno1"{print $1; exit}')
fi

if [ -z "$NM_CONN_NAME" ]; then
    echo "[WARN] Could not find NM connection for eno1. Add route manually:"
    echo "       nmcli connection modify <eno1-connection> +ipv4.routes \"$ROUTE\""
else
    existing=$(nmcli -g ipv4.routes connection show "$NM_CONN_NAME" 2>/dev/null || true)
    if echo "$existing" | grep -q "10.0.0.0/24"; then
        echo "[SKIP] Route already present in connection '$NM_CONN_NAME'."
    else
        nmcli connection modify "$NM_CONN_NAME" +ipv4.routes "$ROUTE"
        nmcli connection up "$NM_CONN_NAME" || true
        echo "[OK] Route added to connection '$NM_CONN_NAME'."
    fi
fi

# ── Libvirt hook ─────────────────────────────────────────────────────────────

echo "[INFO] Installing libvirt network hook..."
mkdir -p /etc/libvirt/hooks

if [ -f "$HOOK_DEST" ] && ! grep -q "hegemon agent-link" "$HOOK_DEST" 2>/dev/null; then
    echo "[WARN] $HOOK_DEST already exists with different content."
    echo "       Backing up to ${HOOK_DEST}.bak and replacing."
    cp "$HOOK_DEST" "${HOOK_DEST}.bak"
fi

cp "$HOOK_SRC" "$HOOK_DEST"
chmod 755 "$HOOK_DEST"
echo "[OK] Hook installed to $HOOK_DEST"

# ── Apply rules now (without waiting for reboot) ─────────────────────────────

echo "[INFO] Applying nftables rules immediately..."
bash "$HOOK_DEST" agent-link started - -
echo "[OK] Rules applied."

echo ""
echo "[DONE] hegemon setup complete."
echo "       Rules will re-apply automatically on next libvirt network start."
