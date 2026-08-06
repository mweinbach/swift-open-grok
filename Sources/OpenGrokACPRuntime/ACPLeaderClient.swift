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
    private var readerTask: Task<Void, Never>?
    private var nextRequestID: Int64 = 1
    private var pendingACP: [AcpRequestId: CheckedContinuation<JSONValue, Error>] = [:]
    private var pendingControl: [String: CheckedContinuation<ACPLeaderControlPayload, Error>] = [:]
    private var closed = false
    private var started = false
    private var registrationValue: ACPLeaderClientRegistration?
    private let eventStream: AsyncThrowingStream<ACPMessage, Error>
    private var eventContinuation: AsyncThrowingStream<ACPMessage, Error>.Continuation?

    public init(
        channel: any WebSocketByteChannel,
        clientType: String = "grok-tui",
        mode: ACPLeaderClientMode = .stdio,
        capabilities: ACPLeaderClientCapabilities = ACPLeaderClientCapabilities()
    ) {
        self.channel = channel
        self.clientType = clientType
        self.mode = mode
        self.capabilities = capabilities
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
        guard !started else { throw ACPLeaderClientError.alreadyStarted }

        try await writer.send(
            .register(
                clientType: clientType,
                mode: mode,
                capabilities: capabilities
            )
        )
        guard let message = try await reader.next(ACPLeaderServerMessage.self) else {
            await close()
            throw ACPLeaderClientError.registrationClosed
        }
        guard case .registered(
            let clientID,
            let ready,
            let protocolVersion,
            let binaryVersion,
            let leaderCapabilities
        ) = message else {
            await close()
            throw ACPLeaderClientError.unexpectedRegistrationReply(String(describing: message))
        }

        let value = ACPLeaderClientRegistration(
            clientID: clientID,
            ready: ready,
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
    }

    /// Incoming ACP requests and notifications. Responses are consumed by the
    /// matching `request` continuation and are not repeated in this stream.
    public func events() throws -> AsyncThrowingStream<ACPMessage, Error> {
        guard started, !closed else { throw ACPLeaderClientError.notStarted }
        return eventStream
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
        case .pong, .leaderReady, .shuttingDown, .shutdown:
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
        await writer.close()
        await channel.close()
    }

    private static func encode(_ message: ACPMessage) -> String {
        guard let data = try? message.encodedData() else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

private actor ACPLeaderClientWriter {
    private let channel: any WebSocketByteChannel
    private var closed = false

    init(channel: any WebSocketByteChannel) {
        self.channel = channel
    }

    func send(_ message: ACPLeaderClientMessage) async throws {
        guard !closed else { throw ACPLeaderClientError.disconnected }
        try await channel.write(try ACPLeaderCodec.encode(message))
    }

    func close() async {
        guard !closed else { return }
        closed = true
        await channel.close()
    }
}
