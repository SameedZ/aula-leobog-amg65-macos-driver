#!/bin/bash
# Build a drag-to-Applications DMG for AMG65.
# Optional: APPLE_SIGNING_IDENTITY="Developer ID Application: ..." ./package_dmg.sh
# Optional notarization: NOTARY_PROFILE="profile-name" APPLE_SIGNING_IDENTITY="..." ./package_dmg.sh
set -euo pipefail
cd "$(dirname "$0")"

APP="build/AMG65.app"
DIST="dist"
IDENTITY="${APPLE_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
SKIP_BUILD="${SKIP_BUILD:-0}"

if [ "$SKIP_BUILD" = "1" ]; then
  [ -d "$APP" ] || { echo "No existing app bundle found at $APP."; exit 1; }
  echo "Using existing app bundle at $APP."
else
  echo "Building fresh app bundle..."
  ./build_app.sh
fi

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
NAME="AMG65-macOS"
DMG="$DIST/${NAME}.dmg"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/amg65-dmg.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

if [ -n "$NOTARY_PROFILE" ] && [ -z "$IDENTITY" ]; then
  echo "Notarization requires APPLE_SIGNING_IDENTITY to be set."
  exit 1
fi

if [ -n "$IDENTITY" ]; then
  echo "Signing app with Developer ID..."
  codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  echo "No Developer ID identity provided; this DMG will contain the local ad-hoc signed build."
  echo "For downloads outside your own Mac, sign and notarize the app (see README)."
fi

mkdir -p "$DIST"
ditto "$APP" "$STAGE/AMG65.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create \
  -volname "LEOBOG AMG65 ${VERSION}" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG"
hdiutil verify "$DMG"

if [ -n "$NOTARY_PROFILE" ]; then
  echo "Submitting DMG for notarization..."
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi

(cd "$DIST" && shasum -a 256 "${NAME}.dmg" > "${NAME}.dmg.sha256")
echo "Created: $(pwd)/$DMG"
echo "Checksum: $(pwd)/$DIST/${NAME}.dmg.sha256"
