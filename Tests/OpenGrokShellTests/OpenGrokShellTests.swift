import Foundation
import Testing
import OpenGrokACP
import OpenGrokSessionPersistence
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

    func unblock() {
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
    let driver = RecordingTurnDriver(block: true)
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
    await driver.unblock()
    _ = try await shell.waitForTurn(first, timeout: ShellDuration(timeInterval: 1))
    _ = await shell.shutdown(timeout: ShellDuration(timeInterval: 1))
}

@Test("completed turns persist assistant history and replayable terminal updates before returning")
func completedTurnsPersistConversationAndTerminal() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let home = root.appendingPathComponent("home", isDirectory: true)
    let sessionID = SessionID("durable-turn")
    let provider = RecordingProvider(sessionID: sessionID.rawValue)
    let driver = RecordingTurnDriver()
    let backend = RecordingBackend()
    let shell = makeShell(root: root, provider: provider, driver: driver, backend: backend)
    _ = try await shell.start()
    _ = try await shell.createSession(OpenGrokShellSessionRequest(sessionID: sessionID, cwd: root))

    let handle = try await shell.submitTurn(
        sessionID: sessionID,
        request: OpenGrokShellTurnRequest(
            promptID: "durable-prompt",
            text: "remember this",
            turnID: "durable-turn-id"
        )
    )
    _ = try await shell.waitForTurn(handle, timeout: ShellDuration(timeInterval: 1))

    let state = try #require(try await SessionStateStore(root: home).load(sessionID: sessionID))
    #expect(state.chatHistory == [
        .object([
            "type": .string("user"),
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string("remember this")
                ])
            ])
        ]),
        .object([
            "type": .string("assistant"),
            "content": .string("accepted: remember this")
        ])
    ])
    #expect(state.summary.chatMessageCount == 2)
    #expect(state.pendingCommands.isEmpty)
    #expect(state.updates.map(\.method) == [
        "session/update",
        "session/update",
        "_x.ai/session/update"
    ])
    let terminal = try #require(state.updates.last)
    #expect(terminal.timestamp == 1_700_000_000)
    #expect(terminal.params["update"]?["sessionUpdate"] == .string("turn_completed"))
    #expect(terminal.params["update"]?["prompt_id"] == .string("durable-prompt"))
    #expect(terminal.params["update"]?["agent_result"] == nil)
    #expect(state.transcript.entries.last?.event == .turnCompleted(kind: .completed))

    _ = await shell.shutdown(timeout: ShellDuration(timeInterval: 1))
}

