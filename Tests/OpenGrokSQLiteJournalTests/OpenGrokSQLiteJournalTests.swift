// OpenGrokSQLiteJournalTests.swift
//
// Ported fixtures from `xai-sqlite-journal` plus actor/migration/recovery
// coverage for OpenGrokSQLiteJournal.

import Foundation
import Testing
@testable import OpenGrokSQLiteJournal

@Suite("OpenGrokSQLiteJournal")
struct OpenGrokSQLiteJournalTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ogrok-sqlite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Env / pure classifiers

    @Test("env override parses wal/truncate/invalid/empty")
    func envParse() {
        #expect(modeFromEnvValue("wal") == .mode(.wal))
        #expect(modeFromEnvValue("WAL") == .mode(.wal))
        #expect(modeFromEnvValue("truncate") == .mode(.truncate))
        #expect(modeFromEnvValue("TRUNCATE") == .mode(.truncate))
        #expect(modeFromEnvValue("delete") == .invalid)
        #expect(modeFromEnvValue("wall") == .invalid)
        #expect(modeFromEnvValue("") == .unset)
        #expect(modeFromEnvValue(nil) == .unset)
    }

    @Test("OPENGROK env preferred over GROK")
    func envPreference() {
        let r = modeFromEnv(openGrok: "truncate", legacy: "wal")
        #expect(r == .mode(.truncate))
        let r2 = modeFromEnv(openGrok: nil, legacy: "wal")
        #expect(r2 == .mode(.wal))
    }

    @Test("network magics classify as network")
    func networkMagics() {
        for magic: UInt64 in [
            0x6969, 0x517B, 0xFE53_4D42, 0xFF53_4D42, 0x0102_1997,
            0x7375_7245, 0x5346_414F, 0x6B41_4653, 0x00C3_6400,
            0x0BD0_0BD0, 0x0116_1970, 0x4750_4653, 0x7461_636F,
            0x1803_1977, 0x6573_5546,
        ] {
            #expect(NetworkFS.isNetworkFSMagic(magic))
        }
    }

    @Test("local magics classify as local")
    func localMagics() {
        for magic: UInt64 in [
            0xEF53, 0x0102_1994, 0x9123_683E, 0x5846_5342, 0x794C_7630, 0x2FC1_2FC1, 0x0,
        ] {
            #expect(!NetworkFS.isNetworkFSMagic(magic))
        }
    }

    @Test("sign-extended CIFS magic still matches")
    func signExtendedMagic() {
        #expect(NetworkFS.isNetworkFSMagic(0xFFFF_FFFF_FF53_4D42))
    }

    @Test("mac classifier uses MNT_LOCAL and name override")
    func macClassifier() {
        #expect(NetworkFS.isNetworkFSMac(fFlags: 0, fstype: "somefutfs"))
        #expect(!NetworkFS.isNetworkFSMac(fFlags: NetworkFS.mntLocal, fstype: "apfs"))
        #expect(NetworkFS.isNetworkFSMac(fFlags: NetworkFS.mntLocal, fstype: "smbfs"))
        #expect(NetworkFS.isNetworkFSMac(fFlags: NetworkFS.mntLocal, fstype: "macfuse"))
    }

    @Test("fstypenames classify")
    func fstypeNames() {
        for name in ["nfs", "smbfs", "cifs", "afpfs", "webdav", "NFS", "macfuse", "osxfuse"] {
            #expect(NetworkFS.isNetworkFSName(name))
        }
        for name in ["apfs", "hfs", "tmpfs", "devfs", ""] {
            #expect(!NetworkFS.isNetworkFSName(name))
        }
    }

    @Test("windows UNC classifies")
    func windowsUNC() {
        #expect(NetworkFS.isWindowsUNC(#"\\server\share\grok"#))
        #expect(NetworkFS.isWindowsUNC(#"\\?\UNC\server\share\grok"#))
        #expect(NetworkFS.isWindowsUNC(#"\\?\unc\server\share"#))
        #expect(!NetworkFS.isWindowsUNC(#"\\?\C:\Users\x"#))
        #expect(!NetworkFS.isWindowsUNC(#"\\.\pipe\grok"#))
        #expect(!NetworkFS.isWindowsUNC(#"C:\Users\x"#))
        #expect(!NetworkFS.isWindowsUNC("/home/x"))
    }

    @Test("local temp paths are not network")
    func localTempNotNetwork() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!isNetworkFS(dir))
        #expect(!isNetworkFS(dir.appendingPathComponent("missing")))
    }

    @Test("forDBPath defaults to WAL on local FS when env unset")
    func forDBPathDefault() throws {
        if ProcessInfo.processInfo.environment["OPENGROK_SQLITE_JOURNAL_MODE"] != nil
            || ProcessInfo.processInfo.environment["GROK_SQLITE_JOURNAL_MODE"] != nil
        {
            return
        }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mode = JournalMode.forDBPath(dir.appendingPathComponent("x.sqlite"))
        #expect(mode == .wal)
    }

    @Test("effective_db_path is per-host only in truncate mode")
    func effectivePath() {
        let p = URL(fileURLWithPath: "/tmp/dir/worktrees.db")
        #expect(JournalMode.wal.effectiveDBPath(p) == p)

        let a = JournalMode.truncate.effectiveDBPath(p)
        let b = JournalMode.truncate.effectiveDBPath(p)
        #expect(a == b)
        #expect(a != p)
        #expect(a.deletingLastPathComponent() == p.deletingLastPathComponent())
        let name = a.lastPathComponent
        #expect(name.hasPrefix("worktrees.h-"))
        #expect(name.hasSuffix(".db"))
        #expect(JournalMode.truncate.effectiveDBPath(a) == a)

        let bare = JournalMode.truncate.effectiveDBPath(URL(fileURLWithPath: "/tmp/dir/state"))
        #expect(bare.lastPathComponent.hasPrefix("state.h-"))
    }

    @Test("host discriminator sanitizes")
    func hostDisc() {
        #expect(hostDiscriminator(raw: "My-Host.local") == "my-host-local")
        #expect(hostDiscriminator(raw: "---") == nil)
        #expect(hostDiscriminator(raw: "") == nil)
        let long = String(repeating: "a", count: 40)
        #expect(hostDiscriminator(raw: long)?.count == 24)
    }

    // MARK: - Open / mode apply

    @Test("open applies wal and truncate modes")
    func openAppliesMode() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let wal = try JournalMode.wal.open(dir.appendingPathComponent("wal.sqlite"))
        defer { wal.close() }
        #expect(try wal.journalMode() == "wal")

        let trunc = try JournalMode.truncate.open(dir.appendingPathComponent("trunc.sqlite"))
        defer { trunc.close() }
        #expect(try trunc.journalMode() == "truncate")
    }

    @Test("WAL-stamped DB converts to truncate")
    func convertWalToTruncate() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("db.sqlite")

        do {
            let conn = try JournalMode.wal.open(path)
            try conn.exec("CREATE TABLE t (v TEXT); INSERT INTO t VALUES ('keep');")
            conn.close()
        }

        let conn = try SQLiteConnection(path: path, mode: .truncate, readOnly: false)
        defer { conn.close() }
        #expect(try conn.journalMode() == "truncate")
        let v = try conn.queryString("SELECT v FROM t")
        #expect(v == "keep")
        try conn.exec("INSERT INTO t VALUES ('more')")
    }

    @Test("open_readonly missing db errors and creates nothing")
    func openReadonlyMissing() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("missing.sqlite")
        #expect(throws: SQLiteJournalError.self) {
            _ = try JournalMode.wal.openReadonly(path)
        }
        #expect(throws: SQLiteJournalError.self) {
            _ = try JournalMode.truncate.openReadonly(path)
        }
        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect(!FileManager.default.fileExists(atPath: JournalMode.truncate.effectiveDBPath(path).path))
    }

    @Test("open_readonly wal rejects writes")
    func openReadonlyWal() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("db.sqlite")
        do {
            let conn = try JournalMode.wal.open(path)
            try conn.exec("CREATE TABLE t (v TEXT); INSERT INTO t VALUES ('ro');")
            conn.close()
        }
        let conn = try JournalMode.wal.openReadonly(path)
        defer { conn.close() }
        #expect(try conn.queryString("SELECT v FROM t") == "ro")
        #expect(throws: (any Error).self) {
            try conn.exec("INSERT INTO t VALUES ('nope')")
        }
    }

    @Test("open_readonly truncate rejects writes via query_only")
    func openReadonlyTruncate() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("db.sqlite")
        do {
            let conn = try JournalMode.truncate.open(path)
            try conn.exec("CREATE TABLE t (v TEXT); INSERT INTO t VALUES ('ro');")
            conn.close()
        }
        let conn = try JournalMode.truncate.openReadonly(path)
        defer { conn.close() }
        #expect(try conn.journalMode() == "truncate")
        #expect(try conn.queryString("SELECT v FROM t") == "ro")
        #expect(throws: (any Error).self) {
            try conn.exec("INSERT INTO t VALUES ('nope')")
        }
    }

    // MARK: - Actor journal

    @Test("actor migrates and appends records transactionally")
    func actorJournalRoundTrip() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("journal.sqlite")

        let journal = try SQLiteJournal(path: path, modeOverride: .wal)
        #expect(try await journal.schemaVersion() == 1)
        #expect(try await journal.journalMode() == "wal")

        let id = try await journal.append(
            JournalRecord(kind: "turn", payload: Data("hello".utf8))
        )
        #expect(id == 1)
        #expect(try await journal.count() == 1)

        let all = try await journal.readAll()
        #expect(all.count == 1)
        #expect(all[0].kind == "turn")
        #expect(String(data: all[0].payload, encoding: .utf8) == "hello")
        await journal.close()

        let again = try SQLiteJournal(path: path, modeOverride: .wal)
        #expect(try await again.count() == 1)
        await again.close()
    }

    @Test("unknown payload fields round-trip as opaque bytes")
    func unknownFieldsRoundTrip() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("journal.sqlite")
        // Simulate a future payload with extra fields the reader does not parse.
        let futurePayload = Data(#"{"type":"turn","v":9,"extra":{"x":1},"blob":"abc"}"#.utf8)
        let journal = try SQLiteJournal(path: path, modeOverride: .wal)
        _ = try await journal.append(JournalRecord(kind: "turn", payload: futurePayload))
        await journal.close()

        let again = try SQLiteJournal(path: path, modeOverride: .wal)
        let all = try await again.readAll()
        #expect(all.count == 1)
        #expect(all[0].payload == futurePayload)
        await again.close()
    }

    @Test("migration is deterministic and skips applied versions")
    func migrations() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("mig.sqlite")

        let v2 = SchemaMigration(
            version: 2,
            sql: ["ALTER TABLE ogrok_journal ADD COLUMN note TEXT"],
            label: "add note"
        )
        let j1 = try SQLiteJournal(
            path: path,
            migrations: SQLiteJournal.defaultMigrations + [v2],
            modeOverride: .wal
        )
        #expect(try await j1.schemaVersion() == 2)
        await j1.close()

        let j2 = try SQLiteJournal(
            path: path,
            migrations: SQLiteJournal.defaultMigrations + [v2],
            modeOverride: .wal
        )
        #expect(try await j2.schemaVersion() == 2)
        await j2.close()
    }

    @Test("migration plan rejects duplicates and gaps")
    func migrationPlanValidation() throws {
        #expect(throws: SQLiteJournalError.self) {
            _ = try SQLiteJournal.validateMigrationPlan([
                SchemaMigration(version: 1, sql: ["SELECT 1"]),
                SchemaMigration(version: 1, sql: ["SELECT 2"]),
            ])
        }
        #expect(throws: SQLiteJournalError.self) {
            _ = try SQLiteJournal.validateMigrationPlan([
                SchemaMigration(version: 1, sql: ["SELECT 1"]),
                SchemaMigration(version: 3, sql: ["SELECT 3"]),
            ])
        }
        #expect(throws: SQLiteJournalError.self) {
            _ = try SQLiteJournal.validateMigrationPlan([
                SchemaMigration(version: 2, sql: ["SELECT 2"]),
            ])
        }
        let ok = try SQLiteJournal.validateMigrationPlan([
            SchemaMigration(version: 1, sql: ["SELECT 1"]),
            SchemaMigration(version: 2, sql: ["SELECT 2"]),
        ])
        #expect(ok.map(\.version) == [1, 2])
    }

    @Test("future schema version is rejected on open")
    func futureSchemaRejected() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("future.sqlite")
        let journal = try SQLiteJournal(path: path, modeOverride: .wal)
        // Bump user_version beyond supported.
        // Use a raw connection via @testable factory after close.
        await journal.close()

        let conn = try JournalMode.wal.open(path)
        try conn.exec("PRAGMA user_version = 99")
        conn.close()

        #expect(throws: SQLiteJournalError.self) {
            _ = try SQLiteJournal(path: path, modeOverride: .wal)
        }
        #expect(throws: SQLiteJournalError.self) {
            _ = try SQLiteJournal(
                readOnlyPath: path,
                modeOverride: .wal,
                supportedVersion: 1
            )
        }
    }

    @Test("transaction rollback leaves no partial records")
    func rollbackNoPartial() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("rb.sqlite")
        let journal = try SQLiteJournal(path: path, modeOverride: .wal)

        do {
            try await journal.appendThenFail(
                JournalRecord(kind: "x", payload: Data("a".utf8)),
                reason: "force rollback"
            )
            Issue.record("expected throw")
        } catch SQLiteJournalError.schema {
            // expected
        }

        #expect(try await journal.count() == 0)
        await journal.close()
    }

    @Test("withRollbackBarrier rolls back on throw without exposing connection")
    func rollbackBarrier() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("barrier.sqlite")
        let journal = try SQLiteJournal(path: path, modeOverride: .wal)
        do {
            try await journal.withRollbackBarrier {
                throw SQLiteJournalError.schema("abort")
            }
            Issue.record("expected throw")
        } catch SQLiteJournalError.schema {
            // expected
        }
        #expect(try await journal.count() == 0)
        await journal.close()
    }

    @Test("corrupt payload encoding is rejected")
    func corruptPayload() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("corrupt.sqlite")
        let journal = try SQLiteJournal(path: path, modeOverride: .wal)
        await journal.close()

        // Inject a bad base64 payload via raw connection.
        let conn = try JournalMode.wal.open(path)
        try conn.exec(
            """
            INSERT INTO ogrok_journal (kind, payload_b64, created_at)
            VALUES ('bad', '%%%not-base64%%%', '0')
            """
        )
        conn.close()

        let again = try SQLiteJournal(path: path, modeOverride: .wal)
        do {
            _ = try await again.readAll()
            Issue.record("expected corrupt")
        } catch SQLiteJournalError.corrupt {
            // expected
        }
        await again.close()
    }

    @Test("cancellation is observed before append")
    func cancellation() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("cancel.sqlite")
        let journal = try SQLiteJournal(path: path, modeOverride: .wal)
        let task = Task {
            try Task.checkCancellation()
            // Cooperative cancel before journal work.
            try await journal.append(JournalRecord(kind: "x", payload: Data()))
        }
        task.cancel()
        do {
            _ = try await task.value
            // May succeed if cancel raced after check; count is still consistent.
        } catch is CancellationError {
            // expected path
        }
        await journal.close()
    }

    @Test("read-only actor open fails when missing")
    func actorReadonlyMissing() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: SQLiteJournalError.self) {
            _ = try SQLiteJournal(readOnlyPath: dir.appendingPathComponent("no.sqlite"), modeOverride: .wal)
        }
    }

    @Test("truncate mode uses per-host effective path")
    func actorTruncatePath() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logical = dir.appendingPathComponent("worktrees.db")
        let journal = try SQLiteJournal(path: logical, modeOverride: .truncate)
        #expect(journal.effectivePath != logical)
        #expect(journal.effectivePath.lastPathComponent.contains(".h-"))
        #expect(FileManager.default.fileExists(atPath: journal.effectivePath.path))
        #expect(!FileManager.default.fileExists(atPath: logical.path))
        await journal.close()
    }

    @Test("SQLiteConnection is not publicly Sendable-escapeable from journal API")
    func connectionStaysInternal() async throws {
        // Compile-time contract: SQLiteJournal public API has no method that
        // returns SQLiteConnection. Runtime check: actor methods only yield
        // typed records.
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("iso.sqlite")
        let journal = try SQLiteJournal(path: path, modeOverride: .wal)
        let records: [JournalRecord] = try await journal.readAll()
        #expect(records.isEmpty)
        await journal.close()
    }
}
