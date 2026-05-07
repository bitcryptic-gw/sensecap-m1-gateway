#!/bin/bash
# First-boot initialisation for SenseCap M1 gateway platform.
# Idempotent — safe to re-run. Skips if sentinel file exists.
set -euo pipefail

SENTINEL="/opt/gateway/.configured"
CONFIG_DIR="/opt/gateway/config"
ENV_FILE="/opt/gateway/config.env"
LOG_FILE="/var/log/gateway-first-boot.log"
SCRIPTS_DIR="/opt/gateway/scripts"

log() {
    local msg="[first-boot] $*"
    echo "$msg"
    echo "$(date -Iseconds) $msg" >> "$LOG_FILE"
}

is_numeric() { [[ "${1:-}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; }

# --- Idempotency guard ---
if [ -f "$SENTINEL" ]; then
    log "Sentinel found at ${SENTINEL}. First-boot already completed. Exiting."
    exit 0
fi

log "Starting SenseCap M1 first-boot initialisation..."

# --- Source config.env ---
BAND="au_915_928"
GPS_LATITUDE=""
GPS_LONGITUDE=""
GPS_ALTITUDE=0
TAILSCALE_AUTHKEY=""
CUSTOM_HOSTNAME=""

if [ -f "$ENV_FILE" ]; then
    log "Sourcing ${ENV_FILE}..."
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    CUSTOM_HOSTNAME="${HOSTNAME:-}"
    # Unset shell HOSTNAME so we can control it explicitly
    unset HOSTNAME 2>/dev/null || true
fi

# --- Validate BAND ---
VALID_BANDS="au_915_928 us_902_928 eu_863_870 as_923_1 as_923_2 in_865_867 kr_920_923 ru_864_870 cn_470_510"
BAND_VALID=false
for b in $VALID_BANDS; do
    if [ "$BAND" = "$b" ]; then BAND_VALID=true; break; fi
done
if [ "$BAND_VALID" = false ]; then
    log "ERROR: Invalid BAND '${BAND}'. Valid: ${VALID_BANDS}"
    exit 1
fi

# --- Validate GPS coordinates (non-fatal: warn and default to 0) ---
if [ -n "${GPS_LATITUDE:-}" ] && ! is_numeric "$GPS_LATITUDE"; then
    log "WARNING: GPS_LATITUDE '${GPS_LATITUDE}' is not numeric — using 0"
    GPS_LATITUDE=0
fi
if [ -n "${GPS_LONGITUDE:-}" ] && ! is_numeric "$GPS_LONGITUDE"; then
    log "WARNING: GPS_LONGITUDE '${GPS_LONGITUDE}' is not numeric — using 0"
    GPS_LONGITUDE=0
fi

# --- Derive Gateway EUI from eth0 MAC ---
log "Deriving Gateway EUI from eth0 MAC..."
mac=$(cat /sys/class/net/eth0/address)
mac_clean=$(echo "$mac" | tr -d ':' | tr '[:lower:]' '[:upper:]')
GATEWAY_EUI="${mac_clean:0:6}FFFE${mac_clean:6:6}"
log "Gateway EUI: ${GATEWAY_EUI}"

# --- Set hostname ---
if [ -n "$CUSTOM_HOSTNAME" ]; then
    NEW_HOSTNAME="$CUSTOM_HOSTNAME"
else
    mac_last6=$(echo "$mac_clean" | tr '[:upper:]' '[:lower:]' | tail -c 7)
    NEW_HOSTNAME="sensecap-${mac_last6}"
fi
log "Setting hostname to: ${NEW_HOSTNAME}"
echo "$NEW_HOSTNAME" > /etc/hostname
hostnamectl set-hostname "$NEW_HOSTNAME" || true

# --- Enable SPI and I2C ---
log "Ensuring SPI and I2C are enabled..."
raspi-config nonint do_spi 0  || log "WARNING: raspi-config do_spi failed (may already be enabled)"
raspi-config nonint do_i2c 0  || log "WARNING: raspi-config do_i2c failed (may already be enabled)"

# --- Apply frequency band ---
log "Applying frequency band: ${BAND}"
"${SCRIPTS_DIR}/apply-band.sh" "$BAND"

# --- Inject Gateway EUI ---
log "Injecting Gateway EUI into global_conf.json..."
jq --arg id "$GATEWAY_EUI" \
    '.gateway_conf.gateway_ID = $id' \
    "${CONFIG_DIR}/global_conf.json" > /tmp/global_conf_tmp.json
mv /tmp/global_conf_tmp.json "${CONFIG_DIR}/global_conf.json"

# --- Inject GPS coordinates if set ---
if [ -n "${GPS_LATITUDE:-}" ] && [ -n "${GPS_LONGITUDE:-}" ]; then
    log "Injecting GPS coordinates: lat=${GPS_LATITUDE}, lon=${GPS_LONGITUDE}, alt=${GPS_ALTITUDE:-0}"
    jq \
        --argjson lat "${GPS_LATITUDE}" \
        --argjson lon "${GPS_LONGITUDE}" \
        --argjson alt "${GPS_ALTITUDE:-0}" \
        '.gateway_conf.ref_latitude  = $lat |
         .gateway_conf.ref_longitude = $lon |
         .gateway_conf.ref_altitude  = $alt' \
        "${CONFIG_DIR}/global_conf.json" > /tmp/global_conf_tmp.json
    mv /tmp/global_conf_tmp.json "${CONFIG_DIR}/global_conf.json"
fi

# --- Docker install ---
if command -v docker &>/dev/null; then
    log "Docker already installed: $(docker --version)"
else
    log "Installing Docker (this may take 30–60 seconds on a Pi)..."
    if curl -fsSL https://get.docker.com | sh; then
        log "Docker installed successfully"
        systemctl enable docker || log "WARNING: Failed to enable docker service"
        systemctl start  docker || log "WARNING: Failed to start docker service"

        # Add gateway user to docker group
        GATEWAY_USER=$(stat -c '%U' /opt/gateway 2>/dev/null || echo "")
        if [ -n "$GATEWAY_USER" ] && [ "$GATEWAY_USER" != "root" ]; then
            usermod -aG docker "$GATEWAY_USER" || \
                log "WARNING: Failed to add $GATEWAY_USER to docker group"
            log "Added $GATEWAY_USER to docker group (re-login required to take effect)"
        fi
    else
        log "WARNING: Docker install failed — continuing without Docker"
        log "Install manually: curl -fsSL https://get.docker.com | sh"
    fi
fi

# --- Tailscale setup ---
if [ -z "${TAILSCALE_AUTHKEY:-}" ]; then
    log "TAILSCALE_AUTHKEY not set — skipping Tailscale setup"
    log "To configure Tailscale later: tailscale up --authkey=<key> --hostname=\$(hostname)"
elif ! command -v tailscale &>/dev/null; then
    log "WARNING: TAILSCALE_AUTHKEY is set but tailscale is not installed — skipping"
else
    log "Configuring Tailscale..."
    if tailscale up --authkey="$TAILSCALE_AUTHKEY" --hostname="$(hostname)"; then
        log "Tailscale connected as $(hostname)"
    else
        log "WARNING: tailscale up failed — continuing without Tailscale"
    fi
fi

# Always scrub the auth key from config.env (one-time use, regardless of outcome above)
sed -i 's/^TAILSCALE_AUTHKEY=.*/TAILSCALE_AUTHKEY=/' /opt/gateway/config.env || true
log "TAILSCALE_AUTHKEY scrubbed from config.env"

# --- Prepare pktfwd working directory ---
log "Creating pktfwd working directory..."
mkdir -p /opt/gateway/pktfwd
# lora_pkt_fwd and chip_id look for ./reset_lgw.sh relative to their CWD
ln -sf /opt/gateway/scripts/reset_lgw.sh /opt/gateway/pktfwd/reset_lgw.sh
log "Symlinked reset_lgw.sh into pktfwd working directory"

# --- Enable and start services ---
log "Enabling and starting pktfwd.service..."
systemctl enable pktfwd.service
systemctl start  pktfwd.service

log "Enabling and starting gateway-rs.service..."
systemctl enable gateway-rs.service
systemctl start  gateway-rs.service

# --- gateway-ui web interface ---
log "Setting up gateway-ui web interface..."

# Create dedicated system user (no login shell, no home directory)
if ! id -u gateway-ui &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin gateway-ui
    log "Created system user: gateway-ui"
else
    log "User gateway-ui already exists — skipping"
fi

# Symlink install location
ln -sfn /opt/gateway/gateway-ui /opt/gateway-ui
log "Linked /opt/gateway-ui -> /opt/gateway/gateway-ui"

# Install Python dependencies
log "Installing Python dependencies for gateway-ui..."
pip3 install --quiet -r /opt/gateway/gateway-ui/requirements.txt
log "Python dependencies installed"

# Generate bearer token
mkdir -p /etc/gateway-ui
if [ ! -s /etc/gateway-ui/token ]; then
    openssl rand -hex 32 > /etc/gateway-ui/token
    chown gateway-ui:gateway-ui /etc/gateway-ui/token
    chmod 600 /etc/gateway-ui/token
    chown gateway-ui:gateway-ui /etc/gateway-ui
    log "Generated gateway-ui bearer token"
    echo ""
    echo "============================================"
    echo "  Gateway Web UI Bearer Token"
    echo "  $(cat /etc/gateway-ui/token)"
    echo "  Record this now — it will not be shown again."
    echo "  Recovery: sudo cat /etc/gateway-ui/token"
    echo "============================================"
    echo ""
else
    log "gateway-ui token already exists — skipping generation"
fi

# Install sudoers entries for gateway-ui
cat > /etc/sudoers.d/10-gateway-ui << 'SUDOERS'
gateway-ui ALL=(root) NOPASSWD: /bin/systemctl restart gateway-ui
gateway-ui ALL=(root) NOPASSWD: /bin/systemctl restart pktfwd
gateway-ui ALL=(root) NOPASSWD: /bin/systemctl restart gateway-rs
gateway-ui ALL=(root) NOPASSWD: /opt/gateway/scripts/apply-band.sh
SUDOERS
chmod 0440 /etc/sudoers.d/10-gateway-ui
if visudo -c -f /etc/sudoers.d/10-gateway-ui; then
    log "Sudoers entries installed and validated"
else
    log "ERROR: sudoers validation failed — removing /etc/sudoers.d/10-gateway-ui"
    rm -f /etc/sudoers.d/10-gateway-ui
fi

# Install and start gateway-ui service
cp /opt/gateway/systemd/gateway-ui.service /etc/systemd/system/gateway-ui.service
systemctl daemon-reload
systemctl enable gateway-ui.service
systemctl start  gateway-ui.service
log "gateway-ui.service enabled and started"

# --- Write sentinel ---
touch "$SENTINEL"
log "First-boot initialisation complete. Sentinel written to ${SENTINEL}."
