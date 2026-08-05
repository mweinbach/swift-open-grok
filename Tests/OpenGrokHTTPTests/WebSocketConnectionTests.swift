// WebSocketConnectionTests.swift
//
// Connection lifecycle over an in-memory byte pipe: upgrade, message
// round-trips, ping/pong, close negotiation, and how protocol violations
// surface to both peers.
//
// These run the same `WebSocketConnection` the socket server runs; only the
// byte channel differs. That is deliberate — a separate in-test protocol
// implementation would prove nothing about the shipping one.

import Foundation
import Testing
@testable import OpenGrokHTTP

/// Server and client halves wired to one in-memory pipe, already upgraded.
private struct ConnectedPair {
    let server: WebSocketConnection
    let client: WebSocketConnection
    let request: WebSocketHandshakeRequest
}

private func makeConnectedPair(
    policy: WebSocketUpgradePolicy = WebSocketUpgradePolicy(),
    target: String = "/ws",
    headers: [(String, String)] = [],
    maximumMessageSize: Int = WebSocketLimits.defaultMaximumMessageSize
) async throws -> ConnectedPair {
    let (serverSide, clientSide) = InMemoryWebSocketChannel.makePair()
    async let upgrade = WebSocketServerUpgrade.perform(channel: serverSide, policy: policy)
    async let connect = WebSocketClientUpgrade.connect(
        channel: clientSide,
        host: "127.0.0.1",
        target: target,
        headers: headers,
        maximumMessageSize: maximumMessageSize
    )
    let accepted = try await upgrade
    let client = try await connect
    let server = WebSocketConnection(
        channel: serverSide,
        role: .server,
        maximumMessageSize: maximumMessageSize,
        initialBytes: accepted.leftover
    )
    return ConnectedPair(server: server, client: client, request: accepted.request)
}

@Suite("WebSocket upgrade over a channel")
struct WebSocketUpgradeTests {
    @Test func completesAHandshakeAndExposesTheRequest() async throws {
        let pair = try await makeConnectedPair(
            target: "/ws?server-key=letmein",
            headers: [("Authorization", "Bearer letmein")]
        )
        #expect(pair.request.path == "/ws")
        #expect(pair.request.queryItems["server-key"] == "letmein")
        #expect(pair.request.bearerToken == "letmein")
        await pair.client.close()
        await pair.server.close()
    }

