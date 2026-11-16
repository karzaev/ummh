#!/bin/bash
# Package a distribution copy without changing the local app.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/dist/ummh.app"
[[ -d "$APP" ]] || { printf 'Build dist/ummh.app with scripts/build-local.sh first.\n' >&2; exit 1; }
codesign --verify --deep --strict "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'Unexpected app version.\n' >&2; exit 1; }
[[ "$(lipo -archs "$APP/Contents/MacOS/ummh")" == "arm64" ]] || { printf 'Expected the Apple Silicon app.\n' >&2; exit 1; }
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/ummh-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
DMG="$PWD/dist/ummh-$VERSION-arm64-adhoc.dmg"
[[ ! -e "$DMG" ]] || { printf 'Preview already exists: %s\n' "$DMG" >&2; exit 1; }
ditto --noextattr --noqtn --norsrc "$APP" "$STAGING/ummh.app"
cp LICENSE NOTICE.md "$STAGING/ummh.app/Contents/Resources/Licenses/"
/usr/bin/strip -S -x "$STAGING/ummh.app/Contents/MacOS/ummh"
codesign --force --deep --sign - --options runtime --timestamp=none --entitlements resources/entitlements.plist "$STAGING/ummh.app"
codesign --verify --deep --strict "$STAGING/ummh.app"
SIGNATURE="$(codesign -dv --verbose=4 "$STAGING/ummh.app" 2>&1)"
[[ "$SIGNATURE" == *"Signature=adhoc"* && "$SIGNATURE" != *"Authority="* ]] || { printf 'Distribution must use an ad-hoc signature.\n' >&2; exit 1; }
if /usr/bin/strings "$STAGING/ummh.app/Contents/MacOS/ummh" | /usr/bin/grep -E '/Users/[^/]+/|/private/var/folders/' >/dev/null; then
    printf 'Distribution contains a local build path; stop before publishing.\n' >&2
    exit 1
fi
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/READ-ME.txt" <<'NOTICE'
ummh

Drag ummh into Applications.

This build is ad-hoc signed and has not been notarized by Apple. If macOS blocks
opening it, follow https://support.apple.com/en-gb/102445.

Speech models download on first use. Audio and transcripts are processed locally.
NOTICE
diskutil image create from --volumeName "ummh $VERSION" --format UDZO "$STAGING" "$DMG"
hdiutil verify "$DMG"
(cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
printf 'Packaged %s\n' "$DMG"
