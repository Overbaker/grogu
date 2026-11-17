#!/usr/bin/env python3
"""Idempotent patcher that injects FBGroguCommands.{h,m} into an appium/WebDriverAgent checkout."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import shutil
import sys


def _oid(seed: str) -> str:
    return hashlib.sha1(seed.encode("utf-8")).hexdigest()[:24].upper()


def patch_wda(wda_repo: Path) -> None:
    patch_dir = Path(__file__).resolve().parent
    commands_dir = wda_repo / "WebDriverAgentLib" / "Commands"
    pbxproj = wda_repo / "WebDriverAgent.xcodeproj" / "project.pbxproj"

    if not commands_dir.is_dir() or not pbxproj.is_file():
        raise FileNotFoundError(f"{wda_repo} does not look like an appium/WebDriverAgent checkout")

    for fname in ("FBGroguCommands.h", "FBGroguCommands.m"):
        shutil.copy2(patch_dir / fname, commands_dir / fname)

    text = pbxproj.read_text(encoding="utf-8")
    if "FBGroguCommands.m" in text:
        print("project.pbxproj already registers FBGroguCommands.m")
        return

    h_ref = _oid("grogu_FBGroguCommands.h_fileref")
    m_ref = _oid("grogu_FBGroguCommands.m_fileref")
    h_build = _oid("grogu_FBGroguCommands.h_buildfile")
    m_build = _oid("grogu_FBGroguCommands.m_buildfile")

    text = text.replace(
        "/* Begin PBXBuildFile section */\n",
        "/* Begin PBXBuildFile section */\n"
        f"\t\t{h_build} /* FBGroguCommands.h in Headers */ = {{isa = PBXBuildFile; fileRef = {h_ref} /* FBGroguCommands.h */; settings = {{ATTRIBUTES = (Public, ); }}; }};\n"
        f"\t\t{m_build} /* FBGroguCommands.m in Sources */ = {{isa = PBXBuildFile; fileRef = {m_ref} /* FBGroguCommands.m */; }};\n",
        1,
    )

    text = text.replace(
        "/* Begin PBXFileReference section */\n",
        "/* Begin PBXFileReference section */\n"
        f"\t\t{h_ref} /* FBGroguCommands.h */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = FBGroguCommands.h; sourceTree = \"<group>\"; }};\n"
        f"\t\t{m_ref} /* FBGroguCommands.m */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.c.objc; path = FBGroguCommands.m; sourceTree = \"<group>\"; }};\n",
        1,
    )

    anchor = "FBCustomCommands.h */,"
    if anchor not in text:
        raise RuntimeError("Could not locate FBCustomCommands.h in project.pbxproj Commands group")
    text = text.replace(
        anchor,
        f"{anchor}\n\t\t\t\t{h_ref} /* FBGroguCommands.h */,\n\t\t\t\t{m_ref} /* FBGroguCommands.m */,",
        1,
    )

    text = text.replace(
        "FBCustomCommands.h in Headers */,",
        f"FBCustomCommands.h in Headers */,\n\t\t\t\t{h_build} /* FBGroguCommands.h in Headers */,",
        1,
    )
    text = text.replace(
        "FBCustomCommands.m in Sources */,",
        f"FBCustomCommands.m in Sources */,\n\t\t\t\t{m_build} /* FBGroguCommands.m in Sources */,",
        1,
    )

    pbxproj.write_text(text, encoding="utf-8")
    print(f"Successfully patched FBGroguCommands into {wda_repo}")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("wda_repo", type=Path)
    args = p.parse_args()
    try:
        patch_wda(args.wda_repo)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
