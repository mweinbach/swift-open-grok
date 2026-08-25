import Foundation
import OpenGrokHooks
import OpenGrokPluginMarketplace
import OpenGrokSamplingTypes
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokWorkspace
import Testing
@testable import OpenGrokCLI

private struct LiveGlobalHookSourceFixture {
    let root: URL
    let workspace: URL
    let home: URL
    let ownerHooks: URL
    let configuredHooks: URL
    let environment: [String: String]

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-live-global-hooks-\(UUID().uuidString)")
        workspace = root.appendingPathComponent("repository")
        home = root.appendingPathComponent("owner")
        ownerHooks = home.appendingPathComponent("hooks")
        configuredHooks = root.appendingPathComponent("owner-configured-hooks")
        for directory in [workspace, home, ownerHooks, configuredHooks] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "GROK_SANDBOX": "off",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func command(touching marker: URL) -> String {
        #if os(Windows)
        return "type nul > \"\(marker.path)\""
        #else
        return "/usr/bin/touch '\(marker.path)'"
        #endif
    }

    func hookDocument(command: String) -> [String: Any] {
        [
            "hooks": [
                "PreToolUse": [
                    ["hooks": [["type": "command", "command": command]]],
                ],
            ],
        ]
    }

    @discardableResult
    func writeHook(named name: String, command: String, directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("\(name).json")
        try JSONSerialization.data(withJSONObject: hookDocument(command: command)).write(to: path)
        return path
    }

    func writeSourceRegistry(_ lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(
            to: home.appendingPathComponent("hooks-paths"),
            atomically: true,
            encoding: .utf8
        )
    }

    @discardableResult
    func registerPlugin(
        named name: String,
        command: String,
        enabled: Bool = true,
        inline: Bool = false,
        installedPath: URL? = nil,
        subdirectory: String? = nil
    ) throws -> URL {
        let location = PluginInstallLocation(grokHome: home)
        let repositoryKey = "\(name)-01234567"
        let repository = installedPath ?? location.installDirectory.appendingPathComponent(repositoryKey)
        let pluginRoot = subdirectory.map { repository.appendingPathComponent($0) } ?? repository
        try FileManager.default.createDirectory(at: pluginRoot, withIntermediateDirectories: true)

        var manifest: [String: Any] = ["name": name]
        if inline {
            manifest["hooks"] = hookDocument(command: command)
        } else {
            try writeHook(named: "hooks", command: command, directory: pluginRoot.appendingPathComponent("hooks"))
        }
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: pluginRoot.appendingPathComponent("plugin.json"))

        let record = PluginInstallRecord(
            repoKey: repositoryKey,
            sourceIdentifier: repository.path,
            path: repository.path,
            pluginNames: [name],
            enabled: enabled,
            installedPath: repository.path,
            pluginDetails: [name: PluginRepositoryPlugin(subdirectory: subdirectory)]
        )
        var registry = PluginInstallRegistry.load(from: location.registryURL)
        registry.repositories.append(record)
        try registry.save(to: location.registryURL)
        return pluginRoot
    }

    func load(environment override: [String: String]? = nil) -> LiveHooksComposition.Loaded {
        LiveHooksComposition.load(
            sessionId: "live-global-hook-source",
            workspaceRoot: workspace,
            environment: override ?? environment,
            projectTrusted: false
        )
    }

    func invokeRealTool(environment override: [String: String]? = nil) async throws {
        let effectiveEnvironment = override ?? environment
        let executor = try await LiveToolExecutor(
            processBackend: LocalShellProcessBackend(inheritedEnvironment: effectiveEnvironment),
            sessionID: "live-global-hook-source",
            workingDirectory: workspace,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            fileAccessPolicy: .allowAll,
            environment: effectiveEnvironment,
            permissionOptions: CLIPermissionOptions(allowRules: ["Bash"])
        )
        #if os(Windows)
        let command = "ver > nul"
        #else
        let command = "/usr/bin/true"
        #endif
        let result = await executor.invoke(
            sessionID: "live-global-hook-source",
            workingDirectory: workspace,
            call: ToolCall(
                id: "actual-configured-hook-tool",
                name: "run_terminal_cmd",
                arguments: #"{"command":"\#(command)"}"#
            )
        )
        await executor.shutdown()
        if case .failure(let error) = result {
            throw NSError(
                domain: "LiveGlobalHookSourceFixture",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "actual live tool failed: \(error)"]
            )
        }
    }
}

