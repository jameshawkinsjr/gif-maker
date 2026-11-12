import CoreGraphics
import Foundation
import GifMakerCore

/// The tools this server offers, and how each one is carried out.
enum Tools {
    static let instructions = """
        GIF Maker records part of the Mac's screen and turns it into a GIF or MP4, which is handy for showing how \
        an app works. A typical session:
        1. list_windows to find the app or window to record (or pick a screen region).
        2. start_recording with app / window_id / region. The app is brought to the front first.
        3. Drive the app with your other tools (clicks, typing, browser automation). Pause briefly between \
        steps so viewers can follow. Note how many seconds into the recording each step happens, so you can \
        caption it.
        4. stop_recording returns video_path.
        5. make_gif with that video_path, trimming dead time and adding captions that explain each step.
        6. preview to look at frames of the result and check it before handing it over.
        Coordinates are global screen points with the origin at the top-left of the main display, the same \
        space as screenshots. For small files keep width around 600–800 and fps at 10–15.
        """

    static func all(session: RecordingSession) -> [Tool] {
        [
            listWindows(),
            status(session: session),
            startRecording(session: session),
            stopRecording(session: session),
            makeGIF(session: session),
            preview(),
        ]
    }

    // MARK: list_windows

    private static func listWindows() -> Tool {
        Tool(
            name: "list_windows",
            description:
                "List the displays and the app windows on screen (front to back) with their window_id and bounds, "
                + "to choose what start_recording should capture. Window titles need Screen Recording permission.",
            inputSchema: schema([
                "app": ["type": "string", "description": "Only show windows of apps whose name contains this."]
            ]),
            handler: { arguments in
                var windows = CaptureTargets.windows()
                if let app = string(arguments["app"]), !app.isEmpty {
                    windows = CaptureTargets.windows(ofApp: app)
                }
                return .json([
                    "displays": CaptureTargets.displays().map(\.summary),
                    "windows": windows.map(\.summary),
                    "screen_recording_permission": ScreenRecorder.hasPermission,
                ])
            })
    }

    // MARK: get_status

    private static func status(session: RecordingSession) -> Tool {
        Tool(
            name: "get_status",
            description:
                "Report whether Screen Recording permission is granted and whether a recording is running. "
                + "If permission is missing this also asks macOS to prompt for it.",
            inputSchema: schema([:]),
            handler: { _ in
                var status = await session.status()
                let granted = ScreenRecorder.hasPermission || ScreenRecorder.requestPermission()
                status["screen_recording_permission"] = granted
                if !granted { status["permission_help"] = RecordingSession.permissionAdvice }
                return .json(status)
            })
    }

    // MARK: start_recording

    private static func startRecording(session: RecordingSession) -> Tool {
        Tool(
            name: "start_recording",
            description: """
                Start recording the screen. Choose what to record with exactly one of window_id, app, region or \
                display_id; with none, the whole main display is recorded. A window is recorded as the screen \
                area it covers, so menus and popovers over it are included, and so is anything covering it. \
                Without duration_seconds this returns at once and keeps recording until stop_recording; with it, \
                this waits and returns the finished recording.
                """,
            inputSchema: schema([
                "window_id": ["type": "integer", "description": "A window_id from list_windows."],
                "app": [
                    "type": "string",
                    "description": "App name or bundle id; records its frontmost window. Narrow with window_title.",
                ],
                "window_title": ["type": "string", "description": "With app: pick the window whose title contains this."],
                "region": [
                    "type": "object",
                    "description": "Area to record in global screen points (origin top-left of the main display).",
                    "properties": [
                        "x": ["type": "number"], "y": ["type": "number"],
                        "width": ["type": "number"], "height": ["type": "number"],
                    ],
                    "required": ["x", "y", "width", "height"],
                ],
                "display_id": ["type": "integer", "description": "Record a whole display (see list_windows)."],
                "padding": [
                    "type": "number", "description": "Extra points to include around a window. Default 0.",
                ],
                "activate": [
                    "type": "boolean",
                    "description": "Bring the window's app to the front before recording. Default true.",
                ],
                "show_cursor": ["type": "boolean", "description": "Include the mouse pointer. Default true."],
                "show_clicks": [
                    "type": "boolean", "description": "Highlight mouse clicks (macOS 15 and later). Default true.",
                ],
                "duration_seconds": [
                    "type": "number",
                    "description": "Record for this long, then stop and return the result in one call.",
                ],
                "max_seconds": [
                    "type": "number",
                    "description": "Safety limit; the recording stops by itself after this long. Default 300.",
                ],
            ]),
            handler: { arguments in
                let (region, processID) = try resolveRegion(arguments)
                if let processID, bool(arguments["activate"]) ?? true {
                    await CaptureTargets.activate(processID: processID)
                }
                let duration = double(arguments["duration_seconds"])
                let maximum = min(1800, max(1, double(arguments["max_seconds"]) ?? max(300, (duration ?? 0) + 5)))
                var started = try await session.start(
                    region: region, showsCursor: bool(arguments["show_cursor"]) ?? true,
                    showsClicks: bool(arguments["show_clicks"]) ?? true, maximumSeconds: maximum)

                guard let duration else {
                    started["next_step"] =
                        "Recording. Perform the steps to show, keeping track of the time of each, then call stop_recording."
                    return .json(started)
                }
                try? await Task.sleep(nanoseconds: UInt64(max(0.5, duration) * 1_000_000_000))
                return .json(try await session.stop())
            })
    }

