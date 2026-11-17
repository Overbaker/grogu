"""Core Tailscale device probing, pairing management, RSD tunnel lifecycle, and DVT telemetry."""

from __future__ import annotations

import asyncio
import base64
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import socket
import subprocess
from typing import Any, Optional
import urllib.request
import uuid

from grogu.config import (
    BIND_HOST,
    DEFAULT_WDA_BUNDLE_ID,
    DEVICE_IP,
    GATEWAY_PORT,
    MAC_TAILSCALE_IP,
    OUTPUT_DIR,
    PAIRING_DIR,
    RSD_RPC_PORT,
    SSH_CONFIG_PATH,
    STATE_DIR,
    WDA_FORWARD_PORT,
    resolve_pmd_python,
)

PMD_WORKER = str(Path(__file__).resolve().parent / "pmd_worker.py")

_UDID_RE = re.compile(r"^[A-Za-z0-9-]{16,44}$")
_MAC_USER_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")


def _tcp_open(host: str, port: int, timeout: float = 1.5) -> bool:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        return s.connect_ex((host, port)) == 0
    finally:
        s.close()


def _http_status_ok(url: str, timeout: float = 1.5) -> bool:
    try:
        with urllib.request.urlopen(f"{url.rstrip('/')}/status", timeout=timeout) as resp:
            return resp.status == 200
    except Exception:
        return False


