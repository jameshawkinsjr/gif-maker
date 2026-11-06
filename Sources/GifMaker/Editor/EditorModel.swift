import AVFoundation
import AppKit
import Combine
import GifMakerCore
import UniformTypeIdentifiers

/// The playhead position. Kept separate from `EditorModel` so that the views
/// following it (playhead, caption overlay) redraw every frame without
/// re-rendering the whole editor.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var time: Double = 0
}

enum ExportStatus: Equatable {
    case idle
    case exporting(title: String, progress: Double)
    case finished(URL)
    case copied
    case failed(String)
}

enum SizeEstimate: Equatable {
    case unknown
    case calculating(Double)
    case known(Int)
}

enum EditorTab: String, CaseIterable, Identifiable {
    case options
    case captions

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// A flag that can be set from one thread and read from another.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// Lets a progress callback fire often while only passing on meaningful steps.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1.0

    func shouldReport(_ progress: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard progress - last >= 0.01 || progress >= 1 else { return false }
        last = progress
        return true
    }
}

/// State and behaviour behind one editor window.
@MainActor
final class EditorModel: ObservableObject {
    let store: RecordingStore
    let videoURL: URL
    let player: AVPlayer
    let clock = PlaybackClock()

    @Published var recording: Recording {
        didSet {
            if recording.settings != oldValue.settings { settingsChanged(from: oldValue.settings) }
        }
    }
    @Published var format: ExportFormat = .gif {
        didSet { if format != oldValue { invalidateEstimate() } }
    }
    @Published var tab: EditorTab = .options
    @Published var isPlaying = true
    @Published var selectedCaptionID: UUID?
    @Published var exportStatus: ExportStatus = .idle
    @Published var sizeEstimate: SizeEstimate = .unknown
    @Published var filmstrip: [CGImage] = []

    private enum Direction {
        case forward
        case backward
    }

    private var direction: Direction = .forward
    private var isScrubbing = false
    private var isRestarting = false
    private var seekInFlight = false
    private var pendingSeek: Double?
    private var timer: Timer?
    private var saveWork: DispatchWorkItem?
    private var estimateFlag: CancelFlag?
    private var exportFlag: CancelFlag?
    private var statusObservation: NSKeyValueObservation?

