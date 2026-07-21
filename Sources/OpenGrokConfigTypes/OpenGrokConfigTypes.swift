// OpenGrokConfigTypes.swift
//
// Open Grok — Swift port of `xai-grok-config-types`.
//
// Leaf configuration value types for the Open Grok CLI, extracted from
// `xai-grok-shell` for dependency inversion. These are the typed wire/persistence
// shapes consumed by the shell, pager, telemetry, memory, MCP, and provider
// slices.
//
// The Swift manifest inverts the Rust `xai-grok-config-types -> xai-grok-config`
// edge: `OpenGrokConfig` depends on `OpenGrokConfigTypes` (not the reverse), so
// `env_bool` and other utilities used by the leaf types are defined here in
// `OpenGrokConfigTypes` and re-exported by `OpenGrokConfig`.
//
// Module layout mirrors the Rust crate:
//   * Flags.swift         — `ConfigSource`, `Resolved`, `BoolFlag`,
//                           `LazinessDetectorPerModelConfig`, `envBool`.
//   * RemoteSettings.swift — `CampaignOverride`, `DoomLoopRecoverySettings`,
//                           `DisplayRefreshSettings`, `RemoteSettings`,
//                           `ContextualHintsRemote`, `GoalRoleModel`,
//                           `RemoteAnnouncement` (local; see note below).
//   * Permission.swift    — `PermissionConfig`, `PermissionRule`, `RuleAction`,
//                           `ToolFilter`, `PatternMode`.
//   * Memory.swift        — `MemoryIndexConfig`, `MemoryEmbeddingConfig`,
//                           `MemorySearchConfig`, `TemporalDecayConfig`,
//                           `MmrConfig`, `MemoryInitialInjectionConfig`,
//                           `MemorySessionConfig`, `MemoryDreamConfig`,
//                           `MemoryWatcherConfig`, `MemoryGcConfig`,
//                           `MemoryFlushConfig`, `PruningConfig`.
//   * Mcp.swift           — `McpServerTransportConfig`, `McpJsonOAuthBlock`,
//                           `McpSetupConfig`, `McpSetupField`,
//                           `McpSetupFieldType`, `McpSetupOption`,
//                           `McpSetupDerivedValue`, `McpPreferenceSource`,
//                           `McpServerPreferences`, `McpPreferencesFile`,
//                           `McpSetupResolution`, `McpServerConfig`,
//                           `McpOAuthConfig` (local; see note below),
//                           `RelaySyncConfig`, `McpConfig`.
//   * Pool.swift          — `PoolConfig`.
//
// Cross-crate notes:
//   * `RemoteAnnouncement` is owned by `xai-grok-announcements` (Rust) ->
//     `OpenGrokAnnouncements` (Swift, W5-S6). `OpenGrokConfigTypes` cannot
//     depend on W5-S6, so a wire-compatible `RemoteAnnouncement` is defined
//     locally here. W5-S6 may consolidate by re-exporting from
//     `OpenGrokAnnouncements` and updating `OpenGrokConfigTypes` to import it
//     once the W5-S6 edge is declared (the Swift manifest already declares
//     `w5s6 -> w0s4 + w1s5 + w2s1`, so the reverse edge would need a manifest
//     edit by W0-S1). The wire form (snake_case, all-optional fields) is
//     stable and matches the Rust contract.
//   * `McpOAuthConfig` is owned by `xai-grok-mcp` (Rust) -> `OpenGrokMCP`
//     (Swift, W5-S4). Same situation: defined locally here, wire-compatible,
//     to be consolidated by W5-S4 with a manifest edge edit.
//   * `DisplayRefreshSettings` is also defined in `OpenGrokShared` (W0-S4)
//     because `UiConfig` references it and W0-S4 has no dependencies. The
//     wire form here matches that definition exactly. The W0-S4 local copy
//     remains the `UiConfig`-facing one; this copy is the
//     `RemoteSettings.display_refresh`-facing one. A future consolidation
//     wave may unify them under `OpenGrokConfigTypes` and have
//     `OpenGrokShared` re-export.

import Foundation

// MARK: - envBool (utility; defined here so leaf types don't depend on OpenGrokConfig)

/// Parse an env var as a boolean. `nil` if unset or unrecognized.
///
/// Mirrors `xai_grok_config::env_bool`. Accepted truthy values (case-insensitive,
/// trimmed): `1`, `true`, `yes`, `on`, `enabled`. Accepted falsy values: `0`,
/// `false`, `no`, `off`, `disabled`. An empty string is treated as unset (`nil`).
/// Any other value is unrecognized (`nil`).
///
/// `environment` defaults to the live process environment but is injectable
/// so tests are deterministic without mutating process-global state.
public func envBool(
    _ name: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Bool? {
    guard let value = environment[name] else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    switch trimmed.lowercased() {
    case "": return nil
    case "1", "true", "yes", "on", "enabled": return true
    case "0", "false", "no", "off", "disabled": return false
    default: return nil
    }
}
