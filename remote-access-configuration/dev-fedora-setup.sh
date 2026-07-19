#!/usr/bin/env bash
# dev-fedora-setup.sh
# Run once on dev-fedora to persist the route to the Talos cluster network
# and install the kubeconfig for kubectl access.
#
# Usage: bash dev-fedora-setup.sh

set -euo pipefail

KUBECONFIG_SRC="junie@192.168.1.101:/home/k8s/kube/config/kubeconfig"
KUBECONFIG_DEST="$HOME/.kube/config-talos"
SSH_KEY="$HOME/.ssh/id_hierophant_access"
NM_CONNECTION="agent-link"
ROUTE="10.0.0.0/24 172.16.1.1"
BASHRC="$HOME/.bashrc"
KUBECONFIG_EXPORT="export KUBECONFIG=$KUBECONFIG_DEST"

# ── Route ────────────────────────────────────────────────────────────────────

echo "[INFO] Adding persistent route $ROUTE via $NM_CONNECTION..."
existing=$(nmcli -g ipv4.routes connection show "$NM_CONNECTION" 2>/dev/null || true)
if echo "$existing" | grep -q "10.0.0.0/24"; then
    echo "[SKIP] Route already present in NetworkManager connection."
else
    nmcli connection modify "$NM_CONNECTION" +ipv4.routes "$ROUTE"
    nmcli connection up "$NM_CONNECTION"
    echo "[OK] Route added and connection reloaded."
fi

# ── kubeconfig ───────────────────────────────────────────────────────────────

echo "[INFO] Copying kubeconfig from hierophant..."
mkdir -p "$(dirname "$KUBECONFIG_DEST")"
scp -i "$SSH_KEY" "$KUBECONFIG_SRC" "$KUBECONFIG_DEST"
chmod 600 "$KUBECONFIG_DEST"
echo "[OK] kubeconfig saved to $KUBECONFIG_DEST"

# ── Shell export ─────────────────────────────────────────────────────────────

if grep -qF "$KUBECONFIG_EXPORT" "$BASHRC" 2>/dev/null; then
    echo "[SKIP] KUBECONFIG export already in $BASHRC"
else
    echo "" >> "$BASHRC"
    echo "# Talos cluster kubectl access" >> "$BASHRC"
    echo "$KUBECONFIG_EXPORT" >> "$BASHRC"
    echo "[OK] Added KUBECONFIG export to $BASHRC"
fi

# ── Verify ───────────────────────────────────────────────────────────────────

echo ""
echo "[INFO] Verifying kubectl access..."
KUBECONFIG="$KUBECONFIG_DEST" kubectl cluster-info
echo ""
echo "[DONE] dev-fedora setup complete."
echo "       Run: source ~/.bashrc   (or open a new shell)"
