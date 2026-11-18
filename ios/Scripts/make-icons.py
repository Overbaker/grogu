#!/usr/bin/env python3
"""Generate clean minimalist Grogu icons using pure Python stdlib (no Pillow required)."""

from __future__ import annotations

import math
from pathlib import Path
import struct
import zlib

IOS_ROOT = Path(__file__).resolve().parent.parent


def _png_chunk(tag: bytes, data: bytes) -> bytes:
    crc = zlib.crc32(tag + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)


def _render_rgb_icon(size: int) -> bytes:
    rows = bytearray()
    cx = (size - 1) * 0.5
    cy = (size - 1) * 0.5
    outer_r = size * 0.30
    inner_r = size * 0.16

    for y in range(size):
        rows.append(0)  # PNG filter type 0
        dy = y - cy
        for x in range(size):
            dx = x - cx
            dist = math.hypot(dx, dy)
            t_bg = (x + y) / max(1.0, 2.0 * (size - 1))
            r = int(14 + 10 * t_bg)
            g = int(28 + 20 * t_bg)
            b = int(32 + 22 * t_bg)

            if dist <= outer_r:
                edge = max(0.0, min(1.0, (outer_r - dist) / max(1.0, size * 0.02)))
                if dist <= inner_r:
                    # Bright sage-teal core
                    tr, tg, tb = 48, 206, 184
                else:
                    # Translucent ring halo
                    tr, tg, tb = 30, 146, 134
                r = int(r * (1.0 - edge) + tr * edge)
                g = int(g * (1.0 - edge) + tg * edge)
                b = int(b * (1.0 - edge) + tb * edge)

            rows.extend((r, g, b))

    ihdr = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
    idat = zlib.compress(bytes(rows), level=9)
    return b"\x89PNG\r\n\x1a\n" + _png_chunk(b"IHDR", ihdr) + _png_chunk(b"IDAT", idat) + _png_chunk(b"IEND", b"")


def main() -> None:
    appicon_dir = IOS_ROOT / "GroguApp/Assets.xcassets/AppIcon.appiconset"
    appicon_dir.mkdir(parents=True, exist_ok=True)
    (IOS_ROOT / "GroguApp/Assets.xcassets/Contents.json").write_text(
        '{"info":{"author":"xcode","version":1}}\n', encoding="utf-8"
    )
    (appicon_dir / "Contents.json").write_text(
        '{"images":[{"filename":"icon_1024x1024.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}\n',
        encoding="utf-8",
    )
    (appicon_dir / "icon_1024x1024.png").write_bytes(_render_rgb_icon(1024))

    runner_dir = IOS_ROOT / "Config/RunnerIcon"
    runner_dir.mkdir(parents=True, exist_ok=True)
    specs = [
        ("AppIcon20x20@2x.png", 40),
        ("AppIcon20x20@3x.png", 60),
        ("AppIcon29x29@2x.png", 58),
        ("AppIcon29x29@3x.png", 87),
        ("AppIcon40x40@2x.png", 80),
        ("AppIcon40x40@3x.png", 120),
        ("AppIcon60x60@2x.png", 120),
        ("AppIcon60x60@3x.png", 180),
        ("AppIcon20x20~ipad.png", 20),
        ("AppIcon20x20@2x~ipad.png", 40),
        ("AppIcon29x29~ipad.png", 29),
        ("AppIcon29x29@2x~ipad.png", 58),
        ("AppIcon40x40~ipad.png", 40),
        ("AppIcon40x40@2x~ipad.png", 80),
        ("AppIcon76x76~ipad.png", 76),
        ("AppIcon76x76@2x~ipad.png", 152),
        ("AppIcon83.5x83.5@2x~ipad.png", 167),
    ]
    for name, px in specs:
        (runner_dir / name).write_bytes(_render_rgb_icon(px))
    print(f"Generated GroguApp and {len(specs)} GroguRunner icons cleanly.")


if __name__ == "__main__":
    main()
