import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokProviderSession
import OpenGrokSessionPersistence
import OpenGrokShared
import OpenGrokShellBase
import OpenGrokShellSessionSupport
import OpenGrokWorkspace

public enum OpenGrokShellError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidState(expected: String, actual: String)
    case invalidSessionID(String)
    case duplicateSession(String)
    case sessionNotFound(String)
    case providerConfigurationMissing(String)
    case providerConfigurationMismatch(String)
    case invalidTurnRequest(String)
    case turnAlreadyActive(String)
    case turnNotFound(String)
    case turnFailed(String)
    case waitTimedOut(String)
    case cancelled
    case startupFailed(String)

    public var description: String {
        switch self {
        case let .invalidState(expected, actual):
            return "shell state must be \(expected), got \(actual)"
        case let .invalidSessionID(id):
            return "invalid Open Grok session id: \(id)"
        case let .duplicateSession(id):
            return "Open Grok session already exists: \(id)"
        case let .sessionNotFound(id):
            return "Open Grok session not found: \(id)"
        case let .providerConfigurationMissing(id):
            return "provider configuration is required for session: \(id)"
        case let .providerConfigurationMismatch(id):
            return "provider configuration session id does not match: \(id)"
        case let .invalidTurnRequest(message):
            return "invalid shell turn request: \(message)"
        case let .turnAlreadyActive(id):
            return "shell session already has an active turn: \(id)"
        case let .turnNotFound(id):
            return "shell turn not found: \(id)"
        case let .turnFailed(message):
            return "shell turn failed: \(message)"
        case let .waitTimedOut(id):
            return "timed out waiting for shell turn: \(id)"
        case .cancelled:
            return "shell operation cancelled"
        case let .startupFailed(message):
            return "shell startup failed: \(message)"
        }
    }
}

public enum OpenGrokShellState: String, Sendable, Equatable {
    case new
    case starting
    case running
    case shuttingDown = "shutting_down"
    case closed
}

public struct OpenGrokShellSessionRequest: Sendable {
    public let sessionID: SessionID
    public let cwd: URL
    public let providerConfiguration: ProviderSessionConfiguration?
    public let restorePersistedState: Bool

    public init(
        sessionID: SessionID,
        cwd: URL,
        providerConfiguration: ProviderSessionConfiguration? = nil,
        restorePersistedState: Bool = true
    ) {
        self.sessionID = sessionID
        self.cwd = cwd.standardizedFileURL
        self.providerConfiguration = providerConfiguration
        self.restorePersistedState = restorePersistedState
    }
}

public struct OpenGrokShellSessionDescriptor: Sendable, Equatable {
    public let sessionID: SessionID
    public let cwd: URL
    public let modelID: String
    public let provider: String
    public let phase: SessionLifecyclePhase
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        sessionID: SessionID,
        cwd: URL,
        modelID: String,
        provider: String,
        phase: SessionLifecyclePhase,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.modelID = modelID
        self.provider = provider
        self.phase = phase
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct OpenGrokShellTurnRequest: Sendable, Equatable {
    public let promptID: String
    public let text: String
    public let turnID: String

    public init(promptID: String = UUID().uuidString, text: String, turnID: String = UUID().uuidString) {
        self.promptID = promptID
        self.text = text
        self.turnID = turnID
    }
}

public enum OpenGrokShellTurnUpdateKind: Sendable, Equatable {
    case assistantText(String)
    case status(String)
}

public struct OpenGrokShellTurnUpdate: Sendable, Equatable {
    public let turnID: String
    public let sequence: UInt64
    public let kind: OpenGrokShellTurnUpdateKind

    public init(turnID: String, sequence: UInt64, kind: OpenGrokShellTurnUpdateKind) {
        self.turnID = turnID
        self.sequence = sequence
        self.kind = kind
    }
}

public struct OpenGrokShellSamplingResult: Sendable, Equatable {
    public let output: String
    public let stopReason: String?
    public let cancelled: Bool

    public init(output: String, stopReason: String? = nil, cancelled: Bool = false) {
        self.output = output
        self.stopReason = stopReason
        self.cancelled = cancelled
    }
}

public struct OpenGrokShellTurnResult: Sendable, Equatable {
    public let sessionID: SessionID
    public let turnID: String
    public let output: String
    public let stopReason: String?
    public let cancelled: Bool

    public init(
        sessionID: SessionID,
        turnID: String,
        output: String,
        stopReason: String? = nil,
        cancelled: Bool = false
    ) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.output = output
        self.stopReason = stopReason
        self.cancelled = cancelled
    }
}

public struct OpenGrokShellTurnHandle: Sendable, Equatable {
    public let sessionID: SessionID
    public let turnID: String