    @Test func rejectsAnUnauthorizedClientWith401() async throws {
        let policy = WebSocketUpgradePolicy(path: "/ws") { $0.bearerToken == "right" }
        let (serverSide, clientSide) = InMemoryWebSocketChannel.makePair()
        async let serverOutcome: Error? = {
            do {
                _ = try await WebSocketServerUpgrade.perform(channel: serverSide, policy: policy)
                return nil
            } catch {
                return error
            }
        }()
        // The client must see an HTTP status, not a dropped connection: that
        // is the difference between "your token is wrong" and "the server is
        // down" for whoever is debugging.
        await #expect(throws: WebSocketChannelError.self) {
            _ = try await WebSocketClientUpgrade.connect(
                channel: clientSide,
                host: "127.0.0.1",
                target: "/ws",
                headers: [("Authorization", "Bearer wrong")]
            )
        }
        #expect(await serverOutcome as? WebSocketHandshakeError == .unauthorized)
    }

    @Test func reportsTheRejectionStatusToTheClient() async throws {
        let policy = WebSocketUpgradePolicy(path: "/ws") { _ in false }
        let (serverSide, clientSide) = InMemoryWebSocketChannel.makePair()
        async let upgrade: Void = {
            _ = try? await WebSocketServerUpgrade.perform(channel: serverSide, policy: policy)
        }()
        do {
            _ = try await WebSocketClientUpgrade.connect(
                channel: clientSide,
                host: "127.0.0.1",
                target: "/ws"
            )
            Issue.record("handshake should have been rejected")
        } catch let error as WebSocketChannelError {
            guard case .handshakeRejected(let status, let body) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(status == 401)
            #expect(body == "Invalid or missing authorization token")
        }
        await upgrade
    }

    @Test func rejectsAWrongPathWith404() async throws {
        let policy = WebSocketUpgradePolicy(path: "/ws")
        let (serverSide, clientSide) = InMemoryWebSocketChannel.makePair()
        async let upgrade: Void = {
            _ = try? await WebSocketServerUpgrade.perform(channel: serverSide, policy: policy)
        }()
        do {
            _ = try await WebSocketClientUpgrade.connect(
                channel: clientSide,
                host: "127.0.0.1",
                target: "/nope"
            )
            Issue.record("handshake should have been rejected")
        } catch let error as WebSocketChannelError {
            guard case .handshakeRejected(let status, _) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(status == 404)
        }
        await upgrade
    }

    @Test func rejectsAHandshakeWithABadKey() async throws {
        let (serverSide, clientSide) = InMemoryWebSocketChannel.makePair()
        // Hand-rolled request with a key that is not 16 decoded bytes.
        let head = "GET /ws HTTP/1.1\r\nHost: h\r\nUpgrade: websocket\r\n"
            + "Connection: Upgrade\r\nSec-WebSocket-Key: c2hvcnQ=\r\n"
            + "Sec-WebSocket-Version: 13\r\n\r\n"
        try await clientSide.write(Array(head.utf8))
        await #expect(throws: WebSocketHandshakeError.invalidKey("c2hvcnQ=")) {
            _ = try await WebSocketServerUpgrade.perform(channel: serverSide)
        }
        let response = try await clientSide.read()
        let text = String(decoding: response ?? [], as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 400 Bad Request"))
    }

    @Test func detectsAnAcceptTokenMismatch() async throws {
        let (serverSide, clientSide) = InMemoryWebSocketChannel.makePair()
        async let fake: Void = {
            _ = try? await serverSide.read()
            // A server that echoes a wrong accept token must be caught, not
            // trusted — otherwise a misconfigured proxy looks like success.
            try? await serverSide.write(WebSocketHandshake.acceptResponse(accept: "bogus"))
        }()
        await #expect(throws: WebSocketChannelError.self) {
            _ = try await WebSocketClientUpgrade.connect(
                channel: clientSide,
                host: "h",
                target: "/ws"
            )
        }
        await fake
    }

    @Test func keepsFrameBytesPipelinedBehindTheHandshake() async throws {
        let (serverSide, clientSide) = InMemoryWebSocketChannel.makePair()
        let key = WebSocketHandshake.makeClientKey()
        // Handshake and first frame arrive in one write, the way a client that
        // does not wait for the 101 would send them.
        var packet = WebSocketHandshake.clientRequest(host: "h", target: "/ws", key: key)
        packet += WebSocketFrameCodec.encode(
            WebSocketFrame(opcode: .text, payload: Array("early".utf8), maskingKey: [1, 2, 3, 4])
        )
        try await clientSide.write(packet)

        let accepted = try await WebSocketServerUpgrade.perform(channel: serverSide)
        #expect(!accepted.leftover.isEmpty)
        let server = WebSocketConnection(
            channel: serverSide,
            role: .server,
            initialBytes: accepted.leftover
        )
        let message = try await server.receive()
        #expect(message == .text("early"))
        await server.close()
    }
}

@Suite("WebSocket connection lifecycle")
struct WebSocketConnectionLifecycleTests {
    @Test func roundTripsTextAndBinaryInBothDirections() async throws {
        let pair = try await makeConnectedPair()
        try await pair.client.send(.text("hello from client"))
        #expect(try await pair.server.receive() == .text("hello from client"))

        try await pair.server.send(.text("hello from server"))
        #expect(try await pair.client.receive() == .text("hello from server"))

        let payload = Data((0..<1000).map { UInt8($0 % 251) })
        try await pair.client.send(.data(payload))
        #expect(try await pair.server.receive() == .data(payload))

        await pair.client.close()
        await pair.server.close()
    }

    @Test func answersAPingWithAPongWithoutSurfacingIt() async throws {
        let pair = try await makeConnectedPair()
        try await pair.server.ping(payload: [0xAB])
        // The client's receive loop answers the ping internally; the pong then
        // arrives at the server and is likewise swallowed. Neither shows up as
        // an application message, so a real message must still come through.
        try await pair.server.send(.text("after ping"))
        #expect(try await pair.client.receive() == .text("after ping"))
        await pair.client.close()
        await pair.server.close()
    }