    init(recording: Recording, store: RecordingStore) {
        self.recording = recording
        self.store = store
        videoURL = store.videoURL(for: recording)

        let item = AVPlayerItem(url: videoURL)
        player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false

        applyPlaybackRange()
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            Task { @MainActor in self?.restartLoop() }
        }

        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        loadFilmstrip()
    }

    /// Stops playback and background work. Call when the window closes.
    func tearDown() {
        timer?.invalidate()
        timer = nil
        statusObservation = nil
        player.pause()
        estimateFlag?.set()
        exportFlag?.set()
        saveWork?.cancel()
        store.update(recording)
    }

    // MARK: Derived values

    var settings: EditSettings { recording.settings }

    var plan: FramePlan {
        FramePlan(
            settings: recording.settings, sourceWidth: recording.pixelWidth, sourceHeight: recording.pixelHeight,
            sourceDuration: recording.duration, evenDimensions: format == .mp4)
    }

    var isExporting: Bool {
        if case .exporting = exportStatus { return true }
        return false
    }

    var suggestedFileName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Capture \(formatter.string(from: recording.createdAt)).\(format.fileExtension)"
    }

    // MARK: Settings changes

    private func settingsChanged(from old: EditSettings) {
        let new = recording.settings
        invalidateEstimate()
        if case .exporting = exportStatus {} else { exportStatus = .idle }

        // Persist a moment after the last change rather than on every slider tick.
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.store.update(self.recording)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)

        if new.trimStart != old.trimStart || new.trimEnd != old.trimEnd {
            applyPlaybackRange()
        }
        guard isPlaying, !isScrubbing else { return }
        if new.loopType != old.loopType {
            restartLoop()
        } else if new.speed != old.speed {
            applyRate()
        }
    }

    private func invalidateEstimate() {
        estimateFlag?.set()
        estimateFlag = nil
        sizeEstimate = .unknown
    }

    // MARK: Playback

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private var canPreviewReverse: Bool {
        player.currentItem?.canPlayReverse ?? false
    }

    private func applyPlaybackRange() {
        guard let item = player.currentItem else { return }
        // Playback stops by itself exactly at the trim points; `tick` then loops it.
        item.forwardPlaybackEndTime = time(settings.trimEnd)
        item.reversePlaybackEndTime = time(settings.trimStart)
    }

    private func applyRate() {
        let speed = Float(settings.speed)
        player.rate = direction == .forward ? speed : -speed
    }

    /// Starts the loop again from its beginning.
    func restartLoop() {
        guard player.currentItem?.status == .readyToPlay else { return }
        let backwards = settings.loopType == .reverse && canPreviewReverse
        direction = backwards ? .backward : .forward
        restart(from: backwards ? settings.trimEnd - 0.001 : settings.trimStart)
    }

    private func restart(from seconds: Double) {
        isRestarting = true
        player.rate = 0
        player.seek(to: time(max(0, seconds)), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isRestarting = false
                if self.isPlaying, !self.isScrubbing { self.applyRate() }
            }
        }
    }

    private func tick() {
        let now = player.currentTime().seconds
        if now.isFinite, !isScrubbing || !seekInFlight { clock.time = now }
        guard isPlaying, !isScrubbing, !isRestarting, now.isFinite,
            player.currentItem?.status == .readyToPlay
        else { return }

        let start = settings.trimStart
        let end = settings.trimEnd
        let stopped = player.rate == 0

        switch direction {
        case .forward:
            let reachedEnd = now >= end - 0.002 || (stopped && now >= end - 0.15)
            if reachedEnd {
                if settings.loopType == .pingPong, canPreviewReverse {
                    direction = .backward
                    applyRate()
                } else {
                    restartLoop()
                }
            } else if stopped || now < start - 0.05 {
                now < start - 0.05 ? restartLoop() : applyRate()
            }
        case .backward:
            let reachedStart = now <= start + 0.002 || (stopped && now <= start + 0.15)
            if reachedStart {
                if settings.loopType == .pingPong {
                    direction = .forward
                    applyRate()
                } else {
                    restartLoop()
                }
            } else if stopped || now > end + 0.05 {
                now > end + 0.05 ? restartLoop() : applyRate()
            }
        }
    }

    func togglePlayback() {
        isPlaying.toggle()
        if isPlaying {
            let now = player.currentTime().seconds
            if now < settings.trimStart - 0.01 || now > settings.trimEnd - 0.02 {
                restartLoop()
            } else {
                applyRate()
            }
        } else {
            player.rate = 0
        }
    }

    // MARK: Scrubbing

    func beginScrub() {
        isScrubbing = true
        player.rate = 0
    }

    /// Shows the frame at `seconds`. Seeks are coalesced so dragging stays responsive.
    func scrub(to seconds: Double) {
        let clamped = min(max(0, seconds), max(0, recording.duration - 0.01))
        clock.time = clamped
        pendingSeek = clamped
        if !seekInFlight { performPendingSeek() }
    }

    private func performPendingSeek() {
        guard let target = pendingSeek else { return }
        pendingSeek = nil
        seekInFlight = true
        player.seek(to: time(target), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seekInFlight = false
                self.performPendingSeek()
            }
        }
    }

    func endScrub(resumeFromLoopStart: Bool = true) {
        isScrubbing = false
        guard isPlaying else { return }
        if resumeFromLoopStart {
            restartLoop()
        } else {
            let now = clock.time
            if now < settings.trimStart || now > settings.trimEnd - 0.02 { restartLoop() } else { applyRate() }
        }
    }

    // MARK: Trimming

    func setTrimStart(_ seconds: Double) {
        let limit = settings.trimEnd - EditSettings.minimumTrimLength
        let value = min(max(0, seconds), max(0, limit))
        recording.settings.trimStart = value
        scrub(to: value)
    }

    func setTrimEnd(_ seconds: Double) {
        let limit = settings.trimStart + EditSettings.minimumTrimLength
        let value = max(min(recording.duration, seconds), min(recording.duration, limit))
        recording.settings.trimEnd = value
        // Show the last frame that's included rather than the first one that isn't.
        scrub(to: value - 1.0 / 30)
    }

    // MARK: Captions

    func addCaption() {
        let caption = Caption(text: "", start: settings.trimStart, end: settings.trimEnd)
        recording.settings.captions.append(caption)
        tab = .captions
        selectCaption(caption.id)
    }

    func deleteCaption(_ id: UUID) {
        recording.settings.captions.removeAll { $0.id == id }
        if selectedCaptionID == id { selectedCaptionID = nil }
    }

    /// Selects a caption and makes sure it's on screen so edits are visible.
    func selectCaption(_ id: UUID?) {
        selectedCaptionID = id
        guard let id, let caption = settings.captions.first(where: { $0.id == id }) else { return }
        if !CaptionRenderer.isVisible(caption, at: clock.time) {
            // Pause on the caption; the play button resumes the loop.
            isPlaying = false
            player.rate = 0
            scrub(to: (caption.start + caption.end) / 2)
        }
    }

    func moveCaption(_ id: UUID, toCenterX x: Double, centerY y: Double) {
        guard let index = recording.settings.captions.firstIndex(where: { $0.id == id }) else { return }
        recording.settings.captions[index].centerX = min(0.98, max(0.02, x))
        recording.settings.captions[index].centerY = min(0.98, max(0.02, y))
    }

    // MARK: Filmstrip

    private func loadFilmstrip() {
        let count = 16
        let duration = recording.duration
        let url = videoURL
        Task { [weak self] in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.maximumSize = CGSize(width: 240, height: 120)
            generator.appliesPreferredTrackTransform = true
            var images: [CGImage] = []
            for index in 0..<count {
                let seconds = duration * (Double(index) + 0.5) / Double(count)
                let moment = CMTime(seconds: seconds, preferredTimescale: 600)
                if let image = try? await generator.image(at: moment).image {
                    images.append(image)
                    self?.filmstrip = images
                }
            }
        }
    }

    // MARK: Size estimate

    /// Encodes the clip with the current settings (without saving it) to find out how big it is.
    func calculateSize() {
        estimateFlag?.set()
        let flag = CancelFlag()
        estimateFlag = flag
        sizeEstimate = .calculating(0)

        let source = videoURL
        let settings = recording.settings
        let format = format
        let throttle = ProgressThrottle()
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = try? await Exporter.export(
                source: source, settings: settings, format: format, destination: nil,
                progress: { [weak self] progress in
                    guard throttle.shouldReport(progress) else { return }
                    Task { @MainActor [weak self] in
                        guard let self, !flag.isSet else { return }
                        self.sizeEstimate = .calculating(progress)
                    }
                },
                isCancelled: { flag.isSet })
            await MainActor.run { [weak self] in
                guard let self, !flag.isSet else { return }
                self.sizeEstimate = result.map { .known($0.byteCount) } ?? .unknown
            }
        }
    }

    // MARK: Export

    /// Writes the clip to `destination` in the current format.
    func export(to destination: URL, completion: ((Result<ExportOutcome, Error>) -> Void)? = nil) {
        runExport(to: destination, format: format, title: "Saving \(format.title)…") { [weak self] result in
            if case .success = result { self?.exportStatus = .finished(destination) }
            completion?(result)
        }
    }

    /// Puts a GIF of the clip on the clipboard, ready to paste into another app.
    func copyGIFToClipboard(pasteboard: NSPasteboard = .general) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GIF Maker", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = (suggestedFileName as NSString).deletingPathExtension + ".gif"
        let destination = folder.appendingPathComponent(name)

        runExport(to: destination, format: .gif, title: "Copying GIF…") { [weak self] result in
            guard case .success = result, let data = try? Data(contentsOf: destination) else { return }
            let item = NSPasteboardItem()
            item.setData(data, forType: NSPasteboard.PasteboardType(UTType.gif.identifier))
            item.setString(destination.absoluteString, forType: .fileURL)
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
            self?.exportStatus = .copied
        }
    }

    private func runExport(
        to destination: URL, format: ExportFormat, title: String,
        completion: @escaping (Result<ExportOutcome, Error>) -> Void
    ) {
        guard !isExporting else { return }
        let flag = CancelFlag()
        exportFlag = flag
        exportStatus = .exporting(title: title, progress: 0)

        let source = videoURL
        let settings = recording.settings
        let throttle = ProgressThrottle()
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<ExportOutcome, Error>
            do {
                result = .success(
                    try await Exporter.export(
                        source: source, settings: settings, format: format, destination: destination,
                        progress: { [weak self] progress in
                            guard throttle.shouldReport(progress) else { return }
                            Task { @MainActor [weak self] in
                                guard let self, !flag.isSet, self.isExporting else { return }
                                self.exportStatus = .exporting(title: title, progress: progress)
                            }
                        },
                        isCancelled: { flag.isSet }))
            } catch {
                result = .failure(error)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let outcome):
                    self.exportStatus = .idle
                    if format == self.format, settings == self.recording.settings {
                        self.sizeEstimate = .known(outcome.byteCount)
                    }
                case .failure(ExportError.cancelled):
                    self.exportStatus = .idle
                case .failure(let error):
                    self.exportStatus = .failed(error.localizedDescription)
                }
                completion(result)
            }
        }
    }

    func cancelExport() {
        exportFlag?.set()
    }
}
