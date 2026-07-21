// OpenGrokHooksPluginTypes.swift
//
// Shared DTO types for hooks/plugins ACP extensions. Ported from the Rust
// crate `crates/codegen/xai-hooks-plugins-types` (single `src/lib.rs`).
//
// This target defines the wire format for `x.ai/hooks/*` and
// `x.ai/plugins/*` ACP extension methods. It is dependency-free (only
// `Foundation`) so both `OpenGrokShell` and `OpenGrokPager` can depend on
// it without pulling in domain logic.
//
// Conversion from domain types (`HookSpec`, `LoadedPlugin`) to these DTOs
// lives in the shell's extension handlers, not here.
//
// Wire format
// -----------
// Wire-format struct fields use **camelCase** to match the existing pager
// ACP extension contract (`#[serde(rename_all = "camelCase")]` in the
// Rust crate). Tagged enums use `tag = "type"` with snake_case variant
// names (also matching the Rust crate).
//
// The `PluginOrigin.unknown` and `HookEvent`-like enums are forward-
// tolerant: an unrecognized variant from a newer shell degrades to
// `unknown` (for `PluginOrigin`) or fails to decode (for the simpler
// enums) rather than breaking the whole plugins list.

import Foundation

// MARK: - Enums

/// Plugin scope.
///
/// Maps from `PluginScope` in `xai-grok-agent`. Variant renames:
/// - source `CliOverride` -> DTO `cli` (matches Display output "cli")
/// - source `ConfigPath` -> DTO `config` (matches Display output "config")
public enum PluginScope: Hashable, Sendable, Codable, Equatable {
    case cli
    case project
    case user
    case config

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        switch raw {
        case "cli": self = .cli
        case "project": self = .project
        case "user": self = .user
        case "config": self = .config
        default:
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown PluginScope: \(raw)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .cli: try c.encode("cli")
        case .project: try c.encode("project")
        case .user: try c.encode("user")
        case .config: try c.encode("config")
        }
    }
}

/// The concrete discovery source a plugin came from.
///
/// Optional on `PluginInfo` so older shells (which don't send it)
/// deserialize to `nil`. Forward-tolerant: an unrecognized `type` tag from
/// a newer shell decodes to `unknown` rather than failing the whole
/// plugins list.
public enum PluginOrigin: Hashable, Sendable, Codable, Equatable {
    /// CLI `--plugin-dir`.
    case cliOverride
    /// Project `.opengrok/plugins/`.
    case projectGrok
    /// Project `.claude/plugins/`.
    case projectClaude
    /// `$OPENGROK_HOME/plugins/`.
    case userGrok
    /// `~/.claude/plugins/`.
    case userClaude
    /// A compat marketplace clone.
    case claudeMarketplace(marketplace: String)
    /// Compat install from `installed_plugins.json`.
    case claudeInstalled(marketplace: String?)
    /// Grok's install registry (marketplace or direct git/local install).
    case marketplaceInstall(sourceName: String?, gitUrl: String?)
    /// `[plugins].paths` in config.
    case configPath
    /// Catch-all for variants added after this client was built, so a
    /// newer shell never breaks an older pager's whole plugins list.
    /// Consumers must treat it like a missing origin.
    case unknown

    private enum Tag: String, Codable {
        case cliOverride = "cli_override"
        case projectGrok = "project_grok"
        case projectClaude = "project_claude"
        case userGrok = "user_grok"
        case userClaude = "user_claude"
        case claudeMarketplace = "claude_marketplace"
        case claudeInstalled = "claude_installed"
        case marketplaceInstall = "marketplace_install"
        case configPath = "config_path"
        case unknown
    }
    private enum CodingKeys: String, CodingKey {
        case type
        case marketplace
        case sourceName = "source_name"
        case gitUrl = "git_url"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .type)
        // Forward-tolerant: an unrecognized `type` tag decodes to `.unknown`
        // rather than throwing.
        guard let tag = Tag(rawValue: raw) else {
            self = .unknown
            return
        }
        switch tag {
        case .cliOverride: self = .cliOverride
        case .projectGrok: self = .projectGrok
        case .projectClaude: self = .projectClaude
        case .userGrok: self = .userGrok
        case .userClaude: self = .userClaude
        case .claudeMarketplace:
            self = .claudeMarketplace(marketplace: try c.decode(String.self, forKey: .marketplace))
        case .claudeInstalled:
            // `#[serde(default, skip_serializing_if = "Option::is_none")]`.
            self = .claudeInstalled(marketplace: try c.decodeIfPresent(String.self, forKey: .marketplace))
        case .marketplaceInstall:
            self = .marketplaceInstall(
                sourceName: try c.decodeIfPresent(String.self, forKey: .sourceName),
                gitUrl: try c.decodeIfPresent(String.self, forKey: .gitUrl)
            )
        case .configPath: self = .configPath
        case .unknown: self = .unknown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .cliOverride:
            try c.encode(Tag.cliOverride, forKey: .type)
        case .projectGrok:
            try c.encode(Tag.projectGrok, forKey: .type)
        case .projectClaude:
            try c.encode(Tag.projectClaude, forKey: .type)
        case .userGrok:
            try c.encode(Tag.userGrok, forKey: .type)
        case .userClaude:
            try c.encode(Tag.userClaude, forKey: .type)
        case .claudeMarketplace(let marketplace):
            try c.encode(Tag.claudeMarketplace, forKey: .type)
            try c.encode(marketplace, forKey: .marketplace)
        case .claudeInstalled(let marketplace):
            try c.encode(Tag.claudeInstalled, forKey: .type)
            // `skip_serializing_if = "Option::is_none"`.
            if let m = marketplace {
                try c.encode(m, forKey: .marketplace)
            }
        case .marketplaceInstall(let sourceName, let gitUrl):
            try c.encode(Tag.marketplaceInstall, forKey: .type)
            if let s = sourceName {
                try c.encode(s, forKey: .sourceName)
            }
            if let u = gitUrl {
                try c.encode(u, forKey: .gitUrl)
            }
        case .configPath:
            try c.encode(Tag.configPath, forKey: .type)
        case .unknown:
            try c.encode(Tag.unknown, forKey: .type)
        }
    }
}