    @Test func closeIsNegotiatedAndEndsBothStreams() async throws {
        let pair = try await makeConnectedPair()
        await pair.client.close(code: 1001, reason: "going away")
        #expect(try await pair.server.receive() == nil)
        #expect(await pair.server.peerCloseCode == 1001)
        #expect(await pair.server.peerCloseReason == "going away")
    }

    @Test func sendingAfterCloseFails() async throws {
        let pair = try await makeConnectedPair()
        await pair.client.close()
        await #expect(throws: WebSocketChannelError.closed) {
            try await pair.client.send(.text("too late"))
        }
        await pair.server.close()
    }

    @Test func aTruncatedFrameAtEOFIsReportedNotSwallowed() async throws {
        let (serverSide, clientSide) = InMemoryWebSocketChannel.makePair()
        let server = WebSocketConnection(channel: serverSide, role: .server)
        // Half a frame, then the peer disappears. Reporting this as a clean
        // end of stream would hide a truncated message.
        try await clientSide.write([0x81, 0x85, 0x01, 0x02])
        await clientSide.close()
        await #expect(throws: WebSocketChannelError.unexpectedEndOfStream) {
            _ = try await server.receive()
        }
    }

    @Test func aCleanEOFWithNoPartialFrameEndsTheStream() async throws {
        let (serverSide, clientSide) = InMemoryWebSocketChannel.makePair()
        let server = WebSocketConnection(channel: serverSide, role: .server)
        await clientSide.close()
        #expect(try await server.receive() == nil)
    }

    @Test func aProtocolViolationClosesWith1002AndTellsThePeerWhy() async throws {
        let pair = try await makeConnectedPair()
        // A client that forgets to mask is a §5.1 violation.
        try await pair.client.sendRawFrame(
            WebSocketFrame(opcode: .text, payload: Array("unmasked".utf8), maskingKey: nil)
        )
        await #expect(throws: WebSocketProtocolError.unmaskedClientFrame) {
            _ = try await pair.server.receive()
        }
        // The offender is told the code and the reason rather than just
        // having the socket vanish.
        #expect(try await pair.client.receive() == nil)
        #expect(await pair.client.peerCloseCode == 1002)
        #expect(await pair.client.peerCloseReason.contains("not masked"))
    }

    @Test func exceedingTheMessageCapClosesWith1009() async throws {
        let pair = try await makeConnectedPair(maximumMessageSize: 64)
        try await pair.client.send(.text(String(repeating: "x", count: 200)))
        await #expect(throws: WebSocketProtocolError.messageTooLarge(limit: 64)) {
            _ = try await pair.server.receive()
        }
        #expect(try await pair.client.receive() == nil)
        #expect(await pair.client.peerCloseCode == 1009)
    }

    @Test func reassemblesAMessageDeliveredOneByteAtATime() async throws {
        let (serverSide, clientSide) = InMemoryWebSocketChannel.makePair()
        let server = WebSocketConnection(channel: serverSide, role: .server)
        let bytes = WebSocketFrameCodec.encode(
            WebSocketFrame(
                opcode: .text,
                payload: Array("split across reads".utf8),
                maskingKey: [0xDE, 0xAD, 0xBE, 0xEF]
            )
        )
        // Every byte is its own read, which is the worst case a real socket
        // can produce.
        Task {
            for byte in bytes { try? await clientSide.write([byte]) }
        }
        #expect(try await server.receive() == .text("split across reads"))
        await server.close()
    }

    @Test func joinsFragmentedMessagesArrivingWithInterleavedPings() async throws {
        let (serverSide, clientSide) = InMemoryWebSocketChannel.makePair()
        let server = WebSocketConnection(channel: serverSide, role: .server)
        let frames = [
            WebSocketFrame(isFinal: false, opcode: .text, payload: Array("frag".utf8), maskingKey: [1, 1, 1, 1]),
            WebSocketFrame(opcode: .ping, payload: [0x01], maskingKey: [2, 2, 2, 2]),
            WebSocketFrame(isFinal: false, opcode: .continuation, payload: Array("ment".utf8), maskingKey: [3, 3, 3, 3]),
            WebSocketFrame(opcode: .continuation, payload: Array("ed".utf8), maskingKey: [4, 4, 4, 4]),
        ]
        try await clientSide.write(frames.flatMap { WebSocketFrameCodec.encode($0) })
        #expect(try await server.receive() == .text("fragmented"))
        await server.close()
    }
}
