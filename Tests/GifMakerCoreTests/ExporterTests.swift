import AVFoundation
import CoreGraphics
import XCTest

@testable import GifMakerCore

/// Exports synthetic movies in which every frame is identifiable: a red bar
/// whose horizontal position encodes the frame number.
final class ExporterTests: XCTestCase {
    static let movieWidth = 320
    static let movieHeight = 200
    static let barWidth = 6

    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("gifmaker-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Fixtures

    /// Writes a movie with one frame at each of `times`; frame `i` has its bar at `x = i * barWidth`.
    func makeMovie(times: [Double], name: String = "source.mov") async throws -> URL {
        let url = directory.appendingPathComponent(name)
        let (width, height) = (Self.movieWidth, Self.movieHeight)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 6_000_000,
                    AVVideoMaxKeyFrameIntervalKey: 30,
                    AVVideoAllowFrameReorderingKey: false,
                ] as [String: Any],
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for (index, time) in times.enumerated() {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var created: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &created)
            let buffer = try XCTUnwrap(created)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            let barStart = index * Self.barWidth
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt32.self)
                for x in 0..<width {
                    let inBar = x >= barStart && x < barStart + Self.barWidth
                    row[x] = inBar ? 0xFFE0_1010 : 0xFFD8_D8D8
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600)))
        }
        input.markAsFinished()
        let last = times.last ?? 0
        let spacing = times.count > 1 ? times[1] - times[0] : 1.0 / 30
        writer.endSession(atSourceTime: CMTime(seconds: last + spacing, preferredTimescale: 600))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    /// 45 frames at 30 fps (1.5 seconds).
    func makeSmoothMovie() async throws -> URL {
        try await makeMovie(times: (0..<45).map { Double($0) / 30 })
    }

    /// Which source frame a decoded image shows, judged by where its red bar is.
    func sourceFrameIndex(of pixels: [UInt32], width: Int, height: Int) -> Int? {
        let row = height / 2
        var sum = 0.0
        var count = 0.0
        for x in 0..<width {
            let pixel = pixels[row * width + x]
            let r = Int((pixel >> 16) & 0xFF), g = Int((pixel >> 8) & 0xFF)
            if r > 150 && g < 110 {
                sum += Double(x) + 0.5
                count += 1
            }
        }
        guard count > 0 else { return nil }
        let scale = Double(Self.movieWidth) / Double(width)
        let centre = sum / count * scale
        return Int(((centre - Double(Self.barWidth) / 2) / Double(Self.barWidth)).rounded())
    }

    func exportGIF(_ source: URL, _ settings: EditSettings, name: String = "out.gif") async throws
        -> (outcome: ExportOutcome, gif: GIFEncoderTests.DecodedGIF, url: URL)
    {
        let url = directory.appendingPathComponent(name)
        let outcome = try await Exporter.export(source: source, settings: settings, format: .gif, destination: url)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, outcome.byteCount)
        return (outcome, try GIFEncoderTests.decode(data), url)
    }

    func frameIndices(_ gif: GIFEncoderTests.DecodedGIF) -> [Int?] {
        gif.frames.map { sourceFrameIndex(of: $0, width: gif.width, height: gif.height) }
    }

    func settings(duration: Double = 1.5, width: Int = ExporterTests.movieWidth) -> EditSettings {
        EditSettings(trimStart: 0, trimEnd: duration, outputWidth: width)
    }

    // MARK: Tests

    func testNormalLoopSamplesFramesInOrder() async throws {
        let source = try await makeSmoothMovie()
        let (outcome, gif, _) = try await exportGIF(source, settings())

        // 1.5s at the standard 15 fps.
        XCTAssertEqual(outcome.frameCount, 23)
        XCTAssertEqual(gif.frames.count, 23)
        XCTAssertEqual(gif.width, Self.movieWidth)
        XCTAssertEqual(gif.height, Self.movieHeight)
        // Output frame k is taken at k/15s, i.e. source frame 2k.
        XCTAssertEqual(frameIndices(gif), (0..<23).map { Optional($0 * 2) })
        XCTAssertEqual(gif.delays.reduce(0, +), 23.0 / 15, accuracy: 0.011)
    }

    func testReverseLoopPlaysBackwards() async throws {
        let source = try await makeSmoothMovie()
        var edit = settings()
        edit.loopType = .reverse
        let (_, gif, _) = try await exportGIF(source, edit)
        XCTAssertEqual(frameIndices(gif), (0..<23).reversed().map { Optional($0 * 2) })
    }

    func testPingPongGoesThereAndBackWithoutRepeatingTheEnds() async throws {
        let source = try await makeSmoothMovie()
        var edit = settings()
        edit.loopType = .pingPong
        let (outcome, gif, _) = try await exportGIF(source, edit)
        let forward = Array(0..<23)
        let expected = (forward + forward.dropFirst().dropLast().reversed()).map { Optional($0 * 2) }
        XCTAssertEqual(outcome.frameCount, 44)
        XCTAssertEqual(frameIndices(gif), expected)
    }

    func testTrimSelectsOnlyTheChosenRange() async throws {
        let source = try await makeSmoothMovie()
        var edit = settings()
        edit.trimStart = 0.5
        edit.trimEnd = 1.0
        edit.frameRate = .max
        let (_, gif, _) = try await exportGIF(source, edit)
        // 0.5s…1.0s at 30 fps is source frames 15 through 29.
        XCTAssertEqual(frameIndices(gif), (15..<30).map { Optional($0) })
    }

    func testSpeedChangesTimingButNotFrames() async throws {
        let source = try await makeSmoothMovie()
        var fast = settings()
        fast.speed = 2
        let (outcome, gif, _) = try await exportGIF(source, fast)
        XCTAssertEqual(outcome.frameCount, 23)
        XCTAssertEqual(frameIndices(gif), (0..<23).map { Optional($0 * 2) })
        XCTAssertEqual(gif.delays.reduce(0, +), 23.0 / 30, accuracy: 0.011)
        XCTAssertEqual(outcome.duration, 23.0 / 30, accuracy: 0.0001)

        var slow = settings()
        slow.speed = 0.5
        let (_, slowGIF, _) = try await exportGIF(source, slow, name: "slow.gif")
        XCTAssertEqual(slowGIF.delays.reduce(0, +), 23.0 / 7.5, accuracy: 0.011)
    }

    func testOutputWidthScalesTheImage() async throws {
        let source = try await makeSmoothMovie()
        let (outcome, gif, _) = try await exportGIF(source, settings(width: 160))
        XCTAssertEqual(outcome.width, 160)
        XCTAssertEqual(outcome.height, 100)
        XCTAssertEqual(gif.width, 160)
        XCTAssertEqual(gif.height, 100)
        XCTAssertEqual(frameIndices(gif), (0..<23).map { Optional($0 * 2) })
    }

    /// Screen recordings only contain a frame when something changed, so a
    /// requested moment usually falls between frames.
    func testSparseSourceHoldsEachFrameUntilTheNextOne() async throws {
        let source = try await makeMovie(times: (0..<8).map { Double($0) * 0.2 })
        var edit = settings(duration: 1.6)
        edit.frameRate = .max
        let (outcome, gif, _) = try await exportGIF(source, edit)
        XCTAssertEqual(outcome.frameCount, 48)
        // Repeats of the same picture collapse into one longer GIF frame.
        XCTAssertEqual(frameIndices(gif), (0..<8).map { Optional($0) })
        for delay in gif.delays { XCTAssertEqual(delay, 0.2, accuracy: 0.011) }
    }

    func testMeasuringSizeMatchesTheRealFile() async throws {
        let source = try await makeSmoothMovie()
        let edit = settings(width: 200)
        let measured = try await Exporter.export(source: source, settings: edit, format: .gif, destination: nil)
        let (written, _, _) = try await exportGIF(source, edit)
        XCTAssertEqual(measured.byteCount, written.byteCount)
        XCTAssertGreaterThan(measured.byteCount, 1000)
    }

    func testCaptionIsDrawnOnlyWhileVisible() async throws {
        let source = try await makeSmoothMovie()
        var edit = settings()
        edit.captions = [Caption(text: "HELLO", start: 0.5, end: 1.0, size: 0.16, centerX: 0.5, centerY: 0.8)]
        let (_, gif, _) = try await exportGIF(source, edit)

        // Count near-white pixels in the band where the caption sits (the background is light grey, not white).
        func whitePixels(_ frame: [UInt32]) -> Int {
            var count = 0
            for y in Int(Double(gif.height) * 0.68)..<Int(Double(gif.height) * 0.92) {
                for x in 0..<gif.width {
                    let p = frame[y * gif.width + x]
                    if (p >> 16) & 0xFF > 245 && (p >> 8) & 0xFF > 245 && p & 0xFF > 245 { count += 1 }
                }
            }
            return count
        }
        XCTAssertEqual(gif.frames.count, 23)
        for (index, frame) in gif.frames.enumerated() {
            let time = Double(index) / 15
            let white = whitePixels(frame)
            if time >= 0.5 && time < 1.0 {
                XCTAssertGreaterThan(white, 300, "caption missing at \(time)s")
            } else {
                XCTAssertEqual(white, 0, "caption should not be visible at \(time)s")
            }
        }
    }

    func testMP4ExportProducesAPlayableMovie() async throws {
        let source = try await makeSmoothMovie()
        var edit = settings(width: 201)  // odd on purpose: video needs even dimensions
        edit.loopType = .pingPong
        let url = directory.appendingPathComponent("out.mp4")
        let outcome = try await Exporter.export(source: source, settings: edit, format: .mp4, destination: url)

        XCTAssertEqual(outcome.width, 200)
        XCTAssertEqual(outcome.height % 2, 0)
        XCTAssertEqual(outcome.frameCount, 44)
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first
        let size = try await XCTUnwrap(track).load(.naturalSize)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(Int(size.width), outcome.width)
        XCTAssertEqual(Int(size.height), outcome.height)
        XCTAssertEqual(duration, 44.0 / 15, accuracy: 0.05)
        XCTAssertEqual(try Data(contentsOf: url).count, outcome.byteCount)
    }

    func testCancellingStopsAndRemovesThePartialFile() async throws {
        let source = try await makeSmoothMovie()
        let url = directory.appendingPathComponent("cancelled.gif")
        let counter = Counter()
        do {
            _ = try await Exporter.export(
                source: source, settings: settings(), format: .gif, destination: url,
                progress: { _ in counter.increment() },
                isCancelled: { counter.value >= 5 })
            XCTFail("export should have been cancelled")
        } catch ExportError.cancelled {
            // expected
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFramePlanHandlesDegenerateInput() {
        let tiny = EditSettings(trimStart: 0.4, trimEnd: 0.4, outputWidth: 5000)
        let plan = FramePlan(settings: tiny, sourceWidth: 320, sourceHeight: 200, sourceDuration: 1)
        XCTAssertEqual(plan.frameCount, 1)
        XCTAssertEqual(plan.outputWidth, 320, "can't export wider than the source")

        var twoFrames = EditSettings(trimStart: 0, trimEnd: 0.2, outputWidth: 320)
        twoFrames.frameRate = .low
        twoFrames.loopType = .pingPong
        XCTAssertEqual(
            FramePlan(settings: twoFrames, sourceWidth: 320, sourceHeight: 200, sourceDuration: 1).sequence, [0, 1])

        // 30 fps at 4x speed would need 120 fps playback; it's capped at 50.
        var fast = EditSettings(trimStart: 0, trimEnd: 1, outputWidth: 320)
        fast.frameRate = .max
        fast.speed = 4
        let fastPlan = FramePlan(settings: fast, sourceWidth: 320, sourceHeight: 200, sourceDuration: 1)
        XCTAssertEqual(fastPlan.outputFPS, 50, accuracy: 0.001)
        XCTAssertEqual(fastPlan.duration, 0.25, accuracy: 0.03)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
