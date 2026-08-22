// Provider.swift
//
// Provider-specific transport policy for the sampling client.
// Authentication is intentionally not part of this adapter.
// Mirrors Rust `provider.rs`.

import Foundation
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokVersion

/// Process-level fallback for the `x-grok-client-identifier` header.
public let DEFAULT_CLIENT_IDENTIFIER = "grok-shell"
public let X_CODEX_TURN_STATE_HEADER = "x-codex-turn-state"
public let CODEX_SESSION_ID_HEADER = "session-id"
public let CODEX_THREAD_ID_HEADER = "thread-id"
public let CODEX_CLIENT_REQUEST_ID_HEADER = "x-client-request-id"
public let X_CODEX_TURN_METADATA_HEADER = "x-codex-turn-metadata"

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
    public var codexPermissions: CodexPermissions?
    public var sessionID: String?
    public var turnID: String?

    public init(
        multiAgentV2: Bool = false,
        localEffort: ReasoningEffort? = nil,
        reasoningSummary: ReasoningSummary? = nil,
        codexPermissions: CodexPermissions? = nil,
        sessionID: String? = nil,
        turnID: String? = nil
    ) {
        self.multiAgentV2 = multiAgentV2
        self.localEffort = localEffort
        self.reasoningSummary = reasoningSummary
        self.codexPermissions = codexPermissions
        self.sessionID = sessionID
        self.turnID = turnID
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
    /// Overrides provider cache-affinity headers, never x-grok telemetry.
    public var cacheAffinityId: String?

    public init(
        convId: String,
        reqId: String,
        modelId: String,
        sessionId: String,
        turnIdx: String? = nil,
        agentId: String,
        deploymentId: String? = nil,
        userId: String? = nil,
        cacheAffinityId: String? = nil
    ) {
        self.convId = convId
        self.reqId = reqId
        self.modelId = modelId
        self.sessionId = sessionId
        self.turnIdx = turnIdx
        self.agentId = agentId
        self.deploymentId = deploymentId
        self.userId = userId
        self.cacheAffinityId = cacheAffinityId
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

    func applySessionAffinityHeaders(_ headers: inout [String: String], sessionId: String?)

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
        // xAI's API gates requests on a parseable client version and rejects
        // absent/unparseable ones with 426 ("version (none)"). The session's
        // configured clientVersion is legitimately nil on cross-provider paths
        // (a Codex-parented subagent overriding to a Grok model), so fall back
        // to this build's own version, normalized to base semver: the fork's
        // `-open-grok.N` pre-release suffix is not part of the version grammar
        // the gate parses.
        headers["x-grok-client-version"] = baseSemVerClientVersion(config.clientVersion)
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
        applySessionAffinityHeaders(
            &headers,
            sessionId: request.cacheAffinityId ?? request.sessionId
        )
        if profile.requestMetadata == .xGrokHeaders {
            request.applyXGrok(into: &headers)
        }
    }

    public func applySessionAffinityHeaders(_ headers: inout [String: String], sessionId: String?) {}

    public func sanitizeChatRequest(_ request: inout ChatCompletionWireRequest) {}

    public func patchResponsesRequest(_ body: inout JSONValue, policy: ResponsesRequestPolicy) {
        switch profile.responsesDialect {
        case .none, .some(.xai):
            break
        case .some(.codex):
            patchCodexResponsesRequest(&body, policy: policy)
        case .some(.deepSeek):
            patchDeepSeekResponsesRequest(&body, policy: policy)
        case .some(.meta):
            patchMetaResponsesRequest(&body)
        }
    }

    public func promptCacheKey(sessionId: String?) -> String? {
        switch profile.responsesDialect {
        case .none, .some(.xai), .some(.deepSeek), .some(.meta):
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
        case .none, .some(.xai), .some(.deepSeek), .some(.meta):
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
        // Every dialect needs the dependency-boundary compatibility pass.
        case .some(.xai), .some(.codex), .some(.deepSeek), .some(.meta): return true
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

    public func applySessionAffinityHeaders(_ headers: inout [String: String], sessionId: String?) {
        guard let sessionId, !sessionId.isEmpty else { return }
        headers[CODEX_SESSION_ID_HEADER] = sessionId
        headers[CODEX_THREAD_ID_HEADER] = sessionId
        headers[CODEX_CLIENT_REQUEST_ID_HEADER] = sessionId
    }
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
        // Routing is provider-owned too (provider.rs:338).
        request.serviceTier = nil
    }
}

public struct FireworksProvider: ProviderAdapter {
    public init() {}
    public var provider: ModelProvider { .fireworks }

    public func sanitizeChatRequest(_ request: inout ChatCompletionWireRequest) {
        // Most Fireworks models 400 on `reasoning_effort`, so strip it
        // unconditionally here (provider.rs:353). The client's chat-defaults
        // gate restores the effort after this sanitize when the model's
        // config declares effort support — see
        // `SamplingClient.sanitizeChatWireRequest`.
        request.reasoningEffort = nil
        // Fireworks rejects internal per-message model_id attribution.
        for i in request.messages.indices {
            request.messages[i].modelId = nil
        }
        // Fireworks validates tool schemas strictly and 400s the whole request
        // on a subschema it considers unconstrained — `true`, or an object
        // carrying nothing but annotations. Loose schemas are legal JSON Schema
        // and several of our tools emit them, so rewrite rather than reject.
        if var tools = request.tools {
            for i in tools.indices {
                normalizeFireworksSchema(&tools[i].function.parameters)
            }
            request.tools = tools
        }
    }
}

/// Rewrite every unconstrained subschema into an explicit any-type union.
///
/// Port of `normalize_fireworks_schema` (`xai-grok-sampler/src/provider.rs:409`).
/// Recursion follows the JSON Schema keywords that hold subschemas, so a loose
/// schema nested inside `properties`, `$defs` or a `oneOf` branch is reached
/// too — Fireworks rejects those just as readily as a top-level one.
func normalizeFireworksSchema(_ schema: inout JSONValue) {
    switch schema {
    case .bool(true):
        schema = fireworksUnconstrainedSchema
    case .array(var items):
        for i in items.indices {
            normalizeFireworksSchema(&items[i])
        }
        schema = .array(items)
    case .object(var object):
        // Keywords whose value is a single subschema.
        for keyword in [
            "additionalProperties", "contains", "else", "if", "items", "not",
            "propertyNames", "then", "unevaluatedItems", "unevaluatedProperties",
        ] {
            guard var child = object[keyword] else { continue }
            normalizeFireworksSchema(&child)
            object[keyword] = child
        }
        // Keywords whose value is an array of subschemas.
        for keyword in ["allOf", "anyOf", "oneOf", "prefixItems"] {
            guard case .array(var children)? = object[keyword] else { continue }
            for i in children.indices {
                normalizeFireworksSchema(&children[i])
            }
            object[keyword] = .array(children)
        }
        // Keywords whose value is a map of name to subschema.
        for keyword in [
            "$defs", "definitions", "dependentSchemas", "patternProperties", "properties",
        ] {
            guard case .object(var children)? = object[keyword] else { continue }
            for key in children.keys {
                guard var child = children[key] else { continue }
                normalizeFireworksSchema(&child)
                children[key] = child
            }
            object[keyword] = .object(children)
        }
        // An object of pure annotations constrains nothing, so it is as
        // unconstrained as `true` and gets the same explicit union. The
        // annotations are kept: they are what the description carries.
        if object.keys.allSatisfy(isFireworksSchemaAnnotation),
           case .object(let unconstrained) = fireworksUnconstrainedSchema {
            object["anyOf"] = unconstrained["anyOf"]
        }
        schema = .object(object)
    default:
        break
    }
}

private func isFireworksSchemaAnnotation(_ keyword: String) -> Bool {
    switch keyword {
    case "$anchor", "$comment", "$id", "$schema", "default", "deprecated",
         "description", "examples", "readOnly", "title", "writeOnly":
        return true
    default:
        return false
    }
}

private let fireworksUnconstrainedSchema: JSONValue = .object([
    "anyOf": .array([
        .object(["type": .string("null")]),
        .object(["type": .string("boolean")]),
        .object(["type": .string("integer")]),
        .object(["type": .string("number")]),
        .object(["type": .string("string")]),
        .object(["type": .string("array")]),
        .object(["type": .string("object")]),
    ]),
])

public struct DeepSeekProvider: ProviderAdapter {
    public init() {}
    public var provider: ModelProvider { .deepseek }

    public func sanitizeChatRequest(_ request: inout ChatCompletionWireRequest) {
        for i in request.messages.indices {
            request.messages[i].modelId = nil
        }
        // DeepSeek does not accept `service_tier` (provider.rs:386).
        request.serviceTier = nil
    }
}

/// Meta's Model API is a stateless, OpenAI-compatible Responses provider.
/// A pure marker: every behavior comes from the protocol defaults driven by
/// `ProviderProfile.meta`, including the Meta arm of the Responses request
/// patch. Port of `MetaProvider` (`xai-grok-sampler/src/provider.rs:388-395`).
public struct MetaProvider: ProviderAdapter {
    public init() {}
    public var provider: ModelProvider { .meta }
}

public struct OpenCodeGoProvider: ProviderAdapter {
    public init() {}
    public var provider: ModelProvider { .openCodeGo }

    public func sanitizeChatRequest(_ request: inout ChatCompletionWireRequest) {
        for i in request.messages.indices {
            request.messages[i].modelId = nil
        }
        // OpenCode Go does not accept `service_tier` (provider.rs:411).
        request.serviceTier = nil
    }
}

/// Wafer AI is an ordinary OpenAI-compatible Chat Completions provider.
public struct WaferProvider: ProviderAdapter {
    public init() {}
    public var provider: ModelProvider { .wafer }

    public func sanitizeChatRequest(_ request: inout ChatCompletionWireRequest) {
        // Wafer does not accept `reasoning_effort`; unlike Fireworks there is
        // no restore gate, so effort never reaches this wire (provider.rs:422).
        request.reasoningEffort = nil
        // Nor `service_tier` (provider.rs:426).
        request.serviceTier = nil
        for i in request.messages.indices {
            request.messages[i].modelId = nil
        }
    }
}

/// Z AI is an OpenAI-compatible Chat Completions provider. It supports GLM
/// "thinking mode", and a requested effort turns on the explicit `thinking`
/// object Z AI expects alongside it; it still drops Grok-internal
/// `service_tier` and per-message `model_id` metadata.
public struct ZaiProvider: ProviderAdapter {
    public init() {}
    public var provider: ModelProvider { .zai }

    public func sanitizeChatRequest(_ request: inout ChatCompletionWireRequest) {
        request.serviceTier = nil
        for i in request.messages.indices {
            request.messages[i].modelId = nil
        }
        // Z AI gates GLM thinking with an explicit `thinking` object; a
        // requested reasoning_effort implies thinking enabled.
        request.thinking = request.reasoningEffort != nil ? .enabled : nil
    }
}

/// RunInfra keeps hosted-model reasoning while stripping xAI-only routing.
public struct RuninfraProvider: ProviderAdapter {
    public init() {}
    public var provider: ModelProvider { .runinfra }

    public func sanitizeChatRequest(_ request: inout ChatCompletionWireRequest) {
        request.serviceTier = nil
        for index in request.messages.indices {
            request.messages[index].modelId = nil
        }

        guard request.model == "deepseek-v4-flash",
              let effort = request.reasoningEffort else { return }
        switch effort {
        case .high, .xhigh, .max, .ultra:
            request.reasoningEffort = .max
        case .none, .minimal, .low, .medium:
            break
        }
    }
}

/// Gemini's OpenAI-compatible endpoint accepts reasoning effort, not Z AI thinking.
public struct GeminiProvider: ProviderAdapter {
    public init() {}
    public var provider: ModelProvider { .gemini }

    public func sanitizeChatRequest(_ request: inout ChatCompletionWireRequest) {
        request.serviceTier = nil
        request.thinking = nil
        for index in request.messages.indices {
            request.messages[index].modelId = nil
        }

        guard let effort = request.reasoningEffort else { return }
        switch effort {
        case .none:
            request.reasoningEffort = nil
        case .minimal where request.model == "gemini-3.7-flash"
            || request.model == "gemini-3.1-pro-preview":
            request.reasoningEffort = .low
        case .xhigh, .max, .ultra:
            request.reasoningEffort = .high
        case .minimal, .low, .medium, .high:
            break
        }
    }
}

/// OpenRouter owns attribution while retaining ordinary client-side tools.
public struct OpenRouterProvider: ProviderAdapter {
    public static let httpReferer = "https://github.com/mweinbach/open-grok"
    public static let appTitle = "Open Grok"

    public init() {}
    public var provider: ModelProvider { .openRouter }

    public func applyDefaultHeaders(_ headers: inout [String: String], config: SamplerConfig) {
        sanitizeHeaders(&headers)
        if !headers.keys.contains(where: {
            $0.caseInsensitiveCompare("HTTP-Referer") == .orderedSame
        }) {
            headers["HTTP-Referer"] = Self.httpReferer
        }
        if !headers.keys.contains(where: {
            $0.caseInsensitiveCompare("X-Title") == .orderedSame
        }) {
            headers["X-Title"] = Self.appTitle
        }
    }

    public func sanitizeChatRequest(_ request: inout ChatCompletionWireRequest) {
        request.serviceTier = nil
        request.thinking = nil
        for index in request.messages.indices {
            request.messages[index].modelId = nil
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
private let deepSeekProvider = DeepSeekProvider()
private let metaProvider = MetaProvider()
private let openCodeGoProvider = OpenCodeGoProvider()
private let waferProvider = WaferProvider()
private let zaiProvider = ZaiProvider()
private let runinfraProvider = RuninfraProvider()
private let geminiProvider = GeminiProvider()
private let openRouterProvider = OpenRouterProvider()

/// Complete registry for the built-in providers.
public let PROVIDER_REGISTRY: [ProviderRegistration] = [
    ProviderRegistration(provider: .xai, adapter: xaiProvider),
    ProviderRegistration(provider: .codex, adapter: codexProvider),
    ProviderRegistration(provider: .kimi, adapter: kimiProvider),
    ProviderRegistration(provider: .fireworks, adapter: fireworksProvider),
    ProviderRegistration(provider: .deepseek, adapter: deepSeekProvider),
    ProviderRegistration(provider: .meta, adapter: metaProvider),
    ProviderRegistration(provider: .openCodeGo, adapter: openCodeGoProvider),
    ProviderRegistration(provider: .wafer, adapter: waferProvider),
    ProviderRegistration(provider: .zai, adapter: zaiProvider),
    ProviderRegistration(provider: .runinfra, adapter: runinfraProvider),
    ProviderRegistration(provider: .gemini, adapter: geminiProvider),
    ProviderRegistration(provider: .openRouter, adapter: openRouterProvider),
]

/// Look up the stateless transport adapter for a built-in provider.
public func providerAdapter(_ provider: ModelProvider) -> any ProviderAdapter {
    switch provider {
    case .xai: return xaiProvider
    case .codex: return codexProvider
    case .kimi: return kimiProvider
    case .fireworks: return fireworksProvider
    case .deepseek: return deepSeekProvider
    case .meta: return metaProvider
    case .openCodeGo: return openCodeGoProvider
    case .wafer: return waferProvider
    case .zai: return zaiProvider
    case .runinfra: return runinfraProvider
    case .gemini: return geminiProvider
    case .openRouter: return openRouterProvider
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

/// Resolve the `x-grok-client-version` value: the configured version when it
/// is non-empty, otherwise this build's own version, truncated at the first
/// `-` or `+` so only the base semver reaches xAI's version gate.
func baseSemVerClientVersion(_ configured: String?) -> String {
    let resolved: String = {
        if let configured, !configured.isEmpty { return configured }
        return OpenGrokVersion.installed()
    }()
    let base = resolved.prefix { $0 != "-" && $0 != "+" }
    return base.isEmpty ? resolved : String(base)
}

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

/// Return true only when the decoder rejected the top-level Responses event
/// *kind* — the serialization message literally names ``unknown variant
/// `<type>` `` — never when a known event was malformed internally. Anything
/// looser turns a truncated known event (a half `response.output_text.delta`)
/// into silently missing tokens. Port of
/// `is_unknown_top_level_response_event`
/// (`xai-grok-sampler/src/provider.rs:834-847`).
func isUnknownTopLevelResponseEvent(error: SamplingError, data: String) -> Bool {
    guard case .serialization(let message) = error else { return false }
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(data.utf8)),
          let type = value["type"]?.stringValue
    else { return false }
    return message.contains("unknown variant `\(type)`")
}

func patchCodexResponsesRequest(_ body: inout JSONValue, policy: ResponsesRequestPolicy) {
    patchCodexInstructionRoles(&body)

    if let permissions = policy.codexPermissions {
        patchCodexPermissions(&body, permissions: permissions, policy: policy)
    }

    // Codex sandboxes `web_search` unless the request opts into live access;
    // grant it while leaving an explicit override untouched (provider.rs:
    // 594-607).
    if case .object(var obj) = body,
       case .array(var tools) = obj["tools"] {
        for i in tools.indices {
            guard tools[i]["type"]?.stringValue == "web_search",
                  case .object(var tool) = tools[i],
                  tool["external_web_access"] == nil
            else { continue }
            tool["external_web_access"] = .bool(true)
            tools[i] = .object(tool)
        }
        obj["tools"] = .array(tools)
        body = .object(obj)
    }

    if let summary = policy.reasoningSummary?.wireValue {
        ensureReasoningObject(&body)
        if case .object(var obj) = body {
            var reasoning = obj["reasoning"]?.objectValue ?? [:]
            reasoning["summary"] = .string(summary)
            obj["reasoning"] = .object(reasoning)
            body = .object(obj)
        }
    } else {
        // Drop summary when unsupported / disabled. Upstream leaves the
        // emptied `reasoning` object in place (provider.rs:613-620); the
        // base projection may still be carrying `reasoning.effort`, and an
        // empty object is valid on the wire, so do not remove it here.
        if case .object(var obj) = body,
           case .object(var reasoning) = obj["reasoning"]
        {
            reasoning.removeValue(forKey: "summary")
            obj["reasoning"] = .object(reasoning)
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

/// Project the same truthful session policy into provider metadata and a
/// developer instruction, matching `provider.rs:867-955`. Replacing existing
/// permission instructions makes repeated provider patching idempotent.
private func patchCodexPermissions(
    _ body: inout JSONValue,
    permissions: CodexPermissions,
    policy: ResponsesRequestPolicy
) {
    guard case .object(var object) = body else { return }

    var clientMetadata = object["client_metadata"]?.objectValue ?? [:]
    clientMetadata[X_CODEX_TURN_METADATA_HEADER] = .string(
        permissions.turnMetadata(sessionID: policy.sessionID, turnID: policy.turnID)
    )
    object["client_metadata"] = .object(clientMetadata)

    guard case .array(var input) = object["input"] else {
        body = .object(object)
        return
    }

    input.removeAll { item in
        item["role"]?.stringValue == "developer"
            && responsesMessageText(item)?.contains("<permissions instructions>") == true
    }

    let instruction: JSONValue = .object([
        "type": .string("message"),
        "role": .string("developer"),
        "content": .array([
            .object([
                "type": .string("input_text"),
                "text": .string(permissions.renderedInstructions),
            ]),
        ]),
    ])
    let insertionIndex = input.firstIndex { $0["role"]?.stringValue == "user" } ?? input.count
    input.insert(instruction, at: insertionIndex)

    object["input"] = .array(input)
    body = .object(object)
}

/// Fields DeepSeek's stateless Responses endpoint does not support. They are
/// silently ignored on the wire, so omitting them avoids implying continuity,
/// storage, or provider-side cache controls that do not exist.
let DEEPSEEK_UNSUPPORTED_RESPONSES_FIELDS = [
    "background",
    "conversation",
    "context_management",
    "include",
    "metadata",
    "previous_response_id",
    "prompt",
    "prompt_cache_key",
    "prompt_cache_retention",
    "safety_identifier",
    "service_tier",
    "store",
    "stream_options",
    "truncation",
]

func patchDeepSeekResponsesRequest(_ body: inout JSONValue, policy: ResponsesRequestPolicy) {
    guard case .object(var obj) = body else { return }

    for field in DEEPSEEK_UNSUPPORTED_RESPONSES_FIELDS {
        obj.removeValue(forKey: field)
    }

    // DeepSeek accepts `reasoning.summary` for compatibility but does not
    // generate one. Its documented Responses effort set is none/low/high/max,
    // so normalize Open Grok's broader menu explicitly.
    let effort: String? = policy.localEffort.map { effort in
        switch effort {
        case .none: return "none"
        case .minimal, .low: return "low"
        case .medium, .high, .xhigh: return "high"
        case .max, .ultra: return "max"
        }
    }

    if case .object(var reasoning) = obj["reasoning"] {
        reasoning.removeValue(forKey: "summary")
        if let effort {
            reasoning["effort"] = .string(effort)
        }
        obj["reasoning"] = .object(reasoning)
    } else if let effort {
        obj["reasoning"] = .object(["effort": .string(effort)])
    }

    if case .object(let reasoning) = obj["reasoning"], reasoning.isEmpty {
        obj.removeValue(forKey: "reasoning")
    }

    body = .object(obj)
}

/// Meta's Responses endpoint is stateless: OpenAI's continuity and cache
/// controls are unsupported, replayed `reasoning` input items are rejected,
/// and no summary is ever generated. Reasoning effort passes through
/// unchanged — Meta accepts the standard effort menu, unlike DeepSeek's
/// remap above, so do not add a mapping here. Port of
/// `patch_meta_responses_request` (`xai-grok-sampler/src/provider.rs:713-729`).
func patchMetaResponsesRequest(_ body: inout JSONValue) {
    guard case .object(var obj) = body else { return }

    for field in ["include", "prompt_cache_key", "prompt_cache_retention", "store"] {
        obj.removeValue(forKey: field)
    }

    if case .array(var input) = obj["input"] {
        input.removeAll { $0["type"]?.stringValue == "reasoning" }
        obj["input"] = .array(input)
    }

    if case .object(var reasoning) = obj["reasoning"] {
        reasoning.removeValue(forKey: "summary")
        obj["reasoning"] = .object(reasoning)
    }

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
