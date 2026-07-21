// Requests.swift
//
// Wire-format request enums. Ported from
// crates/codegen/xai-grok-workspace-types/src/requests/*.
//
// `WorkspaceRequest` is the outer envelope (matched on at the
// transport-layer dispatch). The three inner enums (`ToolRequest`,
// `WorkspaceOpsRequest`, `SessionLifecycleRequest`) are the actual
// per-domain RPC payloads.
//
// Each request enum enumerates its full set of per-domain variants.

import Foundation

// MARK: - WorkspaceRequest (outer envelope)

/// Outer-envelope wire request.
///
/// Each variant maps to one of the four streaming gRPC RPCs (`Tool`,
/// `Ops`, `Session`, plus `Events` which is a separate subscription type
/// and does not appear here).
public enum WorkspaceRequest: Hashable, Sendable, Codable, Equatable {
    case tool(ToolRequest)
    case ops(WorkspaceOpsRequest)
    case session(SessionLifecycleRequest)

    private enum Tag: String, Codable { case tool, ops, session }
    private enum CodingKeys: String, CodingKey { case type, data }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .type)
        switch tag {
        case .tool:
            self = .tool(try c.decode(ToolRequest.self, forKey: .data))
        case .ops:
            self = .ops(try c.decode(WorkspaceOpsRequest.self, forKey: .data))
        case .session:
            self = .session(try c.decode(SessionLifecycleRequest.self, forKey: .data))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tool(let v):
            try c.encode(Tag.tool, forKey: .type)
            try c.encode(v, forKey: .data)
        case .ops(let v):
            try c.encode(Tag.ops, forKey: .type)
            try c.encode(v, forKey: .data)
        case .session(let v):
            try c.encode(Tag.session, forKey: .type)
            try c.encode(v, forKey: .data)
        }
    }
}

// MARK: - ToolRequest

/// Top-level tool RPC.
public enum ToolRequest: Hashable, Sendable, Codable, Equatable {
    /// Execute a tool. The streaming response is a sequence of
    /// `ToolChunk.output` / `.progress` chunks ending with exactly one
    /// `ToolChunk.final`.
    case call(ToolCallArgs)
    /// List the registered tool definitions. The response is a single
    /// `ToolChunk.definitions([ToolDef])`.
    case definitions

    private enum Tag: String, Codable { case call, definitions }
    private enum CodingKeys: String, CodingKey { case type, data }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .type)
        switch tag {
        case .call:
            self = .call(try c.decode(ToolCallArgs.self, forKey: .data))
        case .definitions:
            // Unit variant — tolerate absent or null `data`.
            if c.contains(.data) { _ = try? c.decode(UnitPayload?.self, forKey: .data) }
            self = .definitions
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .call(let v):
            try c.encode(Tag.call, forKey: .type)
            try c.encode(v, forKey: .data)
        case .definitions:
            try c.encode(Tag.definitions, forKey: .type)
        }
    }
}

/// Arguments for `ToolRequest.call`.
public struct ToolCallArgs: Hashable, Sendable, Codable, Equatable {
    public var session: SessionId
    public var toolName: String
    public var inputJson: String
    public var callId: ToolCallId

    public init(
        session: SessionId,
        toolName: String,
        inputJson: String = "",
        callId: ToolCallId
    ) {
        self.session = session
        self.toolName = toolName
        self.inputJson = inputJson
        self.callId = callId
    }

    enum CodingKeys: String, CodingKey {
        case session
        case toolName = "tool_name"
        case inputJson = "input_json"
        case callId = "call_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session = try c.decode(SessionId.self, forKey: .session)
        toolName = try c.decode(String.self, forKey: .toolName)
        inputJson = try c.decodeIfPresent(String.self, forKey: .inputJson) ?? ""
        callId = try c.decode(ToolCallId.self, forKey: .callId)
    }
}

/// Tiny nullable payload used to absorb absent/null `data` for unit
/// variants under adjacent tagging. Defined locally to keep the decode
/// error surface narrow.
private enum UnitPayload: Codable {
    case unit
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .unit } else { self = .unit }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encodeNil()
    }
}

// MARK: - WorkspaceOpsRequest

/// Top-level workspace-ops RPC.
///
/// All variants share a single streaming RPC; the per-variant chunk
/// contract is documented on `OpsChunk` (most are unary, ripgrep and
/// fuzzy_search are streaming).
public enum WorkspaceOpsRequest: Hashable, Sendable, Codable, Equatable {
    // VCS
    case gitStatus(GitStatusOpts)
    case gitDiff(GitDiffArgs)
    case gitBranchInfo
    case gitMetadata
    // Hunks
    case listHunks
    case actOnHunk(HunkAction)
    // Search
    case ripgrep(RipgrepArgs)
    case fuzzySearch(FuzzySearchArgs)
    // Discovery / config
    case discoverSkills
    case discoverPlugins
    case loadProjectConfig
    case loadPermissions
    case loadEnvrc
    // @file provider
    case resolveFileRefs([String])
    // Memory
    case memorySearch(query: String, limit: UInt32)
    case memoryWrite(String)
    // Marketplace
    case installPlugin(String)
    case refreshPlugins

