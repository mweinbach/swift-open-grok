// PlanModeToolsTests.swift
//
// Live-seam tests for the agent-initiated plan-mode lifecycle tools and the
// hunk-attribution wiring. These drive the same path a live session takes:
// `FileToolSession.makeResources` (with a real `PlanModeTracker` and
// `HunkTrackerActor`) → registry finalize with the plan-mode handlers
// installed → `FinalizedToolset.prepareAndCall`. The plan gate, plan-file
// auto-approval, exit approval, hunk attribution, and the subagent strip
// rule are all asserted through this seam rather than against composition
// types.

import Foundation
import OpenGrokHunkTracker
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime
import OpenGrokToolTypes
import OpenGrokWorkspace
import Testing
@testable import OpenGrokFileTools

@Suite("Plan-mode tools (live seam)")
struct PlanModeToolsTests {

    // MARK: - Fixtures

    private func tempDir(_ label: String = "plan") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-plan-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Build a live-seam toolset with the plan-mode tools registered, the same
    /// way `LiveComposition` registers them. `planMode` defaults to inactive so
    /// the gate is unarmed until `enter_plan_mode` arms it through the pipeline.
    private func buildSet(
        at root: URL,
        policy: FileToolAccessPolicy = .allowAll,
        planMode: PlanModeTracker? = nil,
        hunkTracker: HunkTrackerActor? = nil,
        subagent: Bool = false
    ) throws -> FinalizedToolset {
        let resources = FileToolSession.makeResources(
            workspaceRoot: root.path,
            sessionId: "plan-mode-test",
            agentId: "main",
            policy: policy,
            planMode: planMode ?? PlanModeTracker(
                state: .inactive,
                planFilePath: ".opengrok/plan.md",
                sessionDirectory: root.path
            ),
            hunkTracker: hunkTracker
        )
        var builder = FileToolPack.makeBuilder()
        if !subagent {
            builder.setHandler(
                qualifiedId: BuiltinToolCatalog.enterPlanModeQualifiedId,
                handler: EnterPlanModeToolHandler()
            )
            builder.setHandler(
                qualifiedId: BuiltinToolCatalog.exitPlanModeQualifiedId,
                handler: ExitPlanModeToolHandler()
            )
        }
        var toolConfig = toolServerConfig(for: .build, catalogKinds: builder.knownToolKinds())
        if !subagent {
            let kinds = BuiltinToolCatalog.planModeToolKinds
            toolConfig.tools.append(ToolConfig.fromId(
                BuiltinToolCatalog.enterPlanModeQualifiedId,
                kind: kinds[BuiltinToolCatalog.enterPlanModeQualifiedId]
            ))
            toolConfig.tools.append(ToolConfig.fromId(
                BuiltinToolCatalog.exitPlanModeQualifiedId,
                kind: kinds[BuiltinToolCatalog.exitPlanModeQualifiedId]
            ))
        }
        switch builder.finalize(
            config: toolConfig,
            resources: resources,
            options: FinalizeOptions(capabilityMode: .readWrite)
        ) {
        case .success(let set): return set
        case .failure(let errors):
            throw ToolBridgeError.finalizeFailed(errors.errors)
        }
    }

    private func success(_ result: Result<TypedToolOutput, ToolError>) throws -> TypedToolOutput {
        switch result {
        case .success(let t): return t
        case .failure(let e): throw e
        }
    }

    private func fails(_ result: Result<TypedToolOutput, ToolError>) -> ToolError? {
        if case .failure(let e) = result { return e }
        return nil
    }

    // MARK: - enter_plan_mode arms the gate

    @Test("enter_plan_mode blocks a non-plan file edit with the plan-gate refusal shape")
    func enterPlanModeBlocksNonPlanEdit() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = try buildSet(at: dir)

        // Arm plan mode through the live tool, exactly as a model would.
        let entered = await set.prepareAndCall(
            clientName: "enter_plan_mode",
            args: .object([:])
        )
        _ = try success(entered)