/// Hook event type.
///
/// Maps from `HookEventName` in `xai-grok-hooks`. The source type's
/// `SubagentEnd` variant (backward-compat alias) is collapsed into
/// `subagentStop` during conversion.
public enum HookEvent: Hashable, Sendable, Codable, Equatable {
    case sessionStart
    case sessionEnd
    case stop
    case stopFailure
    case preToolUse
    case postToolUse
    case postToolUseFailure
    case permissionDenied
    case userPromptSubmit
    case notification
    case subagentStart
    case subagentStop
    case preCompact
    case postCompact

    private static let wireNames: [(HookEvent, String)] = [
        (.sessionStart, "session_start"),
        (.sessionEnd, "session_end"),
        (.stop, "stop"),
        (.stopFailure, "stop_failure"),
        (.preToolUse, "pre_tool_use"),
        (.postToolUse, "post_tool_use"),
        (.postToolUseFailure, "post_tool_use_failure"),
        (.permissionDenied, "permission_denied"),
        (.userPromptSubmit, "user_prompt_submit"),
        (.notification, "notification"),
        (.subagentStart, "subagent_start"),
        (.subagentStop, "subagent_stop"),
        (.preCompact, "pre_compact"),
        (.postCompact, "post_compact")
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        for (ev, name) in HookEvent.wireNames where name == raw {
            self = ev
            return
        }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown HookEvent: \(raw)")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        for (ev, name) in HookEvent.wireNames where ev == self {
            try c.encode(name)
            return
        }
        throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: "HookEvent has no wire name"))
    }
}

extension HookEvent: CustomStringConvertible {
    public var description: String {
        switch self {
        case .sessionStart: return "Session Start"
        case .preToolUse: return "Pre-Tool Use"
        case .postToolUse: return "Post-Tool Use"
        case .postToolUseFailure: return "Post-Tool Use Failure"
        case .sessionEnd: return "Session End"
        case .stop: return "Stop"
        case .stopFailure: return "Stop Failure"
        case .notification: return "Notification"
        case .userPromptSubmit: return "Prompt Submit"
        case .permissionDenied: return "Permission Denied"
        case .subagentStart: return "Subagent Start"
        case .subagentStop: return "Subagent Stop"
        case .preCompact: return "Pre-Compact"
        case .postCompact: return "Post-Compact"
        }
    }
}

/// Hook handler type.
public enum HookHandlerType: Hashable, Sendable, Codable, Equatable {
    case command
    case http

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        switch raw {
        case "command": self = .command
        case "http": self = .http
        default:
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown HookHandlerType: \(raw)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .command: try c.encode("command")
        case .http: try c.encode("http")
        }
    }
}

/// Plugin hook status — derived from trust + has_hooks + has_inline_hooks_only.
public enum HookStatus: Hashable, Sendable, Codable, Equatable {
    case active
    case activeInline
    case blocked
    case none

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        switch raw {
        case "active": self = .active
        case "active_inline": self = .activeInline
        case "blocked": self = .blocked
        case "none": self = .none
        default:
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown HookStatus: \(raw)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .active: try c.encode("active")
        case .activeInline: try c.encode("active_inline")
        case .blocked: try c.encode("blocked")
        case .none: try c.encode("none")
        }
    }
}

/// Plugin MCP server status — derived from trust + mcp_server_count +
/// has_inline_mcp_only.
public enum McpStatus: Hashable, Sendable, Codable, Equatable {
    case active
    case activeInline
    case blocked
    case none

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        switch raw {
        case "active": self = .active
        case "active_inline": self = .activeInline
        case "blocked": self = .blocked
        case "none": self = .none
        default:
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown McpStatus: \(raw)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .active: try c.encode("active")
        case .activeInline: try c.encode("active_inline")
        case .blocked: try c.encode("blocked")
        case .none: try c.encode("none")
        }
    }
}

/// Machine-readable outcome status for action responses.
public enum OutcomeStatus: Hashable, Sendable, Codable, Equatable {
    case success
    case validationError
    case confirmationRequired
    case notFound
    case internalError
    case unsupported

    private static let wireNames: [(OutcomeStatus, String)] = [
        (.success, "success"),
        (.validationError, "validation_error"),
        (.confirmationRequired, "confirmation_required"),
        (.notFound, "not_found"),
        (.internalError, "internal_error"),
        (.unsupported, "unsupported")
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        for (s, name) in OutcomeStatus.wireNames where name == raw {
            self = s
            return
        }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown OutcomeStatus: \(raw)")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        for (s, name) in OutcomeStatus.wireNames where s == self {
            try c.encode(name)
            return
        }
        throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: "OutcomeStatus has no wire name"))
    }
}

// MARK: - Hook types

/// A single hook's metadata for display in the pager.
public struct HookInfo: Hashable, Sendable, Codable, Equatable {
    /// Full name including scope prefix (e.g.,
    /// "global/safety:pre_tool_use[0].hooks[0]").
    public var name: String
    /// Event type this hook runs on.
    public var event: HookEvent
    /// Handler type.
    public var handlerType: HookHandlerType
    /// Raw matcher pattern from config (for display). `nil` = matches all
    /// tools. Maps from `HookSpec.configured_matcher` (not the compiled
    /// regex).
    public var matcher: String?
    /// Command path (for command handlers).
    public var command: String?
    /// HTTP URL (for http handlers).
    public var url: String?
    /// Timeout in milliseconds.
    public var timeoutMs: UInt64
    /// Source directory of the hook definition file.
    public var sourceDir: String
    /// Whether this hook is disabled via `~/.opengrok/disabled-hooks`.
    public var disabled: Bool

    public init(
        name: String,
        event: HookEvent,
        handlerType: HookHandlerType,
        matcher: String? = nil,
        command: String? = nil,
        url: String? = nil,
        timeoutMs: UInt64,
        sourceDir: String,
        disabled: Bool = false
    ) {
        self.name = name
        self.event = event
        self.handlerType = handlerType
        self.matcher = matcher
        self.command = command
        self.url = url
        self.timeoutMs = timeoutMs
        self.sourceDir = sourceDir
        self.disabled = disabled
    }

