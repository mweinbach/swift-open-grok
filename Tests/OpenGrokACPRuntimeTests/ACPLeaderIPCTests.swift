// ACPLeaderIPCTests.swift
//
// The leader's inbound half: registration, id namespacing across clients, and
// the shared-session guarantee.
//
// Driven over `InMemoryWebSocketChannel` pairs rather than a real Unix socket,
// because everything under test here is platform-free — the socket is one
// adapter and has its own coverage.

import Foundation
import OpenGrokACP
import OpenGrokHTTP
import OpenGrokShared
import Testing

@testable import OpenGrokACPRuntime

// MARK: - Driver

private struct LeaderEchoPromptDriver: ACPPromptDriver {
    func run(
        context: ACPPromptContext,
        emit: @escaping @Sendable (SessionNotification, ACPNotificationDisposition) async -> Void
    ) async throws -> PromptResponse {
        await emit(
            SessionNotification(
                sessionId: context.session.sessionId,
                update: .agentMessageChunk(ContentChunk(content: .text(TextContent(text: "ack"))))
            ),
            .durable
        )
        return PromptResponse(stopReason: .endTurn)
    }

    func cancel(sessionId: AcpSessionId) async {}
}

// MARK: - A client of the leader

/// The far end of one IPC channel, speaking the envelope by hand.
private actor LeaderTestClient {
    private let channel: InMemoryWebSocketChannel
    private let reader: ACPLeaderChannelReader

    init(channel: InMemoryWebSocketChannel) {
        self.channel = channel
        self.reader = ACPLeaderChannelReader(
            channel: channel,
            maximumMessageSize: ACPLeaderProtocolLimits.maximumMessageSize
        )
    }

    func send(_ message: ACPLeaderClientMessage) async throws {
        try await channel.write(try ACPLeaderCodec.encode(message))
    }

    func sendACP(_ message: ACPMessage) async throws {
        let line = String(decoding: try message.encodedData(), as: UTF8.self)
        try await send(.acp(payload: line))
    }

    /// Read one message, bounded.
    ///
    /// The bound is not belt-and-braces: `ByteMailbox.take()` parks on a
    /// continuation that ignores cancellation, so a leader that stops sending
    /// would hang the whole suite rather than fail one test — `.timeLimit`
    /// cannot reap a task that never checks for cancellation. Closing the
    /// channel is what releases the parked read.
    func next(timeoutSeconds: Double = 5) async throws -> ACPLeaderServerMessage? {
        let deadline = Task { [channel] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await channel.close()
        }
        defer { deadline.cancel() }
        return try await reader.next(ACPLeaderServerMessage.self)
    }

    /// Read until a server message matches, so an interleaved notification
    /// cannot make an assertion flaky.
    func next(
        limit: Int = 40,
        until match: @Sendable (ACPLeaderServerMessage) -> Bool
    ) async throws -> ACPLeaderServerMessage {
        for _ in 0..<limit {
            guard let message = try await next() else { break }
            if match(message) { return message }
        }
        throw ACPLeaderProtocolError.connectionClosed
    }

    /// Read until an ACP message matches, decoding the `acp` payloads.
    func nextACP(
        limit: Int = 40,
        until match: @Sendable (ACPMessage) -> Bool
    ) async throws -> ACPMessage {
        for _ in 0..<limit {
            guard let message = try await next() else { break }
            guard case .acp(let payload) = message,
                let decoded = try? ACPMessage(data: Data(payload.utf8))
            else { continue }
            if match(decoded) { return decoded }
        }
        throw ACPLeaderProtocolError.connectionClosed
    }

    func close() async {
        await channel.close()
    }
}

private func attach(
    to host: ACPLeaderIPCHost
) -> (client: LeaderTestClient, served: Task<Void, Never>) {
    let pair = InMemoryWebSocketChannel.makePair()
    let served = Task { await host.serve(channel: pair.a) }
    return (LeaderTestClient(channel: pair.b), served)
}

private func leaderInitialize(id: Int64) -> ACPMessage {
    .request(
        id: .number(id),
        method: AgentMethodNames.initialize,
        params: .object([
            "protocolVersion": .number(.int64(1)),
            "clientCapabilities": .object([:]),
        ])
    )
}

private func leaderNewSession(id: Int64) -> ACPMessage {
    .request(
        id: .number(id),
        method: AgentMethodNames.sessionNew,
        params: .object([
            "cwd": .string(FileManager.default.currentDirectoryPath),
            "mcpServers": .array([]),
        ])
    )
}

