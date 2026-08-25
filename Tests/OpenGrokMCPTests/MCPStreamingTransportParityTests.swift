import Foundation
import OpenGrokHTTP
import OpenGrokToolProtocol
import Testing
@testable import OpenGrokMCP

private final class MCPStreamingSignal: @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let pair = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream
        continuation = pair.continuation
    }

    func signal() {
        continuation.yield(())
    }

    func wait() async -> Bool {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next() != nil
    }
}

private func awaitStreamingSignal(
    _ signal: MCPStreamingSignal,
    description: String
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            guard await signal.wait() else {
                throw MCPError.internalError("signal ended before \(description)")
            }
        }
        group.addTask {
            try await Task.sleep(for: .seconds(3))
            throw MCPError.internalError("timed out waiting for \(description)")
        }
        guard try await group.next() != nil else {
            throw MCPError.internalError("signal waiter ended before \(description)")
        }
        group.cancelAll()
    }
}

private final class MCPStreamingHTTPFixture: HTTPTransport, @unchecked Sendable {
    typealias Continuation = AsyncThrowingStream<HTTPStreamEvent, Error>.Continuation
    typealias StreamHandler = @Sendable (HTTPRequest, Int, Continuation) async -> Void
    typealias SendHandler = @Sendable (HTTPRequest, Int) async throws -> HTTPResponse

    private struct State {
        var requests: [HTTPRequest] = []
        var streamed: [HTTPRequest] = []
        var buffered: [HTTPRequest] = []
        var terminated: [HTTPRequest] = []
    }

    private let lock = NSLock()
    private var state = State()
    private let streamHandler: StreamHandler
    private let sendHandler: SendHandler
    private let terminationSignal: MCPStreamingSignal?

    init(
        terminationSignal: MCPStreamingSignal? = nil,
        sendHandler: @escaping SendHandler = { _, _ in
            HTTPResponse(metadata: HTTPResponseMetadata(statusCode: 204), body: Data())
        },
        streamHandler: @escaping StreamHandler
    ) {
        self.terminationSignal = terminationSignal
        self.sendHandler = sendHandler
        self.streamHandler = streamHandler
    }

    var requests: [HTTPRequest] {
        withState { $0.requests }
    }

    var streamedRequests: [HTTPRequest] {
        withState { $0.streamed }
    }

    var bufferedRequests: [HTTPRequest] {
        withState { $0.buffered }
    }

    var terminatedRequests: [HTTPRequest] {
        withState { $0.terminated }
    }

    private func withState<Value>(_ operation: (inout State) -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return operation(&state)
    }

    private func record(_ request: HTTPRequest, streamed: Bool) -> Int {
        withState { state in
            let index = state.requests.count
            state.requests.append(request)
            if streamed {
                state.streamed.append(request)
            } else {
                state.buffered.append(request)
            }
            return index
        }
    }

    private func terminated(_ request: HTTPRequest) {
        withState { $0.terminated.append(request) }
        terminationSignal?.signal()
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await sendHandler(request, record(request, streamed: false))
    }

    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<HTTPStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let index = record(request, streamed: true)
            let task = Task { [streamHandler] in
                await streamHandler(request, index, continuation)
            }
            continuation.onTermination = { [weak self] _ in
                self?.terminated(request)
                task.cancel()
            }
        }
    }
}

private actor MCPStreamingProgressRecorder {
    private var values: [MCPProgressParams] = []

    func append(_ value: MCPProgressParams) {
        values.append(value)
    }

    func snapshot() -> [MCPProgressParams] {
        values
    }
}

private actor MCPStreamingEventRecorder {
    private var values: [McpClientEvent] = []

    func append(_ value: McpClientEvent) {
        values.append(value)
    }

    func snapshot() -> [McpClientEvent] {
        values
    }
}

