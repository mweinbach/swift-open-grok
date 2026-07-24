// Selection.swift
//
// Tool mode, allow/deny filters, hosted / direct-only flags, and Code Mode
// namespace visibility applied during finalization.

import Foundation
import OpenGrokCodeModeProtocol
import OpenGrokShared

// MARK: - Tool mode

/// How tools are exposed to the model for a turn / session.
public enum SessionToolMode: String, Codable, Sendable, Hashable, CaseIterable {
    /// Ordinary top-level tools (plus optional hosted provider tools).
    case standard
    /// Code Mode Mixed: `exec` / `wait` + ordinary top-level tools.
    case codeModeMixed = "code_mode_mixed"
    /// Code Mode Only: `exec` / `wait` + direct-only tools top-level;
    /// ordinary tools available only via nested `tools.*`.
    case codeModeOnly = "code_mode_only"
}

// MARK: - Allow / deny

/// Deterministic allow/deny name filters applied after capability filtering.
/// Empty allow list means "allow all remaining"; deny always drops.
public struct ToolNameFilters: Codable, Sendable, Hashable, Equatable {
    /// When non-empty, only these client-facing names survive.
    public var allow: Set<String>
    /// Always dropped (checked after allow).
    public var deny: Set<String>

    public init(allow: Set<String> = [], deny: Set<String> = []) {
        self.allow = allow
        self.deny = deny
    }

    public func admits(clientName: String) -> Bool {
        if !allow.isEmpty && !allow.contains(clientName) {
            return false
        }
        if deny.contains(clientName) {
            return false
        }
        return true
    }
}

// MARK: - Hosted / direct-only

/// Flags that change top-level listing without unregistering the tool.
public struct ToolExposureFlags: Codable, Sendable, Hashable, Equatable {
    /// Provider-hosted tools (e.g. native web search) — may stay hidden client-side.
    public var hosted: Bool
    /// Human / multi-agent tools that remain top-level even under Code Mode Only.
    public var directOnly: Bool
    /// When true, tool is available to nested Code Mode `tools.*` dispatch.
    public var nestedCallable: Bool

    public init(hosted: Bool = false, directOnly: Bool = false, nestedCallable: Bool = true) {
        self.hosted = hosted
        self.directOnly = directOnly
        self.nestedCallable = nestedCallable
    }

    public static let ordinary = ToolExposureFlags()
    public static let directOnlyDefault = ToolExposureFlags(directOnly: true, nestedCallable: false)
    public static let hostedDefault = ToolExposureFlags(hosted: true, nestedCallable: false)
}

// MARK: - Finalize options

/// Extra selection knobs applied during `ToolRegistryBuilder.finalize`.
public struct FinalizeOptions: Sendable, Equatable {
    public var capabilityMode: ToolCapabilityMode
    public var toolMode: SessionToolMode
    public var nameFilters: ToolNameFilters
    /// Client names treated as hosted (dropped from ordinary client definitions
    /// when a provider already hosts them, unless `includeHosted` is true).
    public var hostedClientNames: Set<String>
    /// Client names treated as direct-only (visible under Code Mode Only).
    public var directOnlyClientNames: Set<String>
    /// When true, hosted tools are kept in the finalized definitions.
    public var includeHosted: Bool
    /// When true (default), Code Mode namespaces are attached for nested tools.
    public var emitCodeModeNamespaces: Bool

    public init(
        capabilityMode: ToolCapabilityMode = .all,
        toolMode: SessionToolMode = .standard,
        nameFilters: ToolNameFilters = ToolNameFilters(),
        hostedClientNames: Set<String> = [],
        directOnlyClientNames: Set<String> = ["ask_user_question", "enter_plan_mode", "exit_plan_mode"],
        includeHosted: Bool = false,
        emitCodeModeNamespaces: Bool = true
    ) {
        self.capabilityMode = capabilityMode
        self.toolMode = toolMode
        self.nameFilters = nameFilters
        self.hostedClientNames = hostedClientNames
        self.directOnlyClientNames = directOnlyClientNames
        self.includeHosted = includeHosted
        self.emitCodeModeNamespaces = emitCodeModeNamespaces
    }

    public static let unrestricted = FinalizeOptions()
}

// MARK: - Visibility decision

public enum ToolListVisibility: String, Sendable, Hashable {
    /// Appears in model-facing top-level tool definitions.
    case topLevel
    /// Available only via nested Code Mode dispatch (hidden top-level).
    case nestedOnly
    /// Completely dropped for this session.
    case hidden
}

public func listVisibility(
    clientName: String,
    kind: ProductToolKind?,
    options: FinalizeOptions
) -> ToolListVisibility {
    let hosted = options.hostedClientNames.contains(clientName)
    let directOnly = options.directOnlyClientNames.contains(clientName)

    if !options.nameFilters.admits(clientName: clientName) {
        return .hidden
    }
    if hosted && !options.includeHosted {
        return .hidden
    }

    switch options.toolMode {
    case .standard:
        return .topLevel
    case .codeModeMixed:
        return .topLevel
    case .codeModeOnly:
        if directOnly {
            return .topLevel
        }
        if clientName == "exec" || clientName == "wait" {
            return .topLevel
        }
        _ = kind
        return .nestedOnly
    }
}

// MARK: - Code Mode namespace descriptions

/// Lightweight namespace map for nested `tools.*` metadata (W5-S1 surface).
public struct CodeModeToolNamespace: Sendable, Hashable, Equatable {
    public var name: String
    public var description: String
    public var toolNames: [String]

    public init(name: String, description: String, toolNames: [String]) {
        self.name = name
        self.description = description
        self.toolNames = toolNames
    }
}

/// Build Code Mode nested-tool namespace metadata.
///
/// Built-in tools live under the empty namespace (JS: `tools.read_file`);
/// MCP tools would use server prefixes. Visibility controls top-level listing
/// but nested-callable tools remain in the namespace for Code Mode Only.
public func codeModeNamespaceDescriptions(
    tools: [(clientName: String, kind: ProductToolKind, description: String, visibility: ToolListVisibility)]
) -> [String: CodeModeToolNamespace] {
    var names: [String] = []
    for t in tools {
        guard t.visibility != .hidden else { continue }
        // Nested Only + top-level tools are both nested-callable.
        names.append(t.clientName)
    }
    names.sort()
    guard !names.isEmpty else { return [:] }
    return [
        "": CodeModeToolNamespace(
            name: "",
            description: "Built-in tools",
            toolNames: names
        ),
    ]
}

/// Convert a finalized tool list into Code Mode protocol `ToolDefinition`s
/// for nested dispatch registration.
public func codeModeToolDefinitions(
    tools: [(clientName: String, description: String, inputSchema: JSONValue?, visibility: ToolListVisibility)]
) -> [ToolDefinition] {
    tools.compactMap { t in
        guard t.visibility != .hidden else { return nil }
        return ToolDefinition(
            name: t.clientName,
            toolName: ToolName.plain(t.clientName),
            description: t.description,
            kind: .function,
            inputSchema: t.inputSchema
        )
    }
    .sorted { $0.name < $1.name }
}
