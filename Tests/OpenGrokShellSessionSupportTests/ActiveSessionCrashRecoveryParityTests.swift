import Foundation
import OpenGrokFileUtils
import OpenGrokShared
import Testing
@testable import OpenGrokShellSessionSupport

@Suite("Rust active-session crash recovery parity")
struct ActiveSessionCrashRecoveryParityTests {
    @Test("active-session files use Rust snake-case fields and RFC 3339 timestamps")
    func rustCompatibleWireShape() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let openedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let registry = ActiveSessionRegistry(root: root)

        try await registry.register(
            ActiveSessionRecord(
                sessionID: SessionID("rust-wire"),
                pid: currentProcessID,
                cwd: "/work/project",
                openedAt: openedAt
            )
        )

        let data = try Data(contentsOf: root.appendingPathComponent(ActiveSessionRegistry.dataFileName))
        let records = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let record = try #require(records.first)
        #expect(record["session_id"] as? String == "rust-wire")
        #expect(record["pid"] as? Int == Int(currentProcessID))
        #expect(record["cwd"] as? String == "/work/project")
        #expect(record["opened_at"] as? String == "2023-11-14T22:13:20.000Z")
        #expect(record["sessionID"] == nil)
        #expect(record["openedAt"] == nil)
        #expect(try await registry.list().first?.openedAt == openedAt)
    }

    @Test("legacy camel-case numeric-date files migrate on their next mutation")
    func legacyRegistryMigratesWithoutLosingSessions() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let openedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let legacy = """
        [{"sessionID":"legacy","pid":\(currentProcessID),"cwd":"/legacy","openedAt":\(openedAt.timeIntervalSinceReferenceDate)}]
        """
        try Data(legacy.utf8).write(
            to: root.appendingPathComponent(ActiveSessionRegistry.dataFileName)
        )
        let registry = ActiveSessionRegistry(root: root)

        #expect(try await registry.list().map(\.sessionID.rawValue) == ["legacy"])
        #expect(try await registry.list().first?.openedAt == openedAt)
        try await registry.register(
            ActiveSessionRecord(sessionID: SessionID("fresh"), pid: currentProcessID, cwd: "/fresh")
        )

        let migrated = try String(
            contentsOf: root.appendingPathComponent(ActiveSessionRegistry.dataFileName),
            encoding: .utf8
        )
        #expect(migrated.contains("\"session_id\""))
        #expect(migrated.contains("\"opened_at\""))
        #expect(!migrated.contains("\"sessionID\""))
        #expect(!migrated.contains("\"openedAt\""))
        #expect(try await registry.list().map(\.sessionID.rawValue) == ["fresh", "legacy"])
    }

    @Test("Rust timestamps decode with and without fractional seconds")
    func rustTimestampVariantsDecode() throws {
        for timestamp in ["2026-08-22T12:34:56Z", "2026-08-22T12:34:56.123Z"] {
            let json = """
            [{"session_id":"rust","pid":1,"cwd":"/tmp","opened_at":"\(timestamp)"}]
            """
            let records = try JSONDecoder().decode([ActiveSessionRecord].self, from: Data(json.utf8))
            #expect(records.count == 1)
            #expect(records[0].sessionID == SessionID("rust"))
        }
    }

    @Test("independent registries always reload locked state before writing")
    func independentRegistriesCannotOverwriteOneAnother() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ActiveSessionRegistry(root: root)
        let second = ActiveSessionRegistry(root: root)

        try await first.load()
        try await second.load()
        try await first.register(
            ActiveSessionRecord(sessionID: SessionID("first"), pid: currentProcessID, cwd: "/first")
        )
        try await second.register(
            ActiveSessionRecord(sessionID: SessionID("second"), pid: currentProcessID, cwd: "/second")
        )

        #expect(try await first.list().map(\.sessionID.rawValue) == ["first", "second"])
        #expect(try await second.unregister(sessionID: SessionID("first")))
        #expect(try await first.list().map(\.sessionID.rawValue) == ["second"])
    }

    @Test("parallel independent writers retain every registered session")
    func concurrentIndependentWritersRemainAtomic() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let processID = currentProcessID

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<24 {
                group.addTask {
                    let registry = ActiveSessionRegistry(root: root)
                    try await registry.register(
                        ActiveSessionRecord(
                            sessionID: SessionID("session-\(index)"),
                            pid: processID,
                            cwd: "/work/\(index)"
                        )
                    )
                }
            }
            try await group.waitForAll()
        }

        let records = try await ActiveSessionRegistry(root: root).list()
        #expect(records.count == 24)
        #expect(Set(records.map(\.sessionID.rawValue)).count == 24)
    }

    @Test("nonblocking unregister preserves state when another writer owns the lock")
    func nonblockingUnregisterDoesNotWaitForContention() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ActiveSessionRegistry(root: root)
        let sessionID = SessionID("contended")
        try await registry.register(
            ActiveSessionRecord(sessionID: sessionID, pid: currentProcessID, cwd: "/work")
        )

        let lock = try AdvisoryFileLock.acquire(
            at: root.appendingPathComponent(ActiveSessionRegistry.lockFileName)
        )
        let began = Date()
        #expect(try await registry.tryUnregister(sessionID: sessionID) == false)
        #expect(Date().timeIntervalSince(began) < 1)
        lock.release()

        #expect(try await registry.list().map(\.sessionID.rawValue) == ["contended"])
        #expect(try await registry.tryUnregister(sessionID: sessionID))
        #expect(try await registry.list().isEmpty)
    }

    @Test("real process liveness removes dead entries while retaining the current process")
    func processLivenessCollectsOnlyRealOrphans() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ActiveSessionRegistry(root: root)
        try await registry.register(
            ActiveSessionRecord(sessionID: SessionID("alive"), pid: currentProcessID, cwd: "/alive")
        )
        try await registry.register(
            ActiveSessionRecord(sessionID: SessionID("dead"), pid: 2_000_000_000, cwd: "/dead")
        )
        try await registry.register(
            ActiveSessionRecord(sessionID: SessionID("invalid"), pid: 0, cwd: "/invalid")
        )

        let crashed = try await registry.collectCrashed()
        #expect(crashed.map(\.sessionID.rawValue) == ["dead", "invalid"])
        #expect(try await registry.list().map(\.sessionID.rawValue) == ["alive"])
        #expect(try await registry.collectCrashed().isEmpty)
    }

    @Test("registry root, lock, and durable data are private to their owner")
    func registryPathsAreOwnerOnly() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let registry = ActiveSessionRegistry(root: root)
        try await registry.register(
            ActiveSessionRecord(sessionID: SessionID("private"), pid: currentProcessID, cwd: "/work")
        )

        let lockURL = root.appendingPathComponent(ActiveSessionRegistry.lockFileName)
        let dataURL = root.appendingPathComponent(ActiveSessionRegistry.dataFileName)
        #expect(try SecureFile.isOwnerOnly(at: lockURL))
        #expect(try SecureFile.isOwnerOnly(at: dataURL))

        #if !os(Windows)
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.uint16Value & 0o777 == 0o700)
        #endif
    }

    #if !os(Windows)
    @Test("a symlinked registry root is rejected without touching its target")
    func symlinkedRegistryRootFailsClosed() async throws {
        let parent = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let target = parent.appendingPathComponent("target", isDirectory: true)
        let link = parent.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let registry = ActiveSessionRegistry(root: link)

        await #expect(throws: ShellSessionSupportError.self) {
            try await registry.register(
                ActiveSessionRecord(sessionID: SessionID("hostile"), pid: currentProcessID, cwd: "/work")
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: target.appendingPathComponent(ActiveSessionRegistry.dataFileName).path
        ))
    }
    #endif

    private var currentProcessID: UInt32 {
        UInt32(ProcessInfo.processInfo.processIdentifier)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("active-session-parity-\(UUID().uuidString)", isDirectory: true)
    }
}
