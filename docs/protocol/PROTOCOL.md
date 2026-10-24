# LEOBOG AMG65 (AULA) — USB HID protocol notes

Reverse-engineered statically from the official Windows driver
`local/official-driver/LEOBOG AMG65 Driver-1.0.3.1.exe` (SHA-256 `d6b7a7c1…9376b`), main program
`app/DeviceDriver.exe` (SHA-256 `05e4f15b…ccbdeb`). Later hardware tests are noted
throughout this document. Addresses below are virtual addresses in
`DeviceDriver.exe` (image base `0x400000`).

Legend: **Observed** = read directly from code/data. **Inferred** = best reading,
needs a hardware test to confirm.

## 1. What the Windows app is

- Inno Setup 6.1 installer → 32-bit MFC/C++ app (`DeviceDriver.exe`) + SQLite for
  profiles. No kernel driver. **Observed.**
- Talks to the keyboard with the open-source **hidapi** library (statically
  linked; `hid.dll` loaded at runtime at `0x469830`). **Observed.**
- Only `hid_write` (`0x469e70`, Win32 `WriteFile`) and `hid_read_timeout`
  (`0x469f50`, `ReadFile`) are used. `HidD_SetFeature`/`GetFeature` are loaded but
  never called — **no feature reports**. **Observed.**
- Keyboard MCU: SONiX, chip ID string `SI-2692` (also in the firmware file name).
  **Observed.** The firmware updater (`app/firmware/*.exe`) is separate and was
  not analysed; don't use it from a Mac.

Good news for macOS: plain HID output/input reports work the same on macOS via
hidapi (`brew install hidapi`, or Python `hid`/`hidapi`) or IOKit
(`IOHIDDeviceSetReport` / input-report callback). No driver needed.

## 2. Finding the device (registration at `0x41eb00`)

| Connection | VID | PID | Name in app |
|---|---|---|---|
| USB cable (inferred) | `0x0C45` (SONiX) | `0x800A` | LEOBOG AMG65 |
| 2.4 GHz dongle | `0x05AC` (Apple VID, borrowed) | `0x024F` | AMG65 Dongle |

- The app enumerates HID paths and keeps one whose path contains the VID, PID **and
  `MI_02`** → use **USB interface 2** (`0x41f433`). **Observed.**
- On macOS, match VID/PID + `interface_number == 2` in `hid_enumerate`.
- Bluetooth mode is not handled by this app (no BT entry found).
- On this Mac (2026-10-22) the dongle enumerates as `0x05AC:0x024F` "AMG65 Dongle"
  with vendor-defined HID collections on usage pages **`0xFF59`** and **`0xFF60`**
  (usage `0x61`), alongside the normal keyboard/consumer ones. The command channel
  is almost certainly one of the vendor pages (`0xFF60` is the usual raw-HID page). **Observed** via `hidutil list`.

## 3. Transport (`0x467f50`)

- Every packet is **64 bytes**, sent as a 65-byte write: `[0x00 report-ID] + 64 bytes`.
  **Observed.**
- After each write: sleep 2 ms, `hid_read_timeout(…, 200 ms)`. **Observed.**
- Reply status is **reply byte [3]** (report ID stripped): `0x01` = OK,
  `0xFF` = busy → the app resends once. **Observed** (meaning of values inferred).
- Payloads longer than 64 bytes are sent as consecutive 64-byte chunks, each
  followed by a read. **Observed.**

## 4. Command framing

Command packets start with `0x04` then a command byte (rest zero-padded):

```
04 18 …            begin transaction
04 <cmd> … [8]=N   command header; byte 8 = number of data packets that follow
<data packet(s)>   raw 64-byte payload(s), often ending with AA 55
04 02 …            end / commit
04 F0 …            (some commands) apply / save          — meaning inferred
```

### Commands seen (`cmd` byte → function → meaning)

