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
            "GROK_SANDBOX": "off",
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

    func exchange(
        method: String,
        params: JSONValue
    ) async throws -> (result: JSONValue?, error: AcpError?) {
        let response = await runtime.handle(.request(
            id: .string(UUID().uuidString),
            method: method,
            params: params
        ))
        guard case .response(_, let result, let error)? = response.last else {
            throw CLIApplicationError.failed("live ACP peer request did not return a response")
        }
        return (result, error)
    }

    func prompt(text: String, messageID: String) async throws -> PromptResponse {
        let response = try await exchange(
            method: AgentMethodNames.sessionPrompt,
            params: JSONValue.encode(PromptRequest(
                sessionId: wireSessionID,
                prompt: [.text(text)],
                messageId: messageID
            ))
        )
        if let error = response.error { throw error }
        guard let result = response.result else {
            throw CLIApplicationError.failed("live ACP peer prompt returned no result")
        }
        return try result.decode(PromptResponse.self)
    }

    func sessionParameters(
        method: String,
        cwd: String,
        additionalDirectories: [String] = [],
        mcpServers: [McpServer] = [],
        meta: AcpMeta? = [:]
    ) throws -> JSONValue {
        switch method {
        case AgentMethodNames.sessionNew:
            return try JSONValue.encode(NewSessionRequest(
                cwd: cwd,
                additionalDirectories: additionalDirectories,
                mcpServers: mcpServers,
                meta: meta
            ))
        case AgentMethodNames.sessionLoad:
            return try JSONValue.encode(LoadSessionRequest(
                sessionId: wireSessionID,
                cwd: cwd,
                mcpServers: mcpServers,
                additionalDirectories: additionalDirectories,
                meta: meta
            ))
        case AgentMethodNames.sessionResume:
            return try JSONValue.encode(ResumeSessionRequest(
                sessionId: wireSessionID,
                cwd: cwd,
                additionalDirectories: additionalDirectories,
                mcpServers: mcpServers,
                meta: meta
            ))
        default:
            throw CLIApplicationError.failed("unsupported ACP peer fixture session method")
        }
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

            let overlap = Task {
                await fixture.runtime.handle(.request(
                    id: .string("overlapping-acp-user-prompt"),
                    method: AgentMethodNames.sessionPrompt,
                    params: try JSONValue.encode(PromptRequest(
                        sessionId: fixture.wireSessionID,
                        prompt: [.text("never start a second provider session turn")],
                        messageId: "forbidden-concurrent-turn"
                    ))
                ))
            }
            let queueDeadline = Date().addingTimeInterval(5)
            var queuedOverlap = false
            while Date() < queueDeadline, !queuedOverlap {
                let notifications = await fixture.runtime.pollNotifications()
                queuedOverlap = notifications.contains { notification in
                    guard notification.method == "x.ai/queue/changed",
                          let entries = notification.params?.objectValue?["entries"]?.arrayValue
                    else { return false }
                    return entries.contains {
                        $0.objectValue?["id"]?.stringValue == "forbidden-concurrent-turn"
                    }
                }
                if !queuedOverlap {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
            }
            #expect(queuedOverlap)
            #expect(await fixture.probe.requests.count == 1)
            overlap.cancel()
            let overlapResponse = try await overlap.value
            guard case .response(_, let overlapPayload?, nil)? = overlapResponse.last else {
                Issue.record("cancelled overlapping ACP prompt did not return a response")
                await fixture.probe.release()
                _ = try await task.value
                return
            }
            #expect(try overlapPayload.decode(PromptResponse.self).stopReason == .cancelled)

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

    @Test(
        "production rejects independent new and forked wire identities without breaking the original peer",
        arguments: [AgentMethodNames.sessionNew, AgentMethodNames.sessionFork]
    )
    func independentWireSessionsCannotShareTheRootDriver(method: String) async throws {
        try await withACPPeerFixture { fixture in
            let params = method == AgentMethodNames.sessionNew
                ? try JSONValue.encode(NewSessionRequest(cwd: fixture.workspace.path))
                : try JSONValue.encode(ForkSessionRequest(sessionId: fixture.wireSessionID))
            let refused = try await fixture.exchange(method: method, params: params)
            #expect(refused.result == nil)
            #expect(refused.error?.code == .invalidParams)
            #expect(refused.error?.message == LiveACPSingleSessionBinding.independentSessionMessage)
            #expect(await !fixture.runtime.sessionExists(AcpSessionId("wire-acp-2")))

            let unknownPrompt = try await fixture.exchange(
                method: AgentMethodNames.sessionPrompt,
                params: JSONValue.encode(PromptRequest(
                    sessionId: AcpSessionId("wire-acp-2"),
                    prompt: [.text("do not inherit the original session's conversation")]
                ))
            )
            #expect(unknownPrompt.result == nil)
            #expect(unknownPrompt.error != nil)
            #expect(await fixture.probe.requests.isEmpty)

            let status = try await fixture.sender.messageSession(
                sessionID: fixture.rootSessionID,
                message: "the original bound peer remains usable"
            )
            #expect(status == .accepted)
            let sampled = try #require(try await fixture.awaitRequests(1).first)
            #expect(sampled.sessionID == fixture.rootSessionID)
            #expect(sampled.prompt.contains("original bound peer remains usable"))
        }
    }

    @Test(
        "same-ID attach restores live peer authority and history with or without metadata after close",
        arguments: [AgentMethodNames.sessionLoad, AgentMethodNames.sessionResume], [false, true]
    )
    func closeRetainsBindingAndSameSessionCanAttach(method: String, includesMetadata: Bool) async throws {
        try await withACPPeerFixture { fixture in
            let gateway = try #require(fixture.components.notificationGateway)
            let firstText = "private context belonging to the original ACP identity"
            let first = try await fixture.prompt(text: firstText, messageID: "before-close")
            #expect(first.stopReason == .endTurn)

            let closed = try await fixture.exchange(
                method: AgentMethodNames.sessionClose,
                params: JSONValue.encode(CloseSessionRequest(sessionId: fixture.wireSessionID))
            )
            #expect(closed.error == nil)
            #expect(closed.result != nil)
            #expect(await !gateway.ownsSession(fixture.wireSessionID))
            let refused = try await fixture.exchange(
                method: AgentMethodNames.sessionNew,
                params: JSONValue.encode(NewSessionRequest(cwd: fixture.workspace.path))
            )
            #expect(refused.result == nil)
            #expect(refused.error?.message == LiveACPSingleSessionBinding.independentSessionMessage)
            #expect(await !fixture.runtime.sessionExists(AcpSessionId("wire-acp-2")))

            let params = try fixture.sessionParameters(
                method: method,
                cwd: fixture.workspace.path,
                meta: includesMetadata ? [:] : nil
            )
            #expect((params["_meta"] != nil) == includesMetadata)
            let attached = try await fixture.exchange(
                method: method,
                params: params
            )
            #expect(attached.error == nil)
            #expect(attached.result != nil)
            #expect(await gateway.ownsSession(fixture.wireSessionID))

            let peerText = "peer wake after closing and reopening the same ACP identity"
            let status = try await fixture.sender.messageSession(
                sessionID: fixture.rootSessionID,
                message: peerText
            )
            #expect(status == .accepted)
            let peerRequests = try await fixture.awaitRequests(2)
            let peer = try #require(peerRequests.first { $0.turnID.hasPrefix("peer-message-") })
            #expect(peer.sessionID == fixture.rootSessionID)
            #expect(peer.items.contains { $0.textContent() == firstText })
            #expect(peer.items.contains { item in
                guard case .user(let user) = item else { return false }
                return user.syntheticReason == .agentMessage && item.textContent().contains(peerText)
            })

            let completionDeadline = Date().addingTimeInterval(5)
            var peerCompleted = false
            while Date() < completionDeadline, !peerCompleted {
                let notifications = await fixture.runtime.pollNotifications()
                peerCompleted = notifications.contains {
                    $0.method == ACPXaiNotificationMethods.promptComplete
                        && $0.params?["promptId"]?.stringValue == peer.turnID
                }
                if !peerCompleted {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
            }
            try #require(peerCompleted)
            let resumed = try await fixture.prompt(
                text: "continue the original conversation",
                messageID: "after-close"
            )
            #expect(resumed.stopReason == .endTurn)
            let requests = await fixture.probe.requests
            #expect(requests.count == 3)
            let latest = try #require(requests.last)
            #expect(latest.items.contains { $0.textContent() == firstText })
            #expect(latest.sessionID == fixture.rootSessionID)
        }
    }

    @Test(
        "production session admission rejects workspace replacement and unsupported root expansion before mutation",
        arguments: [
            AgentMethodNames.sessionNew,
            AgentMethodNames.sessionLoad,
            AgentMethodNames.sessionResume,
        ]
    )
    func workspaceRequestsCannotRebindTheLaunch(method: String) async throws {
        try await withACPPeerFixture { fixture in
            // The record uses the launch resolver's standardized path, which
            // can differ from the raw /private/tmp fixture URL on macOS. Pin
            // that exact original spelling before any hostile request runs.
            let originalDirectory = try liveResolveWorkingDirectory(fixture.workspace.path)
            let originalState = try #require(try SessionDocumentStore(grokHome: fixture.home).load(
                sessionID: fixture.rootSessionID,
                cwd: originalDirectory.path
            ))
            #expect(originalState.summary.cwd == originalDirectory.path)
            let child = fixture.workspace.appendingPathComponent("child", isDirectory: true)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            for cwd in [fixture.sourceWorkspace.path, child.path, "relative-workspace"] {
                let refused = try await fixture.exchange(
                    method: method,
                    params: fixture.sessionParameters(method: method, cwd: cwd)
                )
                #expect(refused.result == nil)
                #expect(refused.error?.code == .invalidParams)
                #expect(refused.error?.message == LiveACPSingleSessionBinding.workspaceMessage)
            }
            if method != AgentMethodNames.sessionResume {
                let refused = try await fixture.exchange(
                    method: method,
                    params: fixture.sessionParameters(
                        method: method,
                        cwd: fixture.workspace.path,
                        additionalDirectories: [fixture.sourceWorkspace.path]
                    )
                )
                #expect(refused.result == nil)
                #expect(refused.error?.message == LiveACPSingleSessionBinding.additionalDirectoriesMessage)
            }
            #expect(await fixture.probe.requests.isEmpty)

            let original = try await fixture.prompt(
                text: "use only the original workspace",
                messageID: "workspace-still-bound"
            )
            #expect(original.stopReason == .endTurn)
            let persisted = try #require(try SessionDocumentStore(grokHome: fixture.home).load(
                sessionID: fixture.rootSessionID,
                cwd: fixture.workspace.path
            ))
            #expect(persisted.summary.cwd == originalState.summary.cwd)
        }
    }

    @Test(
        "production explicitly rejects uninstalled core client MCP transports and preserves the original session",
        arguments: [
            AgentMethodNames.sessionNew,
            AgentMethodNames.sessionLoad,
            AgentMethodNames.sessionResume,
        ]
    )
    func coreClientMCPServersNeverBecomeSilentSnapshotOnlySuccesses(method: String) async throws {
        try await withACPPeerFixture { fixture in
            let servers: [McpServer] = [
                .stdio(McpServerStdio(
                    name: "unsupported-core-stdio",
                    command: fixture.root.appendingPathComponent("never-launch-core-mcp").path
                )),
                .http(McpServerHttp(
                    name: "unsupported-core-http",
                    url: "http://127.0.0.1:1/unsupported-core-mcp"
                )),
                .sse(McpServerSse(
                    name: "unsupported-core-sse",
                    url: "http://127.0.0.1:1/unsupported-core-mcp"
                )),
            ]
            for server in servers {
                let refused = try await fixture.exchange(
                    method: method,
                    params: fixture.sessionParameters(
                        method: method,
                        cwd: fixture.workspace.path,
                        mcpServers: [server],
                        meta: nil
                    )
                )
                #expect(refused.result == nil)
                #expect(refused.error?.code == .invalidParams)
                #expect(refused.error?.message == LiveACPSingleSessionBinding.unsupportedClientMCPServersMessage)
            }
            #expect(await fixture.probe.requests.isEmpty)
            #expect(await !fixture.runtime.sessionExists(AcpSessionId("wire-acp-2")))
            let gateway = try #require(fixture.components.notificationGateway)
            #expect(await gateway.ownsSession(fixture.wireSessionID))

            let original = try await fixture.prompt(
                text: "the original session remains usable without uninstalled MCP tools",
                messageID: "after-core-mcp-refusal"
            )
            #expect(original.stopReason == .endTurn)
            let sampled = try #require(await fixture.probe.requests.first)
            #expect(sampled.sessionID == fixture.rootSessionID)
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
