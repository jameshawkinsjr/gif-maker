import AppKit
import Combine
import GifMakerCore

/// A borderless floating panel that never activates the app, so pressing
/// Record doesn't take focus away from whatever is being recorded.
final class CapturePanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false  // moving and resizing are handled by the views
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Note: `ignoresMouseEvents` is deliberately left untouched. While it has
        // never been set, clicks on fully transparent pixels fall through to the
        // window underneath, which is what makes the capture area click-through.
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct ResizeEdges: OptionSet {
    let rawValue: Int
    static let left = ResizeEdges(rawValue: 1)
    static let right = ResizeEdges(rawValue: 2)
    static let top = ResizeEdges(rawValue: 4)
    static let bottom = ResizeEdges(rawValue: 8)
}

/// Owns the capture window: a see-through, click-through rectangle (the
/// "glass") framed by a border, with a control bar and a strip of captured
/// clips underneath. Whatever is inside the glass is what gets recorded.
@MainActor
final class CaptureWindowController: NSObject, NSWindowDelegate {
    static let border: CGFloat = 5
    static let barHeight: CGFloat = 40
    static let stripHeight: CGFloat = 84
    static let minimumGlassSize = CGSize(width: 120, height: 60)
    static let defaultGlassSize = CGSize(width: 640, height: 400)

    let panel = CapturePanel()
    let barView = CaptureBarView()
    let stripView = CaptureStripView()
    private let frameView = CaptureFrameView()

    private let capture: CaptureController
    private let store: RecordingStore
    private let preferences: Preferences
    private var subscriptions: Set<AnyCancellable> = []
    private var resizeStartGlass: CGRect?
    private(set) var isStripVisible = false

    var onOpenRecording: ((Recording) -> Void)?
    var onShowSettings: (() -> Void)?

    init(capture: CaptureController, store: RecordingStore, preferences: Preferences) {
        self.capture = capture
        self.store = store
        self.preferences = preferences
        super.init()

        let root = NSView(frame: panel.contentLayoutRect)
        root.autoresizesSubviews = false
        panel.contentView = root
        root.addSubview(frameView)
        root.addSubview(barView)
        root.addSubview(stripView)
        panel.delegate = self

        frameView.controller = self
        barView.grip.controller = self
        barView.onRecord = { [weak self] in self?.capture.toggle() }
        barView.onSize = { [weak self] in self?.promptForSize() }
        barView.onToggleCaptures = { [weak self] in self?.toggleStrip() }
        barView.onGear = { [weak self] button in self?.showGearMenu(from: button) }
        stripView.onOpen = { [weak self] in self?.onOpenRecording?($0) }
        stripView.onDelete = { [weak self] in self?.store.delete($0) }
        stripView.onReveal = { [weak self] recording in
            guard let self else { return }
            NSWorkspace.shared.activateFileViewerSelecting([self.store.videoURL(for: recording)])
        }

        isStripVisible = preferences.showsCaptures && !store.recordings.isEmpty
        glassRect = Self.initialGlassRect(saved: preferences.captureArea)

        capture.$state
            .combineLatest(capture.$elapsed)
            .sink { [weak self] state, elapsed in self?.captureStateChanged(state, elapsed: elapsed) }
            .store(in: &subscriptions)
        store.$recordings
            .sink { [weak self] recordings in self?.recordingsChanged(recordings) }
            .store(in: &subscriptions)
    }

    // MARK: Geometry

    private var bottomHeight: CGFloat { Self.barHeight + (isStripVisible ? Self.stripHeight : 0) }

    /// The see-through capture area, in screen coordinates.
    var glassRect: CGRect {
        get {
            let frame = panel.frame
            return CGRect(
                x: frame.minX + Self.border, y: frame.minY + bottomHeight,
                width: frame.width - 2 * Self.border, height: frame.height - bottomHeight - Self.border)
        }
        set {
            let glass = newValue.integral
            panel.setFrame(
                CGRect(
                    x: glass.minX - Self.border, y: glass.minY - bottomHeight,
                    width: glass.width + 2 * Self.border, height: glass.height + bottomHeight + Self.border),
                display: true)
            layoutSubviews()
        }
    }

    private func layoutSubviews() {
        guard let root = panel.contentView else { return }
        let size = root.bounds.size
        stripView.isHidden = !isStripVisible
        stripView.frame = CGRect(x: 0, y: 0, width: size.width, height: Self.stripHeight)
        barView.frame = CGRect(
            x: 0, y: isStripVisible ? Self.stripHeight : 0, width: size.width, height: Self.barHeight)
        barView.hasStripBelow = isStripVisible
        frameView.frame = CGRect(x: 0, y: bottomHeight, width: size.width, height: size.height - bottomHeight)
        frameView.needsDisplay = true
        barView.setSize(glassRect.size)
    }

