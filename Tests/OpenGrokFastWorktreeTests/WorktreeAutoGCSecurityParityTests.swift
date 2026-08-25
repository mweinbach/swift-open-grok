import Foundation
import Testing
@testable import OpenGrokFastWorktree

@Suite("Worktree auto-GC fail-closed security parity", .serialized)
struct WorktreeAutoGCSecurityParityTests {
    @Test("failed process scans preserve live worktrees and never throttle a safe retry")
    func failedProcessScanDoesNotDeleteOrStamp() throws {
        let fixture = try makeFixture()
        defer { fixture.dispose() }

        let failed = try WorktreeAutoGC.runIfDue(
            registry: fixture.registry,
            policy: fixture.policy,
            protectedPaths: [],
            now: fixture.now,
            processScan: { .failed(.processEnumerationFailed("injected scanner failure")) }
        )

        #expect(failed.candidates == [fixture.recordID])
        #expect(failed.removed.isEmpty)
        #expect(!failed.stamped)
        #expect(failed.failures.contains(where: { $0.contains("injected scanner failure") }))
        #expect(FileManager.default.fileExists(atPath: fixture.worktree.path))
        #expect(try fixture.registry.records().map(\.id) == [fixture.recordID])
        #expect(!FileManager.default.fileExists(
            atPath: fixture.registry.openGrokHome
                .appendingPathComponent("worktrees.meta.json")
                .path
        ))

        var scans = 0
        let retried = try WorktreeAutoGC.runIfDue(
            registry: fixture.registry,
            policy: fixture.policy,
            protectedPaths: [],
            now: fixture.now.addingTimeInterval(1),
            processScan: {
                scans += 1
                return .observed(observations())
            }
        )

        #expect(retried.outcome == .ran)
        #expect(retried.removed == [fixture.recordID])
        #expect(retried.stamped)
        #expect(scans == 2)
        #expect(!FileManager.default.fileExists(atPath: fixture.worktree.path))
    }

    @Test("a matching directory from another PID cannot impersonate the current process")
    func processScanMustObserveCurrentPID() throws {
        let fixture = try makeFixture()
        defer { fixture.dispose() }

        let report = try WorktreeAutoGC.runIfDue(
            registry: fixture.registry,
            policy: fixture.policy,
            protectedPaths: [],
            now: fixture.now,
            processScan: {
                .observed([
                    WorktreeAutoGCProcessObservation(
                        processID: Int32.max,
                        workingDirectory: FileManager.default.currentDirectoryPath
                    ),
                ])
            }
        )

        #expect(report.removed.isEmpty)
        #expect(!report.stamped)
        #expect(report.failures.contains(where: { $0.contains("did not observe this process") }))
        #expect(FileManager.default.fileExists(atPath: fixture.worktree.path))
    }

    @Test("a fresh process scan catches a process entering the stale worktree")
    func freshProcessScanProtectsNewlyActiveWorktree() throws {
        let fixture = try makeFixture()
        defer { fixture.dispose() }
        var scans = 0

        let report = try WorktreeAutoGC.runIfDue(
            registry: fixture.registry,
            policy: fixture.policy,
            protectedPaths: [],
            now: fixture.now,
            processScan: {
                scans += 1
                return .observed(observations(including: scans == 2 ? fixture.worktree : nil))
            }
        )

        #expect(scans == 2)
        #expect(report.removed.isEmpty)
        #expect(report.skippedProtected == [fixture.recordID])
        #expect(FileManager.default.fileExists(atPath: fixture.worktree.path))
        #expect(try fixture.registry.records().map(\.id) == [fixture.recordID])
    }

    @Test("a failed fresh pre-removal process scan preserves the candidate and stamp")
    func failedFreshProcessScanDoesNotDeleteOrStamp() throws {
        let fixture = try makeFixture()
        defer { fixture.dispose() }
        var scans = 0

        let report = try WorktreeAutoGC.runIfDue(
            registry: fixture.registry,
            policy: fixture.policy,
            protectedPaths: [],
            now: fixture.now,
            processScan: {
                scans += 1
                if scans == 2 {
                    return .failed(.processEnumerationTimedOut)
                }
                return .observed(observations())
            }
        )

        #expect(scans == 2)
        #expect(report.removed.isEmpty)
        #expect(!report.stamped)
        #expect(report.failures.contains(where: { $0.contains("timed out") }))
        #expect(FileManager.default.fileExists(atPath: fixture.worktree.path))
    }

    @Test("dirty-state scan errors are never interpreted as a clean worktree")
    func dirtyScanFailureDoesNotDeleteOrStamp() throws {
        let fixture = try makeFixture()
        defer { fixture.dispose() }
        var scans = 0

        let report = try WorktreeAutoGC.runIfDue(
            registry: fixture.registry,
            policy: fixture.policy,
            protectedPaths: [],
            now: fixture.now,
            processScan: {
                scans += 1
                return .observed(observations())
            },
            dirtyScan: { _ in .failure(.dirtyStateUnavailable("injected dirty scan failure")) }
        )

        #expect(scans == 1)
        #expect(report.removed.isEmpty)
        #expect(!report.stamped)
        #expect(report.failures.contains(where: { $0.contains("injected dirty scan failure") }))
        #expect(FileManager.default.fileExists(atPath: fixture.worktree.path))
        #expect(try fixture.registry.records().map(\.id) == [fixture.recordID])
    }

    @Test("a clean registered expired worktree is removed only after two valid scans")
    func cleanStaleWorktreeIsRemovedSafely() throws {
        let fixture = try makeFixture()
        defer { fixture.dispose() }
        var scans = 0

        let report = try WorktreeAutoGC.runIfDue(
            registry: fixture.registry,
            policy: fixture.policy,
            protectedPaths: [],
            now: fixture.now,
            processScan: {
                scans += 1
                return .observed(observations())
            }
        )

        #expect(scans == 2)
        #expect(report.candidates == [fixture.recordID])
        #expect(report.removed == [fixture.recordID])
        #expect(report.failures.isEmpty)
        #expect(report.stamped)
        #expect(!FileManager.default.fileExists(atPath: fixture.worktree.path))
        #expect(try fixture.registry.records().isEmpty)

        let linked = try listLinkedWorktrees(source: fixture.source)
        #expect(!linked.contains(where: { $0.path == fixture.worktree }))
    }

    @Test("an active claimed creator PID protects an otherwise clean stale worktree")
    func activeClaimedCreatorProtectsWorktree() throws {
        let fixture = try makeFixture()
        defer { fixture.dispose() }
        let marker = WorktreeMarkerMetadata(
            leaseID: "live-lease",
            sessionID: "live-session",
            processID: ProcessInfo.processInfo.processIdentifier
        )
        try JSONEncoder().encode(marker).write(to: fixture.claimedMarker)

        let report = try WorktreeAutoGC.runIfDue(
            registry: fixture.registry,
            policy: fixture.policy,
            protectedPaths: [],
            now: fixture.now,
            processScan: { .observed(observations()) }
        )

        #expect(report.removed.isEmpty)
        #expect(report.skippedProtected == [fixture.recordID])
        #expect(report.failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.worktree.path))
    }

    @Test("an upstream-compatible registry creator PID protects its live worktree")
    func registryCreatorPIDProtectsWorktree() throws {
        let fixture = try makeFixture()
        defer { fixture.dispose() }

        let data = try Data(contentsOf: fixture.registry.databaseURL)
        guard var rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !rows.isEmpty
        else {
            throw FastWorktreeError.gitFailed("fixture registry is not an array")
        }
        rows[0]["creator_pid"] = ProcessInfo.processInfo.processIdentifier
        let updated = try JSONSerialization.data(withJSONObject: rows)
        try updated.write(to: fixture.registry.databaseURL, options: .atomic)

        let report = try WorktreeAutoGC.runIfDue(
            registry: fixture.registry,
            policy: fixture.policy,
            protectedPaths: [],
            now: fixture.now,
            processScan: { .observed(observations()) }
        )

        #expect(report.removed.isEmpty)
        #expect(report.skippedProtected == [fixture.recordID])
        #expect(FileManager.default.fileExists(atPath: fixture.worktree.path))
    }

    @Test("an unreadable claimed creator marker fails closed without stamping")
    func unreadableClaimedCreatorMarkerFailsClosed() throws {
        let fixture = try makeFixture()
        defer { fixture.dispose() }
        try "not valid creator metadata".write(
            to: fixture.claimedMarker,
            atomically: true,
            encoding: .utf8
        )

        let report = try WorktreeAutoGC.runIfDue(
            registry: fixture.registry,
            policy: fixture.policy,
            protectedPaths: [],
            now: fixture.now,
            processScan: { .observed(observations()) }
        )

        #expect(report.removed.isEmpty)
        #expect(!report.stamped)
        #expect(report.failures.contains(where: { $0.contains("creator process") }))
        #expect(FileManager.default.fileExists(atPath: fixture.worktree.path))
    }

    @Test("symlink worktree records cannot delete the linked target")
    func symlinkCandidateIsNeverRemoved() throws {
        let fixture = try makeFixture()
        defer { fixture.dispose() }

        let alias = fixture.worktree.deletingLastPathComponent()
            .appendingPathComponent("aged-symlink")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.worktree)
        try fixture.registry.remove(id: fixture.recordID)
        try fixture.registry.register(WorktreeRecord(
            id: "symlink",
            path: alias,
            sourceRepository: fixture.source,
            repositoryName: "source",
            kind: .launch,
            createdAt: fixture.now.addingTimeInterval(-10_000),
            lastSeenAt: fixture.now.addingTimeInterval(-7_200)
        ))

        let report = try WorktreeAutoGC.runIfDue(
            registry: fixture.registry,
            policy: fixture.policy,
            protectedPaths: [],
            now: fixture.now,
            processScan: { .observed(observations()) }
        )

        #expect(report.removed.isEmpty)
        #expect(!report.stamped)
        #expect(report.failures.contains(where: { $0.contains("not a real directory") }))
        #expect(FileManager.default.fileExists(atPath: fixture.worktree.path))
        #expect(FileManager.default.fileExists(atPath: alias.path))
    }

    @Test("non-forced unknown-directory cleanup refuses recursive deletion")
    func nonForcedUnknownWorktreeIsNeverDeleted() throws {
        let fixture = try makeFixture()
        defer { fixture.dispose() }
        let unknown = fixture.root.appendingPathComponent("unknown-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        let valuable = unknown.appendingPathComponent("valuable.txt")
        try "keep me".write(to: valuable, atomically: true, encoding: .utf8)

        #expect(throws: FastWorktreeError.self) {
            try removeWorktreeAt(dest: unknown, force: false)
        }
        #expect(FileManager.default.fileExists(atPath: valuable.path))

        let forced = try removeWorktreeAt(dest: unknown, force: true)
        #expect(forced.removed)
        #expect(!FileManager.default.fileExists(atPath: unknown.path))
    }

    @Test("initialized dirty submodules block both auto-GC and non-forced deletion")
    func initializedDirtySubmoduleIsNeverDeleted() throws {
        let fixture = try makeFixture(withSubmodule: true)
        defer { fixture.dispose() }

        let submoduleFile = fixture.worktree
            .appendingPathComponent("vendor/component/component.txt")
        try "uncommitted submodule changes".write(
            to: submoduleFile,
            atomically: true,
            encoding: .utf8
        )

        let dirty = try getModifiedFiles(repoPath: fixture.worktree)
        #expect(dirty.allDirtyPaths.contains("vendor/component"))

        #expect(throws: FastWorktreeError.self) {
            try removeWorktree(source: fixture.source, dest: fixture.worktree, force: false)
        }
        #expect(FileManager.default.fileExists(atPath: submoduleFile.path))
        #expect(try String(contentsOf: submoduleFile, encoding: .utf8) == "uncommitted submodule changes")

        let report = try WorktreeAutoGC.runIfDue(
            registry: fixture.registry,
            policy: fixture.policy,
            protectedPaths: [],
            now: fixture.now,
            processScan: { .observed(observations()) }
        )

        #expect(report.removed.isEmpty)
        #expect(report.skippedDirty == [fixture.recordID])
        #expect(FileManager.default.fileExists(atPath: submoduleFile.path))
        #expect(try fixture.registry.records().map(\.id) == [fixture.recordID])
    }

    private func observations(
        including activeDirectory: URL? = nil
    ) -> [WorktreeAutoGCProcessObservation] {
        var entries = [
            WorktreeAutoGCProcessObservation(
                processID: ProcessInfo.processInfo.processIdentifier,
                workingDirectory: FileManager.default.currentDirectoryPath
            ),
        ]
        if let activeDirectory {
            entries.append(WorktreeAutoGCProcessObservation(
                processID: Int32.max,
                workingDirectory: activeDirectory.path
            ))
        }
        return entries
    }

    private func makeFixture(withSubmodule: Bool = false) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-auto-gc-security-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let pool = root.appendingPathComponent("pool", isDirectory: true)
        for directory in [source, home, pool] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        try initializeRepository(at: source)
        try "tracked contents".write(
            to: source.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try git(["add", "tracked.txt"], at: source)
        try git(["commit", "-m", "Create worktree security fixture"], at: source)

        if withSubmodule {
            let component = root.appendingPathComponent("component-origin", isDirectory: true)
            try FileManager.default.createDirectory(at: component, withIntermediateDirectories: true)
            try initializeRepository(at: component)
            try "committed submodule contents".write(
                to: component.appendingPathComponent("component.txt"),
                atomically: true,
                encoding: .utf8
            )
            try git(["add", "component.txt"], at: component)
            try git(["commit", "-m", "Create submodule fixture"], at: component)
            try git([
                "-c", "protocol.file.allow=always",
                "submodule", "add", component.path, "vendor/component",
            ], at: source)
            try git(["commit", "-am", "Add initialized submodule fixture"], at: source)
        }

        let worktree = pool.appendingPathComponent("aged", isDirectory: true)
        let created = try WorktreeBuilder(
            source: source,
            dest: worktree,
            creationMode: .gitCheckout,
            allowedPoolRoot: pool
        ).create()
        guard created.worktreePath.standardizedFileURL == worktree.standardizedFileURL else {
            throw FastWorktreeError.gitFailed("fixture created an unexpected worktree")
        }

        if withSubmodule {
            try git([
                "-c", "protocol.file.allow=always",
                "submodule", "update", "--init", "--recursive",
            ], at: worktree)
        }

        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let registry = WorktreeRegistry(openGrokHome: home)
        let recordID = "aged-worktree"
        try registry.register(WorktreeRecord(
            id: recordID,
            path: worktree,
            sourceRepository: source,
            repositoryName: "source",
            kind: .launch,
            creationMode: .gitCheckout,
            createdAt: now.addingTimeInterval(-10_000),
            lastSeenAt: now.addingTimeInterval(-7_200)
        ))

        return Fixture(
            root: root,
            source: source,
            worktree: worktree,
            registry: registry,
            recordID: recordID,
            now: now
        )
    }

    private func initializeRepository(at directory: URL) throws {
        try git(["init"], at: directory)
        try git(["config", "user.email", "worktree-security@example.com"], at: directory)
        try git(["config", "user.name", "Worktree Security Fixture"], at: directory)
    }

    private func git(_ arguments: [String], at directory: URL) throws {
        let result = try runGit(arguments, cwd: directory)
        guard result.exitCode == 0 else {
            throw FastWorktreeError.gitFailed(
                "fixture git \(arguments.joined(separator: " ")): \(result.stderr)"
            )
        }
    }

    private struct Fixture {
        let root: URL
        let source: URL
        let worktree: URL
        let registry: WorktreeRegistry
        let recordID: String
        let now: Date

        var policy: WorktreeAutoGCPolicy {
            WorktreeAutoGCPolicy(maxAge: 3_600, minimumInterval: 600)
        }

        var claimedMarker: URL {
            worktree.deletingLastPathComponent()
                .appendingPathComponent(worktree.lastPathComponent + ".claimed")
        }

        func dispose() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
