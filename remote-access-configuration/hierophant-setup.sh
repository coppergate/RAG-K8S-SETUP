#!/usr/bin/env bash
# hierophant-setup.sh
# Run once on hierophant (as root or with sudo) to install the libvirt
# network hook that allows forwarding from hegemon into the Talos cluster.
#
# Usage: sudo bash /mnt/hegemon-share/share/code/kubernetes-setup/remote-access-configuration/hierophant-setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SRC="$SCRIPT_DIR/hierophant-libvirt-hook.sh"
HOOK_DEST="/etc/libvirt/hooks/network"

if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] Run as root: sudo bash $0"
    exit 1
fi

# ── Libvirt hook ─────────────────────────────────────────────────────────────

echo "[INFO] Installing libvirt network hook..."
mkdir -p /etc/libvirt/hooks

if [ -f "$HOOK_DEST" ] && ! grep -q "hierophant.*talos-bridge" "$HOOK_DEST" 2>/dev/null; then
    echo "[WARN] $HOOK_DEST already exists with different content."
    echo "       Backing up to ${HOOK_DEST}.bak and replacing."
    cp "$HOOK_DEST" "${HOOK_DEST}.bak"
fi

cp "$HOOK_SRC" "$HOOK_DEST"
chmod 755 "$HOOK_DEST"
echo "[OK] Hook installed to $HOOK_DEST"

# ── Apply rule now (without waiting for network restart) ─────────────────────

echo "[INFO] Applying nftables rule immediately..."

# Determine the libvirt network that manages talos-bridge
# (try common names; the hook handles this generically at runtime)
TALOS_NET=$(virsh net-list --all 2>/dev/null \
            | awk 'NR>2 && $1!="" {print $1}' \
            | while read -r net; do
                virsh net-info "$net" 2>/dev/null \
                  | grep -q "talos" && echo "$net" && break
              done || true)

if [ -n "$TALOS_NET" ]; then
    bash "$HOOK_DEST" "$TALOS_NET" started - -
else
    # Call with a dummy name; hook checks for talos-bridge existence directly
    bash "$HOOK_DEST" talos started - -
fi

echo "[OK] Rule applied."
echo ""
echo "[DONE] hierophant setup complete."
echo "       Rule will re-apply automatically on next libvirt network start."