    /// Works out the screen area the arguments ask for, and the app that owns it.
    private static func resolveRegion(_ arguments: [String: Any]) throws -> (CaptureTargets.Region, pid_t?) {
        let padding = max(0, double(arguments["padding"]) ?? 0)

        func windowRegion(_ window: CaptureTargets.Window) throws -> (CaptureTargets.Region, pid_t?) {
            let label = window.title.isEmpty ? "\(window.appName) window" : "\(window.appName) – \(window.title)"
            let rect = window.bounds.insetBy(dx: -padding, dy: -padding)
            return (try CaptureTargets.region(for: rect, description: label), window.processID)
        }

        if let id = int(arguments["window_id"]) {
            guard let window = CaptureTargets.windows().first(where: { Int($0.id) == id }) else {
                throw ToolError("No on-screen window has id \(id). Call list_windows for current ids.")
            }
            return try windowRegion(window)
        }
        if let app = string(arguments["app"]), !app.isEmpty {
            let title = string(arguments["window_title"])
            guard let window = CaptureTargets.windows(ofApp: app, title: title).first else {
                let running = Set(CaptureTargets.windows().map(\.appName)).sorted().joined(separator: ", ")
                throw ToolError(
                    "No on-screen window matches app \"\(app)\"\(title.map { " with title \"\($0)\"" } ?? ""). "
                        + "Apps with windows: \(running). Open the app first, or call list_windows.")
            }
            return try windowRegion(window)
        }
        if let region = arguments["region"] as? [String: Any] {
            guard let x = double(region["x"]), let y = double(region["y"]),
                let width = double(region["width"]), let height = double(region["height"])
            else { throw ToolError("region needs numeric x, y, width and height.") }
            let rect = CGRect(x: x, y: y, width: width, height: height)
            return (try CaptureTargets.region(for: rect, description: "screen region"), nil)
        }
        let displays = CaptureTargets.displays()
        let wanted = int(arguments["display_id"])
        guard let display = displays.first(where: { wanted == nil ? $0.isMain : Int($0.id) == wanted }) else {
            throw ToolError("No display has id \(wanted ?? 0). Call list_windows to see the displays.")
        }
        return (try CaptureTargets.region(for: display.bounds, description: "display \(display.id)"), nil)
    }

    // MARK: stop_recording

    private static func stopRecording(session: RecordingSession) -> Tool {
        Tool(
            name: "stop_recording",
            description:
                "Stop the running recording and return its video_path and duration. If the recording already "
                + "stopped by itself (it hit max_seconds), this returns that recording.",
            inputSchema: schema([:]),
            handler: { _ in .json(try await session.stop()) })
    }

    // MARK: make_gif

    private static func makeGIF(session: RecordingSession) -> Tool {
        let captionSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "text": ["type": "string", "description": "Caption text. Use \\n for a line break."],
                "start": ["type": "number", "description": "Seconds into the source video it appears. Default: trim_start."],
                "end": ["type": "number", "description": "Seconds into the source video it disappears. Default: trim_end."],
                "position": [
                    "type": "string", "enum": ["top", "center", "bottom"], "description": "Default bottom.",
                ],
                "x": ["type": "number", "description": "Centre as a fraction of the width (0–1); overrides position."],
                "y": ["type": "number", "description": "Centre as a fraction of the height (0–1, from the top); overrides position."],
                "size": ["type": "number", "description": "Text size as a fraction of the image width, 0.03–0.2. Default 0.06."],
                "color": [
                    "type": "string",
                    "description": "white, black, yellow, red, green, blue, pink or #RRGGBB. Default white.",
                ],
                "font": ["type": "string", "enum": CaptionFont.allCases.map(\.rawValue), "description": "Default classic."],
                "animation": [
                    "type": "string", "enum": CaptionAnimation.allCases.map(\.rawValue), "description": "Default fade.",
                ],
            ],
            "required": ["text"],
        ]
        return Tool(
            name: "make_gif",
            description: """
                Turn a video (from stop_recording, or any movie file) into a GIF or MP4: trim it, resize it, change \
                the frame rate, speed and loop style, and add captions. Returns the output path, file size and \
                dimensions. All times are seconds into the source video.
                """,
            inputSchema: schema(
                [
                    "video_path": ["type": "string", "description": "Absolute path of the source movie."],
                    "output_path": [
                        "type": "string",
                        "description": "Absolute path to write. Default: next to the video, with a .gif or .mp4 extension.",
                    ],
                    "format": ["type": "string", "enum": ["gif", "mp4"], "description": "Default gif, or from output_path's extension."],
                    "trim_start": ["type": "number", "description": "Default 0."],
                    "trim_end": ["type": "number", "description": "Default: the end of the video."],
                    "width": [
                        "type": "integer",
                        "description": "Output width in pixels; height keeps the aspect ratio. Default: the on-screen width, at most 800.",
                    ],
                    "fps": ["type": "integer", "enum": [10, 15, 24, 30], "description": "Frames per second. Default 15."],
                    "speed": ["type": "number", "description": "Playback speed, 0.25–4. Default 1."],
                    "loop": [
                        "type": "string", "enum": LoopType.allCases.map(\.rawValue),
                        "description": "normal, reverse, or pingPong (forwards then backwards). Default normal.",
                    ],
                    "captions": ["type": "array", "items": captionSchema],
                ], required: ["video_path"]),
            handler: { arguments in
                guard let videoPath = string(arguments["video_path"]) else { throw ToolError("video_path is required.") }
                let source = Media.fileURL(videoPath)
                let info = try await Media.videoInfo(source)

                var format = ExportFormat(rawValue: string(arguments["format"])?.lowercased() ?? "")
                let requestedOutput = string(arguments["output_path"]).map(Media.fileURL)
                if format == nil, let ext = requestedOutput?.pathExtension.lowercased() {
                    format = ExportFormat(rawValue: ext)
                }
                let resolvedFormat = format ?? .gif
                let output =
                    requestedOutput
                    ?? source.deletingPathExtension().appendingPathExtension(resolvedFormat.fileExtension)
                guard output.path != source.path else {
                    throw ToolError("output_path would overwrite the source video; choose another path.")
                }

                let trimStart = max(0, min(info.duration, double(arguments["trim_start"]) ?? 0))
                let trimEnd = max(0, min(info.duration, double(arguments["trim_end"]) ?? info.duration))
                guard trimEnd - trimStart >= EditSettings.minimumTrimLength else {
                    throw ToolError(
                        "trim_start (\(trimStart)) must be before trim_end (\(trimEnd)); the video is "
                            + "\(String(format: "%.2f", info.duration))s long.")
                }

                let scale = await session.scale(forVideoAt: source.path) ?? 1
                let screenWidth = Int((Double(info.pixelWidth) / scale).rounded())
                let width = min(
                    info.pixelWidth,
                    max(Recording.minimumOutputWidth, int(arguments["width"]) ?? min(screenWidth, 800)))

                let fps = int(arguments["fps"]) ?? 15
                let frameRate = FrameRate.allCases.min {
                    abs($0.framesPerSecond - Double(fps)) < abs($1.framesPerSecond - Double(fps))
                }!
                var loop = LoopType.normal
                if let name = string(arguments["loop"]) {
                    guard let parsed = LoopType.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() })
                    else { throw ToolError("loop must be normal, reverse or pingPong.") }
                    loop = parsed
                }
                let speed = min(
                    EditSettings.speedRange.upperBound,
                    max(EditSettings.speedRange.lowerBound, double(arguments["speed"]) ?? 1))
                let captions = try (arguments["captions"] as? [Any] ?? []).map {
                    try caption($0, trimStart: trimStart, trimEnd: trimEnd)
                }

                let settings = EditSettings(
                    trimStart: trimStart, trimEnd: trimEnd, loopType: loop, outputWidth: width,
                    frameRate: frameRate, speed: speed, captions: captions)
                try FileManager.default.createDirectory(
                    at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                let outcome = try await Exporter.export(
                    source: source, settings: settings, format: resolvedFormat, destination: output)

                var result: [String: Any] = [
                    "output_path": output.path, "format": resolvedFormat.rawValue,
                    "bytes": outcome.byteCount, "file_size": Media.byteString(outcome.byteCount),
                    "width": outcome.width, "height": outcome.height, "frames": outcome.frameCount,
                    "duration_seconds": decimal(outcome.duration),
                    "next_step": "Call preview with output_path to check the frames.",
                ]
                if outcome.byteCount > 10_000_000 {
                    result["warning"] =
                        "That's a large file. A smaller width, a lower fps, or a tighter trim will shrink it."
                }
                return .json(result)
            })
    }

    private static func caption(_ value: Any, trimStart: Double, trimEnd: Double) throws -> Caption {
        guard let object = value as? [String: Any], let text = string(object["text"]), !text.isEmpty else {
            throw ToolError("Each caption needs a text.")
        }
        var caption = Caption(
            text: text.replacingOccurrences(of: "\\n", with: "\n"),
            start: double(object["start"]) ?? trimStart, end: double(object["end"]) ?? trimEnd,
            size: 0.06, animation: .fade)
        guard caption.end > caption.start else {
            throw ToolError("Caption \"\(text)\" ends (\(caption.end)s) before it starts (\(caption.start)s).")
        }
        switch string(object["position"])?.lowercased() {
        case "top": caption.centerY = 0.14
        case "center", "middle": caption.centerY = 0.5
        default: caption.centerY = 0.84
        }
        if let x = double(object["x"]) { caption.centerX = min(1, max(0, x)) }
        if let y = double(object["y"]) { caption.centerY = min(1, max(0, y)) }
        if let size = double(object["size"]) {
            caption.size = min(Caption.sizeRange.upperBound, max(Caption.sizeRange.lowerBound, size))
        }
        if let name = string(object["color"]) {
            guard let color = color(name) else {
                throw ToolError("Unknown caption color \"\(name)\". Use a name like white or yellow, or #RRGGBB.")
            }
            caption.color = color
        }
        if let name = string(object["font"]) {
            guard let font = CaptionFont(rawValue: name.lowercased()) else {
                throw ToolError("Unknown font \"\(name)\". Choose from \(CaptionFont.allCases.map(\.rawValue)).")
            }
            caption.font = font
        }
        if let name = string(object["animation"]) {
            guard let animation = CaptionAnimation(rawValue: name.lowercased()) else {
                throw ToolError(
                    "Unknown animation \"\(name)\". Choose from \(CaptionAnimation.allCases.map(\.rawValue)).")
            }
            caption.animation = animation
        }
        return caption
    }

    private static func color(_ name: String) -> CaptionColor? {
        let named: [String: CaptionColor] = [
            "white": .white, "black": .black, "yellow": .yellow, "red": .red, "green": .green, "blue": .blue,
            "pink": .pink,
        ]
        if let color = named[name.lowercased()] { return color }
        let hex = name.hasPrefix("#") ? String(name.dropFirst()) : name
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return CaptionColor(
            red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }

    // MARK: preview

    private static func preview() -> Tool {
        Tool(
            name: "preview",
            description:
                "Show evenly spaced frames of a GIF or video as one image (left to right, top to bottom), so you "
                + "can check what a recording or export looks like.",
            inputSchema: schema(
                [
                    "path": ["type": "string", "description": "Absolute path of a .gif, .mp4 or .mov."],
                    "frames": ["type": "integer", "description": "How many frames to show, 1–16. Default 6."],
                    "columns": ["type": "integer", "description": "Frames per row. Default 3."],
                ], required: ["path"]),
            handler: { arguments in
                guard let path = string(arguments["path"]) else { throw ToolError("path is required.") }
                let count = min(16, max(1, int(arguments["frames"]) ?? 6))
                let frames = try await Media.sampleFrames(of: Media.fileURL(path), count: count)
                let jpeg = try Media.contactSheet(frames.map(\.image), columns: int(arguments["columns"]) ?? 3)
                let times = frames.map { String(format: "%.2fs", $0.time) }.joined(separator: ", ")
                return ToolResult(content: [
                    ["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"],
                    [
                        "type": "text",
                        "text": "\(frames.count) frames of \(path) at \(times) (left to right, top to bottom).",
                    ],
                ])
            })
    }

    // MARK: Argument helpers

    private static func schema(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    private static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string)
        default: return nil
        }
    }

    private static func int(_ value: Any?) -> Int? {
        double(value).map { Int($0.rounded()) }
    }

    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let number as NSNumber: return number.boolValue
        case let string as String: return ["true", "1", "yes"].contains(string.lowercased())
        default: return nil
        }
    }
}
