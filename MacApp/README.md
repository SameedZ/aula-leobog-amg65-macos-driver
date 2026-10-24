# AMG65 for macOS

A native SwiftUI app for the LEOBOG AMG65, styled with the original Windows
app's artwork. Talks to the keyboard directly over USB HID (no driver).

## Build & run

```bash
./build_app.sh
open build/AMG65.app
```

Needs the Xcode Command Line Tools (Swift 5.9+), Homebrew `libusb` at build time and the unpacked Windows
installer at `../local/official-driver/extracted/app` (artwork and fonts are copied from there).
The artwork belongs to AULA/LEOBOG, so keep the built app for personal use.

## What works

- **Lighting** (cable or dongle): 20 effects, colour wheel, Colourful (rainbow),
  brightness 1–5, speed 1–5, Apply. The keyboard confirms each packet and the
  data checksum. Confirmed end-to-end on 2026-10-22: changing effect and colour
  in the app and pressing Apply changed the keyboard to match.
- Static and Breath are confirmed on the keyboard; the other effect names are
  inferred from the original app's strings. Direction is untested.
- **Custom Light** (cable or dongle): paint keys with any colour (click or drag),
  fill all, clear, brightness 1–5, Apply. Confirmed from the app on the keyboard
  (2026-10-22; per-key colour table 0x23 + custom lighting mode 0x80).
- **Screen** (USB cable only): pick or drop a GIF/PNG/JPEG, preview it, Fill or Fit
  to 240 × 135, Upload to the LCD (≤130 frames; ~6 blocks/s, so long GIFs take
  minutes). Confirmed on the keyboard (a GIF uploaded from the tab plays
  correctly, 2026-10-22). "Sync time" sends the Mac's clock (0x28) —
  sent OK, on-screen effect not confirmed yet. Uses libusb (bundled in the app).
- **LED Strip** (USB cable only): scrolling text (3 × 5 font, 8 colours) or a
  GIF/image scaled to 63 × 5, brightness, frame delay (≈ 75 ms + 2.2 ms × value per frame), upload as the strip's
  animation (≤260 frames, confirmed — text uploaded from the tab scrolls at a good
  speed, 2026-10-22) or boot animation (≤200, untested). **Live** modes stream
  Clock, CPU usage or a Music spectrum (microphone) to the strip at ~10 fps while
  the app is open (0x35 frames, cable only). All three confirmed on the strip (2026-10-22).
- **Custom Key** (cable or dongle): click a key, pick a new key or shortcut
  (with ⌃ ⇧ ⌥ ⌘), a media key or a mouse action, then Apply. Key remaps made in
  the app are confirmed on the keyboard (2026-10-22); media and mouse actions are decoded but
  untested. Fn and the volume knob can't be remapped. "Reset all" + Apply puts
  every key back to default.
- **Settings** (USB cable only): screen brightness 1–7 works (confirmed from the
  app's Settings tab, 2026-10-22). Light
  sleep time, Fn hold/toggle and Game Mode (block Alt+Tab, Alt+F4, ⌘/Win) are
  sent too, but showed no effect on the cable/macOS in testing — the page says so.
- **2.4 GHz dongle:** Lighting, Custom Light and Custom Key work over the dongle too
  (all three confirmed from the app over the dongle, 2026-10-22). Screen, LED Strip and Settings still need the USB cable. If the keyboard
  is asleep on battery the app says so — press a key and Apply again.
- Other tabs are shown but disabled until their protocols are decoded.

## Dev helpers

```bash
build/AMG65.app/Contents/MacOS/AMG65 --snapshot out.png lighting   # render UI to PNG
build/AMG65.app/Contents/MacOS/AMG65 --apply mode=7 speed=5        # send lighting, print replies
```

## Code map

| File | What it does |
|---|---|
| `Protocol.swift` | Packet builders (lighting, key map, settings), checksum, effect list |
| `Keymap.swift`, `CustomKeyPage.swift` | Key layout, remap actions, Custom Key tab |
| `SettingsModel.swift`, `SettingsPage.swift` | Settings tab (0x17) |
| `CustomLight.swift` | Custom Light tab (per-key colours) |
| `LCD.swift` | Screen tab: GIF → RGB565 frames, libusb bulk channel, upload |
| `LiveStrip.swift` | Live strip modes: clock, CPU meter, microphone spectrum (0x35) |
| `LEDStrip.swift` | LED Strip tab: 63 × 5 frames, panel wiring table, scrolling text font |
| `KeyboardHID.swift` | IOKit device discovery + send/receive |
| `LightingModel.swift` | UI state, remembers last applied settings |
| `Skin.swift`, `SkinControls.swift` | Original artwork, sprite-based controls |
| `AMG65App.swift`, `LightingPage.swift` | Window, tabs, Home and Lighting pages |
