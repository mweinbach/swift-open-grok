import Foundation
import OpenGrokConfig
import OpenGrokFastWorktree
import OpenGrokHooks
import OpenGrokLSP
import OpenGrokMCP
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokToolRegistry
import OpenGrokWorkspace
import Testing
@testable import OpenGrokCLI

private struct LiveWorkspaceTrustIdentityFixture {
    let root: URL
    let ownerHome: URL
    let openGrokHome: URL
    let source: URL
    let environment: [String: String]

    init() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "open-grok-workspace-trust-identity-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        root = temporaryRoot.standardizedFileURL.resolvingSymlinksInPath()
        ownerHome = root.appendingPathComponent("owner", isDirectory: true)
        openGrokHome = ownerHome.appendingPathComponent(".opengrok", isDirectory: true)
        source = root.appendingPathComponent("source", isDirectory: true)
        for directory in [ownerHome, openGrokHome, source] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        var variables = [
            "HOME": ownerHome.path,
            "OPENGROK_HOME": openGrokHome.path,
            "GROK_FOLDER_TRUST": "1",
            "GROK_LSP_TOOLS": "1",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
        #if os(Windows)
        if let systemRoot = ProcessInfo.processInfo.environment["SystemRoot"] {
            variables["SystemRoot"] = systemRoot
        }
        if let commandInterpreter = ProcessInfo.processInfo.environment["COMSPEC"] {
            variables["COMSPEC"] = commandInterpreter
        }
        #endif
        environment = variables
        try initializeRepository(at: source, contents: "source repository\n")
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func initializeRepository(at repository: URL, contents: String) throws {
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try git(["init", "--quiet"], cwd: repository)
        try contents.write(
            to: repository.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try git(["add", "README.md"], cwd: repository)
        try commit(in: repository)
    }

    func commit(in repository: URL) throws {
        try git([
            "-c", "user.email=trust-parity@example.test",
            "-c", "user.name=Trust Parity",
            "commit", "--quiet", "-m", "initial"
        ], cwd: repository)
    }

    func git(_ arguments: [String], cwd: URL) throws {
        let result = try runGit(arguments, cwd: cwd)
        guard result.exitCode == 0 else {
            throw NSError(
                domain: "LiveWorkspaceTrustIdentityParityTests",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: result.stderr]
            )
        }
    }

    func makeLinked(name: String = "linked") throws -> URL {
        let destination = root.appendingPathComponent(name, isDirectory: true)
        try git(["worktree", "add", "--quiet", "--detach", destination.path, "HEAD"], cwd: source)
        return destination.standardizedFileURL.resolvingSymlinksInPath()
    }

    func makeManaged(
        name: String,
        mode: CreationMode,
        sourceRepository: URL? = nil
    ) throws -> URL {
        let registry = WorktreeRegistry(openGrokHome: openGrokHome)
        let destination = registry.poolRoot.appendingPathComponent(name, isDirectory: true)
        let report = try WorktreeBuilder(
            source: source,
            dest: destination,
            creationMode: mode,
            allowedPoolRoot: registry.poolRoot
        ).create()
        try registry.register(WorktreeRecord(
            path: report.worktreePath,
            sourceRepository: sourceRepository ?? source,
            repositoryName: source.lastPathComponent,
            kind: .launch,
            creationMode: report.creationMode,
            head: report.commit
        ))
        return destination.standardizedFileURL.resolvingSymlinksInPath()
    }

    func register(
        checkout: URL,
        sourceRepository: URL,
        creationMode: CreationMode,
        head: String = ""
    ) throws {
        try WorktreeRegistry(openGrokHome: openGrokHome).register(WorktreeRecord(
            path: checkout,
            sourceRepository: sourceRepository,
            repositoryName: sourceRepository.lastPathComponent,
            creationMode: creationMode,
            head: head
        ))
    }

    func grantSourceTrust() throws {
        var store = PersistentFolderTrustStore(environment: environment)
        try store.record(source, trusted: true)
        #expect(PersistentFolderTrustStore(environment: environment).isTrusted(source))
    }

    func writeProject(
        in checkout: URL,
        name: String,
        marker: URL? = nil,
        hookMarker: URL? = nil
    ) throws {
        let configuration = checkout.appendingPathComponent(".opengrok", isDirectory: true)
        let hooks = configuration.appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)

        let command: String
        let arguments: [String]
        #if os(Windows)
        let systemRoot = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        command = URL(fileURLWithPath: systemRoot).appendingPathComponent("System32/cmd.exe").path
        arguments = marker.map { ["/d", "/c", "echo started > \"\($0.path)\""] }
            ?? ["/d", "/c", "exit 0"]
        #else
        command = marker == nil ? "/usr/bin/true" : "/usr/bin/touch"
        arguments = marker.map { [$0.path] } ?? []
        #endif
        let encodedCommand = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
        let encodedArguments = try arguments.map {
            String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
        }.joined(separator: ", ")
        try """
        [workspace_identity]
        checkout = "\(name)"

        [mcp_servers.project_identity]
        command = \(encodedCommand)
        args = [\(encodedArguments)]
        """.write(
            to: configuration.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        let hookCommand: String
        #if os(Windows)
        hookCommand = hookMarker.map { "cmd /d /c echo executed > \"\($0.path)\"" }
            ?? "echo \(name)-project-hook"
        #else
        hookCommand = hookMarker.map { "/usr/bin/touch '\($0.path)'" }
            ?? "echo \(name)-project-hook"
        #endif
        let hookDocument: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["hooks": [["type": "command", "command": hookCommand]]],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: hookDocument).write(
            to: hooks.appendingPathComponent("identity.json")
        )
    }

