import AppKit
import GifMakerCore

private let barBackground = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 0.98)
private let stripBackground = NSColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 0.98)
private let cornerRadius: CGFloat = 9

func formatElapsed(_ seconds: Double) -> String {
    let tenths = Int((seconds * 10).rounded(.down))
    return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
}

func formatDuration(_ seconds: Double) -> String {
    seconds < 60 ? String(format: "%.1fs", seconds) : String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
}

/// The control bar under the capture area: record button, timer, size, and menus.
/// Dragging its background moves the whole capture window.
final class CaptureBarView: NSView {
    var onRecord: (() -> Void)?
    var onSize: (() -> Void)?
    var onToggleCaptures: (() -> Void)?
    var onGear: ((NSView) -> Void)?

    var isLocked = false
    var hasStripBelow = false { didSet { needsDisplay = true } }

    let recordButton = RecordButton()
    let grip = ResizeGripView()
    private let timeLabel = NSTextField(labelWithString: "")
    private let sizeButton = NSButton(title: "", target: nil, action: nil)
    private let capturesButton = NSButton(title: "", target: nil, action: nil)
    private let gearButton = NSButton(title: "", target: nil, action: nil)
    private var isRecording = false
    private var isIdle = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        recordButton.onClick = { [weak self] in self?.onRecord?() }
        recordButton.toolTip = "Start recording"

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        timeLabel.textColor = .white
        timeLabel.lineBreakMode = .byClipping

        configure(sizeButton, action: #selector(sizeClicked), toolTip: "Set the capture size")
        configure(capturesButton, action: #selector(capturesClicked), toolTip: "Show or hide captured clips")
        capturesButton.image = Self.symbol("rectangle.stack", size: 13)
        capturesButton.imagePosition = .imageLeading
        configure(gearButton, action: #selector(gearClicked), toolTip: "Options")
        gearButton.image = Self.symbol("gearshape.fill", size: 14)
        gearButton.imagePosition = .imageOnly

        for view in [recordButton, timeLabel, sizeButton, capturesButton, gearButton, grip] as [NSView] {
            addSubview(view)
        }
    }

    // MARK: Layout

    private static let spacing: CGFloat = 10
    private static let leftInset: CGFloat = 8
    private static let rightInset: CGFloat = 4

    /// Lays the controls out by hand: record and timer on the left, the rest on
    /// the right. When the capture area is too narrow for everything, the least
    /// important controls are hidden first; Record and the menu always stay.
    override func layout() {
        super.layout()

        let leading: [NSView] = [recordButton] + (timeLabel.stringValue.isEmpty ? [] : [timeLabel])
        let trailing: [NSView] = [sizeButton, capturesButton, gearButton] + (isIdle ? [grip] : [])
        var shown = leading + trailing

        func fitted(_ view: NSView) -> NSSize {
            let size = view.fittingSize
            return NSSize(width: ceil(size.width), height: ceil(size.height))
        }
        func requiredWidth() -> CGFloat {
            shown.reduce(0) { $0 + fitted($1).width } + CGFloat(max(0, shown.count - 1)) * Self.spacing
                + Self.leftInset + Self.rightInset
        }
        for droppable in [sizeButton, capturesButton, timeLabel] as [NSView] where requiredWidth() > bounds.width {
            shown.removeAll { $0 === droppable }
        }

        // The top 2 points are the coloured edge, so centre within what's below it.
        let midY = (bounds.height - 2) / 2
        func place(_ view: NSView, x: CGFloat) {
            let size = fitted(view)
            view.frame = NSRect(x: x, y: (midY - size.height / 2).rounded(), width: size.width, height: size.height)
        }

        var x = Self.leftInset
        for view in leading where shown.contains(where: { $0 === view }) {
            place(view, x: x)
            x += fitted(view).width + Self.spacing
        }
        x = bounds.width - Self.rightInset
        for view in trailing.reversed() where shown.contains(where: { $0 === view }) {
            x -= fitted(view).width
            place(view, x: x)
            x -= Self.spacing
        }
        for view in [recordButton, timeLabel, sizeButton, capturesButton, gearButton, grip] as [NSView] {
            view.isHidden = !shown.contains { $0 === view }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configure(_ button: NSButton, action: Selector, toolTip: String) {
        button.isBordered = false
        button.target = self
        button.action = action
        button.toolTip = toolTip
        button.contentTintColor = NSColor.white.withAlphaComponent(0.9)
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    private static func symbol(_ name: String, size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .medium))
    }

    private static func title(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            ])
    }

    @objc private func sizeClicked() { onSize?() }
    @objc private func capturesClicked() { onToggleCaptures?() }
    @objc private func gearClicked() { onGear?(gearButton) }

    // MARK: Updating

    func setSize(_ size: CGSize) {
        sizeButton.attributedTitle = Self.title("\(Int(size.width)) × \(Int(size.height))")
        needsLayout = true
    }

    func setCaptureCount(_ count: Int, stripVisible: Bool) {
        capturesButton.attributedTitle = Self.title(count > 0 ? " \(count)" : "")
        capturesButton.isEnabled = count > 0
        capturesButton.alphaValue = count > 0 ? 1 : 0.4
        capturesButton.toolTip = stripVisible ? "Hide captured clips" : "Show captured clips"
        needsLayout = true
    }

    func update(state: CaptureState, elapsed: Double, limit: Double) {
        let recording = state == .recording || state == .finishing
        if recording != isRecording {
            isRecording = recording
            needsDisplay = true
        }
        switch state {
        case .idle:
            recordButton.mode = .record
            recordButton.toolTip = "Start recording"
            timeLabel.stringValue = ""
        case .starting:
            recordButton.mode = .busy
            timeLabel.stringValue = "Starting…"
        case .recording:
            recordButton.mode = .stop
            recordButton.toolTip = "Stop recording"
            timeLabel.stringValue = formatElapsed(elapsed)
            // Warn as the automatic stop approaches.
            timeLabel.textColor = limit - elapsed <= 5 ? NSColor.systemYellow : .white
        case .finishing:
            recordButton.mode = .busy
            timeLabel.stringValue = "Saving…"
        }
        if state != .recording { timeLabel.textColor = .white }
        sizeButton.isEnabled = state == .idle
        isIdle = state == .idle
        needsLayout = true
    }

    // MARK: Drawing and dragging

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let radius = hasStripBelow ? 0 : cornerRadius
        barBackground.setFill()
        bottomRoundedPath(bounds, radius: radius).fill()
        // The bar's top edge doubles as the bottom edge of the capture frame.
        (isRecording ? CaptureFrameView.recordingColor : CaptureFrameView.idleColor).setFill()
        NSRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard !isLocked else { return }
        window?.performDrag(with: event)
    }
}

