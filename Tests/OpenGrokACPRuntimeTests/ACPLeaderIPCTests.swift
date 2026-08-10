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

private func leaderClose(id: Int64, sessionId: String) -> ACPMessage {
    .request(
        id: .number(id),
        method: AgentMethodNames.sessionClose,
        params: .object(["sessionId": .string(sessionId)])
    )
}

private func rosterChanged(from message: ACPMessage) -> ACPLeaderRosterChanged? {
    guard case .notification(let method, let params) = message,
          ACPMethodRoute.normalize(method: method, params: params).method
            == ACPLeaderRosterMethods.sessionsChanged
    else { return nil }
    return try? params.decode(ACPLeaderRosterChanged.self)
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

@Suite("Leader IPC roster", .serialized)
struct ACPLeaderIPCRosterTests {
    @Test("other-process sessions publish snapshot and honest activity deltas", .timeLimit(.minutes(1)))
    func rosterLifecycleAcrossClients() async throws {
        let runtime = ACPAgentRuntime(
            promptDriver: LeaderEchoPromptDriver(),
            makeSessionId: { "sess-roster" },
            timestamp: { "2026-08-10T12:00:00Z" },
            rosterTimestampMilliseconds: { 1_754_827_200_000 }
        )
        let host = ACPLeaderIPCHost(runtime: runtime)
        let (driver, driverTask) = attach(to: host)
        let (viewer, viewerTask) = attach(to: host)
        defer {
            driverTask.cancel()
            viewerTask.cancel()
        }

        try await driver.send(.register(
            clientType: "driver",
            mode: .stdio,
            capabilities: ACPLeaderClientCapabilities(yoloMode: true)
        ))
        try await viewer.send(.register(
            clientType: "viewer",
            mode: .stdio,
            capabilities: ACPLeaderClientCapabilities()
        ))
        _ = try await driver.next { if case .registered = $0 { true } else { false } }
        _ = try await viewer.next { if case .registered = $0 { true } else { false } }

        try await driver.sendACP(leaderInitialize(id: 1))
        _ = try await driver.nextACP {
            if case .response(.number(1), _, _) = $0 { true } else { false }
        }

        try await driver.sendACP(leaderNewSession(id: 2))
        let createdForDriver = try await driver.nextACP {
            rosterChanged(from: $0)?.upserted.first?.sessionId == "sess-roster"
        }
        let createdForViewer = try await viewer.nextACP {
            rosterChanged(from: $0)?.upserted.first?.sessionId == "sess-roster"
        }
        let createResponse = try await driver.nextACP {
            if case .response(.number(2), _, _) = $0 { true } else { false }
        }
        #expect(try sessionID(from: createResponse) == "sess-roster")

        for message in [createdForDriver, createdForViewer] {
            let changed = try #require(rosterChanged(from: message))
            let entry = try #require(changed.upserted.first)
            #expect(entry.sessionId == "sess-roster")
            #expect(entry.activity == .idle)
            #expect(entry.resident)
            #expect(entry.yolo)
            #expect(entry.cwd == FileManager.default.currentDirectoryPath)
            #expect(entry.lastChangeUnixMs == 1_754_827_200_000)
            #expect(changed.removed.isEmpty)
        }

        try await viewer.sendACP(.request(
            id: .number(3),
            method: ACPLeaderRosterMethods.sessionsList,
            params: .object([:])
        ))
        let listResponse = try await viewer.nextACP {
            if case .response(.number(3), _, _) = $0 { true } else { false }
        }
        guard case .response(_, let listResult?, nil) = listResponse else {
            Issue.record("expected a successful roster snapshot response")
            return
        }
        let list = try listResult.decode(ACPLeaderRosterListResponse.self)
        #expect(list.sessions.map(\.sessionId) == ["sess-roster"])
        #expect(list.sessions.first?.activity == .idle)

        try await driver.sendACP(leaderPrompt(id: 4, sessionId: "sess-roster"))
        for client in [driver, viewer] {
            let working = try await client.nextACP {
                rosterChanged(from: $0)?.upserted.first?.activity == .working
            }
            #expect(rosterChanged(from: working)?.upserted.first?.sessionId == "sess-roster")
        }
        for client in [driver, viewer] {
            let idle = try await client.nextACP {
                rosterChanged(from: $0)?.upserted.first?.activity == .idle
            }
            #expect(rosterChanged(from: idle)?.upserted.first?.sessionId == "sess-roster")
        }
        _ = try await driver.nextACP {
            if case .response(.number(4), _, _) = $0 { true } else { false }
        }

        try await driver.sendACP(leaderClose(id: 5, sessionId: "sess-roster"))
        for client in [driver, viewer] {
            let removed = try await client.nextACP {
                rosterChanged(from: $0)?.removed == ["sess-roster"]
            }
            #expect(rosterChanged(from: removed)?.upserted.isEmpty == true)
        }
        _ = try await driver.nextACP {
            if case .response(.number(5), _, _) = $0 { true } else { false }
        }

        try await viewer.sendACP(.request(
            id: .number(6),
            method: ACPLeaderRosterMethods.sessionsList,
            params: .object([:])
        ))
        let emptyResponse = try await viewer.nextACP {
            if case .response(.number(6), _, _) = $0 { true } else { false }
        }
        guard case .response(_, let emptyResult?, nil) = emptyResponse else {
            Issue.record("expected a successful empty roster response")
            return
        }
        #expect(try emptyResult.decode(ACPLeaderRosterListResponse.self).sessions.isEmpty)
    }
}

// MARK: - Control plane fakes

/// A connected exposure, standing in for the hub backend a composition
/// injects in production (`ACPWorkspaceExposureConnector`).
private final class FakeExposureConnection: ACPWorkspaceExposureConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var activity: ACPWorkspaceActivitySnapshot
    private var disconnects = 0
    private var reconnects = 0
    private var reconnectError: (any Error)?

    init(activity: ACPWorkspaceActivitySnapshot = ACPWorkspaceActivitySnapshot()) {
        self.activity = activity
    }

    var disconnectCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return disconnects
    }

    var reconnectCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reconnects
    }

    func failReconnects(with error: any Error) {
        lock.lock()
        reconnectError = error
        lock.unlock()
    }

    func snapshot() -> ACPWorkspaceActivitySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return activity
    }

    func disconnect() async {
        lock.withLock {
            disconnects += 1
        }
    }

    func reconnect() async throws {
        let error = lock.withLock {
            reconnects += 1
            return reconnectError
        }
        if let error { throw error }
    }
}

