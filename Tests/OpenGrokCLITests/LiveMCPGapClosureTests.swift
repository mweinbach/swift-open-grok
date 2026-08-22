import Foundation
import OpenGrokACP
import OpenGrokConfigTypes
import OpenGrokMCP
import OpenGrokShared
import OpenGrokToolRegistry
import OpenGrokWorkspace
import Testing

@testable import OpenGrokACPRuntime
@testable import OpenGrokCLI

private typealias JSONValue = OpenGrokShared.JSONValue

private actor GapClosureMCPHandler: MCPServerHandler {
    private let label: String
    private var tools: [MCPTool]
    private var resources: [MCPResource]

    init(label: String, tools: [String], resources: [MCPResource] = []) {
        self.label = label
        self.tools = tools.map { MCPTool(name: $0, description: "\(label) \($0)") }
        self.resources = resources
    }

    func replaceTools(_ names: [String]) {
        tools = names.map { MCPTool(name: $0, description: "\(label) \($0)") }
    }

    func replaceResources(_ updated: [MCPResource]) {
        resources = updated
    }

    func listTools(_ params: MCPListToolsParams) async throws -> MCPListToolsResult {
        MCPListToolsResult(tools: tools)
    }

    func callTool(_ params: MCPCallToolParams) async throws -> MCPCallToolResult {
        MCPCallToolResult(content: [.text(text: "\(label):\(params.name)")])
    }

    func listResources(_ params: MCPListResourcesParams) async throws -> MCPListResourcesResult {
        MCPListResourcesResult(resources: resources)
    }
}

private actor GapClosureNotifications {
    private var messages: [ACPMessage] = []

    func append(_ message: ACPMessage) {
        messages.append(message)
    }

    func snapshot() -> [ACPMessage] {
        messages
    }
}

private actor GapClosureReverseMCP {
    struct Invocation: Sendable {
        let method: String
        let envelope: [String: JSONValue]
        let mcpMethod: String
    }

    private var servers: [String: MCPServer] = [:]
    private var invocations: [Invocation] = []

    func receive(_ message: ACPMessage, runtime: ACPAgentRuntime) async throws {
        guard case .request(let id, let method, let params) = message,
              let envelope = params.objectValue,
              Set(envelope.keys) == Set(["serverId", "message"]),
              let serverID = envelope["serverId"]?.stringValue,
              let payload = envelope["message"]
        else {
            throw ACPRuntimeError.invalidParams("invalid reverse MCP wire envelope")
        }

        let request = try payload.decode(MCPRequest.self)
        invocations.append(Invocation(method: method, envelope: envelope, mcpMethod: request.method))

        let server: MCPServer
        if let existing = servers[serverID] {
            server = existing
        } else {
            let handler = GapClosureMCPHandler(label: serverID, tools: ["echo"])
            let created = MCPServer(
                configuration: MCPServerConfiguration(
                    serverInfo: MCPImplementation(name: serverID, version: "1.0.0"),
                    capabilities: MCPCapabilities(tools: MCPToolsCapability(listChanged: true))
                ),
                handler: handler
            )
            servers[serverID] = created
            server = created
        }

        guard case .response(let reply)? = try await server.handle(.request(request)) else {
            throw ACPRuntimeError.transport("reverse MCP server returned no response")
        }
        let handled = await runtime.handle(.response(
            id: id,
            result: try JSONValue.encode(reply),
            error: nil
        ))
        guard handled.isEmpty else {
            throw ACPRuntimeError.transport("reverse MCP response generated unexpected output")
        }
    }

    func snapshot() -> [Invocation] {
        invocations
    }

    func invocationCount(serverID: String) -> Int {
        invocations.filter { $0.envelope["serverId"] == .string(serverID) }.count
    }
}

private func makeGapClosureToolset() -> (FinalizedToolset, LiveMCPToolSearchIndex) {
    let resources = ToolResources(
        cwd: NSTemporaryDirectory(),
        permissionPipeline: PermissionPipeline(
            permissions: PermissionHandle(allowAll: true, shellCwd: NSTemporaryDirectory()),
            hooks: FailOpenPreToolUseHookRunner(inner: nil)
        )
    )
    let index = LiveMCPToolSearchIndex()
    resources.extras.insert(ToolSearchIndexResource(index))
    return (
        FinalizedToolset(
            tools: [],
            resources: resources,
            codeModeNamespaces: [:],
            options: .unrestricted
        ),
        index
    )
}

