// ImageNormalizeCache.swift
//
// Disk-backed cache for normalized images keyed by SHA-256 content digest.
// Stored under `$OPENGROK_HOME/cache/image_normalize/`.
// Avoids re-processing identical image attachments across multiple conversation turns.
// Port of `crates/codegen/xai-grok-shell/src/session/normalize_cache.rs`.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
import OpenGrokPaths

// MARK: - ImageNormalizeCache

/// Process-wide and disk-backed cache for image normalization outcomes.
public final class ImageNormalizeCache: @unchecked Sendable {
    /// Shared singleton instance resolving against active environment.
    public static let shared = ImageNormalizeCache()

    /// Root directory where cache entries are stored.
    public let cacheDirectory: URL

    private let lock = NSLock()
    private var memoryCache: [String: CachedEntry] = [:]
    private let maxMemoryEntries: Int

    // MARK: - Metadata

    /// Metadata recorded alongside cached normalized images on disk.
    public struct CachedMetadata: Codable, Sendable, Equatable {
        public let hash: String
        public let width: Int
        public let height: Int
        public let originalWidth: Int
        public let originalHeight: Int
        public let format: String
        public let originalFormat: String
        public let byteCount: Int
        public let originalByteCount: Int
        public let timestamp: Date

        public init(
            hash: String,
            width: Int,
            height: Int,
            originalWidth: Int,
            originalHeight: Int,
            format: String,
            originalFormat: String,
            byteCount: Int,
            originalByteCount: Int,
            timestamp: Date = Date()
        ) {
            self.hash = hash
            self.width = width
            self.height = height
            self.originalWidth = originalWidth
            self.originalHeight = originalHeight
            self.format = format
            self.originalFormat = originalFormat
            self.byteCount = byteCount
            self.originalByteCount = originalByteCount
            self.timestamp = timestamp
        }
    }

    private struct CachedEntry {
        let data: Data
        let metadata: CachedMetadata?
    }

    // MARK: - Initializer

    public init(
        cacheDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        maxMemoryEntries: Int = 128
    ) {
        self.cacheDirectory = cacheDirectory ?? Self.defaultCacheDirectory(environment: environment)
        self.maxMemoryEntries = max(1, maxMemoryEntries)
    }

