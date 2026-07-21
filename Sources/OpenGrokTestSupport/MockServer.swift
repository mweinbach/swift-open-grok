// MockServer.swift
//
// Port of `xai-grok-test-support/src/mock_server.rs`. A mock inference server
// serving `/v1/chat/completions`, `/v1/responses`, `/v1/messages`,
// `/v1/models`, `/v1/settings`, `/v1/user`, and `/v1/storage` on
// `127.0.0.1:0`, with three response modes (echo / fixed / scripted),
// request logging, and a flippable storage 401 gate.
//
// The Rust source uses `axum::Router` + `tokio::sync::oneshot` for graceful
// shutdown. The Swift port uses the `HttpServer` (Network.framework / BSD
// sockets) defined in `HttpServer.swift`. The handler logic is a direct
// translation: per-path FIFO of `ScriptedResponse`s, agent-turn-scripted
// queue, agent-turn text queue, response mode, required-auth gate, request
// log, models/settings/user/storage state.
//
// W0-S2 acceptance: the server itself does not touch the filesystem beyond
// its ephemeral socket; spawned subprocesses that talk to it use
// `HermeticEnv` for HOME/USERPROFILE/OPENGROK_HOME isolation.

import Foundation
import OpenGrokTestUtilities

/// A logged inference request entry. Mirrors `mock_server::LogEntry`.
public struct LogEntry: Sendable {
    public let method: String
    public let path: String
    public let body: JSONValue?
    /// Value of the `Authorization` header, if present.
    public let authorization: String?
    /// Request headers (lowercase names, arrival order), captured on the
    /// inference POST endpoints; the GET endpoints log an empty list.
    public let headers: [(String, String)]

    public init(method: String, path: String, body: JSONValue?, authorization: String?, headers: [(String, String)]) {
        self.method = method
        self.path = path
        self.body = body
        self.authorization = authorization
        self.headers = headers
    }

    public static func == (lhs: LogEntry, rhs: LogEntry) -> Bool {
        guard lhs.method == rhs.method && lhs.path == rhs.path else { return false }
        guard lhs.body == rhs.body && lhs.authorization == rhs.authorization else { return false }
        guard lhs.headers.count == rhs.headers.count else { return false }
        for (l, r) in zip(lhs.headers, rhs.headers) {
            guard l.0 == r.0 && l.1 == r.1 else { return false }
        }
        return true
    }

    /// First value of `name` (case-insensitive), if the request carried it.
    public func header(_ name: String) -> String? {
        let lower = name.lowercased()
        for (k, v) in headers where k.lowercased() == lower {
            return v
        }
        return nil
    }
}

/// One accepted (HTTP 200) mock `/v1/storage` upload.
public struct StorageUpload: Sendable, Equatable {
    public let path: String
    public let size: Int
    /// Request body when `size <= 256 KiB`; empty for larger payloads.
    public let body: Data
    /// `Authorization` header value as sent (e.g. `Bearer …`).
    public let authorization: String?

    public init(path: String, size: Int, body: Data, authorization: String?) {
        self.path = path
        self.size = size
        self.body = body
        self.authorization = authorization
    }
}

/// A model entry for the mock `/v1/models` endpoint. Mirrors
/// `mock_server::MockModelEntry`.
public struct MockModelEntry: Sendable, Equatable {
    public var id: String
    public var agentType: String?
    public var apiBackend: String?
    public var provider: String?
    public var supportsBackendSearch: Bool
    public var supportsReasoningEffort: Bool
    public var reasoningEffort: String?
    public var reasoningEfforts: [JSONValue]

    public init(id: String) {
        self.id = id
        self.agentType = nil
        self.apiBackend = nil
        self.provider = nil
        self.supportsBackendSearch = false
        self.supportsReasoningEffort = false
        self.reasoningEffort = nil
        self.reasoningEfforts = []
    }

    public static func withAgentType(id: String, agentType: String) -> MockModelEntry {
        var entry = MockModelEntry(id: id)
        entry.agentType = agentType
        return entry
    }

    public func withAPIBackend(_ backend: String) -> MockModelEntry {
        var copy = self
        copy.apiBackend = backend
        return copy
    }

    public func withProvider(_ provider: String) -> MockModelEntry {
        var copy = self
        copy.provider = provider
        return copy
    }

