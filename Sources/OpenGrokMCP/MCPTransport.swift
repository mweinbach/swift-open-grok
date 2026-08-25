import Foundation
import OpenGrokHTTP
import OpenGrokToolProtocol

public protocol MCPTransport: Sendable {
    func send(_ message: MCPWireMessage) async throws -> MCPWireMessage?
    func close() async
}

struct MCPProgressObservation: Sendable {
    let token: JsonRpcId
    let identifier: UUID
}

protocol MCPProgressObservingTransport: MCPTransport {
    func observeProgress(
        token: JsonRpcId,
        onProgress: @escaping @Sendable (MCPProgressParams) async -> Void
    ) async -> MCPProgressObservation?
    func finishProgress(_ observation: MCPProgressObservation, cancelPending: Bool) async
}

public enum MCPWireCodec {
    public static func encode(_ message: MCPWireMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(message)
        } catch {
            throw MCPError.parse("unable to encode MCP message: \(error)")
        }
    }

    public static func decode(_ data: Data) throws -> MCPWireMessage {
        guard !data.isEmpty else {
            throw MCPError.parse("empty MCP message")
        }
        do {
            return try JSONDecoder().decode(MCPWireMessage.self, from: data)
        } catch {
            throw MCPError.parse("invalid MCP JSON-RPC message: \(error)")
        }
    }

    public static func encodeString(_ message: MCPWireMessage) throws -> String {
        guard let string = String(data: try encode(message), encoding: .utf8) else {
            throw MCPError.parse("MCP message is not valid UTF-8")
        }
        return string
    }

    public static func decodeString(_ string: String) throws -> MCPWireMessage {
        guard let data = string.data(using: .utf8) else {
            throw MCPError.parse("MCP message is not valid UTF-8")
        }
        return try decode(data)
    }
}

public struct MCPHTTPTransportConfiguration: Sendable, Equatable {
    public var endpoint: URL
    public var headers: [String: String]
    public var timeout: TimeInterval?

    public init(
        endpoint: URL,
        headers: [String: String] = [:],
        timeout: TimeInterval? = nil
    ) {
        self.endpoint = endpoint
        self.headers = headers
        self.timeout = timeout
    }
}

/// Bearer-token seam for OAuth-protected MCP servers, filled by
/// `MCPAuthorizationManager`. Mirrors rmcp's `AuthClient` wrapper, which
/// injects the token on every streamable-HTTP operation
/// (rmcp-2.1.0 transport/common/auth/streamable_http_client.rs:9-67) as
/// `Authorization: Bearer {token}` (transport/auth.rs:1731-1737).
public protocol MCPAuthorizationProviding: Sendable {
    /// Token for the next request. Refreshes proactively when the stored
    /// token is within the expiry buffer.
    func accessToken() async throws -> String
    /// Called after an HTTP 401. Returns `true` when a one-shot retry is
    /// worthwhile — a fresh token appeared on disk (another session or
    /// process authenticated) or a refresh grant succeeded. This is the
    /// non-browser prefix of upstream's tool-call recovery ladder
    /// (`force_reauth(false)`, xai-grok-mcp/src/servers.rs:2884-2983).
    func handleUnauthorized(staleToken: String?) async -> Bool
}

private struct MCPIncrementalEventParser: Sendable {
    private var parser = SSEParser(maxBufferedBytes: 4 * 1024 * 1024)
    private var pendingCarriageReturn = false

    var lastEventID: String? { parser.lastSeenEventID }

    mutating func push(_ chunk: Data) throws -> [SSEEvent] {
        guard !chunk.isEmpty else { return [] }

        var bytes = chunk
        if pendingCarriageReturn {
            bytes.insert(0x0D, at: bytes.startIndex)
            pendingCarriageReturn = false
        }

        // SSEParser normalizes complete CRLF pairs within each push. Holding a
        // trailing CR prevents a chunk boundary from becoming a false blank line.
        if bytes.last == 0x0D {
            bytes.removeLast()
            pendingCarriageReturn = true
        }

        if parser.retainedBytes + bytes.count + (pendingCarriageReturn ? 1 : 0)
            > parser.maxBufferedBytes {
            throw HTTPError.bufferExceeded(limit: parser.maxBufferedBytes)
        }
        guard !bytes.isEmpty else { return [] }
        return try parser.push(bytes)
    }