@Test("resume restores canonical session history and metadata without replacing the canonical documents")
func resumedSessionRestoresCanonicalStateAndPreservesMetadata() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let home = root.appendingPathComponent("home", isDirectory: true)
    let sessionID = SessionID("resume-canonical")
    let createdAt = Date(timeIntervalSince1970: 1_600_000_000)
    let summary = SessionSummary(
        sessionID: sessionID,
        cwd: root.path,
        sessionSummary: "Original title",
        createdAt: createdAt,
        updatedAt: createdAt.addingTimeInterval(5),
        currentModelID: "previous-model",
        nextTraceTurn: 27,
        everUsedCodex: true,
        sessionKind: "restored-kind",
        extra: ["relocation_generation": .number(.uint64(8))]
    )
    let originalUpdate = try SessionUpdateEnvelope(
        timestamp: 9,
        method: "session/update",
        params: .object([
            "update": .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object(["type": .string("text"), "text": .string("old reply")])
            ])
        ])
    )
    let originalHistory: [JSONValue] = [
        .object([
            "type": .string("user"),
            "content": .array([
                .object(["type": .string("text"), "text": .string("old prompt")])
            ])
        ]),
        .object(["type": .string("assistant"), "content": .string("old reply")])
    ]
    let originalTranscript = SessionTranscript().appending(
        event: .assistantTextChunk(text: "old reply"),
        timestampMS: 10
    )
    let originalTool = SessionToolHistoryEntry(
        entryID: "historical-tool",
        sequence: 1,
        timestampMS: 10,
        toolCallID: "tool-call",
        title: "Read historical file",
        views: [.durableReplay]
    )
    let recovery = SessionRecoveryState(status: .recoverable, recoveryGeneration: 4)
    let original = PersistedSessionState(
        summary: summary,
        chatHistory: originalHistory,
        updates: [originalUpdate],
        transcript: originalTranscript,
        toolHistory: [originalTool],
        recovery: recovery
    )
    let documents = SessionDocumentStore(grokHome: home)
    try documents.save(original)

    let provider = RecordingProvider(sessionID: sessionID.rawValue)
    let driver = RecordingTurnDriver()
    let backend = RecordingBackend()
    let shell = makeShell(root: root, provider: provider, driver: driver, backend: backend)
    _ = try await shell.start()
    let descriptor = try await shell.createSession(
        OpenGrokShellSessionRequest(sessionID: sessionID, cwd: root, restorePersistedState: true)
    )

    #expect(descriptor.createdAt == createdAt)
    let restored = try #require(try await SessionStateStore(root: home).load(sessionID: sessionID))
    #expect(restored.chatHistory == originalHistory)
    #expect(restored.summary.createdAt == createdAt)
    #expect(restored.summary.nextTraceTurn == 27)
    #expect(restored.summary.currentModelID == "test-model")
    #expect(restored.summary.everUsedCodex)
    #expect(restored.summary.sessionKind == "restored-kind")
    #expect(restored.summary.extra["relocation_generation"] == .number(.uint64(8)))
    #expect(restored.updates == [originalUpdate])
    #expect(restored.transcript == originalTranscript)
    #expect(restored.toolHistory == [originalTool])
    #expect(restored.recovery == recovery)

    let handle = try await shell.submitTurn(
        sessionID: sessionID,
        request: OpenGrokShellTurnRequest(
            promptID: "resumed-prompt",
            text: "continue",
            turnID: "resumed-turn"
        )
    )
    _ = try await shell.waitForTurn(handle, timeout: ShellDuration(timeInterval: 1))

    let canonical = try #require(try documents.load(sessionID: sessionID.rawValue, cwd: root.path))
    #expect(canonical.chatHistory == originalHistory)
    let terminals = canonical.updates.filter {
        $0.params["update"]?["sessionUpdate"] == .string("turn_completed")
    }
    #expect(terminals.count == 1)
    #expect(terminals.first?.params["update"]?["prompt_id"] == .string("resumed-prompt"))

    let auxiliary = try #require(try await SessionStateStore(root: home).load(sessionID: sessionID))
    #expect(auxiliary.chatHistory.count == originalHistory.count + 2)
    #expect(auxiliary.toolHistory == [originalTool])
    #expect(auxiliary.recovery == recovery)

    _ = await shell.shutdown(timeout: ShellDuration(timeInterval: 1))
}

@Test("unpersistable turn submission rolls back admission without starting the provider")
func unpersistableTurnSubmissionRollsBack() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let home = root.appendingPathComponent("home", isDirectory: true)
    let sessionID = SessionID("submit-persistence-failure")
    let provider = RecordingProvider(sessionID: sessionID.rawValue)
    let driver = RecordingTurnDriver()
    let backend = RecordingBackend()
    let shell = makeShell(root: root, provider: provider, driver: driver, backend: backend)
    _ = try await shell.start()
    _ = try await shell.createSession(OpenGrokShellSessionRequest(sessionID: sessionID, cwd: root))

    let sessionDirectory = home.appendingPathComponent("sessions").appendingPathComponent(sessionID.rawValue)
    let savedDirectory = home.appendingPathComponent("saved-submit-state")
    try FileManager.default.moveItem(at: sessionDirectory, to: savedDirectory)
    try Data("not a directory".utf8).write(to: sessionDirectory)

    await #expect(throws: ShellSessionSupportError.self) {
        _ = try await shell.submitTurn(
            sessionID: sessionID,
            request: OpenGrokShellTurnRequest(
                promptID: "failed-prompt",
                text: "must not run",
                turnID: "failed-turn"
            )
        )
    }
    #expect(await provider.counts().begin == 0)
    #expect(await shell.lookupSession(sessionID)?.phase == .idle)

    try FileManager.default.removeItem(at: sessionDirectory)
    try FileManager.default.moveItem(at: savedDirectory, to: sessionDirectory)
    let handle = try await shell.submitTurn(
        sessionID: sessionID,
        request: OpenGrokShellTurnRequest(
            promptID: "recovered-prompt",
            text: "works after rollback",
            turnID: "recovered-turn"
        )
    )
    _ = try await shell.waitForTurn(handle, timeout: ShellDuration(timeInterval: 1))
    _ = await shell.shutdown(timeout: ShellDuration(timeInterval: 1))
}

