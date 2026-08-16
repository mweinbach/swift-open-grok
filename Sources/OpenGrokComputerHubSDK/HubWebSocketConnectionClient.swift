// HubWebSocketConnectionClient.swift
//
// Production Computer Hub transport. The ACP leader owns the composition;
// this target owns the wire protocol so library users and tests share the
// same upgrade, hello, demux, and reconnect path.

import Foundation
import OpenGrokComputerHubCore
import OpenGrokHTTP
import OpenGrokShared
import OpenGrokToolProtocol

public struct HubWebSocketConfiguration: Sendable {
    public var url: WebSocketURL
    public var auth: any AuthProvider
    public var serverId: ServerId?
    public var description: String?
    public var metadata: JSONValue?
    public var connectTimeoutSeconds: Double
    public var maximumMessageSize: Int
    public var reconnectAttempts: Int
    public var reconnectDelayNanoseconds: UInt64

    public init(
        url: WebSocketURL,
        auth: any AuthProvider,
        serverId: ServerId? = nil,
        description: String? = nil,
        metadata: JSONValue? = nil,
        connectTimeoutSeconds: Double = 30,
        maximumMessageSize: Int = WebSocketLimits.defaultMaximumMessageSize,
        reconnectAttempts: Int = 3,
        reconnectDelayNanoseconds: UInt64 = 250_000_000
    ) {
        self.url = url
        self.auth = auth
        self.serverId = serverId
        self.description = description
        self.metadata = metadata
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.maximumMessageSize = maximumMessageSize
        self.reconnectAttempts = max(0, reconnectAttempts)
        self.reconnectDelayNanoseconds = reconnectDelayNanoseconds
    }

    public init(
        url: String,
        auth: any AuthProvider,
        serverId: ServerId? = nil,
        description: String? = nil,
        metadata: JSONValue? = nil,
        connectTimeoutSeconds: Double = 30,
        maximumMessageSize: Int = WebSocketLimits.defaultMaximumMessageSize,
        reconnectAttempts: Int = 3,
        reconnectDelayNanoseconds: UInt64 = 250_000_000
    ) throws {
        try self.init(
            url: WebSocketURL.parse(url),
            auth: auth,
            serverId: serverId,
            description: description,
            metadata: metadata,
            connectTimeoutSeconds: connectTimeoutSeconds,
            maximumMessageSize: maximumMessageSize,
            reconnectAttempts: reconnectAttempts,
            reconnectDelayNanoseconds: reconnectDelayNanoseconds
        )
    }
}

