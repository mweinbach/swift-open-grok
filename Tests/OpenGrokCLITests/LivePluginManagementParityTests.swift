import Dispatch
import Foundation
import OpenGrokFileUtils
import OpenGrokPluginMarketplace
import Testing
@testable import OpenGrokCLI

@Suite("live plugin and marketplace management parity")
struct LivePluginManagementParityTests {
    @Test("local and remote installs both fail closed without explicit trust")
    func allSourcesRequireExplicitTrust() async throws {
        let fixture = try PluginManagementFixture()
        defer { fixture.cleanup() }
        let source = try fixture.makePlugin(name: "trusted-local", version: "1.0.0")

        let local = await fixture.run(["plugin", "install", source.path])
        #expect(local.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(local.stderr.contains("requires confirmation"))
        #expect(local.stderr.contains("--trust"))
        #expect(!FileManager.default.fileExists(atPath: fixture.registry.path))

        let remote = await fixture.run([
            "plugin", "install", "https://example.invalid/plugin.git"
        ])
        #expect(remote.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(remote.stderr.contains("from git repo"))
        #expect(remote.stderr.contains("--trust"))
        #expect(!FileManager.default.fileExists(atPath: fixture.registry.path))
    }

    @Test("trusted local installs write the canonical Rust registry and expose real CLI details")
    func trustedInstallProducesCanonicalRegistry() async throws {
        let fixture = try PluginManagementFixture()
        defer { fixture.cleanup() }
        let source = try fixture.makePlugin(
            name: "formatter",
            version: "1.2.3",
            description: "Formats source files"
        )

        let installed = await fixture.run(["plugin", "install", source.path, "--trust"])
        #expect(installed.status == CLIRunner.ExitCode.success.rawValue)
        #expect(installed.stdout.contains("Installed 1 plugin(s)"))
        let registry = try PluginInstallRegistry.loadOrThrow(from: fixture.registry)
        let record = try #require(registry.record(named: "formatter"))
        #expect(record.pluginDetails["formatter"]?.version == "1.2.3")
        #expect(record.installedPath != source.path)
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.registry)) as? [String: Any]
        )
        #expect(json["repos"] != nil)
        #expect(json["repositories"] == nil)

        let details = await fixture.run(["plugin", "details", "formatter"])
        #expect(details.status == CLIRunner.ExitCode.success.rawValue)
        #expect(details.stdout.contains("formatter v1.2.3"))
        #expect(details.stdout.contains("Formats source files"))
    }

    @Test("unpinned file-URL git plugins update through a validated staged replacement")
    func directGitPluginsUpdateTransactionally() async throws {
        let fixture = try PluginManagementFixture()
        defer { fixture.cleanup() }
        let source = try fixture.makePlugin(name: "git-update", version: "1.0.0")
        try fixture.initializeGitPlugin(source)
        let remote = source.absoluteString

        let installed = await fixture.run(["plugin", "install", remote, "--trust"])
        #expect(installed.status == CLIRunner.ExitCode.success.rawValue)
        let initial = try #require(
            PluginInstallRegistry.loadOrThrow(from: fixture.registry).record(named: "git-update")
        )
        #expect(initial.sha == nil)
        #expect(initial.commit != nil)

        try fixture.writeManifest(name: "git-update", version: "2.0.0", directory: source)
        try fixture.git(["add", "-A"], in: source)
        try fixture.git(["commit", "--quiet", "-m", "update plugin"], in: source)

        let updated = await fixture.run(["plugin", "update", "git-update"])
        #expect(updated.status == CLIRunner.ExitCode.success.rawValue)
        #expect(updated.stdout.contains(": updated ("))
        let current = try #require(
            PluginInstallRegistry.loadOrThrow(from: fixture.registry).record(named: "git-update")
        )
        #expect(current.pluginDetails["git-update"]?.version == "2.0.0")
        #expect(current.commit != initial.commit)
    }

    @Test("failed remote fetch leaves the previous git checkout and registry completely intact")
    func failedGitFetchPreservesInstalledPlugin() async throws {
        let fixture = try PluginManagementFixture()
        defer { fixture.cleanup() }
        let source = try fixture.makePlugin(name: "git-failure", version: "1.0.0")
        try fixture.initializeGitPlugin(source)
        let installed = await fixture.run([
            "plugin", "install", source.absoluteString, "--trust"
        ])
        #expect(installed.status == CLIRunner.ExitCode.success.rawValue)
        let original = try #require(
            PluginInstallRegistry.loadOrThrow(from: fixture.registry).record(named: "git-failure")
        )
        let root = URL(fileURLWithPath: try #require(original.installedPath))
        let before = try Data(contentsOf: fixture.registry)
        try FileManager.default.removeItem(at: source)

        let started = Date()
        let failed = await fixture.run(["plugin", "update", "git-failure"])
        #expect(failed.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(FileManager.default.fileExists(atPath: root.path))
        #expect(try Data(contentsOf: fixture.registry) == before)
    }

    @Test("local copies skip nested file and directory symlinks instead of exposing external data")
    func localInstallSkipsAllSymlinks() async throws {
        let fixture = try PluginManagementFixture()
        defer { fixture.cleanup() }
        let source = try fixture.makePlugin(name: "safe-copy", version: "1.0.0")
        let secret = fixture.root.appendingPathComponent("external-secret.txt")
        try Data("private".utf8).write(to: secret)
        let externalDirectory = fixture.root.appendingPathComponent("external-directory")
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("stolen-secret"),
            withDestinationURL: secret
        )
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("stolen-directory"),
            withDestinationURL: externalDirectory
        )

        let result = await fixture.run(["plugin", "install", source.path, "--trust"])
        #expect(
            result.status == CLIRunner.ExitCode.success.rawValue,
            "local plugin installation failed: \(result.stderr)"
        )
        let record = try #require(
            PluginInstallRegistry.loadOrThrow(from: fixture.registry).record(named: "safe-copy")
        )
        let installed = URL(fileURLWithPath: try #require(record.installedPath))
        #expect(!FileManager.default.fileExists(atPath: installed.appendingPathComponent("stolen-secret").path))
        #expect(!FileManager.default.fileExists(atPath: installed.appendingPathComponent("stolen-directory").path))
    }

    @Test("root symlinks and parent-traversing subdirectories never become trusted installations")
    func unsafePluginPathsAreRejected() async throws {
        let fixture = try PluginManagementFixture()
        defer { fixture.cleanup() }
        let source = try fixture.makePlugin(name: "safe", version: "1.0.0")
        let alias = fixture.root.appendingPathComponent("source-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)

        let symlink = await fixture.run(["plugin", "install", alias.path, "--trust"])
        #expect(symlink.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(symlink.stderr.contains("symbolic link"))

        let traversal = await fixture.run([
            "plugin", "install", "\(source.path)#../outside", "--trust"
        ])
        #expect(traversal.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(!FileManager.default.fileExists(atPath: fixture.registry.path))
    }

    @Test("enable and disable persist both canonical registry state and upstream config arrays")
    func enableDisablePersistRealState() async throws {
        let fixture = try PluginManagementFixture()
        defer { fixture.cleanup() }
        let source = try fixture.makePlugin(name: "toggle-me", version: "1.0.0")
        try await fixture.install(source)

        let disabled = await fixture.run(["plugin", "disable", "toggle-me"])
        #expect(disabled.status == CLIRunner.ExitCode.success.rawValue)
        #expect(disabled.stdout == "Disabled plugin: toggle-me\n")
        #expect(try PluginInstallRegistry.loadOrThrow(from: fixture.registry)
            .record(named: "toggle-me")?.enabled == false)
        #expect(try String(contentsOf: fixture.config, encoding: .utf8)
            .contains("disabled = [\"toggle-me\"]"))

        let enabled = await fixture.run(["plugin", "enable", "toggle-me"])
        #expect(enabled.status == CLIRunner.ExitCode.success.rawValue)
        #expect(enabled.stdout == "Enabled plugin: toggle-me\n")
        #expect(try PluginInstallRegistry.loadOrThrow(from: fixture.registry)
            .record(named: "toggle-me")?.enabled == true)
        let config = try String(contentsOf: fixture.config, encoding: .utf8)
        #expect(config.contains("enabled = [\"toggle-me\"]"))
        #expect(config.contains("disabled = []"))
    }

    @Test("manifest validation reaches the live parser and rejects invalid manifests")
    func validateManifestThroughExecutable() async throws {
        let fixture = try PluginManagementFixture()
        defer { fixture.cleanup() }
        let source = try fixture.makePlugin(name: "validate-me", version: "2.0.0")

        let valid = await fixture.run(["plugin", "validate", source.path])
        #expect(valid.status == CLIRunner.ExitCode.success.rawValue)
        #expect(valid.stdout.contains("Plugin manifest is valid."))
        #expect(valid.stdout.contains("name: validate-me"))
        #expect(valid.stdout.contains("version: 2.0.0"))

        try Data(#"{"name":"Invalid Name"}"#.utf8)
            .write(to: source.appendingPathComponent(".claude-plugin/plugin.json"))
        let invalid = await fixture.run(["plugin", "validate", source.path])
        #expect(invalid.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(invalid.stderr.contains("invalid plugin manifest"))
    }

    @Test("release tags support dry runs, create real git tags, and refuse dirty worktrees")
    func gitTagManagement() async throws {
        let fixture = try PluginManagementFixture()
        defer { fixture.cleanup() }
        let source = try fixture.makePlugin(name: "tag-me", version: "1.4.0")
        try fixture.git(["init", "--quiet"], in: source)
        try fixture.git(["config", "user.email", "plugin-test@example.com"], in: source)
        try fixture.git(["config", "user.name", "Plugin Test"], in: source)
        try fixture.git(["add", "-A"], in: source)
        try fixture.git(["commit", "--quiet", "-m", "seed plugin"], in: source)

        let dryRun = await fixture.run(["plugin", "tag", source.path, "--dry-run"])
        #expect(dryRun.status == CLIRunner.ExitCode.success.rawValue)
        #expect(dryRun.stdout == "Would create tag: v1.4.0\n")

        let tagged = await fixture.run(["plugin", "tag", source.path])
        #expect(tagged.status == CLIRunner.ExitCode.success.rawValue)
        #expect(tagged.stdout == "Created tag: v1.4.0\n")
        let tags = try fixture.gitOutput(["tag", "--list"], in: source)
        #expect(tags.contains("v1.4.0"))

        try Data("dirty".utf8).write(to: source.appendingPathComponent("dirty.txt"))
        let dirty = await fixture.run(["plugin", "tag", source.path, "--dry-run"])
        #expect(dirty.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(dirty.stderr.contains("Working tree is dirty"))
    }

    @Test("marketplace add/list/update/remove mutate durable upstream config")
    func marketplaceSourceLifecycle() async throws {
        let fixture = try PluginManagementFixture()
        defer { fixture.cleanup() }
        let marketplace = try fixture.makeMarketplace(name: "team-market", plugin: "team-tool")

        let added = await fixture.run(["plugin", "marketplace", "add", marketplace.path])
        #expect(added.status == CLIRunner.ExitCode.success.rawValue)
        #expect(added.stdout.contains("Added marketplace source: team-market"))
        #expect(try String(contentsOf: fixture.config, encoding: .utf8)
            .contains("[[marketplace.sources]]"))

        let listed = await fixture.run(["plugin", "marketplace", "list", "--json"])
        #expect(listed.status == CLIRunner.ExitCode.success.rawValue)
        let sources = try #require(
            JSONSerialization.jsonObject(with: Data(listed.stdout.utf8)) as? [[String: Any]]
        )
        #expect(sources.count == 1)
        #expect(sources.first?["name"] as? String == "team-market")
        #expect(sources.first?["kind"] as? String == "local")

        let refreshed = await fixture.run(["plugin", "marketplace", "update", "team-market"])
        #expect(refreshed.status == CLIRunner.ExitCode.success.rawValue)
        #expect(refreshed.stdout.contains("local — nothing to sync"))

        let removed = await fixture.run(["plugin", "marketplace", "remove", "team-market"])
        #expect(removed.status == CLIRunner.ExitCode.success.rawValue)
        #expect(removed.stdout.contains("Removed marketplace source"))
        #expect(try !String(contentsOf: fixture.config, encoding: .utf8).contains("team-market"))
    }

    @Test("marketplace installs require trust, resolve names, and disappear from available inventory")
    func marketplaceInstallAndAvailableInventory() async throws {
        let fixture = try PluginManagementFixture()
        defer { fixture.cleanup() }
        let marketplace = try fixture.makeMarketplace(
            name: "catalog",
            plugin: "catalog-tool",
            version: "3.2.1"
        )
        try await fixture.addMarketplace(marketplace)

        let before = await fixture.run(["plugin", "list", "--available", "--json"])
        #expect(before.status == CLIRunner.ExitCode.success.rawValue)
        let available = try #require(
            JSONSerialization.jsonObject(with: Data(before.stdout.utf8)) as? [[String: Any]]
        )
        #expect(available.count == 1)
        #expect(available.first?["status"] as? String == "available")
        #expect(available.first?["marketplace"] as? String == "catalog")

        let refused = await fixture.run(["plugin", "install", "catalog-tool"])
        #expect(refused.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(refused.stderr.contains("marketplace \"catalog\""))

        let installed = await fixture.run(["plugin", "install", "catalog-tool", "--trust"])
        #expect(installed.status == CLIRunner.ExitCode.success.rawValue)
        let record = try #require(
            PluginInstallRegistry.loadOrThrow(from: fixture.registry).record(named: "catalog-tool")
        )
        #expect(record.marketplace?.sourceDisplayName == "catalog")
        #expect(record.marketplace?.pluginSubdirectory == "plugins/catalog-tool")

        let after = await fixture.run(["plugin", "list", "--available", "--json"])
        let inventory = try #require(
            JSONSerialization.jsonObject(with: Data(after.stdout.utf8)) as? [[String: Any]]
        )
        #expect(inventory.count == 1)
        #expect(inventory.first?["status"] as? String == "installed")
        #expect(inventory.first?["version"] as? String == "3.2.1")
    }

    @Test("ambiguous marketplace plugins require a qualified marketplace name")
    func marketplaceNameResolution() async throws {
        let fixture = try PluginManagementFixture()
        defer { fixture.cleanup() }
        let first = try fixture.makeMarketplace(name: "alpha", plugin: "same-tool")
        let second = try fixture.makeMarketplace(name: "beta", plugin: "same-tool")
        try await fixture.addMarketplace(first)
        try await fixture.addMarketplace(second)

        let ambiguous = await fixture.run(["plugin", "install", "same-tool", "--trust"])
        #expect(ambiguous.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(ambiguous.stderr.contains("multiple marketplaces"))

        let qualified = await fixture.run(["plugin", "install", "same-tool@beta", "--trust"])
        #expect(qualified.status == CLIRunner.ExitCode.success.rawValue)
        #expect(qualified.stdout.contains("from beta"))
    }

    @Test("invalid replacement manifests cannot delete an installed working marketplace plugin")
    func invalidUpdatePreservesWorkingPlugin() async throws {
        let fixture = try PluginManagementFixture()
        defer { fixture.cleanup() }
        let marketplace = try fixture.makeMarketplace(name: "updates", plugin: "rolling", version: "1.0.0")
        try await fixture.addMarketplace(marketplace)
        let installed = await fixture.run(["plugin", "install", "rolling", "--trust"])
        #expect(installed.status == CLIRunner.ExitCode.success.rawValue)
        let original = try #require(
            PluginInstallRegistry.loadOrThrow(from: fixture.registry).record(named: "rolling")
        )
        let installedRoot = URL(fileURLWithPath: try #require(original.installedPath))
        let before = try Data(contentsOf: fixture.registry)
        let sourceManifest = marketplace.appendingPathComponent(
            "plugins/rolling/.claude-plugin/plugin.json"
        )
        try Data(#"{"name":"INVALID"}"#.utf8).write(to: sourceManifest)

        let failed = await fixture.run(["plugin", "update", "rolling"])
        #expect(failed.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(FileManager.default.fileExists(atPath: installedRoot.path))
        #expect(try Data(contentsOf: fixture.registry) == before)
        let surviving = try #require(
            PluginInstallRegistry.loadOrThrow(from: fixture.registry).record(named: "rolling")
        )
        #expect(surviving.pluginDetails["rolling"]?.version == "1.0.0")
    }

    @Test("registry save failure after staged replacement restores both plugin files and registry")
    func failedUpdateRollsBackFilesAndRegistry() async throws {
        let fixture = try PluginManagementFixture()
        defer { fixture.cleanup() }
        let marketplace = try fixture.makeMarketplace(name: "rollback", plugin: "rollback-tool")
        let source = marketplace.appendingPathComponent("plugins/rollback-tool")
        try Data("old".utf8).write(to: source.appendingPathComponent("marker.txt"))
        try await fixture.addMarketplace(marketplace)
        let first = await fixture.run(["plugin", "install", "rollback-tool", "--trust"])
        #expect(first.status == CLIRunner.ExitCode.success.rawValue)
        let original = try #require(
            PluginInstallRegistry.loadOrThrow(from: fixture.registry).record(named: "rollback-tool")
        )
        let installedRoot = URL(fileURLWithPath: try #require(original.installedPath))
        let registryBefore = try Data(contentsOf: fixture.registry)
        try fixture.writeManifest(name: "rollback-tool", version: "2.0.0", directory: source)
        try Data("new".utf8).write(to: source.appendingPathComponent("marker.txt"))

        var injected = fixture.environment
        injected[PluginInstallRegistry.testFailRegistrySaveEnvironmentKey] = "1"
        let failed = await fixture.run(
            ["plugin", "update", "rollback-tool"],
            environment: injected
        )
        #expect(failed.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(failed.stderr.contains("registry"))
        #expect(try String(contentsOf: installedRoot.appendingPathComponent("marker.txt"), encoding: .utf8)
            == "old")
        #expect(try Data(contentsOf: fixture.registry) == registryBefore)
    }

    @Test("uninstall keeps persistent plugin data only when --keep-data is explicit")
    func uninstallKeepDataParity() async throws {
        let fixture = try PluginManagementFixture()
        defer { fixture.cleanup() }
        let source = try fixture.makePlugin(name: "persistent", version: "1.0.0")
        try await fixture.install(source)
        let record = try #require(
            PluginInstallRegistry.loadOrThrow(from: fixture.registry).record(named: "persistent")
        )
        let installed = try #require(record.installedPath)
        let digest = String(FileChecksum.sha256Hex(installed).prefix(8))
        let data = fixture.home
            .appendingPathComponent("plugin-data/user/\(digest)/persistent")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)

        let kept = await fixture.run(["plugin", "uninstall", "persistent", "--keep-data"])
        #expect(kept.status == CLIRunner.ExitCode.success.rawValue)
        #expect(kept.stdout.contains("data preserved"))
        #expect(FileManager.default.fileExists(atPath: data.path))

        try await fixture.install(source)
        let removed = await fixture.run(["plugin", "uninstall", "persistent"])
        #expect(removed.status == CLIRunner.ExitCode.success.rawValue)
        #expect(!FileManager.default.fileExists(atPath: data.path))
    }

    @Test("uninstall registry-save failure restores the working plugin directory")
    func failedUninstallRollsBackInstallation() async throws {
        let fixture = try PluginManagementFixture()
        defer { fixture.cleanup() }
        let source = try fixture.makePlugin(name: "keep-working", version: "1.0.0")
        try await fixture.install(source)
        let record = try #require(
            PluginInstallRegistry.loadOrThrow(from: fixture.registry).record(named: "keep-working")
        )
        let installed = URL(fileURLWithPath: try #require(record.installedPath))
        let original = try Data(contentsOf: fixture.registry)
        var environment = fixture.environment
        environment[PluginInstallRegistry.testFailRegistrySaveEnvironmentKey] = "1"

        let failed = await fixture.run(
            ["plugin", "uninstall", "keep-working"],
            environment: environment
        )
        #expect(failed.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(FileManager.default.fileExists(atPath: installed.path))
        #expect(try Data(contentsOf: fixture.registry) == original)
    }

    @Test("marketplace removal uninstalls only plugins from the selected source")
    func marketplaceRemovalUninstallsOwnedPlugins() async throws {
        let fixture = try PluginManagementFixture()
        defer { fixture.cleanup() }
        let marketplace = try fixture.makeMarketplace(name: "remove-me", plugin: "owned-tool")
        try await fixture.addMarketplace(marketplace)
        let installed = await fixture.run(["plugin", "install", "owned-tool", "--trust"])
        #expect(installed.status == CLIRunner.ExitCode.success.rawValue)

        let removed = await fixture.run(["plugin", "marketplace", "remove", "remove-me"])
        #expect(removed.status == CLIRunner.ExitCode.success.rawValue)
        #expect(removed.stdout.contains("uninstalled 1 plugin(s): owned-tool"))
        #expect(try PluginInstallRegistry.loadOrThrow(from: fixture.registry).repositories.isEmpty)
    }

    @Test("malformed existing registries refuse installation without overwriting prior bytes")
    func corruptRegistryNeverStartsFresh() async throws {
        let fixture = try PluginManagementFixture()
        defer { fixture.cleanup() }
        let source = try fixture.makePlugin(name: "blocked", version: "1.0.0")
        try FileManager.default.createDirectory(
            at: fixture.registry.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let corrupt = Data("{\"version\":1,\"repos\":".utf8)
        try corrupt.write(to: fixture.registry)

        let refused = await fixture.run(["plugin", "install", source.path, "--trust"])
        #expect(refused.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(refused.stderr.contains("invalid plugin install registry"))
        #expect(try Data(contentsOf: fixture.registry) == corrupt)
    }

    @Test("registry records cannot redirect uninstall outside the managed plugin directory")
    func installedPathEscapeCannotDeleteExternalFiles() async throws {
        let fixture = try PluginManagementFixture()
        defer { fixture.cleanup() }
        let external = fixture.root.appendingPathComponent("external-victim")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("preserve".utf8).write(to: external.appendingPathComponent("important.txt"))
        let forged = PluginInstallRecord(
            repoKey: "forged-12345678",
            sourceIdentifier: "/tmp/forged",
            path: "/tmp/forged",
            pluginNames: ["forged"],
            installedPath: external.path
        )
        try PluginInstallRegistry(repositories: [forged]).save(to: fixture.registry)

        let refused = await fixture.run(["plugin", "uninstall", "forged"])
        #expect(refused.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(refused.stderr.contains("escapes the managed directory"))
        #expect(FileManager.default.fileExists(atPath: external.appendingPathComponent("important.txt").path))
        #expect(try PluginInstallRegistry.loadOrThrow(from: fixture.registry).record(named: "forged") != nil)
    }

    @Test("malformed owner config cannot erase managed marketplace SHA-pinning requirements")
    func malformedOwnerConfigurationCannotBypassManagedPinning() async throws {
        let fixture = try PluginManagementFixture()
        defer { fixture.cleanup() }
        try Data("[marketplace]\nrequire_sha = true\n".utf8)
            .write(to: fixture.home.appendingPathComponent("managed_config.toml"))
        try Data("[marketplace\nrequire_sha = false\n".utf8).write(to: fixture.config)

        let refused = await fixture.run([
            "plugin", "install", "https://example.invalid/unpinned.git", "--trust"
        ])
        #expect(refused.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(refused.stderr.contains("Cannot safely resolve plugin trust policy"))
        #expect(!FileManager.default.fileExists(atPath: fixture.registry.path))
    }

    @Test("managed SHA policy rejects unpinned remote installs before any fetch")
    func managedPolicyRejectsUnpinnedRemote() async throws {
        let fixture = try PluginManagementFixture()
        defer { fixture.cleanup() }
        try Data("[marketplace]\nrequire_sha = true\n".utf8)
            .write(to: fixture.home.appendingPathComponent("managed_config.toml"))
        try Data("[marketplace]\nrequire_sha = false\n".utf8).write(to: fixture.config)

        let refused = await fixture.run([
            "plugin", "install", "https://example.invalid/unpinned.git", "--trust"
        ])
        #expect(refused.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(refused.stderr.contains("refusing unpinned remote plugin code"))
        #expect(!FileManager.default.fileExists(atPath: fixture.registry.path))
    }

    @Test("managed strictKnownMarketplaces blocks local additions and unlisted git sources")
    func managedMarketplaceAllowlistIsEnforced() throws {
        let fixture = try PluginManagementFixture()
        defer { fixture.cleanup() }
        let marketplace = try fixture.makeMarketplace(name: "blocked-local", plugin: "demo")
        let managed = fixture.root.appendingPathComponent("managed-settings.json")
        let policy = """
        {"strictKnownMarketplaces":[{
          "source":"git",
          "url":"https://GitHub.com/Example/Allowed.git"
        }]}
        """
        try Data(policy.utf8).write(to: managed)

        let local = try fixture.runManaged(
            ["plugin", "marketplace", "add", marketplace.path],
            managedSettings: managed
        )
        #expect(local.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(local.stderr.contains("strictKnownMarketplaces"))

        let denied = try fixture.runManaged(
            ["plugin", "marketplace", "add", "https://github.com/other/blocked.git", "--force"],
            managedSettings: managed
        )
        #expect(denied.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(denied.stderr.contains("strictKnownMarketplaces"))

        let allowed = try fixture.runManaged(
            ["plugin", "marketplace", "add", "https://github.com/example/allowed", "--force"],
            managedSettings: managed
        )
        #expect(allowed.status == CLIRunner.ExitCode.success.rawValue)
        #expect(allowed.stdout.contains("Added marketplace source"))
    }

    @Test("malformed protected marketplace policy fails closed before any plugin action")
    func malformedManagedMarketplacePolicyFailsClosed() throws {
        let fixture = try PluginManagementFixture()
        defer { fixture.cleanup() }
        let managed = fixture.root.appendingPathComponent("managed-settings.json")
        try Data("{\"strictKnownMarketplaces\":".utf8).write(to: managed)

        let refused = try fixture.runManaged(
            ["plugin", "list"],
            managedSettings: managed
        )
        #expect(refused.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(refused.stderr.contains("Cannot safely read managed marketplace policy"))
    }

    @Test("marketplace symlink escapes are rejected before plugin inventory is exposed")
    func marketplaceSymlinkEscapeIsRejected() async throws {
        let fixture = try PluginManagementFixture()
        defer { fixture.cleanup() }
        let market = fixture.root.appendingPathComponent("unsafe-market")
        let plugins = market.appendingPathComponent("plugins")
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        let external = try fixture.makePlugin(name: "outside-secret", version: "1.0.0")
        try FileManager.default.createSymbolicLink(
            at: plugins.appendingPathComponent("outside-secret"),
            withDestinationURL: external
        )
        try await fixture.addMarketplace(market)

        let refused = await fixture.run(["plugin", "list", "--available", "--json"])
        #expect(refused.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(refused.stderr.contains("unsafe symbolic link"))
        #expect(refused.stdout.isEmpty)
    }
}

