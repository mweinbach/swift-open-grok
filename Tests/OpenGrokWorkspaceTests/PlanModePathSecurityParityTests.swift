import Foundation
import Testing
@testable import OpenGrokWorkspace

@Suite("Plan mode exact authorized-file security")
struct PlanModePathSecurityParityTests {
    @Test("only the exact session-rooted relative or absolute plan path is authorized")
    func exactRootedPlanIdentity() throws {
        let root = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let tracker = activeTracker(root: root)
        let plan = root.appendingPathComponent(".opengrok/plan.md")

        #expect(tracker.shouldAutoApproveEdit(".opengrok/plan.md"))
        #expect(tracker.shouldAutoApproveEdit(plan.path))
        #expect(tracker.shouldAutoApproveEdit(".opengrok/./plan.md"))
        #expect(tracker.shouldAutoApproveEdit(".opengrok//plan.md"))
        #expect(!tracker.shouldAutoApproveEdit("plan.md"))
        #expect(!tracker.shouldAutoApproveEdit("src/plan.md"))
        #expect(!tracker.shouldAutoApproveEdit("other/.opengrok/plan.md"))
        #expect(!tracker.shouldAutoApproveEdit(".opengrok/../src/plan.md"))
        #expect(!tracker.shouldAutoApproveEdit("../.opengrok/plan.md"))
        #expect(!tracker.shouldAutoApproveEdit(".opengrok/plan.md\0.swift"))
    }

    @Test("the authorized plan can be created before its directory or leaf exists")
    func missingAuthorizedPathStillResolves() throws {
        let root = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let tracker = activeTracker(root: root)
        let planDirectory = root.appendingPathComponent(".opengrok")

        #expect(!FileManager.default.fileExists(atPath: planDirectory.path))
        #expect(tracker.shouldAutoApproveEdit(".opengrok/plan.md"))
        #expect(tracker.shouldAutoApproveEdit(planDirectory.appendingPathComponent("plan.md").path))
        #expect(!tracker.shouldAutoApproveEdit("missing/plan.md"))
    }

    @Test("mixed relative and absolute paths fail closed without a trusted session root")
    func missingRootNeverFallsBackToBasename() {
        let relative = PlanModeTracker(state: .active, planFilePath: "plan.md")
        #expect(relative.shouldAutoApproveEdit("plan.md"))
        #expect(!relative.shouldAutoApproveEdit("src/plan.md"))
        #expect(!relative.shouldAutoApproveEdit("/tmp/plan.md"))

        let absolute = PlanModeTracker(state: .active, planFilePath: "/tmp/session/plan.md")
        #expect(absolute.shouldAutoApproveEdit("/tmp/session/plan.md"))
        #expect(!absolute.shouldAutoApproveEdit("plan.md"))
        #expect(!absolute.shouldAutoApproveEdit("src/plan.md"))
    }

