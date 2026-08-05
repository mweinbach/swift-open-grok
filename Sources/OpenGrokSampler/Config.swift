// Config.swift
//
// Sampler configuration types. Mirrors Rust `config.rs`.
//
// Authentication credentials and live bearer resolution are injected; this
// module never imports OpenGrokAuth or OpenGrokModels.

import Foundation
import OpenGrokHTTP
import OpenGrokSamplingTypes
import OpenGrokShared

// MARK: - Auth scheme

/// How the static / resolved API key is applied on the wire.
public enum AuthScheme: String, Codable, Sendable, Equatable, Hashable {
    case bearer
    case xApiKey = "x_api_key"
}

// MARK: - Resolved auth

/// One provider-auth snapshot applied atomically to a request.
///
/// `extraHeaders` must come from the same authenticated state as `bearer`.
public struct ResolvedBearerAuth: Sendable, Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bearer == rhs.bearer &&
        lhs.extraHeaders.elementsEqual(rhs.extraHeaders, by: {
            $0.name == $1.name && $0.value == $1.value
        })
    }
    public var bearer: String
    public var extraHeaders: [(name: String, value: String)]

    public init(bearer: String, extraHeaders: [(name: String, value: String)] = []) {
        self.bearer = bearer
        self.extraHeaders = extraHeaders
    }

    public static func bearerOnly(_ bearer: String) -> ResolvedBearerAuth {
        ResolvedBearerAuth(bearer: bearer)
    }
}

// MARK: - Bearer resolver

/// Cheap sync read of current provider auth for ``SamplerConfig/bearerResolver``.
public protocol BearerResolver: Sendable {
    func currentBearer() -> String?

    /// Resolve bearer plus account-scoped headers from one credential snapshot.
    func currentAuth() -> ResolvedBearerAuth?

    /// Headers owned by this auth provider. The client removes them from the
    /// static header bag before applying live auth.
    var reservedHeaders: [String] { get }

    /// When true, an unavailable live snapshot removes the static auth fallback.
    var failClosedOnMissing: Bool { get }
}

extension BearerResolver {
    public func currentAuth() -> ResolvedBearerAuth? {
        currentBearer().map { ResolvedBearerAuth.bearerOnly($0) }
    }

    public var reservedHeaders: [String] { [] }

    /// New resolvers fail closed by default.
    public var failClosedOnMissing: Bool { true }
}

// MARK: - Header injector

/// Per-request header injection (e.g. OTel `traceparent`).
public protocol HeaderInjector: Sendable {
    func inject(into headers: inout [String: String])
}

// MARK: - Retry policy

/// Retry knobs for the sampler's internal transport-error retry loop.
public struct RetryPolicy: Codable, Sendable, Equatable {
    public var maxRetries: UInt32
    public var rateLimitRetryThreshold: UInt32

    public init(
        maxRetries: UInt32 = DEFAULT_MAX_RETRIES,
        rateLimitRetryThreshold: UInt32 = RATE_LIMIT_RETRY_THRESHOLD
    ) {
        self.maxRetries = maxRetries
        self.rateLimitRetryThreshold = rateLimitRetryThreshold
    }

    public static let `default` = RetryPolicy()
}

// MARK: - SamplerConfig

/// All knobs that control a single sampling request.
///
/// Auth is selected via `authScheme`; `apiBackend` controls only the
/// request/response protocol shape. Live credentials arrive through
/// `bearerResolver` when present.
public struct SamplerConfig: Sendable {
    public var apiKey: String?
    public var baseURL: String
    public var model: String
    public var maxCompletionTokens: UInt32?
    public var temperature: Float?
    public var topP: Float?
    public var apiBackend: ApiBackend
    public var provider: ModelProvider
    public var authScheme: AuthScheme
    /// Extra request headers applied verbatim.
    public var extraHeaders: [(name: String, value: String)]
    public var contextWindow: UInt64
    public var forceHTTP1: Bool
    public var maxRetries: UInt32?
    public var streamToolCalls: Bool
    public var idleTimeoutSecs: UInt64?
    public var reasoningEffort: ReasoningEffort?
    /// Responses `service_tier` routing id (`"priority"` for Codex Fast mode).
    public var serviceTier: String?
    public var reasoningSummary: ReasoningSummary?
    public var originClient: OriginClientInfo?
    public var clientIdentifier: String?
    public var deploymentId: String?
    public var userId: String?
    public var clientVersion: String?
    public var supportsBackendSearch: Bool
    public var codexMultiAgentV2: Bool
    public var compactionsRemaining: CompactionsRemaining?
    public var compactionAtTokens: CompactionAtTokens?
    public var doomLoopRecovery: DoomLoopRecoveryPolicy?

