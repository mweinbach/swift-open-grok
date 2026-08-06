// TelemetryResolution.swift
//
// Open Grok — Swift port of upstream's telemetry mode resolution.
//
// Upstream reference (`~/Projects/grok-build` @ `9ed09e2a`):
//   - `TelemetryMode` + `#[default] Disabled`
//     `crates/codegen/xai-grok-telemetry/src/config.rs:10-21`
//   - `Config::resolve_telemetry_mode`
//     `crates/codegen/xai-grok-shell/src/agent/config.rs:2432-2453`
//   - managed-settings `DISABLE_TELEMETRY` pre-mutation
//     `crates/codegen/xai-grok-shell/src/config/mod.rs:1048-1055`
//   - requirements pin application
//     `crates/codegen/xai-grok-shell/src/config/mod.rs:1132-1142`
//   - sync pre-runtime path `SyncBoolFlag::resolve`
//     `crates/codegen/xai-grok-shell/src/agent/config.rs:3241-3328`
//
// The resolved default is **Disabled**. Absence of configuration is not
// consent: every layer here can only be reached by something a user or an
// admin wrote down, and the terminal fallback is off.

import Foundation
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokHTTP
import OpenGrokShared

// MARK: - Sources

/// Which authority layer decided a telemetry value.
///
/// Mirrors Rust `ConfigSource` for the subset telemetry resolution can return
/// (`agent/config.rs:2432-2453`).
public enum TelemetryConfigSource: String, Sendable, Equatable, Hashable {
    case requirement
    case env
    case config
    case remote
    case `default`
}

/// A resolved telemetry value tagged with the layer that produced it.
///
/// The source is not decoration: `/status`-style diagnostics and the
/// enforced-field list both need to say *why* telemetry is on or off, and a
/// bare `Bool` cannot distinguish "admin pinned off" from "nobody asked".
public struct ResolvedTelemetry<Value: Sendable & Equatable>: Sendable, Equatable {
    public var value: Value
    public var source: TelemetryConfigSource

    public init(_ value: Value, source: TelemetryConfigSource) {
        self.value = value
        self.source = source
    }
}

// MARK: - Env var names

public enum TelemetryEnv {
    /// Bidirectional enable/disable/select. `agent/config.rs:2436`.
    ///
    /// The `OPENGROK_` spelling is this port's primary name; the upstream
    /// `GROK_` spelling stays readable so an existing enterprise rollout that
    /// pins telemetry off keeps working after a rename.
    public static let enabledNames = ["OPENGROK_TELEMETRY_ENABLED", "GROK_TELEMETRY_ENABLED"]

    /// Force-off only, never force-on. `agent/config.rs:3315`.
    public static let disableNames = ["OPENGROK_DISABLE_TELEMETRY", "DISABLE_TELEMETRY"]

    /// External-stream master switch. `external/config.rs:46`.
    public static let externalMasterNames = ["OPENGROK_EXTERNAL_OTEL", "GROK_EXTERNAL_OTEL"]
}

/// Parse an env var as a `TelemetryMode`. `nil` when unset, empty, or
/// unrecognized. Mirrors `env_telemetry_mode`, `config.rs:86-90`.
public func envTelemetryMode(
    _ names: [String] = TelemetryEnv.enabledNames,
    environment: [String: String]
) -> TelemetryMode? {
    for name in names {
        guard let raw = environment[name] else { continue }
        if let mode = TelemetryMode.parse(raw) { return mode }
    }
    return nil
}

/// Process-env boolean truth table. Mirrors telemetry-crate `env_bool`,
/// `config.rs:203-211`: empty string is **`nil`**, not `false`.
public func telemetryEnvBool(_ raw: String?) -> Bool? {
    guard let raw else { return nil }
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "on", "enabled": return true
    case "0", "false", "no", "off", "disabled": return false
    default: return nil
    }
}

/// `managed-settings.json` `env.<NAME>` truthiness. Mirrors
/// `crates/codegen/xai-grok-workspace/src/permission/resolution.rs:927-938`:
/// any string other than `"0"` / `""` / `"false"` is true. This is
/// deliberately looser than ``telemetryEnvBool`` — an admin who wrote
/// `"DISABLE_TELEMETRY": "yes please"` meant *off*, and guessing `nil` there
/// would silently re-enable telemetry against an explicit admin instruction.
public func managedSettingsEnvFlag(_ raw: String?) -> Bool? {
    guard let raw else { return nil }
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "", "0", "false": return false
    default: return true
    }
}

