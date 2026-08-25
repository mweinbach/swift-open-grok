import Foundation
import OpenGrokConfig
import OpenGrokFileUtils
import Testing
@testable import OpenGrokCLI

#if canImport(SQLite3)
import SQLite3

private enum RustSessionSearchSQLiteValue {
    case text(String)
    case integer(Int64)
    case null
}

private struct RustSessionSearchSQLiteFixtureError: Error {
    let message: String
}

private final class RustSessionSearchSQLiteConnection {
    private var handle: OpaquePointer?

    init(path: URL) throws {
        var opened: OpaquePointer?
        let status = path.path.withCString {
            sqlite3_open_v2($0, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        }
        guard status == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let opened { sqlite3_close(opened) }
            throw RustSessionSearchSQLiteFixtureError(message: message)
        }
        handle = opened
        sqlite3_busy_timeout(opened, 5_000)
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func close() throws {
        guard let handle else { return }
        let status = sqlite3_close(handle)
        guard status == SQLITE_OK else {
            throw RustSessionSearchSQLiteFixtureError(message: String(cString: sqlite3_errmsg(handle)))
        }
        self.handle = nil
    }

    func execute(_ sql: String) throws {
        guard let handle else {
            throw RustSessionSearchSQLiteFixtureError(message: "connection closed")
        }
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &message)
        guard status == SQLITE_OK else {
            let reason = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            if let message { sqlite3_free(message) }
            throw RustSessionSearchSQLiteFixtureError(message: reason)
        }
    }

    func perform(_ sql: String, bindings: [RustSessionSearchSQLiteValue] = []) throws {
        try withStatement(sql, bindings: bindings) { statement in
            guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
        }
    }

    func query(
        _ sql: String,
        bindings: [RustSessionSearchSQLiteValue] = []
    ) throws -> [[RustSessionSearchSQLiteValue]] {
        try withStatement(sql, bindings: bindings) { statement in
            var rows: [[RustSessionSearchSQLiteValue]] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return rows }
                guard status == SQLITE_ROW else { throw databaseError() }
                var row: [RustSessionSearchSQLiteValue] = []
                for offset in 0..<sqlite3_column_count(statement) {
                    switch sqlite3_column_type(statement, offset) {
                    case SQLITE_INTEGER:
                        row.append(.integer(sqlite3_column_int64(statement, offset)))
                    case SQLITE_TEXT:
                        guard let value = sqlite3_column_text(statement, offset) else {
                            row.append(.null)
                            continue
                        }
                        row.append(.text(String(cString: value)))
                    default:
                        row.append(.null)
                    }
                }
                rows.append(row)
            }
        }
    }

    func strings(_ sql: String, bindings: [RustSessionSearchSQLiteValue] = []) throws -> [String] {
        try query(sql, bindings: bindings).compactMap { row in
            guard let first = row.first, case .text(let value) = first else { return nil }
            return value
        }
    }

    func integers(_ sql: String, bindings: [RustSessionSearchSQLiteValue] = []) throws -> [Int64] {
        try query(sql, bindings: bindings).compactMap { row in
            guard let first = row.first, case .integer(let value) = first else { return nil }
            return value
        }
    }

    func insertRustDocument(
        sessionID: String,
        cwd: String,
        updatedAt: Int64,
        title: String,
        content: String
    ) throws {
        try perform(
            """
            INSERT INTO session_docs(session_id, cwd, updated_at, title, content, content_hash)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            """,
            bindings: [
                .text(sessionID),
                .text(cwd),
                .integer(updatedAt),
                .text(title),
                .text(content),
                .text(rustSessionSearchContentHash(title: title, content: content)),
            ]
        )
    }

    private func withStatement<T>(
        _ sql: String,
        bindings: [RustSessionSearchSQLiteValue],
        operation: (OpaquePointer) throws -> T
    ) throws -> T {
        guard let handle else {
            throw RustSessionSearchSQLiteFixtureError(message: "connection closed")
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw databaseError()
        }
        defer { sqlite3_finalize(statement) }

        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .text(let text):
                status = text.withCString {
                    sqlite3_bind_text(
                        statement,
                        index,
                        $0,
                        -1,
                        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    )
                }
            case .integer(let number):
                status = sqlite3_bind_int64(statement, index, number)
            case .null:
                status = sqlite3_bind_null(statement, index)
            }
            guard status == SQLITE_OK else { throw databaseError() }
        }
        return try operation(statement)
    }

    private func databaseError() -> RustSessionSearchSQLiteFixtureError {
        RustSessionSearchSQLiteFixtureError(
            message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "connection closed"
        )
    }
}