    public func withSupportsBackendSearch(_ supports: Bool) -> MockModelEntry {
        var copy = self
        copy.supportsBackendSearch = supports
        return copy
    }

    public func withSupportsReasoningEffort(_ supports: Bool) -> MockModelEntry {
        var copy = self
        copy.supportsReasoningEffort = supports
        return copy
    }

    public func withReasoningEffort(_ effort: String) -> MockModelEntry {
        var copy = self
        copy.reasoningEffort = effort
        return copy
    }

    public func withReasoningEfforts(_ efforts: [JSONValue]) -> MockModelEntry {
        var copy = self
        copy.reasoningEfforts = efforts
        return copy
    }

    /// Render to the JSON shape `parse_remote_model_value` reads. Mirrors
    /// `MockModelEntry::to_json`.
    func toJSON() -> JSONValue {
        var pairs: [(String, JSONValue)] = [
            ("id", .string(id)),
            ("object", .string("model")),
            ("created", .integer(1234567890)),
            ("owned_by", .string("test")),
        ]
        if let agentType {
            pairs.append(("_meta", .object([("agentType", .string(agentType))])))
        }
        if let apiBackend {
            pairs.append(("apiBackend", .string(apiBackend)))
        }
        if let provider {
            pairs.append(("provider", .string(provider)))
        }
        if supportsBackendSearch {
            pairs.append(("supportsBackendSearch", .bool(true)))
        }
        if supportsReasoningEffort {
            pairs.append(("supportsReasoningEffort", .bool(true)))
        }
        if let reasoningEffort {
            pairs.append(("reasoningEffort", .string(reasoningEffort)))
        }
        if !reasoningEfforts.isEmpty {
            pairs.append(("reasoningEfforts", .array(reasoningEfforts)))
        }
        return .object(pairs)
    }
}

/// The maximum body bytes retained on each accepted `StorageUpload`.
private let storageBodyCaptureCap = 256 * 1024

/// What the inference endpoints stream back.
private enum ResponseMode: Sendable {
    /// Echo the last user message as `Echo: <msg>` (whitespace-collapsing).
    case echo
    /// Stream a fixed text whose deltas reconstruct it byte-for-byte.
    case fixed(String)
}

/// Mock inference server state, shared between the handler and the public
/// API. `@unchecked Sendable` via internal `NSLock`s.
private final class MockServerState: @unchecked Sendable {
    let log = RequestLogStore()
    let modelsLock = NSLock()
    var models: [JSONValue]
    let settingsLock = NSLock()
    var settings: JSONValue?
    let modeLock = NSLock()
    var mode: ResponseMode = .echo
    let scriptedLock = NSLock()
    var scripted: [String: [ScriptedResponse]] = [:]
    let scriptedAgentTurnsLock = NSLock()
    var scriptedAgentTurns: [ScriptedResponse] = []
    let agentTurnsLock = NSLock()
    var agentTurns: [String] = []
    let messagesStopReasonLock = NSLock()
    var messagesStopReason: String = "end_turn"
    let chunkDelayLock = NSLock()
    var chunkDelay: TimeInterval? = nil
    let storageLock = NSLock()
    var storageUnauthorized: Bool = false
    var storageRequestCount: UInt32 = 0
    var storageUploads: [StorageUpload] = []
    let userTierLock = NSLock()
    var userTier: String? = nil
    let requiredToken: String?
    /// Opt-in barrier holding agent turns' terminal SSE event until
    /// `releaseAgentCompletions` is called. Inert until a test holds it.
    /// Mirrors `mock_server::CompletionGate`.
    let completionGate = CompletionGate()

    init(models: [JSONValue], requiredToken: String?) {
        self.models = models
        self.requiredToken = requiredToken
    }
}

