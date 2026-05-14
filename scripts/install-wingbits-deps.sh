#!/bin/bash
# Install Wingbits dependencies: udev rule and readsb systemd override.
# Safe to re-run. Run once before wingbits-setup.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UDEV_SRC="${SCRIPT_DIR}/udev/99-rtlsdr.rules"
OVERRIDE_SRC="${SCRIPT_DIR}/../systemd/readsb-override.conf"

UDEV_DST="/etc/udev/rules.d/99-rtlsdr.rules"
OVERRIDE_DIR="/etc/systemd/system/readsb.service.d"
OVERRIDE_DST="${OVERRIDE_DIR}/override.conf"

echo "=== Wingbits Dependencies Install ==="

# --- udev rule ---
if [ -f "$UDEV_SRC" ]; then
    cp "$UDEV_SRC" "$UDEV_DST"
    echo "[OK] Copied udev rule to ${UDEV_DST}"
    udevadm control --reload-rules && udevadm trigger
    echo "[OK] udev rules reloaded and triggered"
else
    echo "[WARN] udev rule not found at ${UDEV_SRC} — skipping"
fi

# --- systemd override ---
if [ -f "$OVERRIDE_SRC" ]; then
    mkdir -p "$OVERRIDE_DIR"
    cp "$OVERRIDE_SRC" "$OVERRIDE_DST"
    echo "[OK] Copied systemd override to ${OVERRIDE_DST}"
else
    echo "[WARN] systemd override not found at ${OVERRIDE_SRC} — skipping"
fi

systemctl daemon-reload
echo "[OK] systemd daemon-reload complete"

echo "=== Wingbits Dependencies Install Complete ==="