private struct FakeHubError: Error, CustomStringConvertible {
    var description: String { "hub offline" }
}

/// One (hubURL, cwd) a connector was asked to connect. A named struct rather
/// than a tuple so call lists compare with plain `==` (tuples cannot conform
/// to `Equatable`, so `[(String, String)]` has no array equality).
private struct ConnectCall: Equatable {
    var hubURL: String
    var cwd: String
}

/// Records the connects a connector was asked to perform, so a test can tell
/// a real connect from an idempotent re-read.
private final class ConnectLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ConnectCall] = []

    var calls: [ConnectCall] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func record(_ hubURL: String, _ cwd: String) {
        lock.lock()
        entries.append(ConnectCall(hubURL: hubURL, cwd: cwd))
        lock.unlock()
    }
}

/// A movable offset for the plane's injected clock, so uptime assertions are
/// exact rather than timing-tuned.
private final class MutableUptime: @unchecked Sendable {
    private let lock = NSLock()
    private var nanoseconds: UInt64 = 0

    var value: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return nanoseconds
    }

    func advance(milliseconds: UInt64) {
        lock.lock()
        nanoseconds += milliseconds * 1_000_000
        lock.unlock()
    }
}

@Suite("Leader IPC control plane")
struct ACPLeaderControlPlaneTests {
    private func makeHost(plane: ACPLeaderControlPlane? = nil) -> ACPLeaderIPCHost {
        ACPLeaderIPCHost(
            runtime: ACPAgentRuntime(promptDriver: LeaderEchoPromptDriver()),
            configuration: ACPLeaderIPCConfiguration(binaryVersion: "1.2.3", controlPlane: plane)
        )
    }

