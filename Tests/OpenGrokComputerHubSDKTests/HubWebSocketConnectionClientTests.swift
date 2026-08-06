import Foundation
import Testing
@testable import OpenGrokComputerHubSDK
import OpenGrokComputerHubCore
import OpenGrokHTTP
import OpenGrokShared
import OpenGrokToolProtocol

@Suite("Computer Hub WebSocket transport")
struct HubWebSocketConnectionClientTests {
    @Test("plaintext Hub URLs are restricted to loopback hosts")
    func rejectsInsecureRemoteURL() async throws {
        let user = try UserId("test-user")
        let auth = StaticAuthProvider(
            credential: .bearer(token: "test-token"),
            identity: AuthIdentity(userId: user)
        )
        let configuration = try HubWebSocketConfiguration(
            url: "ws://hub.example/v1/tools",
            auth: auth,
            reconnectAttempts: 0
        )

        do {
            _ = try await HubWebSocketConnectionClient.connect(configuration: configuration)
            Issue.record("plaintext remote Hub URL unexpectedly connected")
        } catch let error as ClientError {
            #expect(error == .insecureScheme(url: configuration.url.absoluteString))
        }
    }

    @Test("upgrade handshake routes progress and terminal response")
    func handshakeProgressAndResponse() async throws {
        let (clientChannel, serverChannel) = InMemoryWebSocketChannel.makePair()
        let clientSocket = WebSocketConnection(channel: clientChannel, role: .client)
        let serverSocket = WebSocketConnection(channel: serverChannel, role: .server)
        let user = try UserId("test-user")
        let auth = StaticAuthProvider(
            credential: .bearer(token: "test-token"),
            identity: AuthIdentity(userId: user)
        )
        let configuration = try HubWebSocketConfiguration(
            url: "ws://localhost/v1/tools",
            auth: auth,
            reconnectAttempts: 0
        )
        let toolId = try ToolId("workspace_rpc")
        let callId = try ToolCallId("call-1")
        let sessionId = try SessionId("session-1")

        let server = Task {
            guard case .text = try await serverSocket.receive() else {
                Issue.record("server did not receive hello")
                return
            }
            let ack = HelloAckMsg(
                connectionId: try ConnectionId("connection-1"),
                userId: user,
                computerHubVersion: "test",
                supportedProtocolVersions: [toolProtocolVersion]
            )
            try await serverSocket.send(.text(try text(ack)))
            guard case .text(let requestText) = try await serverSocket.receive() else {
                Issue.record("server did not receive request")
                return
            }
            let request = try decode(JsonRpcRequest<JSONValue>.self, from: requestText)
            let progress = ToolCallProgressFrame(
                toolCallId: callId,
                kind: "started",
                body: .object(["step": .string("one")])
            )
            let progressNotification = JsonRpcNotification<JSONValue>(
                sessionId: request.sessionId,
                method: Method.toolCallProgress.wireString,
                params: try JSONValue.encode(progress)
            )
            try await serverSocket.send(.text(try text(progressNotification)))
            let result = ToolCallResult(toolCallId: callId, output: .text("done"))
            let response: JsonRpcResponse<JSONValue> = JsonRpcResponse(
                id: request.id,
                sessionId: request.sessionId,
                outcome: .result(try JSONValue.encode(result))
            )
            try await serverSocket.send(.text(try text(response)))
        }

        let client = try await HubWebSocketConnectionClient.connectForTesting(
            configuration: configuration,
            socket: clientSocket
        )
        let progressStream = await client.subscribeProgress(toolCallId: callId)
        let progress = Task { () -> ToolCallProgressFrame? in
            for await frame in progressStream { return frame }
            return nil
        }
        let params = try JSONValue.encode(
            ToolCallParams(toolCallId: callId, toolId: toolId, arguments: .object([:]))
        )
        let request = JsonRpcRequest<JSONValue>(
            id: .newUUID(),
            sessionId: sessionId,
            method: Method.toolCallRequest.wireString,
            params: params
        )
        let response = try await client.request(request)
        guard case .result(let value) = response.outcome else {
            Issue.record("request did not return a result")
            return
        }
        let expectedValue = try JSONValue.encode(
            ToolCallResult(toolCallId: callId, output: .text("done"))
        )
        #expect(value == expectedValue)
        #expect((await progress.value)?.kind == "started")
        await client.close()
        _ = await server.result
    }

    @Test("malformed inbound JSON fails pending requests and disconnects")
    func malformedFrameFailsPendingRequest() async throws {
        let (clientChannel, serverChannel) = InMemoryWebSocketChannel.makePair()
        let clientSocket = WebSocketConnection(channel: clientChannel, role: .client)
        let serverSocket = WebSocketConnection(channel: serverChannel, role: .server)
        let user = try UserId("test-user")
        let auth = StaticAuthProvider(
            credential: .bearer(token: "test-token"),
            identity: AuthIdentity(userId: user)
        )
        let configuration = try HubWebSocketConfiguration(
            url: "ws://localhost/v1/tools",
            auth: auth,
            reconnectAttempts: 0
        )
        let sessionId = try SessionId("session-1")
        let toolId = try ToolId("workspace_rpc")
        let callId = try ToolCallId("call-2")
        let server = Task {
            guard case .text = try await serverSocket.receive() else { return }
            let ack = HelloAckMsg(
                connectionId: try ConnectionId("connection-2"),
                userId: user,
                computerHubVersion: "test",
                supportedProtocolVersions: [toolProtocolVersion]
            )
            try await serverSocket.send(.text(try text(ack)))
            _ = try await serverSocket.receive()
            try await serverSocket.send(.text("{"))
        }
        let client = try await HubWebSocketConnectionClient.connectForTesting(
            configuration: configuration,
            socket: clientSocket
        )
        let request = JsonRpcRequest<JSONValue>(
            id: .newUUID(),
            sessionId: sessionId,
            method: Method.toolCallRequest.wireString,
            params: try JSONValue.encode(
                ToolCallParams(toolCallId: callId, toolId: toolId, arguments: .object([:]))
            )
        )
        do {
            _ = try await client.request(request)
            Issue.record("malformed frame unexpectedly produced a response")
        } catch {
            #expect(!client.hub.isConnected)
        }
        await client.close()
        _ = await server.result
    }

    private func text<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try WireJSONEncoder.make().encode(value), as: UTF8.self)
    }

    private func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        try WireJSONDecoder.make().decode(type, from: Data(text.utf8))
    }
}
