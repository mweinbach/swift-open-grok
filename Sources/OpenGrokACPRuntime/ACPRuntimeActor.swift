import Foundation
import OpenGrokACP
import OpenGrokShared

/// A prompt turn's result plus the error the driver actually threw, kept
/// separately because the response flattens failures into `.refusal` while
/// `prompt_complete` must report upstream's ("error", detail) pair from the
/// same source the response came from (the invariant turn_end.rs:323-326
/// documents: the two signals must never disagree).
private struct PromptRunOutcome: Sendable {
    var response: PromptResponse
    var failure: AcpError?
}

private actor ACPQueuedPromptAdmission {
    enum Resolution: Sendable {
        case admitted(PromptRequest)
        case cancelled
    }

    private var resolution: Resolution?
    private var continuation: CheckedContinuation<Resolution, Never>?

    func wait() async -> Resolution {
        if let resolution {
            return resolution
        }
        return await withCheckedContinuation { continuation in
            if let resolution {
                continuation.resume(returning: resolution)
            } else {
                self.continuation = continuation
            }
        }
    }

    func resolve(_ resolution: Resolution) {
        guard self.resolution == nil else { return }
        self.resolution = resolution
        continuation?.resume(returning: resolution)
        continuation = nil
    }
}

private struct ACPQueuedPrompt: Sendable {
    var request: PromptRequest
    let id: String
    let owner: String?
    var lastEditor: String?
    var version: UInt64
    let kind: String
    var text: String
    let admission: ACPQueuedPromptAdmission
}

private actor ACPTransportWriter {
    private let transport: any ACPTransport

    init(transport: any ACPTransport) {
        self.transport = transport
    }

    func send(_ message: ACPMessage) async throws {
        try await transport.send(message)
    }
}

