// LivePluginComposition.swift
//
// Makes the `plugin` route reachable. `plugin list|install|remove|update` was
// advertised in help and parsed into `.plugin`, but the launcher had no case
// for it, so every invocation died as `unsupported(route:)`.
//
// Ports `xai-grok-shell/src/session/acp_session_impl/slash_exec.rs:247-716`
// (the `/plugins` command surface) onto the CLI's `plugin <action>` spelling.
//
// The trust model is the reason this file is careful. Installing a plugin runs
// third-party code, so:
//
//   * Every install requires explicit `--trust`, including local directories
//     and marketplace entries. Hooks and skills are executable in every case.
//   * When `marketplace.require_sha` (or `OPENGROK_MARKETPLACE_REQUIRE_SHA`) is
//     on, an unpinned remote is refused *before* anything is fetched.
//   * A pinned clone re-reads `HEAD` and aborts on mismatch.
//
// Enforcement lives in `OpenGrokPluginMarketplace/PluginTrust.swift`; this file
// must never bypass it.

import Foundation
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokPluginMarketplace

public enum LivePluginComposition {
    /// Actions this composition implements.
    public static let actions: Set<String> = [
        "list", "install", "uninstall", "remove", "rm", "update",
        "enable", "disable", "details", "validate", "tag", "marketplace"
    ]

    public static func handles(_ command: CLICommand) -> Bool {
        guard case .plugin(let options) = command else { return false }
        return actions.contains(options.action)
    }

    public static func session(
        for command: CLICommand,
        context: CLIApplicationContext
    ) async throws -> CLIApplicationSession {
        guard case .plugin(let options) = command, actions.contains(options.action) else {
            throw CLIApplicationError.unsupported(route: command.routeName)
        }
        try run(options: options, environment: context.environment, streams: context.streams)
        return CLIApplicationSession(waitForExit: {}, shutdown: {})
    }

    public static func run(
        options: CLIResourceOptions,
        environment: [String: String],
        streams: CLIStreams,
        managedSettingsPath: URL? = nil
    ) throws {
        let context = try PluginContext(
            environment: environment,
            managedSettingsPath: managedSettingsPath ?? claudeManagedSettingsPath()
        )
        switch options.action {
        case "list":
            try listPlugins(options: options, context: context, streams: streams)
        case "install":
            try installPlugin(options: options, context: context, streams: streams)
        case "uninstall", "remove", "rm":
            try removePlugin(options: options, context: context, streams: streams)
        case "update":
            try updatePlugins(options: options, context: context, streams: streams)
        case "enable", "disable":
            try setPluginEnabled(options: options, context: context, streams: streams)
        case "details":
            try describePlugin(options: options, context: context, streams: streams)
        case "validate":
            try validatePlugin(options: options, streams: streams)
        case "tag":
            try tagPlugin(options: options, context: context, streams: streams)
        case "marketplace":
            try showMarketplace(options: options, context: context, streams: streams)
        default:
            throw CLIApplicationError.unsupported(route: "plugin \(options.action)")
        }
    }

    // MARK: - list

    static func listPlugins(
        options: CLIResourceOptions,
        context: PluginContext,
        streams: CLIStreams
    ) throws {
        let registry = try PluginInstallRegistry.loadOrThrow(from: context.location.registryURL)
        if options.json {
            if options.options["--available"] == "true" {
                try listAvailablePlugins(registry: registry, context: context, streams: streams)
                return
            }
            writeJSON(
                registry.repositories.map { record in
                    PluginListEntry(
                        name: record.repoKey,
                        plugins: record.pluginNames,
                        source: record.url ?? record.path ?? record.sourceIdentifier,
                        sha: record.sha,
                        ref: record.ref,
                        enabled: record.enabled
                    )
                },
                streams: streams
            )
            return
        }
        guard !registry.repositories.isEmpty else {
            streams.out("No plugins installed.\n")
            return
        }
        streams.out("Installed plugins (\(registry.repositories.count)):\n")
        for record in registry.repositories {
            let status = record.enabled ? "" : " [disabled]"
            let names = record.pluginNames.isEmpty
                ? record.repoKey
                : record.pluginNames.joined(separator: ", ")
            streams.out("  \(names)\(status)\n")
            let source = record.url ?? record.path ?? record.sourceIdentifier
            if let sha = record.sha {
                streams.out("    \(source) @ \(String(sha.prefix(7)))\n")
            } else {
                streams.out("    \(source)\(record.ref.map { " @ \($0)" } ?? "")\n")
            }
        }
    }

    // MARK: - install

