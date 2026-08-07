// PlanModeTools.swift
//
// Live handlers for the agent-initiated plan-mode lifecycle tools
// (`enter_plan_mode`, `exit_plan_mode`). Upstream reference:
//   * `enter_plan_mode/mod.rs` — signals entry, seeds an empty plan file
//     (never truncating existing content), returns a confirmation.
//   * `exit_plan_mode/mod.rs` — reads the plan file from disk, signals exit,
//     surfaces the plan for user approval.
//
// Both tools carry `ToolScope::Read` upstream, so the registry routes them
// to `AccessKind.read` and the permission engine auto-allows them. Plan-mode
// enforcement (read-only + plan-file gating) lives in the permission pipeline
// plan gate, not in these handlers.
//
// Divergence recorded: upstream's `exit_plan_mode` raises a dedicated
// plan-approval reverse-request rendered by the pager's plan-approval view
// (`xai-grok-pager/src/views/plan_approval_view.rs`). The Swift pager lacks
// that view (backing B4), so exit approval is routed through the existing
// permission ask sheet (`PermissionPipeline.requestExitPlanApproval`). See
// `PermissionPipeline.requestExitPlanApproval` for the cost of that trade.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime
import OpenGrokToolTypes
import OpenGrokWorkspace

/// Relative plan-file path under the session directory, matching upstream's
/// `PLAN_FILE_RELATIVE_PATH` (`xai-grok-tools/src/types/resources.rs:416`).
/// The Swift `PlanModeTracker` default is bare `plan.md`; the live tools
// override it to `.opengrok/plan.md` so the plan file lands in the hidden
// project-config directory rather than at the workspace root.
let livePlanFileRelativePath = ".opengrok/plan.md"

/// ToolHandler for `enter_plan_mode`.
///
/// Arms the session's plan gate and seeds an empty plan file at
/// `<sessionFolder>/.opengrok/plan.md` when missing (never truncating an
/// existing file). Returns the upstream "entered plan mode" message with the
/// resolved plan-file path so the model can read it before writing.
public struct EnterPlanModeToolHandler: ToolHandler {
    public init() {}

    public func invoke(
        clientName: String,
        args: JSONValue,
        ctx: ToolCallContext,
        resources: ToolResources
    ) async -> Result<TypedToolOutput, ToolError> {
        _ = args
        guard let pipeline = resources.permissionPipeline else {
            return .failure(.permissionDenied(
                "'\(clientName)' has no permission gate configured for this session"
            ))
        }
        let sessionDir = resources.sessionFolder
        await pipeline.enterPlanMode(
            planFilePath: livePlanFileRelativePath,
            sessionDirectory: sessionDir
        )
        let planPath = await pipeline.planFileResolvedPath()
        let seedStatus = seedPlanFile(at: planPath)
        let message = "You have entered plan mode. You should now focus on exploring the codebase and creating an implementation plan."
        let value: JSONValue = .object([
            "status": .string("entered"),
            "message": .string(message),
            "plan_file_path": .string(planPath),
            "plan_file_seed": .string(seedStatus),
        ])
        return .success(TypedToolOutput(
            toolId: enterPlanModeToolId,
            value: value,
            modelOutput: [.text(text: "\(message)\nPlan file: \(planPath)")]
        ))
    }
}

/// ToolHandler for `exit_plan_mode`.
///
/// Reads the plan file from disk, then routes approval through the existing
/// permission ask sheet (`PermissionPipeline.requestExitPlanApproval`). On
/// approval, disarms the plan gate so non-plan edits flow again. On denial,
/// leaves plan mode armed and returns a "user declined" result so the model
/// sees the rejection without the gate silently dropping.
public struct ExitPlanModeToolHandler: ToolHandler {
    public init() {}

