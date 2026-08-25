import Foundation
import OpenGrokACP
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokMCP
import OpenGrokShared
import OpenGrokTestSupport
import OpenGrokToolRegistry
import OpenGrokWorkspace
import Testing

@testable import OpenGrokACPRuntime
@testable import OpenGrokCLI

private typealias SetupJSONValue = OpenGrokShared.JSONValue

@Suite("Live ACP MCP setup parity", .serialized)
struct LiveMCPSetupParityTests {
    @Test("the actual ACP catalog and auth trigger expose unresolved setup schemas")
    func catalogAndAuthTriggerExposeSetup() async throws {
        let fixture = try await MCPSetupFixture.start()
        defer { Task { await fixture.shutdown() } }

        let (catalog, catalogError) = await fixture.call(
            "x.ai/mcp/list",
            params: .object(["sessionId": .string(fixture.sessionID)])
        )
        #expect(catalogError == nil)
        let entry = try #require(catalog?["result"]?["servers"]?.arrayValue?.first)
        #expect(entry["name"] == .string("configured"))
        #expect(entry["url"] == .string(""))
        #expect(entry["headers"] == nil)
        #expect(entry["setup"]?["fields"]?[0]?["id"] == .string("region"))
        #expect(entry["session"]?["status"] == .string("setuprequired"))
        #expect(entry["session"]?["setupRequired"] == .bool(true))
        #expect(await fixture.connections.names().isEmpty)

        let (auth, authError) = await fixture.call(
            "x.ai/mcp/auth_trigger",
            params: .object([
                "session_id": .string(fixture.sessionID),
                "server_name": .string("configured"),
            ])
        )
        #expect(authError == nil)
        #expect(auth?["result"]?["status"] == .string("setup_required"))
        #expect(auth?["result"]?["setup"]?["fields"]?[0]?["id"] == .string("region"))
        #expect(fixture.server.requestCount() == 0)
    }

    @Test("owned ACP setup persists filtered values, resolves private headers, and connects live tools")
    func ownedSetupConnectsActualServer() async throws {
        let fixture = try await MCPSetupFixture.start()
        defer { Task { await fixture.shutdown() } }

        let (result, error) = await fixture.setup(
            values: [
                "region": .string("primary"),
                "clientSecret": .string("must-never-be-persisted"),
            ]
        )
        #expect(error == nil)
        #expect(result == .object(["result": .object(["ok": .bool(true)])]))

        let preferencesPath = MCPSetupPreferencesStore.path(home: fixture.home)
        let raw = try String(contentsOf: preferencesPath, encoding: .utf8)
        #expect(!raw.contains("must-never-be-persisted"))
        let stored = try #require(
            MCPSetupPreferencesStore.load(home: fixture.home).file.servers["configured"]
        )
        #expect(stored.values == ["region": "primary"])
        #expect(stored.source == McpPreferenceSource(kind: "config", scope: "user"))
        #expect(stored.updatedAt != nil)
        #expect(fixture.server.authorizations().contains("Bearer server-private-token"))

        let (catalog, catalogError) = await fixture.call(
            "x.ai/mcp/list",
            params: .object(["sessionId": .string(fixture.sessionID)])
        )
        #expect(catalogError == nil)
        let entry = try #require(catalog?["result"]?["servers"]?.arrayValue?.first)
        #expect(entry["url"] == .string("\(fixture.http.baseURL)/configured/mcp"))
        #expect(entry["headers"] == nil)
        #expect(entry["setup"] == nil)
        #expect(entry["session"]?["status"] == .string("ready"))
        #expect(entry["session"]?["tools"]?[0]?["name"] == .string("echo"))

