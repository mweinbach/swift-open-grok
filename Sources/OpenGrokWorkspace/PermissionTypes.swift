// PermissionTypes.swift
//
// Access kinds, decisions, rule vocabulary. Ported from
// `xai-grok-workspace/src/permission/types.rs`.

import Foundation
import OpenGrokShared

// MARK: - Access / Decision

/// Kind of resource access requested by a tool call.
public enum AccessKind: Sendable, Equatable, Hashable {
    case read(String?)
    case grep(path: String?, glob: String?)
    case edit(String)
    case bash(String)
    case mcpTool(name: String, input: JSONValue)
    case webFetch(String)
    case webSearch(String)

    public var label: String {
        switch self {
        case .read: return "read"
        case .grep: return "grep"
        case .edit: return "edit"
        case .bash: return "bash"
        case .mcpTool: return "mcp"
        case .webFetch: return "web_fetch"
        case .webSearch: return "web_search"
        }
    }

    public var detail: String? {
        switch self {
        case .read(let p): return p
        case .grep(let path, _): return path
        case .edit(let p): return p
        case .bash(let c): return c
        case .mcpTool(let name, _): return name
        case .webFetch(let u): return u
        case .webSearch(let q): return q
        }
    }
}

/// Outcome of a permission evaluation.
public enum PermissionDecision: Sendable, Equatable, Hashable {
    case allow
    /// A policy `ask` rule matched; prompt the user.
    case ask
    case followupMessage(String)
    case reject(String)
    /// Managed/config deny — return error to the model; do not cancel the turn.
    case policyDeny(String)
    /// User cancelled (e.g. Cmd+C during prompt).
    case cancelled

    public var isAllow: Bool {
        if case .allow = self { return true }
        return false
    }
}

public enum EditPolicy: String, Codable, Sendable, Equatable {
    case ask
    case allow
    case reject
}

public enum PromptPolicy: String, Codable, Sendable, Equatable, CaseIterable {
    case ask
    case deny
    case auto
}

public enum PatternMode: String, Codable, Sendable, Equatable {
    case glob
    case domain
}

public enum RuleAction: String, Codable, Sendable, Equatable {
    case allow
    case deny
    case ask
}

public enum ToolFilter: String, Codable, Sendable, Equatable, CaseIterable {
    case any
    case bash
    case edit
    case read
    case grep
    case mcp
    case webFetch = "web_fetch"
    case webSearch = "web_search"
}

/// A single permission rule.
public struct PermissionRule: Codable, Sendable, Equatable, Hashable {
    public var action: RuleAction
    public var tool: ToolFilter
    public var pattern: String?
    public var patternMode: PatternMode
    /// Provenance for inspect / YOLO pin filtering.
    public var source: PermissionRuleSource

    public init(
        action: RuleAction,
        tool: ToolFilter = .any,
        pattern: String? = nil,
        patternMode: PatternMode = .glob,
        source: PermissionRuleSource = .unknown
    ) {
        self.action = action
        self.tool = tool
        self.pattern = pattern
        self.patternMode = patternMode
        self.source = source
    }
}

public enum PermissionRuleSource: String, Codable, Sendable, Equatable, Hashable {
    case unknown
    case requirements
    case systemRequirements = "system_requirements"
    case managedSettings = "managed_settings"
    case managedConfig = "managed_config"
    case config
    case settings
    case cli
    case synthetic

    /// Admin-tier sources may keep catch-all Allow rules under YOLO pin.
    public var isAdminTier: Bool {
        switch self {
        case .systemRequirements, .managedSettings: return true
        default: return false
        }
    }
}

public struct PermissionConfig: Codable, Sendable, Equatable {
    public var rules: [PermissionRule]
    public var promptPolicy: PromptPolicy

    public init(rules: [PermissionRule] = [], promptPolicy: PromptPolicy = .ask) {
        self.rules = rules
        self.promptPolicy = promptPolicy
    }
}

// MARK: - Grant scopes

public enum PermissionGrantScope: String, Codable, Sendable, Equatable {
    case once
    case session
    case project
}

public struct SessionGrant: Sendable, Equatable, Hashable {
    public var access: AccessKind
    public var scope: PermissionGrantScope
    public var pattern: String?

    public init(access: AccessKind, scope: PermissionGrantScope, pattern: String? = nil) {
        self.access = access
        self.scope = scope
        self.pattern = pattern
    }
}

// MARK: - Telemetry event

