// RpcMethods.swift
//
// Canonical wire types for hub-proxied `workspace.*` RPC methods, shared by
// the server (hub_server), the shell proxy client (`WorkspaceOps`), and
// clients that cannot depend on `OpenGrokWorkspace`. Ported from
// `crates/codegen/xai-grok-workspace-types/src/rpc/*`.
//
// This file ports:
//   * `RpcEnvelope` / `RpcError` (envelope.rs) — the response envelope
//     shared by every `workspace.*` method.
//   * The `WorkspaceRpc` marker protocol + tool-id constants (mod.rs).
//   * The most commonly referenced per-method request/response types:
//     `workspace.info`, `workspace.load_project_config`,
//     `workspace.load_permissions`, `workspace.load_envrc`,
//     `workspace.tool_definitions`, `workspace.update_tool_config`,
//     `workspace.drop_session`, `workspace.configure_mcp`,
//     `workspace.install_plugin`, `workspace.refresh_plugins`,
//     `workspace.list_background_tasks`, `workspace.list_todos`,
//     `workspace.resolve_file_references`, the
//     `workspace.discover_agents_md` / `workspace.discover_skills` /
//     `workspace.discover_plugins` discovery methods, and the
//     `workspace.hook_registry` hook-spec wire mirror.
//
// Per-method types not yet migrated here (the larger `git.*`, `fs.*`,
// `code_nav.*`, `deploy.*`, `hunks.*`, `search.*`, `session.*`,
// `worktree.*` families) live next to their `WorkspaceOp` impls in
// `OpenGrokWorkspace`; each has exactly one `WorkspaceRpc` impl. The
// envelope and protocol defined here are the source of truth for
// dispatch — later slices can lift additional method types into this
// target without changing the wire contract.

import Foundation
import OpenGrokShared

// MARK: - Tool IDs

/// Tool ID for the `WorkspaceRpcHandler` (workspace method dispatch).
public let WORKSPACE_RPC_TOOL_ID: String = "workspace_rpc"

/// Tool ID used for `WorkspaceEvent` notification frames.
public let WORKSPACE_EVENTS_TOOL_ID: String = "workspace_events"

/// Tool ID used for `ToolNotification` forwarding frames.
public let WORKSPACE_TOOL_NOTIFICATIONS_TOOL_ID: String = "workspace_tool_notifications"

/// Tool ID used for workspace-originated client ext-notification frames
/// (e.g. `x.ai/search/fuzzy/status`). Carries `{ method, params }`.
public let WORKSPACE_CLIENT_EXT_NOTIFICATIONS_TOOL_ID: String = "workspace_client_ext_notifications"

// MARK: - WorkspaceRpc protocol

/// Marker protocol for typed workspace RPC requests. Client and server use
/// the same struct for the same method.
///
/// `Response` is bounded both ways because servers serialize it into the
/// `RpcEnvelope` and clients deserialize it out. The `method` constant is
/// the canonical wire method name (e.g. `"workspace.git_status_ext"`).
public protocol WorkspaceRpc: Codable, Sendable {
    /// Wire method name (e.g. `"workspace.git_status_ext"`).
    static var method: String { get }

    /// The typed response payload.
    associatedtype Response: Codable & Sendable
}

// MARK: - RpcEnvelope + RpcError

/// Wire code for "the target session has an active turn" rejections of
/// toolset mutations (`workspace.update_tool_config`). Retryable at the
/// turn boundary. Shared so clients can recognise the retryable class
/// without depending on the workspace crate's error enum.
public let TURN_ACTIVE: String = "turn_active"

/// Response envelope for `workspace.*` methods. Wire shape:
///
///   {"ok": <value>}
///   {"err": {"code": "<code>", "message": "<message>"}}
public enum RpcEnvelope<T: Codable & Sendable & Hashable & Equatable>: Hashable, Sendable, Codable, Equatable {
    case ok(T)
    case err(RpcError)

    /// Convert the envelope into a `Result`.
    public func intoResult() -> Result<T, RpcError> {
        switch self {
        case .ok(let v): return .success(v)
        case .err(let e): return .failure(e)
        }
    }

