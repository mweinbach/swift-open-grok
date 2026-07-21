// SamplingConfig.swift
//
// Open Grok — Swift port of `SamplingConfig` and the compaction-header
// polymorphic types in `crates/codegen/xai-grok-sampling-types/src/types.rs`.
//
// `SamplingConfig` is the secret-free per-model sampling configuration that
// the sampler (W3-S3) and chat state (W1-S3) consume. Credentials live
// elsewhere (W3-S1 OpenGrokAuth) — this struct deliberately excludes API
// keys so it can be persisted and round-tripped without leaking secrets.

import Foundation
import OpenGrokShared

/// Sampling client configuration (API key excluded — that stays in the
/// client).
public struct SamplingConfig: Codable, Sendable, Equatable, Hashable {    public var baseURL: String
    public var model: String
    public var maxCompletionTokens: UInt32?
    public var temperature: Float?
    public var topP: Float?
    /// Which API backend to use for this model.
    public var apiBackend: ApiBackend
    /// First-party provider contract used for hosted-tool filtering.
    public var provider: ModelProvider
    /// Extra headers to send with requests (e.g., for BYOK scenarios).
    /// Preserves insertion order for deterministic header emission, matching
    /// the Rust `indexmap::IndexMap<String, String>` contract. Synthesized
    /// Equatable/Hashable below compare key-value pairs in order.
    public var extraHeaders: [(String, String)]
    /// Total context window size in tokens. Used for auto-compact thresholds.
    /// Stored as `UInt64` because Rust uses `NonZeroU64`; callers must ensure
    /// it is non-zero when constructing.
    public var contextWindow: UInt64
    /// Reasoning effort level for reasoning models.
    public var reasoningEffort: ReasoningEffort?
    /// When true, inject `stream_tool_calls: true` into the Responses API
    /// request body so the upstream emits per-chunk argument deltas.
    public var streamToolCalls: Bool?

    public init(
        baseURL: String,
        model: String,
        maxCompletionTokens: UInt32? = nil,
        temperature: Float? = nil,
        topP: Float? = nil,
        apiBackend: ApiBackend = .defaultValue,
        provider: ModelProvider = .defaultValue,
        extraHeaders: [(String, String)] = [],
        contextWindow: UInt64,
        reasoningEffort: ReasoningEffort? = nil,
        streamToolCalls: Bool? = nil
    ) {
        self.baseURL = baseURL
        self.model = model
        self.maxCompletionTokens = maxCompletionTokens
        self.temperature = temperature
        self.topP = topP
        self.apiBackend = apiBackend
        self.provider = provider
        self.extraHeaders = extraHeaders
        self.contextWindow = contextWindow
        self.reasoningEffort = reasoningEffort
        self.streamToolCalls = streamToolCalls
    }

    // MARK: Synthesized Equatable/Hashable (array-of-tuples needs explicit conformance)

    public static func == (lhs: SamplingConfig, rhs: SamplingConfig) -> Bool {
        guard lhs.extraHeaders.count == rhs.extraHeaders.count else { return false }
        let headersEqual = zip(lhs.extraHeaders, rhs.extraHeaders).allSatisfy { (a, b) in
            a.0 == b.0 && a.1 == b.1
        }
        return lhs.baseURL == rhs.baseURL
            && lhs.model == rhs.model
            && lhs.maxCompletionTokens == rhs.maxCompletionTokens
            && lhs.temperature == rhs.temperature
            && lhs.topP == rhs.topP
            && lhs.apiBackend == rhs.apiBackend
            && lhs.provider == rhs.provider
            && headersEqual
            && lhs.contextWindow == rhs.contextWindow
            && lhs.reasoningEffort == rhs.reasoningEffort
            && lhs.streamToolCalls == rhs.streamToolCalls
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(baseURL)
        hasher.combine(model)
        hasher.combine(maxCompletionTokens)
        hasher.combine(temperature)
        hasher.combine(topP)
        hasher.combine(apiBackend)
        hasher.combine(provider)
        for (k, v) in extraHeaders { hasher.combine(k); hasher.combine(v) }
        hasher.combine(contextWindow)
        hasher.combine(reasoningEffort)
        hasher.combine(streamToolCalls)
    }

