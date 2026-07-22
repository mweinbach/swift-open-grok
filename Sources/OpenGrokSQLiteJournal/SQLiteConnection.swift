// SQLiteConnection.swift
//
// Thin, actor-owned SQLite3 connection wrapper. Intentionally **internal** —
// the raw handle must never escape `SQLiteJournal` isolation. System SQLite
// is used on Apple platforms and Linux when available.

import Foundation

#if canImport(SQLite3)
import SQLite3
#endif

/// SQLite errors with redacted details (never include SQL parameter secrets).
public enum SQLiteJournalError: Error, Equatable, Sendable, CustomStringConvertible {
    case unavailable(String)
    case openFailed(path: String, code: Int32, message: String)
    case execFailed(code: Int32, message: String)
    case busy(String)
    case notFound(String)
    case schema(String)
    case cancelled
    case corrupt(String)
    /// Database `user_version` is newer than this binary's migration plan.
    case unsupportedSchemaVersion(found: Int, supported: Int)

    public var description: String {
        switch self {
        case .unavailable(let d): return "sqlite unavailable: \(d)"
        case .openFailed(let path, let code, let message):
            return "sqlite open failed \(path) (\(code)): \(message)"
        case .execFailed(let code, let message):
            return "sqlite exec failed (\(code)): \(message)"
        case .busy(let d): return "sqlite busy: \(d)"
        case .notFound(let d): return "sqlite not found: \(d)"
        case .schema(let d): return "sqlite schema: \(d)"
        case .cancelled: return "sqlite operation cancelled"
        case .corrupt(let d): return "sqlite corrupt: \(d)"
        case .unsupportedSchemaVersion(let found, let supported):
            return "sqlite unsupported schema version \(found) (supported \(supported))"
        }
    }
}

/// A single SQLite connection. **Not** `Sendable` and not thread-safe.
/// Owned exclusively by `SQLiteJournal` (or short-lived test helpers via
/// `@testable`); never retain or use outside actor isolation.
final class SQLiteConnection {
    #if canImport(SQLite3)
    private var db: OpaquePointer?
    #endif
    let path: URL
    let mode: JournalMode
    private(set) var isReadOnly: Bool

    /// Busy timeout applied at open (matches Rust 5s).
    static let busyTimeoutMilliseconds: Int32 = 5000

    init(path: URL, mode: JournalMode, readOnly: Bool) throws {
        self.path = path
        self.mode = mode
        self.isReadOnly = readOnly
        #if canImport(SQLite3)
        var flags: Int32 = SQLITE_OPEN_NOMUTEX
        if readOnly {
            if mode == .truncate {
                // Network arm needs a writable fd for conversion (no CREATE).
                flags |= SQLITE_OPEN_READWRITE
            } else {
                flags |= SQLITE_OPEN_READONLY
            }
        } else {
            flags |= SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        }
        var ptr: OpaquePointer?
        let rc = path.path.withCString { cPath in
            sqlite3_open_v2(cPath, &ptr, flags, nil)
        }
        guard rc == SQLITE_OK, let ptr else {
            let msg = ptr.map { String(cString: sqlite3_errmsg($0)) } ?? "null db"
            if let ptr { sqlite3_close(ptr) }
            throw SQLiteJournalError.openFailed(path: path.path, code: rc, message: msg)
        }
        self.db = ptr
        try setBusyTimeout(Self.busyTimeoutMilliseconds)

        // Match Rust `JournalMode::open` / `open_readonly` branching exactly:
        //  * read-write: always apply journal mode
        //  * WAL read-only: open read-only, set busy timeout, do NOT apply
        //    PRAGMA journal_mode (would fail / mutate on a read-only open)
        //  * TRUNCATE read-only: open read-write (no CREATE), apply conversion,
        //    then set query_only
        if readOnly {
            if mode == .truncate {
                try applyJournalMode()
                try exec("PRAGMA query_only = 1")
                self.isReadOnly = true
            }
            // WAL read-only: no apply.
        } else {
            try applyJournalMode()
        }
        #else
        throw SQLiteJournalError.unavailable(
            "SQLite3 module not available on this platform; link system sqlite3"
        )
        #endif
    }

