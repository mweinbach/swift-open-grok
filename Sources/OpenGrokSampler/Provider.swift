// Provider.swift
//
// Provider-specific transport policy for the sampling client.
// Authentication is intentionally not part of this adapter.
// Mirrors Rust `provider.rs`.

import Foundation
import OpenGrokSamplingTypes
import OpenGrokShared

/// Process-level fallback for the `x-grok-client-identifier` header.
public let DEFAULT_CLIENT_IDENTIFIER = "grok-shell"
public let X_CODEX_TURN_STATE_HEADER = "x-codex-turn-state"

public let MULTI_AGENT_MODE_OPEN_TAG = "<multi_agent_mode>"
public let MULTI_AGENT_MODE_CLOSE_TAG = "</multi_agent_mode>"
public let EXPLICIT_REQUEST_ONLY_MULTI_AGENT_MODE_TEXT =
    "Any earlier instruction enabling proactive multi-agent delegation no longer applies. Do not spawn sub-agents unless the user or applicable AGENTS.md/skill instructions explicitly ask for sub-agents, delegation, or parallel agent work."
public let PROACTIVE_MULTI_AGENT_MODE_TEXT =
    "Proactive multi-agent delegation is active. Any earlier instruction requiring an explicit user request before spawning sub-agents no longer applies. Use sub-agents when parallel work would materially improve speed or quality. This mode remains active until a later multi-agent mode developer message changes it."

// MARK: - Request policy

/// Provider-neutral input to the Responses request patching seam.
public struct ResponsesRequestPolicy: Sendable, Equatable {
    public var multiAgentV2: Bool
    public var localEffort: ReasoningEffort?
    public var reasoningSummary: ReasoningSummary?

    public init(
        multiAgentV2: Bool = false,
        localEffort: ReasoningEffort? = nil,
        reasoningSummary: ReasoningSummary? = nil
    ) {
        self.multiAgentV2 = multiAgentV2
        self.localEffort = localEffort
        self.reasoningSummary = reasoningSummary
    }
}

/// Request metadata available to providers that use the xAI proxy contract.
public struct ProviderRequestHeaders: Sendable {
    public var convId: String
    public var reqId: String
    public var modelId: String
    public var sessionId: String
    public var turnIdx: String?
    public var agentId: String
    public var deploymentId: String?
    public var userId: String?

    public init(
        convId: String,
        reqId: String,
        modelId: String,
        sessionId: String,
        turnIdx: String? = nil,
        agentId: String,
        deploymentId: String? = nil,
        userId: String? = nil
    ) {
        self.convId = convId
        self.reqId = reqId
        self.modelId = modelId
        self.sessionId = sessionId
        self.turnIdx = turnIdx
        self.agentId = agentId
        self.deploymentId = deploymentId
        self.userId = userId
    }

    /// Apply x-grok identity headers into a mutable header bag.
    public func applyXGrok(into headers: inout [String: String]) {
        headers["x-grok-conv-id"] = convId
        headers["x-grok-req-id"] = reqId
        headers["x-grok-model-override"] = modelId
        headers["x-grok-session-id"] = sessionId
        headers["x-grok-agent-id"] = agentId
        if let turnIdx, !turnIdx.isEmpty {
            headers["x-grok-turn-idx"] = turnIdx
        }
        if let deploymentId, !deploymentId.isEmpty {
            headers["x-grok-deployment-id"] = deploymentId
        }
        if let userId, !userId.isEmpty {
            headers["x-grok-user-id"] = userId
        }
    }
}

// MARK: - Adapter protocol

/// Provider policy consumed by ``SamplingClient``.
///
/// Implementations are stateless. Methods deliberately do not receive
/// credentials or an auth scheme.
public protocol ProviderAdapter: Sendable {
    var provider: ModelProvider { get }

    var profile: ProviderProfile { get }

    func validateBackend(_ backend: ApiBackend) throws

    /// Remove provider-private headers forbidden by this profile.
    func sanitizeHeaders(_ headers: inout [String: String])

    func applyDefaultHeaders(_ headers: inout [String: String], config: SamplerConfig)

    func applyRequestHeaders(_ headers: inout [String: String], request: ProviderRequestHeaders)

    /// Apply provider-owned request constraints after shared defaults.
    func sanitizeChatRequest(_ request: inout ChatCompletionWireRequest)

    func patchResponsesRequest(_ body: inout JSONValue, policy: ResponsesRequestPolicy)

    func promptCacheKey(sessionId: String?) -> String?

    func supportsTurnState(backend: ApiBackend) -> Bool

