// Crypto.swift
//
// Canonical pure-Swift cryptographic primitives (FIPS 180-4 SHA-256 and SHA-512),
// strict RFC-3986 form URL encoding, and Base64URL encoding/decoding.
// Shared across all Open Grok targets without external dependencies.

import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - SHA-256

/// A pure-Swift, platform-neutral SHA-256 implementation (FIPS 180-4).
public enum SHA256 {
    /// Compute the SHA-256 digest of `data` bytes and return 32 raw bytes.
    public static func hash(_ data: [UInt8]) -> [UInt8] {
        #if canImport(CryptoKit)
        return Array(CryptoKit.SHA256.hash(data: data))
        #else
        var hasher = HasherState256()
        hasher.update(data)
        return hasher.finalize()
        #endif
    }

    /// Compute the SHA-256 digest of `data` and return `Data`.
    public static func hash(_ data: Data) -> Data {
        #if canImport(CryptoKit)
        return Data(CryptoKit.SHA256.hash(data: data))
        #else
        return Data(hash([UInt8](data)))
        #endif
    }

    /// Compute the SHA-256 digest of the UTF-8 bytes of `string`.
    public static func hash(_ string: String) -> [UInt8] {
        hash(Array(string.utf8))
    }

    /// Compute the SHA-256 digest of `data` and return a lowercase hex string.
    public static func hexDigest(_ data: [UInt8]) -> String {
        hash(data).map { String(format: "%02x", $0) }.joined()
    }

    /// Compute the SHA-256 digest of `data` and return a lowercase hex string.
    public static func hexDigest(_ data: Data) -> String {
        hexDigest([UInt8](data))
    }

    /// Compute the SHA-256 digest of the UTF-8 bytes of `string` as hex.
    public static func hexDigest(_ string: String) -> String {
        hexDigest(Array(string.utf8))
    }
}

// MARK: - Streaming SHA-256

/// Streaming SHA-256 hasher (FIPS 180-4).
public struct StreamingSHA256: Sendable {
    private var hasher = HasherState256()

    public init() {}

    public mutating func update(_ data: [UInt8]) {
        hasher.update(data)
    }

    public mutating func update(_ data: Data) {
        hasher.update([UInt8](data))
    }

    public mutating func finalize() -> [UInt8] {
        hasher.finalize()
    }

    public mutating func finalizeHex() -> String {
        finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - SHA-256 Internal State

struct HasherState256: Sendable {
    private var state: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]

    private var buffer: [UInt8] = []
    private var totalLength: UInt64 = 0

    mutating func update(_ data: [UInt8]) {
        totalLength &+= UInt64(data.count)
        var input = ArraySlice(data)
        if !buffer.isEmpty {
            let needed = 64 - buffer.count
            let take = min(needed, input.count)
            buffer.append(contentsOf: input.prefix(take))
            input = input.dropFirst(take)
            if buffer.count == 64 {
                processBlock(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        while input.count >= 64 {
            processBlock(Array(input.prefix(64)))
            input = input.dropFirst(64)
        }
        buffer.append(contentsOf: input)
    }

    mutating func finalize() -> [UInt8] {
        buffer.append(0x80)
        while buffer.count % 64 != 56 {
            buffer.append(0x00)
        }
        let bitLength = totalLength &* 8
        for i in (0..<8).reversed() {
            buffer.append(UInt8(truncatingIfNeeded: bitLength >> (i * 8)))
        }
        var idx = 0
        while idx < buffer.count {
            processBlock(Array(buffer[idx..<min(idx + 64, buffer.count)]))
            idx += 64
        }
        buffer.removeAll(keepingCapacity: true)
        return state.flatMap { word in
            (0..<4).reversed().map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) }
        }
    }

    private mutating func processBlock(_ block: [UInt8]) {
        precondition(block.count == 64, "SHA-256 block must be 64 bytes")
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            let b0 = UInt32(block[i * 4]) << 24
            let b1 = UInt32(block[i * 4 + 1]) << 16
            let b2 = UInt32(block[i * 4 + 2]) << 8
            let b3 = UInt32(block[i * 4 + 3])
            w[i] = b0 | b1 | b2 | b3
        }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }

        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]

        for i in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let temp1 = h &+ s1 &+ ch &+ Self.k[i] &+ w[i]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ maj

            h = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
        }

        state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
        state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
    }

    private func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]
}

// MARK: - SHA-512

/// A pure-Swift, platform-neutral SHA-512 implementation (FIPS 180-4).
public enum SHA512 {
    public static func hash(_ message: [UInt8]) -> [UInt8] {
        #if canImport(CryptoKit)
        return Array(CryptoKit.SHA512.hash(data: message))
        #else
        return computeSHA512(message)
        #endif
    }

