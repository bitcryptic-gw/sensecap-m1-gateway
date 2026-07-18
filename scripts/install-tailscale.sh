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
    MAX_RETRIES=3
    unset SCRIPT
    for attempt in $(seq 1 $MAX_RETRIES); do
        echo "[..] Downloading official install script (attempt ${attempt}/${MAX_RETRIES})..."
        if SCRIPT=$(curl -fsSL https://tailscale.com/install.sh); then
            break
        fi
        if [ "$attempt" -lt "$MAX_RETRIES" ]; then
            delay=$((attempt * 5))
            sleep "$delay"
        fi
    done
    if [ -z "${SCRIPT:-}" ]; then
        echo "ERROR: Failed to fetch Tailscale install script after ${MAX_RETRIES} attempts — check network connectivity" >&2
        exit 1
    fi

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

# Set operator so gateway-ui wrapper can modify Tailscale prefs without sudo
echo "[..] Setting tailscale operator to gateway-ui..."
/usr/bin/tailscale set --operator=gateway-ui 2>/dev/null || {
    echo "[WARN] Could not set operator — Tailscale may not yet be authenticated."
    echo "[NOTE] After running 'tailscale up', re-run: sudo tailscale set --operator=gateway-ui"
}

echo ""
echo "=== Next Step ==="
echo "Open the Gateway UI Network tab to authenticate with an auth key"
echo "(a reusable, pre-approved key is recommended — it is persisted to"
echo "/etc/gateway/tailscale.key, 0600 root:root, so the device can"
echo "re-authenticate unattended if its machine record is ever deleted)."
echo "Or run: sudo tailscale up --auth-key=tskey-auth-..."
