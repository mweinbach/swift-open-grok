import Foundation
import Testing
@testable import OpenGrokComputerHubMCPAdapter
import OpenGrokComputerHubCore
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime
import OpenGrokToolTypes

private struct UnexpectedTransportError: Error, Sendable, CustomStringConvertible {
    let message: String

    var description: String { message }
}

private final class MockMcpTransport: McpTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let initializeResponse: Result<McpServerInfo, McpError>
    private let tools: [McpToolDefinition]
    private let listError: McpError?
    private let callResponse: Result<McpCallResult, McpError>
    private let unexpectedCallError: UnexpectedTransportError?
    private let closeError: McpError?
    private var recordedCalls: [(String, JSONValue)] = []
    private var initializeCountValue = 0
    private var listCountValue = 0
    private var closeCountValue = 0

    init(
        initializeResponse: Result<McpServerInfo, McpError>,
        tools: [McpToolDefinition] = [],
        listError: McpError? = nil,
        callResponse: Result<McpCallResult, McpError> = .success(McpCallResult()),
        unexpectedCallError: UnexpectedTransportError? = nil,
        closeError: McpError? = nil
    ) {
        self.initializeResponse = initializeResponse
        self.tools = tools
        self.listError = listError
        self.callResponse = callResponse
        self.unexpectedCallError = unexpectedCallError
        self.closeError = closeError
    }

    func initialize() async throws -> McpServerInfo {
        try recordInitialize().get()
    }

    private func recordInitialize() -> Result<McpServerInfo, McpError> {
        lock.lock()
        defer { lock.unlock() }
        initializeCountValue += 1
        return initializeResponse
    }

    func listTools() async throws -> [McpToolDefinition] {
        if let error = recordList() { throw error }
        return tools
    }

    private func recordList() -> McpError? {
        lock.lock()
        defer { lock.unlock() }
        listCountValue += 1
        return listError
    }

    func callTool(name: String, arguments: JSONValue) async throws -> McpCallResult {
        let result = recordCall(name: name, arguments: arguments)
        if let unexpectedError = result.unexpectedError { throw unexpectedError }
        return try result.response.get()
    }

    private func recordCall(
        name: String,
        arguments: JSONValue
    ) -> (response: Result<McpCallResult, McpError>, unexpectedError: UnexpectedTransportError?) {
        lock.lock()
        defer { lock.unlock() }
        recordedCalls.append((name, arguments))
        return (callResponse, unexpectedCallError)
    }

    func close() async throws {
        if let error = recordClose() { throw error }
    }

    private func recordClose() -> McpError? {
        lock.lock()
        defer { lock.unlock() }
        closeCountValue += 1
        return closeError
    }

    var initializeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return initializeCountValue
    }

    var listCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return listCountValue
    }

    var closeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return closeCountValue
    }

    var calls: [(String, JSONValue)] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }
}

private func sampleServerInfo() -> McpServerInfo {
    McpServerInfo(
        name: "sample-server",
        version: "1.2.3",
        capabilities: .object(["tools": .bool(true)])
    )
}

private func sampleConfig() throws -> McpBridgeConfig {
    McpBridgeConfig(
        sessionId: try SessionId("session-1"),
        mediation: .mediated(AllowAllHubMediator()),
        namespace: "mcp"
    )
}

private func terminalResult(
    _ stream: ToolStream<TypedToolOutput>
) async -> Result<TypedToolOutput, ToolError> {
    for await item in stream {
        if case .terminal(let result) = item { return result }
    }
    return .failure(ToolError(kind: .custom, detail: "stream ended without terminal"))
}

