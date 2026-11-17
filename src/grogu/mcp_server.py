#!/usr/bin/env python3
"""
Grogu MCP Server (`grogu-ios`) for native iOS/iPadOS UI control, Decision API,
low-level DVT/Lockdownd telemetry, and Siri voice task inspection over Tailscale.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from mcp.server.mcpserver import MCPServer
from mcp.server.transport_security import TransportSecuritySettings

from grogu.config import BIND_HOST, DEVICE_IP, GATEWAY_PORT, MCP_HTTP_PORT, OUTPUT_DIR
from grogu.core import GroguCoreManager
from grogu.decision_engine import DecisionEngine
from grogu.wda_client import FastWDAClient

OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

mcp = MCPServer(
    "grogu-ios",
    instructions=(
        f"MCP Server providing direct Tailscale control of an unjailbroken iOS/iPadOS device ({DEVICE_IP}): "
        "ultra-fast native UI hierarchy dump (XCAXClient_iOS / FastWDA), deterministic Decision API execution, "
        "low-level DVT/IORegistry/oslog/pcap/URL-scheme telemetry, and Siri voice task inspection."
    ),
)

_core = GroguCoreManager()
_wda = FastWDAClient(core=_core)
_engine = DecisionEngine(core=_core, wda=_wda)


@mcp.tool()
async def ios_status() -> dict[str, Any]:
    """Query device status: Tailscale ports (62078/49152/8100), pairing keys, WDA readiness, and foreground app."""
    ports = _core.probe_ports()
    pairing = _core.get_pairing_status()
    result: dict[str, Any] = {
        "device_ip": DEVICE_IP,
        "gateway": f"http://{BIND_HOST}:{GATEWAY_PORT}",
        "ports": ports,
        "pairing": pairing,
        "wda_ready": False,
    }
    if ports["wda_direct_8100"] or ports["wda_forward_18832"]:
        try:
            result["wda_status"] = await _wda.status()
            result["active_app"] = await _wda.active_app_info()
            result["wda_ready"] = True
        except Exception as exc:
            result["wda_error"] = str(exc)
    return result


@mcp.tool()
async def ios_ui_dump(compact: bool = True) -> dict[str, Any]:
    """Dump current UI accessibility hierarchy cleanly in milliseconds."""
    return await _wda.fast_ui_dump(compact=compact)


@mcp.tool()
async def ios_tap(x: int, y: int) -> dict[str, Any]:
    """Tap at screen point coordinates (x, y)."""
    return await _wda.tap(x, y)


@mcp.tool()
async def ios_tap_element(text: str, exact: bool = False) -> dict[str, Any]:
    """Find a visible UI element by label/name/value and tap its center immediately."""
    return await _engine.execute_steps([{"op": "tap_selector", "text": text, "exact": exact}])


@mcp.tool()
async def ios_swipe(x1: int, y1: int, x2: int, y2: int, duration_ms: int = 250) -> dict[str, Any]:
    """Swipe from (x1, y1) to (x2, y2) with duration in milliseconds."""
    return await _wda.swipe(x1, y1, x2, y2, duration_ms=duration_ms)


@mcp.tool()
async def ios_input_text(text: str) -> dict[str, Any]:
    """Type text into the currently focused field."""
    return await _wda.type_text(text)


@mcp.tool()
async def ios_key(key_name: str) -> dict[str, Any]:
    """Press hardware button: HOME, VOLUME_UP, or VOLUME_DOWN."""
    return await _wda.press_button(key_name)


@mcp.tool()
async def ios_launch_app(app_target: str) -> dict[str, Any]:
    """Launch an app by alias, Bundle ID, or URL Scheme DeepLink."""
    return await _engine.execute_steps([{"op": "launch", "app": app_target}])


@mcp.tool()
async def ios_decision_run(steps_json: str) -> dict[str, Any]:
    """Execute a deterministic Decision API JSON step list (launch, open_url, tap, tap_selector, wait_selector, swipe, type, button, sleep, reflex, ai_tap)."""
    parsed = json.loads(steps_json)
    steps = parsed["steps"] if isinstance(parsed, dict) and "steps" in parsed else parsed
    if not isinstance(steps, list):
        raise ValueError("steps_json must decode to a JSON array of steps or {'steps': [...]}")
    return await _engine.execute_steps(steps)


@mcp.tool()
async def ios_ai_act(goal: str, max_steps: int = 6, prefer: str = "auto", verify_final: bool = False) -> dict[str, Any]:
    """Execute a multi-step natural-language iOS/iPadOS UI goal via Decision-1 + fast LLM routing."""
    return await _engine.run_ai_goal(goal, max_steps=max_steps, prefer=prefer, verify_final=verify_final)


@mcp.tool()
async def ios_lowlevel_telemetry(kind: str, filter_text: str = "") -> dict[str, Any]:
    """Read low-level iOS/iPadOS telemetry over Tailscale DVT/Lockdownd.
    Supported kind: summary, processes, ioregistry, schemes, oslog, network, accessibility, dvt_launch, dvt_kill.
    """
    return await _core.get_telemetry(kind, filter_text=filter_text)


@mcp.tool()
async def ios_screenshot(filename: str = "grogu_latest.png") -> dict[str, Any]:
    """Capture screen PNG (via WDA if running, else DVT Screenshot)."""
    local_path = OUTPUT_DIR / Path(filename).name
    try:
        res = await _wda.screenshot(local_path)
    except Exception:
        res = await _core.get_telemetry("screenshot", out_path=str(local_path))
    if res.get("ok") and local_path.exists():
        res["file_url"] = f"file://{local_path}"
    return res


@mcp.tool()
async def ios_siri_tasks(limit: int = 10) -> dict[str, Any]:
    """Read recent Siri voice commands & execution traces received by the gateway."""
    return {"ok": True, "tasks": _engine.read_siri_tasks(limit=limit)}


def main() -> None:
    parser = argparse.ArgumentParser(description="Grogu iOS/iPadOS Tailscale MCP Server")
    parser.add_argument("--transport", choices=["stdio", "streamable-http"], default="stdio")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=MCP_HTTP_PORT)
    args = parser.parse_args()

    if args.transport == "streamable-http":
        ts = TransportSecuritySettings(enable_dns_rebinding_protection=False)
        mcp.run(
            transport="streamable-http",
            host=args.host,
            port=args.port,
            stateless_http=True,
            transport_security=ts,
        )
    else:
        mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
