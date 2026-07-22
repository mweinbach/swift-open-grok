// Frames.swift
//
// Open Grok — Swift port of `xai-tool-protocol/src/frames.rs`.
//
// Per-method `params` and `result` payload structs for the computer hub wire.

import Foundation
import OpenGrokShared
import OpenGrokToolTypes

// MARK: - Donation / size caps

/// Hub rejects oversized batches wholesale; donors chunk before encoding.
public let maxSpansPerDonation: Int = 512
public let maxDonationBytes: Int = 1024 * 1024
public let maxLogRecordsPerDonation: Int = 512
public let maxMetricsPerDonation: Int = 512
public let maxSystemNotifyPayloadBytes: Int = 256 * 1024

// MARK: - Tool call

/// `tool.call` / `tool_call_request` params.
public struct ToolCallParams: Codable, Sendable, Hashable {
    public var toolCallId: ToolCallId
    public var toolId: ToolId
    public var arguments: JSONValue
    public var deadlineMs: UInt64?
    public var behaviorVersion: String?
    public var cwd: String?
    public var traceContext: String?

    private enum CodingKeys: String, CodingKey {
        case toolCallId = "tool_call_id"
        case toolId = "tool_id"
        case arguments
        case deadlineMs = "deadline_ms"
        case behaviorVersion = "behavior_version"
        case cwd
        case traceContext = "trace_context"
    }

    public init(
        toolCallId: ToolCallId,
        toolId: ToolId,
        arguments: JSONValue,
        deadlineMs: UInt64? = nil,
        behaviorVersion: String? = nil,
        cwd: String? = nil,
        traceContext: String? = nil
    ) {
        self.toolCallId = toolCallId
        self.toolId = toolId
        self.arguments = arguments
        self.deadlineMs = deadlineMs
        self.behaviorVersion = behaviorVersion
        self.cwd = cwd
        self.traceContext = traceContext
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(toolCallId, forKey: .toolCallId)
        try c.encode(toolId, forKey: .toolId)
        try c.encode(arguments, forKey: .arguments)
        try c.encodeIfPresent(deadlineMs, forKey: .deadlineMs)
        try c.encodeIfPresent(behaviorVersion, forKey: .behaviorVersion)
        try c.encodeIfPresent(cwd, forKey: .cwd)
        try c.encodeIfPresent(traceContext, forKey: .traceContext)
    }
}

/// Body of a successful tool call response.
public struct ToolCallResult: Codable, Sendable, Hashable {
    public var toolCallId: ToolCallId
    public var output: ToolOutputWire
    public var followUps: [JSONValue]
    public var reminders: [JSONValue]
    public var chatCompletionOutput: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case toolCallId = "tool_call_id"
        case output
        case followUps = "follow_ups"
        case reminders
        case chatCompletionOutput = "chat_completion_output"
    }

    public init(
        toolCallId: ToolCallId,
        output: ToolOutputWire,
        followUps: [JSONValue] = [],
        reminders: [JSONValue] = [],
        chatCompletionOutput: JSONValue? = nil
    ) {
        self.toolCallId = toolCallId
        self.output = output
        self.followUps = followUps
        self.reminders = reminders
        self.chatCompletionOutput = chatCompletionOutput
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.toolCallId = try c.decode(ToolCallId.self, forKey: .toolCallId)
        self.output = try c.decode(ToolOutputWire.self, forKey: .output)
        self.followUps = try c.decodeIfPresent([JSONValue].self, forKey: .followUps) ?? []
        self.reminders = try c.decodeIfPresent([JSONValue].self, forKey: .reminders) ?? []
        self.chatCompletionOutput = try c.decodeIfPresent(JSONValue.self, forKey: .chatCompletionOutput)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(toolCallId, forKey: .toolCallId)
        try c.encode(output, forKey: .output)
        if !followUps.isEmpty { try c.encode(followUps, forKey: .followUps) }
        if !reminders.isEmpty { try c.encode(reminders, forKey: .reminders) }
        try c.encodeIfPresent(chatCompletionOutput, forKey: .chatCompletionOutput)
    }
}

public struct TracesDonateParams: Codable, Sendable, Hashable {
    public var otlpRequest: String
    private enum CodingKeys: String, CodingKey { case otlpRequest = "otlp_request" }
    public init(otlpRequest: String) { self.otlpRequest = otlpRequest }
}

public struct LogsDonateParams: Codable, Sendable, Hashable {
    public var otlpRequest: String
    private enum CodingKeys: String, CodingKey { case otlpRequest = "otlp_request" }
    public init(otlpRequest: String) { self.otlpRequest = otlpRequest }
}

public struct MetricsDonateParams: Codable, Sendable, Hashable {
    public var otlpRequest: String
    private enum CodingKeys: String, CodingKey { case otlpRequest = "otlp_request" }
    public init(otlpRequest: String) { self.otlpRequest = otlpRequest }
}

