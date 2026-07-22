// Crypto.swift
//
// Local crypto helpers for auth (PKCE S256, UUID v5 deployment/api-key ids).
// Kept in-module so OpenGrokAuth does not depend on OpenGrokBuildSupport.

import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Security)
import Security
#endif

enum AuthCrypto {
    /// SHA-256 digest of `data`.
    static func sha256(_ data: Data) -> Data {
        #if canImport(CryptoKit)
        return Data(SHA256.hash(data: data))
        #else
        return pureSHA256(data)
        #endif
    }

    static func sha256(_ string: String) -> Data {
        sha256(Data(string.utf8))
    }

    /// Base64url (no padding) encoding.
    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Base64url (no padding) decoding. Returns nil on invalid input.
    static func base64URLDecode(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - s.count % 4) % 4
        if pad > 0 { s += String(repeating: "=", count: pad) }
        return Data(base64Encoded: s)
    }

    /// UUID v5 (SHA-1 name-based) with NAMESPACE_OID, matching Rust
    /// `uuid::Uuid::new_v5(&Uuid::NAMESPACE_OID, key.as_bytes())`.
    static func uuidV5OID(_ name: String) -> String {
        // NAMESPACE_OID = 6ba7b812-9dad-11d1-80b4-00c04fd430c8
        let ns: [UInt8] = [
            0x6b, 0xa7, 0xb8, 0x12, 0x9d, 0xad, 0x11, 0xd1,
            0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8,
        ]
        var input = Data(ns)
        input.append(Data(name.utf8))
        let digest = pureSHA1(input)
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [
            String(hex.prefix(8)),
            String(hex.dropFirst(8).prefix(4)),
            String(hex.dropFirst(12).prefix(4)),
            String(hex.dropFirst(16).prefix(4)),
            String(hex.dropFirst(20).prefix(12)),
        ]
        return parts.joined(separator: "-")
    }

    /// Cryptographically secure random bytes as base64url (PKCE verifier).
    static func randomBase64URL(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        #if canImport(Security)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255) }
        }
        #else
        for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255) }
        #endif
        return base64URLEncode(Data(bytes))
    }

    // MARK: - SHA-1 (UUID v5)

    private static func pureSHA1(_ data: Data) -> Data {
        var h0: UInt32 = 0x67452301
        var h1: UInt32 = 0xEFCDAB89
        var h2: UInt32 = 0x98BADCFE
        var h3: UInt32 = 0x10325476
        var h4: UInt32 = 0xC3D2E1F0

        var msg = [UInt8](data)
        let bitLen = UInt64(msg.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            msg.append(UInt8((bitLen >> UInt64(shift)) & 0xff))
        }

        var i = 0
        while i < msg.count {
            var w = [UInt32](repeating: 0, count: 80)
            for j in 0..<16 {
                let o = i + j * 4
                w[j] = (UInt32(msg[o]) << 24) | (UInt32(msg[o + 1]) << 16)
                    | (UInt32(msg[o + 2]) << 8) | UInt32(msg[o + 3])
            }
            for j in 16..<80 {
                w[j] = rotateLeft(w[j - 3] ^ w[j - 8] ^ w[j - 14] ^ w[j - 16], 1)
            }
            var a = h0, b = h1, c = h2, d = h3, e = h4
            for j in 0..<80 {
                let f: UInt32
                let k: UInt32
                switch j {
                case 0..<20:
                    f = (b & c) | ((~b) & d); k = 0x5A827999
                case 20..<40:
                    f = b ^ c ^ d; k = 0x6ED9EBA1
                case 40..<60:
                    f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
                default:
                    f = b ^ c ^ d; k = 0xCA62C1D6
                }
                let temp = rotateLeft(a, 5) &+ f &+ e &+ k &+ w[j]
                e = d; d = c; c = rotateLeft(b, 30); b = a; a = temp
            }
            h0 = h0 &+ a; h1 = h1 &+ b; h2 = h2 &+ c; h3 = h3 &+ d; h4 = h4 &+ e
            i += 64
        }

        var out = Data(capacity: 20)
        for word in [h0, h1, h2, h3, h4] {
            out.append(UInt8((word >> 24) & 0xff))
            out.append(UInt8((word >> 16) & 0xff))
            out.append(UInt8((word >> 8) & 0xff))
            out.append(UInt8(word & 0xff))
        }
        return out
    }

    #if !canImport(CryptoKit)
    private static func pureSHA256(_ data: Data) -> Data {
        var hasher = PureSHA256()
        hasher.update(data)
        return hasher.finalize()
    }

    private struct PureSHA256 {
        private var state: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        private var buffer: [UInt8] = []
        private var totalLength: UInt64 = 0

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

        mutating func update(_ data: Data) {
            totalLength &+= UInt64(data.count)
            var input = [UInt8](data)
            if !buffer.isEmpty {
                let needed = 64 - buffer.count
                let take = min(needed, input.count)
                buffer.append(contentsOf: input.prefix(take))
                input.removeFirst(take)
                if buffer.count == 64 {
                    process(buffer); buffer.removeAll(keepingCapacity: true)
                }
            }
            while input.count >= 64 {
                process(Array(input.prefix(64))); input.removeFirst(64)
            }
            buffer.append(contentsOf: input)
        }

        mutating func finalize() -> Data {
            buffer.append(0x80)
            while buffer.count % 64 != 56 { buffer.append(0) }
            let bitLength = totalLength &* 8
            for shift in stride(from: 56, through: 0, by: -8) {
                buffer.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
            }
            var i = 0
            while i < buffer.count {
                process(Array(buffer[i..<(i + 64)]))
                i += 64
            }
            var out = Data(capacity: 32)
            for word in state {
                out.append(UInt8((word >> 24) & 0xff))
                out.append(UInt8((word >> 16) & 0xff))
                out.append(UInt8((word >> 8) & 0xff))
                out.append(UInt8(word & 0xff))
            }
            return out
        }

        private mutating func process(_ block: [UInt8]) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let o = i * 4
                w[i] = (UInt32(block[o]) << 24) | (UInt32(block[o + 1]) << 16)
                    | (UInt32(block[o + 2]) << 8) | UInt32(block[o + 3])
            }
            for i in 16..<64 {
                let s0 = rotateRight(w[i - 15], 7) ^ rotateRight(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotateRight(w[i - 2], 17) ^ rotateRight(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = state[0], b = state[1], c = state[2], d = state[3]
            var e = state[4], f = state[5], g = state[6], h = state[7]
            for i in 0..<64 {
                let S1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
                let ch = (e & f) ^ ((~e) & g)
                let t1 = h &+ S1 &+ ch &+ Self.k[i] &+ w[i]
                let S0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = S0 &+ maj
                h = g; g = f; f = e; e = d &+ t1
                d = c; c = b; b = a; a = t1 &+ t2
            }
            state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
            state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
        }
    }

    private static func rotateRight(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }
    #endif

    private static func rotateLeft(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x << n) | (x >> (32 - n))
    }
}

/// Stable id derived from a deployment or API key (uuidv5 NAMESPACE_OID).
public func deploymentIDFromKey(_ key: String) -> String {
    AuthCrypto.uuidV5OID(key)
}
