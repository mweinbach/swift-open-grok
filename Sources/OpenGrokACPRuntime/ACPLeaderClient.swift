import Foundation
import OpenGrokACP
import OpenGrokHTTP
import OpenGrokShared

public struct ACPLeaderClientRegistration: Sendable, Hashable {
    public let clientID: UInt64
    public let ready: Bool
    public let protocolVersion: UInt32?
    public let binaryVersion: String?
    public let capabilities: ACPLeaderCapabilities?

    public init(
        clientID: UInt64,
        ready: Bool,
        protocolVersion: UInt32?,
        binaryVersion: String?,
        capabilities: ACPLeaderCapabilities?
    ) {
        self.clientID = clientID
        self.ready = ready
        self.protocolVersion = protocolVersion
        self.binaryVersion = binaryVersion
        self.capabilities = capabilities
    }
}

public enum ACPLeaderClientError: Error, Sendable, Hashable, CustomStringConvertible {
    case notStarted
    case alreadyStarted
    case registrationClosed
    case registrationTimeout(seconds: Double)
    case readinessTimeout(seconds: Double)
    case unexpectedRegistrationReply(String)
    case leaderError(code: Int, message: String)
    case controlError(requestID: String, code: Int, message: String)
    case remoteACP(AcpError)
    case disconnected

    public var description: String {
        switch self {
        case .notStarted:
            return "leader client is not registered"
        case .alreadyStarted:
            return "leader client is already registered"
        case .registrationClosed:
            return "leader closed the connection during registration"
        case .registrationTimeout(let seconds):
            return "leader did not acknowledge registration within \(seconds) seconds"
        case .readinessTimeout(let seconds):
            return "leader did not become ready within \(seconds) seconds"
        case .unexpectedRegistrationReply(let reply):
            return "unexpected leader registration reply: \(reply)"
        case .leaderError(let code, let message):
            return "leader error \(code): \(message)"
        case .controlError(let requestID, let code, let message):
            return "leader control request \(requestID) failed (\(code)): \(message)"
        case .remoteACP(let error):
            return "leader ACP request failed: \(error)"
        case .disconnected:
            return "leader client disconnected"
        }
    }
}