public struct ToolCallProgressFrame: Codable, Sendable, Hashable {
    public var toolCallId: ToolCallId
    public var kind: String
    public var body: JSONValue
    public var droppedCount: UInt32?

    private enum CodingKeys: String, CodingKey {
        case toolCallId = "tool_call_id"
        case kind, body
        case droppedCount = "dropped_count"
    }

    public init(toolCallId: ToolCallId, kind: String, body: JSONValue, droppedCount: UInt32? = nil) {
        self.toolCallId = toolCallId
        self.kind = kind
        self.body = body
        self.droppedCount = droppedCount
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(toolCallId, forKey: .toolCallId)
        try c.encode(kind, forKey: .kind)
        try c.encode(body, forKey: .body)
        try c.encodeIfPresent(droppedCount, forKey: .droppedCount)
    }
}

public struct ToolNotificationFrame: Codable, Sendable, Hashable {
    public var toolCallId: ToolCallId?
    public var toolId: ToolId?
    public var notification: WireToolNotification

    private enum CodingKeys: String, CodingKey {
        case toolCallId = "tool_call_id"
        case toolId = "tool_id"
        case notification
    }

    public init(toolCallId: ToolCallId? = nil, toolId: ToolId? = nil, notification: WireToolNotification) {
        self.toolCallId = toolCallId
        self.toolId = toolId
        self.notification = notification
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(toolCallId, forKey: .toolCallId)
        try c.encodeIfPresent(toolId, forKey: .toolId)
        try c.encode(notification, forKey: .notification)
    }

    public static func custom(toolId: ToolId, kind: String, payload: JSONValue) -> ToolNotificationFrame {
        ToolNotificationFrame(
            toolId: toolId,
            notification: .custom(WireCustomNotification(kind: kind, payload: payload))
        )
    }

    public static func known(toolId: ToolId, notification: some Encodable) throws -> ToolNotificationFrame {
        let value = try JSONValue.encode(notification)
        return ToolNotificationFrame(toolId: toolId, notification: .known(value))
    }
}

public struct SystemNotifyParams: Codable, Sendable, Hashable {
    public var payload: JSONValue
    public var conversationIdOverride: String?
    public var echoToSubscribers: Bool
    public var requestId: String?

    private enum CodingKeys: String, CodingKey {
        case payload
        case conversationIdOverride = "conversation_id_override"
        case echoToSubscribers = "echo_to_subscribers"
        case requestId = "request_id"
    }

    public init(
        payload: JSONValue,
        conversationIdOverride: String? = nil,
        echoToSubscribers: Bool = false,
        requestId: String? = nil
    ) {
        self.payload = payload
        self.conversationIdOverride = conversationIdOverride
        self.echoToSubscribers = echoToSubscribers
        self.requestId = requestId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.payload = try c.decode(JSONValue.self, forKey: .payload)
        self.conversationIdOverride = try c.decodeIfPresent(String.self, forKey: .conversationIdOverride)
        self.echoToSubscribers = try c.decodeIfPresent(Bool.self, forKey: .echoToSubscribers) ?? false
        self.requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(payload, forKey: .payload)
        try c.encodeIfPresent(conversationIdOverride, forKey: .conversationIdOverride)
        try c.encode(echoToSubscribers, forKey: .echoToSubscribers)
        try c.encodeIfPresent(requestId, forKey: .requestId)
    }
}

// MARK: - List / search

public struct ToolsListParams: Codable, Sendable, Hashable {
    public var sessionId: SessionId
    public var mode: ToolDefinitionMode
    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case mode
    }
    public init(sessionId: SessionId, mode: ToolDefinitionMode) {
        self.sessionId = sessionId
        self.mode = mode
    }
}

public struct ToolsListResult: Codable, Sendable, Hashable {
    public var tools: [ToolDescription]
    public init(tools: [ToolDescription]) { self.tools = tools }
}

public struct ToolsSearchParams: Codable, Sendable, Hashable {
    public var sessionId: SessionId
    public var query: String
    public var limit: Int
    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case query, limit
    }
    public init(sessionId: SessionId, query: String, limit: Int) {
        self.sessionId = sessionId
        self.query = query
        self.limit = limit
    }
}

public struct ProtocolToolSearchResult: Codable, Sendable, Hashable {
    public var toolName: String
    public var serverName: String
    public var description: String
    public var score: Float
    public var parameters: [String]
    public var inputSchema: JSONValue

    private enum CodingKeys: String, CodingKey {
        case toolName = "tool_name"
        case serverName = "server_name"
        case description, score, parameters
        case inputSchema = "input_schema"
    }

    public init(
        toolName: String,
        serverName: String,
        description: String,
        score: Float,
        parameters: [String],
        inputSchema: JSONValue
    ) {
        self.toolName = toolName
        self.serverName = serverName
        self.description = description
        self.score = score
        self.parameters = parameters
        self.inputSchema = inputSchema
    }
}