    @discardableResult
    private func register(_ client: LeaderTestClient) async throws -> ACPLeaderCapabilities? {
        try await client.send(
            .register(clientType: "grok-workspace-cli", mode: .stdio, capabilities: ACPLeaderClientCapabilities())
        )
        let reply = try await client.next { if case .registered = $0 { return true } else { return false } }
        guard case .registered(_, _, _, _, let capabilities) = reply else { return nil }
        return capabilities
    }

    private func sendControl(
        _ client: LeaderTestClient,
        id: String,
        command: [String: String]
    ) async throws {
        try await client.send(.control(requestID: id, command: command))
    }

    private func nextResult(
        _ client: LeaderTestClient
    ) async throws -> ACPLeaderServerMessage {
        try await client.next { if case .controlResult = $0 { return true } else { return false } }
    }

    private func nextError(
        _ client: LeaderTestClient
    ) async throws -> ACPLeaderServerMessage {
        try await client.next { if case .controlError = $0 { return true } else { return false } }
    }

    private var processPID: UInt32 {
        UInt32(clamping: ProcessInfo.processInfo.processIdentifier)
    }

    /// The production default: no hub backend is wired, and status must still
    /// answer truthfully through the real host rather than the route hanging.
    /// This is the live-seam proof behind the `workspace_exposure` advert.
    @Test("workspace status on a backend-less leader answers state none with the real pid", .timeLimit(.minutes(1)))
    func statusWithoutBackend() async throws {
        let host = makeHost()
        let (client, served) = attach(to: host)
        defer { served.cancel() }

        let capabilities = try await register(client)
        #expect(capabilities?.controlV1 == true)
        #expect(capabilities?.workspaceExposure == true)

        try await sendControl(client, id: "ws-1", command: ["type": "workspace_status"])
        let reply = try await nextResult(client)
        guard case .controlResult("ws-1", .workspaceStatus(let status)) = reply else {
            Issue.record("expected a workspace_status result, got \(reply)")
            return
        }
        #expect(status.state == "none")
        #expect(status.pid == processPID)
        #expect(status.uptimeMs == 0)
        #expect(status.activeToolCalls == 0)
        #expect(status.sessions.isEmpty)
        #expect(status.hubURL == nil)
        #expect(status.cwd == nil)
    }

    /// The port's workspace CLI spells the discriminator `command`
    /// (`WorkspaceControlCommand.wire`); upstream spells it `type`. Both must
    /// parse, or the shipped client breaks against its own leader.
    @Test("the port's `command` spelling and upstream's `type` spelling both parse", .timeLimit(.minutes(1)))
    func bothDiscriminatorSpellingsParse() async throws {
        let host = makeHost()
        let (client, served) = attach(to: host)
        defer { served.cancel() }
        _ = try await register(client)

        try await sendControl(client, id: "a", command: ["command": "workspace_status"])
        let portReply = try await nextResult(client)
        guard case .controlResult("a", .workspaceStatus) = portReply else {
            Issue.record("the `command` spelling did not parse: \(portReply)")
            return
        }

        try await sendControl(client, id: "b", command: ["type": "workspace_status"])
        let upstreamReply = try await nextResult(client)
        guard case .controlResult("b", .workspaceStatus) = upstreamReply else {
            Issue.record("the `type` spelling did not parse: \(upstreamReply)")
            return
        }
    }

