#!/usr/bin/env python3
""""Vibe coding" animation for the AMG65 LED strip (63 × 5).

Claude Code (crab), Codex (cloud with >_) and Antigravity (gradient arch) run over
scrolling grass eating bugs, then "VIBE CODING" scrolls by in rainbow colours.

    .venv/bin/python tools/vibe_strip.py preview      # writes assets/preview/amg65-led-strip-preview.gif (scaled up)
    .venv/bin/python tools/vibe_strip.py upload       # uploads to the strip (USB cable)
"""
import colorsys
import sys
from pathlib import Path

from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent))

W, H = 63, 5
BLACK = (0, 0, 0)

# --- Sprites: rows 0–3 (row 4 is grass). '.' = transparent, letters map to colours. ---
CLAUDE = {  # orange crab, dark eyes; two leg poses
    "frames": [
        [".OOOOO.", ".OkOkO.", "OOOOOOO", ".O.O.O."],
        [".OOOOO.", ".OkOkO.", "OOOOOOO", "O.O.O.O"],
    ],
    "colors": {"O": (255, 90, 40), "k": (20, 6, 0)},
}
CODEX = {  # blue-violet cloud with a white >_ prompt; bobs up and down
    "frames": [
        [".bvvb.", "bWbbbb", "bbWbWW", ".bbbb."],
        [".bvvb.", "bWbbbb", "bbWbWW", ".b..b."],
    ],
    "colors": {"b": (40, 70, 255), "v": (150, 90, 255), "W": (230, 240, 255)},
}
ANTIGRAVITY = {  # arch: green → red on top, blue legs that stride
    "frames": [
        [".gyr.", "gc.mr", "B...B", "B...B"],
        [".gyr.", "gc.mr", "B...B", ".B.B."],
    ],
    "colors": {"g": (60, 220, 60), "y": (200, 160, 40), "r": (255, 50, 50),
               "c": (20, 160, 200), "m": (170, 60, 200), "B": (30, 110, 255)},
}
RUNNERS = [CLAUDE, CODEX, ANTIGRAVITY]

FONT = {  # 3 × 5
    "V": ["101", "101", "101", "101", "010"], "I": ["111", "010", "010", "010", "111"],
    "B": ["110", "101", "110", "101", "110"], "E": ["111", "100", "110", "100", "111"],
    "C": ["011", "100", "100", "100", "011"], "O": ["010", "101", "101", "101", "010"],
    "D": ["110", "101", "101", "101", "110"], "N": ["110", "101", "101", "101", "101"],
    "G": ["011", "100", "101", "101", "011"], " ": ["000"] * 5, "!": ["010", "010", "010", "000", "010"],
}


def blank():
    return [[BLACK] * W for _ in range(H)]


def grass(px, t):
    """Bottom row: scrolling grass with lighter tufts."""
    for x in range(W):
        tuft = (x + t) % 5 == 0
        px[4][x] = (90, 255, 60) if tuft else (0, 110, 10)


def draw_sprite(px, sprite, x0, pose):
    for y, row in enumerate(sprite["frames"][pose]):
        for i, ch in enumerate(row):
            x = x0 + i
            if ch != "." and 0 <= x < W:
                px[y][x] = sprite["colors"][ch]


def run_scene(frames=120):
    out = []
    # bugs along the ground (row 3), eaten when a runner reaches them
    bugs = {x: True for x in (12, 22, 31, 40, 47, 55, 60)}
    flashes = {}
    gap = 10
    for t in range(frames):
        px = blank()
        grass(px, t)
        lead = -24 + t * 0.75                     # leader's x; group runs left → right
        xs = [int(lead) - i * gap for i in range(3)]
        # spiders: red body, purple legs that twitch; popped ones flash yellow for 2 frames
        LEG, BODY = (150, 0, 200), (255, 0, 40)

        def put(y, x, c):
            if 0 <= x < W:
                px[y][x] = c

        for bx, alive in bugs.items():
            if not alive:
                continue
            put(2, bx, BODY)                 # body (2 px tall)
            put(3, bx, BODY)
            put(2, bx - 1, LEG)              # upper legs
            put(2, bx + 1, LEG)
            spread = 2 if (t // 3 + bx) % 2 else 1   # lower legs twitch in/out
            put(3, bx - spread, LEG)
            put(3, bx + spread, LEG)
        for bx, until in list(flashes.items()):
            if t <= until:
                for dx in (-1, 0, 1):
                    put(3, bx + dx, (255, 230, 0))
                put(2, bx, (255, 255, 160))
        # draw runners (back to front) and eat bugs under their front edge
        for i, x0 in reversed(list(enumerate(xs))):
            sprite = RUNNERS[i]
            pose = (t // 2 + i) % 2
            draw_sprite(px, sprite, x0, pose)
            front = x0 + len(sprite["frames"][0][0]) - 1
            for bx in bugs:
                if bugs[bx] and x0 <= bx <= front:
                    bugs[bx] = False
                    flashes[bx] = t + 2
        out.append(px)
    return out


def text_scene(text="VIBE CODING!"):
    cols = []
    for ch in text:
        g = FONT[ch]
        for c in range(3):
            cols.append([g[y][c] == "1" for y in range(5)])
        cols.append([False] * 5)
    out = []
    total = len(cols) + W
    for s in range(total):
        px = blank()
        for x in range(W):
            ci = x + s - W
            if 0 <= ci < len(cols):
                hue = ((ci / len(cols)) + s / 60) % 1.0
                r, g, b = colorsys.hsv_to_rgb(hue, 1, 1)
                for y in range(5):
                    if cols[ci][y]:
                        px[y][x] = (int(r * 255), int(g * 255), int(b * 255))
        out.append(px)
    return out


def all_frames():
    return run_scene() + text_scene()


def to_image(px):
    img = Image.new("RGB", (W, H))
    img.putdata([c for row in px for c in row])
    return img


def preview(path, scale=14, ms=86):
    frames = []
    for px in all_frames():
        big = Image.new("RGB", (W * scale, H * scale), (8, 8, 12))
        d = ImageDraw.Draw(big)
        for y in range(H):
            for x in range(W):
                c = px[y][x]
                if c == BLACK:
                    c = (24, 24, 30)
                d.ellipse([x * scale + 2, y * scale + 2, (x + 1) * scale - 2, (y + 1) * scale - 2], fill=c)
        frames.append(big)
    frames[0].save(path, save_all=True, append_images=frames[1:], duration=ms, loop=0)
    return len(frames)


def upload(delay=5):
    from amg65 import pkt
    from amg65_lcd import upload_blocks
    from amg65_strip import build
    frames = [to_image(px) for px in all_frames()][:260]
    buf, blocks = build(frames, delay)
    print(f"{len(frames)} frames → {blocks} blocks")
    header = pkt(0x04, 0x33, at={8: blocks & 0xFF, 9: blocks >> 8})
    return upload_blocks(buf, blocks, header, f"strip header (04 33, {blocks} blocks)", apply_after=True)


if __name__ == "__main__":
    if sys.argv[1:] == ["preview"]:
        out = Path(__file__).resolve().parent.parent / "assets/preview/amg65-led-strip-preview.gif"
        print(preview(out), "frames →", out)
    else:
        print("RESULT:", "OK" if upload() else "FAILED")