// MARK: - TOML key extraction

/// Reads of the telemetry-owned config keys out of a merged TOML tree.
public enum TelemetryConfigKeys {
    /// `[features] telemetry` — bool or mode string.
    ///
    /// An unrecognized *string* resolves to `.disabled`, matching the upstream
    /// `Deserialize` impl (`config.rs:72-85`), which warns
    /// `TELEMETRY_MODE_UNKNOWN` and treats the value as disabled. A typo must
    /// never fail open.
    public static func featuresTelemetry(_ root: TOMLValue) -> TelemetryMode? {
        guard let raw = root.table?["features"]?.table?["telemetry"] else { return nil }
        switch raw {
        case .boolean(let b): return TelemetryMode(bool: b)
        case .string(let s): return TelemetryMode.parse(s) ?? .disabled
        default: return nil
        }
    }

    /// `[telemetry] <key>` boolean.
    public static func telemetryBool(_ root: TOMLValue, _ key: String) -> Bool? {
        root.table?["telemetry"]?.table?[key]?.boolValue
    }

    /// `[telemetry] <key>` string, blank normalized to `nil`.
    public static func telemetryString(_ root: TOMLValue, _ key: String) -> String? {
        guard let s = root.table?["telemetry"]?.table?[key]?.stringValue else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The `[telemetry] otel_*` disk layer. `agent/config.rs:3442-3469`.
    ///
    /// Returns `nil` when the table is absent so the caller can distinguish
    /// "no config" from "config that says nothing" — both resolve to off, but
    /// only the latter is worth reporting in diagnostics.
    public static func externalOtelFileConfig(_ root: TOMLValue) -> ExternalOtelFileConfig? {
        guard let telemetry = root.table?["telemetry"]?.table else { return nil }
        return ExternalOtelFileConfig(
            enabled: telemetry["otel_enabled"]?.boolValue,
            endpoint: telemetry["otel_endpoint"]?.stringValue,
            protocolRaw: (telemetry["otel_protocol"] ?? telemetry["otel_transport"])?.stringValue,
            metricsExporter: telemetry["otel_metrics_exporter"]?.stringValue,
            logsExporter: telemetry["otel_logs_exporter"]?.stringValue,
            logUserPrompts: telemetry["otel_log_user_prompts"]?.boolValue,
            logToolDetails: telemetry["otel_log_tool_details"]?.boolValue
        )
    }

    /// Admin pins from `requirements.toml` `[telemetry]`.
    /// `agent/config.rs:3470-3474`.
    public static func externalOtelPins(_ requirements: TOMLValue?) -> ExternalOtelRequirementPins {
        guard let telemetry = requirements?.table?["telemetry"]?.table else {
            return ExternalOtelRequirementPins()
        }
        return ExternalOtelRequirementPins(
            otelEnabled: telemetry["otel_enabled"]?.boolValue,
            logUserPrompts: telemetry["otel_log_user_prompts"]?.boolValue,
            logToolDetails: telemetry["otel_log_tool_details"]?.boolValue
        )
    }
}

extension ExternalOtelRemotePolicy {
    /// Restrictive-only remote policy. `agent/config.rs:3499-3508`.
    public init(remoteSettings: RemoteSettings?) {
        self.init(
            forceDisable: remoteSettings?.externalOtelDisabled ?? false,
            lockContentGates: remoteSettings?.externalOtelContentGatesLocked ?? false
        )
    }
}

extension TelemetryConfig {
    /// Build the sink configuration for an already-resolved mode.
    ///
    /// `mode` is a parameter rather than something re-derived here so there is
    /// exactly one place that decides whether telemetry is on. Every sink is
    /// additionally gated on its own endpoint/token being present: a mode of
    /// `.enabled` with no configured events URL still sends nothing.
    public static func resolved(
        mode: TelemetryMode,
        inputs: TelemetryResolutionInputs
    ) -> TelemetryConfig {
        let config = inputs.effectiveConfig
        let env = inputs.environment

        /// Env override; blank normalizes to `nil`, which *disables* that sink
        /// (upstream `normalize_optional_string`, `config.rs:187-196`).
        func override(_ names: [String], _ fileValue: String?) -> String? {
            for name in names {
                guard let raw = env[name] else { continue }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return fileValue
        }

        let eventsURL = override(
            ["OPENGROK_TELEMETRY_EVENTS_URL", "GROK_TELEMETRY_EVENTS_URL"],
            TelemetryConfigKeys.telemetryString(config, "events_url")
        )
        let eventsAPIKey = override(
            ["OPENGROK_TELEMETRY_EVENTS_API_KEY", "GROK_TELEMETRY_EVENTS_API_KEY"],
            TelemetryConfigKeys.telemetryString(config, "events_api_key")
        )
        let mixpanelToken = override(
            ["OPENGROK_TELEMETRY_MIXPANEL_TOKEN", "GROK_TELEMETRY_MIXPANEL_TOKEN"],
            TelemetryConfigKeys.telemetryString(config, "mixpanel_token")
        )
        let mixpanelEnabled = telemetryEnvBool(
            env["OPENGROK_TELEMETRY_MIXPANEL_ENABLED"] ?? env["GROK_TELEMETRY_MIXPANEL_ENABLED"]
        ) ?? TelemetryConfigKeys.telemetryBool(config, "mixpanel_enabled") ?? false

        return TelemetryConfig(
            eventsURL: eventsURL,
            eventsAPIKey: eventsAPIKey,
            mixpanelEnabled: mixpanelEnabled && mode.isEnabled,
            mixpanelToken: mixpanelToken,
            // Product OTEL is the *internal* pipeline; it never turns on from
            // the external stream's env vars.
            openTelemetryEnabled: TelemetryConfigKeys.telemetryBool(config, "otlp_enabled") ?? false,
            openTelemetryEndpoint: TelemetryConfigKeys.telemetryString(config, "otlp_endpoint"),
            productTelemetryEnabled: mode.isEnabled
        )
    }
}

extension TelemetryClient {
    /// Construct a client from resolved configuration, or `nil` when there is
    /// nothing to construct.
    ///
    /// Returning `nil` for the fully-default case is the point: an inert
    /// client that "would emit if asked" is one refactor away from emitting.
    /// With no config and no env, no client exists, so no call site can send.
    public static func resolved(
        inputs: TelemetryResolutionInputs,
        userID: String? = nil,
        teamID: String? = nil,
        originClient: OriginClientInfo? = nil,
        transport: (any HTTPTransport)? = nil
    ) -> TelemetryClient? {
        let resolution = TelemetryModeResolver.resolve(inputs)
        let mode = resolution.mode.value
        let external = ExternalOtelConfig.resolve(inputs: inputs)

        // Both streams off ⇒ no client at all.
        guard !mode.isDisabled || external != nil else { return nil }

        let config = TelemetryConfig.resolved(mode: mode, inputs: inputs)
        let http = transport ?? SharedHTTP.sharedTransport()
        return TelemetryClient(
            mode: mode,
            config: config,
            userID: userID,
            teamID: teamID,
            originClient: originClient,
            transport: http,
            externalOTLP: external.map { OTLPExporter(config: $0, transport: http) }
        )
    }
}

extension ExternalOtelConfig {
    /// Resolve the external stream from the same inputs as
    /// ``TelemetryModeResolver/resolve(_:)``.
    ///
    /// The external stream is deliberately **independent of `TelemetryMode`**
    /// (`external/mod.rs:20-23`): a fleet that turns product telemetry off
    /// still gets its own collector, and — more importantly here — turning
    /// product telemetry *on* does not silently start shipping to a customer
    /// collector. Both switches must be thrown separately.
    public static func resolve(inputs: TelemetryResolutionInputs) -> ExternalOtelConfig? {
        resolve(
            environment: inputs.environment,
            file: TelemetryConfigKeys.externalOtelFileConfig(inputs.effectiveConfig),
            pins: TelemetryConfigKeys.externalOtelPins(inputs.requirements),
            remote: ExternalOtelRemotePolicy(remoteSettings: inputs.remoteSettings)
        )
    }
}

// MARK: - Resolution inputs

/// Everything telemetry resolution is allowed to read.
///
/// Passing the layers in as values (rather than letting the resolver reach for
/// `ProcessInfo` or the filesystem) is what makes the default-off proof a real
/// test: a caller can construct the empty state and assert the outcome.
public struct TelemetryResolutionInputs: Sendable {
    /// Merged config layers — `ConfigLayers.effectiveConfigBase()` or the
    /// campaign-aware equivalent. `loader.rs:467-481`.
    public var effectiveConfig: TOMLValue
    /// Merged `requirements.toml` (user → system → MDM). `validation.rs:107-114`.
    public var requirements: TOMLValue?
    /// Remote settings, when a fetch has completed.
    public var remoteSettings: RemoteSettings?
    /// The `env` table from `managed-settings.json` (admin tier).
    public var managedSettingsEnv: [String: String]
    /// Process environment.
    public var environment: [String: String]