/// Opt-in barrier that holds an agent turn's terminal SSE event until the
/// test releases it, so the turn stays deterministically "running" while the
/// test interacts with it (queue edits/removals) — eliminating turn-end races.
///
/// Inert by default: `waitIfHeld` returns immediately, so every test that
/// never calls `holdAgentCompletions` is completely unaffected. Mirrors
/// `mock_server::CompletionGate`.
private final class CompletionGate: SseCompletionGate, @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    /// A manual-reset event equivalent: waiters block on `NSCondition` until
    /// `release` flips `held` to false and broadcasts.
    private let condition = NSCondition()

    func hold() {
        condition.lock()
        held = true
        condition.unlock()
    }

    func release() {
        condition.lock()
        held = false
        condition.broadcast()
        condition.unlock()
    }

    /// Block while the gate is held. Registers the wake-up interest *before*
    /// re-checking `held` so a concurrent `release` can never be missed.
    func waitIfHeld() {
        condition.lock()
        defer { condition.unlock() }
        while held {
            condition.wait()
        }
    }

    /// Snapshot of the held flag without blocking — used by the SSE renderer
    /// to decide whether to gate the terminal event.
    var isHeld: Bool {
        condition.lock()
        defer { condition.unlock() }
        return held
    }
}

/// Lock-protected request log.
private final class RequestLogStore: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [LogEntry] = []
    private var count: UInt32 = 0

    func record(
        method: String,
        path: String,
        body: JSONValue?,
        authorization: String?,
        headers: [(String, String)]
    ) {
        lock.lock()
        defer { lock.unlock() }
        count &+= 1
        entries.append(LogEntry(method: method, path: path, body: body, authorization: authorization, headers: headers))
    }

    func requestCount() -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func entriesSnapshot() -> [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }
}

/// Mock `/v1/chat/completions` + `/v1/responses` + `/v1/messages` +
/// `/v1/models` + `/v1/settings` + `/v1/user` + `/v1/storage` server.
/// Logs all requests. Shuts down on `stop()` / `deinit`.
public final class MockInferenceServer: @unchecked Sendable {
    /// The base URL, e.g. `http://127.0.0.1:54321/v1`.
    public var url: String { server.baseURL }

    private let server: HttpServer
    private let state: MockServerState

    /// Start with a single default `test-model` (no agent_type).
    public init() throws {
        let modelsJSON = [MockModelEntry(id: "test-model")].map { $0.toJSON() }
        let state = MockServerState(models: modelsJSON, requiredToken: nil)
        self.state = state
        let handler = MockInferenceHandler(state: state)
        self.server = HttpServer(handler: handler, basePath: "/v1")
        try server.start()
    }

    /// Start with custom models. Use `MockModelEntry.withAgentType` to
    /// configure models with specific harness types.
    public init(models: [MockModelEntry]) throws {
        let modelsJSON = models.map { $0.toJSON() }
        let state = MockServerState(models: modelsJSON, requiredToken: nil)
        self.state = state
        let handler = MockInferenceHandler(state: state)
        self.server = HttpServer(handler: handler, basePath: "/v1")
        try server.start()
    }

    /// Start a mock that returns 401 on inference requests missing
    /// `Authorization: Bearer <requiredToken>`.
    public init(models: [MockModelEntry], requiredToken: String) throws {
        let modelsJSON = models.map { $0.toJSON() }
        let state = MockServerState(models: modelsJSON, requiredToken: requiredToken)
        self.state = state
        let handler = MockInferenceHandler(state: state)
        self.server = HttpServer(handler: handler, basePath: "/v1")
        try server.start()
    }

    deinit { server.stop() }

    /// Stop the server. Idempotent.
    public func stop() { server.stop() }

    // MARK: - Runtime configuration

    /// Replace the model list at runtime.
    public func setModels(_ models: [MockModelEntry]) {
        state.modelsLock.lock()
        defer { state.modelsLock.unlock() }
        state.models = models.map { $0.toJSON() }
    }

    /// Stream this fixed text from all inference endpoints instead of
    /// echoing. Deltas reconstruct the text byte-for-byte. Subsequent calls
    /// replace the text.
    public func setResponse(_ text: String) {
        state.modeLock.lock()
        defer { state.modeLock.unlock() }
        state.mode = .fixed(text)
    }

    /// Queue a `ScriptedResponse` for the next request on `path` (e.g.
    /// `/v1/chat/completions`). Scripts are consumed FIFO per path; when a
    /// path's queue is empty, requests fall back to the active mode.
    public func enqueueResponse(path: String, response: ScriptedResponse) throws {
        try response.validate()
        state.scriptedLock.lock()
        defer { state.scriptedLock.unlock() }
        state.scripted[path, default: []].append(response)
    }

