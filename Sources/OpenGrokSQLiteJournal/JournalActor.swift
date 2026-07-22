// JournalActor.swift
//
// Actor-isolated, schema-versioned SQLite journal for durable records.
// Combines `xai-sqlite-journal` open/mode policy with a small migration
// and append/read API used by session/worktree consumers.
//
// Isolation invariant: the raw `SQLiteConnection` never leaves this actor.
// Public APIs are typed journal operations only.

import Foundation
import OpenGrokFileUtils

/// A single schema migration step.
public struct SchemaMigration: Sendable, Equatable {
    /// Target schema version after this migration (monotonic, starting at 1).
    public let version: Int
    /// SQL statements applied inside a transaction to reach `version`.
    public let sql: [String]
    /// Optional human label for diagnostics (never secrets).
    public let label: String

    public init(version: Int, sql: [String], label: String = "") {
        precondition(version >= 1)
        self.version = version
        self.sql = sql
        self.label = label
    }
}

/// A durable journal record with forward-compatible payload bytes.
///
/// Unknown fields in the payload blob are preserved as opaque `Data` so
/// readers that do not understand them still round-trip bytes unchanged.
public struct JournalRecord: Sendable, Equatable {
    public var id: Int64
    public var kind: String
    public var payload: Data
    public var createdAt: Date

    public init(id: Int64 = 0, kind: String, payload: Data, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.payload = payload
        self.createdAt = createdAt
    }
}