public struct ToolsSearchResultBody: Codable, Sendable, Hashable {
    public var results: [ProtocolToolSearchResult]
    public var totalHiddenTools: Int
    public var isReady: Bool
    private enum CodingKeys: String, CodingKey {
        case results
        case totalHiddenTools = "total_hidden_tools"
        case isReady = "is_ready"
    }
    public init(results: [ProtocolToolSearchResult], totalHiddenTools: Int, isReady: Bool) {
        self.results = results
        self.totalHiddenTools = totalHiddenTools
        self.isReady = isReady
    }
}

// MARK: - Session lifecycle

public struct LastSeq: Codable, Sendable, Hashable {
    public var connectionId: ConnectionId
    public var seq: FrameSeq
    private enum CodingKeys: String, CodingKey {
        case connectionId = "connection_id"
        case seq
    }
    public init(connectionId: ConnectionId, seq: FrameSeq) {
        self.connectionId = connectionId
        self.seq = seq
    }
}

public struct SessionOpenParams: Codable, Sendable, Hashable {
    public var resume: Bool
    public var lastSeq: LastSeq?
    private enum CodingKeys: String, CodingKey {
        case resume
        case lastSeq = "last_seq"
    }
    public init(resume: Bool = false, lastSeq: LastSeq? = nil) {
        self.resume = resume
        self.lastSeq = lastSeq
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.resume = try c.decodeIfPresent(Bool.self, forKey: .resume) ?? false
        self.lastSeq = try c.decodeIfPresent(LastSeq.self, forKey: .lastSeq)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(resume, forKey: .resume)
        try c.encodeIfPresent(lastSeq, forKey: .lastSeq)
    }
}

public struct SessionCloseParams: Codable, Sendable, Hashable {
    public var reason: String?
    public init(reason: String? = nil) { self.reason = reason }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(reason, forKey: .reason)
    }
    private enum CodingKeys: String, CodingKey { case reason }
}

public struct SessionOpenResult: Codable, Sendable, Hashable {
    public init() {}
}

public struct SessionBindServerParams: Codable, Sendable, Hashable {
    public var serverId: ServerId
    public var cwd: String?
    public var metadata: JSONValue?
    private enum CodingKeys: String, CodingKey {
        case serverId = "server_id"
        case cwd, metadata
    }
    public init(serverId: ServerId, cwd: String? = nil, metadata: JSONValue? = nil) {
        self.serverId = serverId
        self.cwd = cwd
        self.metadata = metadata
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(serverId, forKey: .serverId)
        try c.encodeIfPresent(cwd, forKey: .cwd)
        try c.encodeIfPresent(metadata, forKey: .metadata)
    }
}

public struct SessionBindServerResult: Codable, Sendable, Hashable {
    public var tools: [ToolDescription]
    public var binaryVersion: String?
    public var unservedToolIds: [String]
    public var resolveError: String?
    private enum CodingKeys: String, CodingKey {
        case tools
        case binaryVersion = "binary_version"
        case unservedToolIds = "unserved_tool_ids"
        case resolveError = "resolve_error"
    }
    public init(
        tools: [ToolDescription] = [],
        binaryVersion: String? = nil,
        unservedToolIds: [String] = [],
        resolveError: String? = nil
    ) {
        self.tools = tools
        self.binaryVersion = binaryVersion
        self.unservedToolIds = unservedToolIds
        self.resolveError = resolveError
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.tools = try c.decodeIfPresent([ToolDescription].self, forKey: .tools) ?? []
        self.binaryVersion = try c.decodeIfPresent(String.self, forKey: .binaryVersion)
        self.unservedToolIds = try c.decodeIfPresent([String].self, forKey: .unservedToolIds) ?? []
        self.resolveError = try c.decodeIfPresent(String.self, forKey: .resolveError)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if !tools.isEmpty { try c.encode(tools, forKey: .tools) }
        try c.encodeIfPresent(binaryVersion, forKey: .binaryVersion)
        if !unservedToolIds.isEmpty { try c.encode(unservedToolIds, forKey: .unservedToolIds) }
        try c.encodeIfPresent(resolveError, forKey: .resolveError)
    }
}

public struct SessionUnbindServerParams: Codable, Sendable, Hashable {
    public var serverId: ServerId
    private enum CodingKeys: String, CodingKey { case serverId = "server_id" }
    public init(serverId: ServerId) { self.serverId = serverId }
}

public struct SessionAttachServerParams: Codable, Sendable, Hashable {
    public var serverId: ServerId?
    public var caller: String?
    private enum CodingKeys: String, CodingKey {
        case serverId = "server_id"
        case caller
    }
    public init(serverId: ServerId? = nil, caller: String? = nil) {
        self.serverId = serverId
        self.caller = caller
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(serverId, forKey: .serverId)
        try c.encodeIfPresent(caller, forKey: .caller)
    }
}

public enum AttachRoute: String, Codable, Sendable, Hashable {
    case local, remote, unknown
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = AttachRoute(rawValue: raw) ?? .unknown
    }
}