    /// Queue a `ScriptedResponse` for the next tool-bearing agent turn on
    /// any inference endpoint. Auxiliary requests never consume this queue.
    public func enqueueAgentTurnResponse(_ response: ScriptedResponse) throws {
        try response.validate()
        state.scriptedAgentTurnsLock.lock()
        defer { state.scriptedAgentTurnsLock.unlock() }
        state.scriptedAgentTurns.append(response)
    }

    /// Queue one byte-exact response per agent turn, consumed FIFO. Only
    /// requests carrying 2+ tools count as agent turns.
    public func setAgentTurns(_ turns: [String]) {
        state.agentTurnsLock.lock()
        defer { state.agentTurnsLock.unlock() }
        state.agentTurns = turns
    }

    /// Replace the settings at runtime. Until set, `/v1/settings` returns 404.
    public func setSettings(_ value: JSONValue) {
        state.settingsLock.lock()
        defer { state.settingsLock.unlock() }
        state.settings = value
    }

    /// Preset `/v1/settings` to the minimal `{"allow_access": true}` payload.
    public func presetAllowAccess() {
        setSettings(.object([("allow_access", .bool(true))]))
    }

    /// Set the `subscriptionTier` served by `GET /v1/user`. `nil` (default)
    /// omits the field.
    public func setUserSubscriptionTier(_ tier: String?) {
        state.userTierLock.lock()
        defer { state.userTierLock.unlock() }
        state.userTier = tier
    }

    /// Set the `stop_reason` emitted by the `/v1/messages` terminal
    /// `message_delta` (default `"end_turn"`).
    public func setMessagesStopReason(_ reason: String) {
        state.messagesStopReasonLock.lock()
        defer { state.messagesStopReasonLock.unlock() }
        state.messagesStopReason = reason
    }

    /// Pace all inference SSE streams: each event is emitted after `delay`
    /// seconds. `nil` restores instant streaming.
    public func setChunkDelay(_ delay: TimeInterval?) {
        state.chunkDelayLock.lock()
        defer { state.chunkDelayLock.unlock() }
        state.chunkDelay = delay
    }

    /// Hold every agent turn's terminal SSE event until
    /// `releaseAgentCompletions` is called, keeping the turn
    /// deterministically "streaming-but-not-complete". Lets a test interact
    /// with a running turn (e.g. queue edits/removals) without racing turn
    /// end. Content deltas still stream normally; only completion is gated.
    /// Inert for tests that never call this. Mirrors
    /// `mock_server::MockInferenceServer::hold_agent_completions`.
    public func holdAgentCompletions() {
        state.completionGate.hold()
    }

    /// Release a hold set by `holdAgentCompletions`, letting held (and
    /// future) agent turns emit their terminal event and complete. Mirrors
    /// `mock_server::MockInferenceServer::release_agent_completions`.
    public func releaseAgentCompletions() {
        state.completionGate.release()
    }

    /// Flip the mock `/v1/storage` 401 gate.
    public func setStorageUnauthorized(_ unauthorized: Bool) {
        state.storageLock.lock()
        defer { state.storageLock.unlock() }
        state.storageUnauthorized = unauthorized
    }

    // MARK: - Request log accessors

    public func requestCount() -> UInt32 { state.log.requestCount() }
    public func requests() -> [LogEntry] { state.log.entriesSnapshot() }

    /// Bodies of all received requests, in arrival order (body-less requests
    /// such as `GET /v1/models` are skipped).
    public func requestBodies() -> [JSONValue] {
        state.log.entriesSnapshot().compactMap { $0.body }
    }

    public func hasChatCompletionRequest() -> Bool {
        state.log.entriesSnapshot().contains { $0.path.contains("chat/completions") }
    }

    public func hasResponsesRequest() -> Bool {
        state.log.entriesSnapshot().contains { $0.path.contains("responses") }
    }

    /// Number of `POST /v1/messages` requests received so far.
    public func messagesRequestCount() -> Int {
        state.log.entriesSnapshot().filter { $0.path == "/v1/messages" }.count
    }