    func applyTurnStateHeader(_ headers: inout [String: String], turnState: CodexTurnStateCell?)

    func captureTurnState(from headers: [String: String], into turnState: CodexTurnStateCell?)

    /// Absorb forward-compatible Responses metadata side channel.
    /// Returns `true` when the event was a metadata event and should be swallowed.
    func absorbResponseMetadata(eventName: String, data: String, turnState: CodexTurnStateCell?) -> Bool

    var sendsDoomLoopOptIn: Bool { get }

    var normalizesResponseEvents: Bool { get }

    func ignoresUnknownResponseEvent(error: SamplingError, data: String) -> Bool
}

extension ProviderAdapter {
    public var profile: ProviderProfile { provider.profile }

    public func validateBackend(_ backend: ApiBackend) throws {
        guard profile.supportsBackend(backend) else {
            throw SamplingError.invalidConfiguration(
                "API backend is not supported by the selected provider"
            )
        }
    }

    public func sanitizeHeaders(_ headers: inout [String: String]) {
        if profile.requestMetadata == .standardHeadersOnly {
            removeXGrokHeaders(&headers)
        }
    }

    public func applyDefaultHeaders(_ headers: inout [String: String], config: SamplerConfig) {
        sanitizeHeaders(&headers)
        guard profile.requestMetadata == .xGrokHeaders else { return }
        if let v = config.clientVersion, !v.isEmpty {
            headers["x-grok-client-version"] = v
        }
        if let v = config.deploymentId, !v.isEmpty {
            headers["x-grok-deployment-id"] = v
        }
        if let v = config.userId, !v.isEmpty {
            headers["x-grok-user-id"] = v
        }
        let clientIdentifier = config.clientIdentifier ?? DEFAULT_CLIENT_IDENTIFIER
        headers["x-grok-client-identifier"] = clientIdentifier
    }

    public func applyRequestHeaders(_ headers: inout [String: String], request: ProviderRequestHeaders) {
        if profile.requestMetadata == .xGrokHeaders {
            request.applyXGrok(into: &headers)
        }
    }

    public func sanitizeChatRequest(_ request: inout ChatCompletionWireRequest) {}

    public func patchResponsesRequest(_ body: inout JSONValue, policy: ResponsesRequestPolicy) {
        switch profile.responsesDialect {
        case .none, .some(.xai):
            break
        case .some(.codex):
            patchCodexResponsesRequest(&body, policy: policy)
        }
    }

    public func promptCacheKey(sessionId: String?) -> String? {
        switch profile.responsesDialect {
        case .none, .some(.xai):
            return nil
        case .some(.codex):
            guard let sessionId, !sessionId.isEmpty else { return nil }
            return sessionId
        }
    }

    public func supportsTurnState(backend: ApiBackend) -> Bool {
        profile.responsesDialect == .codex && backend == .responses
    }

    public func applyTurnStateHeader(_ headers: inout [String: String], turnState: CodexTurnStateCell?) {
        // Case-insensitive remove.
        headers = headers.filter { $0.key.lowercased() != X_CODEX_TURN_STATE_HEADER }
        guard supportsTurnState(backend: .responses) else { return }
        if let value = turnState?.get(), !value.isEmpty {
            headers[X_CODEX_TURN_STATE_HEADER] = value
        }
    }

    public func captureTurnState(from headers: [String: String], into turnState: CodexTurnStateCell?) {
        guard supportsTurnState(backend: .responses) else { return }
        guard let turnState else { return }
        let value = headers.first { $0.key.lowercased() == X_CODEX_TURN_STATE_HEADER }?.value
        if let value, !value.isEmpty {
            turnState.setIfEmpty(value)
        }
    }

    public func absorbResponseMetadata(
        eventName: String,
        data: String,
        turnState: CodexTurnStateCell?
    ) -> Bool {
        let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(data.utf8))
        let typeField = parsed?["type"]?.stringValue
        let isMetadata = eventName == "response.metadata" || typeField == "response.metadata"
        guard isMetadata else { return false }

        switch profile.responsesDialect {
        case .none, .some(.xai):
            break
        case .some(.codex):
            if let headersObj = parsed?["headers"]?.objectValue {
                for (name, value) in headersObj {
                    if name.lowercased() == X_CODEX_TURN_STATE_HEADER {
                        let str = responseMetadataHeaderValue(value)
                        if let str, let turnState {
                            turnState.setIfEmpty(str)
                        }
                    }
                }
            }
        }
        return true
    }

    public var sendsDoomLoopOptIn: Bool {
        profile.requestMetadata == .xGrokHeaders
    }

    public var normalizesResponseEvents: Bool {
        switch profile.responsesDialect {
        case .none: return false
        case .some(.xai), .some(.codex): return true
        }
    }

    public func ignoresUnknownResponseEvent(error: SamplingError, data: String) -> Bool {
        profile.responsesDialect == .codex && isUnknownTopLevelResponseEvent(error: error, data: data)
    }
}

