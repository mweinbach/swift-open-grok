// PlanApprovalHandlerTests.swift
//
// `exit_plan_mode` consuming the dedicated plan-approval view's three
// decisions, driven through the same live seam `PlanModeToolsTests` uses
// (`FileToolSession.makeResources` → finalize → `prepareAndCall`) with a
// dedicated prompter installed on the pipeline. The outcome mapping under
// test is upstream's mid-turn intercept
// (`xai-grok-shell/src/session/acp_session_impl/tool_calls.rs:1820-1901`):
// approved and abandoned disarm the plan gate, revise keeps it armed and
// returns the feedback. The generic-sheet fallback pins live in
// `PlanModeToolsTests` (approved releases, denied keeps armed) and must not
// move.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime
import OpenGrokToolTypes
import OpenGrokWorkspace
import Testing
@testable import OpenGrokFileTools

// MARK: - Fixtures

/// Dedicated prompter returning a fixed decision; records the plan it saw.
private final class FixedPlanPrompter: PlanApprovalPrompting, @unchecked Sendable {
    let decision: PlanApprovalDecision
    private(set) var seenPlanContent: String??

    init(_ decision: PlanApprovalDecision) {
        self.decision = decision
    }

    var canPresent: Bool {
        get async { true }
    }

    func decision(toolCallId: String, planContent: String?) async -> PlanApprovalDecision {
        seenPlanContent = planContent
        return decision
    }
}

@Suite("exit_plan_mode with the dedicated plan-approval view")
struct PlanApprovalHandlerTests {
    /// The model-visible text of a tool result — the string upstream's
    /// intercept places in the completed tool-call content.
    private func modelText(_ output: TypedToolOutput) -> String {
        output.modelOutput.compactMap { block -> String? in
            guard case .text(let text) = block else { return nil }
            return text
        }.joined()
    }

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-plan-approval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Live-seam toolset with the plan-mode tools registered and the given
    /// dedicated prompter installed on the pipeline — the composition shape
    /// `LiveToolExecutor` builds for an interactive TTY session.
    private func buildSet(
        at root: URL,
        prompter: FixedPlanPrompter
    ) async throws -> (set: FinalizedToolset, pipeline: PermissionPipeline) {
        let resources = FileToolSession.makeResources(
            workspaceRoot: root.path,
            sessionId: "plan-approval-test",
            agentId: "main",
            policy: .allowAll,
            planMode: PlanModeTracker(
                state: .inactive,
                planFilePath: ".opengrok/plan.md",
                sessionDirectory: root.path
            )
        )
        let pipeline = try #require(resources.permissionPipeline)
        await pipeline.installPlanApprovalPrompter(prompter)
        var builder = FileToolPack.makeBuilder()
        builder.setHandler(
            qualifiedId: BuiltinToolCatalog.enterPlanModeQualifiedId,
            handler: EnterPlanModeToolHandler()
        )
        builder.setHandler(
            qualifiedId: BuiltinToolCatalog.exitPlanModeQualifiedId,
            handler: ExitPlanModeToolHandler()
        )
        var toolConfig = toolServerConfig(for: .build, catalogKinds: builder.knownToolKinds())
        let kinds = BuiltinToolCatalog.planModeToolKinds
        toolConfig.tools.append(ToolConfig.fromId(
            BuiltinToolCatalog.enterPlanModeQualifiedId,
            kind: kinds[BuiltinToolCatalog.enterPlanModeQualifiedId]
        ))
        toolConfig.tools.append(ToolConfig.fromId(
            BuiltinToolCatalog.exitPlanModeQualifiedId,
            kind: kinds[BuiltinToolCatalog.exitPlanModeQualifiedId]
        ))
        switch builder.finalize(
            config: toolConfig,
            resources: resources,
            options: FinalizeOptions(capabilityMode: .readWrite)
        ) {
        case .success(let set): return (set, pipeline)
        case .failure(let errors): throw ToolBridgeError.finalizeFailed(errors.errors)
        }
    }

    private func enterAndWritePlan(
        _ set: FinalizedToolset,
        at root: URL,
        plan: String?
    ) async throws {
        let entered = await set.prepareAndCall(clientName: "enter_plan_mode", args: .object([:]))
        guard case .success = entered else {
            Issue.record("enter_plan_mode failed: \(entered)")
            return
        }
        if let plan {
            let planURL = root.appendingPathComponent(".opengrok/plan.md")
            try plan.write(to: planURL, atomically: true, encoding: .utf8)
        }
    }