public final class HubActivityTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var accepting = true

    @discardableResult
    public func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return false }
        active += 1
        return true
    }

    public func end() {
        lock.lock()
        active = max(0, active - 1)
        lock.unlock()
    }

    public func stopAccepting() {
        lock.lock(); accepting = false; lock.unlock()
    }

    public func resume() {
        lock.lock(); accepting = true; lock.unlock()
    }

    public func snapshot() -> Int {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    public func waitUntilDrained(timeoutNanoseconds: UInt64) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while snapshot() > 0 && DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// A single-reader, serialized-writer JSON-RPC client for Computer Hub.
public final class HubWebSocketConnectionClient: ConnectionClient, @unchecked Sendable {
    public let hub: HubConnection
    public let configuration: HubWebSocketConfiguration
    public let activityTracker: HubActivityTracker

    private let lock = NSLock()
    private var socket: (any WebSocketClient)?
    private var readerTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var closed = false
    private var progressContinuations: [ToolCallId: AsyncStream<ToolCallProgressFrame>.Continuation] = [:]
    private var requestCalls: [String: ToolCallId] = [:]
    private let writeGate = WebSocketWriteGate()

    private func withState<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public static func connect(
        configuration: HubWebSocketConfiguration
    ) async throws -> HubWebSocketConnectionClient {
        try validate(configuration.url)
        let identity = try await configuration.auth.identity()
        let hub = HubConnection(
            key: PrincipalKey(url: configuration.url.absoluteString, userId: identity.userId),
            connected: false
        )
        let client = HubWebSocketConnectionClient(configuration: configuration, hub: hub)
        try await client.connectInitial()
        return client
    }

    public init(configuration: HubWebSocketConfiguration) {
        self.configuration = configuration
        self.activityTracker = HubActivityTracker()
        self.hub = HubConnection(
            key: PrincipalKey(url: configuration.url.absoluteString, userId: try! UserId("pending")),
            connected: false
        )
    }

    init(
        configuration: HubWebSocketConfiguration,
        hub: HubConnection,
        socket: (any WebSocketClient)? = nil
    ) {
        self.configuration = configuration
        self.activityTracker = HubActivityTracker()
        self.hub = hub
        self.socket = socket
    }

    #if DEBUG
    static func connectForTesting(
        configuration: HubWebSocketConfiguration,
        socket: any WebSocketClient
    ) async throws -> HubWebSocketConnectionClient {
        let identity = try await configuration.auth.identity()
        let hub = HubConnection(
            key: PrincipalKey(url: configuration.url.absoluteString, userId: identity.userId),
            connected: false
        )
        let client = HubWebSocketConnectionClient(
            configuration: configuration,
            hub: hub,
            socket: socket
        )
        try await client.startTesting(socket: socket)
        return client
    }

    private func startTesting(socket: any WebSocketClient) async throws {
        let identity = try await configuration.auth.identity()
        let ack = try await handshake(on: socket)
        guard ack.supportedProtocolVersions.contains(toolProtocolVersion) else {
            throw ClientError.handshakeFailed("unsupported protocol")
        }
        guard ack.userId == identity.userId else {
            throw ClientError.unauthorized("hub identity mismatch")
        }
        hub.activate(client: self, emitReconnected: false)
        startReader(socket)
    }
    #endif

    deinit {
        readerTask?.cancel()
        reconnectTask?.cancel()
    }

    public func request(
        _ request: JsonRpcRequest<JSONValue>
    ) async throws -> JsonRpcResponse<JSONValue> {
        try Task.checkCancellation()
        guard activityTracker.begin() else { throw ClientError.notConnected }
        defer { activityTracker.end() }
        guard isOpen else { throw ClientError.notConnected }

        let requestId = request.id.description
        let callId = try? request.params.decode(ToolCallParams.self).toolCallId
        let demux = hub.demux

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let callId { requestCalls[requestId] = callId }
                lock.unlock()
                demux.registerResponseWaiter(
                    requestId: requestId,
                    sessionId: request.sessionId
                ) { [weak self] result in
                    if let self, let callId { self.finishProgress(callId) }
                    continuation.resume(with: result)
                }

                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.send(.request(request))
                    } catch {
                        if let waiter = demux.takeResponseWaiter(requestId: requestId) {
                            waiter(.failure(Self.clientError(error)))
                        }
                    }
                }
            }
        }, onCancel: {
            if let waiter = demux.takeResponseWaiter(requestId: requestId) {
                waiter(.failure(.cancelled))
            }
        })
    }

    public func notify(_ notification: JsonRpcNotification<JSONValue>) async throws {
        guard isOpen else { throw ClientError.notConnected }
        try await send(.notification(notification))
    }

    public func subscribeProgress(
        toolCallId: ToolCallId
    ) async -> AsyncStream<ToolCallProgressFrame> {
        AsyncStream { continuation in
            lock.lock()
            progressContinuations[toolCallId] = continuation
            lock.unlock()
            hub.demux.registerProgressWaiter(toolCallId: toolCallId) { frame in
                continuation.yield(frame)
                return true
            }
            continuation.onTermination = { [weak self] _ in
                self?.removeProgress(toolCallId)
            }
        }
    }

    public func reconnect() async throws {
        try Task.checkCancellation()
        markClosedForReconnect()
        try await establishConnection(emitConnected: true)
        activityTracker.resume()
    }

    public func close() async {
        let resources: ((any WebSocketClient)?, Task<Void, Never>?, Task<Void, Never>?)? = withState {
            guard !closed else { return nil }
            closed = true
            let resources = (socket, readerTask, reconnectTask)
            socket = nil
            readerTask = nil
            reconnectTask = nil
            return resources
        }
        guard let (current, reader, reconnect) = resources else { return }
        activityTracker.stopAccepting()
        reader?.cancel()
        reconnect?.cancel()
        await current?.close()
        hub.markDisconnected(reason: "closed")
        finishAllProgress()
    }

    public func disconnect() async {
        let resources: ((any WebSocketClient)?, Task<Void, Never>?, Task<Void, Never>?)? = withState {
            guard !closed else { return nil }
            let resources = (socket, readerTask, reconnectTask)
            socket = nil
            readerTask = nil
            reconnectTask = nil
            return resources
        }
        guard let (current, reader, reconnect) = resources else { return }
        activityTracker.stopAccepting()
        reader?.cancel()
        reconnect?.cancel()
        await current?.close()
        hub.markDisconnected(reason: "disconnected")
        finishAllProgress()
    }

    var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return !closed && socket != nil && hub.isConnected
    }

    private func connectInitial() async throws {
        try await establishConnection(emitConnected: false)
    }

    private static func validate(_ url: WebSocketURL) throws {
        guard url.isSecure || isLoopbackHost(url.host) else {
            throw ClientError.insecureScheme(url: url.absoluteString)
        }
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "localhost" || normalized == "localhost." || normalized == "::1" {
            return true
        }
        let components = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4, components[0] == "127" else { return false }
        return components.dropFirst().allSatisfy { component in
            guard let octet = UInt16(component) else { return false }
            return octet <= 255
        }
    }

    private func establishConnection(emitConnected: Bool) async throws {
        let identity = try await configuration.auth.identity()
        let credential = try await configuration.auth.credential()
        let headers = Self.headers(for: credential)
        let nextSocket: any WebSocketClient
        do {
            nextSocket = try await WebSocketDialer.connect(
                to: configuration.url,
                options: WebSocketDialOptions(
                    headers: headers,
                    connectTimeoutSeconds: configuration.connectTimeoutSeconds,
                    maximumMessageSize: configuration.maximumMessageSize
                )
            )
        } catch {
            throw ClientError.networkError("dial failed: \(error)")
        }
        let ack: HelloAckMsg
        do {
            ack = try await handshake(on: nextSocket)
        } catch {
            await nextSocket.close()
            throw Self.clientError(error)
        }
        guard ack.supportedProtocolVersions.contains(toolProtocolVersion) else {
            await nextSocket.close()
            throw ClientError.handshakeFailed(
                "server does not support \(toolProtocolVersion); supported: \(ack.supportedProtocolVersions)"
            )
        }
        guard ack.userId == identity.userId else {
            await nextSocket.close()
            throw ClientError.unauthorized(
                "hub identity \(ack.userId.rawValue) does not match credential identity \(identity.userId.rawValue)"
            )
        }

        let wasClosed = withState {
            let wasClosed = closed
            socket = nextSocket
            return wasClosed
        }
        if wasClosed {
            await nextSocket.close()
            throw ClientError.cancelled
        }

        if hub.key.userId != ack.userId {
            await nextSocket.close()
            throw ClientError.unauthorized("hub user changed during reconnect")
        }

        hub.activate(client: self, emitReconnected: emitConnected)
        startReader(nextSocket)
    }

    private func handshake(on socket: any WebSocketClient) async throws -> HelloAckMsg {
        let hello = HelloMsg(
            kind: .toolServer,
            serverId: configuration.serverId,
            description: configuration.description,
            metadata: configuration.metadata
        )
        let data = try WireJSONEncoder.make().encode(hello)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ClientError.handshakeFailed("hello encoding was not UTF-8")
        }
        try await socket.send(.text(text))
        guard let message = try await socket.receive() else {
            throw ClientError.networkError("hub closed before hello_ack")
        }
        guard case .text(let ackText) = message else {
            throw ClientError.handshakeFailed("hub sent a binary hello_ack")
        }
        guard let ackData = ackText.data(using: .utf8) else {
            throw ClientError.handshakeFailed("hello_ack was not UTF-8")
        }
        return try WireJSONDecoder.make().decode(HelloAckMsg.self, from: ackData)
    }

    private func startReader(_ socket: any WebSocketClient) {
        readerTask?.cancel()
        readerTask = Task { [weak self] in
            guard let self else { return }
            await self.readLoop(socket)
        }
    }

    private func readLoop(_ socket: any WebSocketClient) async {
        do {
            while !Task.isCancelled {
                guard let message = try await socket.receive() else {
                    throw ClientError.networkError("hub closed the WebSocket")
                }
                guard case .text(let text) = message,
                      let data = text.data(using: .utf8)
                else {
                    throw ClientError.transport("hub sent a binary JSON-RPC frame")
                }
                let frame = try WireJSONDecoder.make().decode(JSONValue.self, from: data)
                hub.demux.route(frame)
            }
        } catch is CancellationError {
            return
        } catch {
            await handleDisconnect(Self.clientError(error), socket: socket)
        }
    }

    private func handleDisconnect(_ error: ClientError, socket: any WebSocketClient) async {
        let shouldHandle = withState {
            guard self.socket === socket, !closed else { return false }
            self.socket = nil
            return true
        }
        guard shouldHandle else { return }
        await socket.close()
        hub.markDisconnected(reason: error.description)
        finishAllProgress()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        lock.lock()
        guard reconnectTask == nil, !closed, configuration.reconnectAttempts > 0 else {
            lock.unlock()
            return
        }
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            await self.reconnectLoop()
        }
        lock.unlock()
    }

    private func reconnectLoop() async {
        defer {
            withState { reconnectTask = nil }
        }
        for attempt in 1...configuration.reconnectAttempts {
            if Task.isCancelled { return }
            hub.markReconnecting(attempt: attempt)
            if configuration.reconnectDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: configuration.reconnectDelayNanoseconds)
            }
            do {
                try await establishConnection(emitConnected: true)
                return
            } catch {
                if attempt == configuration.reconnectAttempts {
                    hub.markGiveUp(reason: Self.clientError(error).description)
                }
            }
        }
    }

    private func markClosedForReconnect() {
        lock.lock()
        let current = socket
        socket = nil
        lock.unlock()
        Task { await current?.close() }
        hub.markDisconnected(reason: "reconnect requested")
        finishAllProgress()
    }

    private enum Outbound {
        case request(JsonRpcRequest<JSONValue>)
        case notification(JsonRpcNotification<JSONValue>)
    }

    private func send(_ outbound: Outbound) async throws {
        let current = withState { socket }
        guard let current else { throw ClientError.notConnected }
        let value: JSONValue
        switch outbound {
        case .request(let request): value = try JSONValue.encode(request)
        case .notification(let notification): value = try JSONValue.encode(notification)
        }
        let data = try WireJSONEncoder.make().encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ClientError.transport("wire frame was not UTF-8")
        }
        try await writeGate.send(.text(text), on: current)
    }

    private func finishProgress(_ toolCallId: ToolCallId) {
        lock.lock()
        let continuation = progressContinuations.removeValue(forKey: toolCallId)
        requestCalls = requestCalls.filter { $0.value != toolCallId }
        lock.unlock()
        hub.demux.unregisterProgressWaiter(toolCallId: toolCallId)
        continuation?.finish()
    }

    private func removeProgress(_ toolCallId: ToolCallId) {
        lock.lock()
        progressContinuations.removeValue(forKey: toolCallId)
        requestCalls = requestCalls.filter { $0.value != toolCallId }
        lock.unlock()
        hub.demux.unregisterProgressWaiter(toolCallId: toolCallId)
    }

    private func finishAllProgress() {
        lock.lock()
        let continuations = Array(progressContinuations.values)
        let ids = Array(progressContinuations.keys)
        progressContinuations.removeAll()
        requestCalls.removeAll()
        lock.unlock()
        for id in ids { hub.demux.unregisterProgressWaiter(toolCallId: id) }
        continuations.forEach { $0.finish() }
    }

    private static func headers(for credential: AuthCredential) -> [(String, String)] {
        switch credential {
        case .bearer(let token): return [("Authorization", "Bearer \(token)")]
        case .apiKey(let key): return [("X-API-Key", key)]
        case .none: return []
        }
    }

    private static func clientError(_ error: Error) -> ClientError {
        if let error = error as? ClientError { return error }
        return .transport(String(describing: error))
    }
}

private actor WebSocketWriteGate {
    func send(_ message: WebSocketMessage, on socket: any WebSocketClient) async throws {
        try await socket.send(message)
    }
}
