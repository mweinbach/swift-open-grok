// FileToolSession.swift
//
// Session wiring for the write-capable file tool pack: builds the
// `ToolResources` a live session hands to `FinalizedToolset.prepareAndCall`,
// with the permission gate always populated.
//
// Fixed order enforced downstream by `PermissionPipeline.prepare`:
//   plan gate → PreToolUse hooks (fail-open) → plan-file auto-approval →
//   permission evaluation → dispatch → hunk attribution after success.

import Foundation
import OpenGrokHunkTracker
import OpenGrokToolRegistry
import OpenGrokWorkspace

/// How mutating file tools are authorized for a session.
///
/// The gate itself is `PermissionPipeline`; these are the presets a caller
/// picks when it does not already own a configured pipeline.
public enum FileToolAccessPolicy: Sendable {
    /// Every access allowed without prompting. Test / trusted-automation only.
    case allowAll
    /// Reads and searches allowed; every mutation is policy-denied.
    case denyMutations
    /// Reads allowed, mutations routed to `prompter` (headless prompters deny).
    case prompt(any PermissionPrompter)

    /// Deny-by-default: nothing can prompt, so mutations never dispatch.
    public static var denyByDefault: FileToolAccessPolicy { .denyMutations }

    var permissionConfig: PermissionConfig {
        switch self {
        case .allowAll:
            // `allowAll` short-circuits `PermissionHandle.request`; rules are moot.
            return PermissionConfig()
        case .denyMutations:
            // Reads and greps stay on the built-in auto-allow path.
            return PermissionConfig(
                rules: [PermissionRule(action: .deny, tool: .edit, source: .synthetic)],
                promptPolicy: .deny
            )
        case .prompt:
            return PermissionConfig(promptPolicy: .ask)
        }
    }

    var prompter: any PermissionPrompter {
        switch self {
        case .prompt(let prompter): return prompter
        case .allowAll, .denyMutations: return HeadlessPermissionPrompter()
        }
    }

    var allowsAll: Bool {
        if case .allowAll = self { return true }
        return false
    }
}

/// Builds session resources for the file tool pack.
public enum FileToolSession {
    /// Construct a `PermissionPipeline` for `policy`, rooted at `workspaceRoot`.
    ///
    /// `hooks` is the PreToolUse injection point (fail-open by contract) and
    /// `planMode` the plan gate; both default to no-ops until the live session
    /// supplies real ones.
    public static func makePipeline(
        policy: FileToolAccessPolicy,
        workspaceRoot: String,
        planMode: PlanModeTracker? = nil,
        hooks: any PreToolUseHookRunner = FailOpenPreToolUseHookRunner()
    ) -> PermissionPipeline {
        let permissions = PermissionHandle(
            config: policy.permissionConfig,
            allowAll: policy.allowsAll,
            shellCwd: workspaceRoot,
            prompter: policy.prompter
        )
        return PermissionPipeline(
            permissions: permissions,
            planMode: planMode ?? PlanModeTracker(sessionDirectory: workspaceRoot),
            hooks: hooks
        )
    }

    /// Session resources with the permission gate and workspace root pinned.
    ///
    /// `allowedRoots` defaults to `[workspaceRoot]`; every mutation tool
    /// canonicalizes through `SessionFS.enforceRoots` against it.
    public static func makeResources(
        workspaceRoot: String,
        sessionId: String,
        agentId: String = "main",
        policy: FileToolAccessPolicy = .denyByDefault,
        planMode: PlanModeTracker? = nil,
        hooks: any PreToolUseHookRunner = FailOpenPreToolUseHookRunner(),
        hunkTracker: HunkTrackerActor? = nil,
        promptIndex: Int = 0,
        allowedRoots: [String]? = nil
    ) -> ToolResources {
        let root = (workspaceRoot as NSString).standardizingPath
        return ToolResources(
            cwd: root,
            sessionFolder: root,
            permissionPipeline: makePipeline(
                policy: policy,
                workspaceRoot: root,
                planMode: planMode,
                hooks: hooks
            ),
            hunkTracker: hunkTracker,
            promptIndex: promptIndex,
            sessionId: sessionId,
            agentId: agentId,
            allowedRoots: allowedRoots ?? [root]
        )
    }
}

extension FileToolPack {
    /// Finalize the write-capable `.build` preset.
    ///
    /// Pass `capabilityMode: .readOnly` to drop every mutating tool from the
    /// model-facing definitions before the permission gate ever runs.
    public static func finalizeBuildPack(
        resources: ToolResources,
        capabilityMode: ToolCapabilityMode = .readWrite
    ) throws -> FinalizedToolset {
        try finalizePreset(
            .build,
            resources: resources,
            options: FinalizeOptions(capabilityMode: capabilityMode)
        )
    }
}
