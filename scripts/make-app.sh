#!/bin/bash
# Assembles dist/Porchlight.app from the SwiftPM build. No Xcode needed.
# The bundle is ad-hoc signed: good for local use, not for distribution.
#
#   ./scripts/make-app.sh [version]
#
# The version goes into the bundle's Info.plist. It is the first argument, else the VERSION
# environment variable, else 0.0.1.
# PORCHLIGHT_SWIFT_FLAGS adds flags to every `swift build` (see below).
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:-${VERSION:-0.0.1}}"
# The version is written into XML below, so only the characters a version can hold are let through.
if [[ ! "$VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z.+-]*$ ]]; then
    echo "make-app.sh: '$VERSION' is not a version (expected something like 0.1.0)" >&2
    exit 2
fi
APP="dist/Porchlight.app"

# Extra flags for every `swift build`, split on spaces. The Homebrew formula passes
# --disable-sandbox: Homebrew builds inside its own sandbox, and SwiftPM's cannot nest in it.
read -r -a SWIFT_FLAGS <<< "${PORCHLIGHT_SWIFT_FLAGS:-}"
build() { swift build -c release ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} "$@"; }

build --product PorchlightApp
build --product porchlight
build --product PorchlightIconTool
BIN="$(build --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"

# The icon is drawn by the app's own code, then packed by the system's iconutil.
ICONSET="$(mktemp -d)/Porchlight.iconset"
"$BIN/PorchlightIconTool" "$ICONSET"
iconutil -c icns -o "$APP/Contents/Resources/Porchlight.icns" "$ICONSET"
rm -rf "$(dirname "$ICONSET")"
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
    <key>CFBundleIconFile</key>
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
