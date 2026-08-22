import Foundation
import OpenGrokHTTP
import OpenGrokShared
import OpenGrokToolProtocol
import Testing
@testable import OpenGrokMCP

private actor TestMCPHandler: MCPServerHandler {
    private var cancellationAware = false

    func setCancellationAware(_ value: Bool) {
        cancellationAware = value
    }

    func listTools(_ params: MCPListToolsParams) async throws -> MCPListToolsResult {
        _ = params
        return MCPListToolsResult(tools: [
            MCPTool(
                name: "echo",
                description: "Echo input",
                inputSchema: .object(["type": .string("object")])
            )
        ])
    }

    func callTool(_ params: MCPCallToolParams) async throws -> MCPCallToolResult {
        if cancellationAware {
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        return MCPCallToolResult(content: [.text(
            text: params.arguments?.stringValue ?? "missing"
        )])
    }

    func listResources(_ params: MCPListResourcesParams) async throws -> MCPListResourcesResult {
        _ = params
        return MCPListResourcesResult(resources: [
            MCPResource(uri: "memory://one", name: "one", mimeType: "text/plain")
        ])
    }

    func listResourceTemplates(_ params: MCPListResourceTemplatesParams) async throws -> MCPListResourceTemplatesResult {
        _ = params
        return MCPListResourceTemplatesResult(resourceTemplates: [
            MCPResourceTemplate(uriTemplate: "memory://{name}", name: "memory")
        ])
    }

    func readResource(_ params: MCPReadResourceParams) async throws -> MCPReadResourceResult {
        guard params.uri == "memory://one" else { throw MCPError.resourceNotFound(params.uri) }
        return MCPReadResourceResult(contents: [
            MCPResourceContents(uri: params.uri, mimeType: "text/plain", text: "hello")
        ])
    }

    func subscribeResource(_ params: MCPSubscribeResourceParams) async throws {
        _ = params
    }

    func unsubscribeResource(_ params: MCPUnsubscribeResourceParams) async throws {
        _ = params
    }

    func listPrompts(_ params: MCPListPromptsParams) async throws -> MCPListPromptsResult {
        _ = params
        return MCPListPromptsResult(prompts: [
            MCPPrompt(name: "greet", description: "Greeting prompt")
        ])
    }

    func getPrompt(_ params: MCPGetPromptParams) async throws -> MCPGetPromptResult {
        guard params.name == "greet" else { throw MCPError.promptNotFound(params.name) }
        return MCPGetPromptResult(messages: [
            MCPPromptMessage(role: .user, content: .text(text: "hello"))
        ])
    }
}

private func fullCapabilities() -> MCPCapabilities {
    MCPCapabilities(
        prompts: MCPPromptsCapability(),
        resources: MCPResourcesCapability(subscribe: true),
        tools: MCPToolsCapability()
    )
}

private func response(from message: MCPWireMessage?) throws -> MCPResponse {
    guard let message, case .response(let response) = message else {
        throw MCPError.invalidRequest("expected response")
    }
    return response
}

@Suite("OpenGrokMCP")
struct OpenGrokMCPTests {
    @Test("wire codec preserves typed MCP messages deterministically")
    func wireCodec() throws {
        let request = MCPRequest(
            id: .string("request-1"),
            method: MCPMethod.toolsCall,
            params: try mcpJSONValue(MCPCallToolParams(
                name: "echo",
                arguments: .string("hello")
            ))
        )
        let first = try MCPWireCodec.encodeString(.request(request))
        let second = try MCPWireCodec.encodeString(.request(request))
        #expect(first == second)
        #expect(first.contains("\"jsonrpc\":\"2.0\""))

        let decoded = try MCPWireCodec.decodeString(first)
        #expect(decoded == .request(request))

        do {
            _ = try MCPWireCodec.decodeString("{not-json}")
            Issue.record("expected malformed JSON to fail")
        } catch let error as MCPError {
            if case .parse(let detail) = error {
                #expect(detail.hasPrefix("invalid MCP JSON-RPC message:"))
            } else {
                Issue.record("expected MCPError.parse, got \(error)")
            }
        } catch {
            Issue.record("expected MCPError.parse, got \(error)")
        }
    }

    @Test("client and server negotiate lifecycle and route all core methods")
    func lifecycleAndRouting() async throws {
        let handler = TestMCPHandler()
        let server = MCPServer(
            configuration: MCPServerConfiguration(
                serverInfo: MCPImplementation(name: "test-server", version: "1.0"),
                capabilities: fullCapabilities()
            ),
            handler: handler
        )
        let transport = MCPInMemoryTransport(server: server)
        let client = MCPClient(
            transport: transport,
            configuration: MCPClientConfiguration(
                clientInfo: MCPImplementation(name: "test-client", version: "1.0")
            )
        )

        #expect(await client.state() == .disconnected)
        let initialization = try await client.initialize()
        #expect(initialization.serverInfo.name == "test-server")
        #expect(await client.state() == .initialized)
        #expect(await server.state() == .initialized)

        let tools = try await client.listTools()
        #expect(tools.tools.map(\.name) == ["echo"])
        let call = try await client.callTool(MCPCallToolParams(
            name: "echo",
            arguments: .string("hello")
        ))
        #expect(call.content == [.text(text: "hello")])
        let resources = try await client.listResources()
        #expect(resources.resources.count == 1)
        let resourceTemplates = try await client.listResourceTemplates()
        #expect(resourceTemplates.resourceTemplates.count == 1)
        let resource = try await client.readResource(MCPReadResourceParams(uri: "memory://one"))
        #expect(resource.contents[0].text == "hello")
        try await client.subscribeResource(MCPSubscribeResourceParams(uri: "memory://one"))
        try await client.unsubscribeResource(MCPUnsubscribeResourceParams(uri: "memory://one"))
        let prompts = try await client.listPrompts()
        #expect(prompts.prompts[0].name == "greet")
        let prompt = try await client.getPrompt(MCPGetPromptParams(name: "greet"))
        #expect(prompt.messages.count == 1)
        let ping = try await client.request(method: MCPMethod.ping)
        #expect(ping == .object([:]))

        try await client.shutdown()
        #expect(await client.state() == .shuttingDown)
        await client.close()
        #expect(await client.state() == .closed)
        #expect(await server.state() == .closed)
    }

    @Test("server maps lifecycle and routing failures to stable JSON-RPC errors")
    func deterministicErrors() async throws {
        let server = MCPServer()
        let request = MCPRequest(id: .number(7), method: MCPMethod.toolsList)
        let notInitialized = try response(from: await server.handle(.request(request)))
        #expect(notInitialized.error?.code == MCPJSONRPCErrorCode.notInitialized)
        #expect(notInitialized.error?.message == "MCP session is not initialized")

        let initialize = MCPRequest(
            id: .string("init"),
            method: MCPMethod.initialize,
            params: try mcpJSONValue(MCPInitializeParams(
                clientInfo: MCPImplementation(name: "client", version: "1")
            ))
        )
        _ = try await server.handle(.request(initialize))
        let unknown = try response(from: await server.handle(.request(MCPRequest(
            id: .string("unknown"),
            method: "does/not/exist"
        ))))
        #expect(unknown.error?.code == MCPJSONRPCErrorCode.methodNotFound)
        #expect(unknown.error?.data?["subcode"] == .string("method_not_found"))

        let original = MCPError.transport("connection reset")
        let mapped = MCPError.from(original.jsonRPCError())
        #expect(mapped == original)
        #expect(original.code == MCPJSONRPCErrorCode.transport)

        let roundTripErrors: [MCPError] = [
            .parse("bad JSON"),
            .invalidRequest("missing method"),
            .methodNotFound("missing"),
            .invalidParams("wrong shape"),
            .internalError("bug"),
            .notInitialized,
            .alreadyInitialized,
            .cancelled(requestID: .number(3), reason: "user"),
            .timeout(method: "tools/call"),
            .transportClosed,
            .toolNotFound("missing"),
            .resourceNotFound("memory://missing"),
            .promptNotFound("missing"),
            .capabilityUnsupported("resources")
        ]
        for error in roundTripErrors {
            #expect(MCPError.from(error.jsonRPCError()) == error)
        }
    }

    @Test("cancellation notification cancels exactly the matching in-flight request")
    func cancellation() async throws {
        let handler = TestMCPHandler()
        await handler.setCancellationAware(true)
        let server = MCPServer(
            configuration: MCPServerConfiguration(
                capabilities: MCPCapabilities(tools: MCPToolsCapability())
            ),
            handler: handler
        )
        let initialize = MCPRequest(
            id: .string("init"),
            method: MCPMethod.initialize,
            params: try mcpJSONValue(MCPInitializeParams(
                clientInfo: MCPImplementation(name: "client", version: "1")
            ))
        )
        _ = try await server.handle(.request(initialize))

        let requestID = JsonRpcId.string("slow")
        let work = Task<MCPWireMessage?, Never> {
            try? await server.handle(.request(MCPRequest(
                id: requestID,
                method: MCPMethod.toolsCall,
                params: try? mcpJSONValue(MCPCallToolParams(name: "echo"))
            )))
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        _ = try await server.handle(.notification(MCPNotification(
            method: MCPMethod.cancelled,
            params: try mcpJSONValue(MCPCancelledParams(requestId: requestID, reason: "user"))
        )))
        let cancelled = try response(from: await work.value)
        #expect(cancelled.id == requestID)
        #expect(cancelled.error?.code == MCPJSONRPCErrorCode.cancelled)
        #expect(cancelled.error?.data?["reason"]?.stringValue == "user")
    }

    @Test("HTTP transport sends MCP JSON and captures session headers")
    func httpTransport() async throws {
        let payload = MCPResponse(
            id: .string("1"),
            result: .object(["ok": .bool(true)])
        )
        let body = try MCPWireCodec.encode(.response(payload))
        let http = MockHTTPTransport(responses: [
            MockHTTPTransport.ScriptedResponse(
                metadata: HTTPResponseMetadata(
                    statusCode: 200,
                    headers: ["Content-Type": "application/json", "Mcp-Session-Id": "session-1"]
                ),
                body: body
            )
        ])
        let transport = MCPHTTPTransport(
            httpTransport: http,
            configuration: MCPHTTPTransportConfiguration(endpoint: URL(string: "https://example.test/mcp")!)
        )
        _ = try await transport.send(.request(MCPRequest(id: .string("1"), method: MCPMethod.ping)))
        let currentSessionID = await transport.currentSessionID
        #expect(currentSessionID == "session-1")
        #expect(http.recordedRequests.count == 1)
        #expect(http.recordedRequests[0].headers["Content-Type"] == "application/json")
        _ = try MCPWireCodec.decode(http.recordedRequests[0].body ?? Data())
    }

    @Test("HTTP event streams handle CRLF and skip notifications before the matching response")
    func httpEventStreamCorrelatesCRLFResponse() async throws {
        let body = Data([
            ": heartbeat\r\n",
            "event: message\r\n",
            "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{}}\r\n",
            "\r\n",
            "event: message\r\n",
            "data: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"ok\":true}}\r\n",
            "\r\n",
        ].joined().utf8)
        let http = MockHTTPTransport(responses: [
            MockHTTPTransport.ScriptedResponse(
                metadata: HTTPResponseMetadata(
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream"]
                ),
                body: body
            )
        ])
        let transport = MCPHTTPTransport(
            httpTransport: http,
            configuration: MCPHTTPTransportConfiguration(endpoint: URL(string: "https://example.test/mcp")!)
        )

        let message = try await transport.send(.request(MCPRequest(id: .number(7), method: MCPMethod.ping)))
        guard case .response(let response)? = message else {
            Issue.record("expected the JSON-RPC response after the progress event")
            return
        }
        #expect(response.id == .number(7))
        #expect(response.result == .object(["ok": .bool(true)]))
    }

    @Test("HTTP event streams preserve multiline SSE data and ignore other response ids")
    func httpEventStreamPreservesEventsAndMultilineData() async throws {
        let body = Data("""
        data: {"jsonrpc":"2.0","id":"other","result":{"ok":false}}

        event: message
        data: {"jsonrpc":"2.0",
        data: "id":"wanted","result":{"ok":true}}

        """.utf8)
        let http = MockHTTPTransport(responses: [
            MockHTTPTransport.ScriptedResponse(
                metadata: HTTPResponseMetadata(
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream; charset=utf-8"]
                ),
                body: body
            )
        ])
        let transport = MCPHTTPTransport(
            httpTransport: http,
            configuration: MCPHTTPTransportConfiguration(endpoint: URL(string: "https://example.test/mcp")!)
        )

        let message = try await transport.send(.request(MCPRequest(id: .string("wanted"), method: MCPMethod.ping)))
        guard case .response(let response)? = message else {
            Issue.record("expected the multiline response matching the requested id")
            return
        }
        #expect(response.id == .string("wanted"))
        #expect(response.result == .object(["ok": .bool(true)]))
    }

    @Test("HTTP event streams refuse to substitute a response for another request")
    func httpEventStreamRejectsMissingMatchingResponse() async throws {
        let body = Data("data: {\"jsonrpc\":\"2.0\",\"id\":99,\"result\":{}}\n\n".utf8)
        let http = MockHTTPTransport(responses: [
            MockHTTPTransport.ScriptedResponse(
                metadata: HTTPResponseMetadata(
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream"]
                ),
                body: body
            )
        ])
        let transport = MCPHTTPTransport(
            httpTransport: http,
            configuration: MCPHTTPTransportConfiguration(endpoint: URL(string: "https://example.test/mcp")!)
        )

        await #expect(throws: MCPError.self) {
            _ = try await transport.send(.request(MCPRequest(id: .number(7), method: MCPMethod.ping)))
        }
    }
}
