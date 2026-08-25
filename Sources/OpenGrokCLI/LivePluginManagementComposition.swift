// LivePluginManagementComposition.swift
//
// Rust reference: `xai-grok-pager/src/plugin_cmd.rs:86-195,241-260,424-434`
// and `xai-grok-plugin-marketplace/src/installer.rs:201-438` at 00e176c8.
// Registry writes use the canonical agent install registry, never the older
// marketplace-only registry that occupied the same `registry.json` path.

import Dispatch
import Foundation
import OpenGrokConfig
import OpenGrokFileUtils
import OpenGrokPluginMarketplace

extension PluginContext {
    var home: URL { location.installDirectory.deletingLastPathComponent() }
    var configurationURL: URL { home.appendingPathComponent("config.toml") }
}

struct ResolvedMarketplacePlugin {
    var source: MarketplaceSource
    var root: URL
    var entry: MarketplaceEntry
}

/// Admin authority comes only from the canonical Claude managed-settings path;
/// user/project TOML and environment overrides cannot select or relax it.
struct ManagedPluginMarketplacePolicy: Sendable {
    let allowedURLs: [String]
    let sourcePath: URL?

    var isRestricted: Bool { !allowedURLs.isEmpty }

    static func load(from path: URL?) throws -> ManagedPluginMarketplacePolicy {
        guard let path else { return ManagedPluginMarketplacePolicy(allowedURLs: [], sourcePath: nil) }
        if try path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw CLIApplicationError.failed("Managed marketplace policy must not be a symbolic link")
        }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: Data(contentsOf: path))
        } catch {
            throw CLIApplicationError.failed("Cannot safely read managed marketplace policy: \(error)")
        }
        guard let object = value as? [String: Any] else {
            throw CLIApplicationError.failed("Managed marketplace policy must be a JSON object")
        }
        guard let raw = object["strictKnownMarketplaces"] else {
            return ManagedPluginMarketplacePolicy(allowedURLs: [], sourcePath: path)
        }
        guard let entries = raw as? [[String: Any]] else {
            throw CLIApplicationError.failed("strictKnownMarketplaces must be an array of objects")
        }
        var urls: [String] = []
        for entry in entries {
            guard let source = entry["source"] as? String else {
                throw CLIApplicationError.failed("Managed marketplace entry is missing its source")
            }
            guard source == "git" else { continue }
            guard let url = entry["url"] as? String,
                  !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIApplicationError.failed("Managed git marketplace entry is missing its URL")
            }
            urls.append(url)
        }
        return ManagedPluginMarketplacePolicy(allowedURLs: urls, sourcePath: path)
    }

    func allows(_ url: String) -> Bool {
        guard isRestricted else { return true }
        let candidate = normalize(url)
        return allowedURLs.contains { normalize($0) == candidate }
    }

    var blockReason: String {
        if let sourcePath {
            return "source not in strictKnownMarketplaces (\(sourcePath.path))"
        }
        return "source not in strictKnownMarketplaces"
    }

    private func normalize(_ url: String) -> String {
        var normalized = url.lowercased()
        if normalized.hasSuffix(".git") { normalized.removeLast(4) }
        return normalized
    }
}

extension LivePluginComposition {
    static func explicitPluginTrustError(
        subject: String,
        argument: String
    ) -> CLIApplicationError {
        .failed(
            "Installing \(subject) requires confirmation.\n"
                + "Plugins can run hooks, MCP servers, and skills on your machine, "
                + "so installation needs explicit trust.\n\n"
                + "To proceed, re-run with --trust:\n"
                + "  open-grok plugin install \(argument) --trust"
        )
    }

    // MARK: - Transactional installation

    static func installPluginTransaction(
        source: PluginInstallSource,
        raw: String,
        context: PluginContext,
        provenance: MarketplaceProvenance?,
        preserving previous: PluginInstallRecord? = nil
    ) throws -> PluginInstallRecord {
        var registry = try PluginInstallRegistry.loadOrThrow(from: context.location.registryURL)
        let key = previous?.repoKey
            ?? PluginInstallLocation.repoKey(sourceIdentifier: source.identifier)
        let nonce = UUID().uuidString
        let stagingURL = context.location.installDirectory
            .appendingPathComponent(".staging-\(key)-\(nonce)", isDirectory: true)
        let backupURL = context.location.installDirectory
            .appendingPathComponent(".backup-\(key)-\(nonce)", isDirectory: true)

        let pin: (ref: String?, sha: String?)
        switch source {
        case .local:
            pin = (nil, nil)
        case .git(let url, let ref, _):
            pin = PluginPin.hoistPinSlots(ref: ref, sha: nil)
            try PluginPinGate.ensurePinned(
                requireSHA: context.requireSHA,
                sha: pin.sha,
                plugin: raw,
                url: url
            )
        }

        try FileManager.default.createDirectory(
            at: context.location.installDirectory,
            withIntermediateDirectories: true
        )
        let finalURL = try safeInstalledPluginURL(key: key, context: context)

        let discovered: [String: PluginRepositoryPlugin]
        do {
            switch source {
            case .local(let path, let subdirectory):
                let sourceURL = URL(fileURLWithPath: path, isDirectory: true)
                try copyPluginSnapshot(from: sourceURL, to: stagingURL)
                discovered = try discoverValidatedPlugins(
                    in: stagingURL,
                    subdirectory: subdirectory
                )
            case .git(let url, _, let subdirectory):
                try PluginGitClient().clone(
                    url: url,
                    destination: stagingURL,
                    ref: pin.ref,
                    sha: pin.sha
                )
                try rejectEscapingPluginSymlinks(in: stagingURL)
                discovered = try discoverValidatedPlugins(
                    in: stagingURL,
                    subdirectory: subdirectory
                )
            }
        } catch {
            try? removePluginPathIfPresent(stagingURL)
            throw CLIApplicationError.failed("Failed to install plugin: \(error)")
        }

        let prior = previous ?? registry.repositories.first { $0.repoKey == key }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let client = PluginGitClient()
        let record: PluginInstallRecord
        switch source {
        case .local(let path, let subdirectory):
            record = PluginInstallRecord(
                repoKey: key,
                sourceIdentifier: source.identifier,
                path: path,
                pluginNames: discovered.keys.sorted(),
                enabled: prior?.enabled ?? true,
                installedPath: finalURL.path,
                installedAt: prior?.installedAt,
                updatedAt: timestamp,
                subdirectory: subdirectory,
                pluginDetails: mergePluginDetails(discovered, previous: prior),
                marketplace: provenance,
                additionalFields: prior?.additionalFields ?? [:],
                additionalKindFields: prior?.additionalKindFields ?? [:],
                additionalMarketplaceFields: prior?.additionalMarketplaceFields ?? [:]
            )
        case .git(let url, _, let subdirectory):
            record = PluginInstallRecord(
                repoKey: key,
                sourceIdentifier: source.identifier,
                url: url,
                ref: pin.ref,
                sha: pin.sha,
                pluginNames: discovered.keys.sorted(),
                enabled: prior?.enabled ?? true,
                installedPath: finalURL.path,
                installedAt: prior?.installedAt,
                updatedAt: timestamp,
                commit: client.head(at: stagingURL),
                subdirectory: subdirectory,
                pluginDetails: mergePluginDetails(discovered, previous: prior),
                marketplace: provenance,
                additionalFields: prior?.additionalFields ?? [:],
                additionalKindFields: prior?.additionalKindFields ?? [:],
                additionalMarketplaceFields: prior?.additionalMarketplaceFields ?? [:]
            )
        }

        let registrySnapshot = try pluginFileSnapshot(at: context.location.registryURL)
        let hadExistingInstall = FileManager.default.fileExists(atPath: finalURL.path)
        if hadExistingInstall {
            do {
                try FileManager.default.moveItem(at: finalURL, to: backupURL)
            } catch {
                try? removePluginPathIfPresent(stagingURL)
                throw CLIApplicationError.failed("Failed to back up plugin installation: \(error)")
            }
        }

        do {
            try FileManager.default.moveItem(at: stagingURL, to: finalURL)
        } catch {
            try? removePluginPathIfPresent(stagingURL)
            if hadExistingInstall {
                do {
                    try FileManager.default.moveItem(at: backupURL, to: finalURL)
                } catch let restoreError {
                    throw CLIApplicationError.failed(
                        "Failed to install staged plugin and restore its backup: \(restoreError)"
                    )
                }
            }
            throw CLIApplicationError.failed("Failed to install staged plugin: \(error)")
        }

        registry.repositories.removeAll { $0.repoKey == key }
        registry.repositories.append(record)
        registry.repositories.sort { $0.repoKey < $1.repoKey }
        do {
            try registry.save(to: context.location.registryURL, environment: context.environment)
        } catch {
            try rollbackPluginInstallation(
                finalURL: finalURL,
                backupURL: hadExistingInstall ? backupURL : nil,
                registryURL: context.location.registryURL,
                registrySnapshot: registrySnapshot,
                originalError: error
            )
            throw CLIApplicationError.failed("Failed to record plugin install: \(error)")
        }

        if hadExistingInstall {
            try? removePluginPathIfPresent(backupURL)
        }
        return record
    }

