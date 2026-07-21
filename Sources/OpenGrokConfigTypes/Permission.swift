// Permission.swift
//
// Port of `xai-grok-config-types/src/permission.rs`.
//
// Permission-policy config value types, loaded from `[permission]` in config.toml.

import Foundation

// MARK: - PatternMode

/// Match mode for a permission rule's `pattern`.
public enum PatternMode: String, Sendable, Codable, Hashable, Equatable {
    /// Glob match against the full string (default).
    case glob
    /// Match against URL host rather than full string (from `WebFetch(domain:...)`).
    case domain

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = (try? c.decode(String.self)) ?? "glob"
        switch raw.lowercased() {
        case "glob": self = .glob
        case "domain": self = .domain
        default: self = .glob
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

// MARK: - RuleAction

/// Action to take when a permission rule matches.
///
/// CWE-1188: Default changed from `Allow` to `Deny` so that omitting the
/// `action` field in a TOML permission rule does not silently create a
/// catch-all allow rule. Mirrors Rust `RuleAction` (default = `Deny`).
public enum RuleAction: String, Sendable, Codable, Hashable, Equatable {
    case allow
    case deny
    case ask

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = (try? c.decode(String.self)) ?? "deny"
        switch raw.lowercased() {
        case "allow": self = .allow
        case "deny": self = .deny
        case "ask": self = .ask
        default: self = .deny
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

// MARK: - ToolFilter

/// Tool filter for permission rules. Mirrors Rust `ToolFilter` (default = `Any`).
public enum ToolFilter: String, Sendable, Codable, Hashable, Equatable {
    case any
    case bash
    case edit
    case read
    case grep
    case mcp
    case webFetch = "web_fetch"

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = (try? c.decode(String.self)) ?? "any"
        switch raw.lowercased() {
        case "any": self = .any
        case "bash": self = .bash
        case "edit": self = .edit
        case "read": self = .read
        case "grep": self = .grep
        case "mcp": self = .mcp
        case "web_fetch": self = .webFetch
        default: self = .any
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

// MARK: - PermissionRule

/// A single permission rule.
public struct PermissionRule: Hashable, Sendable, Codable, Equatable {
    public var action: RuleAction
    public var tool: ToolFilter
    public var pattern: String?
    public var patternMode: PatternMode

    public init(
        action: RuleAction = .deny,
        tool: ToolFilter = .any,
        pattern: String? = nil,
        patternMode: PatternMode = .glob
    ) {
        self.action = action
        self.tool = tool
        self.pattern = pattern
        self.patternMode = patternMode
    }

    private enum CodingKeys: String, CodingKey {
        case action, tool, pattern
        case patternMode = "pattern_mode"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decodeIfPresent(RuleAction.self, forKey: .action) ?? .deny
        tool = try c.decodeIfPresent(ToolFilter.self, forKey: .tool) ?? .any
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern)
        patternMode = try c.decodeIfPresent(PatternMode.self, forKey: .patternMode) ?? .glob
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(action, forKey: .action)
        try c.encode(tool, forKey: .tool)
        try c.encodeIfPresent(pattern, forKey: .pattern)
        try c.encode(patternMode, forKey: .patternMode)
    }
}

// MARK: - PermissionConfig

/// Permission policy configuration loaded from `[permission]` in config.toml.
public struct PermissionConfig: Hashable, Sendable, Codable, Equatable {
    public var rules: [PermissionRule]

    public init(rules: [PermissionRule] = []) {
        self.rules = rules
    }

    private enum CodingKeys: String, CodingKey { case rules }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rules = try c.decodeIfPresent([PermissionRule].self, forKey: .rules) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(rules, forKey: .rules)
    }
}
