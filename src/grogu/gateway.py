"""Tailscale-only HTTP Gateway for Grogu (FastWDA + Decision API + DVT + Siri + Mac Bootstrap)."""

from __future__ import annotations

import argparse
import asyncio
from contextlib import asynccontextmanager
from datetime import datetime, timezone
import json
from typing import Any
import uuid

from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import FileResponse, JSONResponse, PlainTextResponse
from starlette.routing import Route
import uvicorn

from grogu.config import BIND_HOST, GATEWAY_PORT, OUTPUT_DIR, SSH_PUBKEY_PATH, STATE_DIR
from grogu.core import GroguCoreManager
from grogu.decision_engine import DecisionEngine
from grogu.wda_client import FastWDAClient

core = GroguCoreManager()
wda = FastWDAClient(core=core)
engine = DecisionEngine(core=core, wda=wda)


def _get_host_pubkey() -> str:
    if SSH_PUBKEY_PATH.exists():
        return SSH_PUBKEY_PATH.read_text(encoding="utf-8").strip()
    return ""


async def health(request: Request) -> JSONResponse:
    ports = core.probe_ports()
    pairing = core.get_pairing_status()
    wda_info: dict[str, Any] = {"reachable": bool(ports["wda_direct_8100"] or ports["wda_forward_18832"])}
    if wda_info["reachable"]:
        try:
            wda_info["status"] = await wda.status()
        except Exception as exc:
            wda_info["error"] = str(exc)
    return JSONResponse(
        {
            "ok": True,
            "service": "grogu-gateway",
            "bind": f"{BIND_HOST}:{GATEWAY_PORT}",
            "ts": datetime.now(timezone.utc).isoformat(),
            "ports": ports,
            "pairing": pairing,
            "wda": wda_info,
            "ai_engines": engine.get_ai_engine_status(),
        }
    )


async def siri_command(request: Request) -> JSONResponse:
    text = ""
    ct = request.headers.get("content-type", "")
    try:
        if "application/json" in ct:
            body = await request.json()
            if isinstance(body, dict):
                text = str(body.get("text") or body.get("command") or body.get("query") or "")
        elif "form" in ct:
            form = await request.form()
            text = str(form.get("text") or form.get("command") or "")
        else:
            raw = (await request.body()).decode("utf-8", errors="replace").strip()
            if raw.startswith("{"):
                body = json.loads(raw)
                text = str(body.get("text") or body.get("command") or "")
            else:
                text = raw
    except Exception as exc:
        return JSONResponse({"ok": False, "speak": f"解析语音指令失败：{exc}"}, status_code=400)

    text = text.strip()
    if not text:
        return JSONResponse({"ok": False, "speak": "没有收到有效语音内容。"}, status_code=400)

    mode, payload, spoken_ack = engine.route_voice_command(text)
    if mode == "sync_query":
        answer = await payload()
        engine.log_siri_task(
            {
                "task_id": uuid.uuid4().hex[:10],
                "ts": datetime.now(timezone.utc).isoformat(),
                "text": text,
                "mode": "sync_query",
                "ok": True,
                "speak": answer,
            }
        )
        return JSONResponse({"ok": True, "mode": "sync_query", "speak": answer})

    task_id = uuid.uuid4().hex[:10]
    asyncio.create_task(engine.run_async_voice_task(task_id, mode, payload, text))
    return JSONResponse({"ok": True, "mode": mode, "task_id": task_id, "speak": spoken_ack})


async def siri_tasks(request: Request) -> JSONResponse:
    limit = int(request.query_params.get("limit", "20"))
    return JSONResponse({"ok": True, "tasks": engine.read_siri_tasks(limit=limit)})


async def decision_execute(request: Request) -> JSONResponse:
    try:
        body = await request.json()
        steps = body.get("steps") if isinstance(body, dict) else None
        if not isinstance(steps, list) or not steps:
            return JSONResponse({"ok": False, "error": "Request JSON must include non-empty 'steps' list"}, status_code=400)
        res = await engine.execute_steps(steps)
        return JSONResponse(res, status_code=200 if res.get("ok") else 500)
    except Exception as exc:
        return JSONResponse({"ok": False, "error": str(exc)}, status_code=500)


async def ai_act(request: Request) -> JSONResponse:
    try:
        body = await request.json()
        if not isinstance(body, dict) or not str(body.get("goal", "")).strip():
            return JSONResponse({"ok": False, "error": "Request JSON must include non-empty 'goal'"}, status_code=400)
        goal = str(body["goal"]).strip()
        max_steps = int(body.get("max_steps", 6))
        prefer = str(body.get("prefer", "auto"))
        verify_final = bool(body.get("verify_final", False))
        res = await engine.run_ai_goal(goal, max_steps=max_steps, prefer=prefer, verify_final=verify_final)
        return JSONResponse(res, status_code=200 if res.get("ok") else 500)
    except Exception as exc:
        return JSONResponse({"ok": False, "error": str(exc)}, status_code=500)