    private static func mergePluginDetails(
        _ discovered: [String: PluginRepositoryPlugin],
        previous: PluginInstallRecord?
    ) -> [String: PluginRepositoryPlugin] {
        var result = discovered
        for (name, detail) in discovered {
            var updated = detail
            updated.additionalFields = previous?.pluginDetails[name]?.additionalFields ?? [:]
            result[name] = updated
        }
        return result
    }

    private static func rollbackPluginInstallation(
        finalURL: URL,
        backupURL: URL?,
        registryURL: URL,
        registrySnapshot: Data?,
        originalError: Error
    ) throws {
        do {
            try removePluginPathIfPresent(finalURL)
            if let backupURL {
                try FileManager.default.moveItem(at: backupURL, to: finalURL)
            }
            try restorePluginFileSnapshot(registrySnapshot, at: registryURL)
        } catch {
            throw CLIApplicationError.failed(
                "Registry save failed (\(originalError)); plugin rollback also failed (\(error)). "
                    + "Backup: \(backupURL?.path ?? "none")"
            )
        }
    }

    static func uninstallPluginTransaction(
        _ record: PluginInstallRecord,
        keepData: Bool,
        context: PluginContext
    ) throws {
        var registry = try PluginInstallRegistry.loadOrThrow(from: context.location.registryURL)
        let finalURL = try validatedInstalledPluginDirectory(record, context: context)
        let backupURL = context.location.installDirectory
            .appendingPathComponent(".backup-remove-\(record.repoKey)-\(UUID().uuidString)")
        let snapshot = try pluginFileSnapshot(at: context.location.registryURL)

        guard FileManager.default.fileExists(atPath: finalURL.path) else {
            throw CLIApplicationError.failed("Installed plugin directory is missing: \(finalURL.path)")
        }
        try FileManager.default.moveItem(at: finalURL, to: backupURL)
        registry.repositories.removeAll { $0.repoKey == record.repoKey }
        do {
            try registry.save(to: context.location.registryURL, environment: context.environment)
        } catch {
            do {
                try FileManager.default.moveItem(at: backupURL, to: finalURL)
                try restorePluginFileSnapshot(snapshot, at: context.location.registryURL)
            } catch let rollbackError {
                throw CLIApplicationError.failed(
                    "Failed to update plugin registry (\(error)); "
                        + "restoring plugin also failed (\(rollbackError))"
                )
            }
            throw CLIApplicationError.failed("Failed to update plugin registry: \(error)")
        }

        try removePluginPathIfPresent(backupURL)
        if !keepData {
            try removePluginPersistentData(record, installedRoot: finalURL, context: context)
        }
    }

    private static func removePluginPersistentData(
        _ record: PluginInstallRecord,
        installedRoot: URL,
        context: PluginContext
    ) throws {
        let home = URL(fileURLWithPath: context.environment["HOME"] ?? NSHomeDirectory())
            .standardizedFileURL.resolvingSymlinksInPath()
        let components = installedRoot.standardizedFileURL
            .resolvingSymlinksInPath().pathComponents
        let scope = components.starts(with: home.pathComponents) ? "user" : "config"
        let base = context.home.appendingPathComponent("plugin-data", isDirectory: true)
        for name in record.pluginNames {
            try PluginManifest(name: name).validate()
            let details = record.pluginDetails[name]
            let pluginRoot: URL
            if let subdirectory = details?.subdirectory {
                let normalized = try MarketplaceRelativePath(subdirectory).value
                pluginRoot = installedRoot.appendingPathComponent(normalized)
            } else {
                pluginRoot = installedRoot
            }
            let digest = String(FileChecksum.sha256Hex(pluginRoot.standardizedFileURL.path).prefix(8))
            let data = base
                .appendingPathComponent(scope, isDirectory: true)
                .appendingPathComponent(digest, isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
            try removePluginPathIfPresent(data)
        }
    }

    // MARK: - Source and plugin path validation

    private static func safeInstalledPluginURL(
        key: String,
        context: PluginContext
    ) throws -> URL {
        let relative = try MarketplaceRelativePath(key)
        guard !relative.value.contains("/") else {
            throw CLIApplicationError.failed("Invalid installed plugin repository key: \(key)")
        }
        let installRoot = context.location.installDirectory
        if let rootValues = try? installRoot.resourceValues(forKeys: [.isSymbolicLinkKey]),
           rootValues.isSymbolicLink == true {
            throw CLIApplicationError.failed("Managed plugin directory must not be a symbolic link")
        }
        let canonicalRoot = installRoot.standardizedFileURL.resolvingSymlinksInPath()
        let lexical = canonicalRoot.appendingPathComponent(relative.value).standardizedFileURL
        if let values = try? lexical.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            throw CLIApplicationError.failed("Installed plugin path must not be a symbolic link")
        }
        let resolved = try relative.resolve(under: canonicalRoot)
        guard resolved.standardizedFileURL.path == lexical.path else {
            throw CLIApplicationError.failed("Installed plugin path escapes the managed directory")
        }
        return resolved
    }

