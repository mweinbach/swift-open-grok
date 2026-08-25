import Foundation
import OpenGrokConfig
import OpenGrokFileUtils

#if canImport(SQLite3)
import SQLite3

final class LiveSessionSearchSQLite {
    private static let schemaVersion: UInt64 = 4
    private static let schemaVersionKey = "session_search_schema_version"
    private static let canonicalColumns = [
        "session_id", "cwd", "updated_at", "title", "content", "content_hash",
    ]
    private static let legacySwiftColumns = [
        "session_id", "cwd", "cwd_key", "updated_at", "title", "content", "content_hash",
    ]

    struct Metadata {
        var updatedAt: Int64
        var workingDirectory: String
    }

    private enum Value {
        case text(String)
        case integer(Int64)
        case null
    }

    private var handle: OpaquePointer?

    init(path: URL) throws {
        // Foundation preserves macOS's /var alias even when asked to resolve
        // symlinks; SQLite no-follow requires realpath for every parent.
        let parent = try PathSecurity.canonicalize(path.deletingLastPathComponent())
        let databasePath = parent.appendingPathComponent(path.lastPathComponent)

        if FileManager.default.fileExists(atPath: databasePath.path) {
            try SecureFile.ensureOwnerOnlyPermissions(at: databasePath)
        } else {
            try SecureFile.write(at: databasePath, contents: Data())
        }
        try Self.validateSidecars(for: databasePath)

        var opened: OpaquePointer?
        // SQLITE_OPEN_NOFOLLOW is 0x01000000 in SQLite's stable C ABI. Spell
        // the value directly because older SDK module maps omit the macro.
        let noFollow: Int32 = 0x01000000
        let status = databasePath.path.withCString {
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
            throw LiveSessionSearchIndexError.sqlite(reason)
        }
        handle = opened
        do {
            try SecureFile.ensureOwnerOnlyPermissions(at: databasePath)
            guard try SecureFile.isOwnerOnly(at: databasePath) else {
                throw LiveSessionSearchIndexError.insecure("database is not owner-private")
            }
            sqlite3_busy_timeout(opened, 5_000)
            try configureJournalMode()
            try registerCanonicalWorkspaceFunction(on: opened)
            try initializeSchema()
            try Self.validateSidecars(for: databasePath)
        } catch {
            sqlite3_close(opened)
            handle = nil
            throw error
        }
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func execute(_ sql: String) throws {
        try executeBatch(sql)
    }

    func indexedMetadata() throws -> [String: Metadata] {
        let rows = try query("SELECT session_id, cwd, updated_at FROM session_docs")
        var result: [String: Metadata] = [:]
        result.reserveCapacity(rows.count)
        for row in rows {
            guard let sessionID = text(row, 0),
                  let cwd = text(row, 1),
                  let updated = integer(row, 2)
            else {
                throw LiveSessionSearchIndexError.sqlite("malformed session index metadata")
            }
            let (milliseconds, overflow) = updated.multipliedReportingOverflow(by: 1_000)
            result[sessionID] = Metadata(
                updatedAt: overflow ? (updated < 0 ? .min : .max) : milliseconds,
                workingDirectory: cwd
            )
        }
        return result
    }

    func upsert(document: LiveSessionDocument, timestamp: Int64) throws {
        let title = document.title ?? ""
        let content = String(document.content.prefix(LiveSessionDocument.contentLimit))
        let hash = Self.contentHash(title: title, content: content)
        try perform(
            """
            INSERT INTO session_docs(session_id, cwd, updated_at, title, content, content_hash)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            ON CONFLICT(session_id) DO UPDATE SET
                cwd = excluded.cwd,
                updated_at = excluded.updated_at,
                title = excluded.title,
                content = excluded.content,
                content_hash = excluded.content_hash
            """,
            bindings: [
                .text(document.sessionID),
                .text(document.workingDirectory),
                .integer(Self.unixSeconds(timestamp)),
                .text(title),
                .text(content),
                .text(hash),
            ]
        )
    }

    func delete(sessionID: String) throws {
        try perform("DELETE FROM session_docs WHERE session_id = ?1", bindings: [.text(sessionID)])
    }

    func search(
        query rawQuery: String,
        workingDirectory: URL?,
        limit: Int,
        offset: Int,
        includeContent: Bool
    ) throws -> LiveSessionSearchPage {
        let workspace = workingDirectory.map {
            Value.text($0.resolvingSymlinksInPath().standardizedFileURL.path)
        } ?? .null

        if isSessionIDQuery(rawQuery) {
            let page = try searchSessionIDs(
                query: rawQuery,
                workspace: workspace,
                limit: limit,
                offset: offset
            )
            if page.total > 0 || UUID(uuidString: rawQuery) != nil { return page }
        }

        let terms = LiveSessionSearchQuery.tokens(rawQuery).map(ftsTerm)
        guard !terms.isEmpty else { return .empty }
        let conjunction = terms.joined(separator: " AND ")
        let strict = try searchMatch(
            query: conjunction,
            workspace: workspace,
            limit: limit,
            offset: offset,
            includeContent: includeContent
        )
        guard strict.total == 0, terms.count > 1 else { return strict }
        return try searchMatch(
            query: terms.joined(separator: " OR "),
            workspace: workspace,
            limit: limit,
            offset: offset,
            includeContent: includeContent
        )
    }

    private func searchSessionIDs(
        query needle: String,
        workspace: Value,
        limit: Int,
        offset: Int
    ) throws -> LiveSessionSearchPage {
        let base = """
            FROM session_docs d
            WHERE instr(lower(d.session_id), lower(?1)) > 0
              AND (?2 IS NULL OR d.cwd = ?2 OR opengrok_canonical_cwd(d.cwd) = ?2)
            """
        let count = try count("SELECT COUNT(*) \(base)", bindings: [.text(needle), workspace])
        guard count > 0 else { return .empty }
        let rows = try query(
            """
            SELECT d.session_id, d.cwd, d.title, d.updated_at, 1.0, '', d.content
            \(base)
            ORDER BY d.updated_at DESC, d.session_id ASC
            LIMIT ?3 OFFSET ?4
            """,
            bindings: [.text(needle), workspace, .integer(Int64(limit)), .integer(Int64(offset))]
        )
        return try page(rows: rows, total: count, offset: offset, invertRank: false)
    }

    private func searchMatch(
        query match: String,
        workspace: Value,
        limit: Int,
        offset: Int,
        includeContent: Bool
    ) throws -> LiveSessionSearchPage {
        let base = """
            FROM session_docs_fts
            JOIN session_docs d ON d.rowid = session_docs_fts.rowid
            WHERE session_docs_fts MATCH ?1
              AND (?2 IS NULL OR d.cwd = ?2 OR opengrok_canonical_cwd(d.cwd) = ?2)
            """
        let count = try count("SELECT COUNT(*) \(base)", bindings: [.text(match), workspace])
        guard count > 0 else { return .empty }
        let snippet = includeContent
            ? "snippet(session_docs_fts, 1, '[', ']', ' … ', 18)"
            : "''"
        let rows = try query(
            """
            SELECT d.session_id, d.cwd, d.title, d.updated_at,
                   bm25(session_docs_fts, 10.0, 1.0) AS rank,
                   \(snippet), d.content
            \(base)
            ORDER BY rank ASC, d.updated_at DESC, d.session_id ASC
            LIMIT ?3 OFFSET ?4
            """,
            bindings: [.text(match), workspace, .integer(Int64(limit)), .integer(Int64(offset))]
        )
        return try page(rows: rows, total: count, offset: offset, invertRank: true)
    }

    private func page(
        rows: [[Value]],
        total: Int,
        offset: Int,
        invertRank: Bool
    ) throws -> LiveSessionSearchPage {
        var hits: [LiveSessionSearchHit] = []
        var documents: [String: LiveSessionDocument] = [:]
        for row in rows {
            guard let sessionID = text(row, 0),
                  let cwd = text(row, 1),
                  let title = text(row, 2),
                  let timestamp = integer(row, 3),
                  let rank = number(row, 4),
                  let snippet = text(row, 5),
                  let content = text(row, 6)
            else {
                throw LiveSessionSearchIndexError.sqlite("malformed session search result")
            }
            let updatedAt = Date(timeIntervalSince1970: Double(timestamp))
            let document = LiveSessionDocument(
                sessionID: sessionID,
                workingDirectory: cwd,
                title: title.isEmpty ? nil : title,
                updatedAt: updatedAt,
                content: content
            )
            documents[sessionID] = document
            hits.append(LiveSessionSearchHit(
                sessionID: sessionID,
                title: document.title,
                workingDirectory: cwd,
                updatedAt: updatedAt,
                score: invertRank ? -rank : rank,
                snippet: snippet
            ))
        }
        return LiveSessionSearchPage(
            hits: hits,
            total: total,
            nextOffset: offset + hits.count < total ? offset + hits.count : nil,
            bootstrapping: false,
            documentsByID: documents
        )
    }

    private func count(_ sql: String, bindings: [Value]) throws -> Int {
        let rows = try query(sql, bindings: bindings)
        guard let first = rows.first, let count = integer(first, 0) else {
            throw LiveSessionSearchIndexError.sqlite("missing full-text match count")
        }
        return Int(clamping: count)
    }

    private func ftsTerm(_ token: String) -> String {
        let lowered = token.lowercased()
        let onlyASCII = token.unicodeScalars.allSatisfy {
            ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122)
        }
        let stem: String
        if token.count >= 4, onlyASCII, lowered.hasSuffix("es") {
            stem = String(token.dropLast(2))
        } else if token.count >= 4, onlyASCII,
                  lowered.hasSuffix("s"), !lowered.hasSuffix("ss") {
            stem = String(token.dropLast())
        } else {
            stem = token
        }
        return "\"\(stem.replacingOccurrences(of: "\"", with: "\"\""))\" *"
    }

    private func isSessionIDQuery(_ query: String) -> Bool {
        if UUID(uuidString: query) != nil { return true }
        let stripped = query.filter { $0 != "-" }
        return stripped.count >= 8 && stripped.allSatisfy {
            $0.isASCII && "0123456789abcdefABCDEF".contains($0)
        }
    }

    private func configureJournalMode() throws {
        let current = try query("PRAGMA journal_mode").first.flatMap { text($0, 0) }?.lowercased()
        let environment = ProcessInfo.processInfo.environment
        let override = (
            environment["OPENGROK_SQLITE_JOURNAL_MODE"]
                ?? environment["GROK_SQLITE_JOURNAL_MODE"]
        )?.lowercased()
        let mode: String
        switch override {
        case "truncate": mode = "TRUNCATE"
        case "wal": mode = "WAL"
        default:
            mode = current == "truncate" ? "TRUNCATE" : "WAL"
        }
        try executeBatch("PRAGMA journal_mode = \(mode); PRAGMA foreign_keys = ON;")
    }

    private func registerCanonicalWorkspaceFunction(on handle: OpaquePointer) throws {
        // Canonicalization is connection-local: Rust must never encounter an
        // extra required column, expression index, or persisted Swift callback.
        let status = sqlite3_create_function_v2(
            handle,
            "opengrok_canonical_cwd",
            1,
            SQLITE_UTF8,
            nil,
            { context, count, arguments in
                guard let context,
                      count == 1,
                      let arguments,
                      let argument = arguments[0],
                      let bytes = sqlite3_value_text(argument)
                else {
                    sqlite3_result_null(context)
                    return
                }
                let path = URL(fileURLWithPath: String(cString: bytes))
                    .resolvingSymlinksInPath().standardizedFileURL.path
                path.withCString { value in
                    sqlite3_result_text(
                        context,
                        value,
                        -1,
                        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    )
                }
            },
            nil,
            nil,
            nil
        )
        guard status == SQLITE_OK else {
            throw databaseError("workspace canonicalization registration failed")
        }
    }

    private func initializeSchema() throws {
        try executeBatch("BEGIN IMMEDIATE")
        var committed = false
        defer {
            if !committed { try? executeBatch("ROLLBACK") }
        }

        try executeBatch("""
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """)
        let versionRows = try query(
            "SELECT value FROM meta WHERE key = ?1",
            bindings: [.text(Self.schemaVersionKey)]
        )
        let storedVersion = versionRows.first.flatMap { text($0, 0) }
            .map { UInt64($0) ?? 0 }
        let columns = try query("PRAGMA table_info(session_docs)").compactMap { text($0, 1) }

        if columns == Self.legacySwiftColumns {
            guard storedVersion.map({ $0 <= Self.schemaVersion }) ?? true else {
                throw LiveSessionSearchIndexError.sqlite(
                    "newer session search schema has incompatible legacy columns"
                )
            }
            try migrateLegacySwiftSchema()
        } else if !columns.isEmpty, columns != Self.canonicalColumns {
            guard storedVersion.map({ $0 > Self.schemaVersion }) ?? false,
                  Set(Self.canonicalColumns).isSubset(of: Set(columns))
            else {
                throw LiveSessionSearchIndexError.sqlite("incompatible session search schema")
            }
        }

        try createCanonicalSchema()

        if let storedVersion, storedVersion < Self.schemaVersion {
            try perform(
                "DELETE FROM meta WHERE key = ?1 OR key = ?2",
                bindings: [.text("last_bootstrap_at"), .text("bootstrap_claimed_at")]
            )
        }
        if storedVersion.map({ $0 <= Self.schemaVersion }) ?? true {
            try perform(
                """
                INSERT INTO meta(key, value) VALUES (?1, ?2)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                bindings: [.text(Self.schemaVersionKey), .text(String(Self.schemaVersion))]
            )
        }
        try perform("DELETE FROM meta WHERE key = ?1", bindings: [.text("schema_version")])
        try executeBatch("COMMIT")
        committed = true
    }

    private func migrateLegacySwiftSchema() throws {
        try executeBatch("""
            DROP TRIGGER IF EXISTS session_docs_ai;
            DROP TRIGGER IF EXISTS session_docs_ad;
            DROP TRIGGER IF EXISTS session_docs_au;
            DROP TABLE IF EXISTS session_docs_fts;
            ALTER TABLE session_docs RENAME TO session_docs_swift_legacy;
            """)
        try createCanonicalSchema()
        let legacyRows = try query("""
            SELECT rowid, session_id, cwd, updated_at, title, content
            FROM session_docs_swift_legacy
            """)
        for row in legacyRows {
            guard let rowID = integer(row, 0),
                  let sessionID = text(row, 1),
                  let cwd = text(row, 2),
                  let timestamp = integer(row, 3),
                  let title = text(row, 4),
                  let content = text(row, 5)
            else {
                throw LiveSessionSearchIndexError.sqlite("malformed legacy session search row")
            }
            try perform(
                """
                INSERT INTO session_docs(
                    rowid, session_id, cwd, updated_at, title, content, content_hash
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                """,
                bindings: [
                    .integer(rowID),
                    .text(sessionID),
                    .text(cwd),
                    .integer(Self.unixSeconds(timestamp)),
                    .text(title),
                    .text(content),
                    .text(Self.contentHash(title: title, content: content)),
                ]
            )
        }
        try executeBatch("DROP TABLE session_docs_swift_legacy")
    }

    private func createCanonicalSchema() throws {
        try executeBatch("""
            CREATE TABLE IF NOT EXISTS session_docs (
                session_id TEXT PRIMARY KEY,
                cwd TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                title TEXT NOT NULL,
                content TEXT NOT NULL,
                content_hash TEXT NOT NULL
            );

            CREATE VIRTUAL TABLE IF NOT EXISTS session_docs_fts USING fts5(
                title,
                content,
                content = 'session_docs',
                content_rowid = 'rowid'
            );

            CREATE TRIGGER IF NOT EXISTS session_docs_ai AFTER INSERT ON session_docs BEGIN
                INSERT INTO session_docs_fts(rowid, title, content)
                VALUES (new.rowid, new.title, new.content);
            END;

            CREATE TRIGGER IF NOT EXISTS session_docs_ad AFTER DELETE ON session_docs BEGIN
                INSERT INTO session_docs_fts(session_docs_fts, rowid, title, content)
                VALUES ('delete', old.rowid, old.title, old.content);
            END;

            CREATE TRIGGER IF NOT EXISTS session_docs_au AFTER UPDATE ON session_docs BEGIN
                INSERT INTO session_docs_fts(session_docs_fts, rowid, title, content)
                VALUES ('delete', old.rowid, old.title, old.content);
                INSERT INTO session_docs_fts(rowid, title, content)
                VALUES (new.rowid, new.title, new.content);
            END;
            """)
    }

    private static func contentHash(title: String, content: String) -> String {
        var bytes = Array(title.utf8)
        bytes.append(0)
        bytes.append(contentsOf: content.utf8)
        return Blake3.hexDigest(bytes)
    }

    private static func unixSeconds(_ milliseconds: Int64) -> Int64 {
        let seconds = milliseconds / 1_000
        return milliseconds < 0 && milliseconds % 1_000 != 0 ? seconds - 1 : seconds
    }

    private static func validateSidecars(for databasePath: URL) throws {
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: databasePath.path + suffix)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: sidecar.path)) != nil {
                throw LiveSessionSearchIndexError.insecure("SQLite sidecar must not be a symlink")
            }
            guard FileManager.default.fileExists(atPath: sidecar.path) else { continue }
            try SecureFile.ensureOwnerOnlyPermissions(at: sidecar)
            guard try SecureFile.isOwnerOnly(at: sidecar) else {
                throw LiveSessionSearchIndexError.insecure("SQLite sidecar is not owner-private")
            }
        }
    }

    private func executeBatch(_ sql: String) throws {
        guard let handle else { throw LiveSessionSearchIndexError.sqlite("database is closed") }
        var reason: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &reason)
        guard result == SQLITE_OK else {
            let message = reason.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(handle))
            if let reason { sqlite3_free(reason) }
            throw LiveSessionSearchIndexError.sqlite(message)
        }
    }

    private func perform(_ sql: String, bindings: [Value]) throws {
        try withStatement(sql, bindings: bindings) { statement in
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE else {
                throw databaseError("statement execution failed")
            }
        }
    }

    private func query(_ sql: String, bindings: [Value] = []) throws -> [[Value]] {
        try withStatement(sql, bindings: bindings) { statement in
            var rows: [[Value]] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return rows }
                guard result == SQLITE_ROW else {
                    throw databaseError("query execution failed")
                }
                let width = Int(sqlite3_column_count(statement))
                var row: [Value] = []
                row.reserveCapacity(width)
                for index in 0..<width {
                    let column = Int32(index)
                    switch sqlite3_column_type(statement, column) {
                    case SQLITE_INTEGER:
                        row.append(.integer(sqlite3_column_int64(statement, column)))
                    case SQLITE_FLOAT:
                        row.append(.text(String(sqlite3_column_double(statement, column))))
                    case SQLITE_TEXT:
                        guard let pointer = sqlite3_column_text(statement, column) else {
                            row.append(.null)
                            continue
                        }
                        row.append(.text(String(cString: pointer)))
                    default:
                        row.append(.null)
                    }
                }
                rows.append(row)
            }
        }
    }

    private func withStatement<T>(
        _ sql: String,
        bindings: [Value],
        operation: (OpaquePointer) throws -> T
    ) throws -> T {
        guard let handle else { throw LiveSessionSearchIndexError.sqlite("database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw databaseError("statement preparation failed")
        }
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch binding {
            case .text(let value):
                status = value.withCString {
                    sqlite3_bind_text(
                        statement,
                        index,
                        $0,
                        -1,
                        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    )
                }
            case .integer(let value):
                status = sqlite3_bind_int64(statement, index, value)
            case .null:
                status = sqlite3_bind_null(statement, index)
            }
            guard status == SQLITE_OK else {
                throw databaseError("statement binding failed")
            }
        }
        return try operation(statement)
    }

    private func databaseError(_ fallback: String) -> LiveSessionSearchIndexError {
        guard let handle else { return .sqlite(fallback) }
        return .sqlite(String(cString: sqlite3_errmsg(handle)))
    }

    private func text(_ row: [Value], _ index: Int) -> String? {
        guard row.indices.contains(index), case .text(let value) = row[index] else { return nil }
        return value
    }

    private func integer(_ row: [Value], _ index: Int) -> Int64? {
        guard row.indices.contains(index), case .integer(let value) = row[index] else { return nil }
        return value
    }

    private func number(_ row: [Value], _ index: Int) -> Double? {
        guard row.indices.contains(index) else { return nil }
        switch row[index] {
        case .integer(let value): return Double(value)
        case .text(let value): return Double(value)
        case .null: return nil
        }
    }
}
#endif
