// MarketplaceInstaller.swift
//
// Transactional marketplace install/update with filesystem + registry rollback.
// Port of `xai-grok-plugin-marketplace/src/installer.rs`
// (`update_from_marketplace_entry_transactional`, `install_from_marketplace`).

import Foundation
import OpenGrokFileUtils

public struct MarketplaceUpdateResult: Hashable, Sendable, Equatable {
    public var repositoryKey: String
    public var oldVersion: String?
    public var newVersion: String?
    public var changed: Bool
    public var reinstalled: Bool

    public init(
        repositoryKey: String,
        oldVersion: String?,
        newVersion: String?,
        changed: Bool,
        reinstalled: Bool
    ) {
        self.repositoryKey = repositoryKey
        self.oldVersion = oldVersion
        self.newVersion = newVersion
        self.changed = changed
        self.reinstalled = reinstalled
    }
}

public enum MarketplaceInstallResult: Hashable, Sendable, Equatable {
    case installed(repositoryKey: String)
    case alreadyInstalled(repositoryKey: String)
}

/// On-disk registry of marketplace-installed plugins for one install directory.
public struct MarketplaceInstallRegistry: Sendable {
    public static let registryFileName = "registry.json"
    public static let testFailRegistrySaveEnvironmentKey = "XAI_GROK_TEST_FAIL_REGISTRY_SAVE_AFTER_SERIALIZE"

    public var installDirectory: URL
    public var plugins: [InstalledMarketplacePlugin]

    public init(installDirectory: URL, plugins: [InstalledMarketplacePlugin] = []) {
        self.installDirectory = installDirectory
        self.plugins = plugins
    }

    public var registryURL: URL {
        installDirectory.appendingPathComponent(Self.registryFileName)
    }

    public func cloned() -> MarketplaceInstallRegistry {
        MarketplaceInstallRegistry(installDirectory: installDirectory, plugins: plugins)
    }

    public static func load(installDirectory: URL) -> MarketplaceInstallRegistry {
        let url = installDirectory.appendingPathComponent(registryFileName)
        guard let data = try? Data(contentsOf: url),
              let persisted = try? JSONDecoder().decode(PersistedRegistry.self, from: data)
        else {
            return MarketplaceInstallRegistry(installDirectory: installDirectory)
        }
        return MarketplaceInstallRegistry(installDirectory: installDirectory, plugins: persisted.plugins)
    }