    @Test("approved on the dedicated view disarms the gate with the approved copy")
    func approvedDisarms() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let prompter = FixedPlanPrompter(.approved)
        let (set, pipeline) = try await buildSet(at: dir, prompter: prompter)
        try await enterAndWritePlan(set, at: dir, plan: "# plan\nstep 1\n")

        let result = await set.prepareAndCall(clientName: "exit_plan_mode", args: .object([:]))
        guard case .success(let output) = result else {
            Issue.record("expected approved success, got \(result)")
            return
        }
        #expect(modelText(output) == "Your plan has been approved. You can now start coding.")
        // The view was handed the real plan body, not the file path.
        #expect(prompter.seenPlanContent == "# plan\nstep 1\n")
        #expect(await pipeline.planModeActive == false)
    }

    @Test("revise keeps the gate armed and returns the feedback in upstream's shape")
    func reviseStaysArmed() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let prompter = FixedPlanPrompter(.revise(feedback: "split step 2 into two"))
        let (set, pipeline) = try await buildSet(at: dir, prompter: prompter)
        try await enterAndWritePlan(set, at: dir, plan: "# plan\nstep 1\n")

        let result = await set.prepareAndCall(clientName: "exit_plan_mode", args: .object([:]))
        guard case .success(let output) = result else {
            Issue.record("expected revise success, got \(result)")
            return
        }
        // `revise_plan_message` (`tool_calls.rs:391-400`).
        #expect(modelText(output) == "The user wants to revise the plan. The user said:\nsplit step 2 into two")
        #expect(await pipeline.planModeActive == true)
    }

    @Test("revise with no feedback returns the ask-what-changes copy")
    func reviseWithoutFeedbackAsks() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let prompter = FixedPlanPrompter(.revise(feedback: ""))
        let (set, pipeline) = try await buildSet(at: dir, prompter: prompter)
        try await enterAndWritePlan(set, at: dir, plan: "# plan\n")

        let result = await set.prepareAndCall(clientName: "exit_plan_mode", args: .object([:]))
        guard case .success(let output) = result else {
            Issue.record("expected revise success, got \(result)")
            return
        }
        #expect(modelText(output) == "The user wants to revise the plan. Ask the user what changes they would like to make.")
        #expect(await pipeline.planModeActive == true)
    }

    @Test("revise on an empty plan returns the does-not-want-to-exit copy")
    func reviseEmptyPlan() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let prompter = FixedPlanPrompter(.revise(feedback: "irrelevant"))
        let (set, pipeline) = try await buildSet(at: dir, prompter: prompter)
        // enter_plan_mode seeds an empty plan file; nothing written after.
        try await enterAndWritePlan(set, at: dir, plan: nil)

        let result = await set.prepareAndCall(clientName: "exit_plan_mode", args: .object([:]))
        guard case .success(let output) = result else {
            Issue.record("expected revise success, got \(result)")
            return
        }
        // Empty plan + cancelled maps to the continue-planning copy, not the
        // revise copy (`tool_calls.rs:1856-1863`), and the view saw "no plan".
        #expect(modelText(output) == exitPlanModeEmptyPlanReviseText)
        #expect(prompter.seenPlanContent == .some(nil))
        #expect(await pipeline.planModeActive == true)
    }

    @Test("abandoned disarms the gate and forbids a retry, matching upstream")
    func abandonedDisarms() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let prompter = FixedPlanPrompter(.abandoned)
        let (set, pipeline) = try await buildSet(at: dir, prompter: prompter)
        try await enterAndWritePlan(set, at: dir, plan: "# plan\n")

        let result = await set.prepareAndCall(clientName: "exit_plan_mode", args: .object([:]))
        guard case .success(let output) = result else {
            Issue.record("expected abandoned success, got \(result)")
            return
        }
        // Upstream *leaves* plan mode on abandon (`leave_plan_mode_to_default`,
        // `tool_calls.rs:1833-1854`) and completes the call with this text.
        #expect(modelText(output) == exitPlanModeAbandonedText)
        #expect(modelText(output).contains("Plan mode has been disabled."))
        #expect(await pipeline.planModeActive == false)

        // The gate really is disarmed: a non-plan write now flows (allowAll).
        let write = await set.prepareAndCall(
            clientName: "write",
            args: .object([
                "file_path": .string("after_abandon.swift"),
                "content": .string("ok"),
            ])
        )
        guard case .success = write else {
            Issue.record("expected the write to flow after abandon, got \(write)")
            return
        }
    }
}
