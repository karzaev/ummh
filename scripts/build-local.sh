#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIGURATION="${1:-release}"
case "$CONFIGURATION" in debug|release) ;; *) printf 'Use debug or release.\n' >&2; exit 1 ;; esac
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/"Apple Development:/ { print $2 }')}"
if [[ -z "$SIGNING_IDENTITY" || "$SIGNING_IDENTITY" == *$'\n'* || "$SIGNING_IDENTITY" == "-" ]]; then
    printf 'Set CODE_SIGN_IDENTITY to one valid Apple signing identity; ad-hoc signing breaks permission persistence.\n' >&2
    exit 1
fi
swift build -c "$CONFIGURATION"
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
APP="$PWD/dist/ummh.app"
if pgrep -f "^$APP/Contents/MacOS/ummh$" >/dev/null; then
    printf 'Quit the running ummh app before replacing its bundle.\n' >&2
    exit 1
fi
if [[ -d "$APP" ]]; then chmod -R u+w "$APP"; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ummh" "$APP/Contents/MacOS/ummh"
cp resources/Info.plist "$APP/Contents/Info.plist"
cp resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
ditto resources/sounds "$APP/Contents/Resources/sounds"
mkdir -p "$APP/Contents/Resources/Licenses"
cp LICENSE NOTICE.md "$APP/Contents/Resources/Licenses/"
cp .build/checkouts/FluidAudio/LICENSE "$APP/Contents/Resources/Licenses/FluidAudio-LICENSE"
ditto .build/checkouts/FluidAudio/ThirdPartyLicenses "$APP/Contents/Resources/Licenses/FluidAudio"
for bundle in "$BIN_DIR"/*.bundle; do
    [[ -d "$bundle" ]] || continue
    dest="$APP/Contents/Resources/$(basename "$bundle")"
    ditto "$bundle" "$dest"
    if [[ ! -f "$dest/Info.plist" ]]; then
        /usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string BNDL' "$dest/Info.plist"
    fi
done
codesign --force --deep --sign "$SIGNING_IDENTITY" --options runtime --timestamp=none --entitlements resources/entitlements.plist "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built %s\n' "$APP"