private actor MCPStreamingAuthorization: MCPAuthorizationProviding {
    private var token: String
    private let replacement: String?
    private var rejectedTokens: [String?] = []

    init(token: String, replacement: String? = nil) {
        self.token = token
        self.replacement = replacement
    }

    func accessToken() async throws -> String {
        token
    }

    func handleUnauthorized(staleToken: String?) async -> Bool {
        rejectedTokens.append(staleToken)
        guard let replacement, token != replacement else { return false }
        token = replacement
        return true
    }

    func unauthorizedTokens() -> [String?] {
        rejectedTokens
    }
}

private let mcpStreamingEndpoint = URL(string: "https://stream.example.test/mcp")!

private func streamingMetadata(
    sessionID: String? = nil,
    statusCode: Int = 200
) -> HTTPResponseMetadata {
    var headers = ["Content-Type": "text/event-stream"]
    if let sessionID {
        headers["Mcp-Session-Id"] = sessionID
    }
    return HTTPResponseMetadata(statusCode: statusCode, headers: headers)
}

private func jsonMetadata(sessionID: String? = nil) -> HTTPResponseMetadata {
    var headers = ["Content-Type": "application/json"]
    if let sessionID {
        headers["Mcp-Session-Id"] = sessionID
    }
    return HTTPResponseMetadata(statusCode: 200, headers: headers)
}

private func sseFrame(
    _ message: MCPWireMessage,
    identifier: String? = nil
) throws -> Data {
    let id = identifier.map { "id: \($0)\n" } ?? ""
    return Data("\(id)data: \(try MCPWireCodec.encodeString(message))\n\n".utf8)
}

