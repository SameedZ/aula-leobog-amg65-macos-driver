#!/usr/bin/env python3
"""Upload an animation to the AMG65's dot-matrix LED strip (63 × 5 RGB). USB cable only.

Mirrors the Windows app: 0x434970 (cmd 0x33, animation, ≤260 frames) and 0x434410
(cmd 0x31, boot animation, ≤200 frames). Data goes over interface 3 like the LCD upload.

Buffer: [0..1] frame count (LE) [2..3] frame delay word (app: 0x66 − speed, default 0x50)
        then frames × 315 LEDs × 3 bytes (R, G, B) at 4 + 3 × (frame × 315 + POS[pixel]),
        AA 55 right after the last frame; padded with 00 to whole 4096-byte blocks.
POS maps a row-major 63 × 5 picture to the strip's wiring (4 panels of 14 × 5, one of 7 × 5).

Usage:
    .venv/bin/python tools/amg65_strip.py test            # still test frame
    .venv/bin/python tools/amg65_strip.py gif anim.gif    # any GIF, scaled to 63 × 5
    options: --boot (cmd 0x31) --delay N
"""
import argparse
import sys
from pathlib import Path

from PIL import Image, ImageSequence

sys.path.insert(0, str(Path(__file__).resolve().parent))
from amg65 import pkt  # noqa: E402
from amg65_lcd import BLOCK, upload_blocks  # noqa: E402

W, H, LEDS = 63, 5, 315


def position_table():
    """Pixel (row-major 63×5) → LED index; equals the app's table at 0x59c7f0."""
    pos = []
    for r in range(H):
        for c in range(W):
            panel, col = divmod(c, 14)
            pos.append(70 * panel + 14 * r + col if panel < 4 else 280 + 7 * r + (c - 56))
    return pos


POS = position_table()


def build(frames, delay):
    n = len(frames)
    size = 4 + n * LEDS * 3
    blocks = -(-(size + 2) // BLOCK)
    buf = bytearray(blocks * BLOCK)
    buf[0], buf[1] = n & 0xFF, n >> 8
    buf[2], buf[3] = delay & 0xFF, delay >> 8
    for f, img in enumerate(frames):
        px = list(img.convert("RGB").resize((W, H), Image.NEAREST).getdata())
        for i, (r, g, b) in enumerate(px):
            o = 4 + 3 * (f * LEDS + POS[i])
            buf[o:o + 3] = bytes((r, g, b))
    end = 4 + n * LEDS * 3
    buf[end], buf[end + 1] = 0xAA, 0x55
    return bytes(buf), blocks


def test_frame():
    img = Image.new("RGB", (W, H))
    for x in range(W):
        for y in range(H):
            img.putpixel((x, y), (255, 0, 0) if x < 21 else (0, 255, 0) if x < 42 else (0, 0, 255))
    for x in range(W):
        img.putpixel((x, 0), (255, 255, 255))      # top row white
    for y in range(H):
        img.putpixel((0, y), (255, 255, 255))      # left column white
    return [img]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("what", choices=["test", "gif"])
    ap.add_argument("path", nargs="?")
    ap.add_argument("--boot", action="store_true", help="boot animation (cmd 0x31) instead of 0x33")
    ap.add_argument("--delay", type=int, default=0x50)
    a = ap.parse_args()
    frames = test_frame() if a.what == "test" else [f.copy() for f in ImageSequence.Iterator(Image.open(a.path))]
    frames = frames[:200 if a.boot else 260]
    buf, blocks = build(frames, a.delay)
    cmd = 0x31 if a.boot else 0x33
    print(f"{len(frames)} frame(s) → {blocks} block(s); header {buf[:4].hex(' ')}")
    header = pkt(0x04, cmd, at={8: blocks & 0xFF, 9: blocks >> 8})
    ok = upload_blocks(buf, blocks, header, f"strip header (04 {cmd:02X}, {blocks} blocks)", apply_after=True)
    print("RESULT:", "OK" if ok else "FAILED")
    return 0 if ok else 2


if __name__ == "__main__":
    sys.exit(main())
