// McpClientState.swift
//
// Client state kinds, liveness classifications, client events, and server status payloads
// for MCP server supervision and auto-restart.
// Ported from `crates/codegen/xai-grok-mcp/src/servers.rs` and
// `crates/codegen/xai-grok-shell/src/session/mcp_dispatcher.rs`.

import Foundation
import OpenGrokShared
import OpenGrokToolTypes

/// Projection of client lifecycle state used for cheap state-machine inspection.
/// Mirrors upstream Rust `ClientStateKind` 1:1.
public enum ClientStateKind: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    /// A previous handshake exhausted attempts; recovery is via explicit Refresh button, not auto-restart.
    case empty
    /// Transport is configured or reset; awaiting initial handshake.
    case pending
    /// Per-server handshake is in flight or restart is being debounced.
    case initializing
    /// Handshake completed; transport is healthy.
    case ready
}

public typealias McpClientStateKind = ClientStateKind

/// Liveness classification returned by transport liveness checks.
/// Mirrors upstream Rust `LivenessCheck` 1:1.
public enum McpLivenessCheck: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    /// Client is in `ready` state and transport is healthy.
    case healthy
    /// Client was in `ready` state and transport closed.
    case transportClosed = "transport_closed"
    /// Transient state (initializing, pending, or empty); liveness watcher exits silently.
    case transient
}

/// Discriminator for MCP client events emitted to the session-side dispatcher.
/// Distinct from `McpClientEvent` to support hashing and coalescing keys.
/// Mirrors upstream Rust `McpClientEventKind` 1:1.
public enum McpClientEventKind: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case transportClosed = "transport_closed"
    case handshakeFailed = "handshake_failed"
    case toolsChanged = "tools_changed"
    case resourcesChanged = "resources_changed"
    case ready = "ready"
    case configAdded = "config_added"
    case configRemoved = "config_removed"
    case configDiff = "config_diff"

    /// Whether this event kind indicates a dead transport that may trigger auto-restart.
    public var isRestartTrigger: Bool {
        self == .transportClosed || self == .handshakeFailed
    }
}

/// Events emitted by a live MCP client to its session-side dispatcher.
/// Mirrors upstream Rust `McpClientEvent` 1:1.
public enum McpClientEvent: Sendable, Equatable {
    /// Transport closed unexpectedly.
    case transportClosed(server: String, clientId: UInt64)
    /// Handshake failed with a stringified error.
    case handshakeFailed(server: String, reason: String)
    /// Server pushed `notifications/tools/list_changed`.
    case toolsChanged(server: String)
    /// Server pushed `notifications/resources/list_changed`.
    case resourcesChanged(server: String)
    /// Client transitioned to `ready` state.
    case ready(server: String)
    /// Server configuration was added.
    case configAdded(server: String)
    /// Server configuration was removed.
    case configRemoved(server: String)
    /// Managed/local config diff resolved.
    case configDiff(added: [String], removed: [String], modified: [String])

    /// Server name associated with the event, if applicable.
    public var serverName: String? {
        switch self {
        case .transportClosed(let server, _),
             .handshakeFailed(let server, _),
             .toolsChanged(let server),
             .resourcesChanged(let server),
             .ready(let server),
             .configAdded(let server),
             .configRemoved(let server):
            return server
        case .configDiff:
            return nil
        }
    }

    /// Event kind discriminator.
    public var kind: McpClientEventKind {
        switch self {
        case .transportClosed: return .transportClosed
        case .handshakeFailed: return .handshakeFailed
        case .toolsChanged: return .toolsChanged
        case .resourcesChanged: return .resourcesChanged
        case .ready: return .ready
        case .configAdded: return .configAdded
        case .configRemoved: return .configRemoved
        case .configDiff: return .configDiff
        }
    }
}

/// Status enum surfaced over ACP `x.ai/mcp/server_status`.
/// Mirrors upstream Rust `McpServerStatus` 1:1.
public enum McpServerStatus: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    /// Client is in `ready` state and transport is healthy.
    case ready
    /// Handshake is in flight or restart is being debounced.
    case initializing
    /// Transport closed, handshake failed, or server is disabled/unconfigured.
    case unavailable
    /// OAuth required but not yet acquired.
    case needsAuth = "needs_auth"
}

/// Reason a status delta was emitted.
/// Mirrors upstream Rust `McpServerStatusReason` 1:1 with snake_case wire encoding.
public enum McpServerStatusReason: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case transportClosed = "transport_closed"
    case handshakeFailed = "handshake_failed"
    case configAdded = "config_added"
    case configRemoved = "config_removed"
    case configChanged = "config_changed"
    case disabled = "disabled"
    case authExpired = "auth_expired"
    /// First-time successful handshake (new server transitioned to ready).
    case initialized = "initialized"
    /// A watcher fired transport closed, auto-restart ran, and re-handshake succeeded.
    case restartSucceeded = "restart_succeeded"
    /// Auto-restart attempt or final exhausted run failed.
    case restartFailed = "restart_failed"
    /// Auto-restart backoff loop is actively sleeping/restarting.
    case restarting = "restarting"
    /// Server is unavailable.
    case unavailable = "unavailable"
    /// Managed gateway token refreshed.
    case managedTokenRefreshed = "managed_token_refreshed"
}

/// Classification of server origin (managed gateway vs local config).
/// Mirrors upstream Rust `McpServerSource` 1:1.
public enum McpServerSource: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case local
    case managed

    public static let managedGatewayPrefix = "managed_gateway:"

    public static func classify(name: String) -> McpServerSource {
        if name.hasPrefix(managedGatewayPrefix) {
            return .managed
        }
        return .local
    }
}

/// Wire payload pushed over ACP `x.ai/mcp/server_status`.
/// Mirrors upstream Rust `McpServerStatusPayload` 1:1 with camelCase coding keys.
public struct McpServerStatusPayload: Sendable, Codable, Equatable {
    public var sessionId: String
    public var name: String
    public var source: McpServerSource
    public var status: McpServerStatus
    public var reason: McpServerStatusReason
    public var detail: String?
    public var tools: JSONValue?

    public init(
        sessionId: String,
        name: String,
        source: McpServerSource = .local,
        status: McpServerStatus,
        reason: McpServerStatusReason,
        detail: String? = nil,
        tools: JSONValue? = nil
    ) {
        self.sessionId = sessionId
        self.name = name
        self.source = source
        self.status = status
        self.reason = reason
        self.detail = detail
        self.tools = tools
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId
        case name
        case source
        case status
        case reason
        case detail
        case tools
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        name = try container.decode(String.self, forKey: .name)
        source = try container.decodeIfPresent(McpServerSource.self, forKey: .source) ?? .local
        status = try container.decode(McpServerStatus.self, forKey: .status)
        reason = try container.decode(McpServerStatusReason.self, forKey: .reason)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        tools = try container.decodeIfPresent(JSONValue.self, forKey: .tools)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(name, forKey: .name)
        try container.encode(source, forKey: .source)
        try container.encode(status, forKey: .status)
        try container.encode(reason, forKey: .reason)
        try container.encodeIfPresent(detail, forKey: .detail)
        try container.encodeIfPresent(tools, forKey: .tools)
    }
}
