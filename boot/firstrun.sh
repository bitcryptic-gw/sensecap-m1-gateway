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
# Raspberry Pi Imager's Customisation step can optionally be used to set the
# operator's username, password, SSH key, and hostname before flashing — but
# this is not available in all Imager flows (confirmed unavailable in Imager
# v2.0.10 when flashing via "Use custom" with a custom .img.xz). If no such
# user exists at boot, this script creates a fallback account
# (sensecap/sensecap, forced password change on first login) before falling
# through to the primary-user derivation logic. See the "Fallback default
# account" block below.
set -euo pipefail

LOG="/var/log/firstrun.log"
REPO_URL="https://github.com/bitcryptic-gw/sensecap-m1-gateway"
REPO_DIR="/opt/gateway"

# Tee all output to log file and console
exec > >(tee -a "$LOG") 2>&1

echo "=== SenseCap M1 Gateway First-Run ==="
echo "Started: $(date)"

# --- Wait for network ---
# Check for a real IPv4 default route — this only appears after
# NetworkManager has completed DHCP on the wired interface, so it is
# a genuine readiness signal (unlike ICMP to an external host, which
# can fail even with a working lease, or succeed via other paths with
# no wired lease at all).
echo "[firstrun] Waiting for network connectivity..."
for i in $(seq 1 60); do
    if ip -4 route show default | grep -q '^default'; then
        echo "[firstrun] Network ready after ${i}s"
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "[firstrun] ERROR: Network not ready after 60s — aborting"
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

# --- Fallback default account ---
# If Raspberry Pi Imager did not provision a user — this happens when
# flashing via "Use custom" in some Imager versions — create a fallback
# account 'sensecap' with a static published password and force a change
# on first login. Idempotent: does nothing if sensecap already exists or
# any UID 1000+ user is already present.
if ! id sensecap &>/dev/null; then
    EXISTING_USER=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}')
    if [ -z "$EXISTING_USER" ]; then
        echo "[firstrun] No Imager-provisioned user found — creating fallback account 'sensecap'"

        groupadd -f sudo

        useradd --create-home --shell /bin/bash --groups sudo sensecap

        echo "sensecap:sensecap" | chpasswd

        chage -d 0 sensecap

        systemctl enable --now ssh || echo "[firstrun] WARNING: Failed to enable SSH" >&2

        echo "[firstrun] Fallback account 'sensecap' created. Default password is published in README.md. Password change will be required on first login."
    fi
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
