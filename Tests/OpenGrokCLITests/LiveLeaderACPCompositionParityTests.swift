import Foundation
import OpenGrokACP
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokHTTP
import OpenGrokShared
import OpenGrokWorkspace
import Testing

@testable import OpenGrokACPRuntime
@testable import OpenGrokCLI

private typealias LeaderCompositionJSON = OpenGrokShared.JSONValue

private actor LeaderCompositionRecorder {
    private(set) var factoryCalls = 0
    private(set) var opened: [AcpSessionId] = []
    private(set) var closed: [AcpSessionId] = []
    private(set) var notifications: [String] = []
    private(set) var remoteDeletions: [String] = []
    private(set) var permissionResults: [String: Bool] = [:]
    private(set) var shutdownCalls = 0

    func built() { factoryCalls += 1 }
    func open(_ session: AcpSessionId) { opened.append(session) }
    func close(_ session: AcpSessionId) { closed.append(session) }
    func notify(_ method: String) { notifications.append(method) }
    func remoteDelete(_ session: String) { remoteDeletions.append(session) }
    func permission(_ marker: String, allowed: Bool) { permissionResults[marker] = allowed }
    func shutdown() { shutdownCalls += 1 }
}

private struct LeaderCompositionPromptDriver: ACPPromptDriver {
    let recorder: LeaderCompositionRecorder
    var permissionPrompter: LiveACPPermissionPrompter?

    func run(
        context: ACPPromptContext,
        emit: @escaping @Sendable (SessionNotification, ACPNotificationDisposition) async -> Void
    ) async throws -> PromptResponse {
        let marker = context.request.prompt.compactMap { block -> String? in
            if case .text(let text) = block { return text.text }
            return nil
        }.joined()
        if let permissionPrompter {
            // LiveACPPromptDriver must propagate this turn's session. Binding
            // it in the fixture would hide a broken production turn seam.
            let decision = await permissionPrompter.prompt(
                access: .edit(URL(fileURLWithPath: context.session.cwd)
                    .appendingPathComponent("private.swift").path),
                toolName: "search_replace",
                toolCallId: marker
            )
            await recorder.permission(marker, allowed: decision.isAllow)
        }
        await emit(
            SessionNotification(
                sessionId: context.session.sessionId,
                update: .agentMessageChunk(ContentChunk(content: .text(TextContent(text: marker))))
            ),
            .durable
        )
        return PromptResponse(stopReason: .endTurn)
    }

    func cancel(sessionId: AcpSessionId) async {}
}