    private static func initialGlassRect(saved: CGRect?) -> CGRect {
        let screens = NSScreen.screens
        if let saved, saved.width >= minimumGlassSize.width, saved.height >= minimumGlassSize.height,
            screens.contains(where: { $0.frame.intersects(saved) })
        {
            return saved
        }
        let visible = (NSScreen.main ?? screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(
            width: min(defaultGlassSize.width, visible.width - 80),
            height: min(defaultGlassSize.height, visible.height - 220))
        return CGRect(
            x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + 40, width: size.width,
            height: size.height)
    }

    /// What will be recorded: the glass, clipped to the display it's (mostly) on.
    func captureRegion() -> CaptureRegion? {
        let glass = glassRect
        func overlap(_ screen: NSScreen) -> CGFloat {
            let shared = screen.frame.intersection(glass)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        guard let screen = NSScreen.screens.max(by: { overlap($0) < overlap($1) }), overlap(screen) > 0,
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return nil }

        let clipped = glass.intersection(screen.frame)
        guard clipped.width >= 16, clipped.height >= 16 else { return nil }
        // Screen coordinates start at the bottom-left; capture wants top-left of the display.
        let local = CGRect(
            x: clipped.minX - screen.frame.minX, y: screen.frame.maxY - clipped.maxY, width: clipped.width,
            height: clipped.height)
        return CaptureRegion(displayID: displayID, rect: local, scale: screen.backingScaleFactor)
    }

    // MARK: Showing

    func show() {
        if !panel.isVisible {
            // The saved position may be on a display that's no longer attached.
            if !NSScreen.screens.contains(where: { $0.frame.intersects(glassRect) }) {
                glassRect = Self.initialGlassRect(saved: nil)
            }
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        guard capture.state == .idle else { return }
        panel.orderOut(nil)
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: Moving and resizing

    var isLocked: Bool { capture.state != .idle }

    func beginResize() {
        resizeStartGlass = glassRect
    }

    func resize(_ edges: ResizeEdges, dx: CGFloat, dy: CGFloat) {
        guard let start = resizeStartGlass, !isLocked else { return }
        let minimum = Self.minimumGlassSize
        var minX = start.minX
        var maxX = start.maxX
        var minY = start.minY
        var maxY = start.maxY
        if edges.contains(.left) { minX = min(start.minX + dx, maxX - minimum.width) }
        if edges.contains(.right) { maxX = max(start.maxX + dx, minX + minimum.width) }
        if edges.contains(.bottom) { minY = min(start.minY + dy, maxY - minimum.height) }
        if edges.contains(.top) { maxY = max(start.maxY + dy, minY + minimum.height) }
        glassRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func endResize() {
        resizeStartGlass = nil
        preferences.captureArea = glassRect
    }

    func windowDidMove(_ notification: Notification) {
        preferences.captureArea = glassRect
    }

    /// Resizes the glass, keeping its top-left corner where it is.
    func setGlassSize(_ size: CGSize) {
        let current = glassRect
        let screen = panel.screen ?? NSScreen.main
        let limit = screen?.frame.size ?? CGSize(width: 10000, height: 10000)
        let width = min(max(size.width, Self.minimumGlassSize.width), limit.width)
        let height = min(max(size.height, Self.minimumGlassSize.height), limit.height)
        glassRect = CGRect(x: current.minX, y: current.maxY - height, width: width, height: height)
        preferences.captureArea = glassRect
    }

    private func promptForSize() {
        guard !isLocked else { return }
        if let size = CaptureSizePrompt.run(current: glassRect.size, minimum: Self.minimumGlassSize) {
            setGlassSize(size)
        }
    }

    // MARK: Captures strip

    func toggleStrip() {
        setStripVisible(!isStripVisible)
        preferences.showsCaptures = isStripVisible
    }

    private func setStripVisible(_ visible: Bool) {
        guard visible != isStripVisible else { return }
        let glass = glassRect
        isStripVisible = visible
        glassRect = glass  // re-derive the window frame so the glass stays put
        barView.setCaptureCount(store.recordings.count, stripVisible: isStripVisible)
    }

    private func recordingsChanged(_ recordings: [Recording]) {
        stripView.setRecordings(recordings, store: store)
        barView.setCaptureCount(recordings.count, stripVisible: isStripVisible)
        if recordings.isEmpty {
            setStripVisible(false)
        } else if preferences.showsCaptures {
            setStripVisible(true)
        }
    }

    // MARK: State

    private func captureStateChanged(_ state: CaptureState, elapsed: Double) {
        frameView.isRecording = state == .recording || state == .finishing
        frameView.isLocked = state != .idle
        barView.isLocked = state != .idle
        barView.update(state: state, elapsed: elapsed, limit: preferences.maximumDuration)
    }

    // MARK: Gear menu

    private func showGearMenu(from button: NSView) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        func add(_ title: String, checked: Bool = false, enabled: Bool = true, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, handler: action)
            item.state = checked ? .on : .off
            item.isEnabled = enabled
            menu.addItem(item)
        }

        let idle = capture.state == .idle
        add("Capture Cursor", checked: preferences.captureCursor) { [preferences] in
            preferences.captureCursor.toggle()
        }
        add("Highlight Clicks", checked: preferences.highlightClicks, enabled: preferences.captureCursor) {
            [preferences] in
            preferences.highlightClicks.toggle()
        }
        menu.addItem(.separator())
        add("Set Capture Size…", enabled: idle) { [weak self] in self?.promptForSize() }
        add(isStripVisible ? "Hide Captures" : "Show Captures", enabled: !store.recordings.isEmpty) { [weak self] in
            self?.toggleStrip()
        }
        add("Clear Captures…", enabled: idle && !store.recordings.isEmpty) { [weak self] in
            self?.confirmClearCaptures()
        }
        menu.addItem(.separator())
        add("Settings…") { [weak self] in self?.onShowSettings?() }
        add("Hide Capture Window", enabled: idle) { [weak self] in self?.hide() }
        menu.addItem(.separator())
        add("Quit GIF Maker") { NSApp.terminate(nil) }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 6), in: button)
    }

