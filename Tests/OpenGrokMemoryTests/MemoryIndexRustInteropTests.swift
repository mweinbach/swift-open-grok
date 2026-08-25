import Foundation
import Testing
@testable import OpenGrokMemory

#if canImport(SQLite3)
import SQLite3

private enum MemorySQLiteFixtureError: Error {
    case sqlite(String)
}

private func withMemorySQLiteDatabase<Result>(
    at path: URL,
    operation: (OpaquePointer) throws -> Result
) throws -> Result {
    var database: OpaquePointer?
    let status = path.path.withCString {
        sqlite3_open_v2($0, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
    }
    guard status == SQLITE_OK, let database else {
        if let database { sqlite3_close(database) }
        throw MemorySQLiteFixtureError.sqlite("fixture database could not be opened")
    }
    defer { sqlite3_close(database) }
    return try operation(database)
}

private func memorySQLiteExecute(_ database: OpaquePointer, _ sql: String) throws {
    var message: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
        let reason = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
        if let message { sqlite3_free(message) }
        throw MemorySQLiteFixtureError.sqlite(reason)
    }
}

private func insertRustMemoryFixture(
    database: OpaquePointer,
    rowID: Int64,
    path: URL,
    text: String,
    source: String = "workspace"
) throws {
    let sql = """
        INSERT INTO chunks(
            rowid, id, path, start_line, end_line, text, hash, source,
            created_at, updated_at, access_count, last_accessed
        ) VALUES (?1, ?2, ?3, 0, 3, ?4, ?5, ?6, 1, 1, 0, NULL)
        """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement
    else {
        throw MemorySQLiteFixtureError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_int64(statement, 1, rowID)
    let values = ["\(path.path):0", path.path, text, chunkHash(text), source]
    for (offset, value) in values.enumerated() {
        let status = value.withCString {
            sqlite3_bind_text(statement, Int32(offset + 2), $0, -1, transient)
        }
        guard status == SQLITE_OK else {
            throw MemorySQLiteFixtureError.sqlite("fixture text binding failed")
        }
    }
    guard sqlite3_step(statement) == SQLITE_DONE else {
        throw MemorySQLiteFixtureError.sqlite(String(cString: sqlite3_errmsg(database)))
    }

    var fts: OpaquePointer?
    let ftsSQL = "INSERT INTO chunks_fts(rowid, text) VALUES (?1, ?2)"
    guard sqlite3_prepare_v2(database, ftsSQL, -1, &fts, nil) == SQLITE_OK,
          let fts
    else {
        throw MemorySQLiteFixtureError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(fts) }
    sqlite3_bind_int64(fts, 1, rowID)
    let bound = text.withCString { sqlite3_bind_text(fts, 2, $0, -1, transient) }
    guard bound == SQLITE_OK, sqlite3_step(fts) == SQLITE_DONE else {
        throw MemorySQLiteFixtureError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
}

private func makeMemoryInteropRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "memory-sqlite-interop-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private let rustMemorySchema = """
    CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE TABLE chunks (
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
    CREATE INDEX idx_chunks_path ON chunks(path);
    CREATE INDEX idx_chunks_hash ON chunks(hash);
    CREATE VIRTUAL TABLE chunks_fts USING fts5(text, content='');
    INSERT INTO meta(key, value) VALUES ('reindex_claim', '');
    INSERT INTO meta(key, value) VALUES ('embedding_dimensions', '0');
    """

@Suite("Rust and Swift share the canonical memory SQLite index")
struct MemoryIndexRustInteropTests {
    @Test("a Rust-shaped SQLite fixture is searchable and stays SQLite after Swift writes")
    func readsAndMutatesRustDatabase() throws {
        let root = try makeMemoryInteropRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = MemoryStorage.newFlat(cwd: root, root: root.appendingPathComponent("memory"))
        let path = root.appendingPathComponent("index.sqlite")
        let file = root.appendingPathComponent("rust.md")
        let initial = "# Rust memory\n\nInteroperable dragonfruit knowledge."
        try initial.write(to: file, atomically: true, encoding: .utf8)
        try withMemorySQLiteDatabase(at: path) { database in
            try memorySQLiteExecute(database, rustMemorySchema)
            try insertRustMemoryFixture(database: database, rowID: 7, path: file, text: initial)
        }

        let index = try MemoryIndex(indexURL: path, storage: storage)
        let existing = try index.searchFTS("dragonfruit", limit: 4)
        #expect(existing.count == 1)
        #expect(existing.first?.rowID == 7)
        #expect(try index.getChunk("\(file.path):0")?.hash == chunkHash(initial))
        #if !os(Windows)
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #endif

        let replacement = "# Rust memory\n\nInteroperable persimmon knowledge."
        try replacement.write(to: file, atomically: true, encoding: .utf8)
        let updated = try index.reindexFile(path: file, source: "workspace")
        #expect(updated.updated == 1)
        #expect(try index.searchFTS("dragonfruit", limit: 4).isEmpty)
        #expect(try index.searchFTS("persimmon", limit: 4).count == 1)

        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 16)
        #expect(header == Data("SQLite format 3\u{0}".utf8))
    }

    @Test("Swift-created schema exposes Rust meta, chunks, contentless FTS, and real BM25")
    func createsCanonicalSchemaAndFTS() throws {
        let root = try makeMemoryInteropRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = MemoryStorage.newFlat(cwd: root, root: root.appendingPathComponent("memory"))
        let path = root.appendingPathComponent("index.sqlite")
        let file = root.appendingPathComponent("memory.md")
        try "# Search\n\nBasilisk basilisk ranking.".write(to: file, atomically: true, encoding: .utf8)
        let index = try MemoryIndex(indexURL: path, storage: storage)
        let changed = try index.reindexFile(path: file, source: "workspace")
        #expect(changed.added == 1)

        try withMemorySQLiteDatabase(at: path) { database in
            var statement: OpaquePointer?
            let sql = """
                SELECT c.id, f.rank FROM chunks_fts f
                JOIN chunks c ON c.rowid = f.rowid
                WHERE chunks_fts MATCH 'basilisk'
                """
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement
            else {
                throw MemorySQLiteFixtureError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
            defer { sqlite3_finalize(statement) }
            #expect(sqlite3_step(statement) == SQLITE_ROW)
            #expect(sqlite3_column_double(statement, 1) < 0)
        }
        #expect(try index.deletePath(file) == 1)
        #expect(try index.searchFTS("basilisk", limit: 2).isEmpty)
    }

    @Test("the previous Swift JSON index migrates without overwriting the legacy file")
    func preservesLegacyJSONDuringMigration() throws {
        let root = try makeMemoryInteropRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = MemoryStorage.newFlat(cwd: root, root: root.appendingPathComponent("memory"))
        let legacy = root.appendingPathComponent("index.json")
        let file = root.appendingPathComponent("legacy.md")
        let text = "# Migrated\n\nLegacy kumquat knowledge."
        let record = MemoryChunkRecord(
            rowID: 3,
            id: "\(file.path):0",
            path: file.path,
            startLine: 0,
            endLine: 3,
            text: text,
            hash: chunkHash(text),
            source: "workspace",
            createdAt: 4,
            updatedAt: 4
        )
        let snapshot = MemoryIndexSnapshot(
            version: 1,
            embeddingDimensions: 0,
            nextRowID: 4,
            records: [record],
            embeddings: [],
            reindexClaim: ""
        )
        let original = try JSONEncoder().encode(snapshot)
        try original.write(to: legacy)

        let index = try MemoryIndex(indexURL: root.appendingPathComponent("index.sqlite"), storage: storage)
        #expect(try index.searchFTS("kumquat", limit: 2).count == 1)
        #expect(try Data(contentsOf: legacy) == original)
    }

    @Test("competing handles coordinate reindex claims through Rust's atomic meta update")
    func reindexClaimsCoordinateAcrossConnections() throws {
        let root = try makeMemoryInteropRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = MemoryStorage.newFlat(cwd: root, root: root.appendingPathComponent("memory"))
        let path = root.appendingPathComponent("index.sqlite")
        let first = try MemoryIndex(indexURL: path, storage: storage)
        let second = try MemoryIndex(indexURL: path, storage: storage)

        #expect(first.tryClaimReindex(staleThresholdSeconds: 60, now: 1_000))
        #expect(!second.tryClaimReindex(staleThresholdSeconds: 60, now: 1_000))
        #expect(second.getReindexClaim().hasSuffix(":1000"))
        first.releaseClaim()
        #expect(second.tryClaimReindex(staleThresholdSeconds: 60, now: 1_001))
    }

    @Test("reload observes chunks another Rust-compatible SQLite connection inserted")
    func reloadObservesExternalDatabaseWriter() throws {
        let root = try makeMemoryInteropRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = MemoryStorage.newFlat(cwd: root, root: root.appendingPathComponent("memory"))
        let path = root.appendingPathComponent("index.sqlite")
        let file = root.appendingPathComponent("external-rust.md")
        let index = try MemoryIndex(indexURL: path, storage: storage)

        try withMemorySQLiteDatabase(at: path) { database in
            try insertRustMemoryFixture(
                database: database,
                rowID: 13,
                path: file,
                text: "# External\n\nRust wrote quince knowledge."
            )
        }
        try index.reload()
        #expect(try index.searchFTS("quince", limit: 2).first?.rowID == 13)
        #expect(try index.getChunk("\(file.path):0")?.source == "workspace")
    }

    #if !os(Windows)
    @Test("an index symlink is rejected without following or modifying its target")
    func databaseSymlinkFailsClosed() throws {
        let root = try makeMemoryInteropRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = MemoryStorage.newFlat(cwd: root, root: root.appendingPathComponent("memory"))
        let outside = root.appendingPathComponent("outside-secret")
        let database = root.appendingPathComponent("index.sqlite")
        try "protected target".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: database, withDestinationURL: outside)

        #expect(throws: (any Error).self) {
            _ = try MemoryIndex(indexURL: database, storage: storage)
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "protected target")
    }
    #endif
}
#endif
