# GIF Maker

A small, native macOS app for recording part of your screen and turning it into a GIF (or MP4). Its workflow is modelled on GIPHY Capture: frame an area, hit record, trim, export. It has no account, no upload and no analytics — recordings stay on your Mac.

> Not affiliated with GIPHY.

## Features

### Capture

- A see-through capture frame that floats above other apps. Drag the bar to move it, drag the edges or corners to resize it, or set an exact size.
- The inside of the frame is click-through, so you can keep using the app you're recording.
- Start and stop with the record button, the menu bar icon, or a global keyboard shortcut (⌃⌥⌘G by default).
- Clicking record doesn't steal focus from the app being recorded.
- Optional mouse pointer and click highlights. Recordings stop automatically after a configurable limit (30 seconds by default).
- Every clip is kept in a strip under the frame until you delete it, so you can come back and re-export.

### Edit

- Trim the start and end on a filmstrip.
- Loop type: normal, reverse, or ping-pong.
- Output size, frame rate (10 / 15 / 24 / 30 fps) and playback speed (0.25× – 4×).
- Captions with a choice of text style, colour, size, position, timing and animation (fade, scale, drop, move).
- See the exact file size before saving.

### Export

- Save as GIF or MP4, or copy a GIF straight to the clipboard.

## Requirements

- macOS 14 or later
- Xcode 16 or later (or the matching Command Line Tools) to build

## Install

Download `GIF-Maker-<version>.dmg` from the [releases page](../../releases), open it, and drag **GIF Maker** into your Applications folder.

Unless the release notes say it is notarized, macOS will refuse to open the app the first time because it isn't signed with an Apple-issued Developer ID. To allow it: try to open the app once, then go to *System Settings → Privacy & Security*, scroll down to the message about GIF Maker, and click **Open Anyway**. You only need to do this once.

The first time you record, macOS asks for **Screen Recording** permission. Allow GIF Maker under *System Settings → Privacy & Security → Screen & System Audio Recording*, then quit and reopen the app. Recent versions of macOS also ask you to re-confirm this from time to time for any app that records the screen.

### Updates

GIF Maker can update itself from a folder that new builds are published to — a folder on your Mac, or one that syncs between Macs such as iCloud Drive or Dropbox. It never contacts a server.

