import AVFoundation
import Accelerate
import CoreGraphics

public enum ExportError: LocalizedError {
    case cancelled
    case noVideoTrack
    case cannotReadVideo(String)
    case cannotWriteVideo(String)
    case missingFrame

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "The export was cancelled."
        case .noVideoTrack: return "The recording doesn't contain any video."
        case .cannotReadVideo(let detail): return "The recording couldn't be read. \(detail)"
        case .cannotWriteVideo(let detail): return "The video couldn't be written. \(detail)"
        case .missingFrame: return "The recording ended before all frames could be read."
        }
    }
}

/// Decodes frames of a recording at exact moments in time.
final class VideoFrameSource {
    let asset: AVURLAsset
    let track: AVAssetTrack
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: Double

    /// How far before the first requested moment decoding starts. The recorder
    /// writes a frame at least every 0.25s, so this always includes the frame
    /// that was on screen at that moment.
    private static let lookBehind = 1.0

    private init(asset: AVURLAsset, track: AVAssetTrack, pixelWidth: Int, pixelHeight: Int, duration: Double) {
        self.asset = asset
        self.track = track
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
    }

    static func load(url: URL) async throws -> VideoFrameSource {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        let size = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration)
        return VideoFrameSource(
            asset: asset, track: track, pixelWidth: Int(size.width.rounded()),
            pixelHeight: Int(size.height.rounded()), duration: duration.seconds)
    }

    /// Calls `body(position, frame)` for each of `times` (which must be ascending),
    /// passing the frame that was showing at that moment.
    func readFrames(at times: [Double], body: (Int, CVPixelBuffer) throws -> Void) throws {
        guard let first = times.first, let last = times.last else { return }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ExportError.cannotReadVideo(error.localizedDescription)
        }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ExportError.cannotReadVideo("Unsupported video format.") }
        reader.add(output)

        let start = max(0, first - Self.lookBehind)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 60000),
            end: CMTime(seconds: last + 0.5, preferredTimescale: 60000))
        guard reader.startReading() else {
            throw ExportError.cannotReadVideo(reader.error?.localizedDescription ?? "")
        }
        defer { if reader.status == .reading { reader.cancelReading() } }

        var next = 0
        var previous: CVPixelBuffer?
        while next < times.count, let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            // Every requested moment before this frame appeared was showing the previous frame.
            while next < times.count, times[next] < time - 0.0005 {
                try body(next, previous ?? buffer)
                next += 1
            }
            previous = buffer
        }
        if reader.status == .failed {
            throw ExportError.cannotReadVideo(reader.error?.localizedDescription ?? "")
        }
        // Anything left is at or after the final frame.
        while next < times.count {
            guard let previous else { throw ExportError.missingFrame }
            try body(next, previous)
            next += 1
        }
    }
}

/// Scales decoded frames to the output size and draws captions on top.
final class FrameRenderer {
    let width: Int
    let height: Int
    private let captions: [Caption]
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    var bytesPerFrame: Int { width * height * 4 }

    init(width: Int, height: Int, captions: [Caption]) {
        self.width = width
        self.height = height
        self.captions = captions.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Renders `frame` as it should look at `time` into `destination`
    /// (`width * height` tightly packed BGRA pixels).
    func render(_ frame: CVPixelBuffer, at time: Double, into destination: UnsafeMutablePointer<UInt32>) throws {
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(frame) else {
            throw ExportError.cannotReadVideo("A frame had no pixel data.")
        }
        let sourceWidth = CVPixelBufferGetWidth(frame)
        let sourceHeight = CVPixelBufferGetHeight(frame)
        let sourceRowBytes = CVPixelBufferGetBytesPerRow(frame)

        if sourceWidth == width && sourceHeight == height {
            for row in 0..<height {
                memcpy(destination + row * width, base + row * sourceRowBytes, width * 4)
            }
        } else {
            var source = vImage_Buffer(
                data: base, height: vImagePixelCount(sourceHeight), width: vImagePixelCount(sourceWidth),
                rowBytes: sourceRowBytes)
            var target = vImage_Buffer(
                data: destination, height: vImagePixelCount(height), width: vImagePixelCount(width),
                rowBytes: width * 4)
            let status = vImageScale_ARGB8888(&source, &target, nil, vImage_Flags(kvImageHighQualityResampling))
            guard status == kvImageNoError else {
                throw ExportError.cannotReadVideo("Scaling failed (\(status)).")
            }
        }

        guard captions.contains(where: { CaptionRenderer.isVisible($0, at: time) }) else { return }
        guard
            let context = CGContext(
                data: destination, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return }
        CaptionRenderer.draw(captions, at: time, in: context, canvasSize: CGSize(width: width, height: height))
    }
}
