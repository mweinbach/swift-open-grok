import Foundation
import OpenGrokACP
import OpenGrokShared

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

    private let configuration: ACPAgentConfiguration
    private let store: any ACPSessionStore
    private let promptDriver: any ACPPromptDriver
    private let workspaceBoundary: (any ACPWorkspaceBoundary)?
    private let extensionRouter: ACPExtensionMethodRouter?
    private let reverseRequests: ACPReverseRequestBroker
    private let makeSessionId: @Sendable () -> String
    private let timestamp: @Sendable () -> String

    private var state: ACPConnectionState = .connected
    private var authenticated = false
    private var activePrompts: [AcpSessionId: Task<PromptResponse, Never>] = [:]
    private var requestIDs: Set<AcpRequestId> = []
    private var queuedNotifications: [ACPMessage] = []
    private var notificationSink: NotificationSink?
    private var reverseSender: (@Sendable (ACPMessage) async throws -> Void)?

    public init(
        configuration: ACPAgentConfiguration = ACPAgentConfiguration(),
        store: any ACPSessionStore = InMemoryACPSessionStore(),
        promptDriver: any ACPPromptDriver = ACPNoopPromptDriver(),
        workspaceBoundary: (any ACPWorkspaceBoundary)? = nil,
        extensionRouter: ACPExtensionMethodRouter? = nil,
        extensionHandler: (any ACPAgentExtensionHandler)? = nil,
        reverseRequests: ACPReverseRequestBroker = ACPReverseRequestBroker(),
        makeSessionId: @escaping @Sendable () -> String = { UUID().uuidString },
        timestamp: @escaping @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) }
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
        self.reverseRequests = reverseRequests
        self.makeSessionId = makeSessionId
        self.timestamp = timestamp
    }

    public func connectionState() -> ACPConnectionState {
        state
    }

    public func setNotificationSink(_ sink: NotificationSink?) {
        notificationSink = sink
    }

    public func setReverseSender(_ sender: (@Sendable (ACPMessage) async throws -> Void)?) {
        reverseSender = sender
    }

    public func requestClient(method: String, params: JSONValue) async throws -> JSONValue {
        guard let reverseSender else {
            throw ACPRuntimeError.transport("no ACP client is connected")
        }
        return try await reverseRequests.request(method: method, params: params, send: reverseSender)
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
        await reverseRequests.cancelAll()
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
        // Each inbound message is dispatched on its own child task rather than
        // inline. `session/prompt` does not return until the driver finishes,
        // so a sequential loop could not read the `session/cancel` that is
        // supposed to interrupt it — the cancel would sit in the transport
        // until the prompt it was meant to stop had already completed. The
        // actor still serializes the state each handler touches; only the
        // reading of the next frame is decoupled. This matches upstream, where
        // `AgentSideConnection` dispatches concurrently
        // (`crates/codegen/xai-grok-shell/src/agent/server.rs:375`).
        let runtime = self
        await withTaskGroup(of: Void.self) { group in
            do {
                while state != .closed {
                    let incoming = try await transport.receive()
                    group.addTask {
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
                }
            } catch {
                await close()
            }
        }
        await transport.close()
    }

    public func serve(_ channel: AcpAgentChannel) async {
        setNotificationSink { message in
            guard message.method == ClientMethodNames.sessionUpdate,
                  let params = message.params,
                  let notification = try? params.decode(SessionNotification.self) else {
                return
            }
            let args = AcpArgs(request: notification)
            _ = channel.send(.sessionNotification(args))
        }
        setReverseSender { message in
            guard case .request(_, let method, let params) = message else {
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
            case .success:
                break
            case .failure(let error):
                throw error
            }
        }
        for await message in channel.messages {
            await handleTyped(message)
        }
        await close()
    }

    @discardableResult
    public func handle(_ message: ACPMessage) async -> [ACPMessage] {
        switch message {
        case .response:
            _ = await reverseRequests.resolve(message)
            return []
        case .notification(let method, let params):
            do {
                _ = try await dispatch(method: method, params: params)
            } catch {
                await emitProtocolError(error)
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
        default:
            guard let extensionRouter else {
                throw ACPRuntimeError.methodNotFound(route.method)
            }
            return try await extensionRouter.dispatch(method: route.method, params: route.params)
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
        case .extNotification(let args): await handleTyped(args)
        case .askUserQuestion(let args): await handleTyped(args)
        }
    }

    private func initialize(_ params: JSONValue) async throws -> JSONValue {
        guard state == .connected else {
            throw ACPRuntimeError.invalidState(expected: ACPConnectionState.connected.rawValue, actual: state.rawValue)
        }
        let request = try decode(InitializeRequest.self, from: params, method: AgentMethodNames.initialize)
        guard request.protocolVersion == configuration.protocolVersion else {
            throw ACPRuntimeError.protocolVersionUnsupported(request.protocolVersion)
        }
        state = .initialized
        return try encode(InitializeResponse(
            protocolVersion: configuration.protocolVersion,
            agentCapabilities: configuration.agentCapabilities,
            authMethods: configuration.authMethods,
            agentInfo: configuration.agentInfo,
            meta: configuration.meta
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
        try await store.create(session)
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
        session.cwd = try await validateWorkspace(request.cwd)
        session.additionalDirectories = request.additionalDirectories
        session.mcpServers = request.mcpServers
        session.closed = false
        session.updatedAt = timestamp()
        try await store.update(session)
        await replay(session)
        return try encode(LoadSessionResponse(modes: configuration.modes, models: configuration.models))
    }

    private func resumeSession(_ params: JSONValue) async throws -> JSONValue {
        try requireReady()
        let request = try decode(ResumeSessionRequest.self, from: params, method: AgentMethodNames.sessionResume)
        guard var session = try await store.read(request.sessionId) else {
            throw ACPRuntimeError.sessionNotFound(request.sessionId)
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
        try await store.update(session)
        await replay(session)
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

    private func closeSession(_ params: JSONValue) async throws -> JSONValue {
        try requireReady()
        let request = try decode(CloseSessionRequest.self, from: params, method: AgentMethodNames.sessionClose)
        guard var session = try await store.read(request.sessionId) else {
            throw ACPRuntimeError.sessionNotFound(request.sessionId)
        }
        activePrompts[request.sessionId]?.cancel()
        await promptDriver.cancel(sessionId: request.sessionId)
        session.closed = true
        session.updatedAt = timestamp()
        try await store.update(session)
        return try encode(CloseSessionResponse())
    }

    private func prompt(_ params: JSONValue) async throws -> JSONValue {
        try requireReady()
        let request = try decode(PromptRequest.self, from: params, method: AgentMethodNames.sessionPrompt)
        guard let session = try await store.read(request.sessionId) else {
            throw ACPRuntimeError.sessionNotFound(request.sessionId)
        }
        guard !session.closed else {
            throw ACPRuntimeError.sessionClosed(request.sessionId)
        }
        guard activePrompts[request.sessionId] == nil else {
            throw ACPRuntimeError.sessionBusy(request.sessionId)
        }

        for block in request.prompt {
            await emit(
                SessionNotification(
                    sessionId: request.sessionId,
                    update: .userMessageChunk(ContentChunk(content: block))
                ),
                disposition: .durable
            )
        }

        let driver = promptDriver
        let runtime = self
        let task = Task<PromptResponse, Never> {
            do {
                return try await driver.run(
                    context: ACPPromptContext(session: session, request: request),
                    emit: { update, disposition in
                        await runtime.emit(update, disposition: disposition)
                    }
                )
            } catch is CancellationError {
                return PromptResponse(stopReason: .cancelled, userMessageId: request.messageId)
            } catch {
                return PromptResponse(stopReason: .refusal, userMessageId: request.messageId)
            }
        }
        activePrompts[request.sessionId] = task
        defer { activePrompts.removeValue(forKey: request.sessionId) }
        return try encode(await task.value)
    }

    private func cancel(_ params: JSONValue) async throws -> JSONValue {
        try requireReady()
        let request = try decode(CancelNotification.self, from: params, method: AgentMethodNames.sessionCancel)
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

    private func replay(_ session: ACPSessionSnapshot) async {
        for original in session.durableUpdates {
            var notification = original
            var meta = notification.meta ?? [:]
            meta["isReplay"] = .bool(true)
            notification.meta = meta
            await emit(notification, disposition: .live)
        }
    }

    private func emit(_ notification: SessionNotification, disposition: ACPNotificationDisposition) async {
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

    private func protocolError(for error: Error) -> AcpError {
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
// optional prefix families, first-match dispatch, and `methodNotFound` for
// anything unmatched.
//
// Intended consumers (later slices — not registered here):
//   * `open-grok/codex/models/*`, `open-grok/kimi/models/*`,
//     `open-grok/fireworks/models/apply` — model refresh/apply family
//   * `x.ai/mcp/*` — MCP bridge extension methods
//   * other `x.ai/*` vendor extensions beyond feedback

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
        throw ACPRuntimeError.methodNotFound(method)
    }

    public func handle(method: String, params: JSONValue) async throws -> JSONValue {
        try await dispatch(method: method, params: params)
    }
}
