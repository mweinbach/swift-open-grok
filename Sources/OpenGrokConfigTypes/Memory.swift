// Memory.swift
//
// Port of `xai-grok-config-types/src/memory.rs`.
//
// Memory-system configuration value types: the leaf `[memory.*]` and
// `[compaction.*]` sub-config structs. The `MemoryConfig` aggregate and its
// `resolve()` loader stay in the shell (W6-S3); these leaf types are
// dependency-light and live here for dependency inversion.

import Foundation

// MARK: - MemoryIndexConfig

/// Index and chunking configuration (`[memory.index]`).
public struct MemoryIndexConfig: Hashable, Sendable, Codable, Equatable {
    /// Maximum chunk size in characters (approx tokens × 4).
    public var maxChunkChars: Int
    /// Character overlap between consecutive chunks.
    public var chunkOverlapChars: Int

    public init(maxChunkChars: Int = 1600, chunkOverlapChars: Int = 320) {
        self.maxChunkChars = maxChunkChars
        self.chunkOverlapChars = chunkOverlapChars
    }

    private enum CodingKeys: String, CodingKey {
        case maxChunkChars = "max_chunk_chars"
        case chunkOverlapChars = "chunk_overlap_chars"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxChunkChars = try c.decodeIfPresent(Int.self, forKey: .maxChunkChars) ?? 1600
        chunkOverlapChars = try c.decodeIfPresent(Int.self, forKey: .chunkOverlapChars) ?? 320
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(maxChunkChars, forKey: .maxChunkChars)
        try c.encode(chunkOverlapChars, forKey: .chunkOverlapChars)
    }
}

// MARK: - MemoryEmbeddingConfig

/// Embedding provider configuration (`[memory.embedding]`).
public struct MemoryEmbeddingConfig: Hashable, Sendable, Codable, Equatable {
    /// Provider type: `"api"`, `"local"`, or `"auto"`.
    public var provider: String
    /// Model name for the embedding API. `nil` disables vector embeddings.
    public var model: String?
    /// Embedding vector dimensions.
    public var dimensions: Int

    public init(provider: String = "api", model: String? = nil, dimensions: Int = 1024) {
        self.provider = provider
        self.model = model
        self.dimensions = dimensions
    }

    private enum CodingKeys: String, CodingKey { case provider, model, dimensions }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "api"
        model = try c.decodeIfPresent(String.self, forKey: .model)
        dimensions = try c.decodeIfPresent(Int.self, forKey: .dimensions) ?? 1024
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(provider, forKey: .provider)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encode(dimensions, forKey: .dimensions)
    }
}

// MARK: - TemporalDecayConfig

/// Temporal decay configuration for time-aware search scoring.
///
/// Controls how memory chunk scores decay over time. Chunks from "evergreen"
/// sources (`global`, `workspace`) are exempt from decay since they contain
/// curated long-term knowledge. Only `session` chunks decay, using an
/// exponential half-life formula:
///
///     decayed_score = base_score × e^(-λ × age_days)
///     where λ = ln(2) / half_life_days
public struct TemporalDecayConfig: Hashable, Sendable, Codable, Equatable {
    public var enabled: Bool
    public var halfLifeDays: Double

    public init(enabled: Bool = true, halfLifeDays: Double = 7.0) {
        self.enabled = enabled
        self.halfLifeDays = halfLifeDays
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case halfLifeDays = "half_life_days"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        halfLifeDays = try c.decodeIfPresent(Double.self, forKey: .halfLifeDays) ?? 7.0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(halfLifeDays, forKey: .halfLifeDays)
    }
}

// MARK: - MmrConfig

/// MMR (Maximal Marginal Relevance) diversity re-ranking configuration.
///
/// When enabled, re-ranks search results to penalize redundancy. Uses Jaccard
/// similarity on tokenized snippets, then greedily selects results that
/// balance relevance with diversity:
///
///     MMR(d) = λ × relevance(d) - (1-λ) × max_similarity(d, selected)
///
/// `lambda` is clamped to `[0, 1]` at parse time. Default `0.7`. Opt-in
/// (default `enabled = false`).
public struct MmrConfig: Hashable, Sendable, Codable, Equatable {
    public var enabled: Bool
    public var lambda: Double

    public init(enabled: Bool = false, lambda: Double = 0.7) {
        self.enabled = enabled
        self.lambda = max(0.0, min(1.0, lambda))
    }

    private enum CodingKeys: String, CodingKey { case enabled, lambda }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        // Clamp lambda to [0, 1] at parse time (mirrors `deserialize_clamped_unit`).
        let raw = try c.decodeIfPresent(Double.self, forKey: .lambda) ?? 0.7
        lambda = max(0.0, min(1.0, raw))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(lambda, forKey: .lambda)
    }
}

