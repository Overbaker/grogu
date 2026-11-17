"""Deterministic Decision API executor, URL-scheme resolver, and Siri non-blocking router."""

from __future__ import annotations

import asyncio
from datetime import datetime, timezone
import json
import os
import re
import time
from typing import Any, Optional

import httpx

from grogu.config import OUTPUT_DIR, STATE_DIR
from grogu.core import GroguCoreManager
from grogu.wda_client import FastWDAClient

SIRI_LOG_FILE = OUTPUT_DIR / "siri_tasks.jsonl"

APP_ALIASES: dict[str, str] = {
    "settings": "com.apple.Preferences",
    "设置": "com.apple.Preferences",
    "系统设置": "com.apple.Preferences",
    "safari": "com.apple.mobilesafari",
    "浏览器": "com.apple.mobilesafari",
    "shortcuts": "com.apple.shortcuts",
    "快捷指令": "com.apple.shortcuts",
    "notes": "com.apple.mobilenotes",
    "备忘录": "com.apple.mobilenotes",
    "files": "com.apple.DocumentsApp",
    "文件": "com.apple.DocumentsApp",
    "appstore": "com.apple.AppStore",
    "app store": "com.apple.AppStore",
    "商店": "com.apple.AppStore",
    "camera": "com.apple.camera",
    "相机": "com.apple.camera",
    "photos": "com.apple.mobileslideshow",
    "相册": "com.apple.mobileslideshow",
    "照片": "com.apple.mobileslideshow",
    "wechat": "com.tencent.xin",
    "微信": "com.tencent.xin",
    "alipay": "com.alipay.iphoneclient",
    "支付宝": "com.alipay.iphoneclient",
    "youtube": "com.google.ios.youtube",
    "tailscale": "io.tailscale.ipn.ios",
    "bilibili": "tv.danmaku.bilianime",
    "b站": "tv.danmaku.bilianime",
    "chrome": "com.google.chrome.ios",
    "chatgpt": "com.openai.chat",
    "claude": "com.anthropic.claude",
}