        // A non-plan edit is now rejected by the plan gate (step 1), before the
        // permission engine. Upstream's refusal shape is the plan-gate reject;
        // assert the decision source via the error text rather than exit code.
        let blocked = await set.prepareAndCall(
            clientName: "write",
            args: .object([
                "file_path": .string("code.swift"),
                "content": .string("nope"),
            ])
        )
        guard let error = fails(blocked) else {
            Issue.record("expected plan gate to block the non-plan edit")
            return
        }
        #expect(error.kind == .permissionDenied)
        #expect(error.detail.contains("plan mode"))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("code.swift").path))
    }

    @Test("a plan-file write is auto-approved while other writes still gate")
    func planFileAutoApprovedWhileOthersGate() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = try buildSet(at: dir)

        _ = try success(await set.prepareAndCall(
            clientName: "enter_plan_mode",
            args: .object([:])
        ))

        // The plan file (`.opengrok/plan.md` under the session dir) is the one
        // auto-approval compares against; writing it succeeds via step 3.
        let planPath = dir.appendingPathComponent(".opengrok/plan.md")
        let planWrite = await set.prepareAndCall(
            clientName: "write",
            args: .object([
                "file_path": .string(".opengrok/plan.md"),
                "content": .string("# plan\nstep 1\n"),
            ])
        )
        _ = try success(planWrite)
        #expect(try String(contentsOf: planPath, encoding: .utf8) == "# plan\nstep 1\n")

        // A non-plan write is still gated.
        let blocked = await set.prepareAndCall(
            clientName: "write",
            args: .object([
                "file_path": .string("other.swift"),
                "content": .string("nope"),
            ])
        )
        #expect(fails(blocked) != nil)
    }

    // MARK: - exit_plan_mode routes through the ask sheet

    @Test("exit_plan_mode asks and, once approved, edits flow again")
    func exitPlanModeApprovedReleasesGate() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let prompter = ApprovingPrompter()
        let set = try buildSet(at: dir, policy: .prompt(prompter))

        _ = try success(await set.prepareAndCall(
            clientName: "enter_plan_mode",
            args: .object([:])
        ))

        // While plan mode is active, a non-plan edit is gated.
        #expect(fails(await set.prepareAndCall(
            clientName: "write",
            args: .object(["file_path": .string("a.swift"), "content": .string("x")])
        )) != nil)

        // Exit asks; the prompter approves, so the handler disarms the gate.
        let exited = await set.prepareAndCall(
            clientName: "exit_plan_mode",
            args: .object([:])
        )
        _ = try success(exited)
        #expect(prompter.wasAsked, "exit_plan_mode must route through the ask sheet")

        // Now a non-plan edit flows through the ordinary permission engine,
        // which asks the same prompter and is approved.
        let write = await set.prepareAndCall(
            clientName: "write",
            args: .object([
                "file_path": .string("after_exit.swift"),
                "content": .string("ok"),
            ])
        )
        _ = try success(write)
        #expect(try String(contentsOf: dir.appendingPathComponent("after_exit.swift"), encoding: .utf8) == "ok")
    }

    @Test("a denied exit_plan_mode leaves the gate armed")
    func exitPlanModeDeniedKeepsGate() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let prompter = DenyingPrompter()
        let set = try buildSet(at: dir, policy: .prompt(prompter))

        _ = try success(await set.prepareAndCall(
            clientName: "enter_plan_mode",
            args: .object([:])
        ))

        // Exit is denied; the tool result is rejected and plan mode stays armed.
        let exitResult = await set.prepareAndCall(
            clientName: "exit_plan_mode",
            args: .object([:])
        )
        guard let error = fails(exitResult) else {
            Issue.record("denied exit must reject the tool result")
            return
        }
        #expect(error.kind == .permissionDenied)
        #expect(error.detail.contains("declined"))

        // A non-plan edit is still gated because the gate never disarmed.
        let blocked = await set.prepareAndCall(
            clientName: "write",
            args: .object([
                "file_path": .string("still_blocked.swift"),
                "content": .string("nope"),
            ])
        )
        #expect(fails(blocked) != nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("still_blocked.swift").path))
    }

    // MARK: - Subagent strip rule

    @Test("the plan-mode tools are absent from a subagent-flagged toolset")
    func subagentStripRemovesPlanModeTools() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mainSet = try buildSet(at: dir, subagent: false)
        let subagentSet = try buildSet(at: dir, subagent: true)

        let mainNames = Set(mainSet.topLevelDefinitions().map(\.name))
        let subagentNames = Set(subagentSet.topLevelDefinitions().map(\.name))

        #expect(mainNames.contains("enter_plan_mode"))
        #expect(mainNames.contains("exit_plan_mode"))
        #expect(!subagentNames.contains("enter_plan_mode"))
        #expect(!subagentNames.contains("exit_plan_mode"))
        // The strip removes only the plan-mode tools — every other tool survives.
        #expect(subagentNames.contains("write"))
        #expect(subagentNames.contains("read_file"))
    }

    @Test("stripPlanModeToolDefinitions removes exactly the plan-mode tools")
    func stripHelperRemovesOnlyPlanModeTools() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = try buildSet(at: dir)
        let all = set.topLevelDefinitions()
        let stripped = stripPlanModeToolDefinitions(all)
        let removed = Set(all.map(\.name)) .subtracting(Set(stripped.map(\.name)))
        #expect(removed == Set(["enter_plan_mode", "exit_plan_mode"]))
    }

    // MARK: - Hunk attribution

    @Test("a successful file edit records the hunk with session/agent attribution")
    func successfulEditRecordsHunk() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracker = HunkTrackerActor(sessionId: "plan-mode-test", workingDir: dir.path, defaultAgentId: "main")
        let set = try buildSet(at: dir, hunkTracker: tracker)

        let file = dir.appendingPathComponent("attributed.txt")
        _ = try success(await set.prepareAndCall(
            clientName: "write",
            args: .object([
                "file_path": .string("attributed.txt"),
                "content": .string("hello\n"),
            ])
        ))

        // Attribution is recorded only after the successful write. The actor
        // carries the session id and the agent id the live seam was wired with.
        let tracked = await tracker.getAllTrackedPaths()
        #expect(tracked.contains(file.path))
        let isAgent = await tracker.isAgentFile(file.path)
        #expect(isAgent)
        let snapshot = await tracker.snapshotState()
        #expect(snapshot.sessionId == "plan-mode-test")
    }

    @Test("a denied edit records no hunk")
    func deniedEditRecordsNoHunk() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracker = HunkTrackerActor(sessionId: "plan-mode-test", workingDir: dir.path, defaultAgentId: "main")
        // denyByDefault: every mutation is policy-denied, so the write never
        // dispatches and `SessionFS.writeText` (the attribution site) is never
        // reached.
        let set = try buildSet(at: dir, policy: .denyByDefault, hunkTracker: tracker)

        let file = dir.appendingPathComponent("never_written.txt")
        let blocked = await set.prepareAndCall(
            clientName: "write",
            args: .object([
                "file_path": .string("never_written.txt"),
                "content": .string("nope"),
            ])
        )
        #expect(fails(blocked) != nil)

        let tracked = await tracker.getAllTrackedPaths()
        #expect(!tracked.contains(file.path))
        let isAgent = await tracker.isAgentFile(file.path)
        #expect(!isAgent)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

// MARK: - Test prompters

/// Approves every ask. Used for the exit-approval flow and the post-exit edits.
private final class ApprovingPrompter: PermissionPrompter, @unchecked Sendable {
    private(set) var wasAsked = false
    func prompt(
        access: AccessKind,
        toolName: String,
        toolCallId: String
    ) async -> PermissionDecision {
        wasAsked = true
        return .allow
    }
}

/// Denies every ask. Used to assert a denied exit leaves the gate armed.
private final class DenyingPrompter: PermissionPrompter, @unchecked Sendable {
    func prompt(
        access: AccessKind,
        toolName: String,
        toolCallId: String
    ) async -> PermissionDecision {
        .reject("test: plan exit denied")
    }
}
