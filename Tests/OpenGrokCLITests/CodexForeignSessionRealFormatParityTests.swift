import Foundation
import Testing

@testable import OpenGrokCLI

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(SQLite3)
import SQLite3
#endif

@Suite("Codex foreign sessions match real rollout and database formats")
struct CodexForeignSessionRealFormatParityTests {
    @Test("live scanner discovers nested session_meta and event_msg records")
    func liveScannerDiscoversCanonicalEventRecords() throws {
        let fixture = try CodexForeignParityFixture()
        defer { fixture.remove() }
        let id = UUID().uuidString
        try fixture.writeRollout(
            id: id,
            records: [
                fixture.metadata(id: id, source: "vscode", branch: "  feature/real-format  "),
                fixture.userEvent("  Repair   the real Codex scanner  "),
            ]
        )

        let scanner = LiveForeignSessionScanner(environment: [
            "CODEX_HOME": fixture.home.path,
            "HOME": fixture.root.path,
        ])
        let sessions = scanner.scan(
            cwd: fixture.cwd,
            enabled: EnabledForeignSources(claude: false, codex: true)
        )

        let session = try #require(sessions.first)
        #expect(sessions.count == 1)
        #expect(session.nativeID == id)
        #expect(session.source == .codexVsCode)
        #expect(session.title == "Repair the real Codex scanner")
        #expect(session.cwd == fixture.cwd)
        #expect(session.branch == "feature/real-format")
    }

    @Test("response-item user text skips injected environment and instruction records")
    func responseItemsSkipInjectedContext() throws {
        let fixture = try CodexForeignParityFixture()
        defer { fixture.remove() }
        let id = UUID().uuidString
        try fixture.writeRollout(
            id: id,
            records: [
                fixture.metadata(id: id, source: ["custom": "atlas"]),
                fixture.userResponse("  <environment_context>machine details</environment_context>"),
                fixture.userResponse("<user_instructions>injected rules</user_instructions>"),
                fixture.userResponse("  Resolve the   actual user request  ", textType: "text"),
            ]
        )

        let sessions = fixture.scan()
        let session = try #require(sessions.first)
        #expect(sessions.count == 1)
        #expect(session.source == .codexAtlas)
        #expect(session.title == "Resolve the actual user request")
    }

    @Test("rollout filename UUID must match canonical session_meta UUID")
    func mismatchedFilenameAndPayloadIdentityFailClosed() throws {
        let fixture = try CodexForeignParityFixture()
        defer { fixture.remove() }
        try fixture.writeRollout(
            id: UUID().uuidString,
            records: [
                fixture.metadata(id: UUID().uuidString, source: "cli"),
                fixture.userEvent("A mismatched identity must never be imported"),
            ]
        )

        #expect(fixture.scan().isEmpty)
    }

    @Test("missing and unknown canonical sources are never silently classified as CLI")
    func missingAndUnknownSourcesFailClosed() throws {
        let fixture = try CodexForeignParityFixture()
        defer { fixture.remove() }

        for source in [nil, "unknown-client"] as [String?] {
            let id = UUID().uuidString
            try fixture.writeRollout(
                id: id,
                records: [
                    fixture.metadata(id: id, source: source),
                    fixture.userEvent("An unapproved source must remain hidden"),
                ]
            )
        }

        #expect(fixture.scan().isEmpty)
    }

    @Test("a later session_meta cannot repair or replace the first unapproved source")
    func firstSessionMetadataRemainsAuthoritative() throws {
        let fixture = try CodexForeignParityFixture()
        defer { fixture.remove() }
        let id = UUID().uuidString
        try fixture.writeRollout(
            id: id,
            records: [
                fixture.metadata(id: id, source: nil),
                fixture.metadata(id: id, source: "cli"),
                fixture.userEvent("The second metadata record cannot rescue the first"),
            ]
        )

        #expect(fixture.scan().isEmpty)
    }

