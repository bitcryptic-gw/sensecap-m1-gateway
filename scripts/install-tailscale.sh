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
else
    echo "[..] Downloading official install script..."
    SCRIPT=$(curl -fsSL https://tailscale.com/install.sh) || {
        echo "ERROR: Failed to fetch install script" >&2
        exit 1
    }

    echo "$SCRIPT" | sh

    systemctl enable --now tailscaled
    echo "[OK] tailscaled enabled and started"
fi

# Remove old sudoers entry — replaced by setuid wrapper
SUDOERS_FILE="/etc/sudoers.d/10-gateway-ui"
if [ -f "$SUDOERS_FILE" ]; then
    if grep -qF "tailscale up" "$SUDOERS_FILE" 2>/dev/null; then
        sed -i '/tailscale up/d' "$SUDOERS_FILE"
        echo "[OK] Removed old sudoers entry for tailscale up"
    else
        echo "[OK] No old sudoers entry to remove"
    fi
    # Remove file if empty
    if [ ! -s "$SUDOERS_FILE" ]; then
        rm -f "$SUDOERS_FILE"
        echo "[OK] Removed empty sudoers file"
    fi
fi

# Build and install tailscale-wrapper
echo "[..] Building tailscale-wrapper..."
gcc -O2 -Wall -o /usr/local/bin/tailscale-wrapper \
    /opt/gateway/scripts/tailscale-wrapper.c
chown root:root /usr/local/bin/tailscale-wrapper
chmod 4755 /usr/local/bin/tailscale-wrapper
echo "[OK] tailscale-wrapper installed (setuid root)"

echo ""
echo "=== Next Step ==="
echo "Open the Gateway UI Network tab to authenticate with an auth key."
echo "Or run: sudo tailscale up --authkey=tskey-auth-..."
