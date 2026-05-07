#!/usr/bin/env python3
import asyncio
import hmac
import json
import re
import secrets
import subprocess
import sys
from pathlib import Path
from typing import Annotated

import uvicorn
from fastapi import BackgroundTasks, Depends, FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

# ── Paths ─────────────────────────────────────────────────────────────────────

CONFIG_PATH   = Path("/opt/gateway-ui/config")
TOKEN_PATH    = Path("/etc/gateway-ui/token")
GW_CONFIG_DIR = Path("/opt/gateway/config")
GW_ENV        = Path("/opt/gateway/config.env")
STATIC_DIR    = Path(__file__).parent / "static"

HELIUM_GW     = "/usr/local/bin/helium_gateway"
HELIUM_CONF   = "/etc/helium_gateway/settings.toml"
HELIUM_CONF2  = "/opt/gateway/config/settings.toml"

# Sudoers-granted commands — must match /etc/sudoers.d/10-gateway-ui exactly
_SYSTEMCTL    = "/bin/systemctl"
_APPLY_BAND   = "/opt/gateway/scripts/apply-band.sh"

BAND_RE = re.compile(r"^[a-z][a-z0-9_]{1,30}$")

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


def _tailscale_ip() -> str:
    rc, out, _ = _run(["ip", "addr", "show", "tailscale0"])
    if rc != 0:
        return "127.0.0.1"
    for line in out.splitlines():
        m = re.search(r"inet (\d+\.\d+\.\d+\.\d+)/", line)
        if m:
            return m.group(1)
    return "127.0.0.1"


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


# ── Identity ──────────────────────────────────────────────────────────────────

@app.get("/api/identity")
def api_identity(_: Auth):
    result: dict = {"address": "", "name": "", "eui": "", "region": ""}

    for conf in (HELIUM_CONF, HELIUM_CONF2):
        if Path(conf).exists():
            rc, out, _ = _run([HELIUM_GW, "-c", conf, "key", "info"])
            if rc == 0:
                try:
                    info = json.loads(out)
                    result["address"] = info.get("address", "")
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


# ── Status ────────────────────────────────────────────────────────────────────

@app.get("/api/status")
def api_status(_: Auth):
    return {
        "pktfwd":     _service_info("pktfwd.service"),
        "gateway_rs": _service_info("gateway-rs.service"),
    }


@app.post("/api/restart/{service}")
def api_restart(_: Auth, service: str):
    allowed = {"pktfwd": "pktfwd.service", "gateway-rs": "gateway-rs.service"}
    if service not in allowed:
        raise HTTPException(status_code=400, detail="Unknown service")
    rc, _, err = _run(["sudo", _SYSTEMCTL, "restart", allowed[service]])
    if rc != 0:
        raise HTTPException(status_code=500, detail=err or "restart failed")
    return {"ok": True}


# ── Beacon / Witness ──────────────────────────────────────────────────────────

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


# ── System Info ───────────────────────────────────────────────────────────────

@app.get("/api/sysinfo")
def api_sysinfo(_: Auth):
    try:
        raw = int(Path("/sys/class/thermal/thermal_zone0/temp").read_text().strip())
        cpu = f"{raw / 1000:.1f} °C"
    except Exception:
        cpu = "unavailable"
    _, mem, _ = _run(["free", "-m"])
    _, disk, _ = _run(["df", "-h", "/opt"])
    return {
        "cpu_temp": cpu,
        "memory":   mem.strip()  or "unavailable",
        "disk":     disk.strip() or "unavailable",
    }


# ── Logs ──────────────────────────────────────────────────────────────────────

@app.get("/api/logs")
def api_logs(_: Auth):
    rc, out, _ = _run(
        ["journalctl", "-u", "gateway-rs", "-n", "100", "--no-pager", "--output=short-iso"],
        timeout=15,
    )
    return {"lines": out.splitlines() if rc == 0 else []}


# ── Band ──────────────────────────────────────────────────────────────────────

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


# ── Settings ──────────────────────────────────────────────────────────────────

@app.get("/api/settings")
def api_get_settings(_: Auth):
    return {
        "lan_access": CONFIG.get("bind_host", "0.0.0.0") == "0.0.0.0",
        "port":       CONFIG.get("port", 8080),
        "bind_host":  CONFIG.get("bind_host", "0.0.0.0"),
    }


@app.post("/api/settings/lan")
async def api_set_lan(_: Auth, request: Request, bg: BackgroundTasks):
    body = await request.json()
    enabled = bool(body.get("enabled", True))
    bind_host = "0.0.0.0" if enabled else _tailscale_ip()
    _write_config({"bind_host": bind_host})
    bg.add_task(_restart_after, "gateway-ui")
    return {"ok": True, "bind_host": bind_host}


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