@Suite("live owner-approved and installed-plugin hooks execute through the actual tool gate")
struct LiveGlobalHookSourceParityTests {
    @Test("configured absolute hook sources run without admitting untrusted project hooks")
    func configuredOwnerSourceInvokesThroughTheRealToolExecutor() async throws {
        let fixture = try LiveGlobalHookSourceFixture()
        defer { fixture.dispose() }
        let ownerMarker = fixture.root.appendingPathComponent("owner-hook-executed")
        let configuredMarker = fixture.root.appendingPathComponent("configured-hook-executed")
        let projectMarker = fixture.root.appendingPathComponent("untrusted-project-executed")
        try fixture.writeHook(
            named: "owner",
            command: fixture.command(touching: ownerMarker),
            directory: fixture.ownerHooks
        )
        try fixture.writeHook(
            named: "configured",
            command: fixture.command(touching: configuredMarker),
            directory: fixture.configuredHooks
        )
        try fixture.writeHook(
            named: "hostile",
            command: fixture.command(touching: projectMarker),
            directory: fixture.workspace.appendingPathComponent(".opengrok/hooks")
        )
        try fixture.writeSourceRegistry([fixture.configuredHooks.path, fixture.configuredHooks.path])

        let loaded = fixture.load()
        #expect(loaded.result.errors.isEmpty)
        #expect(loaded.result.registry.allHooks().count == 2)
        #expect(loaded.result.registry.allHooks().allSatisfy { $0.name.hasPrefix("global/") })

        try await fixture.invokeRealTool()

        #expect(FileManager.default.fileExists(atPath: ownerMarker.path))
        #expect(FileManager.default.fileExists(atPath: configuredMarker.path))
        #expect(!FileManager.default.fileExists(atPath: projectMarker.path))
    }

