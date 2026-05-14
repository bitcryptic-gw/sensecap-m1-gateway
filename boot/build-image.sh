#!/bin/bash
# build-image.sh — Build a flashable SenseCap M1 Gateway image.
# Runs locally or in CI. Requires root (for loop device mounting).
# Usage: sudo ./boot/build-image.sh
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
WORKDIR="$(mktemp -d)"
IMG_NAME="sensecap-m1-gateway"
OUTPUT_DIR="${OUTPUT_DIR:-.}"

BASE_URL="https://downloads.raspberrypi.com/raspios_lite_arm64/images"

cleanup() {
    local rc=$?
    echo "[build] Cleaning up..."
    # Unmount any mounted partitions
    for mp in "${WORKDIR}/mnt/boot" "${WORKDIR}/mnt/root"; do
        if mountpoint -q "$mp" 2>/dev/null; then
            umount "$mp" || true
        fi
    done
    # Detach loop devices
    if [ -n "${LOOP_DEV:-}" ]; then
        kpartx -d "$LOOP_DEV" 2>/dev/null || true
        losetup -d "$LOOP_DEV" 2>/dev/null || true
    fi
    rm -rf "$WORKDIR"
    exit $rc
}
trap cleanup EXIT INT TERM

# ── Preflight ──────────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root (for loop device mounting)." >&2
    exit 1
fi

echo "=== SenseCap M1 Gateway Image Builder ==="
echo "Started: $(date)"
echo "Workdir: ${WORKDIR}"

mkdir -p "${WORKDIR}/mnt/boot" "${WORKDIR}/mnt/root"

# ── 1. Download base image ────────────────────────────────────────────────────
echo ""
echo "--- Downloading Raspberry Pi OS Lite 64-bit ---"

LATEST_DIR=$(curl -sSL "$BASE_URL/" | grep -oP 'href="\Kraspios_lite_arm64-[^/]+/' | sort -V | tail -1)
if [ -z "$LATEST_DIR" ]; then
    echo "ERROR: Could not determine latest image directory" >&2
    exit 1
fi

IMAGE_PAGE=$(curl -sSL "${BASE_URL}/${LATEST_DIR}")
IMAGE_FILE=$(echo "$IMAGE_PAGE" | grep -oP 'href="\K[^"]+\.img\.xz[^"]*' | head -1)
if [ -z "$IMAGE_FILE" ]; then
    IMAGE_FILE=$(echo "$IMAGE_PAGE" | grep -oP 'href="\K[^"]+\.img\.xz' | head -1)
fi
if [ -z "$IMAGE_FILE" ]; then
    echo "ERROR: Could not find .img.xz download URL" >&2
    exit 1
fi
if echo "$IMAGE_FILE" | grep -qEv '^https?://'; then
    IMAGE_URL="${BASE_URL}/${LATEST_DIR}${IMAGE_FILE}"
else
    IMAGE_URL="$IMAGE_FILE"
fi

echo "[build] Latest image: ${IMAGE_FILE}"
echo "[build] Downloading..."
wget -q --show-progress -O "${WORKDIR}/base.img.xz" "$IMAGE_URL"

# Fetch and verify SHA256
SHA256_FILE=$(echo "$IMAGE_PAGE" | grep -oP 'href="\K[^"]+\.img\.xz\.sha256' | head -1)
if [ -n "$SHA256_FILE" ]; then
    if echo "$SHA256_FILE" | grep -qEv '^https?://'; then
        SHA256_URL="${BASE_URL}/${LATEST_DIR}${SHA256_FILE}"
    else
        SHA256_URL="$SHA256_FILE"
    fi
    echo "[build] Verifying SHA256..."
    wget -q -O "${WORKDIR}/base.img.xz.sha256" "$SHA256_URL"
    sed -i 's/[^ ]*\.img\.xz/base.img.xz/' "${WORKDIR}/base.img.xz.sha256"
    (cd "$WORKDIR" && sha256sum -c "base.img.xz.sha256" --ignore-missing) || {
        echo "ERROR: SHA256 mismatch on downloaded image" >&2
        exit 1
    }
    echo "[build] SHA256 verified"
else
    echo "[build] WARNING: No SHA256 file found — skipping verification"
fi

# ── 2. Decompress ─────────────────────────────────────────────────────────────
echo ""
echo "--- Decompressing ---"
xz -d "${WORKDIR}/base.img.xz"
IMAGE="${WORKDIR}/base.img"
echo "[build] Decompressed to ${IMAGE}"

