// Events.swift
//
// Pub/sub event types and topic-filter sets. Ported from
// crates/codegen/xai-grok-workspace-types/src/events/*.
//
// Only the wire types live here; the broadcast channel and `EventStream`
// wrapper are runtime concerns and live in `OpenGrokWorkspace`.
//
// There is **no** `SessionEvent` enum. The EventBus only carries
// `WorkspaceEvent` — session-scoped state (prompt boundaries, tool-call
// lifecycle, plan-mode transitions, subagent lifecycle, compaction, memory
// flushes, ...) is sampler-caused and is reported back to the sampler via
// the originating call's return value or stream chunks. The sampler owns
// that state and forwards to its UI channel as needed.

import Foundation

/// Workspace-scoped event.
///
/// Carries only **workspace-observed external state** — filesystem watcher
/// fires, background subprocess lifecycle (LSP / MCP), background indexing
/// progress, file-watcher-detected config changes, and so on. Sampler-caused
/// state never goes here.
public enum WorkspaceEvent: Hashable, Sendable, Codable, Equatable {
    /// Filesystem watcher fired.
    case fsChanged(path: String, kind: FsEventKind)
    /// Git HEAD moved.
    case gitHeadChanged(commit: String, branch: String?, vcs: VcsKind)
    /// Git lock is held by an external process; reads may block until
    /// `until` (wall-clock UTC).
    case gitLockHeld(until: Date)
    /// Skill discovery surfaced changes.
    case skillsChanged(added: [SkillInfo], removed: [String])
    /// Plugin discovery surfaced changes.
    case pluginsChanged(plugins: [PluginInfo], projectTrusted: Bool)
    /// Hook discovery surfaced changes.
    case hooksChanged(hooks: [HookInfo], projectTrusted: Bool)
    /// MCP server transitioned state.
    case mcpServerStateChanged(server: String, status: McpServerStatus)
    /// LSP server transitioned state.
    case lspServerStateChanged(server: String, status: LspServerStatus)
    /// Codebase index ingested more files.
    case codebaseIndexUpdated(filesIndexed: UInt64)
    /// Project config changed on disk.
    case projectConfigChanged
    /// Permission policy changed on disk.
    case permissionPolicyChanged
    /// A session's tool registry was rebuilt.
    case toolsChanged(sessionId: String)

    /// Topic this event belongs to (used for filtering).
    public var topic: WorkspaceTopic {
        switch self {
        case .fsChanged: return .fs
        case .gitHeadChanged, .gitLockHeld: return .vcs
        case .skillsChanged, .pluginsChanged, .hooksChanged: return .discovery
        case .mcpServerStateChanged, .lspServerStateChanged: return .servers
        case .codebaseIndexUpdated: return .index
        case .projectConfigChanged, .permissionPolicyChanged: return .config
        case .toolsChanged: return .tools
        }
    }

    // MARK: Codable — adjacent `type`/`data` tagging, snake_case variants