    func resolve(_ checkout: URL, explicitTrust: Bool = false) -> LiveSecurityContext {
        LiveSecurityContext.resolve(
            workspaceRoot: checkout,
            environment: environment,
            isInteractive: false,
            cli: CLIPermissionOptions(trustFolder: explicitTrust)
        )
    }

    func writeOwnerMCPAndHook(marker: URL) throws {
        let command: String
        let arguments: String
        let hookCommand: String
        #if os(Windows)
        let systemRoot = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        command = URL(fileURLWithPath: systemRoot).appendingPathComponent("System32/cmd.exe").path
        arguments = #"["/d", "/c", "exit 1"]"#
        hookCommand = "cmd /d /c echo executed > \"\(marker.path)\""
        #else
        command = "/usr/bin/false"
        arguments = "[]"
        hookCommand = "/usr/bin/touch '\(marker.path)'"
        #endif
        let encodedCommand = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
        try """
        [mcp_servers.owner_identity]
        command = \(encodedCommand)
        args = \(arguments)
        """.write(
            to: openGrokHome.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        let directory = openGrokHome.appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document: [String: Any] = [
            "hooks": [
                "PreToolUse": [["hooks": [["type": "command", "command": hookCommand]]]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: document).write(
            to: directory.appendingPathComponent("owner.json")
        )
    }

    func writeProjectLSP(in checkout: URL) throws {
        #if os(Windows)
        let command = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows")
            .appendingPathComponent("System32/cmd.exe").path
        #else
        let command = "/usr/bin/true"
        #endif
        let server = LspServerConfig(command: command, args: [], extensions: [".swift": "swift"])
        try JSONEncoder().encode(["project_identity": server]).write(
            to: checkout.appendingPathComponent(".opengrok/lsp.json")
        )
    }

    func executor(for checkout: URL, sessionID: String) async throws -> LiveToolExecutor {
        try await LiveToolExecutor(
            processBackend: LocalShellProcessBackend(inheritedEnvironment: environment),
            sessionID: sessionID,
            workingDirectory: checkout,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            fileAccessPolicy: .allowAll,
            environment: environment,
            permissionOptions: CLIPermissionOptions(allowRules: ["Bash"])
        )
    }

    func attachOwnerAndProjectMCP(to executor: LiveToolExecutor) async throws {
        for name in ["owner_identity", "project_identity"] {
            let server = MCPServer(
                configuration: MCPServerConfiguration(
                    serverInfo: MCPImplementation(name: name, version: "1.0.0"),
                    capabilities: MCPCapabilities(tools: MCPToolsCapability())
                ),
                handler: WorkspaceTrustIdentityMCPHandler()
            )
            let client = MCPClient(transport: MCPInMemoryTransport(server: server))
            let initialization = try await client.initialize()
            #expect(initialization.serverInfo.name == name)
            await executor.mcpSessionConnections.retain(client, as: name)
            let registration = await MCPToolBridge.register(
                provider: MCPClientToolProvider(serverName: name, client: client),
                into: executor.mcpToolset
            )
            #expect(registration.failure == nil)
        }
    }

    func invokeShell(_ executor: LiveToolExecutor, checkout: URL, sessionID: String) async -> Bool {
        #if os(Windows)
        let command = "echo ok"
        #else
        let command = "/usr/bin/true"
        #endif
        let encoded = (try? JSONSerialization.data(withJSONObject: ["command": command])) ?? Data()
        let result = await executor.invoke(
            sessionID: sessionID,
            workingDirectory: checkout,
            call: ToolCall(
                id: UUID().uuidString,
                name: "run_terminal_cmd",
                arguments: String(decoding: encoded, as: UTF8.self)
            )
        )
        guard case .success = result else {
            return false
        }
        return true
    }
}

private actor WorkspaceTrustIdentityMCPHandler: MCPServerHandler {
    func listTools(_ parameters: MCPListToolsParams) async throws -> MCPListToolsResult {
        _ = parameters
        return MCPListToolsResult(tools: [MCPTool(name: "echo", inputSchema: .object([:]))])
    }
}

@Suite("workspace trust identity follows the original Git repository")
struct LiveWorkspaceTrustIdentityParityTests {
    @Test("linked worktrees inherit source trust while loading their own config, hooks, and MCP")
    func linkedWorktreeUsesSourceTrustAndEffectiveCheckoutSources() throws {
        let fixture = try LiveWorkspaceTrustIdentityFixture()
        defer { fixture.dispose() }
        let checkout = try fixture.makeLinked()
        try fixture.writeProject(in: checkout, name: "linked")
        try fixture.grantSourceTrust()

        let identity = LiveWorkspaceTrustIdentity.resolve(
            workingDirectory: checkout,
            environment: fixture.environment
        )
        let security = fixture.resolve(checkout)
        let hooks = LiveHooksComposition.load(
            sessionId: "linked-trust-identity",
            workspaceRoot: checkout,
            environment: fixture.environment
        ).result.registry.allHooks()
        let servers = MCPConfigLoader.load(from: security.document).enabledServers

        #expect(identity == fixture.source)
        #expect(security.projectTrusted)
        #expect(security.document[path: ["workspace_identity", "checkout"]]?.stringValue == "linked")
        #expect(hooks.contains { $0.command == "echo linked-project-hook" })
        #expect(servers.map(\.name) == ["project_identity"])
    }

    @Test("source grants also apply to nested directories inside a linked worktree")
    func nestedLinkedCheckoutCollapsesToThePrimaryRepository() throws {
        let fixture = try LiveWorkspaceTrustIdentityFixture()
        defer { fixture.dispose() }
        let checkout = try fixture.makeLinked(name: "nested-linked")
        let nested = checkout.appendingPathComponent("crates/inner", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try fixture.writeProject(in: checkout, name: "nested-linked")
        try fixture.grantSourceTrust()

        #expect(LiveWorkspaceTrustIdentity.resolve(
            workingDirectory: nested,
            openGrokHome: fixture.openGrokHome
        ) == fixture.source)
        let security = fixture.resolve(nested)
        #expect(security.projectTrusted)
        #expect(security.document[path: ["workspace_identity", "checkout"]]?.stringValue == "nested-linked")
    }

    @Test("--trust from a linked checkout persists the primary repository identity")
    func explicitLinkedCheckoutGrantPersistsTheSharedSourceKey() throws {
        let fixture = try LiveWorkspaceTrustIdentityFixture()
        defer { fixture.dispose() }
        let checkout = try fixture.makeLinked(name: "explicit-linked")
        try fixture.writeProject(in: checkout, name: "explicit-linked")

        #expect(fixture.resolve(checkout).projectTrusted == false)
        #expect(fixture.resolve(checkout, explicitTrust: true).projectTrusted)

        let persisted = PersistentFolderTrustStore(environment: fixture.environment)
        #expect(persisted.isTrusted(fixture.source))
        #expect(persisted.isTrusted(checkout) == false)
        #expect(fixture.resolve(checkout).projectTrusted)
        #expect(fixture.resolve(fixture.source).projectTrusted)
    }

    @Test("trust and revoke slash controls mutate the source grant but reload the effective checkout")
    func linkedCheckoutSlashControlsShareThePrimaryRepositoryGrant() async throws {
        let fixture = try LiveWorkspaceTrustIdentityFixture()
        defer { fixture.dispose() }
        let checkout = try fixture.makeLinked(name: "slash-linked")
        try fixture.writeProject(in: checkout, name: "slash-linked")
        try fixture.grantSourceTrust()
        let executor = try await LiveToolExecutor(
            processBackend: LocalShellProcessBackend(inheritedEnvironment: fixture.environment),
            sessionID: "linked-slash-trust",
            workingDirectory: checkout,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            fileAccessPolicy: .allowAll,
            environment: fixture.environment
        )
        #expect(executor.projectTrusted)

        let revoked = await LiveFolderTrustControls.change(
            trusted: false,
            workingDirectory: checkout,
            sessionID: "linked-slash-trust",
            environment: fixture.environment,
            executor: executor
        )
        #expect(revoked.contains(fixture.source.path))
        #expect(PersistentFolderTrustStore(environment: fixture.environment).isTrusted(fixture.source) == false)
        #expect(executor.projectTrusted == false)

        let restored = await LiveFolderTrustControls.change(
            trusted: true,
            workingDirectory: checkout,
            sessionID: "linked-slash-trust",
            environment: fixture.environment,
            executor: executor
        )
        #expect(restored.contains(fixture.source.path))
        #expect(PersistentFolderTrustStore(environment: fixture.environment).isTrusted(fixture.source))
        #expect(executor.projectTrusted)
        #expect(fixture.resolve(checkout).document[path: ["workspace_identity", "checkout"]]?.stringValue == "slash-linked")
        await executor.shutdown()
    }

    @Test("source revocation immediately removes linked-session project hooks, MCP, and LSP only")
    func revocationBroadcastsAcrossSourceAndLinkedSessionsWithoutDroppingOwnerMCP() async throws {
        let fixture = try LiveWorkspaceTrustIdentityFixture()
        defer { fixture.dispose() }
        let checkout = try fixture.makeLinked(name: "sibling-linked")
        let sourceMarker = fixture.root.appendingPathComponent("source-project-hook-ran")
        let linkedMarker = fixture.root.appendingPathComponent("linked-project-hook-ran")
        let ownerMarker = fixture.root.appendingPathComponent("owner-hook-ran")
        try fixture.writeProject(in: fixture.source, name: "source", hookMarker: sourceMarker)
        try fixture.writeProject(in: checkout, name: "linked", hookMarker: linkedMarker)
        try fixture.writeOwnerMCPAndHook(marker: ownerMarker)
        try fixture.writeProjectLSP(in: fixture.source)
        try fixture.writeProjectLSP(in: checkout)
        try fixture.grantSourceTrust()

        let source = try await fixture.executor(for: fixture.source, sessionID: "source-sibling")
        let linked = try await fixture.executor(for: checkout, sessionID: "linked-sibling")
        try await fixture.attachOwnerAndProjectMCP(to: source)
        try await fixture.attachOwnerAndProjectMCP(to: linked)
        #expect(source.currentToolSpecs().contains { $0.name == "pull_diagnostics" })
        #expect(linked.currentToolSpecs().contains { $0.name == "pull_diagnostics" })

        let sourceBefore = await fixture.invokeShell(source, checkout: fixture.source, sessionID: "source-sibling")
        let linkedBefore = await fixture.invokeShell(linked, checkout: checkout, sessionID: "linked-sibling")
        #expect(sourceBefore)
        #expect(linkedBefore)
        #expect(FileManager.default.fileExists(atPath: sourceMarker.path))
        #expect(FileManager.default.fileExists(atPath: linkedMarker.path))
        try FileManager.default.removeItem(at: sourceMarker)
        try FileManager.default.removeItem(at: linkedMarker)
        try FileManager.default.removeItem(at: ownerMarker)

        let revoked = await LiveFolderTrustControls.change(
            trusted: false,
            workingDirectory: fixture.source,
            sessionID: "source-sibling",
            environment: fixture.environment,
            executor: source
        )
        #expect(revoked.hasPrefix("Untrusted:"))
        #expect(source.projectTrusted == false)
        #expect(linked.projectTrusted == false)
        let sourceConnections = await source.mcpSessionConnections.names()
        let linkedConnections = await linked.mcpSessionConnections.names()
        #expect(sourceConnections == ["owner_identity"])
        #expect(linkedConnections == ["owner_identity"])
        #expect(source.currentToolSpecs().contains { $0.name == "project_identity__echo" } == false)
        #expect(linked.currentToolSpecs().contains { $0.name == "project_identity__echo" } == false)
        #expect(source.currentToolSpecs().contains { $0.name == "owner_identity__echo" })
        #expect(linked.currentToolSpecs().contains { $0.name == "owner_identity__echo" })
        #expect(source.currentToolSpecs().contains { $0.name == "pull_diagnostics" } == false)
        #expect(linked.currentToolSpecs().contains { $0.name == "pull_diagnostics" } == false)

        let sourceAfter = await fixture.invokeShell(source, checkout: fixture.source, sessionID: "source-sibling")
        let linkedAfter = await fixture.invokeShell(linked, checkout: checkout, sessionID: "linked-sibling")
        #expect(sourceAfter)
        #expect(linkedAfter)
        #expect(FileManager.default.fileExists(atPath: sourceMarker.path) == false)
        #expect(FileManager.default.fileExists(atPath: linkedMarker.path) == false)
        #expect(FileManager.default.fileExists(atPath: ownerMarker.path))
        try FileManager.default.removeItem(at: ownerMarker)

        let restored = await LiveFolderTrustControls.change(
            trusted: true,
            workingDirectory: checkout,
            sessionID: "linked-sibling",
            environment: fixture.environment,
            executor: linked
        )
        #expect(restored.hasPrefix("Trusted:"))
        #expect(source.projectTrusted)
        #expect(linked.projectTrusted)
        #expect(source.currentToolSpecs().contains { $0.name == "pull_diagnostics" })
        #expect(linked.currentToolSpecs().contains { $0.name == "pull_diagnostics" })
        let sourceRestored = await fixture.invokeShell(source, checkout: fixture.source, sessionID: "source-sibling")
        let linkedRestored = await fixture.invokeShell(linked, checkout: checkout, sessionID: "linked-sibling")
        #expect(sourceRestored)
        #expect(linkedRestored)
        #expect(FileManager.default.fileExists(atPath: sourceMarker.path))
        #expect(FileManager.default.fileExists(atPath: linkedMarker.path))

        await source.shutdown()
        await linked.shutdown()
    }

    @Test("an externally removed source grant still downgrades every cached trusted sibling")
    func externalGrantRemovalThenUntrustBroadcastsTheAlreadyUntrustedVerdict() async throws {
        let fixture = try LiveWorkspaceTrustIdentityFixture()
        defer { fixture.dispose() }
        let checkout = try fixture.makeLinked(name: "externally-revoked-linked")
        try fixture.writeProject(in: fixture.source, name: "source")
        try fixture.writeProject(in: checkout, name: "linked")
        try fixture.grantSourceTrust()

        let source = try await fixture.executor(for: fixture.source, sessionID: "external-source")
        let linked = try await fixture.executor(for: checkout, sessionID: "external-linked")
        #expect(source.projectTrusted)
        #expect(linked.projectTrusted)

        try FileManager.default.removeItem(
            at: fixture.openGrokHome.appendingPathComponent("trusted_folders.toml")
        )
        #expect(PersistentFolderTrustStore(environment: fixture.environment).isTrusted(fixture.source) == false)

        let result = await LiveFolderTrustControls.change(
            trusted: false,
            workingDirectory: fixture.source,
            sessionID: "external-source",
            environment: fixture.environment,
            executor: source
        )

        #expect(result == "Not currently trusted: \(fixture.source.path)")
        #expect(source.projectTrusted == false)
        #expect(linked.projectTrusted == false)
        #expect(FileManager.default.fileExists(
            atPath: fixture.openGrokHome.appendingPathComponent("trusted_folders.toml").path
        ) == false)

        await source.shutdown()
        await linked.shutdown()
    }

