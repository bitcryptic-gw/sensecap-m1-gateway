#!/usr/bin/env bash
# install-tailscale.sh — install Tailscale on Debian Trixie (ARM64)
# Run once during provisioning: sudo /opt/gateway/scripts/install-tailscale.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root." >&2
    exit 1
fi

echo "=== Tailscale Install ==="

if command -v tailscale &>/dev/null; then
    echo "[OK] Tailscale already installed: $(tailscale version 2>/dev/null | head -1)"
    systemctl enable --now tailscaled 2>/dev/null || true
    exit 0
fi

echo "[..] Downloading official install script..."
SCRIPT=$(curl -fsSL https://tailscale.com/install.sh) || {
    echo "ERROR: Failed to fetch install script" >&2
    exit 1
}

echo "$SCRIPT" | sh

systemctl enable --now tailscaled
echo "[OK] tailscaled enabled and started"

# Add sudoers entry for gateway-ui user to run tailscale up
SUDOERS_FILE="/etc/sudoers.d/10-gateway-ui"
TAILSCALE_ENTRY="gateway-ui ALL=(root) NOPASSWD: /usr/bin/tailscale up"
if [ -f "$SUDOERS_FILE" ]; then
    if ! grep -qF "$TAILSCALE_ENTRY" "$SUDOERS_FILE" 2>/dev/null; then
        echo "$TAILSCALE_ENTRY" >> "$SUDOERS_FILE"
        visudo -c -f "$SUDOERS_FILE" || {
            echo "ERROR: sudoers validation failed — reverting" >&2
            sed -i '/tailscale up/d' "$SUDOERS_FILE"
        }
        echo "[OK] Added sudoers entry for gateway-ui to run tailscale up"
    else
        echo "[OK] sudoers entry already present"
    fi
else
    echo "[WARN] $SUDOERS_FILE not found — sudoers entry not added"
    echo "[WARN] gateway-ui will need sudo access to run tailscale up"
fi

echo ""
echo "=== Next Step ==="
echo "Open the Gateway UI Network tab to authenticate with an auth key."
echo "Or run: sudo tailscale up --authkey=tskey-auth-..."
