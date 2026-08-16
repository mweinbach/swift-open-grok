import Foundation
import Testing
@testable import OpenGrokFastWorktree

@Suite("Worktree auto-GC", .serialized)
struct WorktreeAutoGCTests {
    @Test("policy clamps unsafe age and cadence values")
    func policyClamps() {
        let policy = WorktreeAutoGCPolicy(maxAge: 1, minimumInterval: 1)
        #expect(policy.maxAge == 3_600)
        #expect(policy.minimumInterval == 60)

        let upper = WorktreeAutoGCPolicy(
            maxAge: 365 * 86_400,
            minimumInterval: 30 * 86_400
        )
        #expect(upper.maxAge == 90 * 86_400)
        #expect(upper.minimumInterval == 7 * 86_400)
    }

    @Test("disabled policy does not touch the registry")
    func disabled() throws {
        let fixture = try makeFixture()
        defer { fixture.dispose() }
        try fixture.registry.register(fixture.staleRecord(id: "stale"))

        let report = try WorktreeAutoGC.runIfDue(
            registry: fixture.registry,
            policy: WorktreeAutoGCPolicy(enabled: false)
        )

        #expect(report.outcome == .disabled)
        #expect(try fixture.registry.records().map(\.id) == ["stale"])
    }

    @Test("stale registry entries are removed and the next run is throttled")
    func staleRemovalAndThrottle() throws {
        let fixture = try makeFixture()
        defer { fixture.dispose() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try fixture.registry.register(fixture.staleRecord(id: "stale"))

        let policy = WorktreeAutoGCPolicy(
            maxAge: 3_600,
            minimumInterval: 600
        )
        let first = try WorktreeAutoGC.runIfDue(
            registry: fixture.registry,
            policy: policy,
            now: now
        )
        #expect(first.outcome == .ran)
        #expect(first.candidates == ["stale"])
        #expect(first.removed == ["stale"])
        #expect(first.stamped)
        #expect(try fixture.registry.records().isEmpty)

        let second = try WorktreeAutoGC.runIfDue(
            registry: fixture.registry,
            policy: policy,
            now: now.addingTimeInterval(30)
        )
        #expect(second.outcome == .throttled)
    }

    @Test("dry run preserves protected launch worktrees and ignores manual ones")
    func protectedAndManual() throws {
        let fixture = try makeFixture()
        defer { fixture.dispose() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let launch = fixture.root.appendingPathComponent("launch", isDirectory: true)
        let manual = fixture.root.appendingPathComponent("manual", isDirectory: true)
        try FileManager.default.createDirectory(at: launch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: manual, withIntermediateDirectories: true)
        try fixture.registry.register(WorktreeRecord(
            id: "launch",
            path: launch,
            sourceRepository: fixture.root,
            repositoryName: "fixture",
            kind: .launch,
            lastSeenAt: now.addingTimeInterval(-7_200)
        ))
        try fixture.registry.register(WorktreeRecord(
            id: "manual",
            path: manual,
            sourceRepository: fixture.root,
            repositoryName: "fixture",
            kind: .manual,
            lastSeenAt: now.addingTimeInterval(-7_200)
        ))

        let report = try WorktreeAutoGC.runIfDue(
            registry: fixture.registry,
            policy: WorktreeAutoGCPolicy(
                maxAge: 3_600,
                minimumInterval: 60,
                dryRun: true
            ),
            protectedPaths: [launch],
            now: now
        )

        #expect(report.candidates == ["launch"])
        #expect(report.skippedProtected == ["launch"])
        #expect(report.removed.isEmpty)
        #expect(Set(try fixture.registry.records().map(\.id)) == ["launch", "manual"])
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-auto-gc-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return Fixture(root: root, registry: WorktreeRegistry(openGrokHome: home))
    }

    private struct Fixture {
        var root: URL
        var registry: WorktreeRegistry

        func staleRecord(id: String) -> WorktreeRecord {
            WorktreeRecord(
                id: id,
                path: root.appendingPathComponent("missing-\(id)"),
                sourceRepository: root,
                repositoryName: "fixture",
                kind: .launch,
                lastSeenAt: Date(timeIntervalSince1970: 1)
            )
        }

        func dispose() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