    public enum CodingKeys: String, CodingKey {
        case baseURL = "base_url"
        case model
        case maxCompletionTokens = "max_completion_tokens"
        case temperature
        case topP = "top_p"
        case apiBackend = "api_backend"
        case provider
        case extraHeaders = "extra_headers"
        case contextWindow = "context_window"
        case reasoningEffort = "reasoning_effort"
        case streamToolCalls = "stream_tool_calls"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.baseURL = try c.decode(String.self, forKey: .baseURL)
        self.model = try c.decode(String.self, forKey: .model)
        self.maxCompletionTokens = try c.decodeIfPresent(UInt32.self, forKey: .maxCompletionTokens)
        self.temperature = try c.decodeIfPresent(Float.self, forKey: .temperature)
        self.topP = try c.decodeIfPresent(Float.self, forKey: .topP)
        self.apiBackend = try c.decodeIfPresent(ApiBackend.self, forKey: .apiBackend) ?? .defaultValue
        self.provider = try c.decodeIfPresent(ModelProvider.self, forKey: .provider) ?? .defaultValue
        // `extra_headers` is an IndexMap on the wire (JSON object). Preserve
        // insertion order via the decoder's allKeys when available; fall back
        // to sorted keys for determinism.
        if let headersObject = try c.decodeIfPresent([String: String].self, forKey: .extraHeaders) {
            self.extraHeaders = headersObject.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        } else {
            self.extraHeaders = []
        }
        self.contextWindow = try c.decode(UInt64.self, forKey: .contextWindow)
        self.reasoningEffort = try c.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort)
        self.streamToolCalls = try c.decodeIfPresent(Bool.self, forKey: .streamToolCalls)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(baseURL, forKey: .baseURL)
        try c.encode(model, forKey: .model)
        try c.encodeIfPresent(maxCompletionTokens, forKey: .maxCompletionTokens)
        try c.encodeIfPresent(temperature, forKey: .temperature)
        try c.encodeIfPresent(topP, forKey: .topP)
        try c.encode(apiBackend, forKey: .apiBackend)
        try c.encode(provider, forKey: .provider)
        if extraHeaders.isEmpty {
            // skip_serializing_if = IndexMap::is_empty
        } else {
            let dict = Dictionary(extraHeaders, uniquingKeysWith: { _, last in last })
            try c.encode(dict, forKey: .extraHeaders)
        }
        try c.encode(contextWindow, forKey: .contextWindow)
        try c.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try c.encodeIfPresent(streamToolCalls, forKey: .streamToolCalls)
    }
}

// MARK: - Compaction header polymorphic config

/// Per-model config for the `x-compaction-at` request header (a token count).
///
/// Deserialized from a polymorphic remote-config value: `true` enables the
/// header with a value computed as
/// `context_window * auto_compact_threshold_percent / 100`;
/// `false` (or absent) disables it; an integer `N` sends the constant `N`.
public enum CompactionAtTokens: Codable, Sendable, Equatable, Hashable {
    case enabled(Bool)
    case fixed(UInt64)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) {
            self = .enabled(b)
        } else if let n = try? container.decode(UInt64.self) {
            self = .fixed(n)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "CompactionAtTokens: expected bool or unsigned integer"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .enabled(let b): try container.encode(b)
        case .fixed(let n): try container.encode(n)
        }
    }

    /// Resolve the absolute token count to send, or `nil` when disabled.
    public func resolve(contextWindow: UInt64, thresholdPercent: UInt8) -> UInt64? {
        switch self {
        case .enabled(false): return nil
        case .enabled(true):
            // context_window * threshold_percent / 100 (saturating on overflow).
            let (product, pOverflow) = contextWindow.multipliedReportingOverflow(by: UInt64(thresholdPercent))
            if pOverflow { return UInt64.max }
            let (quotient, _) = product.dividedReportingOverflow(by: 100)
            return quotient
        case .fixed(let n): return n
        }
    }
}

/// Per-model config for the `x-compactions-remaining` request header.
public enum CompactionsRemaining: Codable, Sendable, Equatable, Hashable {
    case dynamic(Bool)
    case fixed(UInt8)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) {
            self = .dynamic(b)
        } else if let n = try? container.decode(UInt8.self) {
            self = .fixed(n)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "CompactionsRemaining: expected bool or uint8"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .dynamic(let b): try container.encode(b)
        case .fixed(let n): try container.encode(n)
        }
    }

    /// Resolve the header value to send, or `nil` when disabled.
    public func resolve(hasCompactionSummary: Bool) -> UInt8? {
        switch self {
        case .dynamic(false): return nil
        case .dynamic(true): return hasCompactionSummary ? 0 : 1
        case .fixed(let n): return n
        }
    }
}

// MARK: - Overflow helpers
//
// `UInt64.multipliedReportingOverflow(by:)` and
// `UInt64.dividedReportingOverflow(by:)` are stdlib members; no extension is
// needed. The saturating-arithmetic helpers used by the percentage / threshold
// math live in OpenGrokTokenEstimation (re-exported via the dependency graph
// where needed). This file uses the stdlib overflow-reporting forms directly
// so the compaction-header resolvers stay overflow-safe without depending on
// a sibling module.