    @Test("a symlinked date directory cannot escape the approved Codex root")
    func symlinkedDateDirectoryIsRejected() throws {
        let fixture = try CodexForeignParityFixture()
        defer { fixture.remove() }
        let id = UUID().uuidString
        let outside = try fixture.writeRollout(
            id: id,
            records: [fixture.metadata(id: id, source: "cli"), fixture.userEvent("outside")],
            base: fixture.outside
        )

        let linkedDate = fixture.dateDirectory(base: fixture.home, namespace: "sessions")
        try FileManager.default.createDirectory(
            at: linkedDate.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkedDate,
            withDestinationURL: outside.deletingLastPathComponent()
        )

        #expect(fixture.scan().isEmpty)
    }

    @Test("a symlinked rollout is rejected even when its target is owner-safe")
    func symlinkedRolloutFileIsRejected() throws {
        let fixture = try CodexForeignParityFixture()
        defer { fixture.remove() }
        let id = UUID().uuidString
        let outside = try fixture.writeRollout(
            id: id,
            records: [fixture.metadata(id: id, source: "cli"), fixture.userEvent("outside")],
            base: fixture.outside
        )

        let date = fixture.dateDirectory(base: fixture.home, namespace: "sessions")
        try FileManager.default.createDirectory(at: date, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: date.appendingPathComponent(outside.lastPathComponent),
            withDestinationURL: outside
        )

        #expect(fixture.scan().isEmpty)
    }

    #if canImport(Darwin) || canImport(Glibc)
    @Test("group-writable rollout files are rejected without mutating their permissions")
    func groupWritableRolloutIsRejected() throws {
        let fixture = try CodexForeignParityFixture()
        defer { fixture.remove() }
        let id = UUID().uuidString
        let path = try fixture.writeRollout(
            id: id,
            records: [fixture.metadata(id: id, source: "cli"), fixture.userEvent("unsafe")]
        )
        #expect(chmod(path.path, mode_t(0o664)) == 0)

        #expect(fixture.scan().isEmpty)

        var information = stat()
        #expect(lstat(path.path, &information) == 0)
        #expect(information.st_mode & mode_t(0o777) == mode_t(0o664))
    }

    @Test("a group-writable Codex root is rejected before either scanner reads its store")
    func groupWritableRootIsRejected() throws {
        let fixture = try CodexForeignParityFixture()
        defer { fixture.remove() }
        let id = UUID().uuidString
        try fixture.writeRollout(
            id: id,
            records: [fixture.metadata(id: id, source: "cli"), fixture.userEvent("unsafe root")]
        )
        #expect(chmod(fixture.home.path, mode_t(0o775)) == 0)

        #expect(fixture.scan().isEmpty)
    }
    #endif

    #if canImport(SQLite3)
    @Test("highest populated state generation wins and preserves persisted source and branch")
    func highestPopulatedDatabaseGenerationWins() throws {
        let fixture = try CodexForeignParityFixture()
        defer { fixture.remove() }
        let olderID = UUID().uuidString
        let latestID = UUID().uuidString
        let older = try fixture.writeRollout(
            id: olderID,
            records: [fixture.metadata(id: olderID, source: "cli"), fixture.userEvent("JSON older")]
        )
        let latest = try fixture.writeRollout(
            id: latestID,
            records: [fixture.metadata(id: latestID, source: "cli"), fixture.userEvent("JSON latest")]
        )
        try fixture.createDatabase(
            generation: 4,
            rows: [fixture.row(id: olderID, rollout: older.path, title: "Older generation")]
        )
        try fixture.createDatabase(
            generation: 17,
            rows: [fixture.row(
                id: latestID,
                rollout: latest.path,
                source: "{\"custom\":\"chatgpt\"}",
                title: "  Latest database title  ",
                branch: "  feature/sqlite  "
            )]
        )

        let scanner = LiveForeignSessionScanner(environment: ["CODEX_HOME": fixture.home.path])
        let sessions = scanner.scan(
            cwd: fixture.cwd,
            enabled: EnabledForeignSources(codex: true)
        )
        let session = try #require(sessions.first)
        #expect(sessions.count == 1)
        #expect(session.nativeID == latestID)
        #expect(session.source == .codexChatGpt)
        #expect(session.title == "Latest database title")
        #expect(session.branch == "feature/sqlite")
    }