    public init(sessionID: SessionID, turnID: String) {
        self.sessionID = sessionID
        self.turnID = turnID
    }
}

public struct OpenGrokShellStartupReport: Sendable, Equatable {
    public let restoredWorkflowRuns: Int
    public let activeSessionCount: Int
    public let state: OpenGrokShellState

    public init(restoredWorkflowRuns: Int, activeSessionCount: Int, state: OpenGrokShellState) {
        self.restoredWorkflowRuns = restoredWorkflowRuns
        self.activeSessionCount = activeSessionCount
        self.state = state
    }
}

public struct OpenGrokShellShutdownReport: Sendable, Equatable {
    public let closedSessionCount: Int
    public let cancelledTurnCount: Int
    public let timedOut: Bool
    public let state: OpenGrokShellState

    public init(closedSessionCount: Int, cancelledTurnCount: Int, timedOut: Bool, state: OpenGrokShellState) {
        self.closedSessionCount = closedSessionCount
        self.cancelledTurnCount = cancelledTurnCount
        self.timedOut = timedOut
        self.state = state
    }
}

public enum OpenGrokShellEvent: Sendable, Equatable {
    case startupBegan
    case startupCompleted(OpenGrokShellStartupReport)
    case sessionCreated(OpenGrokShellSessionDescriptor)
    case sessionClosed(SessionID)
    case turnAccepted(OpenGrokShellTurnHandle)
    case turnStarted(OpenGrokShellTurnHandle)
    case turnUpdate(OpenGrokShellTurnUpdate)
    case turnCompleted(OpenGrokShellTurnResult)
    case turnCancelled(OpenGrokShellTurnHandle)
    case turnFailed(OpenGrokShellTurnHandle, message: String)
    case cancellationRequested(OpenGrokShellTurnHandle)
    case shutdownBegan
    case shutdownCompleted(OpenGrokShellShutdownReport)
    case acpMessage(SessionID, ACPMessage)
}

public protocol OpenGrokShellFacade: Sendable {
    func start() async throws -> OpenGrokShellStartupReport
    func createSession(_ request: OpenGrokShellSessionRequest) async throws -> OpenGrokShellSessionDescriptor
    func lookupSession(_ sessionID: SessionID) async -> OpenGrokShellSessionDescriptor?
    func submitTurn(sessionID: SessionID, request: OpenGrokShellTurnRequest) async throws -> OpenGrokShellTurnHandle
    func waitForTurn(_ handle: OpenGrokShellTurnHandle, timeout: ShellDuration?) async throws -> OpenGrokShellTurnResult
    func cancelTurn(_ handle: OpenGrokShellTurnHandle) async throws
    func events() async -> AsyncThrowingStream<OpenGrokShellEvent, Error>
    func handleACPMessage(sessionID: SessionID, message: ACPMessage) async throws -> [ACPMessage]
    func shutdown(timeout: ShellDuration) async -> OpenGrokShellShutdownReport
}

public struct OpenGrokShellProviderSessionSnapshot: Sendable, Equatable {
    public let sessionID: String
    public let modelID: String
    public let provider: String
    public let generation: UInt64

    public init(sessionID: String, modelID: String, provider: String, generation: UInt64) {
        self.sessionID = sessionID
        self.modelID = modelID
        self.provider = provider
        self.generation = generation
    }
}

public struct OpenGrokShellProviderTurnContext: Sendable, Equatable {
    public let sessionID: String
    public let turnID: String
    public let modelID: String
    public let attempt: UInt32

    public init(sessionID: String, turnID: String, modelID: String, attempt: UInt32) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.modelID = modelID
        self.attempt = attempt
    }
}

public protocol OpenGrokShellProviderSession: Sendable {
    func snapshot() async -> OpenGrokShellProviderSessionSnapshot
    func beginTurn(turnID: String) async throws -> OpenGrokShellProviderTurnContext
    func finishTurn(turnID: String) async throws
    func failTurn(turnID: String) async
    func cancelTurn(turnID: String) async throws
}

public protocol OpenGrokShellProviderFactory: Sendable {
    func makeSession(for request: OpenGrokShellSessionRequest) throws -> any OpenGrokShellProviderSession
}

public struct ProviderSessionFactoryAdapter: OpenGrokShellProviderFactory, Sendable {
    public init() {}

    public func makeSession(for request: OpenGrokShellSessionRequest) throws -> any OpenGrokShellProviderSession {
        guard let configuration = request.providerConfiguration else {
            throw OpenGrokShellError.providerConfigurationMissing(request.sessionID.rawValue)
        }
        guard configuration.sessionID == request.sessionID.rawValue else {
            throw OpenGrokShellError.providerConfigurationMismatch(request.sessionID.rawValue)
        }
        return ProviderSessionAdapter(
            session: try ProviderSession(configuration: configuration),
            sessionID: request.sessionID.rawValue
        )
    }
}

