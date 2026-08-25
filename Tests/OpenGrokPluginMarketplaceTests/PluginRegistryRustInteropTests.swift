import Foundation
import Testing
@testable import OpenGrokPluginMarketplace

@Suite("Rust-compatible plugin install registry")
struct PluginRegistryRustInteropTests {
    @Test("canonical Rust records preserve git metadata, plugin maps, provenance, and unknown fields")
    func canonicalRustRegistryRoundTripsLosslessly() throws {
        let fixture = try PluginRegistryFixture()
        defer { fixture.cleanup() }
        let sha = String(repeating: "a", count: 40)
        let installed = fixture.directory.appendingPathComponent("tools-deadbeef").path
        let document = """
        {
          "version": 1,
          "future_root": {"enabled": true},
          "repos": {
            "tools-deadbeef": {
              "kind": {
                "type": "Git",
                "url": "https://example.com/tools.git",
                "git_ref": "\(sha)",
                "commit": "\(sha)",
                "subdir": "plugins/tools",
                "future_kind": 7
              },
              "installed_at": "2026-01-01T00:00:00Z",
              "updated_at": "2026-02-01T00:00:00Z",
              "path": "\(installed)",
              "plugins": {
                "formatter": {
                  "subdir": "plugins/tools",
                  "version": "2.3.4",
                  "future_plugin": "preserve"
                }
              },
              "marketplace": {
                "source_url_or_path": "https://example.com/market.git",
                "source_display_name": "Example",
                "plugin_subdir": "plugins/tools",
                "future_marketplace": "preserve-provenance"
              },
              "future_repo": [1, 2]
            }
          }
        }
        """
        try Data(document.utf8).write(to: fixture.registry)

        let registry = try PluginInstallRegistry.loadOrThrow(from: fixture.registry)
        let record = try #require(registry.record(named: "formatter"))
        #expect(record.repoKey == "tools-deadbeef")
        #expect(record.url == "https://example.com/tools.git")
        #expect(record.ref == sha)
        #expect(record.sha == sha)
        #expect(record.commit == sha)
        #expect(record.installedPath == installed)
        #expect(record.installedAt == "2026-01-01T00:00:00Z")
        #expect(record.updatedAt == "2026-02-01T00:00:00Z")
        #expect(record.pluginDetails["formatter"]?.subdirectory == "plugins/tools")
        #expect(record.pluginDetails["formatter"]?.version == "2.3.4")
        #expect(record.marketplace?.sourceDisplayName == "Example")

        try registry.save(to: fixture.registry)
        let saved = try fixture.json()
        #expect((saved["version"] as? NSNumber)?.intValue == 1)
        #expect(saved["repositories"] == nil)
        #expect(saved["plugins"] == nil)
        #expect((saved["future_root"] as? [String: Any])?["enabled"] as? Bool == true)
        let repos = try #require(saved["repos"] as? [String: Any])
        let repo = try #require(repos["tools-deadbeef"] as? [String: Any])
        #expect((repo["future_repo"] as? [Int]) == [1, 2])
        let kind = try #require(repo["kind"] as? [String: Any])
        #expect((kind["future_kind"] as? NSNumber)?.intValue == 7)
        let plugins = try #require(repo["plugins"] as? [String: Any])
        let plugin = try #require(plugins["formatter"] as? [String: Any])
        #expect(plugin["future_plugin"] as? String == "preserve")
        let marketplace = try #require(repo["marketplace"] as? [String: Any])
        #expect(marketplace["future_marketplace"] as? String == "preserve-provenance")
    }

    @Test("legacy Swift repositories arrays migrate into canonical Rust maps")
    func legacySwiftRegistryMigrates() throws {
        let fixture = try PluginRegistryFixture()
        defer { fixture.cleanup() }
        let legacy = """
        {
          "repositories": [{
            "repoKey": "local-12345678",
            "sourceIdentifier": "/tmp/source",
            "path": "/tmp/source",
            "pluginNames": ["local"],
            "enabled": false
          }]
        }
        """
        try Data(legacy.utf8).write(to: fixture.registry)

        let registry = try PluginInstallRegistry.loadOrThrow(from: fixture.registry)
        #expect(registry.record(named: "local")?.enabled == false)
        try registry.save(to: fixture.registry)

        let root = try fixture.json()
        let repos = try #require(root["repos"] as? [String: Any])
        let record = try #require(repos["local-12345678"] as? [String: Any])
        let kind = try #require(record["kind"] as? [String: Any])
        #expect(kind["type"] as? String == "Local")
        #expect(kind["source_path"] as? String == "/tmp/source")
        #expect(record["enabled"] as? Bool == false)
        #expect(root["repositories"] == nil)
    }

