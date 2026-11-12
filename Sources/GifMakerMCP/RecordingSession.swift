import CoreGraphics
import Foundation
import GifMakerCore

/// The one screen recording an agent can have running at a time.
actor RecordingSession {
    private struct Active {
        let token: UUID
        let recorder: ScreenRecorder
        let region: CaptureTargets.Region
        let url: URL
        let startedAt: Date
        let maximumSeconds: Double
        var autoStop: Task<Void, Never>?
    }

    private enum State {
        case idle
        case starting
        case recording(Active)
        case stopping
    }

    private var state: State = .idle
    /// A recording that stopped by itself (time limit, or the system ended it)
    /// and hasn't been collected with `stop()` yet.
    private var unclaimed: [String: Any]?
    /// Pixels per point of each clip recorded in this session, by path.
    private var scales: [String: Double] = [:]

    static let directory: URL = {
        let base =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("GIF Maker/Agent Recordings", isDirectory: true)
    }()

    func start(region: CaptureTargets.Region, showsCursor: Bool, showsClicks: Bool, maximumSeconds: Double) async throws
        -> [String: Any]
    {
        switch state {
        case .idle: break
        case .starting, .stopping:
            throw ToolError("A recording is starting or stopping; try again in a moment.")
        case .recording:
            throw ToolError("A recording is already running. Call stop_recording first.")
        }
        try Self.ensurePermission()
        state = .starting

        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter.string(
            from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime])
        // A short random suffix keeps two recordings started in the same second apart.
        let suffix = UUID().uuidString.prefix(4).lowercased()
        let url = Self.directory.appendingPathComponent(
            "recording-\(stamp.replacingOccurrences(of: ":", with: ""))-\(suffix).mov")

        let recorder = ScreenRecorder()
        let token = UUID()
        recorder.onInterrupted = { [weak self] _ in
            Task { await self?.finishByItself(token: token, reason: "the system ended the capture") }
        }
        do {
            try await recorder.start(
                ScreenRecorder.Configuration(
                    displayID: region.display.id, sourceRect: region.localRect, scale: region.display.scale,
                    showsCursor: showsCursor, showsClicks: showsClicks, framesPerSecond: 30, outputURL: url))
        } catch ScreenRecorderError.permissionDenied {
            state = .idle
            throw ToolError(Self.permissionAdvice)
        } catch {
            state = .idle
            throw error
        }

        unclaimed = nil
        var active = Active(
            token: token, recorder: recorder, region: region, url: url, startedAt: Date(),
            maximumSeconds: maximumSeconds)
        active.autoStop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(maximumSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.finishByItself(token: token, reason: "it reached max_seconds (\(maximumSeconds)s)")
        }
        state = .recording(active)
        return [
            "recording": true, "target": region.description, "region": rectSummary(region.globalRect),
            "display_id": Int(region.display.id), "max_seconds": maximumSeconds,
        ]
    }

    func stop() async throws -> [String: Any] {
        guard case .recording(let active) = state else {
            if case .starting = state { throw ToolError("The recording is still starting; try again in a moment.") }
            if let unclaimed {
                self.unclaimed = nil
                return unclaimed
            }
            throw ToolError("No recording is running. Call start_recording first.")
        }
        return try await finish(active)
    }

    func status() -> [String: Any] {
        var status: [String: Any] = ["recordings_folder": Self.directory.path]
        switch state {
        case .idle: status["state"] = "idle"
        case .starting: status["state"] = "starting"
        case .stopping: status["state"] = "stopping"
        case .recording(let active):
            status["state"] = "recording"
            status["elapsed_seconds"] = decimal(Date().timeIntervalSince(active.startedAt), places: 1)
            status["target"] = active.region.description
            status["max_seconds"] = active.maximumSeconds
        }
        if let unclaimed { status["finished_recording_not_yet_collected"] = unclaimed }
        return status
    }

    /// Pixels per point for a clip recorded in this session, if known.
    func scale(forVideoAt path: String) -> Double? { scales[path] }

    /// Finishes any recording in progress so the file is usable.
    func shutdown() async {
        if case .recording(let active) = state { _ = try? await finish(active) }
    }

    private func finishByItself(token: UUID, reason: String) async {
        guard case .recording(let active) = state, active.token == token else { return }
        do {
            var result = try await finish(active)
            result["note"] = "Recording stopped automatically because \(reason)."
            unclaimed = result
        } catch {
            unclaimed = ["error": "The recording stopped because \(reason), but \(error.localizedDescription)"]
        }
    }

    private func finish(_ active: Active) async throws -> [String: Any] {
        state = .stopping
        active.autoStop?.cancel()
        defer { state = .idle }
        let result = try await active.recorder.stop()
        let pointWidth = active.region.localRect.width
        let scale = Double(result.pixelWidth) / Double(max(1, pointWidth))
        scales[result.url.path] = scale
        return [
            "video_path": result.url.path,
            "duration_seconds": decimal(result.duration),
            "pixel_size": ["width": result.pixelWidth, "height": result.pixelHeight],
            "point_size": ["width": Double(pointWidth), "height": Double(active.region.localRect.height)],
            "target": active.region.description,
            "next_step": "Call make_gif with this video_path. Caption times are seconds from the start of this video.",
        ]
    }

    // MARK: Permission

    static let permissionAdvice = """
        Screen Recording permission is missing. macOS grants it to the app that launched this server \
        (for example Terminal, iTerm, Visual Studio Code, Cursor or Claude), not to GIF Maker. Ask the user to \
        open System Settings → Privacy & Security → Screen & System Audio Recording, turn that app on, then \
        quit and reopen it so the permission takes effect.
        """

    static func ensurePermission() throws {
        if ScreenRecorder.hasPermission { return }
        // Shows the system prompt the first time; afterwards it only returns false.
        if ScreenRecorder.requestPermission() { return }
        throw ToolError(permissionAdvice)
    }
}