    func confirmClearCaptures() {
        let count = store.recordings.count
        guard count > 0 else { return }
        let alert = NSAlert()
        alert.messageText = "Clear \(count) \(count == 1 ? "capture" : "captures")?"
        alert.informativeText = "The recordings will be deleted. GIFs and videos you've already saved aren't affected."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NotificationCenter.default.post(name: .willClearCaptures, object: nil)
            store.deleteAll()
        }
    }
}

extension Notification.Name {
    /// Posted before every recording is deleted, so open editors can close.
    static let willClearCaptures = Notification.Name("GifMakerWillClearCaptures")
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func run() {
        handler()
    }
}

/// Draws the border around the glass and turns drags on it into resizes.
/// Everything inside the border is fully transparent, so clicks there go
/// straight through to the app underneath.
final class CaptureFrameView: NSView {
    weak var controller: CaptureWindowController?
    var isRecording = false { didSet { if isRecording != oldValue { needsDisplay = true } } }
    var isLocked = false {
        didSet {
            if isLocked != oldValue {
                needsDisplay = true
                window?.invalidateCursorRects(for: self)
            }
        }
    }

    static let idleColor = NSColor(srgbRed: 0.10, green: 0.84, blue: 0.52, alpha: 1)
    static let recordingColor = NSColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1)
    private static let cornerLength: CGFloat = 22

    private var activeEdges: ResizeEdges = []
    private var dragStart = NSPoint.zero

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var border: CGFloat { CaptureWindowController.border }
    private var leftStrip: NSRect { NSRect(x: 0, y: 0, width: border, height: bounds.height) }
    private var rightStrip: NSRect { NSRect(x: bounds.width - border, y: 0, width: border, height: bounds.height) }
    private var topStrip: NSRect { NSRect(x: 0, y: bounds.height - border, width: bounds.width, height: border) }

    override func draw(_ dirtyRect: NSRect) {
        (isRecording ? Self.recordingColor : Self.idleColor).setFill()
        leftStrip.fill()
        rightStrip.fill()
        topStrip.fill()

        guard !isLocked else { return }
        // Brighter corners hint at where to grab for a diagonal resize.
        NSColor.white.setFill()
        let length = min(Self.cornerLength, bounds.width / 3, bounds.height / 3)
        NSRect(x: 0, y: bounds.height - border, width: length, height: border).fill()
        NSRect(x: 0, y: bounds.height - length, width: border, height: length).fill()
        NSRect(x: bounds.width - length, y: bounds.height - border, width: length, height: border).fill()
        NSRect(x: bounds.width - border, y: bounds.height - length, width: border, height: length).fill()
    }

    private func edges(at point: NSPoint) -> ResizeEdges {
        var edges: ResizeEdges = []
        if point.x <= border { edges.insert(.left) }
        if point.x >= bounds.width - border { edges.insert(.right) }
        if point.y >= bounds.height - border { edges.insert(.top) }
        let corner = Self.cornerLength
        if edges.contains(.top) {
            if point.x < corner { edges.insert(.left) } else if point.x > bounds.width - corner { edges.insert(.right) }
        }
        if edges.contains(.left) || edges.contains(.right) {
            if point.y > bounds.height - corner {
                edges.insert(.top)
            } else if point.y < corner {
                edges.insert(.bottom)
            }
        }
        return edges
    }

    override func resetCursorRects() {
        guard !isLocked else { return }
        addCursorRect(leftStrip, cursor: .resizeLeftRight)
        addCursorRect(rightStrip, cursor: .resizeLeftRight)
        addCursorRect(topStrip, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isLocked else { return }
        activeEdges = edges(at: convert(event.locationInWindow, from: nil))
        guard !activeEdges.isEmpty else { return }
        dragStart = NSEvent.mouseLocation
        controller?.beginResize()
    }

    override func mouseDragged(with event: NSEvent) {
        guard !activeEdges.isEmpty else { return }
        let now = NSEvent.mouseLocation
        controller?.resize(activeEdges, dx: now.x - dragStart.x, dy: now.y - dragStart.y)
    }

    override func mouseUp(with event: NSEvent) {
        guard !activeEdges.isEmpty else { return }
        activeEdges = []
        controller?.endResize()
    }
}

