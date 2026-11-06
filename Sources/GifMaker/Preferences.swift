import AppKit
import Combine

/// User settings, persisted in UserDefaults.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    static let maximumDurationChoices: [Double] = [15, 30, 60, 120, 300]

    private let defaults = UserDefaults.standard

    private enum Key {
        static let captureCursor = "captureCursor"
        static let highlightClicks = "highlightClicks"
        static let openEditorAfterRecording = "openEditorAfterRecording"
        static let maximumDuration = "maximumDuration"
        static let hotKey = "recordHotKey"
        static let hotKeyCleared = "recordHotKeyCleared"
        static let captureArea = "captureArea"
        static let showsCaptures = "showsCaptures"
    }

    /// Include the mouse pointer in recordings.
    @Published var captureCursor: Bool { didSet { defaults.set(captureCursor, forKey: Key.captureCursor) } }
    /// Draw a ring around mouse clicks in recordings.
    @Published var highlightClicks: Bool { didSet { defaults.set(highlightClicks, forKey: Key.highlightClicks) } }
    @Published var openEditorAfterRecording: Bool {
        didSet { defaults.set(openEditorAfterRecording, forKey: Key.openEditorAfterRecording) }
    }
    /// Recordings stop on their own after this many seconds.
    @Published var maximumDuration: Double { didSet { defaults.set(maximumDuration, forKey: Key.maximumDuration) } }
    /// Global shortcut that starts and stops recording. `nil` means none.
    @Published var hotKey: KeyCombo? {
        didSet {
            if let hotKey, let data = try? JSONEncoder().encode(hotKey) {
                defaults.set(data, forKey: Key.hotKey)
                defaults.set(false, forKey: Key.hotKeyCleared)
            } else {
                defaults.removeObject(forKey: Key.hotKey)
                defaults.set(true, forKey: Key.hotKeyCleared)
            }
        }
    }
    /// Whether the strip of captured clips is shown under the capture window.
    @Published var showsCaptures: Bool { didSet { defaults.set(showsCaptures, forKey: Key.showsCaptures) } }

    /// The last position of the capture area, in screen coordinates.
    var captureArea: CGRect? {
        get {
            guard let string = defaults.string(forKey: Key.captureArea) else { return nil }
            let rect = NSRectFromString(string)
            return rect.isEmpty ? nil : rect
        }
        set {
            if let newValue {
                defaults.set(NSStringFromRect(newValue), forKey: Key.captureArea)
            } else {
                defaults.removeObject(forKey: Key.captureArea)
            }
        }
    }

    private init() {
        defaults.register(defaults: [
            Key.captureCursor: true,
            Key.highlightClicks: false,
            Key.openEditorAfterRecording: true,
            Key.maximumDuration: 30.0,
            Key.showsCaptures: true,
        ])
        captureCursor = defaults.bool(forKey: Key.captureCursor)
        highlightClicks = defaults.bool(forKey: Key.highlightClicks)
        openEditorAfterRecording = defaults.bool(forKey: Key.openEditorAfterRecording)
        maximumDuration = defaults.double(forKey: Key.maximumDuration)
        showsCaptures = defaults.bool(forKey: Key.showsCaptures)
        if let data = defaults.data(forKey: Key.hotKey), let combo = try? JSONDecoder().decode(KeyCombo.self, from: data) {
            hotKey = combo
        } else if defaults.bool(forKey: Key.hotKeyCleared) {
            hotKey = nil
        } else {
            hotKey = .defaultRecord
        }
    }
}