private func leaderPrompt(id: Int64, sessionId: String) -> ACPMessage {
    .request(
        id: .number(id),
        method: AgentMethodNames.sessionPrompt,
        params: .object([
            "sessionId": .string(sessionId),
            "prompt": .array([.object(["type": .string("text"), "text": .string("hi")])]),
        ])
    )
}

private func sessionID(from message: ACPMessage) throws -> String {
    guard case .response(_, let result, _) = message,
        case .object(let object)? = result,
        case .string(let id)? = object["sessionId"]
    else { throw ACPTransportError.invalidMessage("no sessionId in \(message)") }
    return id
}

// MARK: - Tests

@Suite("Leader IPC registration")
struct ACPLeaderIPCRegistrationTests {
    private func makeHost() -> ACPLeaderIPCHost {
        ACPLeaderIPCHost(
            runtime: ACPAgentRuntime(promptDriver: LeaderEchoPromptDriver()),
            configuration: ACPLeaderIPCConfiguration(binaryVersion: "1.2.3")
        )
    }

    @Test("registering yields a client id, the protocol version and capabilities", .timeLimit(.minutes(1)))
    func registration() async throws {
        let host = makeHost()
        let (client, served) = attach(to: host)
        defer { served.cancel() }

        try await client.send(
            .register(clientType: "grok-tui", mode: .stdio, capabilities: ACPLeaderClientCapabilities())
        )
        let reply = try await client.next { _ in true }
        guard case .registered(let clientID, let ready, let version, let binary, let capabilities) = reply
        else {
            Issue.record("expected registered, got \(reply)")
            return
        }
        #expect(clientID == 1)
        #expect(ready)
        #expect(version == ACPLeaderProtocolLimits.protocolVersion)
        #expect(binary == "1.2.3")
        #expect(capabilities == ACPLeaderCapabilities.supported)
    }

    /// `server.rs:2379` — a client that starts talking ACP before registering
    /// gets error code 1, not a silently dropped frame.
    @Test("talking before registering is refused with code 1", .timeLimit(.minutes(1)))
    func mustRegisterFirst() async throws {
        let host = makeHost()
        let (client, served) = attach(to: host)
        defer { served.cancel() }

        try await client.send(.ping)
        let reply = try await client.next { _ in true }
        guard case .error(let code, let message) = reply else {
            Issue.record("expected an error, got \(reply)")
            return
        }
        #expect(code == ACPLeaderRegistrationError.expectedRegister)
        #expect(message == "Expected Register message")
    }

    /// `server.rs:2422` — a second `register` is code 2. It must not silently
    /// re-register, which would strand the first registration's routing state.
    @Test("registering twice is refused with code 2", .timeLimit(.minutes(1)))
    func doubleRegistration() async throws {
        let host = makeHost()
        let (client, served) = attach(to: host)
        defer { served.cancel() }

        try await client.send(
            .register(clientType: "a", mode: .stdio, capabilities: ACPLeaderClientCapabilities())
        )
        _ = try await client.next { if case .registered = $0 { return true } else { return false } }

        try await client.send(
            .register(clientType: "b", mode: .stdio, capabilities: ACPLeaderClientCapabilities())
        )
        let reply = try await client.next { if case .error = $0 { return true } else { return false } }
        guard case .error(let code, _) = reply else { return }
        #expect(code == ACPLeaderRegistrationError.alreadyRegistered)
    }

    /// `server.rs:2489` — a client that connects and says nothing holds a slot,
    /// so registration is bounded.
    @Test("a silent client is dropped with code 3", .timeLimit(.minutes(1)))
    func registrationTimeout() async throws {
        let host = ACPLeaderIPCHost(
            runtime: ACPAgentRuntime(promptDriver: LeaderEchoPromptDriver()),
            configuration: ACPLeaderIPCConfiguration(registrationTimeoutSeconds: 0.05)
        )
        let (client, served) = attach(to: host)
        defer { served.cancel() }

        let reply = try await client.next { _ in true }
        guard case .error(let code, let message) = reply else {
            Issue.record("expected an error, got \(reply)")
            return
        }
        #expect(code == ACPLeaderRegistrationError.registrationTimeout)
        #expect(message == "Registration timeout")
    }