private func gapClosureDeclaration(named name: String, enabled: Bool = true) -> MCPServerDeclaration {
    MCPServerDeclaration(
        name: name,
        config: McpServerConfig(
            transport: .stdio(command: "/not-started-in-this-test", args: [], env: nil, cwd: nil),
            enabled: enabled
        )
    )
}

private func drainGapClosureLifecycle(
    _ connections: MCPSessionConnections,
    until predicate: @escaping @Sendable () async -> Bool
) async {
    for _ in 0..<80 {
        await Task.yield()
        await connections.flushLifecycle()
        if await predicate() {
            return
        }
    }
}

private struct GapClosureSDKHarness {
    let toolset: FinalizedToolset
    let index: LiveMCPToolSearchIndex
    let connections: MCPSessionConnections
    let state: LiveMCPACPState
    let handler: LiveMCPACPHandler
    let gateway: ACPNotificationGateway
    let runtime: ACPAgentRuntime
    let reverse: GapClosureReverseMCP

    static func start(declarations: [MCPServerDeclaration] = []) async throws -> Self {
        let (toolset, index) = makeGapClosureToolset()
        let connections = MCPSessionConnections()
        let state = LiveMCPACPState(connections: connections, toolset: toolset, outcomes: [])
        let gateway = ACPNotificationGateway()
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-mcp-gap-\(UUID().uuidString)")
        let handler = LiveMCPACPHandler(
            gateway: gateway,
            state: state,
            declarations: { MCPConfigLoadResult(servers: declarations) },
            userConfigPath: home.appendingPathComponent("config.toml"),
            openGrokHome: home,
            environment: ["OPENGROK_HOME": home.path]
        )
        let runtime = ACPAgentRuntime(
            onSessionOpened: { sessionID, meta in
                try await handler.openSDKServers(sessionID: sessionID, meta: meta)
            },
            onSessionClosed: { sessionID in
                await handler.closeSDKServers(sessionID: sessionID)
            }
        )
        let reverse = GapClosureReverseMCP()
        await gateway.attach(runtime)
        await runtime.setReverseSender { message in
            try await reverse.receive(message, runtime: runtime)
        }

        let initialized = await runtime.handle(.request(
            id: .string("initialize"),
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
        ))
        guard case .response(_, let response?, nil)? = initialized.last else {
            throw ACPRuntimeError.transport("ACP initialization failed")
        }
        let decoded = try response.decode(InitializeResponse.self)
        guard decoded.meta?[MCPACPWire.sdk] == .bool(true) else {
            throw ACPRuntimeError.transport("connected SDK bridge was not advertised")
        }

        return Self(
            toolset: toolset,
            index: index,
            connections: connections,
            state: state,
            handler: handler,
            gateway: gateway,
            runtime: runtime,
            reverse: reverse
        )
    }

    func open(serverName: String, serverID: String) async throws -> AcpSessionId {
        let metadata: AcpMeta = [MCPACPWire.servers: .array([
            .object(["name": .string(serverName), "serverId": .string(serverID)]),
        ])]
        let output = await runtime.handle(.request(
            id: .string("open-\(serverID)"),
            method: AgentMethodNames.sessionNew,
            params: try JSONValue.encode(NewSessionRequest(cwd: NSTemporaryDirectory(), meta: metadata))
        ))
        guard case .response(_, let result?, nil)? = output.last,
              let sessionID = result["sessionId"]?.stringValue
        else {
            throw ACPRuntimeError.transport("ACP session with SDK server was not created: \(output)")
        }
        return AcpSessionId(sessionID)
    }

    func call(serverName: String, sessionID: AcpSessionId) async throws -> String {
        let response = try await handler.handle(
            method: MCPACPWire.call,
            params: .object([
                "server": .string(serverName),
                "tool": .string("echo"),
                "sessionId": .string(sessionID.rawValue),
                "arguments": .object([:]),
            ])
        )
        guard let text = response["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue else {
            throw ACPRuntimeError.transport("SDK MCP call returned no text")
        }
        return text
    }

    func close() async {
        await runtime.close()
        await connections.shutdown()
    }
}

