import Foundation

/// Builds a palette of up to 256 colours for one GIF frame.
///
/// Pixels are bucketed into a 6-bit-per-channel histogram (keeping the true
/// average colour of each bucket), then the buckets are split with a
/// variance-minimising cut: the box with the largest squared error is divided
/// along its widest channel at the mean, which keeps small-but-distinct colours
/// (text anti-aliasing, icons) from being swamped by large flat backgrounds.
///
/// Pixels are packed `0x00RRGGBB` (BGRA bytes read as a little-endian UInt32).
final class ColorQuantizer {
    static let binCount = 1 << 18

    private let counts: UnsafeMutablePointer<UInt32>
    private let sumR: UnsafeMutablePointer<UInt32>
    private let sumG: UnsafeMutablePointer<UInt32>
    private let sumB: UnsafeMutablePointer<UInt32>
    private let binToIndex: UnsafeMutablePointer<UInt8>
    private var touched: [Int32] = []

    // Channel weights for error (roughly perceptual; green matters most).
    private static let weightR = 0.55
    private static let weightG = 1.0
    private static let weightB = 0.30

    init() {
        counts = .allocate(capacity: Self.binCount)
        sumR = .allocate(capacity: Self.binCount)
        sumG = .allocate(capacity: Self.binCount)
        sumB = .allocate(capacity: Self.binCount)
        binToIndex = .allocate(capacity: Self.binCount)
        counts.initialize(repeating: 0, count: Self.binCount)
        sumR.initialize(repeating: 0, count: Self.binCount)
        sumG.initialize(repeating: 0, count: Self.binCount)
        sumB.initialize(repeating: 0, count: Self.binCount)
        binToIndex.initialize(repeating: 0, count: Self.binCount)
        touched.reserveCapacity(4096)
    }

    deinit {
        counts.deallocate()
        sumR.deallocate()
        sumG.deallocate()
        sumB.deallocate()
        binToIndex.deallocate()
    }

    @inline(__always)
    private static func bin(_ pixel: UInt32) -> Int {
        Int(((pixel >> 2) & 0x3F) | ((pixel >> 4) & 0xFC0) | ((pixel >> 6) & 0x3F000))
    }

    /// Adds one pixel to the histogram for the palette being built.
    @inline(__always)
    func add(_ pixel: UInt32) {
        let b = Self.bin(pixel)
        if counts[b] == 0 { touched.append(Int32(b)) }
        counts[b] &+= 1
        sumB[b] &+= pixel & 0xFF
        sumG[b] &+= (pixel >> 8) & 0xFF
        sumR[b] &+= (pixel >> 16) & 0xFF
    }

    /// Palette index for a pixel. Only valid for pixels that were `add`ed before
    /// the most recent `buildPalette` call.
    @inline(__always)
    func index(for pixel: UInt32) -> UInt8 {
        binToIndex[Self.bin(pixel)]
    }

    /// Builds the palette from everything added so far and resets the histogram.
    /// Returns RGB triples (`count * 3` bytes).
    func buildPalette(maxColors: Int) -> [UInt8] {
        precondition((1...256).contains(maxColors))
        let n = touched.count
        guard n > 0 else { return [] }

        var red = [Double](repeating: 0, count: n)
        var green = [Double](repeating: 0, count: n)
        var blue = [Double](repeating: 0, count: n)
        var weight = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let b = Int(touched[i])
            let c = Double(counts[b])
            red[i] = Double(sumR[b]) / c
            green[i] = Double(sumG[b]) / c
            blue[i] = Double(sumB[b]) / c
            weight[i] = c
            counts[b] = 0
            sumR[b] = 0
            sumG[b] = 0
            sumB[b] = 0
        }
        defer { touched.removeAll(keepingCapacity: true) }

        var palette: [UInt8] = []

        if n <= maxColors {
            // Few enough distinct colours to keep every one of them.
            palette.reserveCapacity(n * 3)
            for i in 0..<n {
                palette.append(Self.byte(red[i]))
                palette.append(Self.byte(green[i]))
                palette.append(Self.byte(blue[i]))
                binToIndex[Int(touched[i])] = UInt8(i)
            }
            return palette
        }

        struct Box {
            var lo: Int
            var hi: Int
            var total: Double
            var sumR: Double
            var sumG: Double
            var sumB: Double
            var error: Double  // weighted sum of squared error across channels
            var axis: Int  // channel with the most error
            var cut: Double  // mean along `axis`
        }

        var order = [Int32](unsafeUninitializedCapacity: n) { buffer, count in
            for i in 0..<n { buffer[i] = Int32(i) }
            count = n
        }

        func makeBox(_ lo: Int, _ hi: Int) -> Box {
            var total = 0.0, sr = 0.0, sg = 0.0, sb = 0.0
            var qr = 0.0, qg = 0.0, qb = 0.0
            for j in lo..<hi {
                let e = Int(order[j])
                let w = weight[e]
                let r = red[e], g = green[e], b = blue[e]
                total += w
                sr += w * r
                sg += w * g
                sb += w * b
                qr += w * r * r
                qg += w * g * g
                qb += w * b * b
            }
            let er = max(0, qr - sr * sr / total) * Self.weightR
            let eg = max(0, qg - sg * sg / total) * Self.weightG
            let eb = max(0, qb - sb * sb / total) * Self.weightB
            var axis = 0
            var cut = sr / total
            var top = er
            if eg > top {
                axis = 1
                cut = sg / total
                top = eg
            }
            if eb > top {
                axis = 2
                cut = sb / total
            }
            let error = hi - lo > 1 ? er + eg + eb : 0
            return Box(lo: lo, hi: hi, total: total, sumR: sr, sumG: sg, sumB: sb, error: error, axis: axis, cut: cut)
        }

        var boxes = [makeBox(0, n)]
        boxes.reserveCapacity(maxColors)

        while boxes.count < maxColors {
            var best = -1
            var bestError = 1e-9
            for (i, box) in boxes.enumerated() where box.error > bestError {
                best = i
                bestError = box.error
            }
            guard best >= 0 else { break }
            let box = boxes[best]

            // Partition the box's entries around the mean of its widest channel.
            var i = box.lo
            var j = box.hi - 1
            while i <= j {
                let e = Int(order[i])
                let value = box.axis == 0 ? red[e] : (box.axis == 1 ? green[e] : blue[e])
                if value <= box.cut {
                    i += 1
                } else {
                    order.swapAt(i, j)
                    j -= 1
                }
            }
            let mid = i
            if mid == box.lo || mid == box.hi {
                boxes[best].error = 0  // numerically unsplittable
                continue
            }
            boxes[best] = makeBox(box.lo, mid)
            boxes.append(makeBox(mid, box.hi))
        }

        palette.reserveCapacity(boxes.count * 3)
        for (index, box) in boxes.enumerated() {
            palette.append(Self.byte(box.sumR / box.total))
            palette.append(Self.byte(box.sumG / box.total))
            palette.append(Self.byte(box.sumB / box.total))
            for j in box.lo..<box.hi {
                binToIndex[Int(touched[Int(order[j])])] = UInt8(index)
            }
        }
        return palette
    }

    @inline(__always)
    private static func byte(_ value: Double) -> UInt8 {
        UInt8(max(0, min(255, value.rounded())))
    }
}