    public func invoke(
        clientName: String,
        args: JSONValue,
        ctx: ToolCallContext,
        resources: ToolResources
    ) async -> Result<TypedToolOutput, ToolError> {
        _ = args
        guard let pipeline = resources.permissionPipeline else {
            return .failure(.permissionDenied(
                "'\(clientName)' has no permission gate configured for this session"
            ))
        }
        let planPath = await pipeline.planFileResolvedPath()
        let planContent = (try? SessionFS.readText(at: planPath)) ?? ""
        let trimmed = planContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let decision = await pipeline.requestExitPlanApproval(toolCallId: ctx.callId.rawValue)
        switch decision {
        case .allow:
            await pipeline.exitPlanMode()
            let message: String
            let value: JSONValue
            if trimmed.isEmpty {
                message = "Plan mode exit approved. No plan content was found — you can proceed."
                value = .object([
                    "status": .string("exited"),
                    "message": .string(message),
                    "plan_file_path": .string(planPath),
                    "plan_content": .string(""),
                ])
            } else {
                message = "Your plan has been approved. You can now start coding."
                value = .object([
                    "status": .string("exited"),
                    "message": .string(message),
                    "plan_file_path": .string(planPath),
                    "plan_content": .string(planContent),
                ])
            }
            return .success(TypedToolOutput(
                toolId: exitPlanModeToolId,
                value: value,
                modelOutput: [.text(text: message)]
            ))
        case .reject(let reason), .policyDeny(let reason):
            return .failure(.permissionDenied(
                "user declined to exit plan mode: \(reason)"
            ))
        case .cancelled:
            return .failure(.permissionDenied("user cancelled plan approval"))
        case .ask, .followupMessage:
            // The ask sheet did not resolve to an allow; treat as a decline so
            // the gate stays armed rather than silently exiting on ambiguity.
            return .failure(.permissionDenied(
                "plan exit was not approved (decision: \(decision))"
            ))
        }
    }
}

// MARK: - Plan file seeding

private enum PlanFileSeedStatus: String {
    case empty = "empty"
    case nonEmpty = "non_empty"
    case notCreated = "not_created"
    case inaccessible = "inaccessible"
}

/// Probe the plan file; create an empty one only on not-found.
///
/// Mirrors `probe_or_create_empty_plan_file` (`enter_plan_mode/mod.rs:183`):
/// never truncates existing content, and never writes when the path is a
/// directory or unreadable, so a misconfigured plan path cannot destroy a
/// real file.
private func seedPlanFile(at absolutePath: String) -> String {
    let url = URL(fileURLWithPath: absolutePath)
    if SessionFS.fileExists(absolutePath) {
        if let data = try? Data(contentsOf: url), data.isEmpty {
            return PlanFileSeedStatus.empty.rawValue
        }
        return PlanFileSeedStatus.nonEmpty.rawValue
    }
    // NotFound: create parent dirs + empty file.
    let parent = url.deletingLastPathComponent()
    do {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data().write(to: url, options: [.atomic])
        return PlanFileSeedStatus.empty.rawValue
    } catch {
        return PlanFileSeedStatus.notCreated.rawValue
    }
}

// MARK: - ToolIds

private let enterPlanModeToolId: ToolId = {
    do { return try ToolId("enter_plan_mode") }
    catch { preconditionFailure("invalid plan-mode tool id: enter_plan_mode") }
}()

private let exitPlanModeToolId: ToolId = {
    do { return try ToolId("exit_plan_mode") }
    catch { preconditionFailure("invalid plan-mode tool id: exit_plan_mode") }
}()

// MARK: - Subagent strip rule

/// Remove the plan-mode lifecycle tools (`enter_plan_mode` / `exit_plan_mode`)
/// from a finalized toolset's model-facing definitions.
///
/// Upstream's `strip_plan_mode_tools` (`xai-grok-tools/src/implementations/grok_build/task/types.rs:428`)
/// drops plan-mode tools from a subagent's config: plan mode is a root-session
/// interaction, and a child calling `exit_plan_mode` would present a plan
/// dialog indistinguishable from the parent's. Children get a fresh Inactive
/// plan tracker and must never drive the plan-mode lifecycle themselves.
///
/// The Swift port has no subagent sessions on the live path yet, so this is
/// encoded as a reusable rule rather than a live branch: the live composition
/// calls it when the session is subagent-flagged, and a test asserts the
/// strip removes exactly the plan-mode tools and nothing else. The day a
/// subagent session exists, this is the single call site that keeps the
/// lifecycle out of its hands.
public func stripPlanModeToolDefinitions(_ definitions: [ToolDescription]) -> [ToolDescription] {
    definitions.filter { name in
        name.name != "enter_plan_mode" && name.name != "exit_plan_mode"
    }
}

/// Qualified ids the subagent strip rule removes. Exposed for tests so the
/// assertion can name the exact tools rather than hard-coding strings elsewhere.
public let planModeToolQualifiedIds: Set<String> = [
    BuiltinToolCatalog.enterPlanModeQualifiedId,
    BuiltinToolCatalog.exitPlanModeQualifiedId,
]
