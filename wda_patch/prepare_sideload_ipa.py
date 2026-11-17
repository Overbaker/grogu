#!/usr/bin/env python3
"""Wrapper delegating to `grogu.prepare_sideload_ipa.main`."""

from __future__ import annotations

from pathlib import Path
import sys

_SRC = Path(__file__).resolve().parent.parent / "src"
if _SRC.is_dir() and str(_SRC) not in sys.path:
    sys.path.insert(0, str(_SRC))

from grogu.prepare_sideload_ipa import main, prepare_sideload_ipa  # noqa: E402, F401

if __name__ == "__main__":
    main()