    /// Construct an `ok` envelope.
    public static func makeOk(_ value: T) -> RpcEnvelope<T> { .ok(value) }

    /// Construct an `err` envelope from parts.
    public static func makeErr(code: String, message: String) -> RpcEnvelope<T> {
        .err(RpcError(code: code, message: message))
    }

    // MARK: Codable — `#[serde(rename_all = "snake_case")]` adjacent
    // (untagged-on-`ok`/`err`, content is the value/error directly).

    private enum CodingKeys: String, CodingKey { case ok, err }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try c.decodeIfPresent(T.self, forKey: .ok) {
            self = .ok(v)
        } else if let e = try c.decodeIfPresent(RpcError.self, forKey: .err) {
            self = .err(e)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .ok, in: c, debugDescription: "RpcEnvelope must have either `ok` or `err`")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ok(let v):
            try c.encode(v, forKey: .ok)
        case .err(let e):
            try c.encode(e, forKey: .err)
        }
    }
}

/// RPC error payload.
public struct RpcError: Error, Hashable, Sendable, Codable, Equatable {
    /// Discriminant code (e.g. `"session_not_found"`, `"hub_error"`).
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    /// Whether this error is a `TURN_ACTIVE` rejection, retryable at the
    /// turn boundary.
    public var isTurnActive: Bool { code == TURN_ACTIVE }

    enum CodingKeys: String, CodingKey { case code, message }
}

extension RpcError: CustomStringConvertible {
    public var description: String { "[\(code)] \(message)" }
}

// MARK: - Deploy error kind
//
// Ported from `rpc/deploy.rs`. The `DeployError` enum carries
// machine-readable discriminants that flow as `RpcError.code` strings; the
// `wireCode`/`fromWireCode` pair preserves round-trip parity.

/// App deployment workspace RPC error kind. Carried on the
/// `RpcError.code` discriminant.
public enum DeployError: Hashable, Sendable, Codable, Equatable, CaseIterable {
    case urlConflict
    case urlModeration
    case idempotencyConflict
    case notFound
    case permissionDenied
    case deploymentNotInBuildingState
    case unsupportedProjectType
    case providerUnavailable
    case internal_
    case unauthenticated
    case invalidArgument
    case resourceExhausted
    case deadlineExceeded
    case alreadyExists
    case failedPrecondition

    /// Every kind, for exhaustive iteration in tests.
    public static let allCases: [DeployError] = [
        .urlConflict, .urlModeration, .idempotencyConflict, .notFound,
        .permissionDenied, .deploymentNotInBuildingState, .unsupportedProjectType,
        .providerUnavailable, .internal_, .unauthenticated, .invalidArgument,
        .resourceExhausted, .deadlineExceeded, .alreadyExists, .failedPrecondition
    ]

    /// The `RpcError.code` discriminant carried on the workspace RPC
    /// envelope.
    public var wireCode: String {
        switch self {
        case .urlConflict: return "deploy_url_conflict"
        case .urlModeration: return "deploy_url_moderation"
        case .idempotencyConflict: return "deploy_idempotency_conflict"
        case .notFound: return "deploy_not_found"
        case .permissionDenied: return "deploy_permission_denied"
        case .deploymentNotInBuildingState: return "deploy_not_in_building_state"
        case .unsupportedProjectType: return "deploy_unsupported_project_type"
        case .providerUnavailable: return "deploy_provider_unavailable"
        case .internal_: return "deploy_internal"
        case .unauthenticated: return "deploy_unauthenticated"
        case .invalidArgument: return "deploy_invalid_argument"
        case .resourceExhausted: return "deploy_resource_exhausted"
        case .deadlineExceeded: return "deploy_deadline_exceeded"
        case .alreadyExists: return "deploy_already_exists"
        case .failedPrecondition: return "deploy_failed_precondition"
        }
    }

    /// Parse a `RpcError.code` discriminant back into a kind, or `nil`
    /// when the code is not a deploy error code.
    public static func fromWireCode(_ code: String) -> DeployError? {
        for kind in allCases where kind.wireCode == code {
            return kind
        }
        return nil
    }
}

