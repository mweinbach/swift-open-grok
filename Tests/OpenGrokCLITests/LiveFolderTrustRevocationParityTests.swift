import Foundation
import OpenGrokFastWorktree
import OpenGrokHooks
import OpenGrokLSP
import OpenGrokMCP
import OpenGrokPager
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokTerminalCore
import OpenGrokToolRegistry
import OpenGrokWorkspace
import Testing
@testable import OpenGrokCLI

private struct LiveFolderTrustRevocationFixture {
    let root: URL
    let home: URL
    let state: URL
    let workspace: URL
    let environment: [String: String]

    init(trusted: Bool = true, gitRepository: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-live-trust-revoke-\(UUID().uuidString)")
            .standardizedFileURL.resolvingSymlinksInPath()
        home = root.appendingPathComponent("home")
        state = home.appendingPathComponent(".opengrok")
        workspace = root.appendingPathComponent("workspace")
        for directory in [state, workspace.appendingPathComponent(".opengrok")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if gitRepository {
            let initialized = try runGit(["init", "--quiet"], cwd: workspace)
            guard initialized.exitCode == 0 else {
                throw NSError(domain: "folder-trust-git", code: Int(initialized.exitCode))
            }
        }
        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": state.path,
            "GROK_FOLDER_TRUST": "1",
            "GROK_LSP_TOOLS": "1",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
        if trusted {
            var store = PersistentFolderTrustStore(environment: environment)
            try store.record(workspace, trusted: true)
        }
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeHook(name: String, marker: URL, project: Bool, event: String = "PreToolUse") throws {
        let directory = project
            ? workspace.appendingPathComponent(".opengrok/hooks")
            : state.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(Windows)
        let command = "cmd /d /c echo executed > \"\(marker.path)\""
        #else
        let command = "/usr/bin/touch '\(marker.path)'"
        #endif
        let document: [String: Any] = [
            "hooks": [event: [["hooks": [["type": "command", "command": command]]]]],
        ]
        try JSONSerialization.data(withJSONObject: document)
            .write(to: directory.appendingPathComponent("\(name).json"))
    }

    func makeExecutor(permissionOptions: CLIPermissionOptions? = nil) async throws -> LiveToolExecutor {
        try await LiveToolExecutor(
            processBackend: LocalShellProcessBackend(inheritedEnvironment: environment),
            sessionID: "live-folder-trust",
            workingDirectory: workspace,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            fileAccessPolicy: .allowAll,
            environment: environment,
            permissionOptions: permissionOptions ?? CLIPermissionOptions(allowRules: ["Bash"])
        )
    }

    func change(_ trust: Bool, executor: LiveToolExecutor, directory: URL? = nil) async -> String {
        await LiveFolderTrustControls.change(
            trusted: trust,
            workingDirectory: directory ?? workspace,
            sessionID: "live-folder-trust",
            environment: environment,
            executor: executor
        )
    }

    func invokeShell(_ executor: LiveToolExecutor, id: String = UUID().uuidString) async
        -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError>
    {
        #if os(Windows)
        let command = "echo ok"
        #else
        let command = "/usr/bin/true"
        #endif
        let arguments = (try? String(
            data: JSONSerialization.data(withJSONObject: ["command": command]),
            encoding: .utf8
        )) ?? "{}"
        return await executor.invoke(
            sessionID: "live-folder-trust",
            workingDirectory: workspace,
            call: ToolCall(id: id, name: "run_terminal_cmd", arguments: arguments)
        )
    }

    func writeLSP(marker: URL, project: Bool) throws {
        #if os(Windows)
        let command = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows")
            .appendingPathComponent("System32/cmd.exe").path
        let arguments = ["/d", "/c", "echo started > \"\(marker.path)\""]
        #else
        let command = "/usr/bin/touch"
        let arguments = [marker.path]
        #endif
        let server = LspServerConfig(command: command, args: arguments, extensions: [".swift": "swift"])
        let path = project
            ? workspace.appendingPathComponent(".opengrok/lsp.json")
            : state.appendingPathComponent("lsp.json")
        try JSONEncoder().encode([project ? "project" : "owner": server]).write(to: path)
    }

    func writeMCP(name: String, project: Bool) throws {
        #if os(Windows)
        let command = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows")
            .appendingPathComponent("System32/cmd.exe").path
        let args = #"["/d", "/c", "exit 1"]"#
        #else
        let command = "/usr/bin/false"
        let args = "[]"
        #endif
        let quoted = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
        let config = """
        [mcp_servers.\(name)]
        command = \(quoted)
        args = \(args)
        """
        try config.write(
            to: (project ? workspace.appendingPathComponent(".opengrok") : state)
                .appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
    }
}

private actor FolderTrustMCPHandler: MCPServerHandler {
    func listTools(_ params: MCPListToolsParams) async throws -> MCPListToolsResult {
        _ = params
        return MCPListToolsResult(tools: [MCPTool(name: "echo", inputSchema: .object([:]))])
    }
}

private actor FolderTrustRecordingRenderer: OpenGrokPagerInteractiveRenderAdapter {
    private(set) var notices: [String] = []
    func begin() async throws {}
    func render(_ event: OpenGrokPagerInteractiveEvent) async throws {
        if case .notice(let notice) = event {
            notices.append(notice)
        }
    }
    func restoreTerminal() async throws {}
}

private struct FolderTrustUnusedRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(for request: OpenGrokPagerRequest) async throws -> any OpenGrokPagerSessionAdapter {
        _ = request
        throw NSError(domain: "folder-trust-command", code: 1)
    }
}

private struct FolderTrustSilentOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws {
        _ = event
    }
}

@Suite("live folder trust revocation and regrant parity")
struct LiveFolderTrustRevocationParityTests {
    @Test(arguments: [
        ".opengrok/plugins",
        ".opengrok/agents",
        ".claude/agents",
        ".opengrok/roles",
        ".opengrok/personas",
        ".opengrok/workflows",
    ])
    func executableProjectMarkersRequireFolderTrust(_ marker: String) throws {
        let fixture = try LiveFolderTrustRevocationFixture(trusted: false)
        defer { fixture.dispose() }
        let nested = fixture.workspace.appendingPathComponent("nested/deeper")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: fixture.workspace.appendingPathComponent(marker),
            withIntermediateDirectories: true
        )

