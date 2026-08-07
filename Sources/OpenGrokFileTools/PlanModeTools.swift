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
// Exit approval routes through `PermissionPipeline.requestExitPlanApproval`:
// the dedicated plan-approval view when the composition installed one (the
// port of upstream's plan-approval reverse-request,
// `xai-grok-pager/src/views/plan_approval_view.rs`), otherwise the generic
// permission ask sheet with its pre-dedicated-view semantics. The three
// dedicated-view outcomes map exactly as upstream's mid-turn intercept does
// (`xai-grok-shell/src/session/acp_session_impl/tool_calls.rs:1820-1901`):
// approved exits plan mode, revise stays in plan mode and returns the
// feedback, abandoned *disables* plan mode and tells the model not to retry.

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

/// Model-facing result when the user abandons the plan on the dedicated view.
/// Quoted from the upstream mid-turn intercept (`tool_calls.rs:1836-1839`),
/// with `exit_plan_mode` in place of upstream's `call.function.name` — the
/// only name this handler is registered under.
public let exitPlanModeAbandonedText =
    "The user chose to abandon the plan entirely (via the Abandon option in the plan approval dialog). Plan mode has been disabled. Do not call exit_plan_mode again unless the user explicitly asks to re-enter plan mode."

/// Model-facing result when the user requests changes with no plan on disk.
/// Quoted from `tool_calls.rs:1859-1862`.
public let exitPlanModeEmptyPlanReviseText =
    "The user does not want to exit plan mode. Continue planning and ask the user what they would like to do."

/// `revise_plan_message` (`tool_calls.rs:391-400`): the model-facing result
/// when the user requests changes on a plan that exists.
public func exitPlanModeReviseText(feedback: String) -> String {
    let trimmed = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return "The user wants to revise the plan. Ask the user what changes they would like to make."
    }
    return "The user wants to revise the plan. The user said:\n\(trimmed)"
}

/// ToolHandler for `exit_plan_mode`.
///
/// Reads the plan file from disk, then routes approval through
/// `PermissionPipeline.requestExitPlanApproval`. The dedicated view's three
/// outcomes follow upstream's mid-turn intercept (`tool_calls.rs:1820-1901`):
/// approved disarms the gate, revise keeps it armed and returns the feedback,
/// abandoned disarms it with the do-not-retry message. The generic-sheet
/// fallback keeps the pre-dedicated-view mapping byte for byte: allow disarms,
/// everything else is a "user declined" failure with the gate still armed.
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
        // Empty/whitespace plans present as "no plan", mirroring upstream's
        // `classify_plan_file_read` (`tool_calls.rs:193-200`), which is what
        // makes the view show its empty-plan placeholder.
        let result = await pipeline.requestExitPlanApproval(
            toolCallId: ctx.callId.rawValue,
            planContent: trimmed.isEmpty ? nil : planContent
        )
        switch result {
        case .plan(.approved):
            return await approvedOutput(
                pipeline: pipeline,
                planPath: planPath,
                planContent: planContent,
                trimmed: trimmed
            )
        case .plan(.revise(let feedback)):
            // Stay in plan mode; the feedback goes back to the model
            // (`tool_calls.rs:1856-1879`). A completed result, not an error —
            // upstream marks the tool call Completed with this text.
            let message = trimmed.isEmpty
                ? exitPlanModeEmptyPlanReviseText
                : exitPlanModeReviseText(feedback: feedback)
            return .success(TypedToolOutput(
                toolId: exitPlanModeToolId,
                value: .object([
                    "status": .string("revising"),
                    "message": .string(message),
                    "plan_file_path": .string(planPath),
                ]),
                modelOutput: [.text(text: message)]
            ))
        case .plan(.abandoned):
            // Upstream *leaves* plan mode on abandon — `leave_plan_mode_to_
            // default()` in the intercept (`tool_calls.rs:1833-1854`) and
            // `ResumeAction::LeaveOnly` on resume (`tool_calls.rs:410-419`) —
            // so the gate disarms here too, and the message forbids a retry.
            await pipeline.exitPlanMode()
            return .success(TypedToolOutput(
                toolId: exitPlanModeToolId,
                value: .object([
                    "status": .string("abandoned"),
                    "message": .string(exitPlanModeAbandonedText),
                    "plan_file_path": .string(planPath),
                ]),
                modelOutput: [.text(text: exitPlanModeAbandonedText)]
            ))
        case .generic(let decision):
            switch decision {
            case .allow:
                return await approvedOutput(
                    pipeline: pipeline,
                    planPath: planPath,
                    planContent: planContent,
                    trimmed: trimmed
                )
            case .reject(let reason), .policyDeny(let reason):
                return .failure(.permissionDenied(
                    "user declined to exit plan mode: \(reason)"
                ))
            case .cancelled:
                return .failure(.permissionDenied("user cancelled plan approval"))
            case .ask, .followupMessage:
                // The ask sheet did not resolve to an allow; treat as a
                // decline so the gate stays armed rather than silently
                // exiting on ambiguity.
                return .failure(.permissionDenied(
                    "plan exit was not approved (decision: \(decision))"
                ))
            }
        }
    }

    private func approvedOutput(
        pipeline: PermissionPipeline,
        planPath: String,
        planContent: String,
        trimmed: String
    ) async -> Result<TypedToolOutput, ToolError> {
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
