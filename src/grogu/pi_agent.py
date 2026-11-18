"""Persistent warm Pi coding-agent RPC bridge (`pi --mode rpc`) for pluggable UI control."""

from __future__ import annotations

import asyncio
from contextlib import suppress
import json
import os
from pathlib import Path
import shutil
import time
from typing import Any, Optional
import uuid

_EXTENSION_PATH = Path(__file__).resolve().parent / "pi_ext" / "grogu_ios_tools.ts"


class PiRpcAgent:
    """Maintains a warm `pi --mode rpc` subprocess with minimal iOS extension tools."""

    def __init__(self, gateway_url: str) -> None:
        self.gateway_url = gateway_url.rstrip("/")
        self.pi_bin: str = (os.environ.get("GROGU_PI_BIN") or shutil.which("pi") or "").strip()
        self.provider: str = os.environ.get("GROGU_PI_PROVIDER", "").strip()
        self.model: str = os.environ.get("GROGU_PI_MODEL", "").strip()
        self.thinking: str = os.environ.get("GROGU_PI_THINKING", "off").strip() or "off"
        self._proc: Optional[asyncio.subprocess.Process] = None
        self._lock = asyncio.Lock()

    def get_status(self) -> dict[str, Any]:
        resolved_bin = self.pi_bin or (shutil.which("pi") or "")
        return {
            "available": bool(resolved_bin) and _EXTENSION_PATH.exists(),
            "pi_bin": resolved_bin,
            "provider": self.provider,
            "model": self.model,
            "thinking": self.thinking,
            "warm": bool(self._proc and self._proc.returncode is None),
            "extension_path": str(_EXTENSION_PATH),
        }

    async def aclose(self) -> None:
        proc = self._proc
        self._proc = None
        if proc is None:
            return
        if proc.stdin and not proc.stdin.is_closing():
            with suppress(Exception):
                proc.stdin.close()
        if proc.returncode is None:
            try:
                await asyncio.wait_for(proc.wait(), timeout=2.0)
            except asyncio.TimeoutError:
                with suppress(Exception):
                    proc.terminate()
                try:
                    await asyncio.wait_for(proc.wait(), timeout=2.0)
                except asyncio.TimeoutError:
                    with suppress(Exception):
                        proc.kill()

    async def reconfigure(
        self,
        *,
        provider: Optional[str] = None,
        model: Optional[str] = None,
        thinking: Optional[str] = None,
    ) -> dict[str, Any]:
        async with self._lock:
            changed = False
            if provider is not None and provider.strip() != self.provider:
                self.provider = provider.strip()
                changed = True
            if model is not None and model.strip() != self.model:
                self.model = model.strip()
                changed = True
            if thinking is not None and thinking.strip() and thinking.strip() != self.thinking:
                self.thinking = thinking.strip()
                changed = True
            if changed:
                await self.aclose()
        return self.get_status()

    async def _ensure_process(self) -> asyncio.subprocess.Process:
        if self._proc and self._proc.returncode is None:
            return self._proc
        pi_bin = self.pi_bin or (shutil.which("pi") or "")
        if not pi_bin:
            raise RuntimeError("`pi` CLI not found in PATH (set GROGU_PI_BIN)")
        if not _EXTENSION_PATH.exists():
            raise RuntimeError(f"Pi extension missing: {_EXTENSION_PATH}")

        cmd = [
            pi_bin,
            "--mode",
            "rpc",
            "--no-session",
            "--no-builtin-tools",
            "--no-mcp",
            "--no-skills",
            "--no-context-files",
            "--no-themes",
            "--thinking",
            self.thinking,
            "-e",
            str(_EXTENSION_PATH),
        ]
        if self.provider:
            cmd.extend(["--provider", self.provider])
        if self.model:
            cmd.extend(["--model", self.model])

        env = os.environ.copy()
        env["GROGU_LOCAL_GATEWAY_URL"] = self.gateway_url
        self._proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=env,
            limit=4 * 1024 * 1024,
        )
        return self._proc

    async def _send_cmd(self, proc: asyncio.subprocess.Process, cmd_obj: dict[str, Any]) -> None:
        assert proc.stdin is not None
        line = json.dumps(cmd_obj, ensure_ascii=False).encode("utf-8") + b"\n"
        proc.stdin.write(line)
        await proc.stdin.drain()

    async def _read_record(self, proc: asyncio.subprocess.Process, timeout_s: float) -> dict[str, Any]:
        assert proc.stdout is not None
        raw = await asyncio.wait_for(proc.stdout.readline(), timeout=timeout_s)
        if not raw:
            err_tail = ""
            if proc.stderr:
                with suppress(Exception):
                    err_tail = (await asyncio.wait_for(proc.stderr.read(2048), timeout=0.5)).decode(
                        "utf-8", errors="replace"
                    )
            raise RuntimeError(f"Pi RPC process exited unexpectedly: {err_tail.strip()}")
        return json.loads(raw.decode("utf-8"))

    async def run_goal(
        self,
        goal: str,
        elements: list[dict[str, Any]],
        dump_ms: float = 0.0,
        max_steps: int = 6,
    ) -> dict[str, Any]:
        fg_app = ""
        compact_ui: list[dict[str, Any]] = []
        for pos, el in enumerate(elements):
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
            item: dict[str, Any] = {"i": int(el.get("index", pos)), "t": el_type}
            if lbl:
                item["l"] = lbl[:80]
            if name and name != lbl:
                item["n"] = name[:60]
            if val and val != lbl:
                item["v"] = val[:40]
            if el.get("center"):
                item["c"] = el["center"]
            compact_ui.append(item)
            if len(compact_ui) >= 150:
                break

        prompt_msg = (
            f"Goal: {goal}\n"
            + (f"Foreground App: {fg_app}\n" if fg_app else "")
            + "Rules:\n"
            "- Execute via the provided ios_* tools (prefer ios_tap(x, y) using c=[x,y] from UI below).\n"
            "- On split-view apps (e.g. iPad Settings), left sidebar items (x<300) remain directly tappable.\n"
            "- If a single tool call completely fulfills the goal, reply DONE right after the tool succeeds without calling ios_ui_dump again.\n"
            f"- Take at most {max(1, int(max_steps))} tool calls.\n\n"
            f"Initial UI (i=index, t=type, l=label, n=name, v=value, c=[x,y]):\n"
            + json.dumps(compact_ui, ensure_ascii=False)
        )

        async with self._lock:
            t0 = time.perf_counter()
            proc = await self._ensure_process()
            try:
                ns_id = f"ns-{uuid.uuid4().hex[:8]}"
                await self._send_cmd(proc, {"id": ns_id, "type": "new_session"})
                while True:
                    rec = await self._read_record(proc, timeout_s=15.0)
                    if rec.get("type") == "response" and rec.get("id") == ns_id:
                        if not rec.get("success"):
                            raise RuntimeError(rec.get("error") or "Pi new_session failed")
                        break

                p_id = f"p-{uuid.uuid4().hex[:8]}"
                await self._send_cmd(proc, {"id": p_id, "type": "prompt", "message": prompt_msg})

                tool_calls: list[dict[str, Any]] = []
                tc_by_id: dict[str, dict[str, Any]] = {}
                active_starts: dict[str, float] = {}
                text_parts: list[str] = []
                prompt_err: Optional[str] = None
                deadline = time.perf_counter() + 40.0

                while True:
                    rem = max(0.5, deadline - time.perf_counter())
                    rec = await self._read_record(proc, timeout_s=rem)
                    rtype = rec.get("type")
                    if rtype == "response" and rec.get("id") == p_id:
                        if not rec.get("success"):
                            prompt_err = str(rec.get("error") or "Pi prompt rejected")
                            break
                        if (rec.get("data") or {}).get("disposition") == "handled":
                            break
                    elif rtype == "tool_execution_start":
                        cid = str(rec.get("toolCallId") or "")
                        active_starts[cid] = time.perf_counter()
                        entry = {
                            "tool": rec.get("toolName"),
                            "args": rec.get("args"),
                        }
                        tool_calls.append(entry)
                        if cid:
                            tc_by_id[cid] = entry
                    elif rtype == "tool_execution_end":
                        cid = str(rec.get("toolCallId") or "")
                        t_s = active_starts.pop(cid, None)
                        dur_ms = round((time.perf_counter() - t_s) * 1000, 1) if t_s else None
                        target = tc_by_id.get(cid) or (tool_calls[-1] if tool_calls else None)
                        if target is not None:
                            target["is_error"] = bool(rec.get("isError"))
                            if dur_ms is not None:
                                target["tool_ms"] = dur_ms
                    elif rtype == "message_update":
                        ev = rec.get("assistantMessageEvent") or {}
                        if ev.get("type") == "text_delta":
                            text_parts.append(str(ev.get("delta") or ""))
                        elif ev.get("type") == "error":
                            prompt_err = str((ev.get("error") or {}).get("errorMessage") or "Pi model error")
                    elif rtype == "agent_end":
                        for msg in rec.get("messages") or []:
                            if msg.get("role") == "assistant" and msg.get("stopReason") == "error" and msg.get("errorMessage"):
                                prompt_err = str(msg["errorMessage"])
                    elif rtype == "agent_settled":
                        break

                pi_ms = round((time.perf_counter() - t0) * 1000, 1)
                ok = prompt_err is None and all(not tc.get("is_error") for tc in tool_calls)
                engine_tag = "pi"
                if self.provider or self.model:
                    engine_tag = f"pi:{self.provider}/{self.model}".strip("/")
                return {
                    "ok": ok,
                    "agent": "pi",
                    "engine": engine_tag,
                    "goal": goal,
                    "steps_taken": len(tool_calls),
                    "dump_ms": dump_ms,
                    "ai_ms": pi_ms,
                    "total_latency_ms": round(dump_ms + pi_ms, 1),
                    "error": prompt_err,
                    "trace": tool_calls,
                    "assistant_text": "".join(text_parts).strip(),
                }
            except Exception as exc:
                await self.aclose()
                pi_ms = round((time.perf_counter() - t0) * 1000, 1)
                return {
                    "ok": False,
                    "agent": "pi",
                    "goal": goal,
                    "dump_ms": dump_ms,
                    "ai_ms": pi_ms,
                    "total_latency_ms": round(dump_ms + pi_ms, 1),
                    "error": str(exc),
                    "trace": [],
                }
