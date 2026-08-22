import Foundation
import OpenGrokHTTP
import OpenGrokToolProtocol
import Testing
@testable import OpenGrokMCP

@Suite("MCP transport event production")
struct MCPTransportEventTests {
    @Test("only gateway catalog entries report a managed MCP server source")
    func managedServerClassification() {
        #expect(McpServerSource.classify(name: "managed_gateway:linear") == .managed)
        #expect(McpServerSource.classify(name: "grok_com_linear") == .local)
        #expect(McpServerSource.classify(name: "github") == .local)
    }

    @Test("independent subscribers retain only their newest bounded events")
    func boundedFanout() async {
        let events = MCPEventStream(bufferLimit: 2)
        let first = events.subscribe()
        let second = events.subscribe()

        events.publish(.ready(server: "files"))
        events.publish(.toolsChanged(server: "files"))
        events.publish(.resourcesChanged(server: "files"))
        events.finish()

        let expected: [McpClientEvent] = [
            .toolsChanged(server: "files"),
            .resourcesChanged(server: "files"),
        ]
        #expect(await collectedTransportEvents(first) == expected)
        #expect(await collectedTransportEvents(second) == expected)
    }

    @Test("subscribers created after shutdown terminate immediately")
    func subscriptionAfterShutdown() async {
        let events = MCPEventStream()
        events.finish()

        #expect(await collectedTransportEvents(events.subscribe()).isEmpty)
    }