private struct PluginManagementResult {
    var status: Int32
    var stdout: String
    var stderr: String
}

private struct PluginManagementFixture {
    let root: URL
    let home: URL
    let environment: [String: String]

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-plugin-management-\(UUID().uuidString)")
        home = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        environment = ["OPENGROK_HOME": home.path, "HOME": root.path]
    }

    var config: URL { home.appendingPathComponent("config.toml") }
    var registry: URL { home.appendingPathComponent("installed-plugins/registry.json") }

    func makePlugin(
        name: String,
        version: String,
        description: String? = nil
    ) throws -> URL {
        let directory = root.appendingPathComponent("source-\(name)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeManifest(name: name, version: version, description: description, directory: directory)
        return directory
    }

    func makeMarketplace(
        name: String,
        plugin: String,
        version: String = "1.0.0"
    ) throws -> URL {
        let marketplace = root.appendingPathComponent(name)
        let directory = marketplace.appendingPathComponent("plugins/\(plugin)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeManifest(name: plugin, version: version, directory: directory)
        return marketplace
    }

    func writeManifest(
        name: String,
        version: String,
        description: String? = nil,
        directory: URL
    ) throws {
        let manifestDirectory = directory.appendingPathComponent(".claude-plugin")
        try FileManager.default.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
        var object: [String: Any] = ["name": name, "version": version]
        if let description { object["description"] = description }
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: manifestDirectory.appendingPathComponent("plugin.json"))
    }

    func install(_ source: URL) async throws {
        let result = await run(["plugin", "install", source.path, "--trust"])
        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        guard result.status == CLIRunner.ExitCode.success.rawValue else {
            throw CLIApplicationError.failed(result.stderr)
        }
    }

    func addMarketplace(_ source: URL) async throws {
        let result = await run(["plugin", "marketplace", "add", source.path])
        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        guard result.status == CLIRunner.ExitCode.success.rawValue else {
            throw CLIApplicationError.failed(result.stderr)
        }
    }

    func initializeGitPlugin(_ source: URL) throws {
        try git(["init", "--quiet"], in: source)
        try git(["config", "user.email", "plugin-test@example.com"], in: source)
        try git(["config", "user.name", "Plugin Test"], in: source)
        try git(["add", "-A"], in: source)
        try git(["commit", "--quiet", "-m", "initial plugin"], in: source)
    }

    func run(
        _ arguments: [String],
        environment override: [String: String]? = nil
    ) async -> PluginManagementResult {
        let (streams, out, err) = CLIStreams.buffered()
        let status = await CLIRunner.run(
            arguments,
            environment: override ?? environment,
            streams: streams,
            application: .live(control: .never)
        )
        return PluginManagementResult(status: status, stdout: out.contents, stderr: err.contents)
    }

    func runManaged(
        _ arguments: [String],
        managedSettings: URL
    ) throws -> PluginManagementResult {
        let command = try CLICommandParser.parseOrThrow(arguments)
        guard case .plugin(let options) = command else {
            throw CLIApplicationError.failed("expected a plugin command")
        }
        let (streams, out, err) = CLIStreams.buffered()
        let status: Int32
        do {
            try LivePluginComposition.run(
                options: options,
                environment: environment,
                streams: streams,
                managedSettingsPath: managedSettings
            )
            status = CLIRunner.ExitCode.success.rawValue
        } catch {
            streams.err("\(error)")
            status = CLIRunner.ExitCode.failure.rawValue
        }
        return PluginManagementResult(status: status, stdout: out.contents, stderr: err.contents)
    }

    func git(_ arguments: [String], in directory: URL) throws {
        _ = try gitOutput(arguments, in: directory)
    }

    func gitOutput(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        try process.run()
        try? output.fileHandleForWriting.close()
        guard completion.wait(timeout: .now() + 15) == .success else {
            process.terminate()
            throw CLIApplicationError.failed("git fixture command timed out")
        }
        let data = try output.fileHandleForReading.readToEnd() ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw CLIApplicationError.failed("git fixture command failed: \(text)")
        }
        return text
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