| Cmd | Builder | Meaning | Confidence |
|---|---|---|---|
| `13` | `0x43b3f0`, `0x43b900` | **Lighting effect** (mode/colour) | Observed layout, field names inferred |
| `17` | `0x4454d0` | **Settings**: sleep timer + LED brightness | Observed keys `sleep_light`, `led_brightness` |
| `28` | `0x42ab10`, `0x447450` | **Time Sync** + CPU/GPU/weather data — see §5d | Sent OK; on-screen effect not confirmed |
| `72` | `0x42a1d0` | **LCD animation upload** — see §5d | **Confirmed on hardware** |
| `31` | `0x434410` | **LED strip boot animation** — see §5e | Decoded (same format as `33`) |
| `33` | `0x434970` | **LED strip animation** — see §5e | **Confirmed on hardware** |
| `35` | `0x434ed0`, sender `0x468170` | **Live strip frame** — see §5e | **Confirmed on hardware** |
| `11` | `0x41ad70` | **Key map** — see §5b | **Confirmed on hardware** |
| `23` | `0x43b660` | **Per-key colour table** (Custom Light) — see §5c | **Confirmed on hardware** |
| `19`,`15` | `0x43dad0` | Unknown | Unknown |
| `20`, `F5` | `0x435d10`, `0x43ba50` | Read requests (use the read path) | Unknown |

## 5. Lighting (`cmd 0x13`, decoded from `0x43b3f0`)

```
1) 04 18 00 … 00
2) 04 13 00 00 00 00 00 00 01 00 … 00      (1 data packet follows)
3) data packet (64 bytes):
     [0]  mode            (effect index)
     [1]  byte2  ┐
     [2]  byte3  ├ colour R,G,B (inferred)
     [3]  byte4  ┘
     [8]  colortype       (single colour vs rainbow — inferred)
     [9]  byte6  ┐
     [10] byte7  ├ brightness / speed / direction (order unconfirmed)
     [11] byte5  ┘
     [14] AA  [15] 55
4) 04 02 00 … 00
5) 04 F0 00 … 00
```

Field names come from the app's SQLite table
`t_light_data(profile, name, mode, colortype, byte2, byte3, byte4, byte5, byte6, byte7, sel)`
(column→struct mapping at `0x408920`). **Observed** packing; the meaning of
`byte5–7` needs a test.

## 5b. Key map (`cmd 0x11`, decoded from `0x41ad70`) — confirmed ✅

```
1) 04 18 …
2) 04 11 00 00 00 00 00 00 08 …        (8 data packets follow)
3) 8 × 64-byte data packets = 512-byte table: 128 slots × 4 bytes,
   slot n at offset n*4, bytes 510–511 = AA 55
4) 04 02 …   (reply [4..5] = 16-bit sum of the 512 bytes)
5) 04 F0 …
```

- **Slot index = `key_index` from `KeyboardLayout.xml`** (68 keys; `/?` is missing
  from the file and uses the gap at slot 74, inferred).
- **All-zero slot = factory default.** The app only stores rows for remapped keys
  (`t_key_data`); "reset all" deletes them, so it sends an all-zero map.
- The whole map is sent every time; the app (and our tools) keep the full set of remaps.

Slot encodings (`[type, b1, b2, b3]`):

| Type | Meaning | Bytes | Status |
|---|---|---|---|
| `02` | Keyboard key / shortcut | modifier bits (`01` Ctrl, `02` Shift, `04` Alt/⌥, `08` Win/⌘, `10`–`80` right-hand), HID usage, `00`. A modifier as the target → its bit only, usage `00` | **Confirmed** (Home → `02 00 04 00` typed "a") |
| `03` | Consumer/media | 16-bit usage, little-endian (`CD` play/pause, `B5` next, `B6` prev, `B7` stop, `E9` vol+, `EA` vol−, `E2` mute, `0194` My Computer, `0192` calculator…) | Decoded, untested |
| `01` | Mouse | `01 <mask>` button (`01` left, `02` right, `04` middle, `08` back, `10` forward); `03 01` / `03 FF` wheel up/down | Decoded, untested |
| `06` | Macro | macro number, repeat options | Decoded, macros not yet supported |
| `07` | App-specific (macrotype 13) | 3 values | Unknown meaning |
| `05` | `05 03` = Fn-type key; `05 02 xx` = lighting/function keys | | Unknown |