        let (call, callError) = await fixture.call(
            "x.ai/mcp/call",
            params: .object([
                "sessionId": .string(fixture.sessionID),
                "server": .string("configured"),
                "tool": .string("echo"),
                "arguments": .object(["text": .string("live setup")]),
            ])
        )
        #expect(callError == nil)
        #expect(call?["result"]?["content"]?[0]?["text"] == .string("echo:live setup"))
    }

    @Test("foreign sessions, conflicting identities, wrong value types, and invalid options never write")
    func invalidOrForeignRequestsCannotPersist() async throws {
        let fixture = try await MCPSetupFixture.start()
        defer { Task { await fixture.shutdown() } }

        let (_, foreign) = await fixture.setup(
            values: ["region": .string("primary")],
            sessionID: "foreign-session"
        )
        #expect(foreign?.code == .invalidParams)
        #expect(foreign?.data == .string("session not found"))

        let (_, conflict) = await fixture.call(
            "x.ai/mcp/setup",
            params: .object([
                "sessionId": .string(fixture.sessionID),
                "session_id": .string("foreign-session"),
                "serverName": .string("configured"),
                "values": .object(["region": .string("primary")]),
            ])
        )
        #expect(conflict?.code == .invalidParams)

        let (_, wrongType) = await fixture.setup(values: ["region": .bool(true)])
        #expect(wrongType?.code == .invalidParams)
        let (_, invalidOption) = await fixture.setup(values: ["region": .string("unknown")])
        #expect(invalidOption?.code == .invalidParams)
        #expect(invalidOption?.data == .string("setup values incomplete"))

        #expect(MCPSetupPreferencesStore.load(home: fixture.home) == .missing)
        #expect(fixture.server.requestCount() == 0)
    }

    @Test("corrupt preference files remain byte-for-byte untouched through the real ACP handler")
    func corruptPreferencesCannotBeClobbered() async throws {
        let fixture = try await MCPSetupFixture.start()
        defer { Task { await fixture.shutdown() } }
        let original = Data("{corrupt, keep every byte".utf8)
        let path = MCPSetupPreferencesStore.path(home: fixture.home)
        try original.write(to: path)

        let (_, error) = await fixture.setup(values: ["region": .string("primary")])
        #expect(error?.code == .internalError)
        #expect(error?.data == .string(
            "MCP preferences file is unreadable; fix or remove mcp_preferences.json before saving"
        ))
        #expect(try Data(contentsOf: path) == original)
        #expect(fixture.server.requestCount() == 0)
    }

    @Test("a managed transport deny rejects the resolved endpoint before preferences or network")
    func managedPolicyBlocksResolvedTemplate() async throws {
        let policy = ManagedMCPPolicy(deniedServers: [
            .serverURL("http://127.0.0.1/configured/mcp"),
        ])
        let fixture = try await MCPSetupFixture.start(policy: policy)
        defer { Task { await fixture.shutdown() } }

        let (_, error) = await fixture.setup(values: ["region": .string("primary")])
        #expect(error?.code == .invalidParams)
        #expect(error?.data?.stringValue?.contains("managed policy") == true)
        #expect(MCPSetupPreferencesStore.load(home: fixture.home) == .missing)
        #expect(fixture.server.requestCount() == 0)
    }

    @Test("untrusted project setup declarations remain invisible until folder trust is granted")
    func projectSetupRespectsFolderTrust() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-mcp-setup-trust-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let state = root.appendingPathComponent("state")
        let workspace = root.appendingPathComponent("workspace")
        let project = workspace.appendingPathComponent(".opengrok")
        for directory in [home, state, project] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try """
        [mcpServers.project]
        url = "{{endpoint}}"

        [[mcpServers.project.setup.fields]]
        id = "region"
        label = "Region"
        type = "select"
        options = [{ label = "Safe", value = "safe" }]

        [mcpServers.project.setup.variables.endpoint]
        from = "region"
        map = { safe = "https://safe.example.test/mcp" }
        """.write(
            to: project.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": state.path,
            "GROK_FOLDER_TRUST": "1",
        ]
        let declarations = LiveMCPACPHandler.trustGatedDeclarationSource(
            workspaceRoot: workspace,
            environment: environment,
            cli: CLIPermissionOptions()
        )
        #expect(declarations().setupServers.isEmpty)

        var trust = PersistentFolderTrustStore(environment: environment)
        try trust.record(workspace, trusted: true)
        #expect(declarations().setupRequiredServers.map(\.name) == ["project"])
    }

    @Test("failed reconnect restores the previous durable selection and its actual live server")
    func failedReconnectRestoresPriorSelectionAndClient() async throws {
        let fixture = try await MCPSetupFixture.start()
        defer { Task { await fixture.shutdown() } }
        let (_, initialError) = await fixture.setup(values: ["region": .string("primary")])
        #expect(initialError == nil)
        let before = MCPSetupPreferencesStore.load(home: fixture.home).file

        let (_, error) = await fixture.setup(values: ["region": .string("offline")])
        #expect(error?.code == .internalError)
        #expect(error?.data == .string("failed to reconnect MCP server after setup"))
        #expect(MCPSetupPreferencesStore.load(home: fixture.home).file == before)

        let (call, callError) = await fixture.call(
            "x.ai/mcp/call",
            params: .object([
                "sessionId": .string(fixture.sessionID),
                "server": .string("configured"),
                "tool": .string("echo"),
                "arguments": .object(["text": .string("restored")]),
            ])
        )
        #expect(callError == nil)
        #expect(call?["result"]?["content"]?[0]?["text"] == .string("echo:restored"))
    }

    @Test("failed first setup restores the personal disabled list and config enabled flag")
    func failedSetupRestoresDisabledState() async throws {
        let fixture = try await MCPSetupFixture.start(disabled: true)
        defer { Task { await fixture.shutdown() } }

        let (_, error) = await fixture.setup(values: ["region": .string("offline")])
        #expect(error?.code == .internalError)
        let document = try parseTOML(String(contentsOf: fixture.config, encoding: .utf8))
        #expect(disabledMCPServers(in: document).contains("configured"))
        let entry = try #require(document.table?["mcpServers"]?.table?["configured"]?.table)
        #expect(entry["enabled"]?.boolValue == false)
        #expect(MCPSetupPreferencesStore.load(home: fixture.home).file.servers.isEmpty)
        #expect(await fixture.connections.names().isEmpty)
    }

    @Test("a blank template transport is catalogued as setup-required and cannot be saved")
    func blankTransportNeverDisappears() async throws {
        let fixture = try await MCPSetupFixture.start(blankURL: true)
        defer { Task { await fixture.shutdown() } }

        let (catalog, catalogError) = await fixture.call(
            "x.ai/mcp/list",
            params: .object(["sessionId": .string(fixture.sessionID)])
        )
        #expect(catalogError == nil)
        #expect(catalog?["result"]?["servers"]?[0]?["name"] == .string("configured"))
        #expect(catalog?["result"]?["servers"]?[0]?["session"]?["setupRequired"] == .bool(true))

        let (_, error) = await fixture.setup(values: ["region": .string("primary")])
        #expect(error?.code == .invalidParams)
        #expect(error?.data?.stringValue?.contains("missing or empty 'url'") == true)
        #expect(MCPSetupPreferencesStore.load(home: fixture.home) == .missing)
    }
}

