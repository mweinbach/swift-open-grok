// Checksum.swift
//
// Streaming SHA-256 helpers matching `xai-file-utils::sha256_hex` /
// `sha256_hex_from_file`. Pure Swift so Linux/Windows builds need no
// CryptoKit.

import Foundation

/// SHA-256 digests for durable integrity checks.
public enum FileChecksum: Sendable {
    /// Lowercase hex SHA-256 of in-memory bytes.
    public static func sha256Hex(_ data: Data) -> String {
        var hasher = StreamingSHA256()
        hasher.update(data)
        return hasher.finalizeHex()
    }

    /// Lowercase hex SHA-256 of a string's UTF-8 bytes.
    public static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }

    /// Stream a file through SHA-256 without loading the whole file.
    ///
    /// - Parameters:
    ///   - path: file to hash.
    ///   - maxBytes: when non-nil and > 0, only the first `maxBytes` are hashed
    ///     (matching Rust `sha256_hex_from_file`).
    public static func sha256HexFromFile(
        at path: URL,
        maxBytes: UInt64? = nil
    ) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: path)
        } catch {
            throw mapReadError(path: path.path, error: error)
        }
        defer { try? handle.close() }

        var hasher = StreamingSHA256()
        var remaining: UInt64? = maxBytes.flatMap { $0 > 0 ? $0 : nil }
        let chunkSize = 8192

        while true {
            let toRead: Int
            if let rem = remaining {
                if rem == 0 { break }
                toRead = Int(min(UInt64(chunkSize), rem))
            } else {
                toRead = chunkSize
            }
            let chunk: Data
            do {
                guard let data = try handle.read(upToCount: toRead) else { break }
                if data.isEmpty { break }
                chunk = data
            } catch {
                throw FileUtilsError.io(path: path.path, detail: error.localizedDescription)
            }
            hasher.update(chunk)
            if remaining != nil {
                remaining! -= UInt64(chunk.count)
            }
        }
        return hasher.finalizeHex()
    }

    /// Verify a file's SHA-256 against an expected lowercase hex digest.
    public static func verifyFile(
        at path: URL,
        expectedHex: String,
        maxBytes: UInt64? = nil
    ) throws {
        let actual = try sha256HexFromFile(at: path, maxBytes: maxBytes)
        let expected = expectedHex.lowercased()
        guard actual == expected else {
            throw FileUtilsError.checksumMismatch(
                path: path.path,
                expected: expected,
                actual: actual
            )
        }
    }
}

// MARK: - Pure Swift SHA-256 (streaming)

/// Streaming SHA-256 (FIPS 180-4). Same algorithm as `OpenGrokBuildSupport.SHA256`
/// but kept local because FileUtils cannot depend on BuildSupport.
struct StreamingSHA256: Sendable {
    private var state: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]
    private var buffer: [UInt8] = []
    private var totalLength: UInt64 = 0

    mutating func update(_ data: Data) {
        totalLength &+= UInt64(data.count)
        var input = [UInt8](data)
        if !buffer.isEmpty {
            let needed = 64 - buffer.count
            let take = min(needed, input.count)
            buffer.append(contentsOf: input.prefix(take))
            input.removeFirst(take)
            if buffer.count == 64 {
                processBlock(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        while input.count >= 64 {
            processBlock(Array(input.prefix(64)))
            input.removeFirst(64)
        }
        buffer.append(contentsOf: input)
    }

    mutating func finalizeHex() -> String {
        buffer.append(0x80)
        while buffer.count % 64 != 56 {
            buffer.append(0x00)
        }
        let bitLength = totalLength &* 8
        for shift in stride(from: 56, through: 0, by: -8) {
            buffer.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }
        var i = 0
        while i < buffer.count {
            processBlock(Array(buffer[i..<(i + 64)]))
            i += 64
        }
        return state.map { word in
            String(format: "%08x", word)
        }.joined()
    }

    private mutating func processBlock(_ block: [UInt8]) {
        precondition(block.count == 64)
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            let j = i * 4
            w[i] = (UInt32(block[j]) << 24)
                | (UInt32(block[j + 1]) << 16)
                | (UInt32(block[j + 2]) << 8)
                | UInt32(block[j + 3])
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
            let t1 = h &+ s1 &+ ch &+ k[i] &+ w[i]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj
            h = g; g = f; f = e; e = d &+ t1
            d = c; c = b; b = a; a = t1 &+ t2
        }
        state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
        state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
    }

    private func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }

    private let k: [UInt32] = [
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

private func mapReadError(path: String, error: Error) -> FileUtilsError {
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError {
        return .notFound(path: path)
    }
    if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT) {
        return .notFound(path: path)
    }
    return .io(path: path, detail: error.localizedDescription)
}
