// LiveHubSessionMCPTests.swift
//
// Proves the Rust-direction hub MCP session bridge: local MCP clients register
// qualified tools on a `ToolHarness`, not on a session `FinalizedToolset`.

import Foundation
import OpenGrokComputerHubCore
import OpenGrokComputerHubMCPAdapter
import OpenGrokComputerHubSDK
import OpenGrokMCP
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime
import OpenGrokToolTypes
import OpenGrokToolRegistry
import OpenGrokWorkspaceClient
import Testing
@testable import OpenGrokCLI

// MARK: - Fixtures

private actor HubBridgeHandler: MCPServerHandler {
    private(set) var callCount = 0

    func listTools(_ params: MCPListToolsParams) async throws -> MCPListToolsResult {
        _ = params
        return MCPListToolsResult(tools: [
            MCPTool(
                name: "workspace_read",
                description: "Read workspace files",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string")]),
                    ]),
                ])
            ),
            MCPTool(name: "dangerous_tool", description: "Dangerous"),
        ])
    }

    func callTool(_ params: MCPCallToolParams) async throws -> MCPCallToolResult {
        callCount += 1
        switch params.name {
        case "workspace_read":
            return MCPCallToolResult(content: [
                .text(text: "{\"files\":[\"README.md\"]}"),
            ])
        default:
            return MCPCallToolResult(content: [.text(text: "ok")])
        }
    }

    func calls() -> Int { callCount }
}

private func makeHarness(
    mediation: HubMediation = .mediated(AllowAllHubMediator())
) -> ToolHarness {
    ToolHarnessBuilder(mediation: mediation).build()
}

private func makeConnectedEntry(
    serverName: String,
    handler: HubBridgeHandler
) async throws -> HubMCPClientEntry {
    let server = MCPServer(
        configuration: MCPServerConfiguration(
            serverInfo: MCPImplementation(name: serverName, version: "1.0.0"),
            capabilities: MCPCapabilities(tools: MCPToolsCapability())
        ),
        handler: handler
    )
    let client = MCPClient(transport: MCPInMemoryTransport(server: server))
    _ = try await client.initialize()
    return HubMCPClientEntry(serverName: serverName, client: client)
}

@Suite("Live hub session MCP")
struct LiveHubSessionMCPTests {
    @Test("no clients is a clean no-op")
    func noClientsNoOp() async throws {
        let harness = makeHarness()
        let sessionId = try SessionId("empty-session")

        let outcome = await LiveHubSessionMCP.start(
            sessionId: sessionId,
            clients: [],
            harness: harness,
            mediation: .mediated(AllowAllHubMediator()),
            principal: Principal.new(try UserId("leader"))
        )

        #expect(outcome.handle.isEmpty)
        #expect(outcome.result.started.isEmpty)
        #expect(outcome.result.failed.isEmpty)
        #expect(harness.local.list().isEmpty)
    }

    @Test("adapter start registers qualified tools on the harness")
    func startRegistersOnHarness() async throws {
        let handler = HubBridgeHandler()
        let entry = try await makeConnectedEntry(serverName: "demo", handler: handler)
        let harness = makeHarness()
        let sessionId = try SessionId("register-session")
        let qualified = try #require(qualifiedMCPToolName(server: "demo", tool: "workspace_read"))

        let outcome = await LiveHubSessionMCP.start(
            sessionId: sessionId,
            clients: [entry],
            harness: harness,
            mediation: .mediated(AllowAllHubMediator()),
            principal: Principal.new(try UserId("leader"))
        )

        #expect(outcome.result.started == ["demo"])
        #expect(harness.local.get(try ToolId(qualified)) != nil)
        #expect(harness.local.list().contains { $0.toolId.rawValue == qualified })

        let result = await consumeStreamTerminal(
            await harness.call(
                toolId: try ToolId(qualified),
                args: .object(["path": .string("/")]),
                ctx: ToolCallContext()
            )
        )
        switch result {
        case .success(let output):
            let wire = try output.value.decode(ToolOutputWire.self)
            guard case .text(let text) = wire else {
                Issue.record("expected text output, got \(wire)")
                return
            }
            #expect(text.contains("README.md"))
        case .failure(let error):
            Issue.record("harness call failed: \(error.detail)")
        }

        #expect(await handler.calls() == 1)

        await LiveHubSessionMCP.stop(outcome.handle, harness: harness)
        #expect(harness.local.get(try ToolId(qualified)) == nil)
    }

