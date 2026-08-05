// WebSocketConnection.swift
//
// A WebSocket connection built on an abstract byte channel, plus the upgrade
// drivers for both roles.
//
// The byte channel is the seam that makes this testable: everything from the
// handshake bytes through close negotiation runs identically over a real
// socket and over an in-memory pipe, so the frame-level tests drive the same
// code the server does rather than a parallel implementation.
//
// The framing itself is in `WebSocketProtocol.swift`; this file is lifecycle:
// who answers a ping, when a close is echoed, what happens on EOF.

import Foundation

// MARK: - Byte channel

/// A bidirectional byte stream. `read()` returns `nil` at end of stream.
public protocol WebSocketByteChannel: Sendable {
    func read() async throws -> [UInt8]?
    func write(_ bytes: [UInt8]) async throws
    func close() async
}

public enum WebSocketChannelError: Error, Sendable, Hashable, CustomStringConvertible {
    case closed
    /// The peer disappeared mid-handshake or mid-frame.
    case unexpectedEndOfStream
    case handshakeRejected(status: Int, body: String)
    /// The server answered 101 with an accept token that does not match the key.
    case handshakeAcceptMismatch(expected: String, received: String?)

    public var description: String {
        switch self {
        case .closed:
            return "websocket channel is closed"
        case .unexpectedEndOfStream:
            return "websocket peer closed the connection unexpectedly"
        case .handshakeRejected(let status, let body):
            return "websocket handshake rejected with HTTP \(status): \(body)"
        case .handshakeAcceptMismatch(let expected, let received):
            return "websocket handshake accept mismatch: expected \(expected), received \(received ?? "<absent>")"
        }
    }
}

/// An in-memory bidirectional pipe, for tests and for wiring two in-process
/// halves together.
public final class InMemoryWebSocketChannel: WebSocketByteChannel, Sendable {
    private let inbound: ByteMailbox
    private let outbound: ByteMailbox

    private init(inbound: ByteMailbox, outbound: ByteMailbox) {
        self.inbound = inbound
        self.outbound = outbound
    }

    /// Two ends of one pipe: what `a` writes, `b` reads.
    public static func makePair() -> (a: InMemoryWebSocketChannel, b: InMemoryWebSocketChannel) {
        let toA = ByteMailbox()
        let toB = ByteMailbox()
        return (
            InMemoryWebSocketChannel(inbound: toA, outbound: toB),
            InMemoryWebSocketChannel(inbound: toB, outbound: toA)
        )
    }

    public func read() async throws -> [UInt8]? { await inbound.take() }
    public func write(_ bytes: [UInt8]) async throws {
        guard await outbound.put(bytes) else { throw WebSocketChannelError.closed }
    }
    public func close() async {
        await outbound.finish()
        await inbound.finish()
    }

    /// Deliver `bytes` to this end's reader without going through the peer.
    /// Used by split-across-reads tests to control chunk boundaries exactly.
    public func injectInbound(_ bytes: [UInt8]) async { _ = await inbound.put(bytes) }
}

actor ByteMailbox {
    private var chunks: [[UInt8]] = []
    private var waiter: CheckedContinuation<[UInt8]?, Never>?
    private var finished = false

    func put(_ bytes: [UInt8]) -> Bool {
        guard !finished else { return false }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: bytes)
        } else {
            chunks.append(bytes)
        }
        return true
    }

    func take() async -> [UInt8]? {
        if !chunks.isEmpty { return chunks.removeFirst() }
        if finished { return nil }
        return await withCheckedContinuation { continuation in
            if !chunks.isEmpty {
                continuation.resume(returning: chunks.removeFirst())
            } else if finished {
                continuation.resume(returning: nil)
            } else {
                waiter = continuation
            }
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: nil)
        }
    }
}

// MARK: - Connection