    /// A frame with no discriminator at all must produce a typed error — the
    /// failure mode that matters is a client hanging on a request nobody
    /// answers, and it must stay impossible.
    @Test("a control frame without a discriminator is an error, not a hang", .timeLimit(.minutes(1)))
    func missingDiscriminator() async throws {
        let host = makeHost()
        let (client, served) = attach(to: host)
        defer { served.cancel() }
        _ = try await register(client)

        try await sendControl(client, id: "9", command: [:])
        let reply = try await nextError(client)
        guard case .controlError("9", let code, let message) = reply else {
            Issue.record("expected a control error, got \(reply)")
            return
        }
        #expect(code == ACPLeaderControlErrorCode.invalidCommand)
        #expect(message.contains("discriminator"))
    }

    /// With no hub backend wired, start refuses with a typed error that names
    /// the missing piece — and status keeps telling the truth afterwards.
    @Test("workspace start without a backend is refused and state stays none", .timeLimit(.minutes(1)))
    func startWithoutBackendRefused() async throws {
        let host = makeHost()
        let (client, served) = attach(to: host)
        defer { served.cancel() }
        _ = try await register(client)

        try await sendControl(client, id: "1", command: ["type": "workspace_start", "cwd": "/tmp/proj"])
        let refusal = try await nextError(client)
        guard case .controlError("1", let code, let message) = refusal else {
            Issue.record("expected a control error, got \(refusal)")
            return
        }
        #expect(code == ACPLeaderControlErrorCode.workspaceError)
        #expect(message.contains("no hub connection backend"))

        try await sendControl(client, id: "2", command: ["type": "workspace_status"])
        let reply = try await nextResult(client)
        guard case .controlResult("2", .workspaceStatus(let status)) = reply else {
            Issue.record("expected a status, got \(reply)")
            return
        }
        #expect(status.state == "none")
    }

    /// The whole point of the control plane: drive start → pause → resume →
    /// status → stop through the real host and watch the wire payload track
    /// each transition (`server.rs:1100-1226`).
    @Test("the exposure lifecycle moves through real states on the wire", .timeLimit(.minutes(1)))
    func exposureLifecycle() async throws {
        let connection = FakeExposureConnection(
            activity: ACPWorkspaceActivitySnapshot(activeToolCalls: 2, sessionIDs: ["sess-b", "sess-a"])
        )
        let connects = ConnectLog()
        let plane = ACPLeaderControlPlane(
            metadata: ACPLeaderControlMetadata(binaryVersion: "1.2.3"),
            connector: { hubURL, cwd in
                connects.record(hubURL, cwd)
                return connection
            }
        )
        let host = makeHost(plane: plane)
        let (client, served) = attach(to: host)
        defer { served.cancel() }
        _ = try await register(client)

        try await sendControl(client, id: "1", command: [
            "type": "workspace_start",
            "hub_url": "wss://hub.test/ws",
            "cwd": "/tmp/proj",
        ])
        let started = try await nextResult(client)
        guard case .controlResult("1", .workspaceStatus(let running)) = started else {
            Issue.record("expected start to succeed, got \(started)")
            return
        }
        #expect(running.state == "running")
        #expect(running.hubURL == "wss://hub.test/ws")
        #expect(running.cwd == "/tmp/proj")
        #expect(running.activeToolCalls == 2)
        // `server.rs:1081-1082` — sessions are sorted in the payload.
        #expect(running.sessions == ["sess-a", "sess-b"])
        #expect(running.pid == processPID)
        #expect(connects.calls == [ConnectCall(hubURL: "wss://hub.test/ws", cwd: "/tmp/proj")])

        try await sendControl(client, id: "2", command: ["type": "workspace_pause"])
        let paused = try await nextResult(client)
        guard case .controlResult("2", .workspaceStatus(let pausedStatus)) = paused else {
            Issue.record("expected pause to succeed, got \(paused)")
            return
        }
        #expect(pausedStatus.state == "paused")
        #expect(connection.disconnectCount == 1)

        try await sendControl(client, id: "3", command: ["type": "workspace_resume"])
        let resumed = try await nextResult(client)
        guard case .controlResult("3", .workspaceStatus(let resumedStatus)) = resumed else {
            Issue.record("expected resume to succeed, got \(resumed)")
            return
        }
        #expect(resumedStatus.state == "running")
        #expect(connection.reconnectCount == 1)

        try await sendControl(client, id: "4", command: ["type": "workspace_status"])
        let polled = try await nextResult(client)
        guard case .controlResult("4", .workspaceStatus(let polledStatus)) = polled else {
            Issue.record("expected status to succeed, got \(polled)")
            return
        }
        #expect(polledStatus.state == "running")

        try await sendControl(client, id: "5", command: ["type": "workspace_stop"])
        let stopped = try await nextResult(client)
        guard case .controlResult("5", .workspaceStatus(let stoppedStatus)) = stopped else {
            Issue.record("expected stop to succeed, got \(stopped)")
            return
        }
        #expect(stoppedStatus.state == "none")
        #expect(stoppedStatus.hubURL == nil)
        #expect(connection.disconnectCount == 2)
    }