    @Test("mediation denies a bridged harness call before the MCP transport")
    func mediationDeniesBeforeTransport() async throws {
        let handler = HubBridgeHandler()
        let entry = try await makeConnectedEntry(serverName: "demo", handler: handler)
        let harness = makeHarness(mediation: .mediated(AllowAllHubMediator()))
        let sessionId = try SessionId("deny-session")
        let qualified = try #require(qualifiedMCPToolName(server: "demo", tool: "dangerous_tool"))
        let bridgeMediation = HubMediation.mediated(
            DenyAllHubMediator(reason: "hub MCP blocked by policy")
        )

        let outcome = await LiveHubSessionMCP.start(
            sessionId: sessionId,
            clients: [entry],
            harness: harness,
            mediation: bridgeMediation,
            principal: Principal.new(try UserId("leader"))
        )
        #expect(!outcome.result.started.isEmpty)

        let result = await consumeStreamTerminal(
            await harness.call(
                toolId: try ToolId(qualified),
                args: .null,
                ctx: ToolCallContext()
            )
        )
        guard case .failure(let error) = result else {
            Issue.record("expected denial, got success")
            return
        }
        #expect(error.detail.contains("hub MCP blocked by policy"))
        #expect(await handler.calls() == 0)

        await LiveHubSessionMCP.stop(outcome.handle, harness: harness)
    }

    @Test("MCPClientTransportAdapter round-trips initialize and listTools")
    func adapterRoundTrip() async throws {
        let handler = HubBridgeHandler()
        let entry = try await makeConnectedEntry(serverName: "adapter-demo", handler: handler)
        let adapter = MCPClientTransportAdapter(client: entry.client)

        let info = try await adapter.initialize()
        #expect(info.name == "adapter-demo")

        let tools = try await adapter.listTools()
        #expect(tools.map(\.name).contains("workspace_read"))
    }

    @Test("coordinator disconnect then release closes transport exactly once")
    func coordinatorDisconnectThenReleaseClosesOnce() async throws {
        // MCPClientTransportAdapter.close is a no-op, so this suite cannot prove
        // LiveHubSessionMCP.stop closed a real transport. Close-once is exercised
        // here only through HubMCPBridgeCoordinator + an injectable counting
        // McpTransport (connect → disconnect → release).
        let transport = CountingHubMcpTransport(
            tools: [McpToolDefinition(name: "workspace_read", description: "Read")]
        )
        let toolset = makeCloseOnceToolset()
        var coordinator: HubMCPBridgeCoordinator? = HubMCPBridgeCoordinator()
        let config = McpBridgeConfig(
            sessionId: try SessionId("close-once-disconnect"),
            mediation: .mediated(AllowAllHubMediator())
        )

        _ = try await coordinator!.connect(
            transport: transport,
            config: config,
            toolset: toolset
        )
        await coordinator!.disconnect(toolset: toolset)
        // Successful disconnect completes the shared close; coordinator release
        // must not start another flight.
        #expect(transport.closeCount == 1)

        coordinator = nil
        #expect(transport.closeCount == 1)
    }

    @Test("coordinator release without disconnect still closes transport once")
    func coordinatorReleaseWithoutDisconnectClosesOnce() async throws {
        // Same coordinator seam as above — not a direct LiveHubSessionMCP.stop proof.
        let transport = CountingHubMcpTransport(
            tools: [McpToolDefinition(name: "workspace_read", description: "Read")]
        )
        let toolset = makeCloseOnceToolset()
        var coordinator: HubMCPBridgeCoordinator? = HubMCPBridgeCoordinator()
        let config = McpBridgeConfig(
            sessionId: try SessionId("close-once-release"),
            mediation: .mediated(AllowAllHubMediator())
        )

        _ = try await coordinator!.connect(
            transport: transport,
            config: config,
            toolset: toolset
        )
        #expect(transport.closeCount == 0)

        // Drop without disconnect: McpBridge.deinit must best-effort close.
        coordinator = nil
        #expect(await waitForHubCloseCount(transport, expected: 1))
        #expect(transport.closeCount == 1)
    }
}

// MARK: - Close-once fixtures (HubMCPBridgeCoordinator only; adapter.close is no-op)

private final class CountingHubMcpTransport: McpTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let serverInfo: McpServerInfo
    private let tools: [McpToolDefinition]
    private var closedCount = 0

    init(
        serverInfo: McpServerInfo = McpServerInfo(name: "close-once-server", version: "1.0"),
        tools: [McpToolDefinition]
    ) {
        self.serverInfo = serverInfo
        self.tools = tools
    }

    func initialize() async throws -> McpServerInfo { serverInfo }
    func listTools() async throws -> [McpToolDefinition] { tools }
    func callTool(name: String, arguments: JSONValue) async throws -> McpCallResult {
        _ = (name, arguments)
        return McpCallResult(content: [.text(text: "ok")])
    }

    func close() async throws {
        recordClose()
    }

    private func recordClose() {
        lock.lock()
        defer { lock.unlock() }
        closedCount += 1
    }

    var closeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return closedCount
    }
}

private func makeCloseOnceToolset() -> FinalizedToolset {
    FinalizedToolset(
        tools: [],
        resources: ToolResources(cwd: NSTemporaryDirectory()),
        codeModeNamespaces: [:],
        options: .unrestricted
    )
}

private func waitForHubCloseCount(
    _ transport: CountingHubMcpTransport,
    expected: Int,
    seconds: TimeInterval = 2
) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if transport.closeCount == expected { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return transport.closeCount == expected
}