// MARK: - workspace.info / load_* / tool_definitions / drop_session /
// configure_mcp / install_plugin / refresh_plugins / list_background_tasks /
// list_todos / resolve_file_references / update_tool_config
//
// Ported from `rpc/workspace.rs`. Request types with raw `serde_json::Value`
// responses keep `JSONValue` (from `OpenGrokShared`) as the `Response`
// payload — the shapes are interpreted by the runtime crate, not here.

/// `workspace.info`. Response stays the raw `JSONValue` to preserve the
/// `WorkspaceOps.workspaceInfo()` contract; `WorkspaceInfo` below is the
/// typed shape of that value.
public struct WorkspaceInfoReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public init() {}

    public static let method: String = "workspace.info"
    public typealias Response = JSONValue

    public init(from decoder: Decoder) throws {
        // Empty struct — tolerate any (or no) payload.
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { return }
        // Ignore any object payload.
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encodeNil()
    }
}

/// Typed response of `workspace.info`.
public struct WorkspaceInfo: Hashable, Sendable, Codable, Equatable {
    public var os: String
    public var shell: String
    public var cwd: String

    public init(os: String, shell: String, cwd: String) {
        self.os = os
        self.shell = shell
        self.cwd = cwd
    }

    enum CodingKeys: String, CodingKey { case os, shell, cwd }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        os = try c.decode(String.self, forKey: .os)
        shell = try c.decode(String.self, forKey: .shell)
        cwd = try c.decode(String.self, forKey: .cwd)
    }
}

/// `workspace.load_project_config` — project config discovered at the
/// workspace root.
public struct LoadProjectConfigReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public init() {}

    public static let method: String = "workspace.load_project_config"
    public typealias Response = JSONValue

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { return }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encodeNil()
    }
}

/// `workspace.load_permissions` — permission settings discovered at the
/// workspace root. The raw response is `JSONValue`; the canonical typed
/// shape lives in `PermissionPolicy` (see `WorkspaceTypes.swift`).
public struct LoadPermissionsReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public init() {}

    public static let method: String = "workspace.load_permissions"
    public typealias Response = JSONValue

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { return }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encodeNil()
    }
}

/// `workspace.load_envrc` — `.envrc` environment loaded at the workspace
/// root (empty object when absent).
public struct LoadEnvrcReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public init() {}

    public static let method: String = "workspace.load_envrc"
    public typealias Response = JSONValue

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { return }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encodeNil()
    }
}

/// `workspace.tool_definitions` — tool definitions for a session's
/// finalized toolset.
public struct ToolDefinitionsReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }

    public static let method: String = "workspace.tool_definitions"
    public typealias Response = JSONValue

    enum CodingKeys: String, CodingKey { case sessionId = "session_id" }
}

/// `workspace.resolve_file_references` — resolve `@file` references
/// against the workspace root.
public struct ResolveFileReferencesReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var refs: [String]

    public init(refs: [String]) {
        self.refs = refs
    }

    public static let method: String = "workspace.resolve_file_references"
    public typealias Response = JSONValue

    enum CodingKeys: String, CodingKey { case refs }
}

/// `workspace.update_tool_config` — replace a session's tool config.
///
/// Rejected with the retryable `TURN_ACTIVE` wire code while the target
/// session has an active turn and the new config differs; retry at the
/// turn boundary.
public struct UpdateToolConfigReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    /// Deprecated: self-attested and no longer trusted. The server derives
    /// the caller from the hub-bound envelope session and only falls back
    /// to this field when no envelope session is present (old call paths).
    /// Empty means absent: skipped on serialize so typed clients that leave
    /// the default do not send a self-attested `""` (the server also
    /// filters empty to absent for old serializers).
    public var callerSessionId: String
    public var sessionId: String
    public var newConfig: JSONValue

    public init(callerSessionId: String = "", sessionId: String, newConfig: JSONValue) {
        self.callerSessionId = callerSessionId
        self.sessionId = sessionId
        self.newConfig = newConfig
    }

    public static let method: String = "workspace.update_tool_config"
    public typealias Response = JSONValue

    enum CodingKeys: String, CodingKey {
        case callerSessionId = "caller_session_id"
        case sessionId = "session_id"
        case newConfig = "new_config"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        callerSessionId = try c.decodeIfPresent(String.self, forKey: .callerSessionId) ?? ""
        sessionId = try c.decode(String.self, forKey: .sessionId)
        newConfig = try c.decode(JSONValue.self, forKey: .newConfig)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // `#[serde(default, skip_serializing_if = "String::is_empty")]`.
        if !callerSessionId.isEmpty {
            try c.encode(callerSessionId, forKey: .callerSessionId)
        }
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(newConfig, forKey: .newConfig)
    }
}