    /// Optional 401 attribution hook (not serializable).
    public var attributionCallback: (any Auth401AttributionCallback)?
    /// Live bearer resolve per request. `nil` uses construction-time `apiKey`.
    public var bearerResolver: (any BearerResolver)?
    /// Per-request header injector (e.g. OTel traceparent).
    public var headerInjector: (any HeaderInjector)?

    public init(
        apiKey: String? = nil,
        baseURL: String = "",
        model: String = "",
        maxCompletionTokens: UInt32? = nil,
        temperature: Float? = nil,
        topP: Float? = nil,
        apiBackend: ApiBackend = .chatCompletions,
        provider: ModelProvider = .xai,
        authScheme: AuthScheme = .bearer,
        extraHeaders: [(name: String, value: String)] = [],
        contextWindow: UInt64 = 0,
        forceHTTP1: Bool = false,
        maxRetries: UInt32? = nil,
        streamToolCalls: Bool = false,
        idleTimeoutSecs: UInt64? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        serviceTier: String? = nil,
        reasoningSummary: ReasoningSummary? = nil,
        originClient: OriginClientInfo? = nil,
        clientIdentifier: String? = nil,
        deploymentId: String? = nil,
        userId: String? = nil,
        clientVersion: String? = nil,
        supportsBackendSearch: Bool = false,
        codexMultiAgentV2: Bool = false,
        compactionsRemaining: CompactionsRemaining? = nil,
        compactionAtTokens: CompactionAtTokens? = nil,
        doomLoopRecovery: DoomLoopRecoveryPolicy? = nil,
        attributionCallback: (any Auth401AttributionCallback)? = nil,
        bearerResolver: (any BearerResolver)? = nil,
        headerInjector: (any HeaderInjector)? = nil
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.maxCompletionTokens = maxCompletionTokens
        self.temperature = temperature
        self.topP = topP
        self.apiBackend = apiBackend
        self.provider = provider
        self.authScheme = authScheme
        self.extraHeaders = extraHeaders
        self.contextWindow = contextWindow
        self.forceHTTP1 = forceHTTP1
        self.maxRetries = maxRetries
        self.streamToolCalls = streamToolCalls
        self.idleTimeoutSecs = idleTimeoutSecs
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.reasoningSummary = reasoningSummary
        self.originClient = originClient
        self.clientIdentifier = clientIdentifier
        self.deploymentId = deploymentId
        self.userId = userId
        self.clientVersion = clientVersion
        self.supportsBackendSearch = supportsBackendSearch
        self.codexMultiAgentV2 = codexMultiAgentV2
        self.compactionsRemaining = compactionsRemaining
        self.compactionAtTokens = compactionAtTokens
        self.doomLoopRecovery = doomLoopRecovery
        self.attributionCallback = attributionCallback
        self.bearerResolver = bearerResolver
        self.headerInjector = headerInjector
    }
}

// MARK: - Codable (skips non-serializable hooks)

