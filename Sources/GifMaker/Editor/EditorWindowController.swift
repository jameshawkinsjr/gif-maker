import AppKit
import GifMakerCore
import SwiftUI
import UniformTypeIdentifiers

/// One editor window for one recording.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let model: EditorModel
    var onClose: (() -> Void)?

    init(recording: Recording, store: RecordingStore) {
        model = EditorModel(recording: recording, store: store)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Capture — " + recording.createdAt.formatted(date: .abbreviated, time: .shortened)
        super.init(window: window)

        window.contentViewController = NSHostingController(
            rootView: EditorView(model: model, onSave: { [weak self] in self?.save() }))
        window.setContentSize(Self.contentSize(for: recording, on: NSScreen.main))
        window.center()
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Sizes the window so the preview roughly fits the clip without filling the screen.
    private static func contentSize(for recording: Recording, on screen: NSScreen?) -> NSSize {
        let chrome: CGFloat = 360  // everything below the preview
        let available = screen?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let width = min(max(CGFloat(recording.pointWidth), 700), min(1000, available.width - 80))
        let aspect = CGFloat(recording.pixelHeight) / CGFloat(max(1, recording.pixelWidth))
        let preview = min(max(width * aspect, 220), max(220, available.height - chrome - 80), 520)
        return NSSize(width: width, height: preview + chrome)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Asks where to save, then exports in the currently selected format.
    func save() {
        guard let window, !model.isExporting else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [model.format == .gif ? .gif : .mpeg4Movie]
        panel.nameFieldStringValue = model.suggestedFileName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.model.export(to: url)
        }
    }

    func windowWillClose(_ notification: Notification) {
        model.tearDown()
        onClose?()
    }
}
