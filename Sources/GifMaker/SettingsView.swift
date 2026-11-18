import AppKit
import GifMakerCore
import SwiftUI

/// Which pane of the settings window is showing.
@MainActor
final class SettingsNavigation: ObservableObject {
    enum Pane: Hashable {
        case general
        case updates
    }

    @Published var pane: Pane = .general
}

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var store: RecordingStore
    @ObservedObject var updates: UpdateController
    @ObservedObject var navigation: SettingsNavigation
    let onClearCaptures: () -> Void

    @State private var hasPermission = ScreenRecorder.hasPermission

    var body: some View {
        TabView(selection: $navigation.pane) {
            pane { general }
                .tabItem { Text("General") }
                .tag(SettingsNavigation.Pane.general)
            pane { UpdatesSection(preferences: preferences, updates: updates) }
                .tabItem { Text(updates.availableUpdate == nil ? "Updates" : "Updates •") }
                .tag(SettingsNavigation.Pane.updates)
        }
        .padding(.top, 8)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasPermission = ScreenRecorder.hasPermission
        }
    }

    private func pane(@ViewBuilder _ content: () -> some View) -> some View {
        Form(content: content)
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var general: some View {
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
}

/// The Updates part of Settings: where builds are published, and what's there.
private struct UpdatesSection: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var updates: UpdateController

    var body: some View {
        Section("Updates") {
            LabeledContent("Version") {
                Text(updates.currentVersion?.description ?? "Development build")
            }
            LabeledContent("Update folder") {
                Text(preferences.updateFolder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Not set")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(preferences.updateFolder?.path ?? "")
            }
            HStack {
                Button("Choose…", action: chooseFolder)
                Button("Show in Finder") {
                    if let folder = preferences.updateFolder { NSWorkspace.shared.open(folder) }
                }
                .disabled(preferences.updateFolder == nil)
            }
            Text(
                "The folder new builds are published to, such as one in iCloud Drive or Dropbox. GIF Maker installs what it finds there, so only use a folder you control."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Toggle("Check for updates automatically", isOn: $preferences.automaticallyChecksForUpdates)

            HStack {
                Button("Check Now") { updates.checkNow() }
                    .disabled(updates.isBusy || preferences.updateFolder == nil || !updates.canCheck)
                if updates.availableUpdate != nil {
                    Button("Install and Restart") { updates.installUpdate() }
                        .buttonStyle(.borderedProminent)
                        .disabled(updates.isBusy)
                    Button("Show Disk Image") { updates.showDiskImage() }
                }
                if updates.isBusy {
                    ProgressView().controlSize(.small)
                }
            }
            if let statusText {
                Text(statusText)
                    .foregroundStyle(isProblem ? Color.orange : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notes = updates.availableUpdate?.manifest.notes {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
            }
            if let outcomeText {
                HStack(alignment: .firstTextBaseline) {
                    Text(outcomeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if updates.lastOutcome == .failed {
                        Spacer()
                        Button("Show Log") { updates.showLog() }
                            .controlSize(.small)
                    }
                }
            }
            Text(signingNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var isProblem: Bool {
        if case .failed = updates.status { return true }
        return false
    }

    private var statusText: String? {
        switch updates.status {
        case .idle:
            if !updates.canCheck { return "Updates work in the built app, not in a development build." }
            return lastChecked
        case .checking: return "Checking…"
        case .upToDate: return ["GIF Maker is up to date.", lastChecked].compactMap { $0 }.joined(separator: " ")
        case .available:
            guard let update = updates.availableUpdate else { return nil }
            return "Version \(update.version) is available."
        case .unavailable(let reason): return reason
        case .installing(let step): return step
        case .failed(let reason): return reason
        }
    }

    private var lastChecked: String? {
        guard let date = preferences.lastUpdateCheck else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return "Last checked \(formatter.string(from: date).lowercasedFirstLetter)."
    }

    /// What happened to the update this launch followed, if it followed one.
    private var outcomeText: String? {
        switch updates.lastOutcome {
        case .updated(let signatureChanged):
            let version = updates.currentVersion.map { " to version \($0)" } ?? ""
            return "GIF Maker was updated\(version)."
                + (signatureChanged
                    ? " It is signed differently from the version before, so Screen Recording has to be allowed again."
                    : "")
        case .failed:
            return "The last update couldn't be installed, so the version you had was put back."
        case nil:
            return nil
        }
    }

    /// macOS ties Screen Recording permission to the signature, and development
    /// builds don't have the stable identity a Developer ID gives.
    private var signingNote: String {
        updates.isAdHocSigned
            ? "This build is signed ad-hoc, so macOS will ask you to allow Screen Recording again after every update."
            : "If an update is signed with a different certificate from this build, macOS will ask you to allow Screen Recording again."
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder new builds of GIF Maker are published to."
        panel.directoryURL = preferences.updateFolder
        if panel.runModal() == .OK, let url = panel.url {
            preferences.updateFolder = url
        }
    }
}

extension String {
    /// "Today at 10:02" → "today at 10:02", for use mid-sentence.
    fileprivate var lowercasedFirstLetter: String {
        prefix(1).lowercased() + dropFirst()
    }
}

enum ScreenRecordingPermission {
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// After an update signed differently from the version before: macOS keeps
    /// the old entry in its list, but it no longer matches the app.
    @MainActor
    static func showAlertAfterUpdate() {
        let alert = NSAlert()
        alert.messageText = "Allow Screen Recording again"
        alert.informativeText =
            "GIF Maker was updated, and the new version is signed differently, so macOS no longer applies its Screen Recording permission. In System Settings, under Privacy & Security → Screen & System Audio Recording, turn GIF Maker off and on again, then quit and reopen it."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openSystemSettings()
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
