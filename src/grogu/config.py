"""Environment-driven runtime configuration for Grogu."""

from __future__ import annotations

import os
from pathlib import Path


def _env(key: str, default: str) -> str:
    val = os.environ.get(key)
    return val.strip() if val and val.strip() else default


def _env_int(key: str, default: int) -> int:
    val = os.environ.get(key)
    if val and val.strip():
        return int(val.strip())
    return default


def resolve_pmd_python() -> str:
    explicit = os.environ.get("GROGU_PMD_PYTHON", "").strip()
    if explicit:
        return explicit
    uv_cand = Path.home() / ".local" / "share" / "uv" / "tools" / "pymobiledevice3" / "bin" / "python"
    if uv_cand.exists():
        return str(uv_cand)
    return os.sys.executable


DEVICE_IP: str = _env("GROGU_DEVICE_IP", "100.64.0.10")
BIND_HOST: str = _env("GROGU_BIND_HOST", "127.0.0.1")
GATEWAY_PORT: int = _env_int("GROGU_GATEWAY_PORT", 18830)
MCP_HTTP_PORT: int = _env_int("GROGU_MCP_HTTP_PORT", 18831)
WDA_FORWARD_PORT: int = _env_int("GROGU_WDA_FORWARD_PORT", 18832)
RSD_RPC_PORT: int = _env_int("GROGU_RSD_RPC_PORT", 18833)
MAC_TAILSCALE_IP: str = _env("GROGU_MAC_TAILSCALE_IP", "100.64.0.20")
DEFAULT_WDA_BUNDLE_ID: str = _env("GROGU_WDA_BUNDLE_ID", "com.facebook.WebDriverAgentRunner.xctrunner")

STATE_DIR: Path = Path(_env("GROGU_STATE_DIR", str(Path.home() / ".config" / "grogu"))).expanduser()
PAIRING_DIR: Path = Path(_env("GROGU_PAIRING_DIR", str(Path.home() / ".pymobiledevice3"))).expanduser()
OUTPUT_DIR: Path = Path(_env("GROGU_OUTPUT_DIR", "/tmp/grogu")).expanduser()
SSH_PUBKEY_PATH: Path = Path(_env("GROGU_SSH_PUBKEY_PATH", str(Path.home() / ".ssh" / "id_ed25519.pub"))).expanduser()
SSH_CONFIG_PATH: Path = Path(_env("GROGU_SSH_CONFIG_PATH", str(Path.home() / ".ssh" / "config"))).expanduser()
