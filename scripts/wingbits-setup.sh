#!/bin/bash
# Wingbits setup / reconfiguration script.
# Usage: sudo wingbits-setup.sh --loc "<lat>, <lon>" --id "<station-id>"
#
# Accepts location (lat,lon) and station ID, then fetches and runs the
# official Wingbits install script with those parameters.
# Idempotent and re-runnable — safe for first-time setup, station
# relocation, or station ID change.
set -euo pipefail

WINGBITS_DOWNLOAD_URL="https://gitlab.com/wingbits/config/-/raw/master/download.sh"

# --- Preflight ---
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root (sudo)." >&2
    exit 1
fi

LOC=""
ID=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --loc) LOC="$2"; shift 2 ;;
        --id)  ID="$2";  shift 2 ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            echo "Usage: $0 --loc \"<lat>, <lon>\" --id \"<station-id>\"" >&2
            exit 1
            ;;
    esac
done

if [ -z "$LOC" ] || [ -z "$ID" ]; then
    echo "ERROR: Both --loc and --id are required." >&2
    echo "Usage: $0 --loc \"<lat>, <lon>\" --id \"<station-id>\"" >&2
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
curl -sL "$WINGBITS_DOWNLOAD_URL" | loc="$LOC" id="$ID" bash

# Beast-mode flags for readsb are configured by the upstream Wingbits
# install script (download.sh) at line 54 above — confirmed via direct
# trace that this always completes synchronously before this point.
# A redundant patch here was removed (it never ran in practice, since
# the upstream script already wrote the matching flags every time, but
# it was fragile and added no value). See project knowledge doc,
# "readsb crash-loop" entry, for the full investigation.

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