/// One live WebSocket connection.
///
/// Actor-isolated because a connection has exactly one frame decoder and one
/// write side, and interleaving either would corrupt the stream. Ping/pong and
/// close handling happen inside `receive()`, so callers only ever see
/// application messages.
public actor WebSocketConnection {
    public let role: WebSocketRole
    public let maximumMessageSize: Int

    private let channel: any WebSocketByteChannel
    private var decoder: WebSocketFrameDecoder
    private var assembler: WebSocketMessageAssembler
    private var didSendClose = false
    private var didReceiveClose = false
    private var isClosed = false

    /// The close code the peer sent, once it has.
    public private(set) var peerCloseCode: UInt16?
    public private(set) var peerCloseReason: String = ""

    public init(
        channel: any WebSocketByteChannel,
        role: WebSocketRole,
        maximumMessageSize: Int = WebSocketLimits.defaultMaximumMessageSize,
        initialBytes: [UInt8] = []
    ) {
        self.channel = channel
        self.role = role
        self.maximumMessageSize = maximumMessageSize
        self.decoder = WebSocketFrameDecoder(role: role, maximumPayloadSize: maximumMessageSize)
        self.assembler = WebSocketMessageAssembler(maximumMessageSize: maximumMessageSize)
        // A client may pipeline its first frames into the same packet as the
        // handshake; those bytes were already read and must not be dropped.
        if !initialBytes.isEmpty { decoder.append(initialBytes) }
    }

    /// The next application message, or `nil` once the connection has closed.
    ///
    /// Ping is answered with a pong and does not surface. Pong is dropped. A
    /// close frame is echoed once and then ends the stream.
    public func receive() async throws -> WebSocketMessage? {
        while true {
            if isClosed { return nil }
            let frame: WebSocketFrame?
            do {
                frame = try decoder.nextFrame()
            } catch let error as WebSocketProtocolError {
                await failClose(error)
                throw error
            }

            if let frame {
                do {
                    guard let event = try assembler.accept(frame) else { continue }
                    switch event {
                    case .text(let text):
                        return .text(text)
                    case .binary(let bytes):
                        return .data(Data(bytes))
                    case .ping(let payload):
                        try? await sendFrame(
                            WebSocketFrame(
                                opcode: .pong,
                                payload: payload,
                                maskingKey: outboundMaskingKey()
                            )
                        )
                        continue
                    case .pong:
                        continue
                    case .close(let code, let reason):
                        peerCloseCode = code
                        peerCloseReason = reason
                        didReceiveClose = true
                        // §5.5.1: echo the close, then the connection is done.
                        if !didSendClose {
                            try? await sendFrame(
                                WebSocketFrame(
                                    opcode: .close,
                                    payload: WebSocketMessageAssembler.closePayload(
                                        code: code ?? 1000,
                                        reason: ""
                                    ),
                                    maskingKey: outboundMaskingKey()
                                )
                            )
                            didSendClose = true
                        }
                        await teardown()
                        return nil
                    }
                } catch let error as WebSocketProtocolError {
                    await failClose(error)
                    throw error
                }
                continue
            }

            // Need more bytes.
            let chunk: [UInt8]?
            do {
                chunk = try await channel.read()
            } catch {
                await teardown()
                throw error
            }
            guard let chunk else {
                // EOF. A close we already negotiated is clean; anything else is
                // the peer vanishing, and a half-decoded frame is worth saying
                // out loud rather than reporting as a tidy end of stream.
                await teardown()
                if didReceiveClose || didSendClose { return nil }
                if decoder.bufferedByteCount > 0 || assembler.hasPartialMessage {
                    throw WebSocketChannelError.unexpectedEndOfStream
                }
                return nil
            }
            if !chunk.isEmpty { decoder.append(chunk) }
            try Task.checkCancellation()
        }
    }

    public func send(_ message: WebSocketMessage) async throws {
        guard !isClosed, !didSendClose else { throw WebSocketChannelError.closed }
        switch message {
        case .text(let text):
            try await sendFrame(
                WebSocketFrame(
                    opcode: .text,
                    payload: Array(text.utf8),
                    maskingKey: outboundMaskingKey()
                )
            )
        case .data(let data):
            try await sendFrame(
                WebSocketFrame(
                    opcode: .binary,
                    payload: Array(data),
                    maskingKey: outboundMaskingKey()
                )
            )
        }
    }

    /// Send a ping. This is the keepalive upstream sends every 15s
    /// (`crates/codegen/xai-grok-shell/src/agent/server.rs:265-269`, empty
    /// payload).
    public func ping(payload: [UInt8] = []) async throws {
        guard !isClosed, !didSendClose else { throw WebSocketChannelError.closed }
        try await sendFrame(
            WebSocketFrame(opcode: .ping, payload: payload, maskingKey: outboundMaskingKey())
        )
    }

    /// Send a close frame and tear down. Idempotent.
    public func close(code: UInt16 = 1000, reason: String = "") async {
        guard !isClosed else { return }
        if !didSendClose {
            didSendClose = true
            try? await sendFrame(
                WebSocketFrame(
                    opcode: .close,
                    payload: WebSocketMessageAssembler.closePayload(code: code, reason: reason),
                    maskingKey: outboundMaskingKey()
                )
            )
        }
        await teardown()
    }

    /// Emit a frame exactly as given, bypassing message framing *and* the
    /// role's masking rule. Nothing here fills in a masking key, which is what
    /// lets a test send the violations a well-behaved peer never would.
    public func sendRawFrame(_ frame: WebSocketFrame) async throws {
        try await sendFrame(frame)
    }

    private func sendFrame(_ frame: WebSocketFrame) async throws {
        try await channel.write(WebSocketFrameCodec.encode(frame))
    }

    private func outboundMaskingKey() -> [UInt8]? {
        role.masksOutbound ? Self.randomMaskingKey() : nil
    }

    private static func randomMaskingKey() -> [UInt8] {
        [
            UInt8.random(in: 0...255), UInt8.random(in: 0...255),
            UInt8.random(in: 0...255), UInt8.random(in: 0...255),
        ]
    }

    /// Report a protocol violation to the peer with the code RFC 6455 §7.4.1
    /// assigns it, then close. The peer learning *why* it was dropped is the
    /// difference between a debuggable failure and a mystery disconnect.
    private func failClose(_ error: WebSocketProtocolError) async {
        if !didSendClose {
            didSendClose = true
            try? await sendFrame(
                WebSocketFrame(
                    opcode: .close,
                    payload: WebSocketMessageAssembler.closePayload(
                        code: error.closeCode,
                        reason: error.description
                    ),
                    maskingKey: outboundMaskingKey()
                )
            )
        }
        await teardown()
    }

    private func teardown() async {
        guard !isClosed else { return }
        isClosed = true
        await channel.close()
    }
}