Built-in shortcuts the app offers are just type `02`: `08 07` Win+D, `08 08` Win+E,
`08 0F` Win+L, `01 06` Ctrl+C, `01 19` Ctrl+V, `01 1B` Ctrl+X, `04 2B` Alt+Tab.

Hardware test (2026-10-22): Home → A worked and other keys were unaffected; the
all-zero reset map restored it (user-confirmed). A remap made in the Mac app's
Custom Key tab also worked (user-confirmed). Not yet covered: an Fn-layer map, and the dongle
variant (`0x41b8e0`/`0x41b4f0`, used when the connection type is 2).

## 5c. Custom per-key colours (`cmd 0x23` + lighting mode `0x80`) — confirmed ✅

Decoded from `0x43b660` (table) → `0x43b900` (mode switch):

```
Transaction 1 — colour table
  04 18
  04 23 00 00 00 00 00 00 08        (8 data packets)
  8 × 64 B = 512-byte table, slot n at offset n*4 = [n, R, G, B]
             (n = light_index = key_index from KeyboardLayout.xml); unused slots all 00
  04 02     (reply [4..5] = 16-bit sum of the 512 bytes)
  04 F0
Transaction 2 — switch lighting to the custom layout
  04 18
  04 13 … [8]=01
  data: [0]=80 (custom mode) [1..3]=00 [8]=00 [9]=brightness [10]=0F [11]=0F [14..15]=AA 55
  04 02
  04 F0
```