    enum CodingKeys: String, CodingKey {
        case name, event
        case handlerType = "handlerType"
        case matcher, command, url
        case timeoutMs = "timeoutMs"
        case sourceDir = "sourceDir"
        case disabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        event = try c.decode(HookEvent.self, forKey: .event)
        handlerType = try c.decode(HookHandlerType.self, forKey: .handlerType)
        matcher = try c.decodeIfPresent(String.self, forKey: .matcher)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        timeoutMs = try c.decode(UInt64.self, forKey: .timeoutMs)
        sourceDir = try c.decode(String.self, forKey: .sourceDir)
        // `#[serde(default)]` — missing `disabled` decodes to `false`.
        disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
    }
}

/// Response for `x.ai/hooks/list`.
public struct HooksListResponse: Hashable, Sendable, Codable, Equatable {
    public var hooks: [HookInfo]
    /// Whether the current project's git root is trusted for hook execution.
    public var projectTrusted: Bool
    /// Errors encountered while loading hook config files (parse failures,
    /// etc.).
    public var loadErrors: [String]

    public init(hooks: [HookInfo], projectTrusted: Bool, loadErrors: [String] = []) {
        self.hooks = hooks
        self.projectTrusted = projectTrusted
        self.loadErrors = loadErrors
    }

    enum CodingKeys: String, CodingKey {
        case hooks
        case projectTrusted = "projectTrusted"
        case loadErrors = "loadErrors"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hooks = try c.decode([HookInfo].self, forKey: .hooks)
        projectTrusted = try c.decode(Bool.self, forKey: .projectTrusted)
        // `#[serde(default, skip_serializing_if = "Vec::is_empty")]`.
        loadErrors = try c.decodeIfPresent([String].self, forKey: .loadErrors) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hooks, forKey: .hooks)
        try c.encode(projectTrusted, forKey: .projectTrusted)
        if !loadErrors.isEmpty {
            try c.encode(loadErrors, forKey: .loadErrors)
        }
    }
}

// MARK: - Plugin types

/// A single plugin's metadata for display in the pager.
public struct PluginInfo: Hashable, Sendable, Codable, Equatable {
    /// User-facing plugin name.
    public var name: String
    /// Stable plugin ID (format: "<scope>/<hex8>/<name>").
    public var id: String
    /// Absolute path to plugin root directory.
    public var root: String
    /// Plugin scope.
    public var scope: PluginScope
    /// Deprecated: always `true`. Trust/untrust has been replaced by
    /// enable/disable. Kept for serialization compatibility; will be
    /// removed.
    public var trusted: Bool
    /// Whether the plugin is enabled (not in `[plugins].disabled` list).
    public var enabled: Bool
    /// Version from manifest (if available).
    public var version: String?
    /// Description from manifest (if available).
    public var description: String?
    /// Number of skill subdirectories.
    public var skillCount: Int
    /// Skill names (directory names under `skills/`).
    public var skillNames: [String]
    /// Number of agent `.md` files.
    public var agentCount: Int
    /// Agent/persona names (filenames without `.md` extension).
    public var agentNames: [String]
    /// Hook status (active, active_inline, blocked, none).
    public var hookStatus: HookStatus
    /// Number of hook specs defined.
    public var hookCount: Int
    /// Number of MCP servers.
    public var mcpServerCount: Int
    /// MCP server status (active, active_inline, blocked, none).
    public var mcpStatus: McpStatus
    /// Marketplace source display name (`nil` for non-marketplace installs).
    public var marketplaceSource: String?
    /// The concrete discovery source (`nil` when sent by an older shell).
    public var origin: PluginOrigin?
    /// Warning when this plugin shadowed another with the same name.
    public var conflict: String?

    public init(
        name: String,
        id: String,
        root: String,
        scope: PluginScope,
        trusted: Bool,
        enabled: Bool,
        version: String? = nil,
        description: String? = nil,
        skillCount: Int = 0,
        skillNames: [String] = [],
        agentCount: Int = 0,
        agentNames: [String] = [],
        hookStatus: HookStatus,
        hookCount: Int = 0,
        mcpServerCount: Int = 0,
        mcpStatus: McpStatus,
        marketplaceSource: String? = nil,
        origin: PluginOrigin? = nil,
        conflict: String? = nil
    ) {
        self.name = name
        self.id = id
        self.root = root
        self.scope = scope
        self.trusted = trusted
        self.enabled = enabled
        self.version = version
        self.description = description
        self.skillCount = skillCount
        self.skillNames = skillNames
        self.agentCount = agentCount
        self.agentNames = agentNames
        self.hookStatus = hookStatus
        self.hookCount = hookCount
        self.mcpServerCount = mcpServerCount
        self.mcpStatus = mcpStatus
        self.marketplaceSource = marketplaceSource
        self.origin = origin
        self.conflict = conflict
    }

