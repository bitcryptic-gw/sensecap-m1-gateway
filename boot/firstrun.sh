#!/bin/bash
# firstrun.sh — SenseCap M1 Gateway first-boot provisioning
#
# HOW THIS WORKS (for transparency):
#
# Raspberry Pi OS supports a first-boot hook via the systemd.run= kernel
# parameter in cmdline.txt. When present, systemd invokes the named script
# once as root during the first boot sequence, before the normal login prompt.
# This is the same mechanism used by Raspberry Pi Imager for its own
# first-boot configuration (userconf, Wi-Fi setup, etc).
#
# After this script completes, it removes the systemd.run= parameter from
# cmdline.txt so it does not run again on subsequent boots, then reboots
# the device to start normally.
#
# This script does minimal work itself — its sole job is to clone the
# gateway repo and invoke boot/bootstrap.sh, which handles full provisioning.
# See boot/bootstrap.sh for details of what provisioning does.
#
# Raspberry Pi Imager must be used to set the operator's username, password,
# SSH key, and hostname before flashing. This image does not ship with a
# default user account.
set -euo pipefail

LOG="/var/log/firstrun.log"
REPO_URL="https://github.com/bitcryptic-gw/sensecap-m1-gateway"
REPO_DIR="/opt/gateway"

# Tee all output to log file and console
exec > >(tee -a "$LOG") 2>&1

echo "=== SenseCap M1 Gateway First-Run ==="
echo "Started: $(date)"

# --- Wait for network ---
echo "[firstrun] Waiting for network connectivity..."
for i in $(seq 1 60); do
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        echo "[firstrun] Network reachable after ${i}s"
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "[firstrun] ERROR: Network not reachable after 60s — aborting"
        exit 1
    fi
    sleep 1
done

# --- Install git if needed ---
if ! command -v git &>/dev/null; then
    echo "[firstrun] Installing git..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq git
    echo "[firstrun] git installed"
fi

# --- Derive primary user ---
PRIMARY_USER=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}')
if [ -z "$PRIMARY_USER" ]; then
    echo "[firstrun] ERROR: No primary non-root user found (UID 1000–65533)."
    echo "[firstrun] Did you forget to set a username in Raspberry Pi Imager?"
    exit 1
fi
echo "[firstrun] Primary user: ${PRIMARY_USER}"

# --- Clone the repo ---
echo "[firstrun] Cloning gateway repo..."
mkdir -p "$REPO_DIR"
chown "${PRIMARY_USER}:${PRIMARY_USER}" "$REPO_DIR"
sudo -u "$PRIMARY_USER" git clone "$REPO_URL" "$REPO_DIR"
echo "[firstrun] Repo cloned to ${REPO_DIR}"

# --- Run bootstrap.sh ---
echo "[firstrun] Running bootstrap.sh..."
bash "${REPO_DIR}/boot/bootstrap.sh"

# --- Remove systemd.run from cmdline.txt ---
CMDLINE="/boot/firmware/cmdline.txt"
if [ -f "$CMDLINE" ]; then
    echo "[firstrun] Removing systemd.run from ${CMDLINE}..."
    sed -i 's/\s*systemd\.run=[^ ]*//g' "$CMDLINE"
    echo "[firstrun] cmdline.txt cleaned"
else
    echo "[firstrun] WARNING: ${CMDLINE} not found — skipping cleanup"
fi

echo "[firstrun] First-run complete. Rebooting in 5s..."
echo "=== First-Run Complete: $(date) ==="
sleep 5
reboot
