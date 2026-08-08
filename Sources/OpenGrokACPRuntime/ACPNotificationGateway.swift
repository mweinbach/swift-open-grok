// ACPNotificationGateway.swift
//
// The ACP notification gateway — both directions of the fire-and-forget
// surface the request/response router does not carry:
//
//   * Inbound: JSON-RPC notifications whose method is not a core agent
//     method are extension notifications. Upstream routes them to
//     `ext_notification`, which matches known names (`x.ai/yolo_mode_changed`,
//     `x.ai/swarm_mode_changed`, `x.ai/permissions/reset`, ...) and silently
//     ignores everything else — no error, no response
//     (`crates/codegen/xai-grok-shell/src/agent/mvp_agent/acp_agent.rs:
//     4481-4720`). `ACPExtensionNotificationRouter` is the Swift seam for
//     that dispatch; the live composition registers the handlers in
//     `LiveACPNotificationGateway.swift` (OpenGrokCLI).
//
//   * Outbound: `acp::ExtNotification`s the agent broadcasts to the client —
//     `x.ai/session/prompt_complete` at turn end (acp_agent.rs:2952-2986)
//     and `x.ai/session_notification` carrying one xAI `SessionUpdate`
//     (`send_xai_notification_with_extra_meta`,
//     session/acp_session_impl/updates.rs:715-757; `emit_subagent_notification`,
//     agent/subagent/mod.rs:2502-2528). `ACPNotificationGateway` is the
//     handle the composition-side emitters (recap, swarm mode, the subagent
//     mailbox observer) hold; it forwards onto whichever `ACPAgentRuntime`
//     is currently attached, whose notification sink is the live carrier
//     (stdio or ws) — the SAME channel `session/update` already rides.

import Foundation
import OpenGrokACP
import OpenGrokShared

// MARK: - Inbound extension-notification router

/// A handler for one inbound extension notification. Unlike
/// `ACPAgentExtensionHandler` there is no return value and no throw: a
/// JSON-RPC notification has no response channel, and upstream's
/// `ext_notification` returns `Ok(())` on every arm — a malformed payload is
/// ignored, never answered (acp_agent.rs:4486-4491 parses with `if let Ok`).
public protocol ACPAgentExtensionNotificationHandler: Sendable {
    func handle(method: String, params: JSONValue) async
}

/// Exact-name dispatch for inbound extension notifications — the Swift seam
/// for upstream's `ext_notification` name matching (acp_agent.rs:4481-4720).
/// Unmatched names are ignored silently, exactly like upstream's fall-through.
public struct ACPExtensionNotificationRouter: Sendable {
    private let routes: [(method: String, handler: any ACPAgentExtensionNotificationHandler)]

    public init() {
        routes = []
    }

    private init(routes: [(method: String, handler: any ACPAgentExtensionNotificationHandler)]) {
        self.routes = routes
    }

    public func register(
        exact method: String,
        handler: any ACPAgentExtensionNotificationHandler
    ) -> ACPExtensionNotificationRouter {
        ACPExtensionNotificationRouter(routes: routes + [(method, handler)])
    }

    /// Dispatch one notification. Returns whether any handler matched so a
    /// caller can log the ignored case; the return value is deliberately
    /// discardable because upstream treats an unknown name as a no-op.
    @discardableResult
    public func dispatch(method: String, params: JSONValue) async -> Bool {
        var handled = false
        for route in routes where route.method == method {
            await route.handler.handle(method: method, params: params)
            handled = true
        }
        return handled
    }
}

// MARK: - Outbound gateway

/// The composition-side handle for broadcasting extension notifications to
/// the connected ACP client.
///
/// The emitters (recap generation, swarm-mode acks, the subagent mailbox
/// observer) are built BEFORE the runtime exists — the components factory
/// runs first, then the composition constructs the runtime around them — so
/// they hold this gateway and the composition attaches the runtime once it
/// is built (and re-attaches per connection on the serve host, whose runtime
/// factory runs per accept). The reference is weak: the runtime's extension
/// router retains its handlers, the handlers retain this gateway, and a
/// strong runtime reference here would complete a cycle.
public actor ACPNotificationGateway {
    private weak var runtime: ACPAgentRuntime?
    /// Process-global monotonic event counter, the port of `EVENT_COUNTER`
    /// (`xai-grok-shell-base/src/util/event_id.rs:24-27`): one sequence per
    /// process, ids spelled `{sessionId}-{count}`.
    private var eventCounter: UInt64 = 0

    public init() {}

    public func attach(_ runtime: ACPAgentRuntime) {
        self.runtime = runtime
    }

    /// Whether the attached runtime knows `sessionId`. The recap ext method
    /// refuses unknown sessions with upstream's invalid-params error
    /// (extensions/recap.rs:45-49), and the swarm-mode arm only applies to a
    /// session the agent holds (acp_agent.rs:4564-4568).
    public func sessionExists(_ sessionId: AcpSessionId) async -> Bool {
        guard let runtime else { return false }
        return await runtime.sessionExists(sessionId)
    }

    /// Fire-and-forget one extension notification to the connected client —
    /// the port of `GatewaySender::forward_fire_and_forget`. Dropped when no
    /// runtime is attached, which is upstream's behavior for a gateway whose
    /// client went away.
    public func send(method: String, params: JSONValue) async {
        await runtime?.sendExtensionNotification(method: method, params: params)
    }

    /// Broadcast one xAI session update in upstream's wire envelope:
    /// method `x.ai/session_notification`, params the serialized
    /// `SessionNotification { sessionId, update, _meta }`
    /// (extensions/notification.rs:39-50 for the camelCase spelling;
    /// updates.rs:736-748 for the method name), with `_meta` carrying
    /// `eventId` + `agentTimestampMs` (`build_notification_meta`,
    /// updates.rs:400-407).
    public func sendXaiSessionUpdate(sessionID: String, update: JSONValue) async {
        eventCounter += 1
        let params = JSONValue.object([
            "sessionId": .string(sessionID),
            "update": update,
            "_meta": .object([
                "eventId": .string("\(sessionID)-\(eventCounter)"),
                "agentTimestampMs": .number(.int64(Int64(Date().timeIntervalSince1970 * 1000))),
            ]),
        ])
        await send(method: ACPXaiNotificationMethods.sessionNotification, params: params)
    }
}

/// The xAI extension-notification method names this port emits, verbatim from
/// the upstream emit sites.
public enum ACPXaiNotificationMethods {
    /// `acp::ExtNotification::new("x.ai/session_notification", ...)` —
    /// updates.rs:736-748 and agent/subagent/mod.rs:2523-2527.
    public static let sessionNotification = "x.ai/session_notification"
    /// `acp::ExtNotification::new("x.ai/session/prompt_complete", ...)` —
    /// acp_agent.rs:2978-2986.
    public static let promptComplete = "x.ai/session/prompt_complete"
}
