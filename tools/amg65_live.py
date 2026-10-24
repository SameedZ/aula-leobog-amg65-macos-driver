#!/usr/bin/env python3
"""Push live frames to the LED strip (cmd 0x35, decoded from 0x434ed0). USB cable only.

One frame: 04 18 · 04 35 [8]=15 · 15 × 64-byte data packets (945 bytes = 315 LEDs × RGB,
placed through the strip wiring table, then AA 55) · 04 02.  Each packet is acknowledged.

    .venv/bin/python tools/amg65_live.py text LIVE        # one still frame
    .venv/bin/python tools/amg65_live.py bench            # frames-per-second test (5 s)
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from amg65 import BEGIN, END, WIRED_USAGE_PAGE, drain, open_channel, pkt  # noqa: E402
from amg65_strip import LEDS, POS, W  # noqa: E402

FONT = {  # 3×5, rows top→bottom
    "L": ["100", "100", "100", "100", "111"], "I": ["111", "010", "010", "010", "111"],
    "V": ["101", "101", "101", "101", "010"], "E": ["111", "100", "110", "100", "111"],
}


def frame_from_pixels(px):
    """px: 315 (r,g,b) row-major → 960-byte payload (15 packets)."""
    buf = bytearray(960)
    for i, (r, g, b) in enumerate(px):
        o = 3 * POS[i]
        buf[o:o + 3] = bytes((r, g, b))
    buf[945], buf[946] = 0xAA, 0x55
    return buf


def text_pixels(text, color, x0=2):
    px = [(0, 0, 0)] * LEDS
    x = x0
    for ch in text:
        for y, row in enumerate(FONT.get(ch, ["000"] * 5)):
            for c, bit in enumerate(row):
                if bit == "1" and x + c < W:
                    px[y * W + x + c] = color
        x += 4
    return px


def send_frame(dev, payload):
    packets = [BEGIN, pkt(0x04, 0x35, at={8: 15})] + [bytes(payload[i:i + 64]) for i in range(0, 960, 64)] + [END]
    for p in packets:
        dev.write(b"\x00" + p)
        r = bytes(dev.read(64, 200) or b"")
        if len(r) < 4 or r[3] != 0x01:
            return False
    return True


def main():
    dev = open_channel([WIRED_USAGE_PAGE])
    if not dev:
        sys.exit("Wired AMG65 not found (needs the USB cable).")
    drain(dev)
    try:
        if sys.argv[1] == "text":
            ok = send_frame(dev, frame_from_pixels(text_pixels(sys.argv[2].upper(), (255, 0, 200))))
            print("RESULT:", "OK" if ok else "FAILED")
        else:
            n, t0 = 0, time.time()
            while time.time() - t0 < 5:
                x = n % W
                px = [(0, 0, 0)] * LEDS
                for y in range(5):
                    px[y * W + x] = (0, 255, 120)       # a bar sweeping left → right
                if not send_frame(dev, frame_from_pixels(px)):
                    print("frame failed"); break
                n += 1
            print(f"{n} frames in {time.time() - t0:.1f}s → {n / (time.time() - t0):.1f} fps")
    finally:
        dev.close()


if __name__ == "__main__":
    main()