    public init(
        effectiveConfig: TOMLValue = .table(TOMLTable()),
        requirements: TOMLValue? = nil,
        remoteSettings: RemoteSettings? = nil,
        managedSettingsEnv: [String: String] = [:],
        environment: [String: String] = [:]
    ) {
        self.effectiveConfig = effectiveConfig
        self.requirements = requirements
        self.remoteSettings = remoteSettings
        self.managedSettingsEnv = managedSettingsEnv
        self.environment = environment
    }
}

/// A config field an admin layer forced, for `/status`-style disclosure.
/// Mirrors Rust `EnforcedField` (`config/mod.rs:1048-1055`).
public struct TelemetryEnforcedField: Sendable, Equatable, Hashable {
    public var path: String
    public var value: String

    public init(path: String, value: String) {
        self.path = path
        self.value = value
    }
}

/// The outcome of telemetry resolution.
public struct TelemetryResolution: Sendable, Equatable {
    public var mode: ResolvedTelemetry<TelemetryMode>
    public var enforced: [TelemetryEnforcedField]

    public init(
        mode: ResolvedTelemetry<TelemetryMode>,
        enforced: [TelemetryEnforcedField] = []
    ) {
        self.mode = mode
        self.enforced = enforced
    }

    public var isEnabled: Bool { mode.value.isEnabled }
    public var isSessionMetricsEnabled: Bool { mode.value.sessionMetricsEnabled }
    public var isDisabled: Bool { mode.value.isDisabled }
}

// MARK: - Resolver

public enum TelemetryModeResolver {
    /// Requirements pin: `[features] telemetry` accepted as string *or* bool.
    /// Mirrors `config/mod.rs:1132-1142`.
    public static func requirementsPin(_ requirements: TOMLValue?) -> TelemetryMode? {
        guard let requirements else { return nil }
        guard let raw = requirements.table?["features"]?.table?["telemetry"] else { return nil }
        switch raw {
        case .string(let s): return TelemetryMode.parse(s)
        case .boolean(let b): return TelemetryMode(bool: b)
        default: return nil
        }
    }

