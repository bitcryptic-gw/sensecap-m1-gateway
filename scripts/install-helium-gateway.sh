#!/usr/bin/env bash
# install-helium-gateway.sh — install helium_gateway binary (Helium IoT client)
# Pins a specific release from helium/gateway-rs (aarch64 musl-static).
# Usage: sudo /opt/gateway/scripts/install-helium-gateway.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root." >&2
    exit 1
fi

# ── Pinned version ─────────────────────────────────────────────────────────
HELIUM_GW_REPO="helium/gateway-rs"
HELIUM_GW_VERSION="1.3.0"
HELIUM_GW_TARGET="aarch64-unknown-linux-musl"
ASSET_NAME="helium-gateway-${HELIUM_GW_VERSION}-${HELIUM_GW_TARGET}.tar.gz"
DOWNLOAD_URL="https://github.com/${HELIUM_GW_REPO}/releases/download/v${HELIUM_GW_VERSION}/${ASSET_NAME}"
# SHA256 of the above tarball — computed manually on 2026-06-23 and pinned.
# There is no published checksum available for gateway-rs releases.
EXPECTED_SHA256="8462e792592b24aae8fff587185ec59080e818ff2fff132dde7dd5eafdabbf2d"

echo "=== Helium Gateway Install ==="
echo "[..] Target: helium_gateway v${HELIUM_GW_VERSION} (${HELIUM_GW_TARGET})"

# ── Idempotency check ──────────────────────────────────────────────────────
# Check the installed binary reports the pinned version.  The binary
# outputs a line like "2026-04-17 14:24:11.654 helium_gateway 1.3.0"
# on startup — grep for the version string.
BIN="/usr/local/bin/helium_gateway"
if [ -x "$BIN" ]; then
    if timeout 3 "$BIN" --version 2>&1 | grep -qF "${HELIUM_GW_VERSION}"; then
        echo "[..] helium_gateway v${HELIUM_GW_VERSION} already installed — skipping"
        exit 0
    fi
    echo "[..] Existing binary found but version mismatch — replacing"
fi

# ── Download ───────────────────────────────────────────────────────────────
echo "[..] Downloading ${ASSET_NAME}..."
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

TARBALL="${TMPDIR}/${ASSET_NAME}"
if ! curl -fsSL --connect-timeout 30 --max-time 120 \
    -o "$TARBALL" "$DOWNLOAD_URL"; then
    echo "ERROR: Failed to download ${DOWNLOAD_URL}" >&2
    exit 1
fi

# ── Verify checksum ────────────────────────────────────────────────────────
echo "[..] Verifying SHA256..."
ACTUAL_SHA256=$(sha256sum "$TARBALL" | cut -d' ' -f1)
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
    echo "ERROR: SHA256 mismatch!" >&2
    echo "  Expected: ${EXPECTED_SHA256}" >&2
    echo "  Got:      ${ACTUAL_SHA256}" >&2
    exit 1
fi

# ── Extract and install ────────────────────────────────────────────────────
echo "[..] Extracting..."
tar xzf "$TARBALL" -C "$TMPDIR"

if [ ! -f "${TMPDIR}/helium_gateway" ]; then
    echo "ERROR: helium_gateway binary not found in tarball" >&2
    exit 1
fi

cp "${TMPDIR}/helium_gateway" "$BIN"
chmod 755 "$BIN"

echo "[OK] helium_gateway v${HELIUM_GW_VERSION} installed to ${BIN}"
