import Foundation

/// GIF-flavoured LZW compression (variable code width, LSB-first bit packing,
/// output framed in 255-byte sub-blocks).
enum LZW {
    private static let maxCodeCount = 4096
    private static let tableBits = 14
    private static let tableSize = 1 << tableBits
    private static let tableMask = tableSize - 1

    /// Appends `[minCodeSize][sub-blocks…][0]` for `indices` to `out`.
    static func encode(_ indices: UnsafeBufferPointer<UInt8>, minCodeSize: Int, into out: inout [UInt8]) {
        precondition((2...8).contains(minCodeSize), "GIF LZW min code size must be 2...8")
        precondition(!indices.isEmpty, "cannot LZW-encode an empty image")

        out.append(UInt8(minCodeSize))

        let clearCode = 1 << minCodeSize
        let endCode = clearCode + 1
        let initialBits = minCodeSize + 1

        var writer = BitWriter(out: out)
        out = []  // the writer owns the buffer while encoding, avoiding copy-on-write

        var codeBits = initialBits
        var maxCode = (1 << codeBits) - 1
        var nextCode = clearCode + 2

        // Open-addressing hash table: key = (prefix << 8 | byte), value = code.
        let keys = UnsafeMutablePointer<Int32>.allocate(capacity: tableSize)
        let values = UnsafeMutablePointer<UInt16>.allocate(capacity: tableSize)
        defer {
            keys.deallocate()
            values.deallocate()
        }
        keys.initialize(repeating: -1, count: tableSize)

        // Emits a code, then widens the code size exactly when a decoder would.
        func emit(_ code: Int, resetting: Bool = false) {
            writer.write(code, bits: codeBits)
            if resetting {
                codeBits = initialBits
                maxCode = (1 << codeBits) - 1
            } else if nextCode > maxCode && codeBits < 12 {
                codeBits += 1
                maxCode = codeBits == 12 ? maxCodeCount : (1 << codeBits) - 1
            }
        }

        emit(clearCode)
        var prefix = Int(indices[0])

        var i = 1
        let count = indices.count
        while i < count {
            let byte = Int(indices[i])
            i += 1

            let key = Int32(truncatingIfNeeded: (prefix << 8) | byte)
            var slot = Int((UInt32(bitPattern: key) &* 0x9E37_79B1) >> UInt32(32 - tableBits))
            var found = false
            while true {
                let existing = keys[slot]
                if existing == key {
                    prefix = Int(values[slot])
                    found = true
                    break
                }
                if existing < 0 { break }
                slot = (slot + 1) & tableMask
            }
            if found { continue }

            emit(prefix)
            prefix = byte

            if nextCode < maxCodeCount {
                keys[slot] = key
                values[slot] = UInt16(nextCode)
                nextCode += 1
            } else {
                // Dictionary is full: tell the decoder to start over.
                keys.update(repeating: -1, count: tableSize)
                nextCode = clearCode + 2
                emit(clearCode, resetting: true)
            }
        }

        emit(prefix)
        emit(endCode)
        out = writer.finish()
    }

    /// Packs variable-width codes LSB-first into length-prefixed sub-blocks.
    private struct BitWriter {
        private var out: [UInt8]
        private var accumulator: UInt32 = 0
        private var accumulatedBits = 0
        private var blockLengthIndex: Int
        private var blockLength = 0

        init(out: [UInt8]) {
            self.out = out
            blockLengthIndex = self.out.count
            self.out.append(0)
        }

        mutating func write(_ code: Int, bits: Int) {
            accumulator |= UInt32(code) << UInt32(accumulatedBits)
            accumulatedBits += bits
            while accumulatedBits >= 8 {
                put(UInt8(accumulator & 0xFF))
                accumulator >>= 8
                accumulatedBits -= 8
            }
        }

        private mutating func put(_ byte: UInt8) {
            out.append(byte)
            blockLength += 1
            if blockLength == 255 {
                out[blockLengthIndex] = 255
                blockLengthIndex = out.count
                out.append(0)
                blockLength = 0
            }
        }

        mutating func finish() -> [UInt8] {
            if accumulatedBits > 0 {
                put(UInt8(accumulator & 0xFF))
                accumulator = 0
                accumulatedBits = 0
            }
            if blockLength > 0 {
                out[blockLengthIndex] = UInt8(blockLength)
                out.append(0)  // block terminator
            }
            // Otherwise the pending zero length byte already is the terminator.
            return out
        }
    }
}