private final class SetupLoopbackMCPHandler: HttpRequestHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var seenAuthorizations: [String] = []
    private var requests = 0

    func requestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func authorizations() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return seenAuthorizations
    }

    func handle(_ request: HttpRequest) -> HttpResponse {
        guard request.method == "POST", request.pathOnly == "/configured/mcp" else {
            return .notFound
        }
        lock.lock()
        requests += 1
        if let authorization = request.authorization {
            seenAuthorizations.append(authorization)
        }
        lock.unlock()

        guard let object = try? JSONSerialization.jsonObject(with: request.body)
                as? [String: Any],
              let method = object["method"] as? String
        else {
            return HttpResponse(status: 400, body: .bytes(Data()))
        }
        guard let id = object["id"] else {
            return HttpResponse(status: 202, body: .bytes(Data()))
        }

        let result: [String: Any]
        switch method {
        case "initialize":
            result = [
                "protocolVersion": "2025-06-18",
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "configured", "version": "1.0.0"],
            ]
        case "tools/list":
            result = ["tools": [[
                "name": "echo",
                "description": "Echo setup requests",
                "inputSchema": ["type": "object"] as [String: Any],
            ]]]
        case "tools/call":
            let params = object["params"] as? [String: Any]
            let arguments = params?["arguments"] as? [String: Any]
            let text = arguments?["text"] as? String ?? ""
            result = [
                "content": [["type": "text", "text": "echo:\(text)"]],
                "isError": false,
            ]
        default:
            result = [:]
        }

        let reply: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        guard let data = try? JSONSerialization.data(withJSONObject: reply) else {
            return HttpResponse(status: 500, body: .bytes(Data()))
        }
        return HttpResponse(
            status: 200,
            headers: [("content-type", "application/json")],
            body: .bytes(data)
        )
    }
}

private struct MCPSetupFixture {
    let home: URL
    let config: URL
    let http: HttpServer
    let server: SetupLoopbackMCPHandler
    let connections: MCPSessionConnections
    let runtime: ACPAgentRuntime
    let sessionID: String

