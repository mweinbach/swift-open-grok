import Foundation
import OpenGrokACP
import OpenGrokMCP
import OpenGrokShared
import OpenGrokToolRegistry
import OpenGrokWorkspace
import Testing

@testable import OpenGrokACPRuntime
@testable import OpenGrokCLI

private typealias MCPAuthorityJSON = OpenGrokShared.JSONValue

@Suite("Live MCP ACP authority isolation")
struct LiveMCPAuthorityIsolationParityTests {
    @Test("foreign and conflicting session identities cannot mutate config")
    func foreignIdentityCannotWriteConfig() async throws {
        let fixture = try await Fixture.start()
        defer { fixture.cleanup() }

        let owner = try await fixture.newSession(on: fixture.ownerRuntime, id: "owner-new")
        let victimRuntime = ACPAgentRuntime()
        try await fixture.initialize(victimRuntime, id: "victim-init")
        let victim = try await fixture.newSession(on: victimRuntime, id: "victim-new")

        let foreign = await fixture.invokeUpsert(
            fields: ["session_id": .string(victim)],
            server: "foreign"
        )
        #expect(foreign?.code == .invalidParams)
        #expect(try fixture.configText() == fixture.marker)

        let conflict = await fixture.invokeUpsert(
            fields: [
                "sessionId": .string(owner),
                "session_id": .string(victim),
            ],
            server: "conflict"
        )
        #expect(conflict?.code == .invalidParams)
        #expect(conflict?.data?.stringValue?.contains("conflicting fields") == true)
        #expect(try fixture.configText() == fixture.marker)
    }

    @Test("the attached first-driver owner remains authorized before mutation")
    func ownerCanMutateAfterPreauthorization() async throws {
        let fixture = try await Fixture.start()
        defer { fixture.cleanup() }
        let owner = try await fixture.newSession(on: fixture.ownerRuntime, id: "owner-new")

        // A disabled declaration stops before process or transport startup,
        // but only after the authenticated owner has performed the config
        // mutation. This keeps the regression hermetic under GROK_SANDBOX=off.
        let error = await fixture.invokeUpsert(
            fields: ["session_id": .string(owner)],
            server: "owned"
        )
        #expect(error?.code == .invalidParams)
        #expect(error?.data == .string("server config is disabled"))
        #expect(try fixture.configText().contains("owned"))
    }
}

private struct Fixture {
    let root: URL
    let config: URL
    let marker: String
    let gateway: ACPNotificationGateway
    let state: LiveMCPACPState
    let handler: LiveMCPACPHandler
    let ownerRuntime: ACPAgentRuntime

    static func start() async throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-mcp-authority-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("config.toml")
        let marker = "# authority-marker\n"
        try marker.write(to: config, atomically: true, encoding: .utf8)

        let resources = ToolResources(
            cwd: root.path,
            permissionPipeline: PermissionPipeline(
                permissions: PermissionHandle(allowAll: true, shellCwd: root.path),
                hooks: FailOpenPreToolUseHookRunner(inner: nil)
            )
        )
        let toolset = FinalizedToolset(
            tools: [],
            resources: resources,
            codeModeNamespaces: [:],
            options: .unrestricted
        )
        let connections = MCPSessionConnections()
        let state = LiveMCPACPState(connections: connections, toolset: toolset, outcomes: [])
        let gateway = ACPNotificationGateway()
        let environment = [
            "OPENGROK_HOME": root.path,
            "HOME": root.path,
            "GROK_SANDBOX": "off",
        ]
        let handler = LiveMCPACPHandler(
            gateway: gateway,
            state: state,
            declarations: { MCPConfigLoadResult(servers: []) },
            userConfigPath: config,
            openGrokHome: root,
            environment: environment
        )
        let ownerRuntime = ACPAgentRuntime()
        await gateway.attach(ownerRuntime)
        let fixture = Self(
            root: root,
            config: config,
            marker: marker,
            gateway: gateway,
            state: state,
            handler: handler,
            ownerRuntime: ownerRuntime
        )
        try await fixture.initialize(ownerRuntime, id: "owner-init")
        return fixture
    }

    func initialize(_ runtime: ACPAgentRuntime, id: String) async throws {
        let output = await runtime.handle(.request(
            id: .string(id),
            method: AgentMethodNames.initialize,
            params: try MCPAuthorityJSON.encode(InitializeRequest(protocolVersion: .v1))
        ))
        guard case .response(_, _?, nil)? = output.last else {
            throw ACPRuntimeError.transport("ACP initialization failed")
        }
    }

    func newSession(on runtime: ACPAgentRuntime, id: String) async throws -> String {
        let output = await runtime.handle(.request(
            id: .string(id),
            method: AgentMethodNames.sessionNew,
            params: .object(["cwd": .string(root.path), "mcpServers": .array([])])
        ))
        guard case .response(_, let result?, nil)? = output.last,
              let sessionID = result["sessionId"]?.stringValue else {
            throw ACPRuntimeError.transport("ACP session creation failed")
        }
        return sessionID
    }

    func invokeUpsert(fields: [String: MCPAuthorityJSON], server: String) async -> AcpError? {
        var params = fields
        params["server_name"] = .string(server)
        params["url"] = .string("http://127.0.0.1:9/mcp")
        params["enabled"] = .bool(false)
        do {
            _ = try await handler.handle(method: "x.ai/mcp/upsert", params: .object(params))
            return nil
        } catch let error as AcpError {
            return error
        } catch {
            return .internalError("unexpected error: \(error)")
        }
    }

    func configText() throws -> String {
        try String(contentsOf: config, encoding: .utf8)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