# ── 3. Set up loop device ─────────────────────────────────────────────────────
echo ""
echo "--- Mounting image ---"
LOOP_DEV=$(losetup --show -fP "$IMAGE")
echo "[build] Loop device: ${LOOP_DEV}"

# Find boot and root partitions (boot is usually partition 1, root is 2)
BOOT_PART="${LOOP_DEV}p1"
ROOT_PART="${LOOP_DEV}p2"

if [ ! -b "$BOOT_PART" ]; then
    echo "ERROR: Boot partition not found at ${BOOT_PART}" >&2
    exit 1
fi
if [ ! -b "$ROOT_PART" ]; then
    echo "ERROR: Root partition not found at ${ROOT_PART}" >&2
    exit 1
fi

mount "$BOOT_PART" "${WORKDIR}/mnt/boot"
mount "$ROOT_PART" "${WORKDIR}/mnt/root"
echo "[build] Partitions mounted"

# ── 4. Inject firstrun.sh ─────────────────────────────────────────────────────
echo ""
echo "--- Injecting firstrun.sh ---"
cp "$(dirname "$0")/firstrun.sh" "${WORKDIR}/mnt/boot/firstrun.sh"
chmod +x "${WORKDIR}/mnt/boot/firstrun.sh"
echo "[build] Copied firstrun.sh to boot partition"

# ── 5. Patch cmdline.txt ──────────────────────────────────────────────────────
echo ""
echo "--- Patching cmdline.txt ---"
CMDLINE="${WORKDIR}/mnt/boot/cmdline.txt"
if [ -f "$CMDLINE" ]; then
    # Add systemd.run parameter, preserving all existing kernel params
    sed -i 's/$/ systemd.run=\/boot\/firmware\/firstrun.sh systemd.run_success_action=none systemd.run_failure_action=none/' "$CMDLINE"
    echo "[build] Added systemd.run to cmdline.txt"
    echo "[build] cmdline.txt: $(cat "$CMDLINE")"
else
    echo "ERROR: cmdline.txt not found on boot partition" >&2
    exit 1
fi

# ── 6. Merge config.txt ───────────────────────────────────────────────────────
echo ""
echo "--- Merging config.txt ---"
CONFIG_DST="${WORKDIR}/mnt/boot/config.txt"
CONFIG_SRC="$(dirname "$0")/config.txt"

if [ -f "$CONFIG_DST" ]; then
    echo "[build] Appending SenseCap-specific settings to existing config.txt"
    {
        echo ""
        echo "# SenseCap M1 Gateway settings"
        echo "# The following are appended by the image build process."
        echo "# Values here take precedence over defaults above."
        while IFS= read -r line; do
            # Skip comments and blank lines from our config
            case "$line" in
                \#*|"") continue ;;
            esac
            # If the setting already exists in the file, skip it
            key="${line%%=*}"
            if grep -q "^${key}=" "$CONFIG_DST" 2>/dev/null; then
                echo "[build]   Skipping ${key} (already set)"
                continue
            fi
            echo "$line" >> "$CONFIG_DST"
            echo "[build]   Added ${line}"
        done < "$CONFIG_SRC"
    }
else
    echo "[build] No existing config.txt — creating from repo"
    cp "$CONFIG_SRC" "$CONFIG_DST"
fi
echo "[build] config.txt merged"

# ── 7. Unmount (cleanup trap handles this) ────────────────────────────────────
echo ""
echo "--- Unmounting ---"
# Trap will handle unmount and detach; just report that we're done with image
echo "[build] Image modifications complete"

# ── 8. Compress ───────────────────────────────────────────────────────────────
echo ""
echo "--- Compressing ---"
DATE_TAG=$(date +%Y.%m.%d)
OUTPUT_FILE="${OUTPUT_DIR}/${IMG_NAME}-${DATE_TAG}.img.xz"
echo "[build] Compressing to ${OUTPUT_FILE}..."
# Use all available cores for compression
xz -T0 -9 "${IMAGE}"
mv "${IMAGE}.xz" "$OUTPUT_FILE"
echo "[build] Compressed"

# ── 9. Output ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Build Complete ==="
echo "Image: ${OUTPUT_FILE}"
echo "Size:  $(du -h "$OUTPUT_FILE" | cut -f1)"
echo "SHA256: $(sha256sum "$OUTPUT_FILE" | cut -d' ' -f1)"
echo "Date:   ${DATE_TAG}"
