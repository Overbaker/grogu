"""Tailscale-only HTTP Gateway for Grogu (FastWDA + Decision API + DVT + Siri + Mac Bootstrap)."""

from __future__ import annotations

import argparse
import asyncio
from contextlib import asynccontextmanager
from datetime import datetime, timezone
import json
import time
from typing import Any
import uuid

from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import FileResponse, HTMLResponse, JSONResponse, PlainTextResponse
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
    agent = "auto"
    ct = request.headers.get("content-type", "")
    try:
        if "application/json" in ct:
            body = await request.json()
            if isinstance(body, dict):
                text = str(body.get("text") or body.get("command") or body.get("query") or "")
                agent = str(body.get("agent") or body.get("prefer") or "auto")
        elif "form" in ct:
            form = await request.form()
            text = str(form.get("text") or form.get("command") or "")
            agent = str(form.get("agent") or form.get("prefer") or "auto")
        else:
            raw = (await request.body()).decode("utf-8", errors="replace").strip()
            if raw.startswith("{"):
                body = json.loads(raw)
                text = str(body.get("text") or body.get("command") or "")
                agent = str(body.get("agent") or body.get("prefer") or "auto")
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
    asyncio.create_task(engine.run_async_voice_task(task_id, mode, payload, text, agent=agent))
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
        prefer = str(body.get("agent") or body.get("prefer") or "auto")
        verify_final = bool(body.get("verify_final", False))
        async_tap = bool(body.get("async_tap", False))
        res = await engine.run_ai_goal(
            goal, max_steps=max_steps, prefer=prefer, verify_final=verify_final, async_tap=async_tap
        )
        return JSONResponse(res, status_code=200 if res.get("ok") else 500)
    except Exception as exc:
        return JSONResponse({"ok": False, "error": str(exc)}, status_code=500)


async def ai_plan(request: Request) -> JSONResponse:
    try:
        body = await request.json()
        if not isinstance(body, dict) or not str(body.get("goal", "")).strip():
            return JSONResponse({"ok": False, "error": "Request JSON must include non-empty 'goal'"}, status_code=400)
        goal = str(body["goal"]).strip()
        elements = body.get("elements") if isinstance(body.get("elements"), list) else []
        history = [str(x) for x in (body.get("history") or [])]
        prefer = str(body.get("agent") or body.get("prefer") or "auto")
        t0 = time.perf_counter()
        plan = await engine.plan_step_auto(goal, elements, history, prefer=prefer)
        return JSONResponse(
            {
                "ok": True,
                "ai_ms": round((time.perf_counter() - t0) * 1000, 1),
                "plan": plan,
            }
        )
    except Exception as exc:
        return JSONResponse({"ok": False, "error": str(exc)}, status_code=500)


async def ai_config(request: Request) -> JSONResponse:
    try:
        if request.method == "GET":
            return JSONResponse({"ok": True, "ai_engines": engine.get_ai_engine_status()})
        body = await request.json()
        if not isinstance(body, dict):
            return JSONResponse({"ok": False, "error": "Request JSON must be an object"}, status_code=400)
        res = await engine.set_ai_config(
            default_agent=body.get("default_agent"),
            pi_provider=body.get("pi_provider"),
            pi_model=body.get("pi_model"),
            pi_thinking=body.get("pi_thinking"),
        )
        return JSONResponse({"ok": True, "ai_engines": res})
    except Exception as exc:
        return JSONResponse({"ok": False, "error": str(exc)}, status_code=400)


