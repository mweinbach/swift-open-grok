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

    /// Whether a user is present to answer a prompt. Drives the folder-trust
    /// decision, where "no one to ask" must resolve to untrusted rather than
    /// to a prompt nothing will paint.
    public var isInteractive: Bool {
        if case .prompt = self { return true }
        return false
    }
}

/// Builds session resources for the file tool pack.
public enum FileToolSession {
    /// Fold the user's resolved `[permission]` / `.claude/settings.json` policy
    /// into the preset a caller picked.
    ///
    /// Rules are purely additive — evaluation is deny > ask > allow and is
    /// order-independent, so a config allow rule can never override the
    /// preset's synthetic `deny Edit`. The prompt policy takes whichever side
    /// is more restrictive so a config `defaultMode` cannot loosen a session
    /// that was started deny-only.
    static func mergedConfig(
        preset: PermissionConfig,
        resolved: ResolvedPermissions?
    ) -> PermissionConfig {
        guard let resolved else { return preset }
        var merged = resolved.config
        merged.rules.append(contentsOf: preset.rules)
        if preset.promptPolicy == .deny { merged.promptPolicy = .deny }
        return merged
    }

    /// Construct a `PermissionPipeline` for `policy`, rooted at `workspaceRoot`.
    ///
    /// `hooks` is the PreToolUse injection point (fail-open by contract) and
    /// `planMode` the plan gate; both default to no-ops until the live session
    /// supplies real ones. `resolved` carries the rules sourced from config and
    /// Claude-compatible settings; without it the engine runs over an empty
    /// policy, which is what it did before this was wired. A child session may
    /// inherit its parent's exact permission actor without sharing the parent's
    /// plan-mode tracker, hooks, or other pipeline-local state.
    public static func makePipeline(
        policy: FileToolAccessPolicy,
        workspaceRoot: String,
        planMode: PlanModeTracker? = nil,
        hooks: any PreToolUseHookRunner = FailOpenPreToolUseHookRunner(),
        resolved: ResolvedPermissions? = nil,
        inheritedPermissionHandle: PermissionHandle? = nil,
        sandboxAutoAllowBash: @Sendable @escaping () -> Bool = { false }
    ) -> PermissionPipeline {
        // The blanket-approval request (`OPENGROK_ALLOW_WRITES=1`) maps to
        // `yoloMode`, not `allowAll`, whenever a real policy was resolved.
        //
        // `allowAll` short-circuits `PermissionHandle.request` at step 1, before
        // the policy is consulted, so it would silently ignore a user's own
        // `deny = ["Bash(rm:*)"]`. Rust's always-approve is evaluated *after*
        // deny/ask (manager step 3 runs only when `!policyForcedPrompt`, and a
        // policy deny has already returned), so an explicit deny rule wins over
        // blanket approval there. This matches that ordering. With no resolved
        // policy there are no rules, so the two are equivalent.
        let hasPolicy = resolved.map { !$0.config.rules.isEmpty } ?? false
        // Either the `OPENGROK_ALLOW_WRITES` bypass or `--always-approve`.
        // `resolved.alwaysApprove` is already false when a pin vetoed the flag.
        let blanketApproval =
            (policy.allowsAll || resolved?.alwaysApprove == true)
            && resolved?.yoloPinReason == nil
        let permissions = inheritedPermissionHandle ?? PermissionHandle(
            config: mergedConfig(preset: policy.permissionConfig, resolved: resolved),
            yoloMode: blanketApproval && hasPolicy,
            yoloPinReason: resolved?.yoloPinReason,
            allowAll: blanketApproval && !hasPolicy,
            shellCwd: workspaceRoot,
            prompter: policy.prompter,
            // Default `HeuristicPermissionClassifier` from PermissionHandle.init.
            sandboxAutoAllowBash: sandboxAutoAllowBash
        )
        return PermissionPipeline(
            permissions: permissions,
            planMode: planMode ?? PlanModeTracker(sessionDirectory: workspaceRoot),
            hooks: hooks,
            yoloPinReason: resolved?.yoloPinReason
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
        allowedRoots: [String]? = nil,
        resolved: ResolvedPermissions? = nil,
        inheritedPermissionHandle: PermissionHandle? = nil,
        sandboxAutoAllowBash: @Sendable @escaping () -> Bool = { false }
    ) -> ToolResources {
        let root = (workspaceRoot as NSString).standardizingPath
        return ToolResources(
            cwd: root,
            sessionFolder: root,
            permissionPipeline: makePipeline(
                policy: policy,
                workspaceRoot: root,
                planMode: planMode,
                hooks: hooks,
                resolved: resolved,
                inheritedPermissionHandle: inheritedPermissionHandle,
                sandboxAutoAllowBash: sandboxAutoAllowBash
            ),
            hunkTracker: hunkTracker,
            promptIndex: promptIndex,
            sessionId: sessionId,
            agentId: agentId,
            // `additionalDirectories` from Claude-compatible settings widen the
            // boundary `SessionFS.enforceRoots` checks. Rust parses the key but
            // does not act on it (resolution.rs:605); honouring it here is the
            // only way a user can grant a second root at all.
            allowedRoots: allowedRoots ?? ([root] + (resolved?.additionalDirectories ?? []))
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