    @Test("symlink aliases authorize only the actual plan-file identity")
    func genuineAliasAllowedButExternalAliasRejected() throws {
        #if !os(Windows)
        let root = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let planDirectory = root.appendingPathComponent(".opengrok")
        let external = root.deletingLastPathComponent().appendingPathComponent("external")
        try FileManager.default.createDirectory(at: planDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try "real plan".write(
            to: planDirectory.appendingPathComponent("plan.md"),
            atomically: true,
            encoding: .utf8
        )
        try "protected".write(
            to: external.appendingPathComponent("plan.md"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("real-alias"),
            withDestinationURL: planDirectory
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"),
            withDestinationURL: external
        )
        let tracker = activeTracker(root: root)

        #expect(tracker.shouldAutoApproveEdit("real-alias/plan.md"))
        #expect(!tracker.shouldAutoApproveEdit("escape/plan.md"))
        #expect(!tracker.shouldAutoApproveEdit(external.appendingPathComponent("plan.md").path))
        #endif
    }

    @Test("existing and dangling symlinks at the authorized plan location cannot escape")
    func authorizedPlanSymlinkCannotAuthorizeExternalWrites() throws {
        #if !os(Windows)
        let root = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let planDirectory = root.appendingPathComponent(".opengrok")
        let external = root.deletingLastPathComponent().appendingPathComponent("external")
        try FileManager.default.createDirectory(at: planDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let authorized = planDirectory.appendingPathComponent("plan.md")
        let existingTarget = external.appendingPathComponent("existing.md")
        try "protected".write(to: existingTarget, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: authorized, withDestinationURL: existingTarget)
        let tracker = activeTracker(root: root)

        #expect(!tracker.shouldAutoApproveEdit(".opengrok/plan.md"))
        #expect(!tracker.shouldAutoApproveEdit(authorized.path))

        try FileManager.default.removeItem(at: authorized)
        try FileManager.default.createSymbolicLink(
            at: authorized,
            withDestinationURL: external.appendingPathComponent("not-created-yet.md")
        )
        #expect(!tracker.shouldAutoApproveEdit(".opengrok/plan.md"))
        #endif
    }

    @Test("symlink plus parent traversal is resolved before lexical normalization")
    func parentTraversalCannotCollapseAcrossOutboundSymlink() throws {
        #if !os(Windows)
        let root = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let external = root.deletingLastPathComponent().appendingPathComponent("external")
        let externalNested = external.appendingPathComponent("nested")
        let externalPlanDirectory = external.appendingPathComponent(".opengrok")
        let authorizedPlanDirectory = root.appendingPathComponent(".opengrok")
        for directory in [externalNested, externalPlanDirectory, authorizedPlanDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "outside".write(
            to: externalPlanDirectory.appendingPathComponent("plan.md"),
            atomically: true,
            encoding: .utf8
        )
        try "inside".write(
            to: authorizedPlanDirectory.appendingPathComponent("plan.md"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("redirect"),
            withDestinationURL: externalNested
        )
        let tracker = activeTracker(root: root)

        #expect(!tracker.shouldAutoApproveEdit("redirect/../.opengrok/plan.md"))
        #expect(tracker.shouldAutoApproveEdit(".opengrok/../.opengrok/plan.md"))
        #endif
    }

    @Test("case variants follow actual filesystem identity without portable lowercase bypass")
    func caseSensitivityFollowsFilesystem() throws {
        let root = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let planDirectory = root.appendingPathComponent(".opengrok")
        try FileManager.default.createDirectory(at: planDirectory, withIntermediateDirectories: true)
        try "plan".write(
            to: planDirectory.appendingPathComponent("plan.md"),
            atomically: true,
            encoding: .utf8
        )
        let alternate = planDirectory.appendingPathComponent("PLAN.MD")
        let tracker = activeTracker(root: root)

        #expect(
            tracker.shouldAutoApproveEdit(".opengrok/PLAN.MD")
                == FileManager.default.fileExists(atPath: alternate.path)
        )
    }

    @Test("managed deny cannot be bypassed by a different relative plan.md")
    func managedPolicyCannotBeSkippedByBasenameCollision() async throws {
        let root = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let permissions = PermissionHandle(
            config: PermissionConfig(rules: [
                PermissionRule(action: .deny, tool: .edit, pattern: "**", source: .managedConfig),
            ]),
            yoloMode: true,
            shellCwd: root.path
        )
        let pipeline = PermissionPipeline(permissions: permissions, planMode: activeTracker(root: root))

        let attacker = await pipeline.prepare(PrepareToolAccessRequest(
            access: .edit("src/plan.md"),
            toolName: "write",
            toolCallId: "attacker"
        ))
        #expect(attacker.source == .planModeGate)
        #expect(!attacker.mayDispatch)

        let authorized = await pipeline.prepare(PrepareToolAccessRequest(
            access: .edit(".opengrok/plan.md"),
            toolName: "write",
            toolCallId: "authorized"
        ))
        #expect(authorized.source == .planFileAutoApprove)
        #expect(authorized.decision == .allow)

        await pipeline.exitPlanMode()
        let managed = await pipeline.prepare(PrepareToolAccessRequest(
            access: .edit("src/plan.md"),
            toolName: "write",
            toolCallId: "managed-deny"
        ))
        #expect(managed.source == .permissionEngine)
        #expect(!managed.mayDispatch)
        #expect(await permissions.lastMatchedRuleSource == .managedConfig)
    }

    @Test("inactive mode and opaque patches never acquire plan-file authorization")
    func inactiveAndPatchGatesRemainFailClosed() throws {
        let root = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let inactive = PlanModeTracker(
            state: .inactive,
            planFilePath: ".opengrok/plan.md",
            sessionDirectory: root.path
        )
        #expect(!inactive.shouldAutoApproveEdit(".opengrok/plan.md"))
        #expect(planModeEditGate(
            tracker: activeTracker(root: root),
            access: .edit(".opengrok/plan.md"),
            applyPatchLabel: true
        ) == .rejectNonPlanFile)
    }

    private func activeTracker(root: URL) -> PlanModeTracker {
        PlanModeTracker(
            state: .active,
            planFilePath: ".opengrok/plan.md",
            sessionDirectory: root.path
        )
    }

    private func temporaryWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-plan-security-\(UUID().uuidString)")
            .appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