@Test("terminal persistence failures surface instead of publishing a false successful completion")
func terminalPersistenceFailureDoesNotPublishCompletion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let home = root.appendingPathComponent("home", isDirectory: true)
    let sessionID = SessionID("terminal-persistence-failure")
    let provider = RecordingProvider(sessionID: sessionID.rawValue)
    let driver = RecordingTurnDriver(block: true)
    let backend = RecordingBackend()
    let shell = makeShell(root: root, provider: provider, driver: driver, backend: backend)
    let events = await shell.events()
    _ = try await shell.start()
    _ = try await shell.createSession(OpenGrokShellSessionRequest(sessionID: sessionID, cwd: root))
    let handle = try await shell.submitTurn(
        sessionID: sessionID,
        request: OpenGrokShellTurnRequest(
            promptID: "terminal-prompt",
            text: "cannot finish durably",
            turnID: "terminal-turn"
        )
    )

    let sessionDirectory = home.appendingPathComponent("sessions").appendingPathComponent(sessionID.rawValue)
    let savedDirectory = home.appendingPathComponent("saved-terminal-state")
    try FileManager.default.moveItem(at: sessionDirectory, to: savedDirectory)
    try Data("not a directory".utf8).write(to: sessionDirectory)
    await driver.unblock()

    do {
        _ = try await shell.waitForTurn(handle, timeout: ShellDuration(timeInterval: 1))
        Issue.record("the turn reported success despite its terminal persistence failure")
    } catch let error as OpenGrokShellError {
        guard case let .turnFailed(message) = error else { throw error }
        #expect(message.contains("failed to durably complete turn terminal-turn"))
    }

    try FileManager.default.removeItem(at: sessionDirectory)
    try FileManager.default.moveItem(at: savedDirectory, to: sessionDirectory)
    _ = await shell.shutdown(timeout: ShellDuration(timeInterval: 1))

    var sawFailure = false
    var sawCompletion = false
    for try await event in events {
        if case let .turnFailed(failed, _) = event, failed == handle { sawFailure = true }
        if case let .turnCompleted(result) = event, result.turnID == handle.turnID { sawCompletion = true }
    }
    #expect(sawFailure)
    #expect(!sawCompletion)
}

@Test("ACP prompt responses preserve provider max-token, refusal, and max-turn stop reasons")
func providerStopReasonsReachACPClients() {
    func result(_ reason: String?, cancelled: Bool = false) -> OpenGrokShellTurnResult {
        OpenGrokShellTurnResult(
            sessionID: SessionID("stop-reasons"),
            turnID: "stop-turn",
            output: "answer",
            stopReason: reason,
            cancelled: cancelled
        )
    }

    #expect(ProviderBackedACPPromptDriver.stopReason(for: result("max_tokens")) == .maxTokens)
    #expect(ProviderBackedACPPromptDriver.stopReason(for: result("length")) == .maxTokens)
    #expect(ProviderBackedACPPromptDriver.stopReason(for: result("max_turn_requests")) == .maxTurnRequests)
    #expect(ProviderBackedACPPromptDriver.stopReason(for: result("max_turns_reached")) == .cancelled)
    #expect(ProviderBackedACPPromptDriver.stopReason(for: result("content_filter")) == .refusal)
    #expect(ProviderBackedACPPromptDriver.stopReason(for: result("end_turn")) == .endTurn)
    #expect(ProviderBackedACPPromptDriver.stopReason(for: result("end_turn", cancelled: true)) == .cancelled)
}
