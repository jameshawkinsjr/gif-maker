#if DEBUG
    import AppKit
    import GifMakerCore

    /// Development-only remote control for exercising the app without a mouse.
    ///
    /// Launch a debug build with `GIFMAKER_AUTOMATION=1` and it reads one command
    /// per line from standard input, printing an `AUTO <name> <json>` line for each
    /// result. Nothing here is compiled into release builds.
    @MainActor
    final class Automation {
        private unowned let app: AppDelegate
        private var testPasteboard: NSPasteboard?
        private var shownMenu: NSMenu?

        static func startIfRequested(app: AppDelegate) -> Automation? {
            guard ProcessInfo.processInfo.environment["GIFMAKER_AUTOMATION"] == "1" else { return nil }
            setvbuf(stdout, nil, _IOLBF, 0)
            let automation = Automation(app: app)
            Thread.detachNewThread {
                while let line = readLine() {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { automation.run(line) }
                    }
                }
            }
            automation.reply("ready", ["pid": ProcessInfo.processInfo.processIdentifier])
            return automation
        }

        private init(app: AppDelegate) {
            self.app = app
        }

        private func reply(_ name: String, _ payload: [String: Any]) {
            let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
            print("AUTO \(name) \(String(data: data, encoding: .utf8) ?? "{}")")
        }

        private var editor: EditorModel? {
            app.editors.values.max { $0.model.recording.createdAt < $1.model.recording.createdAt }?.model
        }

        private func run(_ line: String) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let command = parts.first else { return }
            let arguments = Array(parts.dropFirst())
            let numbers = arguments.compactMap(Double.init)

            switch command {
            case "state":
                replyState()
            case "windows":
                replyWindows()
            case "glass" where numbers.count == 4:
                app.captureWindow.glassRect = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
                replyState()
            case "record":
                app.capture.start()
            case "stop":
                app.capture.stop()
            case "toggle":
                app.toggleRecording()
            case "hit" where numbers.count == 2:
                replyHit(NSPoint(x: numbers[0], y: numbers[1]))
            case "press":
                press(arguments)
            case "type":
                type(line.dropFirst("type ".count).description)
            case "hotkey":
                reply(
                    "hotkey",
                    [
                        "registered": app.isHotKeyRegistered,
                        "shortcut": app.preferences.hotKey?.displayString ?? "none",
                    ])
            case "click" where numbers.count == 2:
                mouse(from: NSPoint(x: numbers[0], y: numbers[1]), to: nil)
            case "drag" where numbers.count == 4:
                mouse(from: NSPoint(x: numbers[0], y: numbers[1]), to: NSPoint(x: numbers[2], y: numbers[3]))
            case "resize" where numbers.count == 2:
                // Runs the same code a drag on the frame's edges runs: resize <edges> <dx> <dy>
                var edges: ResizeEdges = []
                for (letter, edge) in [("l", ResizeEdges.left), ("r", .right), ("t", .top), ("b", .bottom)]
                where arguments[0].contains(letter) {
                    edges.insert(edge)
                }
                app.captureWindow.beginResize()
                app.captureWindow.resize(edges, dx: numbers[0], dy: numbers[1])
                app.captureWindow.endResize()
                replyState()
            case "panel":
                arguments.first == "hide" ? app.captureWindow.hide() : app.captureWindow.show()
                replyState()
            case "strip":
                app.captureWindow.toggleStrip()
                replyState()
            case "open":
                let index = Int(numbers.first ?? 0)
                guard app.store.recordings.indices.contains(index) else {
                    return reply("error", ["message": "no recording at \(index)"])
                }
                app.openEditor(for: app.store.recordings[index])
                reply("opened", ["id": app.store.recordings[index].id.uuidString])
            case "close":
                for controller in app.editors.values { controller.close() }
            case "delete":
                let index = Int(numbers.first ?? 0)
                if app.store.recordings.indices.contains(index) { app.store.delete(app.store.recordings[index]) }
                replyState()
            case "set":
                set(arguments)
            case "caption":
                guard let model = editor else { return reply("error", ["message": "no editor"]) }
                model.addCaption()
                if let last = model.recording.settings.captions.indices.last {
                    model.recording.settings.captions[last].text = arguments.joined(separator: " ")
                }
                reply("caption", ["count": model.settings.captions.count])
            case "style":
                style(arguments)
            case "seek" where numbers.count == 1:
                guard let model = editor else { return }
                if model.isPlaying { model.togglePlayback() }
                model.beginScrub()
                model.scrub(to: numbers[0])
            case "playback":
                guard let model = editor else { return reply("error", ["message": "no editor"]) }
                reply(
                    "playback",
                    [
                        "time": (model.clock.time * 1000).rounded() / 1000, "rate": Double(model.player.rate),
                        "playing": model.isPlaying,
                    ])
            case "editor":
                replyEditor()
            case "size":
                measureSize()
            case "export":
                export(to: arguments.joined(separator: " "))
            case "copy":
                copy()
            case "gear":
                // Show the options menu for a moment, then dismiss it.
                let menu = app.captureWindow.makeGearMenu()
                reply(
                    "gear",
                    [
                        "items": menu.items.map {
                            $0.isSeparatorItem
                                ? "---" : "\($0.state == .on ? "✓ " : "")\($0.title)\($0.isEnabled ? "" : " (disabled)")"
                        }
                    ])
                shownMenu = menu
                let timer = Timer(timeInterval: numbers.first ?? 1.5, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.shownMenu?.cancelTracking() }
                }
                RunLoop.main.add(timer, forMode: .common)
                let bar = app.captureWindow.barView
                menu.popUp(positioning: nil, at: NSPoint(x: bar.bounds.maxX - 60, y: -6), in: bar)
            case "sizeprompt":
                // Show the Set Capture Size dialog for a moment, then cancel it.
                let timer = Timer(timeInterval: numbers.first ?? 1.5, repeats: false) { _ in NSApp.abortModal() }
                RunLoop.main.add(timer, forMode: .common)
                app.captureWindow.barView.onSize?()
                replyState()
            case "settings":
                app.showSettings()
            case "appearance":
                switch arguments.first {
                case "light": NSApp.appearance = NSAppearance(named: .aqua)
                case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
                default: NSApp.appearance = nil
                }
            case "quit":
                // Quit from the run loop, as a menu action would. Commands arrive in a
                // main-queue block, and the app can't finish a recording before
                // quitting while that block is still on the stack.
                RunLoop.main.perform(inModes: [.common]) { NSApp.terminate(nil) }
            default:
                reply("error", ["message": "unknown command: \(line)"])
            }
        }

        // MARK: Capture

        private func replyState() {
            let glass = app.captureWindow.glassRect
            let region = app.captureWindow.captureRegion()
            reply(
                "state",
                [
                    "capture": "\(app.capture.state)",
                    "elapsed": (app.capture.elapsed * 100).rounded() / 100,
                    "recordings": app.store.recordings.map {
                        ["duration": $0.duration, "width": $0.pixelWidth, "height": $0.pixelHeight, "scale": $0.scale]
                    },
                    "glass": [glass.minX, glass.minY, glass.width, glass.height],
                    "region": region.map { [$0.rect.minX, $0.rect.minY, $0.rect.width, $0.rect.height] } ?? [],
                    "stripVisible": app.captureWindow.isStripVisible,
                    "panelVisible": app.captureWindow.isVisible,
                    "permission": ScreenRecorder.hasPermission,
                ])
        }

        private func replyWindows() {
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let windows = NSApp.windows.filter(\.isVisible).map { window -> [String: Any] in
                let frame = window.frame
                return [
                    "number": window.windowNumber, "title": window.title, "class": window.className,
                    "frame": [frame.minX, frame.minY, frame.width, frame.height],
                    // The same rectangle in the top-left based coordinates `screencapture -R` expects.
                    "captureRect":
                        "\(Int(frame.minX)),\(Int(primaryHeight - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))",
                    "key": window.isKeyWindow,
                ]
            }
            reply("windows", ["windows": windows, "active": NSApp.isActive])
        }

        /// Reports which window the system would deliver a click at `point` to.
        private func replyHit(_ point: NSPoint) {
            let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
            var owner = ""
            if let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]] {
                owner = info.first?[kCGWindowOwnerName as String] as? String ?? ""
            }
            reply(
                "hit",
                [
                    "point": [point.x, point.y], "window": number, "owner": owner,
                    "isCapturePanel": number == app.captureWindow.panel.windowNumber,
                ])
        }

        /// Sends real mouse-down/up events through the normal event path.
        private func press(_ arguments: [String]) {
            let view: NSView?
            switch arguments.first {
            case "record": view = app.captureWindow.barView.recordButton
            case "thumbnail":
                let index = Int(arguments.dropFirst().first ?? "0") ?? 0
                let thumbnails = app.captureWindow.stripView.thumbnailViews
                view = thumbnails.indices.contains(index) ? thumbnails[index] : nil
            default: view = nil
            }
            guard let view, let window = view.window else { return reply("error", ["message": "nothing to press"]) }
            let location = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0)
                {
                    NSApp.sendEvent(event)
                }
            }
            reply("pressed", ["target": arguments.joined(separator: " "), "appActive": NSApp.isActive])
        }

        /// Clicks or drags inside the front editor window using real mouse events.
        /// Points are measured from the window's top-left corner, as in a screenshot of it.
        private func mouse(from start: NSPoint, to end: NSPoint?) {
            guard let window = app.editors.values.first(where: { $0.model === editor })?.window else {
                return reply("error", ["message": "no editor window"])
            }
            let height = window.frame.height
            func event(_ type: NSEvent.EventType, _ point: NSPoint, _ number: Int) -> NSEvent? {
                NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: point.x, y: height - point.y), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: number, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            }

            guard let end else {
                // AppKit controls track the mouse in a loop that waits for the
                // mouse-up, so it has to be queued before the mouse-down is sent.
                if let up = event(.leftMouseUp, start, 2) { NSApp.postEvent(up, atStart: false) }
                if let down = event(.leftMouseDown, start, 1) { NSApp.sendEvent(down) }
                return reply("clicked", ["point": [start.x, start.y]])
            }

            var steps: [(NSEvent.EventType, NSPoint)] = [(.leftMouseDown, start)]
            let count = 10
            for index in 1...count {
                let t = CGFloat(index) / CGFloat(count)
                steps.append((.leftMouseDragged, NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)))
            }
            steps.append((.leftMouseUp, end))
            // Spread the events over a few run-loop turns, as a real drag would be.
            for (index, step) in steps.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.03) { [weak self] in
                    MainActor.assumeIsolated {
                        if let mouseEvent = event(step.0, step.1, index + 1) { NSApp.sendEvent(mouseEvent) }
                        if index == steps.count - 1 {
                            self?.reply("dragged", ["from": [start.x, start.y], "to": [end.x, end.y]])
                        }
                    }
                }
            }
        }

        /// Types text into whatever has keyboard focus in the front editor window.
        private func type(_ text: String) {
            guard let window = app.editors.values.first(where: { $0.model === editor })?.window else {
                return reply("error", ["message": "no editor window"])
            }
            for character in text {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let event = NSEvent.keyEvent(
                        with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: String(character),
                        charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: 0)
                    {
                        NSApp.sendEvent(event)
                    }
                }
            }
            reply("typed", ["text": text, "focus": "\(Swift.type(of: window.firstResponder as Any))"])
        }

        // MARK: Editor

        private func set(_ arguments: [String]) {
            guard let model = editor, arguments.count >= 2 else { return reply("error", ["message": "no editor"]) }
            let value = arguments[1]
            switch arguments[0] {
            case "loop": if let loop = LoopType(rawValue: value) { model.recording.settings.loopType = loop }
            case "width": if let width = Int(value) { model.recording.settings.outputWidth = width }
            case "fps": if let rate = FrameRate(rawValue: value) { model.recording.settings.frameRate = rate }
            case "speed": if let speed = Double(value) { model.recording.settings.speed = speed }
            case "format": if let format = ExportFormat(rawValue: value) { model.format = format }
            case "tab": if let tab = EditorTab(rawValue: value) { model.tab = tab }
            case "trim":
                if arguments.count >= 3, let start = Double(value), let end = Double(arguments[2]) {
                    model.beginScrub()
                    model.setTrimEnd(end)
                    model.setTrimStart(start)
                    model.endScrub()
                }
            case "playing":
                if (value == "1") != model.isPlaying { model.togglePlayback() }
            default: return reply("error", ["message": "unknown setting \(arguments[0])"])
            }
            replyEditor()
        }

        private func style(_ arguments: [String]) {
            guard let model = editor, let index = model.recording.settings.captions.indices.last else {
                return reply("error", ["message": "no caption"])
            }
            var caption = model.recording.settings.captions[index]
            let colors: [String: CaptionColor] = [
                "white": .white, "black": .black, "yellow": .yellow, "red": .red, "green": .green, "blue": .blue,
                "pink": .pink,
            ]
            for argument in arguments {
                let pair = argument.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                switch pair[0] {
                case "font": if let font = CaptionFont(rawValue: pair[1]) { caption.font = font }
                case "color": if let color = colors[pair[1]] { caption.color = color }
                case "anim": if let animation = CaptionAnimation(rawValue: pair[1]) { caption.animation = animation }
                case "animdur": if let value = Double(pair[1]) { caption.animationDuration = value }
                case "size": if let value = Double(pair[1]) { caption.size = value }
                case "x": if let value = Double(pair[1]) { caption.centerX = value }
                case "y": if let value = Double(pair[1]) { caption.centerY = value }
                case "start": if let value = Double(pair[1]) { caption.start = value }
                case "end": if let value = Double(pair[1]) { caption.end = value }
                default: break
                }
            }
            model.recording.settings.captions[index] = caption
            model.selectedCaptionID = caption.id
            replyEditor()
        }

        private func replyEditor() {
            guard let model = editor else { return reply("error", ["message": "no editor"]) }
            let plan = model.plan
            let settings = model.settings
            reply(
                "editor",
                [
                    "trim": [settings.trimStart, settings.trimEnd], "loop": settings.loopType.rawValue,
                    "fps": plan.outputFPS, "frames": plan.frameCount, "size": [plan.outputWidth, plan.outputHeight],
                    "duration": plan.duration, "speed": settings.speed, "format": model.format.rawValue,
                    "captions": settings.captions.map {
                        [
                            "text": $0.text, "start": ($0.start * 100).rounded() / 100,
                            "end": ($0.end * 100).rounded() / 100, "font": $0.font.rawValue,
                            "animation": $0.animation.rawValue, "x": ($0.centerX * 1000).rounded() / 1000,
                            "y": ($0.centerY * 1000).rounded() / 1000, "size": ($0.size * 1000).rounded() / 1000,
                        ] as [String: Any]
                    },
                    "selected": model.selectedCaptionID != nil, "tab": model.tab.rawValue,
                    "sourceDuration": model.recording.duration, "status": "\(model.exportStatus)",
                ])
        }

        private func measureSize() {
            guard let model = editor else { return reply("error", ["message": "no editor"]) }
            model.calculateSize()
            let started = Date()
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self else { return timer.invalidate() }
                    if case .known(let bytes) = model.sizeEstimate {
                        timer.invalidate()
                        self.reply("size", ["bytes": bytes, "seconds": Date().timeIntervalSince(started)])
                    } else if model.sizeEstimate == .unknown {
                        timer.invalidate()
                        self.reply("error", ["message": "size calculation failed"])
                    }
                }
            }
        }

        private func export(to path: String) {
            guard let model = editor else { return reply("error", ["message": "no editor"]) }
            let started = Date()
            model.export(to: URL(fileURLWithPath: path)) { [weak self] result in
                switch result {
                case .success(let outcome):
                    self?.reply(
                        "exported",
                        [
                            "bytes": outcome.byteCount, "frames": outcome.frameCount,
                            "size": [outcome.width, outcome.height],
                            "duration": outcome.duration, "seconds": Date().timeIntervalSince(started),
                        ])
                case .failure(let error):
                    self?.reply("error", ["message": error.localizedDescription])
                }
            }
        }

        /// Runs the copy-to-clipboard path against a private pasteboard so the
        /// real clipboard is left alone.
        private func copy() {
            guard let model = editor else { return reply("error", ["message": "no editor"]) }
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("gifmaker-automation"))
            testPasteboard = pasteboard
            model.copyGIFToClipboard(pasteboard: pasteboard)
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self, model.exportStatus == .copied || !model.isExporting else { return }
                    timer.invalidate()
                    let item = self.testPasteboard?.pasteboardItems?.first
                    let gif = item?.data(forType: NSPasteboard.PasteboardType("com.compuserve.gif"))
                    self.reply(
                        "copied",
                        [
                            "types": item?.types.map(\.rawValue) ?? [], "gifBytes": gif?.count ?? 0,
                            "status": "\(model.exportStatus)",
                        ])
                    self.testPasteboard?.releaseGlobally()
                    self.testPasteboard = nil
                }
            }
        }
    }
#endif