// MARK: - MemorySearchConfig

/// Hybrid search scoring configuration (`[memory.search]`).
public struct MemorySearchConfig: Hashable, Sendable, Codable, Equatable {
    /// Maximum number of search results to return.
    public var maxResults: Int
    /// Minimum score threshold for inclusion.
    public var minScore: Float
    /// Weight for vector similarity in hybrid scoring.
    public var vectorWeight: Float
    /// Weight for BM25 text similarity in hybrid scoring.
    public var textWeight: Float
    /// **Deprecated** — use `temporalDecay` instead. Per-day decay factor
    /// for recency boosting (0.0–1.0). When `temporalDecay.enabled` is true,
    /// this field is ignored.
    public var recencyDecay: Float
    /// Temporal decay configuration for time-aware scoring.
    public var temporalDecay: TemporalDecayConfig
    /// MMR diversity re-ranking configuration (opt-in).
    public var mmr: MmrConfig
    /// Source-type weight multipliers (all default to 1.0).
    public var sourceWeights: [String: Float]

    public init() {
        self.maxResults = 6
        self.minScore = 0.35
        self.vectorWeight = 0.7
        self.textWeight = 0.3
        self.recencyDecay = MemorySearchConfig.defaultRecencyDecay
        self.temporalDecay = TemporalDecayConfig()
        self.mmr = MmrConfig()
        self.sourceWeights = [
            "workspace": 1.0,
            "session": 1.0,
            "global": 1.0,
        ]
    }

    /// Default value for the legacy `recency_decay` field.
    public static let defaultRecencyDecay: Float = 0.95

    private enum CodingKeys: String, CodingKey {
        case maxResults = "max_results"
        case minScore = "min_score"
        case vectorWeight = "vector_weight"
        case textWeight = "text_weight"
        case recencyDecay = "recency_decay"
        case temporalDecay = "temporal_decay"
        case mmr
        case sourceWeights = "source_weights"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxResults = try c.decodeIfPresent(Int.self, forKey: .maxResults) ?? 6
        minScore = try c.decodeIfPresent(Float.self, forKey: .minScore) ?? 0.35
        vectorWeight = try c.decodeIfPresent(Float.self, forKey: .vectorWeight) ?? 0.7
        textWeight = try c.decodeIfPresent(Float.self, forKey: .textWeight) ?? 0.3
        recencyDecay = try c.decodeIfPresent(Float.self, forKey: .recencyDecay) ?? Self.defaultRecencyDecay
        temporalDecay = try c.decodeIfPresent(TemporalDecayConfig.self, forKey: .temporalDecay) ?? TemporalDecayConfig()
        mmr = try c.decodeIfPresent(MmrConfig.self, forKey: .mmr) ?? MmrConfig()
        sourceWeights = try c.decodeIfPresent([String: Float].self, forKey: .sourceWeights) ?? [
            "workspace": 1.0, "session": 1.0, "global": 1.0,
        ]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(maxResults, forKey: .maxResults)
        try c.encode(minScore, forKey: .minScore)
        try c.encode(vectorWeight, forKey: .vectorWeight)
        try c.encode(textWeight, forKey: .textWeight)
        try c.encode(recencyDecay, forKey: .recencyDecay)
        try c.encode(temporalDecay, forKey: .temporalDecay)
        try c.encode(mmr, forKey: .mmr)
        try c.encode(sourceWeights, forKey: .sourceWeights)
    }

    /// Resolve the effective half-life for temporal decay.
    ///
    /// Priority order:
    /// 1. `temporalDecay.enabled == true` → use `temporalDecay.halfLifeDays`
    ///    (returns `nil` if non-positive, with a warning log).
    /// 2. `temporalDecay.enabled == false` AND `recencyDecay` differs from
    ///    the default (`0.95`) → convert the legacy per-day factor to an
    ///    approximate half-life: `half_life ≈ -1.0 / log2(recencyDecay)`.
    /// 3. Otherwise → `nil` (decay fully disabled).
    public func effectiveHalfLifeDays() -> Double? {
        if temporalDecay.enabled {
            if temporalDecay.halfLifeDays <= 0 {
                return nil
            }
            return temporalDecay.halfLifeDays
        }
        let delta = abs(recencyDecay - Self.defaultRecencyDecay)
        if delta > Float.ulpOfOne && recencyDecay > 0 && recencyDecay < 1 {
            return -1.0 / log2(Double(recencyDecay))
        }
        return nil
    }
}

// MARK: - MemoryInitialInjectionConfig

