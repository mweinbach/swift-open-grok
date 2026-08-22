import Dispatch
import Foundation
import Testing
@testable import OpenGrokSQLiteJournal

@Suite("SQLite journal contention retry parity")
struct SQLiteBusyRetryParityTests {
    @Test("public retry timings match the upstream SQLite journal wire fixture")
    func retryPolicyConstants() {
        #expect(JournalMode.busyTimeoutMilliseconds == 5_000)
        #expect(JournalMode.busyRetryBudgetMilliseconds == 10_000)
        #expect(JournalMode.busyRetryPauseMilliseconds == 20)
        #expect(JournalMode.maxBusyAttemptMilliseconds == 1_000)
    }

    @Test("busy, locked, and extended lock codes retry under one shared deadline")
    func retriesSQLiteBusyAndLockedCodes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = try JournalMode.wal.open(directory.appendingPathComponent("retry.sqlite"))
        defer { connection.close() }
        let deadline = DispatchTime.now() + .milliseconds(500)
        var attempts = 0
        var attemptTimeouts: [Int64] = []

        try connection.applyJournalModeWithRetry(until: deadline) {
            let timeout = try #require(try connection.queryInt64("PRAGMA busy_timeout"))
            attemptTimeouts.append(timeout)
            attempts += 1
            switch attempts {
            case 1:
                throw SQLiteJournalError.busy("busy handler reported contention")
            case 2:
                throw SQLiteJournalError.execFailed(code: 6, message: "SQLITE_LOCKED")
            case 3:
                throw SQLiteJournalError.execFailed(code: 517, message: "SQLITE_BUSY_SNAPSHOT")
            case 4:
                throw SQLiteJournalError.execFailed(code: 262, message: "SQLITE_LOCKED_SHAREDCACHE")
            default:
                break
            }
        }

