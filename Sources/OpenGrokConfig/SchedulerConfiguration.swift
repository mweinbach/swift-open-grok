// SchedulerConfiguration.swift
//
// The `[scheduler] background_loops` resolver — port of
// `resolve_scheduler_background_loops` and its tier helper
// (`xai-grok-shell/src/util/config/resolve/toolset.rs:216-264`).
//
// Precedence, encoded by `BoolFlag` exactly as upstream's builder encodes it
// (toolset.rs:253-262): requirements > env (`GROK_SCHEDULER_BACKGROUND_LOOPS`)
// > user `config.toml` `[scheduler] background_loops` > managed layers >
// remote settings > default `true`.
//
// The tiers are fed from the SEPARATE config layers, never from the merged
// authority document: in the merged document requirements overwrite the user
// value, which would silently re-order the user-vs-managed tiers this
// resolver exists to keep distinct.

import Foundation
import OpenGrokConfigTypes

/// `ENV_SCHEDULER_BACKGROUND_LOOPS` (toolset.rs:216), spelled byte-identically
/// so an environment written for the Rust binary drives this port the same way.
public let schedulerBackgroundLoopsEnvVar = "GROK_SCHEDULER_BACKGROUND_LOOPS"

/// `scheduler_background_loops_from_toml` (toolset.rs:218-220): the
/// `[scheduler] background_loops` key of one layer, or nil when the layer,
/// table, or key is absent or not a boolean.
public func schedulerBackgroundLoopsFromTOML(_ value: TOMLValue?) -> Bool? {
    value?[path: ["scheduler", "background_loops"]]?.boolValue
}

/// `resolve_scheduler_background_loops_tiers` (toolset.rs:245-264). The
/// managed tier is `managed` falling back to `systemManaged`, exactly
/// upstream's `.or_else` (toolset.rs:256-259).
public func resolveSchedulerBackgroundLoopsTiers(
    requirements: TOMLValue? = nil,
    user: TOMLValue? = nil,
    managed: TOMLValue? = nil,
    systemManaged: TOMLValue? = nil,
    remote: Bool? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Resolved<Bool> {
    BoolFlag(envVar: schedulerBackgroundLoopsEnvVar)
        .requirement(schedulerBackgroundLoopsFromTOML(requirements))
        .config(schedulerBackgroundLoopsFromTOML(user))
        .managed(
            schedulerBackgroundLoopsFromTOML(managed)
                ?? schedulerBackgroundLoopsFromTOML(systemManaged)
        )
        .featureFlag(remote)
        .defaultValue(true)
        .resolve(environment: environment)
}

/// `resolve_scheduler_background_loops` (toolset.rs:227-243): load the on-disk
/// layers and resolve. Upstream's `load_merged_requirements` merges the
/// requirements tiers before the key lookup; here the three requirement
/// layers are probed highest-authority first (MDM > system > user), which is
/// the same effective value without materializing the merge.
public func loadResolvedSchedulerBackgroundLoops(
    remote: Bool? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Resolved<Bool> {
    let layers = try? ConfigLayers.load(environment: environment)
    let requirementsValue = layers.flatMap { loaded in
        schedulerBackgroundLoopsFromTOML(loaded.mdmRequirements)
            ?? schedulerBackgroundLoopsFromTOML(loaded.systemRequirements)
            ?? schedulerBackgroundLoopsFromTOML(loaded.userRequirements)
    }
    return BoolFlag(envVar: schedulerBackgroundLoopsEnvVar)
        .requirement(requirementsValue)
        .config(schedulerBackgroundLoopsFromTOML(layers?.user))
        .managed(
            layers.flatMap { loaded in
                schedulerBackgroundLoopsFromTOML(loaded.managed)
                    ?? schedulerBackgroundLoopsFromTOML(loaded.systemManaged)
            }
        )
        .featureFlag(remote)
        .defaultValue(true)
        .resolve(environment: environment)
}