    enum CodingKeys: String, CodingKey {
        case name, id, root, scope, trusted, enabled, version, description
        case skillCount = "skillCount"
        case skillNames = "skillNames"
        case agentCount = "agentCount"
        case agentNames = "agentNames"
        case hookStatus = "hookStatus"
        case hookCount = "hookCount"
        case mcpServerCount = "mcpServerCount"
        case mcpStatus = "mcpStatus"
        case marketplaceSource = "marketplaceSource"
        case origin
        case conflict
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        id = try c.decode(String.self, forKey: .id)
        root = try c.decode(String.self, forKey: .root)
        scope = try c.decode(PluginScope.self, forKey: .scope)
        trusted = try c.decode(Bool.self, forKey: .trusted)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        skillCount = try c.decodeIfPresent(Int.self, forKey: .skillCount) ?? 0
        skillNames = try c.decodeIfPresent([String].self, forKey: .skillNames) ?? []
        agentCount = try c.decodeIfPresent(Int.self, forKey: .agentCount) ?? 0
        agentNames = try c.decodeIfPresent([String].self, forKey: .agentNames) ?? []
        hookStatus = try c.decode(HookStatus.self, forKey: .hookStatus)
        hookCount = try c.decodeIfPresent(Int.self, forKey: .hookCount) ?? 0
        mcpServerCount = try c.decodeIfPresent(Int.self, forKey: .mcpServerCount) ?? 0
        mcpStatus = try c.decode(McpStatus.self, forKey: .mcpStatus)
        marketplaceSource = try c.decodeIfPresent(String.self, forKey: .marketplaceSource)
        origin = try c.decodeIfPresent(PluginOrigin.self, forKey: .origin)
        conflict = try c.decodeIfPresent(String.self, forKey: .conflict)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(id, forKey: .id)
        try c.encode(root, forKey: .root)
        try c.encode(scope, forKey: .scope)
        try c.encode(trusted, forKey: .trusted)
        try c.encode(enabled, forKey: .enabled)
        try c.encodeIfPresent(version, forKey: .version)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encode(skillCount, forKey: .skillCount)
        // `#[serde(default, skip_serializing_if = "Vec::is_empty")]`.
        if !skillNames.isEmpty { try c.encode(skillNames, forKey: .skillNames) }
        try c.encode(agentCount, forKey: .agentCount)
        if !agentNames.isEmpty { try c.encode(agentNames, forKey: .agentNames) }
        try c.encode(hookStatus, forKey: .hookStatus)
        // `#[serde(default)]` — always emit.
        try c.encode(hookCount, forKey: .hookCount)
        try c.encode(mcpServerCount, forKey: .mcpServerCount)
        try c.encode(mcpStatus, forKey: .mcpStatus)
        try c.encodeIfPresent(marketplaceSource, forKey: .marketplaceSource)
        try c.encodeIfPresent(origin, forKey: .origin)
        try c.encodeIfPresent(conflict, forKey: .conflict)
    }
}

/// Response for `x.ai/plugins/list`.
public struct PluginsListResponse: Hashable, Sendable, Codable, Equatable {
    public var plugins: [PluginInfo]

    public init(plugins: [PluginInfo]) {
        self.plugins = plugins
    }

    enum CodingKeys: String, CodingKey { case plugins }
}

// MARK: - MCP server types

/// Source of an MCP server configuration.
public enum McpServerSource: Hashable, Sendable, Codable, Equatable {
    case managed
    case local

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        switch raw {
        case "managed": self = .managed
        case "local": self = .local
        default:
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown McpServerSource: \(raw)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .managed: try c.encode("managed")
        case .local: try c.encode("local")
        }
    }
}

/// Session-level status of an MCP server.
public enum McpSessionStatus: Hashable, Sendable, Codable, Equatable {
    case ready
    case initializing
    case unavailable

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        switch raw {
        case "ready": self = .ready
        case "initializing": self = .initializing
        case "unavailable": self = .unavailable
        default:
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown McpSessionStatus: \(raw)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .ready: try c.encode("ready")
        case .initializing: try c.encode("initializing")
        case .unavailable: try c.encode("unavailable")
        }
    }
}

/// A tool exposed by an MCP server.
public struct McpToolInfo: Hashable, Sendable, Codable, Equatable {
    public var name: String
    public var description: String?

    public init(name: String, description: String? = nil) {
        self.name = name
        self.description = description
    }

    enum CodingKeys: String, CodingKey { case name, description }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
    }
}

/// Summary of an MCP server for display in the pager.
public struct McpServerInfo: Hashable, Sendable, Codable, Equatable {
    public var name: String
    public var source: McpServerSource
    public var enabled: Bool
    public var status: McpSessionStatus?
    /// Number of tools this server exposes.
    public var toolCount: Int
    /// Tool names (for display when expanded).
    public var tools: [McpToolInfo]
    /// Config source label (e.g., "plugin: my-plugin", "config.toml",
    /// ".mcp.json").
    public var configSource: String?

    public init(
        name: String,
        source: McpServerSource,
        enabled: Bool,
        status: McpSessionStatus? = nil,
        toolCount: Int,
        tools: [McpToolInfo] = [],
        configSource: String? = nil
    ) {
        self.name = name
        self.source = source
        self.enabled = enabled
        self.status = status
        self.toolCount = toolCount
        self.tools = tools
        self.configSource = configSource
    }

    enum CodingKeys: String, CodingKey {
        case name, source, enabled, status
        case toolCount = "toolCount"
        case tools
        case configSource = "configSource"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        source = try c.decode(McpServerSource.self, forKey: .source)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        status = try c.decodeIfPresent(McpSessionStatus.self, forKey: .status)
        toolCount = try c.decode(Int.self, forKey: .toolCount)
        tools = try c.decodeIfPresent([McpToolInfo].self, forKey: .tools) ?? []
        configSource = try c.decodeIfPresent(String.self, forKey: .configSource)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(source, forKey: .source)
        try c.encode(enabled, forKey: .enabled)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encode(toolCount, forKey: .toolCount)
        if !tools.isEmpty { try c.encode(tools, forKey: .tools) }
        try c.encodeIfPresent(configSource, forKey: .configSource)
    }
}

/// Response for `x.ai/mcp/list` as consumed by the pager.
public struct McpServersListResponse: Hashable, Sendable, Codable, Equatable {
    public var servers: [McpServerInfo]

    public init(servers: [McpServerInfo]) {
        self.servers = servers
    }

    enum CodingKeys: String, CodingKey { case servers }
}

// MARK: - Plugin component inventory (from marketplace catalogs)

/// Maximum name length for a `ComponentItem` (defends against terminal-
/// escape injection from catalog-supplied strings).
public let MAX_COMPONENT_NAME_CHARS: Int = 120

/// Maximum description length for a `ComponentItem`.
public let MAX_COMPONENT_DESC_CHARS: Int = 120

/// Maximum items kept per component category when sanitizing catalog data.
public let MAX_COMPONENTS_PER_CATEGORY: Int = 50

/// One concrete thing a plugin provides (a skill, command, agent, etc.).
public struct ComponentItem: Hashable, Sendable, Codable, Equatable {
    public var name: String
    public var description: String?

    public init(name: String, description: String? = nil) {
        // Mirrors `ComponentItem::new` — sanitize on construction.
        var item = ComponentItem.unsanitized(name: name, description: description)
        item.sanitize()
        self = item
    }

    /// Construct without sanitizing. Used by Codable decode (which must
    /// match the wire bytes verbatim) and by `PluginComponents.sanitize`
    /// (which sanitizes in place after decoding).
    public static func unsanitized(name: String, description: String?) -> ComponentItem {
        ComponentItem(name: name, description: description, sanitized: ())
    }

