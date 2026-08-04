import Foundation
import OpenGrokConfigTypes
import OpenGrokFileUtils

public final class MemoryIndex {
    public let indexURL: URL
    public let storage: MemoryStorage
    public let chunkConfig: MemoryIndexConfig
    public let embeddingDimensions: Int

    private var recordsByID: [String: MemoryChunkRecord]
    private var embeddingsByID: [String: [Float]]
    private var nextRowID: Int64
    private var reindexClaim: String

    public init(
        indexURL: URL,
        storage: MemoryStorage,
        config: MemoryIndexConfig = MemoryIndexConfig(),
        embeddingDimensions: Int = 0
    ) throws {
        self.indexURL = indexURL.standardizedFileURL
        self.storage = storage
        self.chunkConfig = config
        self.embeddingDimensions = max(0, embeddingDimensions)
        self.recordsByID = [:]
        self.embeddingsByID = [:]
        self.nextRowID = 1
        self.reindexClaim = ""
        try load()
    }

    public static func openOrCreate(
        indexURL: URL,
        storage: MemoryStorage,
        config: MemoryIndexConfig = MemoryIndexConfig(),
        embeddingDimensions: Int = 0
    ) throws -> MemoryIndex {
        try MemoryIndex(
            indexURL: indexURL,
            storage: storage,
            config: config,
            embeddingDimensions: embeddingDimensions
        )
    }

    public var vecAvailable: Bool {
        embeddingDimensions > 0
    }

