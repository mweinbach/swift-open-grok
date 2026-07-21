// Methods.swift
//
// Open Grok — Swift port of `xai-tool-protocol/src/methods.rs`.
//
// Closed enumeration of every JSON-RPC method on the wire. Each variant
// is defined with its wire string; the enum provides `asWireStr` and
// `fromWireStr` from that single source of truth.

import Foundation

/// Message prefix the hub uses when rejecting a request whose `method`
/// string does not parse into `Method`. Pinned here so terminal binaries
/// built while the SDK still keyed old-hub detection on this exact prefix
/// remain in the fleet. Do not change casually.
public let unknownMethodMsgPrefix = "unknown method `"

/// Every JSON-RPC method understood by the computer hub.
///
/// Mirrors Rust `xai_tool_protocol::methods::Method`. Wire form is a
/// bare string (e.g. `"tool.call"`).
public enum Method: String, Codable, Sendable, Hashable, CaseIterable {
    // harness → service
    case sessionOpen = "session_open"
    case sessionClose = "session_close"
    case sessionBindServer = "session_bind_server"
    case sessionUnbindServer = "session_unbind_server"
    case sessionAttachServer = "session_attach_server"
    case toolsList = "tools.list"
    case toolsSearch = "tools.search"
    case toolCall = "tool.call"
    case toolCancel = "tool.cancel"
    case toolNotify = "tool.notify"
    case systemNotify = "system.notify"
    case subscribeNotifications = "subscribe_notifications"
    case unsubscribeNotifications = "unsubscribe_notifications"
    case hook = "hook"
    case hello = "hello"
    case helloAck = "hello_ack"
    case ping = "ping"
    case pong = "pong"

    // tool_server → service
    case toolCallProgress = "tool_call_progress"
    case toolNotification = "tool.notification"
    case hookReply = "hook_reply"
    case tracesDonate = "traces.donate"
    case logsDonate = "logs.donate"
    case metricsDonate = "metrics.donate"

    // service → tool_server
    case toolCallRequest = "tool_call_request"

    // service → harness
    case toolsChanged = "tools_changed"
    case subscribeAck = "subscribe_ack"
    case unsubscribeAck = "unsubscribe_ack"

    // harness → service (server discovery)
    case serversList = "servers.list"

    // tool_server status lifecycle
    case toolServerStatus = "tool_server.status"
    case toolServerGetStatus = "tool_server.get_status"
    case toolServerEvict = "tool_server.evict"

    // session lifecycle
    case serve = "serve"
    case sessionBind = "session.bind"
    case sessionUnbind = "session.unbind"

    /// Wire string for this method. Equals `rawValue`.
    public var wireString: String { rawValue }

    /// Inverse of `wireString`. Returns `nil` for strings that don't match
    /// any known method.
    public static func fromWireStr(_ s: String) -> Method? {
        Method(rawValue: s)
    }
}