/// A rectangle with only its bottom corners rounded.
private func bottomRoundedPath(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    guard radius > 0 else { return NSBezierPath(rect: rect) }
    let path = NSBezierPath()
    path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
    path.line(to: NSPoint(x: rect.minX, y: rect.minY + radius))
    path.appendArc(
        withCenter: NSPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius, startAngle: 180,
        endAngle: 270)
    path.line(to: NSPoint(x: rect.maxX - radius, y: rect.minY))
    path.appendArc(
        withCenter: NSPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius, startAngle: 270,
        endAngle: 360)
    path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
    path.close()
    return path
}

/// The round record / square stop button.
final class RecordButton: NSView {
    enum Mode {
        case record
        case stop
        case busy
    }

    var mode: Mode = .record {
        didSet {
            needsDisplay = true
            setAccessibilityLabel(mode == .stop ? "Stop recording" : "Start recording")
        }
    }
    var onClick: (() -> Void)?
    private var isPressed = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Start recording")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 28) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let side = min(bounds.width, bounds.height)
        let ring = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
            .insetBy(dx: 2, dy: 2)
        NSColor.white.withAlphaComponent(mode == .busy ? 0.35 : 0.95).setStroke()
        let ringPath = NSBezierPath(ovalIn: ring)
        ringPath.lineWidth = 2
        ringPath.stroke()

        let red = CaptureFrameView.recordingColor
        (isPressed ? red.blended(withFraction: 0.3, of: .black) ?? red : red).setFill()
        switch mode {
        case .record:
            NSBezierPath(ovalIn: ring.insetBy(dx: 4, dy: 4)).fill()
        case .stop:
            NSBezierPath(roundedRect: ring.insetBy(dx: 7, dy: 7), xRadius: 2.5, yRadius: 2.5).fill()
        case .busy:
            NSColor.white.withAlphaComponent(0.35).setFill()
            NSBezierPath(ovalIn: ring.insetBy(dx: 7, dy: 7)).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard mode != .busy else { return }
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard mode != .busy else { return false }
        onClick?()
        return true
    }
}

/// The grip at the right end of the bar: drag to resize from the bottom-right corner.
final class ResizeGripView: NSView {
    weak var controller: CaptureWindowController?
    private var dragStart: NSPoint?

    override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 24) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.45).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        let right = bounds.maxX - 3
        let bottom = bounds.minY + 6
        for offset in stride(from: CGFloat(3), through: 11, by: 4) {
            path.move(to: NSPoint(x: right - offset, y: bottom))
            path.line(to: NSPoint(x: right, y: bottom + offset))
        }
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller, !controller.isLocked else { return }
        dragStart = NSEvent.mouseLocation
        controller.beginResize()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let now = NSEvent.mouseLocation
        controller?.resize([.right, .bottom], dx: now.x - dragStart.x, dy: now.y - dragStart.y)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil
        controller?.endResize()
    }
}