extension SamplerConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case baseURL = "base_url"
        case model
        case maxCompletionTokens = "max_completion_tokens"
        case temperature
        case topP = "top_p"
        case apiBackend = "api_backend"
        case provider
        case authScheme = "auth_scheme"
        case extraHeaders = "extra_headers"
        case contextWindow = "context_window"
        case forceHTTP1 = "force_http1"
        case maxRetries = "max_retries"
        case streamToolCalls = "stream_tool_calls"
        case idleTimeoutSecs = "idle_timeout_secs"
        case reasoningEffort = "reasoning_effort"
        case serviceTier = "service_tier"
        case reasoningSummary = "reasoning_summary"
        case originClient = "origin_client"
        case clientIdentifier = "client_identifier"
        case deploymentId = "deployment_id"
        case userId = "user_id"
        case clientVersion = "client_version"
        case supportsBackendSearch = "supports_backend_search"
        case codexMultiAgentV2 = "codex_multi_agent_v2"
        case compactionsRemaining = "compactions_remaining"
        case compactionAtTokens = "compaction_at_tokens"
        case doomLoopRecovery = "doom_loop_recovery"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            apiKey: try c.decodeIfPresent(String.self, forKey: .apiKey),
            baseURL: try c.decodeIfPresent(String.self, forKey: .baseURL) ?? "",
            model: try c.decodeIfPresent(String.self, forKey: .model) ?? "",
            maxCompletionTokens: try c.decodeIfPresent(UInt32.self, forKey: .maxCompletionTokens),
            temperature: try c.decodeIfPresent(Float.self, forKey: .temperature),
            topP: try c.decodeIfPresent(Float.self, forKey: .topP),
            apiBackend: try c.decodeIfPresent(ApiBackend.self, forKey: .apiBackend) ?? .chatCompletions,
            provider: try c.decodeIfPresent(ModelProvider.self, forKey: .provider) ?? .xai,
            authScheme: try c.decodeIfPresent(AuthScheme.self, forKey: .authScheme) ?? .bearer,
            extraHeaders: Self.decodeHeaders(try c.decodeIfPresent([String: String].self, forKey: .extraHeaders)),
            contextWindow: try c.decodeIfPresent(UInt64.self, forKey: .contextWindow) ?? 0,
            forceHTTP1: try c.decodeIfPresent(Bool.self, forKey: .forceHTTP1) ?? false,
            maxRetries: try c.decodeIfPresent(UInt32.self, forKey: .maxRetries),
            streamToolCalls: try c.decodeIfPresent(Bool.self, forKey: .streamToolCalls) ?? false,
            idleTimeoutSecs: try c.decodeIfPresent(UInt64.self, forKey: .idleTimeoutSecs),
            reasoningEffort: try c.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort),
            serviceTier: try c.decodeIfPresent(String.self, forKey: .serviceTier),
            reasoningSummary: try c.decodeIfPresent(ReasoningSummary.self, forKey: .reasoningSummary),
            originClient: try c.decodeIfPresent(OriginClientInfo.self, forKey: .originClient),
            clientIdentifier: try c.decodeIfPresent(String.self, forKey: .clientIdentifier),
            deploymentId: try c.decodeIfPresent(String.self, forKey: .deploymentId),
            userId: try c.decodeIfPresent(String.self, forKey: .userId),
            clientVersion: try c.decodeIfPresent(String.self, forKey: .clientVersion),
            supportsBackendSearch: try c.decodeIfPresent(Bool.self, forKey: .supportsBackendSearch) ?? false,
            codexMultiAgentV2: try c.decodeIfPresent(Bool.self, forKey: .codexMultiAgentV2) ?? false,
            compactionsRemaining: try c.decodeIfPresent(CompactionsRemaining.self, forKey: .compactionsRemaining),
            compactionAtTokens: try c.decodeIfPresent(CompactionAtTokens.self, forKey: .compactionAtTokens),
            doomLoopRecovery: try c.decodeIfPresent(DoomLoopRecoveryPolicy.self, forKey: .doomLoopRecovery)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(apiKey, forKey: .apiKey)
        try c.encode(baseURL, forKey: .baseURL)
        try c.encode(model, forKey: .model)
        try c.encodeIfPresent(maxCompletionTokens, forKey: .maxCompletionTokens)
        try c.encodeIfPresent(temperature, forKey: .temperature)
        try c.encodeIfPresent(topP, forKey: .topP)
        try c.encode(apiBackend, forKey: .apiBackend)
        try c.encode(provider, forKey: .provider)
        try c.encode(authScheme, forKey: .authScheme)
        try c.encode(Self.encodeHeaders(extraHeaders), forKey: .extraHeaders)
        try c.encode(contextWindow, forKey: .contextWindow)
        try c.encode(forceHTTP1, forKey: .forceHTTP1)
        try c.encodeIfPresent(maxRetries, forKey: .maxRetries)
        try c.encode(streamToolCalls, forKey: .streamToolCalls)
        try c.encodeIfPresent(idleTimeoutSecs, forKey: .idleTimeoutSecs)
        try c.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try c.encodeIfPresent(serviceTier, forKey: .serviceTier)
        try c.encodeIfPresent(reasoningSummary, forKey: .reasoningSummary)
        try c.encodeIfPresent(originClient, forKey: .originClient)
        try c.encodeIfPresent(clientIdentifier, forKey: .clientIdentifier)
        try c.encodeIfPresent(deploymentId, forKey: .deploymentId)
        try c.encodeIfPresent(userId, forKey: .userId)
        try c.encodeIfPresent(clientVersion, forKey: .clientVersion)
        try c.encode(supportsBackendSearch, forKey: .supportsBackendSearch)
        try c.encode(codexMultiAgentV2, forKey: .codexMultiAgentV2)
        try c.encodeIfPresent(compactionsRemaining, forKey: .compactionsRemaining)
        try c.encodeIfPresent(compactionAtTokens, forKey: .compactionAtTokens)
        try c.encodeIfPresent(doomLoopRecovery, forKey: .doomLoopRecovery)
    }

    private static func decodeHeaders(_ dict: [String: String]?) -> [(name: String, value: String)] {
        guard let dict else { return [] }
        return dict.map { (name: $0.key, value: $0.value) }
    }

    private static func encodeHeaders(_ headers: [(name: String, value: String)]) -> [String: String] {
        var out: [String: String] = [:]
        for h in headers { out[h.name] = h.value }
        return out
    }
}

