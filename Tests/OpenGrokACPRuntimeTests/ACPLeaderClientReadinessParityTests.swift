import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokHTTP
import Testing

@Suite("ACP leader startup readiness parity")
struct ACPLeaderClientReadinessParityTests {
    @Test("a leader that never acknowledges registration times out and closes")
    func registrationReplyTimesOut() async throws {
        let fixture = LeaderReadinessFixture(registrationTimeoutSeconds: 0.03)
        let client = fixture.client
        let startup = Task { try await client.start() }

        try await fixture.expectRegistration()
        await expectStartupFailure(startup, expected: .registrationTimeout(seconds: 0.03))
        #expect(await client.registration == nil)
        #expect(try await fixture.peer.read() == nil)
    }

    @Test("leader errors and shutdown during initial registration fail closed")
    func terminalRegistrationReplies() async throws {
        let cases: [(ACPLeaderServerMessage, ACPLeaderClientError)] = [
            (
                .error(code: 9, message: "registration refused"),
                .leaderError(code: 9, message: "registration refused")
            ),
            (.shutdown, .unexpectedRegistrationReply("shutdown")),
        ]

        for (reply, expected) in cases {
            let fixture = LeaderReadinessFixture()
            let client = fixture.client
            let startup = Task { try await client.start() }
            try await fixture.expectRegistration()
            try await fixture.send(reply)

            await expectStartupFailure(startup, expected: expected)
            #expect(await client.registration == nil)
            #expect(try await fixture.peer.read() == nil)
        }
    }