/// `workspace.drop_session` — drop a workspace session.
public struct DropSessionReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    /// Deprecated: self-attested and no longer trusted. The server derives
    /// the caller from the hub-bound envelope session. Empty means absent.
    public var callerSessionId: String
    public var sessionId: String

    public init(callerSessionId: String = "", sessionId: String) {
        self.callerSessionId = callerSessionId
        self.sessionId = sessionId
    }

    public static let method: String = "workspace.drop_session"
    public typealias Response = JSONValue

    enum CodingKeys: String, CodingKey {
        case callerSessionId = "caller_session_id"
        case sessionId = "session_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        callerSessionId = try c.decodeIfPresent(String.self, forKey: .callerSessionId) ?? ""
        sessionId = try c.decode(String.self, forKey: .sessionId)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if !callerSessionId.isEmpty {
            try c.encode(callerSessionId, forKey: .callerSessionId)
        }
        try c.encode(sessionId, forKey: .sessionId)
    }
}

/// `workspace.configure_mcp` — start MCP servers for the caller's bound
/// session. `mcpServers` stays raw JSON (the shape is the ACP `McpServer`
/// list) so this crate carries no `agent-client-protocol` dependency.
public struct ConfigureMcpReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var mcpServers: JSONValue

    public init(mcpServers: JSONValue) {
        self.mcpServers = mcpServers
    }

    public static let method: String = "workspace.configure_mcp"
    public typealias Response = JSONValue

    enum CodingKeys: String, CodingKey { case mcpServers = "mcp_servers" }
}

/// `workspace.install_plugin` — no-op on the server (installation needs
/// shell-side auth + registry); always returns `null`.
public struct InstallPluginReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public init() {}

    public static let method: String = "workspace.install_plugin"
    public typealias Response = JSONValue

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { return }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encodeNil()
    }
}

/// `workspace.refresh_plugins` — re-discover plugins at the workspace root.
public struct RefreshPluginsReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public init() {}

    public static let method: String = "workspace.refresh_plugins"
    public typealias Response = JSONValue

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { return }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encodeNil()
    }
}

/// One still-running background terminal command (a slim, dependency-free
/// DTO over `xai_grok_tools`'s `TaskSnapshot`). `toolName`, when set, is
/// the model-facing name of the tool that created the task.
public struct BackgroundTaskSummaryWire: Hashable, Sendable, Codable, Equatable {
    public var taskId: String
    public var command: String
    public var toolName: String?

    public init(taskId: String, command: String, toolName: String? = nil) {
        self.taskId = taskId
        self.command = command
        self.toolName = toolName
    }

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case command
        case toolName = "tool_name"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskId = try c.decode(String.self, forKey: .taskId)
        command = try c.decode(String.self, forKey: .command)
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(taskId, forKey: .taskId)
        try c.encode(command, forKey: .command)
        // `skip_serializing_if = "Option::is_none"`.
        if let t = toolName {
            try c.encode(t, forKey: .toolName)
        }
    }
}

/// Response of `workspace.list_background_tasks` — outstanding
/// (not-completed) background terminal tasks only.
public struct ListBackgroundTasksResponse: Hashable, Sendable, Codable, Equatable {
    public var tasks: [BackgroundTaskSummaryWire]

    public init(tasks: [BackgroundTaskSummaryWire] = []) {
        self.tasks = tasks
    }