    private enum Tag: String, Codable {
        case gitStatus = "git_status"
        case gitDiff = "git_diff"
        case gitBranchInfo = "git_branch_info"
        case gitMetadata = "git_metadata"
        case listHunks = "list_hunks"
        case actOnHunk = "act_on_hunk"
        case ripgrep
        case fuzzySearch = "fuzzy_search"
        case discoverSkills = "discover_skills"
        case discoverPlugins = "discover_plugins"
        case loadProjectConfig = "load_project_config"
        case loadPermissions = "load_permissions"
        case loadEnvrc = "load_envrc"
        case resolveFileRefs = "resolve_file_refs"
        case memorySearch = "memory_search"
        case memoryWrite = "memory_write"
        case installPlugin = "install_plugin"
        case refreshPlugins = "refresh_plugins"
    }
    private enum CodingKeys: String, CodingKey { case type, data, query, limit }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .type)
        switch tag {
        case .gitStatus:
            self = .gitStatus(try c.decode(GitStatusOpts.self, forKey: .data))
        case .gitDiff:
            self = .gitDiff(try c.decode(GitDiffArgs.self, forKey: .data))
        case .gitBranchInfo:
            if c.contains(.data) { _ = try? c.decode(UnitPayload?.self, forKey: .data) }
            self = .gitBranchInfo
        case .gitMetadata:
            if c.contains(.data) { _ = try? c.decode(UnitPayload?.self, forKey: .data) }
            self = .gitMetadata
        case .listHunks:
            if c.contains(.data) { _ = try? c.decode(UnitPayload?.self, forKey: .data) }
            self = .listHunks
        case .actOnHunk:
            self = .actOnHunk(try c.decode(HunkAction.self, forKey: .data))
        case .ripgrep:
            self = .ripgrep(try c.decode(RipgrepArgs.self, forKey: .data))
        case .fuzzySearch:
            self = .fuzzySearch(try c.decode(FuzzySearchArgs.self, forKey: .data))
        case .discoverSkills:
            if c.contains(.data) { _ = try? c.decode(UnitPayload?.self, forKey: .data) }
            self = .discoverSkills
        case .discoverPlugins:
            if c.contains(.data) { _ = try? c.decode(UnitPayload?.self, forKey: .data) }
            self = .discoverPlugins
        case .loadProjectConfig:
            if c.contains(.data) { _ = try? c.decode(UnitPayload?.self, forKey: .data) }
            self = .loadProjectConfig
        case .loadPermissions:
            if c.contains(.data) { _ = try? c.decode(UnitPayload?.self, forKey: .data) }
            self = .loadPermissions
        case .loadEnvrc:
            if c.contains(.data) { _ = try? c.decode(UnitPayload?.self, forKey: .data) }
            self = .loadEnvrc
        case .resolveFileRefs:
            self = .resolveFileRefs(try c.decode([String].self, forKey: .data))
        case .memorySearch:
            let inner = try c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            self = .memorySearch(
                query: try inner.decode(String.self, forKey: .query),
                limit: try inner.decode(UInt32.self, forKey: .limit)
            )
        case .memoryWrite:
            self = .memoryWrite(try c.decode(String.self, forKey: .data))
        case .installPlugin:
            self = .installPlugin(try c.decode(String.self, forKey: .data))
        case .refreshPlugins:
            if c.contains(.data) { _ = try? c.decode(UnitPayload?.self, forKey: .data) }
            self = .refreshPlugins
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .gitStatus(let v):
            try c.encode(Tag.gitStatus, forKey: .type)
            try c.encode(v, forKey: .data)
        case .gitDiff(let v):
            try c.encode(Tag.gitDiff, forKey: .type)
            try c.encode(v, forKey: .data)
        case .gitBranchInfo:
            try c.encode(Tag.gitBranchInfo, forKey: .type)
        case .gitMetadata:
            try c.encode(Tag.gitMetadata, forKey: .type)
        case .listHunks:
            try c.encode(Tag.listHunks, forKey: .type)
        case .actOnHunk(let v):
            try c.encode(Tag.actOnHunk, forKey: .type)
            try c.encode(v, forKey: .data)
        case .ripgrep(let v):
            try c.encode(Tag.ripgrep, forKey: .type)
            try c.encode(v, forKey: .data)
        case .fuzzySearch(let v):
            try c.encode(Tag.fuzzySearch, forKey: .type)
            try c.encode(v, forKey: .data)
        case .discoverSkills:
            try c.encode(Tag.discoverSkills, forKey: .type)
        case .discoverPlugins:
            try c.encode(Tag.discoverPlugins, forKey: .type)
        case .loadProjectConfig:
            try c.encode(Tag.loadProjectConfig, forKey: .type)
        case .loadPermissions:
            try c.encode(Tag.loadPermissions, forKey: .type)
        case .loadEnvrc:
            try c.encode(Tag.loadEnvrc, forKey: .type)
        case .resolveFileRefs(let v):
            try c.encode(Tag.resolveFileRefs, forKey: .type)
            try c.encode(v, forKey: .data)
        case .memorySearch(let query, let limit):
            try c.encode(Tag.memorySearch, forKey: .type)
            var inner = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            try inner.encode(query, forKey: .query)
            try inner.encode(limit, forKey: .limit)
        case .memoryWrite(let s):
            try c.encode(Tag.memoryWrite, forKey: .type)
            try c.encode(s, forKey: .data)
        case .installPlugin(let s):
            try c.encode(Tag.installPlugin, forKey: .type)
            try c.encode(s, forKey: .data)
        case .refreshPlugins:
            try c.encode(Tag.refreshPlugins, forKey: .type)
        }
    }
}

