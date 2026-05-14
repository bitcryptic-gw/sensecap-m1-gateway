#!/usr/bin/env python3
import asyncio
import hmac
import json
import re
import secrets
import socket
import subprocess
import sys
from pathlib import Path
from typing import Annotated

import uvicorn
from fastapi import BackgroundTasks, Depends, FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles

# ── Paths ─────────────────────────────────────────────────────────────────────

CONFIG_PATH   = Path("/opt/gateway-ui/config")
TOKEN_PATH    = Path("/etc/gateway-ui/token")
GW_CONFIG_DIR = Path("/opt/gateway/config")
GW_ENV        = Path("/opt/gateway/config.env")
STATIC_DIR    = Path(__file__).parent / "static"
GW_RELEASE    = Path("/etc/gateway-release")

HELIUM_GW     = "/usr/local/bin/helium_gateway"
HELIUM_CONF   = "/etc/helium_gateway/settings.toml"
HELIUM_CONF2  = "/opt/gateway/config/settings.toml"

_SYSTEMCTL    = "/bin/systemctl"
_APPLY_BAND   = "/opt/gateway/scripts/apply-band.sh"
_TAILSCALE    = "/usr/bin/tailscale"
_SYSCTL_W     = "/usr/sbin/sysctl"

BAND_RE = re.compile(r"^[a-z][a-z0-9_]{1,30}$")
WRAPPER_BIN = "/usr/local/bin/wingbits-setup-wrapper"
WINGBITS_URL_RE = re.compile(r"^https://gitlab\.com/wingbits/config/-/raw/")
SHELL_META_RE = re.compile(r"[;&|`$()<>\n\r]")
_wingbits_running = False

TS_KEY_RE = re.compile(r"^tskey(-auth)?-[A-Za-z0-9]+")
CIDR_RE   = re.compile(r"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$")
ALLOWED_TAILSCALE_UNITS = ["readsb", "wingbits", "tailscaled", "kernel", "sshd", "pktfwd", "gateway-rs"]

# ── Config + Token (loaded at startup) ───────────────────────────────────────

def _load_config() -> dict:
    cfg: dict = {"bind_host": "0.0.0.0", "port": "8080"}
    if CONFIG_PATH.exists():
        for raw in CONFIG_PATH.read_text().splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            cfg[k.strip()] = v.strip()
    try:
        cfg["port"] = int(cfg["port"])
    except (ValueError, KeyError):
        cfg["port"] = 8080
    return cfg


def _load_token() -> str:
    if not TOKEN_PATH.exists():
        print(f"ERROR: {TOKEN_PATH} not found. Run first-boot.sh to generate.", file=sys.stderr)
        sys.exit(1)
    t = TOKEN_PATH.read_text().strip()
    if not t:
        print(f"ERROR: {TOKEN_PATH} is empty.", file=sys.stderr)
        sys.exit(1)
    return t


CONFIG: dict = _load_config()
TOKEN: str   = _load_token()

# ── App ───────────────────────────────────────────────────────────────────────

app = FastAPI(title="Gateway UI", docs_url=None, redoc_url=None)


@app.middleware("http")
async def enforce_body_limit(request: Request, call_next):
    if request.method in ("POST", "PUT", "PATCH"):
        cl = request.headers.get("content-length")
        if cl and int(cl) > 1024:
            return JSONResponse(status_code=413, content={"detail": "Request too large"})
    return await call_next(request)


def _require_auth(request: Request) -> None:
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Unauthorized")
    provided = auth[7:]
    if not hmac.compare_digest(provided.encode(), TOKEN.encode()):
        raise HTTPException(status_code=401, detail="Unauthorized")


Auth = Annotated[None, Depends(_require_auth)]

app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")


@app.get("/", include_in_schema=False)
def index():
    return FileResponse(str(STATIC_DIR / "index.html"))


# ── Helpers ───────────────────────────────────────────────────────────────────

def _run(cmd: list[str], timeout: int = 10) -> tuple[int, str, str]:
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, shell=False)
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "timeout"
    except FileNotFoundError:
        return -1, "", f"not found: {cmd[0]}"
    except Exception as exc:
        return -1, "", str(exc)


