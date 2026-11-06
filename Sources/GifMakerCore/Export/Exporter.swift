import AVFoundation
import CoreGraphics
import Foundation

public struct ExportOutcome: Sendable, Equatable {
    public let byteCount: Int
    public let frameCount: Int
    public let width: Int
    public let height: Int
    public let duration: Double
}

/// Renders a recording with its edit settings to a GIF or MP4.
public enum Exporter {
    /// - Parameters:
    ///   - destination: Where to write the file. Pass `nil` to only measure how
    ///     big the result would be.
    ///   - gifOptions: Encoder tuning; only used for GIF output.
    ///   - progress: Called with 0...1 as frames are produced (on the exporting thread).
    ///   - isCancelled: Polled once per frame; return `true` to stop.
    public static func export(
        source: URL, settings: EditSettings, format: ExportFormat, destination: URL?,
        gifOptions: GIFEncoder.Options = GIFEncoder.Options(),
        progress: (@Sendable (Double) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) async throws -> ExportOutcome {
        let video = try await VideoFrameSource.load(url: source)
        let plan = FramePlan(
            settings: settings, sourceWidth: video.pixelWidth, sourceHeight: video.pixelHeight,
            sourceDuration: video.duration, evenDimensions: format == .mp4)
        let renderer = FrameRenderer(width: plan.outputWidth, height: plan.outputHeight, captions: settings.captions)

        let sink: FrameSink
        switch format {
        case .gif:
            sink = try GIFFrameSink(
                destination: destination, width: plan.outputWidth, height: plan.outputHeight, options: gifOptions)
        case .mp4:
            sink = try MP4FrameSink(
                destination: destination, width: plan.outputWidth, height: plan.outputHeight,
                framesPerSecond: plan.outputFPS)
        }

        do {
            var done = 0
            let total = plan.frameCount
            try forEachFrame(plan: plan, video: video, renderer: renderer) { pixels in
                if isCancelled?() == true { throw ExportError.cancelled }
                try sink.append(pixels, duration: plan.frameDelay)
                done += 1
                progress?(Double(done) / Double(total))
            }
            let bytes = try await sink.finish()
            return ExportOutcome(
                byteCount: bytes, frameCount: total, width: plan.outputWidth, height: plan.outputHeight,
                duration: plan.duration)
        } catch {
            sink.abandon()
            throw error
        }
    }

    /// Produces every output frame in display order.
    ///
    /// Video can only be decoded forwards, so forward runs are streamed straight
    /// through, while backward runs (reverse and the second half of ping-pong) are
    /// decoded a chunk at a time and replayed in reverse. Memory stays bounded
    /// either way.
    private static func forEachFrame(
        plan: FramePlan, video: VideoFrameSource, renderer: FrameRenderer,
        body: (UnsafePointer<UInt32>) throws -> Void
    ) throws {
        let pixelCount = renderer.width * renderer.height
        let scratch = UnsafeMutablePointer<UInt32>.allocate(capacity: pixelCount)
        var chunkBuffers: [UnsafeMutablePointer<UInt32>] = []
        defer {
            scratch.deallocate()
            chunkBuffers.forEach { $0.deallocate() }
        }
        let chunkSize = max(4, min(48, (192 << 20) / max(1, renderer.bytesPerFrame)))

        let sequence = plan.sequence
        var position = 0
        while position < sequence.count {
            // Find the run of consecutive frames heading in one direction.
            var end = position + 1
            var step = 1
            if end < sequence.count, abs(sequence[end] - sequence[position]) == 1 {
                step = sequence[end] - sequence[position]
                while end < sequence.count, sequence[end] - sequence[end - 1] == step { end += 1 }
            }
            let first = sequence[position]
            let last = sequence[end - 1]

            if step > 0 {
                let times = Array(plan.sourceTimes[first...last])
                try video.readFrames(at: times) { offset, frame in
                    try renderer.render(frame, at: times[offset], into: scratch)
                    try body(scratch)
                }
            } else {
                var high = first
                while high >= last {
                    let low = max(last, high - chunkSize + 1)
                    let times = Array(plan.sourceTimes[low...high])
                    while chunkBuffers.count < times.count {
                        chunkBuffers.append(.allocate(capacity: pixelCount))
                    }
                    try video.readFrames(at: times) { offset, frame in
                        try renderer.render(frame, at: times[offset], into: chunkBuffers[offset])
                    }
                    for offset in stride(from: times.count - 1, through: 0, by: -1) {
                        try body(chunkBuffers[offset])
                    }
                    high = low - 1
                }
            }
            position = end
        }
    }
}

// MARK: - Sinks

private protocol FrameSink: AnyObject {
    func append(_ pixels: UnsafePointer<UInt32>, duration: Double) throws
    /// Completes the file and returns its size in bytes.
    func finish() async throws -> Int
    /// Stops and removes anything partially written.
    func abandon()
}

private final class GIFFrameSink: FrameSink {
    private let encoder: GIFEncoder
    private let destination: URL?

    init(destination: URL?, width: Int, height: Int, options: GIFEncoder.Options) throws {
        self.destination = destination
        let sink: GIFByteSink = try destination.map { try FileByteSink(url: $0) } ?? CountingByteSink()
        encoder = try GIFEncoder(sink: sink, width: width, height: height, options: options)
    }

    func append(_ pixels: UnsafePointer<UInt32>, duration: Double) throws {
        try encoder.addFrame(pixels, duration: duration)
    }

    func finish() async throws -> Int {
        try encoder.finish()
    }

    func abandon() {
        if let destination { try? FileManager.default.removeItem(at: destination) }
    }
}

private final class MP4FrameSink: FrameSink {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let url: URL
    private let isTemporary: Bool
    private let width: Int
    private let height: Int
    private var time = 0.0

    init(destination: URL?, width: Int, height: Int, framesPerSecond: Double) throws {
        self.width = width
        self.height = height
        isTemporary = destination == nil
        url =
            destination
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("gifmaker-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: url)

        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw ExportError.cannotWriteVideo(error.localizedDescription)
        }
        let bitRate = max(1_500_000, Int(Double(width * height) * min(30, framesPerSecond) * 0.2))
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitRate,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
            ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(input) else { throw ExportError.cannotWriteVideo("Unsupported video settings.") }
        writer.add(input)
        guard writer.startWriting() else {
            throw ExportError.cannotWriteVideo(writer.error?.localizedDescription ?? "")
        }
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ pixels: UnsafePointer<UInt32>, duration: Double) throws {
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else {
                throw ExportError.cannotWriteVideo(writer.error?.localizedDescription ?? "")
            }
            usleep(2000)
        }
        guard let pool = adaptor.pixelBufferPool else {
            throw ExportError.cannotWriteVideo("No pixel buffer pool.")
        }
        var created: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
        guard let buffer = created else { throw ExportError.cannotWriteVideo("Out of pixel buffers.") }

        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            for row in 0..<height {
                memcpy(base + row * rowBytes, pixels + row * width, width * 4)
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        guard adaptor.append(buffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 60000)) else {
            throw ExportError.cannotWriteVideo(writer.error?.localizedDescription ?? "")
        }
        time += duration
    }

    func finish() async throws -> Int {
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: time, preferredTimescale: 60000))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ExportError.cannotWriteVideo(writer.error?.localizedDescription ?? "")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if isTemporary { try? FileManager.default.removeItem(at: url) }
        return size
    }

    func abandon() {
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }
}
