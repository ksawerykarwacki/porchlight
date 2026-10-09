#!/bin/bash
# Builds an unsigned release of Porchlight: a disk image holding Porchlight.app, and its checksum.
#
#   ./scripts/release.sh <version>          e.g. ./scripts/release.sh 0.1.0
#
# Writes, into dist/release (or the folder named by PORCHLIGHT_RELEASE_OUT; a relative path is
# taken from the repository root):
#
#   Porchlight-<version>.dmg            Porchlight.app and a link to /Applications
#   Porchlight-<version>.dmg.sha256     in `shasum -a 256` format; check with `shasum -a 256 -c`
#
# What it does not do: the app is ad-hoc signed, not signed with a Developer ID, and not
# notarised, so Gatekeeper will stop it on other people's Macs. Nothing is uploaded, tagged or
# published. The steps that need the owner's Apple Developer account are marked OWNER below and
# listed in packaging/README.md. They are commented out and do not run.
#
# Safe to run again: the image and checksum for the same version are replaced.
set -euo pipefail

die() {
    echo "release.sh: $*" >&2
    exit 1
}

usage() {
    echo "usage: ./scripts/release.sh <version>    (for example 0.1.0 or 0.1.0-rc.1)" >&2
    exit 2
}

[ "$#" -eq 1 ] || usage
VERSION="$1"
# Three numbers, and optionally a pre-release part: 0.1.0, 1.2.3-rc.1. No leading "v": the tag is
# v<version>, the version is not.
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$ ]]; then
    echo "release.sh: '$VERSION' is not a version. Expected MAJOR.MINOR.PATCH, optionally with a" >&2
    echo "pre-release part, and without a leading v: 0.1.0, 0.1.0-rc.1" >&2
    usage
fi

for tool in swift codesign hdiutil shasum ditto lipo; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool was not found; this script needs macOS with the Command Line Tools"
done

# The signing and notarisation steps further down are commented out. Asking for them is therefore
# an error, said before anything is built, and not a quiet ad-hoc build that looks like a signed one.
for variable in PORCHLIGHT_SIGN_IDENTITY PORCHLIGHT_NOTARY_PROFILE; do
    if [ -n "${!variable:-}" ]; then
        die "$variable is set, but that step is not enabled in this script yet (see the OWNER blocks in scripts/release.sh and packaging/README.md). Unset it to build the unsigned image."
    fi
done

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/dist/Porchlight.app"
NAME="Porchlight-$VERSION.dmg"

OUT="${PORCHLIGHT_RELEASE_OUT:-dist/release}"
[ -n "$OUT" ] || die "PORCHLIGHT_RELEASE_OUT is empty"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

# Everything half-made lives in one temporary folder, removed however the script ends. The image
# is built there and moved into place only once it has been verified, so a failed run leaves
# neither a partial image nor a checksum for one. No image is ever mounted.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/porchlight-release.XXXXXX")"
cleanup() {
    rm -rf "$WORK"
}
trap cleanup EXIT

# An image or checksum left by an earlier run for this version must not survive a failed run.
rm -f "$OUT/$NAME" "$OUT/$NAME.sha256"

echo "==> Building Porchlight.app $VERSION"
./scripts/make-app.sh "$VERSION"
[ -x "$APP/Contents/MacOS/Porchlight" ] || die "make-app.sh did not produce $APP"
[ -x "$APP/Contents/Helpers/porchlight" ] || die "the command-line tool is missing from $APP"
BUILT="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
[ "$BUILT" = "$VERSION" ] || die "the bundle says version '$BUILT', expected '$VERSION'"

# --- OWNER: Developer ID signing -------------------------------------------------------------
# Not done. Needs an Apple Developer account and a "Developer ID Application" certificate in the
# keychain. The command-line tool inside the bundle is signed first, then the bundle, both with
# the hardened runtime, which notarisation requires. The entitlements file does not exist yet;
# see packaging/README.md, steps 2 and 4.
#
#   PORCHLIGHT_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#
#   codesign --force --options runtime --timestamp \
#       --sign "$PORCHLIGHT_SIGN_IDENTITY" "$APP/Contents/Helpers/porchlight"
#   codesign --force --options runtime --timestamp \
#       --entitlements packaging/Porchlight.entitlements \
#       --sign "$PORCHLIGHT_SIGN_IDENTITY" "$APP"
#
# Until those lines are enabled, a set PORCHLIGHT_SIGN_IDENTITY stops the script at the start
# (see the check near the top).
echo "==> Signing: skipped. PORCHLIGHT_SIGN_IDENTITY is not set; the app keeps its ad-hoc signature."
# ---------------------------------------------------------------------------------------------

codesign --verify --deep --strict "$APP" || die "$APP does not pass signature verification"

echo "==> Building $NAME"
STAGE="$WORK/stage"
mkdir "$STAGE"
# ditto keeps the signature's extended attributes and the bundle's symlinks intact.
ditto "$APP" "$STAGE/Porchlight.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Porchlight $VERSION" -srcfolder "$STAGE" \
    -fs HFS+ -format UDZO -ov "$WORK/$NAME"
hdiutil verify -quiet "$WORK/$NAME" || die "the disk image failed verification"

# --- OWNER: sign and notarise the image ------------------------------------------------------
# Not done. Needs the signing step above, and notary credentials stored once in the keychain:
#
#   xcrun notarytool store-credentials porchlight-notary \
#       --apple-id you@example.com --team-id TEAMID        (asks for an app-specific password)
#   PORCHLIGHT_NOTARY_PROFILE=porchlight-notary
#
#   codesign --force --timestamp --sign "$PORCHLIGHT_SIGN_IDENTITY" "$WORK/$NAME"
#   xcrun notarytool submit "$WORK/$NAME" --keychain-profile "$PORCHLIGHT_NOTARY_PROFILE" --wait
#   xcrun stapler staple "$WORK/$NAME"
#   spctl --assess --type open --context context:primary-signature --verbose "$WORK/$NAME"
#
# This has to stay before the checksum: signing and stapling both change the image.
echo "==> Notarisation: skipped. PORCHLIGHT_NOTARY_PROFILE is not set; the image is not notarised."
# ---------------------------------------------------------------------------------------------

mv -f "$WORK/$NAME" "$OUT/$NAME"
# Written from inside the folder so the file names the image without a path and
# `shasum -a 256 -c Porchlight-<version>.dmg.sha256` works wherever the two files end up.
(cd "$OUT" && shasum -a 256 "$NAME" > "$NAME.sha256.tmp" && mv -f "$NAME.sha256.tmp" "$NAME.sha256")

echo
echo "Image:        $OUT/$NAME"
echo "Checksum:     $(cut -d ' ' -f 1 "$OUT/$NAME.sha256")"
echo "Architecture: $(lipo -archs "$APP/Contents/MacOS/Porchlight")"
echo "Signature:    ad-hoc. Not signed with a Developer ID and not notarised."
echo "Nothing was uploaded, tagged or published. Next steps: packaging/README.md"