    @Test("HTTP SSE notifications before and after the matching response are delivered")
    func httpNotificationsSurroundingResponse() async throws {
        let body = Data([
            "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}\r\n\r\n",
            "data: {\"jsonrpc\":\"2.0\",\"id\":99,\"result\":{\"unrelated\":true}}\r\n\r\n",
            "data: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"ok\":true}}\r\n\r\n",
            "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/list_changed\"}\r\n\r\n",
            "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\r\n\r\n",
        ].joined().utf8)
        let http = MockHTTPTransport(responses: [
            MockHTTPTransport.ScriptedResponse(
                metadata: HTTPResponseMetadata(
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream"]
                ),
                body: body
            ),
        ])
        let transport = MCPHTTPTransport(
            httpTransport: http,
            configuration: MCPHTTPTransportConfiguration(
                endpoint: URL(string: "https://example.test/mcp")!
            )
        )
        let events = MCPEventStream()
        let stream = events.subscribe()
        await transport.setEventSink(events, serverName: "remote", clientID: 19)

        let response = try await transport.send(.request(MCPRequest(
            id: .number(7),
            method: MCPMethod.ping
        )))
        guard case .response(let payload)? = response else {
            Issue.record("expected the response matching JSON-RPC id 7")
            return
        }
        #expect(payload.id == .number(7))

        await transport.close()
        await transport.close()
        events.finish()

        #expect(await collectedTransportEvents(stream) == [
            .toolsChanged(server: "remote"),
            .resourcesChanged(server: "remote"),
            .transportClosed(server: "remote", clientId: 19),
        ])
    }

    @Test("HTTP initialize success emits ready before its once-only close")
    func httpInitializeLifecycle() async throws {
        let payload = MCPResponse(id: .number(1), result: .object([:]))
        let body = try MCPWireCodec.encode(.response(payload))
        let http = MockHTTPTransport(responses: [
            MockHTTPTransport.ScriptedResponse(
                metadata: HTTPResponseMetadata(
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"]
                ),
                body: body
            ),
        ])
        let transport = MCPHTTPTransport(
            httpTransport: http,
            configuration: MCPHTTPTransportConfiguration(
                endpoint: URL(string: "https://example.test/mcp")!
            )
        )
        let events = MCPEventStream()
        let stream = events.subscribe()
        await transport.setEventSink(events, serverName: "remote", clientID: 27)

        let response = try await transport.send(.request(MCPRequest(
            id: .number(1),
            method: MCPMethod.initialize
        )))
        #expect(response == .response(payload))

        await transport.close()
        await transport.close()
        events.finish()

        #expect(await collectedTransportEvents(stream) == [
            .ready(server: "remote"),
            .transportClosed(server: "remote", clientId: 27),
        ])
    }

    @Test("JSON-RPC initialize errors preserve the server's handshake failure reason")
    func httpJSONRPCInitializeFailure() async throws {
        let payload = MCPResponse(
            id: .number(1),
            error: JsonRpcError(code: -32000, message: "credential rejected")
        )
        let http = MockHTTPTransport(responses: [
            MockHTTPTransport.ScriptedResponse(
                metadata: HTTPResponseMetadata(
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"]
                ),
                body: try MCPWireCodec.encode(.response(payload))
            ),
        ])
        let transport = MCPHTTPTransport(
            httpTransport: http,
            configuration: MCPHTTPTransportConfiguration(
                endpoint: URL(string: "https://example.test/mcp")!
            )
        )
        let events = MCPEventStream()
        let stream = events.subscribe()
        await transport.setEventSink(events, serverName: "remote")

        let response = try await transport.send(.request(MCPRequest(
            id: .number(1),
            method: MCPMethod.initialize
        )))
        #expect(response == .response(payload))
        events.finish()

        #expect(await collectedTransportEvents(stream) == [
            .handshakeFailed(server: "remote", reason: "credential rejected"),
        ])
    }

    @Test("HTTP status failures during initialization emit their diagnostic")
    func httpStatusInitializeFailure() async {
        let http = MockHTTPTransport(responses: [
            MockHTTPTransport.ScriptedResponse(
                metadata: HTTPResponseMetadata(statusCode: 503),
                body: Data()
            ),
        ])
        let transport = MCPHTTPTransport(
            httpTransport: http,
            configuration: MCPHTTPTransportConfiguration(
                endpoint: URL(string: "https://example.test/mcp")!
            )
        )
        let events = MCPEventStream()
        let stream = events.subscribe()
        await transport.setEventSink(events, serverName: "remote")

        await #expect(throws: MCPError.self) {
            _ = try await transport.send(.request(MCPRequest(
                id: .number(1),
                method: MCPMethod.initialize
            )))
        }
        events.finish()

        #expect(await collectedTransportEvents(stream) == [
            .handshakeFailed(server: "remote", reason: "MCP transport error: MCP HTTP status 503"),
        ])
    }

    #if !os(Windows)
    @Test("stdio notifications coexist with concurrent out-of-order response correlation")
    func stdioNotificationsAndConcurrentRequests() async throws {
        let script = #"""
        first_id=""
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
          if [ -z "$id" ]; then continue; fi
          if [ -z "$first_id" ]; then
            first_id="$id"
          else
            printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}'
            printf '{"jsonrpc":"2.0","id":%s,"result":{"order":"second"}}\n' "$id"
            printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/resources/list_changed"}'
            printf '{"jsonrpc":"2.0","id":%s,"result":{"order":"first"}}\n' "$first_id"
            first_id=""
          fi
        done
        """#
        let transport = MCPStdioTransport(configuration: MCPStdioTransportConfiguration(
            command: "/bin/sh",
            arguments: ["-c", script],
            requestTimeout: 15
        ))
        defer { Task { await transport.close() } }
        let events = MCPEventStream()
        let stream = events.subscribe()
        await transport.setEventSink(events, serverName: "files", clientID: 42)

        async let first = transport.send(.request(MCPRequest(
            id: .number(1),
            method: MCPMethod.ping
        )))
        async let second = transport.send(.request(MCPRequest(
            id: .number(2),
            method: MCPMethod.ping
        )))
        let (firstMessage, secondMessage) = try await (first, second)
        guard case .response(let firstResponse)? = firstMessage,
              case .response(let secondResponse)? = secondMessage else {
            Issue.record("expected both overlapping requests to complete")
            return
        }
        #expect(firstResponse.id == .number(1))
        #expect(secondResponse.id == .number(2))

        await transport.close()
        await transport.close()
        events.finish()

        #expect(await collectedTransportEvents(stream) == [
            .toolsChanged(server: "files"),
            .resourcesChanged(server: "files"),
            .transportClosed(server: "files", clientId: 42),
        ])
    }
    #endif

    @Test("stdio initialize launch failures emit their handshake diagnostic")
    func stdioInitializeLaunchFailure() async {
        let transport = MCPStdioTransport(configuration: MCPStdioTransportConfiguration(
            command: "/definitely/not/here/mcp-event-server",
            requestTimeout: 5
        ))
        let events = MCPEventStream()
        let stream = events.subscribe()
        await transport.setEventSink(events, serverName: "broken", clientID: 5)

        await #expect(throws: MCPError.self) {
            _ = try await transport.send(.request(MCPRequest(
                id: .number(1),
                method: MCPMethod.initialize
            )))
        }
        events.finish()

        let received = await collectedTransportEvents(stream)
        #expect(received.count == 1)
        guard case .handshakeFailed(let server, let reason)? = received.first else {
            Issue.record("expected a failed handshake for the missing executable")
            return
        }
        #expect(server == "broken")
        #expect(reason.contains("/definitely/not/here/mcp-event-server"))
    }
}

private func collectedTransportEvents(
    _ stream: AsyncStream<McpClientEvent>
) async -> [McpClientEvent] {
    var result: [McpClientEvent] = []
    for await event in stream {
        result.append(event)
    }
    return result
}