/// First-turn memory injection configuration (`[memory.initial_injection]`).
public struct MemoryInitialInjectionConfig: Hashable, Sendable, Codable, Equatable {
    public var enabled: Bool
    /// Optional score threshold override for first-turn injection. `nil` =
    /// no threshold filtering.
    public var minScore: Float?

    public init(enabled: Bool = true, minScore: Float? = nil) {
        self.enabled = enabled
        self.minScore = minScore
    }

    private enum CodingKeys: String, CodingKey { case enabled
        case minScore = "min_score" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        minScore = try c.decodeIfPresent(Float.self, forKey: .minScore)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encodeIfPresent(minScore, forKey: .minScore)
    }
}

// MARK: - MemorySessionConfig

/// Session lifecycle configuration (`[memory.session]`).
public struct MemorySessionConfig: Hashable, Sendable, Codable, Equatable {
    public var saveOnEnd: Bool

    public init(saveOnEnd: Bool = true) {
        self.saveOnEnd = saveOnEnd
    }

    private enum CodingKeys: String, CodingKey {
        case saveOnEnd = "save_on_end"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        saveOnEnd = try c.decodeIfPresent(Bool.self, forKey: .saveOnEnd) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(saveOnEnd, forKey: .saveOnEnd)
    }
}

// MARK: - MemoryDreamConfig

/// autoDream consolidation configuration (`[memory.dream]`).
public struct MemoryDreamConfig: Hashable, Sendable, Codable, Equatable {
    public var enabled: Bool
    public var minHours: UInt64
    public var minSessions: UInt64
    public var staleLockSecs: UInt64
    /// `nil` = disabled (dream only at session end or via /dream).
    public var checkIntervalSecs: UInt64?

    public init(
        enabled: Bool = true,
        minHours: UInt64 = 4,
        minSessions: UInt64 = 3,
        staleLockSecs: UInt64 = 3600,
        checkIntervalSecs: UInt64? = nil
    ) {
        self.enabled = enabled
        self.minHours = minHours
        self.minSessions = minSessions
        self.staleLockSecs = staleLockSecs
        self.checkIntervalSecs = checkIntervalSecs
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case minHours = "min_hours"
        case minSessions = "min_sessions"
        case staleLockSecs = "stale_lock_secs"
        case checkIntervalSecs = "check_interval_secs"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        minHours = try c.decodeIfPresent(UInt64.self, forKey: .minHours) ?? 4
        minSessions = try c.decodeIfPresent(UInt64.self, forKey: .minSessions) ?? 3
        staleLockSecs = try c.decodeIfPresent(UInt64.self, forKey: .staleLockSecs) ?? 3600
        checkIntervalSecs = try c.decodeIfPresent(UInt64.self, forKey: .checkIntervalSecs)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(minHours, forKey: .minHours)
        try c.encode(minSessions, forKey: .minSessions)
        try c.encode(staleLockSecs, forKey: .staleLockSecs)
        try c.encodeIfPresent(checkIntervalSecs, forKey: .checkIntervalSecs)
    }
}

// MARK: - MemoryWatcherConfig

/// File watcher configuration for detecting external memory edits
/// (`[memory.watcher]`). When enabled, watches `~/.opengrok/memory/` for
/// `.md` file changes (create, modify, delete) and syncs the index on the
/// next `memory_search` call.
public struct MemoryWatcherConfig: Hashable, Sendable, Codable, Equatable {
    public var enabled: Bool
    public var staleClaimSecs: Int64

    public init(enabled: Bool = true, staleClaimSecs: Int64 = 60) {
        self.enabled = enabled
        self.staleClaimSecs = staleClaimSecs
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case staleClaimSecs = "stale_claim_secs"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        staleClaimSecs = try c.decodeIfPresent(Int64.self, forKey: .staleClaimSecs) ?? 60
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(staleClaimSecs, forKey: .staleClaimSecs)
    }
}

// MARK: - MemoryGcConfig

/// Garbage collection for orphaned workspace memory directories
/// (`[memory.gc]`).
public struct MemoryGcConfig: Hashable, Sendable, Codable, Equatable {
    public var maxAgeDays: UInt64

    public init(maxAgeDays: UInt64 = 30) {
        self.maxAgeDays = maxAgeDays
    }

    private enum CodingKeys: String, CodingKey {
        case maxAgeDays = "max_age_days"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxAgeDays = try c.decodeIfPresent(UInt64.self, forKey: .maxAgeDays) ?? 30
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(maxAgeDays, forKey: .maxAgeDays)
    }
}

// MARK: - MemoryFlushConfig

