import AVFoundation
import CoreGraphics
import ScreenCaptureKit

public enum ScreenRecorderError: LocalizedError {
    case permissionDenied
    case displayNotFound
    case regionTooSmall
    case cannotStart(String)
    case noFrames
    case notRecording
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Screen Recording permission hasn't been granted."
        case .displayNotFound: return "The display to record couldn't be found."
        case .regionTooSmall: return "The capture area is too small to record."
        case .cannotStart(let detail): return "Recording could not start. \(detail)"
        case .noFrames: return "Nothing was captured."
        case .notRecording: return "There is no recording in progress."
        case .writeFailed(let detail): return "The recording couldn't be saved. \(detail)"
        }
    }
}

/// Records a rectangle of one display to a movie file using ScreenCaptureKit.
public final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public struct Configuration {
        public var displayID: CGDirectDisplayID
        /// Region to capture in the display's own space: points, origin at its top-left corner.
        public var sourceRect: CGRect
        /// Pixels per point on that display.
        public var scale: CGFloat
        public var showsCursor: Bool
        public var showsClicks: Bool
        public var framesPerSecond: Int
        public var outputURL: URL
        /// A process whose windows are left out of the recording (this app).
        public var excludedProcessID: pid_t?

        public init(
            displayID: CGDirectDisplayID, sourceRect: CGRect, scale: CGFloat, showsCursor: Bool = true,
            showsClicks: Bool = false, framesPerSecond: Int = 30, outputURL: URL, excludedProcessID: pid_t? = nil
        ) {
            self.displayID = displayID
            self.sourceRect = sourceRect
            self.scale = scale
            self.showsCursor = showsCursor
            self.showsClicks = showsClicks
            self.framesPerSecond = framesPerSecond
            self.outputURL = outputURL
            self.excludedProcessID = excludedProcessID
        }
    }

    public struct Result: Sendable {
        public let url: URL
        public let duration: Double
        public let pixelWidth: Int
        public let pixelHeight: Int
        public let frameCount: Int
    }

    /// Called on the main queue when the system ends the capture on its own
    /// (for example the user chose "Stop Sharing" in the menu bar).
    public var onInterrupted: ((Error?) -> Void)?

    /// The screen only produces frames when something changes; while it's still,
    /// the last frame is rewritten this often so the movie has no long gaps.
    private static let maximumFrameGap = 0.25
    /// Largest frame the hardware H.264 encoder is asked to handle.
    private static let maximumPixelSize = (width: 3840, height: 2160)

    private let queue = DispatchQueue(label: "gifmaker.screen-recorder", qos: .userInitiated)
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var heartbeat: DispatchSourceTimer?

    // Touched only on `queue`.
    private var isRecording = false
    private var firstFrameTime: CMTime?
    private var lastWrittenTime = CMTime.zero
    private var lastBuffer: CVPixelBuffer?
    private var frameCount = 0
    private var pixelWidth = 0
    private var pixelHeight = 0
    private var framesPerSecond = 30
    private var outputURL: URL?

    /// Whether this process is currently allowed to record the screen.
    public static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt (the first time) and registers the app in System Settings.
    @discardableResult
    public static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Works out exactly what gets recorded for a requested region.
    ///
    /// Video encoders need even pixel dimensions, so the region is snapped to
    /// the display's pixel grid and trimmed by up to one pixel to make it even;
    /// that way the screen is copied 1:1 with no resampling blur. Regions too big
    /// for the encoder are scaled down instead.
    public static func captureGeometry(for region: CGRect, scale: CGFloat) -> (
        sourceRect: CGRect, pixelWidth: Int, pixelHeight: Int
    ) {
        func even(_ value: Double) -> Int { max(2, Int(value) / 2 * 2) }
        let x = (region.minX * scale).rounded()
        let y = (region.minY * scale).rounded()
        let width = even(Double(region.width * scale) + 0.001)
        let height = even(Double(region.height * scale) + 0.001)
        let sourceRect = CGRect(
            x: x / scale, y: y / scale, width: CGFloat(width) / scale, height: CGFloat(height) / scale)

        let shrink = min(
            1, Double(maximumPixelSize.width) / Double(width), Double(maximumPixelSize.height) / Double(height))
        if shrink < 1 {
            return (sourceRect, even(Double(width) * shrink), even(Double(height) * shrink))
        }
        return (sourceRect, width, height)
    }

    public func start(_ configuration: Configuration) async throws {
        guard stream == nil else { throw ScreenRecorderError.cannotStart("A recording is already in progress.") }
        guard configuration.sourceRect.width >= 8, configuration.sourceRect.height >= 8 else {
            throw ScreenRecorderError.regionTooSmall
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw Self.hasPermission
                ? ScreenRecorderError.cannotStart(error.localizedDescription) : ScreenRecorderError.permissionDenied
        }
        guard let display = content.displays.first(where: { $0.displayID == configuration.displayID }) else {
            throw ScreenRecorderError.displayNotFound
        }
        let excluded = content.applications.filter { $0.processID == configuration.excludedProcessID }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])

        let geometry = Self.captureGeometry(for: configuration.sourceRect, scale: configuration.scale)
        let size = (width: geometry.pixelWidth, height: geometry.pixelHeight)
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.sourceRect = geometry.sourceRect
        streamConfiguration.width = size.width
        streamConfiguration.height = size.height
        streamConfiguration.minimumFrameInterval = CMTime(
            value: 1, timescale: CMTimeScale(configuration.framesPerSecond))
        streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfiguration.colorSpaceName = CGColorSpace.sRGB
        streamConfiguration.showsCursor = configuration.showsCursor
        streamConfiguration.queueDepth = 6
        streamConfiguration.capturesAudio = false
        if #available(macOS 15.0, *) {
            streamConfiguration.showMouseClicks = configuration.showsCursor && configuration.showsClicks
        }

        try? FileManager.default.removeItem(at: configuration.outputURL)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: configuration.outputURL, fileType: .mov)
        } catch {
            throw ScreenRecorderError.cannotStart(error.localizedDescription)
        }
        // Generous bitrate: this file is an intermediate that gets re-encoded on export.
        let bitRate = max(4_000_000, Int(Double(size.width * size.height * configuration.framesPerSecond) * 0.3))
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: size.width,
                AVVideoHeightKey: size.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitRate,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    // A keyframe every second keeps scrubbing and reverse playback quick.
                    AVVideoMaxKeyFrameIntervalKey: configuration.framesPerSecond,
                    AVVideoAllowFrameReorderingKey: false,
                    AVVideoExpectedSourceFrameRateKey: configuration.framesPerSecond,
                ] as [String: Any],
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
            ])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size.width,
                kCVPixelBufferHeightKey as String: size.height,
            ])
        guard writer.canAdd(input) else { throw ScreenRecorderError.cannotStart("Unsupported video settings.") }
        writer.add(input)
        guard writer.startWriting() else {
            throw ScreenRecorderError.cannotStart(writer.error?.localizedDescription ?? "")
        }

        let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        } catch {
            writer.cancelWriting()
            throw ScreenRecorderError.cannotStart(error.localizedDescription)
        }

        queue.sync {
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            self.pixelWidth = size.width
            self.pixelHeight = size.height
            self.framesPerSecond = configuration.framesPerSecond
            self.outputURL = configuration.outputURL
            self.firstFrameTime = nil
            self.lastWrittenTime = .zero
            self.lastBuffer = nil
            self.frameCount = 0
            self.isRecording = true
        }

        do {
            try await stream.startCapture()
        } catch {
            queue.sync {
                self.isRecording = false
                self.cleanUp()
            }
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: configuration.outputURL)
            throw Self.hasPermission
                ? ScreenRecorderError.cannotStart(error.localizedDescription) : ScreenRecorderError.permissionDenied
        }
        self.stream = stream

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.fillGap() }
        timer.resume()
        queue.sync { self.heartbeat = timer }
    }

    /// Stops capturing and finishes the movie file.
    public func stop() async throws -> Result {
        guard let stream else { throw ScreenRecorderError.notRecording }
        self.stream = nil
        try? await stream.stopCapture()
        let written: Result = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.finish { continuation.resume(with: $0) }
            }
        }
        // Report the length the finished file really has; the container rounds
        // timestamps, so it can differ slightly from what was requested.
        guard let duration = try? await AVURLAsset(url: written.url).load(.duration).seconds, duration > 0 else {
            return written
        }
        return Result(
            url: written.url, duration: duration, pixelWidth: written.pixelWidth, pixelHeight: written.pixelHeight,
            frameCount: written.frameCount)
    }

    // MARK: Stream callbacks

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType)
    {
        guard type == .screen, isRecording, CMSampleBufferIsValid(sampleBuffer) else { return }
        // Only "complete" frames carry new picture data; idle/blank ones are skipped.
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            SCFrameStatus(rawValue: rawStatus) == .complete,
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstFrameTime == nil {
            firstFrameTime = time
            writer?.startSession(atSourceTime: .zero)
        }
        lastBuffer = pixelBuffer
        write(pixelBuffer, at: CMTimeSubtract(time, firstFrameTime ?? time))
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onInterrupted?(error) }
    }

    // MARK: Writing (on `queue`)

    private func write(_ buffer: CVPixelBuffer, at requestedTime: CMTime) {
        guard let input, let adaptor else { return }
        // Timestamps must strictly increase, even if a real frame's timestamp
        // lands just before a gap-filling frame that was already written.
        var time = requestedTime
        if frameCount > 0 {
            let earliest = CMTimeAdd(lastWrittenTime, CMTime(value: 1, timescale: 600))
            if CMTimeCompare(time, earliest) < 0 { time = earliest }
        }
        guard input.isReadyForMoreMediaData else { return }  // encoder is behind; drop this frame
        if adaptor.append(buffer, withPresentationTime: time) {
            lastWrittenTime = time
            frameCount += 1
        }
    }

    private func elapsedNow() -> CMTime? {
        guard let firstFrameTime else { return nil }
        return CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), firstFrameTime)
    }

    private func fillGap() {
        guard isRecording, let buffer = lastBuffer, let now = elapsedNow() else { return }
        if CMTimeSubtract(now, lastWrittenTime).seconds >= Self.maximumFrameGap {
            write(buffer, at: now)
        }
    }

    private func finish(completion: @escaping (Swift.Result<Result, Error>) -> Void) {
        isRecording = false
        heartbeat?.cancel()
        heartbeat = nil

        guard let writer, let input, let outputURL else {
            cleanUp()
            completion(.failure(ScreenRecorderError.notRecording))
            return
        }
        guard frameCount > 0, let now = elapsedNow() else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            cleanUp()
            completion(.failure(ScreenRecorderError.noFrames))
            return
        }

        // Keep the final picture on screen right up to the moment recording stopped.
        if let buffer = lastBuffer, CMTimeSubtract(now, lastWrittenTime).seconds > 1.0 / 120 {
            write(buffer, at: now)
        }
        let end = CMTimeAdd(lastWrittenTime, CMTime(value: 1, timescale: CMTimeScale(framesPerSecond)))
        let result = Result(
            url: outputURL, duration: end.seconds, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            frameCount: frameCount)

        input.markAsFinished()
        writer.endSession(atSourceTime: end)
        cleanUp()
        writer.finishWriting {
            if writer.status == .completed {
                completion(.success(result))
            } else {
                try? FileManager.default.removeItem(at: outputURL)
                completion(.failure(ScreenRecorderError.writeFailed(writer.error?.localizedDescription ?? "")))
            }
        }
    }

    private func cleanUp() {
        writer = nil
        input = nil
        adaptor = nil
        lastBuffer = nil
        outputURL = nil
    }
}