public struct SessionAttachServerResult: Codable, Sendable, Hashable {
    public var tools: [ToolDescription]
    public var route: AttachRoute?
    private enum CodingKeys: String, CodingKey { case tools, route }
    public init(tools: [ToolDescription] = [], route: AttachRoute? = nil) {
        self.tools = tools
        self.route = route
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.tools = try c.decodeIfPresent([ToolDescription].self, forKey: .tools) ?? []
        self.route = try c.decodeIfPresent(AttachRoute.self, forKey: .route)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if !tools.isEmpty { try c.encode(tools, forKey: .tools) }
        try c.encodeIfPresent(route, forKey: .route)
    }
}

// MARK: - Serve / bind

public struct ServeParams: Codable, Sendable, Hashable {
    public var tools: [ToolDescriptionWithSchema]
    public init(tools: [ToolDescriptionWithSchema]) { self.tools = tools }
}

public struct ServeResult: Codable, Sendable, Hashable {
    public var accepted: Int
    public var added: [ToolId]
    public var removed: [ToolId]
    public init(accepted: Int = 0, added: [ToolId] = [], removed: [ToolId] = []) {
        self.accepted = accepted
        self.added = added
        self.removed = removed
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.accepted = try c.decodeIfPresent(Int.self, forKey: .accepted) ?? 0
        self.added = try c.decodeIfPresent([ToolId].self, forKey: .added) ?? []
        self.removed = try c.decodeIfPresent([ToolId].self, forKey: .removed) ?? []
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accepted, forKey: .accepted)
        if !added.isEmpty { try c.encode(added, forKey: .added) }
        if !removed.isEmpty { try c.encode(removed, forKey: .removed) }
    }
    private enum CodingKeys: String, CodingKey { case accepted, added, removed }
}

public struct SessionBindParams: Codable, Sendable, Hashable {
    public init() {}
}

public struct SessionBindResult: Codable, Sendable, Hashable {
    public var tools: [ToolDescription]
    public var binaryVersion: String?
    public var unservedToolIds: [String]
    public var resolveError: String?
    private enum CodingKeys: String, CodingKey {
        case tools
        case binaryVersion = "binary_version"
        case unservedToolIds = "unserved_tool_ids"
        case resolveError = "resolve_error"
    }
    public init(
        tools: [ToolDescription] = [],
        binaryVersion: String? = nil,
        unservedToolIds: [String] = [],
        resolveError: String? = nil
    ) {
        self.tools = tools
        self.binaryVersion = binaryVersion
        self.unservedToolIds = unservedToolIds
        self.resolveError = resolveError
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.tools = try c.decodeIfPresent([ToolDescription].self, forKey: .tools) ?? []
        self.binaryVersion = try c.decodeIfPresent(String.self, forKey: .binaryVersion)
        self.unservedToolIds = try c.decodeIfPresent([String].self, forKey: .unservedToolIds) ?? []
        self.resolveError = try c.decodeIfPresent(String.self, forKey: .resolveError)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tools, forKey: .tools)
        try c.encodeIfPresent(binaryVersion, forKey: .binaryVersion)
        if !unservedToolIds.isEmpty { try c.encode(unservedToolIds, forKey: .unservedToolIds) }
        try c.encodeIfPresent(resolveError, forKey: .resolveError)
    }
}

public struct SessionUnbindParams: Codable, Sendable, Hashable {
    public init() {}
}

// MARK: - Subscriptions

public struct NotificationFilter: Codable, Sendable, Hashable {
    public var toolId: ToolId?
    public var kinds: [String]?
    private enum CodingKeys: String, CodingKey {
        case toolId = "tool_id"
        case kinds
    }
    public init(toolId: ToolId? = nil, kinds: [String]? = nil) {
        self.toolId = toolId
        self.kinds = kinds
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(toolId, forKey: .toolId)
        try c.encodeIfPresent(kinds, forKey: .kinds)
    }
}

public struct SubscribeNotificationsParams: Codable, Sendable, Hashable {
    public var sessionId: SessionId
    public var filter: NotificationFilter?
    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case filter
    }
    public init(sessionId: SessionId, filter: NotificationFilter? = nil) {
        self.sessionId = sessionId
        self.filter = filter
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encodeIfPresent(filter, forKey: .filter)
    }
}

public enum SubscribeOutcome: String, Codable, Sendable, Hashable {
    case subscribed
    case alreadySubscribed = "already_subscribed"
    case notAuthorized = "not_authorized"
}

public struct SubscribeAck: Codable, Sendable, Hashable {
    public var outcome: SubscribeOutcome
    public var subscriptionId: String
    private enum CodingKeys: String, CodingKey {
        case outcome
        case subscriptionId = "subscription_id"
    }
    public init(outcome: SubscribeOutcome, subscriptionId: String) {
        self.outcome = outcome
        self.subscriptionId = subscriptionId
    }
}

public struct UnsubscribeNotificationsParams: Codable, Sendable, Hashable {
    public var sessionId: SessionId
    public var subscriptionId: String
    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case subscriptionId = "subscription_id"
    }
    public init(sessionId: SessionId, subscriptionId: String) {
        self.sessionId = sessionId
        self.subscriptionId = subscriptionId
    }
}

