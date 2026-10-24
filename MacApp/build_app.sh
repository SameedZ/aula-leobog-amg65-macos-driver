#!/bin/bash
# Builds AMG65.app. Artwork and fonts are copied from the unpacked Windows
# installer (../local/official-driver/extracted/app) — they belong to AULA/LEOBOG, so keep the
# built app for personal use only.
set -euo pipefail
cd "$(dirname "$0")"

SRC_ART="../local/official-driver/extracted/app"
APP="build/AMG65.app"

[ -d "$SRC_ART/skins/theme1" ] || { echo "Missing $SRC_ART — unpack the driver installer first."; exit 1; }

swift build -c release
BIN="$(swift build -c release --show-bin-path)/AMG65"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Skin" "$APP/Contents/Resources/Fonts"
cp "$BIN" "$APP/Contents/MacOS/AMG65"
cp -R "$SRC_ART/skins/theme1/." "$APP/Contents/Resources/Skin/"
cp "$SRC_ART/font/"OpenSans-*.ttf "$APP/Contents/Resources/Fonts/"
cp "$SRC_ART/KeyboardLayout.xml" "$APP/Contents/Resources/"
cp "$SRC_ART/gif/LEOBOG AMG65/0.gif" "$APP/Contents/Resources/DefaultLCD.gif"

# Bundle libusb (Homebrew) so the app runs without Homebrew installed.
mkdir -p "$APP/Contents/Frameworks"
cp /opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib "$APP/Contents/Frameworks/"
chmod u+w "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
install_name_tool -id @rpath/libusb-1.0.0.dylib "$APP/Contents/Frameworks/libusb-1.0.0.dylib"
install_name_tool -change /opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib @executable_path/../Frameworks/libusb-1.0.0.dylib "$APP/Contents/MacOS/AMG65"

# App icon from the original .ico
if command -v sips >/dev/null; then
  sips -s format icns "$SRC_ART/skins/theme1/DeviceDriver.ico" --out "$APP/Contents/Resources/AppIcon.icns" >/dev/null 2>&1 || true
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AMG65</string>
  <key>CFBundleDisplayName</key><string>LEOBOG AMG65</string>
  <key>CFBundleIdentifier</key><string>local.amg65.driver</string>
  <key>CFBundleExecutable</key><string>AMG65</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSMicrophoneUsageDescription</key><string>The LED Strip's Music mode turns sound from the microphone into a live spectrum on the keyboard.</string>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP" >/dev/null
echo "Built $(pwd)/$APP"