    /// Format the request log for diagnostic output on test failures.
    public func requestLogSummary() -> String {
        let entries = state.log.entriesSnapshot()
        if entries.isEmpty { return "(no requests received)" }
        return entries.enumerated().map { i, e in "  [\(i)] \(e.method) \(e.path)" }.joined(separator: "\n")
    }

    /// Get the system prompt from the most recent inference request.
    public func lastSystemPrompt() -> String? {
        let entries = state.log.entriesSnapshot()
        for entry in entries.reversed() {
            if entry.path.contains("chat/completions") || entry.path.contains("responses") {
                guard let body = entry.body else { continue }
                // Chat completions: messages[0].content (system message).
                if let messages = body["messages"].arrayValue,
                   let first = messages.first,
                   let content = first["content"].stringValue {
                    return content
                }
                // Responses API: instructions field.
                if let instructions = body["instructions"].stringValue {
                    return instructions
                }
            }
        }
        return nil
    }

    // MARK: - Storage accessors

    public func storageRequestCount() -> UInt32 {
        state.storageLock.lock()
        defer { state.storageLock.unlock() }
        return state.storageRequestCount
    }

    public func storageUploads() -> [StorageUpload] {
        state.storageLock.lock()
        defer { state.storageLock.unlock() }
        return state.storageUploads
    }
}

/// The handler that routes requests to the mock endpoints.
private struct MockInferenceHandler: HttpRequestHandler {
    let state: MockServerState

    func handle(_ request: HttpRequest) -> HttpResponse {
        switch (request.method, request.pathOnly) {
        case ("POST", "/v1/chat/completions"):
            return handleInference(request, path: "/v1/chat/completions", api: .chatCompletions)
        case ("POST", "/v1/responses"):
            return handleInference(request, path: "/v1/responses", api: .responses)
        case ("POST", "/v1/messages"):
            return handleInference(request, path: "/v1/messages", api: .messages)
        case ("GET", "/v1/models"):
            return handleModels(request)
        case ("GET", "/v1/settings"):
            return handleSettings(request)
        case ("GET", "/v1/user"):
            return handleUser(request)
        case ("POST", "/v1/storage"):
            return handleStorageUpload(request)
        case ("GET", "/v1/storage/exists"):
            return .notFound
        case ("POST", "/v1/storage/batch_exists"):
            return .notFound
        case ("POST", "/v1/storage/batch_upload_json"):
            return .notFound
        case ("POST", "/v1/storage/batch_upload"):
            return .notFound
        case ("GET", "/v1/storage/limits"):
            return .notFound
        default:
            return .notFound
        }
    }

    private enum InferenceAPI {
        case chatCompletions, responses, messages
    }

    private func handleInference(_ request: HttpRequest, path: String, api: InferenceAPI) -> HttpResponse {
        let body = request.jsonBody() ?? .null
        state.log.record(
            method: "POST",
            path: path,
            body: body,
            authorization: request.authorization,
            headers: request.headers
        )

        // Scripted agent-turn response (only tool-bearing turns consume it).
        if let scripted = popScriptedAgentTurn(body: body) {
            return renderScripted(scripted)
        }
        // Per-path scripted response.
        if let scripted = popScripted(path: path) {
            return renderScripted(scripted)
        }
        // Required-auth gate.
        if let rejection = checkAuth(request) {
            return rejection
        }

        let userMessage = extractUserMessage(body: body, api: api)
        let model = body["model"].stringValue ?? "test-model"

        // Snapshot the chunk delay so we apply it consistently to this turn.
        state.chunkDelayLock.lock()
        let delay = state.chunkDelay
        state.chunkDelayLock.unlock()

        // Agent-turn text queue (only tool-bearing turns consume it).
        // Only agent turns are gate-eligible: aux requests (title/classifier)
        // must never block session startup.
        if let text = popAgentTurn(body: body) {
            return sseResponse(text: text, model: model, api: api, byteExact: true, delay: delay, gate: state.completionGate)
        }

        // Active response mode.
        state.modeLock.lock()
        let mode = state.mode
        state.modeLock.unlock()
        switch mode {
        case .echo:
            return sseResponse(text: "Echo: \(userMessage)", model: model, api: api, byteExact: false, delay: delay, gate: nil)
        case .fixed(let text):
            return sseResponse(text: text, model: model, api: api, byteExact: true, delay: delay, gate: nil)
        }
    }

