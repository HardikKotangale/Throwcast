#!/bin/bash
# Builds build/Throwcast.app. Signed ad hoc: a fresh build may ask for Screen Recording again.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product Throwcast
APP=build/Throwcast.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Throwcast "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.throwcast.sender</string>
  <key>CFBundleName</key><string>Throwcast</string>
  <key>CFBundleExecutable</key><string>Throwcast</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Throwcast finds your TV and streams your screen to it over your local network.</string>
  <key>NSBonjourServices</key><array><string>_samsungmsf._tcp</string></array>
</dict></plist>
P
codesign --force --sign - "$APP"
echo "$APP"
