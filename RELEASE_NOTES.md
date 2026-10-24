# Release notes

This file tracks user-facing changes to the LEOBOG AMG65 macOS app. Published releases should also have a GitHub Release page with the matching version and downloadable package.

## Unreleased

- Prepare the first public macOS release.
- Confirm release packaging, signing/notarization status, and permitted handling of the original LEOBOG/AULA artwork before publishing a downloadable app bundle.
- Added a DMG packaging script that builds a fresh app, creates a drag-to-Applications disk image, verifies it, and writes a SHA-256 checksum. Developer ID signing and notarization are optional script settings.
- Added `scripts/configure_download_link.sh` to generate the README's direct latest-release download link from the connected GitHub `origin` remote.

## 0.1.0 — initial project release (draft)

This is the first community-built macOS control app for the LEOBOG AMG65 keyboard. It communicates directly over USB HID without installing a kernel driver.

### Included

- Lighting effect and colour controls
- Per-key Custom Light controls
- Custom Key remapping for keyboard keys and shortcuts
- LCD image and GIF upload over USB
- LED Strip text/image/GIF upload and live clock, CPU, and microphone modes
- Screen brightness setting
- Protocol notes and developer build instructions

### Compatibility and limitations

- Requires macOS 14 or later.
- Lighting, Custom Light, and Custom Key work over USB and the 2.4 GHz receiver. LCD, LED Strip, and Settings require USB.
- Some controls have not been verified or may have no effect on macOS. In particular, media/mouse remaps, boot animation upload, time sync display behavior, and several Settings options remain unverified.
- No firmware update capability is included.
- The local preview package is `MacApp/dist/AMG65-macOS.dmg`, with checksum `MacApp/dist/AMG65-macOS.dmg.sha256`. Upload both as assets on the GitHub Release and replace this draft with final installation/signing notes before publishing. Keep the DMG asset name stable across releases so the README direct-download link always points at the latest version.
