#!/usr/bin/env python3
"""
Grogu pymobiledevice3 Tailscale worker.
Connects directly over Tailscale TCP (`49152..` RemotePairing or `62078` Lockdown) without Bonjour, USB, or root.
Provides DVT telemetry, Personalized DDI auto-mount, XCUITestService supervision, WDA port relay, and RPC.
"""

from __future__ import annotations

import argparse
import asyncio
from contextlib import suppress
from dataclasses import dataclass
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import socket
import sys
import time
from typing import Any, Optional

from pymobiledevice3 import lockdown as pmd_lockdown
from pymobiledevice3.exceptions import AlreadyMountedError
from pymobiledevice3.pair_records import PAIRING_RECORD_EXT, get_remote_pairing_record_filename
from pymobiledevice3.remote import tunnel_service
from pymobiledevice3.remote.userspace_tunnel import TunnelProvider, UserspaceRsdTunnel
from pymobiledevice3.services.accessibilityaudit import AccessibilityAudit
from pymobiledevice3.services.amfi import AmfiService
from pymobiledevice3.services.diagnostics import DiagnosticsService
from pymobiledevice3.services.dvt.instruments.activity_trace_tap import ActivityTraceTap
from pymobiledevice3.services.dvt.instruments.device_info import DeviceInfo
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.network_statistics import NetworkStatistics
from pymobiledevice3.services.dvt.instruments.process_control import ProcessControl
from pymobiledevice3.services.dvt.instruments.screenshot import Screenshot
from pymobiledevice3.services.dvt.instruments.sysmontap import Sysmontap
from pymobiledevice3.services.dvt.testmanaged.xcuitest import NSURL, TestConfig, XCUITestListener, XCUITestService
from pymobiledevice3.services.installation_proxy import InstallationProxyService
from pymobiledevice3.services.mobile_image_mounter import auto_mount
from pymobiledevice3.services.pcapd import CrossPlatformAddressFamily, PcapdService

with suppress(Exception):
    tunnel_service.RemotePairingTcpTunnel.REQUESTED_MTU = 1280
with suppress(Exception):
    tunnel_service.RemotePairingTunnelService.REQUESTED_MTU = 1280

DEVICE_IP = os.environ.get("GROGU_DEVICE_IP", "100.64.0.10").strip()
STATE_DIR = Path(os.environ.get("GROGU_STATE_DIR", str(Path.home() / ".config" / "grogu"))).expanduser()
PAIRING_DIR = Path(os.environ.get("GROGU_PAIRING_DIR", str(Path.home() / ".pymobiledevice3"))).expanduser()
OUTPUT_DIR = Path(os.environ.get("GROGU_OUTPUT_DIR", "/tmp/grogu")).expanduser()
DEFAULT_WDA_BUNDLE_ID = os.environ.get("GROGU_WDA_BUNDLE_ID", "com.facebook.WebDriverAgentRunner.xctrunner").strip()

_AX_ROLE_MAP: dict[str, str] = {
    "button": "Button",
    "switch": "Switch",
    "switch button": "Switch",
    "header": "Header",
    "heading": "Header",
    "link": "Link",
    "image": "Image",
    "text field": "TextField",
    "search field": "SearchField",
    "secure text field": "SecureTextField",
    "tab": "Tab",
    "slider": "Slider",
    "adjustable": "Adjustable",
    "static text": "StaticText",
}

_NET_DAEMON_NAMES = {
    "mdnsresponder",
    "nesessionmanager",
    "tailscaled",
    "tailscale",
    "springboard",
    "commcenter",
    "nsurlsessiond",
    "symptomsd",
    "rapportd",
}