_IPAD_LOCAL_RUNNER_HTML = """<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1" />
<title>Grogu On-Device 127.0.0.1 Runner</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 16px; background: #0f172a; color: #e2e8f0; }
  .card { background: #1e293b; border-radius: 12px; padding: 14px; margin-bottom: 12px; }
  input, button { font-size: 16px; border-radius: 8px; border: 1px solid #334155; padding: 10px 12px; }
  input { width: 100%; box-sizing: border-box; background: #0f172a; color: #f8fafc; margin-bottom: 10px; }
  button { background: #2563eb; color: #fff; border: none; font-weight: 600; cursor: pointer; margin: 4px 6px 4px 0; }
  button.sec { background: #334155; font-size: 14px; padding: 8px 10px; }
  pre { background: #020617; padding: 10px; border-radius: 8px; overflow-x: auto; font-size: 13px; white-space: pre-wrap; }
</style>
</head>
<body>
  <div class="card">
    <h3 style="margin:0 0 8px">Grogu iPad 本机回环 Runner (127.0.0.1:8100)</h3>
    <div style="font-size:13px;color:#94a3b8;margin-bottom:10px">读屏 &amp; 触控均走本机回环，AI 规划走 /api/ai/plan</div>
    <input id="goal" placeholder="输入指令，如：在设置里点开电池页面" />
    <button onclick="runGoal()">执行本机闭环</button>
    <div style="margin-top:8px">
      <button class="sec" onclick="quick('在设置里点开电池页面')">电池</button>
      <button class="sec" onclick="quick('在设置里点开通用页面')">通用</button>
      <button class="sec" onclick="quick('在设置里点开蓝牙页面')">蓝牙</button>
      <button class="sec" onclick="quick('在设置里点开无线局域网页面')">Wi-Fi</button>
    </div>
  </div>
  <div class="card">
    <div id="metrics" style="font-weight:600;margin-bottom:8px">待命</div>
    <pre id="log">等待执行...</pre>
  </div>
<script>
const WDA = 'http://127.0.0.1:8100';
const INTERACTIVE = new Set(['Button','TextField','SecureTextField','SearchField','Cell','Switch','Link','Tab','Slider','TextView']);
let cachedSid = null;

function quick(g) { document.getElementById('goal').value = g; runGoal(); }

async function ensureSid() {
  if (cachedSid) return cachedSid;
  const st = await (await fetch(WDA + '/status')).json();
  let sid = st.sessionId || (st.value && st.value.sessionId);
  if (!sid) {
    const cr = await (await fetch(WDA + '/session', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({capabilities: {alwaysMatch: {}}, desiredCapabilities: {}})
    })).json();
    sid = cr.sessionId || (cr.value && cr.value.sessionId);
  }
  await fetch(WDA + '/session/' + sid + '/appium/settings', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({settings: {waitForIdleTimeout: 0, animationCoolOffTimeout: 0, waitForQuiescence: false, snapshotMaxDepth: 16}})
  }).catch(() => {});
  cachedSid = sid;
  return sid;
}

function parseXmlElements(xmlText, maxEl = 160) {
  const doc = new DOMParser().parseFromString(xmlText, 'text/xml');
  const all = doc.getElementsByTagName('*');
  const out = [];
  for (let i = 0; i < all.length && out.length < maxEl; i++) {
    const el = all[i];
    const t = el.tagName.replace(/^XCUIElementType/, '');
    const label = (el.getAttribute('label') || '').trim();
    const name = (el.getAttribute('name') || '').trim();
    const value = (el.getAttribute('value') || '').trim();
    const x = parseFloat(el.getAttribute('x') || '0') || 0;
    const y = parseFloat(el.getAttribute('y') || '0') || 0;
    const w = parseFloat(el.getAttribute('width') || '0') || 0;
    const h = parseFloat(el.getAttribute('height') || '0') || 0;
    const vis = (el.getAttribute('visible') || 'true').toLowerCase() !== 'false';
    const hasTxt = Boolean(label || name || value);
    if (w > 0 && h > 0 && (x + w) > 0 && (y + h) > 0 && y < 2200 && (hasTxt || INTERACTIVE.has(t)) && vis) {
      if ((t !== 'Application' && t !== 'Window') || hasTxt) {
        out.push({
          index: out.length,
          type: t, label, name, value,
          center: [Math.round(x + w / 2), Math.round(y + h / 2)],
        });
      }
    }
  }
  return out;
}

async function runGoal() {
  const goal = document.getElementById('goal').value.trim();
  if (!goal) return;
  const logEl = document.getElementById('log');
  const metEl = document.getElementById('metrics');
  metEl.textContent = '执行中...';
  try {
    const t0 = performance.now();
    const sid = await ensureSid();
    const tD0 = performance.now();
    const src = await (await fetch(WDA + '/source?excluded_attributes=visible,accessible')).json();
    const elements = parseXmlElements(src.value || '');
    const dumpMs = Math.round((performance.now() - tD0) * 10) / 10;

    const tA0 = performance.now();
    const planResp = await (await fetch('/api/ai/plan', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({goal, elements, history: []}),
    })).json();
    const aiMs = Math.round((performance.now() - tA0) * 10) / 10;

    const steps = (planResp.plan && planResp.plan.steps) || [];
    const tE0 = performance.now();
    if (steps.length === 1 && steps[0].op === 'tap') {
      const resp = await fetch(WDA + '/session/' + sid + '/wda/tap', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({x: steps[0].x, y: steps[0].y}),
      });
      if (resp.status === 404) { cachedSid = null; }
    } else if (steps.length > 0) {
      await fetch('/api/decision/execute', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({steps}),
      });
    }
    const tapMs = Math.round((performance.now() - tE0) * 10) / 10;
    const totalMs = Math.round((performance.now() - t0) * 10) / 10;
    metEl.textContent = `总 ${totalMs}ms (本机读屏 ${dumpMs}ms + AI ${aiMs}ms + 本机点击 ${tapMs}ms)`;
    logEl.textContent = JSON.stringify(planResp, null, 2);
  } catch (err) {
    metEl.textContent = '执行失败';
    logEl.textContent = String(err);
  }
}
</script>
</body>
</html>
"""


async def ipad_agent_page(request: Request) -> HTMLResponse:
    return HTMLResponse(_IPAD_LOCAL_RUNNER_HTML)


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
        Route("/api/ai/plan", ai_plan, methods=["POST"]),
        Route("/api/ai/config", ai_config, methods=["GET", "POST"]),
        Route("/ipad-agent", ipad_agent_page, methods=["GET"]),
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