    @Test("ping is answered with pong", .timeLimit(.minutes(1)))
    func pingPong() async throws {
        let host = makeHost()
        let (client, served) = attach(to: host)
        defer { served.cancel() }

        try await client.send(
            .register(clientType: "a", mode: .stdio, capabilities: ACPLeaderClientCapabilities())
        )
        _ = try await client.next { if case .registered = $0 { return true } else { return false } }
        try await client.send(.ping)
        let reply = try await client.next { if case .pong = $0 { return true } else { return false } }
        #expect(reply == .pong)
    }

    /// This build advertises `control_v1 = false`. A client that ignores the
    /// bit and sends a control request must get a refusal it can act on, not a
    /// request that hangs forever.
    @Test("a control command is refused with an actionable message", .timeLimit(.minutes(1)))
    func controlIsRefused() async throws {
        let host = makeHost()
        let (client, served) = attach(to: host)
        defer { served.cancel() }

        try await client.send(
            .register(clientType: "a", mode: .stdio, capabilities: ACPLeaderClientCapabilities())
        )
        _ = try await client.next { if case .registered = $0 { return true } else { return false } }

        try await client.send(.control(requestID: "42", command: ["type": "get_leader_info"]))
        let reply = try await client.next {
            if case .controlError = $0 { return true } else { return false }
        }
        guard case .controlError(let requestID, _, let message) = reply else { return }
        #expect(requestID == "42")
        #expect(message.contains("control_v1"))
        #expect(message.contains("get_leader_info"))
    }

    /// `server.rs:1650-1665` — only a headless registration arms the relay. A
    /// TUI attaching locally must not, or an auto-spawned leader would open a
    /// remote leg nobody asked for.
    @Test("only a headless client signals relay demand", .timeLimit(.minutes(1)))
    func headlessSignalsRelayDemand() async throws {
        let host = makeHost()
        let (stdio, servedStdio) = attach(to: host)
        defer { servedStdio.cancel() }

        try await stdio.send(
            .register(clientType: "grok-tui", mode: .stdio, capabilities: ACPLeaderClientCapabilities())
        )
        _ = try await stdio.next { if case .registered = $0 { return true } else { return false } }
        #expect(await host.hasHeadlessClient() == false)

        let (headless, servedHeadless) = attach(to: host)
        defer { servedHeadless.cancel() }
        try await headless.send(
            .register(clientType: "grok-p", mode: .headless, capabilities: ACPLeaderClientCapabilities())
        )
        _ = try await headless.next { if case .registered = $0 { return true } else { return false } }
        #expect(await host.hasHeadlessClient())
    }
}

@Suite("Leader IPC routing", .serialized)
struct ACPLeaderIPCRoutingTests {
    private func makeHost() -> ACPLeaderIPCHost {
        ACPLeaderIPCHost(runtime: ACPAgentRuntime(promptDriver: LeaderEchoPromptDriver()))
    }

    private func register(
        _ client: LeaderTestClient,
        as type: String,
        mode: ACPLeaderClientMode = .stdio,
        capabilities: ACPLeaderClientCapabilities = ACPLeaderClientCapabilities()
    ) async throws -> UInt64 {
        try await client.send(.register(clientType: type, mode: mode, capabilities: capabilities))
        let reply = try await client.next {
            if case .registered = $0 { return true } else { return false }
        }
        guard case .registered(let clientID, _, _, _, _) = reply else { return 0 }
        return clientID
    }

