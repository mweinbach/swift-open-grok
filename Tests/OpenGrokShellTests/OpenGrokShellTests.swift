import Foundation
import Testing
import OpenGrokShared
import OpenGrokShellBase
import OpenGrokShellSessionSupport
@testable import OpenGrokShell

private actor RecordingBackend: ShellProcessBackend {
    private(set) var killedForeground: [String] = []
    private(set) var killedBackground: [String] = []

    func run(_ request: ShellCommandRequest) async throws -> ShellCommandResult {
        throw ShellError.unsupported(capability: .processExecution, platform: "test")
    }

    func runBackground(_ request: ShellCommandRequest) async throws -> ShellBackgroundHandle {
        throw ShellError.unsupported(capability: .processExecution, platform: "test")
    }

    func getTask(_ taskID: String) async -> ShellTaskSnapshot? { nil }
    func killTask(_ taskID: String) async -> ShellKillOutcome { .notFound }

    func killForegroundCommands() async {}

    func killForegroundCommands(ownerSessionID: String) async {
        killedForeground.append(ownerSessionID)
    }

    func killAllBackgroundTasks() async {}

    func killAllBackgroundTasks(ownerSessionID: String) async {
        killedBackground.append(ownerSessionID)
    }

    func warmShell(at cwd: URL) async {}
    func backgroundForegroundCommand(toolCallID: String) async -> Bool { false }
    func waitForCompletion(_ taskID: String, timeout: ShellDuration?) async -> ShellTaskSnapshot? { nil }
    func listTasks() async -> [ShellTaskSnapshot] { [] }
    func shellCWD() async -> URL? { nil }

    func processCalls() -> (foreground: [String], background: [String]) {
        (killedForeground, killedBackground)
    }
}

private actor RecordingProvider: OpenGrokShellProviderSession {
    let sessionID: String
    let everUsedNonXAI: Bool
    private var activeTurnID: String?
    private(set) var beginCount = 0
    private(set) var finishCount = 0
    private(set) var cancelCount = 0

    init(sessionID: String, everUsedNonXAI: Bool = false) {
        self.sessionID = sessionID
        self.everUsedNonXAI = everUsedNonXAI
    }

    func snapshot() async -> OpenGrokShellProviderSessionSnapshot {
        OpenGrokShellProviderSessionSnapshot(
            sessionID: sessionID,
            modelID: "test-model",
            provider: "test-provider",
            generation: 0,
            everUsedNonXAI: everUsedNonXAI
        )
    }

    func beginTurn(turnID: String) async throws -> OpenGrokShellProviderTurnContext {
        guard activeTurnID == nil else { throw OpenGrokShellError.turnAlreadyActive(turnID) }
        activeTurnID = turnID
        beginCount += 1
        return OpenGrokShellProviderTurnContext(
            sessionID: sessionID,
            turnID: turnID,
            modelID: "test-model",
            attempt: 0
        )
    }

    func finishTurn(turnID: String) async throws {
        guard activeTurnID == turnID else { throw OpenGrokShellError.turnNotFound(turnID) }
        activeTurnID = nil
        finishCount += 1
    }

    func failTurn(turnID: String) async {
        if activeTurnID == turnID { activeTurnID = nil }
    }

    func cancelTurn(turnID: String) async throws {
        if activeTurnID == turnID {
            activeTurnID = nil
            cancelCount += 1
        }
    }

    func counts() -> (begin: Int, finish: Int, cancel: Int) {
        (beginCount, finishCount, cancelCount)
    }
}

private struct RecordingProviderFactory: OpenGrokShellProviderFactory {
    let provider: RecordingProvider

    func makeSession(for request: OpenGrokShellSessionRequest) throws -> any OpenGrokShellProviderSession {
        provider
    }
}

