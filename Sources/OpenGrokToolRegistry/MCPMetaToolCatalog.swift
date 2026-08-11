// MCPMetaToolCatalog.swift
//
// search_tool / use_tool catalog entries, schemas, search-index protocol,
// and description-truncation helpers. Ported from
// `xai-grok-tools/src/implementations/search_tool/mod.rs:1-431` and
// `use_tool/mod.rs:10-60` at pin 650c1db7.
//
// The tools are registered unconditionally into the catalog (like image/web
// tools) so that a restrictive allowlist cannot strip MCP access
// (`builder.rs:2243-2261`). Whether they appear in a session's model-facing
// definitions depends on capability mode: `search_tool` is always-on,
// `use_tool` requires readWrite or execute (`CapabilityFilter.swift`).

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol

// MARK: - Description truncation

/// Maximum character length for MCP tool/server descriptions returned by
/// `search_tool`. Matches Rust `MAX_MCP_DESCRIPTION_LENGTH` (2048).
public let maxMCPDescriptionLength: Int = 2048

private let truncationSuffix: String = "\u{2026} [truncated]"

/// Truncate a description to `maxMCPDescriptionLength` characters, appending
/// a suffix when truncated. Operates on character boundaries to avoid
/// splitting multi-byte characters.
///
/// Ported from `search_tool/mod.rs:21-28`.
public func truncateMCPDescription(_ s: String) -> String {
    if s.count <= maxMCPDescriptionLength { return s }
    let budget = maxMCPDescriptionLength - truncationSuffix.count
    return String(s.prefix(budget)) + truncationSuffix
}

/// Collapse newlines and excess whitespace into a single space.
/// Ported from `search_tool/mod.rs:186-190`.
public func sanitizeMCPDescription(_ s: String) -> String {
    s.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        .flatMap { $0.split(separator: " ", omittingEmptySubsequences: true).map(String.init) }
        .joined(separator: " ")
}

// MARK: - Search index protocol

/// A single search result from the tool index.
public struct ToolSearchResult: Sendable, Equatable {
    public var toolName: String
    public var serverName: String
    public var description: String
    public var inputSchema: JSONValue
    public var score: Float

    public init(
        toolName: String,
        serverName: String,
        description: String,
        inputSchema: JSONValue = .object(["type": .string("object")]),
        score: Float = 0.0
    ) {
        self.toolName = toolName
        self.serverName = serverName
        self.description = description
        self.inputSchema = inputSchema
        self.score = score
    }
}

/// Point-in-time search snapshot: results + metadata.
public struct ToolSearchSnapshot: Sendable, Equatable {
    public var results: [ToolSearchResult]
    public var totalHiddenTools: Int
    public var isReady: Bool

    public init(
        results: [ToolSearchResult] = [],
        totalHiddenTools: Int = 0,
        isReady: Bool = true
    ) {
        self.results = results
        self.totalHiddenTools = totalHiddenTools
        self.isReady = isReady
    }
}

/// Summary of an MCP server for system-reminder construction.
public struct MCPServerSummary: Sendable, Equatable {
    public var name: String
    public var description: String?
    public var toolCount: Int
    public var toolNames: [String]

    public init(
        name: String,
        description: String? = nil,
        toolCount: Int = 0,
        toolNames: [String] = []
    ) {
        self.name = name
        self.description = description
        self.toolCount = toolCount
        self.toolNames = toolNames
    }
}

/// Backend-agnostic search interface.
///
/// Injected into `ToolResources.extras` by the live composition after MCP
/// initialization. `search_tool` reads it from there; if absent, the tool
/// returns an empty-catalog response.
///
/// Mirrors Rust `ToolSearchIndex` (`xai-grok-tools/src/types/tool_index.rs:58-67`).
public protocol ToolSearchIndexing: Sendable {
    func searchSnapshot(query: String, limit: Int) -> ToolSearchSnapshot
    func listServerSummaries() -> [MCPServerSummary]
}

