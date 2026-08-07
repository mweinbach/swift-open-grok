import Foundation
import Testing
@testable import OpenGrokPluginMarketplace

@Suite("Marketplace transactional install and update", .serialized)
struct MarketplaceInstallerTests {
    private func withTestRegistry<T>(
        _ body: (URL, inout MarketplaceInstallRegistry) throws -> T
    ) throws -> T {
        let home = try temporaryDirectory()
        let installDirectory = home.appendingPathComponent("installed-plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        var registry = MarketplaceInstallRegistry(installDirectory: installDirectory)
        return try body(home, &registry)
    }

    private func writePlugin(
        marketplace: URL,
        name: String,
        version: String,
        marker: String
    ) throws {
        let pluginDir = marketplace.appendingPathComponent("plugins/\(name)", isDirectory: true)
        let manifestDir = pluginDir.appendingPathComponent(".claude-plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestDir, withIntermediateDirectories: true)
        try write(
            #"{"name":"\#(name)","version":"\#(version)"}"#,
            to: manifestDir.appendingPathComponent("plugin.json")
        )
        let skillDir = pluginDir.appendingPathComponent("skills/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try write("# Demo", to: skillDir.appendingPathComponent("SKILL.md"))
        try write(marker, to: pluginDir.appendingPathComponent("marker.txt"))
    }

    private func installTestPlugin(
        registry: inout MarketplaceInstallRegistry,
        marketplace: URL,
        name: String
    ) throws -> String {
        let pluginSubdirectory = "plugins/\(name)"
        let result = try installFromMarketplace(
            marketplaceRoot: marketplace,
            pluginRelativePath: pluginSubdirectory,
            provenance: provenance(for: marketplace, path: pluginSubdirectory),
            registry: &registry
        )
        switch result {
        case let .installed(repositoryKey):
            return repositoryKey
        case let .alreadyInstalled(repositoryKey):
            return repositoryKey
        }
    }

    private func provenance(for marketplace: URL, path: String) -> MarketplaceProvenance {
        MarketplaceProvenance(
            sourceURLOrPath: marketplace.path,
            sourceDisplayName: "Test",
            pluginSubdirectory: path
        )
    }

    private func markerContents(in registry: MarketplaceInstallRegistry, repositoryKey: String) throws -> String {
        let marker = registry.installDirectory
            .appendingPathComponent(repositoryKey)
            .appendingPathComponent("marker.txt")
        return try String(contentsOf: marker, encoding: .utf8)
    }

    @Test("transactional update recopies local entry and updates version")
    func successfulUpdateDoesNotRollBack() throws {
        try withTestRegistry { home, registry in
            let marketplace = home.appendingPathComponent("marketplace", isDirectory: true)
            try writePlugin(marketplace: marketplace, name: "demo", version: "1.0.0", marker: "old")
            let repositoryKey = try installTestPlugin(registry: &registry, marketplace: marketplace, name: "demo")

            try writePlugin(marketplace: marketplace, name: "demo", version: "2.0.0", marker: "new")
            let entry = scanMarketplace(marketplace).entries.first { $0.relativePath == "plugins/demo" }
            guard let entry else {
                Issue.record("expected marketplace entry")
                return
            }

            let result = try updateFromMarketplaceEntryTransactional(
                marketplaceRoot: marketplace,
                entry: entry,
                provenance: provenance(for: marketplace, path: "plugins/demo"),
                registry: &registry,
                requireSHA: false
            )

            #expect(result.repositoryKey == repositoryKey)
            #expect(result.oldVersion == "1.0.0")
            #expect(result.newVersion == "2.0.0")
            #expect(result.changed)
            #expect(result.reinstalled)
            #expect(try markerContents(in: registry, repositoryKey: repositoryKey) == "new")

            let reloaded = MarketplaceInstallRegistry.load(installDirectory: registry.installDirectory)
            #expect(reloaded.plugins.first?.version == "2.0.0")
        }
    }

    @Test("transactional update save failure rolls back install and disk registry")
    func registrySaveFailureRollsBack() throws {
        try withTestRegistry { home, registry in
            let marketplace = home.appendingPathComponent("marketplace", isDirectory: true)
            try writePlugin(marketplace: marketplace, name: "demo", version: "1.0.0", marker: "old")
            let repositoryKey = try installTestPlugin(registry: &registry, marketplace: marketplace, name: "demo")
            let oldRegistryContent = try String(
                contentsOf: registry.registryURL,
                encoding: .utf8
            )

            try writePlugin(marketplace: marketplace, name: "demo", version: "2.0.0", marker: "new")
            let entry = scanMarketplace(marketplace).entries.first { $0.relativePath == "plugins/demo" }
            guard let entry else {
                Issue.record("expected marketplace entry")
                return
            }

            setenv(MarketplaceInstallRegistry.testFailRegistrySaveEnvironmentKey, "1", 1)
            defer { unsetenv(MarketplaceInstallRegistry.testFailRegistrySaveEnvironmentKey) }

            let updateResult = Result {
                try updateFromMarketplaceEntryTransactional(
                    marketplaceRoot: marketplace,
                    entry: entry,
                    provenance: provenance(for: marketplace, path: "plugins/demo"),
                    registry: &registry,
                    requireSHA: false
                )
            }
            guard case .failure = updateResult else {
                Issue.record("expected update failure")
                return
            }

            #expect(try markerContents(in: registry, repositoryKey: repositoryKey) == "old")
            let registryContent = try String(contentsOf: registry.registryURL, encoding: .utf8)
            #expect(registryContent == oldRegistryContent)
            #expect(registry.plugins.first?.version == "1.0.0")
        }
    }

    @Test("transactional update failure preserves old install and registry")
    func invalidSourcePreservesOldInstall() throws {
        try withTestRegistry { home, registry in
            let marketplace = home.appendingPathComponent("marketplace", isDirectory: true)
            try writePlugin(marketplace: marketplace, name: "demo", version: "1.0.0", marker: "old")
            let repositoryKey = try installTestPlugin(registry: &registry, marketplace: marketplace, name: "demo")

            let pluginDir = marketplace.appendingPathComponent("plugins/demo", isDirectory: true)
            try FileManager.default.removeItem(at: pluginDir)
            try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

            let entry = MarketplaceEntry(
                name: "demo",
                version: "2.0.0",
                description: nil,
                relativePath: "plugins/demo"
            )

            let updateResult = Result {
                try updateFromMarketplaceEntryTransactional(
                    marketplaceRoot: marketplace,
                    entry: entry,
                    provenance: provenance(for: marketplace, path: "plugins/demo"),
                    registry: &registry,
                    requireSHA: false
                )
            }
            guard case .failure(let error) = updateResult else {
                Issue.record("expected update failure")
                return
            }
            guard case .installFailed = error as? MarketplaceError else {
                Issue.record("expected installFailed, got \(error)")
                return
            }

            #expect(try markerContents(in: registry, repositoryKey: repositoryKey) == "old")
            #expect(registry.plugins.first?.version == "1.0.0")
        }
    }
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("opengrok-marketplace-installer-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}