    /// Private sanitized-marker initializer.
    private init(name: String, description: String?, sanitized: ()) {
        self.name = name
        self.description = description
    }

    /// Codable uses the unsanitized path so wire bytes round-trip
    /// verbatim; consumers that render catalog-derived data to a terminal
    /// must call `sanitize()` at the ingestion point.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
    }

    enum CodingKeys: String, CodingKey { case name, description }

    /// Strip control characters and truncate the name and description in
    /// place. Defends against terminal-escape injection from catalog-
    /// supplied strings.
    public mutating func sanitize() {
        name = ComponentItem.truncateChars(
            ComponentItem.stripControlChars(name),
            maxChars: MAX_COMPONENT_NAME_CHARS
        )
        if let d = description {
            let cleaned = ComponentItem.truncateChars(
                ComponentItem.stripControlChars(d),
                maxChars: MAX_COMPONENT_DESC_CHARS
            )
            description = cleaned.isEmpty ? nil : cleaned
        } else {
            description = nil
        }
    }

    /// Strip control characters and Unicode spoofing characters (zero-width
    /// spaces, bidi overrides, BOM, etc.) from `s`.
    public static func stripControlChars(_ s: String) -> String {
        String(s.unicodeScalars.filter { scalar in
            // Mirror Rust's `char::is_control()` (Unicode general category
            // Cc) via Swift's `Unicode.GeneralCategory.control`.
            guard scalar.properties.generalCategory != .control else { return false }
            let v = scalar.value
            // Zero-width / bidi / BOM ranges (mirrors the Rust source).
            if (0x202a...0x202e).contains(v) { return false }
            if (0x2066...0x2069).contains(v) { return false }
            if (0x200b...0x200f).contains(v) { return false }
            if v == 0xfeff { return false }
            return true
        })
    }

    /// Truncate `s` to at most `maxChars` Unicode scalars.
    public static func truncateChars(_ s: String, maxChars: Int) -> String {
        if s.unicodeScalars.count <= maxChars { return s }
        return String(s.unicodeScalars.prefix(maxChars))
    }
}

/// Full inventory of a plugin's components, sourced from a marketplace
/// catalog (`plugin-index.json`).
///
/// Codable deserialization bypasses `ComponentItem.init(name:description:)`
/// (which sanitizes), so values are not sanitized by construction: every
/// consumer that renders catalog-derived data to a terminal must call
/// `sanitize()` at its ingestion point.
public struct PluginComponents: Hashable, Sendable, Codable, Equatable {
    public var skills: [ComponentItem]
    public var commands: [ComponentItem]
    public var agents: [ComponentItem]
    public var mcpServers: [ComponentItem]
    /// `name` = hook event (e.g. "PreToolUse"), `description` = optional
    /// matcher.
    public var hooks: [ComponentItem]
    public var lspServers: [ComponentItem]

    public init(
        skills: [ComponentItem] = [],
        commands: [ComponentItem] = [],
        agents: [ComponentItem] = [],
        mcpServers: [ComponentItem] = [],
        hooks: [ComponentItem] = [],
        lspServers: [ComponentItem] = []
    ) {
        self.skills = skills
        self.commands = commands
        self.agents = agents
        self.mcpServers = mcpServers
        self.hooks = hooks
        self.lspServers = lspServers
    }

    enum CodingKeys: String, CodingKey {
        case skills, commands, agents
        case mcpServers = "mcpServers"
        case hooks
        case lspServers = "lspServers"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        skills = try c.decodeIfPresent([ComponentItem].self, forKey: .skills) ?? []
        commands = try c.decodeIfPresent([ComponentItem].self, forKey: .commands) ?? []
        agents = try c.decodeIfPresent([ComponentItem].self, forKey: .agents) ?? []
        mcpServers = try c.decodeIfPresent([ComponentItem].self, forKey: .mcpServers) ?? []
        hooks = try c.decodeIfPresent([ComponentItem].self, forKey: .hooks) ?? []
        lspServers = try c.decodeIfPresent([ComponentItem].self, forKey: .lspServers) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if !skills.isEmpty { try c.encode(skills, forKey: .skills) }
        if !commands.isEmpty { try c.encode(commands, forKey: .commands) }
        if !agents.isEmpty { try c.encode(agents, forKey: .agents) }
        if !mcpServers.isEmpty { try c.encode(mcpServers, forKey: .mcpServers) }
        if !hooks.isEmpty { try c.encode(hooks, forKey: .hooks) }
        if !lspServers.isEmpty { try c.encode(lspServers, forKey: .lspServers) }
    }

    /// `true` when every category is empty.
    public var isEmpty: Bool {
        skills.isEmpty && commands.isEmpty && agents.isEmpty
            && mcpServers.isEmpty && hooks.isEmpty && lspServers.isEmpty
    }

    /// One-line summary like "3 skills · 1 MCP server · 2 commands",
    /// omitting empty categories. `nil` when there is nothing to show.
    public func summaryLine() -> String? {
        let parts: [String] = categories().compactMap { (category, items) in
            guard !items.isEmpty else { return nil }
            let (singular, plural): (String, String)
            switch category {
            case .skills: (singular, plural) = ("skill", "skills")
            case .commands: (singular, plural) = ("command", "commands")
            case .agents: (singular, plural) = ("agent", "agents")
            case .mcpServers: (singular, plural) = ("MCP server", "MCP servers")
            case .hooks: (singular, plural) = ("hook", "hooks")
            case .lspServers: (singular, plural) = ("LSP server", "LSP servers")
            }
            let label = items.count == 1 ? singular : plural
            return "\(items.count) \(label)"
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " \u{00b7}")
    }

    /// Canonical category enumeration; the single source of truth for
    /// which fields exist and their display order.
    public func categories() -> [(ComponentCategory, [ComponentItem])] {
        [
            (.skills, skills),
            (.commands, commands),
            (.agents, agents),
            (.mcpServers, mcpServers),
            (.hooks, hooks),
            (.lspServers, lspServers)
        ]
    }

