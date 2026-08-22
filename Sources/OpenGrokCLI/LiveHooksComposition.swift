// LiveHooksComposition.swift
//
// Live hooks wiring: builds the `PreToolUse` gate a session installs into the
// permission pipeline, from config-declared `[hooks.*]` blocks plus the hook
// files under `$OPENGROK_HOME/hooks` and `<root>/.opengrok/hooks`.
//
// The pipeline's gate order is locked by PORT_PLAN.md and is enforced inside
// `PermissionPipeline.prepare`, not here:
//
//   1. plan edit gate
//   2. PreToolUse hooks — operational failures fail open but are recorded
//   3. plan-file auto-approval
//   4. permission evaluation (deny > ask > allow)
//   5. sandbox / capability validation
//   6. dispatch
//   7. history and hunk attribution, only after the result
//
// This file only supplies step 2's runner. Installing it is a one-line change
// at the pipeline construction site (see the integration notes).

import Foundation
import OpenGrokConfig
import OpenGrokHooks
import OpenGrokWorkspace

public enum LiveHooksComposition {
    /// The gate plus what loading it turned up.
    public struct Loaded: Sendable {
        /// `nil` when no hooks are configured — leave the pipeline on its
        /// default fail-open no-op rather than pay for a gate that never fires.
        public var gate: HookPermissionGate?
        public var result: HookSessionLoadResult

        public init(gate: HookPermissionGate?, result: HookSessionLoadResult) {
            self.gate = gate
            self.result = result
        }

        /// Runner to hand to `FileToolSession.makePipeline(hooks:)`. Always
        /// safe to pass: with no hooks it is the fail-open no-op.
        public var runner: any PreToolUseHookRunner {
            FailOpenPreToolUseHookRunner(inner: gate)
        }
    }

    /// Build the session's hook gate.
    ///
    /// Loading never throws. A hook file that will not parse becomes an entry
    /// in `result.errors` and the remaining hooks still load, because a typo in
    /// one hook must not silently disarm the rest.
    public static func load(
        sessionId: String,
        workspaceRoot: URL,
        cwd: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Loaded {
        let configPath = (userGrokHome(environment: environment)
            ?? workspaceRoot).appendingPathComponent("config.toml")

        var specs: [HookSpec] = []
        var errors: [HookError] = []
        var skippedEvents: [String] = []
        for layer in hookConfigLayers(environment: environment) {
            let parsed = parseHooksFromTOML(
                layer.hooks,
                sourceName: layer.sourceName,
                sourcePath: layer.path,
                sourceKind: hookSourceKind(for: layer.provenance),
                environment: environment
            )
            specs.append(contentsOf: parsed.specs.map { spec in
                var configSpec = spec
                configSpec.name = "config/" + configSpec.name
                return configSpec
            })
            errors.append(contentsOf: parsed.errors)
            skippedEvents.append(contentsOf: parsed.skippedEvents)
        }

        let discovered = HookSessionLoader.load(
            configDocument: nil,
            configPath: configPath,
            workspaceRoot: workspaceRoot,
            environment: environment
        )
        specs.append(contentsOf: discovered.registry.allHooks())
        errors.append(contentsOf: discovered.errors)
        skippedEvents.append(contentsOf: discovered.skippedEvents)
        let result = HookSessionLoadResult(
            registry: HookDiscovery.registryFromSpecsDeduped(specs),
            errors: errors,
            skippedEvents: skippedEvents
        )
        let gate: HookPermissionGate? = result.registry.isEmpty
            ? nil
            : HookPermissionGate(
                dispatcher: HookDispatcher(registry: result.registry, environment: environment),
                context: HookSessionContext(
                    sessionId: sessionId,
                    workspaceRoot: workspaceRoot,
                    cwd: cwd,
                    environment: environment
                )
            )
        return Loaded(gate: gate, result: result)
    }

    private static func hookSourceKind(for provenance: HookProvenance) -> HookSourceKind {
        switch provenance {
        case .systemManaged: return .systemManaged
        case .managed: return .managed
        case .requirements: return .requirements
        case .user: return .user
        case .file: return .file
        case .plugin: return .plugin
        case .unknown: return .unknown
        }
    }

    /// Render load diagnostics for the session log. Empty when nothing to say.
    public static func diagnostics(_ loaded: Loaded) -> [String] {
        var lines: [String] = []
        for error in loaded.result.errors {
            lines.append("hook config: \(error)")
        }
        for event in Set(loaded.result.skippedEvents).sorted() {
            lines.append("hook config: unknown event '\(event)' ignored")
        }
        return lines
    }
}