    enum CodingKeys: String, CodingKey { case tasks }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try c.decodeIfPresent([BackgroundTaskSummaryWire].self, forKey: .tasks) ?? []
    }
}

/// `workspace.list_background_tasks` — list the outstanding background
/// terminal commands for `session_id`, for post-compaction
/// `<system-reminder>` state. The caller supplies the hub-bound session
/// id (the client is session-agnostic).
public struct ListBackgroundTasksReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }

    public static let method: String = "workspace.list_background_tasks"
    public typealias Response = ListBackgroundTasksResponse

    enum CodingKeys: String, CodingKey { case sessionId = "session_id" }
}

/// One TODO list item (slim DTO over `xai_grok_tools`'s `TodoState`).
/// `status` is the snake_case tag: `pending` | `in_progress` |
/// `completed` | `cancelled`.
public struct TodoSummaryWire: Hashable, Sendable, Codable, Equatable {
    public var id: String
    public var content: String
    public var status: String

    public init(id: String, content: String, status: String) {
        self.id = id
        self.content = content
        self.status = status
    }

    enum CodingKeys: String, CodingKey { case id, content, status }
}

/// Response of `workspace.list_todos` — the full TODO list for the session.
public struct ListTodosResponse: Hashable, Sendable, Codable, Equatable {
    public var todos: [TodoSummaryWire]

    public init(todos: [TodoSummaryWire] = []) {
        self.todos = todos
    }

    enum CodingKeys: String, CodingKey { case todos }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        todos = try c.decodeIfPresent([TodoSummaryWire].self, forKey: .todos) ?? []
    }
}

/// `workspace.list_todos` — list the session's TODO items for
/// post-compaction `<system-reminder>` state. The caller supplies the
/// hub-bound session id.
public struct ListTodosReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }

    public static let method: String = "workspace.list_todos"
    public typealias Response = ListTodosResponse

    enum CodingKeys: String, CodingKey { case sessionId = "session_id" }
}

// MARK: - workspace.discover_agents_md
//
// Ported from `rpc/agents_md.rs`.

/// `workspace.discover_agents_md` — project-instruction files (AGENTS.md /
/// Claude.md / `.opengrok/rules/*.md`) discovered from the workspace root
/// up to the git root, plus `~/.opengrok` and compat dirs.
public struct DiscoverAgentsMdReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public init() {}

    public static let method: String = "workspace.discover_agents_md"
    public typealias Response = [AgentConfigFile]

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { return }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encodeNil()
    }
}

/// Mirrors the serde shape of `xai-grok-agent`'s `AgentConfigFile`.
public struct AgentConfigFile: Hashable, Sendable, Codable, Equatable {
    public var fileName: String
    public var filePath: String
    public var content: String

    public init(fileName: String, filePath: String, content: String) {
        self.fileName = fileName
        self.filePath = filePath
        self.content = content
    }

    enum CodingKeys: String, CodingKey {
        case fileName = "file_name"
        case filePath = "file_path"
        case content
    }
}

// MARK: - workspace.discover_skills / workspace.discover_plugins
//
// Ported from `rpc/skills.rs`. The `SkillInfo` here is `scope`-keyed and
// distinct from `OpenGrokWorkspaceTypes.SkillInfo` (which is `source`-keyed
// and used by `OpsChunk.skills` / `WorkspaceEvent.skillsChanged`). The
// namespacing submodule `RPCSkills` keeps the two types from clashing.

public enum RPCSkills {
    /// `workspace.discover_skills`.
    public struct DiscoverReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
        public init() {}

