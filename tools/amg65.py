#!/usr/bin/env python3
"""AMG65 macOS test tool. See docs/protocol/PROTOCOL.md for protocol details.

Commands:
    list        show the keyboard's HID interfaces (sends nothing)
    handshake   send only begin (04 18) + end (04 02) and print replies
    light       send ONE lighting command (cmd 0x13) over the USB cable

Examples:
    .venv/bin/python tools/amg65.py list
    .venv/bin/python tools/amg65.py handshake
    .venv/bin/python tools/amg65.py light                      # static white
    .venv/bin/python tools/amg65.py light --rgb 255 0 0        # static red
"""
import argparse
import contextlib
import html
import io
import re
import sys
import time
from pathlib import Path

import hid

DEVICES = [
    (0x0C45, 0x800A, "LEOBOG AMG65 (USB cable)"),
    (0x05AC, 0x024F, "AMG65 Dongle (2.4 GHz)"),
]
WIRED_USAGE_PAGE = 0xFF68   # interface 2 on the wired keyboard — confirmed
DONGLE_USAGE_PAGE = 0xFF59  # interface 4 on the dongle — 64-byte, always replies 0F 01 01 11
DONGLE_CMD_PAGE = 0xFF60    # interface 3 on the dongle — 32-byte command channel (confirmed echo)
PACKET_LEN = 64
READ_TIMEOUT_MS = 200       # same as the Windows app


def pkt(*head, at=None):
    """64-byte packet: leading bytes from head, plus {offset: value} from at."""
    buf = bytearray(PACKET_LEN)
    buf[: len(head)] = bytes(head)
    for off, val in (at or {}).items():
        buf[off] = val
    return bytes(buf)


BEGIN = pkt(0x04, 0x18)
END = pkt(0x04, 0x02)
APPLY = pkt(0x04, 0xF0)


def lighting_packets(mode, r, g, b, colortype, brightness, speed, direction):
    """Exact sequence the Windows app sends for a lighting change (0x43b3f0)."""
    header = pkt(0x04, 0x13, at={8: 0x01})          # 1 data packet follows
    data = pkt(mode, r, g, b, at={
        8: colortype, 9: brightness, 10: speed, 11: direction,
        14: 0xAA, 15: 0x55,
    })
    return [
        ("begin (04 18)", BEGIN),
        ("lighting header (04 13)", header),
        ("lighting data", data),
        ("end (04 02)", END),
        ("apply (04 F0)", APPLY),
    ]


def hexdump(data):
    return " ".join(f"{b:02X}" for b in data)


def list_interfaces():
    found = False
    for vid, pid, name in DEVICES:
        for d in hid.enumerate(vid, pid):
            found = True
            print(f"{name}: {vid:04X}:{pid:04X} interface={d['interface_number']} "
                  f"usage_page=0x{d['usage_page']:04X} usage=0x{d['usage']:02X}")
    if not found:
        print("No AMG65 found. Plug in the USB cable or the dongle.")


def open_channel(pages):
    for page in pages:
        for vid, pid, name in DEVICES:
            for d in hid.enumerate(vid, pid):
                if d["usage_page"] == page:
                    dev = hid.device()
                    dev.open_path(d["path"])
                    print(f"Using {name}, interface {d['interface_number']}, usage page 0x{page:04X}")
                    return dev
    return None


def drain(dev):
    n = 0
    while dev.read(PACKET_LEN, 20):
        n += 1
    if n:
        print(f"(discarded {n} stale input report(s))")


def send(dev, label, packet, expect_sum=None):
    """Write one packet and print the reply. Returns True if byte [3] == 0x01.

    expect_sum: for the end packet, the 16-bit sum of the data packet(s); the
    keyboard echoes it little-endian in reply bytes [4..5].
    """
    print(f"\n-> {label}\n   {hexdump(packet[:16])} …")
    written = dev.write(b"\x00" + packet)  # report ID 0 + 64 bytes, like Windows
    if written < 0:
        print(f"   write failed: {dev.error()}")
        return False
    time.sleep(0.002)
    reply = dev.read(PACKET_LEN, READ_TIMEOUT_MS)
    if not reply:
        print(f"<- no reply within {READ_TIMEOUT_MS} ms")
        return False
    reply = bytes(reply)
    status = reply[3]
    meaning = {0x01: "OK", 0xFF: "busy"}.get(status, "unknown")
    print(f"<- {hexdump(reply[:16])} …")
    print(f"   status byte [3] = {status:#04x} → {meaning}")
    if expect_sum is not None:
        got = reply[4] | (reply[5] << 8)
        match = "matches" if got == expect_sum else "MISMATCH"
        print(f"   checksum {got:#06x} (expected {expect_sum:#06x}) → {match}")
        if got != expect_sum:
            return False
    return status == 0x01