public enum UnsubscribeOutcome: String, Codable, Sendable, Hashable {
    case unsubscribed
    case notSubscribed = "not_subscribed"
    case evicted
}

public struct UnsubscribeAck: Codable, Sendable, Hashable {
    public var outcome: UnsubscribeOutcome
    public var subscriptionId: String
    private enum CodingKeys: String, CodingKey {
        case outcome
        case subscriptionId = "subscription_id"
    }
    public init(outcome: UnsubscribeOutcome, subscriptionId: String) {
        self.outcome = outcome
        self.subscriptionId = subscriptionId
    }
}

// MARK: - Hooks

public struct HookFrame: Codable, Sendable, Hashable {
    public var sessionId: SessionId
    public var toolId: ToolId?
    public var callId: ToolCallId?
    public var hookId: String?
    public var event: HookEvent
    public var traceContext: String?

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case toolId = "tool_id"
        case callId = "call_id"
        case hookId = "hook_id"
        case event
        case traceContext = "trace_context"
    }

    public init(
        sessionId: SessionId,
        toolId: ToolId? = nil,
        callId: ToolCallId? = nil,
        hookId: String? = nil,
        event: HookEvent,
        traceContext: String? = nil
    ) {
        self.sessionId = sessionId
        self.toolId = toolId
        self.callId = callId
        self.hookId = hookId
        self.event = event
        self.traceContext = traceContext
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encodeIfPresent(toolId, forKey: .toolId)
        try c.encodeIfPresent(callId, forKey: .callId)
        try c.encodeIfPresent(hookId, forKey: .hookId)
        try c.encode(event, forKey: .event)
        try c.encodeIfPresent(traceContext, forKey: .traceContext)
    }

    public static func cancel(sessionId: SessionId, toolId: ToolId, callId: ToolCallId) -> HookFrame {
        HookFrame(sessionId: sessionId, toolId: toolId, callId: callId, event: .cancel)
    }

    public static func pause(sessionId: SessionId) -> HookFrame {
        HookFrame(sessionId: sessionId, event: .pause)
    }

    public static func resume(sessionId: SessionId) -> HookFrame {
        HookFrame(sessionId: sessionId, event: .resume)
    }

    public static func sessionEnded(sessionId: SessionId) -> HookFrame {
        HookFrame(sessionId: sessionId, event: .sessionEnded)
    }

    public static func custom(sessionId: SessionId, kind: String, payload: JSONValue) -> HookFrame {
        HookFrame(sessionId: sessionId, event: .custom(kind: kind, payload: payload))
    }

    public static func customRequest(
        sessionId: SessionId,
        hookId: String,
        kind: String,
        payload: JSONValue
    ) -> HookFrame {
        HookFrame(
            sessionId: sessionId,
            hookId: hookId,
            event: .custom(kind: kind, payload: payload)
        )
    }

    public func withTraceContext(_ traceContext: String?) -> HookFrame {
        var copy = self
        copy.traceContext = traceContext
        return copy
    }
}

public struct HookReplyFrame: Codable, Sendable, Hashable {
    public var sessionId: SessionId
    public var hookId: String
    public var result: JSONValue
    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case hookId = "hook_id"
        case result
    }
    public init(sessionId: SessionId, hookId: String, result: JSONValue) {
        self.sessionId = sessionId
        self.hookId = hookId
        self.result = result
    }
}

public struct ToolsChanged: Codable, Sendable, Hashable {
    public var sessionId: SessionId
    public var added: [ToolId]
    public var removed: [ToolId]
    public var updated: [ToolId]
    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case added, removed, updated
    }
    public init(
        sessionId: SessionId,
        added: [ToolId] = [],
        removed: [ToolId] = [],
        updated: [ToolId] = []
    ) {
        self.sessionId = sessionId
        self.added = added
        self.removed = removed
        self.updated = updated
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionId = try c.decode(SessionId.self, forKey: .sessionId)
        self.added = try c.decodeIfPresent([ToolId].self, forKey: .added) ?? []
        self.removed = try c.decodeIfPresent([ToolId].self, forKey: .removed) ?? []
        self.updated = try c.decodeIfPresent([ToolId].self, forKey: .updated) ?? []
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionId, forKey: .sessionId)
        if !added.isEmpty { try c.encode(added, forKey: .added) }
        if !removed.isEmpty { try c.encode(removed, forKey: .removed) }
        if !updated.isEmpty { try c.encode(updated, forKey: .updated) }
    }
}

// MARK: - Tool server status

public enum ToolServerLifecycleStatus: String, Codable, Sendable, Hashable {
    case starting
    case ready
    case busy
    case draining
    case shuttingDown = "shutting_down"
    case disconnected
}