    mutating func finish() throws -> [SSEEvent] {
        var completed: [SSEEvent] = []
        if pendingCarriageReturn {
            pendingCarriageReturn = false
            completed = try parser.push(Data([0x0D]))
        }
        completed.append(contentsOf: parser.finish())
        return completed
    }
}

private struct MCPHTTPPostResult: Sendable {
    let metadata: HTTPResponseMetadata
    let message: MCPWireMessage?
}

private enum MCPHTTPEventStreamResult: Sendable {
    case ended
    case unauthorized
    case unsupported
}

public actor MCPHTTPTransport: MCPTransport, MCPProgressObservingTransport {
    private static let maximumResponseBytes = 4 * 1024 * 1024

    private let httpTransport: any HTTPTransport
    private let configuration: MCPHTTPTransportConfiguration
    private let authorization: (any MCPAuthorizationProviding)?
    private let eventEmitter = MCPTransportEventEmitter()
    private var sessionID: String?
    private var isClosed = false
    private var isInitialized = false
    private var hasEventSink = false
    private var eventStreamTask: Task<Void, Never>?
    private var eventStreamGeneration: UInt64 = 0
    private var lastEventID: String?
    private var activeRequests: [UUID: Task<MCPHTTPPostResult, Error>] = [:]

    public init(
        httpTransport: any HTTPTransport,
        configuration: MCPHTTPTransportConfiguration,
        authorization: (any MCPAuthorizationProviding)? = nil
    ) {
        self.httpTransport = httpTransport
        self.configuration = configuration
        self.authorization = authorization
    }

    public var currentSessionID: String? { sessionID }

    public func setEventSink(
        _ events: MCPEventStream?,
        serverName: String,
        clientID: UInt64 = 0
    ) {
        eventEmitter.configure(events, serverName: serverName, clientID: clientID)
        hasEventSink = events != nil
        if hasEventSink {
            startEventStreamIfNeeded()
        } else {
            eventStreamTask?.cancel()
            eventStreamTask = nil
            eventStreamGeneration &+= 1
        }
    }

    func observeProgress(
        token: JsonRpcId,
        onProgress: @escaping @Sendable (MCPProgressParams) async -> Void
    ) -> MCPProgressObservation? {
        eventEmitter.observeProgress(token: token, onProgress: onProgress)
    }

    func finishProgress(_ observation: MCPProgressObservation, cancelPending: Bool) async {
        guard let delivery = eventEmitter.finishProgress(
            observation,
            cancelPending: cancelPending
        ) else { return }
        await delivery.value
    }

    public func send(_ message: MCPWireMessage) async throws -> MCPWireMessage? {
        let isInitialize: Bool
        if case .request(let request) = message {
            isInitialize = request.method == MCPMethod.initialize
        } else {
            isInitialize = false
        }

        do {
            let response = try await sendMessage(message)
            if isInitialize, case .response(let payload)? = response {
                eventEmitter.initialized(payload)
                if payload.error == nil {
                    isInitialized = true
                    startEventStreamIfNeeded()
                }
            } else if isInitialize, response == nil {
                eventEmitter.handshakeFailed(MCPError.transport("MCP initialize returned no response"))
            }
            return response
        } catch {
            if isInitialize {
                eventEmitter.handshakeFailed(error)
            }
            throw error
        }
    }

    private func sendMessage(_ message: MCPWireMessage) async throws -> MCPWireMessage? {
        guard !isClosed else { throw MCPError.transportClosed }
        let body = try MCPWireCodec.encode(message)

        do {
            var attachedToken: String?
            var response = try await sendOnce(
                message: message,
                body: body,
                attachedToken: &attachedToken
            )
            // 401 with an auth seam: try disk-fresh/refresh recovery once,
            // then replay. Upstream recovers the same failure via
            // `force_reauth(false)` + one retry at the tool-call layer
            // (servers.rs:1465-1493); the browser escalation arm of that
            // ladder stays with the explicit `mcp login` trigger.
            if response.metadata.statusCode == 401,
               let authorization,
               await authorization.handleUnauthorized(staleToken: attachedToken) {
                response = try await sendOnce(
                    message: message,
                    body: body,
                    attachedToken: &attachedToken
                )
            }
            guard (200..<300).contains(response.metadata.statusCode) else {
                throw MCPError.transport("MCP HTTP status \(response.metadata.statusCode)")
            }
            return response.message
        } catch let error as MCPError {
            throw error
        } catch {
            throw mcpError(from: error)
        }
    }

    private func sendOnce(
        message: MCPWireMessage,
        body: Data,
        attachedToken: inout String?
    ) async throws -> MCPHTTPPostResult {
        let request = try await makeRequest(
            method: .post,
            body: body,
            sessionID: sessionID,
            attachedToken: &attachedToken
        )
        let requestID: JsonRpcId?
        if case .request(let payload) = message {
            requestID = payload.id
        } else {
            requestID = nil
        }

        let identifier = UUID()
        let operation = Task { [weak self] () throws -> MCPHTTPPostResult in
            guard let self else { throw MCPError.transportClosed }
            return try await self.readPOST(request, matching: requestID)
        }
        activeRequests[identifier] = operation
        defer { activeRequests.removeValue(forKey: identifier) }

        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    private func makeRequest(
        method: HTTPMethod,
        body: Data? = nil,
        sessionID: String?,
        lastEventID: String? = nil,
        attachedToken: inout String?
    ) async throws -> HTTPRequest {
        attachedToken = nil
        var headers = configuration.headers
        if method == .post {
            headers["Content-Type"] = headers["Content-Type"] ?? "application/json"
        }
        headers["Accept"] = headers["Accept"]
            ?? (method == .get ? "text/event-stream" : "application/json, text/event-stream")
        if let sessionID {
            headers["Mcp-Session-Id"] = sessionID
        }
        if let lastEventID {
            headers["Last-Event-ID"] = lastEventID
        }
        // A statically configured Authorization header wins; upstream never
        // builds the auth client when config carries one (servers.rs:4294-4304).
        let hasStaticAuthorization = headers.keys.contains {
            $0.caseInsensitiveCompare("Authorization") == .orderedSame
        }
        if let authorization, !hasStaticAuthorization {
            let token: String
            do {
                token = try await authorization.accessToken()
            } catch let error as MCPAuthError {
                throw MCPError.transport(String(describing: error))
            }
            attachedToken = token
            headers["Authorization"] = "Bearer \(token)"
        }

        return HTTPRequest(
            method: method,
            url: configuration.endpoint,
            headers: headers,
            body: body,
            timeout: configuration.timeout,
            idempotency: method == .post ? .nonIdempotent : .idempotent
        )
    }

    private func readPOST(
        _ request: HTTPRequest,
        matching requestID: JsonRpcId?
    ) async throws -> MCPHTTPPostResult {
        var metadata: HTTPResponseMetadata?
        var responseBody = Data()
        var parser = MCPIncrementalEventParser()
        var sawDataEvent = false

        for try await event in httpTransport.stream(request) {
            try Task.checkCancellation()
            switch event {
            case .metadata(let value):
                guard metadata == nil else {
                    throw MCPError.parse("MCP HTTP stream repeated response metadata")
                }
                metadata = value
                guard (200..<300).contains(value.statusCode) else {
                    return MCPHTTPPostResult(metadata: value, message: nil)
                }
                if let nextSessionID = headerValue("mcp-session-id", in: value.headers) {
                    updateSessionID(nextSessionID)
                }

            case .body(let chunk):
                guard let metadata else {
                    throw MCPError.parse("MCP HTTP stream sent body before response metadata")
                }
                if metadata.isEventStream {
                    let events = try parser.push(chunk)
                    if let message = try matchingMessage(
                        in: events,
                        requestID: requestID,
                        sawDataEvent: &sawDataEvent
                    ) {
                        return MCPHTTPPostResult(metadata: metadata, message: message)
                    }
                } else {
                    guard responseBody.count <= Self.maximumResponseBytes - chunk.count else {
                        throw HTTPError.bufferExceeded(limit: Self.maximumResponseBytes)
                    }
                    responseBody.append(chunk)
                }

            case .end:
                return try finishPOST(
                    metadata: metadata,
                    body: responseBody,
                    parser: &parser,
                    requestID: requestID,
                    sawDataEvent: &sawDataEvent
                )
            }
        }

        try Task.checkCancellation()
        return try finishPOST(
            metadata: metadata,
            body: responseBody,
            parser: &parser,
            requestID: requestID,
            sawDataEvent: &sawDataEvent
        )
    }

    private func finishPOST(
        metadata: HTTPResponseMetadata?,
        body: Data,
        parser: inout MCPIncrementalEventParser,
        requestID: JsonRpcId?,
        sawDataEvent: inout Bool
    ) throws -> MCPHTTPPostResult {
        guard let metadata else {
            throw MCPError.transport("MCP HTTP stream ended without response metadata")
        }
        guard metadata.isEventStream else {
            return MCPHTTPPostResult(
                metadata: metadata,
                message: body.isEmpty ? nil : try MCPWireCodec.decode(body)
            )
        }

        if let message = try matchingMessage(
            in: parser.finish(),
            requestID: requestID,
            sawDataEvent: &sawDataEvent
        ) {
            return MCPHTTPPostResult(metadata: metadata, message: message)
        }
        guard sawDataEvent else {
            throw MCPError.parse("MCP event stream contained no data event")
        }
        throw MCPError.parse("MCP event stream contained no response matching the request id")
    }

    private func matchingMessage(
        in events: [SSEEvent],
        requestID: JsonRpcId?,
        sawDataEvent: inout Bool
    ) throws -> MCPWireMessage? {
        var matchedMessage: MCPWireMessage?
        for event in events {
            guard !event.data.isEmpty else { continue }
            sawDataEvent = true
            let message = try MCPWireCodec.decodeString(event.data)
            if case .notification(let notification) = message {
                eventEmitter.notification(notification)
                if requestID == nil, matchedMessage == nil {
                    matchedMessage = message
                }
                continue
            }
            guard matchedMessage == nil else { continue }
            if let requestID {
                guard case .response(let response) = message, response.id == requestID else {
                    continue
                }
            }
            matchedMessage = message
        }
        return matchedMessage
    }

    private func updateSessionID(_ value: String) {
        guard sessionID != value else { return }
        sessionID = value
        lastEventID = nil
        eventStreamTask?.cancel()
        eventStreamTask = nil
        eventStreamGeneration &+= 1
        startEventStreamIfNeeded()
    }

    private func startEventStreamIfNeeded() {
        guard !isClosed,
              isInitialized,
              hasEventSink,
              let sessionID,
              eventStreamTask == nil
        else { return }

        eventStreamGeneration &+= 1
        let generation = eventStreamGeneration
        eventStreamTask = Task { [weak self] in
            await self?.runEventStream(sessionID: sessionID, generation: generation)
        }
    }

    private func runEventStream(sessionID: String, generation: UInt64) async {
        var consecutiveFailures = 0
        var recoveredUnauthorized = false

        while isCurrentEventStream(sessionID: sessionID, generation: generation) {
            var attachedToken: String?
            let openedAt = ProcessInfo.processInfo.systemUptime

            do {
                let request = try await makeRequest(
                    method: .get,
                    sessionID: sessionID,
                    lastEventID: lastEventID,
                    attachedToken: &attachedToken
                )
                guard isCurrentEventStream(sessionID: sessionID, generation: generation) else {
                    return
                }

                let outcome = try await readEventStream(
                    request,
                    sessionID: sessionID,
                    generation: generation
                )
                switch outcome {
                case .unsupported:
                    return
                case .unauthorized:
                    guard !recoveredUnauthorized,
                          let authorization,
                          await authorization.handleUnauthorized(staleToken: attachedToken)
                    else { return }
                    recoveredUnauthorized = true
                    continue
                case .ended:
                    recoveredUnauthorized = false
                }
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentEventStream(sessionID: sessionID, generation: generation) else {
                    return
                }
            }

            guard isCurrentEventStream(sessionID: sessionID, generation: generation) else {
                return
            }
            if ProcessInfo.processInfo.systemUptime - openedAt >= 2 {
                consecutiveFailures = 0
            } else {
                consecutiveFailures += 1
            }

            if consecutiveFailures > 1 {
                let exponent = min(consecutiveFailures - 2, 6)
                let milliseconds = min(500 * (1 << exponent), 30_000)
                do {
                    try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func readEventStream(
        _ request: HTTPRequest,
        sessionID: String,
        generation: UInt64
    ) async throws -> MCPHTTPEventStreamResult {
        var metadata: HTTPResponseMetadata?
        var parser = MCPIncrementalEventParser()

        for try await event in httpTransport.stream(request) {
            try Task.checkCancellation()
            guard isCurrentEventStream(sessionID: sessionID, generation: generation) else {
                return .unsupported
            }

            switch event {
            case .metadata(let value):
                guard metadata == nil else {
                    throw MCPError.parse("MCP event stream repeated response metadata")
                }
                metadata = value
                if value.statusCode == 401 { return .unauthorized }
                guard (200..<300).contains(value.statusCode), value.isEventStream else {
                    return .unsupported
                }
                if let responseSessionID = headerValue("mcp-session-id", in: value.headers),
                   responseSessionID != sessionID {
                    return .unsupported
                }

            case .body(let chunk):
                guard metadata != nil else {
                    throw MCPError.parse("MCP event stream sent body before response metadata")
                }
                let events = try parser.push(chunk)
                if let latestID = parser.lastEventID {
                    lastEventID = latestID
                }
                try publishServerNotifications(
                    events,
                    sessionID: sessionID,
                    generation: generation
                )

            case .end:
                let events = try parser.finish()
                if let latestID = parser.lastEventID {
                    lastEventID = latestID
                }
                try publishServerNotifications(
                    events,
                    sessionID: sessionID,
                    generation: generation
                )
                return .ended
            }
        }

        let events = try parser.finish()
        if let latestID = parser.lastEventID {
            lastEventID = latestID
        }
        try publishServerNotifications(events, sessionID: sessionID, generation: generation)
        return metadata == nil ? .unsupported : .ended
    }

    private func publishServerNotifications(
        _ events: [SSEEvent],
        sessionID: String,
        generation: UInt64
    ) throws {
        for event in events {
            guard isCurrentEventStream(sessionID: sessionID, generation: generation) else {
                return
            }
            guard !event.data.isEmpty else { continue }
            let message = try MCPWireCodec.decodeString(event.data)
            if case .notification(let notification) = message {
                eventEmitter.notification(notification)
            }
        }
    }

    private func isCurrentEventStream(sessionID: String, generation: UInt64) -> Bool {
        !isClosed
            && !Task.isCancelled
            && self.sessionID == sessionID
            && eventStreamGeneration == generation
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        eventStreamGeneration &+= 1
        eventStreamTask?.cancel()
        eventStreamTask = nil
        for operation in activeRequests.values {
            operation.cancel()
        }
        activeRequests.removeAll()
        eventEmitter.transportClosed()

        guard let sessionID else { return }
        do {
            var attachedToken: String?
            var request = try await makeRequest(
                method: .delete,
                sessionID: sessionID,
                attachedToken: &attachedToken
            )
            var response = try await httpTransport.send(request)
            if response.metadata.statusCode == 401,
               let authorization,
               await authorization.handleUnauthorized(staleToken: attachedToken) {
                request = try await makeRequest(
                    method: .delete,
                    sessionID: sessionID,
                    attachedToken: &attachedToken
                )
                response = try await httpTransport.send(request)
            }
            guard (200..<300).contains(response.metadata.statusCode)
                    || response.metadata.statusCode == 404
                    || response.metadata.statusCode == 405
            else { return }
        } catch {
            // Session teardown is best effort; local shutdown must stay final.
        }
    }

    private func headerValue(_ name: String, in headers: [String: String]) -> String? {
        headers.first { key, _ in key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public actor MCPInMemoryTransport: MCPTransport, MCPProgressObservingTransport {
    private let server: MCPServer
    private let eventEmitter = MCPTransportEventEmitter()
    private var isClosed = false

    public init(server: MCPServer) {
        self.server = server
    }

    public func send(_ message: MCPWireMessage) async throws -> MCPWireMessage? {
        guard !isClosed else { throw MCPError.transportClosed }
        return try await server.handle(message)
    }

    /// Inject a server-originated notification through this transport's own
    /// correlation boundary, matching how stdio and SSE deliver notifications.
    public func receiveServerNotification(_ notification: MCPNotification) {
        guard !isClosed else { return }
        eventEmitter.notification(notification)
    }

    func observeProgress(
        token: JsonRpcId,
        onProgress: @escaping @Sendable (MCPProgressParams) async -> Void
    ) -> MCPProgressObservation? {
        eventEmitter.observeProgress(token: token, onProgress: onProgress)
    }

    func finishProgress(_ observation: MCPProgressObservation, cancelPending: Bool) async {
        guard let delivery = eventEmitter.finishProgress(
            observation,
            cancelPending: cancelPending
        ) else { return }
        await delivery.value
    }

    public func close() {
        isClosed = true
        eventEmitter.transportClosed()
    }
}