/// The "Set Capture Size" dialog.
@MainActor
enum CaptureSizePrompt {
    private final class FieldLinker: NSObject, NSTextFieldDelegate {
        let widthField: NSTextField
        let heightField: NSTextField
        let lockAspect: NSButton
        let aspect: CGFloat

        init(widthField: NSTextField, heightField: NSTextField, lockAspect: NSButton, aspect: CGFloat) {
            self.widthField = widthField
            self.heightField = heightField
            self.lockAspect = lockAspect
            self.aspect = aspect
        }

        func controlTextDidChange(_ notification: Notification) {
            guard lockAspect.state == .on, let field = notification.object as? NSTextField else { return }
            let value = CGFloat(field.integerValue)
            guard value > 0 else { return }
            if field === widthField {
                heightField.integerValue = Int((value / aspect).rounded())
            } else {
                widthField.integerValue = Int((value * aspect).rounded())
            }
        }
    }

    static func run(current: CGSize, minimum: CGSize) -> CGSize? {
        let alert = NSAlert()
        alert.messageText = "Set Capture Size"
        alert.informativeText = "The size of the recorded area, in points."
        alert.addButton(withTitle: "Set Size")
        alert.addButton(withTitle: "Cancel")

        func field(_ value: CGFloat) -> NSTextField {
            let field = NSTextField(string: "\(Int(value))")
            field.alignment = .right
            field.formatter = {
                let formatter = NumberFormatter()
                formatter.allowsFloats = false
                formatter.minimum = 1
                formatter.maximum = 20000
                return formatter
            }()
            field.widthAnchor.constraint(equalToConstant: 80).isActive = true
            return field
        }
        let widthField = field(current.width)
        let heightField = field(current.height)
        let lockAspect = NSButton(checkboxWithTitle: "Maintain aspect ratio", target: nil, action: nil)
        lockAspect.state = .off

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Width:"), widthField],
            [NSTextField(labelWithString: "Height:"), heightField],
            [NSGridCell.emptyContentView, lockAspect],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        alert.accessoryView = grid

        let linker = FieldLinker(
            widthField: widthField, heightField: heightField, lockAspect: lockAspect,
            aspect: current.width / max(1, current.height))
        widthField.delegate = linker
        heightField.delegate = linker
        alert.window.initialFirstResponder = widthField

        NSApp.activate(ignoringOtherApps: true)
        let response = withExtendedLifetime(linker) { alert.runModal() }
        guard response == .alertFirstButtonReturn else { return nil }

        let width = CGFloat(widthField.integerValue)
        let height = CGFloat(heightField.integerValue)
        guard width > 0, height > 0 else { return nil }
        if width < minimum.width || height < minimum.height {
            NSSound.beep()
        }
        return CGSize(width: width, height: height)
    }
}
