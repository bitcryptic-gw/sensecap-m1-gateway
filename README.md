# SenseCap M1 Gateway Platform

An open-source replacement firmware platform for the **Seeed SenseCap M1** LoRaWAN gateway, targeting the Helium IoT network.

No hidden services. No telemetry. No third-party backdoors. Fully auditable.

---

## What This Is

This project replaces the default platform that ships on the SenseCap M1. It provides a clean, minimal stack using only open-source components:

- **Semtech `lora_pkt_fwd`** — the reference packet forwarder for the SX1302 concentrator
- **Helium `gateway-rs`** — lightweight Helium network gateway daemon
- **ATECC608A** — on-board secure element for swarm key storage (no software key files)
- **Tailscale** — optional remote access using your own account and auth key

The goal is a gateway you can fully understand, audit, and trust — running on hardware you already own.

---

## What This Is NOT

- Not affiliated with Seeed Studio or the Helium Foundation
- Not a general-purpose LoRaWAN gateway platform (SenseCap M1 hardware only — no abstraction sprawl)
- Not a cloud service — your gateway, your keys, your data

---

## Hardware Requirements

**This firmware is for SenseCap M1 only.** It will not work on other gateways without significant modification.

| Component | Detail |
|-----------|--------|
| SBC | Raspberry Pi 4B (inside SenseCap M1) |
| Concentrator | RAK2287 (SX1302 / SX1250 SPI) |
| Secure Element | Microchip ATECC608A on I2C-1 (0x60) |
| Connectivity | Ethernet (eth0) for Gateway EUI derivation |
| GPS | None — fake GPS configured via `config.env` |

---

## Quick Start

1. **Flash** a fresh Raspberry Pi OS Lite (64-bit) to the SenseCap M1 SD card
2. **Copy** `config.env.example` to `config.env` on the boot partition and edit it:
   ```
   BAND=au_915_928          # Set your region
   GPS_LATITUDE=-33.8688    # Your actual location (required for PoC)
   GPS_LONGITUDE=151.2093
   GPS_ALTITUDE=50
   TAILSCALE_AUTHKEY=tskey-auth-...   # Optional
   ```
3. **Copy** the repository to `/opt/gateway` on the Pi
4. **Install** the systemd services:
   ```bash
   cp systemd/*.service /etc/systemd/system/
   systemctl daemon-reload
   systemctl enable gateway-platform.service
   ```
