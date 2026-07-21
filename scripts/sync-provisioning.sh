#!/bin/bash
# sync-provisioning.sh — idempotent provisioning-sync steps.
# Safe to re-run at any time: first-boot, OTA updates, manual recovery.
# Must run as root.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root (sudo)." >&2
    exit 1
fi

log() {
    echo "  [sync] $*"
}

# --- gateway-ui user creation (idempotent) ---
if ! id -u gateway-ui &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin \
        --groups systemd-journal,i2c gateway-ui
    log "Created system user: gateway-ui (groups: systemd-journal, i2c)"
else
    log "User gateway-ui already exists — skipping"
fi

# --- Tailscale operator ---
if command -v tailscale &>/dev/null; then
    if tailscale set --operator=gateway-ui 2>/dev/null; then
        log "Tailscale operator set to gateway-ui"
    else
        log "WARNING: could not set Tailscale operator (Tailscale not authenticated yet?)"
    fi
fi

# --- File ownership fixes ---
for f in \
    /var/log/gateway-ota.log \
    /etc/gateway-ui/ntfy.json \
    /etc/gateway-ui/github-token; do
    if [ -f "$f" ]; then
        chown gateway-ui:gateway-ui "$f" && \
            log "Fixed ownership of ${f} to gateway-ui:gateway-ui" || \
            log "WARNING: Failed to chown ${f}"
    fi
done

# --- sudoers deployment ---
cat > /etc/sudoers.d/10-gateway-ui << 'SUDOERS'
gateway-ui ALL=(root) NOPASSWD: /bin/systemctl restart gateway-ui
gateway-ui ALL=(root) NOPASSWD: /bin/systemctl restart pktfwd
gateway-ui ALL=(root) NOPASSWD: /bin/systemctl restart gateway-rs
gateway-ui ALL=(root) NOPASSWD: /opt/gateway/scripts/apply-band.sh
gateway-ui ALL=(root) NOPASSWD: /opt/gateway/scripts/apply-timezone.sh
gateway-ui ALL=(root) NOPASSWD: /opt/gateway/scripts/apply-hostname.sh
SUDOERS
chmod 0440 /etc/sudoers.d/10-gateway-ui
if visudo -c -f /etc/sudoers.d/10-gateway-ui; then
    log "Sudoers entries installed and validated"
else
    log "ERROR: sudoers validation failed — removing /etc/sudoers.d/10-gateway-ui"
    rm -f /etc/sudoers.d/10-gateway-ui
    exit 1
fi

log "sync-provisioning complete"