    @Test("failed durable revocation blocks both source and linked sessions before stale hooks can run")
    func failedRevocationPersistenceBlocksEveryTrustedSibling() async throws {
        let fixture = try LiveWorkspaceTrustIdentityFixture()
        defer { fixture.dispose() }
        let checkout = try fixture.makeLinked(name: "failed-revoke-linked")
        try fixture.writeProject(in: fixture.source, name: "source")
        try fixture.writeProject(in: checkout, name: "linked")
        try fixture.grantSourceTrust()

        let source = try await fixture.executor(for: fixture.source, sessionID: "failed-source")
        let linked = try await fixture.executor(for: checkout, sessionID: "failed-linked")
        let lock = fixture.openGrokHome.appendingPathComponent("trusted_folders.toml.lock")
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)

        let result = await LiveFolderTrustControls.change(
            trusted: false,
            workingDirectory: fixture.source,
            sessionID: "failed-source",
            environment: fixture.environment,
            executor: source
        )

        #expect(result.contains("Failed to persist folder trust"))
        #expect(source.projectTrusted == false)
        #expect(linked.projectTrusted == false)
        let sourceBlocked = await fixture.invokeShell(source, checkout: fixture.source, sessionID: "failed-source")
        let linkedBlocked = await fixture.invokeShell(linked, checkout: checkout, sessionID: "failed-linked")
        #expect(sourceBlocked == false)
        #expect(linkedBlocked == false)

