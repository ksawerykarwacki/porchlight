#!/bin/bash
# Assembles dist/Porchlight.app from the SwiftPM build. No Xcode needed.
# The bundle is ad-hoc signed: good for local use, not for distribution.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.0.1}"
APP="dist/Porchlight.app"

swift build -c release --product PorchlightApp
swift build -c release --product porchlight
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers"
cp "$BIN/PorchlightApp" "$APP/Contents/MacOS/Porchlight"
# Not next to the app binary: the default macOS file system is case-insensitive, so
# "porchlight" would overwrite "Porchlight".
cp "$BIN/porchlight" "$APP/Contents/Helpers/porchlight"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>io.github.ksawerykarwacki.porchlight</string>
    <key>CFBundleName</key>
    <string>Porchlight</string>
    <key>CFBundleExecutable</key>
    <string>Porchlight</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "Built $APP"