    static func start(
        disabled: Bool = false,
        blankURL: Bool = false,
        policy: ManagedMCPPolicy = .unrestricted
    ) async throws -> Self {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-live-mcp-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let server = SetupLoopbackMCPHandler()
        let http = HttpServer(handler: server, basePath: "")
        do {
            try http.start()
        } catch {
            try? FileManager.default.removeItem(at: home)
            throw error
        }

        let config = home.appendingPathComponent("config.toml")
        let prefix = disabled ? "disabled_mcp_servers = [\"configured\"]\n\n" : ""
        let url = blankURL ? "" : "{{endpoint}}"
        let document = prefix + """
        [mcpServers.configured]
        url = "\(url)"
        enabled = \(!disabled)
        headers = { Authorization = "Bearer {{token}}" }

        [[mcpServers.configured.setup.fields]]
        id = "region"
        label = "Region"
        type = "select"
        required = true
        options = [
          { label = "Primary", value = "primary" },
          { label = "Offline", value = "offline" }
        ]

        [mcpServers.configured.setup.variables.endpoint]
        from = "region"
        map = { primary = "\(http.baseURL)/configured/mcp", offline = "http://127.0.0.1:1/offline/mcp" }

        [mcpServers.configured.setup.variables.token]
        from = "region"
        map = { primary = "server-private-token", offline = "offline-private-token" }
        """
        try document.write(to: config, atomically: true, encoding: .utf8)

        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "GROK_SANDBOX": "off",
        ]
        let declarations = LiveMCPACPHandler.trustGatedDeclarationSource(
            workspaceRoot: home,
            environment: environment,
            cli: CLIPermissionOptions()
        )
        let toolset = FinalizedToolset(
            tools: [],
            resources: ToolResources(
                cwd: home.path,
                permissionPipeline: PermissionPipeline(
                    permissions: PermissionHandle(allowAll: true, shellCwd: home.path),
                    hooks: FailOpenPreToolUseHookRunner(inner: nil)
                )
            ),
            codeModeNamespaces: [:],
            options: .unrestricted
        )
        let connections = MCPSessionConnections()
        let state = LiveMCPACPState(connections: connections, toolset: toolset, outcomes: [])
        let gateway = ACPNotificationGateway()
        let handler = LiveMCPACPHandler(
            gateway: gateway,
            state: state,
            declarations: declarations,
            userConfigPath: config,
            openGrokHome: home,
            environment: environment,
            managedMCPPolicy: policy
        )
        let router = ACPExtensionMethodRouter()
            .register(prefix: LiveMCPACPHandler.prefix, handler: handler)
        let runtime = ACPAgentRuntime(extensionRouter: router)
        await gateway.attach(runtime)

        let initialized = await runtime.handle(.request(
            id: .string("setup-initialize"),
            method: AgentMethodNames.initialize,
            params: try SetupJSONValue.encode(InitializeRequest(protocolVersion: .v1))
        ))
        guard case .response(_, _?, nil)? = initialized.last else {
            http.stop()
            try? FileManager.default.removeItem(at: home)
            throw ACPRuntimeError.transport("MCP setup ACP initialize failed")
        }
        let opened = await runtime.handle(.request(
            id: .string("setup-session"),
            method: AgentMethodNames.sessionNew,
            params: .object(["cwd": .string(home.path), "mcpServers": .array([])])
        ))
        guard case .response(_, let session?, nil)? = opened.last,
              let sessionID = session["sessionId"]?.stringValue
        else {
            http.stop()
            try? FileManager.default.removeItem(at: home)
            throw ACPRuntimeError.transport("MCP setup ACP session creation failed")
        }

        return Self(
            home: home,
            config: config,
            http: http,
            server: server,
            connections: connections,
            runtime: runtime,
            sessionID: sessionID
        )
    }

    func setup(
        values: [String: SetupJSONValue],
        sessionID explicitSession: String? = nil
    ) async -> (SetupJSONValue?, AcpError?) {
        await call(
            "x.ai/mcp/setup",
            params: .object([
                "sessionId": .string(explicitSession ?? sessionID),
                "serverName": .string("configured"),
                "values": .object(values),
            ])
        )
    }

    func call(
        _ method: String,
        params: SetupJSONValue
    ) async -> (SetupJSONValue?, AcpError?) {
        let output = await runtime.handle(.request(
            id: .string(UUID().uuidString),
            method: method,
            params: params
        ))
        guard case .response(_, let result, let error)? = output.last else {
            return (nil, AcpError.internalError("MCP setup extension produced no response"))
        }
        return (result, error)
    }

    func shutdown() async {
        await connections.shutdown()
        await runtime.close()
        http.stop()
        try? FileManager.default.removeItem(at: home)
    }
}