    static func installPlugin(
        options: CLIResourceOptions,
        context: PluginContext,
        streams: CLIStreams
    ) throws {
        guard let raw = options.target ?? options.options["--source"] else {
            throw CLIApplicationError.failed(
                "Usage: open-grok plugin install <source> [--trust]\n"
                    + "Provide a marketplace plugin name, a git URL, or a local directory."
            )
        }
        let trusted = options.options["--trust"] == "true"
        if let reference = parseMarketplaceReference(raw) {
            let resolved = try resolveMarketplacePlugin(reference, context: context)
            guard trusted else {
                throw explicitPluginTrustError(
                    subject: "\"\(reference.name)\" from marketplace \"\(resolved.source.name)\"",
                    argument: raw
                )
            }
            try installResolvedMarketplacePlugin(
                resolved,
                raw: raw,
                force: options.force,
                context: context,
                streams: streams
            )
            return
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = PluginInstallSource.parse(raw, cwd: cwd)
        guard trusted else {
            let subject: String
            switch source {
            case .local(let path, _): subject = "from directory \(path)"
            case .git(let url, _, _): subject = "from git repo \(url)"
            }
            throw explicitPluginTrustError(subject: subject, argument: raw)
        }

        let registry = try PluginInstallRegistry.loadOrThrow(from: context.location.registryURL)
        let identifier = source.identifier
        if registry.record(named: PluginInstallLocation.repoKey(sourceIdentifier: identifier)) != nil,
           !options.force {
            streams.out("Plugin from \(identifier) is already installed. Use --force to reinstall.\n")
            return
        }

        let record = try installPluginTransaction(
            source: source,
            raw: raw,
            context: context,
            provenance: nil
        )
        let names = record.pluginNames.joined(separator: ", ")
        streams.out("Installed \(record.pluginNames.count) plugin(s) from \(raw): \(names)\n")
        if context.requireSHA, let sha = record.sha {
            streams.out("Pinned at \(sha)\n")
        }
    }

    // MARK: - remove

    static func removePlugin(
        options: CLIResourceOptions,
        context: PluginContext,
        streams: CLIStreams
    ) throws {
        guard let name = options.target else {
            throw CLIApplicationError.failed("Usage: open-grok plugin remove <name>")
        }
        let registry = try PluginInstallRegistry.loadOrThrow(from: context.location.registryURL)
        guard let record = registry.record(named: name) else {
            throw CLIApplicationError.failed(
                "Plugin \"\(name)\" not found in install registry.\n"
                    + "Use 'open-grok plugin list' to see installed plugins."
            )
        }
        // A repo that supplies several plugins takes all of them down at once,
        // so require confirmation rather than surprising the user.
        if record.pluginNames.count > 1,
           options.options["--confirm"] != "true",
           !options.force {
            streams.out(
                "Repo \"\(record.repoKey)\" provides \(record.pluginNames.count) plugins: "
                    + "\(record.pluginNames.joined(separator: ", "))\n"
            )
            streams.out("To remove all of them:\n  open-grok plugin remove \(name) --confirm\n")
            return
        }
        let keepData = options.options["--keep-data"] == "true"
        try uninstallPluginTransaction(record, keepData: keepData, context: context)
        let suffix = keepData ? " (data preserved)" : ""
        streams.out(
            "Uninstalled \(record.pluginNames.count) plugin(s): "
                + "\(record.pluginNames.joined(separator: ", "))\(suffix)\n"
        )
    }

    // MARK: - update

    static func updatePlugins(
        options: CLIResourceOptions,
        context: PluginContext,
        streams: CLIStreams
    ) throws {
        let registry = try PluginInstallRegistry.loadOrThrow(from: context.location.registryURL)
        guard !registry.repositories.isEmpty else {
            streams.out("No installed plugins to update.\n")
            return
        }
        let targets = options.target.map { name in
            registry.repositories.filter { $0.repoKey == name || $0.pluginNames.contains(name) }
        } ?? registry.repositories
        guard !targets.isEmpty else {
            throw CLIApplicationError.failed("Plugin \"\(options.target ?? "")\" not found.")
        }

        let client = PluginGitClient()
        for record in targets {
            if let installedFrom = record.marketplace {
                do {
                    try updateMarketplacePlugin(
                        record,
                        provenance: installedFrom,
                        context: context,
                        streams: streams
                    )
                } catch {
                    streams.err("\(record.repoKey): update failed: \(error)\n")
                    throw error
                }
                continue
            }
            guard let url = record.url else {
                streams.out("\(record.repoKey): local install (already live, no update needed)\n")
                continue
            }
            // A pinned install is pinned. Re-resolving it would silently defeat
            // the pin, so report and move on.
            if let ref = record.ref, PluginPin.isPinnedRef(ref) {
                streams.out(
                    "\(record.repoKey): pinned to \(ref) "
                        + "(use 'plugin install <url>@<new-ref>' to switch)\n"
                )
                continue
            }
            if let sha = record.sha, PluginPin.isFullCommitSHA(sha), record.ref == nil {
                streams.out("\(record.repoKey): pinned to \(String(sha.prefix(7)))\n")
                continue
            }
            do {
                try PluginPinGate.ensurePinned(
                    requireSHA: context.requireSHA,
                    sha: nil,
                    plugin: record.repoKey,
                    url: url
                )
            } catch let error as PluginInstallError {
                streams.out("\(record.repoKey): update failed: \(error.description)\n")
                continue
            }

            let directory = try validatedInstalledPluginDirectory(record, context: context)
            let previous = client.head(at: directory)
            do {
                let source = PluginInstallSource.git(
                    url: url,
                    ref: record.ref,
                    subdirectory: record.subdirectory
                )
                let updated = try installPluginTransaction(
                    source: source,
                    raw: record.repoKey,
                    context: context,
                    provenance: nil,
                    preserving: record
                )
                guard updated.repoKey == record.repoKey else {
                    throw CLIApplicationError.failed("Plugin update changed its repository identity")
                }
            } catch {
                streams.err("\(record.repoKey): update failed: \(error)\n")
                throw error
            }
            let current = client.head(at: directory)
            if previous == current {
                streams.out("\(record.repoKey): already up to date\n")
            } else {
                streams.out(
                    "\(record.repoKey): updated (\(short(previous)) -> \(short(current)))\n"
                )
            }
        }
    }

    static func short(_ sha: String?) -> String {
        guard let sha, !sha.isEmpty else { return "?" }
        return String(sha.prefix(7))
    }

    // MARK: - marketplace

    static func showMarketplace(
        options: CLIResourceOptions,
        context: PluginContext,
        streams: CLIStreams
    ) throws {
        try runMarketplaceManagement(options: options, context: context, streams: streams)
    }

    // MARK: - Helpers

    /// Plugin names a checkout provides, read from its manifests.
    static func pluginNames(in root: URL, subdirectory: String?) -> [String] {
        let base = subdirectory.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
        if let result = try? loadPluginManifest(from: base),
           case .found(let manifest) = result {
            return [manifest.name]
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nameFromDirectory(base).map { [$0] } ?? []
        }
        var names: [String] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if let result = try? loadPluginManifest(from: entry),
               case .found(let manifest) = result {
                names.append(manifest.name)
            }
        }
        if names.isEmpty, let fallback = nameFromDirectory(base) { names = [fallback] }
        return names
    }