// MARK: - SessionLifecycleRequest

/// Top-level session-lifecycle RPC.
public enum SessionLifecycleRequest: Hashable, Sendable, Codable, Equatable {
    /// Fork a new session. Response: `SessionChunk.sessionId`.
    case fork(AgentSessionConfig)
    /// Destroy a session. Response: `SessionChunk.ack`.
    case destroy(SessionId)
    /// List all sessions. Streams `SessionChunk.sessionInfo` (one per
    /// session).
    case list
    /// Apply a (sub)session's worktree back into the parent.
    /// Response: `SessionChunk.ack`.
    case applyWorktree(SessionId)
    /// Mark the start of a prompt. Response: `SessionChunk.ack`.
    case beginPrompt(session: SessionId, idx: UInt64)
    /// Mark the end of a prompt. Response: `SessionChunk.ack`.
    case endPrompt(session: SessionId, idx: UInt64)
    /// Rewind a session to a target prompt index. Response:
    /// `SessionChunk.rewindResult`.
    case rewind(session: SessionId, target: UInt64)
    /// Enumerate the available rewind points for a session. Response:
    /// `SessionChunk.rewindPoints`.
    case getRewindPoints(SessionId)

    private enum Tag: String, Codable {
        case fork, destroy, list
        case applyWorktree = "apply_worktree"
        case beginPrompt = "begin_prompt"
        case endPrompt = "end_prompt"
        case rewind
        case getRewindPoints = "get_rewind_points"
    }
    private enum CodingKeys: String, CodingKey {
        case type, data, session, idx, target
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .type)
        switch tag {
        case .fork:
            self = .fork(try c.decode(AgentSessionConfig.self, forKey: .data))
        case .destroy:
            self = .destroy(try c.decode(SessionId.self, forKey: .data))
        case .list:
            if c.contains(.data) { _ = try? c.decode(UnitPayload?.self, forKey: .data) }
            self = .list
        case .applyWorktree:
            self = .applyWorktree(try c.decode(SessionId.self, forKey: .data))
        case .beginPrompt:
            let inner = try c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            self = .beginPrompt(
                session: try inner.decode(SessionId.self, forKey: .session),
                idx: try inner.decode(UInt64.self, forKey: .idx)
            )
        case .endPrompt:
            let inner = try c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            self = .endPrompt(
                session: try inner.decode(SessionId.self, forKey: .session),
                idx: try inner.decode(UInt64.self, forKey: .idx)
            )
        case .rewind:
            let inner = try c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            self = .rewind(
                session: try inner.decode(SessionId.self, forKey: .session),
                target: try inner.decode(UInt64.self, forKey: .target)
            )
        case .getRewindPoints:
            self = .getRewindPoints(try c.decode(SessionId.self, forKey: .data))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fork(let v):
            try c.encode(Tag.fork, forKey: .type)
            try c.encode(v, forKey: .data)
        case .destroy(let v):
            try c.encode(Tag.destroy, forKey: .type)
            try c.encode(v, forKey: .data)
        case .list:
            try c.encode(Tag.list, forKey: .type)
        case .applyWorktree(let v):
            try c.encode(Tag.applyWorktree, forKey: .type)
            try c.encode(v, forKey: .data)
        case .beginPrompt(let session, let idx):
            try c.encode(Tag.beginPrompt, forKey: .type)
            var inner = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            try inner.encode(session, forKey: .session)
            try inner.encode(idx, forKey: .idx)
        case .endPrompt(let session, let idx):
            try c.encode(Tag.endPrompt, forKey: .type)
            var inner = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            try inner.encode(session, forKey: .session)
            try inner.encode(idx, forKey: .idx)
        case .rewind(let session, let target):
            try c.encode(Tag.rewind, forKey: .type)
            var inner = c.nestedContainer(keyedBy: CodingKeys.self, forKey: .data)
            try inner.encode(session, forKey: .session)
            try inner.encode(target, forKey: .target)
        case .getRewindPoints(let v):
            try c.encode(Tag.getRewindPoints, forKey: .type)
            try c.encode(v, forKey: .data)
        }
    }
}
