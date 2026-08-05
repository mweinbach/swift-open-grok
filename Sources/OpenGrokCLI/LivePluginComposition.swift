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
//   * A **remote** install requires explicit `--trust`. The first invocation
//     prints what would be fetched and stops.
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
        "list", "install", "uninstall", "remove", "rm", "update", "marketplace"
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
        streams: CLIStreams
    ) throws {
        let context = PluginContext(environment: environment)
        switch options.action {
        case "list":
            try listPlugins(options: options, context: context, streams: streams)
        case "install":
            try installPlugin(options: options, context: context, streams: streams)
        case "uninstall", "remove", "rm":
            try removePlugin(options: options, context: context, streams: streams)
        case "update":
            try updatePlugins(options: options, context: context, streams: streams)
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
        let registry = PluginInstallRegistry.load(from: context.location.registryURL)
        if options.json {
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
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = PluginInstallSource.parse(raw, cwd: cwd)
        let trusted = options.options["--trust"] == "true"

        // Remote code needs an explicit second look. Print what would happen and
        // stop, rather than fetching on the first invocation.
        if source.isRemote && !trusted {
            guard case .git(let url, let ref, _) = source else { return }
            streams.out("About to install plugin from remote git repo: \(url)\n")
            if let ref { streams.out("Ref: \(ref)\n") }
            streams.out(
                "Installing a plugin runs third-party code with your session's permissions.\n"
            )
            streams.out("To proceed, re-run with --trust:\n  open-grok plugin install \(raw) --trust\n")
            return
        }

        let registry = PluginInstallRegistry.load(from: context.location.registryURL)
        let identifier = source.identifier
        if registry.record(named: PluginInstallLocation.repoKey(sourceIdentifier: identifier)) != nil,
           !options.force {
            streams.out("Plugin from \(identifier) is already installed. Use --force to reinstall.\n")
            return
        }

        var record: PluginInstallRecord
        switch source {
        case .local(let path, let subdirectory):
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw CLIApplicationError.failed("Failed to install plugin: \(path) is not a directory")
            }
            let destination = context.location.directory(forSourceIdentifier: identifier)
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                // A recursive copy, not a symlink: a symlinked plugin would let
                // later edits outside the install dir change what runs.
                try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: destination)
            } catch {
                throw CLIApplicationError.failed("Failed to install plugin: \(error)")
            }
            record = PluginInstallRecord(
                repoKey: PluginInstallLocation.repoKey(sourceIdentifier: identifier),
                sourceIdentifier: identifier,
                path: path,
                pluginNames: pluginNames(in: destination, subdirectory: subdirectory)
            )

        case .git(let url, let ref, let subdirectory):
            // The pin gate runs before any fetch.
            let (hoistedRef, hoistedSHA) = PluginPin.hoistPinSlots(ref: ref, sha: nil)
            try PluginPinGate.ensurePinned(
                requireSHA: context.requireSHA,
                sha: hoistedSHA,
                plugin: raw,
                url: url
            )
            let destination = context.location.directory(forSourceIdentifier: identifier)
            try? FileManager.default.removeItem(at: destination)
            do {
                try PluginGitClient().clone(
                    url: url,
                    destination: destination,
                    ref: hoistedRef,
                    sha: hoistedSHA
                )
            } catch let error as PluginInstallError {
                try? FileManager.default.removeItem(at: destination)
                throw CLIApplicationError.failed("Failed to install plugin: \(error.description)")
            }
            record = PluginInstallRecord(
                repoKey: PluginInstallLocation.repoKey(sourceIdentifier: identifier),
                sourceIdentifier: identifier,
                url: url,
                ref: hoistedRef,
                sha: hoistedSHA ?? PluginGitClient().head(at: destination),
                pluginNames: pluginNames(in: destination, subdirectory: subdirectory)
            )
        }

        var updated = registry
        updated.repositories.removeAll { $0.repoKey == record.repoKey }
        updated.repositories.append(record)
        do {
            try updated.save(to: context.location.registryURL)
        } catch {
            throw CLIApplicationError.failed("Failed to record plugin install: \(error)")
        }

        let names = record.pluginNames.isEmpty
            ? record.repoKey
            : record.pluginNames.joined(separator: ", ")
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
        var registry = PluginInstallRegistry.load(from: context.location.registryURL)
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
        let directory = context.location.directory(forSourceIdentifier: record.sourceIdentifier)
        try? FileManager.default.removeItem(at: directory)
        registry.repositories.removeAll { $0.repoKey == record.repoKey }
        do {
            try registry.save(to: context.location.registryURL)
        } catch {
            throw CLIApplicationError.failed("Failed to update plugin registry: \(error)")
        }
        streams.out(
            "Uninstalled repo \"\(record.repoKey)\" (\(record.pluginNames.count) plugin(s))\n"
        )
    }

    // MARK: - update

    static func updatePlugins(
        options: CLIResourceOptions,
        context: PluginContext,
        streams: CLIStreams
    ) throws {
        var registry = PluginInstallRegistry.load(from: context.location.registryURL)
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
        var changed = false
        for record in targets {
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

            let directory = context.location.directory(forSourceIdentifier: record.sourceIdentifier)
            let previous = client.head(at: directory)
            do {
                try? FileManager.default.removeItem(at: directory)
                try client.clone(url: url, destination: directory, ref: record.ref, sha: nil)
            } catch let error as PluginInstallError {
                streams.out("\(record.repoKey): update failed: \(error.description)\n")
                continue
            }
            let current = client.head(at: directory)
            if previous == current {
                streams.out("\(record.repoKey): already up to date\n")
            } else {
                streams.out(
                    "\(record.repoKey): updated (\(short(previous)) -> \(short(current)))\n"
                )
                changed = true
            }
            if let index = registry.repositories.firstIndex(where: { $0.repoKey == record.repoKey }) {
                registry.repositories[index].sha = current
            }
        }
        if changed {
            try? registry.save(to: context.location.registryURL)
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
        let root = options.options["--source"].map { URL(fileURLWithPath: $0) }
            ?? context.marketplaceCacheDirectory
        let scan = scanMarketplace(root)
        if options.json {
            writeJSON(
                scan.entries.map { entry in
                    MarketplaceListEntry(
                        name: entry.name,
                        version: entry.version,
                        description: entry.description,
                        remoteURL: entry.remoteURL,
                        remoteSHA: entry.remoteSHA,
                        pinned: entry.remoteSHA.map(PluginPin.isFullCommitSHA) ?? false
                    )
                },
                streams: streams
            )
            return
        }
        guard !scan.entries.isEmpty else {
            streams.out("No marketplace entries found under \(root.path).\n")
            if context.requireSHA {
                streams.out("SHA pinning is required; unpinned entries would be refused.\n")
            }
            return
        }
        streams.out("Marketplace entries (\(scan.entries.count)):\n")
        for entry in scan.entries {
            let version = entry.version.map { " v\($0)" } ?? ""
            streams.out("  \(entry.name)\(version)\n")
            if let description = entry.description {
                streams.out("    \(description)\n")
            }
            if let url = entry.remoteURL {
                let pinned = entry.remoteSHA.map(PluginPin.isFullCommitSHA) ?? false
                // Surfacing the pin state matters: with require_sha on, an
                // unpinned entry is not installable, and the user should see
                // that here rather than at install time.
                let marker = pinned
                    ? " [pinned \(short(entry.remoteSHA))]"
                    : (context.requireSHA ? " [UNPINNED — refused by require_sha]" : " [unpinned]")
                streams.out("    \(url)\(marker)\n")
            }
        }
        if context.requireSHA {
            streams.out("\nSHA pinning is required (marketplace.require_sha).\n")
        }
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

    init(environment: [String: String]) {
        self.environment = environment
        let home = OpenGrokHomeResolver.resolve(environment: environment)
        self.location = PluginInstallLocation(grokHome: home)
        self.marketplaceCacheDirectory = home.appendingPathComponent(
            "marketplace-cache",
            isDirectory: true
        )
        // Config read failure degrades to environment-only, never to "off with
        // a config that asked for on" — the config might be the thing turning
        // pinning on, so failing open there would be the wrong default.
        let configured: Bool?
        if let layers = try? ConfigLayers.load(environment: environment),
           case .boolean(let value)? = layers.effectiveConfigBase()[
            path: ["marketplace", "require_sha"]
           ] {
            configured = value
        } else {
            configured = nil
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