public struct ProviderSessionAdapter: OpenGrokShellProviderSession, Sendable {
    private let session: ProviderSession
    private let sessionID: String

    public init(session: ProviderSession, sessionID: String) {
        self.session = session
        self.sessionID = sessionID
    }

    public func snapshot() async -> OpenGrokShellProviderSessionSnapshot {
        let snapshot = await session.snapshot()
        return OpenGrokShellProviderSessionSnapshot(
            sessionID: sessionID,
            modelID: snapshot.route.modelID,
            provider: snapshot.route.provider.asString,
            generation: snapshot.generation
        )
    }

    public func beginTurn(turnID: String) async throws -> OpenGrokShellProviderTurnContext {
        let context = try await session.beginTurn(turnID: turnID)
        return OpenGrokShellProviderTurnContext(
            sessionID: context.sessionID,
            turnID: context.turnID,
            modelID: context.route.modelID,
            attempt: context.attempt
        )
    }

    public func finishTurn(turnID: String) async throws {
        try await session.finishTurn(turnID: turnID)
    }

    public func failTurn(turnID: String) async {
        try? await session.failTurn(turnID: turnID)
    }

    public func cancelTurn(turnID: String) async throws {
        _ = try await session.cancelTurn(turnID: turnID)
    }
}

public protocol OpenGrokShellSamplingDriver: Sendable {
    func sample(
        context: OpenGrokShellProviderTurnContext,
        request: OpenGrokShellTurnRequest,
        emit: @escaping @Sendable (OpenGrokShellTurnUpdateKind) async -> Void
    ) async throws -> OpenGrokShellSamplingResult
}

public protocol OpenGrokShellTurnDriver: Sendable {
    func submit(
        providerSession: any OpenGrokShellProviderSession,
        request: OpenGrokShellTurnRequest,
        emit: @escaping @Sendable (OpenGrokShellTurnUpdateKind) async -> Void
    ) async throws -> OpenGrokShellTurnResult
    func cancel(providerSession: any OpenGrokShellProviderSession, turnID: String) async throws
}

public struct ProviderSessionTurnDriver: OpenGrokShellTurnDriver, Sendable {
    private let sampler: any OpenGrokShellSamplingDriver

    public init(sampler: any OpenGrokShellSamplingDriver) {
        self.sampler = sampler
    }

    public func submit(
        providerSession: any OpenGrokShellProviderSession,
        request: OpenGrokShellTurnRequest,
        emit: @escaping @Sendable (OpenGrokShellTurnUpdateKind) async -> Void
    ) async throws -> OpenGrokShellTurnResult {
        let context = try await providerSession.beginTurn(turnID: request.turnID)
        do {
            let sample = try await sampler.sample(context: context, request: request, emit: emit)
            if sample.cancelled {
                try? await providerSession.cancelTurn(turnID: request.turnID)
                return OpenGrokShellTurnResult(
                    sessionID: SessionID(context.sessionID),
                    turnID: request.turnID,
                    output: sample.output,
                    stopReason: sample.stopReason,
                    cancelled: true
                )
            }
            try await providerSession.finishTurn(turnID: request.turnID)
            return OpenGrokShellTurnResult(
                sessionID: SessionID(context.sessionID),
                turnID: request.turnID,
                output: sample.output,
                stopReason: sample.stopReason,
                cancelled: false
            )
        } catch {
            if error is CancellationError {
                try? await providerSession.cancelTurn(turnID: request.turnID)
            } else {
                await providerSession.failTurn(turnID: request.turnID)
            }
            throw error
        }
    }

    public func cancel(providerSession: any OpenGrokShellProviderSession, turnID: String) async throws {
        try await providerSession.cancelTurn(turnID: turnID)
    }
}

public protocol OpenGrokShellWorkspace: Sendable {
    var handle: WorkspaceHandle { get }
    var acpBoundary: any ACPWorkspaceBoundary { get }
}

public struct LocalOpenGrokShellWorkspace: OpenGrokShellWorkspace, Sendable {
    public let handle: WorkspaceHandle
    public let acpBoundary: any ACPWorkspaceBoundary

    public init(root: URL, openGrokHome: URL, capability: CapabilityMode = .full) {
        let config = WorkspaceConfig(root: root, openGrokHome: openGrokHome)
        let operations = LocalWorkspaceOps(config: config)
        self.handle = WorkspaceHandle(config: config, capability: capability)
        self.acpBoundary = LocalACPWorkspaceBoundary(operations: operations)
    }
}