class GroguCoreManager:
    """Manages Tailscale reachability, pairing records, RSD/WDA daemon, and DVT telemetry."""

    def __init__(self, device_ip: str = DEVICE_IP) -> None:
        self.device_ip = device_ip
        STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
        PAIRING_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)

    def load_device_meta(self) -> dict[str, Any]:
        meta_path = STATE_DIR / "device.json"
        if meta_path.exists():
            try:
                return json.loads(meta_path.read_text(encoding="utf-8"))
            except Exception:
                return {}
        return {}

    def get_pairing_status(self) -> dict[str, Any]:
        meta = self.load_device_meta()
        udid = meta.get("udid")
        lockdown_files = [p.name for p in sorted(PAIRING_DIR.glob("*.plist")) if not p.name.startswith("remote_")]
        remote_files = [p.name for p in sorted(PAIRING_DIR.glob("remote_*.plist"))]
        if not udid and lockdown_files:
            udid = lockdown_files[0].removesuffix(".plist")
        elif not udid and remote_files:
            udid = remote_files[0].removeprefix("remote_").removesuffix(".plist")
        return {
            "paired": bool(lockdown_files or remote_files),
            "udid": udid,
            "lockdown_records": lockdown_files,
            "remote_records": remote_files,
            "wda_bundle_id": meta.get("wda_bundle_id") or DEFAULT_WDA_BUNDLE_ID,
            "mac_user": meta.get("mac_user"),
            "mac_tailscale_ip": meta.get("mac_tailscale_ip", MAC_TAILSCALE_IP),
            "xcode_path": meta.get("xcode_path"),
            "updated_at": meta.get("updated_at"),
        }

    def probe_ports(self) -> dict[str, Any]:
        lockdown_62078 = _tcp_open(self.device_ip, 62078, timeout=1.8)
        rp_open_port: Optional[int] = None
        for p in (49152, 49153, 49154, 49155, 49156, 49157, 49158):
            if _tcp_open(self.device_ip, p, timeout=1.0):
                rp_open_port = p
                break
        wda_direct_8100 = _http_status_ok(f"http://{self.device_ip}:8100", timeout=1.5)
        wda_forward_18832 = _http_status_ok(f"http://127.0.0.1:{WDA_FORWARD_PORT}", timeout=1.2)
        rsd_rpc_18833 = _tcp_open("127.0.0.1", RSD_RPC_PORT, timeout=0.5)
        mac_ssh_22 = _tcp_open(MAC_TAILSCALE_IP, 22, timeout=1.2) if MAC_TAILSCALE_IP else False
        return {
            "device_tailscale_ip": self.device_ip,
            "lockdownd_62078": lockdown_62078,
            "remotepairing_49152": rp_open_port == 49152,
            "remotepairing_port": rp_open_port,
            "wda_direct_8100": wda_direct_8100,
            "wda_forward_18832": wda_forward_18832,
            "rsd_rpc_18833": rsd_rpc_18833,
            "mac_ssh_22": mac_ssh_22,
        }

    def save_uploaded_pairings(
        self,
        *,
        udid: str,
        lockdown_b64: Optional[str] = None,
        remote_b64: Optional[str] = None,
        mac_user: Optional[str] = None,
        mac_hostname: Optional[str] = None,
        mac_tailscale_ip: Optional[str] = None,
        xcode_path: Optional[str] = None,
        wda_bundle_id: Optional[str] = None,
    ) -> dict[str, Any]:
        udid = udid.strip()
        if not _UDID_RE.match(udid):
            raise ValueError(f"Invalid UDID format: {udid!r}")

        saved_files: list[str] = []

        if lockdown_b64:
            raw_ld = base64.b64decode(lockdown_b64.strip(), validate=True)
            parsed_ld = plistlib.loads(raw_ld)
            if not isinstance(parsed_ld, dict):
                raise ValueError("Lockdown plist payload is not a dictionary")
            ld_path = PAIRING_DIR / f"{udid}.plist"
            ld_path.write_bytes(plistlib.dumps(parsed_ld))
            os.chmod(ld_path, 0o600)
            saved_files.append(str(ld_path))

        if remote_b64:
            raw_rp = base64.b64decode(remote_b64.strip(), validate=True)
            parsed_rp = plistlib.loads(raw_rp)
            if not isinstance(parsed_rp, dict):
                raise ValueError("RemotePairing plist payload is not a dictionary")
            if mac_hostname and "host_identifier" not in parsed_rp:
                parsed_rp["host_identifier"] = str(uuid.uuid3(uuid.NAMESPACE_DNS, mac_hostname.strip())).upper()
            rp_path = PAIRING_DIR / f"remote_{udid}.plist"
            rp_path.write_bytes(plistlib.dumps(parsed_rp))
            os.chmod(rp_path, 0o600)
            saved_files.append(str(rp_path))

        meta = self.load_device_meta()
        mac_ip = (mac_tailscale_ip or meta.get("mac_tailscale_ip") or MAC_TAILSCALE_IP).strip()
        meta.update(
            {
                "udid": udid,
                "device_tailscale_ip": self.device_ip,
                "mac_tailscale_ip": mac_ip,
                "updated_at": datetime.now(timezone.utc).isoformat(),
            }
        )
        if mac_user and _MAC_USER_RE.match(mac_user.strip()):
            meta["mac_user"] = mac_user.strip()
            self._ensure_mac_ssh_config(mac_user.strip(), mac_ip)
        if mac_hostname:
            meta["mac_hostname"] = mac_hostname.strip()
        if xcode_path:
            meta["xcode_path"] = xcode_path.strip()
        if wda_bundle_id:
            meta["wda_bundle_id"] = wda_bundle_id.strip()

        meta_path = STATE_DIR / "device.json"
        meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
        os.chmod(meta_path, 0o600)

        return {
            "ok": True,
            "udid": udid,
            "saved_files": saved_files,
            "mac_ssh_configured": bool(meta.get("mac_user")),
        }

    def _ensure_mac_ssh_config(self, mac_user: str, mac_ip: str) -> None:
        if not SSH_CONFIG_PATH.exists():
            return
        content = SSH_CONFIG_PATH.read_text(encoding="utf-8")
        block = (
            "\n# === Grogu Companion Mac over Tailscale ===\n"
            "Host grogu-mac\n"
            f"    HostName {mac_ip}\n"
            f"    User {mac_user}\n"
            "    IdentityFile ~/.ssh/id_ed25519\n"
            "    IdentitiesOnly yes\n"
            "    StrictHostKeyChecking accept-new\n"
            "    ServerAliveInterval 30\n"
        )
        marker = "Host grogu-mac"
        if marker in content:
            pattern = re.compile(
                r"\n?# === Grogu Companion Mac over Tailscale.*?ServerAliveInterval 30\n?",
                re.DOTALL,
            )
            new_content = pattern.sub(block + "\n", content)
        else:
            new_content = content.rstrip() + "\n" + block
        SSH_CONFIG_PATH.write_text(new_content, encoding="utf-8")
        os.chmod(SSH_CONFIG_PATH, 0o600)

    def _daemon_pid(self) -> Optional[int]:
        pid_file = STATE_DIR / "daemon.pid"
        if not pid_file.exists():
            return None
        try:
            pid = int(pid_file.read_text(encoding="utf-8").strip())
            os.kill(pid, 0)
            return pid
        except Exception:
            return None

    async def ensure_tunnel_and_wda(self, timeout_s: float = 15.0) -> dict[str, Any]:
        if _http_status_ok(f"http://{self.device_ip}:8100", timeout=1.2):
            return {"ok": True, "mode": "direct_tailscale", "wda_url": f"http://{self.device_ip}:8100"}
        if _http_status_ok(f"http://127.0.0.1:{WDA_FORWARD_PORT}", timeout=1.0):
            return {"ok": True, "mode": "rsd_forward", "wda_url": f"http://127.0.0.1:{WDA_FORWARD_PORT}"}

        pairing = self.get_pairing_status()
        if not pairing["paired"]:
            return {
                "ok": False,
                "reason": "not_paired",
                "error": (
                    "Device pairing keys (<udid>.plist / remote_<udid>.plist) not uploaded yet. "
                    f"Run `curl -fsSL http://{BIND_HOST}:{GATEWAY_PORT}/bootstrap/mac.sh | bash` on your Mac."
                ),
            }

        pid = self._daemon_pid()
        if pid is None and not _tcp_open("127.0.0.1", RSD_RPC_PORT, timeout=0.4):
            log_file = OUTPUT_DIR / "grogu_daemon.log"
            log_file.parent.mkdir(parents=True, exist_ok=True)
            wda_bundle = pairing["wda_bundle_id"]
            with log_file.open("a", encoding="utf-8") as lf:
                proc = subprocess.Popen(
                    [
                        resolve_pmd_python(),
                        PMD_WORKER,
                        "--host",
                        self.device_ip,
                        "daemon",
                        "--wda-bundle",
                        wda_bundle,
                        "--forward-port",
                        str(WDA_FORWARD_PORT),
                        "--rpc-port",
                        str(RSD_RPC_PORT),
                    ],
                    stdout=lf,
                    stderr=lf,
                    start_new_session=True,
                )
            (STATE_DIR / "daemon.pid").write_text(str(proc.pid), encoding="utf-8")

        deadline = asyncio.get_running_loop().time() + timeout_s
        while asyncio.get_running_loop().time() < deadline:
            if _http_status_ok(f"http://{self.device_ip}:8100", timeout=1.0):
                return {"ok": True, "mode": "direct_tailscale", "wda_url": f"http://{self.device_ip}:8100"}
            if _http_status_ok(f"http://127.0.0.1:{WDA_FORWARD_PORT}", timeout=1.0):
                return {"ok": True, "mode": "rsd_forward", "wda_url": f"http://127.0.0.1:{WDA_FORWARD_PORT}"}
            await asyncio.sleep(0.5)

        return {
            "ok": False,
            "reason": "wda_unreachable",
            "error": (
                "RSD tunnel daemon is active, but WDA port 8100 is not responding yet. "
                "Verify WebDriverAgentRunner is installed, Personalized DDI is mounted, and screen is unlocked."
            ),
        }

    def stop_daemon(self) -> bool:
        pid = self._daemon_pid()
        if pid is None:
            return False
        try:
            os.kill(pid, signal.SIGTERM)
            return True
        except Exception:
            return False

    async def run_worker(self, *args: str, timeout: float = 25.0) -> dict[str, Any]:
        pairing = self.get_pairing_status()
        if not pairing["paired"]:
            return {
                "ok": False,
                "error": (
                    "Device pairing keys not uploaded yet. "
                    f"Run `curl -fsSL http://{BIND_HOST}:{GATEWAY_PORT}/bootstrap/mac.sh | bash` on your Mac."
                ),
            }
        cmd = [resolve_pmd_python(), PMD_WORKER, "--host", self.device_ip, *args]
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        except asyncio.TimeoutError:
            proc.kill()
            await proc.wait()
            return {"ok": False, "error": f"Worker command timed out after {timeout}s"}

        raw = stdout.decode("utf-8", errors="replace").strip()
        if not raw:
            err = stderr.decode("utf-8", errors="replace").strip()
            return {"ok": False, "error": err or f"Worker exited with code {proc.returncode}"}
        try:
            return json.loads(raw.splitlines()[-1])
        except json.JSONDecodeError:
            return {"ok": proc.returncode == 0, "raw_output": raw, "stderr": stderr.decode("utf-8", errors="replace")}

    async def _rpc_telemetry(
        self,
        kind: str,
        filter_text: str,
        limit: int,
        duration_s: float,
        out_path: str,
        timeout: float,
    ) -> Optional[dict[str, Any]]:
        if not _tcp_open("127.0.0.1", RSD_RPC_PORT, timeout=0.35):
            return None
        try:
            reader, writer = await asyncio.wait_for(asyncio.open_connection("127.0.0.1", RSD_RPC_PORT), timeout=2.0)
            req = {
                "kind": kind,
                "filter_text": filter_text,
                "limit": limit,
                "duration_s": duration_s,
                "out_path": out_path,
            }
            writer.write((json.dumps(req, ensure_ascii=False) + "\n").encode("utf-8"))
            await writer.drain()
            raw = await asyncio.wait_for(reader.readline(), timeout=timeout)
            writer.close()
            if not raw:
                return None
            return json.loads(raw.decode("utf-8"))
        except Exception:
            return None

    async def get_telemetry(
        self,
        kind: str,
        filter_text: str = "",
        limit: int = 80,
        duration_s: float = 2.5,
        out_path: str = "",
    ) -> dict[str, Any]:
        timeout = max(20.0, duration_s + 15.0)
        rpc_res = await self._rpc_telemetry(kind, filter_text, limit, duration_s, out_path, timeout=timeout)
        if rpc_res is not None:
            return rpc_res
        args = ["telemetry", kind, "--filter", filter_text, "--limit", str(limit), "--duration", str(duration_s)]
        if out_path:
            args.extend(["--out", out_path])
        return await self.run_worker(*args, timeout=timeout)