/// Production client for the leader's length-prefixed IPC socket.
///
/// Registration, ACP request/response demultiplexing, control replies, and
/// notifications all share one decoder and one reader task. A second read loop
/// would race the frame decoder and can silently assign another client's
/// response to the wrong continuation.
public actor ACPLeaderClient {
    public let clientType: String
    public let mode: ACPLeaderClientMode
    public let capabilities: ACPLeaderClientCapabilities

    private let channel: any WebSocketByteChannel
    private let reader: ACPLeaderChannelReader
    private let writer: ACPLeaderClientWriter
    private let registrationTimeoutSeconds: TimeInterval
    private let readinessTimeoutSeconds: TimeInterval
    private var readerTask: Task<Void, Never>?
    private var nextRequestID: Int64 = 1
    private var pendingACP: [AcpRequestId: CheckedContinuation<JSONValue, Error>] = [:]
    private var pendingControl: [String: CheckedContinuation<ACPLeaderControlPayload, Error>] = [:]
    private var closed = false
    private var started = false
    private var starting = false
    private var registrationValue: ACPLeaderClientRegistration?
    private let eventStream: AsyncThrowingStream<ACPMessage, Error>
    private var eventContinuation: AsyncThrowingStream<ACPMessage, Error>.Continuation?
    private var rosterContinuations: [
        UUID: AsyncThrowingStream<ACPLeaderRosterChanged, Error>.Continuation
    ] = [:]

    public init(
        channel: any WebSocketByteChannel,
        clientType: String = "grok-tui",
        mode: ACPLeaderClientMode = .stdio,
        capabilities: ACPLeaderClientCapabilities = ACPLeaderClientCapabilities(),
        readinessTimeoutSeconds: TimeInterval = 120,
        registrationTimeoutSeconds: TimeInterval = 10
    ) {
        self.channel = channel
        self.clientType = clientType
        self.mode = mode
        self.capabilities = capabilities
        self.registrationTimeoutSeconds = registrationTimeoutSeconds.isFinite
            ? min(max(0, registrationTimeoutSeconds), 10)
            : 10
        self.readinessTimeoutSeconds = readinessTimeoutSeconds.isFinite
            ? min(max(0, readinessTimeoutSeconds), 120)
            : 120
        self.reader = ACPLeaderChannelReader(
            channel: channel,
            maximumMessageSize: ACPLeaderProtocolLimits.maximumMessageSize
        )
        self.writer = ACPLeaderClientWriter(channel: channel)
        var continuation: AsyncThrowingStream<ACPMessage, Error>.Continuation?
        self.eventStream = AsyncThrowingStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    public var registration: ACPLeaderClientRegistration? { registrationValue }

    public func start() async throws -> ACPLeaderClientRegistration {
        guard !closed else { throw ACPLeaderClientError.disconnected }
        guard !started, !starting else { throw ACPLeaderClientError.alreadyStarted }
        starting = true
        defer { starting = false }

        do {
            try Task.checkCancellation()
            try await writer.send(
                .register(
                    clientType: clientType,
                    mode: mode,
                    capabilities: capabilities
                )
            )
            // Rust leader/client.rs:28,357-369 separately bounds the initial
            // registration reply before its longer leader-readiness deadline.
            let message = try await startupMessage(
                timeoutSeconds: registrationTimeoutSeconds,
                timeoutError: .registrationTimeout(seconds: registrationTimeoutSeconds)
            )
            if case .error(let code, let message) = message {
                throw ACPLeaderClientError.leaderError(code: code, message: message)
            }
            guard case .registered(
                let clientID,
                let ready,
                let protocolVersion,
                let binaryVersion,
                let leaderCapabilities
            ) = message else {
                throw ACPLeaderClientError.unexpectedRegistrationReply(String(describing: message))
            }

            // Rust leader/client.rs:394-428 consumes LeaderReady before its
            // shared reader starts; otherwise the first ACP request races boot.
            if !ready {
                let readiness = try await startupMessage(
                    timeoutSeconds: readinessTimeoutSeconds,
                    timeoutError: .readinessTimeout(seconds: readinessTimeoutSeconds)
                )
                switch readiness {
                case .leaderReady:
                    break
                case .shutdown, .shuttingDown:
                    throw ACPLeaderClientError.registrationClosed
                case .error(let code, let message):
                    throw ACPLeaderClientError.leaderError(code: code, message: message)
                default:
                    throw ACPLeaderClientError.unexpectedRegistrationReply(
                        String(describing: readiness)
                    )
                }
            }

            guard !closed else { throw ACPLeaderClientError.disconnected }
            let value = ACPLeaderClientRegistration(
                clientID: clientID,
                ready: true,
                protocolVersion: protocolVersion,
                binaryVersion: binaryVersion,
                capabilities: leaderCapabilities
            )
            registrationValue = value
            started = true
            readerTask = Task { [weak self] in
                await self?.readLoop()
            }
            return value
        } catch {
            await close()
            throw error
        }
    }

    /// Byte-channel reads do not observe task cancellation. A detached race
    /// can return on its deadline; `start()` then closes the channel to release
    /// the losing read instead of hanging while a task group joins it.
    private func startupMessage(
        timeoutSeconds seconds: TimeInterval,
        timeoutError: ACPLeaderClientError
    ) async throws -> ACPLeaderServerMessage {
        let reader = reader
        let nanoseconds = UInt64(seconds * 1_000_000_000)
        let gate = AsyncOutcomeGate<ACPLeaderServerMessage>()
        let work = Task.detached {
            do {
                guard let message = try await reader.next(ACPLeaderServerMessage.self) else {
                    throw ACPLeaderClientError.registrationClosed
                }
                gate.finish(.success(message))
            } catch {
                gate.finish(.failure(error))
            }
        }
        let timer = Task.detached {
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            gate.finish(.failure(timeoutError))
        }
        defer {
            work.cancel()
            timer.cancel()
        }
        return try await withTaskCancellationHandler {
            try await gate.value()
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }

    /// Incoming requests, notifications, and replies to raw forwarded calls.
    /// Responses matching a `request` continuation are consumed there and
    /// are not repeated in this stream.
    public func events() throws -> AsyncThrowingStream<ACPMessage, Error> {
        guard started, !closed else { throw ACPLeaderClientError.notStarted }
        return eventStream
    }

    public func rosterSnapshot() async throws -> ACPLeaderRosterListResponse {
        let response = try await request(method: ACPLeaderRosterMethods.sessionsList)
        return try response.decode(ACPLeaderRosterListResponse.self)
    }

    public func rosterEvents() throws -> AsyncThrowingStream<ACPLeaderRosterChanged, Error> {
        guard started, !closed else { throw ACPLeaderClientError.notStarted }
        let id = UUID()
        let (stream, continuation) = AsyncThrowingStream<ACPLeaderRosterChanged, Error>.makeStream()
        rosterContinuations[id] = continuation
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeRosterContinuation(id) }
        }
        return stream
    }

    public func request(method: String, params: JSONValue = .object([:])) async throws -> JSONValue {
        guard started, !closed else { throw ACPLeaderClientError.notStarted }
        let id = AcpRequestId.number(nextRequestID)
        nextRequestID += 1
        let message = ACPMessage.request(id: id, method: method, params: params)
        let response = try await withCheckedThrowingContinuation { continuation in
            pendingACP[id] = continuation
            Task { [weak self] in
                do {
                    try await self?.writer.send(.acp(payload: Self.encode(message)))
                } catch {
                    await self?.failACP(id, error: error)
                }
            }
        }
        return response
    }

    public func notify(method: String, params: JSONValue = .object([:])) async throws {
        guard started, !closed else { throw ACPLeaderClientError.notStarted }
        let message = ACPMessage.notification(method: method, params: params)
        try await writer.send(.acp(payload: Self.encode(message)))
    }

    /// The relay preserves peer-assigned IDs, including reverse responses.
    /// Unmatched replies remain in `events`; the host still applies its own
    /// request namespace and reverse-response ownership checks.
    func forward(_ message: ACPMessage) async throws {
        guard started, !closed else { throw ACPLeaderClientError.notStarted }
        try Task.checkCancellation()
        let payload = String(decoding: try message.encodedData(), as: UTF8.self)
        try await writer.send(.acp(payload: payload))
    }

    public func control(_ command: [String: String]) async throws -> ACPLeaderControlPayload {
        guard started, !closed else { throw ACPLeaderClientError.notStarted }
        let requestID = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            pendingControl[requestID] = continuation
            Task { [weak self] in
                do {
                    try await self?.writer.send(.control(requestID: requestID, command: command))
                } catch {
                    await self?.failControl(requestID, error: error)
                }
            }
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        readerTask?.cancel()
        readerTask = nil
        let error = ACPLeaderClientError.disconnected
        for continuation in pendingACP.values {
            continuation.resume(throwing: error)
        }
        pendingACP.removeAll()
        for continuation in pendingControl.values {
            continuation.resume(throwing: error)
        }
        pendingControl.removeAll()
        eventContinuation?.finish(throwing: error)
        eventContinuation = nil
        finishRosterContinuations(throwing: error)
        await writer.close()
        await channel.close()
    }

    private func readLoop() async {
        do {
            while !closed {
                guard let message = try await reader.next(ACPLeaderServerMessage.self) else {
                    throw ACPLeaderClientError.disconnected
                }
                await handle(message)
            }
        } catch {
            await failAll(error)
        }
    }

    private func handle(_ message: ACPLeaderServerMessage) async {
        switch message {
        case .registered:
            break
        case .acp(let payload):
            guard let data = payload.data(using: .utf8) else { return }
            do {
                let message = try ACPMessage(data: data)
                if case .response(let id, let result, let error) = message,
                   let continuation = pendingACP.removeValue(forKey: id)
                {
                    if let error {
                        continuation.resume(throwing: ACPLeaderClientError.remoteACP(error))
                    } else {
                        continuation.resume(returning: result ?? .object([:]))
                    }
                } else {
                    publishRosterEvent(from: message)
                    eventContinuation?.yield(message)
                }
            } catch {
                await failAll(error)
            }
        case .controlResult(let requestID, let payload):
            pendingControl.removeValue(forKey: requestID)?.resume(returning: payload)
        case .controlError(let requestID, let code, let message):
            pendingControl.removeValue(forKey: requestID)?.resume(
                throwing: ACPLeaderClientError.controlError(
                    requestID: requestID,
                    code: code,
                    message: message
                )
            )
        case .error(let code, let message):
            await failAll(ACPLeaderClientError.leaderError(code: code, message: message))
        case .shutdown:
            await close()
        case .pong, .leaderReady, .shuttingDown:
            break
        }
    }

    private func failACP(_ id: AcpRequestId, error: Error) {
        pendingACP.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failControl(_ requestID: String, error: Error) {
        pendingControl.removeValue(forKey: requestID)?.resume(throwing: error)
    }

    private func failAll(_ error: Error) async {
        guard !closed else { return }
        closed = true
        for continuation in pendingACP.values {
            continuation.resume(throwing: error)
        }
        pendingACP.removeAll()
        for continuation in pendingControl.values {
            continuation.resume(throwing: error)
        }
        pendingControl.removeAll()
        eventContinuation?.finish(throwing: error)
        eventContinuation = nil
        finishRosterContinuations(throwing: error)
        await writer.close()
        await channel.close()
    }

    private func publishRosterEvent(from message: ACPMessage) {
        guard case .notification(let method, let params) = message,
              ACPMethodRoute.normalize(method: method, params: params).method
                == ACPLeaderRosterMethods.sessionsChanged,
              let changed = try? params.decode(ACPLeaderRosterChanged.self)
        else { return }
        for continuation in rosterContinuations.values {
            continuation.yield(changed)
        }
    }

    private func removeRosterContinuation(_ id: UUID) {
        rosterContinuations.removeValue(forKey: id)
    }

    private func finishRosterContinuations(throwing error: Error) {
        let continuations = rosterContinuations.values
        rosterContinuations.removeAll()
        for continuation in continuations {
            continuation.finish(throwing: error)
        }
    }

    private static func encode(_ message: ACPMessage) -> String {
        guard let data = try? message.encodedData() else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

private actor ACPLeaderClientWriter {
    private let frames: ACPLeaderFrameWriter
    private var closed = false

    init(channel: any WebSocketByteChannel) {
        self.frames = ACPLeaderFrameWriter(channel: channel)
    }

    func send(_ message: ACPLeaderClientMessage) async throws {
        guard !closed else { throw ACPLeaderClientError.disconnected }
        try await frames.write(try ACPLeaderCodec.encode(message))
    }

    func close() async {
        guard !closed else { return }
        closed = true
        await frames.close()
    }
}
