// Crypto.swift
//
// Local crypto helpers for auth (PKCE S256, UUID v5 deployment/api-key ids).

import Foundation
import OpenGrokShared

#if canImport(Security)
import Security
#endif

enum AuthCrypto {
    /// SHA-256 digest of `data`.
    static func sha256(_ data: Data) -> Data {
        OpenGrokShared.SHA256.hash(data)
    }

    static func sha256(_ string: String) -> Data {
        OpenGrokShared.SHA256.hash(Data(string.utf8))
    }

    /// Base64url (no padding) encoding.
    static func base64URLEncode(_ data: Data) -> String {
        Base64URL.encode(data)
    }

    /// Base64url (no padding) decoding. Returns nil on invalid input.
    static func base64URLDecode(_ string: String) -> Data? {
        Base64URL.decode(string)
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

    private static func rotateLeft(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x << n) | (x >> (32 - n))
    }
}

/// Stable id derived from a deployment or API key (uuidv5 NAMESPACE_OID).
public func deploymentIDFromKey(_ key: String) -> String {
    AuthCrypto.uuidV5OID(key)
}
