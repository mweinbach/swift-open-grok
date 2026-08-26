import Foundation
import OpenGrokACP
import OpenGrokHTTP
import OpenGrokShared
import Testing

@testable import OpenGrokACPRuntime

private struct ACPLeaderIsolationDriver: ACPPromptDriver {
    var admission: (@Sendable (ACPSessionSnapshot) async throws -> Void)? = nil

    func admitSession(_ session: ACPSessionSnapshot) async throws {
        try await admission?(session)
    }

    func run(
        context: ACPPromptContext,
        emit: @escaping @Sendable (SessionNotification, ACPNotificationDisposition) async -> Void
    ) async throws -> PromptResponse {
        await emit(
            SessionNotification(
                sessionId: context.session.sessionId,
                update: .agentMessageChunk(ContentChunk(
                    content: .text(TextContent(text: "leader-private-assistant-marker"))
                ))
            ),
            .durable
        )
        return PromptResponse(stopReason: .endTurn)
    }

    func cancel(sessionId: AcpSessionId) async {}
}

private enum ACPLeaderIsolationError: Error {
    case registrationFailed
    case timedOut
    case unsuccessfulResponse
}

private actor ACPLeaderIsolationInbox {
    private var messages: [ACPMessage] = []

    func append(_ message: ACPMessage) {
        messages.append(message)
    }

    func removeFirst(
        matching predicate: @Sendable (ACPMessage) -> Bool
    ) -> ACPMessage? {
        guard let index = messages.firstIndex(where: predicate) else { return nil }
        return messages.remove(at: index)
    }

    func drain() -> [ACPMessage] {
        defer { messages.removeAll() }
        return messages
    }

    func snapshot() -> [ACPMessage] {
        messages
    }
}