    @Test("an empty newer generation falls back to an older populated database")
    func emptyNewerGenerationFallsBackToOlderDatabase() throws {
        let fixture = try CodexForeignParityFixture()
        defer { fixture.remove() }
        let id = UUID().uuidString
        let rollout = try fixture.writeRollout(
            id: id,
            records: [fixture.metadata(id: id, source: "cli"), fixture.userEvent("JSON title")]
        )
        try fixture.createDatabase(generation: 30, rows: [])
        try fixture.createDatabase(
            generation: 7,
            rows: [fixture.row(id: id, rollout: rollout.path, title: "Older usable database")]
        )

        let session = try #require(fixture.scan().first)
        #expect(session.nativeID == id)
        #expect(session.title == "Older usable database")
    }

    @Test("legacy second-resolution database timestamps use first-user-message fallback")
    func secondResolutionDatabaseAndTitleFallback() throws {
        let fixture = try CodexForeignParityFixture()
        defer { fixture.remove() }
        let id = UUID().uuidString
        let rollout = try fixture.writeRollout(
            id: id,
            records: [fixture.metadata(id: id, source: "cli"), fixture.userEvent("JSON title")],
            namespace: "archived_sessions"
        )
        try fixture.createDatabase(
            generation: 6,
            rows: [fixture.row(
                id: id,
                rollout: "archived_sessions/\(fixture.dateSuffix)/\(rollout.lastPathComponent)",
                source: "vscode",
                title: "   ",
                firstMessage: "  First real database prompt  ",
                updatedAt: Int64(fixture.now.timeIntervalSince1970)
            )],
            timestampColumn: "updated_at"
        )

        let session = try #require(fixture.scan().first)
        #expect(session.nativeID == id)
        #expect(session.source == .codexVsCode)
        #expect(session.title == "First real database prompt")
        #expect(abs(session.updatedAt.timeIntervalSince(fixture.now)) < 1)
    }

    @Test("empty or unsupported databases fall back to canonical rollout records")
    func emptyDatabaseFallsBackToJSONL() throws {
        let fixture = try CodexForeignParityFixture()
        defer { fixture.remove() }
        let id = UUID().uuidString
        try fixture.writeRollout(
            id: id,
            records: [fixture.metadata(id: id, source: "cli"), fixture.userEvent("JSONL fallback")]
        )
        try fixture.createDatabase(generation: 8, rows: [])

        let session = try #require(fixture.scan().first)
        #expect(session.nativeID == id)
        #expect(session.title == "JSONL fallback")
    }

    @Test("symlinked database generations cannot override owner-safe rollout discovery")
    func symlinkedDatabaseFallsBackToJSONL() throws {
        let fixture = try CodexForeignParityFixture()
        defer { fixture.remove() }
        let id = UUID().uuidString
        let rollout = try fixture.writeRollout(
            id: id,
            records: [fixture.metadata(id: id, source: "cli"), fixture.userEvent("Safe rollout")]
        )
        let outsideDatabase = fixture.outside.appendingPathComponent("state_9.sqlite")
        try fixture.createDatabase(
            at: outsideDatabase,
            rows: [fixture.row(id: id, rollout: rollout.path, title: "Escaped database")]
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.home.appendingPathComponent("state_9.sqlite"),
            withDestinationURL: outsideDatabase
        )

        let session = try #require(fixture.scan().first)
        #expect(session.title == "Safe rollout")
    }