        #expect(attempts == 5)
        #expect(attemptTimeouts.count == attempts)
        #expect(attemptTimeouts.allSatisfy { $0 >= 20 && $0 <= 500 })
        #expect((attemptTimeouts.first ?? 0) >= (attemptTimeouts.last ?? 0))
        #expect(try connection.queryInt64("PRAGMA busy_timeout") == 5_000)
    }

    @Test("individual SQLite waits clamp to the upstream 20ms floor and 1s ceiling")
    func busyHandlerAttemptBounds() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = try JournalMode.wal.open(directory.appendingPathComponent("clamp.sqlite"))
        defer { connection.close() }
        var longBudgetTimeout: Int64?
        var exhaustedBudgetTimeout: Int64?

        try connection.applyJournalModeWithRetry(
            until: .now() + .seconds(10)
        ) {
            longBudgetTimeout = try connection.queryInt64("PRAGMA busy_timeout")
        }
        try connection.applyJournalModeWithRetry(until: .now()) {
            exhaustedBudgetTimeout = try connection.queryInt64("PRAGMA busy_timeout")
        }

        #expect(longBudgetTimeout == 1_000)
        #expect(exhaustedBudgetTimeout == 20)
        #expect(try connection.queryInt64("PRAGMA busy_timeout") == 5_000)
    }

    @Test("expired retry budget preserves the original busy error and restores 5s")
    func sharedDeadlineBoundsBusyFailure() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = try JournalMode.wal.open(directory.appendingPathComponent("timeout.sqlite"))
        defer { connection.close() }
        let started = DispatchTime.now()
        let deadline = started + .milliseconds(110)
        var attempts = 0

        do {
            try connection.applyJournalModeWithRetry(until: deadline) {
                attempts += 1
                throw SQLiteJournalError.busy("peer retained an exclusive lock")
            }
            Issue.record("persistent SQLite contention must exhaust the caller's deadline")
        } catch SQLiteJournalError.busy(let message) {
            #expect(message.contains("failed to set journal mode WAL after"))
            #expect(message.contains("peer retained an exclusive lock"))
        }

        let elapsed = elapsedNanoseconds(since: started)
        #expect(attempts >= 2)
        #expect(elapsed >= 40_000_000)
        #expect(elapsed < 1_000_000_000)
        #expect(try connection.queryInt64("PRAGMA busy_timeout") == 5_000)
    }

    @Test("non-lock SQLite failures are not retried and retain their original type")
    func nonRetryableFailureShortCircuits() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = try JournalMode.wal.open(directory.appendingPathComponent("corrupt.sqlite"))
        defer { connection.close() }
        var attempts = 0

        do {
            try connection.applyJournalModeWithRetry(
                until: .now() + .seconds(10)
            ) {
                attempts += 1
                throw SQLiteJournalError.corrupt("malformed database page")
            }
            Issue.record("database corruption must not be retried as lock contention")
        } catch SQLiteJournalError.corrupt(let message) {
            #expect(message == "malformed database page")
        }

        #expect(attempts == 1)
        #expect(try connection.queryInt64("PRAGMA busy_timeout") == 5_000)
    }

    @Test("read-write open survives a real exclusive lock released by another actor")
    func realExclusiveContentionEventuallySucceeds() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("exclusive.sqlite")
        let holder = SQLiteExclusiveLockHolder()
        try await holder.acquire(at: path)

        let release = Task {
            try await Task.sleep(nanoseconds: 150_000_000)
            await holder.release()
        }
        let started = DispatchTime.now()
        let connection = try SQLiteConnection(
            path: path,
            mode: .wal,
            readOnly: false,
            deadline: started + .seconds(2)
        )
        #expect(elapsedNanoseconds(since: started) >= 80_000_000)
        #expect(try connection.journalMode() == "wal")
        #expect(try connection.queryInt64("PRAGMA busy_timeout") == 5_000)
        #expect(try connection.queryInt64("SELECT count(*) FROM contention_holder") == 1)
        connection.close()
        try await release.value
    }

    @Test("read-only TRUNCATE conversion obeys an existing caller deadline without stacking")
    func readonlyConversionSharesCallerDeadline() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logical = directory.appendingPathComponent("readonly.sqlite")
        let effective = JournalMode.truncate.effectiveDBPath(logical)
        let holder = SQLiteExclusiveLockHolder()
        try await holder.acquire(at: effective)
        let started = DispatchTime.now()
        let deadline = started + .milliseconds(140)

        do {
            let connection = try JournalMode.truncate.openReadonly(logical, until: deadline)
            connection.close()
            Issue.record("exclusive owner should prevent read-only journal-mode conversion")
        } catch SQLiteJournalError.busy(let message) {
            #expect(message.contains("TRUNCATE"))
        } catch SQLiteJournalError.execFailed(let code, let message) {
            #expect((code & 0xff) == 5 || (code & 0xff) == 6)
            #expect(message.contains("TRUNCATE"))
        }

        #expect(elapsedNanoseconds(since: started) < 1_000_000_000)
        await holder.release()

        let reopened = try JournalMode.truncate.openReadonly(logical)
        defer { reopened.close() }
        #expect(try reopened.journalMode() == "truncate")
        #expect(try reopened.queryInt64("PRAGMA busy_timeout") == 5_000)
        #expect(try reopened.queryInt64("PRAGMA query_only") == 1)
    }

    @Test("cancelled callers fail before opening or creating a SQLite database")
    func cancellationFailsClosed() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("cancelled.sqlite")
        let operation = Task<SQLiteJournalError?, Never> {
            while !Task.isCancelled {
                await Task.yield()
            }
            do {
                let connection = try SQLiteConnection(path: path, mode: .wal, readOnly: false)
                connection.close()
                return nil
            } catch let error as SQLiteJournalError {
                return error
            } catch {
                return .schema("unexpected cancellation error: \(error)")
            }
        }
        operation.cancel()

        #expect(await operation.value == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "open-grok-sqlite-busy-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func elapsedNanoseconds(since started: DispatchTime) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        return now >= started.uptimeNanoseconds ? now - started.uptimeNanoseconds : 0
    }
}

private actor SQLiteExclusiveLockHolder {
    private var connection: SQLiteConnection?

    func acquire(at path: URL) throws {
        let opened = try SQLiteConnection(path: path, mode: .truncate, readOnly: false)
        try opened.exec("PRAGMA locking_mode = EXCLUSIVE")
        try opened.exec(
            """
            CREATE TABLE IF NOT EXISTS contention_holder (value TEXT);
            INSERT INTO contention_holder VALUES ('held');
            """
        )
        connection = opened
    }

    func release() {
        connection?.close()
        connection = nil
    }
}