// MARK: - Upgrade drivers

/// Everything the server needs to decide whether a handshake becomes a
/// connection.
public struct WebSocketUpgradePolicy: Sendable {
    /// The single route to serve, or `nil` to accept any path. Upstream serves
    /// exactly `/ws` (`crates/codegen/xai-grok-shell/src/agent/server.rs:470`).
    public var path: String?
    public var maximumHeadSize: Int
    /// Returns `true` to let the handshake proceed. Upstream's equivalent is
    /// `validate_auth` (`server.rs:92-106`).
    public var authorize: @Sendable (WebSocketHandshakeRequest) -> Bool

    public init(
        path: String? = "/ws",
        maximumHeadSize: Int = WebSocketLimits.maximumHandshakeHeadSize,
        authorize: @escaping @Sendable (WebSocketHandshakeRequest) -> Bool = { _ in true }
    ) {
        self.path = path
        self.maximumHeadSize = maximumHeadSize
        self.authorize = authorize
    }
}

public enum WebSocketServerUpgrade {
    /// Read the request head, validate it, answer it.
    ///
    /// On failure the HTTP error response is written and the channel closed
    /// before throwing, so the peer gets a status rather than a dropped
    /// connection. The returned leftover bytes are anything the client
    /// pipelined behind the handshake.
    public static func perform(
        channel: any WebSocketByteChannel,
        policy: WebSocketUpgradePolicy = WebSocketUpgradePolicy()
    ) async throws -> (request: WebSocketHandshakeRequest, leftover: [UInt8]) {
        var buffer: [UInt8] = []
        while true {
            let parsed: (request: WebSocketHandshakeRequest, consumed: Int)?
            do {
                parsed = try WebSocketHandshake.parseRequest(buffer, maximumHeadSize: policy.maximumHeadSize)
            } catch let error as WebSocketHandshakeError {
                try? await channel.write(WebSocketHandshake.rejectResponse(error))
                await channel.close()
                throw error
            }

            if let parsed {
                let accept: String
                do {
                    accept = try WebSocketHandshake.validateUpgrade(parsed.request, expectedPath: policy.path)
                    // Authorization comes after the shape checks so a
                    // malformed request reports what is malformed rather than
                    // being masked as an auth failure.
                    guard policy.authorize(parsed.request) else {
                        throw WebSocketHandshakeError.unauthorized
                    }
                } catch let error as WebSocketHandshakeError {
                    try? await channel.write(WebSocketHandshake.rejectResponse(error))
                    await channel.close()
                    throw error
                }
                try await channel.write(WebSocketHandshake.acceptResponse(accept: accept))
                return (parsed.request, Array(buffer[parsed.consumed...]))
            }

            guard let chunk = try await channel.read() else {
                await channel.close()
                throw WebSocketChannelError.unexpectedEndOfStream
            }
            buffer.append(contentsOf: chunk)
        }
    }
}