def _load_device_meta() -> dict[str, Any]:
    meta_path = STATE_DIR / "device.json"
    if meta_path.exists():
        try:
            return json.loads(meta_path.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {}


def _find_pairing_records() -> dict[str, Any]:
    meta = _load_device_meta()
    udid = meta.get("udid")
    lockdown_record: Optional[dict[str, Any]] = None
    remote_record: Optional[dict[str, Any]] = None

    if udid:
        ld_path = PAIRING_DIR / f"{udid}.plist"
        rp_path = PAIRING_DIR / f"{get_remote_pairing_record_filename(udid)}.{PAIRING_RECORD_EXT}"
        if ld_path.exists():
            lockdown_record = plistlib.loads(ld_path.read_bytes())
        if rp_path.exists():
            remote_record = plistlib.loads(rp_path.read_bytes())

    if remote_record is None:
        for p in sorted(PAIRING_DIR.glob("remote_*.plist")):
            try:
                remote_record = plistlib.loads(p.read_bytes())
                if not udid:
                    udid = p.stem.removeprefix("remote_")
                break
            except Exception:
                continue

    if lockdown_record is None:
        for p in sorted(PAIRING_DIR.glob("*.plist")):
            if p.name.startswith("remote_"):
                continue
            try:
                lockdown_record = plistlib.loads(p.read_bytes())
                if not udid:
                    udid = p.stem
                break
            except Exception:
                continue

    return {
        "udid": udid,
        "meta": meta,
        "lockdown_record": lockdown_record,
        "remote_record": remote_record,
    }


def _scan_open_rp_port(host: str, ports: tuple[int, ...] = (49152, 49153, 49154, 49155, 49156, 49157, 49158)) -> Optional[int]:
    for port in ports:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(1.2)
        try:
            if s.connect_ex((host, port)) == 0:
                return port
        finally:
            s.close()
    return None


async def _open_lockdown(host: str, info: dict[str, Any]):
    lockdown_record = info.get("lockdown_record")
    udid = info.get("udid")
    if not lockdown_record:
        raise RuntimeError("Missing lockdown pair record (<udid>.plist). Run Mac pairing bootstrap first.")
    return await pmd_lockdown.create_using_tcp(
        host,
        identifier=udid,
        autopair=False,
        pair_record=lockdown_record,
        pairing_records_cache_folder=PAIRING_DIR,
        keep_alive=True,
    )


async def _open_rsd_tunnel(host: str, info: dict[str, Any]) -> UserspaceRsdTunnel:
    udid = info.get("udid")
    remote_record = info.get("remote_record")
    lockdown_record = info.get("lockdown_record")

    rp_port = _scan_open_rp_port(host)
    if remote_record and udid and rp_port is not None:
        async def _rp_factory() -> TunnelProvider:
            svc = tunnel_service.RemotePairingTunnelService(
                remote_identifier=udid,
                hostname=host,
                port=rp_port,
                connect_timeout=12.0,
            )
            host_id = remote_record.get("host_identifier")
            if host_id:
                svc.identifier = host_id
            try:
                await svc.connect(autopair=False)
            except BaseException:
                await svc.close()
                raise
            return TunnelProvider(svc)

        try:
            tun = UserspaceRsdTunnel(provider_factory=_rp_factory)
            await tun.aopen()
            return tun
        except Exception as rp_err:
            if not lockdown_record:
                raise RuntimeError(f"RemotePairing TCP tunnel failed on {host}:{rp_port}: {rp_err}") from rp_err

    if lockdown_record:
        async def _ld_factory() -> TunnelProvider:
            ld = await _open_lockdown(host, info)
            try:
                proxy = await tunnel_service.CoreDeviceTunnelProxy.create(ld)
                return TunnelProvider(proxy, ld)
            except BaseException:
                await ld.close()
                raise

        tun = UserspaceRsdTunnel(provider_factory=_ld_factory)
        await tun.aopen()
        return tun

    raise RuntimeError("No valid pairing records found. Run the bootstrap command first.")


def _json_default(obj: Any) -> Any:
    if isinstance(obj, bytes):
        return obj.hex()
    if isinstance(obj, datetime):
        return obj.isoformat()
    return str(obj)


def _extract_url_schemes(apps: dict[str, Any]) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for bundle_id, app_info in sorted(apps.items()):
        if not isinstance(app_info, dict):
            continue
        url_types = app_info.get("CFBundleURLTypes") or []
        schemes: list[str] = []
        for entry in url_types:
            if isinstance(entry, dict):
                for s in entry.get("CFBundleURLSchemes") or []:
                    if isinstance(s, str) and s not in schemes:
                        schemes.append(s)
        name = (
            app_info.get("CFBundleDisplayName")
            or app_info.get("CFBundleName")
            or app_info.get("CFBundleExecutable")
            or bundle_id
        )
        app_type = app_info.get("ApplicationType", "")
        if schemes or app_type == "User":
            result.append(
                {
                    "bundle_id": bundle_id,
                    "name": name,
                    "version": app_info.get("CFBundleShortVersionString") or app_info.get("CFBundleVersion") or "",
                    "type": app_type,
                    "schemes": schemes,
                }
            )
    return result


async def _resolve_wda_bundle_id(rsd: Any, preferred: str) -> str:
    try:
        apps = await InstallationProxyService(lockdown=rsd).get_apps(
            application_type="User", calculate_sizes=False, show_placeholders=False
        )
    except Exception:
        return preferred

    if preferred in apps:
        return preferred

    found_bid: Optional[str] = None
    for bid, info in apps.items():
        if not isinstance(info, dict):
            continue
        exe = str(info.get("CFBundleExecutable") or "")
        if exe == "WebDriverAgentRunner-Runner" or "webdriveragent" in bid.lower():
            found_bid = bid
            break

    if found_bid:
        meta_path = STATE_DIR / "device.json"
        meta = _load_device_meta()
        if meta.get("wda_bundle_id") != found_bid:
            meta["wda_bundle_id"] = found_bid
            STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
            meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
            os.chmod(meta_path, 0o600)
        return found_bid
    return preferred


async def cmd_probe(host: str) -> dict[str, Any]:
    info = _find_pairing_records()
    rp_port = _scan_open_rp_port(host)
    out: dict[str, Any] = {
        "host": host,
        "udid": info.get("udid"),
        "has_lockdown_record": info.get("lockdown_record") is not None,
        "has_remote_record": info.get("remote_record") is not None,
        "rp_port_open": rp_port,
        "lockdown_connected": False,
        "rsd_connected": False,
    }
    if info.get("remote_record") or info.get("lockdown_record"):
        try:
            tun = await _open_rsd_tunnel(host, info)
            try:
                rsd = tun.rsd
                assert rsd is not None
                out["rsd_connected"] = True
                out["rsd_udid"] = rsd.udid
                out["rsd_version"] = rsd.product_version
                out["rsd_product_type"] = rsd.product_type
                vals = rsd.all_values or {}
                out["device_name"] = vals.get("DeviceName")
                out["build_version"] = vals.get("BuildVersion")
                with suppress(Exception):
                    out["developer_mode"] = await rsd.get_developer_mode_status()
                preferred_wda = (info.get("meta") or {}).get("wda_bundle_id") or DEFAULT_WDA_BUNDLE_ID
                out["wda_bundle_id"] = await _resolve_wda_bundle_id(rsd, preferred_wda)
            finally:
                await tun.aclose()
        except Exception as exc:
            out["rsd_error"] = str(exc)
    return out


async def cmd_reveal_dev_mode(host: str) -> dict[str, Any]:
    info = _find_pairing_records()
    tun = await _open_rsd_tunnel(host, info)
    try:
        rsd = tun.rsd
        assert rsd is not None
        already = False
        with suppress(Exception):
            already = bool(await rsd.get_developer_mode_status())
        await AmfiService(rsd).reveal_developer_mode_option_in_ui()
        return {
            "ok": True,
            "udid": rsd.udid,
            "developer_mode_already_enabled": already,
            "revealed_in_settings": True,
        }
    finally:
        await tun.aclose()


async def _run_telemetry_on_rsd(
    rsd: Any,
    kind: str,
    filter_text: str = "",
    limit: int = 80,
    duration_s: float = 2.5,
    out_path: str = "",
) -> dict[str, Any]:
    kind_l = kind.lower().strip()

    if kind_l == "probe":
        dev_mode = False
        with suppress(Exception):
            dev_mode = bool(await rsd.get_developer_mode_status())
        preferred_wda = (_load_device_meta()).get("wda_bundle_id") or DEFAULT_WDA_BUNDLE_ID
        wda_bid = await _resolve_wda_bundle_id(rsd, preferred_wda)
        return {
            "ok": True,
            "rsd_connected": True,
            "udid": rsd.udid,
            "product_type": rsd.product_type,
            "product_version": rsd.product_version,
            "developer_mode": dev_mode,
            "wda_bundle_id": wda_bid,
        }

    if kind_l == "ioregistry":
        diag = DiagnosticsService(lockdown=rsd)
        batt = await diag.get_battery()
        wifi = await diag.get_wifi()
        power_tree = None
        with suppress(Exception):
            power_tree = await diag.ioregistry(name="IOPMPowerSource")
        return {"ok": True, "kind": "ioregistry", "battery": batt, "wifi": wifi, "power_source": power_tree}

    if kind_l == "schemes":
        proxy = InstallationProxyService(lockdown=rsd)
        apps = await proxy.get_apps(application_type="Any", calculate_sizes=False, show_placeholders=False)
        extracted = _extract_url_schemes(apps)
        if filter_text:
            ft = filter_text.lower()
            extracted = [
                a
                for a in extracted
                if ft in a["bundle_id"].lower()
                or ft in str(a["name"]).lower()
                or any(ft in s.lower() for s in a["schemes"])
            ]
        STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
        if not filter_text:
            (STATE_DIR / "schemes_cache.json").write_text(
                json.dumps(extracted, ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
        return {"ok": True, "kind": "schemes", "total": len(extracted), "apps": extracted[:limit]}

    if kind_l == "network":
        try:
            svc = PcapdService(lockdown=rsd)
            packets: list[dict[str, Any]] = []
            deadline = time.monotonic() + min(max(duration_s, 0.5), 6.0)
            async for pkt in svc.watch(packets_count=min(limit, 80)):
                if filter_text and filter_text.lower() not in (pkt.comm or "").lower():
                    if time.monotonic() >= deadline:
                        break
                    continue
                packets.append(
                    {
                        "ts": round(pkt.seconds + pkt.microseconds / 1_000_000, 3),
                        "pid": pkt.pid,
                        "proc": pkt.comm,
                        "iface": f"{pkt.interface_name}{pkt.unit}",
                        "family": CrossPlatformAddressFamily(pkt.protocol_family).name,
                        "len": len(pkt.data),
                    }
                )
                if len(packets) >= limit or time.monotonic() >= deadline:
                    break
            return {"ok": True, "kind": "network", "mode": "pcapd", "count": len(packets), "packets": packets}
        except Exception as pcap_err:
            # Wireless RSD blocks com.apple.pcapd.shim.remote as USB-only; use DVT NetworkStatistics instead.
            async with DvtProvider(rsd) as dvt:
                async with DeviceInfo(dvt) as di:
                    interfaces = await di.network_information()
                    procs = await di.proclist()

                proc_map: dict[int, dict[str, Any]] = {}
                selected_pids: list[int] = []
                ft = filter_text.lower().strip()
                for p in procs:
                    pid = int(p.get("pid", 0))
                    if pid <= 0:
                        continue
                    proc_map[pid] = p
                    name_l = str(p.get("name") or "").lower()
                    bid_l = str(p.get("bundleIdentifier") or "").lower()
                    if ft:
                        if ft in name_l or ft in bid_l:
                            selected_pids.append(pid)
                    elif p.get("isApplication") or name_l in _NET_DAEMON_NAMES:
                        selected_pids.append(pid)
                selected_pids = selected_pids[:25]

                latest_sample: dict[Any, dict[str, Any]] = {}
                if selected_pids:
                    sample_budget = min(max(duration_s, 0.7), 6.0)
                    interval_ms = 600
                    max_samples = 2 if sample_budget >= 1.2 else 1
                    async with NetworkStatistics(dvt, selected_pids, interval_ms=interval_ms) as ns:
                        async def _collect_ns() -> None:
                            nonlocal latest_sample
                            count = 0
                            async for sample in ns:
                                if isinstance(sample, dict) and sample:
                                    latest_sample = sample
                                count += 1
                                if count >= max_samples:
                                    break
                        with suppress(asyncio.TimeoutError):
                            await asyncio.wait_for(_collect_ns(), timeout=sample_budget + 2.0)

            rows: list[dict[str, Any]] = []
            for pid_key, stats in latest_sample.items():
                if not isinstance(stats, dict):
                    continue
                pid = int(stats.get("pid") or pid_key)
                meta_p = proc_map.get(pid, {})
                rx_bytes = int(stats.get("net.rx.bytes", 0) or 0)
                tx_bytes = int(stats.get("net.tx.bytes", 0) or 0)
                rx_delta = int(stats.get("net.rx.bytes.delta", 0) or 0)
                tx_delta = int(stats.get("net.tx.bytes.delta", 0) or 0)
                rows.append(
                    {
                        "pid": pid,
                        "name": meta_p.get("name") or str(pid),
                        "bundle_id": meta_p.get("bundleIdentifier") or "",
                        "is_app": bool(meta_p.get("isApplication")),
                        "foreground": bool(meta_p.get("foregroundRunning")),
                        "rx_bytes": rx_bytes,
                        "tx_bytes": tx_bytes,
                        "total_bytes": int(stats.get("net.bytes", rx_bytes + tx_bytes) or 0),
                        "rx_bytes_delta": rx_delta,
                        "tx_bytes_delta": tx_delta,
                        "rx_packets": int(stats.get("net.rx.packets", 0) or 0),
                        "tx_packets": int(stats.get("net.tx.packets", 0) or 0),
                    }
                )
            rows.sort(
                key=lambda r: (
                    -(r["rx_bytes_delta"] + r["tx_bytes_delta"]),
                    -r["total_bytes"],
                    not r["is_app"],
                    r["pid"],
                )
            )
            return {
                "ok": True,
                "kind": "network",
                "mode": "dvt_network_statistics",
                "pcapd_fallback_reason": str(pcap_err),
                "interfaces": interfaces,
                "count": len(rows[:limit]),
                "processes": rows[:limit],
            }

    if kind_l == "summary":
        dev_info_data: dict[str, Any] = {}
        batt: dict[str, Any] = {}
        procs: list[dict[str, Any]] = []
        dev_mode = False
        dvt_ready = False
        dvt_hint = ""
        with suppress(Exception):
            dev_mode = bool(await rsd.get_developer_mode_status())
        with suppress(Exception):
            batt = await DiagnosticsService(lockdown=rsd).get_battery()
        try:
            async with DvtProvider(rsd) as dvt:
                dvt_ready = True
                with suppress(Exception):
                    async with DeviceInfo(dvt) as di:
                        dev_info_data = await di.hardware_information()
                        procs = await di.proclist()
        except Exception as dvt_err:
            dvt_hint = f"DVT unavailable ({dvt_err}). Enable Developer Mode on device."
        app_procs = [p for p in procs if p.get("isApplication")]
        return {
            "ok": True,
            "kind": "summary",
            "udid": rsd.udid,
            "product_type": rsd.product_type,
            "product_version": rsd.product_version,
            "developer_mode": dev_mode,
            "dvt_ready": dvt_ready,
            "dvt_hint": dvt_hint,
            "hardware": dev_info_data,
            "battery": batt,
            "running_apps": app_procs[:30],
        }

    if kind_l == "processes":
        async with DvtProvider(rsd) as dvt:
            async with DeviceInfo(dvt) as di:
                procs = await di.proclist()
            sysmon_map: dict[int, dict[str, Any]] = {}
            with suppress(Exception):
                sysmontap = await Sysmontap.create(dvt)
                async with sysmontap as sm:
                    sample_idx = 0
                    async for snapshot in sm.iter_processes():
                        sample_idx += 1
                        if sample_idx == 1:
                            continue
                        for rec in snapshot:
                            if isinstance(rec, dict) and rec.get("pid") is not None:
                                sysmon_map[int(rec["pid"])] = rec
                        break
        merged: list[dict[str, Any]] = []
        for p in procs:
            pid = int(p.get("pid", 0))
            sm = sysmon_map.get(pid, {})
            item = {
                "pid": pid,
                "name": p.get("name"),
                "bundle_id": p.get("bundleIdentifier") or "",
                "is_app": bool(p.get("isApplication")),
                "cpu_usage": sm.get("cpuUsage"),
                "phys_footprint_mb": round(sm["physFootprint"] / (1024 * 1024), 1)
                if isinstance(sm.get("physFootprint"), (int, float))
                else None,
                "foreground": p.get("foregroundRunning"),
            }
            if filter_text:
                ft = filter_text.lower()
                if ft not in str(item["name"]).lower() and ft not in item["bundle_id"].lower():
                    continue
            merged.append(item)
        merged.sort(key=lambda x: (not x["is_app"], -(x["phys_footprint_mb"] or 0.0), x["pid"]))
        return {"ok": True, "kind": "processes", "total": len(merged), "processes": merged[:limit]}

    if kind_l == "oslog":
        logs: list[dict[str, Any]] = []
        deadline = time.monotonic() + min(max(duration_s, 0.5), 6.0)
        async with DvtProvider(rsd) as dvt, ActivityTraceTap(dvt) as tap:
            async def _collect():
                async for msg in tap:
                    line = {
                        "ts": str(getattr(msg, "device_time", None) or datetime.now(timezone.utc).isoformat()),
                        "pid": getattr(msg, "process", None),
                        "subsystem": getattr(msg, "subsystem", ""),
                        "category": getattr(msg, "category", ""),
                        "image": os.path.basename(getattr(msg, "sender_image_path", "") or ""),
                        "msg": str(getattr(msg, "name", None) or getattr(msg, "format_string", None) or ""),
                    }
                    if filter_text:
                        ft = filter_text.lower()
                        hay = f"{line['subsystem']} {line['category']} {line['image']} {line['msg']}".lower()
                        if ft not in hay:
                            continue
                    logs.append(line)
                    if len(logs) >= limit:
                        break
            with suppress(asyncio.TimeoutError):
                await asyncio.wait_for(_collect(), timeout=max(0.5, deadline - time.monotonic()))
        return {"ok": True, "kind": "oslog", "count": len(logs), "logs": logs}

    if kind_l == "accessibility":
        elements: list[dict[str, Any]] = []
        partial = False
        async with AccessibilityAudit(rsd) as service:
            async def _walk():
                async for elem in service.iter_elements():
                    norm = _normalize_ax_element(len(elements), elem.to_dict())
                    if filter_text:
                        ft = filter_text.lower()
                        if ft not in json.dumps(norm, ensure_ascii=False).lower():
                            continue
                    norm["index"] = len(elements)
                    elements.append(norm)
                    if len(elements) >= limit:
                        break
            try:
                await asyncio.wait_for(_walk(), timeout=min(max(duration_s * 3.0, 7.5), 10.0))
            except asyncio.TimeoutError:
                partial = True
            finally:
                with suppress(Exception):
                    await service.set_show_visuals(False)
                    await service.set_app_monitoring_enabled(False)
        return {
            "ok": True,
            "kind": "accessibility",
            "partial": partial,
            "count": len(elements),
            "elements": elements,
        }

    if kind_l == "dvt_launch":
        if not filter_text:
            raise ValueError("Bundle ID required in --filter for dvt_launch")
        async with DvtProvider(rsd) as dvt, ProcessControl(dvt) as pc:
            pid = await pc.launch(bundle_id=filter_text)
        return {"ok": True, "kind": "dvt_launch", "bundle_id": filter_text, "pid": pid}

    if kind_l == "dvt_kill":
        if not filter_text or not filter_text.isdigit():
            raise ValueError("Numeric PID required in --filter for dvt_kill")
        pid = int(filter_text)
        async with DvtProvider(rsd) as dvt, ProcessControl(dvt) as pc:
            await pc.kill(pid)
        return {"ok": True, "kind": "dvt_kill", "pid": pid}

    if kind_l == "screenshot":
        OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
        target = Path(out_path or str(OUTPUT_DIR / "grogu_dvt.png"))
        target.parent.mkdir(parents=True, exist_ok=True)
        async with DvtProvider(rsd) as dvt, Screenshot(dvt) as sc:
            png = await sc.get_screenshot()
        target.write_bytes(png)
        return {"ok": True, "kind": "screenshot", "local_path": str(target), "size_bytes": len(png)}

    raise ValueError(f"Unsupported telemetry kind: {kind}")


async def cmd_telemetry(
    host: str,
    kind: str,
    filter_text: str = "",
    limit: int = 80,
    duration_s: float = 2.5,
    out_path: str = "",
) -> dict[str, Any]:
    info = _find_pairing_records()
    tun = await _open_rsd_tunnel(host, info)
    try:
        rsd = tun.rsd
        assert rsd is not None
        return await _run_telemetry_on_rsd(
            rsd, kind, filter_text=filter_text, limit=limit, duration_s=duration_s, out_path=out_path
        )
    finally:
        await tun.aclose()


def _normalize_ax_element(idx: int, raw: dict[str, Any]) -> dict[str, Any]:
    """Normalize AccessibilityAudit element into structured label/type fields."""
    caption = str(raw.get("caption") or "").strip()
    spoken = str(raw.get("spoken_description") or "").strip()
    label = caption or spoken or str(raw.get("estimated_uid") or "")
    el_type = "AXElement"

    parts = [p.strip() for p in caption.split(",") if p.strip()]
    while len(parts) > 1:
        tail_l = parts[-1].lower()
        if tail_l in _AX_ROLE_MAP:
            el_type = _AX_ROLE_MAP[tail_l]
            parts.pop()
            break
        if tail_l in ("dimmed", "selected", "not enabled"):
            parts.pop()
            continue
        break
    if parts and caption:
        label = ", ".join(parts)

    return {
        "index": idx,
        "type": el_type,
        "label": label,
        "spoken_description": spoken,
        "platform_identifier": raw.get("platform_identifier") or "",
        "estimated_uid": raw.get("estimated_uid") or "",
    }


def _format_nserror(err: Any) -> str:
    if err is None:
        return "Unknown NSError"
    domain = getattr(err, "domain", None)
    code = getattr(err, "code", None)
    user_info = getattr(err, "user_info", None)
    if domain is not None and code is not None:
        desc = ""
        if isinstance(user_info, dict):
            desc = str(user_info.get("NSLocalizedDescription") or user_info.get("NSDebugDescription") or user_info)
        return f"{domain} ({code}): {desc}".strip(": ")
    return str(err)


@dataclass
class _FlexibleTestConfig(TestConfig):
    """TestConfig allowing Frameworks/<name>.framework bundle override for sideloaded IPAs."""

    bundle_relpath: Optional[str] = None

    def to_xctestconfiguration(self, session_identifier: Any, service_provider: Any) -> Any:
        res = super().to_xctestconfiguration(session_identifier, service_provider)
        if self.bundle_relpath and self.runner_app_info:
            res._config["testBundleURL"] = NSURL(None, f"file://{self.runner_app_info['Path']}/{self.bundle_relpath}")
        return res


def _update_status_file(status_file: Path, updates: dict[str, Any]) -> None:
    cur: dict[str, Any] = {}
    if status_file.exists():
        with suppress(Exception):
            cur = json.loads(status_file.read_text(encoding="utf-8"))
    cur.update(updates)
    if cur.get("xctest_error") is None:
        cur.pop("xctest_error", None)
    status_file.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    status_file.write_text(json.dumps(cur, ensure_ascii=False, indent=2), encoding="utf-8")


async def _pipe(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except Exception:
        pass
    finally:
        with suppress(Exception):
            writer.close()


async def cmd_daemon(
    host: str,
    wda_bundle: str,
    forward_port: int,
    rpc_port: int,
    start_xctest: bool,
) -> None:
    info = _find_pairing_records()
    tun = await _open_rsd_tunnel(host, info)
    rsd = tun.rsd
    assert rsd is not None

    # Auto-mount Personalized DDI if testmanagerd is not yet advertised
    services = (rsd.peer_info or {}).get("Services", {})
    if "com.apple.dt.testmanagerd.remote" not in services:
        with suppress(Exception, AlreadyMountedError):
            print("[ddi] Ensuring Personalized Developer Disk Image is mounted...", file=sys.stderr, flush=True)
            await asyncio.wait_for(auto_mount(rsd), timeout=35.0)
            await tun.aclose()
            tun = await _open_rsd_tunnel(host, info)
            rsd = tun.rsd
            assert rsd is not None

    wda_bundle = await _resolve_wda_bundle_id(rsd, wda_bundle)
    rpc_lock = asyncio.Lock()

    STATUS_FILE = STATE_DIR / "rsd_daemon.json"
    STATE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    STATUS_FILE.write_text(
        json.dumps(
            {
                "pid": os.getpid(),
                "udid": rsd.udid,
                "product_version": rsd.product_version,
                "forward_port": forward_port,
                "rpc_port": rpc_port,
                "wda_bundle": wda_bundle,
                "started_at": datetime.now(timezone.utc).isoformat(),
            },
            indent=2,
        ),
        encoding="utf-8",
    )

    async def handle_wda_forward(local_reader: asyncio.StreamReader, local_writer: asyncio.StreamWriter) -> None:
        try:
            remote_conn = await rsd.create_service_connection(8100)
            t1 = asyncio.create_task(_pipe(local_reader, remote_conn.writer))
            t2 = asyncio.create_task(_pipe(remote_conn.reader, local_writer))
            await asyncio.gather(t1, t2, return_exceptions=True)
        except Exception:
            with suppress(Exception):
                local_writer.close()

    async def handle_rpc(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            line = await asyncio.wait_for(reader.readline(), timeout=5.0)
            if not line:
                return
            req = json.loads(line.decode("utf-8"))
            async with rpc_lock:
                res = await _run_telemetry_on_rsd(
                    rsd,
                    str(req.get("kind") or "summary"),
                    filter_text=str(req.get("filter_text") or ""),
                    limit=int(req.get("limit", 80)),
                    duration_s=float(req.get("duration_s", 2.5)),
                    out_path=str(req.get("out_path") or ""),
                )
            writer.write((json.dumps(res, ensure_ascii=False, default=_json_default) + "\n").encode("utf-8"))
            await writer.drain()
        except Exception as exc:
            with suppress(Exception):
                msg = f"{type(exc).__name__}: {exc}".rstrip(": ")
                err = json.dumps({"ok": False, "error": msg}, ensure_ascii=False) + "\n"
                writer.write(err.encode("utf-8"))
                await writer.drain()
        finally:
            with suppress(Exception):
                writer.close()

    wda_server = await asyncio.start_server(handle_wda_forward, "127.0.0.1", forward_port)
    rpc_server = await asyncio.start_server(handle_rpc, "127.0.0.1", rpc_port)

    class _QuietListener(XCUITestListener):
        def __init__(self) -> None:
            self.bootstrap_error: Optional[str] = None

        async def did_fail_to_bootstrap(self, error: Any) -> None:
            self.bootstrap_error = _format_nserror(error)
            print(f"[wda] did_fail_to_bootstrap: {self.bootstrap_error}", file=sys.stderr, flush=True)

        async def initialization_for_ui_testing_did_fail(self, error: Any) -> None:
            self.bootstrap_error = _format_nserror(error)
            print(f"[wda] ui_testing_init_failed: {self.bootstrap_error}", file=sys.stderr, flush=True)

        def _emit_log(self, message: str) -> None:
            low = message.lower()
            if any(tok in low for tok in ("serverurlhere", "listening", "didfail", "error", "fail")):
                print(f"[wda] {message}", file=sys.stderr, flush=True)

        async def log_message(self, message: str) -> None:
            self._emit_log(message)

        async def log_debug_message(self, message: str) -> None:
            self._emit_log(message)

    async def _xctest_supervisor() -> None:
        preferred_fw_rel: Optional[str] = None
        while True:
            bundle = await _resolve_wda_bundle_id(rsd, wda_bundle)
            listener = _QuietListener()
            base_cfg: Optional[TestConfig] = None
            _update_status_file(STATUS_FILE, {"xctest_error": None, "wda_bundle": bundle})
            try:
                base_cfg = await TestConfig.create_for(rsd, runner_bundle_id=bundle)
                if preferred_fw_rel:
                    run_cfg: TestConfig = _FlexibleTestConfig(
                        runner_app_info=base_cfg.runner_app_info,
                        runner_app_env=base_cfg.runner_app_env,
                        runner_app_args=base_cfg.runner_app_args,
                        bundle_relpath=preferred_fw_rel,
                    )
                    print(f"[wda] starting XCUITestService for {bundle} ({preferred_fw_rel})", file=sys.stderr, flush=True)
                else:
                    run_cfg = base_cfg
                    print(f"[wda] starting XCUITestService for {bundle}", file=sys.stderr, flush=True)
                await XCUITestService(rsd).run(run_cfg, listener=listener)
                if listener.bootstrap_error:
                    raise RuntimeError(listener.bootstrap_error)
                print("[wda] XCUITestService exited cleanly; restarting in 6s", file=sys.stderr, flush=True)
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                err_msg = listener.bootstrap_error or str(exc)
                if listener.bootstrap_error and base_cfg is not None and not preferred_fw_rel:
                    exec_name = str(base_cfg.runner_app_info.get("CFBundleExecutable") or "")
                    if exec_name.endswith("-Runner"):
                        fw_rel = f"Frameworks/{exec_name[:-len('-Runner')]}.framework"
                        print(f"[wda] .xctest bootstrap failed ({err_msg}); trying {fw_rel}", file=sys.stderr, flush=True)
                        fw_listener = _QuietListener()
                        try:
                            fw_cfg = _FlexibleTestConfig(
                                runner_app_info=base_cfg.runner_app_info,
                                runner_app_env=base_cfg.runner_app_env,
                                runner_app_args=base_cfg.runner_app_args,
                                bundle_relpath=fw_rel,
                            )
                            await XCUITestService(rsd).run(fw_cfg, listener=fw_listener)
                            if fw_listener.bootstrap_error:
                                raise RuntimeError(fw_listener.bootstrap_error)
                            preferred_fw_rel = fw_rel
                            print("[wda] Frameworks WDA exited cleanly; restarting in 6s", file=sys.stderr, flush=True)
                            await asyncio.sleep(6.0)
                            continue
                        except asyncio.CancelledError:
                            raise
                        except Exception as fw_exc:
                            if fw_listener.bootstrap_error is None:
                                preferred_fw_rel = fw_rel
                                print(
                                    f"[wda] Frameworks WDA disconnected ({fw_exc}); retrying {fw_rel} in 6s",
                                    file=sys.stderr,
                                    flush=True,
                                )
                                await asyncio.sleep(6.0)
                                continue
                            err_msg = fw_listener.bootstrap_error
                    _update_status_file(STATUS_FILE, {"xctest_error": err_msg})
                    print(
                        f"[wda] Both .xctest and .framework bootstrap failed ({err_msg}). "
                        "Build & install a repackaged IPA via `grogu-prepare-wda-ipa`, then restart grogu-worker; "
                        "keeping telemetry RPC and WDA port relay alive.",
                        file=sys.stderr,
                        flush=True,
                    )
                    return
                elif listener.bootstrap_error and preferred_fw_rel:
                    _update_status_file(STATUS_FILE, {"xctest_error": err_msg})
                    print(
                        f"[wda] Bootstrap failed on {preferred_fw_rel} ({err_msg}); "
                        "keeping telemetry RPC and WDA port relay alive.",
                        file=sys.stderr,
                        flush=True,
                    )
                    return
                print(f"[wda] XCUITestService error: {err_msg}; retrying in 6s", file=sys.stderr, flush=True)
            await asyncio.sleep(6.0)

    xctest_task: Optional[asyncio.Task[None]] = None
    if start_xctest:
        xctest_task = asyncio.create_task(_xctest_supervisor(), name="wda-supervisor")

    try:
        async with wda_server, rpc_server:
            await asyncio.gather(wda_server.serve_forever(), rpc_server.serve_forever())
    finally:
        if xctest_task:
            xctest_task.cancel()
            with suppress(asyncio.CancelledError):
                await xctest_task
        with suppress(Exception):
            STATUS_FILE.unlink()
        await tun.aclose()


def main() -> None:
    parser = argparse.ArgumentParser(description="Grogu pymobiledevice3 Tailscale worker")
    parser.add_argument("--host", default=DEVICE_IP)
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("probe")
    sub.add_parser("reveal-dev-mode")

    p_tel = sub.add_parser("telemetry")
    p_tel.add_argument("kind")
    p_tel.add_argument("--filter", dest="filter_text", default="")
    p_tel.add_argument("--limit", type=int, default=80)
    p_tel.add_argument("--duration", type=float, default=2.5)
    p_tel.add_argument("--out", default="")

    p_daemon = sub.add_parser("daemon")
    p_daemon.add_argument("--wda-bundle", default=DEFAULT_WDA_BUNDLE_ID)
    p_daemon.add_argument("--forward-port", type=int, default=18832)
    p_daemon.add_argument("--rpc-port", type=int, default=18833)
    p_daemon.add_argument("--no-xctest", action="store_true")

    args = parser.parse_args()
    try:
        if args.cmd == "probe":
            res = asyncio.run(cmd_probe(args.host))
            print(json.dumps(res, ensure_ascii=False, default=_json_default))
        elif args.cmd == "reveal-dev-mode":
            res = asyncio.run(cmd_reveal_dev_mode(args.host))
            print(json.dumps(res, ensure_ascii=False, default=_json_default))
        elif args.cmd == "telemetry":
            res = asyncio.run(
                cmd_telemetry(
                    args.host,
                    args.kind,
                    filter_text=args.filter_text,
                    limit=args.limit,
                    duration_s=args.duration,
                    out_path=args.out,
                )
            )
            print(json.dumps(res, ensure_ascii=False, default=_json_default))
        elif args.cmd == "daemon":
            asyncio.run(
                cmd_daemon(
                    args.host,
                    wda_bundle=args.wda_bundle,
                    forward_port=args.forward_port,
                    rpc_port=args.rpc_port,
                    start_xctest=not args.no_xctest,
                )
            )
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
        sys.exit(1)


if __name__ == "__main__":
    main()
