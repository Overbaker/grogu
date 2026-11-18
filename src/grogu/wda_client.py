"""High-speed async WebDriverAgent client with XCAXClient_iOS latency tuning."""

from __future__ import annotations

import asyncio
import base64
import json
import os
from pathlib import Path
import re
import time
from typing import Any, Optional
import xml.etree.ElementTree as ET

import httpx

from grogu.config import DEVICE_IP, STATE_DIR, WDA_FORWARD_PORT
from grogu.core import GroguCoreManager

_FRAME_RE = re.compile(r"\{\{(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)\},\s*\{(\d+(?:\.\d+)?),\s*(\d+(?:\.\d+)?)\}\}")

_INTERACTIVE_TYPES = {
    "Button",
    "StaticText",
    "TextField",
    "SecureTextField",
    "SearchField",
    "Cell",
    "Switch",
    "Link",
    "Image",
    "Tab",
    "TabBar",
    "NavigationBar",
    "CheckBox",
    "RadioButton",
    "Slider",
    "PickerWheel",
    "MenuItem",
    "Icon",
    "TextView",
    "Alert",
    "Sheet",
}


class FastWDAClient:
    """Persistent async HTTP client for WebDriverAgent with fast tree snapshots & on-device reflex."""

    def __init__(
        self,
        core: Optional[GroguCoreManager] = None,
        direct_url: Optional[str] = None,
        forward_url: Optional[str] = None,
    ) -> None:
        self.core = core or GroguCoreManager()
        self.direct_url = (direct_url or f"http://{self.core.device_ip or DEVICE_IP}:8100").rstrip("/")
        self.forward_url = (forward_url or f"http://127.0.0.1:{WDA_FORWARD_PORT}").rstrip("/")
        self._active_base_url: Optional[str] = None
        self._base_url_verified_at: float = 0.0
        self._session_id: Optional[str] = None
        self._window_size: Optional[dict[str, int]] = None
        self._has_custom_fast_tree: Optional[bool] = None
        self._client = httpx.AsyncClient(timeout=8.0)

    async def aclose(self) -> None:
        await self._client.aclose()

    def _active_xctest_error(self) -> Optional[str]:
        status_path = STATE_DIR / "rsd_daemon.json"
        if not status_path.exists():
            return None
        try:
            data = json.loads(status_path.read_text(encoding="utf-8"))
            pid = int(data.get("pid") or 0)
            err = str(data.get("xctest_error") or "").strip()
            if pid > 0 and err:
                os.kill(pid, 0)
                return err
        except Exception:
            return None
        return None

    async def _resolve_base_url(self) -> str:
        xctest_err = self._active_xctest_error()
        if xctest_err and self._active_base_url is None:
            raise RuntimeError(f"WDA XCTest not active ({xctest_err})")

        if self._active_base_url and (time.monotonic() - self._base_url_verified_at) < 30.0:
            return self._active_base_url

        for candidate in ([self._active_base_url] if self._active_base_url else []) + [
            self.direct_url,
            self.forward_url,
        ]:
            if not candidate:
                continue
            try:
                resp = await self._client.get(f"{candidate}/status", timeout=2.0)
                if resp.status_code == 200:
                    self._active_base_url = candidate
                    self._base_url_verified_at = time.monotonic()
                    return candidate
            except Exception:
                continue

        if xctest_err:
            self._active_base_url = None
            self._base_url_verified_at = 0.0
            raise RuntimeError(f"WDA XCTest not active ({xctest_err})")

        res = await self.core.ensure_tunnel_and_wda(timeout_s=12.0)
        if not res.get("ok"):
            raise RuntimeError(res.get("error") or "WDA is unreachable")
        self._active_base_url = str(res["wda_url"]).rstrip("/")
        self._base_url_verified_at = time.monotonic()
        return self._active_base_url

    async def _req(
        self,
        method: str,
        path: str,
        json_body: Optional[dict[str, Any]] = None,
        timeout: float = 8.0,
    ) -> tuple[dict[str, Any], float]:
        base = await self._resolve_base_url()
        t0 = time.perf_counter()
        try:
            resp = await self._client.request(method, f"{base}{path}", json=json_body, timeout=timeout)
        except httpx.TransportError:
            self._active_base_url = None
            self._base_url_verified_at = 0.0
            base = await self._resolve_base_url()
            t0 = time.perf_counter()
            resp = await self._client.request(method, f"{base}{path}", json=json_body, timeout=timeout)
        elapsed_ms = round((time.perf_counter() - t0) * 1000, 1)
        data: dict[str, Any] = resp.json() if resp.content else {}
        if resp.status_code >= 400:
            val = data.get("value")
            err_tag = str(val.get("error") or "").lower() if isinstance(val, dict) else ""
            msg = val.get("message") if isinstance(val, dict) else (val or resp.text)
            msg_low = f"{err_tag} {msg}".lower()
            if resp.status_code in (404, 410) and "/session/" in path and (
                "session does not exist" in msg_low or "invalid session" in msg_low
            ):
                self._session_id = None
            raise RuntimeError(f"WDA HTTP {resp.status_code} on {path}: {msg}")
        return data, elapsed_ms

    async def _apply_fast_settings(self, sid: str) -> None:
        await self._req(
            "POST",
            f"/session/{sid}/appium/settings",
            {
                "settings": {
                    "waitForIdleTimeout": 0,
                    "animationCoolOffTimeout": 0,
                    "waitForQuiescence": False,
                    "shouldUseCompactResponses": True,
                    "snapshotMaxDepth": 25,
                    "elementResponseAttributes": "type,label,name,value,rect,enabled,visible",
                }
            },
            timeout=3.0,
        )

    async def _session_req(
        self,
        method: str,
        subpath: str,
        json_body: Optional[dict[str, Any]] = None,
        timeout: float = 8.0,
    ) -> tuple[dict[str, Any], float]:
        sid = await self.ensure_session()
        try:
            return await self._req(method, f"/session/{sid}{subpath}", json_body, timeout=timeout)
        except RuntimeError as exc:
            low = str(exc).lower()
            if "session does not exist" in low or "invalid session" in low:
                self._session_id = None
                sid = await self.ensure_session(force_new=True)
                return await self._req(method, f"/session/{sid}{subpath}", json_body, timeout=timeout)
            raise

    async def ensure_session(self, bundle_id: Optional[str] = None, force_new: bool = False) -> str:
        if self._session_id and not force_new:
            return self._session_id
        if not force_new and not bundle_id:
            try:
                st_data, _ = await self._req("GET", "/status", timeout=3.0)
                st_val = st_data.get("value")
                cand_sid = st_data.get("sessionId") or (st_val.get("sessionId") if isinstance(st_val, dict) else None)
                if cand_sid:
                    await self._apply_fast_settings(str(cand_sid))
                    self._session_id = str(cand_sid)
                    return self._session_id
            except Exception:
                self._session_id = None
        caps: dict[str, Any] = {}
        if bundle_id:
            caps["bundleId"] = bundle_id
        data, _ = await self._req(
            "POST",
            "/session",
            {"capabilities": {"alwaysMatch": caps}, "desiredCapabilities": caps},
            timeout=10.0,
        )
        sid = data.get("sessionId")
        if not sid and isinstance(data.get("value"), dict):
            sid = data["value"].get("sessionId")
        if not sid:
            raise RuntimeError(f"WDA /session returned no sessionId: {data}")
        self._session_id = str(sid)
        try:
            await self._apply_fast_settings(self._session_id)
        except Exception:
            pass
        return self._session_id

    async def status(self) -> dict[str, Any]:
        data, latency_ms = await self._req("GET", "/status", timeout=3.0)
        return {"ok": True, "base_url": self._active_base_url, "latency_ms": latency_ms, "raw": data}

    async def active_app_info(self) -> dict[str, Any]:
        data, latency_ms = await self._req("GET", "/wda/activeAppInfo", timeout=3.0)
        return {"ok": True, "latency_ms": latency_ms, "app": data.get("value", {})}

    async def window_size(self) -> dict[str, int]:
        if self._window_size:
            return self._window_size
        data, _ = await self._session_req("GET", "/window/size", timeout=4.0)
        val = data.get("value") or {}
        w = int(val.get("width", 744))
        h = int(val.get("height", 1133))
        self._window_size = {"width": w, "height": h}
        return self._window_size

    def _flatten_json_tree(
        self,
        node: dict[str, Any],
        out: list[dict[str, Any]],
        compact: bool,
        max_elements: int,
    ) -> None:
        if len(out) >= max_elements or not isinstance(node, dict):
            return
        raw_type = str(node.get("type") or "")
        short_type = raw_type.removeprefix("XCUIElementType")
        label = str(node.get("label") or "").strip()
        name = str(node.get("name") or "").strip()
        value = str(node.get("value") or "").strip() if node.get("value") is not None else ""
        rect = node.get("rect")
        if isinstance(rect, dict):
            x = int(float(rect.get("x", 0) or 0))
            y = int(float(rect.get("y", 0) or 0))
            w = int(float(rect.get("width", 0) or 0))
            h = int(float(rect.get("height", 0) or 0))
        else:
            m = _FRAME_RE.search(str(node.get("frame") or ""))
            if m:
                x, y, w, h = (int(float(m.group(i))) for i in range(1, 5))
            else:
                x = y = w = h = 0

        raw_enabled = node.get("isEnabled", node.get("enabled", True))
        enabled = str(raw_enabled).strip().lower() not in ("false", "0", "no")
        raw_vis = node.get("isVisible", node.get("visible", True))
        visible = str(raw_vis).strip().lower() not in ("false", "0", "no")

        has_text = bool(label or name or value)
        is_interactive = short_type in _INTERACTIVE_TYPES
        if w > 0 and h > 0 and (not compact or ((has_text or is_interactive) and visible)):
            if short_type not in ("Application", "Window") or has_text:
                out.append(
                    {
                        "index": len(out),
                        "type": short_type,
                        "label": label,
                        "name": name,
                        "value": value,
                        "rect": {"x": x, "y": y, "width": w, "height": h},
                        "center": [x + w // 2, y + h // 2],
                        "enabled": enabled,
                    }
                )

        for child in node.get("children") or []:
            if len(out) >= max_elements:
                break
            self._flatten_json_tree(child, out, compact, max_elements)

    def _flatten_xml_tree(self, xml_text: str, compact: bool, max_elements: int) -> list[dict[str, Any]]:
        root = ET.fromstring(xml_text)
        out: list[dict[str, Any]] = []
        for elem in root.iter():
            if len(out) >= max_elements:
                break
            short_type = elem.tag.removeprefix("XCUIElementType")
            label = (elem.attrib.get("label") or "").strip()
            name = (elem.attrib.get("name") or "").strip()
            value = (elem.attrib.get("value") or "").strip()
            x = int(float(elem.attrib.get("x", "0") or 0))
            y = int(float(elem.attrib.get("y", "0") or 0))
            w = int(float(elem.attrib.get("width", "0") or 0))
            h = int(float(elem.attrib.get("height", "0") or 0))
            enabled = elem.attrib.get("enabled", "true").lower() != "false"
            visible = elem.attrib.get("visible", "true").lower() != "false"
            in_bounds = w > 0 and h > 0 and (x + w) > 0 and (y + h) > 0 and y < 2200
            has_text = bool(label or name or value)
            is_interactive = short_type in _INTERACTIVE_TYPES
            if in_bounds and (not compact or ((has_text or is_interactive) and visible)):
                if short_type not in ("Application", "Window") or has_text:
                    out.append(
                        {
                            "index": len(out),
                            "type": short_type,
                            "label": label,
                            "name": name,
                            "value": value,
                            "rect": {"x": x, "y": y, "width": w, "height": h},
                            "center": [x + w // 2, y + h // 2],
                            "enabled": enabled,
                        }
                    )
        return out

    async def _accessibility_fallback(self, max_elements: int, wda_err: Exception) -> dict[str, Any]:
        ax = await self.core.get_telemetry("accessibility", limit=max_elements)
        if not ax.get("ok"):
            raise RuntimeError(
                f"WDA unavailable ({wda_err}); AccessibilityAudit fallback failed: {ax.get('error') or ax}"
            ) from wda_err
        mapped: list[dict[str, Any]] = []
        for idx, el in enumerate(ax.get("elements") or []):
            label = str(el.get("label") or el.get("caption") or "").strip()
            mapped.append(
                {
                    "index": idx,
                    "type": str(el.get("type") or "AXElement"),
                    "label": label,
                    "name": str(el.get("spoken_description") or label),
                    "value": "",
                    "platform_identifier": str(el.get("platform_identifier") or ""),
                    "enabled": True,
                }
            )
        return {
            "ok": True,
            "source": "dvt_accessibility_audit",
            "wda_fallback_reason": str(wda_err),
            "total_elements": len(mapped),
            "elements": mapped,
        }

    async def fast_ui_dump(self, compact: bool = True, max_elements: int = 100) -> dict[str, Any]:
        try:
            await self._resolve_base_url()
        except Exception as wda_err:
            return await self._accessibility_fallback(max_elements, wda_err)

        try:
            await self.ensure_session()
        except Exception:
            pass

        if self._has_custom_fast_tree is not False:
            found_custom = False
            for ep in ("/grogu/fast_tree", "/aimo/fast_tree"):
                try:
                    data, latency_ms = await self._req("GET", ep, timeout=3.0)
                    val = data.get("value")
                    self._has_custom_fast_tree = True
                    found_custom = True
                    if isinstance(val, list):
                        return {
                            "ok": True,
                            "source": "grogu_fast_tree",
                            "latency_ms": latency_ms,
                            "total_elements": len(val),
                            "elements": val[:max_elements],
                        }
                    if isinstance(val, dict):
                        nodes: list[dict[str, Any]] = []
                        self._flatten_json_tree(val, nodes, compact, max_elements)
                        return {
                            "ok": True,
                            "source": "grogu_fast_tree",
                            "latency_ms": latency_ms,
                            "total_elements": len(nodes),
                            "elements": nodes,
                        }
                except Exception as exc:
                    low = str(exc).lower()
                    if not ("404" in low or "unknown" in low or "unhandled" in low or "does not match" in low):
                        break
            if not found_custom:
                self._has_custom_fast_tree = False

        try:
            data, latency_ms = await self._req("GET", "/source?excluded_attributes=visible,accessible", timeout=18.0)
            xml_str = str(data.get("value") or "")
            if not compact:
                return {"ok": True, "source": "wda_xml_fast", "latency_ms": latency_ms, "xml": xml_str}
            nodes = self._flatten_xml_tree(xml_str, compact=True, max_elements=max_elements)
            return {
                "ok": True,
                "source": "wda_xml_fast",
                "latency_ms": latency_ms,
                "total_elements": len(nodes),
                "elements": nodes,
            }
        except Exception as fast_xml_err:
            last_err: Exception = fast_xml_err

        try:
            data, latency_ms = await self._req("GET", "/source?format=json", timeout=18.0)
            val = data.get("value")
            if isinstance(val, dict):
                nodes = []
                self._flatten_json_tree(val, nodes, compact, max_elements)
                return {
                    "ok": True,
                    "source": "wda_json",
                    "latency_ms": latency_ms,
                    "total_elements": len(nodes),
                    "elements": nodes,
                }
        except Exception as json_err:
            last_err = json_err

        return await self._accessibility_fallback(max_elements, last_err)

    async def tap(self, x: int, y: int) -> dict[str, Any]:
        try:
            _, latency_ms = await self._session_req("POST", "/wda/tap", {"x": int(x), "y": int(y)})
        except RuntimeError as exc:
            low = str(exc).lower()
            if "unhandled" not in low and "unknown command" not in low and "404" not in low:
                raise
            _, latency_ms = await self._session_req(
                "POST",
                "/actions",
                {
                    "actions": [
                        {
                            "type": "pointer",
                            "id": "finger1",
                            "parameters": {"pointerType": "touch"},
                            "actions": [
                                {"type": "pointerMove", "duration": 0, "x": int(x), "y": int(y)},
                                {"type": "pointerDown", "button": 0},
                                {"type": "pause", "duration": 50},
                                {"type": "pointerUp", "button": 0},
                            ],
                        }
                    ]
                },
            )
        return {"ok": True, "x": int(x), "y": int(y), "latency_ms": latency_ms}

    async def double_tap(self, x: int, y: int) -> dict[str, Any]:
        _, latency_ms = await self._session_req("POST", "/wda/doubleTap", {"x": int(x), "y": int(y)})
        return {"ok": True, "x": int(x), "y": int(y), "latency_ms": latency_ms}

    async def long_press(self, x: int, y: int, duration_s: float = 1.0) -> dict[str, Any]:
        _, latency_ms = await self._session_req(
            "POST",
            "/wda/touchAndHold",
            {"x": int(x), "y": int(y), "duration": float(duration_s)},
        )
        return {"ok": True, "x": int(x), "y": int(y), "duration_s": duration_s, "latency_ms": latency_ms}

    async def swipe(self, x1: int, y1: int, x2: int, y2: int, duration_ms: int = 250) -> dict[str, Any]:
        duration_s = max(0.05, duration_ms / 1000.0)
        _, latency_ms = await self._session_req(
            "POST",
            "/wda/dragfromtoforduration",
            {"fromX": int(x1), "fromY": int(y1), "toX": int(x2), "toY": int(y2), "duration": duration_s},
        )
        return {"ok": True, "from": [x1, y1], "to": [x2, y2], "duration_ms": duration_ms, "latency_ms": latency_ms}

    async def type_text(self, text: str) -> dict[str, Any]:
        _, latency_ms = await self._session_req("POST", "/wda/keys", {"value": list(text)}, timeout=12.0)
        return {"ok": True, "text": text, "latency_ms": latency_ms}

    async def press_button(self, name: str) -> dict[str, Any]:
        norm = {
            "home": "home",
            "volume_up": "volumeUp",
            "volumeup": "volumeUp",
            "volume_down": "volumeDown",
            "volumedown": "volumeDown",
        }.get(name.strip().lower(), name)
        if norm == "home":
            try:
                _, latency_ms = await self._req("POST", "/wda/homescreen", {})
                return {"ok": True, "button": "home", "latency_ms": latency_ms}
            except Exception:
                pass
        _, latency_ms = await self._session_req("POST", "/wda/pressButton", {"name": norm})
        return {"ok": True, "button": norm, "latency_ms": latency_ms}

    async def launch_app(self, bundle_id: str) -> dict[str, Any]:
        _, latency_ms = await self._session_req("POST", "/wda/apps/launch", {"bundleId": bundle_id}, timeout=10.0)
        return {"ok": True, "bundle_id": bundle_id, "latency_ms": latency_ms}

    async def terminate_app(self, bundle_id: str) -> dict[str, Any]:
        _, latency_ms = await self._session_req("POST", "/wda/apps/terminate", {"bundleId": bundle_id})
        return {"ok": True, "bundle_id": bundle_id, "latency_ms": latency_ms}

    async def open_url(self, url: str) -> dict[str, Any]:
        _, latency_ms = await self._session_req("POST", "/url", {"url": url}, timeout=10.0)
        return {"ok": True, "url": url, "latency_ms": latency_ms}

    async def screenshot(self, out_path: str | Path) -> dict[str, Any]:
        data, latency_ms = await self._req("GET", "/screenshot", timeout=10.0)
        b64 = data.get("value")
        if not isinstance(b64, str):
            raise RuntimeError("WDA /screenshot did not return base64 string")
        raw = base64.b64decode(b64)
        p = Path(out_path)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(raw)
        return {"ok": True, "local_path": str(p), "size_bytes": len(raw), "latency_ms": latency_ms}

    async def on_device_reflex(self, rule_dict: dict[str, Any]) -> dict[str, Any]:
        for ep in ("/grogu/reflex", "/aimo/reflex"):
            try:
                data, latency_ms = await self._req("POST", ep, rule_dict, timeout=8.0)
                return {"ok": True, "mode": "on_device_reflex", "latency_ms": latency_ms, "result": data.get("value", data)}
            except Exception:
                continue

        match_text = str(rule_dict.get("match") or "").strip()
        timeout_ms = int(rule_dict.get("timeout_ms", 1500))
        poll_ms = max(40, int(rule_dict.get("poll_ms", 100)))
        t0 = time.perf_counter()
        deadline = t0 + timeout_ms / 1000.0
        while time.perf_counter() < deadline:
            dump = await self.fast_ui_dump(compact=True, max_elements=120)
            for el in dump.get("elements") or []:
                hay = f"{el.get('label', '')} {el.get('name', '')} {el.get('value', '')}".lower()
                if match_text and match_text.lower() in hay:
                    cx, cy = el["center"]
                    tap_res = await self.tap(cx, cy)
                    return {
                        "ok": True,
                        "mode": "host_fast_reflex",
                        "matched": el,
                        "tap": tap_res,
                        "latency_ms": round((time.perf_counter() - t0) * 1000, 1),
                    }
            await asyncio.sleep(poll_ms / 1000.0)
        return {"ok": False, "mode": "host_fast_reflex", "error": f"No element matched {match_text!r} within {timeout_ms}ms"}
