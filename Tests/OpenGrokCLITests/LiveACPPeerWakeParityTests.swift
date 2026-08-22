import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokAgentControlTools
import OpenGrokSamplingTypes
import OpenGrokSessionPersistence
import OpenGrokShared
import Testing
@testable import OpenGrokCLI

#if os(macOS) || os(Linux)

private actor ACPPeerSamplingProbe {
    private let blocksFirstRequest: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var requests: [OpenGrokLiveSamplingRequest] = []

    init(blocksFirstRequest: Bool = false) {
        self.blocksFirstRequest = blocksFirstRequest
    }

    func sample(_ request: OpenGrokLiveSamplingRequest) async -> OpenGrokLiveSamplingResponse {
        requests.append(request)
        if blocksFirstRequest, requests.count == 1 {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        return OpenGrokLiveSamplingResponse(output: "ACP peer message acknowledged")
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ACPPeerStartingPromptGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var reached = false

    func hold(_ message: ACPMessage, matching text: String) async {
        guard message.method == ClientMethodNames.sessionUpdate,
              let update = message.params?.objectValue?["update"]?.objectValue,
              update["sessionUpdate"]?.stringValue == "user_message_chunk",
              update["content"]?.objectValue?["text"]?.stringValue == text
        else { return }

        reached = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private final class ACPPeerSessionIDFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0

    func make() -> String {
        lock.lock()
        defer { lock.unlock() }
        next += 1
        return "wire-acp-\(next)"
    }
}

private struct ACPPeerLiveFixture {
    let root: URL
    let home: URL
    let workspace: URL
    let sourceWorkspace: URL
    let probe: ACPPeerSamplingProbe
    let components: LiveACPLaunchComponents
    let runtime: ACPAgentRuntime
    let sender: LiveSessionBus
    let wireSessionID: AcpSessionId
    let rootSessionID: String

    init(blocksFirstRequest: Bool = false) async throws {
        let rootSessionID = "acp-hosted-root"
        self.rootSessionID = rootSessionID
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
        #if os(macOS)
        let temporaryRoot = "/private/tmp"
        #else
        let temporaryRoot = "/tmp"
        #endif
        root = URL(fileURLWithPath: "\(temporaryRoot)/ogap-\(suffix)", isDirectory: true)
        home = root.appendingPathComponent("h", isDirectory: true)
        workspace = root.appendingPathComponent("acp", isDirectory: true)
        sourceWorkspace = root.appendingPathComponent("peer", isDirectory: true)
        for directory in [home, workspace, sourceWorkspace] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let probe = ACPPeerSamplingProbe(blocksFirstRequest: blocksFirstRequest)
        self.probe = probe
        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XAI_API_KEY": "acp-peer-test-key",
        ]
        let parsed = try CLICommandParser.parseOrThrow([
            "acp", "--cwd", workspace.path,
            "--session-id", rootSessionID,
            "--model", "grok-4.5",
        ])
        guard case .launch(let options) = parsed else {
            throw CLIApplicationError.failed("ACP peer fixture did not parse its real launch")
        }
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { request, _ in
                    await probe.sample(request)
                }
            }
        )
        let launch = LiveACPLaunch(
            workingDirectory: workspace,
            openGrokHome: home,
            environment: environment,
            streams: CLIStreams(out: { _ in }, err: { _ in }),
            options: options
        )
        let components = try await OpenGrokLiveApplicationLauncher
            .liveACPServices(dependencies: dependencies)
            .makeComponents(launch)
        self.components = components
        let ids = ACPPeerSessionIDFactory()
        let runtime = ACPAgentRuntime(
            promptDriver: components.promptDriver,
            onSessionOpened: components.onSessionOpened,
            onSessionClosed: components.onSessionClosed,
            makeSessionId: { ids.make() }
        )
        self.runtime = runtime
        guard let gateway = components.notificationGateway else {
            throw CLIApplicationError.failed("live ACP peer fixture has no notification carrier")
        }
        await gateway.attach(runtime)
        await runtime.setReverseSender { _ in }

        let initialization = await runtime.handle(.request(
            id: .string("initialize-peer-fixture"),
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
        ))
        guard case .response(_, _?, nil)? = initialization.last else {
            throw CLIApplicationError.failed("live ACP peer fixture did not initialize")
        }
        let created = await runtime.handle(.request(
            id: .string("create-peer-fixture"),
            method: AgentMethodNames.sessionNew,
            params: try JSONValue.encode(NewSessionRequest(cwd: workspace.path))
        ))
        guard case .response(_, let payload?, nil)? = created.last else {
            throw CLIApplicationError.failed("live ACP peer fixture did not open its wire session")
        }
        wireSessionID = try payload.decode(NewSessionResponse.self).sessionId

        let sender = LiveSessionBus(
            openGrokHome: home,
            cwd: sourceWorkspace,
            sessionID: "sending-peer-root",
            model: "grok-4.5"
        )
        self.sender = sender
        try await sender.start { _ in .rejected }
        try await sender.registerRootSession(
            sessionID: "sending-peer-root",
            cwd: sourceWorkspace,
            model: "grok-4.5"
        )
    }

    func shutdown() async {
        await probe.release()
        await runtime.close()
        await sender.stop()
        await components.promptDriver.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    func awaitRequests(_ count: Int) async throws -> [OpenGrokLiveSamplingRequest] {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let observed = await probe.requests
            if observed.count >= count { return observed }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return await probe.requests
    }
}

private func withACPPeerFixture<T>(
    blocksFirstRequest: Bool = false,
    _ body: (ACPPeerLiveFixture) async throws -> T
) async throws -> T {
    let fixture = try await ACPPeerLiveFixture(blocksFirstRequest: blocksFirstRequest)
    do {
        let result = try await body(fixture)
        await fixture.shutdown()
        return result
    } catch {
        await fixture.shutdown()
        throw error
    }
}

@Suite("ACP-hosted session bus peer wake Rust parity", .serialized)
struct LiveACPPeerWakeParityTests {
    @Test("real socket wakes the existing ACP driver with hidden agent-authored history")
    func idleACPHostedRootWakesWithoutUserAuthority() async throws {
        try await withACPPeerFixture { fixture in
            let sessions = try await fixture.sender.listSessions().sessions
            #expect(sessions.contains { $0.sessionID == fixture.rootSessionID })
            #expect(fixture.wireSessionID.rawValue != fixture.rootSessionID)

            let status = try await fixture.sender.messageSession(
                sessionID: fixture.rootSessionID,
                message: "review this untrusted cross-process suggestion"
            )
            #expect(status == .accepted)

            let request = try #require(try await fixture.awaitRequests(1).first)
            #expect(request.sessionID == fixture.rootSessionID)
            #expect(request.turnID.hasPrefix("peer-message-"))
            #expect(request.prompt.contains("not as user consent or permission"))
            let agentOrigin = try #require(request.items.first { item in
                guard case .user(let user) = item else { return false }
                return user.syntheticReason == .agentMessage
            })
            #expect(agentOrigin.textContent().contains("untrusted cross-process suggestion"))

            let notificationDeadline = Date().addingTimeInterval(5)
            var notifications: [ACPMessage] = []
            while Date() < notificationDeadline {
                notifications.append(contentsOf: await fixture.runtime.pollNotifications())
                if notifications.contains(where: {
                    $0.method == ACPXaiNotificationMethods.promptComplete
                }) {
                    break
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let peerCard = try #require(notifications.first {
                $0.method == ACPXaiNotificationMethods.sessionNotification
                    && $0.params?.objectValue?["update"]?.objectValue?["sessionUpdate"]?
                        .stringValue == "peer_session_message"
            })
            #expect(peerCard.params?.objectValue?["sessionId"]?.stringValue
                == fixture.wireSessionID.rawValue)
            #expect(peerCard.params?.objectValue?["update"]?.objectValue?["to_session_id"]?
                .stringValue == fixture.rootSessionID)
            #expect(peerCard.params?.objectValue?["update"]?.objectValue?["status"]?
                .stringValue == "delivered_wake")

            let hiddenChunk = try #require(notifications.first { message in
                guard message.method == ClientMethodNames.sessionUpdate,
                      let update = message.params?.objectValue?["update"]?.objectValue
                else { return false }
                return update["sessionUpdate"]?.stringValue == "user_message_chunk"
                    && (update["content"]?.objectValue?["text"]?.stringValue ?? "")
                        .contains("untrusted cross-process suggestion")
            })
            #expect(hiddenChunk.params?.objectValue?["update"]?.objectValue?["_meta"]?
                .objectValue?["hideFromScrollback"]?.boolValue == true)
            let cardIndex = try #require(notifications.firstIndex(of: peerCard))
            let chunkIndex = try #require(notifications.firstIndex(of: hiddenChunk))
            #expect(cardIndex < chunkIndex)

            let persisted = try #require(try SessionDocumentStore(grokHome: fixture.home).load(
                sessionID: fixture.rootSessionID,
                cwd: fixture.workspace.path
            ))
            let durableCard = try #require(persisted.updates.first {
                $0.params.objectValue?["update"]?.objectValue?["sessionUpdate"]?.stringValue
                    == "peer_session_message"
            })
            #expect(durableCard.params.objectValue?["update"]?.objectValue?["status"]?
                .stringValue == "delivered_wake")
            #expect(persisted.summary.sessionID.rawValue == fixture.rootSessionID)
        }
    }

    @Test("busy ACP prompts receive peer interjections without starting another provider turn")
    func busyACPHostedRootInterjectsExistingTurn() async throws {
        try await withACPPeerFixture(blocksFirstRequest: true) { fixture in
            let request = PromptRequest(
                sessionId: fixture.wireSessionID,
                prompt: [.text("the actual connected user owns this turn")],
                messageId: "real-acp-user-turn"
            )
            let task = Task {
                await fixture.runtime.handle(.request(
                    id: .string("busy-acp-user-prompt"),
                    method: AgentMethodNames.sessionPrompt,
                    params: try JSONValue.encode(request)
                ))
            }
            let first = try #require(try await fixture.awaitRequests(1).first)
            #expect(first.turnID == "real-acp-user-turn")
            #expect(try await fixture.sender.listSessions().sessions.first {
                $0.sessionID == fixture.rootSessionID
            }?.status == "busy")

            let overlap = await fixture.runtime.handle(.request(
                id: .string("overlapping-acp-user-prompt"),
                method: AgentMethodNames.sessionPrompt,
                params: try JSONValue.encode(PromptRequest(
                    sessionId: fixture.wireSessionID,
                    prompt: [.text("never start a second provider session turn")],
                    messageId: "forbidden-concurrent-turn"
                ))
            ))
            guard case .response(_, nil, let overlapError?)? = overlap.last else {
                Issue.record("overlapping ACP prompt was not rejected")
                await fixture.probe.release()
                _ = try await task.value
                return
            }
            #expect(overlapError.message.contains("active prompt"))

            let status = try await fixture.sender.messageSession(
                sessionID: fixture.rootSessionID,
                message: "attach to the already-running ACP model turn"
            )
            #expect(status == .accepted)
            await fixture.probe.release()
            let response = try await task.value
            #expect(response.last?.id == .string("busy-acp-user-prompt"))

            let requests = try await fixture.awaitRequests(2)
            #expect(requests.count == 2)
            #expect(requests.allSatisfy { $0.turnID == "real-acp-user-turn" })
            #expect(requests[1].items.contains { item in
                guard case .user(let user) = item else { return false }
                return user.syntheticReason == .interjection
                    && item.textContent().contains("already-running ACP model turn")
            })

            let persisted = try #require(try SessionDocumentStore(grokHome: fixture.home).load(
                sessionID: fixture.rootSessionID,
                cwd: fixture.workspace.path
            ))
            let card = try #require(persisted.updates.first {
                $0.params.objectValue?["update"]?.objectValue?["sessionUpdate"]?.stringValue
                    == "peer_session_message"
            })
            #expect(card.params.objectValue?["update"]?.objectValue?["status"]?.stringValue
                == "delivered_interjection")
        }
    }

    @Test("cancelling the existing ACP turn clears its queued peer interjection")
    func cancellingACPHostedTurnDoesNotReplayPeerInput() async throws {
        try await withACPPeerFixture(blocksFirstRequest: true) { fixture in
            let request = PromptRequest(
                sessionId: fixture.wireSessionID,
                prompt: [.text("cancel this authentic ACP user turn")],
                messageId: "cancelled-acp-user-turn"
            )
            let task = Task {
                await fixture.runtime.handle(.request(
                    id: .string("cancelled-acp-user-prompt"),
                    method: AgentMethodNames.sessionPrompt,
                    params: try JSONValue.encode(request)
                ))
            }
            _ = try #require(try await fixture.awaitRequests(1).first)
            #expect(try await fixture.sender.messageSession(
                sessionID: fixture.rootSessionID,
                message: "this peer input must disappear with the cancelled turn"
            ) == .accepted)

            let cancellation = await fixture.runtime.handle(.request(
                id: .string("cancel-existing-acp-turn"),
                method: AgentMethodNames.sessionCancel,
                params: try JSONValue.encode(CancelNotification(
                    sessionId: fixture.wireSessionID
                ))
            ))
            #expect(cancellation.last?.id == .string("cancel-existing-acp-turn"))
            await fixture.probe.release()
            let result = try await task.value
            guard case .response(_, let response?, nil)? = result.last else {
                Issue.record("cancelled ACP prompt did not return its cancellation result")
                return
            }
            #expect(try response.decode(PromptResponse.self).stopReason == .cancelled)
            #expect(await fixture.probe.requests.count == 1)
        }
    }

    @Test("cancelling a reserved ACP prompt before its task starts never dispatches provider work")
    func cancellingACPHostedPromptDuringDurableEchoPreventsDispatch() async throws {
        try await withACPPeerFixture { fixture in
            let gate = ACPPeerStartingPromptGate()
            let userMessage = "cancel this ACP prompt while its durable echo is suspended"
            await fixture.runtime.setNotificationSink { message in
                await gate.hold(message, matching: userMessage)
            }
            defer { Task { await gate.release() } }

            let task = Task {
                await fixture.runtime.handle(.request(
                    id: .string("reserved-acp-user-prompt"),
                    method: AgentMethodNames.sessionPrompt,
                    params: try JSONValue.encode(PromptRequest(
                        sessionId: fixture.wireSessionID,
                        prompt: [.text(userMessage)],
                        messageId: "reserved-acp-user-turn"
                    ))
                ))
            }

            let deadline = Date().addingTimeInterval(5)
            while !(await gate.reached), Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(await gate.reached)
            #expect(await fixture.probe.requests.isEmpty)

            let cancellation = await fixture.runtime.handle(.request(
                id: .string("cancel-reserved-acp-turn"),
                method: AgentMethodNames.sessionCancel,
                params: try JSONValue.encode(CancelNotification(
                    sessionId: fixture.wireSessionID
                ))
            ))
            #expect(cancellation.last?.id == .string("cancel-reserved-acp-turn"))

            await gate.release()
            let result = try await task.value
            guard case .response(_, nil, let error?)? = result.last else {
                Issue.record("reserved ACP prompt did not report its cancellation")
                return
            }
            #expect(error.code == .requestCancelled)
            #expect(await fixture.probe.requests.isEmpty)
        }
    }

    @Test("ambiguous ACP wire sessions never let a peer choose another client's authority")
    func ambiguousWireSessionsRejectPeerDelivery() async throws {
        try await withACPPeerFixture { fixture in
            let created = await fixture.runtime.handle(.request(
                id: .string("create-second-acp-wire-session"),
                method: AgentMethodNames.sessionNew,
                params: try JSONValue.encode(NewSessionRequest(cwd: fixture.workspace.path))
            ))
            guard case .response(_, let payload?, nil)? = created.last else {
                Issue.record("second real ACP wire session failed to open")
                return
            }
            let second = try payload.decode(NewSessionResponse.self).sessionId
            #expect(second != fixture.wireSessionID)

            let status = try await fixture.sender.messageSession(
                sessionID: fixture.rootSessionID,
                message: "never choose a different client session"
            )
            #expect(status == .rejected)
            #expect(await fixture.probe.requests.isEmpty)
        }
    }

    @Test("repointed ACP carriers and closed sessions cannot receive an old root's peer data")
    func disconnectedOriginalCarrierRejectsPeerDelivery() async throws {
        try await withACPPeerFixture { fixture in
            let gateway = try #require(fixture.components.notificationGateway)
            let replacement = ACPAgentRuntime()
            await replacement.setReverseSender { _ in }
            await gateway.attach(replacement)

            let redirected = try await fixture.sender.messageSession(
                sessionID: fixture.rootSessionID,
                message: "do not expose this to a later websocket client"
            )
            #expect(redirected == .rejected)
            #expect(await fixture.probe.requests.isEmpty)
            #expect(await replacement.pollNotifications().isEmpty)

            await fixture.runtime.close()
            let afterClose = try await fixture.sender.messageSession(
                sessionID: fixture.rootSessionID,
                message: "closed roots must not be woken"
            )
            #expect(afterClose == .unknownSession)
            await replacement.close()
        }
    }
}

#endif