private struct RustSessionSearchSQLiteFixture {
    let root: URL
    let workspace: URL
    let otherWorkspace: URL
    let database: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-rust-session-search-\(UUID().uuidString)",
            isDirectory: true
        )
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        otherWorkspace = root.appendingPathComponent("other-workspace", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        database = sessions.appendingPathComponent("session_search.sqlite")
        for directory in [workspace, otherWorkspace, sessions] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try SecureFile.write(at: database, contents: Data())
    }

    func makeRustDatabase(version: String = "4") throws -> RustSessionSearchSQLiteConnection {
        let connection = try RustSessionSearchSQLiteConnection(path: database)
        try connection.execute("""
            PRAGMA journal_mode = WAL;

            CREATE TABLE meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            CREATE TABLE session_docs (
                session_id TEXT PRIMARY KEY,
                cwd TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                title TEXT NOT NULL,
                content TEXT NOT NULL,
                content_hash TEXT NOT NULL
            );

            CREATE VIRTUAL TABLE session_docs_fts USING fts5(
                title,
                content,
                content = 'session_docs',
                content_rowid = 'rowid'
            );

            CREATE TRIGGER session_docs_ai AFTER INSERT ON session_docs BEGIN
                INSERT INTO session_docs_fts(rowid, title, content)
                VALUES (new.rowid, new.title, new.content);
            END;

            CREATE TRIGGER session_docs_ad AFTER DELETE ON session_docs BEGIN
                INSERT INTO session_docs_fts(session_docs_fts, rowid, title, content)
                VALUES ('delete', old.rowid, old.title, old.content);
            END;

            CREATE TRIGGER session_docs_au AFTER UPDATE ON session_docs BEGIN
                INSERT INTO session_docs_fts(session_docs_fts, rowid, title, content)
                VALUES ('delete', old.rowid, old.title, old.content);
                INSERT INTO session_docs_fts(rowid, title, content)
                VALUES (new.rowid, new.title, new.content);
            END;
            """)
        try connection.perform(
            "INSERT INTO meta(key, value) VALUES (?1, ?2)",
            bindings: [.text("session_search_schema_version"), .text(version)]
        )
        return connection
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func rustSessionSearchContentHash(title: String, content: String) -> String {
    var bytes = Array(title.utf8)
    bytes.append(0)
    bytes.append(contentsOf: content.utf8)
    return Blake3.hexDigest(bytes)
}

@Suite("Rust and Swift share the actual session-search SQLite index")
struct LiveSessionSearchRustSQLiteInteropTests {
    @Test("a precreated Rust v4 WAL database remains scoped, searchable, and in Unix seconds")
    func opensCanonicalRustDatabaseAndScopesBothQueryPaths() throws {
        let fixture = try RustSessionSearchSQLiteFixture()
        defer { fixture.cleanup() }
        let identifier = "019f870d-6976-7123-8123-abcdef123456"
        let rust = try fixture.makeRustDatabase()
        try rust.insertRustDocument(
            sessionID: identifier,
            cwd: fixture.workspace.path,
            updatedAt: 1_725_000_001,
            title: "Rust architecture",
            content: "crossruntime sharedneedle"
        )
        try rust.insertRustDocument(
            sessionID: "019f870d-6976-7123-8123-ffffffffffff",
            cwd: fixture.otherWorkspace.path,
            updatedAt: 1_725_000_002,
            title: "Other workspace",
            content: "crossruntime foreignsecret"
        )
        try rust.close()

        let swift = try LiveSessionSearchSQLite(path: fixture.database)
        let scoped = try swift.search(
            query: "crossruntime",
            workingDirectory: fixture.workspace,
            limit: 20,
            offset: 0,
            includeContent: true
        )
        #expect(scoped.total == 1)
        #expect(scoped.hits.map(\.sessionID) == [identifier])
        #expect(scoped.hits.first?.updatedAt == Date(timeIntervalSince1970: 1_725_000_001))

        let byID = try swift.search(
            query: "019f870d-6976",
            workingDirectory: fixture.workspace,
            limit: 20,
            offset: 0,
            includeContent: false
        )
        #expect(byID.hits.map(\.sessionID) == [identifier])

        let foreign = try swift.search(
            query: "foreignsecret",
            workingDirectory: fixture.workspace,
            limit: 20,
            offset: 0,
            includeContent: true
        )
        #expect(foreign.total == 0)

        let metadata = try swift.indexedMetadata()
        #expect(metadata[identifier]?.updatedAt == 1_725_000_001_000)
    }

    @Test("Swift writes Rust's six-column rows, BLAKE3 material and WAL-visible FTS triggers")
    func swiftRowsAndRawRustRowsRoundTripInBothDirections() throws {
        let fixture = try RustSessionSearchSQLiteFixture()
        defer { fixture.cleanup() }
        let swift = try LiveSessionSearchSQLite(path: fixture.database)
        let document = LiveSessionDocument(
            sessionID: "swift-document",
            workingDirectory: fixture.workspace.path,
            title: "Swift Title",
            updatedAt: Date(timeIntervalSince1970: 1_725_000_123),
            content: "shared roundtrip content"
        )
        try swift.upsert(document: document, timestamp: 1_725_000_123_456)

        let rust = try RustSessionSearchSQLiteConnection(path: fixture.database)
        let columns = try rust.strings("SELECT name FROM pragma_table_info('session_docs')")
        #expect(columns == ["session_id", "cwd", "updated_at", "title", "content", "content_hash"])
        #expect(try rust.strings("SELECT value FROM meta WHERE key = 'session_search_schema_version'")
            == ["4"])
        #expect(try rust.strings("SELECT value FROM meta WHERE key = 'schema_version'").isEmpty)
        #expect(try rust.integers("SELECT updated_at FROM session_docs") == [1_725_000_123])
        #expect(try rust.strings("SELECT content_hash FROM session_docs") == [
            rustSessionSearchContentHash(title: "Swift Title", content: "shared roundtrip content"),
        ])
        #expect(try rust.integers(
            "SELECT count(*) FROM session_docs_fts WHERE session_docs_fts MATCH 'roundtrip'"
        ) == [1])
        #expect(try rust.strings("PRAGMA journal_mode") == ["wal"])

        try rust.insertRustDocument(
            sessionID: "rust-document",
            cwd: fixture.workspace.path,
            updatedAt: 1_725_000_124,
            title: "Rust Title",
            content: "roundtrip rustinsertedneedle"
        )
        let swiftReadsRust = try swift.search(
            query: "rustinsertedneedle",
            workingDirectory: fixture.workspace,
            limit: 20,
            offset: 0,
            includeContent: true
        )
        #expect(swiftReadsRust.hits.map(\.sessionID) == ["rust-document"])

        var renamed = document
        renamed.title = "Renamed Swift Title"
        try swift.upsert(document: renamed, timestamp: 1_725_000_125_789)
        #expect(try rust.strings(
            "SELECT content_hash FROM session_docs WHERE session_id = 'swift-document'"
        ) == [
            rustSessionSearchContentHash(title: "Renamed Swift Title", content: document.content),
        ])
        #expect(try rust.integers(
            "SELECT count(*) FROM session_docs_fts WHERE session_docs_fts MATCH 'Renamed'"
        ) == [1])
    }

    @Test("fractional timestamps, including pre-epoch values, do not reindex on every live search")
    func canonicalUnixSecondsPreserveIncrementalIndexing() throws {
        let fixture = try RustSessionSearchSQLiteFixture()
        defer { fixture.cleanup() }
        let documents = [
            LiveSessionDocument(
                sessionID: "positive-fractional-session",
                workingDirectory: fixture.workspace.path,
                title: "Positive fractional timestamp",
                updatedAt: Date(timeIntervalSince1970: 1_725_000_123.456),
                content: "fractionalroundtrip positive"
            ),
            LiveSessionDocument(
                sessionID: "negative-fractional-session",
                workingDirectory: fixture.workspace.path,
                title: "Negative fractional timestamp",
                updatedAt: Date(timeIntervalSince1970: -0.25),
                content: "fractionalroundtrip negative"
            ),
        ]
        var loads = 0
        let sources = documents.map { document in
            LiveSessionSearchIndexSource(
                sessionID: document.sessionID,
                workingDirectory: document.workingDirectory,
                updatedAt: document.updatedAt,
                load: {
                    loads += 1
                    return document
                }
            )
        }
        let environment = [
            "HOME": fixture.root.path,
            "OPENGROK_HOME": fixture.root.path,
            "GROK_SESSION_SEARCH": "1",
        ]
        let gate = SessionSearchGate()

        let initial = try LiveSessionSearchIndex.search(
            openGrokHome: fixture.root,
            environment: environment,
            query: "fractionalroundtrip",
            workingDirectory: fixture.workspace,
            limit: 20,
            gate: gate,
            sources: { sources }
        )
        #expect(initial.total == 2)
        #expect(loads == 2)

        let reopened = try LiveSessionSearchIndex.search(
            openGrokHome: fixture.root,
            environment: environment,
            query: "fractionalroundtrip",
            workingDirectory: fixture.workspace,
            limit: 20,
            gate: gate,
            sources: { sources }
        )
        #expect(reopened.total == 2)
        #expect(loads == 2)

        let rust = try RustSessionSearchSQLiteConnection(path: fixture.database)
        #expect(try rust.integers(
            "SELECT updated_at FROM session_docs ORDER BY updated_at ASC"
        ) == [-1, 1_725_000_123])
    }

    @Test("legacy seven-column Swift databases migrate atomically without losing rows or metadata")
    func migratesLegacySwiftSchemaAndRebuildsRustCompatibleHashes() throws {
        let fixture = try RustSessionSearchSQLiteFixture()
        defer { fixture.cleanup() }
        let legacy = try RustSessionSearchSQLiteConnection(path: fixture.database)
        try legacy.execute("""
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE session_docs (
                session_id TEXT PRIMARY KEY,
                cwd TEXT NOT NULL,
                cwd_key TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                title TEXT NOT NULL,
                content TEXT NOT NULL,
                content_hash TEXT NOT NULL
            );
            CREATE INDEX session_docs_cwd_key ON session_docs(cwd_key);
            CREATE VIRTUAL TABLE session_docs_fts USING fts5(
                title, content, content = 'session_docs', content_rowid = 'rowid'
            );
            CREATE TRIGGER session_docs_ai AFTER INSERT ON session_docs BEGIN
                INSERT INTO session_docs_fts(rowid, title, content)
                VALUES (new.rowid, new.title, new.content);
            END;
            INSERT INTO meta(key, value) VALUES ('schema_version', '1');
            INSERT INTO meta(key, value) VALUES ('custom_marker', 'preserved');
            """)
        try legacy.perform(
            """
            INSERT INTO session_docs(
                session_id, cwd, cwd_key, updated_at, title, content, content_hash
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            """,
            bindings: [
                .text("legacy-document"),
                .text(fixture.workspace.path),
                .text(fixture.workspace.resolvingSymlinksInPath().standardizedFileURL.path),
                .integer(1_725_000_456_789),
                .text("Legacy Title"),
                .text("migrated durablelegacyneedle"),
                .text("obsolete-sha256-digest"),
            ]
        )
        try legacy.close()

        let swift = try LiveSessionSearchSQLite(path: fixture.database)
        let migrated = try swift.search(
            query: "durablelegacyneedle",
            workingDirectory: fixture.workspace,
            limit: 20,
            offset: 0,
            includeContent: true
        )
        #expect(migrated.hits.map(\.sessionID) == ["legacy-document"])
        #expect(migrated.hits.first?.updatedAt == Date(timeIntervalSince1970: 1_725_000_456))

        let rust = try RustSessionSearchSQLiteConnection(path: fixture.database)
        #expect(try rust.strings("SELECT name FROM pragma_table_info('session_docs')") == [
            "session_id", "cwd", "updated_at", "title", "content", "content_hash",
        ])
        #expect(try rust.strings("SELECT content_hash FROM session_docs") == [
            rustSessionSearchContentHash(
                title: "Legacy Title",
                content: "migrated durablelegacyneedle"
            ),
        ])
        #expect(try rust.integers("SELECT updated_at FROM session_docs") == [1_725_000_456])
        #expect(try rust.strings("SELECT value FROM meta WHERE key = 'custom_marker'") == ["preserved"])
        #expect(try rust.strings("SELECT value FROM meta WHERE key = 'session_search_schema_version'")
            == ["4"])
        #expect(try rust.strings("SELECT value FROM meta WHERE key = 'schema_version'").isEmpty)
        #expect(try rust.strings(
            "SELECT name FROM sqlite_master WHERE name = 'session_docs_swift_legacy'"
        ).isEmpty)

        try rust.insertRustDocument(
            sessionID: "rust-after-migration",
            cwd: fixture.workspace.path,
            updatedAt: 1_725_000_457,
            title: "Rust after migration",
            content: "postmigrationneedle"
        )
        let inserted = try swift.search(
            query: "postmigrationneedle",
            workingDirectory: fixture.workspace,
            limit: 20,
            offset: 0,
            includeContent: true
        )
        #expect(inserted.hits.map(\.sessionID) == ["rust-after-migration"])
        #expect(try SecureFile.isOwnerOnly(at: fixture.database))
    }

    @Test("newer Rust schema ownership remains monotonic while compatible rows stay writable")
    func preservesNewerSchemaVersionWithoutDowngradingOrDeletingRows() throws {
        let fixture = try RustSessionSearchSQLiteFixture()
        defer { fixture.cleanup() }
        let rust = try fixture.makeRustDatabase(version: "9")
        try rust.execute("""
            ALTER TABLE session_docs
            ADD COLUMN future_generation TEXT NOT NULL DEFAULT 'newer-owner'
            """)
        try rust.perform(
            "INSERT INTO meta(key, value) VALUES (?1, ?2)",
            bindings: [.text("last_bootstrap_at"), .text("1725000000")]
        )
        try rust.insertRustDocument(
            sessionID: "future-rust-document",
            cwd: fixture.workspace.path,
            updatedAt: 1_725_000_000,
            title: "Future Rust",
            content: "futureindexneedle"
        )
        try rust.close()

        let swift = try LiveSessionSearchSQLite(path: fixture.database)
        let existing = try swift.search(
            query: "futureindexneedle",
            workingDirectory: fixture.workspace,
            limit: 20,
            offset: 0,
            includeContent: true
        )
        #expect(existing.hits.map(\.sessionID) == ["future-rust-document"])
        try swift.upsert(
            document: LiveSessionDocument(
                sessionID: "swift-with-newer-owner",
                workingDirectory: fixture.workspace.path,
                title: "Compatible Swift",
                updatedAt: Date(timeIntervalSince1970: 1_725_000_001),
                content: "futurecompatibilityneedle"
            ),
            timestamp: 1_725_000_001_000
        )

        let reopenedRust = try RustSessionSearchSQLiteConnection(path: fixture.database)
        #expect(try reopenedRust.strings(
            "SELECT value FROM meta WHERE key = 'session_search_schema_version'"
        ) == ["9"])
        #expect(try reopenedRust.strings("SELECT value FROM meta WHERE key = 'last_bootstrap_at'")
            == ["1725000000"])
        #expect(try reopenedRust.integers("SELECT count(*) FROM session_docs") == [2])
        #expect(try reopenedRust.strings("SELECT future_generation FROM session_docs")
            == ["newer-owner", "newer-owner"])
    }

    @Test("an unrecognized current-version schema fails closed and leaves its rows untouched")
    func incompatibleCurrentSchemaRollsBackWithoutDroppingData() throws {
        let fixture = try RustSessionSearchSQLiteFixture()
        defer { fixture.cleanup() }
        let rust = try fixture.makeRustDatabase()
        try rust.insertRustDocument(
            sessionID: "incompatible-document",
            cwd: fixture.workspace.path,
            updatedAt: 1_725_000_000,
            title: "Preserved incompatible row",
            content: "preserveonfailureneedle"
        )
        try rust.execute("""
            ALTER TABLE session_docs
            ADD COLUMN unrecognized_required_column TEXT NOT NULL DEFAULT 'preserve-me'
            """)
        try rust.close()

        #expect(throws: LiveSessionSearchIndexError.self) {
            try LiveSessionSearchSQLite(path: fixture.database)
        }

        let preserved = try RustSessionSearchSQLiteConnection(path: fixture.database)
        #expect(try preserved.integers("SELECT count(*) FROM session_docs") == [1])
        #expect(try preserved.strings("SELECT unrecognized_required_column FROM session_docs")
            == ["preserve-me"])
        #expect(try preserved.strings("SELECT value FROM meta WHERE key = 'session_search_schema_version'")
            == ["4"])
        #expect(try preserved.integers(
            "SELECT count(*) FROM session_docs_fts WHERE session_docs_fts MATCH 'preserveonfailureneedle'"
        ) == [1])
    }

    @Test("older canonical schemas retain rows while resetting stale Rust bootstrap ownership")
    func upgradesOlderCanonicalVersionWithoutDiscardingIndexedDocuments() throws {
        let fixture = try RustSessionSearchSQLiteFixture()
        defer { fixture.cleanup() }
        let rust = try fixture.makeRustDatabase(version: "3")
        try rust.execute("""
            INSERT INTO meta(key, value) VALUES ('last_bootstrap_at', '123');
            INSERT INTO meta(key, value) VALUES ('bootstrap_claimed_at', '123:prior-owner');
            INSERT INTO meta(key, value) VALUES ('unrelated_marker', 'keep');
            """)
        try rust.insertRustDocument(
            sessionID: "older-rust-document",
            cwd: fixture.workspace.path,
            updatedAt: 1_725_000_000,
            title: "Older Rust",
            content: "preservedolderneedle"
        )
        try rust.close()

        let swift = try LiveSessionSearchSQLite(path: fixture.database)
        #expect(try swift.search(
            query: "preservedolderneedle",
            workingDirectory: fixture.workspace,
            limit: 20,
            offset: 0,
            includeContent: true
        ).total == 1)

        let upgraded = try RustSessionSearchSQLiteConnection(path: fixture.database)
        #expect(try upgraded.strings("SELECT value FROM meta WHERE key = 'session_search_schema_version'")
            == ["4"])
        #expect(try upgraded.strings(
            "SELECT value FROM meta WHERE key IN ('last_bootstrap_at', 'bootstrap_claimed_at')"
        ).isEmpty)
        #expect(try upgraded.strings("SELECT value FROM meta WHERE key = 'unrelated_marker'")
            == ["keep"])
    }

    #if !os(Windows)
    @Test("Rust cwd aliases remain project-scoped without adding a persisted Swift-only column")
    func canonicalWorkspaceAliasFiltersBothFullTextAndSessionIdentity() throws {
        let fixture = try RustSessionSearchSQLiteFixture()
        defer { fixture.cleanup() }
        let alias = fixture.root.appendingPathComponent("workspace-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.workspace)
        let identifier = "019f870d-6976-7123-8123-acde12345678"
        let rust = try fixture.makeRustDatabase()
        try rust.insertRustDocument(
            sessionID: identifier,
            cwd: alias.path,
            updatedAt: 1_725_000_000,
            title: "Aliased Rust",
            content: "canonicalaliasneedle"
        )
        try rust.close()

        let swift = try LiveSessionSearchSQLite(path: fixture.database)
        let fullText = try swift.search(
            query: "canonicalaliasneedle",
            workingDirectory: fixture.workspace,
            limit: 20,
            offset: 0,
            includeContent: true
        )
        #expect(fullText.hits.map(\.sessionID) == [identifier])

        let identity = try swift.search(
            query: "019f870d-6976",
            workingDirectory: fixture.workspace,
            limit: 20,
            offset: 0,
            includeContent: false
        )
        #expect(identity.hits.map(\.sessionID) == [identifier])

        let foreign = try swift.search(
            query: "canonicalaliasneedle",
            workingDirectory: fixture.otherWorkspace,
            limit: 20,
            offset: 0,
            includeContent: true
        )
        #expect(foreign.total == 0)
    }

    @Test("a hostile WAL symlink is rejected before SQLite can touch its owner-private target")
    func symlinkedWALSidecarFailsClosedWithoutModifyingItsTarget() throws {
        let fixture = try RustSessionSearchSQLiteFixture()
        defer { fixture.cleanup() }
        let rust = try fixture.makeRustDatabase()
        try rust.close()

        let protected = fixture.root.appendingPathComponent("protected-target")
        try SecureFile.write(at: protected, contents: "do-not-modify")
        let sidecar = URL(fileURLWithPath: fixture.database.path + "-wal")
        if FileManager.default.fileExists(atPath: sidecar.path) {
            try FileManager.default.removeItem(at: sidecar)
        }
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: protected)

        #expect(throws: LiveSessionSearchIndexError.self) {
            try LiveSessionSearchSQLite(path: fixture.database)
        }
        #expect(try String(contentsOf: protected, encoding: .utf8) == "do-not-modify")
        #expect(try SecureFile.isOwnerOnly(at: protected))
    }
    #endif
}
#endif