    private func sseResponse(text: String, model: String, api: InferenceAPI, byteExact: Bool, delay: TimeInterval?, gate: SseCompletionGate?) -> HttpResponse {
        let events: [SseEvent]
        switch api {
        case .chatCompletions:
            events = byteExact
                ? SseEvents.chatCompletionEventsExact(text: text, model: model)
                : SseEvents.chatCompletionEvents(text: text, model: model)
        case .responses:
            events = byteExact
                ? SseEvents.responsesApiEventsExact(text: text, model: model)
                : SseEvents.responsesApiEvents(text: text, model: model)
        case .messages:
            state.messagesStopReasonLock.lock()
            let stop = state.messagesStopReason
            state.messagesStopReasonLock.unlock()
            events = SseEvents.messagesApiEvents(text: text, model: model, stopReason: stop)
        }
        // Use the paced SSE body only when there's a delay or a gate;
        // otherwise the plain `.sse` path is faster and identical.
        if delay == nil && gate == nil {
            return HttpResponse(status: 200, body: .sse(events))
        }
        let config = SseStreamConfig(delay: delay, gate: gate)
        return HttpResponse(status: 200, body: .ssePaced(events, config))
    }

    private func renderScripted(_ response: ScriptedResponse) -> HttpResponse {
        var headers = response.headers
        switch response.body {
        case .json(let value):
            // Preserve any caller-supplied headers (e.g. Retry-After on a
            // 429) on top of the JSON content-type the helper adds.
            var jsonHeaders: [(String, String)] = [("content-type", "application/json")]
            for (k, v) in response.headers where k.lowercased() != "content-type" {
                jsonHeaders.append((k, v))
            }
            let bytes = (try? value.encode()) ?? Data()
            return HttpResponse(status: response.status, headers: jsonHeaders, body: .bytes(bytes))
        case .raw(let s):
            // Preserve caller-supplied headers on top of the text/plain
            // default. Mirrors the Rust `into_response_paced` which inserts
            // the scripted headers AFTER the body's default content-type.
            var textHeaders: [(String, String)] = [("content-type", "text/plain; charset=utf-8")]
            for (k, v) in response.headers where k.lowercased() != "content-type" {
                textHeaders.append((k, v))
            }
            return HttpResponse(status: response.status, headers: textHeaders, body: .bytes(Data(s.utf8)))
        case .sse(let events):
            headers.append(("content-type", "text/event-stream"))
            headers.append(("cache-control", "no-cache"))
            // Scripted SSE bodies honor the server's `set_chunk_delay` pacing,
            // same as the echo/fixed modes (mirrors Rust `into_response_paced`).
            state.chunkDelayLock.lock()
            let delay = state.chunkDelay
            state.chunkDelayLock.unlock()
            if let delay {
                let config = SseStreamConfig(delay: delay, gate: nil)
                return HttpResponse(status: response.status, headers: headers, body: .ssePaced(events, config))
            }
            return HttpResponse(status: response.status, headers: headers, body: .sse(events))
        }
    }

    private func popScripted(path: String) -> ScriptedResponse? {
        state.scriptedLock.lock()
        defer { state.scriptedLock.unlock() }
        guard var queue = state.scripted[path], !queue.isEmpty else { return nil }
        let first = queue.removeFirst()
        state.scripted[path] = queue
        return first
    }

    private func popScriptedAgentTurn(body: JSONValue) -> ScriptedResponse? {
        guard isAgentTurn(body) else { return nil }
        state.scriptedAgentTurnsLock.lock()
        defer { state.scriptedAgentTurnsLock.unlock() }
        guard !state.scriptedAgentTurns.isEmpty else { return nil }
        return state.scriptedAgentTurns.removeFirst()
    }

    private func popAgentTurn(body: JSONValue) -> String? {
        guard isAgentTurn(body) else { return nil }
        state.agentTurnsLock.lock()
        defer { state.agentTurnsLock.unlock() }
        guard !state.agentTurns.isEmpty else { return nil }
        return state.agentTurns.removeFirst()
    }

    private func isAgentTurn(_ body: JSONValue) -> Bool {
        guard let tools = body["tools"].arrayValue else { return false }
        return tools.count >= 2
    }