public struct ToolServerStatusPayload: Codable, Sendable, Hashable {
    public var status: ToolServerLifecycleStatus
    public var sessionId: SessionId?
    public var connectionId: String?
    public var activeToolCalls: UInt32
    public var activeToolNames: [String]
    public var backgroundTasks: UInt32
    public var backgroundTaskIds: [String]
    public var pendingToolCalls: UInt32
    public var lastToolCallStartedMs: UInt64
    public var lastToolCallCompletedMs: UInt64
    public var uptimeMs: UInt64
    public var idleSinceMs: UInt64?
    public var uploadQueuePending: UInt32
    public var uploadQueuePendingBytes: UInt64
    public var uploadQueueInflight: UInt32
    public var uploadQueueCircuitBreakerTripped: Bool
    public var artifactProducersInflight: UInt32
    public var drainStartedMs: UInt64?
    public var turnActive: Bool
    public var idleIgnoresBackground: Bool

    private enum CodingKeys: String, CodingKey {
        case status
        case sessionId = "session_id"
        case connectionId = "connection_id"
        case activeToolCalls = "active_tool_calls"
        case activeToolNames = "active_tool_names"
        case backgroundTasks = "background_tasks"
        case backgroundTaskIds = "background_task_ids"
        case pendingToolCalls = "pending_tool_calls"
        case lastToolCallStartedMs = "last_tool_call_started_ms"
        case lastToolCallCompletedMs = "last_tool_call_completed_ms"
        case uptimeMs = "uptime_ms"
        case idleSinceMs = "idle_since_ms"
        case uploadQueuePending = "upload_queue_pending"
        case uploadQueuePendingBytes = "upload_queue_pending_bytes"
        case uploadQueueInflight = "upload_queue_inflight"
        case uploadQueueCircuitBreakerTripped = "upload_queue_circuit_breaker_tripped"
        case artifactProducersInflight = "artifact_producers_inflight"
        case drainStartedMs = "drain_started_ms"
        case turnActive = "turn_active"
        case idleIgnoresBackground = "idle_ignores_background"
    }

