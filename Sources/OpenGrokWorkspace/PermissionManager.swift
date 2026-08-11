// PermissionManager.swift
//
// Permission request pipeline: policy → YOLO/auto → grants → prompt.
// Ported conceptually from `xai-grok-workspace/src/permission/manager.rs`
// without the full actor runtime (session wiring lands later).

import Foundation
import OpenGrokConfig

/// Resolved once: `protectedEditPath` needs it on every edit request, and the
/// answer cannot change within a process.
let userGrokHomePath: String? = userGrokHome()?.path

/// Interactive prompter seam. Headless implementations return deny/cancel.
public protocol PermissionPrompter: Sendable {
    func prompt(
        access: AccessKind,
        toolName: String,
        toolCallId: String
    ) async -> PermissionDecision
}

/// Headless prompter that denies without interaction.
public struct HeadlessPermissionPrompter: PermissionPrompter {
    public init() {}
    public func prompt(
        access: AccessKind,
        toolName: String,
        toolCallId: String
    ) async -> PermissionDecision {
        _ = (access, toolName, toolCallId)
        return .reject("permission prompt unavailable in headless mode")
    }
}

/// Auto-mode classifier seam.
public protocol PermissionClassifier: Sendable {
    func classify(access: AccessKind, toolName: String) async -> PermissionDecision

    func classify(
        access: AccessKind,
        toolName: String,
        accessDetail: String?,
        transcript: String
    ) async -> PermissionDecision
}

extension PermissionClassifier {
    /// Default ignores detail/transcript so existing two-parameter classifiers compile.
    public func classify(
        access: AccessKind,
        toolName: String,
        accessDetail: String?,
        transcript: String
    ) async -> PermissionDecision {
        _ = (accessDetail, transcript)
        return await classify(access: access, toolName: toolName)
    }
}

/// Always-ask classifier (safe default).
public struct AskPermissionClassifier: PermissionClassifier {
    public init() {}
    public func classify(access: AccessKind, toolName: String) async -> PermissionDecision {
        _ = (access, toolName)
        return .ask
    }
}

