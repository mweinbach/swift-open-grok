import Foundation
import OpenGrokACP
import OpenGrokHTTP
import OpenGrokShared
import Testing

@testable import OpenGrokACPRuntime

private struct UpdateRelaunchPromptDriver: ACPPromptDriver {
    func run(
        context: ACPPromptContext,
        emit: @escaping @Sendable (SessionNotification, ACPNotificationDisposition) async -> Void
    ) async throws -> PromptResponse {
        _ = (context, emit)
        return PromptResponse(stopReason: .endTurn)
    }

    func cancel(sessionId: AcpSessionId) async {
        _ = sessionId
    }
}

private actor UpdateRelaunchClient {
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

    func next(timeoutSeconds: Double = 7) async throws -> ACPLeaderServerMessage {
        let deadline = Task { [channel] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await channel.close()
        }
        defer { deadline.cancel() }
        guard let message = try await reader.next(ACPLeaderServerMessage.self) else {
            throw ACPLeaderProtocolError.connectionClosed
        }
        return message
    }

    func register() async throws -> ACPLeaderCapabilities? {
        try await send(
            .register(
                clientType: "grok-pager-update",
                mode: .stdio,
                capabilities: ACPLeaderClientCapabilities()
            )
        )
        guard case .registered(_, _, _, _, let capabilities) = try await next() else {
            throw ACPLeaderProtocolError.connectionClosed
        }
        return capabilities
    }

    func close() async {
        await channel.close()
    }
}

private func attachUpdateRelaunchClient(
    to host: ACPLeaderIPCHost
) -> (client: UpdateRelaunchClient, served: Task<Void, Never>) {
    let channels = InMemoryWebSocketChannel.makePair()
    return (
        UpdateRelaunchClient(channel: channels.b),
        Task { await host.serve(channel: channels.a) }
    )
}

private final class UpdateRelaunchExposure: ACPWorkspaceExposureConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var activeToolCalls: Int
    private var disconnects = 0

    init(activeToolCalls: Int) {
        self.activeToolCalls = activeToolCalls
    }

    var disconnectCount: Int {
        lock.withLock { disconnects }
    }

    func setActiveToolCalls(_ count: Int) {
        lock.withLock {
            activeToolCalls = count
        }
    }

    func snapshot() -> ACPWorkspaceActivitySnapshot {
        lock.withLock {
            ACPWorkspaceActivitySnapshot(
                activeToolCalls: activeToolCalls,
                sessionIDs: ["shared-session"]
            )
        }
    }

    func disconnect() async {
        lock.withLock {
            disconnects += 1
            activeToolCalls = 0
        }
    }

    func reconnect() async throws {}
}

private final class UpdateRelaunchShutdownCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func record() {
        lock.withLock { count += 1 }
    }
}

@Suite("Leader update relaunch parity")
struct ACPLeaderUpdateRelaunchParityTests {
    private func makeHost(
        binaryVersion: String = "1.2.3",
        exposure: UpdateRelaunchExposure? = nil
    ) -> ACPLeaderIPCHost {
        let connector: ACPWorkspaceExposureConnector?
        if let exposure {
            connector = { _, _ in exposure }
        } else {
            connector = nil
        }
        let plane = ACPLeaderControlPlane(
            metadata: ACPLeaderControlMetadata(binaryVersion: binaryVersion),
            connector: connector
        )
        return ACPLeaderIPCHost(
            runtime: ACPAgentRuntime(promptDriver: UpdateRelaunchPromptDriver()),
            configuration: ACPLeaderIPCConfiguration(
                binaryVersion: binaryVersion,
                controlPlane: plane
            )
        )
    }

    private func startExposure(_ client: UpdateRelaunchClient) async throws {
        try await client.send(.control(
            requestID: "workspace",
            command: [
                "type": "workspace_start",
                "hub_url": "wss://hub.example.invalid/v1/tools",
                "cwd": "/workspace",
            ]
        ))
        let response = try await client.next()
        guard case .controlResult("workspace", .workspaceStatus(let status)) = response,
              status.state == "running"
        else {
            Issue.record("expected a running workspace exposure, got \(response)")
            throw ACPLeaderProtocolError.connectionClosed
        }
    }