    public init(
        status: ToolServerLifecycleStatus = .ready,
        sessionId: SessionId? = nil,
        connectionId: String? = nil,
        activeToolCalls: UInt32 = 0,
        activeToolNames: [String] = [],
        backgroundTasks: UInt32 = 0,
        backgroundTaskIds: [String] = [],
        pendingToolCalls: UInt32 = 0,
        lastToolCallStartedMs: UInt64 = 0,
        lastToolCallCompletedMs: UInt64 = 0,
        uptimeMs: UInt64 = 0,
        idleSinceMs: UInt64? = nil,
        uploadQueuePending: UInt32 = 0,
        uploadQueuePendingBytes: UInt64 = 0,
        uploadQueueInflight: UInt32 = 0,
        uploadQueueCircuitBreakerTripped: Bool = false,
        artifactProducersInflight: UInt32 = 0,
        drainStartedMs: UInt64? = nil,
        turnActive: Bool = false,
        idleIgnoresBackground: Bool = false
    ) {
        self.status = status
        self.sessionId = sessionId
        self.connectionId = connectionId
        self.activeToolCalls = activeToolCalls
        self.activeToolNames = activeToolNames
        self.backgroundTasks = backgroundTasks
        self.backgroundTaskIds = backgroundTaskIds
        self.pendingToolCalls = pendingToolCalls
        self.lastToolCallStartedMs = lastToolCallStartedMs
        self.lastToolCallCompletedMs = lastToolCallCompletedMs
        self.uptimeMs = uptimeMs
        self.idleSinceMs = idleSinceMs
        self.uploadQueuePending = uploadQueuePending
        self.uploadQueuePendingBytes = uploadQueuePendingBytes
        self.uploadQueueInflight = uploadQueueInflight
        self.uploadQueueCircuitBreakerTripped = uploadQueueCircuitBreakerTripped
        self.artifactProducersInflight = artifactProducersInflight
        self.drainStartedMs = drainStartedMs
        self.turnActive = turnActive
        self.idleIgnoresBackground = idleIgnoresBackground
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.status = try c.decodeIfPresent(ToolServerLifecycleStatus.self, forKey: .status) ?? .ready
        self.sessionId = try c.decodeIfPresent(SessionId.self, forKey: .sessionId)
        self.connectionId = try c.decodeIfPresent(String.self, forKey: .connectionId)
        self.activeToolCalls = try c.decodeIfPresent(UInt32.self, forKey: .activeToolCalls) ?? 0
        self.activeToolNames = try c.decodeIfPresent([String].self, forKey: .activeToolNames) ?? []
        self.backgroundTasks = try c.decodeIfPresent(UInt32.self, forKey: .backgroundTasks) ?? 0
        self.backgroundTaskIds = try c.decodeIfPresent([String].self, forKey: .backgroundTaskIds) ?? []
        self.pendingToolCalls = try c.decodeIfPresent(UInt32.self, forKey: .pendingToolCalls) ?? 0
        self.lastToolCallStartedMs = try c.decodeIfPresent(UInt64.self, forKey: .lastToolCallStartedMs) ?? 0
        self.lastToolCallCompletedMs = try c.decodeIfPresent(UInt64.self, forKey: .lastToolCallCompletedMs) ?? 0
        self.uptimeMs = try c.decodeIfPresent(UInt64.self, forKey: .uptimeMs) ?? 0
        self.idleSinceMs = try c.decodeIfPresent(UInt64.self, forKey: .idleSinceMs)
        self.uploadQueuePending = try c.decodeIfPresent(UInt32.self, forKey: .uploadQueuePending) ?? 0
        self.uploadQueuePendingBytes = try c.decodeIfPresent(UInt64.self, forKey: .uploadQueuePendingBytes) ?? 0
        self.uploadQueueInflight = try c.decodeIfPresent(UInt32.self, forKey: .uploadQueueInflight) ?? 0
        self.uploadQueueCircuitBreakerTripped =
            try c.decodeIfPresent(Bool.self, forKey: .uploadQueueCircuitBreakerTripped) ?? false
        self.artifactProducersInflight =
            try c.decodeIfPresent(UInt32.self, forKey: .artifactProducersInflight) ?? 0
        self.drainStartedMs = try c.decodeIfPresent(UInt64.self, forKey: .drainStartedMs)
        self.turnActive = try c.decodeIfPresent(Bool.self, forKey: .turnActive) ?? false
        self.idleIgnoresBackground = try c.decodeIfPresent(Bool.self, forKey: .idleIgnoresBackground) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
        try c.encodeIfPresent(connectionId, forKey: .connectionId)
        try c.encode(activeToolCalls, forKey: .activeToolCalls)
        if !activeToolNames.isEmpty { try c.encode(activeToolNames, forKey: .activeToolNames) }
        try c.encode(backgroundTasks, forKey: .backgroundTasks)
        if !backgroundTaskIds.isEmpty { try c.encode(backgroundTaskIds, forKey: .backgroundTaskIds) }
        try c.encode(pendingToolCalls, forKey: .pendingToolCalls)
        try c.encode(lastToolCallStartedMs, forKey: .lastToolCallStartedMs)
        try c.encode(lastToolCallCompletedMs, forKey: .lastToolCallCompletedMs)
        try c.encode(uptimeMs, forKey: .uptimeMs)
        try c.encodeIfPresent(idleSinceMs, forKey: .idleSinceMs)
        try c.encode(uploadQueuePending, forKey: .uploadQueuePending)
        try c.encode(uploadQueuePendingBytes, forKey: .uploadQueuePendingBytes)
        try c.encode(uploadQueueInflight, forKey: .uploadQueueInflight)
        try c.encode(uploadQueueCircuitBreakerTripped, forKey: .uploadQueueCircuitBreakerTripped)
        try c.encode(artifactProducersInflight, forKey: .artifactProducersInflight)
        try c.encodeIfPresent(drainStartedMs, forKey: .drainStartedMs)
        try c.encode(turnActive, forKey: .turnActive)
        try c.encode(idleIgnoresBackground, forKey: .idleIgnoresBackground)
    }

    public static func terminal(status: ToolServerLifecycleStatus) -> ToolServerStatusPayload {
        ToolServerStatusPayload(status: status)
    }
}

public struct ToolServerEvictParams: Codable, Sendable, Hashable {
    public var sessionId: SessionId
    public var reason: String
    public var gracePeriodMs: UInt64
    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case reason
        case gracePeriodMs = "grace_period_ms"
    }
    public init(sessionId: SessionId, reason: String, gracePeriodMs: UInt64) {
        self.sessionId = sessionId
        self.reason = reason
        self.gracePeriodMs = gracePeriodMs
    }
}

public struct ToolServerGetStatusParams: Codable, Sendable, Hashable {
    public var sessionId: SessionId
    private enum CodingKeys: String, CodingKey { case sessionId = "session_id" }
    public init(sessionId: SessionId) { self.sessionId = sessionId }
}

public struct ToolServerConnectionStatus: Codable, Sendable, Hashable {
    public var connectionId: String
    public var status: ToolServerStatusPayload
    private enum CodingKeys: String, CodingKey {
        case connectionId = "connection_id"
        case status
    }
    public init(connectionId: String, status: ToolServerStatusPayload) {
        self.connectionId = connectionId
        self.status = status
    }
}

public struct ToolServerGetStatusResult: Codable, Sendable, Hashable {
    public var toolServers: [ToolServerConnectionStatus]
    private enum CodingKeys: String, CodingKey { case toolServers = "tool_servers" }
    public init(toolServers: [ToolServerConnectionStatus]) { self.toolServers = toolServers }
}

public enum ToolServerDisconnectReason: String, Codable, Sendable, Hashable {
    case normalClose = "normal_close"
    case idleTimeout = "idle_timeout"
    case forceEvicted = "force_evicted"
    case connectionLost = "connection_lost"
}

// MARK: - Servers list / bind

