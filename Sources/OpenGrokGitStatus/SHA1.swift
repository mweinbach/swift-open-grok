// SHA1.swift
//
// Portable pure-Swift SHA-1 for Git object/blob hashing.
//
// Avoids unconditional CryptoKit so Linux and other non-Apple hosts do not
// require Apple crypto frameworks. Git uses SHA-1 for object IDs; this is not
// a general-purpose security primitive.

import Foundation

/// Pure Swift SHA-1 (FIPS 180-1). Produces a 20-byte digest.
public enum PortableSHA1 {
    /// Hash the concatenation of `pieces` without allocating a single merged buffer
    /// when a single piece is provided.
    public static func hash(_ pieces: Data...) -> Data {
        var ctx = Context()
        for piece in pieces {
            ctx.update(piece)
        }
        return ctx.finalize()
    }

    public static func hash(_ data: Data) -> Data {
        var ctx = Context()
        ctx.update(data)
        return ctx.finalize()
    }

    // MARK: - Context

    struct Context {
        private var h0: UInt32 = 0x6745_2301
        private var h1: UInt32 = 0xEFCD_AB89
        private var h2: UInt32 = 0x98BA_DCFE
        private var h3: UInt32 = 0x1032_5476
        private var h4: UInt32 = 0xC3D2_E1F0
        private var messageLengthBits: UInt64 = 0
        private var buffer = [UInt8]()

        mutating func update(_ data: Data) {
            if data.isEmpty { return }
            messageLengthBits &+= UInt64(data.count) &* 8
            data.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                var offset = 0
                if !buffer.isEmpty {
                    let need = 64 - buffer.count
                    let take = min(need, bytes.count)
                    buffer.append(contentsOf: bytes[offset..<(offset + take)])
                    offset += take
                    if buffer.count == 64 {
                        processBlock(buffer)
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
                while offset + 64 <= bytes.count {
                    processBlock(Array(bytes[offset..<(offset + 64)]))
                    offset += 64
                }
                if offset < bytes.count {
                    buffer.append(contentsOf: bytes[offset..<bytes.count])
                }
            }
        }

        mutating func finalize() -> Data {
            // Append 0x80 then pad with zeros to 56 mod 64, then 8-byte length.
            buffer.append(0x80)
            while buffer.count % 64 != 56 {
                buffer.append(0)
            }
            var len = messageLengthBits.bigEndian
            withUnsafeBytes(of: &len) { buffer.append(contentsOf: $0) }
            precondition(buffer.count % 64 == 0)
            var i = 0
            while i < buffer.count {
                processBlock(Array(buffer[i..<(i + 64)]))
                i += 64
            }
            var out = Data(capacity: 20)
            for word in [h0, h1, h2, h3, h4] {
                var be = word.bigEndian
                withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
            }
            return out
        }

        private mutating func processBlock(_ block: [UInt8]) {
            precondition(block.count == 64)
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0..<16 {
                let j = i * 4
                w[i] =
                    (UInt32(block[j]) << 24)
                    | (UInt32(block[j + 1]) << 16)
                    | (UInt32(block[j + 2]) << 8)
                    | UInt32(block[j + 3])
            }
            for i in 16..<80 {
                w[i] = rotateLeft(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], by: 1)
            }

            var a = h0, b = h1, c = h2, d = h3, e = h4
            for i in 0..<80 {
                let f: UInt32
                let k: UInt32
                switch i {
                case 0..<20:
                    f = (b & c) | ((~b) & d)
                    k = 0x5A82_7999
                case 20..<40:
                    f = b ^ c ^ d
                    k = 0x6ED9_EBA1
                case 40..<60:
                    f = (b & c) | (b & d) | (c & d)
                    k = 0x8F1B_BCDC
                default:
                    f = b ^ c ^ d
                    k = 0xCA62_C1D6
                }
                let temp = rotateLeft(a, by: 5) &+ f &+ e &+ k &+ w[i]
                e = d
                d = c
                c = rotateLeft(b, by: 30)
                b = a
                a = temp
            }
            h0 &+= a
            h1 &+= b
            h2 &+= c
            h3 &+= d
            h4 &+= e
        }

        private func rotateLeft(_ value: UInt32, by bits: UInt32) -> UInt32 {
            (value << bits) | (value >> (32 - bits))
        }
    }
}