    #if canImport(Darwin) || canImport(Glibc)
    @Test("group-writable state databases are skipped without changing their permissions")
    func groupWritableDatabaseFallsBackToJSONL() throws {
        let fixture = try CodexForeignParityFixture()
        defer { fixture.remove() }
        let id = UUID().uuidString
        let rollout = try fixture.writeRollout(
            id: id,
            records: [fixture.metadata(id: id, source: "cli"), fixture.userEvent("Safe JSONL")]
        )
        try fixture.createDatabase(
            generation: 11,
            rows: [fixture.row(id: id, rollout: rollout.path, title: "Unsafe database")]
        )
        let database = fixture.home.appendingPathComponent("state_11.sqlite")
        #expect(chmod(database.path, mode_t(0o664)) == 0)

        let session = try #require(fixture.scan().first)
        #expect(session.title == "Safe JSONL")

        var information = stat()
        #expect(lstat(database.path, &information) == 0)
        #expect(information.st_mode & mode_t(0o777) == mode_t(0o664))
    }
    #endif

    @Test("database rows reject archived, unknown-source, traversal, and symlinked rollouts")
    func databaseRowsFailClosedOnUnsafeIdentityAndPaths() throws {
        let fixture = try CodexForeignParityFixture()
        defer { fixture.remove() }
        let symlinkID = UUID().uuidString
        let outside = try fixture.writeRollout(
            id: symlinkID,
            records: [fixture.metadata(id: symlinkID, source: "cli"), fixture.userEvent("outside")],
            base: fixture.outside
        )
        let archived = fixture.dateDirectory(base: fixture.home, namespace: "archived_sessions")
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let linked = archived.appendingPathComponent(outside.lastPathComponent)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)

        let archivedID = UUID().uuidString
        let archivedRollout = try fixture.writeRollout(
            id: archivedID,
            records: [fixture.metadata(id: archivedID, source: "cli"), fixture.userEvent("archived")],
            namespace: "archived_sessions"
        )
        try fixture.createDatabase(
            generation: 12,
            rows: [
                fixture.row(id: symlinkID, rollout: linked.path, title: "Symlink escape"),
                fixture.row(id: UUID().uuidString, rollout: "../outside/escape.jsonl", title: "Traversal"),
                fixture.row(id: archivedID, rollout: archivedRollout.path, title: "Archived", archived: 1),
                fixture.row(
                    id: UUID().uuidString,
                    rollout: archivedRollout.path,
                    source: "unknown-client",
                    title: "Unknown source"
                ),
                fixture.row(id: UUID().uuidString, rollout: archivedRollout.path, title: "Wrong filename ID"),
            ]
        )

        #expect(fixture.scan().isEmpty)
    }
    #endif
}

private struct CodexForeignParityFixture {
    let root: URL
    let home: URL
    let outside: URL
    let now: Date
    let cwd = "/workspace/real-codex-project"

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-codex-real-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("codex", isDirectory: true)
        outside = root.appendingPathComponent("outside", isDirectory: true)
        now = Date()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    var dateSuffix: String {
        let components = Calendar(identifier: .gregorian)
            .dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d/%02d/%02d", components.year!, components.month!, components.day!)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func scan() -> [ForeignSessionSummary] {
        CodexSessionScanner.scan(requestedCwd: cwd, now: now, codexHome: home)
    }

    func dateDirectory(base: URL, namespace: String) -> URL {
        dateSuffix.split(separator: "/").reduce(
            base.appendingPathComponent(namespace, isDirectory: true)
        ) { partial, component in
            partial.appendingPathComponent(String(component), isDirectory: true)
        }
    }

    func metadata(id: String, source: Any?, branch: String? = nil) -> [String: Any] {
        var payload: [String: Any] = ["id": id, "cwd": cwd]
        if let source { payload["source"] = source }
        if let branch { payload["git"] = ["branch": branch] }
        return ["timestamp": "2026-08-25T12:00:00Z", "type": "session_meta", "payload": payload]
    }

    func userEvent(_ message: String) -> [String: Any] {
        ["type": "event_msg", "payload": ["type": "user_message", "message": message]]
    }