@Suite("MCP streamable HTTP transport parity")
struct MCPStreamingTransportParityTests {
    @Test("POST emits genuine progress before returning a response on an indefinitely open stream")
    func streamingProgressPrecedesLiveResponse() async throws {
        let progressObserved = MCPStreamingSignal()
        let releaseResponse = MCPStreamingSignal()
        let recorder = MCPStreamingProgressRecorder()
        let token = JsonRpcId.string("live-progress")
        let progress = MCPProgressParams(
            progressToken: token,
            progress: 1,
            total: 2,
            message: "still running"
        )
        let progressFrame = try sseFrame(.notification(MCPNotification(
            method: MCPMethod.progress,
            params: try mcpJSONValue(progress)
        )))
        let response = MCPResponse(id: .number(7), result: .object(["ok": .bool(true)]))
        let responseFrame = try sseFrame(.response(response))

        let http = MCPStreamingHTTPFixture { _, _, continuation in
            continuation.yield(.metadata(streamingMetadata()))
            continuation.yield(.body(progressFrame))
            guard await releaseResponse.wait(), !Task.isCancelled else { return }
            continuation.yield(.body(responseFrame))
            try? await Task.sleep(for: .seconds(30))
        }
        let transport = MCPHTTPTransport(
            httpTransport: http,
            configuration: MCPHTTPTransportConfiguration(endpoint: mcpStreamingEndpoint)
        )
        let observation = try #require(await transport.observeProgress(token: token) { update in
            await recorder.append(update)
            progressObserved.signal()
        })

        let request = Task {
            try await transport.send(.request(MCPRequest(id: .number(7), method: MCPMethod.ping)))
        }
        defer {
            releaseResponse.signal()
            request.cancel()
        }

        try await awaitStreamingSignal(progressObserved, description: "live MCP progress")
        #expect(await recorder.snapshot() == [progress])
        releaseResponse.signal()

        #expect(try await request.value == .response(response))
        await transport.finishProgress(observation, cancelPending: false)
        #expect(http.streamedRequests.map(\.method) == [.post])
        #expect(http.bufferedRequests.isEmpty)
        await transport.close()
    }

    @Test("split CRLF boundaries retain multiline events and reject unrelated response IDs")
    func fragmentedCRLFAndResponseCorrelation() async throws {
        let unrelated = try sseFrame(.response(MCPResponse(id: .number(99), result: .object([:]))))
        let chunks = [
            unrelated,
            Data("data: {\"jsonrpc\":\"2.0\",\r".utf8),
            Data("\ndata: \"id\":7,\"result\":{\"ok\":true}}\r".utf8),
            Data("\n\r".utf8),
            Data("\n".utf8),
        ]
        let http = MCPStreamingHTTPFixture { _, _, continuation in
            continuation.yield(.metadata(streamingMetadata()))
            for chunk in chunks {
                continuation.yield(.body(chunk))
            }
            continuation.yield(.end)
            continuation.finish()
        }
        let transport = MCPHTTPTransport(
            httpTransport: http,
            configuration: MCPHTTPTransportConfiguration(endpoint: mcpStreamingEndpoint)
        )

        let reply = try await transport.send(.request(MCPRequest(id: .number(7), method: MCPMethod.ping)))
        #expect(reply == .response(MCPResponse(
            id: .number(7),
            result: .object(["ok": .bool(true)])
        )))
        await transport.close()
    }

    @Test("malformed event payloads fail instead of silently becoming an empty response")
    func malformedEventFailsClosed() async {
        let http = MCPStreamingHTTPFixture { _, _, continuation in
            continuation.yield(.metadata(streamingMetadata()))
            continuation.yield(.body(Data("data: {not-json}\n\n".utf8)))
            continuation.yield(.end)
            continuation.finish()
        }
        let transport = MCPHTTPTransport(
            httpTransport: http,
            configuration: MCPHTTPTransportConfiguration(endpoint: mcpStreamingEndpoint)
        )

        await #expect(throws: MCPError.self) {
            try await transport.send(.request(MCPRequest(id: .number(1), method: MCPMethod.ping)))
        }
        await transport.close()
    }

    @Test("unfinished SSE frames are bounded before their JSON-RPC body can grow indefinitely")
    func oversizedEventIsBounded() async {
        let oversized = Data(repeating: 0x78, count: 4 * 1024 * 1024 + 1)
        let http = MCPStreamingHTTPFixture { _, _, continuation in
            continuation.yield(.metadata(streamingMetadata()))
            continuation.yield(.body(oversized))
        }
        let transport = MCPHTTPTransport(
            httpTransport: http,
            configuration: MCPHTTPTransportConfiguration(endpoint: mcpStreamingEndpoint)
        )

        await #expect(throws: MCPError.transport("response buffer exceeded limit 4194304")) {
            try await transport.send(.request(MCPRequest(id: .number(1), method: MCPMethod.ping)))
        }
        await transport.close()
    }

    @Test("cancelling a pending request terminates the underlying live POST stream")
    func cancellationTerminatesLivePOST() async throws {
        let opened = MCPStreamingSignal()
        let terminated = MCPStreamingSignal()
        let http = MCPStreamingHTTPFixture(terminationSignal: terminated) { _, _, continuation in
            continuation.yield(.metadata(streamingMetadata()))
            opened.signal()
            try? await Task.sleep(for: .seconds(30))
        }
        let transport = MCPHTTPTransport(
            httpTransport: http,
            configuration: MCPHTTPTransportConfiguration(endpoint: mcpStreamingEndpoint)
        )
        let request = Task {
            try await transport.send(.request(MCPRequest(id: .number(1), method: MCPMethod.ping)))
        }

        try await awaitStreamingSignal(opened, description: "POST stream opening")
        request.cancel()
        await #expect(throws: MCPError.self) {
            try await request.value
        }
        try await awaitStreamingSignal(terminated, description: "POST stream cancellation")
        #expect(http.terminatedRequests.contains { $0.method == .post })
        await transport.close()
    }

    @Test("closing the transport also cancels a pending indefinitely open POST")
    func closeTerminatesLivePOST() async throws {
        let opened = MCPStreamingSignal()
        let terminated = MCPStreamingSignal()
        let http = MCPStreamingHTTPFixture(terminationSignal: terminated) { _, _, continuation in
            continuation.yield(.metadata(streamingMetadata()))
            opened.signal()
            try? await Task.sleep(for: .seconds(30))
        }
        let transport = MCPHTTPTransport(
            httpTransport: http,
            configuration: MCPHTTPTransportConfiguration(endpoint: mcpStreamingEndpoint)
        )
        let request = Task {
            try await transport.send(.request(MCPRequest(id: .number(1), method: MCPMethod.ping)))
        }

        try await awaitStreamingSignal(opened, description: "POST stream opening")
        await transport.close()
        await #expect(throws: MCPError.self) {
            try await request.value
        }
        try await awaitStreamingSignal(terminated, description: "closed POST stream")
    }

    @Test("401 response bodies cannot publish events before one authenticated POST retry")
    func unauthorizedPOSTRetriesWithoutLeakingEvents() async throws {
        let authorization = MCPStreamingAuthorization(token: "expired", replacement: "renewed")
        let events = MCPEventStream()
        let stream = events.subscribe()
        let spoofed = try sseFrame(.notification(MCPNotification(
            method: "notifications/tools/list_changed"
        )))
        let response = MCPResponse(id: .number(8), result: .object([:]))
        let valid = try sseFrame(.response(response))
        let http = MCPStreamingHTTPFixture { _, index, continuation in
            if index == 0 {
                continuation.yield(.metadata(streamingMetadata(statusCode: 401)))
                continuation.yield(.body(spoofed))
            } else {
                continuation.yield(.metadata(streamingMetadata()))
                continuation.yield(.body(valid))
            }
            continuation.yield(.end)
            continuation.finish()
        }
        let transport = MCPHTTPTransport(
            httpTransport: http,
            configuration: MCPHTTPTransportConfiguration(endpoint: mcpStreamingEndpoint),
            authorization: authorization
        )
        await transport.setEventSink(events, serverName: "secured", clientID: 31)

        #expect(try await transport.send(.request(MCPRequest(
            id: .number(8),
            method: MCPMethod.ping
        ))) == .response(response))
        #expect(http.streamedRequests.map { $0.headers["Authorization"] } == [
            "Bearer expired",
            "Bearer renewed",
        ])
        #expect(await authorization.unauthorizedTokens() == ["expired"])

        await transport.close()
        events.finish()
        var delivered: [McpClientEvent] = []
        for await event in stream {
            delivered.append(event)
        }
        #expect(delivered == [.transportClosed(server: "secured", clientId: 31)])
    }

    @Test("session GET refreshes a rejected bearer token without publishing its unauthorized body")
    func unauthorizedGETRetriesWithoutLeakingEvents() async throws {
        let authorizedNotification = MCPStreamingSignal()
        let authorization = MCPStreamingAuthorization(token: "stale-get", replacement: "fresh-get")
        let initializeResponse = MCPResponse(id: .number(1), result: .object([:]))
        let initializeBody = try MCPWireCodec.encode(.response(initializeResponse))
        let spoofed = try sseFrame(.notification(MCPNotification(
            method: "notifications/tools/list_changed"
        )))
        let trusted = try sseFrame(.notification(MCPNotification(
            method: "notifications/resources/list_changed"
        )))
        let http = MCPStreamingHTTPFixture { request, _, continuation in
            switch request.method {
            case .post:
                continuation.yield(.metadata(jsonMetadata(sessionID: "session-auth")))
                continuation.yield(.body(initializeBody))
                continuation.yield(.end)
                continuation.finish()

            case .get:
                if request.headers["Authorization"] == "Bearer stale-get" {
                    continuation.yield(.metadata(streamingMetadata(statusCode: 401)))
                    continuation.yield(.body(spoofed))
                    continuation.yield(.end)
                    continuation.finish()
                } else {
                    continuation.yield(.metadata(streamingMetadata(sessionID: "session-auth")))
                    continuation.yield(.body(trusted))
                    try? await Task.sleep(for: .seconds(30))
                }

            default:
                continuation.finish()
            }
        }
        let transport = MCPHTTPTransport(
            httpTransport: http,
            configuration: MCPHTTPTransportConfiguration(endpoint: mcpStreamingEndpoint),
            authorization: authorization
        )
        let events = MCPEventStream()
        let subscription = events.subscribe()
        let recorder = MCPStreamingEventRecorder()
        let collector = Task {
            for await event in subscription {
                await recorder.append(event)
                if case .resourcesChanged = event {
                    authorizedNotification.signal()
                }
            }
        }
        await transport.setEventSink(events, serverName: "auth-get", clientID: 39)

        #expect(try await transport.send(.request(MCPRequest(
            id: .number(1),
            method: MCPMethod.initialize
        ))) == .response(initializeResponse))
        try await awaitStreamingSignal(
            authorizedNotification,
            description: "authorized session GET notification"
        )
        await transport.close()
        events.finish()
        await collector.value

        let gets = http.streamedRequests.filter { $0.method == .get }
        #expect(gets.map { $0.headers["Authorization"] } == [
            "Bearer stale-get",
            "Bearer fresh-get",
        ])
        #expect(await authorization.unauthorizedTokens() == ["stale-get"])
        #expect(await recorder.snapshot() == [
            .ready(server: "auth-get"),
            .resourcesChanged(server: "auth-get"),
            .transportClosed(server: "auth-get", clientId: 39),
        ])
    }

    @Test("authenticated session GET reconnects with Last-Event-ID and DELETE tears down once")
    func authenticatedSessionNotificationsReconnectAndDelete() async throws {
        let deliveredBoth = MCPStreamingSignal()
        let authorization = MCPStreamingAuthorization(token: "session-token")
        let initialResponse = MCPResponse(id: .number(1), result: .object([:]))
        let initialBody = try MCPWireCodec.encode(.response(initialResponse))
        let firstNotification = try sseFrame(
            .notification(MCPNotification(method: "notifications/tools/list_changed")),
            identifier: "event-one"
        )
        let secondNotification = try sseFrame(
            .notification(MCPNotification(method: "notifications/resources/list_changed")),
            identifier: "event-two"
        )
        let http = MCPStreamingHTTPFixture { request, _, continuation in
            switch request.method {
            case .post:
                continuation.yield(.metadata(jsonMetadata(sessionID: "session-7")))
                continuation.yield(.body(initialBody))
                continuation.yield(.end)
                continuation.finish()

            case .get:
                continuation.yield(.metadata(streamingMetadata(sessionID: "session-7")))
                if request.headers["Last-Event-ID"] == nil {
                    continuation.yield(.body(firstNotification))
                    continuation.yield(.end)
                    continuation.finish()
                } else {
                    continuation.yield(.body(secondNotification))
                    try? await Task.sleep(for: .seconds(30))
                }

            default:
                continuation.finish()
            }
        }
        let transport = MCPHTTPTransport(
            httpTransport: http,
            configuration: MCPHTTPTransportConfiguration(endpoint: mcpStreamingEndpoint),
            authorization: authorization
        )
        let events = MCPEventStream()
        let subscription = events.subscribe()
        let recorder = MCPStreamingEventRecorder()
        let collector = Task {
            for await event in subscription {
                await recorder.append(event)
                if case .resourcesChanged = event {
                    deliveredBoth.signal()
                }
            }
        }
        await transport.setEventSink(events, serverName: "live", clientID: 41)

        #expect(try await transport.send(.request(MCPRequest(
            id: .number(1),
            method: MCPMethod.initialize
        ))) == .response(initialResponse))
        try await awaitStreamingSignal(deliveredBoth, description: "reconnected GET notification")
        await transport.close()
        await transport.close()
        events.finish()
        await collector.value

        let requests = http.requests
        let gets = requests.filter { $0.method == .get }
        #expect(gets.count == 2)
        #expect(gets[0].headers["Last-Event-ID"] == nil)
        #expect(gets[1].headers["Last-Event-ID"] == "event-one")
        #expect(gets.allSatisfy { $0.headers["Mcp-Session-Id"] == "session-7" })
        #expect(gets.allSatisfy { $0.headers["Accept"] == "text/event-stream" })
        #expect(requests.allSatisfy { $0.headers["Authorization"] == "Bearer session-token" })
        let deletes = http.bufferedRequests.filter { $0.method == .delete }
        #expect(deletes.count == 1)
        #expect(deletes[0].headers["Mcp-Session-Id"] == "session-7")
        #expect(await recorder.snapshot() == [
            .ready(server: "live"),
            .toolsChanged(server: "live"),
            .resourcesChanged(server: "live"),
            .transportClosed(server: "live", clientId: 41),
        ])
    }

    @Test("GET notifications bearing another session identifier never cross client boundaries")
    func rejectsCrossSessionServerEvents() async throws {
        let validNotificationArrived = MCPStreamingSignal()
        let firstResponse = MCPResponse(id: .number(1), result: .object([:]))
        let secondResponse = MCPResponse(id: .number(2), result: .object([:]))
        let firstBody = try MCPWireCodec.encode(.response(firstResponse))
        let secondBody = try MCPWireCodec.encode(.response(secondResponse))
        let spoofed = try sseFrame(.notification(MCPNotification(
            method: "notifications/tools/list_changed"
        )))
        let valid = try sseFrame(.notification(MCPNotification(
            method: "notifications/resources/list_changed"
        )))

        let http = MCPStreamingHTTPFixture { request, _, continuation in
            let first = request.url.path == "/first"
            switch request.method {
            case .post:
                continuation.yield(.metadata(jsonMetadata(sessionID: first ? "session-a" : "session-b")))
                continuation.yield(.body(first ? firstBody : secondBody))
                continuation.yield(.end)
                continuation.finish()

            case .get:
                continuation.yield(.metadata(streamingMetadata(sessionID: "session-b")))
                continuation.yield(.body(first ? spoofed : valid))
                if first {
                    continuation.yield(.end)
                    continuation.finish()
                } else {
                    try? await Task.sleep(for: .seconds(30))
                }

            default:
                continuation.finish()
            }
        }
        let first = MCPHTTPTransport(
            httpTransport: http,
            configuration: MCPHTTPTransportConfiguration(
                endpoint: URL(string: "https://stream.example.test/first")!
            )
        )
        let second = MCPHTTPTransport(
            httpTransport: http,
            configuration: MCPHTTPTransportConfiguration(
                endpoint: URL(string: "https://stream.example.test/second")!
            )
        )
        let firstEvents = MCPEventStream()
        let secondEvents = MCPEventStream()
        let firstSubscription = firstEvents.subscribe()
        let secondSubscription = secondEvents.subscribe()
        let firstRecorder = MCPStreamingEventRecorder()
        let secondRecorder = MCPStreamingEventRecorder()
        let firstCollector = Task {
            for await event in firstSubscription {
                await firstRecorder.append(event)
            }
        }
        let secondCollector = Task {
            for await event in secondSubscription {
                await secondRecorder.append(event)
                if case .resourcesChanged = event {
                    validNotificationArrived.signal()
                }
            }
        }
        await first.setEventSink(firstEvents, serverName: "first", clientID: 51)
        await second.setEventSink(secondEvents, serverName: "second", clientID: 52)

        #expect(try await first.send(.request(MCPRequest(
            id: .number(1), method: MCPMethod.initialize
        ))) == .response(firstResponse))
        #expect(try await second.send(.request(MCPRequest(
            id: .number(2), method: MCPMethod.initialize
        ))) == .response(secondResponse))
        try await awaitStreamingSignal(
            validNotificationArrived,
            description: "isolated second-session notification"
        )

        await first.close()
        await second.close()
        firstEvents.finish()
        secondEvents.finish()
        await firstCollector.value
        await secondCollector.value

        #expect(await firstRecorder.snapshot() == [
            .ready(server: "first"),
            .transportClosed(server: "first", clientId: 51),
        ])
        #expect(await secondRecorder.snapshot() == [
            .ready(server: "second"),
            .resourcesChanged(server: "second"),
            .transportClosed(server: "second", clientId: 52),
        ])
    }
}