def _env_value(key: str) -> str:
    if not GW_ENV.exists():
        return ""
    for line in GW_ENV.read_text().splitlines():
        s = line.strip()
        if s.startswith(f"{key}="):
            return s[len(key) + 1:].strip()
    return ""


def _service_info(unit: str) -> dict:
    rc, out, _ = _run(["systemctl", "is-active", unit])
    state = out.strip() or ("active" if rc == 0 else "inactive")
    _, ts_out, _ = _run(
        ["systemctl", "show", unit, "--property=ActiveEnterTimestamp", "--value"]
    )
    return {"unit": unit, "state": state, "since": ts_out.strip()}


def _service_installed(unit: str) -> bool:
    rc, _, _ = _run(["systemctl", "cat", unit])
    return rc == 0


def _write_config(updates: dict) -> None:
    current: dict = {}
    if CONFIG_PATH.exists():
        for raw in CONFIG_PATH.read_text().splitlines():
            s = raw.strip()
            if not s or s.startswith("#") or "=" not in s:
                continue
            k, _, v = s.partition("=")
            current[k.strip()] = v.strip()
    current.update({str(k): str(v) for k, v in updates.items()})
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    CONFIG_PATH.write_text("".join(f"{k}={v}\n" for k, v in current.items()))
    CONFIG.update(updates)
    if "port" in updates:
        CONFIG["port"] = int(str(updates["port"]))


async def _restart_after(unit: str, delay: float = 0.8) -> None:
    await asyncio.sleep(delay)
    _run(["sudo", _SYSTEMCTL, "restart", unit])


# ── Dashboard / System Info ──────────────────────────────────────────────────

@app.get("/api/identity")
def api_identity(_: Auth):
    result: dict = {"key": "", "name": "", "eui": "", "region": ""}
    for conf in (HELIUM_CONF, HELIUM_CONF2):
        if Path(conf).exists():
            rc, out, _ = _run([HELIUM_GW, "-c", conf, "key", "info"])
            if rc == 0:
                try:
                    info = json.loads(out)
                    result["key"]  = info.get("key", "")
                    result["name"] = info.get("name", "")
                except json.JSONDecodeError:
                    pass
            break
    try:
        mac = Path("/sys/class/net/eth0/address").read_text().strip().replace(":", "").upper()
        result["eui"] = f"{mac[:6]}FFFE{mac[6:]}"
    except Exception:
        pass
    result["region"] = _env_value("BAND") or "unknown"
    return result


@app.get("/api/status")
def api_status(_: Auth):
    services = ["pktfwd", "gateway-rs", "readsb", "wingbits", "tailscaled"]
    result = {}
    for s in services:
        unit = f"{s}.service"
        if _service_installed(unit):
            result[s] = _service_info(unit)
        else:
            result[s] = {"unit": unit, "state": "not-installed", "since": ""}
    return result


@app.get("/api/sysinfo")
def api_sysinfo(_: Auth):
    try:
        raw = int(Path("/sys/class/thermal/thermal_zone0/temp").read_text().strip())
        cpu = f"{raw / 1000:.1f} °C"
    except Exception:
        cpu = "unavailable"
    _, mem, _ = _run(["free", "-m"])
    _, disk, _ = _run(["df", "-h", "/opt"])
    image_ver = "Development build"
    build_date = ""
    if GW_RELEASE.exists():
        for line in GW_RELEASE.read_text().splitlines():
            if line.startswith("IMAGE_VERSION="):
                image_ver = line.split("=", 1)[1].strip()
            elif line.startswith("BUILD_DATE="):
                build_date = line.split("=", 1)[1].strip()
    return {
        "cpu_temp":     cpu,
        "memory":       mem.strip()  or "unavailable",
        "disk":         disk.strip() or "unavailable",
        "hostname":     socket.gethostname(),
        "image_version": image_ver,
        "build_date":   build_date,
    }


