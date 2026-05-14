#!/bin/bash
# Wingbits setup / reconfiguration script.
# Usage: sudo wingbits-setup.sh "<install-url>"
#
# Accepts the station-specific install URL from the Wingbits dashboard
# ("BYOD Install" button).  Idempotent and re-runnable — safe for
# first-time setup, station relocation, or station ID change.
set -euo pipefail

URL_PATTERN='^https://gitlab\.com/wingbits/config/-/raw/'

# --- Preflight ---
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root (sudo)." >&2
    exit 1
fi

URL="${1:-}"
if [ -z "$URL" ]; then
    echo "ERROR: No install URL provided." >&2
    echo "Usage: $0 \"https://gitlab.com/wingbits/config/-/raw/install.sh?station_id=<id>&token=<token>\"" >&2
    exit 1
fi

if ! echo "$URL" | grep -qE "$URL_PATTERN"; then
    echo "ERROR: URL does not match expected Wingbits GitLab pattern." >&2
    echo "  Expected prefix: https://gitlab.com/wingbits/config/-/raw/" >&2
    echo "  Got: ${URL}" >&2
    exit 1
fi

# --- Detect reconfiguration ---
IS_RECONFIG=false
if systemctl list-unit-files --type=service | grep -q '^wingbits\.service'; then
    IS_RECONFIG=true
    echo "=== Wingbits Reconfiguration ==="
    echo "[INFO] Wingbits appears already installed — stopping services..."
    systemctl stop readsb.service 2>/dev/null || true
    systemctl stop wingbits.service 2>/dev/null || true
else
    echo "=== Wingbits Setup ==="
fi

# --- Run official Wingbits install script ---
echo "[INFO] Running Wingbits install script..."
bash <(curl -s "$URL")

# --- Patch /etc/default/readsb for beast mode ---
READSB_DEFAULT="/etc/default/readsb"
BEAST_OPTIONS="--net-connector localhost,30015,beast_reduce_out --net-beast-reduce-optimize-for-mlat --net-beast-reduce-interval=0.125"

if [ -f "$READSB_DEFAULT" ]; then
    if grep -qF "$BEAST_OPTIONS" "$READSB_DEFAULT"; then
        echo "[OK] Beast mode already configured in ${READSB_DEFAULT}"
    else
        echo "[INFO] Adding beast mode options to ${READSB_DEFAULT}"
        # Shell-quote safe replacement: append BEAST_OPTIONS to NET_OPTIONS
        sed -i "s|^NET_OPTIONS=\\(.*\\)|NET_OPTIONS=\\1 $BEAST_OPTIONS|" "$READSB_DEFAULT"
        echo "[OK] Beast mode options added"
    fi
else
    echo "[WARN] ${READSB_DEFAULT} not found — creating"
    echo "NET_OPTIONS=\"${BEAST_OPTIONS}\"" > "$READSB_DEFAULT"
    echo "[OK] Created ${READSB_DEFAULT} with beast mode options"
fi

# --- Restart services ---
echo "[INFO] Restarting readsb.service..."
systemctl restart readsb.service

echo "[INFO] Restarting wingbits.service..."
systemctl restart wingbits.service

# --- Status check ---
echo ""
echo "=== Service Status ==="
wingbits status 2>&1 || true

# --- Next steps ---
echo ""
echo "=== Next Steps ==="
if [ "$IS_RECONFIG" = true ]; then
    echo "Reconfiguration complete."
    echo "If you changed the station ID: link or re-link your GeoSigner"
    echo "in the Wingbits dashboard under My Stations."
else
    echo "Setup complete."
    echo "Next: link your GeoSigner in the Wingbits dashboard under My Stations."
fi
echo "Then verify both readsb and wingbits services show Running in the Gateway UI."