private actor ACPLeaderIsolationClient {
    private let channel: any WebSocketByteChannel
    private let reader: ACPLeaderChannelReader
    private let inbox = ACPLeaderIsolationInbox()
    private var readerTask: Task<Void, Never>?

    init(channel: any WebSocketByteChannel) {
        self.channel = channel
        self.reader = ACPLeaderChannelReader(
            channel: channel,
            maximumMessageSize: ACPLeaderProtocolLimits.maximumMessageSize
        )
    }

    func register(as name: String) async throws -> UInt64 {
        let registration = ACPLeaderClientMessage.register(
            clientType: name,
            mode: .stdio,
            capabilities: ACPLeaderClientCapabilities(
                terminal: true,
                fsRead: true,
                fsWrite: true
            )
        )
        try await channel.write(try ACPLeaderCodec.encode(registration))
        guard case .registered(let clientID, _, _, _, _)? = try await reader.next(
            ACPLeaderServerMessage.self
        ) else {
            throw ACPLeaderIsolationError.registrationFailed
        }

        readerTask = Task { [reader, inbox] in
            do {
                while let message = try await reader.next(ACPLeaderServerMessage.self) {
                    guard case .acp(let payload) = message else { continue }
                    let decoded = try ACPMessage(data: Data(payload.utf8))
                    await inbox.append(decoded)
                }
            } catch {}
        }
        return clientID
    }

    func send(_ message: ACPMessage) async throws {
        let payload = String(decoding: try message.encodedData(), as: UTF8.self)
        try await channel.write(try ACPLeaderCodec.encode(
            ACPLeaderClientMessage.acp(payload: payload)
        ))
    }

    func request(
        id: Int64,
        method: String,
        params: JSONValue
    ) async throws -> JSONValue {
        let response = try await response(id: id, method: method, params: params)
        guard case .response(_, let result?, nil) = response else {
            throw ACPLeaderIsolationError.unsuccessfulResponse
        }
        return result
    }

    func response(
        id: Int64,
        method: String,
        params: JSONValue
    ) async throws -> ACPMessage {
        try await send(.request(id: .number(id), method: method, params: params))
        return try await next { message in
            if case .response(.number(id), _, _) = message { return true }
            return false
        }
    }

    func next(
        timeoutSeconds: Double = 5,
        matching predicate: @escaping @Sendable (ACPMessage) -> Bool
    ) async throws -> ACPMessage {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let message = await inbox.removeFirst(matching: predicate) {
                return message
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw ACPLeaderIsolationError.timedOut
    }

    func drain() async -> [ACPMessage] {
        await inbox.drain()
    }

    func messages() async -> [ACPMessage] {
        await inbox.snapshot()
    }

    func close() async {
        await channel.close()
        readerTask?.cancel()
        await readerTask?.value
        readerTask = nil
    }
}

private actor ACPLeaderIsolationReverseResult {
    private(set) var value: JSONValue?

    func record(_ value: JSONValue) {
        self.value = value
    }
}

private actor ACPLeaderIsolationExtensionCounter {
    private(set) var methods = 0
    private(set) var notifications = 0

    func recordMethod() {
        methods += 1
    }

    func recordNotification() {
        notifications += 1
    }
}

private struct ACPLeaderIsolationExtensionHandler: ACPAgentExtensionHandler {
    let counter: ACPLeaderIsolationExtensionCounter

    func handle(method: String, params: JSONValue) async throws -> JSONValue {
        await counter.recordMethod()
        return .object(["authorized": .bool(true)])
    }
}

private struct ACPLeaderIsolationNotificationHandler: ACPAgentExtensionNotificationHandler {
    let counter: ACPLeaderIsolationExtensionCounter

    func handle(method: String, params: JSONValue) async {
        await counter.recordNotification()
    }
}

private final class ACPLeaderIsolationSessionIDs: @unchecked Sendable {
    private let lock = NSLock()
    private let identifiers: [String]
    private var index = 0

    init(_ identifiers: [String]) {
        self.identifiers = identifiers
    }

    func next() -> String {
        lock.withLock {
            defer { index += 1 }
            return index < identifiers.count ? identifiers[index] : UUID().uuidString
        }
    }
}

private actor ACPLeaderIsolationGate {
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async throws {
        let deadline = Date().addingTimeInterval(2)
        while !entered && Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard entered else { throw ACPLeaderIsolationError.timedOut }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor ACPLeaderIsolationStore: ACPSessionStore {
    private let storage = InMemoryACPSessionStore()
    private var nextReadGate: (AcpSessionId, ACPLeaderIsolationGate)?
    private var failingSession: AcpSessionId?
    private var reads: [AcpSessionId: Int] = [:]

    func suspendNextRead(of sessionID: AcpSessionId, gate: ACPLeaderIsolationGate) {
        nextReadGate = (sessionID, gate)
    }

    func failReads(of sessionID: AcpSessionId?) {
        failingSession = sessionID
    }

    func create(_ session: ACPSessionSnapshot) async throws {
        try await storage.create(session)
    }

    func readCount(_ sessionID: AcpSessionId) -> Int {
        reads[sessionID, default: 0]
    }

    func read(_ sessionID: AcpSessionId) async throws -> ACPSessionSnapshot? {
        reads[sessionID, default: 0] += 1
        if failingSession == sessionID {
            throw ACPRuntimeError.transport("fixture store read failed")
        }
        let snapshot = await storage.read(sessionID)
        if let (target, gate) = nextReadGate, target == sessionID {
            nextReadGate = nil
            await gate.suspend()
        }
        return snapshot
    }

    func update(_ session: ACPSessionSnapshot) async throws {
        try await storage.update(session)
    }

    func list(cwd: String?) async throws -> [ACPSessionSnapshot] {
        await storage.list(cwd: cwd)
    }
}

private actor ACPLeaderIsolationOwnership {
    private var nextVerificationGate: ACPLeaderIsolationGate?
    private var revoked = false

    func suspendNextVerification(gate: ACPLeaderIsolationGate) {
        nextVerificationGate = gate
    }

    func revoke() {
        revoked = true
    }

    func restore() {
        revoked = false
    }

    func owns(_ sessionID: AcpSessionId, clientID: String) async -> Bool {
        if let gate = nextVerificationGate {
            nextVerificationGate = nil
            await gate.suspend()
        }
        return !revoked && ((sessionID.rawValue == "owner-root" && clientID == "owner")
            || (sessionID.rawValue == "history-target" && clientID == "foreign"))
    }
}

private actor ACPLeaderIsolationLifecycle {
    private(set) var opened: [AcpSessionId] = []
    private(set) var closed: [AcpSessionId] = []

    func open(_ sessionID: AcpSessionId) { opened.append(sessionID) }
    func close(_ sessionID: AcpSessionId) { closed.append(sessionID) }
}

private struct ACPLeaderIsolationClosureHandler: ACPAgentExtensionHandler {
    let body: @Sendable (String, JSONValue) async throws -> JSONValue

    func handle(method: String, params: JSONValue) async throws -> JSONValue {
        try await body(method, params)
    }
}

enum ACPLeaderHistoryPausePoint: CaseIterable, Equatable, Sendable {
    case targetLookup
    case ownerVerification
    case ownerSnapshot
    case dispatch
}

private func leaderAuthorityRequest(
    _ runtime: ACPAgentRuntime,
    clientID: String? = "owner",
    id: Int64,
    method: String,
    params: JSONValue = .object([:])
) async -> ACPMessage {
    let replies = await ACPLeaderRequestAuthority.$clientID.withValue(clientID) {
        await runtime.handle(.request(id: .number(id), method: method, params: params))
    }
    guard let response = replies.last else {
        Issue.record("ACP request produced no response")
        return .response(id: .number(id), result: nil, error: AcpError.internalError())
    }
    return response
}

private func expectLeaderSuccess(_ response: ACPMessage) {
    guard case .response(_, _?, nil) = response else {
        Issue.record("expected a successful ACP response, got \(response)")
        return
    }
}

private func expectLeaderSessionDenied(_ response: ACPMessage, sessionID: String) {
    guard case .response(_, nil, let error?) = response else {
        Issue.record("expected an owner-scoped ACP refusal, got \(response)")
        return
    }
    #expect(error == ACPRuntimeError.sessionNotFound(AcpSessionId(sessionID)).acpError)
}

private func initializeLeaderAuthorityRuntime(_ runtime: ACPAgentRuntime) async throws {
    let initialized = await leaderAuthorityRequest(
        runtime,
        id: 1,
        method: AgentMethodNames.initialize,
        params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
    )
    expectLeaderSuccess(initialized)
    let opened = await leaderAuthorityRequest(
        runtime,
        id: 2,
        method: AgentMethodNames.sessionNew,
        params: try JSONValue.encode(NewSessionRequest(cwd: FileManager.default.temporaryDirectory.path))
    )
    guard case .response(_, let result?, nil) = opened else {
        throw ACPLeaderIsolationError.unsuccessfulResponse
    }
    #expect(try result.decode(NewSessionResponse.self).sessionId == AcpSessionId("owner-root"))
}

private func makeLeaderHistoryRuntime(
    handler: any ACPAgentExtensionHandler,
    store: any ACPSessionStore = InMemoryACPSessionStore(),
    promptDriver: any ACPPromptDriver = ACPNoopPromptDriver(),
    ownership: ACPLeaderIsolationOwnership = ACPLeaderIsolationOwnership(),
    onSessionOpened: ACPAgentRuntime.SessionOpenedHook? = nil,
    onSessionClosed: ACPAgentRuntime.SessionClosedHook? = nil
) async throws -> ACPAgentRuntime {
    let identifiers = ACPLeaderIsolationSessionIDs([
        "owner-root", "history-target", "history-target", "history-target",
    ])
    let runtime = ACPAgentRuntime(
        store: store,
        promptDriver: promptDriver,
        extensionHandler: handler,
        onSessionOpened: onSessionOpened,
        onSessionClosed: onSessionClosed,
        makeSessionId: { identifiers.next() }
    )
    await runtime.setSessionOwnerVerifier { sessionID, clientID in
        await ownership.owns(sessionID, clientID: clientID)
    }
    try await initializeLeaderAuthorityRuntime(runtime)
    return runtime
}

@Suite("ACP extension and leader router authority boundaries")
struct ACPLeaderAuthorityBoundaryTests {
    @Test("extension requests and mutating notifications require initialize and authentication")
    func extensionSurfacesFailClosedBeforeAuthentication() async throws {
        let counter = ACPLeaderIsolationExtensionCounter()
        let extensions = ACPExtensionMethodRouter().register(
            exact: "x.ai/interject",
            handler: ACPLeaderIsolationExtensionHandler(counter: counter)
        )
        let notifications = ACPExtensionNotificationRouter().register(
            exact: "x.ai/yolo_mode_changed",
            handler: ACPLeaderIsolationNotificationHandler(counter: counter)
        )
        let runtime = ACPAgentRuntime(
            configuration: ACPAgentConfiguration(requireAuthentication: true),
            extensionRouter: extensions,
            extensionNotifications: notifications
        )

        let beforeInitialization = await runtime.handle(.request(
            id: .number(1),
            method: "x.ai/interject",
            params: .object([:])
        ))
        guard case .response(_, nil, _?)? = beforeInitialization.last else {
            Issue.record("pre-initialization extension unexpectedly executed")
            return
        }
        _ = await runtime.handle(.notification(
            method: "x.ai/yolo_mode_changed",
            params: .object(["enabled": .bool(true)])
        ))

        _ = await runtime.handle(.request(
            id: .number(2),
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
        ))
        let unauthenticated = await runtime.handle(.request(
            id: .number(3),
            method: "x.ai/interject",
            params: .object([:])
        ))
        guard case .response(_, nil, let error?)? = unauthenticated.last else {
            Issue.record("unauthenticated extension unexpectedly executed")
            return
        }
        #expect(error.code == .authRequired)
        _ = await runtime.handle(.notification(
            method: "x.ai/yolo_mode_changed",
            params: .object(["enabled": .bool(true)])
        ))
        #expect(await counter.methods == 0)
        #expect(await counter.notifications == 0)
    }

    @Test("a direct ACP runtime still rejects a second initialization")
    func directRuntimeInitializationIsNotReusable() async throws {
        let runtime = ACPAgentRuntime()
        let params = try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
        let initialized = await runtime.handle(.request(
            id: .number(1),
            method: AgentMethodNames.initialize,
            params: params
        ))
        guard case .response(_, _?, nil)? = initialized.last else {
            Issue.record("the first direct initialization failed")
            return
        }

        let repeated = await runtime.handle(.request(
            id: .number(2),
            method: AgentMethodNames.initialize,
            params: params
        ))
        guard case .response(_, nil, _?)? = repeated.last else {
            Issue.record("a direct runtime unexpectedly accepted reinitialization")
            return
        }
        #expect(await runtime.connectionState() == .initialized)
    }

    @Test("claiming an existing session never replaces its first connected driver")
    func repeatedDriverClaimsRemainObservers() async throws {
        let router = ACPLeaderRouter()
        let session = AcpSessionId("immutable-driver")
        try await router.register(clientID: "owner") { _ in }
        try await router.register(clientID: "observer") { _ in }
        try await router.claim(sessionID: session, clientID: "owner", role: .driver)
        try await router.claim(sessionID: session, clientID: "observer", role: .driver)

        #expect(await router.isDriver(clientID: "owner", for: session))
        #expect(await !router.isDriver(clientID: "observer", for: session))
        #expect(await router.sessionRecipients(session) == ["observer", "owner"])

        let reverse = ACPMessage.request(
            id: .number(99),
            method: ClientMethodNames.sessionRequestPermission,
            params: .object(["sessionId": .string(session.rawValue)])
        )
        #expect(await router.recipients(for: reverse, from: "") == ["owner"])
    }

    @Test("router recognizes every supported nested session identity spelling")
    func sessionIdentitySpellingsRouteToDriver() async throws {
        let router = ACPLeaderRouter()
        let session = AcpSessionId("normalized-session")
        try await router.register(clientID: "owner") { _ in }
        try await router.register(clientID: "observer") { _ in }
        try await router.claim(sessionID: session, clientID: "owner", role: .driver)
        try await router.claim(sessionID: session, clientID: "observer", role: .subscriber)

        for params: JSONValue in [
            .object(["session_id": .string(session.rawValue)]),
            .object(["sourceSessionId": .string(session.rawValue)]),
            .object(["source_session_id": .string(session.rawValue)]),
            .object(["params": .object(["session_id": .string(session.rawValue)])]),
        ] {
            let reverse = ACPMessage.request(
                id: .string(UUID().uuidString),
                method: OpenGrokACPExtMethods.askUserQuestion,
                params: params
            )
            #expect(await router.recipients(for: reverse, from: "") == ["owner"])
        }
    }

    @Test("history authorization never reaches a catch-all or a shadowing prefix", arguments: [false, true])
    func historicalAuthorityRequiresEffectiveExactRoute(shadowedExact: Bool) async throws {
        let counter = ACPLeaderIsolationExtensionCounter()
        let implementation = ACPLeaderIsolationExtensionHandler(counter: counter)
        let handler: any ACPAgentExtensionHandler
        if shadowedExact {
            handler = ACPExtensionMethodRouter()
                .register(prefix: "x.ai/session/", handler: implementation)
                .register(exact: "x.ai/session/delete", handler: implementation)
        } else {
            handler = implementation
        }
        let runtime = try await makeLeaderHistoryRuntime(handler: handler)
        let refused = await leaderAuthorityRequest(
            runtime,
            id: 3,
            method: "x.ai/session/delete",
            params: .object(["sessionId": .string("history-target")])
        )
        expectLeaderSessionDenied(refused, sessionID: "history-target")
        #expect(await counter.methods == 0)
        await runtime.close()
    }

    @Test("exact history handlers validate malformed canonical fields without trusting forged identities")
    func malformedHistoryParamsReachOnlyAuthorizedExactHandler() async throws {
        let counter = ACPLeaderIsolationExtensionCounter()
        let handler = ACPLeaderIsolationClosureHandler { _, _ in
            await counter.recordMethod()
            throw ACPRuntimeError.invalidParams("missing canonical history target")
        }
        let router = ACPExtensionMethodRouter().register(exact: "x.ai/session/fork", handler: handler)
        let runtime = try await makeLeaderHistoryRuntime(handler: router)
        let params: JSONValue = .object([
            "source_session_id": .string("owner-root"),
            "_meta": .object(["x.ai/leaderClientId": .string("owner")]),
        ])
        let missingAuthority = await leaderAuthorityRequest(
            runtime, clientID: nil, id: 3, method: "x.ai/session/fork", params: params
        )
        let observer = await leaderAuthorityRequest(
            runtime, clientID: "observer", id: 4, method: "x.ai/session/fork", params: params
        )
        for response in [missingAuthority, observer] {
            guard case .response(_, nil, let error?) = response else {
                Issue.record("forged request metadata granted history authority")
                continue
            }
            #expect(error.code == .authRequired)
        }
        #expect(await counter.methods == 0)
        let malformed = await leaderAuthorityRequest(
            runtime, id: 5, method: "x.ai/session/fork", params: params
        )
        guard case .response(_, nil, let error?) = malformed else {
            Issue.record("the exact handler's malformed-parameter error was lost")
            await runtime.close()
            return
        }
        #expect(error == ACPRuntimeError.invalidParams("missing canonical history target").acpError)
        #expect(await counter.methods == 1)
        await runtime.close()
    }

    @Test("history reservations exclude residency across every authorization and dispatch await", arguments: ACPLeaderHistoryPausePoint.allCases)
    func historyReservationSurvivesSuspension(_ pause: ACPLeaderHistoryPausePoint) async throws {
        let gate = ACPLeaderIsolationGate()
        let store = ACPLeaderIsolationStore()
        let ownership = ACPLeaderIsolationOwnership()
        let counter = ACPLeaderIsolationExtensionCounter()
        let handler = ACPLeaderIsolationClosureHandler { _, _ in
            await counter.recordMethod()
            if pause == .dispatch { await gate.suspend() }
            return .object(["authorized": .bool(true)])
        }
        let runtime = try await makeLeaderHistoryRuntime(
            handler: ACPExtensionMethodRouter().register(exact: "x.ai/session/delete", handler: handler),
            store: store,
            ownership: ownership
        )
        switch pause {
        case .targetLookup:
            await store.suspendNextRead(of: AcpSessionId("history-target"), gate: gate)
        case .ownerVerification:
            await ownership.suspendNextVerification(gate: gate)
        case .ownerSnapshot:
            await store.suspendNextRead(of: AcpSessionId("owner-root"), gate: gate)
        case .dispatch:
            break
        }
        let administration = Task {
            await leaderAuthorityRequest(
                runtime, id: 3, method: "x.ai/session/delete",
                params: .object(["sessionId": .string("history-target")])
            )
        }
        do {
            try await gate.waitUntilEntered()
            let newParams = try JSONValue.encode(NewSessionRequest(cwd: FileManager.default.temporaryDirectory.path))
            let overlappingAdmission = await leaderAuthorityRequest(
                runtime, clientID: "foreign", id: 4, method: AgentMethodNames.sessionNew, params: newParams
            )
            expectLeaderSessionDenied(overlappingAdmission, sessionID: "history-target")
            let load = await leaderAuthorityRequest(
                runtime, clientID: "foreign", id: 6, method: AgentMethodNames.sessionLoad,
                params: try JSONValue.encode(LoadSessionRequest(
                    sessionId: AcpSessionId("history-target"), cwd: FileManager.default.temporaryDirectory.path
                ))
            )
            expectLeaderSessionDenied(load, sessionID: "history-target")
            let resume = await leaderAuthorityRequest(
                runtime, clientID: "foreign", id: 7, method: AgentMethodNames.sessionResume,
                params: try JSONValue.encode(ResumeSessionRequest(
                    sessionId: AcpSessionId("history-target"), cwd: FileManager.default.temporaryDirectory.path
                ))
            )
            expectLeaderSessionDenied(resume, sessionID: "history-target")
            #expect(await store.readCount(AcpSessionId("history-target")) == 1)
            let fork = await leaderAuthorityRequest(
                runtime, id: 8, method: AgentMethodNames.sessionFork,
                params: try JSONValue.encode(ForkSessionRequest(sessionId: AcpSessionId("owner-root")))
            )
            expectLeaderSessionDenied(fork, sessionID: "history-target")
            await gate.release()
            expectLeaderSuccess(await administration.value)
            #expect(await counter.methods == 1)
            let retriedAdmission = await leaderAuthorityRequest(
                runtime, clientID: "foreign", id: 5, method: AgentMethodNames.sessionNew, params: newParams
            )
            expectLeaderSuccess(retriedAdmission)
        } catch {
            await gate.release()
            administration.cancel()
            #expect(await administration.value.id == .number(3))
            await runtime.close()
            throw error
        }
        await runtime.close()
    }

    @Test("an opening lifecycle cannot be mistaken for unclaimed historical state")
    func historyDeniesInFlightLifecycleAdmission() async throws {
        let gate = ACPLeaderIsolationGate()
        let counter = ACPLeaderIsolationExtensionCounter()
        let router = ACPExtensionMethodRouter().register(
            exact: "x.ai/session/delete",
            handler: ACPLeaderIsolationExtensionHandler(counter: counter)
        )
        let runtime = try await makeLeaderHistoryRuntime(
            handler: router,
            onSessionOpened: { sessionID, _ in
                if sessionID.rawValue == "history-target" { await gate.suspend() }
            }
        )
        let newParams = try JSONValue.encode(NewSessionRequest(cwd: FileManager.default.temporaryDirectory.path))
        let admission = Task {
            await leaderAuthorityRequest(
                runtime, clientID: "foreign", id: 3, method: AgentMethodNames.sessionNew, params: newParams
            )
        }
        do {
            try await gate.waitUntilEntered()
            let refused = await leaderAuthorityRequest(
                runtime, id: 4, method: "x.ai/session/delete",
                params: .object(["sessionId": .string("history-target")])
            )
            expectLeaderSessionDenied(refused, sessionID: "history-target")
            #expect(await counter.methods == 0)
            await gate.release()
            expectLeaderSuccess(await admission.value)
            let nowResident = await leaderAuthorityRequest(
                runtime, id: 5, method: "x.ai/session/delete",
                params: .object(["sessionId": .string("history-target")])
            )
            expectLeaderSessionDenied(nowResident, sessionID: "history-target")
            #expect(await counter.methods == 0)
        } catch {
            await gate.release()
            admission.cancel()
            #expect(await admission.value.id == .number(3))
            await runtime.close()
            throw error
        }
        await runtime.close()
    }

    @Test("a cancelled carrier cannot publish a session after its opening hook returns")
    func cancelledLifecycleHookCannotPublishSession() async throws {
        let gate = ACPLeaderIsolationGate()
        let store = ACPLeaderIsolationStore()
        let counter = ACPLeaderIsolationExtensionCounter()
        let router = ACPExtensionMethodRouter().register(
            exact: "x.ai/session/delete", handler: ACPLeaderIsolationExtensionHandler(counter: counter)
        )
        let runtime = try await makeLeaderHistoryRuntime(
            handler: router,
            store: store,
            onSessionOpened: { sessionID, _ in
                // Deliberately noncooperative: the runtime must recheck when
                // the hook returns, even though the shared leader is still up.
                if sessionID.rawValue == "history-target" { await gate.suspend() }
            }
        )
        let params = try JSONValue.encode(NewSessionRequest(cwd: FileManager.default.temporaryDirectory.path))
        let admission = Task {
            await leaderAuthorityRequest(
                runtime, clientID: "foreign", id: 3, method: AgentMethodNames.sessionNew, params: params
            )
        }
        do {
            try await gate.waitUntilEntered()
            admission.cancel()
            await gate.release()
            let cancelled = await admission.value
            guard case .response(_, nil, _?) = cancelled else {
                Issue.record("cancelled admission unexpectedly published its session")
                await runtime.close()
                return
            }
            #expect(try await store.read(AcpSessionId("history-target")) == nil)
            let history = await leaderAuthorityRequest(
                runtime, id: 4, method: "x.ai/session/delete",
                params: .object(["sessionId": .string("history-target")])
            )
            expectLeaderSuccess(history)
            #expect(await counter.methods == 1)
        } catch {
            await gate.release()
            admission.cancel()
            #expect(await admission.value.id == .number(3))
            await runtime.close()
            throw error
        }
        await runtime.close()
    }

    @Test("history reservations release when a handler fails or is cancelled", arguments: [false, true])
    func historyReservationReleasesOnHandlerFailure(cancelled: Bool) async throws {
        let gate = ACPLeaderIsolationGate()
        let handler = ACPLeaderIsolationClosureHandler { _, _ in
            await gate.suspend()
            try Task.checkCancellation()
            throw ACPRuntimeError.transport("history fixture failure")
        }
        let runtime = try await makeLeaderHistoryRuntime(
            handler: ACPExtensionMethodRouter().register(exact: "x.ai/session/delete", handler: handler)
        )
        let administration = Task {
            await leaderAuthorityRequest(
                runtime, id: 3, method: "x.ai/session/delete",
                params: .object(["sessionId": .string("history-target")])
            )
        }
        do {
            try await gate.waitUntilEntered()
            if cancelled { administration.cancel() }
            await gate.release()
            let failed = await administration.value
            guard case .response(_, nil, _?) = failed else {
                Issue.record("failed history handler unexpectedly returned success")
                await runtime.close()
                return
            }
            let admitted = await leaderAuthorityRequest(
                runtime, clientID: "foreign", id: 4, method: AgentMethodNames.sessionNew,
                params: try JSONValue.encode(NewSessionRequest(cwd: FileManager.default.temporaryDirectory.path))
            )
            expectLeaderSuccess(admitted)
        } catch {
            await gate.release()
            administration.cancel()
            #expect(await administration.value.id == .number(3))
            await runtime.close()
            throw error
        }
        await runtime.close()
    }

    @Test("a failing residency lookup denies and releases the historical reservation")
    func historyLookupFailureFailsClosed() async throws {
        let store = ACPLeaderIsolationStore()
        let counter = ACPLeaderIsolationExtensionCounter()
        let router = ACPExtensionMethodRouter().register(
            exact: "x.ai/session/delete", handler: ACPLeaderIsolationExtensionHandler(counter: counter)
        )
        let runtime = try await makeLeaderHistoryRuntime(handler: router, store: store)
        await store.failReads(of: AcpSessionId("history-target"))
        let refused = await leaderAuthorityRequest(
            runtime, id: 3, method: "x.ai/session/delete",
            params: .object(["sessionId": .string("history-target")])
        )
        expectLeaderSessionDenied(refused, sessionID: "history-target")
        #expect(await counter.methods == 0)
        await store.failReads(of: nil)
        let recovered = await leaderAuthorityRequest(
            runtime, id: 4, method: "x.ai/session/delete",
            params: .object(["sessionId": .string("history-target")])
        )
        expectLeaderSuccess(recovered)
        #expect(await counter.methods == 1)
        await runtime.close()
    }

    @Test("a stale owner snapshot cannot authorize history after closure or driver revocation", arguments: [false, true])
    func historyAuthorityRechecksOwnerLifecycleAfterStoreAwait(closesRoot: Bool) async throws {
        let gate = ACPLeaderIsolationGate()
        let store = ACPLeaderIsolationStore()
        let ownership = ACPLeaderIsolationOwnership()
        let counter = ACPLeaderIsolationExtensionCounter()
        let router = ACPExtensionMethodRouter().register(
            exact: "x.ai/session/delete", handler: ACPLeaderIsolationExtensionHandler(counter: counter)
        )
        let runtime = try await makeLeaderHistoryRuntime(handler: router, store: store, ownership: ownership)
        await store.suspendNextRead(of: AcpSessionId("owner-root"), gate: gate)
        let administration = Task {
            await leaderAuthorityRequest(
                runtime, id: 3, method: "x.ai/session/delete",
                params: .object(["sessionId": .string("history-target")])
            )
        }
        do {
            try await gate.waitUntilEntered()
            if closesRoot {
                let closed = await leaderAuthorityRequest(
                    runtime, id: 4, method: AgentMethodNames.sessionClose,
                    params: try JSONValue.encode(CloseSessionRequest(sessionId: AcpSessionId("owner-root")))
                )
                expectLeaderSuccess(closed)
            } else {
                await ownership.revoke()
            }
            await gate.release()
            expectLeaderSessionDenied(await administration.value, sessionID: "history-target")
            #expect(await counter.methods == 0)
        } catch {
            await gate.release()
            administration.cancel()
            #expect(await administration.value.id == .number(3))
            await runtime.close()
            throw error
        }
        await runtime.close()
    }

    @Test(
        "load and resume recheck driver authority after suspended admission or lifecycle hooks",
        arguments: [AgentMethodNames.sessionLoad, AgentMethodNames.sessionResume], [false, true]
    )
    func reopeningRechecksDriverAfterAwait(method: String, pauseAdmission: Bool) async throws {
        let sessionID = AcpSessionId("history-target")
        let original = ACPSessionSnapshot(
            sessionId: sessionID,
            cwd: FileManager.default.temporaryDirectory.path,
            closed: true,
            createdAt: "created",
            updatedAt: "updated"
        )
        let gate = ACPLeaderIsolationGate()
        let store = ACPLeaderIsolationStore()
        try await store.create(original)
        let ownership = ACPLeaderIsolationOwnership()
        let lifecycle = ACPLeaderIsolationLifecycle()
        let runtime = try await makeLeaderHistoryRuntime(
            handler: ACPExtensionMethodRouter(),
            store: store,
            promptDriver: ACPLeaderIsolationDriver(admission: { session in
                if session.sessionId == sessionID, pauseAdmission { await gate.suspend() }
            }),
            ownership: ownership,
            onSessionOpened: { openedID, _ in
                guard openedID == sessionID else { return }
                await lifecycle.open(openedID)
                if !pauseAdmission { await gate.suspend() }
            },
            onSessionClosed: { closedID in
                if closedID == sessionID { await lifecycle.close(closedID) }
            }
        )
        let params: JSONValue
        if method == AgentMethodNames.sessionLoad {
            params = try JSONValue.encode(LoadSessionRequest(sessionId: sessionID, cwd: original.cwd))
        } else {
            params = try JSONValue.encode(ResumeSessionRequest(sessionId: sessionID, cwd: original.cwd))
        }
        #expect(params["_meta"] == nil)
        let reopening = Task {
            await leaderAuthorityRequest(runtime, clientID: "foreign", id: 3, method: method, params: params)
        }
        do {
            try await gate.waitUntilEntered()
            await ownership.revoke()
            await gate.release()
            expectLeaderSessionDenied(await reopening.value, sessionID: sessionID.rawValue)
            #expect(try await store.read(sessionID) == original)
            #expect(await lifecycle.opened == (pauseAdmission ? [] : [sessionID]))
            #expect(await lifecycle.closed == (pauseAdmission ? [] : [sessionID]))

            await ownership.restore()
            let retried = await leaderAuthorityRequest(
                runtime, clientID: "foreign", id: 4, method: method, params: params
            )
            expectLeaderSuccess(retried)
            #expect(try await store.read(sessionID)?.closed == false)
            let ownsSession = await ACPLeaderRequestAuthority.$clientID.withValue("foreign") {
                await runtime.ownsSession(sessionID)
            }
            #expect(ownsSession)
        } catch {
            await gate.release()
            reopening.cancel()
            #expect(await reopening.value.id == .number(3))
            await runtime.close()
            throw error
        }
        await runtime.close()
        #expect(await lifecycle.opened == Array(repeating: sessionID, count: pauseAdmission ? 1 : 2))
        #expect(await lifecycle.closed == Array(repeating: sessionID, count: pauseAdmission ? 1 : 2))
    }
}

#if os(macOS) || os(Linux)

private struct ACPLeaderIsolationFixture {
    let directory: URL
    let store: InMemoryACPSessionStore
    let lifecycle: ACPLeaderIsolationLifecycle
    let runtime: ACPAgentRuntime
    let router: ACPLeaderRouter
    let host: ACPLeaderIPCHost
    let listener: ACPLeaderSocketListener
    let acceptTask: Task<Void, Never>
    let owner: ACPLeaderIsolationClient
    let observer: ACPLeaderIsolationClient
    let ownerID: UInt64
    let observerID: UInt64
    let extensionCounter: ACPLeaderIsolationExtensionCounter

    init() async throws {
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
        #if os(macOS)
        let directory = URL(fileURLWithPath: "/private/tmp/ogli-\(suffix)", isDirectory: true)
        #else
        let directory = URL(fileURLWithPath: "/tmp/ogli-\(suffix)", isDirectory: true)
        #endif
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let extensionCounter = ACPLeaderIsolationExtensionCounter()
        let extensionHandler = ACPLeaderIsolationExtensionHandler(counter: extensionCounter)
        let extensions = ACPExtensionMethodRouter()
            .register(exact: "x.ai/mcp/upsert", handler: extensionHandler)
            .register(exact: "x.ai/share_session", handler: extensionHandler)
            .register(exact: "x.ai/session/delete", handler: extensionHandler)
            .register(exact: "x.ai/session/rename", handler: extensionHandler)
            .register(exact: "x.ai/session/fork", handler: extensionHandler)
            .register(exact: "x.ai/interject", handler: extensionHandler)
            .register(exact: "x.ai/sessionless/control", handler: extensionHandler)
        let notificationHandler = ACPLeaderIsolationNotificationHandler(counter: extensionCounter)
        let notifications = ACPExtensionNotificationRouter()
            .register(exact: "x.ai/yolo_mode_changed", handler: notificationHandler)
            .register(exact: "x.ai/permissions/reset", handler: notificationHandler)
        let identifiers = ACPLeaderIsolationSessionIDs(["leader-isolated-root"])
        let store = InMemoryACPSessionStore()
        let lifecycle = ACPLeaderIsolationLifecycle()
        let runtime = ACPAgentRuntime(
            store: store,
            promptDriver: ACPLeaderIsolationDriver(),
            extensionHandler: extensions,
            extensionNotifications: notifications,
            onSessionOpened: { sessionID, _ in await lifecycle.open(sessionID) },
            onSessionClosed: { sessionID in await lifecycle.close(sessionID) },
            makeSessionId: { identifiers.next() }
        )
        let router = ACPLeaderRouter()
        let host = ACPLeaderIPCHost(runtime: runtime, router: router)
        let listener = ACPLeaderSocketListener(path: directory.appendingPathComponent("leader.sock"))
        let channels = try await listener.start()
        let acceptTask = Task {
            await withTaskGroup(of: Void.self) { group in
                for await channel in channels {
                    group.addTask {
                        await host.serve(channel: channel)
                    }
                }
            }
        }

        let owner = ACPLeaderIsolationClient(channel: try await ACPLeaderSocketDialer.connect(
            path: directory.appendingPathComponent("leader.sock")
        ))
        let ownerID = try await owner.register(as: "authenticated-owner")
        let observer = ACPLeaderIsolationClient(channel: try await ACPLeaderSocketDialer.connect(
            path: directory.appendingPathComponent("leader.sock")
        ))
        let observerID = try await observer.register(as: "untrusted-observer")

        _ = try await owner.request(
            id: 1,
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
        )

        self.directory = directory
        self.store = store
        self.lifecycle = lifecycle
        self.runtime = runtime
        self.router = router
        self.host = host
        self.listener = listener
        self.acceptTask = acceptTask
        self.owner = owner
        self.observer = observer
        self.ownerID = ownerID
        self.observerID = observerID
        self.extensionCounter = extensionCounter
    }

    func createSession() async throws -> AcpSessionId {
        let result = try await owner.request(
            id: 2,
            method: AgentMethodNames.sessionNew,
            params: try JSONValue.encode(NewSessionRequest(cwd: directory.path))
        )
        return try result.decode(NewSessionResponse.self).sessionId
    }

    func shutdown() async {
        await owner.close()
        await observer.close()
        await host.stop()
        await listener.stop()
        acceptTask.cancel()
        await acceptTask.value
        await runtime.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

private func withLeaderIsolationFixture<T>(
    _ body: (ACPLeaderIsolationFixture) async throws -> T
) async throws -> T {
    let fixture = try await ACPLeaderIsolationFixture()
    do {
        let result = try await body(fixture)
        await fixture.shutdown()
        return result
    } catch {
        await fixture.shutdown()
        throw error
    }
}

private func leaderIsolationReplayMetadata(_ message: ACPMessage) -> [String: JSONValue]? {
    guard case .notification(let method, let params) = message,
          method == ClientMethodNames.sessionUpdate,
          let metadata = params.objectValue?["_meta"]?.objectValue,
          metadata["isReplay"]?.boolValue == true
    else { return nil }
    return metadata
}

@Suite("Leader ACP authenticated client ownership and private replay", .serialized)
struct ACPLeaderClientIsolationParityTests {
    @Test(
        "a closed session retains its driver gate while an ownerless reconnect may claim it",
        arguments: [AgentMethodNames.sessionLoad, AgentMethodNames.sessionResume]
    )
    func closedSessionAttachRequiresDriverUntilOwnerDisconnects(method: String) async throws {
        try await withLeaderIsolationFixture { fixture in
            let sessionID = try await fixture.createSession()
            let hostileDirectory = fixture.directory.appendingPathComponent("observer-workspace")
            try FileManager.default.createDirectory(at: hostileDirectory, withIntermediateDirectories: true)
            func attachParams(cwd: String) throws -> JSONValue {
                if method == AgentMethodNames.sessionLoad {
                    return try JSONValue.encode(LoadSessionRequest(sessionId: sessionID, cwd: cwd))
                }
                return try JSONValue.encode(ResumeSessionRequest(sessionId: sessionID, cwd: cwd))
            }
            let ownerParams = try attachParams(cwd: fixture.directory.path)
            #expect(ownerParams["_meta"] == nil)
            let observed = try await fixture.observer.response(id: 100, method: method, params: ownerParams)
            expectLeaderSuccess(observed)
            #expect(await fixture.lifecycle.opened == [sessionID])
            #expect(await fixture.router.isDriver(clientID: String(fixture.observerID), for: sessionID) == false)

            let closeParams = try JSONValue.encode(CloseSessionRequest(sessionId: sessionID))
            expectLeaderSuccess(try await fixture.owner.response(
                id: 101, method: AgentMethodNames.sessionClose, params: closeParams
            ))
            let closedSnapshot = await fixture.store.read(sessionID)
            #expect(closedSnapshot?.closed == true)
            let refused = try await fixture.observer.response(
                id: 102, method: method, params: try attachParams(cwd: hostileDirectory.path)
            )
            expectLeaderSessionDenied(refused, sessionID: sessionID.rawValue)
            #expect(await fixture.store.read(sessionID) == closedSnapshot)
            #expect(await fixture.lifecycle.opened == [sessionID])
            #expect(await fixture.lifecycle.closed == [sessionID])

            expectLeaderSuccess(try await fixture.owner.response(id: 103, method: method, params: ownerParams))
            #expect(await fixture.lifecycle.opened == [sessionID, sessionID])
            let ownerAuthorized = await ACPLeaderRequestAuthority.$clientID.withValue(String(fixture.ownerID)) {
                await fixture.runtime.ownsSession(sessionID)
            }
            #expect(ownerAuthorized)
            let observerAuthorized = await ACPLeaderRequestAuthority.$clientID.withValue(String(fixture.observerID)) {
                await fixture.runtime.ownsSession(sessionID)
            }
            #expect(!observerAuthorized)
            let promptParams = try JSONValue.encode(PromptRequest(
                sessionId: sessionID, prompt: [.text("only the current driver may prompt after reopening")]
            ))
            let promptDenied = try await fixture.observer.response(
                id: 104, method: AgentMethodNames.sessionPrompt, params: promptParams
            )
            expectLeaderSessionDenied(promptDenied, sessionID: sessionID.rawValue)
            let ownerPrompt = try await fixture.owner.request(
                id: 105, method: AgentMethodNames.sessionPrompt, params: promptParams
            )
            #expect(try ownerPrompt.decode(PromptResponse.self).stopReason == .endTurn)
            expectLeaderSuccess(try await fixture.owner.response(
                id: 106, method: AgentMethodNames.sessionClose, params: closeParams
            ))

            // Failed observer attachment released its provisional subscription.
            // Wait for the actual transport teardown, not just the local close,
            // before checking the host's legitimate ownerless-driver claim.
            await fixture.owner.close()
            let deadline = Date().addingTimeInterval(2)
            while !(await fixture.router.sessionRecipients(sessionID)).isEmpty, Date() < deadline {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard await fixture.router.sessionRecipients(sessionID).isEmpty else {
                throw ACPLeaderIsolationError.timedOut
            }
            #expect(await fixture.host.connectedClientCount() == 1)
            expectLeaderSuccess(try await fixture.observer.response(id: 107, method: method, params: ownerParams))
            #expect(await fixture.router.isDriver(clientID: String(fixture.observerID), for: sessionID))
            #expect(await fixture.store.read(sessionID)?.closed == false)
            #expect(await fixture.lifecycle.opened == [sessionID, sessionID, sessionID])
            let reconnected = await ACPLeaderRequestAuthority.$clientID.withValue(String(fixture.observerID)) {
                await fixture.runtime.ownsSession(sessionID)
            }
            #expect(reconnected)
            let reconnectPrompt = try await fixture.observer.request(
                id: 108, method: AgentMethodNames.sessionPrompt, params: promptParams
            )
            #expect(try reconnectPrompt.decode(PromptResponse.self).stopReason == .endTurn)
            expectLeaderSuccess(try await fixture.observer.response(
                id: 109, method: AgentMethodNames.sessionClose, params: closeParams
            ))
            #expect(await fixture.lifecycle.closed == [sessionID, sessionID, sessionID])
        }
    }

    @Test("leader history administration requires an owned root and never controls another live or closed session")
    func historicalAdministrationPreservesTransportOwnership() async throws {
        try await withLeaderIsolationFixture { fixture in
            let methods = [
                ("x.ai/session/delete", "sessionId"),
                ("x.ai/session/rename", "sessionId"),
                ("x.ai/session/fork", "sourceSessionId"),
            ]
            let historyID = "unloaded-private-history"
            let beforeRoot = try await fixture.owner.response(
                id: 10, method: "x.ai/session/delete",
                params: .object(["sessionId": .string(historyID)])
            )
            expectLeaderSessionDenied(beforeRoot, sessionID: historyID)
            let ownerSession = try await fixture.createSession()

            for (offset, method) in methods.enumerated() {
                let params: JSONValue = .object([
                    method.1: .string(historyID),
                    "_meta": .object([
                        "x.ai/leaderClientId": .number(.uint64(fixture.ownerID)),
                    ]),
                ])
                let observer = try await fixture.observer.response(
                    id: Int64(20 + offset), method: method.0, params: params
                )
                expectLeaderSessionDenied(observer, sessionID: historyID)
                let owner = try await fixture.owner.request(
                    id: Int64(30 + offset), method: method.0, params: params
                )
                #expect(owner["authorized"]?.boolValue == true)
            }
            #expect(await fixture.extensionCounter.methods == methods.count)

            let attached = try await fixture.observer.response(
                id: 40,
                method: AgentMethodNames.sessionLoad,
                params: try JSONValue.encode(LoadSessionRequest(
                    sessionId: ownerSession, cwd: fixture.directory.path
                ))
            )
            expectLeaderSuccess(attached)
            let observerSession = try await fixture.observer.request(
                id: 41,
                method: AgentMethodNames.sessionNew,
                params: try JSONValue.encode(NewSessionRequest(cwd: fixture.directory.path))
            ).decode(NewSessionResponse.self).sessionId
            #expect(observerSession != ownerSession)

            for (offset, method) in methods.enumerated() {
                // The generic sessionId field must never override the fork
                // handler's sourceSessionId authorization target.
                var observerParams: [String: JSONValue] = [
                    "sessionId": .string(observerSession.rawValue),
                    "session_id": .string(observerSession.rawValue),
                ]
                observerParams[method.1] = .string(ownerSession.rawValue)
                let observer = try await fixture.observer.response(
                    id: Int64(50 + offset), method: method.0, params: .object(observerParams)
                )
                expectLeaderSessionDenied(observer, sessionID: ownerSession.rawValue)
                let owner = try await fixture.owner.response(
                    id: Int64(60 + offset), method: method.0,
                    params: .object([method.1: .string(observerSession.rawValue)])
                )
                expectLeaderSessionDenied(owner, sessionID: observerSession.rawValue)
            }
            #expect(await fixture.extensionCounter.methods == methods.count)

            let independentOwner = try await fixture.observer.request(
                id: 65, method: "x.ai/session/delete",
                params: .object(["sessionId": .string(historyID)])
            )
            #expect(independentOwner["authorized"]?.boolValue == true)

            let coreFork = try await fixture.owner.response(
                id: 66, method: AgentMethodNames.sessionFork,
                params: .object(["sessionId": .string(historyID)])
            )
            expectLeaderSessionDenied(coreFork, sessionID: historyID)
            let genericControl = try await fixture.owner.response(
                id: 67, method: "x.ai/mcp/upsert",
                params: .object(["session_id": .string(historyID)])
            )
            expectLeaderSessionDenied(genericControl, sessionID: historyID)
            try await fixture.owner.send(.notification(
                method: "x.ai/session/delete",
                params: .object(["sessionId": .string(ownerSession.rawValue)])
            ))
            let closed = try await fixture.owner.response(
                id: 70, method: AgentMethodNames.sessionClose,
                params: try JSONValue.encode(CloseSessionRequest(sessionId: ownerSession))
            )
            expectLeaderSuccess(closed)
            let replacement = try await fixture.owner.response(
                id: 71, method: AgentMethodNames.sessionNew,
                params: try JSONValue.encode(NewSessionRequest(cwd: fixture.directory.path))
            )
            expectLeaderSuccess(replacement)
            for (offset, method) in methods.enumerated() {
                let closedHistory = try await fixture.owner.response(
                    id: Int64(80 + offset), method: method.0,
                    params: .object([method.1: .string(ownerSession.rawValue)])
                )
                expectLeaderSessionDenied(closedHistory, sessionID: ownerSession.rawValue)
            }
            #expect(await fixture.extensionCounter.methods == methods.count + 1)
            #expect(await fixture.extensionCounter.notifications == 0)
        }
    }

    @Test("failed mutations and loads cannot reserve a future session identifier")
    func failedRequestsDoNotPreclaimFutureSession() async throws {
        try await withLeaderIsolationFixture { fixture in
            let future = AcpSessionId("leader-isolated-root")
            _ = try await fixture.owner.request(
                id: 97,
                method: AgentMethodNames.authenticate,
                params: .object(["methodId": .string("owner-auth")])
            )
            #expect(await fixture.runtime.connectionState() == .authenticated)

            try await fixture.observer.send(.request(
                id: .number(98),
                method: AgentMethodNames.initialize,
                params: try JSONValue.encode(InitializeRequest(protocolVersion: ProtocolVersion(2)))
            ))
            let unsupportedInitialization = try await fixture.observer.next {
                if case .response(.number(98), nil, _?) = $0 { return true }
                return false
            }
            guard case .response(_, nil, let unsupportedError?) = unsupportedInitialization else {
                Issue.record("an incompatible observer unexpectedly initialized")
                return
            }
            #expect(unsupportedError.code == .invalidRequest)
            #expect(await fixture.runtime.connectionState() == .authenticated)

            _ = try await fixture.observer.request(
                id: 99,
                method: AgentMethodNames.initialize,
                params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
            )
            #expect(await fixture.runtime.connectionState() == .authenticated)
            try await fixture.observer.send(.request(
                id: .number(100),
                method: AgentMethodNames.sessionPrompt,
                params: .object(["sessionId": .string(future.rawValue)])
            ))
            _ = try await fixture.observer.next {
                if case .response(.number(100), nil, _?) = $0 { return true }
                return false
            }

            try await fixture.observer.send(.request(
                id: .number(101),
                method: AgentMethodNames.sessionLoad,
                params: try JSONValue.encode(LoadSessionRequest(
                    sessionId: future,
                    cwd: fixture.directory.path
                ))
            ))
            _ = try await fixture.observer.next {
                if case .response(.number(101), nil, _?) = $0 { return true }
                return false
            }

            let created = try await fixture.createSession()
            #expect(created == future)
            try await fixture.observer.send(.request(
                id: .number(102),
                method: AgentMethodNames.sessionPrompt,
                params: try JSONValue.encode(PromptRequest(
                    sessionId: created,
                    prompt: [.text("observer must not own the future identifier")]
                ))
            ))
            _ = try await fixture.observer.next {
                if case .response(.number(102), nil, _?) = $0 { return true }
                return false
            }
            _ = try await fixture.owner.request(
                id: 103,
                method: AgentMethodNames.sessionPrompt,
                params: try JSONValue.encode(PromptRequest(
                    sessionId: created,
                    prompt: [.text("the genuine creator retains authority")]
                ))
            )
        }
    }

    @Test("real concurrent Unix clients cannot steal session ownership or another client's replay")
    func creatorRemainsOwnerAndReplayIsPrivate() async throws {
        try await withLeaderIsolationFixture { fixture in
            #expect(fixture.ownerID != fixture.observerID)
            let sessionID = try await fixture.createSession()

            _ = try await fixture.owner.request(
                id: 3,
                method: AgentMethodNames.sessionPrompt,
                params: try JSONValue.encode(PromptRequest(
                    sessionId: sessionID,
                    prompt: [.text("owner-private-user-marker")],
                    messageId: "owner-original-turn"
                ))
            )
            _ = await fixture.owner.drain()
            _ = await fixture.observer.drain()

            _ = try await fixture.observer.request(
                id: 4,
                method: AgentMethodNames.sessionLoad,
                params: try JSONValue.encode(LoadSessionRequest(
                    sessionId: sessionID,
                    cwd: fixture.directory.path,
                    meta: [
                        ACPLeaderCapabilityInjection.clientIDKey:
                            .number(.uint64(fixture.ownerID)),
                    ]
                ))
            )

            let observerNotifications = await fixture.observer.drain()
            let privateReplays = observerNotifications.compactMap(leaderIsolationReplayMetadata)
            #expect(!privateReplays.isEmpty)
            #expect(privateReplays.allSatisfy {
                $0[ACPLeaderCapabilityInjection.clientIDKey]?.uint64Value == fixture.observerID
            })
            #expect(privateReplays.allSatisfy {
                $0[ACPLeaderCapabilityInjection.clientIDKey]?.uint64Value != fixture.ownerID
            })
            #expect(await fixture.owner.messages().compactMap(leaderIsolationReplayMetadata).isEmpty)

            _ = try await fixture.owner.request(
                id: 5,
                method: AgentMethodNames.sessionPrompt,
                params: try JSONValue.encode(PromptRequest(
                    sessionId: sessionID,
                    prompt: [.text("shared-live-turn-marker")],
                    messageId: "owner-shared-turn"
                ))
            )
            for client in [fixture.owner, fixture.observer] {
                let live = try await client.next { message in
                    guard case .notification(let method, let params) = message,
                          method == ClientMethodNames.sessionUpdate
                    else { return false }
                    return params.objectValue?["update"]?.objectValue?["content"]?
                        .objectValue?["text"]?.stringValue == "shared-live-turn-marker"
                }
                #expect(leaderIsolationReplayMetadata(live) == nil)
            }
        }
    }

    @Test("observer cannot answer or receive the immutable driver's reverse authority requests")
    func reverseAuthorityRemainsWithFirstAuthenticatedDriver() async throws {
        try await withLeaderIsolationFixture { fixture in
            let sessionID = try await fixture.createSession()

            _ = try await fixture.observer.request(
                id: 10,
                method: AgentMethodNames.sessionLoad,
                params: try JSONValue.encode(LoadSessionRequest(
                    sessionId: sessionID,
                    cwd: fixture.directory.path
                ))
            )
            _ = await fixture.owner.drain()
            _ = await fixture.observer.drain()

            for (offset, method) in [
                "fs/read_text_file",
                "terminal/create",
                ClientMethodNames.sessionRequestPermission,
            ].enumerated() {
                let captured = ACPLeaderIsolationReverseResult()
                let reverse = Task {
                    let response = try await fixture.runtime.requestClient(
                        method: method,
                        params: .object(["sessionId": .string(sessionID.rawValue)])
                    )
                    await captured.record(response)
                    return response
                }
                let request = try await fixture.owner.next { $0.method == method }
                guard case .request(let requestID, _, _) = request else {
                    Issue.record("owner did not receive a real reverse request")
                    reverse.cancel()
                    return
                }
                #expect(await fixture.observer.messages().allSatisfy { $0.method != method })

                try await fixture.observer.send(.response(
                    id: requestID,
                    result: .object(["value": .string("stolen")]),
                    error: nil
                ))
                _ = try await fixture.observer.request(
                    id: Int64(100 + offset),
                    method: ACPLeaderRosterMethods.sessionsList,
                    params: .object([:])
                )
                #expect(await captured.value == nil)

                let authorized = JSONValue.object(["value": .string("authorized-\(offset)")])
                try await fixture.owner.send(.response(
                    id: requestID,
                    result: authorized,
                    error: nil
                ))
                #expect(try await reverse.value == authorized)
            }
        }
    }

    @Test("only the authenticated first driver can submit visible genuine-user idle interjections")
    func idleInterjectionRequiresDriverAndRetainsUserProvenance() async throws {
        try await withLeaderIsolationFixture { fixture in
            let sessionID = try await fixture.createSession()
            _ = try await fixture.observer.request(
                id: 20,
                method: AgentMethodNames.sessionLoad,
                params: try JSONValue.encode(LoadSessionRequest(
                    sessionId: sessionID,
                    cwd: fixture.directory.path
                ))
            )
            _ = await fixture.owner.drain()
            _ = await fixture.observer.drain()

            let gateway = ACPNotificationGateway()
            await gateway.attach(fixture.runtime)

            let observerOwns = await ACPLeaderRequestAuthority.$clientID.withValue(
                String(fixture.observerID)
            ) {
                await gateway.ownsSession(sessionID)
            }
            #expect(!observerOwns)
            let refused = try await ACPLeaderRequestAuthority.$clientID.withValue(
                String(fixture.observerID)
            ) {
                try await gateway.submitUserInterjection(
                    sessionId: sessionID,
                    promptID: "observer-forged-user-turn",
                    text: "observer cannot impersonate the connected owner"
                )
            }
            #expect(refused == .unknownSession)

            let admitted = try await ACPLeaderRequestAuthority.$clientID.withValue(
                String(fixture.ownerID)
            ) {
                try await gateway.submitUserInterjection(
                    sessionId: sessionID,
                    promptID: "owner-authentic-user-interjection",
                    text: "an actual user supplied this idle interjection"
                )
            }
            #expect(admitted == .accepted)

            for client in [fixture.owner, fixture.observer] {
                let message = try await client.next { message in
                    guard case .notification(let method, let params) = message,
                          method == ClientMethodNames.sessionUpdate,
                          let update = params.objectValue?["update"]?.objectValue
                    else { return false }
                    return update["sessionUpdate"]?.stringValue == "user_message_chunk"
                        && update["content"]?.objectValue?["text"]?.stringValue
                            == "an actual user supplied this idle interjection"
                }
                guard case .notification(_, let params) = message else { continue }
                #expect(params.objectValue?["update"]?.objectValue?["_meta"]?
                    .objectValue?["hideFromScrollback"]?.boolValue != true)
            }
        }
    }

    @Test("observers cannot prompt, cancel, close, fork, reconfigure, reset, or mutate owner sessions")
    func observerMutationAttemptsNeverAcquireAuthority() async throws {
        try await withLeaderIsolationFixture { fixture in
            let sessionID = try await fixture.createSession()
            let session = JSONValue.string(sessionID.rawValue)

            try await fixture.observer.send(.request(
                id: .number(29),
                method: AgentMethodNames.sessionPrompt,
                params: .object(["sessionId": session])
            ))
            let deniedBeforeAttach = try await fixture.observer.next {
                if case .response(.number(29), nil, _?) = $0 { return true }
                return false
            }
            #expect(deniedBeforeAttach.id == .number(29))
            _ = try await fixture.owner.request(
                id: 31,
                method: AgentMethodNames.sessionPrompt,
                params: try JSONValue.encode(PromptRequest(
                    sessionId: sessionID,
                    prompt: [.text("not visible to an unregistered attacker")],
                    messageId: "owner-before-observer-attachment"
                ))
            )
            #expect(await fixture.observer.messages().allSatisfy {
                $0.method != ClientMethodNames.sessionUpdate
            })

            _ = try await fixture.observer.request(
                id: 30,
                method: AgentMethodNames.sessionLoad,
                params: try JSONValue.encode(LoadSessionRequest(
                    sessionId: sessionID,
                    cwd: fixture.directory.path
                ))
            )

            let attacks: [(String, JSONValue)] = [
                (AgentMethodNames.sessionPrompt, .object(["sessionId": session])),
                (AgentMethodNames.sessionCancel, .object(["sessionId": session])),
                (AgentMethodNames.sessionClose, .object(["sessionId": session])),
                (AgentMethodNames.sessionFork, .object(["sessionId": session])),
                (AgentMethodNames.sessionSetMode, .object(["sessionId": session])),
                (AgentMethodNames.sessionSetModel, .object(["sessionId": session])),
                (AgentMethodNames.sessionSetConfigOption, .object(["sessionId": session])),
                ("x.ai/mcp/upsert", .object(["session_id": session])),
                ("x.ai/share_session", .object(["params": .object(["session_id": session])])),
                ("x.ai/session/fork", .object(["sourceSessionId": session])),
                ("x.ai/interject", .object(["sessionId": session])),
                ("x.ai/sessionless/control", .object([:])),
            ]
            for (offset, attack) in attacks.enumerated() {
                let requestID = Int64(40 + offset)
                try await fixture.observer.send(.request(
                    id: .number(requestID),
                    method: attack.0,
                    params: attack.1
                ))
                let response = try await fixture.observer.next {
                    if case .response(.number(requestID), _, _) = $0 { return true }
                    return false
                }
                guard case .response(_, nil, _?) = response else {
                    Issue.record("observer mutation unexpectedly succeeded: \(attack.0)")
                    continue
                }
            }
            #expect(await fixture.extensionCounter.methods == 0)

            try await fixture.observer.send(.notification(
                method: "x.ai/yolo_mode_changed",
                params: .object(["yolo_mode": .bool(true)])
            ))
            try await fixture.observer.send(.notification(
                method: "x.ai/permissions/reset",
                params: .object(["session_id": session])
            ))
            _ = try await fixture.observer.request(
                id: 90,
                method: ACPLeaderRosterMethods.sessionsList,
                params: .object([:])
            )
            #expect(await fixture.extensionCounter.notifications == 0)

            let authorized = try await fixture.owner.request(
                id: 91,
                method: "x.ai/interject",
                params: .object(["sessionId": session])
            )
            #expect(authorized["authorized"]?.boolValue == true)
            #expect(await fixture.extensionCounter.methods == 1)
        }
    }

    @Test("observer loads replay without replacing the owner's working directory")
    func observerLoadCannotReconfigureOwningSession() async throws {
        try await withLeaderIsolationFixture { fixture in
            let sessionID = try await fixture.createSession()
            let hostileDirectory = fixture.directory.appendingPathComponent("observer-workspace")
            try FileManager.default.createDirectory(
                at: hostileDirectory,
                withIntermediateDirectories: true
            )

            _ = try await fixture.observer.request(
                id: 60,
                method: AgentMethodNames.sessionLoad,
                params: try JSONValue.encode(LoadSessionRequest(
                    sessionId: sessionID,
                    cwd: hostileDirectory.path,
                    additionalDirectories: [hostileDirectory.path]
                ))
            )
            let listed = try await fixture.owner.request(
                id: 61,
                method: AgentMethodNames.sessionList,
                params: .object([:])
            )
            let sessions = try listed.decode(ListSessionsResponse.self)
            #expect(sessions.sessions.first?.cwd == fixture.directory.path)
        }
    }

    @Test("targeted replay for a departed observer never falls back to another subscriber")
    func departedReplayTargetIsDropped() async throws {
        try await withLeaderIsolationFixture { fixture in
            let sessionID = try await fixture.createSession()
            _ = try await fixture.observer.request(
                id: 70,
                method: AgentMethodNames.sessionLoad,
                params: try JSONValue.encode(LoadSessionRequest(
                    sessionId: sessionID,
                    cwd: fixture.directory.path
                ))
            )
            _ = await fixture.owner.drain()
            await fixture.observer.close()

            await fixture.host.route(.notification(
                method: ClientMethodNames.sessionUpdate,
                params: .object([
                    "sessionId": .string(sessionID.rawValue),
                    "update": .object([
                        "sessionUpdate": .string("agent_message_chunk"),
                        "content": .object([
                            "type": .string("text"),
                            "text": .string("departed-client-private-replay-marker"),
                        ]),
                    ]),
                    "_meta": .object([
                        "isReplay": .bool(true),
                        ACPLeaderCapabilityInjection.clientIDKey:
                            .number(.uint64(fixture.observerID)),
                    ]),
                ])
            ))

            #expect(await fixture.owner.messages().compactMap(leaderIsolationReplayMetadata).isEmpty)
        }
    }
}

#endif