# ---- Key remapping (cmd 0x11) -------------------------------------------------

LAYOUT_XML = Path(__file__).resolve().parent.parent / "local/official-driver/extracted/app/KeyboardLayout.xml"


def load_keys():
    """name -> (slot index, HID code) from the original app's layout file."""
    text = LAYOUT_XML.read_bytes().decode("utf-8", "ignore")
    text = text[text.find("<?xml"):]
    keys = {}
    for attrs in re.findall(r"<key ([^/]*)/>", text):
        a = dict(re.findall(r'(\w+)="([^"]*)"', attrs))
        name = html.unescape(a["name"])
        entry = (int(a["key_index"]), int(a["code"], 16), name)
        for alias in {name.lower().replace(" ", ""), name[-1:].lower() if len(name) == 2 else None}:
            if alias:
                keys.setdefault(alias, entry)
    keys.setdefault("/", (74, 0x38, "/?"))  # missing from the layout file; slot 74 is the gap
    return keys


def slot_for(target, keys):
    """4-byte slot: [type 02 = keyboard, modifier bits, HID code, 00]."""
    if target.startswith("0x"):
        code = int(target, 16)
    else:
        if target.lower() not in keys:
            raise SystemExit(f"Unknown target key '{target}'")
        code = keys[target.lower()][1]
    if 0xE0 <= code <= 0xE7:                     # modifier key → modifier bit only
        return bytes([0x02, 1 << (code - 0xE0), 0x00, 0x00])
    return bytes([0x02, 0x00, code, 0x00])


def keymap_packets(slots):
    """512-byte map (128 slots × 4 bytes, AA 55 at the end), as the app sends it."""
    buf = bytearray(512)
    for idx, slot in slots.items():
        buf[idx * 4: idx * 4 + 4] = slot
    buf[510], buf[511] = 0xAA, 0x55
    steps = [("begin (04 18)", BEGIN), ("keymap header (04 11)", pkt(0x04, 0x11, at={8: 0x08}))]
    steps += [(f"keymap data {i + 1}/8", bytes(buf[i * 64:(i + 1) * 64])) for i in range(8)]
    steps += [("end (04 02)", END), ("apply (04 F0)", APPLY)]
    return steps


# ---- Custom per-key colours (cmd 0x23 + lighting mode 0x80) -------------------

def custom_light_packets(colors, brightness=5):
    """colors: {light_index: (r, g, b)}. Mirrors 0x43b660 → 0x43b900:
    a 512-byte table (slot n = [n, R, G, B]) then lighting mode 0x80."""
    buf = bytearray(512)
    for idx, (r, g, b) in colors.items():
        buf[idx * 4: idx * 4 + 4] = bytes([idx, r, g, b])
    steps = [("begin (04 18)", BEGIN), ("colour table header (04 23)", pkt(0x04, 0x23, at={8: 0x08}))]
    steps += [(f"colour data {i + 1}/8", bytes(buf[i * 64:(i + 1) * 64])) for i in range(8)]
    steps += [("end (04 02)", END), ("apply (04 F0)", APPLY)]
    # then switch the lighting to the custom mode (separate transaction, like the app)
    mode = pkt(0x80, 0, 0, 0, at={8: 0x00, 9: brightness, 10: 0x0F, 11: 0x0F, 14: 0xAA, 15: 0x55})
    steps2 = [("begin (04 18)", BEGIN), ("lighting header (04 13)", pkt(0x04, 0x13, at={8: 0x01})),
              ("lighting data (mode 0x80)", mode), ("end (04 02)", END), ("apply (04 F0)", APPLY)]
    return steps, steps2


# ---- Screen info: clock, CPU/GPU, weather (cmd 0x28) ---------------------------

