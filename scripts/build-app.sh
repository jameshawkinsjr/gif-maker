#!/bin/bash
#
# Builds "GIF Maker.app" into ./build.
#
#   scripts/build-app.sh              build the app
#   scripts/build-app.sh --install    build, then copy it to /Applications
#   scripts/build-app.sh --open       build, then launch it
#
# Environment:
#   CODESIGN_IDENTITY   Signing identity to use. Defaults to the first
#                       "Apple Development" or "Developer ID Application"
#                       certificate in your keychain, or ad-hoc ("-") if there
#                       is none.
#   BUNDLE_ID           Bundle identifier (default: app.gifmaker.GifMaker).
#   VERSION             Version string (default: 1.0.0).
#
# Why signing matters: macOS ties the Screen Recording permission to the app's
# signature. With a real certificate the permission survives rebuilds. An
# ad-hoc signature changes on every build, so you'd have to re-allow the app
# in System Settings each time you rebuild.

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="GIF Maker"
BUNDLE_ID="${BUNDLE_ID:-app.gifmaker.GifMaker}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

INSTALL=0
OPEN=0
for argument in "$@"; do
    case "$argument" in
        --install) INSTALL=1 ;;
        --open) OPEN=1 ;;
        -h | --help)
            sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown option: $argument" >&2
            exit 64
            ;;
    esac
done

echo "==> Compiling (release)"
swift build -c release
BINARY="$(swift build -c release --show-bin-path)/GifMaker"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/GifMaker"
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" \
    Resources/Info.plist > "$APP/Contents/Info.plist"

echo "==> Drawing the icon"
ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null |
        awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')"
fi
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
    echo "==> Signing with a certificate from your keychain"
    if ! codesign --force --sign "$IDENTITY" "$APP"; then
        echo "    Certificate signing failed; falling back to an ad-hoc signature." >&2
        codesign --force --sign - "$APP"
    fi
else
    echo "==> Signing ad-hoc (no signing certificate found)"
    codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

echo "==> Built $APP"

if [ "$INSTALL" = 1 ]; then
    DESTINATION="/Applications/$APP_NAME.app"
    echo "==> Installing to $DESTINATION"
    rm -rf "$DESTINATION"
    ditto "$APP" "$DESTINATION"
    APP="$DESTINATION"
fi

if [ "$OPEN" = 1 ]; then
    open "$APP"
fi