    static func writeJSON<T: Encodable>(_ value: T, streams: CLIStreams) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        if let data = try? encoder.encode(value) {
            streams.out(String(decoding: data, as: UTF8.self) + "\n")
        }
    }
}

// MARK: - Context

struct PluginContext {
    let environment: [String: String]
    let location: PluginInstallLocation
    let requireSHA: Bool
    let marketplaceCacheDirectory: URL
    let managedMarketplacePolicy: ManagedPluginMarketplacePolicy

    init(environment: [String: String], managedSettingsPath: URL?) throws {
        self.environment = environment
        let home = OpenGrokHomeResolver.resolve(environment: environment)
        self.location = PluginInstallLocation(grokHome: home)
        self.marketplaceCacheDirectory = home.appendingPathComponent(
            "marketplace-cache",
            isDirectory: true
        )
        self.managedMarketplacePolicy = try ManagedPluginMarketplacePolicy.load(
            from: managedSettingsPath
        )
        // Losing any layer can hide a managed SHA-pinning requirement. A
        // malformed owner config therefore refuses the whole plugin action;
        // falling back to environment-only would silently install unpinned code.
        let layers: ConfigLayers
        do {
            layers = try ConfigLayers.load(environment: environment)
        } catch {
            throw CLIApplicationError.failed(
                "Cannot safely resolve plugin trust policy from configuration: \(error)"
            )
        }
        let documents = [layers.systemManaged, layers.managed, layers.user]
            + [layers.userRequirements, layers.systemRequirements, layers.mdmRequirements]
                .compactMap { $0 }
        var configured: Bool?
        for document in documents {
            guard case .boolean(let value)? = document[path: ["marketplace", "require_sha"]]
            else { continue }
            // SHA pinning is tighten-only across authority tiers. A lower-tier
            // explicit `false` must never erase a managed or requirements `true`.
            configured = (configured ?? false) || value
        }
        self.requireSHA = PluginTrustPolicy.requireSHA(
            configuredValue: configured,
            environment: environment
        )
    }
}

// MARK: - JSON output shapes

struct PluginListEntry: Encodable {
    let name: String
    let plugins: [String]
    let source: String
    let sha: String?
    let ref: String?
    let enabled: Bool
}

struct MarketplaceListEntry: Encodable {
    let name: String
    let version: String?
    let description: String?
    let remoteURL: String?
    let remoteSHA: String?
    let pinned: Bool
}