    /// Resolve the default cache directory under `$OPENGROK_HOME/cache/image_normalize/`.
    public static func defaultCacheDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let stateDir: URL
        if let override = environment[OpenGrokPathPolicy.homeEnvironmentVariable], !override.isEmpty {
            stateDir = URL(fileURLWithPath: override)
        } else {
            stateDir = OpenGrokStatePaths.stateDirectory(environment: environment)
        }
        return stateDir.appendingPathComponent("cache").appendingPathComponent("image_normalize")
    }

    // MARK: - Public API

    /// Lookup cached normalized image data by raw original image bytes.
    public func cachedNormalizedImage(for rawData: Data) -> Data? {
        guard !rawData.isEmpty else { return nil }
        let hash = Self.sha256Hex(for: rawData)

        lock.lock()
        if let entry = memoryCache[hash] {
            lock.unlock()
            return entry.data
        }
        lock.unlock()

        // Disk lookup
        let imageFileURL = cacheDirectory.appendingPathComponent("\(hash).png")
        if let data = try? Data(contentsOf: imageFileURL) {
            let metaURL = cacheDirectory.appendingPathComponent("\(hash).json")
            let meta = (try? Data(contentsOf: metaURL)).flatMap { try? JSONDecoder().decode(CachedMetadata.self, from: $0) }

            lock.lock()
            if memoryCache.count >= maxMemoryEntries {
                memoryCache.remove(at: memoryCache.startIndex)
            }
            memoryCache[hash] = CachedEntry(data: data, metadata: meta)
            lock.unlock()

            return data
        }

        return nil
    }

    /// Store normalized image data for raw original image bytes.
    public func cacheNormalizedImage(data: Data, for rawData: Data) {
        guard !rawData.isEmpty, !data.isEmpty else { return }
        let hash = Self.sha256Hex(for: rawData)

        let dims = ImageNormalizer.detectDimensions(in: data) ?? ImageDimensions(width: 0, height: 0)
        let origDims = ImageNormalizer.detectDimensions(in: rawData) ?? ImageDimensions(width: 0, height: 0)
        let format = ImageNormalizer.detectFormat(in: data)
        let origFormat = ImageNormalizer.detectFormat(in: rawData)

        let meta = CachedMetadata(
            hash: hash,
            width: dims.width,
            height: dims.height,
            originalWidth: origDims.width,
            originalHeight: origDims.height,
            format: format.mimeType,
            originalFormat: origFormat.mimeType,
            byteCount: data.count,
            originalByteCount: rawData.count,
            timestamp: Date()
        )

        store(hash: hash, data: data, metadata: meta)
    }

    /// Store complete normalized result.
    public func cacheNormalizedResult(_ result: NormalizedImageResult, for rawData: Data) {
        guard !rawData.isEmpty else { return }
        let hash = Self.sha256Hex(for: rawData)
        let meta = CachedMetadata(
            hash: hash,
            width: result.dimensions.width,
            height: result.dimensions.height,
            originalWidth: result.originalDimensions.width,
            originalHeight: result.originalDimensions.height,
            format: result.format.mimeType,
            originalFormat: result.originalFormat.mimeType,
            byteCount: result.byteCount,
            originalByteCount: result.originalByteCount,
            timestamp: Date()
        )
        store(hash: hash, data: result.data, metadata: meta)
    }

    /// Lookup complete cached normalized result including metadata.
    public func cachedNormalizedResult(for rawData: Data) -> NormalizedImageResult? {
        guard !rawData.isEmpty else { return nil }
        let hash = Self.sha256Hex(for: rawData)

        lock.lock()
        if let entry = memoryCache[hash], let meta = entry.metadata {
            lock.unlock()
            return makeResult(data: entry.data, metadata: meta)
        }
        lock.unlock()

        let imageFileURL = cacheDirectory.appendingPathComponent("\(hash).png")
        guard let data = try? Data(contentsOf: imageFileURL) else { return nil }

        let metaURL = cacheDirectory.appendingPathComponent("\(hash).json")
        let metadata: CachedMetadata
        if let metaData = try? Data(contentsOf: metaURL),
           let decoded = try? JSONDecoder().decode(CachedMetadata.self, from: metaData) {
            metadata = decoded
        } else {
            let dims = ImageNormalizer.detectDimensions(in: data) ?? ImageDimensions(width: 0, height: 0)
            let origDims = ImageNormalizer.detectDimensions(in: rawData) ?? ImageDimensions(width: 0, height: 0)
            metadata = CachedMetadata(
                hash: hash,
                width: dims.width,
                height: dims.height,
                originalWidth: origDims.width,
                originalHeight: origDims.height,
                format: ImageNormalizer.detectFormat(in: data).mimeType,
                originalFormat: ImageNormalizer.detectFormat(in: rawData).mimeType,
                byteCount: data.count,
                originalByteCount: rawData.count,
                timestamp: Date()
            )
        }

        lock.lock()
        if memoryCache.count >= maxMemoryEntries {
            memoryCache.remove(at: memoryCache.startIndex)
        }
        memoryCache[hash] = CachedEntry(data: data, metadata: metadata)
        lock.unlock()

        return makeResult(data: data, metadata: metadata)
    }

    /// Check if cache contains an entry for the given raw image data.
    public func contains(rawData: Data) -> Bool {
        guard !rawData.isEmpty else { return false }
        let hash = Self.sha256Hex(for: rawData)

        lock.lock()
        if memoryCache[hash] != nil {
            lock.unlock()
            return true
        }
        lock.unlock()

        let file = cacheDirectory.appendingPathComponent("\(hash).png")
        return FileManager.default.fileExists(atPath: file.path)
    }

    /// Clear all in-memory and on-disk cached normalized images.
    public func clear() {
        lock.lock()
        memoryCache.removeAll()
        lock.unlock()

        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    /// Total count of cached entries on disk.
    public var entryCount: Int {
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) else {
            return 0
        }
        return files.filter { $0.pathExtension == "png" }.count
    }

    // MARK: - Internal Storage & Helpers

    private func store(hash: String, data: Data, metadata: CachedMetadata) {
        lock.lock()
        if memoryCache.count >= maxMemoryEntries {
            memoryCache.remove(at: memoryCache.startIndex)
        }
        memoryCache[hash] = CachedEntry(data: data, metadata: metadata)
        lock.unlock()

        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let imageFileURL = cacheDirectory.appendingPathComponent("\(hash).png")
            let metaURL = cacheDirectory.appendingPathComponent("\(hash).json")

            try data.write(to: imageFileURL, options: .atomic)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let metaData = try encoder.encode(metadata)
            try metaData.write(to: metaURL, options: .atomic)
        } catch {
            // Memory cache remains functional even if disk write fails
        }
    }

    private func makeResult(data: Data, metadata: CachedMetadata) -> NormalizedImageResult {
        let format = ImageFormat.from(mimeType: metadata.format)
        let origFormat = ImageFormat.from(mimeType: metadata.originalFormat)
        let dims = ImageDimensions(width: metadata.width, height: metadata.height)
        let origDims = ImageDimensions(width: metadata.originalWidth, height: metadata.originalHeight)
        let wasDownsampled = dims.width != origDims.width || dims.height != origDims.height
        let wasRecompressed = data.count != metadata.originalByteCount

        return NormalizedImageResult(
            data: data,
            dimensions: dims,
            originalDimensions: origDims,
            format: format,
            originalFormat: origFormat,
            byteCount: data.count,
            originalByteCount: metadata.originalByteCount,
            wasDownsampled: wasDownsampled,
            wasRecompressed: wasRecompressed
        )
    }

    // MARK: - SHA-256 Digest

    /// Compute lowercase hex-encoded SHA-256 digest of arbitrary data.
    public static func sha256Hex(for data: Data) -> String {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        return pureSwiftSHA256Hex(data)
        #endif
    }
}