async def screenshot_api(request: Request):
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    out_path = OUTPUT_DIR / "latest_screenshot.png"
    try:
        try:
            res = await wda.screenshot(out_path)
        except Exception:
            res = await core.get_telemetry("screenshot", out_path=str(out_path))
        if not res.get("ok") or not out_path.exists():
            return JSONResponse(
                {"ok": False, "error": res.get("error") or "Failed to capture screenshot"},
                status_code=500,
            )
        return FileResponse(out_path, media_type="image/png", filename="screenshot.png")
    except Exception as exc:
        return JSONResponse({"ok": False, "error": str(exc)}, status_code=500)


async def ui_dump(request: Request) -> JSONResponse:
    compact = request.query_params.get("compact", "true").lower() != "false"
    max_elements = int(request.query_params.get("max_elements", "100"))
    try:
        res = await wda.fast_ui_dump(compact=compact, max_elements=max_elements)
        return JSONResponse(res)
    except Exception as exc:
        return JSONResponse({"ok": False, "error": str(exc)}, status_code=503)


async def telemetry(request: Request) -> JSONResponse:
    kind = request.path_params["kind"]
    filter_text = request.query_params.get("filter", "")
    limit = int(request.query_params.get("limit", "80"))
    duration_s = float(request.query_params.get("duration", "2.5"))
    try:
        res = await core.get_telemetry(kind, filter_text=filter_text, limit=limit, duration_s=duration_s)
        return JSONResponse(res, status_code=200 if res.get("ok") else 500)
    except Exception as exc:
        return JSONResponse({"ok": False, "error": str(exc)}, status_code=500)


async def bootstrap_mac_script(request: Request) -> PlainTextResponse:
    pubkey = _get_host_pubkey()
    gw_url = str(request.base_url).rstrip("/")
    script = f"""#!/usr/bin/env bash
set -euo pipefail

GATEWAY_URL="{gw_url}"
HOST_PUBKEY="{pubkey}"

echo "=== [1/5] Authorize Grogu host SSH key on Mac ==="
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
if [ -n "$HOST_PUBKEY" ] && ! grep -Fq "$HOST_PUBKEY" "$HOME/.ssh/authorized_keys"; then
  printf '%s\\n' "$HOST_PUBKEY" >> "$HOME/.ssh/authorized_keys"
  echo "  -> Added SSH public key to ~/.ssh/authorized_keys"
fi

echo "=== [2/5] Locate or install pymobiledevice3 ==="
PMD_BIN=""
for cand in "$(command -v pymobiledevice3 2>/dev/null || true)" "$HOME/.local/bin/pymobiledevice3" "/opt/homebrew/bin/pymobiledevice3" "$HOME/.cache/grogu-venv/bin/pymobiledevice3"; do
  if [ -n "$cand" ] && [ -x "$cand" ]; then
    PMD_BIN="$cand"
    break
  fi
done

if [ -z "$PMD_BIN" ]; then
  if command -v uv >/dev/null 2>&1; then
    uv tool install pymobiledevice3
    PMD_BIN="$HOME/.local/bin/pymobiledevice3"
  else
    python3 -m venv "$HOME/.cache/grogu-venv"
    "$HOME/.cache/grogu-venv/bin/pip" install -q --upgrade pip pymobiledevice3
    PMD_BIN="$HOME/.cache/grogu-venv/bin/pymobiledevice3"
  fi
fi

echo "=== [3/5] Pair USB-connected iOS/iPadOS device ==="
UDID="$("$PMD_BIN" usbmux list -u --simple | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0] if isinstance(d,list) and d else "")')"
if [ -z "$UDID" ]; then
  echo "ERROR: No USB device detected. Unlock device and reconnect USB cable." >&2
  exit 1
fi
"$PMD_BIN" lockdown pair --udid "$UDID"
"$PMD_BIN" lockdown wifi-connections --udid "$UDID" on

TMP_LD="$(mktemp /tmp/grogu_ld.XXXXXX.plist)"
trap 'rm -f "$TMP_LD"' EXIT
"$PMD_BIN" lockdown save-pair-record --udid "$UDID" "$TMP_LD"
"$PMD_BIN" lockdown remotepairing --udid "$UDID" --pair >/dev/null || true
RP_PLIST="$HOME/.pymobiledevice3/remote_${{UDID}}.plist"
if [ ! -f "$RP_PLIST" ]; then
  RP_PLIST="$(ls -t "$HOME/.pymobiledevice3"/remote_*.plist 2>/dev/null | head -n 1 || true)"
fi

echo "=== [4/5] Upload pairing records to Grogu gateway ==="
MAC_USER="$(whoami)"
MAC_HOST="$(python3 -c 'import platform; print(platform.node())')"
XCODE_PATH="$(xcode-select -p 2>/dev/null || true)"

python3 - "$UDID" "$TMP_LD" "$RP_PLIST" "$MAC_USER" "$MAC_HOST" "$XCODE_PATH" "$GATEWAY_URL" << 'PYEOF'
import base64, json, pathlib, sys, urllib.request

udid, ld_path, rp_path, mac_user, mac_host, xcode_path, gw = sys.argv[1:]
payload = {{
    "udid": udid,
    "lockdown_b64": base64.b64encode(pathlib.Path(ld_path).read_bytes()).decode("ascii"),
    "remote_b64": base64.b64encode(pathlib.Path(rp_path).read_bytes()).decode("ascii") if rp_path and pathlib.Path(rp_path).exists() else None,
    "mac_user": mac_user,
    "mac_hostname": mac_host,
    "xcode_path": xcode_path,
}}
req = urllib.request.Request(
    f"{{gw}}/bootstrap/upload-pairing",
    data=json.dumps(payload).encode("utf-8"),
    headers={{"Content-Type": "application/json"}},
    method="POST",
)
with urllib.request.urlopen(req, timeout=15) as resp:
    print("  -> Upload response:", resp.read().decode("utf-8"))
PYEOF

echo "=== [5/5] Check macOS Remote Login (SSH port 22) ==="
if nc -z 127.0.0.1 22 >/dev/null 2>&1; then
  echo "  -> SSH (Remote Login) is enabled."
else
  open "x-apple.systempreferences:com.apple.Sharing-Settings.extension" || true
  echo "  -> Please toggle Remote Login ON in System Settings -> Sharing."
fi
"""
    return PlainTextResponse(script, media_type="text/x-shellscript")