@Suite("Live MCP foundational gap closure", .serialized)
struct LiveMCPGapClosureTests {
    @Test("server events replace live tools and search, refresh resources, preserve disables, and reject stale close")
    func dynamicLifecycleReachesActualToolsetAndACP() async throws {
        let (toolset, index) = makeGapClosureToolset()
        let serverHandler = GapClosureMCPHandler(label: "dynamic", tools: ["old"])
        let server = MCPServer(
            configuration: MCPServerConfiguration(
                serverInfo: MCPImplementation(name: "dynamic", version: "1.0.0"),
                capabilities: MCPCapabilities(
                    resources: MCPResourcesCapability(listChanged: true),
                    tools: MCPToolsCapability(listChanged: true)
                )
            ),
            handler: serverHandler
        )
        let client = MCPClient(transport: MCPInMemoryTransport(server: server))
        let initialized = try await client.initialize()
        #expect(initialized.serverInfo.name == "dynamic")

        let initial = await MCPToolBridge.register(
            provider: MCPClientToolProvider(serverName: "dynamic", client: client),
            into: toolset
        )
        #expect(initial.failure == nil)
        #expect(initial.registeredNames == ["dynamic__old"])
        index.refresh(from: toolset)

        let connections = MCPSessionConnections()
        await connections.retain(client, as: "dynamic", clientID: 42)
        let declarations: @Sendable () -> MCPConfigLoadResult = {
            MCPConfigLoadResult(servers: [gapClosureDeclaration(named: "dynamic")])
        }
        let gateway = ACPNotificationGateway()
        let runtime = ACPAgentRuntime()
        let notifications = GapClosureNotifications()
        await runtime.setNotificationSink { await notifications.append($0) }
        await gateway.attach(runtime)
        let state = LiveMCPACPState(connections: connections, toolset: toolset, outcomes: [])

        await connections.startLifecycle(
            sessionID: "dynamic-session",
            toolset: toolset,
            declarations: declarations,
            environment: [:],
            disabledTools: { _ in ["blocked"] }
        )
        await connections.attachLifecycle(
            gateway: gateway,
            state: state,
            declarations: declarations,
            disabledTools: { _ in [] }
        )

        await serverHandler.replaceTools(["fresh", "blocked"])
        connections.events.publish(.toolsChanged(server: "dynamic"))
        await drainGapClosureLifecycle(connections) {
            let deliveredNotifications = await notifications.snapshot()
            return toolset.clientNames == ["dynamic__fresh"]
                && !deliveredNotifications.isEmpty
        }
        #expect(toolset.clientNames == ["dynamic__fresh"])
        #expect(index.searchSnapshot(query: "fresh", limit: 5).results.map(\.toolName) == ["dynamic__fresh"])
        #expect(index.searchSnapshot(query: "old", limit: 5).results.isEmpty)
        #expect(toolset.tool(named: "dynamic__blocked") == nil)
        #expect(await state.outcome(for: "dynamic")?.toolNames == ["dynamic__fresh"])

        let statuses = await notifications.snapshot()
        guard case .notification(let method, let params)? = statuses.last else {
            Issue.record("dynamic MCP change emitted no actual ACP notification")
            await connections.shutdown()
            return
        }
        #expect(method == "x.ai/mcp/server_status")
        #expect(params["sessionId"] == .string("dynamic-session"))
        #expect(params["name"] == .string("dynamic"))
        #expect(params["status"] == .string("ready"))
        #expect(params["reason"] == .string("config_changed"))
        #expect(params["tools"] == .null)

        let resource = MCPResource(uri: "file:///dynamic.md", name: "dynamic.md")
        await serverHandler.replaceResources([resource])
        connections.events.publish(.resourcesChanged(server: "dynamic"))
        await drainGapClosureLifecycle(connections) {
            await connections.resourceSnapshot(named: "dynamic") == [resource]
        }
        #expect(await connections.resourceSnapshot(named: "dynamic") == [resource])

        let statusCount = (await notifications.snapshot()).count
        connections.events.publish(.transportClosed(server: "dynamic", clientId: 41))
        await drainGapClosureLifecycle(connections) {
            await connections.clientIdentifier(named: "dynamic") == 42
        }
        #expect(await connections.clientIdentifier(named: "dynamic") == 42)
        #expect(toolset.clientNames == ["dynamic__fresh"])
        #expect((await notifications.snapshot()).count == statusCount)

        await connections.shutdown()
    }

