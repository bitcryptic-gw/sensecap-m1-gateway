#!/bin/bash
# SX1302 CoreCell GPIO reset — hardcoded for SenseCap M1
# Uses sysfs GPIO interface (Pi 4B / not Pi 5)
set -euo pipefail

# BCM GPIO numbers for SenseCap M1
BCM_RESET=17
BCM_POWER=27
BCM_SX1261=5

# Resolve sysfs global GPIO numbers.
# Kernel 6.x on Pi 4B uses gpiochip512 as the main BCM2711 controller base.
# The second chip (base 570) is onboard peripherals — we always want chip 512.
GPIO_BASE=$(cat /sys/class/gpio/gpiochip512/base 2>/dev/null || echo 512)
GPIO_RESET=$((GPIO_BASE + BCM_RESET))
GPIO_POWER=$((GPIO_BASE + BCM_POWER))
GPIO_SX1261=$((GPIO_BASE + BCM_SX1261))

gpio_export() {
    local pin=$1
    if [ ! -d "/sys/class/gpio/gpio${pin}" ]; then
        echo "$pin" > /sys/class/gpio/export
    fi
}

gpio_unexport() {
    local pin=$1
    if [ -d "/sys/class/gpio/gpio${pin}" ]; then
        echo "$pin" > /sys/class/gpio/unexport
    fi
}

gpio_direction() {
    local pin=$1 dir=$2
    echo "$dir" > "/sys/class/gpio/gpio${pin}/direction"
}

gpio_write() {
    local pin=$1 val=$2
    echo "$val" > "/sys/class/gpio/gpio${pin}/value"
}

case "${1:-}" in
    start)
        echo "[reset_lgw] Starting SX1302 concentrator..."

        # Clean unexport first (idempotent)
        gpio_unexport $GPIO_RESET
        gpio_unexport $GPIO_POWER
        gpio_unexport $GPIO_SX1261

        gpio_export $GPIO_RESET
        gpio_export $GPIO_POWER
        gpio_export $GPIO_SX1261

        gpio_direction $GPIO_RESET out
        gpio_direction $GPIO_POWER out
        gpio_direction $GPIO_SX1261 out

        # Assert power enable
        gpio_write $GPIO_POWER 1
        sleep 0.1

        # Pulse SX1302 reset: high → low (active-low reset)
        gpio_write $GPIO_RESET 1
        sleep 0.1
        gpio_write $GPIO_RESET 0
        sleep 0.1

        # Pulse SX1261 reset
        gpio_write $GPIO_SX1261 0
        sleep 0.05
        gpio_write $GPIO_SX1261 1
        sleep 0.05

        echo "[reset_lgw] Concentrator started."
        ;;

    stop)
        echo "[reset_lgw] Stopping SX1302 concentrator..."

        if [ -d "/sys/class/gpio/gpio${GPIO_RESET}" ]; then
            gpio_direction $GPIO_RESET out
            gpio_write $GPIO_RESET 0
            sleep 0.1
            gpio_write $GPIO_RESET 1
        fi

        gpio_unexport $GPIO_RESET
        gpio_unexport $GPIO_POWER
        gpio_unexport $GPIO_SX1261

        echo "[reset_lgw] Concentrator stopped."
        ;;

    *)
        echo "Usage: $0 {start|stop}" >&2
        exit 1
        ;;
esac