        public static let method: String = "workspace.discover_skills"
        public typealias Response = [SkillInfo]

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { return }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encodeNil()
        }
    }

    /// `workspace.discover_plugins` — plugins discovered at the workspace
    /// root. Each element is the raw serialized plugin object.
    public struct DiscoverPluginsReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
        public init() {}

        public static let method: String = "workspace.discover_plugins"
        public typealias Response = [JSONValue]

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { return }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encodeNil()
        }
    }

    /// Scope/priority of a skill based on where it was discovered.
    /// Lower values have higher priority.
    ///
    /// The `unknown` case preserves an unrecognized scope string verbatim
    /// so round-tripping never rewrites a novel scope value (forward-tolerant
    /// decode against a newer server).
    public enum SkillScope: Hashable, Sendable, Codable, Equatable {
        case local
        case repo
        case user
        case server
        case bundled
        case plugin
        case unknown(String)

        public var asString: String {
            switch self {
            case .local: return "local"
            case .repo: return "repo"
            case .user: return "user"
            case .server: return "server"
            case .bundled: return "bundled"
            case .plugin: return "plugin"
            case .unknown(let s): return s
            }
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            let raw = try c.decode(String.self)
            switch raw {
            case "local": self = .local
            case "repo": self = .repo
            case "user": self = .user
            case "server": self = .server
            case "bundled": self = .bundled
            case "plugin": self = .plugin
            default: self = .unknown(raw)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(asString)
        }
    }

    /// A discovered skill as serialized by `workspace.discover_skills`.
    public struct SkillInfo: Hashable, Sendable, Codable, Equatable {
        public var name: String
        public var displayName: String?
        public var description: String
        public var hasUserSpecifiedDescription: Bool
        public var paths: [String]?
        public var whenToUse: String?
        public var shortDescription: String?
        public var author: String?
        public var argumentHint: String?
        public var license: String?
        public var compatibility: String?
        public var metadata: [String: String]?
        public var path: String
        public var scope: SkillScope
        /// Raw JSON: the shape is the tools crate's `ConfigSource` tagged
        /// enum, which RPC clients have no need to interpret structurally.
        public var configSource: JSONValue?
        public var pluginName: String?
        public var pluginVersion: String?
        public var pluginRoot: String?
        public var pluginData: String?
        public var allowedTools: [String]?
        public var model: String?
        public var effort: String?
        public var userInvocable: Bool
        public var disableModelInvocation: Bool
        public var enabled: Bool
        public var body: String?

        public init(
            name: String,
            displayName: String? = nil,
            description: String,
            hasUserSpecifiedDescription: Bool = false,
            paths: [String]? = nil,
            whenToUse: String? = nil,
            shortDescription: String? = nil,
            author: String? = nil,
            argumentHint: String? = nil,
            license: String? = nil,
            compatibility: String? = nil,
            metadata: [String: String]? = nil,
            path: String,
            scope: SkillScope,
            configSource: JSONValue? = nil,
            pluginName: String? = nil,
            pluginVersion: String? = nil,
            pluginRoot: String? = nil,
            pluginData: String? = nil,
            allowedTools: [String]? = nil,
            model: String? = nil,
            effort: String? = nil,
            userInvocable: Bool = true,
            disableModelInvocation: Bool = false,
            enabled: Bool = true,
            body: String? = nil
        ) {
            self.name = name
            self.displayName = displayName
            self.description = description
            self.hasUserSpecifiedDescription = hasUserSpecifiedDescription
            self.paths = paths
            self.whenToUse = whenToUse
            self.shortDescription = shortDescription
            self.author = author
            self.argumentHint = argumentHint
            self.license = license
            self.compatibility = compatibility
            self.metadata = metadata
            self.path = path
            self.scope = scope
            self.configSource = configSource
            self.pluginName = pluginName
            self.pluginVersion = pluginVersion
            self.pluginRoot = pluginRoot
            self.pluginData = pluginData
            self.allowedTools = allowedTools
            self.model = model
            self.effort = effort
            self.userInvocable = userInvocable
            self.disableModelInvocation = disableModelInvocation
            self.enabled = enabled
            self.body = body
        }

        enum CodingKeys: String, CodingKey {
            case name
            case displayName = "display_name"
            case description
            case hasUserSpecifiedDescription = "has_user_specified_description"
            case paths
            case whenToUse = "when_to_use"
            case shortDescription = "short_description"
            case author
            case argumentHint = "argument_hint"
            case license
            case compatibility
            case metadata
            case path
            case scope
            case configSource = "config_source"
            case pluginName = "plugin_name"
            case pluginVersion = "plugin_version"
            case pluginRoot = "plugin_root"
            case pluginData = "plugin_data"
            case allowedTools = "allowed_tools"
            case model
            case effort
            case userInvocable = "user_invocable"
            case disableModelInvocation = "disable_model_invocation"
            case enabled
            case body
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
            description = try c.decode(String.self, forKey: .description)
            hasUserSpecifiedDescription = try c.decodeIfPresent(Bool.self, forKey: .hasUserSpecifiedDescription) ?? false
            paths = try c.decodeIfPresent([String].self, forKey: .paths)
            whenToUse = try c.decodeIfPresent(String.self, forKey: .whenToUse)
            shortDescription = try c.decodeIfPresent(String.self, forKey: .shortDescription)
            author = try c.decodeIfPresent(String.self, forKey: .author)
            argumentHint = try c.decodeIfPresent(String.self, forKey: .argumentHint)
            license = try c.decodeIfPresent(String.self, forKey: .license)
            compatibility = try c.decodeIfPresent(String.self, forKey: .compatibility)
            metadata = try c.decodeIfPresent([String: String].self, forKey: .metadata)
            path = try c.decode(String.self, forKey: .path)
            scope = try c.decode(SkillScope.self, forKey: .scope)
            configSource = try c.decodeIfPresent(JSONValue.self, forKey: .configSource)
            pluginName = try c.decodeIfPresent(String.self, forKey: .pluginName)
            pluginVersion = try c.decodeIfPresent(String.self, forKey: .pluginVersion)
            pluginRoot = try c.decodeIfPresent(String.self, forKey: .pluginRoot)
            pluginData = try c.decodeIfPresent(String.self, forKey: .pluginData)
            allowedTools = try c.decodeIfPresent([String].self, forKey: .allowedTools)
            model = try c.decodeIfPresent(String.self, forKey: .model)
            effort = try c.decodeIfPresent(String.self, forKey: .effort)
            userInvocable = try c.decodeIfPresent(Bool.self, forKey: .userInvocable) ?? true
            disableModelInvocation = try c.decodeIfPresent(Bool.self, forKey: .disableModelInvocation) ?? false
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            body = try c.decodeIfPresent(String.self, forKey: .body)
        }
    }
}

