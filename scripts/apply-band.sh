#!/bin/bash
# Apply LoRa frequency band configuration.
# Usage: apply-band.sh <band>
# Example: apply-band.sh au_915_928
set -euo pipefail

VALID_BANDS="au_915_928 us_902_928 eu_863_870 as_923_1 as_923_2 in_865_867 kr_920_923 ru_864_870 cn_470_510"
CONFIG_DIR="/opt/gateway/config"
ENV_FILE="/opt/gateway/config.env"

# --- Resolve band ---
BAND="${1:-}"
if [ -z "$BAND" ] && [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    BAND="${BAND:-}"
fi

if [ -z "$BAND" ]; then
    echo "[apply-band] ERROR: No band specified and BAND not set in config.env." >&2
    exit 1
fi

VALID=false
for b in $VALID_BANDS; do
    if [ "$BAND" = "$b" ]; then
        VALID=true
        break
    fi
done

if [ "$VALID" = false ]; then
    echo "[apply-band] ERROR: Unknown band '${BAND}'." >&2
    echo "[apply-band] Valid options: ${VALID_BANDS}" >&2
    exit 1
fi

TEMPLATE="${CONFIG_DIR}/global_conf.${BAND}.json"
if [ ! -f "$TEMPLATE" ]; then
    echo "[apply-band] ERROR: Template not found: ${TEMPLATE}" >&2
    exit 1
fi

echo "[apply-band] Applying band: ${BAND}"

# --- Load runtime values ---
GATEWAY_ID=""
SERVER_ADDRESS="127.0.0.1"
SERV_PORT_UP=1680
SERV_PORT_DOWN=1680
GPS_LATITUDE=0
GPS_LONGITUDE=0
GPS_ALTITUDE=0

# Save user-selected band before sourcing config.env;
# config.env carries its own BAND= line which would overwrite it.
USER_BAND="$BAND"

if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi

BAND="$USER_BAND"

# Derive gateway_ID from eth0 MAC if not already set
if [ -z "$GATEWAY_ID" ] && [ -f /sys/class/net/eth0/address ]; then
    mac=$(cat /sys/class/net/eth0/address)
    mac_clean=$(echo "$mac" | tr -d ':' | tr '[:lower:]' '[:upper:]')
    GATEWAY_ID="${mac_clean:0:6}FFFE${mac_clean:6:6}"
fi

# Validate GPS coords are numeric if set
if [ -n "$GPS_LATITUDE" ] && ! echo "$GPS_LATITUDE" | grep -qE '^-?[0-9]+(\.[0-9]+)?$'; then
    echo "[apply-band] ERROR: GPS_LATITUDE is not a valid number: ${GPS_LATITUDE}" >&2
    exit 1
fi
if [ -n "$GPS_LONGITUDE" ] && ! echo "$GPS_LONGITUDE" | grep -qE '^-?[0-9]+(\.[0-9]+)?$'; then
    echo "[apply-band] ERROR: GPS_LONGITUDE is not a valid number: ${GPS_LONGITUDE}" >&2
    exit 1
fi

LAT="${GPS_LATITUDE:-0}"
LON="${GPS_LONGITUDE:-0}"
ALT="${GPS_ALTITUDE:-0}"

# --- Inject runtime values using jq ---
echo "[apply-band] Injecting gateway_ID=${GATEWAY_ID}, server=${SERVER_ADDRESS}, lat=${LAT}, lon=${LON}, alt=${ALT}"

jq \
    --arg     gw_id  "$GATEWAY_ID" \
    --arg     srv    "$SERVER_ADDRESS" \
    --argjson up     "$SERV_PORT_UP" \
    --argjson down   "$SERV_PORT_DOWN" \
    --argjson lat    "$LAT" \
    --argjson lon    "$LON" \
    --argjson alt    "$ALT" \
    '
    .gateway_conf.gateway_ID    = $gw_id |
    .gateway_conf.server_address = $srv   |
    .gateway_conf.serv_port_up  = $up    |
    .gateway_conf.serv_port_down = $down  |
    .gateway_conf.ref_latitude  = $lat   |
    .gateway_conf.ref_longitude = $lon   |
    .gateway_conf.ref_altitude  = $alt
    ' \
    "$TEMPLATE" > "${CONFIG_DIR}/global_conf.json"

echo "[apply-band] Written to ${CONFIG_DIR}/global_conf.json"

# --- Restart pktfwd if running ---
if systemctl is-active --quiet pktfwd.service 2>/dev/null; then
    echo "[apply-band] Restarting pktfwd.service..."
    systemctl restart pktfwd.service
    echo "[apply-band] pktfwd.service restarted."
fi

# --- Persist band to config.env ---
echo "[apply-band] Persisting BAND=${BAND} to ${ENV_FILE}"
ENV_TMP="${ENV_FILE}.tmp"
if [ -f "$ENV_FILE" ]; then
    grep -v '^BAND=' "$ENV_FILE" > "$ENV_TMP" || true
else
    : > "$ENV_TMP"
fi
printf 'BAND=%s\n' "$BAND" >> "$ENV_TMP"
mv "$ENV_TMP" "$ENV_FILE"
echo "[apply-band] Persisted BAND=${BAND} to ${ENV_FILE}"

echo "[apply-band] Done."