    @Test("legacy marketplace plugins arrays migrate without dropping provenance or versions")
    func legacyMarketplaceRegistryMigrates() throws {
        let fixture = try PluginRegistryFixture()
        defer { fixture.cleanup() }
        let installed = fixture.directory.appendingPathComponent("demo-abcd1234").path
        let legacy = """
        {
          "version": 1,
          "plugins": [{
            "key": "demo-abcd1234",
            "name": "demo",
            "version": "1.2.3",
            "path": "\(installed)",
            "provenance": {
              "source_url_or_path": "/tmp/marketplace",
              "source_display_name": "Local market",
              "plugin_subdir": "plugins/demo"
            },
            "installed_at": "2026-01-01T00:00:00Z",
            "updated_at": "2026-02-01T00:00:00Z"
          }]
        }
        """
        try Data(legacy.utf8).write(to: fixture.registry)

        let registry = try PluginInstallRegistry.loadOrThrow(from: fixture.registry)
        let record = try #require(registry.record(named: "demo"))
        #expect(record.pluginDetails["demo"]?.version == "1.2.3")
        #expect(record.marketplace?.sourceURLOrPath == "/tmp/marketplace")
        #expect(record.installedPath == installed)
        try registry.save(to: fixture.registry)

        let saved = try fixture.json()
        #expect(saved["plugins"] == nil)
        let repos = try #require(saved["repos"] as? [String: Any])
        let repo = try #require(repos["demo-abcd1234"] as? [String: Any])
        let marketplace = try #require(repo["marketplace"] as? [String: Any])
        #expect(marketplace["plugin_subdir"] as? String == "plugins/demo")
    }

    @Test("missing registry is empty but corrupt or unknown schemas fail closed")
    func corruptRegistryFailsClosed() throws {
        let fixture = try PluginRegistryFixture()
        defer { fixture.cleanup() }
        #expect(try PluginInstallRegistry.loadOrThrow(from: fixture.registry).repositories.isEmpty)

        try Data("{\"version\":1,\"repos\":".utf8).write(to: fixture.registry)
        #expect(throws: PluginRegistryError.self) {
            try PluginInstallRegistry.loadOrThrow(from: fixture.registry)
        }

        try Data("{\"version\":99,\"repos\":{}}".utf8).write(to: fixture.registry)
        #expect(throws: PluginRegistryError.unsupportedVersion(99)) {
            try PluginInstallRegistry.loadOrThrow(from: fixture.registry)
        }

        try Data("{\"version\":1,\"something_else\":[]}".utf8).write(to: fixture.registry)
        #expect(throws: PluginRegistryError.self) {
            try PluginInstallRegistry.loadOrThrow(from: fixture.registry)
        }

        try Data("{\"repos\":{}}".utf8).write(to: fixture.registry)
        #expect(throws: PluginRegistryError.self) {
            try PluginInstallRegistry.loadOrThrow(from: fixture.registry)
        }
    }

    @Test("failed atomic registry saves preserve every byte of the previous Rust registry")
    func failedSavePreservesRegistry() throws {
        let fixture = try PluginRegistryFixture()
        defer { fixture.cleanup() }
        let record = PluginInstallRecord(
            repoKey: "demo-12345678",
            sourceIdentifier: "/tmp/demo",
            path: "/tmp/demo",
            pluginNames: ["demo"]
        )
        let original = PluginInstallRegistry(repositories: [record])
        try original.save(to: fixture.registry)
        let before = try Data(contentsOf: fixture.registry)

        let replacement = PluginInstallRegistry()
        #expect(throws: PluginRegistryError.injectedSaveFailure) {
            try replacement.save(
                to: fixture.registry,
                environment: [PluginInstallRegistry.testFailRegistrySaveEnvironmentKey: "1"]
            )
        }
        #expect(try Data(contentsOf: fixture.registry) == before)
        #expect(try PluginInstallRegistry.loadOrThrow(from: fixture.registry).record(named: "demo") != nil)
    }

    @Test("symlinked plugin registries are refused instead of reading external state")
    func symlinkedRegistryIsRejected() throws {
        let fixture = try PluginRegistryFixture()
        defer { fixture.cleanup() }
        let external = fixture.directory.appendingPathComponent("external-registry.json")
        try Data("{\"version\":1,\"repos\":{}}".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: fixture.registry, withDestinationURL: external)

        #expect(throws: PluginRegistryError.self) {
            try PluginInstallRegistry.loadOrThrow(from: fixture.registry)
        }
    }

    @Test("canonical local subdirectory records retain selector and per-plugin metadata")
    func localSubdirectoryRoundTrips() throws {
        let fixture = try PluginRegistryFixture()
        defer { fixture.cleanup() }
        let original = PluginInstallRecord(
            repoKey: "monorepo-12345678",
            sourceIdentifier: "/tmp/monorepo#plugins/demo",
            path: "/tmp/monorepo",
            pluginNames: ["demo"],
            subdirectory: "plugins/demo",
            pluginDetails: ["demo": PluginRepositoryPlugin(
                subdirectory: "plugins/demo",
                version: "3.0.0"
            )]
        )
        try PluginInstallRegistry(repositories: [original]).save(to: fixture.registry)

        let loaded = try #require(
            PluginInstallRegistry.loadOrThrow(from: fixture.registry).record(named: "demo")
        )
        #expect(loaded.sourceIdentifier == "/tmp/monorepo#plugins/demo")
        #expect(loaded.subdirectory == "plugins/demo")
        #expect(loaded.pluginDetails["demo"]?.version == "3.0.0")
        #expect(loaded.pluginDetails["demo"]?.subdirectory == "plugins/demo")
    }
}

private struct PluginRegistryFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-plugin-registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var registry: URL { directory.appendingPathComponent("registry.json") }

    func json() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: registry)) as? [String: Any])
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
