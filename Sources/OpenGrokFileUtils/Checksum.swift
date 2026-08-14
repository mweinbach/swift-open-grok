// Checksum.swift
//
// Streaming SHA-256 helpers matching `xai-file-utils::sha256_hex` /
// `sha256_hex_from_file`. Pure Swift so Linux/Windows builds need no
// CryptoKit.

import Foundation
import OpenGrokShared

/// SHA-256 digests for durable integrity checks.
public enum FileChecksum: Sendable {
    /// Lowercase hex SHA-256 of in-memory bytes.
    public static func sha256Hex(_ data: Data) -> String {
        OpenGrokShared.SHA256.hexDigest(data)
    }

    /// Lowercase hex SHA-256 of a string's UTF-8 bytes.
    public static func sha256Hex(_ string: String) -> String {
        OpenGrokShared.SHA256.hexDigest(string)
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