// MARK: - Concrete adapters

public struct XaiProvider: ProviderAdapter {
    public init() {}
    public var provider: ModelProvider { .xai }
}

public struct CodexProvider: ProviderAdapter {
    public init() {}
    public var provider: ModelProvider { .codex }
}

public struct KimiProvider: ProviderAdapter {
    public init() {}
    public var provider: ModelProvider { .kimi }

    public func sanitizeChatRequest(_ request: inout ChatCompletionWireRequest) {
        // Kimi coding models own sampling policy; do not forward temperature/top_p.
        request.temperature = nil
        request.topP = nil
        request.frequencyPenalty = nil
        request.presencePenalty = nil
    }
}

public struct FireworksProvider: ProviderAdapter {
    public init() {}
    public var provider: ModelProvider { .fireworks }

    public func sanitizeChatRequest(_ request: inout ChatCompletionWireRequest) {
        // Fireworks rejects internal per-message model_id attribution.
        for i in request.messages.indices {
            request.messages[i].modelId = nil
        }
    }
}

// MARK: - Registry

public struct ProviderRegistration: Sendable {
    public let provider: ModelProvider
    public let adapter: any ProviderAdapter

    public init(provider: ModelProvider, adapter: any ProviderAdapter) {
        self.provider = provider
        self.adapter = adapter
    }
}

private let xaiProvider = XaiProvider()
private let codexProvider = CodexProvider()
private let kimiProvider = KimiProvider()
private let fireworksProvider = FireworksProvider()

/// Complete registry for the built-in providers.
public let PROVIDER_REGISTRY: [ProviderRegistration] = [
    ProviderRegistration(provider: .xai, adapter: xaiProvider),
    ProviderRegistration(provider: .codex, adapter: codexProvider),
    ProviderRegistration(provider: .kimi, adapter: kimiProvider),
    ProviderRegistration(provider: .fireworks, adapter: fireworksProvider),
]

/// Look up the stateless transport adapter for a built-in provider.
public func providerAdapter(_ provider: ModelProvider) -> any ProviderAdapter {
    switch provider {
    case .xai: return xaiProvider
    case .codex: return codexProvider
    case .kimi: return kimiProvider
    case .fireworks: return fireworksProvider
    }
}

// MARK: - Codex turn state cell

/// First-value-wins sticky-routing token for one logical Codex turn.
public final class CodexTurnStateCell: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    public init() {}

    public func get() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    @discardableResult
    public func setIfEmpty(_ newValue: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value == nil {
            value = newValue
            return true
        }
        return false
    }
}

/// Shared owner for Codex's turn-scoped sticky-routing token.
public final class CodexTurnState: @unchecked Sendable {
    private let lock = NSLock()
    private var current: CodexTurnStateCell

    public init() {
        self.current = CodexTurnStateCell()
    }

    public func beginTurn() {
        lock.lock()
        defer { lock.unlock() }
        current = CodexTurnStateCell()
    }

    public func snapshot() -> CodexTurnStateCell {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
}

// MARK: - Helpers

func removeXGrokHeaders(_ headers: inout [String: String]) {
    headers = headers.filter { !$0.key.lowercased().hasPrefix("x-grok-") }
}

private func responseMetadataHeaderValue(_ value: JSONValue) -> String? {
    switch value {
    case .string(let s): return s
    case .array(let arr):
        return arr.compactMap { $0.stringValue }.first
    default:
        return nil
    }
}

func isUnknownTopLevelResponseEvent(error: SamplingError, data: String) -> Bool {
    guard case .serialization = error else { return false }
    // Unknown top-level `type` fields on Responses events.
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(data.utf8)) else {
        return false
    }
    guard let type = value["type"]?.stringValue else { return false }
    let knownPrefixes = ["response.", "error"]
    // If it looks like a response event type we don't know, Codex may ignore it.
    return type.hasPrefix("response.") || knownPrefixes.contains(where: { type.hasPrefix($0) })
}