public protocol OpenGrokShellWorkspaceFactory: Sendable {
    func makeWorkspace(sessionID: SessionID, cwd: URL, openGrokHome: URL) throws -> any OpenGrokShellWorkspace
}

public struct LocalOpenGrokShellWorkspaceFactory: OpenGrokShellWorkspaceFactory, Sendable {
    public init() {}

    public func makeWorkspace(sessionID: SessionID, cwd: URL, openGrokHome: URL) throws -> any OpenGrokShellWorkspace {
        LocalOpenGrokShellWorkspace(root: cwd, openGrokHome: openGrokHome)
    }
}

public struct OpenGrokShellACPComponents: Sendable {
    public let runtime: ACPAgentRuntime
    public let store: any ACPSessionStore

    public init(runtime: ACPAgentRuntime, store: any ACPSessionStore) {
        self.runtime = runtime
        self.store = store
    }
}

public protocol OpenGrokShellACPRuntimeFactory: Sendable {
    func makeRuntime(
        sessionID: SessionID,
        cwd: URL,
        workspace: any OpenGrokShellWorkspace,
        promptDriver: any ACPPromptDriver
    ) -> OpenGrokShellACPComponents
}

public struct DefaultOpenGrokShellACPRuntimeFactory: OpenGrokShellACPRuntimeFactory, Sendable {
    public init() {}

    public func makeRuntime(
        sessionID: SessionID,
        cwd: URL,
        workspace: any OpenGrokShellWorkspace,
        promptDriver: any ACPPromptDriver
    ) -> OpenGrokShellACPComponents {
        let store = InMemoryACPSessionStore()
        let runtime = ACPAgentRuntime(
            store: store,
            promptDriver: promptDriver,
            workspaceBoundary: workspace.acpBoundary
        )
        return OpenGrokShellACPComponents(runtime: runtime, store: store)
    }
}

public actor ProviderBackedACPPromptDriver: ACPPromptDriver {
    private let providerSession: any OpenGrokShellProviderSession
    private let turnDriver: any OpenGrokShellTurnDriver
    private var activeTurnID: String?

    public init(
        providerSession: any OpenGrokShellProviderSession,
        turnDriver: any OpenGrokShellTurnDriver
    ) {
        self.providerSession = providerSession
        self.turnDriver = turnDriver
    }

    public func run(
        context: ACPPromptContext,
        emit: @escaping @Sendable (SessionNotification, ACPNotificationDisposition) async -> Void
    ) async throws -> PromptResponse {
        let text = context.request.prompt.compactMap { block -> String? in
            if case let .text(value) = block { return value.text }
            return nil
        }.joined()
        let turnID = context.request.messageId ?? UUID().uuidString
        activeTurnID = turnID
        defer { activeTurnID = nil }
        let request = OpenGrokShellTurnRequest(promptID: turnID, text: text, turnID: turnID)
        let result = try await turnDriver.submit(providerSession: providerSession, request: request) { update in
            guard case let .assistantText(value) = update else { return }
            await emit(
                SessionNotification(
                    sessionId: context.request.sessionId,
                    update: .agentMessageChunk(ContentChunk(content: .text(value)))
                ),
                .live
            )
        }
        return PromptResponse(
            stopReason: result.cancelled ? .cancelled : .endTurn,
            userMessageId: context.request.messageId ?? turnID
        )
    }

    public func cancel(sessionId: AcpSessionId) async {
        guard let activeTurnID else { return }
        try? await turnDriver.cancel(providerSession: providerSession, turnID: activeTurnID)
    }
}

public struct OpenGrokShellConfiguration: Sendable {
    public let openGrokHome: URL
    public let processBackend: any ShellProcessBackend
    public let providerFactory: any OpenGrokShellProviderFactory
    public let turnDriver: any OpenGrokShellTurnDriver
    public let workspaceFactory: any OpenGrokShellWorkspaceFactory
    public let acpRuntimeFactory: any OpenGrokShellACPRuntimeFactory
    public let sessionStateStore: SessionStateStore
    public let activeSessionRegistry: ActiveSessionRegistry
    public let workflowStore: WorkflowSessionStore
    public let processID: UInt32
    public let now: @Sendable () -> Date