    /// `server.rs:1116-1124` — a start that names the live exposure's own
    /// parameters is a status read, not a reconnect.
    @Test("re-starting the same exposure answers without reconnecting", .timeLimit(.minutes(1)))
    func startIsIdempotent() async throws {
        let connects = ConnectLog()
        let plane = ACPLeaderControlPlane(
            connector: { hubURL, cwd in
                connects.record(hubURL, cwd)
                return FakeExposureConnection()
            }
        )
        let host = makeHost(plane: plane)
        let (client, served) = attach(to: host)
        defer { served.cancel() }
        _ = try await register(client)

        let command: [String: String] = [
            "type": "workspace_start",
            "hub_url": "wss://hub.test/ws",
            "cwd": "/tmp/proj",
        ]
        try await sendControl(client, id: "1", command: command)
        _ = try await nextResult(client)
        try await sendControl(client, id: "2", command: command)
        let second = try await nextResult(client)
        guard case .controlResult("2", .workspaceStatus(let status)) = second else {
            Issue.record("expected the second start to succeed, got \(second)")
            return
        }
        #expect(status.state == "running")
        #expect(connects.calls.count == 1)
    }

    /// `server.rs:1108-1114` — no explicit `hub_url` falls through to the
    /// production hub constant.
    @Test("start with no hub url resolves the production hub", .timeLimit(.minutes(1)))
    func startDefaultsHubURL() async throws {
        let connects = ConnectLog()
        let plane = ACPLeaderControlPlane(
            connector: { hubURL, cwd in
                connects.record(hubURL, cwd)
                return FakeExposureConnection()
            }
        )
        let host = makeHost(plane: plane)
        let (client, served) = attach(to: host)
        defer { served.cancel() }
        _ = try await register(client)

        try await sendControl(client, id: "1", command: ["type": "workspace_start", "cwd": "/tmp/proj"])
        let reply = try await nextResult(client)
        guard case .controlResult("1", .workspaceStatus(let status)) = reply else {
            Issue.record("expected start to succeed, got \(reply)")
            return
        }
        #expect(status.hubURL == ACPLeaderControlPlane.productionComputerHubURL)
        #expect(connects.calls == [ConnectCall(hubURL: ACPLeaderControlPlane.productionComputerHubURL, cwd: "/tmp/proj")])
    }

    /// `server.rs:1112-1113` — a hub URL that is not ws/wss is refused before
    /// any connect is attempted.
    @Test("start with an invalid hub url is refused before any connect", .timeLimit(.minutes(1)))
    func startInvalidHubURL() async throws {
        let connects = ConnectLog()
        let plane = ACPLeaderControlPlane(
            connector: { hubURL, cwd in
                connects.record(hubURL, cwd)
                return FakeExposureConnection()
            }
        )
        let host = makeHost(plane: plane)
        let (client, served) = attach(to: host)
        defer { served.cancel() }
        _ = try await register(client)

        try await sendControl(client, id: "1", command: [
            "type": "workspace_start",
            "hub_url": "https://not-a-socket.example",
            "cwd": "/tmp/proj",
        ])
        let refusal = try await nextError(client)
        guard case .controlError("1", let code, let message) = refusal else {
            Issue.record("expected a control error, got \(refusal)")
            return
        }
        #expect(code == ACPLeaderControlErrorCode.workspaceError)
        #expect(message.contains("invalid hub url"))
        #expect(connects.calls.isEmpty)
    }