func patchCodexResponsesRequest(_ body: inout JSONValue, policy: ResponsesRequestPolicy) {
    patchCodexInstructionRoles(&body)

    if let summary = policy.reasoningSummary?.wireValue {
        ensureReasoningObject(&body)
        if case .object(var obj) = body {
            var reasoning = obj["reasoning"]?.objectValue ?? [:]
            reasoning["summary"] = .string(summary)
            obj["reasoning"] = .object(reasoning)
            body = .object(obj)
        }
    } else {
        // Drop summary when unsupported / disabled.
        if case .object(var obj) = body,
           case .object(var reasoning) = obj["reasoning"]
        {
            reasoning.removeValue(forKey: "summary")
            if reasoning.isEmpty {
                obj.removeValue(forKey: "reasoning")
            } else {
                obj["reasoning"] = .object(reasoning)
            }
            body = .object(obj)
        }
    }

    if policy.localEffort == .max || policy.localEffort == .ultra {
        ensureReasoningObject(&body)
        if case .object(var obj) = body {
            var reasoning = obj["reasoning"]?.objectValue ?? [:]
            reasoning["effort"] = .string("max")
            obj["reasoning"] = .object(reasoning)
            body = .object(obj)
        }
    }

    guard policy.multiAgentV2 else { return }

    let modeText = (policy.localEffort == .ultra)
        ? PROACTIVE_MULTI_AGENT_MODE_TEXT
        : EXPLICIT_REQUEST_ONLY_MULTI_AGENT_MODE_TEXT
    let rendered = "\(MULTI_AGENT_MODE_OPEN_TAG)\(modeText)\(MULTI_AGENT_MODE_CLOSE_TAG)"

    guard case .object(var obj) = body,
          case .array(var input) = obj["input"]
    else { return }

    input.removeAll(where: { isMultiAgentModeItem($0) })

    let modeItem: JSONValue = .object([
        "type": .string("message"),
        "role": .string("developer"),
        "content": .array([
            .object([
                "type": .string("input_text"),
                "text": .string(rendered),
            ]),
        ]),
    ])

    let lastIsUser = input.last?["role"]?.stringValue == "user"
    let insertAt = lastIsUser ? max(0, input.count - 1) : input.count
    input.insert(modeItem, at: insertAt)

    obj["input"] = .array(input)
    body = .object(obj)
}

private func ensureReasoningObject(_ body: inout JSONValue) {
    guard case .object(var obj) = body else { return }
    if obj["reasoning"] == nil || obj["reasoning"]?.objectValue == nil {
        obj["reasoning"] = .object([:])
        body = .object(obj)
    }
}

/// Codex instruction roles: extract leading system instructions to `instructions`
/// and map subsequent system messages to `developer` on the Responses input list.
private func patchCodexInstructionRoles(_ body: inout JSONValue) {
    guard case .object(var obj) = body else { return }
    guard case .array(let input) = obj["input"] else { return }

    var leadingInstructions: [String] = []
    var inLeadingPrefix = true
    var projected: [JSONValue] = []

    for var item in input {
        let isSystem = item["role"]?.stringValue == "system"
        if !isSystem {
            inLeadingPrefix = false
            projected.append(item)
            continue
        }

        if inLeadingPrefix,
           let text = responsesMessageText(item)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty
        {
            leadingInstructions.append(text)
            continue
        }

        if case .object(var itemObj) = item {
            itemObj["role"] = .string("developer")
            item = .object(itemObj)
        }
        projected.append(item)
    }

    obj["input"] = .array(projected)

    if !leadingInstructions.isEmpty {
        let leading = leadingInstructions.joined(separator: "\n\n")
        let existingInstructions = obj["instructions"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        if existingInstructions == nil || existingInstructions?.isEmpty == true {
            obj["instructions"] = .string(leading)
        }
    }

    body = .object(obj)
}

private func responsesMessageText(_ item: JSONValue) -> String? {
    guard let content = item["content"] else { return nil }
    switch content {
    case .string(let text):
        return text
    case .array(let parts):
        let text = parts.compactMap { part -> String? in
            part["text"]?.stringValue
        }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    default:
        return nil
    }
}

private func isMultiAgentModeItem(_ item: JSONValue) -> Bool {
    guard item["role"]?.stringValue == "developer" else { return false }
    guard let content = item["content"] else { return false }
    switch content {
    case .string(let text):
        return text.contains(MULTI_AGENT_MODE_OPEN_TAG)
    case .array(let parts):
        return parts.contains { part in
            part["text"]?.stringValue?.contains(MULTI_AGENT_MODE_OPEN_TAG) == true
        }
    default:
        return false
    }
}