class DecisionEngine:
    """Fast deterministic Decision API + Siri voice router + optional async LLM planner."""

    def __init__(self, core: Optional[GroguCoreManager] = None, wda: Optional[FastWDAClient] = None) -> None:
        self.core = core or GroguCoreManager()
        self.wda = wda or FastWDAClient(core=self.core)

    def resolve_target(self, app_or_url: str) -> tuple[str, str]:
        raw = app_or_url.strip()
        low = raw.lower()
        if "://" in raw or low.startswith("prefs:") or low.startswith("mailto:") or low.startswith("tel:"):
            return "url", raw
        if low in APP_ALIASES:
            return "bundle", APP_ALIASES[low]

        cache_file = STATE_DIR / "schemes_cache.json"
        if cache_file.exists():
            try:
                apps = json.loads(cache_file.read_text(encoding="utf-8"))
                for item in apps:
                    name_l = str(item.get("name", "")).lower()
                    bid = str(item.get("bundle_id", ""))
                    if low == bid.lower() or low == name_l or low in name_l:
                        return "bundle", bid
            except Exception:
                pass
        return "bundle", raw

    def _match_element(self, elements: list[dict[str, Any]], step: dict[str, Any]) -> Optional[dict[str, Any]]:
        query = str(step.get("text") or step.get("label") or "").strip()
        el_type = str(step.get("type") or "").strip().lower()
        regex = str(step.get("regex") or "").strip()
        exact = bool(step.get("exact", False))
        idx = int(step.get("index", 0))

        rx = re.compile(regex, re.IGNORECASE) if regex else None
        matches: list[dict[str, Any]] = []
        for el in elements:
            if el_type and el.get("type", "").lower() != el_type:
                continue
            label = str(el.get("label") or "")
            name = str(el.get("name") or "")
            value = str(el.get("value") or "")
            if rx is not None:
                if rx.search(label) or rx.search(name) or rx.search(value):
                    matches.append(el)
            elif query:
                ql = query.lower()
                if exact:
                    if ql in (label.lower(), name.lower(), value.lower()):
                        matches.append(el)
                elif ql in label.lower() or ql in name.lower() or ql in value.lower():
                    matches.append(el)
            elif el_type:
                matches.append(el)

        if 0 <= idx < len(matches):
            return matches[idx]
        return None

    def _resolve_scheme_bundle(self, url: str) -> Optional[str]:
        scheme = url.split(":", 1)[0].strip().lower() if ":" in url else ""
        if not scheme:
            return None
        builtin = {
            "http": "com.apple.mobilesafari",
            "https": "com.apple.mobilesafari",
            "prefs": "com.apple.Preferences",
            "app-prefs": "com.apple.Preferences",
            "shortcuts": "com.apple.shortcuts",
            "mobilenotes": "com.apple.mobilenotes",
        }
        if scheme in builtin:
            return builtin[scheme]
        cache_file = STATE_DIR / "schemes_cache.json"
        if cache_file.exists():
            try:
                apps = json.loads(cache_file.read_text(encoding="utf-8"))
                for item in apps:
                    schemes = [str(s).lower() for s in (item.get("schemes") or [])]
                    if scheme in schemes and item.get("bundle_id"):
                        return str(item["bundle_id"])
            except Exception:
                pass
        return None

    async def _open_url_with_fallback(self, url: str) -> dict[str, Any]:
        try:
            return await self.wda.open_url(url)
        except Exception as wda_err:
            matched_bid = self._resolve_scheme_bundle(url)
            if not matched_bid:
                raise wda_err
            res = await self.core.get_telemetry("dvt_launch", filter_text=matched_bid)
            if not res.get("ok"):
                raise RuntimeError(f"WDA offline ({wda_err}); dvt_launch fallback failed: {res.get('error')}") from wda_err
            return {
                "ok": True,
                "mode": "dvt_scheme_app_launch",
                "bundle_id": matched_bid,
                "url": url,
                "pid": res.get("pid"),
            }

    async def execute_steps(self, steps: list[dict[str, Any]]) -> dict[str, Any]:
        t_start = time.perf_counter()
        step_results: list[dict[str, Any]] = []

        for idx, step in enumerate(steps):
            op = str(step.get("op") or step.get("action") or "").strip().lower()
            s_t0 = time.perf_counter()
            try:
                if op == "launch":
                    target = str(step.get("app") or step.get("bundle_id") or "")
                    kind, resolved = self.resolve_target(target)
                    if kind == "url":
                        res = await self._open_url_with_fallback(resolved)
                    else:
                        try:
                            res = await self.wda.launch_app(resolved)
                        except Exception:
                            res = await self.core.get_telemetry("dvt_launch", filter_text=resolved)
                            if not res.get("ok"):
                                raise RuntimeError(res.get("error") or f"dvt_launch failed for {resolved}")
                elif op == "open_url":
                    res = await self._open_url_with_fallback(str(step["url"]))
                elif op == "tap":
                    res = await self.wda.tap(int(step["x"]), int(step["y"]))
                elif op == "tap_selector":
                    dump = await self.wda.fast_ui_dump(compact=True, max_elements=150)
                    hit = self._match_element(dump.get("elements") or [], step)
                    if hit is None:
                        raise RuntimeError(f"Element not found for selector: {step}")
                    cx, cy = hit["center"]
                    tap_res = await self.wda.tap(cx, cy)
                    res = {"ok": True, "matched": hit, "tap": tap_res}
                elif op == "wait_selector":
                    timeout_ms = int(step.get("timeout_ms", 3000))
                    poll_ms = max(50, int(step.get("poll_ms", 120)))
                    deadline = time.perf_counter() + timeout_ms / 1000.0
                    hit = None
                    while time.perf_counter() < deadline:
                        dump = await self.wda.fast_ui_dump(compact=True, max_elements=150)
                        hit = self._match_element(dump.get("elements") or [], step)
                        if hit is not None:
                            break
                        await asyncio.sleep(poll_ms / 1000.0)
                    if hit is None:
                        raise RuntimeError(f"Timed out waiting {timeout_ms}ms for selector: {step}")
                    res = {"ok": True, "matched": hit}
                elif op == "swipe":
                    if "direction" in step:
                        sz = await self.wda.window_size()
                        w, h = sz["width"], sz["height"]
                        d = str(step["direction"]).lower()
                        coords = {
                            "up": (w // 2, int(h * 0.75), w // 2, int(h * 0.25)),
                            "down": (w // 2, int(h * 0.28), w // 2, int(h * 0.78)),
                            "left": (int(w * 0.82), h // 2, int(w * 0.18), h // 2),
                            "right": (int(w * 0.18), h // 2, int(w * 0.82), h // 2),
                        }
                        if d not in coords:
                            raise ValueError(f"Unsupported swipe direction: {d}")
                        x1, y1, x2, y2 = coords[d]
                    else:
                        x1, y1, x2, y2 = int(step["x1"]), int(step["y1"]), int(step["x2"]), int(step["y2"])
                    res = await self.wda.swipe(x1, y1, x2, y2, int(step.get("duration_ms", 250)))
                elif op == "type":
                    txt = str(step.get("text") or "")
                    if step.get("submit"):
                        txt += "\n"
                    res = await self.wda.type_text(txt)
                elif op == "button":
                    res = await self.wda.press_button(str(step.get("name") or "home"))
                elif op == "sleep":
                    ms = max(0, int(step.get("ms", 200)))
                    await asyncio.sleep(ms / 1000.0)
                    res = {"ok": True, "slept_ms": ms}
                elif op == "reflex":
                    res = await self.wda.on_device_reflex(step)
                else:
                    raise ValueError(f"Unsupported Decision API op: {op!r}")

                step_results.append(
                    {
                        "step": idx,
                        "op": op,
                        "ok": bool(res.get("ok", True)),
                        "latency_ms": round((time.perf_counter() - s_t0) * 1000, 1),
                        "result": res,
                    }
                )
            except Exception as exc:
                step_results.append(
                    {
                        "step": idx,
                        "op": op,
                        "ok": False,
                        "latency_ms": round((time.perf_counter() - s_t0) * 1000, 1),
                        "error": str(exc),
                    }
                )
                return {
                    "ok": False,
                    "failed_step": idx,
                    "total_latency_ms": round((time.perf_counter() - t_start) * 1000, 1),
                    "step_results": step_results,
                }

        return {
            "ok": True,
            "total_latency_ms": round((time.perf_counter() - t_start) * 1000, 1),
            "step_results": step_results,
        }

    def log_siri_task(self, entry: dict[str, Any]) -> None:
        SIRI_LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with SIRI_LOG_FILE.open("a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")

    def read_siri_tasks(self, limit: int = 20) -> list[dict[str, Any]]:
        if not SIRI_LOG_FILE.exists():
            return []
        lines = SIRI_LOG_FILE.read_text(encoding="utf-8").splitlines()
        out: list[dict[str, Any]] = []
        for ln in lines[-limit:]:
            try:
                out.append(json.loads(ln))
            except Exception:
                continue
        return list(reversed(out))

    async def _query_status_speech(self) -> str:
        ports = self.core.probe_ports()
        pairing = self.core.get_pairing_status()
        if not pairing["paired"]:
            return "设备尚未完成配对密钥上传，请在 Mac 端执行一次配对引导脚本。"
        parts: list[str] = ["设备在线且已配对"]
        fg_reported = False
        if ports["wda_direct_8100"] or ports["wda_forward_18832"]:
            try:
                app = await self.wda.active_app_info()
                bid = app.get("app", {}).get("bundleId") or "桌面"
                parts.append(f"WDA 已就绪，当前前台应用是 {bid}")
                fg_reported = True
            except Exception:
                parts.append("WDA 端口连通")
        if not fg_reported:
            try:
                proc_res = await self.core.get_telemetry("processes", limit=15)
                if proc_res.get("ok"):
                    fg = next((p for p in (proc_res.get("processes") or []) if p.get("foreground")), None)
                    if fg:
                        fg_name = fg.get("name") or fg.get("bundle_id") or "未知应用"
                        parts.append(f"RSD 原生通道已就绪，当前前台应用是 {fg_name}")
                    else:
                        parts.append("RSD 原生通道已就绪，当前处于桌面或锁屏")
                else:
                    parts.append("WDA 服务尚未拉起")
            except Exception:
                parts.append("WDA 服务尚未拉起")

        try:
            io = await self.core.get_telemetry("ioregistry")
            batt = io.get("battery") or {}
            cap = batt.get("CurrentCapacity")
            charging = batt.get("IsCharging")
            if cap is not None:
                parts.append(f"当前电量百分之{cap}" + ("，正在充电" if charging else ""))
        except Exception:
            pass
        return "，".join(parts) + "。"

    async def _query_screen_speech(self) -> str:
        try:
            dump = await self.wda.fast_ui_dump(compact=True, max_elements=15)
            texts = [
                el.get("label") or el.get("name") or el.get("value")
                for el in (dump.get("elements") or [])
                if (el.get("label") or el.get("name") or el.get("value"))
            ]
            uniq: list[str] = []
            for t in texts:
                s = str(t).strip()
                if s and s not in uniq:
                    uniq.append(s)
                if len(uniq) >= 8:
                    break
            if uniq:
                return f"当前屏幕主要内容有：{ '、'.join(uniq) }。"
            return "屏幕已读取，但未识别到可读文字控件。"
        except Exception as exc:
            return f"暂无法读取屏幕内容：{exc}"

    def route_voice_command(self, text: str) -> tuple[str, Any, str]:
        t = text.strip()
        tl = t.lower()

        if any(k in tl for k in ("电量", "状态", "连接", "status", "battery", "在线")):
            return ("sync_query", self._query_status_speech, "")
        if any(k in tl for k in ("屏幕上有什么", "读一下屏幕", "读屏幕", "当前界面", "看下屏幕", "屏幕内容", "what's on screen")):
            return ("sync_query", self._query_screen_speech, "")

        if any(k in tl for k in ("回桌面", "回到桌面", "回主屏幕", "主屏幕", "home screen", "go home")):
            return ("fast_decision", [{"op": "button", "name": "home"}], "好的，正在回到主屏幕。")
        if any(k in tl for k in ("往下滑", "向下滑", "下一页", "下翻", "scroll down")):
            return ("fast_decision", [{"op": "swipe", "direction": "up"}], "好的，向下滚动。")
        if any(k in tl for k in ("往上滑", "向上滑", "上一页", "上翻", "scroll up")):
            return ("fast_decision", [{"op": "swipe", "direction": "down"}], "好的，向上滚动。")
        if any(k in tl for k in ("往左滑", "向左滑", "右翻", "swipe left")):
            return ("fast_decision", [{"op": "swipe", "direction": "left"}], "好的，向左滑动。")
        if any(k in tl for k in ("往右滑", "向右滑", "左翻", "返回上一级", "swipe right")):
            return ("fast_decision", [{"op": "swipe", "direction": "right"}], "好的，向右滑动。")

        m_url = re.match(r"^(?:打开网址|访问|打开网页|open\s+url)\s+(.+)$", t, re.IGNORECASE)
        if m_url:
            raw_url = m_url.group(1).strip()
            if "://" not in raw_url:
                raw_url = f"https://{raw_url}"
            return ("fast_decision", [{"op": "open_url", "url": raw_url}], "好的，正在打开网页。")

        m_open = re.match(r"^(?:打开|启动|切到|切换到|launch|open)\s*(.+)$", t, re.IGNORECASE)
        if m_open and len(m_open.group(1).strip()) <= 24:
            target = m_open.group(1).strip().rstrip("。！.!")
            return ("fast_decision", [{"op": "launch", "app": target}], f"好的，正在打开 {target}。")

        m_tap = re.match(r"^(?:点击|点一下|按下|点|tap|click)\s*(.+)$", t, re.IGNORECASE)
        if m_tap and len(m_tap.group(1).strip()) <= 24:
            target = m_tap.group(1).strip().rstrip("。！.!")
            return ("fast_decision", [{"op": "tap_selector", "text": target}], f"好的，正在点击 {target}。")

        m_type = re.match(r"^(?:输入|打字|填写|搜索|search|type)\s*(.+)$", t, re.IGNORECASE)
        if m_type:
            val = m_type.group(1).strip()
            submit = t.startswith("搜索") or tl.startswith("search")
            return ("fast_decision", [{"op": "type", "text": val, "submit": submit}], "好的，正在输入内容。")

        return ("async_llm", t, f"收到，正在为你执行：{t}。")

    async def run_async_voice_task(self, task_id: str, mode: str, payload: Any, original_text: str) -> None:
        # Allow Siri overlay orb to dismiss before dispatching UI actions
        await asyncio.sleep(0.45)
        t0 = time.perf_counter()
        if mode == "fast_decision":
            res = await self.execute_steps(payload)
            self.log_siri_task(
                {
                    "task_id": task_id,
                    "ts": datetime.now(timezone.utc).isoformat(),
                    "text": original_text,
                    "mode": "fast_decision",
                    "ok": res.get("ok"),
                    "latency_ms": res.get("total_latency_ms"),
                    "result": res,
                }
            )
            return

        llm_base = os.environ.get("GROGU_LLM_BASE_URL", "").strip()
        llm_key = os.environ.get("GROGU_LLM_API_KEY", "").strip()
        llm_model = os.environ.get("GROGU_LLM_MODEL", "gpt-4o-mini").strip()

        if llm_base and llm_key:
            try:
                res = await self._run_lm_loop(original_text, llm_base, llm_key, llm_model)
                self.log_siri_task(
                    {
                        "task_id": task_id,
                        "ts": datetime.now(timezone.utc).isoformat(),
                        "text": original_text,
                        "mode": "async_llm",
                        "ok": res.get("ok"),
                        "latency_ms": round((time.perf_counter() - t0) * 1000, 1),
                        "result": res,
                    }
                )
                return
            except Exception as exc:
                self.log_siri_task(
                    {
                        "task_id": task_id,
                        "ts": datetime.now(timezone.utc).isoformat(),
                        "text": original_text,
                        "mode": "async_llm",
                        "ok": False,
                        "error": str(exc),
                    }
                )
                return

        snapshot: Optional[dict[str, Any]] = None
        try:
            snapshot = await self.wda.fast_ui_dump(compact=True, max_elements=50)
        except Exception as exc:
            snapshot = {"ok": False, "error": str(exc)}
        self.log_siri_task(
            {
                "task_id": task_id,
                "ts": datetime.now(timezone.utc).isoformat(),
                "text": original_text,
                "mode": "queued_for_lm",
                "ok": True,
                "note": "No GROGU_LLM_BASE_URL set; captured UI context and queued for MCP agent.",
                "snapshot": snapshot,
            }
        )

    async def _run_lm_loop(self, goal: str, base_url: str, api_key: str, model: str, max_steps: int = 8) -> dict[str, Any]:
        trace: list[dict[str, Any]] = []
        async with httpx.AsyncClient(timeout=20.0) as client:
            for step_idx in range(max_steps):
                dump = await self.wda.fast_ui_dump(compact=True, max_elements=80)
                sys_prompt = (
                    "You control an iOS/iPadOS device via Grogu JSON Decision API. Given the goal and compact UI elements, "
                    "output ONLY JSON: {\"done\": bool, \"reason\": str, \"steps\": [{\"op\": ...}]}. "
                    "Allowed ops: launch(app), open_url(url), tap(x,y), tap_selector(text), swipe(direction), type(text,submit), button(name)."
                )
                resp = await client.post(
                    f"{base_url.rstrip('/')}/chat/completions",
                    headers={"Authorization": f"Bearer {api_key}"},
                    json={
                        "model": model,
                        "response_format": {"type": "json_object"},
                        "messages": [
                            {"role": "system", "content": sys_prompt},
                            {
                                "role": "user",
                                "content": json.dumps({"goal": goal, "step": step_idx, "ui": dump}, ensure_ascii=False),
                            },
                        ],
                    },
                )
                resp.raise_for_status()
                plan = json.loads(resp.json()["choices"][0]["message"]["content"])
                steps = plan.get("steps") or []
                exec_res = await self.execute_steps(steps) if steps else {"ok": True, "step_results": []}
                trace.append({"step": step_idx, "plan": plan, "exec": exec_res})
                if plan.get("done"):
                    return {"ok": True, "trace": trace}
        return {"ok": False, "error": "Max LLM steps reached", "trace": trace}