5. **Build and install** `lora_pkt_fwd` (see [Building from Source](#building-from-source))
6. **Reboot** — `first-boot.sh` runs automatically and brings up the stack

---

## Configuration

All user-facing settings live in `/opt/gateway/config.env`. Copy `config.env.example` to start.

| Variable | Required | Description |
|----------|----------|-------------|
| `BAND` | Yes | LoRa frequency region (see [Band Selection](#bandregion-selection)) |
| `GPS_LATITUDE` | Recommended | Decimal degrees, your install location |
| `GPS_LONGITUDE` | Recommended | Decimal degrees, your install location |
| `GPS_ALTITUDE` | No | Metres above sea level (default: 0) |
| `TAILSCALE_AUTHKEY` | No | One-time auth key from tailscale.com/settings/keys |
| `HOSTNAME` | No | Custom hostname (default: `sensecap-<last6mac>`) |

> **Note:** `GPS_LATITUDE` and `GPS_LONGITUDE` are used for fake GPS injection. The SenseCap M1 has no GPS hardware. Helium Proof of Coverage requires accurate coordinates — set your actual install location.

---

## Band / Region Selection

Set `BAND` in `config.env` to one of the following values. To change band after first boot, run `apply-band.sh <band>` and reboot.

| BAND value | Region | Notes |
|------------|--------|-------|
| `au_915_928` | AU915 | **FSB2 (ch 8–15 + 65)** — Helium AU default |
| `us_902_928` | US915 | **FSB2 (ch 8–15 + 65)** — Helium US default |
| `eu_863_870` | EU868 | 8 standard TTN/Helium channels, 868.1–868.5 + 867.1–867.9 MHz |
| `as_923_1` | AS923-1 | Singapore, Indonesia, Vietnam; 922.0–923.4 MHz |
| `as_923_2` | AS923-2 | Vietnam (alternate plan); 921.4–922.8 MHz |
| `in_865_867` | IN865 | India; 865.0625, 865.4025, 865.985 MHz (3 mandatory channels) |
| `kr_920_923` | KR920 | South Korea; 922.1–923.5 MHz |
| `ru_864_870` | RU864 | Russia; 864.1–864.9 + 868.7–869.3 MHz |
| `cn_470_510` | CN470 | China; FSB11 (486.3–487.7 MHz uplink, 500.3–509.7 MHz downlink) |

> **Helium note:** Helium AU and Helium US both use FSB2. Using any other FSB will result in zero PoC activity.

---

## How It Works

```
LoRa devices (nodes)
       │  RF
       ▼
RAK2287 concentrator (SX1302 via SPI /dev/spidev0.0)
       │  UDP 127.0.0.1:1680
       ▼
lora_pkt_fwd  [pktfwd.service]
       │  UDP 127.0.0.1:1680
       ▼
gateway-rs  [gateway-rs.service]
       │  ECC508 swarm key (i2c-1:0x60 slot 0)
       ▼
Helium IoT Network (mainnet)
```

- `pktfwd.service` runs the Semtech packet forwarder, which handles SX1302 hardware and forwards raw LoRa packets as UDP datagrams
- `gateway-rs.service` runs the Helium gateway daemon in a Docker container, connecting to the Helium mainnet using the ECC608A secure element for identity
- `gateway-platform.service` (oneshot) runs `first-boot.sh` at startup to configure everything

---

## Tailscale

Tailscale is optional but strongly recommended for remote access. You supply your own auth key — this project never provides one.

**To enable on first boot:**
Add your one-time auth key to `config.env`:
```
TAILSCALE_AUTHKEY=tskey-auth-xxxxxxxxxxxxxxxx
```
The key is used once during `first-boot.sh` and then **automatically removed** from `config.env` (it is single-use by design).

**To enable after first boot:**
```bash
tailscale up --authkey=tskey-auth-xxxxxxxxxxxxxxxx --hostname=$(hostname)
```

**To generate a key:** Visit [tailscale.com/settings/keys](https://tailscale.com/settings/keys) → Generate auth key → Select "One-time use".

---

## Wingbits (Optional)

Wingbits is an optional ADS-B data aggregation service. To enable it, uncomment the `wingbits` block in `docker/docker-compose.yml` and configure your Wingbits account credentials.

```bash
cd /opt/gateway
docker compose up -d wingbits
```

Wingbits runs independently of the Helium stack and does not interfere with LoRaWAN operation.

---

## Building from Source

The `lora_pkt_fwd` binary must be compiled from the Semtech sx1302_hal repository for the RAK2287 / SX1302 hardware.

```bash
# Install build dependencies
sudo apt-get install -y git build-essential libssl-dev

# Clone sx1302_hal
git clone https://github.com/Lora-net/sx1302_hal.git
cd sx1302_hal

# Build
make all

# Install
sudo cp packet_forwarder/lora_pkt_fwd /usr/local/bin/
sudo mkdir -p /opt/gateway/pktfwd
sudo ln -sf /opt/gateway/scripts/reset_lgw.sh /opt/gateway/pktfwd/reset_lgw.sh
```

> `lora_pkt_fwd` (and `chip_id`) hardcode `./reset_lgw.sh` as a relative path and look for it in their working directory (`/opt/gateway/pktfwd`). `first-boot.sh` creates this symlink automatically. If you are setting up manually, the `ln -sf` line above is required — without it, `pktfwd.service` will fail on start with `sh: ./reset_lgw.sh: not found`.

**helium_gateway** must be installed as a native ARM64 musl binary at `/usr/local/bin/helium_gateway`. Download a release from the [helium-systems/gateway-rs releases page](https://github.com/helium/gateway-rs/releases) — select the `aarch64-unknown-linux-musl` build and extract the binary.

---

## Directory Layout

```
/opt/gateway/
├── config.env              # Your live config (copy from config.env.example)
├── config/
│   ├── settings.toml       # gateway-rs config (ECC608A / i2c-1)
│   ├── global_conf.json    # Active frequency plan (written by apply-band.sh)
│   ├── global_conf.*.json  # Frequency plan templates for each region
│   └── local_conf.json     # Written at runtime by lora_pkt_fwd (gitignored)
├── pktfwd/
│   └── reset_lgw.sh        # Symlink → scripts/reset_lgw.sh (required by lora_pkt_fwd)
├── scripts/
│   ├── reset_lgw.sh        # SX1302 GPIO reset
│   ├── first-boot.sh       # First-boot initialisation
│   └── apply-band.sh       # Band change helper
└── .configured             # Sentinel: first-boot has run
```

---

## Contributing

This project is hardware-specific by design. Contributions welcome for:

- Bug fixes and correctness improvements
- Additional frequency plan configs (verified against Helium network requirements)
- Documentation improvements
- Web UI implementation (see placeholder in `docker/docker-compose.yml`)

**Hardware variant contributions** (e.g. support for RAK2287 over USB, or other concentrator modules) are welcome via PRs — please keep SenseCap M1 behaviour unchanged.

Please open an issue before starting large changes.

---

## License

MIT — see [LICENSE](LICENSE).

Copyright (c) 2024 SenseCap M1 Gateway Contributors.