/// The scrolling row of captured clips shown under the bar.
final class CaptureStripView: NSView {
    var onOpen: ((Recording) -> Void)?
    var onDelete: ((Recording) -> Void)?
    var onReveal: ((Recording) -> Void)?

    private let scrollView = NSScrollView()
    private let documentView = NSView()
    private var thumbnails: [ThumbnailView] = []
    var thumbnailViews: [ThumbnailView] { thumbnails }

    private static let thumbnailHeight: CGFloat = 58
    private static let spacing: CGFloat = 8
    private static let inset: CGFloat = 10

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = documentView
        scrollView.autoresizingMask = [.width, .height]
        scrollView.frame = bounds
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        stripBackground.setFill()
        bottomRoundedPath(bounds, radius: cornerRadius).fill()
    }

    func setRecordings(_ recordings: [Recording], store: RecordingStore) {
        let existing = Dictionary(uniqueKeysWithValues: thumbnails.map { ($0.recording.id, $0) })
        var updated: [ThumbnailView] = []
        for recording in recordings {
            let view = existing[recording.id] ?? makeThumbnail(for: recording, store: store)
            view.recording = recording
            updated.append(view)
        }
        for view in thumbnails where !updated.contains(where: { $0 === view }) {
            view.removeFromSuperview()
        }
        thumbnails = updated

        var x = Self.inset
        let y = (bounds.height - Self.thumbnailHeight) / 2 + 2
        for view in thumbnails {
            let aspect = CGFloat(view.recording.pixelWidth) / CGFloat(max(1, view.recording.pixelHeight))
            let width = min(150, max(44, (Self.thumbnailHeight * aspect).rounded()))
            view.frame = NSRect(x: x, y: y, width: width, height: Self.thumbnailHeight)
            if view.superview == nil { documentView.addSubview(view) }
            x += width + Self.spacing
        }
        documentView.frame = NSRect(x: 0, y: 0, width: x - Self.spacing + Self.inset, height: bounds.height)
    }

    private func makeThumbnail(for recording: Recording, store: RecordingStore) -> ThumbnailView {
        let view = ThumbnailView(recording: recording)
        view.onOpen = { [weak self] in self?.onOpen?($0) }
        view.onDelete = { [weak self] in self?.onDelete?($0) }
        view.onReveal = { [weak self] in self?.onReveal?($0) }
        Task { @MainActor [weak view] in
            let image = await store.thumbnail(for: recording)
            view?.setImage(image)
        }
        return view
    }
}

/// One clip in the strip. Click to edit it; the ✕ deletes it.
final class ThumbnailView: NSView {
    var recording: Recording { didSet { durationLabel.stringValue = " \(formatDuration(recording.duration)) " } }
    var onOpen: ((Recording) -> Void)?
    var onDelete: ((Recording) -> Void)?
    var onReveal: ((Recording) -> Void)?

    private let imageLayer = CALayer()
    private let durationLabel = NSTextField(labelWithString: "")
    private let deleteButton = NSButton(title: "", target: nil, action: nil)
    private var isPressed = false

    init(recording: Recording) {
        self.recording = recording
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(white: 0.25, alpha: 1).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        layer?.borderWidth = 1

        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        layer?.addSublayer(imageLayer)

        durationLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        durationLabel.textColor = .white
        durationLabel.drawsBackground = true
        durationLabel.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        durationLabel.stringValue = " \(formatDuration(recording.duration)) "
        addSubview(durationLabel)

        deleteButton.isBordered = false
        deleteButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Delete")?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
                    .applying(.init(paletteColors: [.white, NSColor.black.withAlphaComponent(0.65)])))
        deleteButton.imagePosition = .imageOnly
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        deleteButton.toolTip = "Delete this capture"
        addSubview(deleteButton)

        toolTip = "Edit and export"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Captured clip, \(formatDuration(recording.duration))")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setImage(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
        let labelSize = durationLabel.fittingSize
        durationLabel.frame = NSRect(x: bounds.maxX - labelSize.width, y: 0, width: labelSize.width, height: 14)
        deleteButton.frame = NSRect(x: bounds.maxX - 19, y: bounds.maxY - 19, width: 18, height: 18)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        layer?.opacity = 0.7
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        layer?.opacity = 1
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onOpen?(recording)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onOpen?(recording)
        return true
    }

    @objc private func deleteClicked() {
        onDelete?(recording)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let recording = recording
        menu.addItem(ClosureMenuItem(title: "Edit and Export…") { [weak self] in self?.onOpen?(recording) })
        menu.addItem(ClosureMenuItem(title: "Show Recording in Finder") { [weak self] in self?.onReveal?(recording) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Delete") { [weak self] in self?.onDelete?(recording) })
        return menu
    }
}