    @Test("same-name SDK servers remain session-scoped, model-callable, and survive sibling teardown")
    func sdkServersAreLiveIsolatedAndCleanedUp() async throws {
        let harness = try await GapClosureSDKHarness.start()
        let first = try await harness.open(serverName: "shared", serverID: "server-A")
        let second = try await harness.open(serverName: "shared", serverID: "server-B")

        #expect(harness.toolset.clientNames == ["shared__echo"])
        #expect(harness.index.searchSnapshot(query: "echo", limit: 5).results.map(\.toolName) == ["shared__echo"])
        #expect(try await harness.call(serverName: "shared", sessionID: first) == "server-A:echo")
        #expect(try await harness.call(serverName: "shared", sessionID: second) == "server-B:echo")

        let firstBeforeModelCall = await harness.reverse.invocationCount(serverID: "server-A")
        let firstModelCall = await LiveACPPermissionPrompter.$activeSession.withValue(first) {
            await harness.toolset.prepareAndCall(clientName: "shared__echo", args: .object([:]))
        }
        switch firstModelCall {
        case .success:
            #expect(await harness.reverse.invocationCount(serverID: "server-A") == firstBeforeModelCall + 1)
        case .failure(let error):
            Issue.record("authorized model MCP tool unexpectedly failed: \(error)")
        }

        let unauthorized = await harness.toolset.prepareAndCall(
            clientName: "shared__echo",
            args: .object([:])
        )
        switch unauthorized {
        case .success:
            Issue.record("SDK MCP tool dispatched without an owning ACP session")
        case .failure:
            break
        }

        let unknown = AcpSessionId("unknown-session")
        await #expect(throws: AcpError.self) {
            try await harness.call(serverName: "shared", sessionID: unknown)
        }

        let requests = await harness.reverse.snapshot()
        #expect(requests.allSatisfy {
            $0.method == "x.ai/mcp/sdk_call"
                && Set($0.envelope.keys) == Set(["serverId", "message"])
                && $0.envelope["sessionId"] == nil
        })
        #expect(requests.filter { $0.mcpMethod == MCPMethod.initialize }.count == 2)
        #expect(requests.contains { $0.mcpMethod == MCPMethod.toolsList })
        #expect(requests.contains { $0.mcpMethod == MCPMethod.toolsCall })

        await harness.handler.closeSDKServers(sessionID: first)
        #expect(await harness.state.sdkClient(named: "shared", sessionID: first.rawValue) == nil)
        #expect(await harness.state.sdkClient(named: "shared", sessionID: second.rawValue) != nil)
        #expect(harness.toolset.clientNames == ["shared__echo"])
        #expect(try await harness.call(serverName: "shared", sessionID: second) == "server-B:echo")

        await harness.handler.closeSDKServers(sessionID: second)
        #expect(harness.toolset.clientNames.isEmpty)
        #expect(harness.index.searchSnapshot(query: "echo", limit: 5).results.isEmpty)
        await harness.close()
    }

    @Test("SDK reverse traffic stays bound to its owning ACP client after gateway reattachment")
    func reverseRequestsNeverCrossACPConnections() async throws {
        let harness = try await GapClosureSDKHarness.start()
        let session = try await harness.open(serverName: "private", serverID: "owner-server")
        guard let client = await harness.state.sdkClient(
            named: "private",
            sessionID: session.rawValue
        ) else {
            Issue.record("session did not retain its reverse MCP client")
            await harness.close()
            return
        }

        let unrelated = ACPAgentRuntime()
        let unrelatedReverse = GapClosureReverseMCP()
        await unrelated.setReverseSender { message in
            try await unrelatedReverse.receive(message, runtime: unrelated)
        }
        await harness.gateway.attach(unrelated)

        let before = await harness.reverse.invocationCount(serverID: "owner-server")
        let result = try await client.callTool(MCPCallToolParams(name: "echo", arguments: .object([:])))
        #expect(result.content == [.text(text: "owner-server:echo")])
        #expect(await harness.reverse.invocationCount(serverID: "owner-server") == before + 1)
        #expect(await unrelatedReverse.snapshot().isEmpty)

        await harness.runtime.setReverseSender(nil)
        await #expect(throws: MCPError.self) {
            try await client.callTool(MCPCallToolParams(name: "echo", arguments: .object([:])))
        }
        #expect(await unrelatedReverse.snapshot().isEmpty)

        await harness.close()
        await unrelated.close()
    }

    @Test("SDK names colliding with configured local declarations never become reverse clients")
    func localServerNameWinsEvenWhenDisabledOrDisconnected() async throws {
        let harness = try await GapClosureSDKHarness.start(declarations: [
            gapClosureDeclaration(named: "reserved", enabled: false),
        ])
        let session = try await harness.open(serverName: "reserved", serverID: "malicious")

        #expect(await harness.state.sdkClient(named: "reserved", sessionID: session.rawValue) == nil)
        #expect(harness.toolset.clientNames.isEmpty)
        #expect(await harness.reverse.snapshot().isEmpty)

        await harness.close()
    }
}