@app.get("/api/beacon")
def api_beacon(_: Auth):
    from datetime import datetime, timezone, timedelta

    rc, out, _ = _run(
        ["journalctl", "-u", "gateway-rs", "-n", "500", "--no-pager", "--output=short-iso"],
        timeout=15,
    )
    lines = out.splitlines() if rc == 0 else []
    cutoff = datetime.now(timezone.utc) - timedelta(hours=24)

    last_beacon: dict | None = None
    next_beacon: str | None = None
    witness_count = 0

    for line in reversed(lines):
        ll = line.lower()
        if last_beacon is None and "transmit" in ll and "beacon" in ll:
            m = re.match(r"^(\S+)", line)
            last_beacon = {"timestamp": m.group(1) if m else "", "line": line.strip()}
        if next_beacon is None and "next beacon" in ll:
            m = re.search(r"(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2})", line)
            if m:
                next_beacon = m.group(1)

    for line in lines:
        if "witness" in line.lower():
            m = re.match(r"^(\S+)", line)
            if m:
                try:
                    ts = datetime.fromisoformat(m.group(1).replace("+0000", "+00:00"))
                    if ts >= cutoff:
                        witness_count += 1
                except ValueError:
                    pass

    return {
        "last_beacon":       last_beacon,
        "next_beacon":       next_beacon,
        "witness_count_24h": witness_count,
    }


# ── Band / Region ────────────────────────────────────────────────────────────

@app.get("/api/bands")
def api_bands(_: Auth):
    prefix, suffix = "global_conf.", ".json"
    regions = sorted(
        p.name[len(prefix):-len(suffix)]
        for p in GW_CONFIG_DIR.glob(f"{prefix}*{suffix}")
        if BAND_RE.fullmatch(p.name[len(prefix):-len(suffix)])
    )
    return {"regions": regions, "current": _env_value("BAND")}


@app.post("/api/band")
async def api_set_band(_: Auth, request: Request):
    body = await request.json()
    region = str(body.get("region", ""))
    if not BAND_RE.fullmatch(region):
        raise HTTPException(status_code=400, detail="Invalid region name")
    if not (GW_CONFIG_DIR / f"global_conf.{region}.json").exists():
        raise HTTPException(status_code=400, detail="Unknown region")
    rc, out, err = _run(["sudo", _APPLY_BAND, region], timeout=30)
    if rc != 0:
        raise HTTPException(status_code=500, detail=err or "apply-band failed")
    return {"ok": True, "output": out}


# ── Service Restart ──────────────────────────────────────────────────────────

@app.post("/api/restart/{service}")
def api_restart(_: Auth, service: str):
    allowed = {"pktfwd": "pktfwd.service", "gateway-rs": "gateway-rs.service"}
    if service not in allowed:
        raise HTTPException(status_code=400, detail="Unknown service")
    rc, _, err = _run(["sudo", _SYSTEMCTL, "restart", allowed[service]])
    if rc != 0:
        raise HTTPException(status_code=500, detail=err or "restart failed")
    return {"ok": True}


# ── Wingbits ─────────────────────────────────────────────────────────────────

@app.get("/api/wingbits")
def api_wingbits(_: Auth):
    readsb_installed   = _service_installed("readsb.service")
    wingbits_installed = _service_installed("wingbits.service")
    return {
        "readsb":   _service_info("readsb.service")   if readsb_installed   else {"unit": "readsb.service",   "state": "not-installed", "since": ""},
        "wingbits": _service_info("wingbits.service") if wingbits_installed else {"unit": "wingbits.service", "state": "not-installed", "since": ""},
    }


def _validate_wingbits_url(url: str) -> str | None:
    if not url:
        return "URL is required"
    if not WINGBITS_URL_RE.match(url):
        return "URL must start with https://gitlab.com/wingbits/config/-/raw/"
    if SHELL_META_RE.search(url):
        return "URL contains invalid characters"
    return None


@app.post("/api/wingbits/setup")
async def api_wingbits_setup(_: Auth, request: Request):
    global _wingbits_running

    if not Path(WRAPPER_BIN).exists():
        raise HTTPException(status_code=503, detail="Setup wrapper not installed — run install-wingbits-deps.sh")

    if _wingbits_running:
        raise HTTPException(status_code=409, detail="Setup already in progress")

    body = await request.json()
    url = str(body.get("url", ""))
    err = _validate_wingbits_url(url)
    if err:
        raise HTTPException(status_code=400, detail=err)

    _wingbits_running = True

    async def event_stream():
        global _wingbits_running
        try:
            proc = await asyncio.create_subprocess_exec(
                WRAPPER_BIN, url,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
            )
            while True:
                line = await proc.stdout.readline()
                if not line:
                    break
                yield f"data: {line.decode('utf-8', errors='replace').rstrip()}\n\n"
            exit_code = await proc.wait()
            yield f"data: {json.dumps({'exit_code': exit_code})}\n\n"
        finally:
            _wingbits_running = False

    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


