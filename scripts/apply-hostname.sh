#!/bin/bash
# Apply system hostname change — atomic OS-level + Tailscale rename.
# Usage: apply-hostname.sh <hostname>
# Exit codes:
#   0 — full success (OS rename + Tailscale rename both succeeded)
#   1 — OS rename failed (hostname invalid or hostnamectl failed)
#   2 — partial success (OS renamed, Tailscale rename failed)
set -euo pipefail

HOSTNAME_RE='^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$'

NEW_NAME="${1:-}"
if [ -z "$NEW_NAME" ]; then
    echo "[apply-hostname] ERROR: No hostname specified." >&2
    exit 1
fi

LEN=${#NEW_NAME}
if [ "$LEN" -lt 1 ] || [ "$LEN" -gt 63 ]; then
    echo "[apply-hostname] ERROR: Hostname must be 1–63 characters." >&2
    exit 1
fi

if ! echo "$NEW_NAME" | grep -qE "$HOSTNAME_RE"; then
    echo "[apply-hostname] ERROR: Invalid hostname '${NEW_NAME}' — must be alphanumeric and hyphens only, not start or end with a hyphen." >&2
    exit 1
fi

echo "[apply-hostname] Applying hostname: ${NEW_NAME}"

# ── OS-level rename ──
hostnamectl set-hostname "$NEW_NAME"
echo "[apply-hostname] hostnamectl set to ${NEW_NAME}"

if ! grep -q "^127\.0\.1\.1[[:space:]]" /etc/hosts; then
    echo "127.0.1.1 ${NEW_NAME}" >> /etc/hosts
    echo "[apply-hostname] Added 127.0.1.1 ${NEW_NAME} to /etc/hosts"
elif ! grep -q "^127\.0\.1\.1[[:space:]]\+${NEW_NAME}$" /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1 ${NEW_NAME}/" /etc/hosts
    echo "[apply-hostname] Updated /etc/hosts 127.0.1.1 entry to ${NEW_NAME}"
fi

# ── Tailscale rename ──
if command -v tailscale &>/dev/null && tailscale status --json &>/dev/null; then
    echo "[apply-hostname] Renaming Tailscale machine to ${NEW_NAME}..."
    if tailscale set --hostname="$NEW_NAME" 2>/dev/null; then
        echo "[apply-hostname] Tailscale machine name updated to ${NEW_NAME}"
        echo "[apply-hostname] Done."
        exit 0
    else
        echo "[apply-hostname] WARNING: OS hostname changed to ${NEW_NAME}, but Tailscale rename FAILED." >&2
        echo "[apply-hostname] The device may appear under its old name in the Tailscale admin console until this is resolved." >&2
        echo "[apply-hostname] Retry manually: tailscale set --hostname=${NEW_NAME}" >&2
        exit 2
    fi
else
    echo "[apply-hostname] Tailscale not available or not authenticated — OS-only rename."
    echo "[apply-hostname] Done."
    exit 0
fi