@Suite("OpenGrokComputerHubMCPAdapter")
struct ComputerHubMCPAdapterTests {
    @Test("MCP types preserve camelCase wire keys and defaults")
    func wireTypes() throws {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["query": .object(["type": .string("string")])])
        ])
        let definition = McpToolDefinition(
            name: "search",
            description: "Search items",
            inputSchema: schema
        )
        let encoded = try JSONValue.encode(definition)
        if case .object(let fields) = encoded {
            #expect(fields["inputSchema"] == schema)
            #expect(fields["description"] == .string("Search items"))
            #expect(fields["input_schema"] == nil)
        } else {
            Issue.record("expected object encoding")
        }

        let decodedInfo = try JSONValue.object([
            "name": .string("server"),
            "version": .string("1.0")
        ]).decode(McpServerInfo.self)
        #expect(decodedInfo.capabilities == .null)

        let decodedResult = try JSONValue.object([:]).decode(McpCallResult.self)
        #expect(decodedResult.content.isEmpty)
        #expect(!decodedResult.isError)
    }

    @Test("content decoding rejects unknown and incomplete blocks")
    func rejectsMalformedContent() throws {
        do {
            _ = try JSONValue.object([
                "type": .string("audio"),
                "data": .string("ignored")
            ]).decode(McpContent.self)
            Issue.record("expected unknown content type to fail")
        } catch {
            #expect(error is DecodingError)
        }

        do {
            _ = try JSONValue.object(["type": .string("image")]).decode(McpContent.self)
            Issue.record("expected incomplete image content to fail")
        } catch {
            #expect(error is DecodingError)
        }
    }

    @Test("connect discovers valid tools and skips invalid IDs")
    func connectDiscovery() async throws {
        let transport = MockMcpTransport(
            initializeResponse: .success(sampleServerInfo()),
            tools: [
                McpToolDefinition(
                    name: "search",
                    description: "Search items",
                    inputSchema: .object(["type": .string("object")])
                ),
                McpToolDefinition(name: "", description: "missing name"),
                McpToolDefinition(name: "invalid name", description: "invalid name")
            ]
        )

        let handle = try await McpBridge.connect(transport, try sampleConfig())
        #expect(transport.initializeCount == 1)
        #expect(transport.listCount == 1)
        #expect(handle.serverInfo == sampleServerInfo())
        #expect(handle.bridge.sessionId.rawValue == "session-1")
        #expect(handle.bridge.toolCount() == 1)

        let handler = try #require(handle.bridge.handlers().first)
        #expect(handler.id().rawValue == "search")
        #expect(handler.inputSchema() == .object(["type": .string("object")]))
        let description = handler.description(ctx: ListToolsContext())
        #expect(description.name == "search")
        #expect(description.description == "Search items")
        #expect(description.namespace == "mcp")
        #expect(description.argumentsSchema == .object(["type": .string("object")]))
    }

    @Test("list failure closes an initialized transport")
    func discoveryFailureClosesTransport() async throws {
        let transport = MockMcpTransport(
            initializeResponse: .success(sampleServerInfo()),
            listError: .protocolError(code: -32601, message: "tools/list unavailable")
        )

        do {
            _ = try await McpBridge.connect(transport, try sampleConfig())
            Issue.record("expected connect to fail")
        } catch let error as McpError {
            #expect(error == .protocolError(code: -32601, message: "tools/list unavailable"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(transport.closeCount == 1)
    }

    @Test("initialization failure does not close an uninitialized transport")
    func initializationFailureDoesNotCloseTransport() async throws {
        let transport = MockMcpTransport(
            initializeResponse: .failure(.timeout("handshake"))
        )

        do {
            _ = try await McpBridge.connect(transport, try sampleConfig())
            Issue.record("expected connect to fail")
        } catch let error as McpError {
            #expect(error == .timeout("handshake"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(transport.closeCount == 0)
        #expect(transport.listCount == 0)
    }

    @Test("single text result forwards arguments and flattens output")
    func forwardsTextResult() async throws {
        let transport = MockMcpTransport(
            initializeResponse: .success(sampleServerInfo()),
            tools: [McpToolDefinition(name: "search", description: "Search")],
            callResponse: .success(McpCallResult(content: [.text(text: "found 3")]))
        )
        let handle = try await McpBridge.connect(transport, try sampleConfig())
        let handler = try #require(handle.bridge.handlers().first)
        let args: JSONValue = .object(["query": .string("swift")])

        let result = await terminalResult(await handler.execute(ctx: ToolCallContext(), args: args))
        switch result {
        case .success(let output):
            #expect(output.toolId.rawValue == "search")
            #expect(try output.value.decode(ToolOutputWire.self) == .text("found 3"))
        case .failure(let error):
            Issue.record("unexpected tool error: \(error.detail)")
        }

        #expect(transport.calls.count == 1)
        #expect(transport.calls[0].0 == "search")
        #expect(transport.calls[0].1 == args)
    }

    @Test("structured result preserves text, image, and resource blocks")
    func forwardsStructuredResult() async throws {
        let transport = MockMcpTransport(
            initializeResponse: .success(sampleServerInfo()),
            tools: [McpToolDefinition(name: "inspect")],
            callResponse: .success(McpCallResult(content: [
                .text(text: "details"),
                .image(mimeType: "image/png", data: "base64"),
                .resource(uri: "file:///tmp/out", mimeType: "text/plain", text: "body")
            ]))
        )
        let handle = try await McpBridge.connect(transport, try sampleConfig())
        let handler = try #require(handle.bridge.handlers().first)
        let result = await terminalResult(await handler.handleCall(ctx: ToolCallContext(), args: .null))

        switch result {
        case .success(let output):
            let wire = try output.value.decode(ToolOutputWire.self)
            guard case .mcp(let blocks) = wire else {
                Issue.record("expected MCP output blocks")
                return
            }
            #expect(blocks == [
                .text(text: "details"),
                .image(mimeType: "image/png", data: "base64"),
                .resource(uri: "file:///tmp/out", mimeType: "text/plain", text: "body")
            ])
        case .failure(let error):
            Issue.record("unexpected tool error: \(error.detail)")
        }
    }

    @Test("MCP error responses flatten text and discard non-text content")
    func forwardsMcpErrorResult() async throws {
        let transport = MockMcpTransport(
            initializeResponse: .success(sampleServerInfo()),
            tools: [McpToolDefinition(name: "write")],
            callResponse: .success(McpCallResult(
                content: [
                    .text(text: "permission denied"),
                    .image(mimeType: "image/png", data: "ignored"),
                    .text(text: "try again")
                ],
                isError: true
            ))
        )
        let handle = try await McpBridge.connect(transport, try sampleConfig())
        let handler = try #require(handle.bridge.handlers().first)
        let result = await terminalResult(await handler.execute(ctx: ToolCallContext(), args: .null))

        switch result {
        case .success(let output):
            #expect(try output.value.decode(ToolOutputWire.self) == .text("permission denied\ntry again"))
        case .failure(let error):
            Issue.record("unexpected tool error: \(error.detail)")
        }
    }

    @Test("empty and non-text error results return empty text")
    func emptyResults() {
        #expect(translateMcpResult(McpCallResult()) == .text(""))
        #expect(translateMcpResult(McpCallResult(isError: true)) == .text(""))
        #expect(translateMcpResult(McpCallResult(
            content: [.image(mimeType: "image/png", data: "ignored")],
            isError: true
        )) == .text(""))
    }

    @Test("transport failure becomes an execution error")
    func transportFailure() async throws {
        let transport = MockMcpTransport(
            initializeResponse: .success(sampleServerInfo()),
            tools: [McpToolDefinition(name: "search")],
            callResponse: .failure(.transport("connection reset"))
        )
        let handle = try await McpBridge.connect(transport, try sampleConfig())
        let handler = try #require(handle.bridge.handlers().first)
        let result = await terminalResult(await handler.execute(ctx: ToolCallContext(), args: .null))

        switch result {
        case .success:
            Issue.record("expected execution failure")
        case .failure(let error):
            #expect(error.kind == .execution)
            #expect(error.detail == "transport error: connection reset")
        }
    }

    @Test("unexpected transport throws remain transport errors")
    func unexpectedTransportFailure() async throws {
        let transport = MockMcpTransport(
            initializeResponse: .success(sampleServerInfo()),
            tools: [McpToolDefinition(name: "search")],
            unexpectedCallError: UnexpectedTransportError(message: "invalid response envelope")
        )
        let handle = try await McpBridge.connect(transport, try sampleConfig())
        let handler = try #require(handle.bridge.handlers().first)
        let result = await terminalResult(await handler.execute(ctx: ToolCallContext(), args: .null))

        switch result {
        case .success:
            Issue.record("expected execution failure")
        case .failure(let error):
            #expect(error.kind == .execution)
            #expect(error.detail == "transport error: invalid response envelope")
        }
    }

    @Test("shutdown forwards close and preserves close errors")
    func shutdown() async throws {
        let transport = MockMcpTransport(
            initializeResponse: .success(sampleServerInfo()),
            closeError: .transport("pipe closed")
        )
        let handle = try await McpBridge.connect(transport, try sampleConfig())

        do {
            try await handle.bridge.shutdown()
            Issue.record("expected shutdown to fail")
        } catch let error as McpError {
            #expect(error == .transport("pipe closed"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(transport.closeCount == 1)
    }
}