public struct PermissionEvent: Codable, Sendable, Equatable {
    public var toolId: String
    public var toolName: String
    public var accessKind: String
    public var accessDetail: String?
    public var yoloMode: Bool
    public var autoApproved: Bool
    public var userPrompted: Bool
    public var decision: String
    public var promptOutcome: String?
    public var rejectReason: String?
    public var timestamp: Date
    public var decisionReason: String?
    public var permissionMode: String?
    /// Auditable rule provenance when a policy rule matched.
    public var ruleSource: String?

    public init(
        toolId: String,
        toolName: String,
        accessKind: String,
        accessDetail: String? = nil,
        yoloMode: Bool,
        autoApproved: Bool,
        userPrompted: Bool,
        decision: String,
        promptOutcome: String? = nil,
        rejectReason: String? = nil,
        timestamp: Date = Date(),
        decisionReason: String? = nil,
        permissionMode: String? = nil,
        ruleSource: String? = nil
    ) {
        self.toolId = toolId
        self.toolName = toolName
        self.accessKind = accessKind
        self.accessDetail = accessDetail
        self.yoloMode = yoloMode
        self.autoApproved = autoApproved
        self.userPrompted = userPrompted
        self.decision = decision
        self.promptOutcome = promptOutcome
        self.rejectReason = rejectReason
        self.timestamp = timestamp
        self.decisionReason = decisionReason
        self.permissionMode = permissionMode
        self.ruleSource = ruleSource
    }
}

/// Policy match with auditable rule source.
public struct PolicyMatch: Sendable, Equatable {
    public var decision: PermissionDecision
    public var ruleSource: PermissionRuleSource?
    public var pattern: String?

    public init(
        decision: PermissionDecision,
        ruleSource: PermissionRuleSource? = nil,
        pattern: String? = nil
    ) {
        self.decision = decision
        self.ruleSource = ruleSource
        self.pattern = pattern
    }
}

// MARK: - Client type

public enum PermissionClientType: String, Codable, Sendable, Equatable {
    case generic
    case grokTUI = "grok-tui"
    case grokWeb = "grok_web"
    case nebula
    case extensionClient = "extension"
    case grokPager = "grok-pager"
    case desktop = "grok_desktop"

    public static func from(clientIdentifier: String?) -> PermissionClientType {
        switch clientIdentifier {
        case "grok-web": return .grokWeb
        case "nebula": return .nebula
        case "grok-code-extension": return .extensionClient
        case "grok-desktop": return .desktop
        case "grok-pager": return .grokPager
        case "grok-tui": return .grokTUI
        default: return .generic
        }
    }
}

// MARK: - Default mode

public enum DefaultPermissionMode: String, Sendable, Equatable {
    case `default`
    case acceptEdits
    case plan
    case auto
    case dontAsk
    case bypassPermissions

    public init(parsing raw: String) {
        switch raw {
        case "default": self = .default
        case "acceptEdits": self = .acceptEdits
        case "plan": self = .plan
        case "auto": self = .auto
        case "dontAsk": self = .dontAsk
        case "bypassPermissions": self = .bypassPermissions
        default: self = .default
        }
    }

    public var effects: DefaultModeEffects {
        switch self {
        case .acceptEdits:
            return DefaultModeEffects(promptPolicy: .ask, acceptEdits: true, bypassPermissions: false)
        case .bypassPermissions:
            return DefaultModeEffects(promptPolicy: .ask, acceptEdits: false, bypassPermissions: true)
        case .dontAsk:
            return DefaultModeEffects(promptPolicy: .deny, acceptEdits: false, bypassPermissions: false)
        case .auto:
            return DefaultModeEffects(promptPolicy: .auto, acceptEdits: false, bypassPermissions: false)
        case .default, .plan:
            return DefaultModeEffects()
        }
    }
}

public struct DefaultModeEffects: Sendable, Equatable {
    public var promptPolicy: PromptPolicy
    public var acceptEdits: Bool
    public var bypassPermissions: Bool

    public init(
        promptPolicy: PromptPolicy = .ask,
        acceptEdits: Bool = false,
        bypassPermissions: Bool = false
    ) {
        self.promptPolicy = promptPolicy
        self.acceptEdits = acceptEdits
        self.bypassPermissions = bypassPermissions
    }
}

public let yoloPinReasonRequirements = "requirements"
public let yoloPinReasonLegacyYolo = "legacy_yolo"