        #expect(repoConfigsPresent(at: fixture.workspace))
        #expect(repoConfigsPresent(at: nested))
        #expect(LiveSecurityContext.resolve(
            workspaceRoot: fixture.workspace,
            environment: fixture.environment,
            isInteractive: false
        ).projectTrusted == false)
    }

    @Test("the executable-marker walk stops at the canonical Git root")
    func ownerGlobalAgentDirectoryDoesNotTaintRepositories() throws {
        let fixture = try LiveFolderTrustRevocationFixture(trusted: false)
        defer { fixture.dispose() }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent(".claude/agents"),
            withIntermediateDirectories: true
        )

        #expect(repoConfigsPresent(at: fixture.workspace) == false)
    }

    @Test("trust slash commands are visible only when a real session backs them")
    func slashCommandCatalogRequiresLiveBacking() {
        let backed = OpenGrokPagerInteractiveController.visibleBuiltinCommandCatalog(
            folderTrustCommandsEnabled: true
        ).map(\.name)
        let unbacked = OpenGrokPagerInteractiveController.visibleBuiltinCommandCatalog().map(\.name)

        #expect(backed.contains("hooks-trust"))
        #expect(backed.contains("hooks-untrust"))
        #expect(unbacked.contains("hooks-trust") == false)
        #expect(unbacked.contains("hooks-untrust") == false)
    }

    @Test("the actual pager slash dispatcher revokes durable trust immediately")
    func realPagerDispatchReachesTheLiveTrustControl() async throws {
        let fixture = try LiveFolderTrustRevocationFixture()
        defer { fixture.dispose() }
        try FileManager.default.createDirectory(
            at: fixture.workspace.appendingPathComponent(".opengrok/workflows"),
            withIntermediateDirectories: true
        )
        let executor = try await fixture.makeExecutor()
        let renderer = FolderTrustRecordingRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: AsyncStream { continuation in
                continuation.yield(.paste("/hooks-untrust"))
                continuation.yield(.key(KeyEvent(key: .enter)))
                continuation.finish()
            },
            runtime: FolderTrustUnusedRuntime(),
            renderer: renderer,
            output: FolderTrustSilentOutput(),
            folderTrustCommandsEnabled: true
        )
        await controller.setFolderTrustHandler { trusted in
            await fixture.change(trusted, executor: executor)
        }

        let result = try await controller.run(.init(prompt: "", mode: .inline))

        #expect(result.lifecycle == .eof)
        #expect(await renderer.notices.contains { $0.hasPrefix("Untrusted:") })
        #expect(executor.projectTrusted == false)
        #expect(PersistentFolderTrustStore(environment: fixture.environment).isTrusted(fixture.workspace) == false)
        await executor.shutdown()
    }

    @Test("revocation persists a scoped deny and an explicit regrant restores the session")
    func durableRevokeAndRegrantReachFreshResolutions() async throws {
        let fixture = try LiveFolderTrustRevocationFixture()
        defer { fixture.dispose() }
        try FileManager.default.createDirectory(
            at: fixture.workspace.appendingPathComponent(".opengrok/workflows"),
            withIntermediateDirectories: true
        )
        let executor = try await fixture.makeExecutor()

        let revoked = await fixture.change(false, executor: executor)
        #expect(revoked.hasPrefix("Untrusted:"))
        #expect(executor.projectTrusted == false)
        #expect(LiveSecurityContext.resolve(
            workspaceRoot: fixture.workspace,
            environment: fixture.environment,
            isInteractive: false
        ).projectTrusted == false)

        let restored = await fixture.change(true, executor: executor)
        #expect(restored.hasPrefix("Trusted:"))
        #expect(executor.projectTrusted)
        #expect(PersistentFolderTrustStore(environment: fixture.environment).isTrusted(fixture.workspace))
        await executor.shutdown()
    }

    @Test("revocation immediately drops project hooks while retaining owner hooks")
    func projectHooksStopExecutingAndRegrantRestoresThem() async throws {
        let fixture = try LiveFolderTrustRevocationFixture()
        defer { fixture.dispose() }
        let projectMarker = fixture.root.appendingPathComponent("project-hook-ran")
        let ownerMarker = fixture.root.appendingPathComponent("owner-hook-ran")
        try fixture.writeHook(name: "project", marker: projectMarker, project: true)
        try fixture.writeHook(name: "owner", marker: ownerMarker, project: false)
        let executor = try await fixture.makeExecutor()

        let initial = await fixture.invokeShell(executor)
        guard case .success = initial else {
            Issue.record("trusted shell tool did not execute: \(initial)")
            await executor.shutdown()
            return
        }
        #expect(FileManager.default.fileExists(atPath: projectMarker.path))
        #expect(FileManager.default.fileExists(atPath: ownerMarker.path))
        try FileManager.default.removeItem(at: projectMarker)
        try FileManager.default.removeItem(at: ownerMarker)

        #expect(await fixture.change(false, executor: executor).hasPrefix("Untrusted:"))
        let afterRevoke = await fixture.invokeShell(executor)
        guard case .success = afterRevoke else {
            Issue.record("owner-authorized shell tool stopped working: \(afterRevoke)")
            await executor.shutdown()
            return
        }
        #expect(FileManager.default.fileExists(atPath: projectMarker.path) == false)
        #expect(FileManager.default.fileExists(atPath: ownerMarker.path))
        try FileManager.default.removeItem(at: ownerMarker)

        #expect(await fixture.change(true, executor: executor).hasPrefix("Trusted:"))
        let afterRegrant = await fixture.invokeShell(executor)
        guard case .success = afterRegrant else {
            Issue.record("regranted shell tool did not execute: \(afterRegrant)")
            await executor.shutdown()
            return
        }
        #expect(FileManager.default.fileExists(atPath: projectMarker.path))
        #expect(FileManager.default.fileExists(atPath: ownerMarker.path))
        await executor.shutdown()
    }

    @Test("Stop hooks read the newly reloaded gate rather than a stale startup snapshot")
    func stopHookCannotRunAfterProjectTrustIsRevoked() async throws {
        let fixture = try LiveFolderTrustRevocationFixture()
        defer { fixture.dispose() }
        let marker = fixture.root.appendingPathComponent("project-stop-ran")
        try fixture.writeHook(name: "project-stop", marker: marker, project: true, event: "Stop")
        let executor = try await fixture.makeExecutor()

        _ = await executor.runStop(promptID: "before", payload: [:])
        #expect(FileManager.default.fileExists(atPath: marker.path))
        try FileManager.default.removeItem(at: marker)
        #expect(await fixture.change(false, executor: executor).hasPrefix("Untrusted:"))
        _ = await executor.runStop(promptID: "after", payload: [:])

        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
        await executor.shutdown()
    }

    @Test("revocation disconnects repository MCP tools but preserves owner MCP connections")
    func projectMCPIsDisconnectedWhileOwnerMCPStaysLive() async throws {
        let fixture = try LiveFolderTrustRevocationFixture()
        defer { fixture.dispose() }
        try fixture.writeMCP(name: "owner", project: false)
        try fixture.writeMCP(name: "project", project: true)
        let executor = try await fixture.makeExecutor()

        for name in ["owner", "project"] {
            let server = MCPServer(
                configuration: MCPServerConfiguration(
                    serverInfo: MCPImplementation(name: name, version: "1.0.0"),
                    capabilities: MCPCapabilities(tools: MCPToolsCapability())
                ),
                handler: FolderTrustMCPHandler()
            )
            let client = MCPClient(transport: MCPInMemoryTransport(server: server))
            _ = try await client.initialize()
            await executor.mcpSessionConnections.retain(client, as: name)
            let registration = await MCPToolBridge.register(
                provider: MCPClientToolProvider(serverName: name, client: client),
                into: executor.mcpToolset
            )
            #expect(registration.failure == nil)
        }
        #expect(await executor.mcpSessionConnections.names() == ["owner", "project"])

        #expect(await fixture.change(false, executor: executor).hasPrefix("Untrusted:"))

        #expect(await executor.mcpSessionConnections.names() == ["owner"])
        #expect(executor.currentToolSpecs().contains { $0.name == "owner__echo" })
        #expect(executor.currentToolSpecs().contains { $0.name == "project__echo" } == false)
        await executor.shutdown()
    }

    @Test("project LSP processes and their advertised tool disappear until explicit regrant")
    func projectLanguageServerCannotRunAfterRevocation() async throws {
        let fixture = try LiveFolderTrustRevocationFixture()
        defer { fixture.dispose() }
        let marker = fixture.root.appendingPathComponent("project-lsp-started")
        try fixture.writeLSP(marker: marker, project: true)
        let executor = try await fixture.makeExecutor()
        #expect(executor.currentToolSpecs().contains { $0.name == "pull_diagnostics" })

        #expect(await fixture.change(false, executor: executor).hasPrefix("Untrusted:"))
        #expect(executor.projectTrusted == false)
        #expect(executor.currentToolSpecs().contains { $0.name == "pull_diagnostics" } == false)
        let denied = await executor.invoke(
            sessionID: "live-folder-trust",
            workingDirectory: fixture.workspace,
            call: ToolCall(id: "denied-lsp", name: "pull_diagnostics", arguments: #"{"path":"Sample.swift"}"#)
        )
        if case .success = denied {
            Issue.record("revoked project language server remained callable")
        }
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)

        #expect(await fixture.change(true, executor: executor).hasPrefix("Trusted:"))
        #expect(executor.currentToolSpecs().contains { $0.name == "pull_diagnostics" })
        await executor.shutdown()
    }

    @Test("a failed revoke persistence blocks every previously authorized project call")
    func failedPersistenceFailsClosed() async throws {
        let fixture = try LiveFolderTrustRevocationFixture()
        defer { fixture.dispose() }
        try FileManager.default.createDirectory(
            at: fixture.workspace.appendingPathComponent(".opengrok/workflows"),
            withIntermediateDirectories: true
        )
        let executor = try await fixture.makeExecutor()
        let lock = fixture.state.appendingPathComponent("trusted_folders.toml.lock")
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)

        let outcome = await fixture.change(false, executor: executor)
        #expect(outcome.contains("Failed to persist folder trust"))
        #expect(executor.projectTrusted == false)
        let blocked = await fixture.invokeShell(executor)
        if case .success = blocked {
            Issue.record("failed trust persistence left the old project authorization callable")
        }
        await executor.shutdown()
    }

    @Test("revoking a never-trusted repository does not poison a future ancestor grant")
    func neverTrustedRevokeDoesNotCreateAnExplicitDeny() async throws {
        let fixture = try LiveFolderTrustRevocationFixture(trusted: false)
        defer { fixture.dispose() }
        try FileManager.default.createDirectory(
            at: fixture.workspace.appendingPathComponent(".opengrok/workflows"),
            withIntermediateDirectories: true
        )
        let executor = try await fixture.makeExecutor()

        let outcome = await fixture.change(false, executor: executor)

        #expect(outcome == "Not currently trusted: \(fixture.workspace.path)")
        #expect(FileManager.default.fileExists(
            atPath: fixture.state.appendingPathComponent("trusted_folders.toml").path
        ) == false)
        await executor.shutdown()
    }

    @Test("trust commands refuse non-Git directories without granting repository authority")
    func nonGitDirectoryCannotBeTrusted() async throws {
        let fixture = try LiveFolderTrustRevocationFixture(trusted: false, gitRepository: false)
        defer { fixture.dispose() }
        try FileManager.default.createDirectory(
            at: fixture.workspace.appendingPathComponent(".opengrok/workflows"),
            withIntermediateDirectories: true
        )
        let executor = try await fixture.makeExecutor()

        #expect(await fixture.change(true, executor: executor)
            == "Not in a git repository. Project hooks require a git worktree root.")
        #expect(await fixture.change(false, executor: executor) == "Not in a git repository.")
        #expect(executor.projectTrusted == false)
        await executor.shutdown()
    }
}