    @Test("malformed registration replies fail closed before leader readiness")
    func malformedRegistrationReply() async throws {
        let fixture = LeaderReadinessFixture()
        let client = fixture.client
        let startup = Task { try await client.start() }
        try await fixture.expectRegistration()
        try await fixture.peer.write(
            try ACPLeaderFrameEncoder.encode(Array(#"{"type":"registered""#.utf8))
        )

        do {
            let registration = try await startup.value
            Issue.record("malformed reply unexpectedly registered \(registration.clientID)")
        } catch {
            #expect(!(error is ACPLeaderClientError))
        }
        #expect(await client.registration == nil)
        #expect(try await fixture.peer.read() == nil)
    }

    @Test("cancelling an unanswered registration closes the parked byte-channel read")
    func cancellingRegistrationClosesChannel() async throws {
        let fixture = LeaderReadinessFixture()
        let client = fixture.client
        let startup = Task { try await client.start() }
        try await fixture.expectRegistration()

        startup.cancel()
        do {
            let registration = try await startup.value
            Issue.record("cancelled registration unexpectedly registered \(registration.clientID)")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(await client.registration == nil)
        #expect(try await fixture.peer.read() == nil)
    }

    @Test("an immediately ready registration starts without a readiness frame")
    func immediatelyReadyRegistration() async throws {
        let fixture = LeaderReadinessFixture()
        let client = fixture.client
        let startup = Task { try await client.start() }

        try await fixture.expectRegistration()
        try await fixture.register(ready: true)

        let registration = try await startup.value
        #expect(registration.clientID == 17)
        #expect(registration.ready)
        #expect(registration.protocolVersion == 3)
        #expect(registration.binaryVersion == "leader-readiness")
        await client.close()
    }

    @Test("an initializing leader remains inaccessible until LeaderReady")
    func waitsForDelayedReadiness() async throws {
        let fixture = LeaderReadinessFixture()
        let client = fixture.client
        let startup = Task { try await client.start() }

        try await fixture.expectRegistration()
        try await fixture.register(ready: false)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(await client.registration == nil)

        do {
            try await client.notify(method: "test/premature")
            Issue.record("ACP traffic was accepted before leader readiness")
        } catch let error as ACPLeaderClientError {
            #expect(error == .notStarted)
        }

        try await fixture.send(.leaderReady)
        let registration = try await startup.value
        #expect(registration.ready)
        #expect(await client.registration?.ready == true)
        await client.close()
    }

    @Test("pipelined readiness, duplicate readiness, and ACP preserve frame order")
    func pipelinedFramesUseOnlyOneReader() async throws {
        let fixture = LeaderReadinessFixture()
        let client = fixture.client
        let startup = Task { try await client.start() }

        try await fixture.expectRegistration()
        try await fixture.register(ready: false)

        let notification = ACPMessage.notification(
            method: "test/ready-order",
            params: .object(["value": .string("after-ready")])
        )
        let payload = String(decoding: try notification.encodedData(), as: UTF8.self)
        var pipelined = try ACPLeaderCodec.encode(ACPLeaderServerMessage.leaderReady)
        pipelined.append(contentsOf: try ACPLeaderCodec.encode(ACPLeaderServerMessage.leaderReady))
        pipelined.append(contentsOf: try ACPLeaderCodec.encode(
            ACPLeaderServerMessage.acp(payload: payload)
        ))
        try await fixture.peer.write(pipelined)

        let registration = try await startup.value
        #expect(registration.ready)
        let events = try await client.events()
        var iterator = events.makeAsyncIterator()
        guard case .notification(let method, let params) = try await iterator.next() else {
            Issue.record("the ACP notification following readiness was lost")
            await client.close()
            return
        }
        #expect(method == "test/ready-order")
        #expect(params == .object(["value": .string("after-ready")]))
        await client.close()
    }

    @Test("an initializing leader that never becomes ready times out and closes")
    func neverReadyTimesOut() async throws {
        let fixture = LeaderReadinessFixture(timeoutSeconds: 0.03)
        let client = fixture.client
        let startup = Task { try await client.start() }

        try await fixture.expectRegistration()
        try await fixture.register(ready: false)
        await expectStartupFailure(startup, expected: .readinessTimeout(seconds: 0.03))
        #expect(await client.registration == nil)
        #expect(try await fixture.peer.read() == nil)
    }

    @Test("shutdown, leader errors, and unexpected frames fail readiness closed")
    func terminalReadinessReplies() async throws {
        let cases: [(ACPLeaderServerMessage, ACPLeaderClientError)] = [
            (.shutdown, .registrationClosed),
            (
                .shuttingDown(reason: .autoUpdate, delayMilliseconds: 0),
                .registrationClosed
            ),
            (
                .error(code: 17, message: "leader boot failed"),
                .leaderError(code: 17, message: "leader boot failed")
            ),
            (.pong, .unexpectedRegistrationReply("pong")),
        ]

        for (reply, expected) in cases {
            let fixture = LeaderReadinessFixture()
            let client = fixture.client
            let startup = Task { try await client.start() }
            try await fixture.expectRegistration()
            try await fixture.register(ready: false)
            try await fixture.send(reply)

            await expectStartupFailure(startup, expected: expected)
            #expect(await client.registration == nil)
            #expect(try await fixture.peer.read() == nil)
        }
    }

    @Test("malformed readiness frames fail closed without publishing registration")
    func malformedReadinessFrame() async throws {
        let fixture = LeaderReadinessFixture()
        let client = fixture.client
        let startup = Task { try await client.start() }
        try await fixture.expectRegistration()
        try await fixture.register(ready: false)
        try await fixture.peer.write(
            try ACPLeaderFrameEncoder.encode(Array(#"{"type":"leader_ready""#.utf8))
        )

        do {
            let registration = try await startup.value
            Issue.record("malformed readiness unexpectedly registered \(registration.clientID)")
        } catch {
            #expect(!(error is ACPLeaderClientError))
        }
        #expect(await client.registration == nil)
        #expect(try await fixture.peer.read() == nil)
    }

    @Test("cancelling readiness closes the parked byte-channel read")
    func cancellingReadinessClosesChannel() async throws {
        let fixture = LeaderReadinessFixture(timeoutSeconds: 1)
        let client = fixture.client
        let startup = Task { try await client.start() }
        try await fixture.expectRegistration()
        try await fixture.register(ready: false)
        try await Task.sleep(nanoseconds: 10_000_000)

        startup.cancel()
        do {
            let registration = try await startup.value
            Issue.record("cancelled readiness unexpectedly registered \(registration.clientID)")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(await client.registration == nil)
        #expect(try await fixture.peer.read() == nil)
    }

    @Test("a duplicate start cannot race or abort the active readiness handshake")
    func duplicateStartPreservesOriginalHandshake() async throws {
        let fixture = LeaderReadinessFixture()
        let client = fixture.client
        let startup = Task { try await client.start() }
        try await fixture.expectRegistration()
        try await fixture.register(ready: false)
        try await Task.sleep(nanoseconds: 10_000_000)

        do {
            let registration = try await client.start()
            Issue.record("duplicate startup unexpectedly registered \(registration.clientID)")
        } catch let error as ACPLeaderClientError {
            #expect(error == .alreadyStarted)
        }

        try await fixture.send(.leaderReady)
        let registration = try await startup.value
        #expect(registration.ready)
        await client.close()
    }

    private func expectStartupFailure(
        _ startup: Task<ACPLeaderClientRegistration, Error>,
        expected: ACPLeaderClientError
    ) async {
        do {
            let registration = try await startup.value
            Issue.record("failed readiness unexpectedly registered \(registration.clientID)")
        } catch let error as ACPLeaderClientError {
            #expect(error == expected)
        } catch {
            Issue.record("unexpected startup failure: \(error)")
        }
    }
}

private struct LeaderReadinessFixture: Sendable {
    let client: ACPLeaderClient
    let peer: InMemoryWebSocketChannel
    private let reader: ACPLeaderChannelReader

    init(
        timeoutSeconds: TimeInterval = 1,
        registrationTimeoutSeconds: TimeInterval = 1
    ) {
        let pair = InMemoryWebSocketChannel.makePair()
        client = ACPLeaderClient(
            channel: pair.a,
            clientType: "readiness-client",
            readinessTimeoutSeconds: timeoutSeconds,
            registrationTimeoutSeconds: registrationTimeoutSeconds
        )
        peer = pair.b
        reader = ACPLeaderChannelReader(
            channel: pair.b,
            maximumMessageSize: ACPLeaderProtocolLimits.maximumMessageSize
        )
    }

    func expectRegistration() async throws {
        guard case .register(let clientType, let mode, _) = try await reader.next(
            ACPLeaderClientMessage.self
        ) else {
            throw ACPLeaderProtocolError.invalidJSON("expected exactly one leader registration")
        }
        #expect(clientType == "readiness-client")
        #expect(mode == .stdio)
    }

    func register(ready: Bool) async throws {
        try await send(.registered(
            clientID: 17,
            ready: ready,
            protocolVersion: 3,
            binaryVersion: "leader-readiness",
            capabilities: ACPLeaderCapabilities(controlV1: true)
        ))
    }

    func send(_ message: ACPLeaderServerMessage) async throws {
        try await peer.write(try ACPLeaderCodec.encode(message))
    }
}