// MARK: - Portable Pure-Swift SHA-256 Fallback

#if !canImport(CryptoKit)
private func pureSwiftSHA256Hex(_ data: Data) -> String {
    let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    var h0: UInt32 = 0x6a09e667
    var h1: UInt32 = 0xbb67ae85
    var h2: UInt32 = 0x3c6ef372
    var h3: UInt32 = 0xa54ff53a
    var h4: UInt32 = 0x510e527f
    var h5: UInt32 = 0x9b05688c
    var h6: UInt32 = 0x1f83d9ab
    var h7: UInt32 = 0x5be0cd19

    var message = data
    let bitLength = UInt64(data.count) * 8
    message.append(0x80)
    while (message.count % 64) != 56 {
        message.append(0x00)
    }
    var bigEndianBits = bitLength.bigEndian
    withUnsafeBytes(of: &bigEndianBits) { message.append(contentsOf: $0) }

    for chunkStart in stride(from: 0, to: message.count, by: 64) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            let offset = chunkStart + i * 4
            w[i] = (UInt32(message[offset]) << 24) | (UInt32(message[offset + 1]) << 16) |
                   (UInt32(message[offset + 2]) << 8) | UInt32(message[offset + 3])
        }
        for i in 16..<64 {
            let s0 = (w[i - 15] >> 7 | w[i - 15] << 25) ^ (w[i - 15] >> 18 | w[i - 15] << 14) ^ (w[i - 15] >> 3)
            let s1 = (w[i - 2] >> 17 | w[i - 2] << 15) ^ (w[i - 2] >> 19 | w[i - 2] << 13) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }

        var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7
        for i in 0..<64 {
            let s1 = (e >> 6 | e << 26) ^ (e >> 11 | e << 21) ^ (e >> 25 | e << 7)
            let ch = (e & f) ^ (~e & g)
            let temp1 = h &+ s1 &+ ch &+ k[i] &+ w[i]
            let s0 = (a >> 2 | a << 30) ^ (a >> 13 | a << 19) ^ (a >> 22 | a << 10)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ maj

            h = g; g = f; f = e; e = d &+ temp1
            d = c; c = b; b = a; a = temp1 &+ temp2
        }

        h0 = h0 &+ a; h1 = h1 &+ b; h2 = h2 &+ c; h3 = h3 &+ d
        h4 = h4 &+ e; h5 = h5 &+ f; h6 = h6 &+ g; h7 = h7 &+ h
    }

    return String(format: "%08x%08x%08x%08x%08x%08x%08x%08x", h0, h1, h2, h3, h4, h5, h6, h7)
}
#endif
