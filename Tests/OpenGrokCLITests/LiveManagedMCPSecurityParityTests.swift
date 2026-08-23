import Foundation
import OpenGrokACP
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokMCP
import OpenGrokShared
import OpenGrokShellBase
import OpenGrokToolRegistry
import OpenGrokWorkspace
import Testing

@testable import OpenGrokACPRuntime
@testable import OpenGrokCLI

private typealias ManagedPolicyJSONValue = OpenGrokShared.JSONValue

private struct ManagedMCPSecurityFixture {
    let root: URL
    let home: URL
    let state: URL
    let workspace: URL
    let adminPolicy: URL

    var environment: [String: String] {
        [
            "HOME": home.path,
            "OPENGROK_HOME": state.path,
            "GROK_SANDBOX": "off",
            "GROK_FOLDER_TRUST": "1",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
    }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-managed-mcp-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        state = root.appendingPathComponent("state")
        workspace = root.appendingPathComponent("workspace")
        adminPolicy = root.appendingPathComponent("administrator-managed-settings.json")
        for directory in [home, state, workspace.appendingPathComponent(".opengrok")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func writePolicy(_ json: String) throws {
        try Data(json.utf8).write(to: adminPolicy)
    }

    func writeUser(_ document: String) throws {
        try document.write(
            to: state.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
    }

    func writeProject(_ document: String) throws {
        try document.write(
            to: workspace.appendingPathComponent(".opengrok/config.toml"),
            atomically: true,
            encoding: .utf8
        )
    }

    func trustProject() throws {
        var trust = PersistentFolderTrustStore(environment: environment)
        try trust.record(workspace, trusted: true)
    }

    func makeToolset() -> FinalizedToolset {
        FinalizedToolset(
            tools: [],
            resources: ToolResources(cwd: workspace.path),
            codeModeNamespaces: [:],
            options: .unrestricted
        )
    }

    func markerServer(named name: String, marker: URL) throws -> (document: String, command: String) {
        let command: String
        let arguments: [String]
        #if os(Windows)
        let systemRoot = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        command = URL(fileURLWithPath: systemRoot).appendingPathComponent("System32/cmd.exe").path
        arguments = ["/d", "/c", "echo started > \"\(marker.path)\""]
        #else
        command = "/usr/bin/touch"
        arguments = [marker.path]
        #endif
        let encodedCommand = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
        let encodedArguments = try arguments.map {
            String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
        }.joined(separator: ", ")
        return ("""
        [mcpServers.\(name)]
        command = \(encodedCommand)
        args = [\(encodedArguments)]
        """, command)
    }
}

private actor ManagedSDKMCPHandler: MCPServerHandler {
    func listTools(_ params: MCPListToolsParams) async throws -> MCPListToolsResult {
        _ = params
        return MCPListToolsResult(tools: [MCPTool(name: "echo", description: "managed-safe")])
    }

    func callTool(_ params: MCPCallToolParams) async throws -> MCPCallToolResult {
        MCPCallToolResult(content: [.text(text: "managed:\(params.name)")])
    }
}

private actor ManagedSDKReverseRequests {
    private var servers: [String: MCPServer] = [:]
    private var invokedServerIDs: [String] = []

    func receive(_ message: ACPMessage, runtime: ACPAgentRuntime) async throws {
        guard case .request(let id, let method, let params) = message,
              method == MCPACPWire.sdkCall,
              let envelope = params.objectValue,
              let serverID = envelope["serverId"]?.stringValue,
              let message = envelope["message"] else {
            throw ACPRuntimeError.invalidParams("invalid managed-policy SDK reverse request")
        }

        invokedServerIDs.append(serverID)
        let server: MCPServer
        if let existing = servers[serverID] {
            server = existing
        } else {
            let created = MCPServer(
                configuration: MCPServerConfiguration(
                    serverInfo: MCPImplementation(name: serverID, version: "1.0.0"),
                    capabilities: MCPCapabilities(tools: MCPToolsCapability())
                ),
                handler: ManagedSDKMCPHandler()
            )
            servers[serverID] = created
            server = created
        }

        let request = try message.decode(MCPRequest.self)
        guard case .response(let response)? = try await server.handle(.request(request)) else {
            throw ACPRuntimeError.transport("managed-policy SDK server returned no response")
        }
        let result = await runtime.handle(.response(
            id: id,
            result: try ManagedPolicyJSONValue.encode(response),
            error: nil
        ))
        guard result.isEmpty else {
            throw ACPRuntimeError.transport("managed-policy SDK response produced unexpected output")
        }
    }

    func serverIDs() -> [String] {
        invokedServerIDs
    }
}

private struct ManagedSDKPolicyHarness {
    let fixture: ManagedMCPSecurityFixture
    let handler: LiveMCPACPHandler
    let state: LiveMCPACPState
    let toolset: FinalizedToolset
    let connections: MCPSessionConnections
    let runtime: ACPAgentRuntime
    let reverse: ManagedSDKReverseRequests

    static func start(
        fixture: ManagedMCPSecurityFixture,
        policy: ManagedMCPPolicy,
        declarations: [MCPServerDeclaration] = []
    ) async throws -> Self {
        let toolset = fixture.makeToolset()
        let connections = MCPSessionConnections()
        let state = LiveMCPACPState(connections: connections, toolset: toolset, outcomes: [])
        let gateway = ACPNotificationGateway()
        let handler = LiveMCPACPHandler(
            gateway: gateway,
            state: state,
            declarations: { MCPConfigLoadResult(servers: declarations) },
            userConfigPath: fixture.state.appendingPathComponent("config.toml"),
            openGrokHome: fixture.state,
            environment: fixture.environment,
            managedMCPPolicy: policy
        )
        let runtime = ACPAgentRuntime(
            onSessionOpened: { session, metadata in
                try await handler.openSDKServers(sessionID: session, meta: metadata)
            },
            onSessionClosed: { session in
                await handler.closeSDKServers(sessionID: session)
            }
        )
        let reverse = ManagedSDKReverseRequests()
        await gateway.attach(runtime)
        await runtime.setReverseSender { message in
            try await reverse.receive(message, runtime: runtime)
        }
        let response = await runtime.handle(.request(
            id: .string("managed-policy-initialize"),
            method: AgentMethodNames.initialize,
            params: try ManagedPolicyJSONValue.encode(InitializeRequest(protocolVersion: .v1))
        ))
        guard case .response(_, _?, nil)? = response.last else {
            throw ACPRuntimeError.transport("managed-policy ACP initialization failed")
        }
        return Self(
            fixture: fixture,
            handler: handler,
            state: state,
            toolset: toolset,
            connections: connections,
            runtime: runtime,
            reverse: reverse
        )
    }

    func open(_ entries: [(name: String, id: String)]) async throws -> AcpSessionId {
        let metadata: AcpMeta = [MCPACPWire.servers: .array(entries.map { entry in
            .object(["name": .string(entry.name), "serverId": .string(entry.id)])
        })]
        let output = await runtime.handle(.request(
            id: .string("managed-policy-session"),
            method: AgentMethodNames.sessionNew,
            params: try ManagedPolicyJSONValue.encode(NewSessionRequest(
                cwd: fixture.workspace.path,
                meta: metadata
            ))
        ))
        guard case .response(_, let result?, nil)? = output.last,
              let identifier = result["sessionId"]?.stringValue else {
            throw ACPRuntimeError.transport("managed-policy ACP session failed: \(output)")
        }
        return AcpSessionId(identifier)
    }

    func close() async {
        await runtime.close()
        await connections.shutdown()
    }
}

@Suite("Live managed MCP policy security", .serialized)
struct LiveManagedMCPSecurityParityTests {
    @Test("actual live executor blocks a denied process before spawn and still launches an allowed process")
    func realExecutorDeniesBeforeSpawnAndAllowsPermittedCommand() async throws {
        let fixture = try ManagedMCPSecurityFixture()
        defer { fixture.dispose() }
        let marker = fixture.root.appendingPathComponent("actual-managed-mcp-process")
        let server = try fixture.markerServer(named: "process", marker: marker)
        try fixture.writeUser(server.document)
        let encodedCommand = String(decoding: try JSONEncoder().encode(server.command), as: UTF8.self)
        try fixture.writePolicy("{\"deniedMcpServers\":[{\"command\":\(encodedCommand)}]}")

        let deniedSecurity = LiveSecurityContext.resolve(
            workspaceRoot: fixture.workspace,
            environment: fixture.environment,
            isInteractive: false,
            managedSettingsPath: fixture.adminPolicy
        )
        let denied = try await LiveToolExecutor(
            processBackend: LocalShellProcessBackend(inheritedEnvironment: fixture.environment),
            sessionID: "managed-denied-real-executor",
            workingDirectory: fixture.workspace,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            environment: fixture.environment,
            securityContext: deniedSecurity
        )

        #expect(denied.mcpServerConnections.count == 1)
        #expect(denied.mcpServerConnections[0].failure?.contains("deniedMcpServers") == true)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(denied.mcpToolset.clientNames.allSatisfy { !$0.hasPrefix("process__") })
        await denied.shutdown()

        try fixture.writePolicy(#"{"deniedMcpServers":[{"command":"different-command"}]}"#)
        let permittedSecurity = LiveSecurityContext.resolve(
            workspaceRoot: fixture.workspace,
            environment: fixture.environment,
            isInteractive: false,
            managedSettingsPath: fixture.adminPolicy
        )
        let permitted = try await LiveToolExecutor(
            processBackend: LocalShellProcessBackend(inheritedEnvironment: fixture.environment),
            sessionID: "managed-permitted-real-executor",
            workingDirectory: fixture.workspace,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            environment: fixture.environment,
            securityContext: permittedSecurity
        )

        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(permitted.mcpServerConnections.count == 1)
        #expect(permitted.mcpServerConnections[0].failure?.contains("deniedMcpServers") != true)
        await permitted.shutdown()
    }

    @Test("a protected policy removed during startup still blocks MCP before process creation")
    func removedAdministratorPolicyFailsClosedBeforeActualProcessSpawn() async throws {
        let fixture = try ManagedMCPSecurityFixture()
        defer { fixture.dispose() }
        let marker = fixture.root.appendingPathComponent("removed-policy-mcp-process")
        let server = try fixture.markerServer(named: "process", marker: marker)
        try fixture.writeUser(server.document)
        let encodedCommand = String(decoding: try JSONEncoder().encode(server.command), as: UTF8.self)
        try fixture.writePolicy("{\"deniedMcpServers\":[{\"command\":\(encodedCommand)}]}")
        let security = LiveSecurityContext.resolve(
            workspaceRoot: fixture.workspace,
            environment: fixture.environment,
            isInteractive: false,
            managedSettingsPath: fixture.adminPolicy
        )
        let policyPath = fixture.adminPolicy

        let executor = try await LiveToolExecutor(
            processBackend: LocalShellProcessBackend(inheritedEnvironment: fixture.environment),
            sessionID: "managed-policy-removed-before-process",
            workingDirectory: fixture.workspace,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            environment: fixture.environment,
            securityContext: security,
            startupTrustCheckpoint: { _ in
                try? FileManager.default.removeItem(at: policyPath)
            }
        )

        #expect(!FileManager.default.fileExists(atPath: policyPath.path))
        #expect(executor.mcpServerConnections.count == 1)
        #expect(executor.mcpServerConnections[0].failure?
            .contains("invalid managed MCP server policy") == true)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(executor.mcpToolset.clientNames.allSatisfy { !$0.hasPrefix("process__") })
        await executor.shutdown()
    }

    @Test("folder-trust reload cannot discard the administrator policy and spawn a denied MCP")
    func trustReloadPreservesProtectedManagedMCPPolicyBeforeSpawn() async throws {
        let fixture = try ManagedMCPSecurityFixture()
        defer { fixture.dispose() }
        let marker = fixture.root.appendingPathComponent("reloaded-managed-mcp-process")
        let server = try fixture.markerServer(named: "process", marker: marker)
        try fixture.writeUser(server.document)
        let encodedCommand = String(decoding: try JSONEncoder().encode(server.command), as: UTF8.self)
        try fixture.writePolicy("{\"deniedMcpServers\":[{\"command\":\(encodedCommand)}]}")
        let security = LiveSecurityContext.resolve(
            workspaceRoot: fixture.workspace,
            environment: fixture.environment,
            isInteractive: false,
            managedSettingsPath: fixture.adminPolicy
        )
        let sessionID = "managed-policy-survives-trust-reload"
        let executor = try await LiveToolExecutor(
            processBackend: LocalShellProcessBackend(inheritedEnvironment: fixture.environment),
            sessionID: sessionID,
            workingDirectory: fixture.workspace,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            environment: fixture.environment,
            securityContext: security
        )

        #expect(!FileManager.default.fileExists(atPath: marker.path))
        let reloadedHooks = await executor.reloadFolderTrust(
            trusted: security.projectTrusted,
            sessionID: sessionID,
            workspaceRoot: fixture.workspace,
            environment: fixture.environment
        )

        #expect(reloadedHooks == 0)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(executor.mcpToolset.clientNames.allSatisfy { !$0.hasPrefix("process__") })
        await executor.shutdown()
    }

    @Test("protected deny rules outrank malicious trusted-project and user allow keys")
    func managedAuthorityCannotBeOverriddenByProject() throws {
        let fixture = try ManagedMCPSecurityFixture()
        defer { fixture.dispose() }
        try fixture.writePolicy(#"{"deniedMcpServers":[{"serverName":"blocked"}]}"#)
        try fixture.writeUser("""
        allowedMcpServers = [{ serverName = "blocked" }]
        [mcpServers.safe]
        command = "safe-command"
        """)
        try fixture.writeProject("""
        allowedMcpServers = [{ serverName = "blocked" }]
        [mcpServers.blocked]
        command = "project-command"
        """)
        try fixture.trustProject()

        let security = LiveSecurityContext.resolve(
            workspaceRoot: fixture.workspace,
            environment: fixture.environment,
            isInteractive: false,
            managedSettingsPath: fixture.adminPolicy
        )
        #expect(security.projectTrusted)
        #expect(security.managedMCPPolicy.isServerDenied(.init(
            name: "blocked", transport: .stdio(command: "project-command")
        )))
        #expect(security.managedMCPPolicy.isServerAllowed(.init(
            name: "safe", transport: .stdio(command: "safe-command")
        )))

        let source = LiveMCPACPHandler.trustGatedDeclarationSource(
            workspaceRoot: fixture.workspace,
            environment: fixture.environment,
            cli: CLIPermissionOptions(),
            managedSettingsPath: fixture.adminPolicy
        )()
        #expect(source.servers.map(\.name) == ["safe"])
        #expect(source.problems.contains {
            $0.server == "blocked" && $0.message.contains("deniedMcpServers")
        })
    }

    @Test("nonempty managed allowlist preserves compliant global declarations")
    func managedAllowlistPreservesCompliantGlobalServers() throws {
        let fixture = try ManagedMCPSecurityFixture()
        defer { fixture.dispose() }
        try fixture.writePolicy(#"{"allowedMcpServers":[{"command":"approved"}]}"#)
        try fixture.writeUser("""
        [mcpServers.compliant]
        command = "approved"
        [mcpServers.unlisted]
        command = "different"
        """)

        let loaded = LiveMCPACPHandler.trustGatedDeclarationSource(
            workspaceRoot: fixture.workspace,
            environment: fixture.environment,
            cli: CLIPermissionOptions(),
            managedSettingsPath: fixture.adminPolicy
        )()
        #expect(loaded.servers.map(\.name) == ["compliant"])
        #expect(loaded.problems.count == 1)
        #expect(loaded.problems.first?.server == "unlisted")
        #expect(loaded.problems.first?.message.contains("allowedMcpServers") == true)
    }

    @Test("malformed admin policy blocks every declaration instead of falling back to user rules")
    func malformedManagedPolicyFailsClosedAtLiveSource() throws {
        let fixture = try ManagedMCPSecurityFixture()
        defer { fixture.dispose() }
        try fixture.writePolicy(#"{"deniedMcpServers":[{"typo":"intended-deny"}]}"#)
        try fixture.writeUser("""
        [mcpServers.untrusted]
        command = "run-anything"
        """)

        let loaded = LiveMCPACPHandler.trustGatedDeclarationSource(
            workspaceRoot: fixture.workspace,
            environment: fixture.environment,
            cli: CLIPermissionOptions(),
            managedSettingsPath: fixture.adminPolicy
        )()
        #expect(loaded.servers.isEmpty)
        #expect(loaded.problems.count == 1)
        #expect(loaded.problems.first?.message.contains("invalid managed MCP server policy") == true)
    }

    @Test("ACP-provided SDK deny is rejected before reverse initialization while allowed peers remain live")
    func sdkDenyBlocksReverseCallsWithoutDroppingAllowedPeer() async throws {
        let fixture = try ManagedMCPSecurityFixture()
        defer { fixture.dispose() }
        let harness = try await ManagedSDKPolicyHarness.start(
            fixture: fixture,
            policy: ManagedMCPPolicy(
                allowedServers: [.serverName("safe")],
                deniedServers: [.serverName("blocked")]
            )
        )
        defer { Task { await harness.close() } }

        let session = try await harness.open([
            (name: "blocked", id: "forbidden-server"),
            (name: "safe", id: "compliant-server"),
        ])

        let reverseIDs = await harness.reverse.serverIDs()
        #expect(!reverseIDs.isEmpty)
        #expect(reverseIDs.allSatisfy { $0 == "compliant-server" })
        #expect(harness.toolset.clientNames == ["safe__echo"])
        #expect(await harness.state.outcome(for: "blocked")?.failure?
            .contains("deniedMcpServers") == true)
        #expect(await harness.state.sdkClient(named: "blocked", sessionID: session.rawValue) == nil)
        #expect(await harness.state.sdkClient(named: "safe", sessionID: session.rawValue) != nil)
    }

    @Test("opaque ACP SDK transports cannot bypass command deny policies")
    func sdkOpaqueTransportCannotBypassCommandDeny() async throws {
        let fixture = try ManagedMCPSecurityFixture()
        defer { fixture.dispose() }
        let harness = try await ManagedSDKPolicyHarness.start(
            fixture: fixture,
            policy: ManagedMCPPolicy(deniedServers: [.command("npx")])
        )
        defer { Task { await harness.close() } }

        let session = try await harness.open([(name: "uninspectable", id: "hidden-stdio")])

        #expect(await harness.reverse.serverIDs().isEmpty)
        #expect(harness.toolset.clientNames.isEmpty)
        #expect(await harness.state.outcome(for: "uninspectable")?.failure?
            .contains("deniedMcpServers") == true)
        #expect(await harness.state.sdkClient(
            named: "uninspectable", sessionID: session.rawValue
        ) == nil)
    }

    @Test("ACP upsert cannot persist or launch a managed-denied server")
    func deniedUpsertNeverTouchesUserConfig() async throws {
        let fixture = try ManagedMCPSecurityFixture()
        defer { fixture.dispose() }
        let harness = try await ManagedSDKPolicyHarness.start(
            fixture: fixture,
            policy: ManagedMCPPolicy(deniedServers: [.command("forbidden-command")])
        )
        defer { Task { await harness.close() } }

        do {
            _ = try await harness.handler.handle(
                method: "x.ai/mcp/upsert",
                params: .object([
                    "session_id": .string("irrelevant-session"),
                    "server_name": .string("malicious"),
                    "command": .string("forbidden-command"),
                ])
            )
            Issue.record("managed-denied ACP upsert was accepted")
        } catch let error as AcpError {
            #expect(error.code == .invalidParams)
            #expect(error.data?.stringValue?.contains("deniedMcpServers") == true)
        }

        #expect(!FileManager.default.fileExists(
            atPath: fixture.state.appendingPathComponent("config.toml").path
        ))
        #expect(await harness.connections.names().isEmpty)
        #expect(harness.toolset.clientNames.isEmpty)
    }
}
