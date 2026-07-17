#!/bin/bash
# install-wrappers.sh — compile and install all setuid wrappers
# Run as root. Safe to re-run at any time.
set -e

SCRIPTS_DIR="$(dirname "$(readlink -f "$0")")"
INSTALL_DIR="/usr/local/bin"

wrappers=(
    ota-update-wrapper
    system-power-wrapper
    tailscale-wrapper
    wingbits-setup-wrapper
    wifi-toggle-wrapper
)

failed=0
for name in "${wrappers[@]}"; do
    src="$SCRIPTS_DIR/${name}.c"
    bin="$INSTALL_DIR/${name}"
    if [ ! -f "$src" ]; then
        echo "WRAPPER: $name SKIPPED (source not found)"
        continue
    fi
    if gcc -O2 "$src" -o "$bin"; then
        chown root:root "$bin"
        chmod 4755 "$bin"
        echo "WRAPPER: $name OK"
    else
        echo "WRAPPER: $name FAILED"
        failed=1
    fi
done
exit "$failed"