/// Pre-compaction memory flush configuration (`[compaction.memory_flush]`).
public struct MemoryFlushConfig: Hashable, Sendable, Codable, Equatable {
    public var enabled: Bool
    public var softThresholdTokens: UInt64
    public var flushModel: String?
    public var maxFlushWriteChars: Int
    public var idleTimeoutSecs: UInt64?
    /// Cosine similarity threshold for semantic dedup of flush content.
    /// `nil` falls back to the compiled-in default (0.92). Clamped to
    /// `[0, 1]` at parse time.
    public var semanticDedupThreshold: Double?

    public init(
        enabled: Bool = true,
        softThresholdTokens: UInt64 = 4000,
        flushModel: String? = nil,
        maxFlushWriteChars: Int = 8000,
        idleTimeoutSecs: UInt64? = nil,
        semanticDedupThreshold: Double? = nil
    ) {
        self.enabled = enabled
        self.softThresholdTokens = softThresholdTokens
        self.flushModel = flushModel
        self.maxFlushWriteChars = maxFlushWriteChars
        self.idleTimeoutSecs = idleTimeoutSecs
        self.semanticDedupThreshold = semanticDedupThreshold.map { max(0.0, min(1.0, $0)) }
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case softThresholdTokens = "soft_threshold_tokens"
        case flushModel = "flush_model"
        case maxFlushWriteChars = "max_flush_write_chars"
        case idleTimeoutSecs = "idle_timeout_secs"
        case semanticDedupThreshold = "semantic_dedup_threshold"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        softThresholdTokens = try c.decodeIfPresent(UInt64.self, forKey: .softThresholdTokens) ?? 4000
        flushModel = try c.decodeIfPresent(String.self, forKey: .flushModel)
        maxFlushWriteChars = try c.decodeIfPresent(Int.self, forKey: .maxFlushWriteChars) ?? 8000
        idleTimeoutSecs = try c.decodeIfPresent(UInt64.self, forKey: .idleTimeoutSecs)
        // Clamp to [0, 1] at parse time (mirrors `deserialize_clamped_unit_option`).
        if let raw = try c.decodeIfPresent(Double.self, forKey: .semanticDedupThreshold) {
            semanticDedupThreshold = max(0.0, min(1.0, raw))
        } else {
            semanticDedupThreshold = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(softThresholdTokens, forKey: .softThresholdTokens)
        try c.encodeIfPresent(flushModel, forKey: .flushModel)
        try c.encode(maxFlushWriteChars, forKey: .maxFlushWriteChars)
        try c.encodeIfPresent(idleTimeoutSecs, forKey: .idleTimeoutSecs)
        try c.encodeIfPresent(semanticDedupThreshold, forKey: .semanticDedupThreshold)
    }
}

// MARK: - PruningConfig

/// Tool-result pruning configuration (`[compaction.pruning]`).
public struct PruningConfig: Hashable, Sendable, Codable, Equatable {
    public var enabled: Bool
    public var keepLastNTurns: Int
    public var softTrimThreshold: Int
    public var softTrimHead: Int
    public var softTrimTail: Int
    public var hardClearAgeTurns: Int

    public init(
        enabled: Bool = true,
        keepLastNTurns: Int = 3,
        softTrimThreshold: Int = 4000,
        softTrimHead: Int = 1500,
        softTrimTail: Int = 1500,
        hardClearAgeTurns: Int = 10
    ) {
        self.enabled = enabled
        self.keepLastNTurns = keepLastNTurns
        self.softTrimThreshold = softTrimThreshold
        self.softTrimHead = softTrimHead
        self.softTrimTail = softTrimTail
        self.hardClearAgeTurns = hardClearAgeTurns
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case keepLastNTurns = "keep_last_n_turns"
        case softTrimThreshold = "soft_trim_threshold"
        case softTrimHead = "soft_trim_head"
        case softTrimTail = "soft_trim_tail"
        case hardClearAgeTurns = "hard_clear_age_turns"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        keepLastNTurns = try c.decodeIfPresent(Int.self, forKey: .keepLastNTurns) ?? 3
        softTrimThreshold = try c.decodeIfPresent(Int.self, forKey: .softTrimThreshold) ?? 4000
        softTrimHead = try c.decodeIfPresent(Int.self, forKey: .softTrimHead) ?? 1500
        softTrimTail = try c.decodeIfPresent(Int.self, forKey: .softTrimTail) ?? 1500
        hardClearAgeTurns = try c.decodeIfPresent(Int.self, forKey: .hardClearAgeTurns) ?? 10
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(keepLastNTurns, forKey: .keepLastNTurns)
        try c.encode(softTrimThreshold, forKey: .softTrimThreshold)
        try c.encode(softTrimHead, forKey: .softTrimHead)
        try c.encode(softTrimTail, forKey: .softTrimTail)
        try c.encode(hardClearAgeTurns, forKey: .hardClearAgeTurns)
    }
}
