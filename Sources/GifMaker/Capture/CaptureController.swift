import AppKit
import Combine
import GifMakerCore

enum CaptureState: Equatable {
    case idle
    case starting
    case recording
    case finishing
}

/// The part of a display to record.
struct CaptureRegion {
    var displayID: CGDirectDisplayID
    /// In the display's own space: points, origin at its top-left corner.
    var rect: CGRect
    var scale: CGFloat
}

/// Runs a recording from start to finish and files the result in the library.
@MainActor
final class CaptureController: ObservableObject {
    @Published private(set) var state: CaptureState = .idle
    /// Seconds recorded so far.
    @Published private(set) var elapsed: Double = 0

    let store: RecordingStore
    let preferences: Preferences

    /// Supplies the region to record at the moment recording starts.
    var regionProvider: (() -> CaptureRegion?)?
    var onFinished: ((Recording) -> Void)?
    var onFailure: ((Error) -> Void)?
    /// Called when Screen Recording permission is missing and the system prompt won't appear again.
    var onPermissionNeeded: (() -> Void)?

    private var recorder: ScreenRecorder?
    private var activeRegion: CaptureRegion?
    private var recordingID: UUID?
    private var startedAt: Date?
    private var timer: Timer?

    private static let didRequestAccessKey = "didRequestScreenRecordingAccess"

    init(store: RecordingStore, preferences: Preferences) {
        self.store = store
        self.preferences = preferences
    }

    func toggle() {
        switch state {
        case .idle: start()
        case .recording: stop()
        case .starting, .finishing: break
        }
    }

    func start() {
        guard state == .idle else { return }

        if !ScreenRecorder.hasPermission {
            // The system shows its own prompt, but only the first time it's asked.
            let alreadyAsked = UserDefaults.standard.bool(forKey: Self.didRequestAccessKey)
            UserDefaults.standard.set(true, forKey: Self.didRequestAccessKey)
            if !ScreenRecorder.requestPermission() {
                if alreadyAsked { onPermissionNeeded?() }
                return
            }
        }

        guard let region = regionProvider?() else {
            onFailure?(ScreenRecorderError.regionTooSmall)
            return
        }

        let id = UUID()
        let recorder = ScreenRecorder()
        recorder.onInterrupted = { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        let configuration = ScreenRecorder.Configuration(
            displayID: region.displayID, sourceRect: region.rect, scale: region.scale,
            showsCursor: preferences.captureCursor, showsClicks: preferences.highlightClicks,
            outputURL: store.videoURL(forNewRecording: id),
            excludedProcessID: ProcessInfo.processInfo.processIdentifier)

        self.recorder = recorder
        activeRegion = region
        recordingID = id
        elapsed = 0
        state = .starting

        Task {
            do {
                try await recorder.start(configuration)
                beginTiming()
            } catch {
                self.recorder = nil
                state = .idle
                if case ScreenRecorderError.permissionDenied = error {
                    onPermissionNeeded?()
                } else {
                    onFailure?(error)
                }
            }
        }
    }

    func stop() {
        guard state == .recording, let recorder, let region = activeRegion, let id = recordingID else { return }
        state = .finishing
        timer?.invalidate()
        timer = nil

        Task {
            do {
                let result = try await recorder.stop()
                let recording = Recording(
                    id: id, duration: result.duration, pixelWidth: result.pixelWidth,
                    pixelHeight: result.pixelHeight,
                    // Normally the display's scale; smaller if the capture had to be shrunk.
                    scale: Double(result.pixelWidth) / Double(max(1, region.rect.width)))
                store.add(recording)
                onFinished?(recording)
            } catch {
                onFailure?(error)
            }
            self.recorder = nil
            activeRegion = nil
            recordingID = nil
            elapsed = 0
            state = .idle
        }
    }

    private func beginTiming() {
        startedAt = Date()
        elapsed = 0
        state = .recording
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Common modes keep the clock running while menus are open or the mouse is down.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard state == .recording, let startedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        if elapsed >= preferences.maximumDuration {
            stop()
        }
    }
}