    private func checkAuth(_ request: HttpRequest) -> HttpResponse? {
        guard let required = state.requiredToken else { return nil }
        let valid: Bool
        if let auth = request.authorization {
            let token = auth.hasPrefix("Bearer ") ? String(auth.dropFirst("Bearer ".count))
                : auth.hasPrefix("bearer ") ? String(auth.dropFirst("bearer ".count))
                : nil
            valid = token == required
        } else {
            valid = false
        }
        if valid { return nil }
        return .unauthorized("missing API key; set the x-api-key header or Authorization: Bearer header")
    }

    private func extractUserMessage(body: JSONValue, api: InferenceAPI) -> String {
        switch api {
        case .chatCompletions:
            if let messages = body["messages"].arrayValue {
                for msg in messages.reversed() where msg["role"].stringValue == "user" {
                    if let s = msg["content"].stringValue { return s }
                }
            }
            return "hello"
        case .responses:
            if let items = body["input"].arrayValue {
                for item in items.reversed() where item["role"].stringValue == "user" {
                    let content = item["content"]
                    if let s = content.stringValue { return s }
                    if let parts = content.arrayValue {
                        for p in parts where p["type"].stringValue == "input_text" {
                            if let s = p["text"].stringValue { return s }
                        }
                    }
                }
            }
            return "hello"
        case .messages:
            if let messages = body["messages"].arrayValue {
                for msg in messages.reversed() where msg["role"].stringValue == "user" {
                    let content = msg["content"]
                    if let s = content.stringValue { return s }
                    if let blocks = content.arrayValue {
                        for b in blocks where b["type"].stringValue == "text" {
                            if let s = b["text"].stringValue { return s }
                        }
                    }
                }
            }
            return "hello"
        }
    }

    private func handleModels(_ request: HttpRequest) -> HttpResponse {
        state.log.record(method: "GET", path: "/v1/models", body: nil, authorization: nil, headers: [])
        state.modelsLock.lock()
        let models = state.models
        state.modelsLock.unlock()
        let body = JSONValue.object([
            ("object", .string("list")),
            ("data", .array(models)),
        ])
        return .json(status: 200, body)
    }

    private func handleSettings(_ request: HttpRequest) -> HttpResponse {
        state.log.record(method: "GET", path: "/v1/settings", body: nil, authorization: nil, headers: [])
        // Scripted one-shots take precedence (FIFO).
        if let scripted = popScripted(path: "/v1/settings") {
            return renderScripted(scripted)
        }
        state.settingsLock.lock()
        let settings = state.settings
        state.settingsLock.unlock()
        if let settings {
            return .json(status: 200, settings)
        }
        return .notFound
    }

    private func handleUser(_ request: HttpRequest) -> HttpResponse {
        let path = request.query.isEmpty ? "/v1/user" : "/v1/user?\(request.query)"
        state.log.record(method: "GET", path: path, body: nil, authorization: nil, headers: [])
        state.userTierLock.lock()
        let tier = state.userTier
        state.userTierLock.unlock()
        var pairs: [(String, JSONValue)] = [
            ("userId", .string("mock-user")),
            ("email", .string("mock-user@test.invalid")),
        ]
        if let tier {
            pairs.append(("subscriptionTier", .string(tier)))
        }
        return .json(status: 200, .object(pairs))
    }

    private func handleStorageUpload(_ request: HttpRequest) -> HttpResponse {
        state.storageLock.lock()
        state.storageRequestCount &+= 1
        let unauthorized = state.storageUnauthorized
        if unauthorized {
            state.storageLock.unlock()
            return .unauthorized("Invalid or expired credentials (mock)")
        }
        let path = request.header("X-Storage-Path") ?? ""
        let size = request.body.count
        let capturedBody = size <= storageBodyCaptureCap ? request.body : Data()
        let authorization = request.authorization
        state.storageUploads.append(StorageUpload(path: path, size: size, body: capturedBody, authorization: authorization))
        state.storageLock.unlock()
        let body = JSONValue.object([
            ("bucket", .string("mock-bucket")),
            ("path", .string(path)),
            ("size", .integer(Int64(size))),
            ("content_type", .string("application/octet-stream")),
            ("generation", .integer(1)),
        ])
        return .json(status: 200, body)
    }
}
