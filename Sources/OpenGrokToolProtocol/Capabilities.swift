// Capabilities.swift
//
// Open Grok — Swift port of `xai-tool-protocol/src/capabilities.rs` and
// `xai-tool-protocol/src/connection.rs`.
//
// Per-tool capabilities, notification schemas, streaming specs, hook
// kinds, tool scopes, connection kinds, and tool-definition modes.

import Foundation

/// Lifecycle hook a tool may opt in to receive.
///
/// Mirrors Rust `HookKind`. Wire form is snake_case.
public enum HookKind: String, Codable, Sendable, Hashable, CaseIterable {
    case onSessionOpen = "on_session_open"
    case onSessionClose = "on_session_close"
    case onToolCallStart = "on_tool_call_start"
    case onToolCallResult = "on_tool_call_result"
    case onCancel = "on_cancel"
    case onNotification = "on_notification"
}

/// Multi-agent write-coordination scope.
///
/// Mirrors Rust `ToolScope`. Wire form is snake_case.
public enum ToolScope: String, Codable, Sendable, Hashable {
    case read
    case write
}

/// How a tool streams partial results. Declared once in
/// `ToolCapabilities.streaming` and consumed at the source to stamp a
/// self-describing progress envelope.
///
/// Mirrors Rust `StreamingSpec`.
public struct StreamingSpec: Codable, Sendable, Hashable {
    /// Stable snake_case discriminator the tool stamps on its
    /// `ToolProgress::Custom.subkind`.
    public var subkind: String

    /// Per-frame `delta` byte cap (UTF-8-safe). Unset falls back to the
    /// runtime's 16 KiB default.
    public var maxDeltaBytes: UInt32?

    private enum CodingKeys: String, CodingKey {
        case subkind
        case maxDeltaBytes = "max_delta_bytes"
    }

    public init(subkind: String, maxDeltaBytes: UInt32? = nil) {
        self.subkind = subkind
        self.maxDeltaBytes = maxDeltaBytes
    }
}

/// Per-tool wire-traveling capabilities. Defaults conservatively (no
/// progress, no cancel, single concurrency, no hooks).
///
/// Mirrors Rust `ToolCapabilities`.
public struct ToolCapabilities: Codable, Sendable, Hashable {
    public var streaming: StreamingSpec?
    public var supportsCancel: Bool
    public var maxConcurrency: UInt32?
    public var isReadOnly: Bool
    public var hooks: [HookKind]
    public var behaviorVersion: String?
    public var maxFrameBytes: UInt32?
    public var timeoutMs: UInt64?
    public var toolScope: ToolScope?

    private enum CodingKeys: String, CodingKey {
        case streaming
        case supportsCancel = "supports_cancel"
        case maxConcurrency = "max_concurrency"
        case isReadOnly = "is_read_only"
        case hooks
        case behaviorVersion = "behavior_version"
        case maxFrameBytes = "max_frame_bytes"
        case timeoutMs = "timeout_ms"
        case toolScope = "tool_scope"
    }

