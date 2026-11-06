# GIF Maker

A small, native macOS app for recording part of your screen and turning it into a GIF (or MP4). Its workflow is modelled on GIPHY Capture: frame an area, hit record, trim, export. It has no account, no upload and no analytics — recordings stay on your Mac.

> Not affiliated with GIPHY.

## Features

**Capture**

- A see-through capture frame that floats above other apps. Drag the bar to move it, drag the edges or corners to resize it, or set an exact size.
- The inside of the frame is click-through, so you can keep using the app you're recording.
- Start and stop with the record button, the menu bar icon, or a global keyboard shortcut (⌃⌥⌘G by default).
- Clicking record doesn't steal focus from the app being recorded.
- Optional mouse pointer and click highlights. Recordings stop automatically after a configurable limit (30 seconds by default).
- Every clip is kept in a strip under the frame until you delete it, so you can come back and re-export.

**Edit**

- Trim the start and end on a filmstrip.
- Loop type: normal, reverse, or ping-pong.
- Output size, frame rate (10 / 15 / 24 / 30 fps) and playback speed (0.25× – 4×).
- Captions with a choice of text style, colour, size, position, timing and animation (fade, scale, drop, move).
- See the exact file size before saving.

**Export**

- Save as GIF or MP4, or copy a GIF straight to the clipboard.

## Requirements

- macOS 14 or later
- Xcode 16 or later (or the matching Command Line Tools) to build

## Build and run

```sh
scripts/build-app.sh            # builds build/GIF Maker.app
scripts/build-app.sh --open     # ...and launches it
scripts/build-app.sh --install  # ...and copies it to /Applications
```

The first time you record, macOS asks for **Screen Recording** permission. Allow GIF Maker under *System Settings → Privacy & Security → Screen & System Audio Recording*, then quit and reopen the app. Recent versions of macOS also ask you to re-confirm this from time to time for any app that records the screen.

### A note on code signing

macOS ties the Screen Recording permission to the app's code signature. The build script signs with the first *Apple Development* or *Developer ID Application* certificate it finds in your keychain, which keeps the permission valid across rebuilds. Without a certificate it falls back to an ad-hoc signature; that works, but you'll need to re-allow the app after each rebuild. Set `CODESIGN_IDENTITY` to choose an identity explicitly (`-` forces ad-hoc).

## Using it

1. Position the green frame over what you want to record.
2. Press the record button (or the shortcut). The frame turns red while recording.
3. Press it again to stop. The clip appears in the strip and opens in the editor.
4. Trim, adjust the options, add captions, then **Save As…** or **Copy GIF**.

The gear button holds the capture options (cursor, click highlights, exact size) and Settings, where you can change the shortcut and the recording limit.

## How it works

The code is a Swift package with two targets:

- **`GifMakerCore`** — everything that doesn't need a window.
  - `ScreenRecorder` captures a display region with ScreenCaptureKit and writes it to an H.264 movie. The app's own windows are excluded from the capture.
  - `FramePlan` turns the edit settings (trim, frame rate, speed, loop type) into the exact list of frames to produce.
  - `Exporter` decodes those frames, scales them, draws captions, and feeds a GIF or MP4 writer. Reverse and ping-pong loops are decoded in chunks so memory stays bounded.
  - `GIFEncoder` is a streaming GIF encoder written for screen recordings: each frame gets its own palette, and only pixels that changed since the previous frame are stored.
- **`GifMaker`** — the AppKit/SwiftUI app: the capture window, editor, settings, menus and global shortcut.

Recordings and their edit settings are stored in `~/Library/Application Support/GIF Maker/Captures`.

## Development

```sh
swift build   # debug build
swift test    # unit tests for the encoder, frame planning, export and capture geometry
```

Debug builds include a small automation hook for driving the app from a script (see `Sources/GifMaker/Automation.swift`); it is compiled out of release builds.

## Not included

Audio, uploading or sharing to online services, and watermarks.

## License

MIT — see [LICENSE](LICENSE).
