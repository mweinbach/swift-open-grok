// PermissionManager.swift
//
// Permission request pipeline: policy → YOLO/auto → grants → prompt.
// Ported conceptually from `xai-grok-workspace/src/permission/manager.rs`
// without the full actor runtime (session wiring lands later).

import Foundation

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
    public var prompter: any PermissionPrompter
    public var classifier: (any PermissionClassifier)?
    public private(set) var events: [PermissionEvent]

    public init(
        config: PermissionConfig = PermissionConfig(),
        yoloMode: Bool = false,
        autoMode: Bool = false,
        yoloPinReason: String? = nil,
        allowAll: Bool = false,
        prompter: any PermissionPrompter = HeadlessPermissionPrompter()
    ) {
        var cfg = config
        if let pin = yoloPinReason {
            cfg.rules = clampRulesForYoloPin(cfg.rules)
            _ = pin
        }
        self.config = cfg
        self.policy = CompiledPolicy(config: cfg)
        self.yoloMode = yoloPinReason != nil ? false : yoloMode
        self.autoMode = autoMode
        self.yoloPinReason = yoloPinReason
        self.sessionGrants = []
        self.bashPrefixGrants = []
        self.bashDisallows = []
        self.allowAll = allowAll
        self.prompter = prompter
        self.classifier = nil
        self.events = []
    }

    public func setYoloMode(_ enabled: Bool) {
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

    public func replaceConfig(_ config: PermissionConfig) {
        var cfg = config
        if yoloPinReason != nil {
            cfg.rules = clampRulesForYoloPin(cfg.rules)
        }
        self.config = cfg
        self.policy = CompiledPolicy(config: cfg)
    }

    public func grant(_ grant: SessionGrant) {
        sessionGrants.append(grant)
        if case .bash(let cmd) = grant.access, grant.scope != .once {
            bashPrefixGrants.append(grant.pattern ?? cmd)
        }
    }

    public func disallowBashPrefix(_ prefix: String) {
        bashDisallows.append(prefix)
    }

    public func resetState() {
        sessionGrants.removeAll()
        bashPrefixGrants.removeAll()
        // keep disallows / pin / config
    }

    /// Core request path matching the Rust permission actor order.
    public func request(
        access: AccessKind,
        toolName: String,
        toolCallId: String
    ) async -> PermissionDecision {
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

        // 1. Compiled policy direct evaluate.
        if let decision = policy.evaluate(access) {
            switch decision {
            case .policyDeny(let reason):
                record(
                    access: access, toolName: toolName, toolCallId: toolCallId,
                    decision: decision, autoApproved: false, userPrompted: false,
                    reason: "policy_deny", reject: reason
                )
                return decision
            case .ask:
                // Force prompt path (blocks YOLO).
                return await promptPath(
                    access: access, toolName: toolName, toolCallId: toolCallId,
                    reason: "policy_ask"
                )
            case .allow:
                record(
                    access: access, toolName: toolName, toolCallId: toolCallId,
                    decision: .allow, autoApproved: true, userPrompted: false,
                    reason: "policy_allow"
                )
                return .allow
            default:
                record(
                    access: access, toolName: toolName, toolCallId: toolCallId,
                    decision: decision, autoApproved: false, userPrompted: false,
                    reason: "policy"
                )
                return decision
            }
        }

        // 2. Bash segment policy (escalation only).
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
                    return await promptPath(
                        access: access, toolName: toolName, toolCallId: toolCallId,
                        reason: "bash_ask"
                    )
                default:
                    break
                }
            }
        }

        // 3. YOLO / always-approve (unless shell-forced ask already returned).
        if yoloMode && yoloPinReason == nil {
            record(
                access: access, toolName: toolName, toolCallId: toolCallId,
                decision: .allow, autoApproved: true, userPrompted: false,
                reason: "yolo"
            )
            return .allow
        }

        // 4. Session grants.
        if matchesSessionGrant(access) {
            record(
                access: access, toolName: toolName, toolCallId: toolCallId,
                decision: .allow, autoApproved: true, userPrompted: false,
                reason: "session_grant"
            )
            return .allow
        }

        // 5. Bash safe/dangerous/grants classification.
        if case .bash(let cmd) = access {
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
            if seg.autoAllow {
                record(
                    access: access, toolName: toolName, toolCallId: toolCallId,
                    decision: .allow, autoApproved: true, userPrompted: false,
                    reason: "safe_command"
                )
                return .allow
            }
        }

        // 6. Auto mode classifier.
        if autoMode, let classifier {
            let classified = await classifier.classify(access: access, toolName: toolName)
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
                reason: "auto_needs_user"
            )
        case .ask:
            return await promptPath(
                access: access, toolName: toolName, toolCallId: toolCallId,
                reason: "needs_user"
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
            permissionMode: yoloMode ? "always-approve" : (autoMode ? "auto" : "ask")
        ))
    }
}
