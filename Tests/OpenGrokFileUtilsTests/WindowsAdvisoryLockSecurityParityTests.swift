import Foundation
import Testing
@testable import OpenGrokFileUtils

#if os(Windows)
import COpenGrokSockets
#endif

private struct AdvisoryLockSecurityFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "open-grok-advisory-lock-security-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    var lock: URL {
        directory.appendingPathComponent("managed_config.lock")
    }
}

@Suite("advisory lock owner-private Windows enterprise security")
struct WindowsAdvisoryLockSecurityParityTests {
    @Test("new managed-policy locks are owner-only before acquisition succeeds")
    func newManagedLockIsOwnerPrivate() throws {
        let fixture = try AdvisoryLockSecurityFixture()
        defer { fixture.cleanup() }
        let lock = try AdvisoryFileLock.acquire(at: fixture.lock)
        defer { lock.release() }

        #if os(Windows)
        #expect(fixture.lock.path.withCString { og_file_is_owner_only($0) } == 1)
        #expect(fixture.lock.path.withCString { og_path_is_private_to_current_user($0, 0) } == 1)
        #else
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.lock.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #endif
    }

    @Test("existing inherited lock permissions are tightened without truncating the lock file")
    func existingPermissiveLockBecomesOwnerPrivate() throws {
        let fixture = try AdvisoryLockSecurityFixture()
        defer { fixture.cleanup() }
        try Data("existing-lock-state".utf8).write(to: fixture.lock)

        #if os(Windows)
        #expect(fixture.lock.path.withCString { og_file_is_owner_only($0) } != 1)
        #else
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o666],
            ofItemAtPath: fixture.lock.path
        )
        #endif

        let lock = try AdvisoryFileLock.acquire(at: fixture.lock)
        defer { lock.release() }

        #expect(try String(contentsOf: fixture.lock, encoding: .utf8) == "existing-lock-state")
        #if os(Windows)
        #expect(fixture.lock.path.withCString { og_file_is_owner_only($0) } == 1)
        #expect(fixture.lock.path.withCString { og_path_is_private_to_current_user($0, 0) } == 1)
        #else
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.lock.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #endif
    }

    @Test("owner-only locking preserves nonblocking contention and later reacquisition")
    func ownerPrivateLockContentionRemainsNonblocking() throws {
        let fixture = try AdvisoryLockSecurityFixture()
        defer { fixture.cleanup() }
        let held = try AdvisoryFileLock.acquire(at: fixture.lock)

        #expect(try AdvisoryFileLock.tryAcquire(at: fixture.lock) == nil)
        held.release()

        let reacquired = try #require(try AdvisoryFileLock.tryAcquire(at: fixture.lock))
        reacquired.release()
    }

    #if os(Windows)
    @Test("a held owner-private lock cannot be renamed into an independent second lock")
    func heldOwnerPrivateLockCannotBeReplaced() throws {
        let fixture = try AdvisoryLockSecurityFixture()
        defer { fixture.cleanup() }
        let held = try AdvisoryFileLock.acquire(at: fixture.lock)
        defer { held.release() }
        let renamed = fixture.directory.appendingPathComponent("abandoned.lock")

        do {
            try FileManager.default.moveItem(at: fixture.lock, to: renamed)
            Issue.record("the held lock was renamed, allowing a second independent lock")
        } catch {
            #expect(FileManager.default.fileExists(atPath: fixture.lock.path))
            #expect(!FileManager.default.fileExists(atPath: renamed.path))
        }
        #expect(try AdvisoryFileLock.tryAcquire(at: fixture.lock) == nil)
    }
    #endif

    @Test("opening a missing lock with creation disabled never creates a file")
    func existingOnlyLockRefusesAbsentPath() throws {
        let fixture = try AdvisoryLockSecurityFixture()
        defer { fixture.cleanup() }

        #expect(throws: FileUtilsError.self) {
            try AdvisoryFileLock.acquire(
                at: fixture.lock,
                options: AdvisoryLockOptions(create: false)
            )
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.lock.path))
    }

    @Test("an existing owner-private lock can be opened without create permissions")
    func existingOnlyLockStillOpensAnExistingFile() throws {
        let fixture = try AdvisoryLockSecurityFixture()
        defer { fixture.cleanup() }
        let initial = try AdvisoryFileLock.acquire(at: fixture.lock)
        initial.release()

        let existing = try AdvisoryFileLock.acquire(
            at: fixture.lock,
            options: AdvisoryLockOptions(create: false)
        )
        existing.release()
    }

    @Test("a lock symlink or reparse point never authorizes or rewrites its target")
    func lockReparsePointFailsClosed() throws {
        let fixture = try AdvisoryLockSecurityFixture()
        defer { fixture.cleanup() }
        let target = fixture.directory.appendingPathComponent("private-policy.toml")
        try Data("leave-policy-alone".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: fixture.lock, withDestinationURL: target)

        #expect(throws: FileUtilsError.self) {
            try AdvisoryFileLock.acquire(at: fixture.lock)
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "leave-policy-alone")
    }

    @Test("non-owner-specific lock modes retain their existing acquisition semantics")
    func nonOwnerSpecificModeStillAcquires() throws {
        let fixture = try AdvisoryLockSecurityFixture()
        defer { fixture.cleanup() }
        let lock = try AdvisoryFileLock.acquire(
            at: fixture.lock,
            options: AdvisoryLockOptions(mode: 0o644)
        )
        lock.release()

        #expect(FileManager.default.fileExists(atPath: fixture.lock.path))
        #if !os(Windows)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.lock.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o644)
        #endif
    }
}