// MARK: - workspace.hook_registry
//
// Ported from `rpc/hooks.rs`. The hook registry is mirrored here as
// wire-shape structs (the upstream `xai_grok_hooks` crate pulls in
// `git2`/`reqwest`/`xai-grok-tools`, too heavy for this lean crate). The
// shapes stay byte-identical to the upstream serde attributes.

/// Request for the loaded hook registry. No parameters.
public struct HookRegistryReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public init() {}

    public static let method: String = "workspace.hook_registry"
    public typealias Response = HookRegistryWire

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { return }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encodeNil()
    }
}

/// Wire mirror of `xai_grok_hooks::discovery::HookRegistry`.
///
/// The upstream type keeps its `hooks` map private; the serde shape is
/// `{ "hooks": { "<event>": [<HookSpec>, …] } }`.
public struct HookRegistryWire: Hashable, Sendable, Codable, Equatable {
    public var hooks: [HookEventNameWire: [HookSpecWire]]

    public init(hooks: [HookEventNameWire: [HookSpecWire]] = [:]) {
        self.hooks = hooks
    }

    enum CodingKeys: String, CodingKey { case hooks }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hooks = try c.decodeIfPresent([HookEventNameWire: [HookSpecWire]].self, forKey: .hooks) ?? [:]
    }
}

/// Wire mirror of `xai_grok_hooks::config::HookSpec`.
///
/// The upstream `matcher` field is `#[serde(skip)]` (compiled regex, never
/// on the wire) and is therefore omitted here; clients recompile it. All
/// other fields keep their snake_case names (the upstream type has no
/// `rename_all`).
public struct HookSpecWire: Hashable, Sendable, Codable, Equatable {
    public var name: String
    public var event: HookEventNameWire
    public var handlerType: String
    public var configuredMatcher: String?
    public var enabled: Bool
    public var command: String?
    public var commandRaw: String?
    public var url: String?
    public var urlRaw: String?
    public var timeoutMs: UInt64
    public var sourceDir: String
    public var extraEnv: [String: String]

