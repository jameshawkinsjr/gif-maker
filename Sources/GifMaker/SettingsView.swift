import AppKit
import GifMakerCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var store: RecordingStore
    let onClearCaptures: () -> Void

    @State private var hasPermission = ScreenRecorder.hasPermission

    var body: some View {
        Form {
            Section("Recording") {
                LabeledContent("Record shortcut") {
                    ShortcutRecorder(combo: $preferences.hotKey)
                        .frame(width: 170, height: 24)
                }
                Text("Starts and stops recording from any app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Stop automatically after", selection: $preferences.maximumDuration) {
                    ForEach(Preferences.maximumDurationChoices, id: \.self) { seconds in
                        Text(seconds < 60 ? "\(Int(seconds)) seconds" : "\(Int(seconds / 60)) min").tag(seconds)
                    }
                }
                Toggle("Capture cursor", isOn: $preferences.captureCursor)
                Toggle("Highlight mouse clicks", isOn: $preferences.highlightClicks)
                    .disabled(!preferences.captureCursor)
                Toggle("Open the editor when a recording finishes", isOn: $preferences.openEditorAfterRecording)
            }

            Section("Captures") {
                LabeledContent("Saved recordings") {
                    Text("\(store.recordings.count)")
                }
                HStack {
                    Button("Show in Finder") {
                        NSWorkspace.shared.open(store.directory)
                    }
                    Button("Clear Captures…", role: .destructive, action: onClearCaptures)
                        .disabled(store.recordings.isEmpty)
                }
            }

            Section("Permission") {
                LabeledContent("Screen Recording") {
                    Label(
                        hasPermission ? "Allowed" : "Not allowed",
                        systemImage: hasPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(hasPermission ? Color.green : Color.orange)
                }
                if !hasPermission {
                    Text(
                        "Turn on GIF Maker under Privacy & Security → Screen & System Audio Recording, then quit and reopen GIF Maker."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Button("Open System Settings") { ScreenRecordingPermission.openSystemSettings() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasPermission = ScreenRecorder.hasPermission
        }
    }
}

enum ScreenRecordingPermission {
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Explains how to grant access once the system's own prompt won't appear again.
    @MainActor
    static func showAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording is off for GIF Maker"
        alert.informativeText =
            "To record your screen, turn on GIF Maker under Privacy & Security → Screen & System Audio Recording in System Settings, then quit and reopen GIF Maker."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openSystemSettings()
        }
    }
}

/// A field that records a keyboard shortcut: click it, then press the keys.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var combo: KeyCombo?

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.onChange = { combo = $0 }
        view.combo = combo
        return view
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.combo = combo
    }
}

final class ShortcutRecorderView: NSView {
    var onChange: ((KeyCombo?) -> Void)?
    var combo: KeyCombo? { didSet { needsDisplay = true } }

    private var isRecording = false { didSet { needsDisplay = true } }
    private var monitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Record shortcut")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 170, height: 24) }

    private var clearRect: NSRect {
        NSRect(x: bounds.maxX - 22, y: bounds.midY - 8, width: 16, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
        box.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        box.lineWidth = isRecording ? 2 : 1
        box.stroke()

        let text: String
        let color: NSColor
        if isRecording {
            text = "Type shortcut…"
            color = .secondaryLabelColor
        } else if let combo {
            text = combo.displayString
            color = .labelColor
        } else {
            text = "Click to record"
            color = .secondaryLabelColor
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: color]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)

        if combo != nil, !isRecording,
            let image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear shortcut")
        {
            image.withSymbolConfiguration(.init(paletteColors: [.tertiaryLabelColor]))?.draw(in: clearRect)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if combo != nil, !isRecording, clearRect.insetBy(dx: -3, dy: -3).contains(point) {
            onChange?(nil)
            return
        }
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        window?.makeFirstResponder(self)
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            switch event.keyCode {
            case 53:  // Escape cancels
                self.stopRecording()
            case 51, 117:  // Delete clears
                self.stopRecording()
                self.onChange?(nil)
            default:
                if let combo = KeyCombo(event: event) {
                    self.stopRecording()
                    self.onChange?(combo)
                } else {
                    NSSound.beep()  // needs ⌘, ⌃ or ⌥
                }
            }
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }
}
