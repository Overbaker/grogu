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

from grogu.config import BIND_HOST, GATEWAY_PORT, OUTPUT_DIR, STATE_DIR
from grogu.core import GroguCoreManager
from grogu.pi_agent import PiRpcAgent
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
    """Fast deterministic Decision API + Siri voice router + Gemini Decision-1 & fast MoE planner."""

    def __init__(self, core: Optional[GroguCoreManager] = None, wda: Optional[FastWDAClient] = None) -> None:
        self.core = core or GroguCoreManager()
        self.wda = wda or FastWDAClient(core=self.core)
        self._http = httpx.AsyncClient(timeout=20.0)
        self._background_tasks: set[asyncio.Task[Any]] = set()
        self.default_agent: str = (os.environ.get("GROGU_DEFAULT_AGENT") or "auto").strip().lower()
        self.pi_agent = PiRpcAgent(gateway_url=f"http://{BIND_HOST}:{GATEWAY_PORT}")

    async def aclose(self) -> None:
        for task in list(self._background_tasks):
            task.cancel()
        await self.pi_agent.aclose()
        await self._http.aclose()

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
            op = str(step.get("op") or step.get("action") or "").strip().lower().split("(", 1)[0].strip()
            s_t0 = time.perf_counter()
            try:
                if op == "launch":
                    target = str(
                        step.get("app") or step.get("bundle_id") or step.get("text") or step.get("name") or ""
                    )
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
                elif op == "ai_tap":
                    goal = str(step.get("goal") or step.get("text") or "").strip()
                    if not goal:
                        raise ValueError("ai_tap step requires 'goal' or 'text'")
                    res = await self.run_ai_goal(goal, max_steps=1, prefer=str(step.get("prefer") or "auto"))
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

    def _get_openrouter_config(self) -> tuple[str, str, str]:
        api_key = (
            os.environ.get("OPENROUTER_API_KEY")
            or os.environ.get("GROGU_DECISION_API_KEY")
            or ""
        ).strip()
        url = (
            os.environ.get("OPENROUTER_DECISIONS_URL")
            or os.environ.get("GROGU_DECISIONS_URL")
            or "https://openrouter.ai/api/alpha/decisions"
        ).strip()
        model = (
            os.environ.get("GROGU_DECISION_MODEL")
            or os.environ.get("OPENROUTER_DECISION_MODEL")
            or "google/gemini-decision-1"
        ).strip()
        return api_key, url, model

    def _get_llm_config(self) -> tuple[str, str, str, bool]:
        base = os.environ.get("GROGU_LLM_BASE_URL", "").strip()
        key = os.environ.get("GROGU_LLM_API_KEY", "").strip()
        model = os.environ.get("GROGU_LLM_MODEL", "gpt-4o-mini").strip()
        disable_thinking = os.environ.get("GROGU_LLM_DISABLE_THINKING", "true").strip().lower() not in (
            "false",
            "0",
            "no",
        )
        return base, key, model, disable_thinking

    def get_ai_engine_status(self) -> dict[str, Any]:
        or_key, _, or_model = self._get_openrouter_config()
        llm_base, llm_key, llm_model, disable_thinking = self._get_llm_config()
        return {
            "default_agent": self.default_agent,
            "available_agents": ["auto", "fast-llm", "pi", "decision-1"],
            "decision_1_configured": bool(or_key),
            "decision_1_model": or_model,
            "fast_llm_configured": bool(llm_base and llm_key),
            "fast_llm_model": llm_model if (llm_base and llm_key) else "",
            "disable_thinking": disable_thinking,
            "pi_agent": self.pi_agent.get_status(),
        }

    async def set_ai_config(
        self,
        *,
        default_agent: Optional[str] = None,
        pi_provider: Optional[str] = None,
        pi_model: Optional[str] = None,
        pi_thinking: Optional[str] = None,
    ) -> dict[str, Any]:
        if default_agent is not None:
            norm = default_agent.strip().lower()
            if norm not in ("auto", "fast-llm", "llm", "pi", "decision-1"):
                raise ValueError(f"Unsupported agent: {default_agent!r}")
            self.default_agent = "fast-llm" if norm == "llm" else norm
        if pi_provider is not None or pi_model is not None or pi_thinking is not None:
            await self.pi_agent.reconfigure(
                provider=pi_provider,
                model=pi_model,
                thinking=pi_thinking,
            )
        return self.get_ai_engine_status()

    async def plan_step_auto(
        self,
        goal: str,
        elements: list[dict[str, Any]],
        history: list[str],
        prefer: str = "auto",
        *,
        base_url: Optional[str] = None,
        api_key: Optional[str] = None,
        model: Optional[str] = None,
    ) -> dict[str, Any]:
        or_key, _, _ = self._get_openrouter_config()
        mode = (prefer or "auto").strip().lower()
        if mode == "auto" and self.default_agent != "auto":
            mode = self.default_agent
        if mode in ("auto", "decision-1") and or_key and not base_url:
            try:
                plan = await self.decide_with_openrouter(goal, elements, history)
                if plan is not None:
                    return plan
            except Exception:
                pass
        return await self.plan_step_with_fast_llm(
            goal,
            elements,
            history,
            base_url=base_url,
            api_key=api_key,
            model=model,
        )

    @staticmethod
    def _parse_json_object(raw_text: str) -> dict[str, Any]:
        cleaned = raw_text.strip()
        if cleaned.startswith("```"):
            cleaned = re.sub(r"^```(?:json)?\s*|\s*```$", "", cleaned, flags=re.IGNORECASE | re.DOTALL).strip()
        try:
            parsed = json.loads(cleaned)
            if isinstance(parsed, dict):
                return parsed
        except Exception:
            pass
        start = cleaned.find("{")
        end = cleaned.rfind("}")
        if start != -1 and end > start:
            parsed = json.loads(cleaned[start : end + 1])
            if isinstance(parsed, dict):
                return parsed
        raise ValueError(f"Model did not return a JSON object: {raw_text[:200]!r}")

    async def decide_with_openrouter(
        self, goal: str, elements: list[dict[str, Any]], history: list[str]
    ) -> Optional[dict[str, Any]]:
        api_key, url, model = self._get_openrouter_config()
        if not api_key:
            return None

        criteria: dict[str, str] = {}
        el_by_key: dict[str, dict[str, Any]] = {}
        for pos, el in enumerate(elements):
            if len(criteria) >= 240:
                break
            idx = int(el.get("index", pos))
            el_type = str(el.get("type") or "AXElement")
            label = str(el.get("label") or "").strip()
            name = str(el.get("name") or "").strip()
            val = str(el.get("value") or "").strip()
            if not (label or name or val):
                continue
            key = f"el_{idx}"
            center = el.get("center")
            coord_txt = f" @{center}" if center else ""
            criteria[key] = f"[{el_type}] label={label!r} name={name!r} val={val!r}{coord_txt}"
            el_by_key[key] = el

        criteria["act_scroll_down"] = "Scroll down to reveal more content below"
        criteria["act_scroll_up"] = "Scroll up to reveal content above"
        criteria["act_navigate_back"] = "Swipe right / go back to previous screen"
        criteria["act_go_home"] = "Press Home button to return to home screen"
        criteria["act_need_text_or_launch"] = "Requires typing text into a field or launching a different app by name"

        payload = {
            "model": model,
            "state": {"goal": goal, "step_history": history[-6:]},
            "questions": {
                "goal_complete": {
                    "type": "noul",
                    "instructions": (
                        "Has the user's goal ALREADY been completely satisfied on the current screen "
                        "(after taking the steps in step_history)?"
                    ),
                    "criteria": {
                        "true": "The requested target screen or setting state is already achieved.",
                        "false": "At least one more action is still required.",
                    },
                },
                "next_action": {
                    "type": "choice",
                    "instructions": f"Goal: {goal}. Select the single best UI element to tap or navigation action to perform next.",
                    "criteria": criteria,
                },
                "is_final_action": {
                    "type": "noul",
                    "instructions": "Determine whether executing next_action will completely fulfill the user's goal with no further clicks, typing, or navigation needed afterwards.",
                    "criteria": {
                        "true": "Clicking the selected target element directly reaches the requested page or final state.",
                        "false": "More steps are still required after executing next_action.",
                    },
                },
            },
        }
        resp = await self._http.post(
            url,
            headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
            json=payload,
            timeout=15.0,
        )
        resp.raise_for_status()
        data = resp.json()
        answers = data.get("answers") or {}

        gc = answers.get("goal_complete") or {}
        noul_prob = float(gc.get("noul") or 0.0)
        if history and noul_prob >= 0.82:
            return {
                "done": True,
                "reason": "goal_complete satisfied via single-pass check",
                "engine": model,
                "confidence": gc.get("confidence"),
                "noul": noul_prob,
                "steps": [],
            }

        na = answers.get("next_action") or {}
        choice = str(na.get("choice") or "").strip()
        probs = na.get("probabilities") or {}
        if not choice or choice == "act_need_text_or_launch":
            return None

        if choice.startswith("el_") and choice in el_by_key:
            matched = el_by_key[choice]
            center = matched.get("center")
            if isinstance(center, list) and len(center) == 2:
                step = {"op": "tap", "x": int(center[0]), "y": int(center[1])}
            else:
                step = {"op": "tap_selector", "text": str(matched.get("label") or matched.get("name") or "")}
            fa = answers.get("is_final_action") or {}
            final_prob = float(fa.get("noul") or 0.0)
            return {
                "done": final_prob >= 0.80,
                "reason": f"Selected {choice}",
                "engine": model,
                "choice": choice,
                "confidence": na.get("confidence"),
                "probability": probs.get(choice),
                "final_noul": final_prob,
                "matched": matched,
                "steps": [step],
            }

        synthetic_map = {
            "act_scroll_down": [{"op": "swipe", "direction": "up"}],
            "act_scroll_up": [{"op": "swipe", "direction": "down"}],
            "act_navigate_back": [{"op": "swipe", "direction": "right"}],
            "act_go_home": [{"op": "button", "name": "home"}],
        }
        if choice in synthetic_map:
            return {
                "done": False,
                "reason": f"Selected {choice}",
                "engine": model,
                "choice": choice,
                "confidence": na.get("confidence"),
                "probability": probs.get(choice),
                "steps": synthetic_map[choice],
            }
        return None

    async def plan_step_with_fast_llm(
        self,
        goal: str,
        elements: list[dict[str, Any]],
        history: list[str],
        *,
        base_url: Optional[str] = None,
        api_key: Optional[str] = None,
        model: Optional[str] = None,
    ) -> dict[str, Any]:
        cfg_base, cfg_key, cfg_model, disable_thinking = self._get_llm_config()
        use_base = (base_url or cfg_base).strip()
        use_key = (api_key or cfg_key).strip()
        use_model = (model or cfg_model).strip()
        if not use_base or not use_key:
            raise RuntimeError("No LLM endpoint/key configured (set GROGU_LLM_BASE_URL & GROGU_LLM_API_KEY)")

        fg_app = ""
        compact_ui: list[dict[str, Any]] = []
        el_by_index: dict[int, dict[str, Any]] = {}
        for pos, el in enumerate(elements):
            idx = int(el.get("index", pos))
            el_by_index[idx] = el
            lbl = str(el.get("label") or "").strip()
            name = str(el.get("name") or "").strip()
            val = str(el.get("value") or "").strip()
            el_type = str(el.get("type") or "")
            if el_type == "Application" and (lbl or name):
                fg_app = lbl or name
            if el_type in ("Application", "Window"):
                continue
            if not (lbl or name or val) and el_type in ("Cell", "Other", "CollectionView"):
                continue
            item: dict[str, Any] = {"i": idx, "t": el_type}
            if lbl:
                item["l"] = lbl[:80]
            if name and name != lbl:
                item["n"] = name[:60]
            if val and val != lbl:
                item["v"] = val[:40]
            if el.get("center"):
                item["c"] = el["center"]
            compact_ui.append(item)
            if len(compact_ui) >= 160:
                break

        sys_prompt = (
            "You control an iOS/iPadOS device via Grogu JSON Decision API. Given goal, compact indexed UI elements "
            "(i=index, t=type, l=label, n=name, v=value, c=[x,y]), and history, output ONLY raw JSON: "
            "{\"done\": bool, \"reason\": str, \"tap_index\": int|null, \"steps\": [{\"op\": ...}]}. "
            "Set tap_index (preferred for clicking a listed element) OR steps using valid JSON step objects: "
            '{"op":"launch","app":"settings"}, {"op":"open_url","url":"..."}, {"op":"tap","x":150,"y":600}, '
            '{"op":"tap_selector","text":"..."}, {"op":"swipe","direction":"up|down|left|right"}, '
            '{"op":"type","text":"...","submit":true}, {"op":"button","name":"home"}. '
            "Never put parentheses in 'op'. Note: to scroll down the list/page use {\"op\":\"swipe\",\"direction\":\"up\"}. "
            "On split-view apps (e.g. iPad Settings), left sidebar items (x<300) remain directly tappable — tap the target sidebar Button directly instead of NavigationBar headers. "
            "If visible UI already satisfies the goal with no action needed, set done=true, tap_index=null, steps=[]. "
            "If tapping tap_index (or executing steps) is the FINAL action needed to fulfill the goal (e.g. clicking the target visible button/menu/tab directly), set BOTH tap_index (or steps) AND done=true so execution finishes in 1 step; set done=false ONLY when further steps are still needed afterwards (e.g. launching an app before navigating inside it, or scrolling to find an off-screen item)."
        )
        req_body: dict[str, Any] = {
            "model": use_model,
            "temperature": 0,
            "max_tokens": 180,
            "messages": [
                {"role": "system", "content": sys_prompt},
                {
                    "role": "user",
                    "content": json.dumps(
                        {"goal": goal, "foreground_app": fg_app, "history": history[-6:], "ui": compact_ui},
                        ensure_ascii=False,
                    ),
                },
            ],
        }
        if disable_thinking:
            req_body["chat_template_kwargs"] = {"enable_thinking": False}

        headers = {"Authorization": f"Bearer {use_key}", "Content-Type": "application/json"}
        endpoint = f"{use_base.rstrip('/')}/chat/completions"
        resp = await self._http.post(endpoint, headers=headers, json=req_body, timeout=20.0)
        if resp.status_code == 400 and "chat_template_kwargs" in req_body:
            req_body.pop("chat_template_kwargs", None)
            resp = await self._http.post(endpoint, headers=headers, json=req_body, timeout=20.0)
        resp.raise_for_status()

        raw_content = resp.json()["choices"][0]["message"].get("content") or ""
        plan = self._parse_json_object(raw_content)
        steps = list(plan.get("steps") or [])
        tap_idx = plan.get("tap_index")
        if tap_idx is not None and not steps:
            idx_int = int(tap_idx)
            matched = el_by_index.get(idx_int)
            if matched and isinstance(matched.get("center"), list) and len(matched["center"]) == 2:
                cx, cy = matched["center"]
                steps = [{"op": "tap", "x": int(cx), "y": int(cy)}]
                plan["matched"] = matched
            elif matched:
                txt = str(matched.get("label") or matched.get("name") or "")
                steps = [{"op": "tap_selector", "text": txt}]
                plan["matched"] = matched
        plan["steps"] = steps
        plan["engine"] = use_model
        return plan

    async def run_ai_goal(
        self,
        goal: str,
        max_steps: int = 6,
        prefer: str = "auto",
        *,
        verify_final: bool = False,
        async_tap: bool = False,
        base_url: Optional[str] = None,
        api_key: Optional[str] = None,
        model: Optional[str] = None,
    ) -> dict[str, Any]:
        t_total0 = time.perf_counter()
        trace: list[dict[str, Any]] = []
        history: list[str] = []
        mode = (prefer or "auto").strip().lower()
        if mode == "auto" and self.default_agent != "auto":
            mode = self.default_agent

        if mode == "pi":
            t_d0 = time.perf_counter()
            dump = await self.wda.fast_ui_dump(compact=True, max_elements=160)
            dump_ms = round((time.perf_counter() - t_d0) * 1000, 1)
            return await self.pi_agent.run_goal(
                goal,
                dump.get("elements") or [],
                dump_ms=dump_ms,
                max_steps=max_steps,
            )

        for step_idx in range(max(1, int(max_steps))):
            t_d0 = time.perf_counter()
            dump = await self.wda.fast_ui_dump(compact=True, max_elements=160)
            dump_ms = round((time.perf_counter() - t_d0) * 1000, 1)
            elements = dump.get("elements") or []

            t_a0 = time.perf_counter()
            plan = await self.plan_step_auto(
                goal,
                elements,
                history,
                prefer=mode,
                base_url=base_url,
                api_key=api_key,
                model=model,
            )
            ai_ms = round((time.perf_counter() - t_a0) * 1000, 1)

            steps = plan.get("steps") or []
            if plan.get("done") and not steps:
                trace.append(
                    {
                        "step": step_idx,
                        "engine": plan.get("engine"),
                        "dump_ms": dump_ms,
                        "ai_ms": ai_ms,
                        "exec_ms": 0.0,
                        "plan": plan,
                    }
                )
                return {
                    "ok": True,
                    "goal": goal,
                    "steps_taken": len(trace),
                    "total_latency_ms": round((time.perf_counter() - t_total0) * 1000, 1),
                    "trace": trace,
                }

            can_async_tap = (
                async_tap
                and bool(plan.get("done"))
                and not verify_final
                and len(steps) == 1
                and steps[0].get("op") == "tap"
            )
            if can_async_tap:
                task = asyncio.create_task(self.execute_steps(steps))
                self._background_tasks.add(task)
                task.add_done_callback(self._background_tasks.discard)
                exec_res = {"ok": True, "async_dispatched": True, "step_results": []}
                exec_ms = 0.0
            else:
                t_e0 = time.perf_counter()
                exec_res = await self.execute_steps(steps) if steps else {"ok": True, "step_results": []}
                exec_ms = round((time.perf_counter() - t_e0) * 1000, 1)

            summary = f"step {step_idx}: {plan.get('reason') or steps}"
            if plan.get("matched"):
                summary += f" -> {plan['matched'].get('label') or plan['matched'].get('name')}"
            history.append(summary)

            trace.append(
                {
                    "step": step_idx,
                    "engine": plan.get("engine"),
                    "dump_ms": dump_ms,
                    "ai_ms": ai_ms,
                    "exec_ms": exec_ms,
                    "plan": plan,
                    "exec": exec_res,
                }
            )
            if not exec_res.get("ok"):
                return {
                    "ok": False,
                    "goal": goal,
                    "steps_taken": len(trace),
                    "total_latency_ms": round((time.perf_counter() - t_total0) * 1000, 1),
                    "trace": trace,
                }
            if plan.get("done") and not verify_final:
                return {
                    "ok": True,
                    "goal": goal,
                    "async_dispatched": can_async_tap,
                    "steps_taken": len(trace),
                    "total_latency_ms": round((time.perf_counter() - t_total0) * 1000, 1),
                    "trace": trace,
                }
            await asyncio.sleep(0.35)

        return {
            "ok": False,
            "error": "Max AI steps reached",
            "goal": goal,
            "steps_taken": len(trace),
            "total_latency_ms": round((time.perf_counter() - t_total0) * 1000, 1),
            "trace": trace,
        }

    async def run_async_voice_task(
        self,
        task_id: str,
        mode: str,
        payload: Any,
        original_text: str,
        agent: str = "auto",
    ) -> None:
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

        status = self.get_ai_engine_status()
        eff_agent = (agent or "auto").strip().lower()
        if eff_agent == "auto" and self.default_agent != "auto":
            eff_agent = self.default_agent
        pi_ready = bool((status.get("pi_agent") or {}).get("available"))
        if status["decision_1_configured"] or status["fast_llm_configured"] or (eff_agent == "pi" and pi_ready):
            try:
                res = await self.run_ai_goal(original_text, max_steps=6, prefer=eff_agent)
                self.log_siri_task(
                    {
                        "task_id": task_id,
                        "ts": datetime.now(timezone.utc).isoformat(),
                        "text": original_text,
                        "mode": "async_llm",
                        "agent": res.get("agent") or eff_agent,
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
                        "agent": eff_agent,
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
                "note": "No GROGU_LLM_BASE_URL or OPENROUTER_API_KEY set; captured UI context and queued for MCP agent.",
                "snapshot": snapshot,
            }
        )

    async def _run_lm_loop(self, goal: str, base_url: str, api_key: str, model: str, max_steps: int = 8) -> dict[str, Any]:
        return await self.run_ai_goal(goal, max_steps=max_steps, prefer="llm", base_url=base_url, api_key=api_key, model=model)
