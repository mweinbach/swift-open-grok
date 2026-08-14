// ImageNormalizeCache.swift
//
// Disk-backed cache for normalized images keyed by SHA-256 content digest.
// Stored under `$OPENGROK_HOME/cache/image_normalize/`.
// Avoids re-processing identical image attachments across multiple conversation turns.
// Port of `crates/codegen/xai-grok-shell/src/session/normalize_cache.rs`.

import Foundation
import OpenGrokPaths
import OpenGrokShared

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
        OpenGrokShared.SHA256.hexDigest(data)
    }
}