    @Test("a client drives a full session through the leader", .timeLimit(.minutes(1)))
    func fullSessionThroughTheLeader() async throws {
        let host = makeHost()
        let (client, served) = attach(to: host)
        defer { served.cancel() }
        _ = try await register(client, as: "grok-tui")

        try await client.sendACP(leaderInitialize(id: 1))
        let initialized = try await client.nextACP { message in
            if case .response(.number(1), _, _) = message { return true }
            return false
        }
        if case .response(_, _, let error) = initialized { #expect(error == nil) }

        try await client.sendACP(leaderNewSession(id: 2))
        let created = try await client.nextACP { message in
            if case .response(.number(2), _, _) = message { return true }
            return false
        }
        let session = try sessionID(from: created)

        try await client.sendACP(leaderPrompt(id: 3, sessionId: session))
        let update = try await client.nextACP { $0.method == ClientMethodNames.sessionUpdate }
        #expect(update.method == ClientMethodNames.sessionUpdate)

        let done = try await client.nextACP { message in
            if case .response(.number(3), _, _) = message { return true }
            return false
        }
        if case .response(_, let result, _) = done, case .object(let object)? = result {
            #expect(object["stopReason"] == .string("end_turn"))
        }
    }

    /// The id a client sent is the id it must get back. Two clients both using
    /// `id: 1` is the ordinary case, not a corner one — every ACP client starts
    /// counting at 1.
    @Test("two clients using the same id each get their own response", .timeLimit(.minutes(1)))
    func idsDoNotCollideAcrossClients() async throws {
        let host = makeHost()
        let (first, servedFirst) = attach(to: host)
        let (second, servedSecond) = attach(to: host)
        defer {
            servedFirst.cancel()
            servedSecond.cancel()
        }

        let firstID = try await register(first, as: "client-a")
        let secondID = try await register(second, as: "client-b")
        #expect(firstID != secondID)

        try await first.sendACP(leaderInitialize(id: 1))
        try await second.sendACP(leaderInitialize(id: 1))

        let firstReply = try await first.nextACP { message in
            if case .response(.number(1), _, _) = message { return true }
            return false
        }
        let secondReply = try await second.nextACP { message in
            if case .response(.number(1), _, _) = message { return true }
            return false
        }

        // The namespacing is invisible to the client: what comes back is the
        // plain `1` it sent, not `"1|1"`.
        #expect(firstReply.id == .number(1))
        #expect(secondReply.id == .number(1))
    }

    /// The shared-agent guarantee: a session created by one client is
    /// addressable by another. Without it, leader mode is just several agents
    /// behind one socket.
    @Test("a session created by one client is usable by another", .timeLimit(.minutes(1)))
    func sessionsAreShared() async throws {
        let host = makeHost()
        let (first, servedFirst) = attach(to: host)
        let (second, servedSecond) = attach(to: host)
        defer {
            servedFirst.cancel()
            servedSecond.cancel()
        }

        _ = try await register(first, as: "client-a")
        _ = try await register(second, as: "client-b")

        // The runtime refuses `session/new` before `initialize`; the shared
        // runtime means one client's initialize covers the connection.
        try await first.sendACP(leaderInitialize(id: 1))
        _ = try await first.nextACP { message in
            if case .response(.number(1), _, _) = message { return true }
            return false
        }

        try await first.sendACP(leaderNewSession(id: 10))
        let created = try await first.nextACP { message in
            if case .response(.number(10), _, _) = message { return true }
            return false
        }
        let session = try sessionID(from: created)

        try await second.sendACP(leaderPrompt(id: 20, sessionId: session))
        let done = try await second.nextACP { message in
            if case .response(.number(20), _, _) = message { return true }
            return false
        }
        if case .response(_, let result, let error) = done {
            #expect(error == nil)
            if case .object(let object)? = result {
                #expect(object["stopReason"] == .string("end_turn"))
            }
        }
    }

    /// `server.rs:670-767` — the capabilities a client registered with reach
    /// the agent as `_meta` on `session/new`, which is how a yolo-mode TUI and
    /// a read-only IDE get different behaviour from one shared agent.
    @Test("registered capabilities reach the agent as session/new meta", .timeLimit(.minutes(1)))
    func capabilitiesReachTheAgent() async throws {
        // Captured from the runtime's side by inspecting what injection
        // produces for this client, which is the same code path the host runs.
        let injected = ACPLeaderCapabilityInjection.inject(
            into: leaderNewSession(id: 1),
            clientID: 4,
            clientType: "grok-tui",
            capabilities: ACPLeaderClientCapabilities(yoloMode: true, fsWrite: true)
        )
        guard case .request(_, _, let params) = injected,
            case .object(let object) = params ?? .null,
            case .object(let meta) = object["_meta"] ?? .null
        else {
            Issue.record("injection did not produce _meta")
            return
        }
        #expect(meta["yoloMode"] == .bool(true))
        #expect(meta["clientFsWrite"] == .bool(true))
        #expect(meta["clientIdentifier"] == .string("grok-tui"))

        // And the `cwd` the request carried is untouched.
        #expect(object["cwd"] == .string(FileManager.default.currentDirectoryPath))
    }

    @Test("a disconnected client stops being counted", .timeLimit(.minutes(1)))
    func disconnectUnregisters() async throws {
        let host = makeHost()
        let (client, served) = attach(to: host)
        defer { served.cancel() }
        _ = try await register(client, as: "client-a")
        #expect(await host.connectedClientCount() == 1)

        try await client.send(.disconnect)

        // The read loop returns on `disconnect`; poll rather than sleep a fixed
        // interval so the test is not timing-tuned.
        for _ in 0..<100 {
            if await host.connectedClientCount() == 0 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(await host.connectedClientCount() == 0)
    }
}