    /// Full resolution.
    ///
    /// Precedence, exactly as upstream `Config::resolve_telemetry_mode`
    /// (`agent/config.rs:2432-2453`), with the two pre-mutations upstream
    /// applies to `features.telemetry` before resolution runs:
    ///
    /// 1. `requirements.toml` pin (`config/mod.rs:1132-1142`)
    /// 2. `OPENGROK_TELEMETRY_ENABLED` / `GROK_TELEMETRY_ENABLED`
    /// 3. `[features] telemetry` from the merged config, after
    ///    managed-settings `DISABLE_TELEMETRY` has forced it off
    ///    (`config/mod.rs:1048-1055`)
    /// 4. remote settings (`telemetry_mode`, then `telemetry_enabled`)
    /// 5. `.disabled`
    ///
    /// Note the ordering consequence, which upstream shares: an admin
    /// requirements pin outranks `DISABLE_TELEMETRY`. That is intentional
    /// upstream (`config/mod.rs:1032` applies managed settings *before*
    /// requirements) and is preserved here rather than "improved", because a
    /// fleet that pins telemetry on for compliance reasons must not be
    /// silently opted out by a stray env var.
    public static func resolve(_ inputs: TelemetryResolutionInputs) -> TelemetryResolution {
        var enforced: [TelemetryEnforcedField] = []

        // Pre-mutation 1: managed-settings.json env.DISABLE_TELEMETRY forces
        // the config layer off. config/mod.rs:1048-1055.
        var featuresTelemetry = TelemetryConfigKeys.featuresTelemetry(inputs.effectiveConfig)
        let managedDisable = TelemetryEnv.disableNames
            .lazy
            .compactMap { managedSettingsEnvFlag(inputs.managedSettingsEnv[$0]) }
            .first { $0 }
        if managedDisable == true {
            featuresTelemetry = .disabled
            enforced.append(
                TelemetryEnforcedField(
                    path: "features.telemetry",
                    value: "false (DISABLE_TELEMETRY)"
                )
            )
        }

        // Pre-mutation 2: a requirements pin also writes through to the config
        // layer. config/mod.rs:1136-1141.
        let pin = requirementsPin(inputs.requirements)
        if let pin {
            if featuresTelemetry != pin {
                featuresTelemetry = pin
                enforced.append(
                    TelemetryEnforcedField(
                        path: "features.telemetry",
                        value: pin.description
                    )
                )
            }
            return TelemetryResolution(
                mode: ResolvedTelemetry(pin, source: .requirement),
                enforced: enforced
            )
        }

        if let envMode = envTelemetryMode(environment: inputs.environment) {
            return TelemetryResolution(
                mode: ResolvedTelemetry(envMode, source: .env),
                enforced: enforced
            )
        }

        if let featuresTelemetry {
            return TelemetryResolution(
                mode: ResolvedTelemetry(featuresTelemetry, source: .config),
                enforced: enforced
            )
        }

        if let remote = inputs.remoteSettings {
            if let raw = remote.telemetryMode, let mode = TelemetryMode.parse(raw) {
                return TelemetryResolution(
                    mode: ResolvedTelemetry(mode, source: .remote),
                    enforced: enforced
                )
            }
            if let enabled = remote.telemetryEnabled {
                return TelemetryResolution(
                    mode: ResolvedTelemetry(TelemetryMode(bool: enabled), source: .remote),
                    enforced: enforced
                )
            }
        }

        return TelemetryResolution(
            mode: ResolvedTelemetry(.disabled, source: .default),
            enforced: enforced
        )
    }

