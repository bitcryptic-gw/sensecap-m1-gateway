#!/bin/bash
# Apply system timezone configuration.
# Usage: apply-timezone.sh <timezone>
# Example: apply-timezone.sh Australia/Perth
set -euo pipefail

ENV_FILE="/opt/gateway/config.env"

TIMEZONE="${1:-}"
if [ -z "$TIMEZONE" ]; then
    echo "[apply-timezone] ERROR: No timezone specified." >&2
    exit 1
fi

if [ ! -f "/usr/share/zoneinfo/${TIMEZONE}" ]; then
    echo "[apply-timezone] ERROR: Invalid timezone '${TIMEZONE}' — zoneinfo file not found." >&2
    exit 1
fi

echo "[apply-timezone] Applying timezone: ${TIMEZONE}"

timedatectl set-timezone "$TIMEZONE"
echo "[apply-timezone] Timezone set to ${TIMEZONE}"

# --- Persist timezone to config.env ---
echo "[apply-timezone] Persisting TIMEZONE=${TIMEZONE} to ${ENV_FILE}"
ENV_TMP="${ENV_FILE}.tmp"
if [ -f "$ENV_FILE" ]; then
    grep -v '^TIMEZONE=' "$ENV_FILE" > "$ENV_TMP" || true
else
    : > "$ENV_TMP"
fi
printf 'TIMEZONE=%s\n' "$TIMEZONE" >> "$ENV_TMP"
mv "$ENV_TMP" "$ENV_FILE"
echo "[apply-timezone] Persisted TIMEZONE=${TIMEZONE} to ${ENV_FILE}"

echo "[apply-timezone] Done."