- No AA 55 inside the 512-byte table (the app's marker sits past the sent range).
- The volume knob entries (light index 13/14) have no LED and are left out.
- Hardware test 2026-10-22: all keys blue, Esc red, W/A/S/D green — exactly as sent
  (user-confirmed). Selecting any normal effect (mode 1–20) leaves custom mode.
- Not yet decoded: `0x31`/`0x33` (custom *animated* modes with frames — "Custom
  Lighting Mode" tab).

## 5d. Screens: LCD upload (`0x72`) and Time Sync (`0x28`)

The AMG65 has two screens: the **dot-matrix LED strip** (65 × 5 RGB LEDs, its own
animation commands — not decoded yet) and a **240 × 135 colour LCD** on the right.

### LCD animation upload (`cmd 0x72`, `0x42a1d0` → bulk sender `0x468650`) — confirmed ✅

The keyboard has a 4th USB interface just for image data:

| Interface | Usage page | Reports | Endpoint |
|---|---|---|---|
| 3 | `0xFF67` / `0x61` | 64-byte feature, **4096-byte output** | `0x06` interrupt OUT |

macOS attaches **no driver** to interface 3 (no IOHIDDevice), so the Mac side writes
it with **libusb** (claim interface 3, interrupt transfer to EP `0x06`).

```
On interface 2 (0xFF68):  04 18 → OK
                          04 72 <slot> 00 00 00 00 00 <N lo> <N hi> → OK   (N = number of 4 KB blocks)
For each block:           write 4096 bytes to interface 3 / EP 0x06,
                          wait for a 64-byte reply on interface 2 with byte [3] = 01
                          (app: sleep 5 ms, up to 100 × 600 ms; 500 ms extra after block 1)
On interface 2:           04 02 → OK      (no 04 F0)
```

Image buffer (filled with `FF`, padded to whole 4096-byte blocks):

```
[0]          frame count (app max 130 for the AMG65)
[1 + i]      frame i delay in 2 ms units (40 ms → 20; app clamps ≥ 1)
[256 + …]    frames back to back, 240 × 135, row-major from top-left,
             RGB565 little-endian (low byte first)
```

Device values are hard-coded in the app's constructor (`0x4169d3…`): header 0x100,
max frames 0x82, width 0xF0, height 0x87. Header byte 2 (`slot`) is the LCD list
item + 1; slot 1 tested. Throughput ≈ 5.8 blocks/s (a 125-frame GIF ≈ 1,980 blocks
≈ 6 min). Bundled default AMG65 GIF: 128 × 128, 125 frames, 40 ms.

Hardware tests 2026-10-22: red/green/blue frames with a white top-left marker showed
correctly (colours, orientation, timing — user-confirmed). Same upload via the Mac
app's Swift code: 48/48 blocks acknowledged.

### Time Sync / info (`cmd 0x28`)

```
04 18 · 04 28 … [8]=01 · data · 04 02     (end reply has no checksum for 0x28)
data: [0]=00 [1]=LCD item to show (list index + 1) [2]=5A
      [3]=year−2000 [4]=month [5]=day [6]=hour [7]=minute [8]=second [9]=00 [10]=weekday (0=Sun)
      [11]=CPU % [12]=CPU °C [13]=GPU % [14]=GPU °C            (only in 0x447450)
      [15]=temp [16]=day temp [17]=night temp [18]=weather code (only in 0x447450)
      [62..63]=AA 55
weather: 0 晴 sunny, 1 云 cloudy, 3 小雨, 4 中雨, 5 大雨, 6 阵雨, 7 暴雨, 8 大暴雨, 9 雷阵雨, 0x12 雪 snow
```

The app's "Time Sync" button (`0x42ab10`) sends only the time fields; the periodic
hardware/weather update (`0x447450`) fills all of them. The CPU/GPU/time values likely
feed the LED strip's built-in modes (CPU usage, GPU usage, net speed, date/time).
Test: sending 12:34 + sample stats was acknowledged; the LCD kept showing item 1
(the user's GIF), as byte [1] asks. Where the time appears is not yet confirmed.

## 5e. LED strip animation (`cmd 0x33`, boot animation `0x31`) — confirmed ✅

The dot-matrix strip is **63 × 5 = 315 RGB LEDs** (`[0x52b24] = 0x13B`), wired as four
14 × 5 panels plus one 7 × 5 panel. Decoded from `0x434970` (0x33) / `0x434410` (0x31).

```
On interface 2:  04 18 → OK
                 04 33 00 00 00 00 00 00 <N lo> <N hi> → OK      (0x31 for the boot animation)
N × 4096-byte blocks on interface 3 (EP 0x06), each acknowledged on interface 2 (as §5d)
On interface 2:  04 02 → OK,  04 F0 → OK
```

Buffer (zero-filled, padded to 4096-byte blocks):

```
[0..1]  frame count (LE)          max 260 for 0x33, 200 for 0x31
[2..3]  frame delay word (LE)     app: 0x66 − speed setting, default 0x50; ≈ 75 ms + 2.2 ms × value per frame
[4 + 3 × (frame × 315 + POS[p]) …]   R, G, B for pixel p (row-major 63 × 5, top-left first)
right after the last frame: AA 55
```

`POS` (app table at `0x59c7f0`) maps pixel (row r, column c) to the LED index:
`c < 56 → 70·(c ÷ 14) + 14·r + (c mod 14)`, else `280 + 7·r + (c − 56)`.
The app scales colours by its brightness setting before packing.

Hardware tests 2026-10-22 (user-confirmed): a still frame — red | green | blue thirds
with a white top row and left column — appeared exactly as sent; uploading switches the
strip to the new animation by itself. Timing (user, 119-frame scroll): delay 80 ≈ 30 s/pass (≈ 250 ms/frame), delay 20 ≈ 14 s
(≈ 118 ms/frame) → **frame time ≈ 75 ms + 2.2 ms × delay** (likely 2 ms units plus a fixed
per-frame cost; an estimate from hand timing). Boot animation (0x31) not yet tested.

### Live frames (`cmd 0x35`, `0x434ed0`) — confirmed ✅

The strip's "data" modes (CPU/GPU usage, net speed, date/time, music) are drawn by the PC
and pushed as live frames on the command channel (cable only, no bulk interface):

```
04 18 · 04 35 … [8]=0F (15 data packets) · 15 × 64 bytes · 04 02      (each packet acknowledged)
data: 945 bytes = 315 LEDs × R,G,B at 3 × POS[pixel], then AA 55; zero-padded to 960
```

Test 2026-10-22 (user-confirmed): "LIVE" text, a sweeping bar, "LIVE" again all showed
immediately. Throughput ≈ 20 frames/s over the cable (102 frames in 5 s).

## 6. Settings (`cmd 0x17`, `0x4454d0`)

```
1) 04 18 …
2) 04 17 01 00 00 00 00 00 01 …   (byte 2 = profile, always 1 in the app; 1 data packet)
3) data (64 B):
   [0] 00
   [1] Game Mode on/off            (master: the app zeroes [2..4] when off)
   [2] block Alt+Tab               [3] block Alt+F4       [4] block Windows key
   [5] Fn mode: 0 hold, 1 toggle   (config key fn_switch / fn_switchfunction)
   [6] light sleep: 0 never, 1 = 1 min, 2 = 5 min, 3 = 30 min
   [7] screen (dot-matrix) brightness, app default 7
   [62] AA [63] 55
4) 04 02 …   (reply [4..5] = sum of data bytes). The app sends NO 04 F0 here.
```

Field names come from the settings page's controls (labels "Alt + Tab", "Alt + F4",
"Windows Key", radio group `GROUP_LIGHT_SLEEPTIME` → values 0–3 at `0x43cd20`,
`KeyLayerButton` "Momentary"/"Toggle").

Hardware tests 2026-10-22 (USB cable, macOS) — every packet acknowledged, checksums OK:

| Field | Test | Result |
|---|---|---|
| [7] screen brightness | 7 → 1 → 7 | ✅ **screen dimmed, then restored** (user-confirmed) |
| [1]+[4] Game Mode + block Win | ⌘ Space | ✗ still opened Spotlight |
| [1]+[2..4] all blocks (+ `04 F0` too) | ⌘ Space | ✗ no effect |
| [6] sleep = 1 (1 min) | idle 90 s | ✗ backlight stayed on — probably battery-only |
| [5] Fn toggle | tap Fn, press 1 | ✗ still typed "1" |

The keyboard clearly processes 0x17 (brightness works); the other fields may only
apply on Windows / on battery, or the AMG65 may not implement them. The screen
brightness maximum isn't known (1 and 7 tested; the app's UI uses 1–7).

Dongle variant: `0x4456e0` (used when the connection type ≠ wired) builds the same
fields with a different wrapper (`… 07 10 00 00 01 …`) via `0x468790` — a lead for
dongle support.

## 7. macOS hardware test — 2026-10-22 (dongle)

Dongle interfaces on macOS (from report descriptors):

| Interface | Usage page | Reports | Opens without permission? |
|---|---|---|---|
| 0 | Keyboard (boot) | 8-byte in | No (Input Monitoring) |
| 1 | Mouse | 5-byte in | No |
| 2 | Consumer/System/NKRO/Digitizer + `0xFFFF` (ID 5, 3-byte **input only**) | no 64-byte output | No |
| 3 | `0xFF60` | 32 B in / 32 B out, no report ID | Yes |
| 4 | **`0xFF59`** | **64 B in / 64 B out, no report ID** | Yes |

- Interface 2 has no output report on the dongle, so the Windows `MI_02` rule must
  be for the USB-cable device (`0C45:800A`). On the dongle, **interface 4 /
  `0xFF59`** is the only channel that fits the 64-byte protocol.
- `tools/amg65_handshake.py` sent `04 18` then `04 02` there. Both writes were
  accepted (65 bytes) and **each got a 64-byte reply: `0F 01 01 11 00 … 00`**.
- With nothing sent, the channel stays silent (0 reports in 3 s), so the reply is a
  response to our packet.
- The reply is identical for begin and end, and byte [3] is `0x11` rather than
  `0x01`. So the dongle doesn't follow the wired OK/busy scheme. Guesses to test:
  a dongle-level status (`0F` = dongle response?), or "keyboard asleep/not linked".
- **Re-run with the keyboard awake and linked: identical reply** (`0F 01 01 11`
  for both begin and end). So it's not a sleep/link status. The reply doesn't
  depend on the command, which points to a fixed dongle info/status packet
  (e.g. `01 01 11` could be a version or device type) rather than a per-command ack.
  Either the dongle wraps commands differently than the wired protocol, or the
  real command channel is elsewhere (interface 3 `0xFF60` is 32-byte, so it
  would need a different packet size).
- Next, most informative: test over the **USB cable** (`0C45:800A`), where the
  Windows code path (`MI_02`, 64-byte packets, `01`=OK) applies directly. Or
  capture the Windows app talking to the dongle (USBPcap + Wireshark).

### Wired (USB cable, `0C45:800A`) — protocol confirmed ✅

| Interface | Usage page | Reports |
|---|---|---|
| 0 | Keyboard (boot) | 8-byte in |
| 1 | Consumer/System/NKRO/Mouse + `0xFFFF` (ID 5, 3-byte in) | — |
| 2 (`MI_02`) | **`0xFF68`** | **64 B in / 64 B out, no report ID**, opens without permission |

Handshake result:

```
-> 04 18 00 …    <- 04 18 00 01 00 …   (OK)
-> 04 02 00 …    <- 04 02 00 01 00 …   (OK)
```

- **Reply format confirmed:** the keyboard echoes bytes [0..1] (`04 <cmd>`), and
  **byte [3] = `01` means OK**, matching the Windows code.
- The dongle (`0F 01 01 11`, fixed) uses a different wrapper that's still unknown.
  Use the **cable** for configuration until the dongle format is known.
- `tools/amg65_handshake.py` now picks the wired `0xFF68` channel first, then falls
  back to the dongle's `0xFF59`.

### First lighting command — 2026-10-22 (wired)

Field meanings, from the app's first-run defaults (`0x408290`, modes 1–20):
R=255 G=0 B=0, colortype=1, byte5 (direction)=0 (3 for mode 10),
byte6 (**brightness**)=5, byte7 (**speed**)=3; mode 11 selected by default.
Mode names: string ID 199+mode, so **mode 1 = 静态恒亮 "static, always on"**
(English file mistranslates it as "LED1"). The mode mapping is inferred.

`tools/amg65.py light` (static white) — every packet acknowledged:

```
-> 04 18 …                              <- 04 18 00 01 …          OK
-> 04 13 00 00 00 00 00 00 01 …         <- 04 13 00 01 …          OK
-> 01 FF FF FF 00 00 00 00 01 05 03 00 00 00 AA 55 …
                                        <- 04 41 00 01 …          OK  (data ack = 0x41)
-> 04 02 …                              <- 04 02 00 01 06 04 …    OK  (06 04 = ? )
-> 04 F0 …                              <- 04 F0 00 01 …          OK
```

Visual result (user): **static rainbow ("RGB static")**. So **mode 1 = static is
confirmed**, but with colortype=1 the RGB bytes were ignored: colortype 1 seems to
mean "colourful".

Retry with **colortype=0** (data `01 FF FF FF 00 00 00 00 00 05 03 …`): all 5 OK;
end reply was `04 02 00 01 05 04` (was `06 04` with colortype 1, so bytes [4..5]
seem to report state). Visual result (user): **solid white on all keys ✅**.

**Confirmed on hardware:** mode 1 = static; data bytes [1..3] = R,G,B;
byte [8] colortype **0 = use RGB, 1 = colourful/rainbow**; byte [9]
**brightness** (1 = dim white, 5 = full, user-confirmed). Still unconfirmed:
speed (byte 10), direction (byte 11), brightness 0, modes 2–20.

End-packet reply bytes [4..5] across runs:

| Sent (mode 1, white) | End reply |
|---|---|
| colortype 1, brightness 5 | `06 04` |
| colortype 0, brightness 5 | `05 04` (twice) |
| colortype 0, brightness 1 | `01 04` |

**Solved:** end reply bytes [4..5] = **16-bit little-endian sum of all bytes in
the data packet(s)** received since begin. Checked against 5 runs (0x0406, 0x0405,
0x0401, 0x0409, 0x040D). `tools/amg65.py` verifies it automatically.

### Speed (Breath = mode 7)

- Mode 7 = Breath confirmed (user: white fading in and out). This supports
  mode = string ID − 199 for the other modes too.
- **Speed (byte [10]) confirmed:** 1 = slow, 5 = much faster (user-observed).
  Higher = faster.

## 8. 2.4 GHz dongle protocol — decoded from `0x468790` and its callers ✅

**Channel:** dongle `05AC:024F`, **interface 3, usage page `0xFF60`, 32-byte reports**
(not `0xFF59`, which only ever answers `0F 01 01 11`). macOS opens it without
permission. The keyboard must be awake: after a while on battery it sleeps and the
dongle stops answering until a key is pressed.

**Packet (32 bytes):**

```
[0] command   [1] payload length   [2] chunk index   [3 … 30] payload   [31] sum of bytes 0…30 (low byte)
```

Sent as one output report (report ID 0). The app waits (20 × short reads) for a reply
whose first 3 bytes echo the packet; that echo is the acknowledgement. No 04 18 / 04 02.

| Cmd | Builder | What | Status |
|---|---|---|---|
| `05` | `0x43b560` | Lighting: `05 10 00` + the wired lighting data (mode, R, G, B, 0×4, colortype, brightness, speed, direction, 0, 0, AA, 55) | **Confirmed** (static red / green) |
| `05` + `14` | `0x435f40` | Custom colours: `05 10 00 80 …` (mode 0x80, brightness at payload [9]), then a 576-byte table (slot n = [n, R, G, B], AA 55 at 574) as 20 × 28 + 1 × 16 byte chunks of cmd `14` | **Confirmed** (blue / red Esc / green WASD) |
| `10` | `0x41b8e0` → slots `0x41b4f0` | Key map: the same 512-byte slot table as wired `0x11`, as 18 × 28 + 1 × 8 byte chunks | **Confirmed** (remap from the app works over the dongle) |
| `07` | `0x4456e0` | Settings: `07 10 00 00 01` + blocks Alt+Tab, Alt+F4, Win, fn_switch, sleep, —, key_respondtime, … AA 55 at [17..18]. **No screen-brightness field.** | Decoded, untested |
| `0C` | `0x42ac40` | Time sync (has the `5A` marker like wired 0x28) | Not decoded |
| `09`, `0B` | `0x43e0d0`, `0x444180` | Chunked uploads (likely macros / another table) | Not decoded |
| `20` | `0x448170` | Probably a status query | Not decoded |

The LCD (0x72) and LED strip (0x33/0x31) need the bulk interface `0xFF67`, which the
dongle doesn't have — cable only. The Windows app's own strings agree ("light effect of
the dot-matrix screen … only one light effect … in the wireless connection state").

## 9. Open questions / next steps

1. Confirm on hardware: open interface 2, send `04 18` and check reply byte 3 = `01`.
2. Pin down `byte5–7` (brightness/speed/direction) and the mode index list by
   sweeping values on the keyboard.
3. ~~Decode `0x11`~~ (done, §5b). Still open: macros (type `06` slots + macro upload),
   Fn layer, and `0x72` (screen upload format).
4. Optional: capture real USB traffic on the Windows PC (USBPcap + Wireshark)
   while changing one setting at a time — the fastest way to confirm field names.