/// Resource wrapper for storing a `ToolSearchIndexing` instance in
/// `ToolResources.extras`.
public struct ToolSearchIndexResource: Sendable {
    public var index: any ToolSearchIndexing
    public init(_ index: any ToolSearchIndexing) { self.index = index }
}

/// Set of native tool names currently enabled in the session, used by
/// `use_tool` for native-tool corrective errors.
///
/// Mirrors Rust `EnabledNativeToolNames` (`use_tool/mod.rs:320`).
public struct EnabledNativeToolNames: Sendable {
    public var names: Set<String>
    public init(_ names: Set<String>) { self.names = names }
}

// MARK: - Schemas

private func objectSchema(
    properties: [String: JSONValue],
    required: [String] = []
) -> JSONValue {
    var obj: [String: JSONValue] = [
        "type": .string("object"),
        "properties": .object(properties),
    ]
    if !required.isEmpty {
        obj["required"] = .array(required.map { .string($0) })
    }
    return .object(obj)
}

private func stringProp(_ description: String) -> JSONValue {
    .object(["type": .string("string"), "description": .string(description)])
}

private func intProp(_ description: String) -> JSONValue {
    .object(["type": .string("integer"), "description": .string(description)])
}

/// `search_tool` input schema. Mirrors `SearchToolInput`
/// (`search_tool/types.rs:8-17`).
public let searchToolSchema: JSONValue = objectSchema(
    properties: [
        "query": stringProp(
            "Keywords to match against tool names, server names, and descriptions. "
            + "Include the server name and action for best results "
            + "(e.g. \"linear create issue\", \"slack read thread history\")."
        ),
        "limit": intProp("Maximum number of results to return (default 5)."),
    ],
    required: ["query"]
)

/// `use_tool` input schema. Mirrors `UseToolInput`
/// (`use_tool/mod.rs:12-19`).
public let useToolSchema: JSONValue = objectSchema(
    properties: [
        "tool_name": stringProp(
            "The qualified name of the integration tool to call (e.g., \"linear__save_issue\"). "
            + "Must be a tool previously discovered via search_tool."
        ),
        "tool_input": .object([
            "type": .string("object"),
            "additionalProperties": .bool(true),
            "description": .string(
                "The arguments to pass to the tool, as a JSON object. "
                + "Use the parameter schema returned by search_tool to construct this."
            ),
        ]),
    ],
    required: ["tool_name", "tool_input"]
)

// MARK: - Catalog entries

extension BuiltinToolCatalog {
    /// MCP meta-tool description: `search_tool`.
    /// Ported from `SearchTool::description_template` (`search_tool/mod.rs:199-202`).
    public static let searchToolDescription: String =
        "Search for MCP tools by keyword and retrieve their input schemas.\n\n"
        + "If status is \"partial\", some servers may still be connecting."

    /// MCP meta-tool description: `use_tool`.
    /// Ported from `UseTool::description_template` (`use_tool/mod.rs:282-286`).
    public static let useToolDescription: String =
        "Call an MCP integration tool.\n\n"
        + "The `tool_name` must be the qualified `server__tool` name (e.g., `linear__save_issue`). "
        + "The `tool_input` must conform exactly to the tool's input schema as returned by `search_tool`."

    /// MCP meta-tools. Always retained in restrictive allowlists
    /// (`builder.rs:2243-2261`).
    public static let mcpMetaTools: [RegisteredToolSpec] = [
        RegisteredToolSpec(
            namespace: .grokBuild, id: "search_tool", kind: .searchTool,
            description: searchToolDescription,
            inputSchema: searchToolSchema
        ),
        RegisteredToolSpec(
            namespace: .grokBuild, id: "use_tool", kind: .useTool,
            description: useToolDescription,
            inputSchema: useToolSchema
        ),
    ]

    public static var mcpMetaToolKinds: [String: ProductToolKind] {
        Dictionary(uniqueKeysWithValues: mcpMetaTools.map { ($0.qualifiedId, $0.kind) })
    }

    public static let searchToolQualifiedId = "GrokBuild:search_tool"
    public static let useToolQualifiedId = "GrokBuild:use_tool"
}
