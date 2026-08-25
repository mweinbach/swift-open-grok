// LiveHooksComposition.swift
//
// Live hooks wiring: builds the `PreToolUse` gate a session installs into the
// permission pipeline, from config-declared `[hooks.*]` blocks plus the hook
// files under `$OPENGROK_HOME/hooks`, owner-approved absolute paths listed in
// `$OPENGROK_HOME/hooks-paths`, and trusted `<root>/.opengrok/hooks`.
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
import OpenGrokFileUtils
import OpenGrokHooks
import OpenGrokPluginMarketplace
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
        environment: [String: String] = ProcessInfo.processInfo.environment,
        projectTrusted: Bool? = nil
    ) -> Loaded {
        let canonicalWorkspaceRoot = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedProjectTrust = projectTrusted ?? LiveSecurityContext.resolve(
            workspaceRoot: canonicalWorkspaceRoot,
            environment: environment,
            isInteractive: false
        ).projectTrusted
        let globalSources = GlobalHookSourceDiscovery.resolve(environment: environment)
        let configLayers = globalSources.sources.isEmpty
            ? hookConfigLayersAt(
                systemDir: systemConfigDir(),
                userHome: nil,
                environment: environment
            )
            : hookConfigLayers(environment: environment)
        var specs: [HookSpec] = []
        var errors: [HookError] = []
        var skippedEvents: [String] = []
        for layer in configLayers {
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

        let discovered = HookDiscovery.loadDefaults(
            workspaceRoot: canonicalWorkspaceRoot,
            environment: environment,
            projectTrusted: resolvedProjectTrust
        )
        specs.append(contentsOf: discovered.registry.allHooks())
        errors.append(contentsOf: discovered.errors)
        skippedEvents.append(contentsOf: discovered.skippedEvents)

        if !globalSources.sources.isEmpty {
            let pluginHooks = installedPluginHooks(
                home: openGrokHome(environment: environment),
                environment: environment
            )
            specs.append(contentsOf: pluginHooks.specs)
            errors.append(contentsOf: pluginHooks.errors)
            skippedEvents.append(contentsOf: pluginHooks.skippedEvents)
        }

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
                    workspaceRoot: canonicalWorkspaceRoot,
                    cwd: cwd,
                    environment: environment
                )
            )
        return Loaded(gate: gate, result: result)
    }

    private static func installedPluginHooks(
        home: URL,
        environment: [String: String]
    ) -> HookParseResult {
        let location = PluginInstallLocation(grokHome: home)
        guard FileManager.default.fileExists(atPath: location.registryURL.path) else {
            return HookParseResult()
        }

        let registry: PluginInstallRegistry
        do {
            let contents = try GlobalHookSourceDiscovery.readOwnerDocument(at: location.registryURL)
            registry = try JSONDecoder().decode(PluginInstallRegistry.self, from: Data(contents.utf8))
            try GlobalHookSourceDiscovery.validateOwnerDirectory(at: location.installDirectory)
        } catch {
            return HookParseResult(errors: [
                .readFile(path: location.registryURL, detail: String(describing: error)),
            ])
        }

        var result = HookParseResult()
        for record in registry.repositories.sorted(by: { $0.repoKey < $1.repoKey }) where record.enabled {
            let rawInstallPath = record.installedPath
                ?? location.installDirectory.appendingPathComponent(record.repoKey).path
            let installedRoot = URL(fileURLWithPath: rawInstallPath).standardizedFileURL
            guard (rawInstallPath as NSString).isAbsolutePath,
                  isStrictDescendant(installedRoot, of: location.installDirectory)
            else {
                result.errors.append(.readFile(
                    path: installedRoot,
                    detail: "installed plugin escapes the trusted owner installation directory"
                ))
                continue
            }

            do {
                try GlobalHookSourceDiscovery.validateOwnerDirectory(at: installedRoot)
            } catch {
                result.errors.append(.readFile(path: installedRoot, detail: String(describing: error)))
                continue
            }

            let plugins: [(name: String, subdirectory: String?)]
            if record.pluginDetails.isEmpty {
                let names = record.pluginNames.isEmpty ? [record.repoKey] : record.pluginNames
                plugins = names.sorted().map { (name: $0, subdirectory: nil) }
            } else {
                plugins = record.pluginDetails
                    .map { (name: $0.key, subdirectory: $0.value.subdirectory) }
                    .sorted { $0.name < $1.name }
            }

            for plugin in plugins {
                do {
                    let pluginRoot: URL
                    if let subdirectory = plugin.subdirectory {
                        let relative = try MarketplaceRelativePath(subdirectory)
                        pluginRoot = installedRoot.appendingPathComponent(relative.asString).standardizedFileURL
                        guard isStrictDescendant(pluginRoot, of: installedRoot) else {
                            throw MarketplaceError.invalidPath(path: subdirectory, reason: .escapesRoot)
                        }
                    } else {
                        pluginRoot = installedRoot
                    }
                    try GlobalHookSourceDiscovery.validateOwnerDirectory(at: pluginRoot)
                    let parsed = try loadInstalledPluginHooks(
                        named: plugin.name,
                        root: pluginRoot,
                        home: home,
                        environment: environment
                    )
                    result.specs.append(contentsOf: parsed.specs)
                    result.errors.append(contentsOf: parsed.errors)
                    result.skippedEvents.append(contentsOf: parsed.skippedEvents)
                } catch {
                    result.errors.append(.readFile(path: installedRoot, detail: String(describing: error)))
                }
            }
        }
        return result
    }

    private static func loadInstalledPluginHooks(
        named expectedName: String,
        root: URL,
        home: URL,
        environment: [String: String]
    ) throws -> HookParseResult {
        var manifest: PluginManifest?
        var manifestPath = root.appendingPathComponent("plugin.json")
        for relative in ["plugin.json", ".opengrok-plugin/plugin.json", ".claude-plugin/plugin.json"] {
            let candidate = root.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            let contents = try GlobalHookSourceDiscovery.readOwnerDocument(at: candidate)
            let decoded = try JSONDecoder().decode(PluginManifest.self, from: Data(contents.utf8))
            try decoded.validate()
            guard decoded.name == expectedName else {
                throw MarketplaceError.invalidManifest(
                    path: candidate.path,
                    reason: "installed plugin name does not match its trusted registry entry"
                )
            }
            manifest = decoded
            manifestPath = candidate
            break
        }

        let pluginName = manifest?.name ?? expectedName
        try PluginManifest(name: pluginName).validate()
        let rootHash = String(FileChecksum.sha256Hex(root.path).prefix(8))
        let dataDirectory = home.appendingPathComponent("plugin-data/user/\(rootHash)/\(pluginName)")
        let pluginEnvironment = [
            "GROK_PLUGIN_ROOT": root.path,
            "CLAUDE_PLUGIN_ROOT": root.path,
            "GROK_PLUGIN_DATA": dataDirectory.path,
            "CLAUDE_PLUGIN_DATA": dataDirectory.path,
        ]
        var effectiveEnvironment = environment
        for (key, value) in pluginEnvironment {
            effectiveEnvironment[key] = value
        }

        let sourcePath: URL
        let contents: String
        if case .inline(let inline)? = manifest?.hooks {
            sourcePath = manifestPath
            let encoded = try JSONEncoder().encode(inline)
            guard let document = String(data: encoded, encoding: .utf8) else {
                throw MarketplaceError.invalidManifest(path: manifestPath.path, reason: "inline hooks are not valid UTF-8")
            }
            contents = document
        } else {
            let relativePath: String
            if case .path(let custom)? = manifest?.hooks {
                relativePath = try MarketplaceRelativePath(custom).asString
            } else {
                relativePath = "hooks/hooks.json"
            }
            sourcePath = root.appendingPathComponent(relativePath).standardizedFileURL
            guard isStrictDescendant(sourcePath, of: root) else {
                throw MarketplaceError.invalidPath(path: relativePath, reason: .escapesRoot)
            }
            guard FileManager.default.fileExists(atPath: sourcePath.path) else {
                return HookParseResult()
            }
            contents = try GlobalHookSourceDiscovery.readOwnerDocument(at: sourcePath)
        }

        var result = parseHookFile(contents, path: sourcePath, environment: effectiveEnvironment)
        result.specs = result.specs.map { original in
            var spec = original
            spec.name = "plugin/\(pluginName)/\(original.name)"
            spec.sourceKind = .plugin
            for (key, value) in pluginEnvironment {
                spec.extraEnvironment[key] = value
            }
            if let raw = spec.commandRaw {
                spec.command = expandHookEnvironmentSkippingRunnerVariables(
                    raw,
                    extra: spec.extraEnvironment,
                    environment: effectiveEnvironment
                )
            }
            if let raw = spec.urlRaw {
                spec.url = expandHookEnvironmentSkippingRunnerVariables(
                    raw,
                    extra: spec.extraEnvironment,
                    environment: effectiveEnvironment
                )
            }
            return spec
        }
        return result
    }

    private static func isStrictDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard candidateComponents.count > rootComponents.count else { return false }
        return zip(rootComponents, candidateComponents).allSatisfy { root, child in
            #if os(Windows)
            root.caseInsensitiveCompare(child) == .orderedSame
            #else
            root == child
            #endif
        }
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