    /// Strip control characters, truncate descriptions, and cap each
    /// category at `MAX_COMPONENTS_PER_CATEGORY` items. Applied when
    /// loading untrusted catalog data.
    public mutating func sanitize() {
        func cap(_ items: inout [ComponentItem]) {
            items.truncate(MAX_COMPONENTS_PER_CATEGORY)
            for i in items.indices {
                items[i].sanitize()
            }
        }
        cap(&skills)
        cap(&commands)
        cap(&agents)
        cap(&mcpServers)
        cap(&hooks)
        cap(&lspServers)
    }
}

private extension Array {
    /// Mirror Rust's `Vec::truncate` — keeps at most `maxLength` elements.
    mutating func truncate(_ maxLength: Int) {
        if count > maxLength {
            removeLast(count - maxLength)
        }
    }
}

/// Stable identifier for one of the six component categories. Consumers
/// map this to their own display labels via exhaustive `switch` so adding
/// a category is a compile error until every consumer handles it.
public enum ComponentCategory: Hashable, Sendable, Equatable, CaseIterable {
    case skills
    case commands
    case agents
    case mcpServers
    case hooks
    case lspServers
}

// MARK: - Action types

/// Request wrapper for `x.ai/hooks/action`.
public struct HooksActionRequest: Hashable, Sendable, Codable, Equatable {
    public var sessionId: String
    public var action: HooksAction

    public init(sessionId: String, action: HooksAction) {
        self.sessionId = sessionId
        self.action = action
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "sessionId"
        case action
    }
}

/// Hook management actions.
public enum HooksAction: Hashable, Sendable, Codable, Equatable {
    /// Re-discover and reload all hooks mid-session.
    case reload
    case trust
    case untrust
    case add(path: String)
    case remove(path: String)
    /// Enable a disabled hook by name.
    case enable(hookName: String)
    /// Disable a hook by name.
    case disable(hookName: String)
    /// Enable or disable all hooks from a source directory at once.
    case toggleSource(hookNames: [String], disable: Bool)

    private enum Tag: String, Codable {
        case reload, trust, untrust, add, remove, enable, disable
        case toggleSource = "toggle_source"
    }
    private enum CodingKeys: String, CodingKey {
        case type
        case path
        case hookName = "hook_name"
        case hookNames = "hook_names"
        case disable
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .type)
        switch tag {
        case .reload: self = .reload
        case .trust: self = .trust
        case .untrust: self = .untrust
        case .add:
            self = .add(path: try c.decode(String.self, forKey: .path))
        case .remove:
            self = .remove(path: try c.decode(String.self, forKey: .path))
        case .enable:
            self = .enable(hookName: try c.decode(String.self, forKey: .hookName))
        case .disable:
            self = .disable(hookName: try c.decode(String.self, forKey: .hookName))
        case .toggleSource:
            self = .toggleSource(
                hookNames: try c.decode([String].self, forKey: .hookNames),
                disable: try c.decode(Bool.self, forKey: .disable)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .reload: try c.encode(Tag.reload, forKey: .type)
        case .trust: try c.encode(Tag.trust, forKey: .type)
        case .untrust: try c.encode(Tag.untrust, forKey: .type)
        case .add(let path):
            try c.encode(Tag.add, forKey: .type)
            try c.encode(path, forKey: .path)
        case .remove(let path):
            try c.encode(Tag.remove, forKey: .type)
            try c.encode(path, forKey: .path)
        case .enable(let hookName):
            try c.encode(Tag.enable, forKey: .type)
            try c.encode(hookName, forKey: .hookName)
        case .disable(let hookName):
            try c.encode(Tag.disable, forKey: .type)
            try c.encode(hookName, forKey: .hookName)
        case .toggleSource(let hookNames, let disable):
            try c.encode(Tag.toggleSource, forKey: .type)
            try c.encode(hookNames, forKey: .hookNames)
            try c.encode(disable, forKey: .disable)
        }
    }
}

/// Request wrapper for `x.ai/plugins/action`.
public struct PluginsActionRequest: Hashable, Sendable, Codable, Equatable {
    public var sessionId: String
    public var action: PluginsAction

    public init(sessionId: String, action: PluginsAction) {
        self.sessionId = sessionId
        self.action = action
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "sessionId"
        case action
    }
}

/// Plugin management actions.
public enum PluginsAction: Hashable, Sendable, Codable, Equatable {
    case reload
    case install(source: String)
    case uninstall(pluginId: String, confirmed: Bool)
    case update(pluginId: String?)
    case add(path: String)
    case remove(path: String)
    /// Enable a disabled plugin by ID.
    case enable(pluginId: String)
    /// Disable a plugin by ID (adds to disabled list in config).
    case disable(pluginId: String)

    private enum Tag: String, Codable {
        case reload, install, uninstall, update, add, remove, enable, disable
    }
    private enum CodingKeys: String, CodingKey {
        case type
        case source
        case pluginId = "plugin_id"
        case confirmed
        case path
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .type)
        switch tag {
        case .reload: self = .reload
        case .install:
            self = .install(source: try c.decode(String.self, forKey: .source))
        case .uninstall:
            self = .uninstall(
                pluginId: try c.decode(String.self, forKey: .pluginId),
                // `#[serde(default)]` — missing `confirmed` decodes to `false`.
                confirmed: try c.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false
            )
        case .update:
            self = .update(pluginId: try c.decodeIfPresent(String.self, forKey: .pluginId))
        case .add:
            self = .add(path: try c.decode(String.self, forKey: .path))
        case .remove:
            self = .remove(path: try c.decode(String.self, forKey: .path))
        case .enable:
            self = .enable(pluginId: try c.decode(String.self, forKey: .pluginId))
        case .disable:
            self = .disable(pluginId: try c.decode(String.self, forKey: .pluginId))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .reload: try c.encode(Tag.reload, forKey: .type)
        case .install(let source):
            try c.encode(Tag.install, forKey: .type)
            try c.encode(source, forKey: .source)
        case .uninstall(let pluginId, let confirmed):
            try c.encode(Tag.uninstall, forKey: .type)
            try c.encode(pluginId, forKey: .pluginId)
            // `#[serde(default)]` — always emit.
            try c.encode(confirmed, forKey: .confirmed)
        case .update(let pluginId):
            try c.encode(Tag.update, forKey: .type)
            try c.encodeIfPresent(pluginId, forKey: .pluginId)
        case .add(let path):
            try c.encode(Tag.add, forKey: .type)
            try c.encode(path, forKey: .path)
        case .remove(let path):
            try c.encode(Tag.remove, forKey: .type)
            try c.encode(path, forKey: .path)
        case .enable(let pluginId):
            try c.encode(Tag.enable, forKey: .type)
            try c.encode(pluginId, forKey: .pluginId)
        case .disable(let pluginId):
            try c.encode(Tag.disable, forKey: .type)
            try c.encode(pluginId, forKey: .pluginId)
        }
    }
}

