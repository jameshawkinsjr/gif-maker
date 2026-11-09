#!/bin/bash
#
# Builds "GIF Maker.app" and packages it as a disk image for download:
# build/GIF-Maker-<version>.dmg, compressed, signed, with the usual
# drag-to-Applications window.
#
#   scripts/make-dmg.sh
#
# Environment (see scripts/common.sh for the signing variables):
#   NOTARY_PROFILE      Name of a notarytool keychain profile. When set, and the
#                       app is signed with a Developer ID certificate, the image
#                       is notarized and stapled so it opens on other Macs
#                       without a Gatekeeper warning. Create the profile once
#                       with `xcrun notarytool store-credentials`.
#
# Without a Developer ID certificate the image is still signed, but macOS will
# warn people who download it that it can't be verified; they can allow it
# under System Settings > Privacy & Security.

set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/common.sh

APP="$BUILD_DIR/$APP_NAME.app"
DMG="$BUILD_DIR/GIF-Maker-$VERSION.dmg"
RW_IMAGE="$BUILD_DIR/GIF-Maker-$VERSION-rw.dmg"
STAGING="$BUILD_DIR/dmg"
MOUNT_POINT="/Volumes/$APP_NAME"

# The window layout. Keep in sync with scripts/make-dmg-background.swift.
WINDOW_WIDTH=560
WINDOW_HEIGHT=360
APP_ICON_X=150
APP_ICON_Y=150
APPLICATIONS_X=410
APPLICATIONS_Y=150

if [ "$#" -gt 0 ]; then
    case "$1" in
        -h | --help)
            sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 64
            ;;
    esac
fi

if [ -d "$MOUNT_POINT" ]; then
    echo "A volume named \"$APP_NAME\" is already mounted. Eject it first." >&2
    exit 1
fi

scripts/build-app.sh

echo "==> Staging the disk image contents"
rm -rf "$STAGING" "$RW_IMAGE" "$DMG"
mkdir -p "$STAGING/.background"
ditto "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"

BACKGROUNDS="$BUILD_DIR/dmg-background"
rm -rf "$BACKGROUNDS"
swift scripts/make-dmg-background.swift "$BACKGROUNDS"
tiffutil -cathidpicheck "$BACKGROUNDS/background.png" "$BACKGROUNDS/background@2x.png" \
    -out "$STAGING/.background/background.tiff" >/dev/null
rm -rf "$BACKGROUNDS"

echo "==> Creating the image"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGING" -fs HFS+ -format UDRW -ov "$RW_IMAGE"
hdiutil attach -quiet -readwrite -noverify -noautoopen "$RW_IMAGE"
trap 'hdiutil detach -quiet "$MOUNT_POINT" 2>/dev/null || true' EXIT

echo "==> Arranging the Finder window"
# Finder writes the layout into the volume's .DS_Store. If Finder can't be
# scripted from here (the first run asks for permission), the image still works,
# it just opens as a plain folder.
if ! osascript - "$APP_NAME" "$WINDOW_WIDTH" "$WINDOW_HEIGHT" $APP_ICON_X $APP_ICON_Y $APPLICATIONS_X $APPLICATIONS_Y <<'EOF'
on run {volumeName, windowWidth, windowHeight, appX, appY, applicationsX, applicationsY}
    set windowWidth to windowWidth as integer
    set windowHeight to windowHeight as integer
    -- The window's bounds include its title bar; add that to the content height.
    set titleBarHeight to 28
    tell application "Finder"
        tell disk volumeName
            -- First pass: the window style and view options. These have to be
            -- saved and the window reopened before placing icons, otherwise
            -- Finder still snaps the positions to its grid.
            open
            set theWindow to container window
            set current view of theWindow to icon view
            set toolbar visible of theWindow to false
            set statusbar visible of theWindow to false
            set bounds of theWindow to {200, 120, 200 + windowWidth, 120 + windowHeight + titleBarHeight}
            set theOptions to icon view options of theWindow
            set arrangement of theOptions to not arranged
            set icon size of theOptions to 128
            set text size of theOptions to 13
            set label position of theOptions to bottom
            set background picture of theOptions to file ".background:background.tiff"
            close
            -- Second pass: icon positions (their centres, in points from the
            -- top-left of the content area).
            open
            set theWindow to container window
            set position of item (volumeName & ".app") of theWindow to {appX as integer, appY as integer}
            set position of item "Applications" of theWindow to {applicationsX as integer, applicationsY as integer}
            -- Keep the hidden support items out of the way for people who show hidden files.
            repeat with hiddenName in {".background", ".fseventsd"}
                try
                    set position of item hiddenName of theWindow to {(windowWidth as integer) + 200, appY as integer}
                end try
            end repeat
            update without registering applications
            delay 1
            close
        end tell
    end tell
end run
EOF
then
    echo "    Couldn't arrange the window; the image will open as a plain folder." >&2
fi

# Give the volume the app's icon. This has to happen after the Finder step:
# Finder removes the icon file and its flag when it saves the window layout.
# The flag is the Finder-info bit that `SetFile -a C` used to set.
cp "$APP/Contents/Resources/AppIcon.icns" "$MOUNT_POINT/.VolumeIcon.icns"
xattr -wx com.apple.FinderInfo \
    0000000000000000040000000000000000000000000000000000000000000000 "$MOUNT_POINT"
chflags hidden "$MOUNT_POINT/.background" 2>/dev/null || true
sync
sleep 1
hdiutil detach -quiet "$MOUNT_POINT"
trap - EXIT

echo "==> Compressing"
hdiutil convert -quiet "$RW_IMAGE" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -f "$RW_IMAGE"
rm -rf "$STAGING"

IDENTITY="$(signing_identity)"
if [ "$IDENTITY" != "-" ]; then
    echo "==> Signing the image"
    if is_developer_id "$IDENTITY"; then
        codesign --sign "$IDENTITY" --timestamp "$DMG"
    else
        codesign --sign "$IDENTITY" "$DMG"
    fi
fi

if [ -n "${NOTARY_PROFILE:-}" ]; then
    if is_developer_id "$IDENTITY"; then
        echo "==> Notarizing (this can take a few minutes)"
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
    else
        echo "    NOTARY_PROFILE is set, but notarization needs a Developer ID certificate; skipping." >&2
    fi
elif is_developer_id "$IDENTITY"; then
    echo "    Not notarized: set NOTARY_PROFILE to notarize and staple the image." >&2
else
    echo "    Signed with a development certificate, so macOS will warn before opening the app." >&2
    echo "    A Developer ID certificate plus NOTARY_PROFILE removes the warning." >&2
fi

echo "==> Built $DMG"
du -h "$DMG" | cut -f1 | sed 's/^/    size: /'
shasum -a 256 "$DMG" | cut -d' ' -f1 | sed 's/^/    sha256: /'
