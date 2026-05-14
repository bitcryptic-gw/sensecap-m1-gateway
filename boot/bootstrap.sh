#!/bin/bash
# bootstrap.sh — One-time provisioning for a fresh Debian Trixie (ARM64) Pi.
# Usage: sudo ./boot/bootstrap.sh [--force]
set -euo pipefail

# ── Constants ──────────────────────────────────────────────────────────────────
REPO_URL="https://github.com/bitcryptic-gw/sensecap-m1-gateway"
REPO_DIR="/opt/gateway"
CONFIG_TXT_SRC="${REPO_DIR}/boot/config.txt"
CONFIG_TXT_DST="/boot/firmware/config.txt"
ENV_FILE="${REPO_DIR}/config.env"
ENV_EXAMPLE="${REPO_DIR}/config.env.example"
SENTINEL="${REPO_DIR}/.git"

# ── Colour helpers ─────────────────────────────────────────────────────────────
green() { echo "  [OK] $*"; }
warn()  { echo "  [WARN] $*" >&2; }
info()  { echo "  [..] $*"; }

# ── Preflight ──────────────────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root (sudo)." >&2
    exit 1
fi

PRIMARY_USER=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}')
if [ -z "$PRIMARY_USER" ]; then
    echo "ERROR: No primary non-root user found (UID 1000–65533)." >&2
    exit 1
fi

echo "============================================"
echo "  SenseCap M1 Gateway Bootstrap"
echo "  Hostname:  $(hostname)"
echo "  User:      ${PRIMARY_USER}"
echo "  Date:      $(date)"
echo "============================================"
echo ""

FORCE=false
if [ "${1:-}" = "--force" ]; then
    FORCE=true
    info "Running in --force mode (re-run steps only)"
fi

# --- Already provisioned? ---
if [ -d "$SENTINEL" ] && [ "$FORCE" = false ]; then
    echo ""
    echo "This device appears to already be provisioned (${SENTINEL} exists)."
    echo "Re-run with --force to overwrite. This will not delete existing config or secrets."
    echo ""
    exit 0
fi

# ── 1. System packages ────────────────────────────────────────────────────────

echo "--- System Packages ---"
info "Updating package lists..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

info "Installing required packages..."
apt-get install -y -qq --no-install-recommends \
    git \
    python3 python3-pip python3-venv \
    i2c-tools \
    jq \
    curl \
    docker.io

info "Adding ${PRIMARY_USER} to docker group..."
usermod -aG docker "$PRIMARY_USER"
green "System packages installed"

# ── 2. Repo clone ────────────────────────────────────────────────────────────

echo ""
echo "--- Repo Clone ---"
if [ -d "$SENTINEL" ]; then
    info "Repo already cloned at ${REPO_DIR}"
    # Ensure correct ownership in case of previous root-owned clone
    chown -R "${PRIMARY_USER}:${PRIMARY_USER}" "$REPO_DIR"
    green "Ownership verified: ${PRIMARY_USER}"
else
    info "Creating ${REPO_DIR}..."
    mkdir -p "$REPO_DIR"
    chown "${PRIMARY_USER}:${PRIMARY_USER}" "$REPO_DIR"
    info "Cloning repo as ${PRIMARY_USER}..."
    sudo -u "$PRIMARY_USER" git clone "$REPO_URL" "$REPO_DIR"
    green "Repo cloned at ${REPO_DIR}"
fi

# ── 3. boot/config.txt ───────────────────────────────────────────────────────

echo ""
echo "--- Boot Config ---"
if [ "$FORCE" = true ] && [ -d "$SENTINEL" ]; then
    info "Skipping boot config in --force mode"
elif [ -f "$CONFIG_TXT_DST" ]; then
    if cmp -s "$CONFIG_TXT_SRC" "$CONFIG_TXT_DST"; then
        green "Boot config already up-to-date"
    else
        echo ""
        echo "WARNING: ${CONFIG_TXT_DST} exists and differs from the repo version."
        echo "Overwrite it? The new config enables SPI, I2C, and other gateway settings."
        echo ""
        read -r -p "Overwrite /boot/firmware/config.txt? [y/N] " REPLY
        if [ "${REPLY,,}" = "y" ]; then
            cp "$CONFIG_TXT_SRC" "$CONFIG_TXT_DST"
            green "Copied boot config to ${CONFIG_TXT_DST}"
        else
            warn "Leaving existing boot config unchanged"
        fi
    fi
else
    cp "$CONFIG_TXT_SRC" "$CONFIG_TXT_DST"
    green "Copied boot config to ${CONFIG_TXT_DST}"
fi

# ── 4. Systemd units ─────────────────────────────────────────────────────────

echo ""
echo "--- Systemd Units ---"
for unit in "${REPO_DIR}"/systemd/*.service; do
    name=$(basename "$unit")
    cp "$unit" "/etc/systemd/system/${name}"
    info "Copied ${name}"
    systemctl enable "$name" 2>/dev/null || \
        warn "Failed to enable ${name} (continuing)"
done
systemctl daemon-reload
green "Systemd units installed and enabled"

# ── 5. Wingbits deps ─────────────────────────────────────────────────────────

echo ""
echo "--- Wingbits Dependencies ---"
if [ -x "${REPO_DIR}/scripts/install-wingbits-deps.sh" ]; then
    "${REPO_DIR}/scripts/install-wingbits-deps.sh"
    green "Wingbits dependencies installed"
else
    warn "install-wingbits-deps.sh not found or not executable — skipping"
fi

# ── 6. Post-provisioning summary ─────────────────────────────────────────────

echo ""
echo "============================================"
echo "  Bootstrap complete."
echo "============================================"
echo ""
echo "Next steps:"
echo ""
echo "  1. Configure Helium:"
echo "       cp ${ENV_EXAMPLE} ${ENV_FILE}"
echo "       nano ${ENV_FILE}"
echo "       sudo systemctl start pktfwd gateway-rs"
echo ""
echo "  2. Start the web UI:"
echo "       sudo systemctl start gateway-ui"
echo "       # Access at http://$(hostname):8080"
echo ""
echo "  3. Set up Wingbits (if hardware is connected):"
echo "       sudo ${REPO_DIR}/scripts/wingbits-setup.sh \"<dashboard-url>\""
echo ""
echo "  4. Reboot to apply boot config changes:"
echo "       sudo reboot"
echo ""
