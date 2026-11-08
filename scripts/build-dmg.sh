#!/bin/bash
# Builds dist/Throwcast.dmg: the Mac app, a link to Applications, and the browser extension.
#
#   scripts/build-dmg.sh
#
# Signing, best first:
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)"   signs for other Macs
#   NOTARY_PROFILE=<keychain profile>                         also notarizes and staples, so it opens with a double-click
#   (neither)                                                 signs ad hoc; other Macs need Open Anyway the first time
# Make a notary profile once with: xcrun notarytool store-credentials <name>
#
# The TV app isn't inside: Samsung only installs a Developer Mode app signed for that TV,
# so each person builds their own from tv/ (see the README).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Throwcast"
VERSION=$(sed -n 's/^version: *\([0-9.]*\).*/\1/p' app/pubspec.yaml)
DIST="$PWD/dist"
STAGING="$DIST/dmg-staging"
DMG="$DIST/${APP_NAME}.dmg"
SIGN_ID=${SIGN_ID:--}

echo "=== Building ${APP_NAME} ${VERSION} ==="
# Picks up new engine files, which CocoaPods only sees on install.
(cd app && flutter pub get >/dev/null && cd macos && pod install >/dev/null)
(cd app && flutter build macos --release | tail -1)
APP="$PWD/app/build/macos/Build/Products/Release/${APP_NAME}.app"
test -d "$APP" || { echo "ERROR: ${APP} was not built"; exit 1; }

echo "=== Signing (${SIGN_ID}) ==="
# Stray extended attributes break signatures, so they go first.
xattr -cr "$APP"
if [ "$SIGN_ID" = "-" ]; then
  codesign --force --deep --sign - "$APP"
else
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_ID" "$APP"
fi
codesign --verify --deep --strict "$APP"

echo "=== Staging ==="
rm -rf "$STAGING" && mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
mkdir -p "$DIST" "$STAGING/Browser Extension"
cp -R extension/. "$STAGING/Browser Extension/"
cat > "$STAGING/Read Me First.txt" <<EOF
Throwcast ${VERSION}

1. Drag Throwcast to Applications, then open it.
   If macOS says it can't check the app, open System Settings > Privacy & Security
   and choose Open Anyway. This is needed once, for builds that aren't notarized.
   Updating from an earlier version? Allow Screen Recording again: in System
   Settings > Privacy & Security > Screen Recording, remove Throwcast with the
   minus button, then open Throwcast and allow it.
2. Browser extension: open chrome://extensions (or brave://extensions), turn on
   Developer mode, choose Load unpacked, and pick a copy of the Browser Extension
   folder from your Mac, not from this disk image. It casts a browser tab by itself,
   even without the Mac app.
3. TV app: Samsung only installs apps signed for your own TV, so it's built from
   the source once. Follow "2. The TV app" in docs/INSTALL.md on the project page:
   https://github.com/HardikKotangale/Throwcast/blob/main/docs/INSTALL.md
4. iPhone remote (optional): an iPhone can't install apps from a disk image, so it's
   built from the source with Xcode and your own Apple ID. Follow "4. The iPhone
   remote" in docs/INSTALL.md. It controls the Mac app, or the TV when the browser
   extension casts by itself.

Only tested on a Samsung AU8000 55" TV.
EOF

echo "=== Creating DMG ==="
# dmgbuild lays out the window (background, icon spots, no toolbar) without driving Finder.
VENV="$DIST/.venv"
[ -x "$VENV/bin/dmgbuild" ] || { python3 -m venv "$VENV" && "$VENV/bin/pip" install --quiet dmgbuild; }
# One background with both sizes, so Retina screens get the sharp one.
tiffutil -cathidpicheck scripts/dmg/background.png scripts/dmg/background@2x.png -out "$DIST/background.tiff" >/dev/null
rm -f "$DMG"
"$VENV/bin/dmgbuild" -s scripts/dmg/settings.py -D app="$APP" -D staging="$STAGING" -D background="$DIST/background.tiff" \
  "${APP_NAME} ${VERSION}" "$DMG" >/dev/null
rm -rf "$STAGING" "$DIST/background.tiff"

if [ "$SIGN_ID" != "-" ]; then
  codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "=== Notarizing ==="
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi

cp "$DMG" "$DIST/${APP_NAME}-${VERSION}.dmg"
echo "=== Done ==="
ls -lh "$DMG" "$DIST/${APP_NAME}-${VERSION}.dmg"