    public mutating func save() throws {
        try FileManager.default.createDirectory(
            at: installDirectory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(PersistedRegistry(version: 1, plugins: plugins))
        if ProcessInfo.processInfo.environment[Self.testFailRegistrySaveEnvironmentKey] != nil {
            throw MarketplaceError.installFailed(detail: "test-injected registry save failure")
        }
        try writeAtomically(registryURL, data: data)
    }

    public mutating func upsert(_ plugin: InstalledMarketplacePlugin) {
        if let index = plugins.firstIndex(where: { $0.key == plugin.key }) {
            plugins[index] = plugin
        } else {
            plugins.append(plugin)
        }
    }

    public func installed(
        sourceURLOrPath: String,
        pluginSubdirectory: String
    ) -> InstalledMarketplacePlugin? {
        plugins.first {
            $0.provenance.sourceURLOrPath == sourceURLOrPath
                && $0.provenance.pluginSubdirectory == pluginSubdirectory
        }
    }

    private struct PersistedRegistry: Codable {
        var version: Int
        var plugins: [InstalledMarketplacePlugin]
    }
}

/// Install a plugin from a synced marketplace checkout.
public func installFromMarketplace(
    marketplaceRoot: URL,
    pluginRelativePath: String,
    provenance: MarketplaceProvenance,
    registry: inout MarketplaceInstallRegistry
) throws -> MarketplaceInstallResult {
    let normalizedPath = try MarketplaceRelativePath(pluginRelativePath).value
    let normalizedProvenance = try MarketplaceRelativePath(provenance.pluginSubdirectory).value
    if let existing = registry.installed(
        sourceURLOrPath: provenance.sourceURLOrPath,
        pluginSubdirectory: normalizedProvenance
    ) {
        return .alreadyInstalled(repositoryKey: existing.key)
    }

    let sourceURL = try MarketplaceRelativePath(normalizedPath).resolve(under: marketplaceRoot)
    guard marketplacePathIsDirectory(sourceURL) else {
        throw MarketplaceError.installFailed(detail: "plugin directory not found: \(sourceURL.path)")
    }

    let source = MarketplaceInstallSource.local(
        root: marketplaceRoot.standardizedFileURL.path,
        relativePath: normalizedPath
    )
    let repositoryKey = marketplaceRepositoryKey(source: source, fallbackPluginName: normalizedPath.split(separator: "/").last.map(String.init) ?? "plugin")
    let finalURL = registry.installDirectory.appendingPathComponent(repositoryKey, isDirectory: true)
    try copyDirectoryContents(from: sourceURL, to: finalURL)

    let staged = try discoverPluginsInDirectory(finalURL, subdirectory: nil)
    guard let first = staged.first else {
        try? removePathIfExists(finalURL)
        throw MarketplaceError.installFailed(
            detail: "no plugins found in the marketplace entry (no plugin.json or convention components)"
        )
    }

    let timestamp = marketplaceUTCTimestamp()
    let record = InstalledMarketplacePlugin(
        key: repositoryKey,
        name: first.name,
        version: first.version,
        path: finalURL.path,
        provenance: MarketplaceProvenance(
            sourceURLOrPath: provenance.sourceURLOrPath,
            sourceDisplayName: provenance.sourceDisplayName,
            pluginSubdirectory: normalizedPath
        ),
        installedAt: timestamp,
        updatedAt: timestamp
    )
    registry.upsert(record)
    try registry.save()
    return .installed(repositoryKey: repositoryKey)
}

/// Update an installed marketplace plugin transactionally; rolls back tree + registry on failure.
///
/// Port of `update_from_marketplace_entry_transactional` (`installer.rs:201-438`).
public func updateFromMarketplaceEntryTransactional(
    marketplaceRoot: URL,
    entry: MarketplaceEntry,
    provenance: MarketplaceProvenance,
    registry: inout MarketplaceInstallRegistry,
    requireSHA: Bool,
    gitClient: PluginGitClient = PluginGitClient()
) throws -> MarketplaceUpdateResult {
    let pluginRelativePath = try MarketplaceRelativePath(entry.relativePath).value
    var normalizedProvenance = try MarketplaceRelativePath(provenance.pluginSubdirectory).value
    guard pluginRelativePath == normalizedProvenance else {
        throw MarketplaceError.installFailed(
            detail: "marketplace entry path mismatch: requested \(normalizedProvenance), found \(pluginRelativePath)"
        )
    }
    normalizedProvenance = pluginRelativePath

    let remoteSubdirectory = try entry.remoteSubdirectory.map { try MarketplaceRelativePath($0).value }

    guard let oldInstalled = registry.installed(
        sourceURLOrPath: provenance.sourceURLOrPath,
        pluginSubdirectory: normalizedProvenance
    ) else {
        throw MarketplaceError.notInstalled(plugin: normalizedProvenance)
    }
    let repositoryKey = oldInstalled.key
    let finalURL = URL(fileURLWithPath: oldInstalled.path)

    let remoteSource: (url: String, ref: String?, sha: String?)?
    if let remoteURL = entry.remoteURL {
        let pin = try normalizeMarketplaceRemotePin(ref: entry.remoteRef, sha: entry.remoteSHA)
        let normalizedURL = try validateGitURL(remoteURL)
        try requirePinnedRemote(plugin: entry.name, url: normalizedURL, sha: pin.sha, requireSHA: requireSHA)
        remoteSource = (normalizedURL, pin.ref, pin.sha)
    } else {
        remoteSource = nil
    }

    try FileManager.default.createDirectory(
        at: registry.installDirectory,
        withIntermediateDirectories: true
    )

    let nonce = marketplaceStagingNonce()
    let stagingURL = registry.installDirectory.appendingPathComponent(".staging-\(repositoryKey)-\(nonce)", isDirectory: true)
    let backupURL = registry.installDirectory.appendingPathComponent(".backup-\(repositoryKey)-\(nonce)", isDirectory: true)

    try removePathIfExists(stagingURL)
    try removePathIfExists(backupURL)

    do {
        if let remote = remoteSource {
            try gitClient.clone(
                url: remote.url,
                destination: stagingURL,
                ref: remote.ref,
                sha: remote.sha
            )
        } else {
            let sourceURL = try MarketplaceRelativePath(pluginRelativePath).resolve(under: marketplaceRoot)
            guard marketplacePathIsDirectory(sourceURL) else {
                throw MarketplaceError.installFailed(detail: "plugin directory not found: \(sourceURL.path)")
            }
            try copyDirectoryContents(from: sourceURL, to: stagingURL)
        }
    } catch {
        try? removePathIfExists(stagingURL)
        throw mapInstallError(error)
    }

    let discovered: [StagedMarketplacePlugin]
    do {
        discovered = try discoverPluginsInDirectory(stagingURL, subdirectory: remoteSubdirectory)
        guard !discovered.isEmpty else {
            try removePathIfExists(stagingURL)
            throw MarketplaceError.installFailed(
                detail: "no plugins found in the marketplace entry (no plugin.json or convention components)"
            )
        }
    } catch {
        try? removePathIfExists(stagingURL)
        throw error
    }

    let oldVersion = oldInstalled.version
    let newVersion = discovered.first?.version
    let changed = oldVersion != newVersion
    let updatedAt = marketplaceUTCTimestamp()

    let originalRegistry = registry.cloned()

    guard FileManager.default.fileExists(atPath: finalURL.path) else {
        try? removePathIfExists(stagingURL)
        throw MarketplaceError.installFailed(detail: "installed plugin directory not found: \(finalURL.path)")
    }

    do {
        try FileManager.default.moveItem(at: finalURL, to: backupURL)
    } catch {
        try? removePathIfExists(stagingURL)
        throw MarketplaceError.io(path: finalURL.path, reason: error.localizedDescription)
    }

    do {
        try FileManager.default.moveItem(at: stagingURL, to: finalURL)
    } catch {
        let restoreResult = Result { try FileManager.default.moveItem(at: backupURL, to: finalURL) }
        try? removePathIfExists(stagingURL)
        registry = originalRegistry
        if case .failure(let restoreError) = restoreResult {
            throw MarketplaceError.installFailed(
                detail: "failed to install staged marketplace update: \(error.localizedDescription); restore also failed: \(restoreError.localizedDescription)"
            )
        }
        throw MarketplaceError.io(path: stagingURL.path, reason: error.localizedDescription)
    }

    let updatedRecord = InstalledMarketplacePlugin(
        key: repositoryKey,
        name: discovered.first?.name ?? oldInstalled.name,
        version: newVersion,
        path: finalURL.path,
        provenance: MarketplaceProvenance(
            sourceURLOrPath: provenance.sourceURLOrPath,
            sourceDisplayName: provenance.sourceDisplayName,
            pluginSubdirectory: normalizedProvenance
        ),
        installedAt: oldInstalled.installedAt,
        updatedAt: updatedAt
    )
    registry.upsert(updatedRecord)

    do {
        try registry.save()
    } catch let saveError {
        let filesystemRolledBack = (try? removePathIfExists(finalURL)) != nil
            && (Result { try FileManager.default.moveItem(at: backupURL, to: finalURL) }).isSuccess
        if !filesystemRolledBack {
            throw MarketplaceError.installFailed(
                detail: """
                registry save failed after installing the update (\(saveError.localizedDescription)); \
                the installed plugin at \(finalURL.path) could not be rolled back and no longer \
                matches the registry — rerun the update or reinstall (backup at \(backupURL.path))
                """
            )
        }
        registry = originalRegistry
        do {
            try registry.save()
        } catch let rollbackError {
            throw MarketplaceError.installFailed(
                detail: """
                registry save failed (\(saveError.localizedDescription)); filesystem rolled back but \
                registry rollback failed (\(rollbackError.localizedDescription)) — rerun the update or reinstall
                """
            )
        }
        try? removePathIfExists(backupURL)
        throw saveError
    }

    try? removePathIfExists(backupURL)
    return MarketplaceUpdateResult(
        repositoryKey: repositoryKey,
        oldVersion: oldVersion,
        newVersion: newVersion,
        changed: changed,
        reinstalled: true
    )
}

// MARK: - Staging helpers

private struct StagedMarketplacePlugin: Hashable, Sendable {
    var name: String
    var subdirectory: String?
    var version: String?
}

private func discoverPluginsInDirectory(
    _ root: URL,
    subdirectory: String?
) throws -> [StagedMarketplacePlugin] {
    let scanRoot: URL
    if let subdirectory {
        let relative = try MarketplaceRelativePath(subdirectory)
        scanRoot = root.appendingPathComponent(relative.value, isDirectory: true)
        guard marketplacePathIsDirectory(scanRoot) else {
            throw MarketplaceError.installFailed(detail: "subdirectory '\(subdirectory)' not found in source")
        }
    } else {
        scanRoot = root
    }

    if let plugin = tryLoadStagedPlugin(in: scanRoot, subdirectory: subdirectory) {
        return [plugin]
    }

    var plugins: [StagedMarketplacePlugin] = []
    let children = (try? FileManager.default.contentsOfDirectory(
        at: scanRoot,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    )) ?? []
    for child in children where marketplacePathIsDirectory(child) {
        let entryName = child.lastPathComponent
        let sub: String?
        if let subdirectory {
            sub = "\(subdirectory)/\(entryName)"
        } else {
            sub = entryName
        }
        if let plugin = tryLoadStagedPlugin(in: child, subdirectory: sub) {
            plugins.append(plugin)
        }
    }
    return plugins
}

private func tryLoadStagedPlugin(
    in directory: URL,
    subdirectory: String?
) -> StagedMarketplacePlugin? {
    switch try? loadPluginManifest(from: directory) {
    case .found(let manifest):
        return StagedMarketplacePlugin(name: manifest.name, subdirectory: subdirectory, version: manifest.version)
    case .notFound, nil:
        break
    }

    let hasSkills = marketplacePathIsDirectory(directory.appendingPathComponent("skills"))
    let hasAgents = marketplacePathIsDirectory(directory.appendingPathComponent("agents"))
    let hasMCP = FileManager.default.fileExists(atPath: directory.appendingPathComponent(".mcp.json").path)
    let hasHooks = FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("hooks/hooks.json").path
    )
    guard hasSkills || hasAgents || hasMCP || hasHooks else { return nil }
    guard let name = nameFromDirectory(directory) else { return nil }
    return StagedMarketplacePlugin(name: name, subdirectory: subdirectory, version: nil)
}