async def bootstrap_upload_pairing(request: Request) -> JSONResponse:
    try:
        body = await request.json()
        res = core.save_uploaded_pairings(
            udid=str(body.get("udid") or ""),
            lockdown_b64=body.get("lockdown_b64"),
            remote_b64=body.get("remote_b64"),
            mac_user=body.get("mac_user"),
            mac_hostname=body.get("mac_hostname"),
            mac_tailscale_ip=body.get("mac_tailscale_ip"),
            xcode_path=body.get("xcode_path"),
            wda_bundle_id=body.get("wda_bundle_id"),
        )
        return JSONResponse(res)
    except Exception as exc:
        return JSONResponse({"ok": False, "error": str(exc)}, status_code=400)


async def bootstrap_wda_sideload_ipa(request: Request):
    ipa_path = STATE_DIR / "WebDriverAgentRunner-sideload.ipa"
    if not ipa_path.is_file():
        return JSONResponse(
            {
                "ok": False,
                "error": (
                    f"Sideload IPA not generated yet at {ipa_path}. "
                    "Run `grogu-prepare-wda-ipa --download -o ~/.config/grogu/WebDriverAgentRunner-sideload.ipa`."
                ),
            },
            status_code=404,
        )
    return FileResponse(
        ipa_path,
        media_type="application/octet-stream",
        filename="WebDriverAgentRunner-sideload.ipa",
    )


@asynccontextmanager
async def lifespan(app: Starlette):
    yield
    await engine.aclose()
    await wda.aclose()


app = Starlette(
    lifespan=lifespan,
    routes=[
        Route("/health", health, methods=["GET"]),
        Route("/api/siri/command", siri_command, methods=["POST"]),
        Route("/api/siri/tasks", siri_tasks, methods=["GET"]),
        Route("/api/decision/execute", decision_execute, methods=["POST"]),
        Route("/api/ai/act", ai_act, methods=["POST"]),
        Route("/api/ui/dump", ui_dump, methods=["GET"]),
        Route("/api/screenshot", screenshot_api, methods=["GET"]),
        Route("/api/telemetry/{kind}", telemetry, methods=["GET"]),
        Route("/bootstrap/mac.sh", bootstrap_mac_script, methods=["GET"]),
        Route("/bootstrap/upload-pairing", bootstrap_upload_pairing, methods=["POST"]),
        Route("/bootstrap/wda-sideload.ipa", bootstrap_wda_sideload_ipa, methods=["GET"]),
    ],
)


def main() -> None:
    parser = argparse.ArgumentParser(description="Grogu Tailscale Gateway")
    parser.add_argument("--host", default=BIND_HOST)
    parser.add_argument("--port", type=int, default=GATEWAY_PORT)
    args = parser.parse_args()
    uvicorn.run(app, host=args.host, port=args.port, log_level="info")


if __name__ == "__main__":
    main()
