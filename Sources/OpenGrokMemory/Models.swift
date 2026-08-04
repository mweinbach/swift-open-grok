import Foundation

public enum MemoryScope: String, Codable, CaseIterable, Sendable {
    case global
    case workspace
    case session
}

public struct MemoryDocument: Codable, Equatable, Hashable, Sendable {
    public let path: String
    public let source: String
    public let content: String

    public init(path: String, source: String, content: String) {
        self.path = path
        self.source = source
        self.content = content
    }

    public init(path: URL, source: String, content: String) {
        self.init(path: path.path, source: source, content: content)
    }
}

public struct MemoryChunk: Codable, Equatable, Hashable, Sendable {
    public let text: String
    public let startLine: Int
    public let endLine: Int

    public init(text: String, startLine: Int, endLine: Int) {
        self.text = text
        self.startLine = startLine
        self.endLine = endLine
    }

    public var hash: String {
        chunkHash(text)
    }
}

public struct MemoryChunkRecord: Codable, Equatable, Hashable, Sendable {
    public let rowID: Int64
    public let id: String
    public let path: String
    public let startLine: Int
    public let endLine: Int
    public let text: String
    public let hash: String
    public let source: String
    public let createdAt: Int64
    public let updatedAt: Int64
    public let accessCount: Int64
    public let lastAccessed: Int64?

    public init(
        rowID: Int64,
        id: String,
        path: String,
        startLine: Int,
        endLine: Int,
        text: String,
        hash: String,
        source: String,
        createdAt: Int64,
        updatedAt: Int64,
        accessCount: Int64 = 0,
        lastAccessed: Int64? = nil
    ) {
        self.rowID = rowID
        self.id = id
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
        self.text = text
        self.hash = hash
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.accessCount = accessCount
        self.lastAccessed = lastAccessed
    }

    private enum CodingKeys: String, CodingKey {
        case rowID = "row_id"
        case id, path
        case startLine = "start_line"
        case endLine = "end_line"
        case text, hash, source
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case accessCount = "access_count"
        case lastAccessed = "last_accessed"
    }
}

public typealias ChunkRecord = MemoryChunkRecord

public struct FtsResult: Codable, Equatable, Hashable, Sendable {
    public let chunkID: String
    public let rowID: Int64
    public let rank: Double

    public init(chunkID: String, rowID: Int64, rank: Double) {
        self.chunkID = chunkID
        self.rowID = rowID
        self.rank = rank
    }

    private enum CodingKeys: String, CodingKey {
        case chunkID = "chunk_id"
        case rowID = "row_id"
        case rank
    }
}

public struct ReindexResult: Codable, Equatable, Hashable, Sendable {
    public var added: Int
    public var updated: Int
    public var removed: Int

    public init(added: Int = 0, updated: Int = 0, removed: Int = 0) {
        self.added = added
        self.updated = updated
        self.removed = removed
    }
}

public struct MemorySearchResult: Codable, Equatable, Hashable, Sendable {
    public let chunkID: String
    public let path: String
    public let startLine: Int
    public let endLine: Int
    public let score: Double
    public let snippet: String
    public let source: String
    public let createdAt: Int64

    public init(
        chunkID: String,
        path: String,
        startLine: Int,
        endLine: Int,
        score: Double,
        snippet: String,
        source: String,
        createdAt: Int64
    ) {
        self.chunkID = chunkID
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
        self.score = score
        self.snippet = snippet
        self.source = source
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case chunkID = "chunk_id"
        case path
        case startLine = "start_line"
        case endLine = "end_line"
        case score, snippet, source
        case createdAt = "created_at"
    }
}

public enum MemoryError: Error, Equatable, Sendable, LocalizedError {
    case memoryDirectoryMissing(String)
    case pathOutsideMemory(path: String, root: String)
    case unsafePath(String)
    case unsupportedScope(MemoryScope)
    case corruptIndex(String)
    case unsupportedIndexVersion(Int)
    case embeddingDimensionMismatch(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case let .memoryDirectoryMissing(path):
            return "memory directory does not exist: \(path)"
        case let .pathOutsideMemory(path, root):
            return "path \(path) is outside memory directory \(root)"
        case let .unsafePath(path):
            return "unsafe memory path: \(path)"
        case let .unsupportedScope(scope):
            return "scope \(scope.rawValue) is not supported for this operation"
        case let .corruptIndex(detail):
            return "corrupt memory index: \(detail)"
        case let .unsupportedIndexVersion(version):
            return "unsupported memory index version: \(version)"
        case let .embeddingDimensionMismatch(expected, actual):
            return "embedding dimension mismatch: expected \(expected), got \(actual)"
        }
    }
}

public struct MemoryEmbedding: Codable, Equatable, Sendable {
    public let chunkID: String
    public let values: [Float]

    public init(chunkID: String, values: [Float]) {
        self.chunkID = chunkID
        self.values = values
    }

    private enum CodingKeys: String, CodingKey {
        case chunkID = "chunk_id"
        case values
    }
}

public struct MemoryIndexSnapshot: Codable, Equatable, Sendable {
    public var version: Int
    public var embeddingDimensions: Int
    public var nextRowID: Int64
    public var records: [MemoryChunkRecord]
    public var embeddings: [MemoryEmbedding]
    public var reindexClaim: String

    private enum CodingKeys: String, CodingKey {
        case version
        case embeddingDimensions = "embedding_dimensions"
        case nextRowID = "next_row_id"
        case records, embeddings
        case reindexClaim = "reindex_claim"
    }

    static let empty = MemoryIndexSnapshot(
        version: 1,
        embeddingDimensions: 0,
        nextRowID: 1,
        records: [],
        embeddings: [],
        reindexClaim: ""
    )
}