private actor LeaderCompositionInbox {
    private var pending: [ACPMessage] = []
    private var observed: [ACPMessage] = []
    private var ended = false

    func append(_ message: ACPMessage) throws {
        guard observed.count < 256 else {
            throw ACPTransportError.invalidMessage("leader composition inbox exceeded 256 messages")
        }
        pending.append(message)
        observed.append(message)
    }

    func finish() { ended = true }

    func next(
        timeoutSeconds: Double = 5,
        matching predicate: @escaping @Sendable (ACPMessage) -> Bool
    ) async throws -> ACPMessage {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let index = pending.firstIndex(where: predicate) {
                return pending.remove(at: index)
            }
            guard !ended else {
                throw ACPTransportError.invalidMessage("leader composition peer ended before the expected message")
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw ACPTransportError.invalidMessage("leader composition message timed out after \(timeoutSeconds)s")
    }

    func snapshot() -> [ACPMessage] { observed }
    func isFinished() -> Bool { ended }

    func waitUntilFinished() async throws {
        let deadline = Date().addingTimeInterval(5)
        while !ended, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(ended, "leader shutdown left a carrier reader alive")
    }
}

private struct LeaderCompositionLocalPeer: Sendable {
    let client: ACPLeaderClient
    let inbox: LeaderCompositionInbox
    private let reader: Task<Void, Never>

    static func start(_ client: ACPLeaderClient) async throws -> Self {
        let events = try await client.events()
        let inbox = LeaderCompositionInbox()
        let reader = Task {
            do {
                for try await message in events {
                    try await inbox.append(message)
                }
            } catch {}
            await inbox.finish()
        }
        return Self(client: client, inbox: inbox, reader: reader)
    }

    func request(
        method: String,
        params: LeaderCompositionJSON = .object([:])
    ) async throws -> LeaderCompositionJSON {
        let timeout = Task {
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            await client.close()
        }
        defer { timeout.cancel() }
        return try await client.request(method: method, params: params)
    }

    func stop() async {
        reader.cancel()
        await reader.value
    }
}

private actor LeaderCompositionRelayPeer {
    let request: WebSocketHandshakeRequest
    let inbox = LeaderCompositionInbox()
    private let transport: ACPWebSocketConnectionTransport
    private var reader: Task<Void, Never>?
    private var nextID: Int64 = 1

    init(_ connection: WebSocketServerConnection) {
        request = connection.request
        transport = ACPWebSocketConnectionTransport(connection: connection.connection)
    }

    func start() {
        reader = Task { [transport, inbox] in
            do {
                while !Task.isCancelled {
                    let message = try await transport.receive()
                    try await inbox.append(message)
                }
            } catch {}
            await inbox.finish()
        }
    }

    func send(_ message: ACPMessage) async throws {
        try await transport.send(message)
    }

    func call(
        id: AcpRequestId? = nil,
        method: String,
        params: LeaderCompositionJSON = .object([:])
    ) async throws -> LeaderCompositionJSON {
        let requestID = id ?? .number(nextID)
        nextID += 1
        try await send(.request(id: requestID, method: method, params: params))
        let response = try await inbox.next {
            if case .response(let id, _, _) = $0 { return id == requestID }
            return false
        }
        guard case .response(_, let result, let error) = response else {
            throw ACPTransportError.invalidMessage("expected a correlated relay response")
        }
        if let error { throw ACPLeaderClientError.remoteACP(error) }
        return try #require(result)
    }

    func initialize() async throws -> InitializeResponse {
        try await call(
            id: .string("relay-initialize"),
            method: AgentMethodNames.initialize,
            params: try LeaderCompositionJSON.encode(InitializeRequest(protocolVersion: .v1))
        ).decode(InitializeResponse.self)
    }

    func newSession(cwd: String) async throws -> AcpSessionId {
        try await call(
            method: AgentMethodNames.sessionNew,
            params: try LeaderCompositionJSON.encode(NewSessionRequest(cwd: cwd))
        ).decode(NewSessionResponse.self).sessionId
    }

    func close() async {
        await transport.close()
        reader?.cancel()
        await reader?.value
        reader = nil
    }
}

private actor LeaderCompositionRelay {
    private let server: WebSocketServer
    private var peers: [LeaderCompositionRelayPeer] = []
    private var accepting: Task<Void, Never>?

    init() {
        server = WebSocketServer(configuration: WebSocketServerConfiguration(
            host: "127.0.0.1",
            port: 0,
            policy: WebSocketUpgradePolicy(
                path: "/ws",
                authorize: { $0.bearerToken == "PRIVATE_LEADER_FIRST_PARTY_TOKEN" }
            )
        ))
    }

    func start() async throws -> String {
        let port = try await server.start()
        let connections = await server.connections
        accepting = Task { [weak self] in
            for await connection in connections {
                await self?.accept(connection)
            }
        }
        return "ws://127.0.0.1:\(port)/ws"
    }

    private func accept(_ connection: WebSocketServerConnection) async {
        let peer = LeaderCompositionRelayPeer(connection)
        await peer.start()
        peers.append(peer)
    }

    func peer(_ index: Int = 0) async throws -> LeaderCompositionRelayPeer {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if peers.count > index { return peers[index] }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ACPTransportError.invalidMessage("authenticated leader relay connection \(index) timed out")
    }

    func stop() async {
        accepting?.cancel()
        await server.stop()
        await accepting?.value
        accepting = nil
        for peer in peers { await peer.close() }
    }

    func connectionCount() -> Int { peers.count }

    func expectLeaderDisconnected() async throws {
        for peer in peers {
            try await peer.inbox.waitUntilFinished()
        }
    }
}

private func withLeaderCompositionRelay<T>(
    _ body: (LeaderCompositionFixture, LeaderCompositionRelay) async throws -> T
) async throws -> T {
    let relay = LeaderCompositionRelay()
    let url = try await relay.start()
    let fixture: LeaderCompositionFixture
    do {
        fixture = try LeaderCompositionFixture(relayURL: url, relayOnDemand: false)
    } catch {
        await relay.stop()
        throw error
    }
    do {
        try fixture.installFirstPartyAccount()
        let result = try await body(fixture, relay)
        await relay.stop()
        fixture.cleanup()
        return result
    } catch {
        await relay.stop()
        fixture.cleanup()
        throw error
    }
}

private func leaderCompositionPrompt(_ session: AcpSessionId, marker: String) throws -> LeaderCompositionJSON {
    try LeaderCompositionJSON.encode(PromptRequest(
        sessionId: session,
        prompt: [.text(TextContent(text: marker))]
    ))
}

private func expectLeaderPromptUpdate(
    _ inbox: LeaderCompositionInbox,
    session: AcpSessionId,
    marker: String
) async throws {
    let message = try await inbox.next {
        $0.method == ClientMethodNames.sessionUpdate
            && $0.params?["sessionId"]?.stringValue == session.rawValue
            && $0.params?["update"]?["content"]?["text"]?.stringValue == marker
    }
    let update = try #require(message.params).decode(SessionNotification.self)
    #expect(update.sessionId == session)
}

private func expectLeaderMarkerAbsent(
    _ marker: String,
    from inbox: LeaderCompositionInbox
) async throws {
    let messages = await inbox.snapshot()
    let wire = try messages.map {
        String(decoding: try $0.encodedData(), as: UTF8.self)
    }.joined(separator: "\n")
    #expect(!wire.contains(marker))
}

private func expectLeaderGatewayMarker(
    _ inbox: LeaderCompositionInbox,
    session: AcpSessionId,
    marker: String
) async throws {
    let message = try await inbox.next {
        $0.method == ACPXaiNotificationMethods.sessionNotification
            && $0.params?["sessionId"]?.stringValue == session.rawValue
            && $0.params?["update"]?["marker"]?.stringValue == marker
    }
    #expect(message.params?["_meta"]?["eventId"]?.stringValue?.hasPrefix(session.rawValue) == true)
}

private func leaderCompositionApproval(
    _ message: ACPMessage,
    session: AcpSessionId,
    marker: String,
    optionID: String = "allow-once"
) throws -> ACPMessage {
    guard case .request(let id, let method, let params) = message else {
        throw ACPTransportError.invalidMessage("expected a reverse permission request")
    }
    #expect(method == ClientMethodNames.sessionRequestPermission)
    let request = try params.decode(RequestPermissionRequest.self)
    #expect(request.sessionId == session)
    #expect(request.toolCall.toolCallId.rawValue == marker)
    #expect(request.options.contains { $0.optionId.rawValue == optionID })
    return .response(
        id: id,
        result: try LeaderCompositionJSON.encode(RequestPermissionResponse(
            outcome: .selected(SelectedPermissionOutcome(optionId: PermissionOptionId(optionID)))
        )),
        error: nil
    )
}

private func approveLeaderLocalPrompt(
    _ local: LeaderCompositionLocalPeer,
    session: AcpSessionId,
    marker: String,
    foreignPeer: LeaderCompositionRelayPeer? = nil
) async throws {
    let prompt = Task {
        try await local.request(
            method: AgentMethodNames.sessionPrompt,
            params: leaderCompositionPrompt(session, marker: marker)
        ).decode(PromptResponse.self)
    }
    defer { prompt.cancel() }
    let request = try await local.inbox.next {
        $0.method == ClientMethodNames.sessionRequestPermission
            && $0.params?["toolCall"]?["toolCallId"]?.stringValue == marker
    }
    if let foreignPeer {
        try await foreignPeer.send(leaderCompositionApproval(
            request,
            session: session,
            marker: marker,
            optionID: "reject-once"
        ))
        let barrier = try await foreignPeer.call(method: "x.ai/session/list")
        #expect(barrier["result"]?["sessions"]?.arrayValue != nil)
    }
    try await local.client.forward(leaderCompositionApproval(request, session: session, marker: marker))
    let response = try await prompt.value
    #expect(response.stopReason == .endTurn)
    try await expectLeaderPromptUpdate(local.inbox, session: session, marker: marker)
}

private func approveLeaderRelayPrompt(
    _ remote: LeaderCompositionRelayPeer,
    session: AcpSessionId,
    marker: String
) async throws {
    let prompt = Task {
        try await remote.call(
            method: AgentMethodNames.sessionPrompt,
            params: leaderCompositionPrompt(session, marker: marker)
        ).decode(PromptResponse.self)
    }
    defer { prompt.cancel() }
    let request = try await remote.inbox.next {
        $0.method == ClientMethodNames.sessionRequestPermission
            && $0.params?["toolCall"]?["toolCallId"]?.stringValue == marker
    }
    try await remote.send(leaderCompositionApproval(request, session: session, marker: marker))
    let response = try await prompt.value
    #expect(response.stopReason == .endTurn)
    try await expectLeaderPromptUpdate(remote.inbox, session: session, marker: marker)
}

private func expectLeaderSessionRefused(
    _ target: AcpSessionId,
    operation: () async throws -> LeaderCompositionJSON
) async throws {
    do {
        let result = try await operation()
        Issue.record("foreign session operation unexpectedly succeeded: \(result)")
    } catch let error as ACPLeaderClientError {
        guard case .remoteACP(let response) = error else { throw error }
        #expect(response == ACPRuntimeError.sessionNotFound(target).acpError)
    }
}

private func expectLeaderLifecycleClosed(_ recorder: LeaderCompositionRecorder, sessions: Int) async {
    let opened = await recorder.opened
    let closed = await recorder.closed
    #expect(opened.count == sessions)
    #expect(Set(opened).count == sessions)
    #expect(closed.count == sessions)
    #expect(Set(closed) == Set(opened))
    #expect(await recorder.factoryCalls == 1)
    #expect(await recorder.shutdownCalls == 1)
}

private func finishLeaderCompositionRun(_ running: Task<Void, any Error>) async {
    switch await running.result {
    case .success:
        break
    case .failure(let error):
        if !(error is CancellationError) {
            Issue.record("leader run failed during cleanup: \(error)")
        }
    }
}

private struct LeaderCompositionNotificationHandler: ACPAgentExtensionNotificationHandler {
    let recorder: LeaderCompositionRecorder

    func handle(method: String, params: LeaderCompositionJSON) async {
        await recorder.notify(method)
    }
}

private struct LeaderCompositionFixture: Sendable {
    let root: URL
    let home: URL
    let workspace: URL
    let relayURL: String
    let relayOnDemand: Bool

    init(relayURL: String? = nil, relayOnDemand: Bool = true) throws {
        self.relayURL = relayURL ?? "wss://leader-regression.invalid/ws"
        self.relayOnDemand = relayOnDemand
        #if os(Windows)
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "olc-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        #else
        root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
            "olc-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        #endif
        home = root.appendingPathComponent("h", isDirectory: true)
        workspace = root.appendingPathComponent("w", isDirectory: true)
        #if os(Windows)
        try OpenGrokConfig.createDirAllOwnerOnly(root, stateRoot: root)
        try OpenGrokConfig.createDirAllOwnerOnly(home, stateRoot: home)
        try OpenGrokConfig.createDirAllOwnerOnly(workspace, stateRoot: root)
        #else
        for directory in [root, home, workspace] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        #endif
    }

    var environment: [String: String] {
        [
            "HOME": root.path,
            "OPENGROK_HOME": home.path,
            "PWD": workspace.path,
            "GROK_MANAGED_CONFIG": "false",
            "GROK_SANDBOX": "off",
            "GROK_SESSION_REGISTRY": "true",
            "GROK_WS_URL": relayURL,
        ]
    }

    func installFirstPartyAccount() throws {
        let account = GrokAuth(
            key: "PRIVATE_LEADER_FIRST_PARTY_TOKEN",
            authMode: .oidc,
            userID: "leader-owner",
            principalID: "leader-principal",
            teamID: "leader-team",
            organizationID: "leader-organization",
            codingDataRetentionOptOut: false,
            refreshToken: "PRIVATE_LEADER_REFRESH_TOKEN",
            expiresAt: Date().addingTimeInterval(3_600),
            oidcIssuer: "https://auth.x.ai"
        )
        let configuration = liveManagedAuthenticationConfiguration(environment: environment)
        try writeAuthJSON(
            at: home.appendingPathComponent("auth.json"),
            store: [configuration.authScope: account]
        )
    }

    func seed(_ id: String = "durable-leader-session") async throws {
        var record = LiveConversationRecord.new(
            sessionID: id,
            workingDirectory: workspace
        )
        record.title = "Durable leader history"
        record.currentModelID = "grok-leader"
        record.items = [.user("PRIVATE_LEADER_TRANSCRIPT")]
        try await LiveConversationStore(openGrokHome: home).save(record)
    }

    func registryResponse(id: String = "remote-leader-session") throws -> MockHTTPTransport.ScriptedResponse {
        let body: [String: Any] = [
            "sessions": [[
                "sessionId": id,
                "summary": "Owner-private remote metadata",
                "firstPrompt": "First remote leader prompt",
                "modelId": "grok-code-fast-1",
                "createdAt": "2026-08-25T12:00:00Z",
                "updatedAt": "2026-08-25T12:05:00Z",
                "lastTurnNumber": 2,
                "cwd": workspace.path,
                "hostname": "owner-machine",
                "status": "active",
                "gcsTracePrefix": "PRIVATE_LEADER_TRACE_LOCATION",
                "gcsBucket": "PRIVATE_LEADER_BUCKET",
            ]],
        ]
        return MockHTTPTransport.ScriptedResponse(
            metadata: HTTPResponseMetadata(statusCode: 200),
            body: try JSONSerialization.data(withJSONObject: body)
        )
    }

    func components(
        recorder: LeaderCompositionRecorder,
        gateway: ACPNotificationGateway = ACPNotificationGateway(),
        permissionPrompter: LiveACPPermissionPrompter? = nil,
        promptDriver: any ACPPromptDriver = ACPNoopPromptDriver(),
        transport: any HTTPTransport = MockHTTPTransport(),
        remoteDelete: (@Sendable (String) async throws -> Void)? = nil
    ) -> LiveACPServices {
        LiveACPServices(makeComponents: { launch in
            await recorder.built()
            let router = LiveACPExtensionRouter.build(
                feedback: nil,
                models: LiveModelsACPHandler(
                    catalogStore: LiveModelCatalogStore(
                        input: .default,
                        environment: launch.environment,
                        openGrokHome: launch.openGrokHome,
                        transport: MockHTTPTransport()
                    ),
                    modelSwitch: nil
                ),
                sessionAdmin: LiveSessionAdminACPHandler(
                    openGrokHome: launch.openGrokHome,
                    gateway: gateway,
                    remoteDelete: remoteDelete
                ),
                persistentSessions: LivePersistentSessionACPHandler(
                    openGrokHome: launch.openGrokHome,
                    gateway: gateway,
                    environment: launch.environment,
                    workingDirectory: launch.workingDirectory,
                    transport: transport
                )
            )
            let notifications = ACPExtensionNotificationRouter().register(
                exact: "x.ai/leader-regression/notification",
                handler: LeaderCompositionNotificationHandler(recorder: recorder)
            )
            return LiveACPLaunchComponents(
                promptDriver: LiveACPPromptDriver(
                    driver: promptDriver,
                    permissionPrompter: permissionPrompter,
                    shutdown: { await recorder.shutdown() }
                ),
                extensionHandler: router,
                extensionNotifications: notifications,
                notificationGateway: gateway,
                permissionPrompter: permissionPrompter,
                onSessionOpened: { session, _ in await recorder.open(session) },
                onSessionClosed: { session in await recorder.close(session) }
            )
        })
    }

    func withLeader<T>(
        services: LiveACPServices,
        createOwnerSession: Bool = true,
        body: (ACPLeaderClient, InitializeResponse, AcpSessionId?) async throws -> T
    ) async throws -> T {
        let context = CLIApplicationContext(
            environment: environment,
            streams: CLIStreams(out: { _ in }, err: { _ in }),
            control: .never
        )
        let session = try await LiveLeaderComposition.session(
            for: .leader(CLILeaderOptions(
                common: CLICommonOptions(cwd: workspace.path),
                relayOnDemand: relayOnDemand
            )),
            context: context,
            services: services
        )
        let running = Task { try await session.waitForExit() }
        let paths = ACPLeaderSocketPaths.resolve(
            openGrokHome: home,
            relayURL: relayURL,
            environment: environment
        )
        var peer: ACPLeaderClient?
        do {
            let channel = try await ACPLeaderSocketDialer.connect(
                path: paths.socket,
                timeoutSeconds: 5
            )
            let client = ACPLeaderClient(
                channel: channel,
                clientType: "leader-acp-parity",
                mode: .stdio
            )
            peer = client
            let timeout = Task {
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                Issue.record("leader composition fixture exceeded its 30-second request deadline")
                await client.close()
            }
            defer { timeout.cancel() }
            let registration = try await client.start()
            guard registration.ready else {
                throw CLIApplicationError.failed("leader ACP parity client was not ready")
            }
            let initialized = try await client.request(
                method: AgentMethodNames.initialize,
                params: try LeaderCompositionJSON.encode(InitializeRequest(protocolVersion: .v1))
            ).decode(InitializeResponse.self)
            let ownerSessionID: AcpSessionId?
            if createOwnerSession {
                ownerSessionID = try await client.request(
                    method: AgentMethodNames.sessionNew,
                    params: try LeaderCompositionJSON.encode(NewSessionRequest(
                        cwd: workspace.path
                    ))
                ).decode(NewSessionResponse.self).sessionId
            } else {
                ownerSessionID = nil
            }
            let value = try await body(client, initialized, ownerSessionID)
            await client.close()
            await session.shutdown()
            running.cancel()
            await finishLeaderCompositionRun(running)
            return value
        } catch {
            if let peer { await peer.close() }
            await session.shutdown()
            running.cancel()
            await finishLeaderCompositionRun(running)
            throw error
        }
    }

    func withObservedLeader<T>(
        services: LiveACPServices,
        body: (LeaderCompositionLocalPeer, InitializeResponse, AcpSessionId) async throws -> T
    ) async throws -> T {
        try await withLeader(services: services) { client, initialized, session in
            let local = try await LeaderCompositionLocalPeer.start(client)
            do {
                let result = try await body(local, initialized, #require(session))
                await local.stop()
                #expect(await local.inbox.isFinished())
                return result
            } catch {
                await local.stop()
                throw error
            }
        }
    }

    func cleanup() {
        LiveManagedPolicyLifecycle.stop(environment: environment)
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Leader ACP carrier composition parity", .serialized)
struct LiveLeaderACPCompositionParityTests {
    @Test("registered carriers cannot list durable sessions before they own a live driver session")
    func sessionlessCarrierCannotReadDurableHistory() async throws {
        let fixture = try LeaderCompositionFixture()
        defer { fixture.cleanup() }
        try await fixture.seed()
        let recorder = LeaderCompositionRecorder()

        try await fixture.withLeader(
            services: fixture.components(recorder: recorder),
            createOwnerSession: false
        ) { client, _, owner in
            #expect(owner == nil)
            do {
                _ = try await client.request(method: "x.ai/session/list")
                Issue.record("the leader disclosed durable sessions to a carrier without a driver")
            } catch let error as ACPLeaderClientError {
                guard case .remoteACP(let response) = error else {
                    Issue.record("unexpected sessionless leader error: \(error)")
                    return
                }
                #expect(response.code == .authRequired)
            }
            #expect(await recorder.opened.isEmpty)
        }
    }

    @Test("one complete launch factory exposes durable extension and core list over the real leader socket")
    func durableSessionListingCrossesActualLeaderSocket() async throws {
        let fixture = try LeaderCompositionFixture()
        defer { fixture.cleanup() }
        try await fixture.seed()
        let recorder = LeaderCompositionRecorder()

        try await fixture.withLeader(services: fixture.components(recorder: recorder)) { client, initialized, owner in
            #expect(initialized.meta?["currentWorkingDirectory"]?.stringValue == fixture.workspace.path)
            #expect(initialized.agentCapabilities.promptCapabilities.embeddedContext)
            #expect(owner != nil)

            let extensionResult = try await client.request(method: "x.ai/session/list")
            #expect(extensionResult["result"]?["sessions"]?[0]?["sessionId"]?.stringValue
                == "durable-leader-session")

            let coreResult = try await client.request(method: AgentMethodNames.sessionList)
            #expect(coreResult["sessions"]?[0]?["sessionId"]?.stringValue
                == "durable-leader-session")
        }

        #expect(await recorder.factoryCalls == 1)
    }

    @Test("an authenticated remote registry row is reachable over both real leader ACP list routes")
    func authenticatedRegistryCrossesLeaderSocket() async throws {
        let fixture = try LeaderCompositionFixture()
        defer { fixture.cleanup() }
        try fixture.installFirstPartyAccount()
        let transport = MockHTTPTransport(responses: [
            try fixture.registryResponse(),
            try fixture.registryResponse(),
        ])
        let recorder = LeaderCompositionRecorder()

        try await fixture.withLeader(services: fixture.components(
            recorder: recorder,
            transport: transport
        )) { client, _, owner in
            #expect(owner != nil)
            let extensionResult = try await client.request(method: "x.ai/session/list")
            let row = try #require(extensionResult["result"]?["sessions"]?.arrayValue?.first)
            #expect(row["sessionId"]?.stringValue == "remote-leader-session")
            #expect(row["source"]?.stringValue == "remote")
            #expect(row["gcsTracePrefix"] == nil)
            #expect(row["gcsBucket"] == nil)

            let coreResult = try await client.request(method: AgentMethodNames.sessionList)
            #expect(coreResult["sessions"]?[0]?["sessionId"]?.stringValue
                == "remote-leader-session")
        }

        #expect(transport.recordedRequests.count == 2)
        #expect(transport.recordedRequests.allSatisfy {
            $0.url.query == "limit=300"
                && $0.headers["Authorization"] == "Bearer PRIVATE_LEADER_FIRST_PARTY_TOKEN"
        })
    }

    @Test("session lifecycle hooks and their exact owner gateway survive the leader carrier")
    func sessionHooksAndGatewayUseOneRuntime() async throws {
        let fixture = try LeaderCompositionFixture()
        defer { fixture.cleanup() }
        let recorder = LeaderCompositionRecorder()
        let gateway = ACPNotificationGateway()

        try await fixture.withLeader(services: fixture.components(
            recorder: recorder,
            gateway: gateway
        ), createOwnerSession: false) { client, initialized, owner in
            #expect(owner == nil)
            #expect(await gateway.hasConnectedRuntime())
            #expect(initialized.meta?["x.ai/mcp/sdk"]?.boolValue == true)

            let created = try await client.request(
                method: AgentMethodNames.sessionNew,
                params: try LeaderCompositionJSON.encode(NewSessionRequest(
                    cwd: fixture.workspace.path
                ))
            ).decode(NewSessionResponse.self)
            #expect(await recorder.opened == [created.sessionId])
            #expect(!(await gateway.ownsConnectedSession(created.sessionId)))
            let registration = try #require(await client.registration)
            let ownsConnectedSession = await ACPLeaderRequestAuthority.$clientID.withValue(
                String(registration.clientID)
            ) {
                await gateway.ownsConnectedSession(created.sessionId)
            }
            #expect(ownsConnectedSession)
            let foreignCarrierOwnsSession = await ACPLeaderRequestAuthority.$clientID.withValue(
                "foreign-carrier"
            ) {
                await gateway.ownsConnectedSession(created.sessionId)
            }
            #expect(!foreignCarrierOwnsSession)

            let response = try await client.request(
                method: AgentMethodNames.sessionClose,
                params: try LeaderCompositionJSON.encode(CloseSessionRequest(
                    sessionId: created.sessionId
                ))
            )
            #expect(response.objectValue != nil)
            #expect(await recorder.closed == [created.sessionId])
            #expect(!(await gateway.ownsSession(created.sessionId)))
        }
    }

    @Test("leader shutdown closes still-open session lifecycle hooks before its prompt stack")
    func shutdownClosesRemainingSessionLifecycles() async throws {
        let fixture = try LeaderCompositionFixture()
        defer { fixture.cleanup() }
        let recorder = LeaderCompositionRecorder()
        let sessionID = try await fixture.withLeader(
            services: fixture.components(recorder: recorder),
            createOwnerSession: false
        ) { client, _, owner in
            #expect(owner == nil)
            return try await client.request(
                method: AgentMethodNames.sessionNew,
                params: try LeaderCompositionJSON.encode(NewSessionRequest(
                    cwd: fixture.workspace.path
                ))
            ).decode(NewSessionResponse.self).sessionId
        }

        #expect(await recorder.opened == [sessionID])
        #expect(await recorder.closed == [sessionID])
    }

    @Test("inbound extension notifications are delivered to the complete leader runtime")
    func extensionNotificationsReachLeaderRuntime() async throws {
        let fixture = try LeaderCompositionFixture()
        defer { fixture.cleanup() }
        let recorder = LeaderCompositionRecorder()

        try await fixture.withLeader(services: fixture.components(recorder: recorder)) { client, _, owner in
            let sessionID = try #require(owner)
            try await client.notify(
                method: "x.ai/leader-regression/notification",
                params: .object(["sessionId": .string(sessionID.rawValue)])
            )
            for _ in 0..<50 {
                if await !recorder.notifications.isEmpty { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(await recorder.notifications == ["x.ai/leader-regression/notification"])
        }
    }

    @Test("unregistered extension methods preserve the exact typed ACP method-not-found error")
    func unknownExtensionRemainsRefused() async throws {
        let fixture = try LeaderCompositionFixture()
        defer { fixture.cleanup() }
        let recorder = LeaderCompositionRecorder()

        try await fixture.withLeader(services: fixture.components(recorder: recorder)) { client, _, owner in
            #expect(owner != nil)
            do {
                _ = try await client.request(method: "x.ai/leader-regression/nonexistent")
                Issue.record("the leader unexpectedly registered an absent extension")
            } catch let error as ACPLeaderClientError {
                guard case .remoteACP(let response) = error else {
                    Issue.record("unexpected leader extension error: \(error)")
                    return
                }
                #expect(response.code == .methodNotFound)
            }
        }
    }

    @Test("writeback session deletion runs before local mutation through the real leader socket")
    func authenticatedRemoteDeletionCrossesLeaderSocket() async throws {
        let fixture = try LeaderCompositionFixture()
        defer { fixture.cleanup() }
        try fixture.installFirstPartyAccount()
        try await fixture.seed("deletable-leader-session")
        let backend = MockHTTPTransport(responses: [MockHTTPTransport.ScriptedResponse(
            metadata: HTTPResponseMetadata(statusCode: 200),
            body: Data("{}".utf8)
        )])
        var backendEnvironment = fixture.environment
        backendEnvironment["GROK_CODE_BACKEND_URL"] = "http://127.0.0.1:48921"
        let administration = LiveACPSessionRemoteAdministration(
            home: fixture.home,
            environment: backendEnvironment,
            storageMode: .writeback,
            transport: backend
        )
        let recorder = LeaderCompositionRecorder()

        try await fixture.withLeader(services: fixture.components(
            recorder: recorder,
            remoteDelete: { id in
                try await administration.deleteIfEligible(sessionID: id)
            }
        )) { client, _, owner in
            #expect(owner != nil)
            let result = try await client.request(
                method: "x.ai/session/delete",
                params: .object([
                    "sessionId": .string("deletable-leader-session"),
                    "cwd": .string(fixture.workspace.path),
                ])
            )
            #expect(result == .object(["success": .bool(true)]))
        }

        let deletion = try #require(backend.recordedRequests.first)
        #expect(deletion.method == .delete)
        #expect(deletion.url.absoluteString
            == "http://127.0.0.1:48921/sessions/deletable-leader-session/data")
        #expect(deletion.headers["Authorization"] == "Bearer PRIVATE_LEADER_FIRST_PARTY_TOKEN")
        #expect(try await LiveConversationStore(openGrokHome: fixture.home)
            .loadIfPresent(sessionID: "deletable-leader-session") == nil)
    }

    @Test("leader reverse permissions reach only the session-owning IPC client and deny without an answer")
    func reversePermissionUsesAttachedLeaderRuntime() async throws {
        let fixture = try LeaderCompositionFixture()
        defer { fixture.cleanup() }
        let recorder = LeaderCompositionRecorder()
        let prompter = LiveACPPermissionPrompter(timeoutSeconds: 0.5)

        try await fixture.withLeader(services: fixture.components(
            recorder: recorder,
            permissionPrompter: prompter
        ), createOwnerSession: false) { client, _, owner in
            #expect(owner == nil)
            let created = try await client.request(
                method: AgentMethodNames.sessionNew,
                params: try LeaderCompositionJSON.encode(NewSessionRequest(
                    cwd: fixture.workspace.path
                ))
            ).decode(NewSessionResponse.self)
            await prompter.bindSession(created.sessionId)
            let events = try await client.events()
            let timeout = Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                await client.close()
            }
            defer { timeout.cancel() }

            let decision = Task {
                await prompter.prompt(
                    access: .edit(fixture.workspace.appendingPathComponent("private.swift").path),
                    toolName: "search_replace",
                    toolCallId: "leader-private-call"
                )
            }
            var observed = false
            for try await event in events {
                guard case .request(_, let method, let params) = event,
                      method == ClientMethodNames.sessionRequestPermission
                else { continue }
                #expect(params["sessionId"]?.stringValue == created.sessionId.rawValue)
                #expect(params["toolCall"]?["toolCallId"]?.stringValue == "leader-private-call")
                observed = true
                break
            }

            #expect(observed)
            #expect(!(await decision.value.isAllow))
        }
    }

    @Test("the genuine liveACPServices production router survives leader transport without recreating an agent")
    func genuineProductionComponentsReachLeaderCarrier() async throws {
        let fixture = try LeaderCompositionFixture()
        defer { fixture.cleanup() }
        try fixture.installFirstPartyAccount()
        try await fixture.seed()
        let transport = MockHTTPTransport()
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { _, _ in
                    OpenGrokLiveSamplingResponse(output: "unused leader composition sampler")
                }
            },
            makeImageTransport: { transport }
        )
        let services = OpenGrokLiveApplicationLauncher.liveACPServices(
            dependencies: dependencies
        )

        try await fixture.withLeader(services: services) { client, initialized, owner in
            #expect(owner != nil)
            #expect(initialized.meta?["currentWorkingDirectory"]?.stringValue
                == fixture.workspace.path)
            #expect(initialized.agentCapabilities.sessionCapabilities.fork == nil)
            #expect(!initialized.agentCapabilities.mcpCapabilities.http)
            #expect(!initialized.agentCapabilities.mcpCapabilities.sse)
            #expect(initialized.meta?["x.ai/mcp/sdk"]?.boolValue == true)
            let response = try await client.request(method: "x.ai/session/list")
            let rows = try #require(response["result"]?["sessions"]?.arrayValue)
            #expect(rows.contains { $0["sessionId"]?.stringValue == "durable-leader-session" })
            let core = try await client.request(method: AgentMethodNames.sessionList)
            #expect(core["sessions"]?.arrayValue?.contains {
                $0["sessionId"]?.stringValue == "durable-leader-session"
            } == true)
        }
    }

    @Test("authenticated relay and local IPC share the complete launch bundle", .timeLimit(.minutes(1)))
    func authenticatedRelayUsesCompleteLeaderComponents() async throws {
        try await withLeaderCompositionRelay { fixture, relay in
            try await fixture.seed()
            let recorder = LeaderCompositionRecorder()
            let gateway = ACPNotificationGateway()

            try await fixture.withObservedLeader(services: fixture.components(
                recorder: recorder,
                gateway: gateway
            )) { local, initialized, localSession in
                let remote = try await relay.peer()
                let handshake = remote.request
                #expect(handshake.bearerToken == "PRIVATE_LEADER_FIRST_PARTY_TOKEN")
                #expect(handshake.header("x-userid") == "leader-owner")
                #expect(handshake.header("X-XAI-Token-Auth") == "xai-grok-cli")
                #expect(handshake.header("x-grok-client-mode") == "headless")
                #expect(handshake.header("x-grok-client-version")
                    == OpenGrokCLIVersion.installed(environment: fixture.environment))

                let relayInitialized = try await remote.initialize()
                #expect(relayInitialized.protocolVersion == initialized.protocolVersion)
                #expect(relayInitialized.meta?["currentWorkingDirectory"]?.stringValue == fixture.workspace.path)
                #expect(relayInitialized.agentCapabilities.promptCapabilities.embeddedContext)
                #expect(relayInitialized.meta?["x.ai/mcp/sdk"]?.boolValue == true)
                do {
                    let result = try await remote.call(method: "x.ai/session/list")
                    Issue.record("sessionless relay inherited the local carrier's history authority: \(result)")
                } catch let error as ACPLeaderClientError {
                    guard case .remoteACP(let response) = error else { throw error }
                    #expect(response.code == .authRequired)
                }
                let relaySession = try await remote.newSession(cwd: fixture.workspace.path)
                #expect(relaySession != localSession)
                #expect(await gateway.hasConnectedRuntime())

                let extensionList = try await remote.call(
                    id: .string("relay-extension-list"),
                    method: "x.ai/session/list"
                )
                #expect(extensionList["result"]?["sessions"]?[0]?["sessionId"]?.stringValue
                    == "durable-leader-session")
                let coreList = try await remote.call(method: AgentMethodNames.sessionList)
                #expect(coreList["sessions"]?[0]?["sessionId"]?.stringValue == "durable-leader-session")
                let localList = try await local.request(method: "x.ai/session/list")
                #expect(localList == extensionList)

                let missing = "x.ai/leader-regression/nonexistent"
                do {
                    let result = try await remote.call(method: missing)
                    Issue.record("relay registered an absent extension: \(result)")
                } catch let error as ACPLeaderClientError {
                    guard case .remoteACP(let response) = error else { throw error }
                    #expect(response == ACPExtensionMethodRouter.unknownExtensionMethodError(missing))
                }
                try await remote.send(.notification(
                    method: "x.ai/leader-regression/notification",
                    params: .object(["sessionId": .string(relaySession.rawValue)])
                ))
                let deadline = Date().addingTimeInterval(5)
                while await recorder.notifications.isEmpty, Date() < deadline {
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                #expect(await recorder.notifications == ["x.ai/leader-regression/notification"])
            }

            #expect(await relay.connectionCount() == 1)
            try await relay.expectLeaderDisconnected()
            await expectLeaderLifecycleClosed(recorder, sessions: 2)
        }
    }

    @Test("real local and relay prompts keep core and extension notifications private", .timeLimit(.minutes(1)))
    func relayAndLocalPromptNotificationsRemainPrivate() async throws {
        // Rust 00e176c8, leader/server.rs:2205-2265,2292-2333: session
        // recipients are explicit; relay-owned updates never fall back to IPC.
        try await withLeaderCompositionRelay { fixture, relay in
            let recorder = LeaderCompositionRecorder()
            let gateway = ACPNotificationGateway()
            let localMarker = "PRIVATE_LOCAL_PROMPT_MARKER"
            let relayMarker = "PRIVATE_RELAY_PROMPT_MARKER"
            let localGatewayMarker = "PRIVATE_LOCAL_GATEWAY_MARKER"
            let relayGatewayMarker = "PRIVATE_RELAY_GATEWAY_MARKER"

            try await fixture.withObservedLeader(services: fixture.components(
                recorder: recorder,
                gateway: gateway,
                promptDriver: LeaderCompositionPromptDriver(recorder: recorder)
            )) { local, _, localSession in
                let remote = try await relay.peer()
                let initialized = try await remote.initialize()
                #expect(initialized.protocolVersion == .v1)
                let relaySession = try await remote.newSession(cwd: fixture.workspace.path)
                let localPrompt = Task {
                    try await local.request(
                        method: AgentMethodNames.sessionPrompt,
                        params: leaderCompositionPrompt(localSession, marker: localMarker)
                    ).decode(PromptResponse.self)
                }
                defer { localPrompt.cancel() }
                let relayPrompt = try await remote.call(
                    method: AgentMethodNames.sessionPrompt,
                    params: leaderCompositionPrompt(relaySession, marker: relayMarker)
                ).decode(PromptResponse.self)
                let localResponse = try await localPrompt.value
                #expect(localResponse.stopReason == .endTurn)
                #expect(relayPrompt.stopReason == .endTurn)
                try await expectLeaderPromptUpdate(local.inbox, session: localSession, marker: localMarker)
                try await expectLeaderPromptUpdate(remote.inbox, session: relaySession, marker: relayMarker)

                await gateway.sendXaiSessionUpdate(
                    sessionID: localSession.rawValue,
                    update: .object(["marker": .string(localGatewayMarker)])
                )
                await gateway.sendXaiSessionUpdate(
                    sessionID: relaySession.rawValue,
                    update: .object(["marker": .string(relayGatewayMarker)])
                )
                // Each final in-order marker flushes that inbox before the
                // negative assertions; a short sleep could miss a leaked frame.
                for session in [localSession, relaySession] {
                    await gateway.sendXaiSessionUpdate(
                        sessionID: session.rawValue,
                        update: .object(["marker": .string("notification-barrier")])
                    )
                }
                try await expectLeaderGatewayMarker(local.inbox, session: localSession, marker: localGatewayMarker)
                try await expectLeaderGatewayMarker(remote.inbox, session: relaySession, marker: relayGatewayMarker)
                try await expectLeaderGatewayMarker(local.inbox, session: localSession, marker: "notification-barrier")
                try await expectLeaderGatewayMarker(remote.inbox, session: relaySession, marker: "notification-barrier")
                try await expectLeaderMarkerAbsent(localMarker, from: remote.inbox)
                try await expectLeaderMarkerAbsent(relayMarker, from: local.inbox)
                try await expectLeaderMarkerAbsent(localGatewayMarker, from: remote.inbox)
                try await expectLeaderMarkerAbsent(relayGatewayMarker, from: local.inbox)
            }

            try await relay.expectLeaderDisconnected()
            await expectLeaderLifecycleClosed(recorder, sessions: 2)
        }
    }

    @Test("local and relay carriers cannot mutate one another's resident history", .timeLimit(.minutes(1)))
    func reciprocalRelaySessionAuthorityCannotMutateHistory() async throws {
        try await withLeaderCompositionRelay { fixture, relay in
            let recorder = LeaderCompositionRecorder()
            let services = fixture.components(
                recorder: recorder,
                remoteDelete: { await recorder.remoteDelete($0) }
            )
            try await fixture.withObservedLeader(services: services) { local, _, localSession in
                let remote = try await relay.peer()
                let initialized = try await remote.initialize()
                #expect(initialized.protocolVersion == .v1)
                let relaySession = try await remote.newSession(cwd: fixture.workspace.path)
                try await fixture.seed(localSession.rawValue)
                try await fixture.seed(relaySession.rawValue)

                for (target, forkID) in [
                    (localSession, "forged-by-relay"),
                    (relaySession, "forged-by-local"),
                ] {
                    let mutations: [(String, LeaderCompositionJSON)] = [
                        ("x.ai/session/rename", .object([
                            "sessionId": .string(target.rawValue),
                            "cwd": .string(fixture.workspace.path),
                            "title": .string("FORGED_FOREIGN_TITLE"),
                        ])),
                        ("x.ai/session/delete", .object([
                            "sessionId": .string(target.rawValue),
                            "cwd": .string(fixture.workspace.path),
                        ])),
                        ("x.ai/session/fork", .object([
                            "sourceSessionId": .string(target.rawValue),
                            "sourceCwd": .string(fixture.workspace.path),
                            "newCwd": .string(fixture.workspace.path),
                            "newSessionId": .string(forkID),
                        ])),
                        (AgentMethodNames.sessionClose, .object([
                            "sessionId": .string(target.rawValue),
                        ])),
                    ]
                    for (method, params) in mutations {
                        try await expectLeaderSessionRefused(target) {
                            if target == localSession {
                                return try await remote.call(method: method, params: params)
                            }
                            return try await local.request(method: method, params: params)
                        }
                    }
                    let store = LiveConversationStore(openGrokHome: fixture.home)
                    let record = try #require(try await store.loadIfPresent(sessionID: target.rawValue))
                    #expect(record.title == "Durable leader history")
                    #expect(record.items == [.user("PRIVATE_LEADER_TRANSCRIPT")])
                    #expect(try await store.loadIfPresent(sessionID: forkID) == nil)
                }
                #expect(await recorder.remoteDeletions.isEmpty)
                #expect(await recorder.closed.isEmpty)

                let localClosed = try await local.request(
                    method: AgentMethodNames.sessionClose,
                    params: try LeaderCompositionJSON.encode(CloseSessionRequest(sessionId: localSession))
                )
                let relayClosed = try await remote.call(
                    method: AgentMethodNames.sessionClose,
                    params: try LeaderCompositionJSON.encode(CloseSessionRequest(sessionId: relaySession))
                )
                #expect(localClosed.objectValue != nil)
                #expect(relayClosed.objectValue != nil)
                #expect(Set(await recorder.closed) == Set([localSession, relaySession]))
            }

            try await relay.expectLeaderDisconnected()
            await expectLeaderLifecycleClosed(recorder, sessions: 2)
        }
    }

    @Test("relay reconnect preserves local gateway, suspended approvals, and session authority", .timeLimit(.minutes(1)))
    func relayReconnectKeepsLocalNotificationsAndApproval() async throws {
        try await withLeaderCompositionRelay { fixture, relay in
            let recorder = LeaderCompositionRecorder()
            let gateway = ACPNotificationGateway()
            let prompter = LiveACPPermissionPrompter(timeoutSeconds: 3)
            let localBefore = "PRIVATE_LOCAL_APPROVAL_BEFORE_DROP"
            let localDuring = "PRIVATE_LOCAL_APPROVAL_AFTER_DROP"
            let localAfter = "PRIVATE_LOCAL_APPROVAL_AFTER_RECONNECT"
            let relayAfter = "PRIVATE_RELAY_APPROVAL_AFTER_RECONNECT"

            try await fixture.withObservedLeader(services: fixture.components(
                recorder: recorder,
                gateway: gateway,
                permissionPrompter: prompter,
                promptDriver: LeaderCompositionPromptDriver(
                    recorder: recorder,
                    permissionPrompter: prompter
                )
            )) { local, _, localSession in
                let original = try await relay.peer()
                let firstInitialize = try await original.initialize()
                #expect(firstInitialize.protocolVersion == .v1)
                let originalSession = try await original.newSession(cwd: fixture.workspace.path)
                try await approveLeaderLocalPrompt(
                    local,
                    session: localSession,
                    marker: localBefore,
                    foreignPeer: original
                )
                #expect(await recorder.permissionResults[localBefore] == true)
                await gateway.sendXaiSessionUpdate(
                    sessionID: originalSession.rawValue,
                    update: .object(["marker": .string("before-drop-barrier")])
                )
                try await expectLeaderGatewayMarker(
                    original.inbox,
                    session: originalSession,
                    marker: "before-drop-barrier"
                )
                try await expectLeaderMarkerAbsent(localBefore, from: original.inbox)

                await original.close()
                #expect(await original.inbox.isFinished())
                #expect(await gateway.hasConnectedRuntime())
                #expect(await recorder.closed.isEmpty)
                await gateway.sendXaiSessionUpdate(
                    sessionID: localSession.rawValue,
                    update: .object(["marker": .string("local-gateway-after-drop")])
                )
                try await expectLeaderGatewayMarker(
                    local.inbox,
                    session: localSession,
                    marker: "local-gateway-after-drop"
                )
                try await approveLeaderLocalPrompt(local, session: localSession, marker: localDuring)
                #expect(await recorder.permissionResults[localDuring] == true)

                let replacement = try await relay.peer(1)
                let reinitialized = try await replacement.initialize()
                #expect(reinitialized.protocolVersion == .v1)
                #expect(reinitialized.meta?["x.ai/mcp/sdk"]?.boolValue == true)
                let replacementSession = try await replacement.newSession(cwd: fixture.workspace.path)
                #expect(replacementSession != originalSession)
                #expect(replacementSession != localSession)
                for target in [localSession, originalSession] {
                    try await expectLeaderSessionRefused(target) {
                        try await replacement.call(
                            method: AgentMethodNames.sessionClose,
                            params: try LeaderCompositionJSON.encode(CloseSessionRequest(sessionId: target))
                        )
                    }
                }
                #expect(await gateway.hasConnectedRuntime())
                #expect(await recorder.closed.isEmpty)
                try await approveLeaderLocalPrompt(
                    local,
                    session: localSession,
                    marker: localAfter,
                    foreignPeer: replacement
                )
                try await approveLeaderRelayPrompt(replacement, session: replacementSession, marker: relayAfter)
                #expect(await recorder.permissionResults == [
                    localBefore: true,
                    localDuring: true,
                    localAfter: true,
                    relayAfter: true,
                ])

                for session in [localSession, replacementSession] {
                    await gateway.sendXaiSessionUpdate(
                        sessionID: session.rawValue,
                        update: .object(["marker": .string("reconnect-barrier")])
                    )
                }
                try await expectLeaderGatewayMarker(local.inbox, session: localSession, marker: "reconnect-barrier")
                try await expectLeaderGatewayMarker(replacement.inbox, session: replacementSession, marker: "reconnect-barrier")
                for marker in [localBefore, localDuring, localAfter] {
                    try await expectLeaderMarkerAbsent(marker, from: replacement.inbox)
                }
                try await expectLeaderMarkerAbsent(relayAfter, from: local.inbox)
                #expect(await recorder.factoryCalls == 1)
            }

            #expect(await relay.connectionCount() == 2)
            try await relay.expectLeaderDisconnected()
            await expectLeaderLifecycleClosed(recorder, sessions: 3)
        }
    }
}
