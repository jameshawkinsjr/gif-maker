import Foundation

/// Where encoded GIF bytes go.
public protocol GIFByteSink: AnyObject {
    func write(_ bytes: [UInt8]) throws
    func close() throws
    var bytesWritten: Int { get }
}

/// Writes to a file as frames are produced, so memory stays flat for long GIFs.
public final class FileByteSink: GIFByteSink {
    private let handle: FileHandle
    public private(set) var bytesWritten = 0

    public init(url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
    }

    public func write(_ bytes: [UInt8]) throws {
        try handle.write(contentsOf: Data(bytes))
        bytesWritten += bytes.count
    }

    public func close() throws {
        try handle.close()
    }
}

/// Discards the bytes and only counts them (used to answer "how big would this be?").
public final class CountingByteSink: GIFByteSink {
    public private(set) var bytesWritten = 0
    public init() {}
    public func write(_ bytes: [UInt8]) throws { bytesWritten += bytes.count }
    public func close() throws {}
}

/// Collects the bytes in memory.
public final class DataByteSink: GIFByteSink {
    public private(set) var data = Data()
    public var bytesWritten: Int { data.count }
    public init() {}
    public func write(_ bytes: [UInt8]) throws { data.append(contentsOf: bytes) }
    public func close() throws {}
}

/// A streaming animated-GIF encoder tuned for screen recordings.
///
/// Each frame gets its own palette, and only the pixels that changed since they
/// were last drawn are encoded: everything else is left transparent so the
/// previous frame shows through. For typical screen content that makes files
/// several times smaller than encoding every frame in full.
public final class GIFEncoder {
    public struct Options {
        /// Netscape loop count. 0 loops forever.
        public var loopCount: Int = 0
        /// A pixel is re-encoded only when a channel moved by more than this
        /// since the pixel was last drawn. Hides video-compression shimmer in
        /// static areas; 0 re-encodes on any change at all.
        public var changeThreshold: Int = 2

        public init(loopCount: Int = 0, changeThreshold: Int = 2) {
            self.loopCount = loopCount
            self.changeThreshold = changeThreshold
        }
    }

    public let width: Int
    public let height: Int
    public private(set) var frameCount = 0
    public var bytesWritten: Int { sink.bytesWritten }

    private let sink: GIFByteSink
    private let options: Options
    private let quantizer = ColorQuantizer()

    /// True colour of each pixel at the moment it was last encoded.
    private let reference: UnsafeMutablePointer<UInt32>
    private let changed: UnsafeMutablePointer<UInt8>
    private let indices: UnsafeMutablePointer<UInt8>

    /// The most recent frame is held back until the next one arrives, because
    /// its delay isn't known until then (identical frames just extend it).
    private struct PendingFrame {
        var body: [UInt8]  // image descriptor + colour table + LZW data
        var transparentIndex: Int?
    }
    private var pending: PendingFrame?
    private var hasFirstFrame = false
    /// Ideal time at which the pending frame stops being displayed.
    private var scheduledTime = 0.0
    private var emittedCentiseconds = 0
    private var finished = false

    public init(sink: GIFByteSink, width: Int, height: Int, options: Options = Options()) throws {
        precondition(width > 0 && height > 0 && width <= 65535 && height <= 65535, "invalid GIF size")
        self.sink = sink
        self.width = width
        self.height = height
        self.options = options

        let pixelCount = width * height
        reference = .allocate(capacity: pixelCount)
        changed = .allocate(capacity: pixelCount)
        indices = .allocate(capacity: pixelCount)
        reference.initialize(repeating: 0, count: pixelCount)
        changed.initialize(repeating: 0, count: pixelCount)
        indices.initialize(repeating: 0, count: pixelCount)

        var header: [UInt8] = Array("GIF89a".utf8)
        header.append(contentsOf: Self.le16(width))
        header.append(contentsOf: Self.le16(height))
        header.append(0x70)  // no global colour table, 8 bits of colour resolution
        header.append(0)  // background colour index
        header.append(0)  // pixel aspect ratio
        // Looping extension.
        header.append(contentsOf: [0x21, 0xFF, 0x0B])
        header.append(contentsOf: Array("NETSCAPE2.0".utf8))
        header.append(contentsOf: [0x03, 0x01])
        header.append(contentsOf: Self.le16(options.loopCount))
        header.append(0)
        try sink.write(header)
    }

    deinit {
        reference.deallocate()
        changed.deallocate()
        indices.deallocate()
    }