/// Shared action response for both `x.ai/hooks/action` and
/// `x.ai/plugins/action`.
public struct ActionOutcome: Hashable, Sendable, Codable, Equatable {
    public var status: OutcomeStatus
    public var message: String
    public var requiresReload: Bool
    public var requiresRestart: Bool

    public init(
        status: OutcomeStatus,
        message: String,
        requiresReload: Bool,
        requiresRestart: Bool
    ) {
        self.status = status
        self.message = message
        self.requiresReload = requiresReload
        self.requiresRestart = requiresRestart
    }

    enum CodingKeys: String, CodingKey {
        case status, message
        case requiresReload = "requiresReload"
        case requiresRestart = "requiresRestart"
    }
}

// MARK: - Marketplace types (wire format for x.ai/marketplace/* ACP
// endpoints)

/// Response for `x.ai/marketplace/list`.
public struct MarketplaceListResponse: Hashable, Sendable, Codable, Equatable {
    public var sources: [MarketplaceScanResult]

    public init(sources: [MarketplaceScanResult]) {
        self.sources = sources
    }

    enum CodingKeys: String, CodingKey { case sources }

    /// Sanitize all catalog-derived components in the response. Every
    /// consumer that renders this data to a terminal must call this at its
    /// ingestion point (deserialization bypasses
    /// `ComponentItem.init(name:description:)`).
    public mutating func sanitize() {
        for i in sources.indices {
            for j in sources[i].plugins.indices {
                if var components = sources[i].plugins[j].components {
                    components.sanitize()
                    sources[i].plugins[j].components = components
                }
            }
        }
    }
}

/// Result of scanning a single marketplace source.
public struct MarketplaceScanResult: Hashable, Sendable, Codable, Equatable {
    public var sourceName: String
    public var sourceKind: String
    public var sourceUrlOrPath: String
    public var plugins: [MarketplacePluginEntry]
    public var error: String?