# ── Network — Interfaces ─────────────────────────────────────────────────────

@app.get("/api/network/interfaces")
def api_network_interfaces(_: Auth):
    result = {}
    for iface in ("eth0", "wlan0"):
        info: dict = {"name": iface, "link": "Down", "ipv4": "", "ipv6": "", "mac": ""}
        path = Path(f"/sys/class/net/{iface}")
        if not path.exists():
            info["link"] = "N/A"
            result[iface] = info
            continue
        op = path / "operstate"
        if op.exists():
            info["link"] = op.read_text().strip()
            if info["link"] == "up":
                info["link"] = "Up"
            elif info["link"] == "down":
                info["link"] = "Down"
        mac_path = path / "address"
        if mac_path.exists():
            info["mac"] = mac_path.read_text().strip()
        # Get IPs from ip addr
        rc, out, _ = _run(["ip", "addr", "show", iface])
        if rc == 0:
            for line in out.splitlines():
                m4 = re.search(r"inet (\d+\.\d+\.\d+\.\d+/\d+)", line)
                if m4 and not line.strip().startswith("valid_lft"):
                    info["ipv4"] = m4.group(1)
                m6 = re.search(r"inet6 ([0-9a-f:]+/\d+)", line)
                if m6:
                    info["ipv6"] = m6.group(1)
        # SSID for wlan0
        if iface == "wlan0":
            rc2, ssid_out, _ = _run(["iwgetid", "-r", iface])
            info["ssid"] = ssid_out.strip() if rc2 == 0 else "N/A"
        result[iface] = info
    return result


# ── Network — Tailscale ──────────────────────────────────────────────────────

@app.get("/api/network/tailscale")
def api_network_tailscale(_: Auth):
    if not Path("/usr/bin/tailscale").exists():
        return {"status": "not-installed"}

    ts_installed = _service_installed("tailscaled.service")
    if not ts_installed:
        return {"status": "not-installed"}

    ts_info = _service_info("tailscaled.service")
    if ts_info["state"] != "active":
        return {"status": "stopped", "service": ts_info}

    rc, out, _ = _run([_TAILSCALE, "status", "--json"])
    if rc != 0:
        return {"status": "error", "detail": out.strip() or "tailscale status failed"}

    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        return {"status": "error", "detail": "failed to parse tailscale status"}

    self_info = data.get("Self", {})
    online = self_info.get("Online", False)
    ips = self_info.get("TailscaleIPs", [])
    hostname = self_info.get("DNSName", "").rstrip(".")

    # Check subnet routing
    ip_forward = False
    rc2, fwd_out, _ = _run(["cat", "/proc/sys/net/ipv4/ip_forward"])
    if rc2 == 0 and fwd_out.strip() == "1":
        ip_forward = True

    # Check advertised routes from tailscale status (may not be present in JSON)
    advertised = ""
    # Check tailscale up output for --advertise-routes
    rc3, up_out, _ = _run([_TAILSCALE, "up", "--json"])
    if rc3 == 0:
        try:
            up_data = json.loads(up_out)
            advertised = up_data.get("AdvertisedRoutes", "")
        except (json.JSONDecodeError, AttributeError):
            advertised = ""

    return {
        "status": "connected",
        "online": online,
        "ips": ips,
        "hostname": hostname,
        "ip_forward": ip_forward,
        "advertised_routes": advertised,
    }


TS_KEY_VALID_RE = re.compile(r"^tskey(-auth)?-[A-Za-z0-9]+$")