    @Test("accepted and declined control results match pinned Rust JSON exactly")
    func exactRelaunchControlWire() throws {
        let accepted = try ACPLeaderCodec.encode(
            ACPLeaderServerMessage.controlResult(
                requestID: "update-7",
                payload: .relaunching(
                    fromVersion: "1.2.3",
                    toVersion: "2.0.0",
                    graceMilliseconds: 10_000
                )
            )
        )
        #expect(
            String(decoding: accepted.dropFirst(4), as: UTF8.self)
                == #"{"request_id":"update-7","result":{"Ok":{"from_version":"1.2.3","grace_ms":10000,"to_version":"2.0.0","type":"relaunching"}},"type":"control_result"}"#
        )

        let declined = try ACPLeaderCodec.encode(
            ACPLeaderServerMessage.controlResult(
                requestID: "update-8",
                payload: .relaunchDeclined(reason: "a relaunch is already in progress")
            )
        )
        #expect(
            String(decoding: declined.dropFirst(4), as: UTF8.self)
                == #"{"request_id":"update-8","result":{"Ok":{"reason":"a relaunch is already in progress","type":"relaunch_declined"}},"type":"control_result"}"#
        )
    }

    @Test(arguments: [
        #"{"type":"relaunching","from_version":"1.2.3","to_version":"2.0.0"}"#,
        #"{"type":"relaunching","from_version":"1.2.3","to_version":"2.0.0","grace_ms":-1}"#,
        #"{"type":"relaunching","from_version":"1.2.3","to_version":"2.0.0","grace_ms":"10000"}"#,
        #"{"type":"relaunch_declined"}"#,
        #"{"type":"relaunch_declined","reason":null}"#,
    ])
    func malformedRelaunchPayloadFailsClosed(_ payload: String) {
        #expect(throws: ACPLeaderProtocolError.self) {
            try ACPLeaderCodec.decode(ACPLeaderControlPayload.self, from: Array(payload.utf8))
        }
    }

    @Test(arguments: [
        "1.2.3",
        "1.2.2",
        "0.9.0",
        "1.2.3+different-build",
        "unknown",
        "v2.0.0",
        "1.2.03",
        " 2.0.0",
        "2.0.0 ",
    ])
    func nonNewerOrMalformedVersionsAreDeclined(_ target: String) async {
        let plane = ACPLeaderControlPlane(
            metadata: ACPLeaderControlMetadata(binaryVersion: "1.2.3")
        )
        let outcome = await plane.run([
            "type": "relaunch_for_update",
            "to_version": target,
        ])
        #expect(outcome == .success(.relaunchDeclined(
            reason: "leader version 1.2.3 is not older than \(target)"
        )))
    }

    @Test("an unparseable current version never authorizes a destructive relaunch")
    func unparseableCurrentVersionDeclines() async {
        let plane = ACPLeaderControlPlane(
            metadata: ACPLeaderControlMetadata(binaryVersion: "unknown")
        )
        let outcome = await plane.run([
            "type": "relaunch_for_update",
            "to_version": "9.9.9",
        ])
        #expect(outcome == .success(.relaunchDeclined(
            reason: "leader version unknown is not older than 9.9.9"
        )))
    }

    @Test("strict semantic-version prerelease precedence accepts the final release")
    func prereleaseComparisonIsDirectional() async {
        let plane = ACPLeaderControlPlane(
            metadata: ACPLeaderControlMetadata(binaryVersion: "2.0.0-beta.1")
        )
        let outcome = await plane.run([
            "type": "relaunch_for_update",
            "to_version": "2.0.0",
        ])
        #expect(outcome == .success(.relaunching(
            fromVersion: "2.0.0-beta.1",
            toVersion: "2.0.0",
            graceMilliseconds: 10_000
        )))
    }

    @Test("simultaneous newer requests atomically elect exactly one relaunch")
    func simultaneousRelaunchDecisionsAreAtomic() async {
        let plane = ACPLeaderControlPlane(
            metadata: ACPLeaderControlMetadata(binaryVersion: "1.2.3")
        )
        async let first = plane.run([
            "type": "relaunch_for_update",
            "to_version": "2.0.0",
        ])
        async let second = plane.run([
            "type": "relaunch_for_update",
            "to_version": "3.0.0",
        ])
        let firstOutcome = await first
        let secondOutcome = await second
        let outcomes = [firstOutcome, secondOutcome]
        let accepted = outcomes.filter {
            if case .success(.relaunching) = $0 { return true }
            return false
        }
        let declined = outcomes.filter {
            if case .success(.relaunchDeclined(let reason)) = $0 {
                return reason == "a relaunch is already in progress"
            }
            return false
        }

        #expect(accepted.count == 1)
        #expect(declined.count == 1)
    }

    @Test("the live host sends its exact acceptance ACK before auto-update shutdown", .timeLimit(.minutes(1)))
    func liveAcceptanceAcknowledgesBeforeShutdown() async throws {
        let host = makeHost()
        let shutdowns = UpdateRelaunchShutdownCounter()
        await host.setRelaunchShutdownHandler {
            shutdowns.record()
        }
        let (client, served) = attachUpdateRelaunchClient(to: host)
        defer { served.cancel() }
        let capabilities = try await client.register()
        #expect(capabilities?.relaunchV1 == true)
        #expect(capabilities?.runtimeCPUProfile == false)

        try await client.send(.control(
            requestID: "update-1",
            command: ["type": "relaunch_for_update", "to_version": "2.0.0"]
        ))

        #expect(try await client.next() == .controlResult(
            requestID: "update-1",
            payload: .relaunching(
                fromVersion: "1.2.3",
                toVersion: "2.0.0",
                graceMilliseconds: 10_000
            )
        ))
        #expect(try await client.next() == .shuttingDown(
            reason: .autoUpdate,
            delayMilliseconds: 0
        ))
        #expect(try await client.next() == .shutdown)
        #expect(await host.isStopped())
        for _ in 0..<100 where shutdowns.value == 0 {
            await Task.yield()
        }
        #expect(shutdowns.value == 1)
        await client.close()
    }

    @Test("ordinary host shutdown preserves its manual reason and immediate zero delay", .timeLimit(.minutes(1)))
    func existingManualShutdownRemainsUnchanged() async throws {
        let host = makeHost()
        let (client, served) = attachUpdateRelaunchClient(to: host)
        defer { served.cancel() }
        _ = try await client.register()

        await host.stop()

        #expect(try await client.next() == .shuttingDown(reason: .manual, delayMilliseconds: 0))
        #expect(try await client.next() == .shutdown)
        #expect(await host.isStopped())
        await client.close()
    }

    @Test("declined live updates preserve the shared leader and its control channel", .timeLimit(.minutes(1)))
    func liveDeclinesDoNotStopLeader() async throws {
        let host = makeHost()
        let (client, served) = attachUpdateRelaunchClient(to: host)
        defer { served.cancel() }
        _ = try await client.register()

        for target in ["1.2.3", "1.0.0", "unknown", " 9.9.9"] {
            try await client.send(.control(
                requestID: target,
                command: ["type": "relaunch_for_update", "to_version": target]
            ))
            #expect(try await client.next() == .controlResult(
                requestID: target,
                payload: .relaunchDeclined(
                    reason: "leader version 1.2.3 is not older than \(target)"
                )
            ))
            #expect(await host.isStopped() == false)
        }

        try await client.send(.ping)
        #expect(try await client.next() == .pong)
        await client.close()
    }

    @Test("concurrent clients receive one acceptance, one duplicate decline, and the same shutdown", .timeLimit(.minutes(1)))
    func multipleClientsDeduplicateAcceptedRelaunch() async throws {
        let exposure = UpdateRelaunchExposure(activeToolCalls: 1)
        let host = makeHost(exposure: exposure)
        let (first, firstServed) = attachUpdateRelaunchClient(to: host)
        let (second, secondServed) = attachUpdateRelaunchClient(to: host)
        defer {
            firstServed.cancel()
            secondServed.cancel()
        }
        _ = try await first.register()
        _ = try await second.register()
        try await startExposure(first)

        try await first.send(.control(
            requestID: "first",
            command: ["type": "relaunch_for_update", "to_version": "2.0.0"]
        ))
        #expect(try await first.next() == .controlResult(
            requestID: "first",
            payload: .relaunching(
                fromVersion: "1.2.3",
                toVersion: "2.0.0",
                graceMilliseconds: 10_000
            )
        ))

        try await second.send(.control(
            requestID: "second",
            command: ["type": "relaunch_for_update", "to_version": "3.0.0"]
        ))
        #expect(try await second.next() == .controlResult(
            requestID: "second",
            payload: .relaunchDeclined(reason: "a relaunch is already in progress")
        ))

        exposure.setActiveToolCalls(0)
        for client in [first, second] {
            #expect(try await client.next() == .shuttingDown(
                reason: .autoUpdate,
                delayMilliseconds: 0
            ))
            #expect(try await client.next() == .shutdown)
            await client.close()
        }
        #expect(exposure.disconnectCount == 1)
    }

    @Test("accepted relaunch refuses new ACP work while existing exposure activity drains", .timeLimit(.minutes(1)))
    func relaunchClosesNewRequestAdmission() async throws {
        let exposure = UpdateRelaunchExposure(activeToolCalls: 1)
        let host = makeHost(exposure: exposure)
        let (client, served) = attachUpdateRelaunchClient(to: host)
        defer { served.cancel() }
        _ = try await client.register()
        try await startExposure(client)

        try await client.send(.control(
            requestID: "update",
            command: ["type": "relaunch_for_update", "to_version": "2.0.0"]
        ))
        let acknowledgement = try await client.next()
        guard case .controlResult("update", .relaunching) = acknowledgement else {
            Issue.record("expected an accepted update, got \(acknowledgement)")
            return
        }

        let request = ACPMessage.request(
            id: .number(42),
            method: AgentMethodNames.initialize,
            params: .object([:])
        )
        try await client.send(.acp(
            payload: String(decoding: try request.encodedData(), as: UTF8.self)
        ))
        let refusal = try await client.next()
        guard case .acp(let payload) = refusal,
              case .response(.number(42), nil, let error?) = try ACPMessage(
                  data: Data(payload.utf8)
              )
        else {
            Issue.record("expected a cancelled ACP request, got \(refusal)")
            return
        }
        #expect(error.code == .requestCancelled)

        exposure.setActiveToolCalls(0)
        #expect(try await client.next() == .shuttingDown(
            reason: .autoUpdate,
            delayMilliseconds: 0
        ))
        #expect(try await client.next() == .shutdown)
        await client.close()
    }

    @Test("an indefinitely busy exposure cannot extend the five-second idle grace", .timeLimit(.minutes(1)))
    func busyDrainIsStrictlyBounded() async throws {
        let exposure = UpdateRelaunchExposure(activeToolCalls: 1)
        let host = makeHost(exposure: exposure)
        let (client, served) = attachUpdateRelaunchClient(to: host)
        defer { served.cancel() }
        _ = try await client.register()
        try await startExposure(client)

        try await client.send(.control(
            requestID: "busy",
            command: ["type": "relaunch_for_update", "to_version": "2.0.0"]
        ))
        let acknowledgement = try await client.next()
        guard case .controlResult("busy", .relaunching) = acknowledgement else {
            Issue.record("expected an accepted update, got \(acknowledgement)")
            return
        }
        let began = DispatchTime.now().uptimeNanoseconds

        #expect(try await client.next(timeoutSeconds: 8) == .shuttingDown(
            reason: .autoUpdate,
            delayMilliseconds: 0
        ))
        let elapsed = DispatchTime.now().uptimeNanoseconds - began
        #expect(elapsed >= 4_500_000_000)
        #expect(elapsed < 8_000_000_000)
        #expect(try await client.next() == .shutdown)
        #expect(exposure.disconnectCount == 1)
        await client.close()
    }
}