    public func serializedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(snapshot())
    }

    public func reindexFile(path: URL, source: String) throws -> ReindexResult {
        guard let content = try? String(contentsOf: path, encoding: .utf8) else {
            return ReindexResult()
        }

        let pathString = path.path
        let newChunks = chunkMarkdown(content, config: chunkConfig)
        let existing = recordsByID.values.filter { $0.path == pathString }
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let now = Self.unixNow()
        var result = ReindexResult()
        var seenIDs = Set<String>()
        var changed = false

        for (index, chunk) in newChunks.enumerated() {
            let chunkID = "\(pathString):\(index)"
            let hash = chunkHash(chunk.text)
            seenIDs.insert(chunkID)

            if let old = existingByID[chunkID] {
                guard old.hash != hash else { continue }
                recordsByID[chunkID] = MemoryChunkRecord(
                    rowID: old.rowID,
                    id: old.id,
                    path: old.path,
                    startLine: chunk.startLine,
                    endLine: chunk.endLine,
                    text: chunk.text,
                    hash: hash,
                    source: old.source,
                    createdAt: old.createdAt,
                    updatedAt: now,
                    accessCount: old.accessCount,
                    lastAccessed: old.lastAccessed
                )
                embeddingsByID.removeValue(forKey: chunkID)
                result.updated += 1
                changed = true
            } else {
                recordsByID[chunkID] = MemoryChunkRecord(
                    rowID: nextRowID,
                    id: chunkID,
                    path: pathString,
                    startLine: chunk.startLine,
                    endLine: chunk.endLine,
                    text: chunk.text,
                    hash: hash,
                    source: source,
                    createdAt: now,
                    updatedAt: now
                )
                nextRowID += 1
                result.added += 1
                changed = true
            }
        }

        for old in existing where !seenIDs.contains(old.id) {
            recordsByID.removeValue(forKey: old.id)
            embeddingsByID.removeValue(forKey: old.id)
            result.removed += 1
            changed = true
        }

        if changed {
            try persist()
        }
        return result
    }

    public func searchFTS(_ query: String, limit: Int) throws -> [FtsResult] {
        searchFTSBySources(query, limit: limit, sources: nil)
    }

    public func searchFTSBySources(
        _ query: String,
        limit: Int,
        sources: [String]
    ) throws -> [FtsResult] {
        searchFTSBySources(query, limit: limit, sources: Set(sources))
    }

    public func getChunk(_ id: String) throws -> MemoryChunkRecord? {
        recordsByID[id]
    }

    public func allIndexedPaths() throws -> [String] {
        Array(Set(recordsByID.values.map(\.path))).sorted()
    }

    public func recordAccess(_ chunkID: String) throws {
        guard let old = recordsByID[chunkID] else { return }
        recordsByID[chunkID] = MemoryChunkRecord(
            rowID: old.rowID,
            id: old.id,
            path: old.path,
            startLine: old.startLine,
            endLine: old.endLine,
            text: old.text,
            hash: old.hash,
            source: old.source,
            createdAt: old.createdAt,
            updatedAt: old.updatedAt,
            accessCount: old.accessCount + 1,
            lastAccessed: Self.unixNow()
        )
        try persist()
    }

    public func chunksWithoutEmbeddings() throws -> [(String, String)] {
        guard vecAvailable else { return [] }
        return recordsByID.values
            .filter { embeddingsByID[$0.id] == nil }
            .sorted { $0.id < $1.id }
            .map { ($0.id, $0.text) }
    }

    public func upsertEmbedding(_ chunkID: String, embedding: [Float]) throws {
        guard vecAvailable else { return }
        guard embedding.count == embeddingDimensions else {
            throw MemoryError.embeddingDimensionMismatch(expected: embeddingDimensions, actual: embedding.count)
        }
        guard recordsByID[chunkID] != nil else { return }
        embeddingsByID[chunkID] = embedding
        try persist()
    }

    public func vectorSearch(queryEmbedding: [Float], k: Int) throws -> [(String, Float)] {
        guard vecAvailable else { return [] }
        guard queryEmbedding.count == embeddingDimensions else {
            throw MemoryError.embeddingDimensionMismatch(expected: embeddingDimensions, actual: queryEmbedding.count)
        }
        guard k > 0 else { return [] }

        let distances: [(id: String, distance: Float)] = embeddingsByID.compactMap { id, embedding in
            guard recordsByID[id] != nil else { return nil }
            let squaredDistance = zip(queryEmbedding, embedding).reduce(Float.zero) { partial, pair in
                let difference = pair.0 - pair.1
                return partial + difference * difference
            }
            let distance = sqrt(squaredDistance)
            return (id: id, distance: distance)
        }
        return distances.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 < rhs.1
        }
        .prefix(k)
        .map { $0 }
    }

    public func getReindexClaim() -> String {
        reindexClaim
    }

    public func tryClaimReindex(staleThresholdSeconds: Int64, now: Int64 = MemoryIndex.currentUnixTime()) -> Bool {
        let timestamp = max(0, now)
        let cutoff = timestamp - max(0, staleThresholdSeconds)
        if !reindexClaim.isEmpty {
            let components = reindexClaim.split(separator: ":", maxSplits: 1).map(String.init)
            guard components.count == 2, let claimTime = Int64(components[1]), claimTime < cutoff else {
                return false
            }
        }

        reindexClaim = "\(ProcessInfo.processInfo.processIdentifier):\(timestamp)"
        do {
            try persist()
            return true
        } catch {
            return false
        }
    }

    public func releaseClaim() {
        reindexClaim = ""
        try? persist()
    }

    @discardableResult
    public func deletePath(_ path: URL) throws -> Int {
        let pathString = path.path
        let matching = recordsByID.values.filter { $0.path == pathString }
        guard !matching.isEmpty else { return 0 }
        for record in matching {
            recordsByID.removeValue(forKey: record.id)
            embeddingsByID.removeValue(forKey: record.id)
        }
        try persist()
        return matching.count
    }

    public func reload() throws {
        recordsByID.removeAll(keepingCapacity: true)
        embeddingsByID.removeAll(keepingCapacity: true)
        nextRowID = 1
        reindexClaim = ""
        try load()
    }

    private func searchFTSBySources(
        _ query: String,
        limit: Int,
        sources: Set<String>?
    ) -> [FtsResult] {
        guard limit > 0 else { return [] }
        if let sources, sources.isEmpty { return [] }
        let keywords = extractKeywords(query)
        guard !keywords.isEmpty else { return [] }

        let candidates = recordsByID.values.filter { record in
            guard sources == nil || sources!.contains(record.source) else { return false }
            let tokens = memoryTokens(record.text)
            return !Set(tokens).intersection(keywords).isEmpty
        }

        var results: [FtsResult] = []
        results.reserveCapacity(candidates.count)
        for record in candidates {
            let rank = ftsRank(text: record.text, keywords: keywords)
            results.append(FtsResult(chunkID: record.id, rowID: record.rowID, rank: rank))
        }
        results.sort { lhs, rhs in
            lhs.rank == rhs.rank ? lhs.rowID < rhs.rowID : lhs.rank < rhs.rank
        }
        return Array(results.prefix(limit))
    }

    private func load() throws {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return }
        do {
            let data = try Data(contentsOf: indexURL)
            let snapshot = try JSONDecoder().decode(MemoryIndexSnapshot.self, from: data)
            guard snapshot.version == 1 else {
                throw MemoryError.unsupportedIndexVersion(snapshot.version)
            }

            let records = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.id, $0) })
            recordsByID = records
            nextRowID = max(
                snapshot.nextRowID,
                (records.values.map(\.rowID).max() ?? 0) + 1
            )
            reindexClaim = snapshot.reindexClaim
            if embeddingDimensions > 0 && snapshot.embeddingDimensions == embeddingDimensions {
                embeddingsByID = Dictionary(uniqueKeysWithValues: snapshot.embeddings.map { ($0.chunkID, $0.values) })
            } else {
                embeddingsByID = [:]
            }
        } catch let error as MemoryError {
            throw error
        } catch {
            throw MemoryError.corruptIndex(error.localizedDescription)
        }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: indexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeAtomically(indexURL, data: try serializedData())
    }

    private func snapshot() -> MemoryIndexSnapshot {
        MemoryIndexSnapshot(
            version: 1,
            embeddingDimensions: embeddingDimensions,
            nextRowID: nextRowID,
            records: recordsByID.values.sorted { $0.id < $1.id },
            embeddings: embeddingsByID.keys.sorted().compactMap { id in
                guard let values = embeddingsByID[id] else { return nil }
                return MemoryEmbedding(chunkID: id, values: values)
            },
            reindexClaim: reindexClaim
        )
    }

    public static func currentUnixTime() -> Int64 {
        Int64(Date().timeIntervalSince1970)
    }

    private static func unixNow() -> Int64 {
        currentUnixTime()
    }
}
