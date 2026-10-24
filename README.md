# LEOBOG AMG65 for macOS

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111111?logo=apple&logoColor=white)
![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift&logoColor=white)
![Unofficial](https://img.shields.io/badge/Project-unofficial-blue)

A native macOS control app for the LEOBOG AMG65 keyboard. AULA/LEOBOG does not provide an official macOS companion app for this keyboard, so this community project communicates directly with the keyboard over USB HID without installing a kernel driver.

> **Unofficial community project.** Not affiliated with, endorsed by, or supported by AULA or LEOBOG. Designed for the LEOBOG AMG65.

[![Download](https://img.shields.io/badge/Download-macOS%20DMG-007AFF?style=for-the-badge&logo=apple&logoColor=white)](#download)
[![Features](https://img.shields.io/badge/Explore-Features-2563EB?style=for-the-badge)](#features)
[![Installation](https://img.shields.io/badge/Read-Install_Guide-16A34A?style=for-the-badge)](#install)
[![Build](https://img.shields.io/badge/Build-from_Source-7C3AED?style=for-the-badge)](#build-from-source)
[![Protocol](https://img.shields.io/badge/Read-Protocol_Notes-475569?style=for-the-badge)](docs/protocol/PROTOCOL.md)

## Download

**For macOS 14 or later.** When a public release is available, download **`AMG65-macOS.dmg`** from the latest release:

<!-- AMG65_DOWNLOAD_LINK_START -->
[![Download AMG65 for macOS](https://img.shields.io/badge/Download-macOS%20DMG-007AFF?style=for-the-badge&logo=apple&logoColor=white)](<https://github.com/SameedZ/aula-leobog-amg65-macos-driver/releases/latest/download/AMG65-macOS.dmg>)
<!-- AMG65_DOWNLOAD_LINK_END -->

The release will include the DMG and a SHA-256 checksum file. The DMG is a drag-to-install image: open it and drag **LEOBOG AMG65** into **Applications**. No separate driver or Homebrew installation is needed to use a published app.

> **Building from source?** The locally generated package is `MacApp/dist/AMG65-macOS.dmg`; source-build instructions are below.

<p align="center">
  <img src="assets/preview/amg65-led-strip-preview.gif" alt="AMG65 LED strip preview" width="720">
</p>

## Install

1. Download and open **`AMG65-macOS.dmg`**.
2. Drag **LEOBOG AMG65** to **Applications**.
3. Eject the mounted disk image, then open the app from **Applications** and connect the keyboard.

Requires **macOS 14 or later**. Use USB for all features; the 2.4 GHz receiver supports Lighting, Custom Light, and Custom Key.

> **If macOS blocks the app:** An app that is not signed and notarized may show a warning that Apple cannot verify it. The release page should state its signing status before you install it.

<p align="center">
  <img src="assets/preview/amg65-demo.gif" alt="LEOBOG AMG65 for macOS demo" width="720">
</p>

## Features

| Feature | What you can do | Connection |
|---|---|---|
| **Lighting** | Pick from 20 effects; set colour or rainbow mode, brightness, and speed. | USB or 2.4 GHz |
| **Custom Light** | Paint keys, fill or clear the layout, and set brightness. | USB or 2.4 GHz |
| **Custom Key** | Remap keys to keyboard keys and shortcuts. Media/mouse remaps are unverified; Fn and the volume knob cannot be remapped. | USB or 2.4 GHz |
| **LCD screen** | Upload GIF, PNG, or JPEG to the 240 × 135 display (up to 130 frames). Long GIFs may take several minutes. | USB |
| **LED Strip** | Upload text, images, or GIFs to the 63 × 5 strip (up to 260 frames); stream clock, CPU, or microphone spectrum while the app is open. | USB |
| **Settings** | Adjust screen brightness. Other settings are exposed but not confirmed to work on macOS. | USB |

For hardware test details, see [MacApp/README.md](MacApp/README.md). Protocol research is in [docs/protocol/PROTOCOL.md](docs/protocol/PROTOCOL.md).

## Build from source

### Requirements

- macOS 14 or later
- Xcode Command Line Tools with Swift 5.9 or later
- Homebrew and `libusb`
- The official Windows driver installer, unpacked under `local/official-driver/extracted/app`

The artwork/fonts are taken from the official Windows installer by the build script. The Windows app and installer are not needed at runtime. Their assets remain the property of their respective rights holders; see [Artwork and licensing](#artwork-and-licensing).

```bash
brew install libusb
cd MacApp
./build_app.sh
open build/AMG65.app
```

The build script expects the extracted installer files in `../local/official-driver/extracted/app` relative to `MacApp` and Homebrew's default Apple Silicon paths under `/opt/homebrew`. Place the installer and its extracted files there locally; they are excluded from version control. See [MacApp/README.md](MacApp/README.md) for developer helpers and a source file map.

### Package a DMG

On a Mac with the build requirements installed, run `MacApp/package_dmg.sh`. It builds the app, creates `MacApp/dist/AMG65-macOS.dmg` with an Applications shortcut, verifies the image, and writes a SHA-256 checksum alongside it. Use that same filename as the asset name on every GitHub Release so the README's latest-download link stays stable. If you already have a built app bundle and only want to package that copy, run `SKIP_BUILD=1 MacApp/package_dmg.sh`.

For a public download, use an Apple Developer ID Application certificate and notarize the image:

```bash
cd MacApp
APPLE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="your-notarytool-keychain-profile" \
./package_dmg.sh
```

Create the notarytool keychain profile separately with Apple's `xcrun notarytool store-credentials` command. The app bundle identifier is currently `local.amg65.driver`; replace it with a bundle identifier under a domain you control before making a maintained signed release. The package includes artwork/fonts from the official installer, so confirm you have permission to redistribute those assets before publishing the DMG. After connecting this project to its GitHub repository, publish a release with the DMG named `AMG65-macOS.dmg`, then run `scripts/configure_download_link.sh` to activate the one-click download button. See [MacApp/package_dmg.sh](MacApp/package_dmg.sh).

## Connection notes

- Connect the keyboard with a USB data cable and select the wired connection where applicable.
- The 2.4 GHz receiver supports Lighting, Custom Light, and Custom Key. Connect the keyboard by cable for LCD, LED Strip, and Settings.
- If the keyboard is asleep on battery, press a key and try applying the setting again.
- Do not use the Windows firmware updater on macOS. Firmware updating is outside this project's scope.

## Project status

This is an early, hardware-specific project built by reverse-engineering the Windows companion software and testing decoded commands on an AMG65. Some controls are still untested or have no confirmed effect. See the feature notes for the current status; please include your macOS version, connection type, app version, and relevant steps when reporting an issue. Do not include serial numbers or other private information.

## Acknowledgements

The protocol work was made possible with help from Claude's reverse-engineering skill. The app implementation is an independent community project.

## Artwork and licensing

The Swift source code in this repository has no explicit open-source license yet. Until a license is added, standard copyright applies and others do not have permission to redistribute or modify that code. The original LEOBOG/AULA artwork, fonts, icon, and bundled sample animation are separate third-party assets and are not relicensed by this project. Do not redistribute those assets or a built app containing them unless you have permission from their rights holders. A public release package should omit those assets or include them only with appropriate authorization.

This project is provided as-is, without warranty. It sends configuration commands to a physical keyboard; use it at your own discretion.
