// SHA256.swift
//
// Dependency-free SHA-256 implementation (FIPS 180-4).
//
// This is intentionally self-contained so that OpenGrokBuildSupport (and the
// fixture validator / release checksum machinery that depends on it) builds
// identically on macOS, Linux, and Windows without requiring CryptoKit or the
// swift-crypto package. The algorithm is the standard SHA-256 and is verified
// against NIST test vectors in OpenGrokBuildSupportTests.

import Foundation

/// A pure-Swift, platform-neutral SHA-256 implementation.
public enum SHA256 {
    /// Compute the SHA-256 digest of `data` and return 32 raw bytes.
    public static func hash(_ data: [UInt8]) -> [UInt8] {
        var hasher = HasherState()
        hasher.update(data)
        return hasher.finalize()
    }

    /// Compute the SHA-256 digest of the UTF-8 bytes of `string`.
    public static func hash(_ string: String) -> [UInt8] {
        hash(Array(string.utf8))
    }

    /// Compute the SHA-256 digest of `data` and return a lowercase hex string.
    public static func hexDigest(_ data: [UInt8]) -> String {
        hash(data).map { String(format: "%02x", $0) }.joined()
    }

    /// Compute the SHA-256 digest of the UTF-8 bytes of `string` as hex.
    public static func hexDigest(_ string: String) -> String {
        hexDigest(Array(string.utf8))
    }
}

// MARK: - Internal state

struct HasherState {
    var state: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]

    var buffer: [UInt8] = []
    var totalLength: UInt64 = 0

    mutating func update(_ data: [UInt8]) {
        totalLength &+= UInt64(data.count)
        var input = ArraySlice(data)
        // Top off any partial block.
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
        // Process full blocks directly.
        while input.count >= 64 {
            processBlock(Array(input.prefix(64)))
            input = input.dropFirst(64)
        }
        // Stash the tail.
        buffer.append(contentsOf: input)
    }

    mutating func finalize() -> [UInt8] {
        // Append the 0x80 terminator.
        buffer.append(0x80)
        // Pad with zeros until the block is 56 bytes (leaving 8 for the length).
        while buffer.count % 64 != 56 {
            buffer.append(0x00)
        }
        // Append the 64-bit big-endian bit length.
        let bitLength = totalLength &* 8
        for i in (0..<8).reversed() {
            buffer.append(UInt8(truncatingIfNeeded: bitLength >> (i * 8)))
        }
        // Process remaining blocks.
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

    mutating func processBlock(_ block: [UInt8]) {
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

    func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }

    // SHA-256 round constants.
    static let k: [UInt32] = [
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