    public static func hash(_ data: Data) -> Data {
        Data(hash([UInt8](data)))
    }

    public static func hexDigest(_ message: [UInt8]) -> String {
        hash(message).map { String(format: "%02x", $0) }.joined()
    }

    public static func hexDigest(_ data: Data) -> String {
        hexDigest([UInt8](data))
    }

    public static func hexDigest(_ string: String) -> String {
        hexDigest(Data(string.utf8))
    }

    private static func computeSHA512(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt64] = [
            0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
            0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
        ]
        let bitLen = UInt64(message.count) &* 8
        var padded = message
        padded.append(0x80)
        while (padded.count % 128) != 112 { padded.append(0) }
        for _ in 0..<8 { padded.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8((bitLen >> UInt64(shift)) & 0xff))
        }

        let k: [UInt64] = [
            0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc,
            0x3956c25bf348b538, 0x59f111f1b605d019, 0x923f82a4af194f9b, 0xab1c5ed5da6d8118,
            0xd807aa98a3030242, 0x12835b0145706fbe, 0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2,
            0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235, 0xc19bf174cf692694,
            0xe49b69c19ef14ad2, 0xefbe4786384f25e3, 0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65,
            0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5,
            0x983e5152ee66dfab, 0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4,
            0xc6e00bf33da88fc2, 0xd5a79147930aa725, 0x06ca6351e003826f, 0x142929670a0e6e70,
            0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed, 0x53380d139d95b3df,
            0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b,
            0xa2bfe8a14cf10364, 0xa81a664bbc423001, 0xc24b8b70d0f89791, 0xc76c51a30654be30,
            0xd192e819d6ef5218, 0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8,
            0x19a4c116b8d2d0c8, 0x1e376c085141ab53, 0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8,
            0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb, 0x5b9cca4f7763e373, 0x682e6ff3d6b2b8a3,
            0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec,
            0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b,
            0xca273eceea26619c, 0xd186b8c721c0c207, 0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178,
            0x06f067aa72176fba, 0x0a637dc5a2c898a6, 0x113f9804bef90dae, 0x1b710b35131c471b,
            0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc, 0x431d67c49c100d4c,
            0x4cc5d4becb3e42b6, 0x597f299cfc657e2a, 0x5fcb6fab3ad6faec, 0x6c44198c4a475817,
        ]

        var w = [UInt64](repeating: 0, count: 80)
        var offset = 0
        while offset < padded.count {
            for i in 0..<16 {
                let j = offset + i * 8
                var word: UInt64 = 0
                for b in 0..<8 {
                    word = (word << 8) | UInt64(padded[j + b])
                }
                w[i] = word
            }
            for i in 16..<80 {
                let s0 = rotr64(w[i - 15], 1) ^ rotr64(w[i - 15], 8) ^ (w[i - 15] >> 7)
                let s1 = rotr64(w[i - 2], 19) ^ rotr64(w[i - 2], 61) ^ (w[i - 2] >> 6)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3]
            var e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<80 {
                let S1 = rotr64(e, 14) ^ rotr64(e, 18) ^ rotr64(e, 41)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ S1 &+ ch &+ k[i] &+ w[i]
                let S0 = rotr64(a, 28) ^ rotr64(a, 34) ^ rotr64(a, 39)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = S0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1
                d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d
            h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
            offset += 128
        }

        var out = [UInt8](repeating: 0, count: 64)
        for (i, v) in h.enumerated() {
            for b in 0..<8 {
                out[i * 8 + b] = UInt8((v >> UInt64(56 - b * 8)) & 0xff)
            }
        }
        return out
    }

    private static func rotr64(_ x: UInt64, _ n: UInt64) -> UInt64 {
        (x >> n) | (x << (64 - n))
    }
}

// MARK: - Form URL Encoding (RFC-3986)

public enum FormURLEncoding {
    private static let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    /// Encode key-value pairs according to application/x-www-form-urlencoded using RFC-3986 unreserved charset.
    public static func encode(_ fields: [String: String]) -> String {
        fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: unreserved) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
            return "\(k)=\(v)"
        }
        .sorted()
        .joined(separator: "&")
    }

    /// Encode key-value pairs directly to UTF-8 `Data`.
    public static func encodeData(_ fields: [String: String]) -> Data {
        Data(encode(fields).utf8)
    }
}

// MARK: - Base64URL

public enum Base64URL {
    /// Base64url (no padding) encoding.
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Base64url (no padding) decoding. Returns nil on invalid input.
    public static func decode(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 {
            s.append("=")
        }
        return Data(base64Encoded: s)
    }
}