1. Open *Settings → Updates* and choose the folder ([Making a release](#making-a-release) explains how builds get there).
2. GIF Maker looks in the folder when it starts and about once a day after that, or when you click **Check Now**. Turn off *Check for updates automatically* to check only by hand.
3. When a newer build is there, Settings and the menu bar menu say so. Click **Install and Restart**: GIF Maker checks the build, replaces itself and reopens. If the new version doesn't start, the one you had is put back.

Things to know:

- **Only use a folder you control.** These builds aren't signed with a Developer ID, so GIF Maker can't tell who made one. It checks that the disk image matches its published checksum, that the app inside is GIF Maker, that it is newer, and that its code signature is intact — and then installs it. Anyone who can write to the folder can therefore put software on your Mac.
- **Screen Recording permission may need allowing again.** macOS ties the permission to the app's signature. An update signed with the same certificate as the version you have keeps it. An ad-hoc signed build never matches the one before, so after each update you have to turn GIF Maker off and on again under *Privacy & Security → Screen & System Audio Recording*. GIF Maker tells you when this applies.
- A build that is still syncing is skipped until it has arrived completely.
- GIF Maker won't restart to update while it is recording or exporting.
- If GIF Maker can't replace itself where it is installed (for example, in a folder only an administrator can change), it shows you the disk image instead so you can drag the app across yourself. **Show Disk Image** does the same at any time.
- What the last install did is logged in `~/Library/Logs/GIF Maker/Update.log`.

## Build from source

```sh
scripts/build-app.sh            # builds build/GIF Maker.app
scripts/build-app.sh --open     # ...and launches it
scripts/build-app.sh --install  # ...and copies it to /Applications
```

### A note on code signing

macOS ties the Screen Recording permission to the app's code signature. The build script signs with the first *Developer ID Application* or *Apple Development* certificate it finds in your keychain, which keeps the permission valid across rebuilds. Without a certificate it falls back to an ad-hoc signature; that works, but you'll need to re-allow the app after each rebuild. Set `CODESIGN_IDENTITY` to choose an identity explicitly (`-` forces ad-hoc).

## Using it

1. Position the green frame over what you want to record.
2. Press the record button (or the shortcut). The frame turns red while recording.
3. Press it again to stop. The clip appears in the strip and opens in the editor.
4. Trim, adjust the options, add captions, then **Save As…** or **Copy GIF**.

The gear button holds the capture options (cursor, click highlights, exact size) and Settings, where you can change the shortcut and the recording limit, and set up [updates](#updates).

## Use it from an AI agent (MCP)

GIF Maker includes a [Model Context Protocol](https://modelcontextprotocol.io) server, so an AI agent such as Claude Code can record the screen and make GIFs on its own — for example to show how an app works, while it drives the app with its other tools. It uses the same recorder and encoder as the app, and GIF Maker doesn't need to be open.

The server is inside the app bundle. To add it to Claude Code:

```sh
claude mcp add --scope user gif-maker -- "/Applications/GIF Maker.app/Contents/Helpers/gifmaker-mcp"
```

Other MCP clients take the same path as a `stdio` server command, with no arguments.

| Tool | What it does |
| --- | --- |
| `list_windows` | Lists displays and on-screen windows with their ids and bounds. |
| `start_recording` | Records an app's window, a window by id, a screen region or a whole display. Runs until `stop_recording`, or for a fixed `duration_seconds`. |
| `stop_recording` | Stops and returns the path of the recorded movie. |
| `make_gif` | Turns a movie into a GIF or MP4: trim, width, frame rate, speed, loop style and captions. |
| `preview` | Returns evenly spaced frames of a GIF or movie as one image, so the agent can check its work. |
| `get_status` | Reports Screen Recording permission and whether a recording is running. |

A window is recorded as the area of the screen it covers, so menus and popovers that open over it are included. Recordings go to `~/Library/Caches/GIF Maker/Agent Recordings`; GIFs are written wherever the agent asks.

**Permission:** macOS gives Screen Recording permission to the app that starts the server — your terminal, editor or Claude app — not to GIF Maker. If it's missing, the tools say so; turn that app on under *System Settings → Privacy & Security → Screen & System Audio Recording* and restart it.

## How it works

The code is a Swift package with three targets:

- **`GifMakerCore`** — everything that doesn't need a window.
  - `ScreenRecorder` captures a display region with ScreenCaptureKit and writes it to an H.264 movie. The app's own windows are excluded from the capture.
  - `FramePlan` turns the edit settings (trim, frame rate, speed, loop type) into the exact list of frames to produce.
  - `Exporter` decodes those frames, scales them, draws captions, and feeds a GIF or MP4 writer. Reverse and ping-pong loops are decoded in chunks so memory stays bounded.
  - `GIFEncoder` is a streaming GIF encoder written for screen recordings: each frame gets its own palette, and only pixels that changed since the previous frame are stored.
  - `Updates` finds a newer build in the update folder: `ReleaseManifest` reads `latest.json`, `AppVersion` compares versions, `UpdateChecker` decides whether a build is newer and completely there, and `UpdateInstallPlan` holds the script that swaps the installed app for the new one and puts it back if that fails.
- **`GifMaker`** — the AppKit/SwiftUI app: the capture window, editor, settings, menus and global shortcut. Its `UpdateInstaller` verifies a published build and stages it beside the installed app before the swap.
- **`GifMakerMCP`** — the `gifmaker-mcp` server described above, built on `GifMakerCore`.

Recordings and their edit settings are stored in `~/Library/Application Support/GIF Maker/Captures`.

## Development

```sh
swift build   # debug build
swift test    # unit tests for the encoder, frame planning, export, capture geometry and updates
```

Debug builds include a small automation hook for driving the app from a script (see `Sources/GifMaker/Automation.swift`); it is compiled out of release builds.

### Making a release

```sh
VERSION=1.2.0 scripts/make-dmg.sh   # builds build/GIF-Maker-1.2.0.dmg
```

This builds the app, wraps it in a compressed disk image with the usual drag-to-Applications window, and signs the image. The script asks Finder to lay out the window, so the first run may prompt for permission to control Finder.

To produce an image that opens on other Macs without a Gatekeeper warning you need a *Developer ID Application* certificate (from a paid Apple Developer account) and a notarization profile:

```sh
xcrun notarytool store-credentials gifmaker   # once; asks for your Apple ID and an app-specific password
NOTARY_PROFILE=gifmaker scripts/make-dmg.sh   # signs with Developer ID, notarizes, staples
```

The script picks a Developer ID certificate over a development one automatically. Without one it still signs the image, but downloaders have to allow the app in System Settings as described under [Install](#install).

### Publishing an update

To make a release show up in the app's [updater](#updates), publish it to a folder:

```sh
VERSION=1.2.0 PUBLISH_DIR="$HOME/path/to/update-folder" scripts/make-dmg.sh
```

This copies the disk image into the folder and then writes `latest.json` beside it:

```json
{
  "build" : 14,
  "file" : "GIF-Maker-1.2.0.dmg",
  "sha256" : "…",
  "size" : 4123456,
  "version" : "1.2.0"
}
```

Set `RELEASE_NOTES` to add a `notes` entry, which Settings shows beside the update. The folder has to exist already; older disk images in it are left alone and can be deleted.

Copies of the app that are pointed at that folder (or at a folder that syncs with it) offer the build once it is newer than what they are running: a higher `VERSION`, or the same version with a higher build number. The build number is the number of commits, so commit before publishing — rebuilding the same commit with the same `VERSION` isn't seen as an update.

The manifest is written last so that the folder never advertises an image that isn't there yet. The app also checks the image's size and checksum before offering it, because a sync service may deliver the two files in either order.

Two things follow from these builds not being signed with a Developer ID:

- The updater has no way to check who made a build. Whoever can write to the folder can ship code to every copy of the app that reads it, so keep the folder private.
- Sign with the same certificate every time and the Screen Recording permission carries across updates. An *Apple Development* certificate is picked up by the build script on its own; a self-signed code-signing certificate works too if you name it in `CODESIGN_IDENTITY`. With an ad-hoc signature the permission has to be allowed again after every update.

## Not included

Audio, uploading or sharing to online services, and watermarks.

## License

MIT — see [LICENSE](LICENSE).