def screen_info_packets(when, view=1, cpu=0, cpu_temp=0, gpu=0, gpu_temp=0,
                        temp=0, day_temp=0, night_temp=0, weather=0):
    """Mirrors 0x447450: [0]=00 [1]=view (list index+1) [2]=5A [3..8]=yy mm dd hh mi ss
    [10]=weekday (0=Sunday) [11..14]=CPU%, CPU°C, GPU%, GPU°C [15..18]=temp, day, night,
    weather code (0 sunny, 1 cloudy, 3-5 rain, 6 showers, 7-8 storm, 9 thunder, 18 snow)."""
    wd = (when.isoweekday()) % 7
    vals = [0x00, view, 0x5A, when.year % 2000, when.month, when.day, when.hour, when.minute,
            when.second, 0x00, wd, cpu, cpu_temp, gpu, gpu_temp,
            temp & 0xFF, day_temp & 0xFF, night_temp & 0xFF, weather]
    data = pkt(*vals, at={62: 0xAA, 63: 0x55})
    return [("begin (04 18)", BEGIN), ("screen header (04 28)", pkt(0x04, 0x28, at={8: 0x01})),
            ("screen data", data), ("end (04 02)", END)]


# ---- 2.4 GHz dongle (interface 4, 0xFF59) ---------------------------------------

def dongle_packet(cmd, fields):
    """32-byte dongle command (0x468790): [cmd, 10, 00, …fields], byte 31 = sum of 0..30."""
    d = bytearray(32)
    d[0], d[1], d[2] = cmd, 0x10, 0x00
    for i, v in enumerate(fields):
        d[3 + i] = v
    d[31] = sum(d[:31]) & 0xFF
    return bytes(d)


def dongle_lighting(mode, r, g, b, colortype, brightness, speed, direction):
    """Same fields as the wired lighting data packet, behind 05 10 00 (0x43b560)."""
    f = [mode, r, g, b, 0, 0, 0, 0, colortype, brightness, speed, direction, 0, 0, 0xAA, 0x55]
    return dongle_packet(0x05, f)


def dongle_chunks(cmd, table, size=28):
    """Chunked dongle upload (0x41b8e0 / 0x435f40): [cmd, len, index, payload…]."""
    out = []
    for i in range(0, len(table), size):
        part = table[i:i + size]
        d = bytearray(32)
        d[0], d[1], d[2] = cmd, len(part), i // size
        d[3:3 + len(part)] = part
        d[31] = sum(d[:31]) & 0xFF
        out.append(bytes(d))
    return out


def dongle_custom_light(colors, brightness=5):
    """Custom per-key colours over the dongle (0x435f40): mode-0x80 lighting packet,
    then a 576-byte table (slot n = [n, R, G, B], AA 55 at 574) as 21 chunks of cmd 0x14."""
    mode = dongle_packet(0x05, [0x80, 0, 0, 0, 0, 0, 0, 0, 0, brightness, 0, 0, 0, 0, 0xAA, 0x55])
    table = bytearray(576)
    for idx, (r, g, b) in colors.items():
        table[idx * 4: idx * 4 + 4] = bytes([idx, r, g, b])
    table[574], table[575] = 0xAA, 0x55
    return [mode] + dongle_chunks(0x14, bytes(table))


def dongle_send(dev, packet, label):
    """Write one 32-byte report and wait for a reply echoing bytes 0..2 (0x468790)."""
    print(f"-> {label}\n   {hexdump(packet)}")
    dev.write(b"\x00" + packet)
    for _ in range(20):
        r = bytes(dev.read(32, 50) or b"")
        if r:
            ok = r[:3] == packet[:3]
            print(f"<- {hexdump(r[:32])}\n   {'echo matches → OK' if ok else 'no echo'}")
            if ok:
                return True
    print("<- no matching reply")
    return False


# ---- Keyboard settings (cmd 0x17) ---------------------------------------------

def settings_packets(game_mode, block_alt_tab, block_alt_f4, block_win, fn_toggle,
                     sleep, led_brightness, profile=1):
    """Exact sequence the Windows app sends (0x4454d0). No 04 F0 for this command.
    The three 'block' flags only count when game_mode is on (the app zeroes them)."""
    on = 1 if game_mode else 0
    data = pkt(0x00, on,
               on and int(block_alt_tab), on and int(block_alt_f4), on and int(block_win),
               int(fn_toggle), sleep, led_brightness, at={62: 0xAA, 63: 0x55})
    return [
        ("begin (04 18)", BEGIN),
        ("settings header (04 17)", pkt(0x04, 0x17, profile, at={8: 0x01})),
        ("settings data", data),
        ("end (04 02)", END),
    ]


def run(dev, packets):
    drain(dev)
    data_sum = sum(sum(p) for label, p in packets if "data" in label) & 0xFFFF
    has_data = any("data" in label for label, _ in packets)
    results = [send(dev, label, p, data_sum if (has_data and p == END) else None)
               for label, p in packets]
    ok = sum(results)
    print(f"\nResult: {ok}/{len(results)} packets acknowledged OK")
    return 0 if all(results) else 2