    static func validatedInstalledPluginDirectory(
        _ record: PluginInstallRecord,
        context: PluginContext
    ) throws -> URL {
        let expected = try safeInstalledPluginURL(key: record.repoKey, context: context)
        if let claimed = record.installedPath {
            let actual = URL(fileURLWithPath: claimed).standardizedFileURL
            guard actual.path == expected.standardizedFileURL.path else {
                throw CLIApplicationError.failed(
                    "Plugin installation path escapes the managed directory: \(claimed)"
                )
            }
        }
        if let values = try? expected.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            throw CLIApplicationError.failed("Installed plugin path must not be a symbolic link")
        }
        return expected
    }

    private static func copyPluginSnapshot(from source: URL, to destination: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CLIApplicationError.failed("\(source.path) is not a directory")
        }
        let sourceValues = try source.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard sourceValues.isSymbolicLink != true else {
            throw CLIApplicationError.failed("Plugin source directory must not be a symbolic link")
        }
        let sourceComponents = source.standardizedFileURL.pathComponents
        let destinationComponents = destination.standardizedFileURL.pathComponents
        guard !destinationComponents.starts(with: sourceComponents) else {
            throw CLIApplicationError.failed("Plugin staging directory cannot live inside its source")
        }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var pendingDirectories = [source]
        while let directory = pendingDirectories.popLast() {
            let entries = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                ],
                options: []
            )
            for entry in entries {
                let values = try entry.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
                )
                if values.isSymbolicLink == true {
                    // Owning traversal avoids DirectoryEnumerator.skipDescendants
                    // suppressing an unrelated plugin-manifest sibling.
                    continue
                }
                let relativeComponents = entry.standardizedFileURL.pathComponents
                    .dropFirst(sourceComponents.count)
                guard !relativeComponents.isEmpty,
                      relativeComponents.allSatisfy({ $0 != "." && $0 != ".." }) else {
                    throw CLIApplicationError.failed("Plugin source contains an unsafe relative path")
                }
                let target = relativeComponents.reduce(destination) { partial, component in
                    partial.appendingPathComponent(component)
                }
                if values.isDirectory == true {
                    try FileManager.default.createDirectory(
                        at: target,
                        withIntermediateDirectories: true
                    )
                    pendingDirectories.append(entry)
                } else if values.isRegularFile == true {
                    try FileManager.default.createDirectory(
                        at: target.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try FileManager.default.copyItem(at: entry, to: target)
                }
            }
        }
    }

    private static func rejectEscapingPluginSymlinks(in root: URL) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: nil
        ) else {
            throw CLIApplicationError.failed("Unable to inspect staged plugin")
        }
        for case let entry as URL in enumerator {
            if try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                try FileManager.default.removeItem(at: entry)
                enumerator.skipDescendants()
            }
        }
    }

    private static func discoverValidatedPlugins(
        in root: URL,
        subdirectory: String?
    ) throws -> [String: PluginRepositoryPlugin] {
        let selected: URL
        let selectedSubdirectory: String?
        if let subdirectory {
            let safe = try MarketplaceRelativePath(subdirectory)
            selected = try safe.resolve(under: root)
            selectedSubdirectory = safe.value
        } else {
            selected = root
            selectedSubdirectory = nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: selected.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CLIApplicationError.failed("Plugin subdirectory does not exist: \(selected.path)")
        }

        if case .found(let manifest) = try loadPluginManifest(from: selected) {
            return [manifest.name: PluginRepositoryPlugin(
                subdirectory: selectedSubdirectory,
                version: manifest.version
            )]
        }
        if hasConventionPluginComponents(in: selected), let name = nameFromDirectory(selected) {
            try PluginManifest(name: name).validate()
            return [name: PluginRepositoryPlugin(subdirectory: selectedSubdirectory)]
        }

        let children = try FileManager.default.contentsOfDirectory(
            at: selected,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var plugins: [String: PluginRepositoryPlugin] = [:]
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let relative = selectedSubdirectory.map { "\($0)/\(child.lastPathComponent)" }
                ?? child.lastPathComponent
            switch try loadPluginManifest(from: child) {
            case .found(let manifest):
                plugins[manifest.name] = PluginRepositoryPlugin(
                    subdirectory: relative,
                    version: manifest.version
                )
            case .notFound:
                if hasConventionPluginComponents(in: child), let name = nameFromDirectory(child) {
                    try PluginManifest(name: name).validate()
                    plugins[name] = PluginRepositoryPlugin(subdirectory: relative)
                }
            }
        }
        guard !plugins.isEmpty else {
            throw CLIApplicationError.failed(
                "No plugin manifests or standard plugin components found in \(selected.path)"
            )
        }
        return plugins
    }

    private static func hasConventionPluginComponents(in root: URL) -> Bool {
        ["skills", "commands", "agents", "hooks/hooks.json", ".mcp.json", ".lsp.json"]
            .contains { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
    }

    private static func pluginFileSnapshot(at url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain,
               error.code == NSFileReadNoSuchFileError {
                return nil
            }
            throw error
        }
    }

    private static func restorePluginFileSnapshot(_ snapshot: Data?, at url: URL) throws {
        if let snapshot {
            try snapshot.write(to: url, options: .atomic)
        } else {
            try removePluginPathIfPresent(url)
        }
    }

    private static func removePluginPathIfPresent(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain,
               error.code == NSFileNoSuchFileError {
                return
            }
            throw error
        }
    }

    // MARK: - Enable, disable, details, validate, tag

    static func setPluginEnabled(
        options: CLIResourceOptions,
        context: PluginContext,
        streams: CLIStreams
    ) throws {
        guard let name = options.target else {
            throw CLIApplicationError.failed("Usage: open-grok plugin \(options.action) <name>")
        }
        var registry = try PluginInstallRegistry.loadOrThrow(from: context.location.registryURL)
        guard let index = registry.repositories.firstIndex(where: {
            $0.repoKey == name || $0.pluginNames.contains(name)
        }) else {
            throw CLIApplicationError.failed(
                "Plugin \"\(name)\" not found.\nRun `open-grok plugin list` to see installed plugins."
            )
        }

        let enabling = options.action == "enable"
        let snapshot = try pluginFileSnapshot(at: context.configurationURL)
        var document = try loadTomlFile(at: context.configurationURL, environment: context.environment)
        guard var root = document.table else {
            throw CLIApplicationError.failed("config.toml root is not a table")
        }
        let existing = root["plugins"]
        guard existing == nil || existing?.table != nil else {
            throw CLIApplicationError.failed("[plugins] is not a table")
        }
        var plugins = existing?.table ?? TOMLTable()
        let enableValues = try pluginStringArray(plugins["enabled"], field: "[plugins].enabled")
        let disableValues = try pluginStringArray(plugins["disabled"], field: "[plugins].disabled")
        var enabled = enableValues.filter { $0 != name }
        var disabled = disableValues.filter { $0 != name }
        if enabling {
            enabled.append(name)
        } else {
            disabled.append(name)
        }
        plugins.insert(.array(enabled.map(TOMLValue.string)), forKey: "enabled")
        plugins.insert(.array(disabled.map(TOMLValue.string)), forKey: "disabled")
        root.insert(.table(plugins), forKey: "plugins")
        document = .table(root)
        try writeConfigFile(document, to: context.configurationURL)

        registry.repositories[index].enabled = enabling
        do {
            try registry.save(to: context.location.registryURL, environment: context.environment)
        } catch {
            try restorePluginFileSnapshot(snapshot, at: context.configurationURL)
            throw CLIApplicationError.failed("Failed to \(options.action) plugin: \(error)")
        }
        streams.out("\(enabling ? "Enabled" : "Disabled") plugin: \(name)\n")
    }

    private static func pluginStringArray(_ value: TOMLValue?, field: String) throws -> [String] {
        guard let value else { return [] }
        guard let array = value.arrayValue else {
            throw CLIApplicationError.failed("\(field) is not an array")
        }
        return try array.map { value in
            guard let string = value.stringValue else {
                throw CLIApplicationError.failed("\(field) must contain only strings")
            }
            return string
        }
    }

    static func describePlugin(
        options: CLIResourceOptions,
        context: PluginContext,
        streams: CLIStreams
    ) throws {
        guard let name = options.target else {
            throw CLIApplicationError.failed("Usage: open-grok plugin details <name>")
        }
        let registry = try PluginInstallRegistry.loadOrThrow(from: context.location.registryURL)
        guard let record = registry.record(named: name) else {
            throw CLIApplicationError.failed("Plugin \"\(name)\" not found.")
        }
        let root = try validatedInstalledPluginDirectory(record, context: context)
        streams.out("\(record.repoKey)\n")
        streams.out("  path: \(root.path)\n")
        if let url = record.url {
            streams.out("  kind: git: \(url)\n")
        } else {
            streams.out("  kind: local: \(record.path ?? record.sourceIdentifier)\n")
        }
        if let marketplace = record.marketplace {
            streams.out("  source: \(marketplace.sourceDisplayName)\n")
        }
        streams.out("  installed: \(record.installedAt)\n")
        streams.out("  updated: \(record.updatedAt)\n")
        streams.out("  plugins (\(record.pluginNames.count)):\n")
        for plugin in record.pluginNames.sorted() {
            let details = record.pluginDetails[plugin]
            let version = details?.version.map { " v\($0)" } ?? ""
            let subdirectory = details?.subdirectory.map { " (subdir: \($0))" } ?? ""
            streams.out("    \(plugin)\(version)\(subdirectory)\n")
        }
        let selected = record.pluginDetails[name]?.subdirectory.map {
            root.appendingPathComponent($0)
        } ?? root
        if case .found(let manifest) = try loadPluginManifest(from: selected) {
            if let description = manifest.description {
                streams.out("  description: \(description)\n")
            }
            printPluginComponentSummary(manifest, root: selected, streams: streams)
        }
    }

    static func validatePlugin(options: CLIResourceOptions, streams: CLIStreams) throws {
        let path = options.target ?? "."
        let root = URL(fileURLWithPath: path, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CLIApplicationError.failed("Not a directory: \(path)")
        }
        switch try loadPluginManifest(from: root) {
        case .found(let manifest):
            try manifest.validate()
            streams.out("Plugin manifest is valid.\n")
            streams.out("  name: \(manifest.name)\n")
            if let version = manifest.version { streams.out("  version: \(version)\n") }
            if let description = manifest.description {
                streams.out("  description: \(description)\n")
            }
            printPluginComponentSummary(manifest, root: root, streams: streams)
        case .notFound:
            streams.out(
                "No plugin.json found. Grok discovers skills, agents, and hooks "
                    + "automatically from standard directories. A manifest is only needed "
                    + "for custom paths or metadata.\n"
            )
        }
    }

    private static func printPluginComponentSummary(
        _ manifest: PluginManifest,
        root: URL,
        streams: CLIStreams
    ) {
        let skills = manifest.componentDirectories(manifest.skills, root: root, defaultName: "skills")
        let commands = manifest.componentDirectories(
            manifest.commands,
            root: root,
            defaultName: "commands"
        )
        let agents = manifest.componentDirectories(manifest.agents, root: root, defaultName: "agents")
        let hooks = manifest.componentFile(manifest.hooks, root: root, defaultName: "hooks/hooks.json")
            != nil || isInlinePluginComponent(manifest.hooks)
        let mcp = manifest.componentFile(manifest.mcpServers, root: root, defaultName: ".mcp.json")
            != nil || isInlinePluginComponent(manifest.mcpServers)
        let lsp = manifest.componentFile(manifest.lspServers, root: root, defaultName: ".lsp.json")
            != nil || isInlinePluginComponent(manifest.lspServers)
        streams.out(
            "  components: \(skills.count) skill dir(s), \(commands.count) command dir(s), "
                + "\(agents.count) agent dir(s)"
                + (hooks ? ", hooks" : "")
                + (mcp ? ", MCP servers" : "")
                + (lsp ? ", LSP servers" : "")
                + "\n"
        )
    }

    private static func isInlinePluginComponent(_ value: ManifestComponentValue?) -> Bool {
        if case .inline = value { return true }
        return false
    }

    static func tagPlugin(
        options: CLIResourceOptions,
        context: PluginContext,
        streams: CLIStreams
    ) throws {
        let path = options.target ?? "."
        let root = URL(fileURLWithPath: path, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CLIApplicationError.failed("Not a directory: \(path)")
        }
        guard case .found(let manifest) = try loadPluginManifest(from: root) else {
            throw CLIApplicationError.failed("No plugin.json found in \(path).")
        }
        guard let version = manifest.version, !version.isEmpty else {
            throw CLIApplicationError.failed(
                "No `version` field in plugin.json. Set a version to use `open-grok plugin tag`."
            )
        }
        let normalized = version.hasPrefix("v") || version.hasPrefix("V")
            ? String(version.dropFirst()) : version
        let tag = "v\(normalized)"
        let push = options.options["--push"] == "true"
        let dryRun = options.options["--dry-run"] == "true"

        if !options.force {
            let status = try runPluginGitCommand(
                ["status", "--porcelain"],
                root: root,
                environment: context.environment
            )
            guard status.stdout.isEmpty else {
                throw CLIApplicationError.failed(
                    "Working tree is dirty. Commit changes first, or use --force."
                )
            }
        }
        if dryRun {
            streams.out("Would create tag: \(tag)\n")
            if push { streams.out("Would push tag to remote.\n") }
            return
        }
        var arguments = ["tag", tag]
        if options.force { arguments.append("--force") }
        do {
            _ = try runPluginGitCommand(arguments, root: root, environment: context.environment)
        } catch {
            throw CLIApplicationError.failed("Failed to create tag: \(error)")
        }
        streams.out("Created tag: \(tag)\n")
        if push {
            var pushArguments = ["push", "origin", tag]
            if options.force { pushArguments.append("--force") }
            do {
                _ = try runPluginGitCommand(
                    pushArguments,
                    root: root,
                    environment: context.environment
                )
            } catch {
                throw CLIApplicationError.failed("Failed to push tag: \(error)")
            }
            streams.out("Pushed tag \(tag) to origin.\n")
        }
    }

    private struct PluginGitOutput {
        var stdout: String
        var stderr: String
    }

    @discardableResult
    private static func runPluginGitCommand(
        _ arguments: [String],
        root: URL,
        environment: [String: String]
    ) throws -> PluginGitOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        var processEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment { processEnvironment[key] = value }
        processEnvironment["GIT_TERMINAL_PROMPT"] = "0"
        processEnvironment["GIT_LFS_SKIP_SMUDGE"] = "1"
        process.environment = processEnvironment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        try process.run()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        if completion.wait(timeout: .now() + 30) == .timedOut {
            process.terminate()
            throw CLIApplicationError.failed("git \(arguments.first ?? "?") timed out")
        }
        let out = String(decoding: try stdout.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
        let err = String(decoding: try stderr.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw CLIApplicationError.failed(err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return PluginGitOutput(stdout: out, stderr: err)
    }

    // MARK: - Marketplace sources

    static func runMarketplaceManagement(
        options: CLIResourceOptions,
        context: PluginContext,
        streams: CLIStreams
    ) throws {
        guard let action = options.target else {
            throw CLIApplicationError.failed(
                "Usage: open-grok plugin marketplace list|add|remove|update"
            )
        }
        switch action {
        case "list":
            try listMarketplaceSources(options: options, context: context, streams: streams)
        case "add":
            guard let input = options.values.first ?? options.options["--url"]
                ?? options.options["--source"] else {
                throw CLIApplicationError.failed("Usage: open-grok plugin marketplace add <source>")
            }
            try addMarketplaceSource(input, force: options.force, context: context, streams: streams)
        case "remove":
            guard let input = options.values.first ?? options.options["--source"] else {
                throw CLIApplicationError.failed("Usage: open-grok plugin marketplace remove <source>")
            }
            try removeMarketplaceSource(input, context: context, streams: streams)
        case "update":
            try updateMarketplaceSources(
                name: options.values.first,
                context: context,
                streams: streams
            )
        default:
            throw CLIApplicationError.failed("Unknown marketplace action: \(action)")
        }
    }

    private static func configuredMarketplaceSources(
        context: PluginContext
    ) throws -> [MarketplaceSource] {
        let document = try loadTomlFile(at: context.configurationURL, environment: context.environment)
        guard let root = document.table else {
            throw CLIApplicationError.failed("config.toml root is not a table")
        }
        let marketplaceValue = root["marketplace"]
        if marketplaceValue != nil && marketplaceValue?.table == nil {
            throw CLIApplicationError.failed("[marketplace] is not a table")
        }
        let configuredValue = marketplaceValue?.table?["sources"]
        if configuredValue != nil && configuredValue?.arrayValue == nil {
            throw CLIApplicationError.failed("marketplace.sources is not an array of tables")
        }
        let entries = configuredValue?.arrayValue ?? []
        var sources = try entries.map { value -> MarketplaceSource in
            guard let table = value.table,
                  let name = table["name"]?.stringValue else {
                throw CLIApplicationError.failed("Marketplace sources require a name")
            }
            if let git = table["git"]?.stringValue {
                return MarketplaceSource(
                    name: name,
                    kind: .git(url: git, branch: table["branch"]?.stringValue)
                )
            }
            if let path = table["path"]?.stringValue {
                let expanded: String
                if path.hasPrefix("~") {
                    let userHome = context.environment["HOME"] ?? NSHomeDirectory()
                    expanded = userHome + String(path.dropFirst())
                } else {
                    expanded = path
                }
                return MarketplaceSource(name: name, kind: .local(path: expanded))
            }
            throw CLIApplicationError.failed("Marketplace source \"\(name)\" has no git URL or path")
        }
        let userHome = context.environment["HOME"].map { URL(fileURLWithPath: $0) }
        var roots = [context.home]
        if let userHome { roots.append(userHome.appendingPathComponent(".claude")) }
        sources.append(contentsOf: loadExtraMarketplaceSources(existing: sources, roots: roots))
        return sources
    }

    private static func listMarketplaceSources(
        options: CLIResourceOptions,
        context: PluginContext,
        streams: CLIStreams
    ) throws {
        let sources = try configuredMarketplaceSources(context: context)
        if options.json {
            writeJSON(
                sources.map { source in
                    let detail: MarketplaceSourceOutput.Detail
                    switch source.kind {
                    case .git(let url, let branch):
                        detail = .init(url: url, branch: branch, path: nil)
                    case .local(let path):
                        detail = .init(url: nil, branch: nil, path: path)
                    }
                    return MarketplaceSourceOutput(
                        name: source.name,
                        kind: source.sourceKindLabel,
                        source: detail
                    )
                },
                streams: streams
            )
            return
        }
        guard !sources.isEmpty else {
            streams.out(
                "No marketplace sources configured.\n"
                    + "Run `open-grok plugin marketplace add --help` to get started.\n"
            )
            return
        }
        for source in sources {
            streams.out("  \(source.name): \(source.sourceURLOrPath)\n")
        }
    }

    private static func addMarketplaceSource(
        _ input: String,
        force: Bool,
        context: PluginContext,
        streams: CLIStreams
    ) throws {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CLIApplicationError.failed("URL cannot be empty.") }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let parsed = PluginInstallSource.parse(trimmed, cwd: cwd)
        let source: MarketplaceSource
        switch parsed {
        case .local(let path, let subdirectory):
            guard !context.managedMarketplacePolicy.isRestricted else {
                throw CLIApplicationError.failed(
                    "Marketplace source blocked: \(context.managedMarketplacePolicy.blockReason)"
                )
            }
            guard subdirectory == nil else {
                throw CLIApplicationError.failed("Marketplace source paths do not support subdirectories")
            }
            let root = URL(fileURLWithPath: path, isDirectory: true)
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory),
                  directory.boolValue else {
                throw CLIApplicationError.failed(
                    "Local marketplace path not found (or is not a directory): \(path)"
                )
            }
            guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw CLIApplicationError.failed("Local marketplace path must not be a symbolic link")
            }
            let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
            source = MarketplaceSource(
                name: canonical.lastPathComponent,
                kind: .local(path: canonical.path)
            )
        case .git(let url, let ref, let subdirectory):
            guard context.managedMarketplacePolicy.allows(url) else {
                throw CLIApplicationError.failed(
                    "Marketplace source blocked: \(context.managedMarketplacePolicy.blockReason)"
                )
            }
            guard subdirectory == nil else {
                throw CLIApplicationError.failed("Marketplace git sources do not support subdirectories")
            }
            try PluginGitClient.validateOperand(url)
            if !force {
                do {
                    _ = try runPluginGitCommand(
                        ["ls-remote", "--exit-code", "--", url, "HEAD"],
                        root: cwd,
                        environment: context.environment
                    )
                } catch {
                    throw CLIApplicationError.failed(
                        "\(error)\nNot adding \"\(input)\": it doesn't look like a reachable git "
                            + "repository. Re-run with --force to add it anyway."
                    )
                }
            }
            let base = url.split(separator: "/").last.map(String.init) ?? "marketplace"
            let name = base.hasSuffix(".git") ? String(base.dropLast(4)) : base
            source = MarketplaceSource(name: name, kind: .git(url: url, branch: ref))
        }

        let existing = try configuredMarketplaceSources(context: context)
        guard !existing.contains(where: { marketplaceSourceMatches($0, source.sourceURLOrPath) }) else {
            throw CLIApplicationError.failed(
                "Marketplace source already configured: \(source.sourceURLOrPath)"
            )
        }
        try mutateMarketplaceSources(context: context) { entries in
            var entry = TOMLTable()
            entry.insert(.string(source.name), forKey: "name")
            switch source.kind {
            case .local(let path): entry.insert(.string(path), forKey: "path")
            case .git(let url, let branch):
                entry.insert(.string(url), forKey: "git")
                if let branch { entry.insert(.string(branch), forKey: "branch") }
            }
            entries.append(.table(entry))
        }
        streams.out("Added marketplace source: \(source.name) (\(source.sourceURLOrPath))\n")
    }

    private static func removeMarketplaceSource(
        _ input: String,
        context: PluginContext,
        streams: CLIStreams
    ) throws {
        let sources = try configuredMarketplaceSources(context: context)
        let source = try findMarketplaceSource(input, among: sources)
        let registry = try PluginInstallRegistry.loadOrThrow(from: context.location.registryURL)
        let matching = registry.repositories.filter {
            $0.marketplace?.sourceURLOrPath == source.sourceURLOrPath
        }

        var removedFromConfiguration = false
        try mutateMarketplaceSources(context: context) { entries in
            let before = entries.count
            entries.removeAll { entry in
                guard let table = entry.table else { return false }
                let identity = table["git"]?.stringValue ?? table["path"]?.stringValue
                guard let identity else { return false }
                return marketplaceSourceMatches(source, identity)
            }
            removedFromConfiguration = before != entries.count
        }
        guard removedFromConfiguration else {
            throw CLIApplicationError.failed(
                "Marketplace source \"\(source.name)\" is managed or cannot be removed from config.toml"
            )
        }
        for record in matching {
            try uninstallPluginTransaction(record, keepData: false, context: context)
        }
        if matching.isEmpty {
            streams.out("Removed marketplace source: \(source.name) (\(source.sourceURLOrPath))\n")
        } else {
            let names = matching.flatMap(\.pluginNames)
            streams.out(
                "Removed marketplace source and uninstalled \(names.count) plugin(s): "
                    + "\(names.joined(separator: ", "))\n"
            )
        }
    }

    private static func updateMarketplaceSources(
        name: String?,
        context: PluginContext,
        streams: CLIStreams
    ) throws {
        let sources = try configuredMarketplaceSources(context: context)
        let selected: [MarketplaceSource]
        if let name {
            selected = [try findMarketplaceSource(name, among: sources)]
        } else {
            selected = sources
        }
        guard !selected.isEmpty else {
            streams.out("No marketplace sources configured.\n")
            return
        }

        var refreshed = 0
        for source in selected {
            switch source.kind {
            case .local:
                if name != nil {
                    streams.out("Source \"\(source.name)\" is local — nothing to sync.\n")
                }
            case .git:
                _ = try marketplaceSourceRoot(source, context: context, forceRefresh: true)
                streams.out("  \(source.name): synced\n")
                refreshed += 1
            }
        }
        if refreshed > 0 {
            streams.out("Refreshed \(refreshed) source(s).\n")
        } else if name == nil {
            streams.out("No marketplace sources configured.\n")
        }
    }

    private static func mutateMarketplaceSources(
        context: PluginContext,
        mutation: (inout [TOMLValue]) throws -> Void
    ) throws {
        let document = try loadTomlFile(at: context.configurationURL, environment: context.environment)
        guard var root = document.table else {
            throw CLIApplicationError.failed("config.toml root is not a table")
        }
        if root["marketplace"] != nil && root["marketplace"]?.table == nil {
            throw CLIApplicationError.failed("[marketplace] is not a table")
        }
        var marketplace = root["marketplace"]?.table ?? TOMLTable()
        if marketplace["sources"] != nil && marketplace["sources"]?.arrayValue == nil {
            throw CLIApplicationError.failed("marketplace.sources is not an array of tables")
        }
        var entries = marketplace["sources"]?.arrayValue ?? []
        try mutation(&entries)
        if entries.isEmpty {
            marketplace.removeValue(forKey: "sources")
        } else {
            marketplace.insert(.array(entries), forKey: "sources")
        }
        if marketplace.isEmpty {
            root.removeValue(forKey: "marketplace")
        } else {
            root.insert(.table(marketplace), forKey: "marketplace")
        }
        try writeConfigFile(.table(root), to: context.configurationURL)
    }

    private static func findMarketplaceSource(
        _ input: String,
        among sources: [MarketplaceSource]
    ) throws -> MarketplaceSource {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let byName = sources.filter { $0.name == trimmed }
        if byName.count > 1 {
            throw CLIApplicationError.failed(
                "Multiple sources are named \"\(trimmed)\"; remove by URL/path instead."
            )
        }
        if let source = byName.first { return source }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let parsed = PluginInstallSource.parse(trimmed, cwd: cwd)
        let normalized: String
        switch parsed {
        case .local(let path, _): normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        case .git(let url, _, _): normalized = url
        }
        if let source = sources.first(where: {
            marketplaceSourceMatches($0, trimmed) || marketplaceSourceMatches($0, normalized)
        }) {
            return source
        }
        if sources.isEmpty {
            throw CLIApplicationError.failed(
                "Marketplace source \"\(trimmed)\" not found; no sources are configured."
            )
        }
        throw CLIApplicationError.failed(
            "Marketplace source \"\(trimmed)\" not found. Configured sources: "
                + sources.map(\.name).joined(separator: ", ")
        )
    }

    private static func marketplaceSourceMatches(_ source: MarketplaceSource, _ identity: String) -> Bool {
        switch source.kind {
        case .local(let path):
            return URL(fileURLWithPath: path).standardizedFileURL.path
                == URL(fileURLWithPath: identity).standardizedFileURL.path
        case .git(let url, _):
            let lhs = url.hasSuffix(".git") ? String(url.dropLast(4)) : url
            let rhs = identity.hasSuffix(".git") ? String(identity.dropLast(4)) : identity
            return lhs == rhs
        }
    }

    // MARK: - Marketplace installation and inventory

    static func resolveMarketplacePlugin(
        _ reference: MarketplaceRef,
        context: PluginContext
    ) throws -> ResolvedMarketplacePlugin {
        let sources = try configuredMarketplaceSources(context: context).filter { source in
            switch source.kind {
            case .local: return true
            case .git(let url, _): return context.managedMarketplacePolicy.allows(url)
            }
        }
        let selectedSources: [MarketplaceSource]
        if let qualifier = reference.qualifier {
            switch resolveMarketplaceQualifier(qualifier, sources: sources) {
            case .success(let index): selectedSources = [sources[index]]
            case .failure(.unknown):
                throw CLIApplicationError.failed("Marketplace source \"\(qualifier)\" not found.")
            case .failure(.ambiguous):
                throw CLIApplicationError.failed("Marketplace source \"\(qualifier)\" is ambiguous.")
            }
        } else {
            selectedSources = sources
        }

        var candidates: [(source: MarketplaceSource, root: URL, entry: MarketplaceEntry)] = []
        for source in selectedSources {
            let root = try marketplaceSourceRoot(source, context: context, forceRefresh: false)
            let scan = try safelyScanMarketplace(root)
            for entry in scan.entries {
                candidates.append((source: source, root: root, entry: entry))
            }
        }
        let entries = candidates.map { (source: $0.source, entry: $0.entry) }
        switch selectMarketplaceEntry(name: reference.name, scanned: entries) {
        case .success(let selected):
            let candidate = candidates[selected.chosen]
            return ResolvedMarketplacePlugin(
                source: candidate.source,
                root: candidate.root,
                entry: candidate.entry
            )
        case .failure(.notFound):
            throw CLIApplicationError.failed(
                "Plugin \"\(reference.name)\" was not found in configured marketplace sources."
            )
        case .failure(.ambiguous(let matches)):
            let names = matches.map { candidates[$0].source.name }.joined(separator: ", ")
            throw CLIApplicationError.failed(
                "Plugin \"\(reference.name)\" exists in multiple marketplaces: \(names). "
                    + "Specify \(reference.name)@<marketplace>."
            )
        }
    }

    static func installResolvedMarketplacePlugin(
        _ resolved: ResolvedMarketplacePlugin,
        raw: String,
        force: Bool,
        context: PluginContext,
        streams: CLIStreams
    ) throws {
        let relative = try MarketplaceRelativePath(resolved.entry.relativePath).value
        let provenance = MarketplaceProvenance(
            sourceURLOrPath: resolved.source.sourceURLOrPath,
            sourceDisplayName: resolved.source.name,
            pluginSubdirectory: relative
        )
        let registry = try PluginInstallRegistry.loadOrThrow(from: context.location.registryURL)
        if let existing = registry.repositories.first(where: {
            $0.marketplace?.sourceURLOrPath == provenance.sourceURLOrPath
                && $0.marketplace?.pluginSubdirectory == provenance.pluginSubdirectory
        }), !force {
            let name = existing.pluginNames.first ?? resolved.entry.name
            streams.out(
                "Plugin \"\(resolved.entry.name)\" is already installed from \(resolved.source.name). "
                    + "Run `open-grok plugin update \(name)` to update it.\n"
            )
            return
        }

        let source = try marketplacePluginInstallSource(resolved)
        let record = try installPluginTransaction(
            source: source,
            raw: raw,
            context: context,
            provenance: provenance
        )
        streams.out(
            "Installed \(record.pluginNames.count) plugin(s) from \(resolved.source.name): "
                + "\(record.pluginNames.joined(separator: ", "))\n"
        )
    }

    private static func marketplacePluginInstallSource(
        _ resolved: ResolvedMarketplacePlugin
    ) throws -> PluginInstallSource {
        if let remote = resolved.entry.remoteURL {
            let url = try validateGitURL(remote)
            let pin = try normalizeMarketplaceRemotePin(
                ref: resolved.entry.remoteRef,
                sha: resolved.entry.remoteSHA
            )
            let subdirectory = try resolved.entry.remoteSubdirectory.map {
                try MarketplaceRelativePath($0).value
            }
            return .git(url: url, ref: pin.sha ?? pin.ref, subdirectory: subdirectory)
        }
        let relative = try MarketplaceRelativePath(resolved.entry.relativePath)
        let root = try relative.resolve(under: resolved.root)
        return .local(path: root.path, subdirectory: nil)
    }

    static func updateMarketplacePlugin(
        _ existing: PluginInstallRecord,
        provenance: MarketplaceProvenance,
        context: PluginContext,
        streams: CLIStreams
    ) throws {
        let sources = try configuredMarketplaceSources(context: context)
        guard let source = sources.first(where: {
            marketplaceSourceMatches($0, provenance.sourceURLOrPath)
        }) else {
            throw CLIApplicationError.failed(
                "Marketplace source \"\(provenance.sourceDisplayName)\" is not configured."
            )
        }
        let root = try marketplaceSourceRoot(source, context: context, forceRefresh: source.isGitSource)
        let safePath = try MarketplaceRelativePath(provenance.pluginSubdirectory).value
        guard let entry = try safelyScanMarketplace(root).entries.first(where: {
            $0.relativePath == safePath
        }) else {
            throw CLIApplicationError.failed("Marketplace plugin \"\(safePath)\" was not found.")
        }
        let resolved = ResolvedMarketplacePlugin(source: source, root: root, entry: entry)
        let installSource = try marketplacePluginInstallSource(resolved)
        let before = existing.pluginNames.first.flatMap { existing.pluginDetails[$0]?.version }
        let updated = try installPluginTransaction(
            source: installSource,
            raw: existing.repoKey,
            context: context,
            provenance: provenance,
            preserving: existing
        )
        let after = updated.pluginNames.first.flatMap { updated.pluginDetails[$0]?.version }
        if before == after {
            streams.out("\(existing.repoKey): already up to date\n")
        } else {
            streams.out("\(existing.repoKey): updated (\(before ?? "?") -> \(after ?? "?"))\n")
        }
    }

    private static func marketplaceSourceRoot(
        _ source: MarketplaceSource,
        context: PluginContext,
        forceRefresh: Bool
    ) throws -> URL {
        switch source.kind {
        case .local(let path):
            let root = URL(fileURLWithPath: path, isDirectory: true)
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory),
                  directory.boolValue else {
                throw CLIApplicationError.failed("Marketplace source directory is missing: \(path)")
            }
            guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw CLIApplicationError.failed("Marketplace source directory must not be a symbolic link")
            }
            return root.standardizedFileURL.resolvingSymlinksInPath()
        case .git(let url, let branch):
            guard context.managedMarketplacePolicy.allows(url) else {
                throw CLIApplicationError.failed(
                    "Marketplace source blocked: \(context.managedMarketplacePolicy.blockReason)"
                )
            }
            try FileManager.default.createDirectory(
                at: context.marketplaceCacheDirectory,
                withIntermediateDirectories: true
            )
            let key = PluginInstallLocation.repoKey(sourceIdentifier: url)
            let final = context.marketplaceCacheDirectory.appendingPathComponent(key, isDirectory: true)
            if FileManager.default.fileExists(atPath: final.path), !forceRefresh {
                return final
            }
            let nonce = UUID().uuidString
            let staging = context.marketplaceCacheDirectory
                .appendingPathComponent(".staging-\(key)-\(nonce)")
            let backup = context.marketplaceCacheDirectory
                .appendingPathComponent(".backup-\(key)-\(nonce)")
            do {
                try PluginGitClient().clone(url: url, destination: staging, ref: branch, sha: nil)
                try rejectEscapingPluginSymlinks(in: staging)
                _ = try loadMarketplaceIndex(from: staging)
            } catch {
                try? removePluginPathIfPresent(staging)
                throw CLIApplicationError.failed("Failed to sync marketplace \(source.name): \(error)")
            }
            let hadExisting = FileManager.default.fileExists(atPath: final.path)
            if hadExisting {
                do {
                    try FileManager.default.moveItem(at: final, to: backup)
                } catch {
                    try? removePluginPathIfPresent(staging)
                    throw error
                }
            }
            do {
                try FileManager.default.moveItem(at: staging, to: final)
            } catch {
                if hadExisting {
                    try FileManager.default.moveItem(at: backup, to: final)
                }
                try? removePluginPathIfPresent(staging)
                throw error
            }
            if hadExisting { try? removePluginPathIfPresent(backup) }
            return final
        }
    }

    static func listAvailablePlugins(
        registry: PluginInstallRegistry,
        context: PluginContext,
        streams: CLIStreams
    ) throws {
        var entries: [PluginInventoryOutput] = []
        for record in registry.repositories {
            for name in record.pluginNames.sorted() {
                entries.append(PluginInventoryOutput(
                    status: "installed",
                    name: name,
                    repoKey: record.repoKey,
                    version: record.pluginDetails[name]?.version,
                    path: record.installedPath,
                    source: record.url ?? record.path ?? record.sourceIdentifier,
                    marketplace: record.marketplace?.sourceDisplayName,
                    description: nil,
                    skillCount: nil,
                    hasHooks: nil,
                    hasAgents: nil,
                    hasMCP: nil
                ))
            }
        }
        for source in try configuredMarketplaceSources(context: context) {
            let root = try marketplaceSourceRoot(source, context: context, forceRefresh: false)
            for entry in try safelyScanMarketplace(root).entries {
                let installed = registry.repositories.contains {
                    $0.marketplace?.sourceURLOrPath == source.sourceURLOrPath
                        && $0.marketplace?.pluginSubdirectory == entry.relativePath
                }
                guard !installed else { continue }
                entries.append(PluginInventoryOutput(
                    status: "available",
                    name: entry.name,
                    repoKey: nil,
                    version: entry.version,
                    path: nil,
                    source: nil,
                    marketplace: source.name,
                    description: entry.description,
                    skillCount: entry.skillCount,
                    hasHooks: entry.hasHooks,
                    hasAgents: entry.hasAgents,
                    hasMCP: entry.hasMcp
                ))
            }
        }
        writeJSON(entries, streams: streams)
    }

    private static func safelyScanMarketplace(_ root: URL) throws -> MarketplaceScan {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: nil
        ) else {
            throw CLIApplicationError.failed("Unable to inspect marketplace source \(root.path)")
        }
        for case let entry as URL in enumerator {
            if try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                enumerator.skipDescendants()
                throw CLIApplicationError.failed(
                    "Marketplace source contains an unsafe symbolic link: \(entry.path)"
                )
            }
        }
        return scanMarketplace(root)
    }
}

private extension MarketplaceSource {
    var sourceKindLabel: String {
        switch kind {
        case .local: return "local"
        case .git: return "git"
        }
    }

    var isGitSource: Bool {
        if case .git = kind { return true }
        return false
    }
}

private struct MarketplaceSourceOutput: Encodable {
    struct Detail: Encodable {
        var url: String?
        var branch: String?
        var path: String?
    }

    var name: String
    var kind: String
    var source: Detail
}

private struct PluginInventoryOutput: Encodable {
    var status: String
    var name: String
    var repoKey: String?
    var version: String?
    var path: String?
    var source: String?
    var marketplace: String?
    var description: String?
    var skillCount: Int?
    var hasHooks: Bool?
    var hasAgents: Bool?
    var hasMCP: Bool?

    enum CodingKeys: String, CodingKey {
        case status, name, version, path, source, marketplace, description
        case repoKey = "repo_key"
        case skillCount = "skill_count"
        case hasHooks = "has_hooks"
        case hasAgents = "has_agents"
        case hasMCP = "has_mcp"
    }
}
