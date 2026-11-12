import AVFoundation
import CoreGraphics
import Foundation
import GifMakerCore
import ImageIO
import UniformTypeIdentifiers

enum Media {
    struct VideoInfo {
        let duration: Double
        let pixelWidth: Int
        let pixelHeight: Int
    }

    static func videoInfo(_ url: URL) async throws -> VideoInfo {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError("No file at \(url.path).")
        }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ToolError("\(url.lastPathComponent) has no video track.")
        }
        let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
        let oriented = size.applying(transform)
        return VideoInfo(
            duration: try await asset.load(.duration).seconds,
            pixelWidth: Int(abs(oriented.width).rounded()), pixelHeight: Int(abs(oriented.height).rounded()))
    }

    /// Expands `~` and makes relative paths absolute.
    static func fileURL(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    static func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: Previews

    /// Evenly spaced frames of a GIF or movie, with the time each one appears.
    static func sampleFrames(of url: URL, count: Int) async throws -> [(time: Double, image: CGImage)] {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError("No file at \(url.path).") }
        if url.pathExtension.lowercased() == "gif" {
            return try gifFrames(url, count: count)
        }
        let info = try await videoInfo(url)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let times = spread(count: count, over: info.duration)
        var frames: [(Double, CGImage)] = []
        for time in times {
            let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            frames.append((time, image))
        }
        return frames
    }

    private static func gifFrames(_ url: URL, count: Int) throws -> [(time: Double, image: CGImage)] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ToolError("\(url.lastPathComponent) couldn't be read as a GIF.")
        }
        let total = CGImageSourceGetCount(source)
        guard total > 0 else { throw ToolError("\(url.lastPathComponent) has no frames.") }
        var starts: [Double] = []
        var clock = 0.0
        for index in 0..<total {
            starts.append(clock)
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            clock +=
                gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
                ?? gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0.1
        }
        let picks = count >= total ? Array(0..<total) : (0..<count).map { $0 * (total - 1) / max(1, count - 1) }
        return picks.compactMap { index in
            CGImageSourceCreateImageAtIndex(source, index, nil).map { (starts[index], $0) }
        }
    }

    private static func spread(count: Int, over duration: Double) -> [Double] {
        let last = max(0, duration - 0.05)
        guard count > 1 else { return [0] }
        return (0..<count).map { last * Double($0) / Double(count - 1) }
    }

    /// Lays frames out in a grid, left to right then top to bottom, as a JPEG.
    static func contactSheet(_ images: [CGImage], columns: Int, maximumWidth: Int = 1600) throws -> Data {
        guard let first = images.first else { throw ToolError("No frames to show.") }
        let columns = max(1, min(columns, images.count))
        let rows = (images.count + columns - 1) / columns
        let gap = 8
        let aspect = Double(first.height) / Double(max(1, first.width))
        let cellWidth = min(first.width, (maximumWidth - gap * (columns + 1)) / columns)
        let cellHeight = max(1, Int(Double(cellWidth) * aspect))
        let width = gap + columns * (cellWidth + gap)
        let height = gap + rows * (cellHeight + gap)

        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw ToolError("Couldn't draw the preview.") }
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        for (index, image) in images.enumerated() {
            let column = index % columns
            let row = index / columns
            // Core Graphics counts y from the bottom.
            let y = height - gap - (row + 1) * (cellHeight + gap) + gap
            context.draw(
                image,
                in: CGRect(x: gap + column * (cellWidth + gap), y: y, width: cellWidth, height: cellHeight))
        }
        guard let sheet = context.makeImage() else { throw ToolError("Couldn't draw the preview.") }

        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw ToolError("Couldn't encode the preview.") }
        CGImageDestinationAddImage(
            destination, sheet, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ToolError("Couldn't encode the preview.") }
        return data as Data
    }
}