    private enum Tag: String, Codable {
        case fsChanged = "fs_changed"
        case gitHeadChanged = "git_head_changed"
        case gitLockHeld = "git_lock_held"
        case skillsChanged = "skills_changed"
        case pluginsChanged = "plugins_changed"
        case hooksChanged = "hooks_changed"
        case mcpServerStateChanged = "mcp_server_state_changed"
        case lspServerStateChanged = "lsp_server_state_changed"
        case codebaseIndexUpdated = "codebase_index_updated"
        case projectConfigChanged = "project_config_changed"
        case permissionPolicyChanged = "permission_policy_changed"
        case toolsChanged = "tools_changed"
    }
    private enum CodingKeys: String, CodingKey {
        case type, data
        case path, kind
        case commit, branch, vcs
        case until
        case added, removed
        case plugins
        case projectTrusted = "project_trusted"
        case hooks
        case server, status
        case filesIndexed = "files_indexed"
        case sessionId = "session_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .type)
        switch tag {
        case .fsChanged:
            let inner = try c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            self = .fsChanged(
                path: try inner.decode(String.self, forKey: .path),
                kind: try inner.decode(FsEventKind.self, forKey: .kind)
            )
        case .gitHeadChanged:
            let inner = try c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            self = .gitHeadChanged(
                commit: try inner.decode(String.self, forKey: .commit),
                branch: try inner.decodeIfPresent(String.self, forKey: .branch),
                vcs: try inner.decode(VcsKind.self, forKey: .vcs)
            )
        case .gitLockHeld:
            let inner = try c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            self = .gitLockHeld(until: try inner.decode(Date.self, forKey: .until))
        case .skillsChanged:
            let inner = try c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            self = .skillsChanged(
                added: try inner.decodeIfPresent([SkillInfo].self, forKey: .added) ?? [],
                removed: try inner.decodeIfPresent([String].self, forKey: .removed) ?? []
            )
        case .pluginsChanged:
            let inner = try c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            self = .pluginsChanged(
                plugins: try inner.decode([PluginInfo].self, forKey: .plugins),
                projectTrusted: try inner.decode(Bool.self, forKey: .projectTrusted)
            )
        case .hooksChanged:
            let inner = try c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            self = .hooksChanged(
                hooks: try inner.decode([HookInfo].self, forKey: .hooks),
                projectTrusted: try inner.decode(Bool.self, forKey: .projectTrusted)
            )
        case .mcpServerStateChanged:
            let inner = try c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            self = .mcpServerStateChanged(
                server: try inner.decode(String.self, forKey: .server),
                status: try inner.decode(McpServerStatus.self, forKey: .status)
            )
        case .lspServerStateChanged:
            let inner = try c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            self = .lspServerStateChanged(
                server: try inner.decode(String.self, forKey: .server),
                status: try inner.decode(LspServerStatus.self, forKey: .status)
            )
        case .codebaseIndexUpdated:
            let inner = try c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            self = .codebaseIndexUpdated(filesIndexed: try inner.decode(UInt64.self, forKey: .filesIndexed))
        case .projectConfigChanged:
            if c.contains(.data) { _ = try? c.decode(WorkspaceEventJSONValue?.self, forKey: .data) }
            self = .projectConfigChanged
        case .permissionPolicyChanged:
            if c.contains(.data) { _ = try? c.decode(WorkspaceEventJSONValue?.self, forKey: .data) }
            self = .permissionPolicyChanged
        case .toolsChanged:
            let inner = try c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            self = .toolsChanged(sessionId: try inner.decode(String.self, forKey: .sessionId))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fsChanged(let path, let kind):
            try c.encode(Tag.fsChanged, forKey: .type)
            var inner = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            try inner.encode(path, forKey: .path)
            try inner.encode(kind, forKey: .kind)
        case .gitHeadChanged(let commit, let branch, let vcs):
            try c.encode(Tag.gitHeadChanged, forKey: .type)
            var inner = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            try inner.encode(commit, forKey: .commit)
            try inner.encodeIfPresent(branch, forKey: .branch)
            try inner.encode(vcs, forKey: .vcs)
        case .gitLockHeld(let until):
            try c.encode(Tag.gitLockHeld, forKey: .type)
            var inner = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            try inner.encode(until, forKey: .until)
        case .skillsChanged(let added, let removed):
            try c.encode(Tag.skillsChanged, forKey: .type)
            var inner = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            try inner.encode(added, forKey: .added)
            try inner.encode(removed, forKey: .removed)
        case .pluginsChanged(let plugins, let projectTrusted):
            try c.encode(Tag.pluginsChanged, forKey: .type)
            var inner = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            try inner.encode(plugins, forKey: .plugins)
            try inner.encode(projectTrusted, forKey: .projectTrusted)
        case .hooksChanged(let hooks, let projectTrusted):
            try c.encode(Tag.hooksChanged, forKey: .type)
            var inner = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            try inner.encode(hooks, forKey: .hooks)
            try inner.encode(projectTrusted, forKey: .projectTrusted)
        case .mcpServerStateChanged(let server, let status):
            try c.encode(Tag.mcpServerStateChanged, forKey: .type)
            var inner = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            try inner.encode(server, forKey: .server)
            try inner.encode(status, forKey: .status)
        case .lspServerStateChanged(let server, let status):
            try c.encode(Tag.lspServerStateChanged, forKey: .type)
            var inner = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            try inner.encode(server, forKey: .server)
            try inner.encode(status, forKey: .status)
        case .codebaseIndexUpdated(let filesIndexed):
            try c.encode(Tag.codebaseIndexUpdated, forKey: .type)
            var inner = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            try inner.encode(filesIndexed, forKey: .filesIndexed)
        case .projectConfigChanged:
            try c.encode(Tag.projectConfigChanged, forKey: .type)
        case .permissionPolicyChanged:
            try c.encode(Tag.permissionPolicyChanged, forKey: .type)
        case .toolsChanged(let sessionId):
            try c.encode(Tag.toolsChanged, forKey: .type)
            var inner = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            try inner.encode(sessionId, forKey: .sessionId)
        }
    }
}