private actor RecordingTurnDriver: OpenGrokShellTurnDriver {
    private let block: Bool
    private var release = false

    init(block: Bool = false) {
        self.block = block
    }

    func submit(
        providerSession: any OpenGrokShellProviderSession,
        request: OpenGrokShellTurnRequest,
        emit: @escaping @Sendable (OpenGrokShellTurnUpdateKind) async -> Void
    ) async throws -> OpenGrokShellTurnResult {
        let context = try await providerSession.beginTurn(turnID: request.turnID)
        await emit(.assistantText("accepted: \(request.text)"))
        if block {
            while !release {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        try await providerSession.finishTurn(turnID: request.turnID)
        return OpenGrokShellTurnResult(
            sessionID: SessionID(context.sessionID),
            turnID: request.turnID,
            output: "accepted: \(request.text)",
            stopReason: "test"
        )
    }

    func cancel(providerSession: any OpenGrokShellProviderSession, turnID: String) async throws {
        try await providerSession.cancelTurn(turnID: turnID)
        release = true
    }
}

private struct RecordingWorkspaceFactory: OpenGrokShellWorkspaceFactory {
    func makeWorkspace(sessionID: SessionID, cwd: URL, openGrokHome: URL) throws -> any OpenGrokShellWorkspace {
        LocalOpenGrokShellWorkspace(root: cwd, openGrokHome: openGrokHome)
    }
}

private func makeShell(
    root: URL,
    provider: RecordingProvider,
    driver: RecordingTurnDriver,
    backend: RecordingBackend
) -> OpenGrokShell {
    let configuration = OpenGrokShellConfiguration(
        openGrokHome: root.appendingPathComponent("home", isDirectory: true),
        processBackend: backend,
        providerFactory: RecordingProviderFactory(provider: provider),
        turnDriver: driver,
        workspaceFactory: RecordingWorkspaceFactory(),
        now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )
    return OpenGrokShell(configuration: configuration)
}

@Test("startup creates, looks up, streams, and shuts down a session")
func startupSessionLifecycle() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let provider = RecordingProvider(sessionID: "session-1")
    let driver = RecordingTurnDriver()
    let backend = RecordingBackend()
    let shell = makeShell(root: root, provider: provider, driver: driver, backend: backend)
    let events = await shell.events()
    let report = try await shell.start()
    #expect(report.state == .running)

    let sessionID = SessionID("session-1")
    let descriptor = try await shell.createSession(
        OpenGrokShellSessionRequest(sessionID: sessionID, cwd: root)
    )
    #expect(descriptor.modelID == "test-model")
    #expect(await shell.lookupSession(sessionID) != nil)

    let handle = try await shell.submitTurn(
        sessionID: sessionID,
        request: OpenGrokShellTurnRequest(promptID: "prompt-1", text: "hello", turnID: "turn-1")
    )
    let result = try await shell.waitForTurn(handle, timeout: ShellDuration(timeInterval: 1))
    #expect(result.output == "accepted: hello")
    let shutdown = await shell.shutdown(timeout: ShellDuration(timeInterval: 1))
    #expect(shutdown.closedSessionCount == 1)
    #expect(shutdown.timedOut == false)

    var collected: [OpenGrokShellEvent] = []
    for try await event in events {
        collected.append(event)
    }
    #expect(collected.contains { if case .sessionCreated = $0 { return true }; return false })
    #expect(collected.contains { if case .turnCompleted = $0 { return true }; return false })
    #expect(collected.contains { if case .shutdownCompleted = $0 { return true }; return false })
}

@Test("createSession persists the provider export boundary marker")
func createSessionPersistsBoundaryMarker() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let provider = RecordingProvider(sessionID: "session-marker", everUsedNonXAI: true)
    let driver = RecordingTurnDriver()
    let backend = RecordingBackend()
    let shell = makeShell(root: root, provider: provider, driver: driver, backend: backend)
    _ = try await shell.start()
    let sessionID = SessionID("session-marker")
    _ = try await shell.createSession(OpenGrokShellSessionRequest(sessionID: sessionID, cwd: root))

    let store = SessionStateStore(root: root.appendingPathComponent("home", isDirectory: true))
    let state = try await store.load(sessionID: sessionID)
    #expect(state?.summary.everUsedCodex == true)
    _ = await shell.shutdown(timeout: ShellDuration(timeInterval: 1))
}

@Test("cancellation reaches the provider and bounded shutdown kills owned tools")
func cancellationAndBoundedShutdown() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let provider = RecordingProvider(sessionID: "session-2")
    let driver = RecordingTurnDriver(block: true)
    let backend = RecordingBackend()
    let shell = makeShell(root: root, provider: provider, driver: driver, backend: backend)
    _ = try await shell.start()
    let sessionID = SessionID("session-2")
    _ = try await shell.createSession(OpenGrokShellSessionRequest(sessionID: sessionID, cwd: root))
    let handle = try await shell.submitTurn(
        sessionID: sessionID,
        request: OpenGrokShellTurnRequest(promptID: "prompt-2", text: "cancel me", turnID: "turn-2")
    )
    try await shell.cancelTurn(handle)
    await #expect(throws: OpenGrokShellError.cancelled) {
        try await shell.waitForTurn(handle, timeout: ShellDuration(timeInterval: 1))
    }
    let counts = await provider.counts()
    #expect(counts.cancel == 1)
    let shutdown = await shell.shutdown(timeout: ShellDuration(timeInterval: 1))
    #expect(shutdown.cancelledTurnCount == 0)
    let calls = await backend.processCalls()
    #expect(calls.foreground == ["session-2"])
    #expect(calls.background == ["session-2"])
}

@Test("duplicate sessions and turns are rejected deterministically")
func duplicateLifecycleRequests() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let provider = RecordingProvider(sessionID: "session-3")
    let driver = RecordingTurnDriver()
    let backend = RecordingBackend()
    let shell = makeShell(root: root, provider: provider, driver: driver, backend: backend)
    _ = try await shell.start()
    let sessionID = SessionID("session-3")
    let request = OpenGrokShellSessionRequest(sessionID: sessionID, cwd: root)
    _ = try await shell.createSession(request)
    await #expect(throws: OpenGrokShellError.duplicateSession("session-3")) {
        _ = try await shell.createSession(request)
    }
    let first = try await shell.submitTurn(
        sessionID: sessionID,
        request: OpenGrokShellTurnRequest(promptID: "prompt-3", text: "first", turnID: "turn-3")
    )
    await #expect(throws: OpenGrokShellError.turnAlreadyActive("turn-3")) {
        _ = try await shell.submitTurn(
            sessionID: sessionID,
            request: OpenGrokShellTurnRequest(promptID: "prompt-4", text: "second", turnID: "turn-4")
        )
    }
    _ = try await shell.waitForTurn(first, timeout: ShellDuration(timeInterval: 1))
    _ = await shell.shutdown(timeout: ShellDuration(timeInterval: 1))
}