def byte(lo, hi):
    def parse(s):
        v = int(s, 0)
        if not lo <= v <= hi:
            raise argparse.ArgumentTypeError(f"must be {lo}..{hi}")
        return v
    return parse


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list", help="list interfaces, send nothing")
    sub.add_parser("handshake", help="send begin + end only")
    lp = sub.add_parser("light", help="send one lighting command (USB cable only)")
    lp.add_argument("--mode", type=byte(1, 20), default=1, help="effect 1..20 (1 = static, confirmed)")
    lp.add_argument("--rgb", nargs=3, type=byte(0, 255), default=[255, 255, 255], metavar=("R", "G", "B"))
    lp.add_argument("--brightness", type=byte(0, 5), default=5, help="0..5, 5 = full (confirmed)")
    lp.add_argument("--speed", type=byte(0, 5), default=3, help="0..5, higher = faster (confirmed)")
    lp.add_argument("--direction", type=byte(0, 3), default=0)
    lp.add_argument("--colortype", type=byte(0, 1), default=0,
                    help="0 = use --rgb, 1 = colourful/rainbow (both confirmed)")
    sp = sub.add_parser("settings", help="send keyboard settings (cmd 0x17, USB cable only)")
    sp.add_argument("--game-mode", action="store_true")
    sp.add_argument("--block-alt-tab", action="store_true")
    sp.add_argument("--block-alt-f4", action="store_true")
    sp.add_argument("--block-win", action="store_true")
    sp.add_argument("--fn-toggle", action="store_true", help="Fn works as a toggle instead of while held")
    sp.add_argument("--sleep", type=byte(0, 255), default=0, help="sleep_light value (app default 0)")
    sp.add_argument("--led-brightness", type=byte(0, 255), default=7, help="led_brightness (app default 7)")
    dl = sub.add_parser("dongle-light", help="send one lighting command through the 2.4 GHz dongle")
    dl.add_argument("--mode", type=byte(1, 20), default=1)
    dl.add_argument("--rgb", nargs=3, type=byte(0, 255), default=[255, 0, 0], metavar=("R", "G", "B"))
    dl.add_argument("--brightness", type=byte(0, 5), default=5)
    dl.add_argument("--speed", type=byte(0, 5), default=3)
    dl.add_argument("--colortype", type=byte(0, 1), default=0)
    dc = sub.add_parser("dongle-customlight", help="per-key colours through the 2.4 GHz dongle")
    dc.add_argument("--all", nargs=3, type=byte(0, 255), metavar=("R", "G", "B"))
    dc.add_argument("--key", action="append", default=[], metavar="NAME=R,G,B")
    sc = sub.add_parser("screeninfo", help="send clock / CPU / weather info to the LCD (USB cable only)")
    sc.add_argument("--time", help="HH:MM to send instead of now (for testing)")
    sc.add_argument("--view", type=byte(0, 255), default=1)
    for name in ("cpu", "cpu-temp", "gpu", "gpu-temp", "weather"):
        sc.add_argument(f"--{name}", type=byte(0, 255), default=0)
    for name in ("temp", "day-temp", "night-temp"):
        sc.add_argument(f"--{name}", type=int, default=0)
    cp = sub.add_parser("customlight", help="per-key colours (USB cable only)")
    cp.add_argument("--all", nargs=3, type=byte(0, 255), metavar=("R", "G", "B"), help="colour for every key")
    cp.add_argument("--key", action="append", default=[], metavar="NAME=R,G,B", help="e.g. esc=255,0,0 (repeatable)")
    cp.add_argument("--brightness", type=byte(0, 5), default=5)
    rp = sub.add_parser("remap", help="remap one key, or --reset all keys to default (USB cable only)")
    rp.add_argument("key", nargs="?", help="physical key, e.g. home, capslock, a")
    rp.add_argument("target", nargs="?", help="what it should send, e.g. a, esc, 0x29")
    rp.add_argument("--reset", action="store_true", help="send an empty map = every key default")
    args = ap.parse_args()

    if args.cmd == "list":
        list_interfaces()
        return 0

    if args.cmd == "remap":
        keys = load_keys()
        if args.reset:
            slots, desc = {}, "reset all keys to default"
        else:
            if not (args.key and args.target) or args.key.lower() not in keys:
                print("Usage: remap KEY TARGET   (or --reset). Keys:",
                      ", ".join(sorted({v[2] for v in keys.values()})))
                return 1
            idx, _, name = keys[args.key.lower()]
            slot = slot_for(args.target, keys)
            slots, desc = {idx: slot}, f"{name} (slot {idx}) → {hexdump(slot)}"
        print(f"Key map: {desc}")

    # Settings changes only over the cable: the dongle's format isn't understood yet.
    if args.cmd == "customlight":
        keys = load_keys()
        colors = {}
        if args.all:
            colors = {idx: tuple(args.all) for idx, _, _ in set(keys.values())}
        for spec in args.key:
            name, rgb = spec.split("=")
            if name.lower() not in keys:
                print(f"Unknown key '{name}'"); return 1
            colors[keys[name.lower()][0]] = tuple(int(x) for x in rgb.split(","))
        print(f"Custom light: {len(colors)} keys coloured")

    if args.cmd == "dongle-customlight":
        keys = load_keys()
        colors = {idx: tuple(args.all) for idx, code, _ in set(keys.values()) if code not in (0xE9, 0xEA)} if args.all else {}
        for spec in args.key:
            name, rgb = spec.split("=")
            colors[keys[name.lower()][0]] = tuple(int(x) for x in rgb.split(","))
        dev = open_channel([DONGLE_CMD_PAGE])
        if not dev:
            print("Dongle not found."); return 1
        try:
            drain(dev)
            packets = dongle_custom_light(colors)
            results = []
            for i, p in enumerate(packets):
                label = "custom mode (05 … 80)" if i == 0 else f"colour chunk {i}/{len(packets) - 1}"
                with contextlib.redirect_stdout(io.StringIO()):
                    ok = dongle_send(dev, p, label)
                results.append(ok)
                print(f"{'✓' if ok else '✗'} {label}")
                time.sleep(0.002)
            print("Result:", f"{sum(results)}/{len(results)} echoed OK")
            return 0 if all(results) else 2
        finally:
            dev.close()

    if args.cmd == "dongle-light":
        try:
            dev = open_channel([DONGLE_CMD_PAGE])
        except OSError as e:
            print(f"Could not open the dongle: {e}"); return 1
        if not dev:
            print("Dongle not found."); return 1
        try:
            drain(dev)
            r, g, b = args.rgb
            ok = dongle_send(dev, dongle_lighting(args.mode, r, g, b, args.colortype, args.brightness, args.speed, 0),
                             f"dongle lighting (mode {args.mode}, rgb {r},{g},{b})")
            print("Result:", "OK" if ok else "FAILED")
            return 0 if ok else 2
        finally:
            dev.close()

    pages = [WIRED_USAGE_PAGE] if args.cmd in ("light", "remap", "settings", "customlight", "screeninfo") else [WIRED_USAGE_PAGE, DONGLE_USAGE_PAGE]
    try:
        dev = open_channel(pages)
    except OSError as e:
        print(f"Could not open the interface: {e}")
        return 1
    if not dev:
        print("Keyboard not found" + (" on the USB cable (lighting needs the cable)." if args.cmd == "light" else "."))
        return 1

    try:
        if args.cmd == "handshake":
            return run(dev, [("begin (04 18)", BEGIN), ("end (04 02)", END)])
        if args.cmd == "remap":
            return run(dev, keymap_packets(slots))
        if args.cmd == "screeninfo":
            import datetime
            when = datetime.datetime.now()
            if args.time:
                h, m = map(int, args.time.split(":"))
                when = when.replace(hour=h, minute=m, second=0)
            steps = screen_info_packets(when, args.view, args.cpu, args.cpu_temp, args.gpu, args.gpu_temp,
                                        args.temp, args.day_temp, args.night_temp, args.weather)
            print("Screen data:", hexdump(steps[2][1][:19]))
            return run(dev, steps)
        if args.cmd == "customlight":
            table, mode = custom_light_packets(colors, args.brightness)
            rc = run(dev, table)
            print("\n--- switch lighting to custom mode ---")
            return rc or run(dev, mode)
        if args.cmd == "settings":
            steps = settings_packets(args.game_mode, args.block_alt_tab, args.block_alt_f4, args.block_win,
                                     args.fn_toggle, args.sleep, args.led_brightness)
            print("Settings data:", hexdump(steps[2][1][:8]))
            return run(dev, steps)
        r, g, b = args.rgb
        print(f"Lighting: mode={args.mode} rgb=({r},{g},{b}) colortype={args.colortype} "
              f"brightness={args.brightness} speed={args.speed} direction={args.direction}")
        return run(dev, lighting_packets(args.mode, r, g, b, args.colortype,
                                         args.brightness, args.speed, args.direction))
    finally:
        dev.close()


if __name__ == "__main__":
    sys.exit(main())
