#!/usr/bin/env python3
"""Upload an animation to the AMG65's 240×135 LCD (cmd 0x72). USB cable only.

Mirrors the Windows app (0x42a1d0 → 0x468650):
  - commands + replies on interface 2 (usage page 0xFF68, 64-byte reports, via hidapi)
  - image data on interface 3 (usage page 0xFF67, 4096-byte output reports, endpoint 0x06),
    which macOS leaves without a driver, so it is written with libusb.

Image buffer: pre-filled with FF; [0] = frame count, [1+i] = frame i delay in 2 ms units,
frames from offset 256 as 240×135 RGB565, padded to whole 4096-byte blocks.

Usage:
    .venv/bin/python tools/amg65_lcd.py test               # red/green/blue test frames
    .venv/bin/python tools/amg65_lcd.py gif path/to.gif    # upload a GIF (resized to 240×135)
    add --slot N (default 1) and --swap (big-endian RGB565) as needed
"""
import argparse
import sys
import time
from pathlib import Path

import hid
import usb.backend.libusb1
import usb.core
import usb.util
from PIL import Image, ImageSequence

sys.path.insert(0, str(Path(__file__).resolve().parent))
from amg65 import BEGIN, END, WIRED_USAGE_PAGE, hexdump, open_channel, pkt  # noqa: E402

W, H = 240, 135
HEADER = 256
MAX_FRAMES = 130
BLOCK = 4096
BULK_EP = 0x06
LIBUSB = "/opt/homebrew/lib/libusb-1.0.dylib"


def rgb565(img, swap):
    img = img.convert("RGB").resize((W, H))
    out = bytearray()
    for r, g, b in img.get_flattened_data() if hasattr(img, 'get_flattened_data') else img.getdata():
        v = ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)
        out += v.to_bytes(2, "big" if swap else "little")
    return bytes(out)


def build_buffer(frames, delays_ms, swap):
    frames = frames[:MAX_FRAMES]
    size = HEADER + len(frames) * W * H * 2
    blocks = -(-size // BLOCK)
    buf = bytearray(b"\xFF" * (blocks * BLOCK))
    buf[0] = len(frames)
    for i, d in enumerate(delays_ms[:len(frames)]):
        buf[1 + i] = max(1, min(255, d // 2))
    for i, f in enumerate(frames):
        data = rgb565(f, swap)
        buf[HEADER + i * len(data): HEADER + (i + 1) * len(data)] = data
    return bytes(buf), blocks


def test_frames():
    frames = []
    for color in [(255, 0, 0), (0, 255, 0), (0, 0, 255)]:
        img = Image.new("RGB", (W, H), color)
        img.paste((255, 255, 255), (0, 0, 40, 20))       # top-left orientation marker
        frames.append(img)
    return frames, [500, 500, 500]


def gif_frames(path):
    im = Image.open(path)
    frames, delays = [], []
    for f in ImageSequence.Iterator(im):
        frames.append(f.convert("RGB").copy())
        delays.append(int(f.info.get("duration", 100)))
    return frames, delays


def exchange(dev, packet, label):
    dev.write(b"\x00" + packet)
    reply = bytes(dev.read(64, 200) or b"")
    ok = len(reply) > 3 and reply[3] == 0x01
    print(f"{'✓' if ok else '✗'} {label}: {hexdump(reply[:6]) if reply else 'no reply'}")
    return ok


def wait_ok(dev, tries=100, timeout=600):
    for _ in range(tries):
        r = bytes(dev.read(64, timeout) or b"")
        if len(r) > 3 and r[3] == 0x01:
            return r
    return None


def upload(buf, blocks, slot):
    header = pkt(0x04, 0x72, slot, at={8: blocks & 0xFF, 9: blocks >> 8})
    return upload_blocks(buf, blocks, header, f"upload header (04 72, slot {slot}, {blocks} blocks)")


def upload_blocks(buf, blocks, header, header_label, apply_after=False):
    """Shared bulk upload: header on interface 2, 4 KB blocks on interface 3, end (+ apply)."""
    be = usb.backend.libusb1.get_backend(find_library=lambda _: LIBUSB)
    udev = usb.core.find(idVendor=0x0C45, idProduct=0x800A, backend=be)
    if udev is None:
        sys.exit("Wired AMG65 not found (needs the USB cable).")
    usb.util.claim_interface(udev, 3)
    hdev = open_channel([WIRED_USAGE_PAGE])
    try:
        while hdev.read(64, 20):
            pass
        if not exchange(hdev, BEGIN, "begin (04 18)"):
            return False
        if not exchange(hdev, header, header_label):
            return False
        t0 = time.time()
        for i in range(blocks):
            while hdev.read(64, 10):          # drain, like the app
                pass
            udev.write(BULK_EP, buf[i * BLOCK:(i + 1) * BLOCK], timeout=2000)
            time.sleep(0.005)
            r = wait_ok(hdev)
            if r is None:
                print(f"✗ block {i + 1}/{blocks}: no OK reply")
                return False
            if i == 0:
                print(f"✓ block 1 acknowledged: {hexdump(r[:6])}")
                time.sleep(0.5)
            elif (i + 1) % 10 == 0 or i + 1 == blocks:
                print(f"  {i + 1}/{blocks} blocks ({time.time() - t0:.1f}s)")
        ok = exchange(hdev, END, "end (04 02)")
        if ok and apply_after:
            ok = exchange(hdev, pkt(0x04, 0xF0), "apply (04 F0)")
        return ok
    finally:
        hdev.close()
        usb.util.release_interface(udev, 3)
        usb.util.dispose_resources(udev)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("what", choices=["test", "gif"])
    ap.add_argument("path", nargs="?")
    ap.add_argument("--slot", type=int, default=1)
    ap.add_argument("--swap", action="store_true", help="send RGB565 big-endian")
    a = ap.parse_args()
    frames, delays = test_frames() if a.what == "test" else gif_frames(a.path)
    buf, blocks = build_buffer(frames, delays, a.swap)
    print(f"{len(frames[:MAX_FRAMES])} frames → {len(buf)} bytes, {blocks} blocks; header {hexdump(buf[:8])}")
    ok = upload(buf, blocks, a.slot)
    print("RESULT:", "OK" if ok else "FAILED")
    return 0 if ok else 2


if __name__ == "__main__":
    sys.exit(main())