public struct ServersListParams: Codable, Sendable, Hashable {
    public init() {}
}

public struct ServerInfo: Codable, Sendable, Hashable {
    public var serverId: ServerId
    public var sessionId: SessionId?
    public var description: String
    public var metadata: JSONValue
    public var connectedSince: String
    public var status: ToolServerLifecycleStatus

    private enum CodingKeys: String, CodingKey {
        case serverId = "server_id"
        case sessionId = "session_id"
        case description, metadata
        case connectedSince = "connected_since"
        case status
    }

    public init(
        serverId: ServerId,
        sessionId: SessionId? = nil,
        description: String = "",
        metadata: JSONValue = .object([:]),
        connectedSince: String = "",
        status: ToolServerLifecycleStatus
    ) {
        self.serverId = serverId
        self.sessionId = sessionId
        self.description = description
        self.metadata = metadata
        self.connectedSince = connectedSince
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.serverId = try c.decode(ServerId.self, forKey: .serverId)
        self.sessionId = try c.decodeIfPresent(SessionId.self, forKey: .sessionId)
        self.description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.metadata = try c.decodeIfPresent(JSONValue.self, forKey: .metadata) ?? .object([:])
        self.connectedSince = try c.decodeIfPresent(String.self, forKey: .connectedSince) ?? ""
        self.status = try c.decode(ToolServerLifecycleStatus.self, forKey: .status)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(serverId, forKey: .serverId)
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
        try c.encode(description, forKey: .description)
        try c.encode(metadata, forKey: .metadata)
        try c.encode(connectedSince, forKey: .connectedSince)
        try c.encode(status, forKey: .status)
    }
}

public struct ServersListResult: Codable, Sendable, Hashable {
    public var servers: [ServerInfo]
    public init(servers: [ServerInfo]) { self.servers = servers }
}

public struct ServerBindParams: Codable, Sendable, Hashable {
    public var serverId: ServerId
    public var sessionId: SessionId
    private enum CodingKeys: String, CodingKey {
        case serverId = "server_id"
        case sessionId = "session_id"
    }
    public init(serverId: ServerId, sessionId: SessionId) {
        self.serverId = serverId
        self.sessionId = sessionId
    }
}

public enum ServerBindOutcome: String, Codable, Sendable, Hashable {
    case bound
    case alreadyBound = "already_bound"
    case serverNotFound = "server_not_found"
    case unavailable
}

public struct ServerBindAck: Codable, Sendable, Hashable {
    public var outcome: ServerBindOutcome
    public init(outcome: ServerBindOutcome) { self.outcome = outcome }
}

public struct ServerUnbindParams: Codable, Sendable, Hashable {
    public var serverId: ServerId
    public var sessionId: SessionId
    private enum CodingKeys: String, CodingKey {
        case serverId = "server_id"
        case sessionId = "session_id"
    }
    public init(serverId: ServerId, sessionId: SessionId) {
        self.serverId = serverId
        self.sessionId = sessionId
    }
}

public enum ServerUnbindOutcome: String, Codable, Sendable, Hashable {
    case unbound
    case serverNotFound = "server_not_found"
}

public struct ServerUnbindAck: Codable, Sendable, Hashable {
    public var outcome: ServerUnbindOutcome
    public init(outcome: ServerUnbindOutcome) { self.outcome = outcome }
}

// MARK: - Heartbeat

/// Application-level heartbeat ping. Serializes as `{"method":"ping","ts_ms":N}`.
public struct PingFrame: Codable, Sendable, Hashable {
    public var tsMs: UInt64
    public init(tsMs: UInt64) { self.tsMs = tsMs }

    private enum CodingKeys: String, CodingKey {
        case method
        case tsMs = "ts_ms"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let method = try c.decodeIfPresent(String.self, forKey: .method), method != Method.ping.rawValue {
            throw DecodingError.dataCorruptedError(
                forKey: .method, in: c,
                debugDescription: "expected method \"ping\" but got \"\(method)\""
            )
        }
        self.tsMs = try c.decode(UInt64.self, forKey: .tsMs)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Method.ping.rawValue, forKey: .method)
        try c.encode(tsMs, forKey: .tsMs)
    }
}

/// Application-level heartbeat pong. Serializes as `{"method":"pong","ts_ms":N}`.
public struct PongFrame: Codable, Sendable, Hashable {
    public var tsMs: UInt64
    public init(tsMs: UInt64) { self.tsMs = tsMs }

    private enum CodingKeys: String, CodingKey {
        case method
        case tsMs = "ts_ms"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let method = try c.decodeIfPresent(String.self, forKey: .method), method != Method.pong.rawValue {
            throw DecodingError.dataCorruptedError(
                forKey: .method, in: c,
                debugDescription: "expected method \"pong\" but got \"\(method)\""
            )
        }
        self.tsMs = try c.decode(UInt64.self, forKey: .tsMs)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Method.pong.rawValue, forKey: .method)
        try c.encode(tsMs, forKey: .tsMs)
    }
}