    public init(
        openGrokHome: URL,
        processBackend: any ShellProcessBackend,
        providerFactory: any OpenGrokShellProviderFactory,
        turnDriver: any OpenGrokShellTurnDriver,
        workspaceFactory: any OpenGrokShellWorkspaceFactory = LocalOpenGrokShellWorkspaceFactory(),
        acpRuntimeFactory: any OpenGrokShellACPRuntimeFactory = DefaultOpenGrokShellACPRuntimeFactory(),
        sessionStateStore: SessionStateStore? = nil,
        activeSessionRegistry: ActiveSessionRegistry? = nil,
        workflowStore: WorkflowSessionStore? = nil,
        processID: UInt32 = UInt32(ProcessInfo.processInfo.processIdentifier),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.openGrokHome = openGrokHome.standardizedFileURL
        self.processBackend = processBackend
        self.providerFactory = providerFactory
        self.turnDriver = turnDriver
        self.workspaceFactory = workspaceFactory
        self.acpRuntimeFactory = acpRuntimeFactory
        self.sessionStateStore = sessionStateStore ?? SessionStateStore(root: openGrokHome)
        self.activeSessionRegistry = activeSessionRegistry ?? ActiveSessionRegistry(root: openGrokHome)
        self.workflowStore = workflowStore ?? WorkflowSessionStore(directory: openGrokHome)
        self.processID = processID
        self.now = now
    }
}

private actor OpenGrokShellEventHub {
    private var history: [OpenGrokShellEvent] = []
    private var continuations: [UUID: AsyncThrowingStream<OpenGrokShellEvent, Error>.Continuation] = [:]
    private var finished = false
    private let historyLimit = 1_024

    func stream() -> AsyncThrowingStream<OpenGrokShellEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { self.attach(continuation) }
        }
    }

    func emit(_ event: OpenGrokShellEvent) {
        guard !finished else { return }
        history.append(event)
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    private func attach(_ continuation: AsyncThrowingStream<OpenGrokShellEvent, Error>.Continuation) {
        for event in history {
            continuation.yield(event)
        }
        guard !finished else {
            continuation.finish()
            return
        }
        continuations[UUID()] = continuation
    }
}

private actor OpenGrokShellCompletionFlag {
    private var completed = false

    func markCompleted() { completed = true }
    func isCompleted() -> Bool { completed }
}

private enum OpenGrokShellTurnOutcome: Sendable {
    case completed(OpenGrokShellTurnResult)
    case cancelled
    case failed(String)
}

private struct OpenGrokShellTurnKey: Hashable, Sendable {
    let sessionID: SessionID
    let turnID: String

    init(_ handle: OpenGrokShellTurnHandle) {
        self.sessionID = handle.sessionID
        self.turnID = handle.turnID
    }
}