    /// `server.rs:1176`, :1192 vs :1207-1217: pause and resume with no
    /// exposure are errors; stop is a successful not-running status.
    @Test("pause and resume without an exposure are refused; stop reports none", .timeLimit(.minutes(1)))
    func noExposureRefusals() async throws {
        let host = makeHost()
        let (client, served) = attach(to: host)
        defer { served.cancel() }
        _ = try await register(client)

        for (id, command) in [("1", "workspace_pause"), ("2", "workspace_resume")] {
            try await sendControl(client, id: id, command: ["type": command])
            let refusal = try await nextError(client)
            guard case .controlError(_, let code, let message) = refusal else {
                Issue.record("expected a control error, got \(refusal)")
                return
            }
            #expect(code == ACPLeaderControlErrorCode.workspaceError)
            #expect(message == "no workspace exposure is running")
        }

        try await sendControl(client, id: "3", command: ["type": "workspace_stop"])
        let stopped = try await nextResult(client)
        guard case .controlResult("3", .workspaceStatus(let status)) = stopped else {
            Issue.record("expected stop to succeed, got \(stopped)")
            return
        }
        #expect(status.state == "none")
    }

    /// `server.rs:1197-1200` — a failed reconnect leaves the exposure paused,
    /// so status keeps reporting the truth.
    @Test("a failed reconnect leaves the exposure paused", .timeLimit(.minutes(1)))
    func resumeFailureKeepsPaused() async throws {
        let connection = FakeExposureConnection()
        let plane = ACPLeaderControlPlane(
            connector: { _, _ in connection }
        )
        let host = makeHost(plane: plane)
        let (client, served) = attach(to: host)
        defer { served.cancel() }
        _ = try await register(client)

        try await sendControl(client, id: "1", command: ["type": "workspace_start", "cwd": "/tmp/proj"])
        _ = try await nextResult(client)
        try await sendControl(client, id: "2", command: ["type": "workspace_pause"])
        _ = try await nextResult(client)

        connection.failReconnects(with: FakeHubError())
        try await sendControl(client, id: "3", command: ["type": "workspace_resume"])
        let refusal = try await nextError(client)
        guard case .controlError("3", let code, let message) = refusal else {
            Issue.record("expected a control error, got \(refusal)")
            return
        }
        #expect(code == ACPLeaderControlErrorCode.workspaceError)
        #expect(message.contains("failed to reconnect to hub"))

        try await sendControl(client, id: "4", command: ["type": "workspace_status"])
        let polled = try await nextResult(client)
        guard case .controlResult("4", .workspaceStatus(let status)) = polled else {
            Issue.record("expected a status, got \(polled)")
            return
        }
        #expect(status.state == "paused")
    }

    /// Uptime comes from the exposure's real start instant
    /// (`server.rs:1161`, :1092), proven with the plane's injected clock so
    /// the assertion is exact rather than timing-tuned.
    @Test("uptime accrues from the start instant, through a pause", .timeLimit(.minutes(1)))
    func uptimeAccrues() async throws {
        let startNanoseconds: UInt64 = 1_000_000_000
        let uptime = MutableUptime()
        let connection = FakeExposureConnection()
        let plane = ACPLeaderControlPlane(
            connector: { _, _ in connection },
            nowNanoseconds: { startNanoseconds + uptime.value }
        )
        let host = makeHost(plane: plane)
        let (client, served) = attach(to: host)
        defer { served.cancel() }
        _ = try await register(client)

        try await sendControl(client, id: "1", command: ["type": "workspace_start", "cwd": "/tmp/proj"])
        _ = try await nextResult(client)

        uptime.advance(milliseconds: 4200)
        try await sendControl(client, id: "2", command: ["type": "workspace_pause"])
        let paused = try await nextResult(client)
        guard case .controlResult("2", .workspaceStatus(let status)) = paused else {
            Issue.record("expected pause to succeed, got \(paused)")
            return
        }
        // Paused time counts: upstream keeps one `Instant` on the exposure.
        #expect(status.uptimeMs == 4200)
    }

