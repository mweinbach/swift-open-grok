// Taxonomy.swift
//
// Product-level tool namespace / kind taxonomy from
// `xai-grok-tools/src/types/tool.rs` and `tool_taxonomy.rs`.

import Foundation

// MARK: - Namespace

/// Tool pack identity. Wire form is snake_case; Display / FQ id uses PascalCase.
public enum ProductToolNamespace: String, Codable, Sendable, Hashable, CaseIterable {
    case grokBuild = "grok_build"
    case grokBuildConcise = "grok_build_concise"
    case grokBuildHashline = "grok_build_hashline"
    case codex = "codex"
    case openCode = "opencode"
    case mcp = "mcp"

    /// PascalCase id prefix used in fully-qualified registration keys.
    public var displayName: String {
        switch self {
        case .grokBuild: return "GrokBuild"
        case .grokBuildConcise: return "GrokBuildConcise"
        case .grokBuildHashline: return "GrokBuildHashline"
        case .codex: return "Codex"
        case .openCode: return "OpenCode"
        case .mcp: return "MCP"
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        switch raw {
        case "grok_build", "GrokBuild": self = .grokBuild
        case "grok_build_concise", "GrokBuildConcise": self = .grokBuildConcise
        case "grok_build_hashline", "GrokBuildHashline": self = .grokBuildHashline
        case "codex", "Codex": self = .codex
        case "opencode", "OpenCode", "open_code": self = .openCode
        case "mcp", "MCP": self = .mcp
        default:
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "unknown ProductToolNamespace: \(raw)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

// MARK: - Kind

/// High-level tool category used by capability filtering and `_meta`.
public enum ProductToolKind: String, Codable, Sendable, Hashable, CaseIterable {
    case read
    case edit
    case delete
    case listDir = "list_dir"
    case write
    case move
    case search
    case lsp
    case execute
    case plan
    case webSearch = "web_search"
    case webFetch = "web_fetch"
    case backgroundTaskAction = "background_task_action"
    case waitTasksAction = "wait_tasks_action"
    case killTaskAction = "kill_task_action"
    case list
    case skill
    case memorySearch = "memory_search"
    case memoryGet = "memory_get"
    case task
    case agentSwarm = "agent_swarm"
    /// Team-scoped mailbox tools (`list_agents`, `send_message`,
    /// `followup_task`, `wait_agent`). Rust `ToolKind::AgentCollaboration`
    /// (`xai-grok-tools/src/types/tool.rs:92`).
    case agentCollaboration = "agent_collaboration"
    case workflow
    case enterPlan = "enter_plan"
    case exitPlan = "exit_plan"
    case askUser = "ask_user"
    case imageGen = "image_gen"
    case videoGen = "video_gen"
    case imageToVideo = "image_to_video"
    case referenceToVideo = "reference_to_video"
    case deployApp = "deploy_app"
    case searchTool = "search_tool"
    case useTool = "use_tool"
    case monitor
    case goalUpdate = "goal_update"
    case other

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        if let known = ProductToolKind(rawValue: raw) {
            self = known
        } else {
            // Unknown wire kinds sink to `.other` (parity with Rust `#[serde(other)]`).
            self = .other
        }
    }

    public var isReadOnly: Bool {
        switch self {
        case .read, .listDir, .search, .list, .lsp, .memorySearch, .memoryGet,
             .webSearch, .webFetch, .searchTool, .plan, .skill:
            return true
        default:
            return false
        }
    }
}

// MARK: - Identity

/// Fully-qualified tool id: `"GrokBuild:read_file"`.
public struct ProductToolIdentity: Hashable, Sendable, Codable, Equatable, CustomStringConvertible {
    public var namespace: ProductToolNamespace
    public var id: String

    public init(namespace: ProductToolNamespace, id: String) {
        self.namespace = namespace
        self.id = id
    }

    public var qualifiedId: String { "\(namespace.displayName):\(id)" }
    public var description: String { qualifiedId }

    public static func parse(_ raw: String) -> ProductToolIdentity? {
        let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let nsRaw = String(parts[0])
        let id = String(parts[1])
        let ns: ProductToolNamespace?
        switch nsRaw {
        case "GrokBuild", "grok_build": ns = .grokBuild
        case "GrokBuildConcise", "grok_build_concise": ns = .grokBuildConcise
        case "GrokBuildHashline", "grok_build_hashline": ns = .grokBuildHashline
        case "Codex", "codex": ns = .codex
        case "OpenCode", "opencode", "open_code": ns = .openCode
        case "MCP", "mcp": ns = .mcp
        default: ns = nil
        }
        guard let ns else { return nil }
        return ProductToolIdentity(namespace: ns, id: id)
    }
}

// MARK: - Meta

/// Canonical ACP / consumer identity stamp under `x.ai/tool`.
public struct CanonicalToolMeta: Codable, Sendable, Hashable, Equatable {
    public var version: UInt32
    public var name: String
    public var kind: ProductToolKind
    public var namespace: ProductToolNamespace
    public var label: String
    public var readOnly: Bool
    public var input: [String: String]

    public init(
        name: String,
        kind: ProductToolKind,
        namespace: ProductToolNamespace,
        label: String? = nil,
        readOnly: Bool? = nil,
        input: [String: String] = [:],
        version: UInt32 = toolMetaVersion
    ) {
        self.version = version
        self.name = name
        self.kind = kind
        self.namespace = namespace
        self.label = label ?? Self.defaultLabel(for: kind)
        self.readOnly = readOnly ?? kind.isReadOnly
        self.input = input
    }

    public static func defaultLabel(for kind: ProductToolKind) -> String {
        switch kind {
        case .read: return "Read"
        case .edit, .write: return "Edit"
        case .listDir, .list: return "List"
        case .search: return "Search"
        case .execute: return "Execute"
        case .delete: return "Delete"
        default:
            return kind.rawValue
                .split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, name, kind, namespace, label
        case readOnly = "read_only"
        case input
    }
}
