#!/bin/bash
#
# Builds "GIF Maker.app" into ./build.
#
#   scripts/build-app.sh              build the app
#   scripts/build-app.sh --install    build, then copy it to /Applications
#   scripts/build-app.sh --open       build, then launch it
#
# Environment (see scripts/common.sh):
#   CODESIGN_IDENTITY   Signing identity to use. Defaults to the first
#                       "Developer ID Application" certificate in your keychain,
#                       then the first "Apple Development" one, or ad-hoc ("-")
#                       if there is neither.
#   BUNDLE_ID           Bundle identifier (default: app.gifmaker.GifMaker).
#   VERSION             Version string (default: 1.0.0).
#
# Why signing matters: macOS ties the Screen Recording permission to the app's
# signature. With a real certificate the permission survives rebuilds. An
# ad-hoc signature changes on every build, so you'd have to re-allow the app
# in System Settings each time you rebuild.

set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/common.sh

BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
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
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN_DIR/GifMaker" "$APP/Contents/MacOS/GifMaker"
# The MCP server for AI agents (see the README). Helpers is the conventional
# home for extra command-line tools inside a bundle.
cp "$BIN_DIR/gifmaker-mcp" "$APP/Contents/Helpers/gifmaker-mcp"
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" \
    Resources/Info.plist > "$APP/Contents/Info.plist"

echo "==> Drawing the icon"
ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

IDENTITY="$(signing_identity)"
SIGN_FLAGS=()
if [ "$IDENTITY" != "-" ]; then
    echo "==> Signing with a certificate from your keychain"
    # The hardened runtime and a secure timestamp are both required for
    # notarization. The timestamp needs network access, so it's only requested
    # for Developer ID signing, where it matters.
    SIGN_FLAGS=(--options runtime)
    if is_developer_id "$IDENTITY"; then
        SIGN_FLAGS+=(--timestamp)
    fi
else
    echo "==> Signing ad-hoc (no signing certificate found)"
fi
# Nested code has to be signed before the bundle that contains it.
sign() {
    if ! codesign --force --sign "$IDENTITY" ${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"} "$1"; then
        echo "    Certificate signing failed; falling back to an ad-hoc signature." >&2
        codesign --force --sign - "$1"
    fi
}
sign "$APP/Contents/Helpers/gifmaker-mcp"
sign "$APP"
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
