#!/usr/bin/env python3
"""
Repackage WebDriverAgentRunner-Runner.app into a sideloader-compatible .ipa.

Free-account sideloaders using `apple-codesign` (Impactor / AltStore / SideStore / plumesign)
often skip code-signing `PlugIns/*.xctest` bundles, causing iOS dyld to reject the test
bundle at launch with `NSCocoaErrorDomain 3588: mapped file has no cdhash`.

Moving `WebDriverAgentLib.framework` and converting `PlugIns/WebDriverAgentRunner.xctest` into
`Frameworks/WebDriverAgentRunner.framework` (with `CFBundlePackageType = "FMWK"`, while deleting
`.dSYM` debug folders) makes every Mach-O binary discoverable by sideloading signers while
preserving `@executable_path/Frameworks` rpath resolution and `XCTestService` compatibility.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import plistlib
import shutil
import tempfile
import urllib.request
import zipfile

DEFAULT_WDA_ZIP_URL = (
    "https://github.com/appium/WebDriverAgent/releases/latest/download/WebDriverAgentRunner-Runner.zip"
)


def _extract_input_app(src: Path, work_dir: Path) -> Path:
    """Locate or extract `*.app` from an .app directory or .zip/.ipa archive."""
    if src.is_dir():
        if src.suffix == ".app":
            dest = work_dir / "Payload" / src.name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(src, dest, symlinks=True)
            return dest
        cands = list(src.glob("*.app")) + list((src / "Payload").glob("*.app") if (src / "Payload").is_dir() else [])
        if not cands:
            raise FileNotFoundError(f"No .app bundle found inside directory {src}")
        dest = work_dir / "Payload" / cands[0].name
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(cands[0], dest, symlinks=True)
        return dest

    extract_root = work_dir / "extracted"
    extract_root.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(src, "r") as zf:
        for info in zf.infolist():
            zf.extract(info, extract_root)
            target = extract_root / info.filename
            unix_mode = (info.external_attr >> 16) & 0o777
            if unix_mode and target.exists() and not target.is_dir():
                os.chmod(target, unix_mode)

    cands = list(extract_root.glob("*.app")) + list((extract_root / "Payload").glob("*.app"))
    if not cands:
        raise FileNotFoundError(f"No .app bundle found inside archive {src}")
    app_dir = cands[0]
    payload_app = work_dir / "Payload" / app_dir.name
    payload_app.parent.mkdir(parents=True, exist_ok=True)
    if app_dir.resolve() != payload_app.resolve():
        shutil.move(str(app_dir), str(payload_app))
    return payload_app


def _ensure_executable_bits(app_dir: Path) -> None:
    """Ensure every bundle CFBundleExecutable file carries Unix executable bits."""
    for plist_path in app_dir.rglob("Info.plist"):
        try:
            info = plistlib.loads(plist_path.read_bytes())
        except Exception:
            continue
        exe_name = info.get("CFBundleExecutable")
        if not isinstance(exe_name, str) or not exe_name:
            continue
        exe_path = plist_path.parent / exe_name
        if exe_path.is_file():
            mode = exe_path.stat().st_mode
            os.chmod(exe_path, mode | 0o755)


def prepare_sideload_ipa(src_path: Path, out_ipa: Path) -> Path:
    """Repackage a WebDriverAgentRunner bundle into a sideloader-compatible .ipa."""
    with tempfile.TemporaryDirectory(prefix="grogu_wda_prep_") as tmp:
        work_dir = Path(tmp)
        app_dir = _extract_input_app(src_path, work_dir)
        plugins_dir = app_dir / "PlugIns"
        frameworks_dir = app_dir / "Frameworks"

        if plugins_dir.is_dir():
            for dsym in list(plugins_dir.glob("*.dSYM")):
                shutil.rmtree(dsym)

            for xctest_dir in sorted(plugins_dir.glob("*.xctest")):
                nested_fw = xctest_dir / "Frameworks"
                if nested_fw.is_dir():
                    frameworks_dir.mkdir(parents=True, exist_ok=True)
                    for fw in sorted(nested_fw.iterdir()):
                        dest_fw = frameworks_dir / fw.name
                        if dest_fw.exists():
                            shutil.rmtree(dest_fw)
                        shutil.move(str(fw), str(dest_fw))
                    with open(os.devnull, "w"):
                        pass
                    if not any(nested_fw.iterdir()):
                        nested_fw.rmdir()

                frameworks_dir.mkdir(parents=True, exist_ok=True)
                target_fw = frameworks_dir / f"{xctest_dir.stem}.framework"
                if target_fw.exists():
                    shutil.rmtree(target_fw)
                shutil.move(str(xctest_dir), str(target_fw))

                plist_path = target_fw / "Info.plist"
                if plist_path.exists():
                    plist_data = plistlib.loads(plist_path.read_bytes())
                    plist_data["CFBundlePackageType"] = "FMWK"
                    plist_path.write_bytes(plistlib.dumps(plist_data))

            if not any(plugins_dir.iterdir()):
                plugins_dir.rmdir()

        _ensure_executable_bits(app_dir)

        payload_dir = work_dir / "Payload"
        out_ipa.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(out_ipa, "w", compression=zipfile.ZIP_DEFLATED) as zf:
            for item in sorted(payload_dir.rglob("*")):
                rel = item.relative_to(work_dir)
                if item.is_dir():
                    zinfo = zipfile.ZipInfo(str(rel) + "/")
                    zinfo.external_attr = (0o40755 << 16) | 0x10
                    zf.writestr(zinfo, b"")
                else:
                    st = item.stat()
                    zinfo = zipfile.ZipInfo(str(rel))
                    zinfo.external_attr = (st.st_mode & 0xFFFF) << 16
                    zf.writestr(zinfo, item.read_bytes(), compress_type=zipfile.ZIP_DEFLATED)

    return out_ipa


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Repackage WebDriverAgentRunner-Runner into a sideloader-compatible .ipa"
    )
    parser.add_argument("--input", "-i", help="Path to WebDriverAgentRunner-Runner.app, .zip, or .ipa")
    parser.add_argument(
        "--download",
        action="store_true",
        help=f"Download latest release zip from {DEFAULT_WDA_ZIP_URL}",
    )
    parser.add_argument(
        "--output",
        "-o",
        default="WebDriverAgentRunner-sideload.ipa",
        help="Output .ipa path",
    )
    args = parser.parse_args()

    out_ipa = Path(args.output).expanduser().resolve()
    with tempfile.TemporaryDirectory(prefix="grogu_wda_dl_") as dl_tmp:
        if args.download:
            dl_zip = Path(dl_tmp) / "WebDriverAgentRunner-Runner.zip"
            urllib.request.urlretrieve(DEFAULT_WDA_ZIP_URL, dl_zip)
            src = dl_zip
        elif args.input:
            src = Path(args.input).expanduser().resolve()
        else:
            raise SystemExit("Pass either --input <path> or --download")

        result = prepare_sideload_ipa(src, out_ipa)
        print(f"Prepared sideloader-compatible WDA IPA: {result}")


if __name__ == "__main__":
    main()