/// A `JSONValue?` shim used only for `WorkspaceEvent` unit variants to
/// tolerate an absent or null `data` payload without importing the full
/// `OpenGrokShared.JSONValue` machinery. Defined locally to keep the
/// events module's decode error surface narrow.
private enum WorkspaceEventJSONValue: Codable {
    case null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null } else { self = .null }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encodeNil()
    }
}

// MARK: - WorkspaceTopic

/// Topic discriminator for workspace events.
///
/// Used by `EventBus.subscribeFiltered` to skip uninteresting events. The
/// mapping from event variant to topic is documented inline on
/// `WorkspaceEvent.topic`; topic filtering is purely a delivery
/// optimisation — it never changes the event payload.
public enum WorkspaceTopic: Hashable, Sendable, Codable, Equatable, CaseIterable {
    case fs
    case vcs
    case discovery
    case servers
    case index
    case config
    case tools

    /// Stable wire string.
    public var asString: String {
        switch self {
        case .fs: return "fs"
        case .vcs: return "vcs"
        case .discovery: return "discovery"
        case .servers: return "servers"
        case .index: return "index"
        case .config: return "config"
        case .tools: return "tools"
        }
    }

    // MARK: Codable

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        switch raw {
        case "fs": self = .fs
        case "vcs": self = .vcs
        case "discovery": self = .discovery
        case "servers": self = .servers
        case "index": self = .index
        case "config": self = .config
        case "tools": self = .tools
        default:
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown WorkspaceTopic: \(raw)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(asString)
    }
}

// MARK: - WorkspaceTopicSet

/// Set of workspace topics. Implemented as a small bitmask to keep filter
/// checks branch-free.
public struct WorkspaceTopicSet: Hashable, Sendable, Codable, Equatable {
    /// Bitmask: bit `n` is `WorkspaceTopic` discriminant `n`.
    public var bits: UInt32

    /// Empty set (matches no events).
    public init() { self.bits = 0 }

    /// Empty set (matches no events).
    public static let empty = WorkspaceTopicSet()

    /// Set containing every topic.
    public static func all() -> WorkspaceTopicSet {
        var s = WorkspaceTopicSet.empty
        for t in WorkspaceTopic.allCases {
            s = s.with(t)
        }
        return s
    }

    /// Return a copy of this set with `topic` added.
    @discardableResult
    public func with(_ topic: WorkspaceTopic) -> WorkspaceTopicSet {
        var copy = self
        copy.bits |= 1 &<< Self.topicIndex(topic)
        return copy
    }

    /// Whether `topic` is contained in the set.
    public func contains(_ topic: WorkspaceTopic) -> Bool {
        (bits & (1 &<< Self.topicIndex(topic))) != 0
    }

    /// Whether the set is empty.
    public var isEmpty: Bool { bits == 0 }

    private static func topicIndex(_ topic: WorkspaceTopic) -> UInt32 {
        // Stable indices (do not reorder existing variants without bumping
        // the wire-compat manifest).
        switch topic {
        case .fs: return 0
        case .vcs: return 1
        case .discovery: return 2
        case .servers: return 3
        case .index: return 4
        case .config: return 5
        case .tools: return 6
        }
    }

    // MARK: Codable — transparent integer

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        bits = try c.decode(UInt32.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(bits)
    }
}

// MARK: - EventLag

/// Backpressure signal emitted when the event-bus subscriber lags behind
/// the producer and events are dropped.
///
/// The `lagged` case carries the number of events dropped between the
/// previous successful receive and the current one.
public enum EventLag: Error, Hashable, Sendable, Codable, Equatable {
    case lagged(UInt64)

    private enum Tag: String, Codable { case lagged }
    private enum CodingKeys: String, CodingKey { case type, data }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .type)
        switch tag {
        case .lagged:
            self = .lagged(try c.decode(UInt64.self, forKey: .data))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .lagged(let n):
            try c.encode(Tag.lagged, forKey: .type)
            try c.encode(n, forKey: .data)
        }
    }
}

extension EventLag: CustomStringConvertible {
    public var description: String {
        switch self {
        case .lagged(let n):
            return "lagged by \(n) events"
        }
    }
}