private func copyDirectoryContents(from source: URL, to destination: URL) throws {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: destination.path) {
        try fileManager.removeItem(at: destination)
    }
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
    let entries = try fileManager.contentsOfDirectory(
        at: source,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: []
    )
    for entry in entries {
        let target = destination.appendingPathComponent(entry.lastPathComponent)
        if marketplacePathIsDirectory(entry) {
            try copyDirectoryContents(from: entry, to: target)
        } else {
            try fileManager.copyItem(at: entry, to: target)
        }
    }
}

private func removePathIfExists(_ url: URL) throws {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
    if isDirectory.boolValue {
        try fileManager.removeItem(at: url)
    } else {
        try fileManager.removeItem(at: url)
    }
}

private func marketplaceStagingNonce() -> String {
    let nanos = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
    return "\(ProcessInfo.processInfo.processIdentifier)-\(nanos)"
}

private func marketplaceUTCTimestamp() -> String {
    ISO8601DateFormatter().string(from: Date())
}

private func mapInstallError(_ error: Error) -> MarketplaceError {
    switch error {
    case let marketplace as MarketplaceError:
        return marketplace
    case let install as PluginInstallError:
        switch install {
        case .unpinnedRemoteRefused(let plugin, let url):
            return .unpinnedRemote(plugin: plugin, url: url)
        case .shaMismatch(let expected, let actual):
            return .integrityMismatch(expected: expected, actual: actual)
        case .invalidGitOperand(let value):
            return .invalidGitOperand(kind: "operand", value: value)
        case .gitFailed(_, _, let output):
            return .installFailed(detail: output)
        case .notFound(let name):
            return .notInstalled(plugin: name)
        case .ioFailure(let detail):
            return .installFailed(detail: detail)
        }
    default:
        return .installFailed(detail: error.localizedDescription)
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

private func marketplacePathIsDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
}