        await source.shutdown()
        await linked.shutdown()
    }

    @Test("managed standalone clones use registered source roots and really launch trusted project MCP")
    func registeredStandaloneWorktreeRestoresLiveProjectMCP() async throws {
        let fixture = try LiveWorkspaceTrustIdentityFixture()
        defer { fixture.dispose() }
        let sourceSubdirectory = fixture.source.appendingPathComponent("crates/core", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceSubdirectory, withIntermediateDirectories: true)
        let checkout = try fixture.makeManaged(
            name: "managed-standalone",
            mode: .standalone,
            sourceRepository: sourceSubdirectory
        )
        let marker = fixture.root.appendingPathComponent("managed-mcp-really-started")
        try fixture.writeProject(in: checkout, name: "managed", marker: marker)
        try fixture.grantSourceTrust()

        #expect(LiveWorkspaceTrustIdentity.resolve(
            workingDirectory: checkout,
            environment: fixture.environment
        ) == fixture.source)
        let security = fixture.resolve(checkout)
        #expect(security.projectTrusted)
        #expect(security.document[path: ["workspace_identity", "checkout"]]?.stringValue == "managed")

        let connections = MCPSessionConnections()
        let entries = await LiveMCPComposition.connectConfiguredClientsForHub(
            cwd: checkout.path,
            environment: fixture.environment,
            connections: connections
        )

        #expect(entries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        await connections.shutdown()
    }

    @Test("registered standalone snapshots without Git metadata still use their exact source mapping")
    func registeredPlainStandaloneSnapshotUsesSourceGitRoot() throws {
        let fixture = try LiveWorkspaceTrustIdentityFixture()
        defer { fixture.dispose() }
        let checkout = fixture.openGrokHome.appendingPathComponent("worktrees/plain-snapshot")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try fixture.register(checkout: checkout, sourceRepository: fixture.source, creationMode: .standalone)
        try fixture.writeProject(in: checkout, name: "plain-snapshot")
        try fixture.grantSourceTrust()

        #expect(LiveWorkspaceTrustIdentity.resolve(
            workingDirectory: checkout,
            environment: fixture.environment
        ) == fixture.source)
        #expect(fixture.resolve(checkout).projectTrusted)
    }

    @Test("a forged registry entry cannot transfer trust into an unrelated Git repository")
    func foreignRegisteredRepositoryDoesNotInheritSourceTrust() async throws {
        let fixture = try LiveWorkspaceTrustIdentityFixture()
        defer { fixture.dispose() }
        let foreign = fixture.openGrokHome.appendingPathComponent("worktrees/foreign")
        try fixture.initializeRepository(at: foreign, contents: "unrelated repository\n")
        try fixture.register(checkout: foreign, sourceRepository: fixture.source, creationMode: .gitCheckout)
        let marker = fixture.root.appendingPathComponent("foreign-mcp-must-not-start")
        try fixture.writeProject(in: foreign, name: "foreign", marker: marker)
        try fixture.grantSourceTrust()

        #expect(LiveWorkspaceTrustIdentity.resolve(
            workingDirectory: foreign,
            environment: fixture.environment
        ) == foreign)
        let security = fixture.resolve(foreign)
        #expect(security.projectTrusted == false)
        #expect(security.document[path: ["workspace_identity", "checkout"]] == nil)

        let connections = MCPSessionConnections()
        let entries = await LiveMCPComposition.connectConfiguredClientsForHub(
            cwd: foreign.path,
            environment: fixture.environment,
            connections: connections
        )
        #expect(entries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
        await connections.shutdown()
    }

    @Test("registry records outside the actual owner-managed worktree pool never apply")
    func registryCannotClaimAnUnrelatedRepositoryOutsideItsPool() throws {
        let fixture = try LiveWorkspaceTrustIdentityFixture()
        defer { fixture.dispose() }
        let foreign = fixture.root.appendingPathComponent("outside-registry")
        try fixture.initializeRepository(at: foreign, contents: "unrelated outside repository\n")
        try fixture.register(checkout: foreign, sourceRepository: fixture.source, creationMode: .standalone)
        try fixture.writeProject(in: foreign, name: "outside-registry")
        try fixture.grantSourceTrust()

        #expect(LiveWorkspaceTrustIdentity.resolve(
            workingDirectory: foreign,
            environment: fixture.environment
        ) == foreign)
        #expect(fixture.resolve(foreign).projectTrusted == false)
    }

    @Test("a symlinked registry checkout cannot redirect source trust into a foreign repository")
    func symlinkedManagedRecordCannotEscapeTheOwnerPool() throws {
        #if !os(Windows)
        let fixture = try LiveWorkspaceTrustIdentityFixture()
        defer { fixture.dispose() }
        let foreign = fixture.root.appendingPathComponent("symlink-target")
        try fixture.initializeRepository(at: foreign, contents: "foreign symlink target\n")
        let pool = fixture.openGrokHome.appendingPathComponent("worktrees")
        try FileManager.default.createDirectory(at: pool, withIntermediateDirectories: true)
        let alias = pool.appendingPathComponent("redirected-checkout")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: foreign)
        try fixture.register(checkout: alias, sourceRepository: fixture.source, creationMode: .standalone)
        try fixture.writeProject(in: foreign, name: "symlink-target")
        try fixture.grantSourceTrust()

        #expect(LiveWorkspaceTrustIdentity.resolve(
            workingDirectory: alias,
            environment: fixture.environment
        ) == foreign)
        #expect(fixture.resolve(alias).projectTrusted == false)
        #endif
    }

    @Test("a separate Git directory never widens a linked-worktree grant to its parent")
    func separateGitDirectoryFallsBackToTheLinkedCheckout() throws {
        let fixture = try LiveWorkspaceTrustIdentityFixture()
        defer { fixture.dispose() }
        let checkout = fixture.root.appendingPathComponent("separate-checkout")
        let gitStore = fixture.root.appendingPathComponent("separate-git-store")
        try fixture.git([
            "init", "--quiet", "--separate-git-dir", gitStore.path, checkout.path,
        ], cwd: fixture.root)
        try "separate checkout\n".write(
            to: checkout.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try fixture.git(["add", "README.md"], cwd: checkout)
        try fixture.commit(in: checkout)
        let linked = fixture.root.appendingPathComponent("separate-linked")
        try fixture.git(["worktree", "add", "--quiet", "--detach", linked.path, "HEAD"], cwd: checkout)

        let identity = LiveWorkspaceTrustIdentity.resolve(
            workingDirectory: linked,
            environment: fixture.environment
        )
        #expect(identity == linked)
        #expect(identity != fixture.root)
        #expect(identity != checkout)
    }

    @Test("non-Git directories retain their exact canonical identity and never inherit a foreign repo")
    func nonGitDirectoriesRemainExactlyScoped() throws {
        let fixture = try LiveWorkspaceTrustIdentityFixture()
        defer { fixture.dispose() }
        let plain = fixture.root.appendingPathComponent("plain-workspace")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try fixture.writeProject(in: plain, name: "plain")
        try fixture.grantSourceTrust()

        #expect(LiveWorkspaceTrustIdentity.resolve(
            workingDirectory: plain,
            environment: fixture.environment
        ) == plain)
        #expect(fixture.resolve(plain).projectTrusted == false)
        #expect(fixture.resolve(plain, explicitTrust: true).projectTrusted)
        #expect(PersistentFolderTrustStore(environment: fixture.environment).isTrusted(plain))
    }
}
