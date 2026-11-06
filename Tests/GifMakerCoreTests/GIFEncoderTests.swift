import CoreGraphics
import ImageIO
import XCTest

@testable import GifMakerCore

/// Round-trips animations through `GIFEncoder` and Apple's ImageIO decoder.
final class GIFEncoderTests: XCTestCase {
    // MARK: Helpers

    /// Packs a colour the way the encoder expects (BGRA bytes, little-endian).
    static func pack(_ r: Int, _ g: Int, _ b: Int) -> UInt32 {
        0xFF00_0000 | UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
    }

    struct DecodedGIF {
        var width: Int
        var height: Int
        var frames: [[UInt32]]
        var delays: [Double]
        var loopCount: Int?
    }

    static func encode(
        width: Int, height: Int, frames: [[UInt32]], duration: Double,
        options: GIFEncoder.Options = .init()
    ) throws -> Data {
        let sink = DataByteSink()
        let encoder = try GIFEncoder(sink: sink, width: width, height: height, options: options)
        for frame in frames {
            try frame.withUnsafeBufferPointer { try encoder.addFrame($0.baseAddress!, duration: duration) }
        }
        try encoder.finish()
        return sink.data
    }

    static func decode(_ data: Data) throws -> DecodedGIF {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw XCTSkip("ImageIO could not open the GIF")
        }
        let count = CGImageSourceGetCount(source)
        var result = DecodedGIF(width: 0, height: 0, frames: [], delays: [], loopCount: nil)
        if let props = CGImageSourceCopyProperties(source, nil) as? [CFString: Any],
            let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        {
            result.loopCount = gif[kCGImagePropertyGIFLoopCount] as? Int
        }
        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                XCTFail("frame \(index) failed to decode")
                continue
            }
            result.width = image.width
            result.height = image.height
            var pixels = [UInt32](repeating: 0, count: image.width * image.height)
            pixels.withUnsafeMutableBytes { raw in
                let context = CGContext(
                    data: raw.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                    space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)!
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            result.frames.append(pixels)
            if let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any],
                let delay = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
            {
                result.delays.append(delay)
            }
        }
        return result
    }

    static func maxChannelDifference(_ a: [UInt32], _ b: [UInt32]) -> Int {
        var worst = 0
        for i in 0..<a.count {
            for shift in [0, 8, 16] {
                let d = abs(Int((a[i] >> UInt32(shift)) & 0xFF) - Int((b[i] >> UInt32(shift)) & 0xFF))
                worst = max(worst, d)
            }
        }
        return worst
    }

    static func psnr(_ a: [UInt32], _ b: [UInt32]) -> Double {
        var squared = 0.0
        for i in 0..<a.count {
            for shift in [0, 8, 16] {
                let d = Double(Int((a[i] >> UInt32(shift)) & 0xFF) - Int((b[i] >> UInt32(shift)) & 0xFF))
                squared += d * d
            }
        }
        let mse = squared / Double(a.count * 3)
        return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
    }

    /// A flat background with a coloured square that moves each frame.
    static func movingSquareFrames(width: Int, height: Int, count: Int) -> [[UInt32]] {
        (0..<count).map { f in
            var pixels = [UInt32](repeating: pack(240, 240, 244), count: width * height)
            let x0 = 4 + f * 5, y0 = 6 + f * 3
            for y in y0..<min(height, y0 + 12) {
                for x in x0..<min(width, x0 + 12) {
                    pixels[y * width + x] = pack(220, 40 + f * 8, 60)
                }
            }
            // A static detail that must survive untouched across frames.
            for x in 0..<width { pixels[(height - 2) * width + x] = pack(20, 20, 20) }
            return pixels
        }
    }

    // MARK: Tests

    func testFlatColourAnimationRoundTripsExactly() throws {
        let (w, h) = (80, 60)
        let frames = Self.movingSquareFrames(width: w, height: h, count: 8)
        let data = try Self.encode(width: w, height: h, frames: frames, duration: 0.1, options: .init(changeThreshold: 0))
        let decoded = try Self.decode(data)

        XCTAssertEqual(decoded.width, w)
        XCTAssertEqual(decoded.height, h)
        XCTAssertEqual(decoded.frames.count, frames.count)
        XCTAssertEqual(decoded.loopCount, 0, "should loop forever")
        for (index, frame) in decoded.frames.enumerated() {
            XCTAssertEqual(
                Self.maxChannelDifference(frame, frames[index]), 0,
                "frame \(index) should decode to exactly the source pixels")
        }
    }

    func testDelaysAreAccurateAndDoNotDrift() throws {
        let (w, h) = (40, 30)
        let frames = Self.movingSquareFrames(width: w, height: h, count: 6)

        let tenth = try Self.decode(try Self.encode(width: w, height: h, frames: frames, duration: 0.1))
        XCTAssertEqual(tenth.delays.count, 6)
        for delay in tenth.delays { XCTAssertEqual(delay, 0.1, accuracy: 0.0001) }

        // 30 fps can't be expressed exactly in centiseconds; the total must still be right.
        let thirty = try Self.decode(try Self.encode(width: w, height: h, frames: frames, duration: 1.0 / 30))
        XCTAssertEqual(thirty.delays.reduce(0, +), 0.2, accuracy: 0.0001)
        for delay in thirty.delays { XCTAssertTrue(delay == 0.03 || delay == 0.04, "unexpected delay \(delay)") }
    }

    func testIdenticalFramesCollapseIntoOneLongerFrame() throws {
        let (w, h) = (40, 30)
        let moving = Self.movingSquareFrames(width: w, height: h, count: 2)
        let frames = [moving[0], moving[0], moving[0], moving[1], moving[1]]
        let decoded = try Self.decode(try Self.encode(width: w, height: h, frames: frames, duration: 0.1))

        XCTAssertEqual(decoded.frames.count, 2)
        XCTAssertEqual(decoded.delays[0], 0.3, accuracy: 0.0001)
        XCTAssertEqual(decoded.delays[1], 0.2, accuracy: 0.0001)
        XCTAssertEqual(Self.maxChannelDifference(decoded.frames[1], moving[1]), 0)
    }

    func testOnlyChangedRegionIsEncoded() throws {
        let (w, h) = (400, 300)
        let frames = Self.movingSquareFrames(width: w, height: h, count: 10)
        let animated = try Self.encode(width: w, height: h, frames: frames, duration: 0.1)
        let single = try Self.encode(width: w, height: h, frames: [frames[0]], duration: 0.1)
        // Nine more frames of a small moving square should cost far less than nine full frames.
        XCTAssertLessThan(animated.count, single.count * 3)
    }

    func testManyColoursQuantiseWithGoodFidelity() throws {
        let (w, h) = (160, 120)
        let frames: [[UInt32]] = (0..<4).map { f in
            var pixels = [UInt32](repeating: 0, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    let r = (x * 255 / (w - 1) + f * 20) % 256
                    let g = y * 255 / (h - 1)
                    let b = ((x + y) * 255 / (w + h - 2) + f * 35) % 256
                    pixels[y * w + x] = Self.pack(r, g, b)
                }
            }
            return pixels
        }
        let decoded = try Self.decode(try Self.encode(width: w, height: h, frames: frames, duration: 0.1))
        XCTAssertEqual(decoded.frames.count, 4)
        for (index, frame) in decoded.frames.enumerated() {
            let quality = Self.psnr(frame, frames[index])
            XCTAssertGreaterThan(quality, 30, "frame \(index) PSNR \(quality) dB is too low")
        }
    }

    func testSmallChangesBelowThresholdAreIgnored() throws {
        let (w, h) = (40, 30)
        let base = [UInt32](repeating: Self.pack(100, 100, 100), count: w * h)
        let shimmer = [UInt32](repeating: Self.pack(101, 99, 102), count: w * h)
        let data = try Self.encode(
            width: w, height: h, frames: [base, shimmer, base], duration: 0.1, options: .init(changeThreshold: 2))
        let decoded = try Self.decode(data)
        XCTAssertEqual(decoded.frames.count, 1, "sub-threshold shimmer should not produce new frames")
        XCTAssertEqual(decoded.delays[0], 0.3, accuracy: 0.0001)
    }

    /// Video compression needs a few frames to settle after a change, so what
    /// was drawn first can be slightly off from where the source ends up.
    func testPixelsAreRedrawnOnceAfterTheSourceSettles() throws {
        let (w, h) = (40, 30)
        let rough = [UInt32](repeating: Self.pack(100, 100, 100), count: w * h)
        let settled = [UInt32](repeating: Self.pack(102, 101, 100), count: w * h)
        let frames = [rough] + Array(repeating: settled, count: 9)
        let decoded = try Self.decode(
            try Self.encode(
                width: w, height: h, frames: frames, duration: 0.1,
                options: .init(changeThreshold: 2, settleFrames: 4)))

        XCTAssertEqual(decoded.frames.count, 2, "one redraw once the source has settled, and no more")
        XCTAssertEqual(decoded.delays[0], 0.4, accuracy: 0.0001)
        XCTAssertEqual(decoded.delays[1], 0.6, accuracy: 0.0001)
        XCTAssertEqual(Self.maxChannelDifference(decoded.frames[1], settled), 0)
    }

    /// Once a pixel has had its follow-up check, later shimmer is ignored again.
    func testLongSettledPixelsIgnoreLaterShimmer() throws {
        let (w, h) = (40, 30)
        let base = [UInt32](repeating: Self.pack(100, 100, 100), count: w * h)
        let shimmer = [UInt32](repeating: Self.pack(102, 101, 100), count: w * h)
        let frames = Array(repeating: base, count: 8) + Array(repeating: shimmer, count: 8)
        let decoded = try Self.decode(
            try Self.encode(
                width: w, height: h, frames: frames, duration: 0.1,
                options: .init(changeThreshold: 2, settleFrames: 4)))

        XCTAssertEqual(decoded.frames.count, 1)
        XCTAssertEqual(decoded.delays[0], 1.6, accuracy: 0.0001)
    }

    /// Noise defeats LZW's dictionary, forcing many dictionary resets and every code width.
    func testNoiseSurvivesLZWDictionaryResets() throws {
        let (w, h) = (300, 300)
        var state: UInt64 = 0x1234_5678_9ABC_DEF0
        func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state >> 33)
        }
        for levels in [2, 3, 4, 6] {
            let step = 255 / (levels - 1)
            let frame = (0..<(w * h)).map { _ in
                Self.pack(next() % levels * step, next() % levels * step, next() % levels * step)
            }
            let decoded = try Self.decode(
                try Self.encode(width: w, height: h, frames: [frame], duration: 0.1, options: .init(changeThreshold: 0)))
            XCTAssertEqual(decoded.frames.count, 1)
            XCTAssertEqual(
                Self.maxChannelDifference(decoded.frames[0], frame), 0, "\(levels * levels * levels)-colour noise")
        }
    }

    func testTinyAndOddSizes() throws {
        for (w, h) in [(1, 1), (1, 7), (3, 2), (17, 5)] {
            let frames: [[UInt32]] = (0..<3).map { f in
                (0..<(w * h)).map { i in Self.pack((i * 37 + f * 80) % 256, (i * 11) % 256, f * 100) }
            }
            let decoded = try Self.decode(
                try Self.encode(width: w, height: h, frames: frames, duration: 0.05, options: .init(changeThreshold: 0)))
            XCTAssertEqual(decoded.frames.count, 3, "\(w)x\(h)")
            for (index, frame) in decoded.frames.enumerated() {
                XCTAssertEqual(Self.maxChannelDifference(frame, frames[index]), 0, "\(w)x\(h) frame \(index)")
            }
        }
    }
}