/// Mutable permission handle for a session.
public actor PermissionHandle {
    public private(set) var config: PermissionConfig
    public private(set) var policy: CompiledPolicy
    public private(set) var yoloMode: Bool
    public private(set) var autoMode: Bool
    public private(set) var yoloPinReason: String?
    public private(set) var sessionGrants: [SessionGrant]
    public private(set) var bashPrefixGrants: [String]
    public private(set) var bashDisallows: [String]
    public private(set) var allowAll: Bool
    public private(set) var allowEditsForSession: Bool
    public private(set) var editPolicy: EditPolicy
    /// Workspace cwd used for shell file-access path resolution.
    public var shellCwd: String
    public var prompter: any PermissionPrompter
    public var classifier: (any PermissionClassifier)?
    public let sandboxAutoAllowBash: @Sendable () -> Bool
    public private(set) var events: [PermissionEvent]
    /// Last matched rule source for auditing (deny/ask/allow).
    public private(set) var lastMatchedRuleSource: PermissionRuleSource?
    /// Flat transcript fed to the auto-mode classifier (hostile-intent scan + LLM context).
    public private(set) var classifierTranscript: String
    /// Optional AGENTS.md / project instructions for the LLM classifier prompt.
    public private(set) var classifierProjectInstructions: String?
    /// True when the installed classifier is an `LlmPermissionClassifier` with a live side-query.
    public private(set) var hasLLMSideQuery: Bool

    public init(
        config: PermissionConfig = PermissionConfig(),
        yoloMode: Bool = false,
        autoMode: Bool = false,
        yoloPinReason: String? = nil,
        allowAll: Bool = false,
        shellCwd: String = FileManager.default.currentDirectoryPath,
        prompter: any PermissionPrompter = HeadlessPermissionPrompter(),
        /// Production default is the Rust heuristic classifier. Tests that need
        /// a fixed or absent classifier pass one explicitly (or `nil`).
        classifier: (any PermissionClassifier)? = HeuristicPermissionClassifier(),
        sandboxAutoAllowBash: @Sendable @escaping () -> Bool = { false }
    ) {
        var cfg = config
        if yoloPinReason != nil {
            cfg.rules = clampRulesForYoloPin(cfg.rules)
        }
        self.config = cfg
        // Path rules anchor against the session cwd, so a rule written
        // `Edit(src/**)` matches the absolute path a tool actually receives.
        self.policy = CompiledPolicy(
            config: cfg,
            pathContext: PathRuleContext(cwd: shellCwd)
        )
        self.yoloMode = yoloPinReason != nil ? false : yoloMode
        self.autoMode = autoMode
        self.yoloPinReason = yoloPinReason
        self.sessionGrants = []
        self.bashPrefixGrants = []
        self.bashDisallows = []
        self.allowAll = allowAll
        self.allowEditsForSession = false
        self.editPolicy = .ask
        self.shellCwd = shellCwd
        self.prompter = prompter
        self.classifier = classifier
        self.sandboxAutoAllowBash = sandboxAutoAllowBash
        self.events = []
        self.lastMatchedRuleSource = nil
        self.classifierTranscript = ""
        self.classifierProjectInstructions = nil
        self.hasLLMSideQuery = Self.sideQueryEnabled(classifier)
    }

    public func setYoloMode(_ enabled: Bool) {
        // Authoritative re-clamp under pin — no optimistic true window.
        if yoloPinReason != nil {
            yoloMode = false
            return
        }
        yoloMode = enabled
        if enabled { autoMode = false }
    }

    public func setAutoMode(_ enabled: Bool) {
        autoMode = enabled
        if enabled { yoloMode = false }
    }

    public func setClassifier(_ classifier: (any PermissionClassifier)?) {
        self.classifier = classifier
        self.hasLLMSideQuery = Self.sideQueryEnabled(classifier)
    }

    public func setClassifierTranscript(_ transcript: String) {
        classifierTranscript = transcript
    }

    public func setClassifierProjectInstructions(_ instructions: String?) {
        classifierProjectInstructions = instructions
    }

    private static func sideQueryEnabled(_ classifier: (any PermissionClassifier)?) -> Bool {
        guard let llm = classifier as? LlmPermissionClassifier else { return false }
        return llm.hasSideQuery
    }

    public func setAllowEditsForSession(_ enabled: Bool) {
        allowEditsForSession = enabled
    }

    public func setEditPolicy(_ policy: EditPolicy) {
        editPolicy = policy
    }

    public func replaceConfig(_ config: PermissionConfig) {
        var cfg = config
        if yoloPinReason != nil {
            cfg.rules = clampRulesForYoloPin(cfg.rules)
        }
        self.config = cfg
        self.policy = CompiledPolicy(
            config: cfg,
            pathContext: PathRuleContext(cwd: shellCwd)
        )
    }

    public func grant(_ grant: SessionGrant) {
        sessionGrants.append(grant)
        if case .bash(let cmd) = grant.access, grant.scope != .once {
            bashPrefixGrants.append(grant.pattern ?? cmd)
        }
        if case .edit = grant.access, grant.scope == .session {
            allowEditsForSession = true
        }
    }

    public func disallowBashPrefix(_ prefix: String) {
        bashDisallows.append(prefix)
    }

    public func resetState() {
        sessionGrants.removeAll()
        bashPrefixGrants.removeAll()
        allowEditsForSession = false
        // keep disallows / pin / config
    }

    /// Core request path matching the Rust permission actor order.
    public func request(
        access: AccessKind,
        toolName: String,
        toolCallId: String
    ) async -> PermissionDecision {
        lastMatchedRuleSource = nil
        if allowAll {
            record(
                access: access,
                toolName: toolName,
                toolCallId: toolCallId,
                decision: .allow,
                autoApproved: true,
                userPrompted: false,
                reason: "allow_all"
            )
            return .allow
        }

        var policyForcedPrompt = false
        var shellFileForcedPrompt = false
        var autoForcedPrompt = false

        // 1. Compiled policy direct evaluate (deny > ask > allow).
        if let matched = policy.evaluateWithSource(access) {
            lastMatchedRuleSource = matched.ruleSource
            switch matched.decision {
            case .policyDeny(let reason), .reject(let reason):
                let decision = PermissionDecision.policyDeny(reason)
                record(
                    access: access, toolName: toolName, toolCallId: toolCallId,
                    decision: decision, autoApproved: false, userPrompted: false,
                    reason: "policy_deny", reject: reason
                )
                return decision
            case .ask:
                policyForcedPrompt = true
            case .allow:
                // Policy allow on the whole access short-circuits (YOLO not needed).
                record(
                    access: access, toolName: toolName, toolCallId: toolCallId,
                    decision: .allow, autoApproved: true, userPrompted: false,
                    reason: "policy_allow"
                )
                return .allow
            case .followupMessage, .cancelled:
                record(
                    access: access, toolName: toolName, toolCallId: toolCallId,
                    decision: matched.decision, autoApproved: false, userPrompted: false,
                    reason: "policy"
                )
                return matched.decision
            }
        }

        // 2. Bash segment policy + shell file-access escalation (never Allow).
        if case .bash(let cmd) = access {
            if let bashDecision = policy.evaluateBashCommandPolicy(cmd) {
                switch bashDecision {
                case .policyDeny, .reject:
                    record(
                        access: access, toolName: toolName, toolCallId: toolCallId,
                        decision: bashDecision, autoApproved: false, userPrompted: false,
                        reason: "bash_policy"
                    )
                    return bashDecision
                case .ask:
                    policyForcedPrompt = true
                default:
                    break
                }
            }
            if let shellDecision = policy.evaluateShellFileAccess(cmd, cwd: shellCwd) {
                switch shellDecision {
                case .policyDeny, .reject:
                    record(
                        access: access, toolName: toolName, toolCallId: toolCallId,
                        decision: shellDecision, autoApproved: false, userPrompted: false,
                        reason: "shell_file_access"
                    )
                    return shellDecision
                case .ask:
                    shellFileForcedPrompt = true
                    policyForcedPrompt = true
                default:
                    break
                }
            }
        }

        // Protected edit paths always force prompt (not YOLO-bypassable for safety lists
        // but YOLO still allows — Rust YOLO short-circuits after policy/shell ask).
        var protectedEdit = false
        if case .edit(let path) = access {
            // Passing the user grok home is what makes
            // `$OPENGROK_HOME/config.toml` and `$OPENGROK_HOME/hooks/**`
            // protected, not just the `.opengrok/` forms.
            protectedEdit = protectedEditPath(path, userGrokHome: userGrokHomePath)
        }

        // 3. YOLO / always-approve (blocked by policy/shell Ask; pin keeps false).
        if yoloMode && yoloPinReason == nil && !policyForcedPrompt {
            record(
                access: access, toolName: toolName, toolCallId: toolCallId,
                decision: .allow, autoApproved: true, userPrompted: false,
                reason: "yolo"
            )
            return .allow
        }

        // 4. Session grants (before auto classifier). Shell-file forced asks
        // still prompt; protected edits still prompt.
        if matchesSessionGrant(access), !shellFileForcedPrompt {
            let blockProtected: Bool
            if case .edit = access, protectedEdit {
                blockProtected = true
            } else {
                blockProtected = false
            }
            if !blockProtected {
                record(
                    access: access, toolName: toolName, toolCallId: toolCallId,
                    decision: .allow, autoApproved: true, userPrompted: false,
                    reason: "session_grant"
                )
                return .allow
            }
        }

        // 5. Built-in auto-allows / bash safe classification.
        if !policyForcedPrompt {
            switch access {
            case .read, .grep, .webSearch:
                record(
                    access: access, toolName: toolName, toolCallId: toolCallId,
                    decision: .allow, autoApproved: true, userPrompted: false,
                    reason: "safe_command"
                )
                return .allow
            case .edit:
                if allowEditsForSession && !protectedEdit {
                    record(
                        access: access, toolName: toolName, toolCallId: toolCallId,
                        decision: .allow, autoApproved: true, userPrompted: false,
                        reason: "persisted_grant"
                    )
                    return .allow
                }
                if editPolicy == .reject {
                    let d = PermissionDecision.reject("edits prohibited")
                    record(
                        access: access, toolName: toolName, toolCallId: toolCallId,
                        decision: d, autoApproved: false, userPrompted: false,
                        reason: "session_deny"
                    )
                    return d
                }
            case .bash(let cmd):
                let seg = evaluateBashSegments(
                    cmd,
                    grants: bashPrefixGrants,
                    disallows: bashDisallows
                )
                if let reason = seg.reason, reason == "disallow" {
                    let d = PermissionDecision.reject("bash prefix disallowed")
                    record(
                        access: access, toolName: toolName, toolCallId: toolCallId,
                        decision: d, autoApproved: false, userPrompted: false,
                        reason: "session_deny"
                    )
                    return d
                }
                if seg.autoAllow && !seg.needsPrompt,
                   bashSandboxAutoAllow(cmd, exactGrants: bashPrefixGrants) {
                    record(
                        access: access, toolName: toolName, toolCallId: toolCallId,
                        decision: .allow, autoApproved: true, userPrompted: false,
                        reason: "safe_command"
                    )
                    return .allow
                }
            case .mcpTool, .webFetch:
                break
            }
        } else if case .bash(let cmd) = access {
            // Still honor hard disallow under ask floor.
            let seg = evaluateBashSegments(
                cmd,
                grants: bashPrefixGrants,
                disallows: bashDisallows
            )
            if let reason = seg.reason, reason == "disallow" {
                let d = PermissionDecision.reject("bash prefix disallowed")
                record(
                    access: access, toolName: toolName, toolCallId: toolCallId,
                    decision: d, autoApproved: false, userPrompted: false,
                    reason: "session_deny"
                )
                return d
            }
        }

        // 6. Auto mode classifier (not when policy forced prompt).
        if autoMode, !policyForcedPrompt, let classifier {
            let classified: PermissionDecision
            if let llm = classifier as? LlmPermissionClassifier {
                // Prefer the outcome API so Unavailable (timeout/transport)
                // forces a prompt rather than a silent deny.
                let outcome = await llm.classifyOutcome(
                    toolName: toolName,
                    access: access,
                    accessDetail: access.detail,
                    context: ClassifierContext(
                        transcript: classifierTranscript,
                        projectInstructions: classifierProjectInstructions
                    )
                )
                switch outcome.verdict {
                case .allow:
                    classified = .allow
                case .block:
                    classified = .policyDeny(
                        outcome.reason ?? "auto mode: classifier blocked"
                    )
                case .unavailable:
                    classified = .ask
                }
            } else {
                classified = await classifier.classify(
                    access: access,
                    toolName: toolName,
                    accessDetail: access.detail,
                    transcript: classifierTranscript
                )
            }
            if case .allow = classified {
                record(
                    access: access, toolName: toolName, toolCallId: toolCallId,
                    decision: .allow, autoApproved: true, userPrompted: false,
                    reason: "auto_classifier_allow"
                )
                return .allow
            }
            if case .policyDeny = classified {
                record(
                    access: access, toolName: toolName, toolCallId: toolCallId,
                    decision: classified, autoApproved: false, userPrompted: false,
                    reason: "auto_classifier_block"
                )
                return classified
            }
            if case .ask = classified {
                autoForcedPrompt = true
            }
        }

        // Sandbox auto-approval is intentionally later than policy, hooks,
        // shell-file escalation, and auto classification. The Bash floor helper
        // keeps opaque shell, dangerous segments, executable indirection,
        // unsafe environment assignments, and real-file writes on the prompt
        // path even when the OS sandbox is active.
        if case .bash(let cmd) = access,
           !policyForcedPrompt,
           !autoForcedPrompt,
           sandboxAutoAllowBash(),
           bashSandboxAutoAllow(cmd, exactGrants: bashPrefixGrants) {
            record(
                access: access, toolName: toolName, toolCallId: toolCallId,
                decision: .allow, autoApproved: true, userPrompted: false,
                reason: "sandbox_auto"
            )
            return .allow
        }

        // 7. Prompt policy.
        switch config.promptPolicy {
        case .deny:
            let d = PermissionDecision.policyDeny("prompt policy: dontAsk")
            record(
                access: access, toolName: toolName, toolCallId: toolCallId,
                decision: d, autoApproved: false, userPrompted: false,
                reason: "prompt_deny"
            )
            return d
        case .auto:
            return await promptPath(
                access: access, toolName: toolName, toolCallId: toolCallId,
                reason: policyForcedPrompt ? "policy_ask" : "auto_needs_user"
            )
        case .ask:
            return await promptPath(
                access: access, toolName: toolName, toolCallId: toolCallId,
                reason: policyForcedPrompt ? "policy_ask" : "needs_user"
            )
        }
    }

    private func promptPath(
        access: AccessKind,
        toolName: String,
        toolCallId: String,
        reason: String
    ) async -> PermissionDecision {
        let decision = await prompter.prompt(
            access: access,
            toolName: toolName,
            toolCallId: toolCallId
        )
        record(
            access: access, toolName: toolName, toolCallId: toolCallId,
            decision: decision, autoApproved: false, userPrompted: true,
            reason: reason
        )
        return decision
    }

    private func matchesSessionGrant(_ access: AccessKind) -> Bool {
        for g in sessionGrants {
            switch (g.access, access) {
            case (.edit, .edit(let path)):
                if let pat = g.pattern {
                    if globMatches(text: path, pattern: pat, pathContext: true) { return true }
                } else {
                    return true
                }
            case (.read, .read(let path)):
                if let pat = g.pattern, let path {
                    if globMatches(text: path, pattern: pat, pathContext: true) { return true }
                } else if g.pattern == nil {
                    return true
                }
            case (.bash, .bash(let cmd)):
                let prefix = g.pattern ?? {
                    if case .bash(let c) = g.access { return c }
                    return ""
                }()
                if cmd.trimmingCharacters(in: .whitespaces).hasPrefix(prefix) { return true }
            case (.mcpTool(let n, _), .mcpTool(let name, _)):
                if n == name { return true }
            case (.webFetch, .webFetch(let url)):
                if let pat = g.pattern, domainMatches(pattern: pat, url: url) { return true }
            default:
                continue
            }
        }
        return false
    }

    private func record(
        access: AccessKind,
        toolName: String,
        toolCallId: String,
        decision: PermissionDecision,
        autoApproved: Bool,
        userPrompted: Bool,
        reason: String,
        reject: String? = nil
    ) {
        let decisionStr: String
        var rejectReason = reject
        switch decision {
        case .allow: decisionStr = "allow"
        case .ask: decisionStr = "ask"
        case .followupMessage: decisionStr = "followup"
        case .reject(let r):
            decisionStr = "reject"
            rejectReason = r
        case .policyDeny(let r):
            decisionStr = "policy_deny"
            rejectReason = r
        case .cancelled:
            decisionStr = "cancelled"
        }
        events.append(PermissionEvent(
            toolId: toolCallId,
            toolName: toolName,
            accessKind: access.label,
            accessDetail: access.detail,
            yoloMode: yoloMode,
            autoApproved: autoApproved,
            userPrompted: userPrompted,
            decision: decisionStr,
            rejectReason: rejectReason,
            decisionReason: reason,
            permissionMode: yoloMode ? "always-approve" : (autoMode ? "auto" : "ask"),
            ruleSource: lastMatchedRuleSource?.rawValue
        ))
    }
}
