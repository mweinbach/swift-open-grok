import Foundation
import OpenGrokMCP
import OpenGrokShared
import Testing
@testable import OpenGrokCLI

private actor FoundationPagedMCPHandler: MCPServerHandler {
    let repeatsCursor: Bool

    init(repeatsCursor: Bool = false) {
        self.repeatsCursor = repeatsCursor
    }

    func listTools(_ params: MCPListToolsParams) async throws -> MCPListToolsResult {
        if params.cursor == nil {
            return MCPListToolsResult(
                tools: [MCPTool(name: "first", inputSchema: .object([:]))],
                nextCursor: "second-page"
            )
        }
        return MCPListToolsResult(
            tools: [MCPTool(name: "second", inputSchema: .object([
                "properties": .object(["value": .object(["type": .string("string")])]),
            ]))],
            nextCursor: repeatsCursor ? "second-page" : nil
        )
    }
}

@Suite("Live MCP foundational discovery parity")
struct LiveMCPFoundationParityTests {
    private func makeClient(repeatsCursor: Bool = false) async throws -> MCPClient {
        let server = MCPServer(
            configuration: MCPServerConfiguration(
                serverInfo: MCPImplementation(name: "paged", version: "1.0.0"),
                capabilities: MCPCapabilities(tools: MCPToolsCapability())
            ),
            handler: FoundationPagedMCPHandler(repeatsCursor: repeatsCursor)
        )
        let client = MCPClient(transport: MCPInMemoryTransport(server: server))
        _ = try await client.initialize()
        return client
    }

    @Test("registry discovers tools from every page and normalizes their schemas")
    func registryDiscoversAllPages() async throws {
        let client = try await makeClient()
        defer { Task { await client.close() } }

        let tools = try await MCPClientToolProvider(
            serverName: "paged",
            client: client
        ).listBridgedTools()

        #expect(tools.map(\.name) == ["first", "second"])
        #expect(tools[0].inputSchema == .object([
            "type": .string("object"),
            "properties": .object([:]),
        ]))
        guard case .object(let secondSchema) = tools[1].inputSchema else {
            Issue.record("second tool did not expose an object schema")
            return
        }
        #expect(secondSchema["type"] == .string("object"))
        #expect(secondSchema["properties"] != nil)
    }

    @Test("a repeated pagination cursor fails instead of hanging discovery")
    func repeatedCursorFailsClosed() async throws {
        let client = try await makeClient(repeatsCursor: true)
        defer { Task { await client.close() } }

        do {
            _ = try await MCPClientToolProvider(
                serverName: "paged",
                client: client
            ).listBridgedTools()
            Issue.record("a repeated MCP pagination cursor was accepted")
        } catch let error as MCPError {
            guard case .invalidRequest(let detail) = error else {
                Issue.record("unexpected MCP error: \(error)")
                return
            }
            #expect(detail.contains("second-page"))
        }
    }

    @Test("the workspace transport rejects the same repeated pagination cursor")
    func workspaceTransportRejectsCursorCycles() async throws {
        let client = try await makeClient(repeatsCursor: true)
        defer { Task { await client.close() } }

        do {
            _ = try await MCPClientTransportAdapter(client: client).listTools()
            Issue.record("workspace MCP transport accepted a repeated cursor")
        } catch let error as MCPError {
            #expect(error.description.contains("second-page"))
        }
    }
}