    public init(
        sourceName: String,
        sourceKind: String,
        sourceUrlOrPath: String,
        plugins: [MarketplacePluginEntry],
        error: String? = nil
    ) {
        self.sourceName = sourceName
        self.sourceKind = sourceKind
        self.sourceUrlOrPath = sourceUrlOrPath
        self.plugins = plugins
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case sourceName = "sourceName"
        case sourceKind = "sourceKind"
        case sourceUrlOrPath = "sourceUrlOrPath"
        case plugins, error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceName = try c.decode(String.self, forKey: .sourceName)
        sourceKind = try c.decode(String.self, forKey: .sourceKind)
        sourceUrlOrPath = try c.decode(String.self, forKey: .sourceUrlOrPath)
        plugins = try c.decode([MarketplacePluginEntry].self, forKey: .plugins)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

/// A marketplace plugin with install status.
public struct MarketplacePluginEntry: Hashable, Sendable, Codable, Equatable {
    public var name: String
    public var version: String?
    public var description: String?
    public var category: String?
    public var author: String?
    public var tags: [String]
    public var keywords: [String]
    public var domains: [String]
    public var homepage: String?
    public var relativePath: String
    public var skillCount: Int
    public var hasHooks: Bool
    public var hasAgents: Bool
    public var hasMcp: Bool
    public var installStatus: String
    public var installedVersion: String?
    /// Structured inventory from the marketplace catalog. `nil` = no
    /// catalog data for this plugin (or the sender predates this field).
    public var components: PluginComponents?
    /// Remote git URL for URL-sourced plugins (not present for local
    /// plugins).
    public var remoteUrl: String?
    /// Git ref (branch/tag) for remote URL sources.
    public var remoteRef: String?
    public var remoteSha: String?
    public var remoteSubdir: String?

    public init(
        name: String,
        version: String? = nil,
        description: String? = nil,
        category: String? = nil,
        author: String? = nil,
        tags: [String] = [],
        keywords: [String] = [],
        domains: [String] = [],
        homepage: String? = nil,
        relativePath: String,
        skillCount: Int,
        hasHooks: Bool,
        hasAgents: Bool,
        hasMcp: Bool,
        installStatus: String,
        installedVersion: String? = nil,
        components: PluginComponents? = nil,
        remoteUrl: String? = nil,
        remoteRef: String? = nil,
        remoteSha: String? = nil,
        remoteSubdir: String? = nil
    ) {
        self.name = name
        self.version = version
        self.description = description
        self.category = category
        self.author = author
        self.tags = tags
        self.keywords = keywords
        self.domains = domains
        self.homepage = homepage
        self.relativePath = relativePath
        self.skillCount = skillCount
        self.hasHooks = hasHooks
        self.hasAgents = hasAgents
        self.hasMcp = hasMcp
        self.installStatus = installStatus
        self.installedVersion = installedVersion
        self.components = components
        self.remoteUrl = remoteUrl
        self.remoteRef = remoteRef
        self.remoteSha = remoteSha
        self.remoteSubdir = remoteSubdir
    }

    enum CodingKeys: String, CodingKey {
        case name, version, description, category, author, tags, keywords, domains, homepage
        case relativePath = "relativePath"
        case skillCount = "skillCount"
        case hasHooks = "hasHooks"
        case hasAgents = "hasAgents"
        case hasMcp = "hasMcp"
        case installStatus = "installStatus"
        case installedVersion = "installedVersion"
        case components
        case remoteUrl = "remoteUrl"
        case remoteRef = "remoteRef"
        case remoteSha = "remoteSha"
        case remoteSubdir = "remoteSubdir"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        // `#[serde(default)]` — missing arrays decode to empty.
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
        domains = try c.decodeIfPresent([String].self, forKey: .domains) ?? []
        homepage = try c.decodeIfPresent(String.self, forKey: .homepage)
        relativePath = try c.decode(String.self, forKey: .relativePath)
        skillCount = try c.decode(Int.self, forKey: .skillCount)
        hasHooks = try c.decode(Bool.self, forKey: .hasHooks)
        hasAgents = try c.decode(Bool.self, forKey: .hasAgents)
        hasMcp = try c.decode(Bool.self, forKey: .hasMcp)
        installStatus = try c.decode(String.self, forKey: .installStatus)
        installedVersion = try c.decodeIfPresent(String.self, forKey: .installedVersion)
        components = try c.decodeIfPresent(PluginComponents.self, forKey: .components)
        remoteUrl = try c.decodeIfPresent(String.self, forKey: .remoteUrl)
        remoteRef = try c.decodeIfPresent(String.self, forKey: .remoteRef)
        remoteSha = try c.decodeIfPresent(String.self, forKey: .remoteSha)
        remoteSubdir = try c.decodeIfPresent(String.self, forKey: .remoteSubdir)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(version, forKey: .version)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(category, forKey: .category)
        try c.encodeIfPresent(author, forKey: .author)
        try c.encode(tags, forKey: .tags)
        try c.encode(keywords, forKey: .keywords)
        try c.encode(domains, forKey: .domains)
        try c.encodeIfPresent(homepage, forKey: .homepage)
        try c.encode(relativePath, forKey: .relativePath)
        try c.encode(skillCount, forKey: .skillCount)
        try c.encode(hasHooks, forKey: .hasHooks)
        try c.encode(hasAgents, forKey: .hasAgents)
        try c.encode(hasMcp, forKey: .hasMcp)
        try c.encode(installStatus, forKey: .installStatus)
        try c.encodeIfPresent(installedVersion, forKey: .installedVersion)
        try c.encodeIfPresent(components, forKey: .components)
        try c.encodeIfPresent(remoteUrl, forKey: .remoteUrl)
        try c.encodeIfPresent(remoteRef, forKey: .remoteRef)
        try c.encodeIfPresent(remoteSha, forKey: .remoteSha)
        try c.encodeIfPresent(remoteSubdir, forKey: .remoteSubdir)
    }
}

/// Request wrapper for `x.ai/marketplace/action`.
public struct MarketplaceActionRequest: Hashable, Sendable, Codable, Equatable {
    public var sessionId: String
    public var action: MarketplaceAction

    public init(sessionId: String, action: MarketplaceAction) {
        self.sessionId = sessionId
        self.action = action
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "sessionId"
        case action
    }
}

/// Marketplace management actions.
public enum MarketplaceAction: Hashable, Sendable, Codable, Equatable {
    /// Re-scan all sources (git: pull, local: re-read).
    case refresh(sourceUrlOrPath: String?)
    /// Install a plugin from a marketplace source.
    case install(sourceUrlOrPath: String, pluginRelativePath: String)
    /// Update an installed marketplace plugin to the latest version.
    case update(sourceUrlOrPath: String, pluginRelativePath: String)
    /// Uninstall a marketplace-installed plugin.
    case uninstall(sourceUrlOrPath: String, pluginRelativePath: String)
    /// Add a new marketplace source (git URL).
    case addSource(url: String)
    /// Remove a marketplace source.
    case removeSource(sourceUrlOrPath: String)

    private enum Tag: String, Codable {
        case refresh, install, update, uninstall
        case addSource = "add_source"
        case removeSource = "remove_source"
    }
    private enum CodingKeys: String, CodingKey {
        case type
        case sourceUrlOrPath = "source_url_or_path"
        case pluginRelativePath = "plugin_relative_path"
        case url
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .type)
        switch tag {
        case .refresh:
            // `#[serde(default)]` — missing `source_url_or_path` decodes to `nil`.
            self = .refresh(sourceUrlOrPath: try c.decodeIfPresent(String.self, forKey: .sourceUrlOrPath))
        case .install:
            self = .install(
                sourceUrlOrPath: try c.decode(String.self, forKey: .sourceUrlOrPath),
                pluginRelativePath: try c.decode(String.self, forKey: .pluginRelativePath)
            )
        case .update:
            self = .update(
                sourceUrlOrPath: try c.decode(String.self, forKey: .sourceUrlOrPath),
                pluginRelativePath: try c.decode(String.self, forKey: .pluginRelativePath)
            )
        case .uninstall:
            self = .uninstall(
                sourceUrlOrPath: try c.decode(String.self, forKey: .sourceUrlOrPath),
                pluginRelativePath: try c.decode(String.self, forKey: .pluginRelativePath)
            )
        case .addSource:
            self = .addSource(url: try c.decode(String.self, forKey: .url))
        case .removeSource:
            self = .removeSource(sourceUrlOrPath: try c.decode(String.self, forKey: .sourceUrlOrPath))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .refresh(let source):
            try c.encode(Tag.refresh, forKey: .type)
            // `#[serde(default)]` — always emit (null when nil).
            try c.encodeIfPresent(source, forKey: .sourceUrlOrPath)
        case .install(let source, let pluginRelativePath):
            try c.encode(Tag.install, forKey: .type)
            try c.encode(source, forKey: .sourceUrlOrPath)
            try c.encode(pluginRelativePath, forKey: .pluginRelativePath)
        case .update(let source, let pluginRelativePath):
            try c.encode(Tag.update, forKey: .type)
            try c.encode(source, forKey: .sourceUrlOrPath)
            try c.encode(pluginRelativePath, forKey: .pluginRelativePath)
        case .uninstall(let source, let pluginRelativePath):
            try c.encode(Tag.uninstall, forKey: .type)
            try c.encode(source, forKey: .sourceUrlOrPath)
            try c.encode(pluginRelativePath, forKey: .pluginRelativePath)
        case .addSource(let url):
            try c.encode(Tag.addSource, forKey: .type)
            try c.encode(url, forKey: .url)
        case .removeSource(let source):
            try c.encode(Tag.removeSource, forKey: .type)
            try c.encode(source, forKey: .sourceUrlOrPath)
        }
    }
}