    deinit {
        close()
    }

    func close() {
        #if canImport(SQLite3)
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
        #endif
    }

    /// Apply this connection's journal mode (see Rust `JournalMode::apply`).
    func applyJournalMode() throws {
        #if canImport(SQLite3)
        switch mode {
        case .wal:
            try pragmaUpdate("journal_mode", value: "WAL")
        case .truncate:
            // EXCLUSIVE locking keeps the wal-index in heap during conversion.
            try pragmaUpdate("locking_mode", value: "EXCLUSIVE")
            try pragmaUpdate("journal_mode", value: "TRUNCATE")
            try pragmaUpdate("locking_mode", value: "NORMAL")
        }
        #endif
    }

    /// Run SQL that does not return rows.
    func exec(_ sql: String) throws {
        #if canImport(SQLite3)
        guard let db else {
            throw SQLiteJournalError.unavailable("connection closed")
        }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let message = errMsg.map { String(cString: $0) } ?? sqliteErrorMessage()
            if let errMsg { sqlite3_free(errMsg) }
            if rc == SQLITE_BUSY || rc == SQLITE_LOCKED {
                throw SQLiteJournalError.busy(message)
            }
            if rc == SQLITE_CORRUPT {
                throw SQLiteJournalError.corrupt(message)
            }
            throw SQLiteJournalError.execFailed(code: rc, message: message)
        }
        #else
        throw SQLiteJournalError.unavailable("SQLite3 not linked")
        #endif
    }

    /// Query a single string column from the first row.
    func queryString(_ sql: String) throws -> String? {
        #if canImport(SQLite3)
        guard let db else {
            throw SQLiteJournalError.unavailable("connection closed")
        }
        var stmt: OpaquePointer?
        let prep = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prep == SQLITE_OK, let stmt else {
            throw SQLiteJournalError.execFailed(code: prep, message: sqliteErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }
        let step = sqlite3_step(stmt)
        if step == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                return String(cString: c)
            }
            return nil
        }
        if step == SQLITE_DONE { return nil }
        if step == SQLITE_BUSY || step == SQLITE_LOCKED {
            throw SQLiteJournalError.busy(sqliteErrorMessage())
        }
        throw SQLiteJournalError.execFailed(code: step, message: sqliteErrorMessage())
        #else
        throw SQLiteJournalError.unavailable("SQLite3 not linked")
        #endif
    }

    /// Query a single Int64 column from the first row.
    func queryInt64(_ sql: String) throws -> Int64? {
        #if canImport(SQLite3)
        guard let db else {
            throw SQLiteJournalError.unavailable("connection closed")
        }
        var stmt: OpaquePointer?
        let prep = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prep == SQLITE_OK, let stmt else {
            throw SQLiteJournalError.execFailed(code: prep, message: sqliteErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }
        let step = sqlite3_step(stmt)
        if step == SQLITE_ROW {
            return sqlite3_column_int64(stmt, 0)
        }
        if step == SQLITE_DONE { return nil }
        if step == SQLITE_BUSY || step == SQLITE_LOCKED {
            throw SQLiteJournalError.busy(sqliteErrorMessage())
        }
        throw SQLiteJournalError.execFailed(code: step, message: sqliteErrorMessage())
        #else
        throw SQLiteJournalError.unavailable("SQLite3 not linked")
        #endif
    }

    /// Current `PRAGMA journal_mode` (lowercase).
    func journalMode() throws -> String {
        let v = try queryString("PRAGMA journal_mode") ?? ""
        return v.lowercased()
    }

    /// Begin an immediate transaction.
    func beginImmediate() throws {
        try exec("BEGIN IMMEDIATE")
    }

    func commit() throws {
        try exec("COMMIT")
    }

    func rollback() throws {
        try exec("ROLLBACK")
    }

    /// Run `body` inside a transaction; rolls back on throw.
    /// The connection reference must not escape the non-escaping closure.
    func transaction<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        try beginImmediate()
        do {
            let value = try body(self)
            try commit()
            return value
        } catch {
            try? rollback()
            throw error
        }
    }

    /// Execute a parameterized INSERT/UPDATE with text binds.
    func execute(_ sql: String, textBinds: [String]) throws {
        #if canImport(SQLite3)
        guard let db else {
            throw SQLiteJournalError.unavailable("connection closed")
        }
        var stmt: OpaquePointer?
        let prep = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prep == SQLITE_OK, let stmt else {
            throw SQLiteJournalError.execFailed(code: prep, message: sqliteErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }
        for (i, text) in textBinds.enumerated() {
            let rc = sqlite3_bind_text(
                stmt,
                Int32(i + 1),
                text,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
            if rc != SQLITE_OK {
                throw SQLiteJournalError.execFailed(code: rc, message: sqliteErrorMessage())
            }
        }
        let step = sqlite3_step(stmt)
        if step != SQLITE_DONE {
            if step == SQLITE_BUSY || step == SQLITE_LOCKED {
                throw SQLiteJournalError.busy(sqliteErrorMessage())
            }
            throw SQLiteJournalError.execFailed(code: step, message: sqliteErrorMessage())
        }
        #else
        throw SQLiteJournalError.unavailable("SQLite3 not linked")
        #endif
    }

    /// Query all rows as arrays of optional strings (simple result set).
    func queryRows(_ sql: String, textBinds: [String] = []) throws -> [[String?]] {
        #if canImport(SQLite3)
        guard let db else {
            throw SQLiteJournalError.unavailable("connection closed")
        }
        var stmt: OpaquePointer?
        let prep = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prep == SQLITE_OK, let stmt else {
            throw SQLiteJournalError.execFailed(code: prep, message: sqliteErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }
        for (i, text) in textBinds.enumerated() {
            let rc = sqlite3_bind_text(
                stmt,
                Int32(i + 1),
                text,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
            if rc != SQLITE_OK {
                throw SQLiteJournalError.execFailed(code: rc, message: sqliteErrorMessage())
            }
        }
        var rows: [[String?]] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW {
                let cols = sqlite3_column_count(stmt)
                var row: [String?] = []
                for c in 0..<cols {
                    if sqlite3_column_type(stmt, c) == SQLITE_NULL {
                        row.append(nil)
                    } else if let p = sqlite3_column_text(stmt, c) {
                        row.append(String(cString: p))
                    } else {
                        row.append(nil)
                    }
                }
                rows.append(row)
            } else if step == SQLITE_DONE {
                break
            } else if step == SQLITE_BUSY || step == SQLITE_LOCKED {
                throw SQLiteJournalError.busy(sqliteErrorMessage())
            } else {
                throw SQLiteJournalError.execFailed(code: step, message: sqliteErrorMessage())
            }
        }
        return rows
        #else
        throw SQLiteJournalError.unavailable("SQLite3 not linked")
        #endif
    }

    #if canImport(SQLite3)
    private func setBusyTimeout(_ ms: Int32) throws {
        guard let db else { return }
        let rc = sqlite3_busy_timeout(db, ms)
        if rc != SQLITE_OK {
            throw SQLiteJournalError.execFailed(code: rc, message: sqliteErrorMessage())
        }
    }

    private func pragmaUpdate(_ key: String, value: String) throws {
        // journal_mode returns a row; use query for it, exec for others.
        if key == "journal_mode" {
            _ = try queryString("PRAGMA \(key) = \(value)")
        } else {
            try exec("PRAGMA \(key) = \(value)")
        }
    }

    private func sqliteErrorMessage() -> String {
        guard let db else { return "closed" }
        return String(cString: sqlite3_errmsg(db))
    }
    #endif
}