/// Actor-isolated SQLite journal.
///
/// - Uses `JournalMode.forDBPath` + `effectiveDBPath` at open.
/// - Applies ordered migrations transactionally with version-boundary checks.
/// - Appends records so interrupted transactions never expose partial rows.
public actor SQLiteJournal {
    private var connection: SQLiteConnection
    public nonisolated let logicalPath: URL
    public nonisolated let effectivePath: URL
    public nonisolated let mode: JournalMode
    /// Highest schema version this open understands (max of migration plan).
    public nonisolated let supportedSchemaVersion: Int

    /// Open (or create) a read-write journal.
    public init(
        path: URL,
        migrations: [SchemaMigration] = SQLiteJournal.defaultMigrations,
        modeOverride: JournalMode? = nil
    ) throws {
        let validated = try Self.validateMigrationPlan(migrations)
        let mode = modeOverride ?? JournalMode.forDBPath(path)
        let effective = mode.effectiveDBPath(path)
        try FileManager.default.createDirectory(
            at: effective.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let conn = try SQLiteConnection(path: effective, mode: mode, readOnly: false)
        self.connection = conn
        self.logicalPath = path
        self.effectivePath = effective
        self.mode = mode
        self.supportedSchemaVersion = validated.last?.version ?? 0
        try Self.bootstrapAndMigrate(conn, migrations: validated)
    }

    /// Open an existing journal read-only. Errors if the DB file is missing
    /// (never creates it) — matching Rust `open_readonly`.
    ///
    /// Rejects databases whose `user_version` is newer than `supportedVersion`
    /// (defaults to `defaultMigrations` max) so future-schema files fail closed.
    public init(
        readOnlyPath path: URL,
        modeOverride: JournalMode? = nil,
        supportedVersion: Int = SQLiteJournal.defaultSupportedSchemaVersion
    ) throws {
        let mode = modeOverride ?? JournalMode.forDBPath(path)
        let effective = mode.effectiveDBPath(path)
        guard FileManager.default.fileExists(atPath: effective.path) else {
            throw SQLiteJournalError.notFound(effective.path)
        }
        let conn = try SQLiteConnection(path: effective, mode: mode, readOnly: true)
        self.connection = conn
        self.logicalPath = path
        self.effectivePath = effective
        self.mode = mode
        self.supportedSchemaVersion = supportedVersion
        let found = Int(try conn.queryInt64("PRAGMA user_version") ?? 0)
        if found > supportedVersion {
            conn.close()
            throw SQLiteJournalError.unsupportedSchemaVersion(
                found: found,
                supported: supportedVersion
            )
        }
    }

    /// Current schema version (`PRAGMA user_version`).
    public func schemaVersion() throws -> Int {
        Int(try connection.queryInt64("PRAGMA user_version") ?? 0)
    }

    /// Current journal mode string.
    public func journalMode() throws -> String {
        try connection.journalMode()
    }

    /// Append a record transactionally. Returns the new row id.
    public func append(_ record: JournalRecord) throws -> Int64 {
        try Task.checkCancellation()
        // payload stored as BLOB via base64 text for portability without
        // binding helpers; unknown fields live inside the opaque payload.
        let payloadB64 = record.payload.base64EncodedString()
        let ts = String(record.createdAt.timeIntervalSince1970)
        return try connection.transaction { conn in
            try conn.execute(
                """
                INSERT INTO ogrok_journal (kind, payload_b64, created_at)
                VALUES (?, ?, ?)
                """,
                textBinds: [record.kind, payloadB64, ts]
            )
            let id = try conn.queryInt64("SELECT last_insert_rowid()") ?? 0
            return id
        }
    }

    /// Read all records ordered by id (stable).
    public func readAll() throws -> [JournalRecord] {
        try Task.checkCancellation()
        let rows = try connection.queryRows(
            "SELECT id, kind, payload_b64, created_at FROM ogrok_journal ORDER BY id ASC"
        )
        return try rows.compactMap { row in
            guard row.count >= 4,
                  let idStr = row[0], let id = Int64(idStr),
                  let kind = row[1],
                  let b64 = row[2],
                  let tsStr = row[3], let ts = Double(tsStr)
            else {
                throw SQLiteJournalError.corrupt("malformed journal row")
            }
            guard let payload = Data(base64Encoded: b64) else {
                throw SQLiteJournalError.corrupt("invalid payload encoding")
            }
            return JournalRecord(
                id: id,
                kind: kind,
                payload: payload,
                createdAt: Date(timeIntervalSince1970: ts)
            )
        }
    }

    /// Count records.
    public func count() throws -> Int {
        Int(try connection.queryInt64("SELECT COUNT(*) FROM ogrok_journal") ?? 0)
    }

    /// Run a unit of work that must commit or fully roll back.
    ///
    /// The body does **not** receive the raw connection — only opaque
    /// operations that stay on this actor — so the SQLite handle cannot escape.
    public func withRollbackBarrier<T: Sendable>(
        _ body: @Sendable () throws -> T
    ) throws -> T {
        try Task.checkCancellation()
        try connection.beginImmediate()
        do {
            let value = try body()
            try connection.commit()
            return value
        } catch {
            try? connection.rollback()
            throw error
        }
    }

    /// Force a failed transaction (test/recovery helper). Inserts nothing durable.
    public func appendThenFail(_ record: JournalRecord, reason: String) throws {
        try Task.checkCancellation()
        let payloadB64 = record.payload.base64EncodedString()
        let ts = String(record.createdAt.timeIntervalSince1970)
        try connection.transaction { conn in
            try conn.execute(
                """
                INSERT INTO ogrok_journal (kind, payload_b64, created_at)
                VALUES (?, ?, ?)
                """,
                textBinds: [record.kind, payloadB64, ts]
            )
            throw SQLiteJournalError.schema(reason)
        }
    }

    /// Close the underlying connection.
    public func close() {
        connection.close()
    }

    // MARK: - Bootstrap

    /// Highest version in `defaultMigrations`.
    public static let defaultSupportedSchemaVersion: Int = 1

    /// Default migrations establishing the journal table at v1.
    ///
    /// Schema is intentionally simple and portable:
    /// `ogrok_journal(id, kind, payload_b64, created_at)`.
    /// Payload bytes are opaque so unknown fields survive round-trips.
    public static let defaultMigrations: [SchemaMigration] = [
        SchemaMigration(
            version: 1,
            sql: [
                """
                CREATE TABLE IF NOT EXISTS ogrok_journal (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    kind TEXT NOT NULL,
                    payload_b64 TEXT NOT NULL,
                    created_at TEXT NOT NULL
                )
                """,
                "CREATE INDEX IF NOT EXISTS idx_ogrok_journal_kind ON ogrok_journal(kind)",
            ],
            label: "create ogrok_journal"
        ),
    ]

    /// Validate a migration plan: versions start at 1, strictly increasing by 1,
    /// no duplicates or gaps.
    public static func validateMigrationPlan(
        _ migrations: [SchemaMigration]
    ) throws -> [SchemaMigration] {
        let sorted = migrations.sorted { $0.version < $1.version }
        var seen = Set<Int>()
        var expected = 1
        for m in sorted {
            if seen.contains(m.version) {
                throw SQLiteJournalError.schema(
                    "duplicate migration version \(m.version)"
                )
            }
            seen.insert(m.version)
            if m.version != expected {
                throw SQLiteJournalError.schema(
                    "non-contiguous migration versions: expected \(expected), found \(m.version)"
                )
            }
            expected = m.version + 1
        }
        return sorted
    }

    private static func bootstrapAndMigrate(
        _ conn: SQLiteConnection,
        migrations: [SchemaMigration]
    ) throws {
        let maxSupported = migrations.last?.version ?? 0
        let current = Int(try conn.queryInt64("PRAGMA user_version") ?? 0)
        if current > maxSupported {
            throw SQLiteJournalError.unsupportedSchemaVersion(
                found: current,
                supported: maxSupported
            )
        }
        var version = current
        for migration in migrations where migration.version > version {
            try conn.transaction { c in
                for stmt in migration.sql {
                    try c.exec(stmt)
                }
                try c.exec("PRAGMA user_version = \(migration.version)")
            }
            version = migration.version
        }
    }
}

// MARK: - Internal factory matching Rust JournalMode::open
//
// Visible to tests via `@testable`. Not part of the public surface so the
// raw connection cannot be obtained by external modules.

extension JournalMode {
    /// Open (or create) a read-write connection with this journal mode at
    /// `effectiveDBPath`, 5s busy timeout, mode applied.
    func open(_ dbPath: URL) throws -> SQLiteConnection {
        let effective = effectiveDBPath(dbPath)
        try FileManager.default.createDirectory(
            at: effective.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try SQLiteConnection(path: effective, mode: self, readOnly: false)
    }

    /// Open read-only (never creates). See Rust `open_readonly`.
    func openReadonly(_ dbPath: URL) throws -> SQLiteConnection {
        let effective = effectiveDBPath(dbPath)
        guard FileManager.default.fileExists(atPath: effective.path) else {
            throw SQLiteJournalError.notFound(effective.path)
        }
        return try SQLiteConnection(path: effective, mode: self, readOnly: true)
    }
}