    public init(
        streaming: StreamingSpec? = nil,
        supportsCancel: Bool = false,
        maxConcurrency: UInt32? = nil,
        isReadOnly: Bool = false,
        hooks: [HookKind] = [],
        behaviorVersion: String? = nil,
        maxFrameBytes: UInt32? = nil,
        timeoutMs: UInt64? = nil,
        toolScope: ToolScope? = nil
    ) {
        self.streaming = streaming
        self.supportsCancel = supportsCancel
        self.maxConcurrency = maxConcurrency
        self.isReadOnly = isReadOnly
        self.hooks = hooks
        self.behaviorVersion = behaviorVersion
        self.maxFrameBytes = maxFrameBytes
        self.timeoutMs = timeoutMs
        self.toolScope = toolScope
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.streaming = try c.decodeIfPresent(StreamingSpec.self, forKey: .streaming)
        self.supportsCancel = try c.decodeIfPresent(Bool.self, forKey: .supportsCancel) ?? false
        self.maxConcurrency = try c.decodeIfPresent(UInt32.self, forKey: .maxConcurrency)
        self.isReadOnly = try c.decodeIfPresent(Bool.self, forKey: .isReadOnly) ?? false
        self.hooks = try c.decodeIfPresent([HookKind].self, forKey: .hooks) ?? []
        self.behaviorVersion = try c.decodeIfPresent(String.self, forKey: .behaviorVersion)
        self.maxFrameBytes = try c.decodeIfPresent(UInt32.self, forKey: .maxFrameBytes)
        self.timeoutMs = try c.decodeIfPresent(UInt64.self, forKey: .timeoutMs)
        self.toolScope = try c.decodeIfPresent(ToolScope.self, forKey: .toolScope)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(streaming, forKey: .streaming)
        try c.encode(supportsCancel, forKey: .supportsCancel)
        try c.encodeIfPresent(maxConcurrency, forKey: .maxConcurrency)
        try c.encode(isReadOnly, forKey: .isReadOnly)
        if !hooks.isEmpty { try c.encode(hooks, forKey: .hooks) }
        try c.encodeIfPresent(behaviorVersion, forKey: .behaviorVersion)
        try c.encodeIfPresent(maxFrameBytes, forKey: .maxFrameBytes)
        try c.encodeIfPresent(timeoutMs, forKey: .timeoutMs)
        try c.encodeIfPresent(toolScope, forKey: .toolScope)
    }
}

/// Per-tool notification schemas. Keys are the notification `kind`
/// strings the computer hub validates against.
///
/// Mirrors Rust `NotificationSchemas`.
public struct NotificationSchemas: Codable, Sendable, Hashable {
    public var outbound: [String: JSONValue]
    public var inbound: [String: JSONValue]

    public init(outbound: [String: JSONValue] = [:], inbound: [String: JSONValue] = [:]) {
        self.outbound = outbound
        self.inbound = inbound
    }

    private enum CodingKeys: String, CodingKey {
        case outbound
        case inbound
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.outbound = try c.decodeIfPresent([String: JSONValue].self, forKey: .outbound) ?? [:]
        self.inbound = try c.decodeIfPresent([String: JSONValue].self, forKey: .inbound) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if !outbound.isEmpty { try c.encode(outbound, forKey: .outbound) }
        if !inbound.isEmpty { try c.encode(inbound, forKey: .inbound) }
    }
}

// MARK: - Connection

/// Role of a WebSocket connection. The computer hub uses this to decide
/// which methods are valid on a given socket.
///
/// Mirrors Rust `ConnectionKind`. Wire form is snake_case.
public enum ConnectionKind: String, Codable, Sendable, Hashable {
    case harness
    case toolServer = "tool_server"
}

/// How the computer hub exposes the registered tool set to the model.
///
/// `Full` carries every `ToolDescription` directly; `Concise` carries
/// only a configurable meta-tool pair so callers can choose the
/// model-facing names of the search/invoke meta-tools per session.
///
/// Wire form is adjacently tagged on `mode`: `Full` serialises as
/// `{"mode": "full"}` and `Concise` as
/// `{"mode": "concise", "meta_search": "...", "meta_call": "..."}`.
///
/// Mirrors Rust `ToolDefinitionMode`.
public enum ToolDefinitionMode: Codable, Sendable, Hashable {
    case full
    case concise(metaSearch: ToolId, metaCall: ToolId)

    private enum CodingKeys: String, CodingKey {
        case mode
        case metaSearch = "meta_search"
        case metaCall = "meta_call"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try c.decode(String.self, forKey: .mode)
        switch mode {
        case "full":
            self = .full
        case "concise":
            let metaSearch = try c.decode(ToolId.self, forKey: .metaSearch)
            let metaCall = try c.decode(ToolId.self, forKey: .metaCall)
            self = .concise(metaSearch: metaSearch, metaCall: metaCall)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .mode, in: c,
                debugDescription: "unknown ToolDefinitionMode: \(mode)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .full:
            try c.encode("full", forKey: .mode)
        case .concise(let metaSearch, let metaCall):
            try c.encode("concise", forKey: .mode)
            try c.encode(metaSearch, forKey: .metaSearch)
            try c.encode(metaCall, forKey: .metaCall)
        }
    }
}