    /// `server.rs:975-997` — the discovery payload carries the leader's real
    /// metadata, with this build's profiler facts honestly false.
    @Test("get_leader_info answers with the leader's real metadata", .timeLimit(.minutes(1)))
    func leaderInfo() async throws {
        let plane = ACPLeaderControlPlane(
            metadata: ACPLeaderControlMetadata(
                socketPath: "/tmp/leader.sock",
                lockPath: "/tmp/leader.lock",
                wsURLSuffix: "-abcd1234",
                binaryVersion: "1.2.3"
            )
        )
        let host = makeHost(plane: plane)
        let (client, served) = attach(to: host)
        defer { served.cancel() }
        _ = try await register(client)

        try await sendControl(client, id: "1", command: ["type": "get_leader_info"])
        let reply = try await nextResult(client)
        guard case .controlResult("1", .leaderInfo(let info)) = reply else {
            Issue.record("expected leader_info, got \(reply)")
            return
        }
        #expect(info.socketPath == "/tmp/leader.sock")
        #expect(info.lockPath == "/tmp/leader.lock")
        #expect(info.wsURLSuffix == "-abcd1234")
        #expect(info.leaderProtocolVersion == ACPLeaderProtocolLimits.protocolVersion)
        #expect(info.leaderBinaryVersion == "1.2.3")
        #expect(info.pid == processPID)
        // No profiler exists in this port (`cpu_profile.rs:650-655` compiles
        // one in upstream on unix); both flags stay false.
        #expect(!info.profilingSupported)
        #expect(!info.profilingCompiledIn)
        #expect(!info.cpuProfileActive)
        #expect(!info.cpuProfileStopping)
        #expect(info.profileStartedAt == nil)
        #expect(info.profileFormats.isEmpty)
    }

    /// The commands this build does not implement get a typed refusal with
    /// the request id echoed — while the read-only probes still answer, so
    /// the refusals are scoped, not a blanket "no control plane".
    @Test("cpu profiling and relaunch are typed refusals, never a hang", .timeLimit(.minutes(1)))
    func unsupportedCommandsRefused() async throws {
        let host = makeHost()
        let (client, served) = attach(to: host)
        defer { served.cancel() }
        _ = try await register(client)

        try await client.send(.control(requestID: "1", command: ["type": "start_cpu_profile", "frequency_hz": "250"]))
        let profileRefusal = try await nextError(client)
        guard case .controlError("1", let profileCode, let profileMessage) = profileRefusal else {
            Issue.record("expected a control error, got \(profileRefusal)")
            return
        }
        #expect(profileCode == ACPLeaderControlErrorCode.unsupportedCommand)
        // `cpu_profile.rs:707-709`.
        #expect(profileMessage.contains("not supported in this build"))

        try await sendControl(client, id: "2", command: ["type": "relaunch_for_update", "to_version": "9.9.9"])
        let relaunchRefusal = try await nextError(client)
        guard case .controlError("2", let relaunchCode, let relaunchMessage) = relaunchRefusal else {
            Issue.record("expected a control error, got \(relaunchRefusal)")
            return
        }
        #expect(relaunchCode == ACPLeaderControlErrorCode.unsupportedCommand)
        #expect(relaunchMessage.contains("restart the leader manually"))

        try await sendControl(client, id: "3", command: ["type": "cpu_profile_status"])
        let status = try await nextResult(client)
        guard case .controlResult("3", .cpuProfileStatus(let profile)) = status else {
            Issue.record("expected cpu_profile_status, got \(status)")
            return
        }
        #expect(!profile.active)
        #expect(!profile.stopping)
        #expect(profile.startedAt == nil)
    }
}