    /// Pre-runtime (synchronous) disable check, for callers that run before
    /// the config stack is built — crash-reporter init is the upstream case.
    ///
    /// Mirrors `SyncBoolFlag::resolve` + `is_telemetry_disabled_sync`
    /// (`agent/config.rs:3241-3318`). The precedence differs from
    /// ``resolve(_:)`` on purpose: here `DISABLE_TELEMETRY` outranks
    /// `GROK_TELEMETRY_ENABLED`, because the sync path has no managed-settings
    /// pre-mutation to carry the force-off for it.
    ///
    /// Returns `true` when telemetry is disabled. Absence of every layer
    /// returns `true` — the sync default is off (`agent/config.rs:3315`,
    /// `.default(false)` on an *enabled* flag).
    public static func isDisabledSync(_ inputs: TelemetryResolutionInputs) -> Bool {
        // 1. requirements.toml. agent/config.rs:3280-3285.
        if let pin = requirementsPin(inputs.requirements) {
            return pin.isDisabled
        }
        // 2. managed-settings.json env.DISABLE_TELEMETRY. agent/config.rs:3286-3290.
        for name in TelemetryEnv.disableNames
        where managedSettingsEnvFlag(inputs.managedSettingsEnv[name]) == true {
            return true
        }
        // 3. process env DISABLE_TELEMETRY force-off. agent/config.rs:3291-3295.
        for name in TelemetryEnv.disableNames
        where telemetryEnvBool(inputs.environment[name]) == true {
            return true
        }
        // 4. bidirectional GROK_TELEMETRY_ENABLED. agent/config.rs:3296-3300.
        if let envMode = envTelemetryMode(environment: inputs.environment) {
            return envMode.isDisabled
        }
        // 5. effective config. agent/config.rs:3301-3307.
        if let mode = TelemetryConfigKeys.featuresTelemetry(inputs.effectiveConfig) {
            return mode.isDisabled
        }
        // 6. default: disabled.
        return true
    }
}