    @Test("config hooks keep first-wins precedence over matching configured-source hooks")
    func configurationWinsOverDuplicateConfiguredFile() throws {
        let fixture = try LiveGlobalHookSourceFixture()
        defer { fixture.dispose() }
        let marker = fixture.root.appendingPathComponent("deduplicated")
        let command = fixture.command(touching: marker)
        let tomlCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        try """
        [[hooks.PreToolUse]]
        [[hooks.PreToolUse.hooks]]
        type = "command"
        command = "\(tomlCommand)"
        """.write(to: fixture.home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try fixture.writeHook(named: "duplicate", command: command, directory: fixture.configuredHooks)
        try fixture.writeSourceRegistry([fixture.configuredHooks.path])

        let loaded = fixture.load()
        let hook = try #require(loaded.result.registry.allHooks().first)

        #expect(loaded.result.errors.isEmpty)
        #expect(loaded.result.registry.count == 1)
        #expect(hook.name.hasPrefix("config/"))
        #expect(hook.sourceKind == .user)
    }

    @Test("enabled trusted installed plugin hook files execute and carry authoritative plugin variables")
    func trustedEnabledPluginHookExecutes() async throws {
        let fixture = try LiveGlobalHookSourceFixture()
        defer { fixture.dispose() }
        let marker = fixture.root.appendingPathComponent("installed-plugin-executed")
        let pluginRoot = try fixture.registerPlugin(
            named: "trusted-plugin",
            command: fixture.command(touching: marker)
        )

        let loaded = fixture.load()
        let hook = try #require(loaded.result.registry.allHooks().first)
        #expect(loaded.result.errors.isEmpty)
        #expect(hook.name.hasPrefix("plugin/trusted-plugin/"))
        #expect(hook.sourceKind == .plugin)
        #expect(hook.extraEnvironment["GROK_PLUGIN_ROOT"] == pluginRoot.path)
        #expect(hook.extraEnvironment["CLAUDE_PLUGIN_ROOT"] == pluginRoot.path)
        #expect(hook.extraEnvironment["GROK_PLUGIN_DATA"]?.contains("plugin-data") == true)

        try await fixture.invokeRealTool()

        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("trusted registered plugin subdirectories resolve without widening installation authority")
    func trustedPluginSubdirectoryExecutes() async throws {
        let fixture = try LiveGlobalHookSourceFixture()
        defer { fixture.dispose() }
        let marker = fixture.root.appendingPathComponent("plugin-subdirectory-executed")
        try fixture.registerPlugin(
            named: "nested-plugin",
            command: fixture.command(touching: marker),
            subdirectory: "packages/nested-plugin"
        )

        let loaded = fixture.load()
        #expect(loaded.result.errors.isEmpty)
        #expect(loaded.result.registry.allHooks().first?.name.hasPrefix("plugin/nested-plugin/") == true)

        try await fixture.invokeRealTool()

        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("enabled inline plugin manifest hooks execute through the same live permission gate")
    func trustedInlinePluginHookExecutes() async throws {
        let fixture = try LiveGlobalHookSourceFixture()
        defer { fixture.dispose() }
        let marker = fixture.root.appendingPathComponent("inline-plugin-executed")
        try fixture.registerPlugin(
            named: "inline-plugin",
            command: fixture.command(touching: marker),
            inline: true
        )

        let loaded = fixture.load()
        #expect(loaded.result.errors.isEmpty)
        #expect(loaded.result.registry.allHooks().first?.name.hasPrefix("plugin/inline-plugin/") == true)

        try await fixture.invokeRealTool()

        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("disabled installed plugin hooks never become executable")
    func disabledInstalledPluginCannotExecute() async throws {
        let fixture = try LiveGlobalHookSourceFixture()
        defer { fixture.dispose() }
        let marker = fixture.root.appendingPathComponent("disabled-plugin-executed")
        try fixture.registerPlugin(
            named: "disabled-plugin",
            command: fixture.command(touching: marker),
            enabled: false
        )

        #expect(fixture.load().result.registry.isEmpty)

        try await fixture.invokeRealTool()

        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("a forged registered installation outside the owner plugin directory cannot run")
    func registeredPluginCannotEscapeOwnerInstallRoot() async throws {
        let fixture = try LiveGlobalHookSourceFixture()
        defer { fixture.dispose() }
        let marker = fixture.root.appendingPathComponent("escaped-plugin-executed")
        try fixture.registerPlugin(
            named: "escaped-plugin",
            command: fixture.command(touching: marker),
            installedPath: fixture.workspace.appendingPathComponent("untrusted-plugin")
        )

        let loaded = fixture.load()
        #expect(loaded.result.registry.isEmpty)
        #expect(loaded.result.errors.contains { $0.description.contains("escapes the trusted owner") })

        try await fixture.invokeRealTool()

        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    #if !os(Windows)
    @Test("a symbolic-link configured JSON never reaches the actual tool hook subprocess")
    func hostileConfiguredJSONNeverExecutes() async throws {
        let fixture = try LiveGlobalHookSourceFixture()
        defer { fixture.dispose() }
        let marker = fixture.root.appendingPathComponent("hostile-configured-executed")
        let outside = try fixture.writeHook(
            named: "outside",
            command: fixture.command(touching: marker),
            directory: fixture.workspace
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.configuredHooks.appendingPathComponent("malicious.json"),
            withDestinationURL: outside
        )
        try fixture.writeSourceRegistry([fixture.configuredHooks.path])

        let loaded = fixture.load()
        #expect(loaded.result.registry.isEmpty)
        #expect(loaded.result.errors.contains { $0.description.contains("symbolic-link") })

        try await fixture.invokeRealTool()

        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("a symbolic-link plugin registry cannot authorize a forged installed hook")
    func symlinkedInstalledPluginRegistryCannotExecute() async throws {
        let fixture = try LiveGlobalHookSourceFixture()
        defer { fixture.dispose() }
        let marker = fixture.root.appendingPathComponent("symlink-plugin-registry-executed")
        try fixture.registerPlugin(
            named: "registry-plugin",
            command: fixture.command(touching: marker)
        )
        let location = PluginInstallLocation(grokHome: fixture.home)
        let copiedRegistry = fixture.root.appendingPathComponent("forged-registry.json")
        try FileManager.default.moveItem(at: location.registryURL, to: copiedRegistry)
        try FileManager.default.createSymbolicLink(at: location.registryURL, withDestinationURL: copiedRegistry)

        let loaded = fixture.load()
        #expect(loaded.result.registry.isEmpty)
        #expect(loaded.result.errors.contains { $0.description.contains("symbolic-link") })

        try await fixture.invokeRealTool()

        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("a symbolic-link plugin hook file never becomes an executable trusted hook")
    func symlinkedInstalledPluginHookCannotExecute() async throws {
        let fixture = try LiveGlobalHookSourceFixture()
        defer { fixture.dispose() }
        let marker = fixture.root.appendingPathComponent("symlink-plugin-hook-executed")
        let pluginRoot = try fixture.registerPlugin(
            named: "symlink-plugin",
            command: fixture.command(touching: marker)
        )
        let original = pluginRoot.appendingPathComponent("hooks/hooks.json")
        let outside = fixture.root.appendingPathComponent("outside-plugin-hook.json")
        try FileManager.default.moveItem(at: original, to: outside)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: outside)

        let loaded = fixture.load()
        #expect(loaded.result.registry.isEmpty)
        #expect(loaded.result.errors.contains { $0.description.contains("symbolic-link") })

        try await fixture.invokeRealTool()

        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("a hard-linked plugin hook file cannot execute through a writable alias")
    func hardLinkedInstalledPluginHookCannotExecute() async throws {
        let fixture = try LiveGlobalHookSourceFixture()
        defer { fixture.dispose() }
        let marker = fixture.root.appendingPathComponent("hard-linked-plugin-hook-executed")
        let pluginRoot = try fixture.registerPlugin(
            named: "hardlink-plugin",
            command: fixture.command(touching: marker)
        )
        let original = pluginRoot.appendingPathComponent("hooks/hooks.json")
        try FileManager.default.linkItem(
            at: original,
            to: fixture.root.appendingPathComponent("outside-plugin-hook-alias.json")
        )

        let loaded = fixture.load()
        #expect(loaded.result.registry.isEmpty)
        #expect(loaded.result.errors.contains { $0.description.contains("hard-link aliases") })

        try await fixture.invokeRealTool()

        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("a symbolic-link owner home cannot activate either user TOML or global JSON hooks")
    func symlinkedOwnerHomeDisablesAllOwnerExecutableHookLayers() throws {
        let fixture = try LiveGlobalHookSourceFixture()
        defer { fixture.dispose() }
        let marker = fixture.root.appendingPathComponent("symlink-home-executed")
        let command = fixture.command(touching: marker)
        try """
        [[hooks.PreToolUse]]
        [[hooks.PreToolUse.hooks]]
        type = "command"
        command = "\(command)"
        """.write(to: fixture.home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try fixture.writeHook(named: "owner", command: command, directory: fixture.ownerHooks)
        let alias = fixture.root.appendingPathComponent("owner-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.home)
        var environment = fixture.environment
        environment["OPENGROK_HOME"] = alias.path

        let loaded = fixture.load(environment: environment)

        #expect(loaded.result.registry.isEmpty)
        #expect(loaded.result.errors.contains { $0.description.contains("symbolic-link") })
    }
    #endif
}