public enum WebSocketClientUpgrade {
    /// Send a client handshake and verify the response.
    ///
    /// Returns leftover bytes: a server may pack its first frame into the same
    /// packet as the 101, and dropping them would lose a message.
    public static func perform(
        channel: any WebSocketByteChannel,
        host: String,
        target: String,
        headers: [(String, String)] = [],
        key: String = WebSocketHandshake.makeClientKey()
    ) async throws -> [UInt8] {
        try await channel.write(
            WebSocketHandshake.clientRequest(host: host, target: target, key: key, headers: headers)
        )
        var buffer: [UInt8] = []
        while true {
            if let response = try WebSocketHandshake.parseResponse(buffer) {
                guard response.status == 101 else {
                    await channel.close()
                    throw WebSocketChannelError.handshakeRejected(
                        status: response.status,
                        body: response.body
                    )
                }
                let expected = WebSocketHandshake.acceptToken(forKey: key)
                let received = response.headers["sec-websocket-accept"]
                guard received == expected else {
                    await channel.close()
                    throw WebSocketChannelError.handshakeAcceptMismatch(
                        expected: expected,
                        received: received
                    )
                }
                return Array(buffer[response.consumed...])
            }
            guard let chunk = try await channel.read() else {
                await channel.close()
                throw WebSocketChannelError.unexpectedEndOfStream
            }
            buffer.append(contentsOf: chunk)
        }
    }

    /// Handshake and wrap the result in a client-role connection.
    public static func connect(
        channel: any WebSocketByteChannel,
        host: String,
        target: String,
        headers: [(String, String)] = [],
        maximumMessageSize: Int = WebSocketLimits.defaultMaximumMessageSize
    ) async throws -> WebSocketConnection {
        let leftover = try await perform(
            channel: channel,
            host: host,
            target: target,
            headers: headers
        )
        return WebSocketConnection(
            channel: channel,
            role: .client,
            maximumMessageSize: maximumMessageSize,
            initialBytes: leftover
        )
    }
}