public actor OpenGrokShell: OpenGrokShellFacade {
    private struct ManagedSession: Sendable {
        let request: OpenGrokShellSessionRequest
        let workspace: any OpenGrokShellWorkspace
        let providerSession: any OpenGrokShellProviderSession
        let acp: OpenGrokShellACPComponents
        let mailbox: SessionCommandMailbox
        var summary: SessionSummary
        var phase: SessionLifecyclePhase
        var chatHistory: [JSONValue]
        var activeTurnID: String?
    }

    private let configuration: OpenGrokShellConfiguration
    private let eventHub = OpenGrokShellEventHub()
    private var state: OpenGrokShellState = .new
    private var startupReport: OpenGrokShellStartupReport?
    private var sessions: [SessionID: ManagedSession] = [:]
    private var turnTasks: [OpenGrokShellTurnKey: Task<Void, Never>] = [:]
    private var turnCommands: [OpenGrokShellTurnKey: String] = [:]
    private var requestedCancellations: Set<OpenGrokShellTurnKey> = []
    private var turnOutcomes: [OpenGrokShellTurnKey: OpenGrokShellTurnOutcome] = [:]
    private var turnUpdateSequences: [OpenGrokShellTurnKey: UInt64] = [:]

    public init(configuration: OpenGrokShellConfiguration) {
        self.configuration = configuration
    }

    public func start() async throws -> OpenGrokShellStartupReport {
        switch state {
        case .running:
            return startupReport ?? OpenGrokShellStartupReport(restoredWorkflowRuns: 0, activeSessionCount: sessions.count, state: state)
        case .starting, .shuttingDown:
            throw OpenGrokShellError.invalidState(expected: OpenGrokShellState.running.rawValue, actual: state.rawValue)
        case .closed:
            throw OpenGrokShellError.invalidState(expected: OpenGrokShellState.new.rawValue, actual: state.rawValue)
        case .new:
            break
        }

        state = .starting
        await eventHub.emit(.startupBegan)
        do {
            let restored = try await configuration.workflowStore.restore()
            try await configuration.activeSessionRegistry.load()
            let activeCount = try await configuration.activeSessionRegistry.list().count
            state = .running
            let report = OpenGrokShellStartupReport(
                restoredWorkflowRuns: restored.count,
                activeSessionCount: activeCount,
                state: state
            )
            startupReport = report
            await eventHub.emit(.startupCompleted(report))
            return report
        } catch {
            state = .new
            let failure = OpenGrokShellError.startupFailed(String(describing: error))
            throw failure
        }
    }

    public func createSession(_ request: OpenGrokShellSessionRequest) async throws -> OpenGrokShellSessionDescriptor {
        try requireRunning()
        guard !request.sessionID.rawValue.isEmpty else {
            throw OpenGrokShellError.invalidSessionID(request.sessionID.rawValue)
        }
        guard sessions[request.sessionID] == nil else {
            throw OpenGrokShellError.duplicateSession(request.sessionID.rawValue)
        }
        let workspace = try configuration.workspaceFactory.makeWorkspace(
            sessionID: request.sessionID,
            cwd: request.cwd,
            openGrokHome: configuration.openGrokHome
        )
        let provider = try configuration.providerFactory.makeSession(for: request)
        let providerSnapshot = await provider.snapshot()
        let mailbox = try SessionCommandMailbox(sessionID: request.sessionID, ownerID: "shell")
        let promptDriver = ProviderBackedACPPromptDriver(
            providerSession: provider,
            turnDriver: configuration.turnDriver
        )
        let acp = configuration.acpRuntimeFactory.makeRuntime(
            sessionID: request.sessionID,
            cwd: request.cwd,
            workspace: workspace,
            promptDriver: promptDriver
        )
        let now = configuration.now()
        let summary = SessionSummary(
            sessionID: request.sessionID,
            cwd: request.cwd.path,
            createdAt: now,
            updatedAt: now,
            currentModelID: providerSnapshot.modelID,
            sessionKind: "shell"
        )
        let managed = ManagedSession(
            request: request,
            workspace: workspace,
            providerSession: provider,
            acp: acp,
            mailbox: mailbox,
            summary: summary,
            phase: .idle,
            chatHistory: [],
            activeTurnID: nil
        )
        let acpSnapshot = ACPSessionSnapshot(
            sessionId: AcpSessionId(request.sessionID.rawValue),
            cwd: request.cwd.path,
            modelId: ModelId(providerSnapshot.modelID),
            createdAt: timestamp(now),
            updatedAt: timestamp(now)
        )
        try await acp.store.create(acpSnapshot)
        sessions[request.sessionID] = managed
        try await persistSession(request.sessionID)
        try await configuration.activeSessionRegistry.register(
            ActiveSessionRecord(
                sessionID: request.sessionID,
                pid: configuration.processID,
                cwd: request.cwd.path,
                openedAt: now
            )
        )
        let descriptor = await descriptor(for: managed)
        await eventHub.emit(.sessionCreated(descriptor))
        return descriptor
    }

    public func lookupSession(_ sessionID: SessionID) async -> OpenGrokShellSessionDescriptor? {
        guard let session = sessions[sessionID] else { return nil }
        return await descriptor(for: session)
    }

    public func submitTurn(sessionID: SessionID, request: OpenGrokShellTurnRequest) async throws -> OpenGrokShellTurnHandle {
        try requireRunning()
        guard !request.promptID.isEmpty, !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenGrokShellError.invalidTurnRequest("prompt id and text are required")
        }
        guard var session = sessions[sessionID] else {
            throw OpenGrokShellError.sessionNotFound(sessionID.rawValue)
        }
        guard session.activeTurnID == nil else {
            throw OpenGrokShellError.turnAlreadyActive(session.activeTurnID ?? request.turnID)
        }
        let command = try await session.mailbox.enqueue(
            .prompt(promptID: request.promptID, text: request.text),
            owner: .client,
            issuedAtMS: milliseconds(configuration.now())
        )
        guard try await session.mailbox.claimNext(by: "shell") != nil else {
            throw OpenGrokShellError.turnAlreadyActive(request.turnID)
        }
        session.activeTurnID = request.turnID
        session.phase = .sampling
        session.summary.messageCount &+= 1
        session.summary.chatMessageCount &+= 1
        session.summary.updatedAt = configuration.now()
        session.chatHistory.append(.object([
            "role": .string("user"),
            "text": .string(request.text),
            "prompt_id": .string(request.promptID)
        ]))
        sessions[sessionID] = session
        let handle = OpenGrokShellTurnHandle(sessionID: sessionID, turnID: request.turnID)
        let key = OpenGrokShellTurnKey(handle)
        turnCommands[key] = command.commandID
        await eventHub.emit(.turnAccepted(handle))
        await eventHub.emit(.turnStarted(handle))
        try? await persistSession(sessionID)

        let provider = session.providerSession
        let driver = configuration.turnDriver
        let shell = self
        let task = Task { [shell] in
            do {
                let result = try await driver.submit(providerSession: provider, request: request) { update in
                    await shell.receive(update: update, for: handle)
                }
                await shell.finishTurn(handle: handle, commandID: command.commandID, outcome: .completed(result))
            } catch is CancellationError {
                await shell.finishTurn(handle: handle, commandID: command.commandID, outcome: .cancelled)
            } catch {
                await shell.finishTurn(handle: handle, commandID: command.commandID, outcome: .failed(String(describing: error)))
            }
        }
        turnTasks[key] = task
        return handle
    }

    public func waitForTurn(_ handle: OpenGrokShellTurnHandle, timeout: ShellDuration?) async throws -> OpenGrokShellTurnResult {
        let key = OpenGrokShellTurnKey(handle)
        guard turnTasks[key] != nil || turnOutcomes[key] != nil else {
            throw OpenGrokShellError.turnNotFound(handle.turnID)
        }
        let deadline = timeout.map { Date().addingTimeInterval($0.timeInterval) }
        while turnOutcomes[key] == nil {
            if let deadline, Date() >= deadline {
                throw OpenGrokShellError.waitTimedOut(handle.turnID)
            }
            do {
                try await Task.sleep(nanoseconds: 1_000_000)
            } catch {
                throw OpenGrokShellError.cancelled
            }
        }
        guard let outcome = turnOutcomes[key] else {
            throw OpenGrokShellError.turnNotFound(handle.turnID)
        }
        switch outcome {
        case let .completed(result):
            return result
        case .cancelled:
            throw OpenGrokShellError.cancelled
        case let .failed(message):
            throw OpenGrokShellError.turnFailed(message)
        }
    }

    public func cancelTurn(_ handle: OpenGrokShellTurnHandle) async throws {
        let key = OpenGrokShellTurnKey(handle)
        guard let task = turnTasks[key], let session = sessions[handle.sessionID] else {
            throw OpenGrokShellError.turnNotFound(handle.turnID)
        }
        requestedCancellations.insert(key)
        task.cancel()
        try? await configuration.turnDriver.cancel(
            providerSession: session.providerSession,
            turnID: handle.turnID
        )
        await eventHub.emit(.cancellationRequested(handle))
    }

    public func events() async -> AsyncThrowingStream<OpenGrokShellEvent, Error> {
        await eventHub.stream()
    }

    public func handleACPMessage(sessionID: SessionID, message: ACPMessage) async throws -> [ACPMessage] {
        try requireRunning()
        guard let session = sessions[sessionID] else {
            throw OpenGrokShellError.sessionNotFound(sessionID.rawValue)
        }
        let responses = await session.acp.runtime.handle(message)
        for response in responses {
            await eventHub.emit(.acpMessage(sessionID, response))
        }
        return responses
    }

    public func shutdown(timeout: ShellDuration = ShellDuration(timeInterval: 5)) async -> OpenGrokShellShutdownReport {
        if state == .closed {
            return OpenGrokShellShutdownReport(closedSessionCount: 0, cancelledTurnCount: 0, timedOut: false, state: state)
        }
        state = .shuttingDown
        await eventHub.emit(.shutdownBegan)
        let sessionValues = sessions
        let handles = turnTasks.keys.map { OpenGrokShellTurnHandle(sessionID: $0.sessionID, turnID: $0.turnID) }
        for handle in handles {
            let key = OpenGrokShellTurnKey(handle)
            requestedCancellations.insert(key)
            turnTasks[key]?.cancel()
            if let session = sessions[handle.sessionID] {
                try? await configuration.turnDriver.cancel(providerSession: session.providerSession, turnID: handle.turnID)
            }
        }

        let deadline = Date().addingTimeInterval(max(0, timeout.timeInterval))
        var timedOut = false
        while !turnTasks.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        if !turnTasks.isEmpty { timedOut = true }

        let processWorkFinished = await runBounded(timeout: remainingDuration(until: deadline)) {
            for sessionID in sessionValues.keys {
                await self.configuration.processBackend.killForegroundCommands(ownerSessionID: sessionID.rawValue)
                await self.configuration.processBackend.killAllBackgroundTasks(ownerSessionID: sessionID.rawValue)
            }
        }
        if !processWorkFinished { timedOut = true }

        for (sessionID, var session) in sessionValues {
            session.phase = .shuttingDown
            sessions[sessionID] = session
            try? await persistSession(sessionID)
            await session.acp.runtime.close()
            _ = try? await configuration.activeSessionRegistry.unregister(sessionID: sessionID)
            sessions.removeValue(forKey: sessionID)
            await eventHub.emit(.sessionClosed(sessionID))
        }
        turnTasks.removeAll()
        turnCommands.removeAll()
        requestedCancellations.removeAll()
        turnUpdateSequences.removeAll()
        state = .closed
        let report = OpenGrokShellShutdownReport(
            closedSessionCount: sessionValues.count,
            cancelledTurnCount: handles.count,
            timedOut: timedOut,
            state: state
        )
        await eventHub.emit(.shutdownCompleted(report))
        await eventHub.finish()
        return report
    }

    private func receive(update: OpenGrokShellTurnUpdateKind, for handle: OpenGrokShellTurnHandle) async {
        let key = OpenGrokShellTurnKey(handle)
        guard turnTasks[key] != nil else { return }
        let sequence = nextUpdateSequence(for: key)
        await eventHub.emit(.turnUpdate(OpenGrokShellTurnUpdate(turnID: handle.turnID, sequence: sequence, kind: update)))
    }

    private func finishTurn(
        handle: OpenGrokShellTurnHandle,
        commandID: String,
        outcome: OpenGrokShellTurnOutcome
    ) async {
        guard var session = sessions[handle.sessionID], session.activeTurnID == handle.turnID else { return }
        let key = OpenGrokShellTurnKey(handle)
        let wasCancelled = requestedCancellations.remove(key) != nil
        turnTasks.removeValue(forKey: key)
        turnCommands.removeValue(forKey: key)
        turnUpdateSequences.removeValue(forKey: key)
        session.activeTurnID = nil
        session.phase = .idle
        session.summary.updatedAt = configuration.now()
        sessions[handle.sessionID] = session
        if wasCancelled {
            turnOutcomes[key] = .cancelled
            _ = try? await session.mailbox.cancel(commandID: commandID, by: "shell")
            await eventHub.emit(.turnCancelled(handle))
        } else {
            switch outcome {
            case let .completed(result):
                turnOutcomes[key] = .completed(result)
                try? await session.mailbox.complete(commandID: commandID, by: "shell")
                await eventHub.emit(.turnCompleted(result))
            case .cancelled:
                turnOutcomes[key] = .cancelled
                _ = try? await session.mailbox.cancel(commandID: commandID, by: "shell")
                await eventHub.emit(.turnCancelled(handle))
            case let .failed(message):
                turnOutcomes[key] = .failed(message)
                try? await session.mailbox.complete(commandID: commandID, by: "shell")
                await eventHub.emit(.turnFailed(handle, message: message))
            }
        }
        try? await persistSession(handle.sessionID)
    }

    private func descriptor(for session: ManagedSession) async -> OpenGrokShellSessionDescriptor {
        let snapshot = await session.providerSession.snapshot()
        return OpenGrokShellSessionDescriptor(
            sessionID: session.summary.sessionID,
            cwd: session.request.cwd,
            modelID: snapshot.modelID,
            provider: snapshot.provider,
            phase: session.phase,
            createdAt: session.summary.createdAt,
            updatedAt: session.summary.updatedAt
        )
    }

    private func persistSession(_ sessionID: SessionID) async throws {
        guard let session = sessions[sessionID] else { return }
        let mailbox = await session.mailbox.snapshot()
        let state = PersistedSessionState(
            summary: session.summary,
            chatHistory: session.chatHistory,
            pendingCommands: mailbox.queued + (mailbox.inFlight.map { [$0] } ?? [])
        )
        try await configuration.sessionStateStore.save(state)
    }

    private func requireRunning() throws {
        guard state == .running else {
            throw OpenGrokShellError.invalidState(expected: OpenGrokShellState.running.rawValue, actual: state.rawValue)
        }
    }

    private func nextUpdateSequence(for key: OpenGrokShellTurnKey) -> UInt64 {
        let sequence = turnUpdateSequences[key] ?? 0
        turnUpdateSequences[key] = sequence &+ 1
        return sequence
    }
}

private func milliseconds(_ date: Date) -> UInt64 {
    UInt64(max(0, date.timeIntervalSince1970 * 1_000))
}

private func timestamp(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

private func remainingDuration(until deadline: Date) -> ShellDuration {
    ShellDuration(timeInterval: max(0, deadline.timeIntervalSinceNow))
}

private func runBounded(
    timeout: ShellDuration,
    operation: @escaping @Sendable () async -> Void
) async -> Bool {
    let flag = OpenGrokShellCompletionFlag()
    let task = Task {
        await operation()
        await flag.markCompleted()
    }
    let deadline = Date().addingTimeInterval(max(0, timeout.timeInterval))
    while !(await flag.isCompleted()) {
        if Date() >= deadline {
            task.cancel()
            return false
        }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return true
}
