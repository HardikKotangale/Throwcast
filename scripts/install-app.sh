#!/bin/bash
# Builds the Flutter app and installs /Applications/Throwcast.app.
set -euo pipefail
cd "$(dirname "$0")/.."
# Picks up new engine files, which CocoaPods only sees on install.
(cd app && flutter pub get >/dev/null && cd macos && pod install >/dev/null)
(cd app && flutter build macos --release)
APP=app/build/macos/Build/Products/Release/Throwcast.app
# A stable identity keeps Screen Recording and Local Network approvals across rebuilds.
# Falls back to ad hoc on a Mac without it, where each rebuild needs approving again.
IDENTITY="Throwcast Local Signing"
security find-certificate -c "$IDENTITY" >/dev/null 2>&1 || IDENTITY=-
codesign --force --deep --sign "$IDENTITY" "$APP"
rm -rf /Applications/Throwcast.app
cp -R "$APP" /Applications/Throwcast.app
echo /Applications/Throwcast.app
