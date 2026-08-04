// Config.swift
//
// ToolConfig / ToolServerConfig / finalize errors from
// `xai-grok-tools/src/registry/types.rs`.

import Foundation
import OpenGrokShared

/// Per-tool enablement + client-facing renames.
public struct ToolConfig: Codable, Sendable, Hashable, Equatable {
    /// Fully-qualified id (`"GrokBuild:read_file"`) or runtime MCP id.
    public var id: String
    public var params: [String: JSONValue]?
    public var nameOverride: String?
    public var paramsNameOverrides: [String: String]?
    public var descriptionOverride: String?
    public var behaviorVersion: String?
    /// Capability category. `nil` preserves the tool under all modes for
    /// ad-hoc/custom tools (MCP origin is filtered separately).
    public var kind: ProductToolKind?

    public init(
        id: String,
        params: [String: JSONValue]? = nil,
        nameOverride: String? = nil,
        paramsNameOverrides: [String: String]? = nil,
        descriptionOverride: String? = nil,
        behaviorVersion: String? = nil,
        kind: ProductToolKind? = nil
    ) {
        self.id = id
        self.params = params
        self.nameOverride = nameOverride
        self.paramsNameOverrides = paramsNameOverrides
        self.descriptionOverride = descriptionOverride
        self.behaviorVersion = behaviorVersion
        self.kind = kind
    }

    /// Build from a fully-qualified id with optional kind backfill.
    public static func fromId(_ id: String, kind: ProductToolKind? = nil) -> ToolConfig {
        ToolConfig(id: id, kind: kind)
    }

    public func withName(_ name: String) -> ToolConfig {
        var c = self
        c.nameOverride = name
        return c
    }

    public func withDescription(_ desc: String) -> ToolConfig {
        var c = self
        c.descriptionOverride = desc
        return c
    }

    public func withKind(_ kind: ProductToolKind) -> ToolConfig {
        var c = self
        c.kind = kind
        return c
    }

    public func resolveClientName(defaultId: String) -> String {
        nameOverride ?? defaultId
    }

    private enum CodingKeys: String, CodingKey {
        case id, params
        case nameOverride = "name_override"
        case paramsNameOverrides = "params_name_overrides"
        case descriptionOverride = "description_override"
        case behaviorVersion = "behavior_version"
        case kind
    }
}

/// Session tool enablement payload (what the client turns on).
public struct ToolServerConfig: Codable, Sendable, Hashable, Equatable {
    public var tools: [ToolConfig]
    public var behaviorPreset: String?

    public init(tools: [ToolConfig] = [], behaviorPreset: String? = nil) {
        self.tools = tools
        self.behaviorPreset = behaviorPreset
    }

    private enum CodingKeys: String, CodingKey {
        case tools
        case behaviorPreset = "behavior_preset"
    }
}

/// Finalization / validation error with optional field path.
public struct RequirementError: Error, Codable, Sendable, Hashable, Equatable, CustomStringConvertible {
    public var tool: String
    public var message: String
    public var fieldPath: String?
    public var expected: String?
    public var badValue: JSONValue?
    public var category: String?

    public init(
        tool: String,
        message: String,
        fieldPath: String? = nil,
        expected: String? = nil,
        badValue: JSONValue? = nil,
        category: String? = nil
    ) {
        self.tool = tool
        self.message = message
        self.fieldPath = fieldPath
        self.expected = expected
        self.badValue = badValue
        self.category = category
    }

    public var description: String { summary }

    public var summary: String {
        var parts: [String] = []
        if let fieldPath { parts.append(fieldPath) }
        parts.append(message)
        if let expected { parts.append("expected \(expected)") }
        if let badValue { parts.append("got \(badValue)") }
        return "\(tool): \(parts.joined(separator: "; "))"
    }

    private enum CodingKeys: String, CodingKey {
        case tool, message
        case fieldPath = "field_path"
        case expected
        case badValue = "bad_value"
        case category
    }
}

public struct RequirementErrors: Error, Codable, Sendable, Hashable, Equatable, RandomAccessCollection, CustomStringConvertible {
    public typealias Element = RequirementError
    public typealias Index = Int

    public var errors: [RequirementError]

    public init(_ errors: [RequirementError]) {
        self.errors = errors
    }

    public var startIndex: Int { errors.startIndex }
    public var endIndex: Int { errors.endIndex }
    public subscript(position: Int) -> RequirementError { errors[position] }
    public var description: String { errors.map(\.summary).joined(separator: "\n") }
}

/// Named toolset presets used by agents (selection helpers, not the full agent crate).
public enum NamedToolsetPreset: String, Sendable, Hashable, CaseIterable {
    case grokBuild = "grok-build"
    case grokBuildConcise = "grok-build-concise"
    case codex = "codex"
    case explore = "explore"
    case plan = "plan"
    case openCode = "opencode"
    case hashline = "hashline"
}

/// Build a `ToolServerConfig` for a named preset from known catalog ids.
public func toolServerConfig(
    for preset: NamedToolsetPreset,
    catalogKinds: [String: ProductToolKind]
) -> ToolServerConfig {
    let ids: [String]
    switch preset {
    case .grokBuild:
        ids = [
            "GrokBuild:read_file", "GrokBuild:list_dir", "GrokBuild:grep",
            "GrokBuild:search_replace", "GrokBuild:view_image",
        ]
    case .grokBuildConcise:
        ids = [
            "GrokBuildConcise:read_file", "GrokBuild:list_dir", "GrokBuild:grep",
            "GrokBuildConcise:search_replace",
        ]
    case .codex:
        ids = [
            "Codex:read_file", "Codex:list_dir", "Codex:grep_files",
            "Codex:apply_patch",
        ]
    case .explore:
        ids = ["GrokBuild:read_file", "GrokBuild:list_dir", "GrokBuild:grep"]
    case .plan:
        ids = ["GrokBuild:read_file", "GrokBuild:list_dir", "GrokBuild:grep"]
    case .openCode:
        ids = [
            "OpenCode:read", "OpenCode:edit", "OpenCode:write",
            "OpenCode:grep", "OpenCode:glob",
        ]
    case .hashline:
        ids = [
            "GrokBuildHashline:hashline_read",
            "GrokBuildHashline:hashline_edit",
            "GrokBuildHashline:hashline_grep",
        ]
    }
    let tools = ids.map { id in
        ToolConfig.fromId(id, kind: catalogKinds[id])
    }
    return ToolServerConfig(tools: tools)
}