    /// Adds a frame shown for `duration` seconds.
    ///
    /// `pixels` is `width * height` BGRA pixels (the native macOS bitmap layout,
    /// i.e. `0xAARRGGBB` as a little-endian UInt32) with no row padding. Alpha is ignored.
    public func addFrame(_ pixels: UnsafePointer<UInt32>, duration: Double) throws {
        precondition(!finished, "encoder already finished")
        let threshold = Int32(options.changeThreshold)
        let isFirst = !hasFirstFrame

        var minX = width, minY = height, maxX = -1, maxY = -1

        if isFirst {
            for i in 0..<(width * height) {
                let pixel = pixels[i] & 0x00FF_FFFF
                reference[i] = pixel
                quantizer.add(pixel)
            }
            minX = 0
            minY = 0
            maxX = width - 1
            maxY = height - 1
        } else {
            var i = 0
            for y in 0..<height {
                var rowChanged = false
                for x in 0..<width {
                    let pixel = pixels[i] & 0x00FF_FFFF
                    let old = reference[i]
                    var isChanged = false
                    if pixel != old {
                        if threshold == 0 {
                            isChanged = true
                        } else {
                            let db = abs(Int32(pixel & 0xFF) - Int32(old & 0xFF))
                            let dg = abs(Int32((pixel >> 8) & 0xFF) - Int32((old >> 8) & 0xFF))
                            let dr = abs(Int32((pixel >> 16) & 0xFF) - Int32((old >> 16) & 0xFF))
                            isChanged = db > threshold || dg > threshold || dr > threshold
                        }
                    }
                    if isChanged {
                        changed[i] = 1
                        quantizer.add(pixel)
                        if x < minX { minX = x }
                        if x > maxX { maxX = x }
                        rowChanged = true
                    } else {
                        changed[i] = 0
                    }
                    i += 1
                }
                if rowChanged {
                    if y < minY { minY = y }
                    maxY = y
                }
            }
        }

        if maxX < 0 {
            // Nothing moved: just hold the previous frame longer.
            scheduledTime += duration
            return
        }

        // The previous frame's display time is now known, so it can be written.
        try flushPending()
        scheduledTime += duration

        let boxWidth = maxX - minX + 1
        let boxHeight = maxY - minY + 1
        let palette = quantizer.buildPalette(maxColors: isFirst ? 256 : 255)
        let colorCount = palette.count / 3
        let transparentIndex: Int? = isFirst ? nil : colorCount

        var out = 0
        if isFirst {
            for i in 0..<(width * height) {
                indices[i] = quantizer.index(for: reference[i])
            }
            out = width * height
        } else {
            let transparent = UInt8(colorCount)
            for y in minY...maxY {
                var i = y * width + minX
                for _ in 0..<boxWidth {
                    if changed[i] != 0 {
                        let pixel = pixels[i] & 0x00FF_FFFF
                        reference[i] = pixel
                        indices[out] = quantizer.index(for: pixel)
                    } else {
                        indices[out] = transparent
                    }
                    out += 1
                    i += 1
                }
            }
        }

        let tableEntries = colorCount + (transparentIndex == nil ? 0 : 1)
        var tableBits = 1
        while (1 << tableBits) < tableEntries { tableBits += 1 }

        var body: [UInt8] = []
        body.reserveCapacity(out / 2 + 1024)
        body.append(0x2C)  // image descriptor
        body.append(contentsOf: Self.le16(minX))
        body.append(contentsOf: Self.le16(minY))
        body.append(contentsOf: Self.le16(boxWidth))
        body.append(contentsOf: Self.le16(boxHeight))
        body.append(0x80 | UInt8(tableBits - 1))  // local colour table follows
        body.append(contentsOf: palette)
        body.append(contentsOf: [UInt8](repeating: 0, count: (1 << tableBits) * 3 - palette.count))
        LZW.encode(UnsafeBufferPointer(start: indices, count: out), minCodeSize: max(2, tableBits), into: &body)

        pending = PendingFrame(body: body, transparentIndex: transparentIndex)
        hasFirstFrame = true
        frameCount += 1
    }

    /// Writes the trailer and closes the sink. Returns the total size in bytes.
    @discardableResult
    public func finish() throws -> Int {
        precondition(!finished, "encoder already finished")
        finished = true
        try flushPending()
        try sink.write([0x3B])
        try sink.close()
        return sink.bytesWritten
    }

    private func flushPending() throws {
        guard let frame = pending else { return }
        pending = nil

        // GIF delays are whole centiseconds. Round against the running total so
        // e.g. 30 fps comes out as 3,3,4,3,3,4… rather than drifting, and never
        // go below 2cs, which browsers treat as "unset" and play at 10 fps.
        let target = Int((scheduledTime * 100).rounded())
        let delay = max(2, min(65535, target - emittedCentiseconds))
        emittedCentiseconds += delay

        var bytes: [UInt8] = [0x21, 0xF9, 0x04]
        // Disposal 1: leave the frame in place so later frames can draw on top.
        bytes.append((1 << 2) | (frame.transparentIndex == nil ? 0 : 1))
        bytes.append(contentsOf: Self.le16(delay))
        bytes.append(UInt8(frame.transparentIndex ?? 0))
        bytes.append(0)
        bytes.append(contentsOf: frame.body)
        try sink.write(bytes)
    }

    private static func le16(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }
}