    func userResponse(_ message: String, textType: String = "input_text") -> [String: Any] {
        [
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "user",
                "content": [["type": textType, "text": message]],
            ],
        ]
    }

    @discardableResult
    func writeRollout(
        id: String,
        records: [[String: Any]],
        namespace: String = "sessions",
        base: URL? = nil
    ) throws -> URL {
        let directory = dateDirectory(base: base ?? home, namespace: namespace)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(
            "rollout-2027-01-15T12-00-00-\(id).jsonl"
        )
        let lines = try records.map { object in
            let data = try JSONSerialization.data(withJSONObject: object)
            return String(decoding: data, as: UTF8.self)
        }
        try (lines.joined(separator: "\n") + "\n").write(
            to: path,
            atomically: true,
            encoding: .utf8
        )
        return path
    }
}

#if canImport(SQLite3)
private struct CodexForeignDatabaseRow {
    var id: String
    var rollout: String
    var updatedAt: Int64
    var source: String
    var cwd: String
    var title: String
    var firstMessage: String
    var archived: Int
    var branch: String?
}

private struct CodexForeignDatabaseFixtureError: Error {
    let message: String
}

extension CodexForeignParityFixture {
    func row(
        id: String,
        rollout: String,
        source: String = "cli",
        title: String,
        firstMessage: String = "",
        updatedAt: Int64? = nil,
        archived: Int = 0,
        branch: String? = nil
    ) -> CodexForeignDatabaseRow {
        CodexForeignDatabaseRow(
            id: id,
            rollout: rollout,
            updatedAt: updatedAt ?? Int64(now.timeIntervalSince1970 * 1_000),
            source: source,
            cwd: cwd,
            title: title,
            firstMessage: firstMessage,
            archived: archived,
            branch: branch
        )
    }

    func createDatabase(
        generation: Int,
        rows: [CodexForeignDatabaseRow],
        timestampColumn: String = "updated_at_ms"
    ) throws {
        try createDatabase(
            at: home.appendingPathComponent("state_\(generation).sqlite"),
            rows: rows,
            timestampColumn: timestampColumn
        )
    }

    func createDatabase(
        at path: URL,
        rows: [CodexForeignDatabaseRow],
        timestampColumn: String = "updated_at_ms"
    ) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var opened: OpaquePointer?
        let status = path.path.withCString {
            sqlite3_open_v2(
                $0,
                &opened,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                nil
            )
        }
        guard status == SQLITE_OK, let database = opened else {
            if let opened { sqlite3_close(opened) }
            throw CodexForeignDatabaseFixtureError(message: "could not create SQLite fixture")
        }
        defer { sqlite3_close(database) }

        try execute(
            """
            CREATE TABLE threads (
                id TEXT,
                rollout_path TEXT,
                \(timestampColumn) INTEGER,
                source TEXT,
                cwd TEXT,
                archived INTEGER,
                title TEXT,
                first_user_message TEXT,
                git_branch TEXT
            )
            """,
            database: database
        )
        for row in rows {
            let branch = row.branch.map(sqlLiteral) ?? "NULL"
            try execute(
                """
                INSERT INTO threads (
                    id, rollout_path, \(timestampColumn), source, cwd, archived,
                    title, first_user_message, git_branch
                ) VALUES (
                    \(sqlLiteral(row.id)), \(sqlLiteral(row.rollout)), \(row.updatedAt),
                    \(sqlLiteral(row.source)), \(sqlLiteral(row.cwd)), \(row.archived),
                    \(sqlLiteral(row.title)), \(sqlLiteral(row.firstMessage)), \(branch)
                )
                """,
                database: database
            )
        }
    }

    private func sqlLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private func execute(_ sql: String, database: OpaquePointer) throws {
        var reason: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &reason)
        guard status == SQLITE_OK else {
            let message = reason.map { String(cString: $0) } ?? "SQLite fixture operation failed"
            if let reason { sqlite3_free(reason) }
            throw CodexForeignDatabaseFixtureError(message: message)
        }
    }
}
#endif