public actor ACPAgentRuntime {
    public typealias NotificationSink = @Sendable (ACPMessage) async -> Void
    public typealias SessionOpenedHook = @Sendable (AcpSessionId, AcpMeta?) async throws -> Void
    public typealias SessionClosedHook = @Sendable (AcpSessionId) async -> Void
    public typealias PeerPromptPreparation = @Sendable () async throws -> Void
    public typealias SessionOwnerVerifier = @Sendable (AcpSessionId, String) async -> Bool

    public enum PeerPromptAdmission: Sendable, Equatable {
        case accepted
        case busy
        case unknownSession
    }

    private let configuration: ACPAgentConfiguration
    private let store: any ACPSessionStore
    private let promptDriver: any ACPPromptDriver
    private let workspaceBoundary: (any ACPWorkspaceBoundary)?
    private let extensionRouter: ACPExtensionMethodRouter?
    /// Inbound extension-notification dispatch — upstream's `ext_notification`
    /// surface (acp_agent.rs:4481-4720), a separate table from the ext-METHOD
    /// router above: a JSON-RPC notification never reaches the method table
    /// and an unmatched name is ignored, not answered with an error.
    private let extensionNotifications: ACPExtensionNotificationRouter?
    private let reverseRequests: ACPReverseRequestBroker
    private let onSessionOpened: SessionOpenedHook?
    private let onSessionClosed: SessionClosedHook?
    private let makeSessionId: @Sendable () -> String
    private let timestamp: @Sendable () -> String
    private let rosterTimestampMilliseconds: @Sendable () -> Int64

    private var state: ACPConnectionState = .connected
    private var authenticated = false
    private var activePrompts: [AcpSessionId: Task<PromptRunOutcome, Never>] = [:]
    /// Durable prompt echoes suspend; reserve admission first so a peer cannot
    /// start a second turn while the ordinary prompt is recording its input.
    private var startingPrompts: Set<AcpSessionId> = []
    private var pendingPromptQueues: [AcpSessionId: [ACPQueuedPrompt]] = [:]
    private var queueEditingHolds: [AcpSessionId: Set<String>] = [:]
    private var runningQueuePrompts: [AcpSessionId: (
        id: String,
        text: String,
        kind: String,
        combinedTexts: [String]?
    )] = [:]
    private var combineQueuedPrompts = false
    private var peerPromptGenerations: [AcpSessionId: UUID] = [:]
    private var pendingRosterInteractions: [AcpSessionId: Int] = [:]
    private var rosterMetadata: [AcpSessionId: RosterMetadata] = [:]
    private var requestIDs: Set<AcpRequestId> = []
    private var queuedNotifications: [ACPMessage] = []
    private var notificationSink: NotificationSink?
    private var rosterNotificationSink: NotificationSink?
    private var reverseSender: (@Sendable (ACPMessage) async throws -> Void)?
    private var sessionOwnerVerifier: SessionOwnerVerifier?
    private var openedLifecycleSessions: Set<AcpSessionId> = []

    private struct RosterMetadata: Sendable {
        var title: String?
        var yolo: Bool
    }

    public init(
        configuration: ACPAgentConfiguration = ACPAgentConfiguration(),
        store: any ACPSessionStore = InMemoryACPSessionStore(),
        promptDriver: any ACPPromptDriver = ACPNoopPromptDriver(),
        workspaceBoundary: (any ACPWorkspaceBoundary)? = nil,
        extensionRouter: ACPExtensionMethodRouter? = nil,
        extensionHandler: (any ACPAgentExtensionHandler)? = nil,
        extensionNotifications: ACPExtensionNotificationRouter? = nil,
        reverseRequests: ACPReverseRequestBroker = ACPReverseRequestBroker(),
        onSessionOpened: SessionOpenedHook? = nil,
        onSessionClosed: SessionClosedHook? = nil,
        makeSessionId: @escaping @Sendable () -> String = { UUID().uuidString },
        timestamp: @escaping @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) },
        rosterTimestampMilliseconds: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.configuration = configuration
        self.store = store
        self.promptDriver = promptDriver
        self.workspaceBoundary = workspaceBoundary
        if let extensionRouter {
            self.extensionRouter = extensionRouter
        } else if let extensionHandler {
            self.extensionRouter = ACPExtensionMethodRouter().register(
                catchAll: extensionHandler
            )
        } else {
            self.extensionRouter = nil
        }
        self.extensionNotifications = extensionNotifications
        self.reverseRequests = reverseRequests
        self.onSessionOpened = onSessionOpened
        self.onSessionClosed = onSessionClosed
        self.makeSessionId = makeSessionId
        self.timestamp = timestamp
        self.rosterTimestampMilliseconds = rosterTimestampMilliseconds
    }

    public func connectionState() -> ACPConnectionState {
        state
    }

    public func setNotificationSink(_ sink: NotificationSink?) {
        notificationSink = sink
    }

    func setRosterNotificationSink(_ sink: NotificationSink?) {
        rosterNotificationSink = sink
    }

    public func setReverseSender(_ sender: (@Sendable (ACPMessage) async throws -> Void)?) {
        reverseSender = sender
    }

    public func setSessionOwnerVerifier(_ verifier: SessionOwnerVerifier?) {
        sessionOwnerVerifier = verifier
    }

    /// Apply the effective `[ui].combine_queued_prompts` value to future turns.
    ///
    /// Queue promotion samples this actor-isolated flag only after the active
    /// turn exits, so toggling it cannot rewrite a request already in flight.
    public func setCombineQueuedPrompts(_ enabled: Bool) {
        combineQueuedPrompts = enabled
    }

    public func hasConnectedReverseClient() -> Bool {
        state != .closed && reverseSender != nil
    }

    public func requestClient(method: String, params: JSONValue) async throws -> JSONValue {
        guard let reverseSender else {
            throw ACPRuntimeError.transport("no ACP client is connected")
        }
        let interactionSession = Self.rosterInteractionSession(method: method, params: params)
        if let interactionSession {
            pendingRosterInteractions[interactionSession, default: 0] += 1
            await publishRosterUpsert(sessionId: interactionSession, activity: .needsInput)
        }
        do {
            let response = try await reverseRequests.request(
                method: method,
                params: params,
                send: reverseSender
            )
            if let interactionSession {
                await endRosterInteraction(sessionId: interactionSession)
            }
            return response
        } catch {
            if let interactionSession {
                await endRosterInteraction(sessionId: interactionSession)
            }
            throw error
        }
    }

    public func readTextFile(
        sessionId: AcpSessionId,
        path: String,
        line: UInt32? = nil,
        limit: UInt32? = nil
    ) async throws -> String {
        try requireReady()
        guard let session = try await store.read(sessionId) else {
            throw ACPRuntimeError.sessionNotFound(sessionId)
        }
        guard !session.closed else { throw ACPRuntimeError.sessionClosed(sessionId) }
        guard let workspaceBoundary else {
            throw ACPRuntimeError.workspace("workspace boundary is not configured")
        }
        return try await workspaceBoundary.readTextFile(
            sessionId: sessionId,
            path: path,
            line: line,
            limit: limit
        )
    }

    public func writeTextFile(
        sessionId: AcpSessionId,
        path: String,
        content: String
    ) async throws {
        try requireReady()
        guard let session = try await store.read(sessionId) else {
            throw ACPRuntimeError.sessionNotFound(sessionId)
        }
        guard !session.closed else { throw ACPRuntimeError.sessionClosed(sessionId) }
        guard let workspaceBoundary else {
            throw ACPRuntimeError.workspace("workspace boundary is not configured")
        }
        try await workspaceBoundary.writeTextFile(sessionId: sessionId, path: path, content: content)
    }

    public func pollNotifications() -> [ACPMessage] {
        defer { queuedNotifications.removeAll() }
        return queuedNotifications
    }

    public func close() async {
        guard state != .closed else { return }
        state = .closed
        for task in activePrompts.values {
            task.cancel()
        }
        activePrompts.removeAll()
        startingPrompts.removeAll()
        let queuedPrompts = pendingPromptQueues.values.flatMap { $0 }
        pendingPromptQueues.removeAll()
        queueEditingHolds.removeAll()
        runningQueuePrompts.removeAll()
        for queued in queuedPrompts {
            await queued.admission.resolve(.cancelled)
        }
        peerPromptGenerations.removeAll()
        let sessions = openedLifecycleSessions
        openedLifecycleSessions.removeAll()
        if let onSessionClosed {
            for session in sessions {
                await onSessionClosed(session)
            }
        }
        await reverseRequests.cancelAll()
        rosterNotificationSink = nil
        reverseSender = nil
    }

    public func serve(_ transport: any ACPTransport) async {
        let writer = ACPTransportWriter(transport: transport)
        setNotificationSink { message in
            try? await writer.send(message)
        }
        setReverseSender { message in
            try await writer.send(message)
        }
        let runtime = self
        let dispatchAndSend: @Sendable (ACPMessage) async -> Void = { incoming in
            let outgoing = await runtime.handle(incoming)
            for message in outgoing {
                do {
                    try await writer.send(message)
                } catch {
                    await runtime.close()
                    return
                }
            }
        }

        // Initialization is a protocol barrier: upstream guarantees it runs
        // before any session-creating request (mvp_agent/acp_agent.rs:299-302),
        // and reconnect replay explicitly awaits its response before restoring
        // sessions (xai-grok-pager-bin/src/main.rs:822-845). Once that response
        // is on the wire, requests must remain concurrent so session/cancel
        // can interrupt a session/prompt that has not returned yet.
        await withTaskGroup(of: Void.self) { group in
            do {
                while state != .closed {
                    let incoming = try await transport.receive()
                    if case .request(_, let method, _) = incoming,
                       method == AgentMethodNames.initialize
                    {
                        await dispatchAndSend(incoming)
                    } else {
                        group.addTask {
                            await dispatchAndSend(incoming)
                        }
                    }
                }
            } catch {
                await close()
            }
        }
        await transport.close()
    }

    public func serve(_ channel: AcpAgentChannel) async {
        setNotificationSink { message in
            if message.method == ClientMethodNames.sessionUpdate,
               let params = message.params,
               let notification = try? params.decode(SessionNotification.self) {
                let args = AcpArgs(request: notification)
                _ = channel.send(.sessionNotification(args))
                return
            }
            // Extension notifications (`x.ai/session/prompt_complete`,
            // `x.ai/session_notification`, ...) ride the typed channel as
            // `.extNotification` client messages, the same classification
            // `decodeAcpClientMessage` gives an unknown notification method.
            guard case .notification(let method, let params) = message else { return }
            let decoded = decodeAcpClientMessage(
                method: method,
                params: params,
                isNotification: true
            )
            guard case .success(let clientMessage) = decoded else { return }
            _ = channel.send(clientMessage)
        }
        setReverseSender { [reverseRequests] message in
            guard case .request(let id, let method, let params) = message else {
                throw ACPRuntimeError.transport("reverse ACP message is not a request")
            }
            let responseChannel = ResponseChannel<JSONValue>()
            let decoded = decodeAcpClientMessage(
                method: method,
                params: params,
                responseChannel: responseChannel
            )
            guard case .success(let clientMessage) = decoded else {
                throw ACPRuntimeError.invalidParams("unable to decode reverse method \(method)")
            }
            guard channel.send(clientMessage) else {
                throw ACPRuntimeError.transport("ACP client channel is closed")
            }
            switch await responseChannel.awaitResponse() {
            case .success(let result):
                guard await reverseRequests.resolve(.response(id: id, result: result, error: nil)) else {
                    throw ACPRuntimeError.transport("reverse ACP response has no pending request")
                }
            case .failure(let error):
                throw error
            }
        }
        let runtime = self
        await withTaskGroup(of: Void.self) { group in
            for await message in channel.messages {
                group.addTask {
                    await runtime.handleTyped(message)
                }
            }
            await runtime.close()
            group.cancelAll()
        }
    }

    @discardableResult
    public func handle(_ message: ACPMessage) async -> [ACPMessage] {
        switch message {
        case .response:
            _ = await reverseRequests.resolve(message)
            return []
        case .notification(let method, let params):
            let route = ACPMethodRoute.normalize(method: method, params: params)
            if Self.coreAgentMethods.contains(route.method) {
                do {
                    _ = try await dispatch(method: method, params: params)
                } catch {
                    await emitProtocolError(error)
                }
            } else {
                do {
                    try requireReady()
                } catch {
                    return []
                }
                if await !mayControlLeaderSession(from: route.params) {
                    return []
                }
                // Upstream routes every non-core JSON-RPC notification to
                // `ext_notification`, which matches known names and silently
                // ignores the rest (acp_agent.rs:4481-4720). The ext-METHOD
                // router never sees notifications — a method table entry
                // must not be executable without a response channel.
                if !(await handleQueueNotification(method: route.method, params: route.params)) {
                    await extensionNotifications?.dispatch(method: route.method, params: route.params)
                }
            }
            return []
        case .request(let id, let method, let params):
            guard requestIDs.insert(id).inserted else {
                return [.response(
                    id: id,
                    result: nil,
                    error: ACPRuntimeError.duplicateRequest(id).acpError
                )]
            }
            do {
                let result = try await dispatch(method: method, params: params)
                return [.response(id: id, result: result, error: nil)]
            } catch {
                return [.response(id: id, result: nil, error: protocolError(for: error))]
            }
        }
    }

    private func dispatch(method: String, params: JSONValue) async throws -> JSONValue {
        let route = ACPMethodRoute.normalize(method: method, params: params)
        if sessionOwnerVerifier != nil,
           Self.driverControlledCoreMethods.contains(route.method),
           await !mayControlLeaderSession(from: route.params)
        {
            if let sessionID = Self.sessionID(in: route.params) {
                throw ACPRuntimeError.sessionNotFound(sessionID)
            }
            throw ACPRuntimeError.authenticationRequired
        }
        switch route.method {
        case AgentMethodNames.initialize:
            return try await initialize(route.params)
        case AgentMethodNames.authenticate:
            return try await authenticate(route.params)
        case AgentMethodNames.logout:
            return try await logout(route.params)
        case AgentMethodNames.sessionNew:
            return try await newSession(route.params)
        case AgentMethodNames.sessionLoad:
            return try await loadSession(route.params)
        case AgentMethodNames.sessionResume:
            return try await resumeSession(route.params)
        case AgentMethodNames.sessionFork:
            return try await forkSession(route.params)
        case AgentMethodNames.sessionList:
            return try await listSessions(route.params)
        case AgentMethodNames.sessionClose:
            return try await closeSession(route.params)
        case AgentMethodNames.sessionPrompt:
            return try await prompt(route.params)
        case AgentMethodNames.sessionCancel:
            return try await cancel(route.params)
        case AgentMethodNames.sessionSetMode, AgentMethodNames.sessionSetModeCamel:
            return try await setMode(route.params)
        case AgentMethodNames.sessionSetModel, AgentMethodNames.sessionSetModelCamel:
            return try await setModel(route.params)
        case AgentMethodNames.sessionSetConfigOption:
            return try await setConfigOption(route.params)
        case ACPLeaderRosterMethods.sessionsList:
            return try await listRoster()
        default:
            try requireReady()
            guard let extensionRouter else {
                throw ACPRuntimeError.methodNotFound(route.method)
            }
            if await !mayControlLeaderSession(from: route.params) {
                if extensionRouter.hasExactRoute(route.method),
                   let hidden = Self.hiddenDeniedLeaderExtensionResponse(
                    method: route.method,
                    params: route.params
                   )
                {
                    return hidden
                }
                if let sessionID = Self.sessionID(in: route.params) {
                    throw ACPRuntimeError.sessionNotFound(sessionID)
                }
                throw ACPRuntimeError.authenticationRequired
            }
            return try await extensionRouter.dispatch(method: route.method, params: route.params)
        }
    }

    /// These two upstream endpoints hide an inaccessible child as missing.
    /// Build that inert wire response only after authority has already been
    /// denied; invoking the registered handler here would reopen its mutation
    /// path before the owner-scoped checks can safely defend it.
    private static func hiddenDeniedLeaderExtensionResponse(
        method: String,
        params: JSONValue
    ) -> JSONValue? {
        guard case .object(let fields) = params,
              case .string(let subagentID)? = fields["subagentId"]
        else {
            return nil
        }

        switch method {
        case "x.ai/subagent/cancel":
            return .object([
                "result": .object([
                    "subagentId": .string(subagentID),
                    "cancelled": .bool(false),
                    "outcome": .object(["kind": .string("not_found")]),
                ])
            ])
        case "x.ai/subagent/get":
            return .object([
                "result": .object(["snapshot": .null])
            ])
        default:
            return nil
        }
    }

    private func handleTyped<T: AcpRequest>(_ args: AcpArgs<T>) async {
        do {
            let params = try JSONValue.encode(args.request)
            let result = try await dispatch(method: args.methodName, params: params)
            let response = try result.decode(T.Response.self)
            _ = args.respond(.success(response))
        } catch {
            _ = args.respond(.failure(protocolError(for: error)))
        }
    }

    private func handleTyped(_ message: AcpAgentMessage) async {
        switch message {
        case .initialize(let args): await handleTyped(args)
        case .authenticate(let args): await handleTyped(args)
        case .newSession(let args): await handleTyped(args)
        case .loadSession(let args): await handleTyped(args)
        case .resumeSession(let args): await handleTyped(args)
        case .forkSession(let args): await handleTyped(args)
        case .listSessions(let args): await handleTyped(args)
        case .closeSession(let args): await handleTyped(args)
        case .prompt(let args): await handleTyped(args)
        case .cancel(let args): await handleTyped(args)
        case .setSessionMode(let args): await handleTyped(args)
        case .setSessionModel(let args): await handleTyped(args)
        case .setSessionConfigOption(let args): await handleTyped(args)
        case .logout(let args): await handleTyped(args)
        case .extMethod(let args): await handleTyped(args)
        case .extNotification(let args):
            // Same table as the wire `.notification` arm: the typed channel's
            // ext notifications go to `ext_notification` dispatch, never the
            // method router, and always acknowledge empty (a notification has
            // no failure channel — acp_agent.rs:4481 returns Ok on every arm).
            do {
                try requireReady()
                if await mayControlLeaderSession(from: args.request.params) {
                    if !(await handleQueueNotification(
                        method: args.request.method,
                        params: args.request.params
                    )) {
                        await extensionNotifications?.dispatch(
                            method: args.request.method,
                            params: args.request.params
                        )
                    }
                }
            } catch {}
            _ = args.respond(.success(EmptyAcpResponse()))
        case .askUserQuestion(let args): await handleTyped(args)
        }
    }

    /// The core agent methods `dispatch` matches by name. A notification
    /// naming anything else is an extension notification (upstream's split
    /// between the generated core dispatch and `ext_notification`).
    private static let coreAgentMethods: Set<String> = [
        AgentMethodNames.initialize,
        AgentMethodNames.authenticate,
        AgentMethodNames.logout,
        AgentMethodNames.sessionNew,
        AgentMethodNames.sessionLoad,
        AgentMethodNames.sessionResume,
        AgentMethodNames.sessionFork,
        AgentMethodNames.sessionList,
        AgentMethodNames.sessionClose,
        AgentMethodNames.sessionPrompt,
        AgentMethodNames.sessionCancel,
        AgentMethodNames.sessionSetMode,
        AgentMethodNames.sessionSetModeCamel,
        AgentMethodNames.sessionSetModel,
        AgentMethodNames.sessionSetModelCamel,
        AgentMethodNames.sessionSetConfigOption,
    ]

    private static let driverControlledCoreMethods: Set<String> = [
        AgentMethodNames.logout,
        AgentMethodNames.sessionFork,
        AgentMethodNames.sessionClose,
        AgentMethodNames.sessionPrompt,
        AgentMethodNames.sessionCancel,
        AgentMethodNames.sessionSetMode,
        AgentMethodNames.sessionSetModeCamel,
        AgentMethodNames.sessionSetModel,
        AgentMethodNames.sessionSetModelCamel,
        AgentMethodNames.sessionSetConfigOption,
    ]

    private func initialize(_ params: JSONValue) async throws -> JSONValue {
        guard state == .connected else {
            throw ACPRuntimeError.invalidState(expected: ACPConnectionState.connected.rawValue, actual: state.rawValue)
        }
        let request = try decode(InitializeRequest.self, from: params, method: AgentMethodNames.initialize)
        guard request.protocolVersion == configuration.protocolVersion else {
            throw ACPRuntimeError.protocolVersionUnsupported(request.protocolVersion)
        }
        state = .initialized
        var meta = configuration.meta ?? [:]
        if onSessionOpened != nil && reverseSender != nil {
            meta["x.ai/mcp/sdk"] = .bool(true)
        } else {
            meta.removeValue(forKey: "x.ai/mcp/sdk")
        }
        return try encode(InitializeResponse(
            protocolVersion: configuration.protocolVersion,
            agentCapabilities: configuration.agentCapabilities,
            authMethods: configuration.authMethods,
            agentInfo: configuration.agentInfo,
            meta: meta.isEmpty ? nil : meta
        ))
    }

    private func authenticate(_ params: JSONValue) async throws -> JSONValue {
        try requireInitialized()
        let request = try decode(AuthenticateRequest.self, from: params, method: AgentMethodNames.authenticate)
        if !configuration.authMethods.isEmpty,
           !configuration.authMethods.contains(where: { $0.id == request.methodId }) {
            throw ACPRuntimeError.invalidParams("unsupported authentication method \(request.methodId)")
        }
        authenticated = true
        state = .authenticated
        return try encode(AuthenticateResponse())
    }

    private func logout(_ params: JSONValue) async throws -> JSONValue {
        try requireInitialized()
        _ = try decode(LogoutRequest.self, from: params, method: AgentMethodNames.logout)
        authenticated = false
        state = .initialized
        return try encode(LogoutResponse())
    }

    private func newSession(_ params: JSONValue) async throws -> JSONValue {
        try requireReady()
        let request = try decode(NewSessionRequest.self, from: params, method: AgentMethodNames.sessionNew)
        let cwd = try await validateWorkspace(request.cwd)
        let session = ACPSessionSnapshot(
            sessionId: AcpSessionId(makeSessionId()),
            cwd: cwd,
            additionalDirectories: request.additionalDirectories,
            mcpServers: request.mcpServers,
            modeId: configuration.modes?.currentModeId,
            modelId: configuration.models?.currentModelId,
            createdAt: timestamp(),
            updatedAt: timestamp()
        )
        try await openSessionLifecycle(sessionId: session.sessionId, meta: request.meta)
        do {
            try await store.create(session)
        } catch {
            await closeSessionLifecycle(sessionId: session.sessionId)
            throw error
        }
        rosterMetadata[session.sessionId] = RosterMetadata(
            title: nil,
            yolo: Self.metaBool(request.meta, key: "yoloMode") ?? false
        )
        await publishRosterUpsert(sessionId: session.sessionId)
        return try encode(NewSessionResponse(
            sessionId: session.sessionId,
            modes: configuration.modes,
            models: configuration.models
        ))
    }

    private func loadSession(_ params: JSONValue) async throws -> JSONValue {
        try requireReady()
        let request = try decode(LoadSessionRequest.self, from: params, method: AgentMethodNames.sessionLoad)
        guard var session = try await store.read(request.sessionId) else {
            throw ACPRuntimeError.sessionNotFound(request.sessionId)
        }
        if sessionOwnerVerifier != nil,
           openedLifecycleSessions.contains(request.sessionId),
           await !ownsSession(request.sessionId)
        {
            guard !session.closed else { throw ACPRuntimeError.sessionClosed(request.sessionId) }
            await replay(session, leaderClientID: request.meta?[ACPLeaderCapabilityInjection.clientIDKey])
            if pendingPromptQueues[session.sessionId] != nil {
                await publishQueueChanged(sessionID: session.sessionId)
            }
            return try encode(LoadSessionResponse(modes: configuration.modes, models: configuration.models))
        }
        session.cwd = try await validateWorkspace(request.cwd)
        session.additionalDirectories = request.additionalDirectories
        session.mcpServers = request.mcpServers
        session.closed = false
        session.updatedAt = timestamp()
        if request.meta != nil {
            try await openSessionLifecycle(sessionId: session.sessionId, meta: request.meta)
        }
        do {
            try await store.update(session)
        } catch {
            if request.meta != nil {
                await closeSessionLifecycle(sessionId: session.sessionId)
            }
            throw error
        }
        updateRosterMetadata(sessionId: session.sessionId, meta: request.meta)
        await replay(session, leaderClientID: request.meta?[ACPLeaderCapabilityInjection.clientIDKey])
        if pendingPromptQueues[session.sessionId] != nil {
            await publishQueueChanged(sessionID: session.sessionId)
        }
        await publishRosterUpsert(sessionId: session.sessionId)
        return try encode(LoadSessionResponse(modes: configuration.modes, models: configuration.models))
    }

    private func resumeSession(_ params: JSONValue) async throws -> JSONValue {
        try requireReady()
        let request = try decode(ResumeSessionRequest.self, from: params, method: AgentMethodNames.sessionResume)
        guard var session = try await store.read(request.sessionId) else {
            throw ACPRuntimeError.sessionNotFound(request.sessionId)
        }
        if sessionOwnerVerifier != nil,
           openedLifecycleSessions.contains(request.sessionId),
           await !ownsSession(request.sessionId)
        {
            guard !session.closed else { throw ACPRuntimeError.sessionClosed(request.sessionId) }
            await replay(session, leaderClientID: request.meta?[ACPLeaderCapabilityInjection.clientIDKey])
            if pendingPromptQueues[session.sessionId] != nil {
                await publishQueueChanged(sessionID: session.sessionId)
            }
            return try encode(ResumeSessionResponse(modes: configuration.modes, models: configuration.models))
        }
        if let cwd = request.cwd {
            session.cwd = try await validateWorkspace(cwd)
        }
        if !request.additionalDirectories.isEmpty {
            session.additionalDirectories = request.additionalDirectories
        }
        if !request.mcpServers.isEmpty {
            session.mcpServers = request.mcpServers
        }
        session.closed = false
        session.updatedAt = timestamp()
        if request.meta != nil {
            try await openSessionLifecycle(sessionId: session.sessionId, meta: request.meta)
        }
        do {
            try await store.update(session)
        } catch {
            if request.meta != nil {
                await closeSessionLifecycle(sessionId: session.sessionId)
            }
            throw error
        }
        updateRosterMetadata(sessionId: session.sessionId, meta: request.meta)
        await replay(session, leaderClientID: request.meta?[ACPLeaderCapabilityInjection.clientIDKey])
        if pendingPromptQueues[session.sessionId] != nil {
            await publishQueueChanged(sessionID: session.sessionId)
        }
        await publishRosterUpsert(sessionId: session.sessionId)
        return try encode(ResumeSessionResponse(modes: configuration.modes, models: configuration.models))
    }

    private func forkSession(_ params: JSONValue) async throws -> JSONValue {
        try requireReady()
        let request = try decode(ForkSessionRequest.self, from: params, method: AgentMethodNames.sessionFork)
        guard let source = try await store.read(request.sessionId) else {
            throw ACPRuntimeError.sessionNotFound(request.sessionId)
        }
        let cwd = try await validateWorkspace(request.cwd ?? source.cwd)
        let now = timestamp()
        let fork = ACPSessionSnapshot(
            sessionId: AcpSessionId(makeSessionId()),
            cwd: cwd,
            additionalDirectories: request.additionalDirectories.isEmpty ? source.additionalDirectories : request.additionalDirectories,
            mcpServers: request.mcpServers.isEmpty ? source.mcpServers : request.mcpServers,
            modeId: source.modeId,
            modelId: source.modelId,
            createdAt: now,
            updatedAt: now,
            durableUpdates: source.durableUpdates
        )
        try await store.create(fork)
        rosterMetadata[fork.sessionId] = rosterMetadata[source.sessionId]
            ?? RosterMetadata(title: nil, yolo: false)
        await publishRosterUpsert(sessionId: fork.sessionId)
        return try encode(ForkSessionResponse(
            sessionId: fork.sessionId,
            modes: configuration.modes,
            models: configuration.models
        ))
    }

    private func listSessions(_ params: JSONValue) async throws -> JSONValue {
        try requireReady()
        let request = try decode(ListSessionsRequest.self, from: params, method: AgentMethodNames.sessionList)
        let stored = try await store.list(cwd: request.cwd)
        let sessions = stored.map {
            AcpSessionInfo(sessionId: $0.sessionId, cwd: $0.cwd, updatedAt: $0.updatedAt)
        }
        return try encode(ListSessionsResponse(sessions: sessions))
    }

    private func listRoster() async throws -> JSONValue {
        try requireReady()
        let stored = try await store.list(cwd: nil)
        let sessions = stored
            .filter { !$0.closed }
            .map { rosterEntry(for: $0) }
            .sorted {
                if $0.lastChangeUnixMs == $1.lastChangeUnixMs {
                    return $0.sessionId < $1.sessionId
                }
                return $0.lastChangeUnixMs > $1.lastChangeUnixMs
            }
        return try encode(ACPLeaderRosterListResponse(sessions: sessions))
    }

    private func closeSession(_ params: JSONValue) async throws -> JSONValue {
        try requireReady()
        let request = try decode(CloseSessionRequest.self, from: params, method: AgentMethodNames.sessionClose)
        guard var session = try await store.read(request.sessionId) else {
            throw ACPRuntimeError.sessionNotFound(request.sessionId)
        }
        startingPrompts.remove(request.sessionId)
        activePrompts[request.sessionId]?.cancel()
        await cancelQueuedPrompts(sessionID: request.sessionId)
        runningQueuePrompts.removeValue(forKey: request.sessionId)
        await promptDriver.cancel(sessionId: request.sessionId)
        session.closed = true
        session.updatedAt = timestamp()
        try await store.update(session)
        await closeSessionLifecycle(sessionId: request.sessionId)
        await publishRosterRemoved(sessionId: request.sessionId)
        rosterMetadata.removeValue(forKey: request.sessionId)
        pendingRosterInteractions.removeValue(forKey: request.sessionId)
        return try encode(CloseSessionResponse())
    }

    private func openSessionLifecycle(sessionId: AcpSessionId, meta: AcpMeta?) async throws {
        do {
            try await onSessionOpened?(sessionId, meta)
            guard state != .closed else {
                throw ACPRuntimeError.transport("ACP client disconnected while opening its session")
            }
            openedLifecycleSessions.insert(sessionId)
        } catch {
            await onSessionClosed?(sessionId)
            openedLifecycleSessions.remove(sessionId)
            throw error
        }
    }

    private func closeSessionLifecycle(sessionId: AcpSessionId) async {
        guard openedLifecycleSessions.remove(sessionId) != nil else { return }
        await onSessionClosed?(sessionId)
    }

    private static func promptQueueText(_ request: PromptRequest) -> String {
        request.prompt.compactMap { block in
            guard case .text(let content) = block else { return nil }
            return content.text
        }.joined(separator: "\n")
    }

    private func publishQueueChanged(sessionID: AcpSessionId) async {
        let entries = pendingPromptQueues[sessionID, default: []].enumerated().map { position, entry in
            var fields: [String: JSONValue] = [
                "id": .string(entry.id),
                "version": .number(.uint64(entry.version)),
                "kind": .string(entry.kind),
                "text": .string(entry.text),
                "position": .number(.int64(Int64(position))),
            ]
            if let owner = entry.owner {
                fields["owner"] = .string(owner)
            }
            if let lastEditor = entry.lastEditor {
                fields["lastEditor"] = .string(lastEditor)
            }
            return JSONValue.object(fields)
        }

        var fields: [String: JSONValue] = [
            "sessionId": .string(sessionID.rawValue),
            "entries": .array(entries),
        ]
        if let running = runningQueuePrompts[sessionID] {
            fields["runningPromptId"] = .string(running.id)
            fields["runningText"] = .string(running.text)
            fields["runningKind"] = .string(running.kind)
            if let combinedTexts = running.combinedTexts, combinedTexts.count >= 2 {
                fields["runningCombinedTexts"] = .array(combinedTexts.map(JSONValue.string))
            }
        }
        await sendExtensionNotification(method: "x.ai/queue/changed", params: .object(fields))
    }

    private func cancelQueuedPrompts(sessionID: AcpSessionId) async {
        let removed = pendingPromptQueues.removeValue(forKey: sessionID) ?? []
        queueEditingHolds.removeValue(forKey: sessionID)
        for entry in removed {
            await entry.admission.resolve(.cancelled)
        }
    }

    private func cancelQueuedPrompt(
        sessionID: AcpSessionId,
        id: String,
        admission: ACPQueuedPromptAdmission
    ) async {
        guard let index = pendingPromptQueues[sessionID]?.firstIndex(where: {
            $0.id == id && $0.admission === admission
        }), let entry = pendingPromptQueues[sessionID]?.remove(at: index)
        else { return }
        queueEditingHolds[sessionID]?.remove(id)
        await entry.admission.resolve(.cancelled)
        await publishQueueChanged(sessionID: sessionID)
    }

    private func promoteNextQueuedPrompt(sessionID: AcpSessionId) async {
        guard pendingPromptQueues[sessionID] != nil else { return }
        guard state != .closed,
              openedLifecycleSessions.contains(sessionID),
              activePrompts[sessionID] == nil,
              !startingPrompts.contains(sessionID)
        else { return }

        guard var entry = pendingPromptQueues[sessionID]?.first else {
            pendingPromptQueues.removeValue(forKey: sessionID)
            queueEditingHolds.removeValue(forKey: sessionID)
            await publishQueueChanged(sessionID: sessionID)
            return
        }

        guard queueEditingHolds[sessionID]?.contains(entry.id) != true else { return }

        var mergedFollowers: [ACPQueuedPrompt] = []
        var combinedTexts = [entry.text]
        if combineQueuedPrompts, Self.isMergeableQueuedPrompt(entry, allowImages: true) {
            let queue = pendingPromptQueues[sessionID, default: []]
            var combinedUTF8Count = entry.text.utf8.count
            for follower in queue.dropFirst() {
                guard queueEditingHolds[sessionID]?.contains(follower.id) != true,
                      Self.isMergeableQueuedPrompt(follower, allowImages: false),
                      Self.canCombineQueuedPrompts(entry, follower),
                      combinedUTF8Count + 2 + follower.text.utf8.count <= 131_072
                else { break }
                combinedUTF8Count += 2 + follower.text.utf8.count
                combinedTexts.append(follower.text)
                mergedFollowers.append(follower)
            }
        }

        pendingPromptQueues[sessionID]?.removeFirst()
        if !mergedFollowers.isEmpty {
            pendingPromptQueues[sessionID]?.removeFirst(mergedFollowers.count)
            Self.applyCombinedPromptTexts(combinedTexts, to: &entry)
        }
        queueEditingHolds[sessionID]?.remove(entry.id)
        startingPrompts.insert(sessionID)
        runningQueuePrompts[sessionID] = (
            id: entry.id,
            text: entry.text,
            kind: entry.kind,
            combinedTexts: mergedFollowers.isEmpty ? nil : combinedTexts
        )
        for follower in mergedFollowers {
            await follower.admission.resolve(.cancelled)
        }
        await publishQueueChanged(sessionID: sessionID)
        guard state != .closed,
              openedLifecycleSessions.contains(sessionID),
              startingPrompts.contains(sessionID)
        else {
            await entry.admission.resolve(.cancelled)
            return
        }
        await entry.admission.resolve(.admitted(entry.request))
    }

    private static func isMergeableQueuedPrompt(
        _ entry: ACPQueuedPrompt,
        allowImages: Bool
    ) -> Bool {
        guard entry.kind == "prompt",
              !entry.text.isEmpty,
              entry.request.meta?["synthetic"]?.boolValue != true,
              entry.request.meta?["isSynthetic"]?.boolValue != true,
              entry.request.meta?["toolOverrides"] == nil,
              entry.request.meta?["tool_overrides"] == nil
        else { return false }

        var hasText = false
        for block in entry.request.prompt {
            switch block {
            case .text(let content):
                guard content.meta?["bash_command"] == nil,
                      content.meta?["bashCommand"] == nil,
                      content.meta?["displayText"]?.stringValue?
                          .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
                else { return false }
                if !content.text.isEmpty {
                    hasText = true
                }
            case .image:
                guard allowImages else { return false }
            case .audio, .resourceLink, .resource:
                return false
            }
        }
        return hasText
    }

    private static func canCombineQueuedPrompts(
        _ front: ACPQueuedPrompt,
        _ follower: ACPQueuedPrompt
    ) -> Bool {
        guard front.request.sessionId == follower.request.sessionId,
              front.owner == follower.owner
        else { return false }

        let identityKeys = [
            "clientIdentifier",
            "owner",
            "provider",
            "providerId",
            "provider_id",
            "modelProvider",
            "model_provider",
            "turnId",
            "turn_id",
        ]
        return identityKeys.allSatisfy { key in
            front.request.meta?[key] == follower.request.meta?[key]
        }
    }

    private static func applyCombinedPromptTexts(
        _ texts: [String],
        to entry: inout ACPQueuedPrompt
    ) {
        guard texts.count >= 2,
              let lastTextIndex = entry.request.prompt.lastIndex(where: { block in
                  if case .text = block { return true }
                  return false
              }),
              case .text(var lastText) = entry.request.prompt[lastTextIndex]
        else { return }

        for extra in texts.dropFirst() {
            if !lastText.text.isEmpty {
                lastText.text += "\n\n"
            }
            lastText.text += extra
        }
        entry.request.prompt[lastTextIndex] = .text(lastText)

        guard let firstTextIndex = entry.request.prompt.firstIndex(where: { block in
            if case .text = block { return true }
            return false
        }), case .text(var firstText) = entry.request.prompt[firstTextIndex] else { return }
        var metadata = firstText.meta ?? [:]
        metadata["combinedDisplayTexts"] = .array(texts.map(JSONValue.string))
        firstText.meta = metadata
        entry.request.prompt[firstTextIndex] = .text(firstText)
        entry.text = promptQueueText(entry.request)
    }

    private static func combinedPromptDisplayTexts(_ request: PromptRequest) -> [String]? {
        for block in request.prompt {
            guard case .text(let content) = block else { continue }
            guard let values = content.meta?["combinedDisplayTexts"]?.arrayValue,
                  values.count >= 2,
                  values.allSatisfy({ $0.stringValue != nil })
            else { continue }
            return values.compactMap(\.stringValue)
        }
        return nil
    }

    private static func editedQueuedPromptBlocks(
        _ request: PromptRequest,
        text: String
    ) -> [ContentBlock] {
        let isBash = request.prompt.contains { block in
            guard case .text(let content) = block else { return false }
            return content.meta?["bash_command"] != nil
                || content.meta?["bashCommand"] != nil
        }
        let metadata: AcpMeta? = isBash ? ["bash_command": .string(text)] : nil
        var blocks: [ContentBlock] = [.text(TextContent(text: text, meta: metadata))]
        blocks.append(contentsOf: request.prompt.filter { block in
            if case .image = block { return true }
            return false
        })
        return blocks
    }

    private func handleQueueNotification(method: String, params: JSONValue) async -> Bool {
        let supported: Set<String> = [
            "x.ai/queue/remove",
            "x.ai/queue/reorder",
            "x.ai/queue/clear",
            "x.ai/queue/edit",
            "x.ai/queue/interject",
            "x.ai/queue/hold_edit",
            "x.ai/queue/release_edit",
        ]
        guard supported.contains(method) else { return false }
        guard let rawSessionID = params["sessionId"]?.stringValue
                ?? params["session_id"]?.stringValue,
              !rawSessionID.isEmpty,
              rawSessionID.utf8.count <= 128,
              params["_meta"]?["x.ai/replayed"]?.boolValue != true
        else { return true }

        let sessionID = AcpSessionId(rawSessionID)
        guard await ownsSession(sessionID) else { return true }
        let owner = ACPLeaderRequestAuthority.clientID
            ?? params["owner"]?.stringValue
            ?? params["clientIdentifier"]?.stringValue
        let id = params["id"]?.stringValue
        if let id, id.utf8.count > 128 {
            return true
        }

        switch method {
        case "x.ai/queue/remove":
            guard let id else { return true }
            let version = params["expectedVersion"]?.uint64Value ?? 0
            if let index = pendingPromptQueues[sessionID]?.firstIndex(where: {
                $0.id == id && $0.version == version && (owner == nil || $0.owner == owner)
            }), let entry = pendingPromptQueues[sessionID]?.remove(at: index) {
                queueEditingHolds[sessionID]?.remove(id)
                await entry.admission.resolve(.cancelled)
            }
            await publishQueueChanged(sessionID: sessionID)

        case "x.ai/queue/reorder":
            let orderedIDs = (params["orderedIds"]?.arrayValue ?? []).compactMap(\.stringValue)
            guard orderedIDs.count <= 256,
                  orderedIDs.allSatisfy({ $0.utf8.count <= 128 })
            else { return true }
            var ranks: [String: Int] = [:]
            for (index, orderedID) in orderedIDs.enumerated() where ranks[orderedID] == nil {
                ranks[orderedID] = index
            }
            let queue = pendingPromptQueues[sessionID, default: []]
            pendingPromptQueues[sessionID] = queue.enumerated().sorted { lhs, rhs in
                let leftRank = ranks[lhs.element.id] ?? Int.max
                let rightRank = ranks[rhs.element.id] ?? Int.max
                return leftRank == rightRank ? lhs.offset < rhs.offset : leftRank < rightRank
            }.map(\.element)
            await publishQueueChanged(sessionID: sessionID)

        case "x.ai/queue/clear":
            let queue = pendingPromptQueues[sessionID, default: []]
            let removed = queue.filter { owner == nil || $0.owner == owner }
            pendingPromptQueues[sessionID] = queue.filter { entry in
                owner != nil && entry.owner != owner
            }
            for entry in removed {
                queueEditingHolds[sessionID]?.remove(entry.id)
                await entry.admission.resolve(.cancelled)
            }
            await publishQueueChanged(sessionID: sessionID)

        case "x.ai/queue/edit":
            guard let id,
                  let newText = params["newText"]?.stringValue,
                  !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  newText.utf8.count <= 131_072,
                  let index = pendingPromptQueues[sessionID]?.firstIndex(where: { $0.id == id })
            else { return true }
            if let request = pendingPromptQueues[sessionID]?[index].request {
                pendingPromptQueues[sessionID]?[index].request.prompt = Self.editedQueuedPromptBlocks(
                    request,
                    text: newText
                )
            }
            pendingPromptQueues[sessionID]?[index].text = newText
            pendingPromptQueues[sessionID]?[index].version &+= 1
            pendingPromptQueues[sessionID]?[index].lastEditor = owner
            queueEditingHolds[sessionID]?.remove(id)
            if activePrompts[sessionID] == nil, !startingPrompts.contains(sessionID) {
                await promoteNextQueuedPrompt(sessionID: sessionID)
                return true
            }
            await publishQueueChanged(sessionID: sessionID)

        case "x.ai/queue/interject":
            guard let id else { return true }
            let version = params["expectedVersion"]?.uint64Value ?? 0
            guard let index = pendingPromptQueues[sessionID]?.firstIndex(where: {
                $0.id == id && $0.version == version && (owner == nil || $0.owner == owner)
            }), var entry = pendingPromptQueues[sessionID]?.remove(at: index)
            else {
                await publishQueueChanged(sessionID: sessionID)
                return true
            }
            if let newText = params["newText"]?.stringValue,
               !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               newText.utf8.count <= 131_072 {
                entry.request.prompt = Self.editedQueuedPromptBlocks(entry.request, text: newText)
                entry.text = newText
                entry.version &+= 1
                entry.lastEditor = owner
            }
            queueEditingHolds[sessionID]?.remove(id)

            if activePrompts[sessionID] != nil,
               let extensionRouter,
               extensionRouter.hasExactRoute("x.ai/interject"),
               let content = try? JSONValue.encode(entry.request.prompt) {
                let payload: JSONValue = .object([
                    "sessionId": .string(rawSessionID),
                    "text": .string(entry.text),
                    "interjectionId": .string(entry.id),
                    "content": content,
                ])
                do {
                    _ = try await extensionRouter.dispatch(method: "x.ai/interject", params: payload)
                    await entry.admission.resolve(.cancelled)
                } catch {
                    let count = pendingPromptQueues[sessionID, default: []].count
                    pendingPromptQueues[sessionID, default: []].insert(entry, at: min(index, count))
                }
            } else {
                pendingPromptQueues[sessionID, default: []].insert(entry, at: 0)
                if activePrompts[sessionID] == nil, !startingPrompts.contains(sessionID) {
                    await promoteNextQueuedPrompt(sessionID: sessionID)
                    return true
                }
            }
            await publishQueueChanged(sessionID: sessionID)

        case "x.ai/queue/hold_edit":
            guard let id,
                  pendingPromptQueues[sessionID]?.contains(where: { $0.id == id }) == true
            else { return true }
            queueEditingHolds[sessionID, default: []].insert(id)

        case "x.ai/queue/release_edit":
            guard let id else { return true }
            queueEditingHolds[sessionID]?.remove(id)
            if activePrompts[sessionID] == nil, !startingPrompts.contains(sessionID) {
                await promoteNextQueuedPrompt(sessionID: sessionID)
            }

        default:
            return false
        }
        return true
    }

    private func prompt(_ params: JSONValue) async throws -> JSONValue {
        try requireReady()
        var pendingRequest = try decode(
            PromptRequest.self,
            from: params,
            method: AgentMethodNames.sessionPrompt
        )
        guard let session = try await store.read(pendingRequest.sessionId) else {
            throw ACPRuntimeError.sessionNotFound(pendingRequest.sessionId)
        }
        guard !session.closed else {
            throw ACPRuntimeError.sessionClosed(pendingRequest.sessionId)
        }
        if activePrompts[pendingRequest.sessionId] != nil
            || startingPrompts.contains(pendingRequest.sessionId) {
            guard pendingPromptQueues[pendingRequest.sessionId, default: []].count < 256 else {
                throw ACPRuntimeError.sessionBusy(pendingRequest.sessionId)
            }
            let promptID = pendingRequest.meta?["promptId"]?.stringValue
                ?? pendingRequest.messageId
                ?? makeSessionId()
            guard !promptID.isEmpty, promptID.utf8.count <= 128 else {
                throw ACPRuntimeError.invalidParams("queued prompt id exceeds its maximum size")
            }
            guard runningQueuePrompts[pendingRequest.sessionId]?.id != promptID,
                  pendingPromptQueues[pendingRequest.sessionId, default: []]
                    .allSatisfy({ $0.id != promptID })
            else {
                throw ACPRuntimeError.invalidParams("queued prompt id is already active")
            }
            let text = Self.promptQueueText(pendingRequest)
            guard text.utf8.count <= 131_072 else {
                throw ACPRuntimeError.invalidParams("queued prompt text exceeds its maximum size")
            }
            var meta = pendingRequest.meta ?? [:]
            meta["promptId"] = .string(promptID)
            pendingRequest.meta = meta
            let owner = ACPLeaderRequestAuthority.clientID
                ?? meta["clientIdentifier"]?.stringValue
                ?? meta["owner"]?.stringValue
            let admission = ACPQueuedPromptAdmission()
            pendingPromptQueues[pendingRequest.sessionId, default: []].append(ACPQueuedPrompt(
                request: pendingRequest,
                id: promptID,
                owner: owner,
                lastEditor: nil,
                version: 0,
                kind: meta["kind"]?.stringValue ?? "prompt",
                text: text,
                admission: admission
            ))
            await publishQueueChanged(sessionID: pendingRequest.sessionId)

            let runtime = self
            let sessionID = pendingRequest.sessionId
            let resolution = await withTaskCancellationHandler {
                await admission.wait()
            } onCancel: {
                Task {
                    await runtime.cancelQueuedPrompt(
                        sessionID: sessionID,
                        id: promptID,
                        admission: admission
                    )
                }
            }
            switch resolution {
            case .cancelled:
                return try encode(PromptResponse(
                    stopReason: .cancelled,
                    userMessageId: pendingRequest.messageId
                ))
            case .admitted(let admitted):
                pendingRequest = admitted
            }
        }
        let request = pendingRequest
        startingPrompts.insert(request.sessionId)
        let runningID = request.meta?["promptId"]?.stringValue
            ?? request.messageId
            ?? makeSessionId()
        runningQueuePrompts[request.sessionId] = (
            id: runningID,
            text: Self.promptQueueText(request),
            kind: request.meta?["kind"]?.stringValue ?? "prompt",
            combinedTexts: Self.combinedPromptDisplayTexts(request)
        )

        for block in request.prompt {
            await emit(
                SessionNotification(
                    sessionId: request.sessionId,
                    update: .userMessageChunk(ContentChunk(content: block))
                ),
                disposition: .durable
            )
        }
        guard state != .closed,
              startingPrompts.contains(request.sessionId)
        else {
            startingPrompts.remove(request.sessionId)
            throw ACPRuntimeError.requestCancelled
        }

        let driver = promptDriver
        let runtime = self
        let task = Task<PromptRunOutcome, Never> {
            do {
                let response = try await driver.run(
                    context: ACPPromptContext(session: session, request: request),
                    emit: { update, disposition in
                        await runtime.emit(update, disposition: disposition)
                    }
                )
                return PromptRunOutcome(response: response, failure: nil)
            } catch is CancellationError {
                // Upstream reports a cancelled turn through the Ok arm —
                // `prompt_complete` carries ("cancelled", null), not an error.
                return PromptRunOutcome(
                    response: PromptResponse(stopReason: .cancelled, userMessageId: request.messageId),
                    failure: nil
                )
            } catch {
                // The response flattens to refusal (this runtime's
                // pre-existing contract), but the ORIGINAL error is kept so
                // `prompt_complete` can carry upstream's ("error", detail) /
                // ("rate_limit", null) pair instead of a lie about a refusal.
                return PromptRunOutcome(
                    response: PromptResponse(stopReason: .refusal, userMessageId: request.messageId),
                    failure: runtime.protocolError(for: error)
                )
            }
        }
        activePrompts[request.sessionId] = task
        startingPrompts.remove(request.sessionId)
        await publishRosterUpsert(sessionId: request.sessionId, activity: .working)
        let outcome = await task.value
        activePrompts.removeValue(forKey: request.sessionId)
        runningQueuePrompts.removeValue(forKey: request.sessionId)
        await emitPromptComplete(request: request, outcome: outcome)
        await publishRosterUpsert(sessionId: request.sessionId)
        await promoteNextQueuedPrompt(sessionID: request.sessionId)
        return try encode(outcome.response)
    }

    /// Admit a machine-local peer prompt onto this connection's existing ACP
    /// turn driver. Returning before sampling completes matches the upstream
    /// session actor's accepted-command acknowledgement.
    public func submitPeerPrompt(
        sessionId: AcpSessionId,
        promptID: String,
        text: String,
        prepare: @escaping PeerPromptPreparation
    ) async throws -> PeerPromptAdmission {
        try requireReady()
        guard promptID.hasPrefix("peer-message-") else {
            throw ACPRuntimeError.invalidParams("peer prompts require a system-generated peer-message id")
        }
        guard openedLifecycleSessions.contains(sessionId) else {
            return .unknownSession
        }
        guard let session = try await store.read(sessionId),
              !session.closed,
              state != .closed,
              openedLifecycleSessions.contains(sessionId)
        else {
            return .unknownSession
        }
        guard activePrompts[sessionId] == nil,
              !startingPrompts.contains(sessionId)
        else {
            return .busy
        }

        let request = PromptRequest(
            sessionId: sessionId,
            prompt: [.text(text)],
            messageId: promptID,
            meta: ["promptId": .string(promptID)]
        )
        let generation = UUID()
        let driver = promptDriver
        let runtime = self
        let task = Task<PromptRunOutcome, Never> {
            do {
                try await prepare()
                try Task.checkCancellation()
                await runtime.emit(
                    SessionNotification(
                        sessionId: sessionId,
                        update: .userMessageChunk(ContentChunk(
                            content: .text(text),
                            meta: ["hideFromScrollback": .bool(true)]
                        ))
                    ),
                    disposition: .durable
                )
                await runtime.publishRosterUpsert(sessionId: sessionId, activity: .working)
                let response = try await driver.run(
                    context: ACPPromptContext(session: session, request: request),
                    emit: { update, disposition in
                        await runtime.emit(update, disposition: disposition)
                    }
                )
                return PromptRunOutcome(response: response, failure: nil)
            } catch is CancellationError {
                return PromptRunOutcome(
                    response: PromptResponse(stopReason: .cancelled, userMessageId: promptID),
                    failure: nil
                )
            } catch {
                return PromptRunOutcome(
                    response: PromptResponse(stopReason: .refusal, userMessageId: promptID),
                    failure: runtime.protocolError(for: error)
                )
            }
        }
        activePrompts[sessionId] = task
        runningQueuePrompts[sessionId] = (
            id: promptID,
            text: text,
            kind: "prompt",
            combinedTexts: nil
        )
        peerPromptGenerations[sessionId] = generation
        Task { [weak runtime] in
            let outcome = await task.value
            await runtime?.finishPeerPrompt(
                request: request,
                generation: generation,
                outcome: outcome
            )
        }
        return .accepted
    }

    /// Admit an authenticated connected user's idle interjection as an actual
    /// user prompt; peer-message provenance must never be reused for consent.
    public func submitUserInterjection(
        sessionId: AcpSessionId,
        promptID: String,
        text: String
    ) async throws -> PeerPromptAdmission {
        try requireReady()
        guard !promptID.hasPrefix("peer-message-") else {
            throw ACPRuntimeError.invalidParams("user interjections cannot use peer-message provenance")
        }
        guard await ownsSession(sessionId),
              let session = try await store.read(sessionId),
              !session.closed,
              state != .closed,
              openedLifecycleSessions.contains(sessionId)
        else {
            return .unknownSession
        }
        guard activePrompts[sessionId] == nil,
              !startingPrompts.contains(sessionId)
        else {
            return .busy
        }

        let request = PromptRequest(
            sessionId: sessionId,
            prompt: [.text(text)],
            messageId: promptID,
            meta: ["promptId": .string(promptID)]
        )
        let generation = UUID()
        let driver = promptDriver
        let runtime = self
        let task = Task<PromptRunOutcome, Never> {
            do {
                for block in request.prompt {
                    await runtime.emit(
                        SessionNotification(
                            sessionId: sessionId,
                            update: .userMessageChunk(ContentChunk(content: block))
                        ),
                        disposition: .durable
                    )
                    try Task.checkCancellation()
                }
                await runtime.publishRosterUpsert(sessionId: sessionId, activity: .working)
                let response = try await driver.run(
                    context: ACPPromptContext(session: session, request: request),
                    emit: { update, disposition in
                        await runtime.emit(update, disposition: disposition)
                    }
                )
                return PromptRunOutcome(response: response, failure: nil)
            } catch is CancellationError {
                return PromptRunOutcome(
                    response: PromptResponse(stopReason: .cancelled, userMessageId: promptID),
                    failure: nil
                )
            } catch {
                return PromptRunOutcome(
                    response: PromptResponse(stopReason: .refusal, userMessageId: promptID),
                    failure: runtime.protocolError(for: error)
                )
            }
        }
        activePrompts[sessionId] = task
        runningQueuePrompts[sessionId] = (
            id: promptID,
            text: text,
            kind: "prompt",
            combinedTexts: nil
        )
        peerPromptGenerations[sessionId] = generation
        Task { [weak runtime] in
            let outcome = await task.value
            await runtime?.finishPeerPrompt(
                request: request,
                generation: generation,
                outcome: outcome
            )
        }
        return .accepted
    }

    private func finishPeerPrompt(
        request: PromptRequest,
        generation: UUID,
        outcome: PromptRunOutcome
    ) async {
        guard peerPromptGenerations[request.sessionId] == generation else { return }
        peerPromptGenerations.removeValue(forKey: request.sessionId)
        activePrompts.removeValue(forKey: request.sessionId)
        runningQueuePrompts.removeValue(forKey: request.sessionId)
        guard state != .closed,
              openedLifecycleSessions.contains(request.sessionId)
        else { return }
        await emitPromptComplete(request: request, outcome: outcome)
        await publishRosterUpsert(sessionId: request.sessionId)
        await promoteNextQueuedPrompt(sessionID: request.sessionId)
    }

    /// The `x.ai/session/prompt_complete` fire-and-forget broadcast the
    /// prompt handler emits once the stop result is known, before the prompt
    /// response returns (acp_agent.rs:2952-2986). `promptId` echoes the
    /// client's `_meta.promptId` when present, else a fresh UUID
    /// (acp_agent.rs:2671-2677); `turnId` rides through only when the client
    /// sent an integer `_meta.turnId` (acp_agent.rs:2960-2974).
    ///
    /// Recorded divergence: upstream additionally attaches `cancelTrigger`
    /// when the session's cancellation context named one
    /// (acp_agent.rs:2942-2951, 2975-2977); this runtime has no cancellation
    /// context seam, so the field is never present. Cost: a client that
    /// distinguishes user-cancel from timeout-cancel sees neither here.
    private func emitPromptComplete(request: PromptRequest, outcome: PromptRunOutcome) async {
        let (stopReason, agentResult) = Self.promptCompleteFields(
            response: outcome.response,
            failure: outcome.failure
        )
        let promptId = request.meta?["promptId"]?.stringValue ?? UUID().uuidString
        var payload: [String: JSONValue] = [
            "sessionId": .string(request.sessionId.rawValue),
            "promptId": .string(promptId),
            "stopReason": stopReason,
            "agentResult": agentResult,
        ]
        if case .number(let number)? = request.meta?["turnId"],
           let turnId = number.int64Value, turnId >= 0 {
            payload["turnId"] = .number(.int64(turnId))
        }
        await sendExtensionNotification(
            method: ACPXaiNotificationMethods.promptComplete,
            params: .object(payload)
        )
    }

    /// `(stopReason, agentResult)` for `prompt_complete` — the port of
    /// `prompt_complete_fields` (sampling/error.rs:308-331): success passes
    /// the stop reason through with a null result; a rate-limit error
    /// (code -32003, `RATE_LIMITED_ERROR_CODE`, sampling/error.rs:19) yields
    /// ("rate_limit", null) so the client shows its own upgrade copy; any
    /// other error yields ("error", detail), the detail being the error
    /// data's `message` field, else the whole data value, else the message
    /// string (`error_message_from_data`, sampling/error.rs:236-238).
    static func promptCompleteFields(
        response: PromptResponse,
        failure: AcpError?
    ) -> (stopReason: JSONValue, agentResult: JSONValue) {
        guard let failure else {
            return (.string(response.stopReason.rawValue), .null)
        }
        if failure.code.code == -32003 {
            return (.string("rate_limit"), .null)
        }
        let detail: JSONValue
        if let data = failure.data {
            detail = data["message"] ?? data
        } else {
            detail = .string(failure.message)
        }
        return (.string("error"), detail)
    }

    /// Fire-and-forget one extension notification to the connected client —
    /// the outbound half of the notification gateway. Rides the SAME queue
    /// and sink `session/update` rides, so whichever carrier is serving this
    /// runtime (stdio line, ws frame, typed channel) carries it too.
    public func sendExtensionNotification(method: String, params: JSONValue) async {
        let message = ACPMessage.notification(method: method, params: params)
        queuedNotifications.append(message)
        if let notificationSink {
            await notificationSink(message)
        }
    }

    /// Whether `sessionId` exists in this runtime's store. The two-step
    /// spelling avoids `try?` flattening the store's `Snapshot?` into one
    /// silent nil (AGENTS.md §2).
    public func sessionExists(_ sessionId: AcpSessionId) async -> Bool {
        let snapshot = (try? await store.read(sessionId)) ?? nil
        return snapshot != nil
    }

    public func ownsSession(_ sessionId: AcpSessionId) async -> Bool {
        do {
            try requireReady()
        } catch {
            return false
        }
        guard state != .closed, openedLifecycleSessions.contains(sessionId) else {
            return false
        }
        if let sessionOwnerVerifier {
            guard let clientID = ACPLeaderRequestAuthority.clientID,
                  await sessionOwnerVerifier(sessionId, clientID)
            else {
                return false
            }
        }
        do {
            guard let session = try await store.read(sessionId) else { return false }
            return !session.closed
        } catch {
            return false
        }
    }

    private func mayControlLeaderSession(from params: JSONValue) async -> Bool {
        guard let sessionOwnerVerifier else { return true }
        guard let clientID = ACPLeaderRequestAuthority.clientID else { return false }
        if let sessionID = Self.sessionID(in: params) {
            return await ownsSession(sessionID)
        }
        for sessionID in openedLifecycleSessions {
            if await sessionOwnerVerifier(sessionID, clientID) {
                return true
            }
        }
        return false
    }

    private static func sessionID(in params: JSONValue) -> AcpSessionId? {
        guard case .object(let object) = params else { return nil }
        if let raw = (
            object["sessionId"]
            ?? object["session_id"]
            ?? object["sourceSessionId"]
            ?? object["source_session_id"]
        )?.stringValue {
            return AcpSessionId(raw)
        }
        if let nested = object["params"] {
            return sessionID(in: nested)
        }
        return nil
    }

    private func cancel(_ params: JSONValue) async throws -> JSONValue {
        try requireReady()
        let request = try decode(CancelNotification.self, from: params, method: AgentMethodNames.sessionCancel)
        startingPrompts.remove(request.sessionId)
        activePrompts[request.sessionId]?.cancel()
        await promptDriver.cancel(sessionId: request.sessionId)
        return try encode(EmptyAcpResponse())
    }

    private func setMode(_ params: JSONValue) async throws -> JSONValue {
        try requireReady()
        let request = try decode(SetSessionModeRequest.self, from: params, method: AgentMethodNames.sessionSetMode)
        guard var session = try await store.read(request.sessionId) else {
            throw ACPRuntimeError.sessionNotFound(request.sessionId)
        }
        guard !session.closed else { throw ACPRuntimeError.sessionClosed(request.sessionId) }
        if let modes = configuration.modes,
           !modes.availableModes.isEmpty,
           !modes.availableModes.contains(where: { $0.id == request.modeId }) {
            throw ACPRuntimeError.invalidParams("unknown mode \(request.modeId)")
        }
        session.modeId = request.modeId
        session.updatedAt = timestamp()
        try await store.update(session)
        await emit(
            SessionNotification(
                sessionId: request.sessionId,
                update: .currentModeUpdate(CurrentModeUpdate(currentModeId: request.modeId))
            ),
            disposition: .durable
        )
        return try encode(SetSessionModeResponse())
    }

    private func setModel(_ params: JSONValue) async throws -> JSONValue {
        try requireReady()
        let request = try decode(SetSessionModelRequest.self, from: params, method: AgentMethodNames.sessionSetModel)
        guard var session = try await store.read(request.sessionId) else {
            throw ACPRuntimeError.sessionNotFound(request.sessionId)
        }
        guard !session.closed else { throw ACPRuntimeError.sessionClosed(request.sessionId) }
        if let models = configuration.models,
           !models.availableModels.isEmpty,
           !models.availableModels.contains(where: { $0.modelId == request.modelId }) {
            throw ACPRuntimeError.invalidParams("unknown model \(request.modelId)")
        }
        session.modelId = request.modelId
        session.updatedAt = timestamp()
        try await store.update(session)
        await publishRosterUpsert(sessionId: request.sessionId)
        return try encode(SetSessionModelResponse())
    }

    private func setConfigOption(_ params: JSONValue) async throws -> JSONValue {
        try requireReady()
        let request = try decode(
            SetSessionConfigOptionRequest.self,
            from: params,
            method: AgentMethodNames.sessionSetConfigOption
        )
        guard var session = try await store.read(request.sessionId) else {
            throw ACPRuntimeError.sessionNotFound(request.sessionId)
        }
        guard !session.closed else { throw ACPRuntimeError.sessionClosed(request.sessionId) }
        session.updatedAt = timestamp()
        try await store.update(session)
        return try encode(SetSessionConfigOptionResponse())
    }

    private func validateWorkspace(_ cwd: String) async throws -> String {
        guard let workspaceBoundary else { return cwd }
        return try await workspaceBoundary.validate(cwd: cwd)
    }

    private func requireInitialized() throws {
        guard state == .initialized || state == .authenticated else {
            throw ACPRuntimeError.invalidState(expected: "initialized", actual: state.rawValue)
        }
    }

    private func requireReady() throws {
        try requireInitialized()
        if configuration.requireAuthentication && !authenticated {
            throw ACPRuntimeError.authenticationRequired
        }
    }

    private func replay(_ session: ACPSessionSnapshot, leaderClientID: JSONValue? = nil) async {
        for original in session.durableUpdates {
            var notification = original
            var meta = notification.meta ?? [:]
            meta["isReplay"] = .bool(true)
            if let leaderClientID, leaderClientID.uint64Value != nil {
                meta[ACPLeaderCapabilityInjection.clientIDKey] = leaderClientID
            }
            notification.meta = meta
            await emit(notification, disposition: .live)
        }
    }

    private func emit(_ notification: SessionNotification, disposition: ACPNotificationDisposition) async {
        var rosterTitleChanged = false
        if case .sessionInfoUpdate(let update) = notification.update,
           let title = update.title {
            var metadata = rosterMetadata[notification.sessionId]
                ?? RosterMetadata(title: nil, yolo: false)
            if metadata.title != title {
                metadata.title = title
                rosterMetadata[notification.sessionId] = metadata
                rosterTitleChanged = true
            }
        }
        if disposition == .durable {
            do {
                if var session = try await store.read(notification.sessionId) {
                    session.durableUpdates.append(notification)
                    session.updatedAt = timestamp()
                    try await store.update(session)
                }
            } catch {
            }
        }
        guard let params = try? JSONValue.encode(notification) else { return }
        let message = ACPMessage.notification(method: ClientMethodNames.sessionUpdate, params: params)
        queuedNotifications.append(message)
        if let notificationSink {
            await notificationSink(message)
        }
        if rosterTitleChanged {
            await publishRosterUpsert(sessionId: notification.sessionId)
        }
    }

    private func publishRosterUpsert(
        sessionId: AcpSessionId,
        activity: ACPLeaderRosterActivity? = nil
    ) async {
        let stored: ACPSessionSnapshot?
        do {
            stored = try await store.read(sessionId)
        } catch {
            return
        }
        guard let snapshot = stored, !snapshot.closed else { return }
        await sendRosterChanged(
            ACPLeaderRosterChanged(upserted: [rosterEntry(for: snapshot, activity: activity)])
        )
    }

    private func publishRosterRemoved(sessionId: AcpSessionId) async {
        await sendRosterChanged(ACPLeaderRosterChanged(removed: [sessionId.rawValue]))
    }

    private func sendRosterChanged(_ changed: ACPLeaderRosterChanged) async {
        guard !changed.upserted.isEmpty || !changed.removed.isEmpty,
               let params = try? JSONValue.encode(changed)
        else { return }
        let message = ACPMessage.notification(
            method: ACPLeaderRosterMethods.sessionsChanged,
            params: params
        )
        if let rosterNotificationSink {
            await rosterNotificationSink(message)
        }
    }

    private func rosterEntry(
        for snapshot: ACPSessionSnapshot,
        activity: ACPLeaderRosterActivity? = nil
    ) -> ACPLeaderRosterEntry {
        let metadata = rosterMetadata[snapshot.sessionId]
            ?? RosterMetadata(title: nil, yolo: false)
        return ACPLeaderRosterEntry(
            sessionId: snapshot.sessionId.rawValue,
            title: metadata.title,
            cwd: snapshot.cwd,
            isWorktree: false,
            modelId: snapshot.modelId?.rawValue,
            reasoningEffort: nil,
            yolo: metadata.yolo,
            activity: activity ?? rosterActivity(sessionId: snapshot.sessionId),
            resident: true,
            lastChangeUnixMs: rosterTimestampMilliseconds(),
            origin: .local
        )
    }

    private func rosterActivity(sessionId: AcpSessionId) -> ACPLeaderRosterActivity {
        if pendingRosterInteractions[sessionId, default: 0] > 0 {
            return .needsInput
        }
        if activePrompts[sessionId] != nil {
            return .working
        }
        return .idle
    }

    private func endRosterInteraction(sessionId: AcpSessionId) async {
        let remaining = max(0, pendingRosterInteractions[sessionId, default: 0] - 1)
        if remaining == 0 {
            pendingRosterInteractions.removeValue(forKey: sessionId)
        } else {
            pendingRosterInteractions[sessionId] = remaining
        }
        await publishRosterUpsert(sessionId: sessionId)
    }

    private func updateRosterMetadata(sessionId: AcpSessionId, meta: AcpMeta?) {
        guard let yolo = Self.metaBool(meta, key: "yoloMode") else { return }
        var metadata = rosterMetadata[sessionId] ?? RosterMetadata(title: nil, yolo: false)
        metadata.yolo = yolo
        rosterMetadata[sessionId] = metadata
    }

    private static func metaBool(_ meta: AcpMeta?, key: String) -> Bool? {
        guard case .bool(let value)? = meta?[key] else { return nil }
        return value
    }

    private static func rosterInteractionSession(method: String, params: JSONValue) -> AcpSessionId? {
        let route = ACPMethodRoute.normalize(method: method, params: params)
        guard route.method == ClientMethodNames.sessionRequestPermission
                || route.method == OpenGrokACPExtMethods.askUserQuestion,
              case .object(let object) = route.params,
              case .string(let sessionId)? = object["sessionId"]
        else { return nil }
        return AcpSessionId(sessionId)
    }

    private func emitProtocolError(_ error: Error) async {
        let params = JSONValue.object(["error": .string(protocolError(for: error).message)])
        let message = ACPMessage.notification(method: "_x.ai/protocol/error", params: params)
        queuedNotifications.append(message)
        if let notificationSink {
            await notificationSink(message)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from params: JSONValue, method: String) throws -> T {
        do {
            return try params.decode(type)
        } catch {
            throw ACPRuntimeError.invalidParams("\(method): \(error)")
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        do {
            return try JSONValue.encode(value)
        } catch {
            throw ACPRuntimeError.transport("failed to encode ACP response: \(error)")
        }
    }

    nonisolated private func protocolError(for error: Error) -> AcpError {
        if let acpError = error as? AcpError { return acpError }
        if let runtimeError = error as? ACPRuntimeError { return runtimeError.acpError }
        if error is DecodingError {
            return AcpError(code: .invalidParams, message: "invalid params")
        }
        return AcpError.internalError(String(describing: error))
    }
}

// MARK: - Extension method router
//
// Upstream dispatches ACP extension methods through a name-indexed match
// (`crates/codegen/xai-grok-shell/src/agent/mvp_agent/acp_agent.rs:3794-4471`).
// This router is the Swift seam for the same shape: exact-name handlers plus
// optional prefix families, first-match dispatch, and upstream's terminal
// unknown-method error for anything unmatched.
//
// Registered by the live composition (`LiveACPExtensionMethods.swift`):
// `x.ai/feedback`, the `open-grok/*/models` credential family, `x.ai/recap`,
// `x.ai/btw`, the `x.ai/mcp/` prefix family, and the session-admin trio
// (`x.ai/session/rename`/`delete`/`fork`). Remaining upstream families
// (feedback-dismiss, the xAI auth family, …) belong to their own
// slices; until they land they fall through to the terminal arm.

public struct ACPExtensionMethodRouter: ACPAgentExtensionHandler, Sendable {
    private enum Route: Sendable {
        case exact(String, any ACPAgentExtensionHandler)
        case prefix(String, any ACPAgentExtensionHandler)
        case catchAll(any ACPAgentExtensionHandler)
    }

    private let routes: [Route]

    public init() {
        routes = []
    }

    private init(routes: [Route]) {
        self.routes = routes
    }

    public func register(
        exact method: String,
        handler: any ACPAgentExtensionHandler
    ) -> ACPExtensionMethodRouter {
        ACPExtensionMethodRouter(routes: routes + [.exact(method, handler)])
    }

    public func register(
        prefix: String,
        handler: any ACPAgentExtensionHandler
    ) -> ACPExtensionMethodRouter {
        ACPExtensionMethodRouter(routes: routes + [.prefix(prefix, handler)])
    }

    fileprivate func register(
        catchAll handler: any ACPAgentExtensionHandler
    ) -> ACPExtensionMethodRouter {
        ACPExtensionMethodRouter(routes: routes + [.catchAll(handler)])
    }

    fileprivate func hasExactRoute(_ method: String) -> Bool {
        routes.contains { route in
            guard case .exact(let registered, _) = route else { return false }
            return registered == method
        }
    }

    public func dispatch(method: String, params: JSONValue) async throws -> JSONValue {
        for route in routes {
            switch route {
            case .exact(let name, let handler):
                guard method == name else { continue }
                return try await handler.handle(method: method, params: params)
            case .prefix(let prefix, let handler):
                guard method.hasPrefix(prefix) else { continue }
                return try await handler.handle(method: method, params: params)
            case .catchAll(let handler):
                return try await handler.handle(method: method, params: params)
            }
        }
        throw Self.unknownExtensionMethodError(method)
    }

    /// Upstream's terminal ext-method arm, byte-exact
    /// (`acp_agent.rs:4467-4471`): `acp::Error::method_not_found()` — code
    /// -32601, message "Method not found" — with the method name in `data`.
    /// This is deliberately NOT `ACPRuntimeError.methodNotFound`, whose
    /// message embeds the method name; upstream's ext surface keeps the
    /// standard message and puts the specifics in `data`, and clients match
    /// on that copy. Every method this port has not implemented falls
    /// through to here — a refusal with the right error, never a silent arm.
    public static func unknownExtensionMethodError(_ method: String) -> AcpError {
        AcpError(
            code: .methodNotFound,
            message: AcpErrorCode.methodNotFound.displayName,
            data: .string("unknown ACP extension method: \(method)")
        )
    }

    public func handle(method: String, params: JSONValue) async throws -> JSONValue {
        try await dispatch(method: method, params: params)
    }
}