    public init(
        name: String,
        event: HookEventNameWire,
        handlerType: String,
        configuredMatcher: String? = nil,
        enabled: Bool,
        command: String? = nil,
        commandRaw: String? = nil,
        url: String? = nil,
        urlRaw: String? = nil,
        timeoutMs: UInt64,
        sourceDir: String,
        extraEnv: [String: String] = [:]
    ) {
        self.name = name
        self.event = event
        self.handlerType = handlerType
        self.configuredMatcher = configuredMatcher
        self.enabled = enabled
        self.command = command
        self.commandRaw = commandRaw
        self.url = url
        self.urlRaw = urlRaw
        self.timeoutMs = timeoutMs
        self.sourceDir = sourceDir
        self.extraEnv = extraEnv
    }

    enum CodingKeys: String, CodingKey {
        case name, event
        case handlerType = "handler_type"
        case configuredMatcher = "configured_matcher"
        case enabled
        case command
        case commandRaw = "command_raw"
        case url
        case urlRaw = "url_raw"
        case timeoutMs = "timeout_ms"
        case sourceDir = "source_dir"
        case extraEnv = "extra_env"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        event = try c.decode(HookEventNameWire.self, forKey: .event)
        handlerType = try c.decode(String.self, forKey: .handlerType)
        configuredMatcher = try c.decodeIfPresent(String.self, forKey: .configuredMatcher)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        commandRaw = try c.decodeIfPresent(String.self, forKey: .commandRaw)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        urlRaw = try c.decodeIfPresent(String.self, forKey: .urlRaw)
        timeoutMs = try c.decode(UInt64.self, forKey: .timeoutMs)
        sourceDir = try c.decode(String.self, forKey: .sourceDir)
        extraEnv = try c.decodeIfPresent([String: String].self, forKey: .extraEnv) ?? [:]
    }
}

/// Wire mirror of `xai_grok_hooks::event::HookEventName`.
///
/// Serializes to snake_case (matching the upstream derive) and is used as
/// a JSON map key in `HookRegistryWire`. An unknown event from a newer
/// server is preserved losslessly in `unknown`: the structured
/// `hook_registry` decode never fails under deploy skew, and distinct
/// unknown events stay distinct map keys.
public enum HookEventNameWire: Hashable, Sendable, Equatable {
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
    case subagentEnd
    case preCompact
    case postCompact
    case unknown(String)

    /// The snake_case wire string (the captured raw value for `unknown`).
    public var asString: String {
        switch self {
        case .sessionStart: return "session_start"
        case .sessionEnd: return "session_end"
        case .stop: return "stop"
        case .stopFailure: return "stop_failure"
        case .preToolUse: return "pre_tool_use"
        case .postToolUse: return "post_tool_use"
        case .postToolUseFailure: return "post_tool_use_failure"
        case .permissionDenied: return "permission_denied"
        case .userPromptSubmit: return "user_prompt_submit"
        case .notification: return "notification"
        case .subagentStart: return "subagent_start"
        case .subagentStop: return "subagent_stop"
        case .subagentEnd: return "subagent_end"
        case .preCompact: return "pre_compact"
        case .postCompact: return "post_compact"
        case .unknown(let s): return s
        }
    }

    public init(_ raw: String) {
        switch raw {
        case "session_start": self = .sessionStart
        case "session_end": self = .sessionEnd
        case "stop": self = .stop
        case "stop_failure": self = .stopFailure
        case "pre_tool_use": self = .preToolUse
        case "post_tool_use": self = .postToolUse
        case "post_tool_use_failure": self = .postToolUseFailure
        case "permission_denied": self = .permissionDenied
        case "user_prompt_submit": self = .userPromptSubmit
        case "notification": self = .notification
        case "subagent_start": self = .subagentStart
        case "subagent_stop": self = .subagentStop
        case "subagent_end": self = .subagentEnd
        case "pre_compact": self = .preCompact
        case "post_compact": self = .postCompact
        default: self = .unknown(raw)
        }
    }
}

extension HookEventNameWire: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self.init(try c.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(asString)
    }
}
