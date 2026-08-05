// HookSessionLoading.swift
//
// Assembles the hook registry a live session runs with.
//
// Hooks arrive from two places and both must be honored:
//   * `[hooks.*]` blocks in the merged config document, parsed by
//     `parseHooksFromTOML`. That function existed but had no caller outside
//     tests, so config-declared hooks never reached a session.
//   * `.json` files under `$OPENGROK_HOME/hooks` and `<root>/.opengrok/hooks`,
//     found by `HookDiscovery`.
//
// Config-declared hooks are loaded first so that when a config hook and a file
// hook are byte-identical (same event, command/url, and matcher) the dedup in
// `HookDiscovery.registryFromSpecsDeduped` keeps the config one.

import Foundation
import OpenGrokConfig
import OpenGrokHooksPluginTypes

/// Everything a session needs to run hooks, plus what went wrong loading them.
public struct HookSessionLoadResult: Sendable {
    public var registry: HookRegistry
    public var errors: [HookError]
    /// Event keys present in config that this build does not know.
    public var skippedEvents: [String]

    public init(
        registry: HookRegistry = HookRegistry(),
        errors: [HookError] = [],
        skippedEvents: [String] = []
    ) {
        self.registry = registry
        self.errors = errors
        self.skippedEvents = skippedEvents
    }

    public var isEmpty: Bool { registry.isEmpty }
}

public enum HookSessionLoader {
    /// Root table key holding hook declarations in the merged config document.
    public static let configTableName = "hooks"

    /// Load config-declared and file-discovered hooks into one registry.
    ///
    /// A malformed hook block is an error in the result, never a throw: a typo
    /// in one hook must not strip the session of the others.
    public static func load(
        configDocument: TOMLValue?,
        configPath: URL,
        workspaceRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        includeFileDiscovery: Bool = true
    ) -> HookSessionLoadResult {
        var specs: [HookSpec] = []
        var errors: [HookError] = []
        var skippedEvents: [String] = []

        if let hooksValue = configHooksTable(in: configDocument) {
            let parsed = parseHooksFromTOML(
                hooksValue,
                sourceName: "config",
                sourcePath: configPath,
                sourceKind: .user,
                environment: environment
            )
            specs.append(contentsOf: parsed.specs.map { spec in
                var copy = spec
                copy.name = "config/" + spec.name
                return copy
            })
            errors.append(contentsOf: parsed.errors)
            skippedEvents.append(contentsOf: parsed.skippedEvents)
        }

        if includeFileDiscovery {
            let discovered = HookDiscovery.loadDefaults(
                workspaceRoot: workspaceRoot,
                environment: environment
            )
            specs.append(contentsOf: discovered.registry.allHooks())
            errors.append(contentsOf: discovered.errors)
            skippedEvents.append(contentsOf: discovered.skippedEvents)
        }

        return HookSessionLoadResult(
            registry: HookDiscovery.registryFromSpecsDeduped(specs),
            errors: errors,
            skippedEvents: skippedEvents
        )
    }

    /// Build the permission-pipeline gate for a session in one step.
    ///
    /// Returns `nil` when no hooks are configured, so the caller can leave the
    /// pipeline on its default fail-open no-op rather than pay for a gate that
    /// would never fire.
    public static func makeGate(
        configDocument: TOMLValue?,
        configPath: URL,
        sessionId: String,
        workspaceRoot: URL,
        cwd: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        includeFileDiscovery: Bool = true
    ) -> (gate: HookPermissionGate?, result: HookSessionLoadResult) {
        let result = load(
            configDocument: configDocument,
            configPath: configPath,
            workspaceRoot: workspaceRoot,
            environment: environment,
            includeFileDiscovery: includeFileDiscovery
        )
        guard !result.registry.isEmpty else { return (nil, result) }
        let gate = HookPermissionGate(
            dispatcher: HookDispatcher(registry: result.registry, environment: environment),
            context: HookSessionContext(
                sessionId: sessionId,
                workspaceRoot: workspaceRoot,
                cwd: cwd,
                environment: environment
            )
        )
        return (gate, result)
    }

    private static func configHooksTable(in document: TOMLValue?) -> TOMLValue? {
        guard let root = document?.table, let hooks = root[configTableName] else { return nil }
        return hooks.isTable ? hooks : nil
    }
}
