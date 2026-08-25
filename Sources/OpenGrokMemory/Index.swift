import Foundation
import OpenGrokConfigTypes
import OpenGrokFileUtils
import OpenGrokSQLiteJournal

#if canImport(SQLite3)
import SQLite3
#endif

public final class MemoryIndex {
    public let indexURL: URL
    public let storage: MemoryStorage
    public let chunkConfig: MemoryIndexConfig
    public let embeddingDimensions: Int

    private var recordsByID: [String: MemoryChunkRecord]
    private var embeddingsByID: [String: [Float]]
    private var nextRowID: Int64
    private var reindexClaim: String

    #if canImport(SQLite3)
    private var database: OpaquePointer?
    private var persistedRecordsByID: [String: MemoryChunkRecord]
    private var persistedEmbeddingsByID: [String: [Float]]
    private var persistedReindexClaim: String
    private var sqliteVectorAvailable: Bool
    #endif

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
        #if canImport(SQLite3)
        self.database = nil
        self.persistedRecordsByID = [:]
        self.persistedEmbeddingsByID = [:]
        self.persistedReindexClaim = ""
        self.sqliteVectorAvailable = false
        #endif
        try load()
    }

    deinit {
        #if canImport(SQLite3)
        if let database {
            sqlite3_close(database)
        }
        #endif
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
        try searchFTSBySources(query, limit: limit, sources: nil)
    }

    public func searchFTSBySources(
        _ query: String,
        limit: Int,
        sources: [String]
    ) throws -> [FtsResult] {
        try searchFTSBySources(query, limit: limit, sources: Set(sources))
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
        #if canImport(SQLite3)
        if let rows = try? sqliteQuery(
            "SELECT value FROM meta WHERE key = ?1",
            bindings: [.text("reindex_claim")]
        ), let first = rows.first, case let .text(value) = first[0] {
            return value
        }
        #endif
        return reindexClaim
    }

    public func tryClaimReindex(staleThresholdSeconds: Int64, now: Int64 = MemoryIndex.currentUnixTime()) -> Bool {
        let timestamp = max(0, now)
        let cutoff = timestamp - max(0, staleThresholdSeconds)
        #if canImport(SQLite3)
        let claim = "\(ProcessInfo.processInfo.processIdentifier):\(timestamp)"
        do {
            try sqliteExecute(
                """
                UPDATE meta SET value = ?1 WHERE key = 'reindex_claim'
                AND (value = '' OR CAST(SUBSTR(value, INSTR(value, ':') + 1) AS INTEGER) < ?2)
                """,
                bindings: [.text(claim), .integer(cutoff)]
            )
            guard let database, sqlite3_changes(database) == 1 else { return false }
            reindexClaim = claim
            persistedReindexClaim = claim
            return true
        } catch {
            return false
        }
        #else
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
        #endif
    }

    public func releaseClaim() {
        reindexClaim = ""
        #if canImport(SQLite3)
        do {
            try sqliteExecute(
                "UPDATE meta SET value = '' WHERE key = 'reindex_claim'",
                bindings: []
            )
            persistedReindexClaim = ""
        } catch {
            return
        }
        #else
        try? persist()
        #endif
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
        #if canImport(SQLite3)
        persistedRecordsByID.removeAll(keepingCapacity: true)
        persistedEmbeddingsByID.removeAll(keepingCapacity: true)
        persistedReindexClaim = ""
        #endif
        try load()
    }

    private func searchFTSBySources(
        _ query: String,
        limit: Int,
        sources: Set<String>?
    ) throws -> [FtsResult] {
        guard limit > 0 else { return [] }
        if let sources, sources.isEmpty { return [] }
        let keywords = extractKeywords(query)
        guard !keywords.isEmpty else { return [] }

        #if canImport(SQLite3)
        let ftsQuery = keywords.map {
            "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\""
        }.joined(separator: " OR ")
        var sql = """
            SELECT c.id, f.rowid, f.rank FROM chunks_fts AS f
            JOIN chunks AS c ON c.rowid = f.rowid
            WHERE chunks_fts MATCH ?1
            """
        var bindings: [SQLiteValue] = [.text(ftsQuery)]
        if let sources {
            let orderedSources = sources.sorted()
            let placeholders = orderedSources.indices.map { "?\($0 + 2)" }.joined(separator: ", ")
            sql += " AND c.source IN (\(placeholders))"
            bindings.append(contentsOf: orderedSources.map(SQLiteValue.text))
        }
        sql += " ORDER BY f.rank, f.rowid LIMIT ?\(bindings.count + 1)"
        bindings.append(.integer(Int64(limit)))

        return try sqliteQuery(sql, bindings: bindings).map { row in
            guard row.count == 3,
                  case let .text(chunkID) = row[0],
                  case let .integer(rowID) = row[1],
                  case let .real(rank) = row[2]
            else {
                throw MemoryError.corruptIndex("malformed FTS search row")
            }
            return FtsResult(chunkID: chunkID, rowID: rowID, rank: rank)
        }
        #else
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
        #endif
    }

    private func load() throws {
        #if canImport(SQLite3)
        try loadSQLite()
        #else
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
        #endif
    }

    private func persist() throws {
        #if canImport(SQLite3)
        try persistSQLite()
        #else
        try FileManager.default.createDirectory(
            at: indexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeAtomically(indexURL, data: try serializedData())
        #endif
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

#if canImport(SQLite3)
private enum SQLiteValue {
    case text(String)
    case integer(Int64)
    case real(Double)
    case blob(Data)
    case null
}

private extension MemoryIndex {
    static let sqliteHeader = Data("SQLite format 3\u{0}".utf8)

    static let schema = """
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS chunks (
            rowid INTEGER PRIMARY KEY AUTOINCREMENT,
            id TEXT UNIQUE NOT NULL,
            path TEXT NOT NULL,
            start_line INTEGER NOT NULL,
            end_line INTEGER NOT NULL,
            text TEXT NOT NULL,
            hash TEXT NOT NULL,
            source TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            access_count INTEGER DEFAULT 0,
            last_accessed INTEGER
        );

        CREATE INDEX IF NOT EXISTS idx_chunks_path ON chunks(path);
        CREATE INDEX IF NOT EXISTS idx_chunks_hash ON chunks(hash);
        CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(text, content='');
        INSERT OR IGNORE INTO meta(key, value) VALUES ('reindex_claim', '');
        """

    func loadSQLite() throws {
        if database == nil {
            try openSQLite()
        }

        let rows = try sqliteQuery(
            """
            SELECT rowid, id, path, start_line, end_line, text, hash, source,
                   created_at, updated_at, COALESCE(access_count, 0), last_accessed
            FROM chunks ORDER BY rowid
            """
        )
        for row in rows {
            let record = try sqliteRecord(row)
            recordsByID[record.id] = record
        }
        nextRowID = (recordsByID.values.map(\.rowID).max() ?? 0) + 1
        let sequence = try sqliteQuery(
            "SELECT seq FROM sqlite_sequence WHERE name = ?1",
            bindings: [.text("chunks")]
        )
        if let first = sequence.first, case let .integer(value) = first[0] {
            nextRowID = max(nextRowID, value + 1)
        }

        if embeddingDimensions > 0 {
            let embeddings = try sqliteQuery(
                "SELECT key, value FROM meta WHERE key LIKE 'swift_embedding:%'"
            )
            for row in embeddings {
                guard case let .text(key) = row[0],
                      case let .text(encoded) = row[1],
                      let data = Data(base64Encoded: encoded),
                      let values = try? JSONDecoder().decode([Float].self, from: data),
                      values.count == embeddingDimensions
                else { continue }
                let chunkID = String(key.dropFirst("swift_embedding:".count))
                if recordsByID[chunkID] != nil {
                    embeddingsByID[chunkID] = values
                }
            }
        }
        reindexClaim = getReindexClaim()
        persistedRecordsByID = recordsByID
        persistedEmbeddingsByID = embeddingsByID
        persistedReindexClaim = reindexClaim
    }

    func openSQLite() throws {
        let manager = FileManager.default
        let parent = indexURL.deletingLastPathComponent()
        try MemoryStorage.ensureSecureDirectory(parent)
        let canonicalParent = try PathSecurity.canonicalize(parent)
        let path = canonicalParent.appendingPathComponent(indexURL.lastPathComponent)
        let alreadyExisted = manager.fileExists(atPath: path.path)
        let legacySnapshot = alreadyExisted ? nil : try loadLegacySnapshot()

        if alreadyExisted {
            try SecureFile.ensureOwnerOnlyPermissions(at: path)
            let handle = try FileHandle(forReadingFrom: path)
            defer { try? handle.close() }
            let header = try handle.read(upToCount: Self.sqliteHeader.count) ?? Data()
            guard header.isEmpty || header == Self.sqliteHeader else {
                throw MemoryError.corruptIndex("existing memory index is not a SQLite database")
            }
        } else {
            try SecureFile.write(at: path, contents: Data())
        }
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: path.path + suffix)
            if manager.fileExists(atPath: sidecar.path) {
                try SecureFile.ensureOwnerOnlyPermissions(at: sidecar)
                guard try SecureFile.isOwnerOnly(at: sidecar) else {
                    throw MemoryError.unsafePath(sidecar.path)
                }
            }
        }

        var opened: OpaquePointer?
        let noFollow: Int32 = 0x01000000
        let status = path.path.withCString {
            sqlite3_open_v2(
                $0,
                &opened,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | noFollow,
                nil
            )
        }
        guard status == SQLITE_OK, let opened else {
            let reason = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let opened { sqlite3_close(opened) }
            throw MemoryError.corruptIndex(reason)
        }
        database = opened

        do {
            try SecureFile.ensureOwnerOnlyPermissions(at: path)
            guard try SecureFile.isOwnerOnly(at: path) else {
                throw MemoryError.unsafePath(path.path)
            }
            sqlite3_busy_timeout(opened, JournalMode.busyTimeoutMilliseconds)
            let journal = JournalMode.forDBPath(path)
            if journal == .truncate {
                try sqliteBatch("PRAGMA locking_mode = EXCLUSIVE")
                try sqliteBatch("PRAGMA journal_mode = TRUNCATE")
                try sqliteBatch("PRAGMA locking_mode = NORMAL")
            } else {
                try sqliteBatch("PRAGMA journal_mode = WAL")
            }
            try sqliteBatch(Self.schema)
            sqliteVectorAvailable = embeddingDimensions > 0
                && (try? sqliteQuery("SELECT vec_version()"))?.isEmpty == false
            if sqliteVectorAvailable {
                try sqliteBatch(
                    """
                    CREATE VIRTUAL TABLE IF NOT EXISTS chunks_vec USING vec0(
                        chunk_id TEXT PRIMARY KEY,
                        embedding FLOAT[\(embeddingDimensions)]
                    )
                    """
                )
            }

            let storedDimensions = try sqliteQuery(
                "SELECT value FROM meta WHERE key = ?1",
                bindings: [.text("embedding_dimensions")]
            )
            if let first = storedDimensions.first,
               case let .text(value) = first[0],
               Int(value) != embeddingDimensions {
                try sqliteExecute("DELETE FROM meta WHERE key LIKE 'swift_embedding:%'", bindings: [])
                if sqliteVectorAvailable {
                    try sqliteBatch("DROP TABLE IF EXISTS chunks_vec")
                    if embeddingDimensions > 0 {
                        try sqliteBatch(
                            """
                            CREATE VIRTUAL TABLE chunks_vec USING vec0(
                                chunk_id TEXT PRIMARY KEY,
                                embedding FLOAT[\(embeddingDimensions)]
                            )
                            """
                        )
                    }
                }
            }
            try sqliteExecute(
                "INSERT OR REPLACE INTO meta(key, value) VALUES (?1, ?2)",
                bindings: [.text("embedding_dimensions"), .text(String(embeddingDimensions))]
            )

            if let legacySnapshot {
                guard legacySnapshot.version == 1 else {
                    throw MemoryError.unsupportedIndexVersion(legacySnapshot.version)
                }
                recordsByID = Dictionary(uniqueKeysWithValues: legacySnapshot.records.map { ($0.id, $0) })
                nextRowID = legacySnapshot.nextRowID
                reindexClaim = legacySnapshot.reindexClaim
                if legacySnapshot.embeddingDimensions == embeddingDimensions {
                    embeddingsByID = Dictionary(
                        uniqueKeysWithValues: legacySnapshot.embeddings.map { ($0.chunkID, $0.values) }
                    )
                }
                try persistSQLite()
            }
        } catch {
            sqlite3_close(opened)
            database = nil
            throw error
        }
    }

    func loadLegacySnapshot() throws -> MemoryIndexSnapshot? {
        let legacy = indexURL.deletingLastPathComponent().appendingPathComponent("index.json")
        guard legacy.standardizedFileURL != indexURL.standardizedFileURL,
              FileManager.default.fileExists(atPath: legacy.path)
        else { return nil }
        try SecureFile.ensureOwnerOnlyPermissions(at: legacy)
        let attributes = try FileManager.default.attributesOfItem(atPath: legacy.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= 64 * 1_024 * 1_024 else {
            throw MemoryError.corruptIndex("legacy memory index exceeds the migration limit")
        }
        let data = try PathSecurity.readNoFollow(
            legacy,
            maximumBytes: 64 * 1_024 * 1_024,
            requireOwnerOnly: true
        )
        if data.starts(with: Self.sqliteHeader) {
            return nil
        }
        do {
            return try JSONDecoder().decode(MemoryIndexSnapshot.self, from: data)
        } catch {
            throw MemoryError.corruptIndex("legacy memory index could not be safely migrated")
        }
    }

    func persistSQLite() throws {
        try sqliteBatch("BEGIN IMMEDIATE TRANSACTION")
        do {
            let removedIDs = Set(persistedRecordsByID.keys).subtracting(recordsByID.keys).sorted()
            for id in removedIDs {
                guard let old = persistedRecordsByID[id] else { continue }
                try deleteSQLiteFTS(record: old)
                if sqliteVectorAvailable {
                    try sqliteExecute("DELETE FROM chunks_vec WHERE chunk_id = ?1", bindings: [.text(id)])
                }
                try sqliteExecute("DELETE FROM chunks WHERE id = ?1", bindings: [.text(id)])
            }

            for id in recordsByID.keys.sorted() {
                guard let record = recordsByID[id], persistedRecordsByID[id] != record else { continue }
                if let previous = persistedRecordsByID[id] {
                    if previous.text != record.text {
                        try deleteSQLiteFTS(record: previous)
                    }
                    try sqliteExecute(
                        """
                        UPDATE chunks SET path = ?1, start_line = ?2, end_line = ?3,
                            text = ?4, hash = ?5, source = ?6, created_at = ?7,
                            updated_at = ?8, access_count = ?9, last_accessed = ?10
                        WHERE id = ?11
                        """,
                        bindings: [
                            .text(record.path), .integer(Int64(record.startLine)),
                            .integer(Int64(record.endLine)), .text(record.text), .text(record.hash),
                            .text(record.source), .integer(record.createdAt), .integer(record.updatedAt),
                            .integer(record.accessCount), sqliteOptionalInteger(record.lastAccessed),
                            .text(record.id),
                        ]
                    )
                    if previous.text != record.text {
                        try insertSQLiteFTS(record: record)
                    }
                } else {
                    try sqliteExecute(
                        """
                        INSERT INTO chunks(
                            rowid, id, path, start_line, end_line, text, hash, source,
                            created_at, updated_at, access_count, last_accessed
                        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
                        """,
                        bindings: [
                            .integer(record.rowID), .text(record.id), .text(record.path),
                            .integer(Int64(record.startLine)), .integer(Int64(record.endLine)),
                            .text(record.text), .text(record.hash), .text(record.source),
                            .integer(record.createdAt), .integer(record.updatedAt),
                            .integer(record.accessCount), sqliteOptionalInteger(record.lastAccessed),
                        ]
                    )
                    try insertSQLiteFTS(record: record)
                }
            }

            let removedEmbeddings = Set(persistedEmbeddingsByID.keys)
                .subtracting(embeddingsByID.keys).sorted()
            for id in removedEmbeddings {
                try sqliteExecute(
                    "DELETE FROM meta WHERE key = ?1",
                    bindings: [.text("swift_embedding:\(id)")]
                )
                if sqliteVectorAvailable {
                    try sqliteExecute("DELETE FROM chunks_vec WHERE chunk_id = ?1", bindings: [.text(id)])
                }
            }
            for id in embeddingsByID.keys.sorted() {
                guard let embedding = embeddingsByID[id],
                      persistedEmbeddingsByID[id] != embedding
                else { continue }
                let data = try JSONEncoder().encode(embedding)
                try sqliteExecute(
                    "INSERT OR REPLACE INTO meta(key, value) VALUES (?1, ?2)",
                    bindings: [.text("swift_embedding:\(id)"), .text(data.base64EncodedString())]
                )
                if sqliteVectorAvailable {
                    var vector = Data(capacity: embedding.count * MemoryLayout<Float>.size)
                    for value in embedding {
                        var bits = value.bitPattern.littleEndian
                        withUnsafeBytes(of: &bits) { vector.append(contentsOf: $0) }
                    }
                    try sqliteExecute(
                        "INSERT OR REPLACE INTO chunks_vec(chunk_id, embedding) VALUES (?1, ?2)",
                        bindings: [.text(id), .blob(vector)]
                    )
                }
            }

            if persistedReindexClaim != reindexClaim {
                try sqliteExecute(
                    "UPDATE meta SET value = ?1 WHERE key = 'reindex_claim'",
                    bindings: [.text(reindexClaim)]
                )
            }
            try sqliteBatch("COMMIT")
            persistedRecordsByID = recordsByID
            persistedEmbeddingsByID = embeddingsByID
            persistedReindexClaim = reindexClaim
        } catch {
            try? sqliteBatch("ROLLBACK")
            recordsByID = persistedRecordsByID
            embeddingsByID = persistedEmbeddingsByID
            reindexClaim = persistedReindexClaim
            nextRowID = (recordsByID.values.map(\.rowID).max() ?? 0) + 1
            throw error
        }
    }

    func insertSQLiteFTS(record: MemoryChunkRecord) throws {
        try sqliteExecute(
            "INSERT INTO chunks_fts(rowid, text) VALUES (?1, ?2)",
            bindings: [.integer(record.rowID), .text(record.text)]
        )
    }

    func deleteSQLiteFTS(record: MemoryChunkRecord) throws {
        try sqliteExecute(
            "INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES('delete', ?1, ?2)",
            bindings: [.integer(record.rowID), .text(record.text)]
        )
    }

    func sqliteOptionalInteger(_ value: Int64?) -> SQLiteValue {
        value.map(SQLiteValue.integer) ?? .null
    }

    func sqliteRecord(_ row: [SQLiteValue]) throws -> MemoryChunkRecord {
        guard row.count == 12,
              case let .integer(rowID) = row[0],
              case let .text(id) = row[1],
              case let .text(path) = row[2],
              case let .integer(startLine) = row[3],
              case let .integer(endLine) = row[4],
              case let .text(text) = row[5],
              case let .text(hash) = row[6],
              case let .text(source) = row[7],
              case let .integer(createdAt) = row[8],
              case let .integer(updatedAt) = row[9],
              case let .integer(accessCount) = row[10]
        else {
            throw MemoryError.corruptIndex("malformed indexed memory chunk")
        }
        let lastAccessed: Int64?
        switch row[11] {
        case .null:
            lastAccessed = nil
        case .integer(let value):
            lastAccessed = value
        default:
            throw MemoryError.corruptIndex("malformed indexed memory access timestamp")
        }
        return MemoryChunkRecord(
            rowID: rowID,
            id: id,
            path: path,
            startLine: Int(startLine),
            endLine: Int(endLine),
            text: text,
            hash: hash,
            source: source,
            createdAt: createdAt,
            updatedAt: updatedAt,
            accessCount: accessCount,
            lastAccessed: lastAccessed
        )
    }

    func sqliteBatch(_ sql: String) throws {
        guard let database else { throw MemoryError.corruptIndex("memory database is closed") }
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &message)
        guard status == SQLITE_OK else {
            let reason = message.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            if let message { sqlite3_free(message) }
            throw MemoryError.corruptIndex(reason)
        }
    }

    func sqliteExecute(_ sql: String, bindings: [SQLiteValue]) throws {
        try sqliteStatement(sql, bindings: bindings) { statement in
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw sqliteError("memory database statement failed")
            }
        }
    }

    func sqliteQuery(_ sql: String, bindings: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
        try sqliteStatement(sql, bindings: bindings) { statement in
            var rows: [[SQLiteValue]] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return rows }
                guard status == SQLITE_ROW else {
                    throw sqliteError("memory database query failed")
                }
                var row: [SQLiteValue] = []
                for offset in 0..<Int(sqlite3_column_count(statement)) {
                    let column = Int32(offset)
                    switch sqlite3_column_type(statement, column) {
                    case SQLITE_INTEGER:
                        row.append(.integer(sqlite3_column_int64(statement, column)))
                    case SQLITE_FLOAT:
                        row.append(.real(sqlite3_column_double(statement, column)))
                    case SQLITE_TEXT:
                        guard let value = sqlite3_column_text(statement, column) else {
                            throw sqliteError("memory database returned an invalid text value")
                        }
                        row.append(.text(String(cString: value)))
                    case SQLITE_BLOB:
                        let length = Int(sqlite3_column_bytes(statement, column))
                        if length == 0 {
                            row.append(.blob(Data()))
                        } else if let bytes = sqlite3_column_blob(statement, column) {
                            row.append(.blob(Data(bytes: bytes, count: length)))
                        } else {
                            throw sqliteError("memory database returned an invalid binary value")
                        }
                    default:
                        row.append(.null)
                    }
                }
                rows.append(row)
            }
        }
    }

    func sqliteStatement<Result>(
        _ sql: String,
        bindings: [SQLiteValue],
        operation: (OpaquePointer) throws -> Result
    ) throws -> Result {
        guard let database else { throw MemoryError.corruptIndex("memory database is closed") }
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &prepared, nil) == SQLITE_OK,
              let prepared
        else {
            throw sqliteError("memory database statement could not be prepared")
        }
        defer { sqlite3_finalize(prepared) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch binding {
            case .text(let value):
                status = value.withCString {
                    sqlite3_bind_text(prepared, index, $0, -1, transient)
                }
            case .integer(let value):
                status = sqlite3_bind_int64(prepared, index, value)
            case .real(let value):
                status = sqlite3_bind_double(prepared, index, value)
            case .blob(let value):
                status = value.withUnsafeBytes {
                    sqlite3_bind_blob(prepared, index, $0.baseAddress, Int32(value.count), transient)
                }
            case .null:
                status = sqlite3_bind_null(prepared, index)
            }
            guard status == SQLITE_OK else {
                throw sqliteError("memory database statement could not be bound")
            }
        }
        return try operation(prepared)
    }

    func sqliteError(_ fallback: String) -> MemoryError {
        guard let database else { return .corruptIndex(fallback) }
        return .corruptIndex(String(cString: sqlite3_errmsg(database)))
    }
}
#endif
