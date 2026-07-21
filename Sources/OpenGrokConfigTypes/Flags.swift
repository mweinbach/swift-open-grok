// Flags.swift
//
// Port of `xai-grok-config-types/src/flags.rs`.
//
// `ConfigSource` / `Resolved<T>` / `BoolFlag` / `LazinessDetectorPerModelConfig`.

import Foundation

// MARK: - ConfigSource

/// Where a resolved config value came from. Mirrors Rust `ConfigSource`.
///
/// Wire form is `snake_case` (e.g. `system_managed_config`, `managed_config`).
public enum ConfigSource: String, Sendable, Codable, Hashable, CustomStringConvertible {
    case requirement
    case cli
    case env
    case systemManagedConfig = "system_managed_config"
    case managedConfig = "managed_config"
    case userConfig = "user_config"
    case config
    case remote
    case `default`

    public var description: String { rawValue }
}

// MARK: - Resolved<T>

/// A resolved config value with its source for diagnostics.
///
/// Mirrors Rust `Resolved<T>`. `CustomStringConvertible` mirrors the Rust
/// `Display` impl (`"{value} ({source})"`) for any `T: CustomStringConvertible`.
public struct Resolved<T>: Sendable where T: Sendable {
    public let value: T
    public let source: ConfigSource

    public init(value: T, source: ConfigSource) {
        self.value = value
        self.source = source
    }
}

extension Resolved: CustomStringConvertible where T: CustomStringConvertible {
    public var description: String { "\(value) (\(source))" }
}

extension Resolved: Equatable where T: Equatable {
    public static func == (lhs: Resolved<T>, rhs: Resolved<T>) -> Bool {
        lhs.value == rhs.value && lhs.source == rhs.source
    }
}

extension Resolved: Hashable where T: Hashable {}

// MARK: - BoolFlag

/// Resolve a boolean feature flag.
///
/// Precedence (highest first):
///   requirement > cli > env > config > managed > feature_flag > default
///
/// Mirrors Rust `BoolFlag` and `resolve_bool_flag`. The builder is a fluent
/// `Option`-setter chain just like the Rust struct; `resolve()` produces a
/// `Resolved<Bool>` carrying the chosen value and its `ConfigSource`.
public struct BoolFlag {
    private var requirement: Bool?
    private var cli: Bool?
    private let envVar: String
    private var config: Bool?
    private var managed: Bool?
    private var featureFlag: Bool?
    private var defaultValue: Bool

    public init(envVar: String) {
        self.envVar = envVar
        self.requirement = nil
        self.cli = nil
        self.config = nil
        self.managed = nil
        self.featureFlag = nil
        self.defaultValue = false
    }

    public func requirement(_ v: Bool?) -> BoolFlag { var s = self; s.requirement = v; return s }
    public func cli(_ v: Bool?) -> BoolFlag { var s = self; s.cli = v; return s }
    public func config(_ v: Bool?) -> BoolFlag { var s = self; s.config = v; return s }
    public func managed(_ v: Bool?) -> BoolFlag { var s = self; s.managed = v; return s }
    public func featureFlag(_ v: Bool?) -> BoolFlag { var s = self; s.featureFlag = v; return s }
    /// Set the default value (used when no higher tier supplies a value).
    public func defaultValue(_ v: Bool) -> BoolFlag { var s = self; s.defaultValue = v; return s }

    /// Resolve the flag, carrying the source. The `environment` parameter is
    /// injectable so tests are deterministic.
    public func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Resolved<Bool> {
        if let v = requirement { return Resolved(value: v, source: .requirement) }
        if let v = cli { return Resolved(value: v, source: .cli) }
        if let v = envBool(envVar, environment: environment) { return Resolved(value: v, source: .env) }
        if let v = config { return Resolved(value: v, source: .config) }
        if let v = managed { return Resolved(value: v, source: .managedConfig) }
        if let v = featureFlag { return Resolved(value: v, source: .remote) }
        return Resolved(value: defaultValue, source: .default)
    }
}

// MARK: - LazinessDetectorPerModelConfig

/// Per-model configuration for the Layer-3 LazinessDetector.
///
/// All fields default to the disabled state. Activation is a deliberate
/// two-step opt-in: setting `enabled = true` lets the classifier fire (and
/// emit `LazinessClassifierFired` telemetry), but a nudge is only injected
/// when `maxNudgesPerSession > 0` as well. This makes observation-only
/// rollout (classify-but-don't-act) the natural intermediate state.
public struct LazinessDetectorPerModelConfig: Hashable, Sendable, Codable, Equatable {
    public var enabled: Bool
    public var maxNudgesPerSession: UInt32
    public var idleThresholdMs: UInt64?
    public var minConfidence: Float?
    public var includeReasoning: Bool?

    public init() {
        self.enabled = false
        self.maxNudgesPerSession = 0
        self.idleThresholdMs = nil
        self.minConfidence = nil
        self.includeReasoning = nil
    }

    public init(
        enabled: Bool,
        maxNudgesPerSession: UInt32,
        idleThresholdMs: UInt64?,
        minConfidence: Float?,
        includeReasoning: Bool?
    ) {
        self.enabled = enabled
        self.maxNudgesPerSession = maxNudgesPerSession
        self.idleThresholdMs = idleThresholdMs
        self.minConfidence = minConfidence
        self.includeReasoning = includeReasoning
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case maxNudgesPerSession = "max_nudges_per_session"
        case idleThresholdMs = "idle_threshold_ms"
        case minConfidence = "min_confidence"
        case includeReasoning = "include_reasoning"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        maxNudgesPerSession = try c.decodeIfPresent(UInt32.self, forKey: .maxNudgesPerSession) ?? 0
        idleThresholdMs = try c.decodeIfPresent(UInt64.self, forKey: .idleThresholdMs)
        minConfidence = try c.decodeIfPresent(Float.self, forKey: .minConfidence)
        includeReasoning = try c.decodeIfPresent(Bool.self, forKey: .includeReasoning)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(maxNudgesPerSession, forKey: .maxNudgesPerSession)
        try c.encodeIfPresent(idleThresholdMs, forKey: .idleThresholdMs)
        try c.encodeIfPresent(minConfidence, forKey: .minConfidence)
        try c.encodeIfPresent(includeReasoning, forKey: .includeReasoning)
    }
}