@app.post("/api/network/tailscale/auth")
async def api_tailscale_auth(_: Auth, request: Request):
    body = await request.json()
    key = str(body.get("key", "")).strip()

    if not TS_KEY_VALID_RE.match(key):
        raise HTTPException(status_code=400, detail="Invalid auth key format — must start with tskey- or tskey-auth-")

    # Run tailscale up
    proc = await asyncio.create_subprocess_exec(
        "sudo", _TAILSCALE, "up", "--authkey", key,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await proc.communicate()

    # Scrub key from any output
    out_text = stdout.decode().replace(key, "[REDACTED]")
    err_text = stderr.decode().replace(key, "[REDACTED]")

    if proc.returncode != 0:
        raise HTTPException(status_code=500, detail=err_text or out_text or "tailscale up failed")

    return {"ok": True, "output": out_text}


@app.post("/api/network/tailscale/routing")
async def api_tailscale_routing(_: Auth, request: Request):
    body = await request.json()
    enabled = bool(body.get("enabled", False))
    subnets_str = str(body.get("subnets", "")).strip()

    if enabled and not subnets_str:
        raise HTTPException(status_code=400, detail="Subnets required when enabling routing")
    if subnets_str:
        parts = [s.strip() for s in subnets_str.split(",") if s.strip()]
        for p in parts:
            if not CIDR_RE.match(p):
                raise HTTPException(status_code=400, detail=f"Invalid CIDR: {p}")

    cmd = ["sudo", _TAILSCALE, "up"]
    if enabled:
        cmd += ["--advertise-routes", subnets_str]

    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await proc.communicate()
    out_text = stdout.decode()
    err_text = stderr.decode()

    if proc.returncode != 0:
        raise HTTPException(status_code=500, detail=err_text or out_text or "tailscale routing failed")

    # Persist ip_forward setting
    if enabled:
        sysctl_conf = Path("/etc/sysctl.d/99-tailscale.conf")
        sysctl_conf.write_text("net.ipv4.ip_forward=1\n")
        _run([_SYSCTL_W, "net.ipv4.ip_forward=1"])

    return {"ok": True, "output": out_text}


# ── Logs ─────────────────────────────────────────────────────────────────────

UNIT_MAP = {
    "system":    [],
    "helium":    ["pktfwd.service", "gateway-rs.service"],
    "wingbits":  ["readsb.service", "wingbits.service"],
    "tailscale": ["tailscaled.service"],
}


@app.get("/api/logs")
def api_logs(_: Auth, units: str = ""):
    if units:
        selected = [u.strip() for u in units.split(",") if u.strip()]
        unit_args = []
        for s in selected:
            if s in UNIT_MAP:
                unit_args.extend(UNIT_MAP[s])
            elif s in ALLOWED_TAILSCALE_UNITS:
                unit_args.append(f"{s}.service")
        if not unit_args:
            unit_args = ["gateway-rs.service"]
    else:
        unit_args = ["gateway-rs.service"]

    cmd = ["journalctl", "-n", "200", "--no-pager", "--output=short-iso"]
    for u in unit_args:
        cmd += ["-u", u]

    rc, out, _ = _run(cmd, timeout=15)
    return {"lines": out.splitlines() if rc == 0 else []}


# ── Settings ─────────────────────────────────────────────────────────────────

@app.get("/api/settings")
def api_get_settings(_: Auth):
    return {
        "port":      CONFIG.get("port", 8080),
        "bind_host": CONFIG.get("bind_host", "0.0.0.0"),
    }


@app.get("/api/settings/token")
def api_get_token(_: Auth):
    t = TOKEN_PATH.read_text().strip() if TOKEN_PATH.exists() else ""
    masked = (t[:4] + "••••••••" + t[-4:]) if len(t) >= 8 else "••••••••"
    return {"masked": masked, "full": t}


@app.post("/api/settings/token")
async def api_regen_token(_: Auth, bg: BackgroundTasks):
    new_token = secrets.token_hex(32)
    TOKEN_PATH.write_text(new_token + "\n")
    bg.add_task(_restart_after, "gateway-ui")
    return {"ok": True, "token": new_token}


@app.post("/api/settings/port")
async def api_set_port(_: Auth, request: Request, bg: BackgroundTasks):
    body = await request.json()
    try:
        port = int(body.get("port", 8080))
    except (ValueError, TypeError):
        raise HTTPException(status_code=400, detail="Invalid port")
    if not 1024 <= port <= 65535:
        raise HTTPException(status_code=400, detail="Port must be 1024–65535")
    _write_config({"port": str(port)})
    bg.add_task(_restart_after, "gateway-ui")
    return {"ok": True, "port": port}


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    uvicorn.run(
        "main:app",
        host=str(CONFIG.get("bind_host", "0.0.0.0")),
        port=int(CONFIG.get("port", 8080)),
        log_level="info",
    )
