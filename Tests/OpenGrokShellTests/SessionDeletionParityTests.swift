import Foundation
import OpenGrokShared
import OpenGrokShellBase
import OpenGrokShellSessionSupport
import Testing
@testable import OpenGrokShell

@Suite("Deleted shell sessions cannot resurrect", .serialized)
struct SessionDeletionParityTests {
    @Test("shutdown never recreates a deleted session's plaintext auxiliary state")
    func deletedStateStaysGoneAfterShutdown() async throws {
        let fixture = SessionDeletionFixture(sessionID: "deleted-shutdown")
        defer { fixture.cleanup() }
        try await fixture.start()
        try await fixture.completeTurn(text: "secret before deletion", turnID: "old-turn")
        #expect(try await fixture.store.load(sessionID: fixture.sessionID) != nil)

        try await fixture.shell.clearSessionHistoryForDeletion(fixture.sessionID)
        try await fixture.store.delete(sessionID: fixture.sessionID)
        #expect(try await fixture.store.load(sessionID: fixture.sessionID) == nil)

        let report = await fixture.shell.shutdown(timeout: ShellDuration(timeInterval: 1))
        #expect(report.closedSessionCount == 1)
        #expect(try await fixture.store.load(sessionID: fixture.sessionID) == nil)
    }

    @Test("the first genuinely accepted turn starts with completely clean history")
    func freshTurnCannotRecoverDeletedTranscript() async throws {
        let fixture = SessionDeletionFixture(sessionID: "deleted-restart")
        defer { fixture.cleanup() }
        try await fixture.start()
        try await fixture.completeTurn(text: "TOP-SECRET-OLD-HISTORY", turnID: "old-turn")
        try await fixture.shell.clearSessionHistoryForDeletion(fixture.sessionID)
        try await fixture.store.delete(sessionID: fixture.sessionID)

        await #expect(throws: OpenGrokShellError.self) {
            try await fixture.shell.submitTurn(
                sessionID: fixture.sessionID,
                request: OpenGrokShellTurnRequest(text: "   ", turnID: "invalid-turn")
            )
        }
        #expect(try await fixture.store.load(sessionID: fixture.sessionID) == nil)

        try await fixture.completeTurn(text: "clean replacement", turnID: "fresh-turn")
        let state = try #require(try await fixture.store.load(sessionID: fixture.sessionID))
        let encoded = try #require(String(data: JSONEncoder().encode(state), encoding: .utf8))
        #expect(!encoded.contains("TOP-SECRET-OLD-HISTORY"))
        #expect(encoded.contains("clean replacement"))
        #expect(state.chatHistory.count == 2)
        #expect(state.summary.chatMessageCount == 2)
        #expect(state.summary.sessionSummary.isEmpty)
        #expect(state.toolHistory.isEmpty)
        #expect(state.pendingCommands.isEmpty)

        let report = await fixture.shell.shutdown(timeout: ShellDuration(timeInterval: 1))
        #expect(report.state == .closed)
    }

    @Test("an active turn is rejected without clearing or suppressing its history")
    func activeTurnCannotBeDeleted() async throws {
        let fixture = SessionDeletionFixture(sessionID: "deleted-busy", blocked: true)
        defer { fixture.cleanup() }
        try await fixture.start()
        let handle = try await fixture.shell.submitTurn(
            sessionID: fixture.sessionID,
            request: OpenGrokShellTurnRequest(text: "still running", turnID: "busy-turn")
        )

        await #expect(throws: OpenGrokShellError.turnAlreadyActive("busy-turn")) {
            try await fixture.shell.clearSessionHistoryForDeletion(fixture.sessionID)
        }
        let state = try #require(try await fixture.store.load(sessionID: fixture.sessionID))
        let encoded = try #require(String(data: JSONEncoder().encode(state), encoding: .utf8))
        #expect(encoded.contains("still running"))

        try await fixture.shell.cancelTurn(handle)
        let report = await fixture.shell.shutdown(timeout: ShellDuration(timeInterval: 1))
        #expect(report.state == .closed)
    }

    @Test("deleting a missing resident session fails explicitly")
    func unknownSessionFailsClosed() async throws {
        let fixture = SessionDeletionFixture(sessionID: "existing")
        defer { fixture.cleanup() }
        let report = try await fixture.shell.start()
        #expect(report.state == .running)

        await #expect(throws: OpenGrokShellError.sessionNotFound("missing")) {
            try await fixture.shell.clearSessionHistoryForDeletion(SessionID("missing"))
        }

        let shutdown = await fixture.shell.shutdown(timeout: ShellDuration(timeInterval: 1))
        #expect(shutdown.state == .closed)
    }

    @Test("deletion never reopens an already crossed provider-export boundary")
    func providerBoundaryRemainsClosedAfterDeletion() async throws {
        let fixture = SessionDeletionFixture(
            sessionID: "deleted-provider-boundary",
            everUsedNonXAI: true
        )
        defer { fixture.cleanup() }
        try await fixture.start()
        try await fixture.completeTurn(text: "old provider context", turnID: "old-turn")
        try await fixture.shell.clearSessionHistoryForDeletion(fixture.sessionID)
        try await fixture.store.delete(sessionID: fixture.sessionID)
        try await fixture.completeTurn(text: "safe replacement", turnID: "fresh-turn")

        let state = try #require(try await fixture.store.load(sessionID: fixture.sessionID))
        #expect(state.summary.everUsedCodex)

        let shutdown = await fixture.shell.shutdown(timeout: ShellDuration(timeInterval: 1))
        #expect(shutdown.state == .closed)
    }
}

private struct SessionDeletionFixture {
    let root: URL
    let sessionID: SessionID
    let shell: OpenGrokShell
    let store: SessionStateStore

    init(sessionID: String, blocked: Bool = false, everUsedNonXAI: Bool = false) {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-session-deletion-\(UUID().uuidString)",
            isDirectory: true
        )
        self.sessionID = SessionID(sessionID)
        store = SessionStateStore(root: root)
        shell = OpenGrokShell(configuration: OpenGrokShellConfiguration(
            openGrokHome: root,
            processBackend: LocalShellProcessBackend(),
            providerFactory: SessionDeletionProviderFactory(everUsedNonXAI: everUsedNonXAI),
            turnDriver: SessionDeletionTurnDriver(blocked: blocked),
            sessionStateStore: store
        ))
    }

    func start() async throws {
        let startup = try await shell.start()
        #expect(startup.state == .running)
        let descriptor = try await shell.createSession(
            OpenGrokShellSessionRequest(sessionID: sessionID, cwd: root)
        )
        #expect(descriptor.sessionID == sessionID)
    }

    func completeTurn(text: String, turnID: String) async throws {
        let handle = try await shell.submitTurn(
            sessionID: sessionID,
            request: OpenGrokShellTurnRequest(
                promptID: "prompt-\(turnID)",
                text: text,
                turnID: turnID
            )
        )
        let result = try await shell.waitForTurn(
            handle,
            timeout: ShellDuration(timeInterval: 2)
        )
        #expect(result.output == "accepted: \(text)")
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct SessionDeletionProviderFactory: OpenGrokShellProviderFactory {
    let everUsedNonXAI: Bool

    func makeSession(
        for request: OpenGrokShellSessionRequest
    ) throws -> any OpenGrokShellProviderSession {
        SessionDeletionProvider(
            sessionID: request.sessionID.rawValue,
            everUsedNonXAI: everUsedNonXAI
        )
    }
}

private struct SessionDeletionProvider: OpenGrokShellProviderSession {
    let sessionID: String
    let everUsedNonXAI: Bool

    func snapshot() async -> OpenGrokShellProviderSessionSnapshot {
        OpenGrokShellProviderSessionSnapshot(
            sessionID: sessionID,
            modelID: "deletion-test-model",
            provider: "deletion-test-provider",
            generation: 0,
            everUsedNonXAI: everUsedNonXAI
        )
    }

    func beginTurn(turnID: String) async throws -> OpenGrokShellProviderTurnContext {
        OpenGrokShellProviderTurnContext(
            sessionID: sessionID,
            turnID: turnID,
            modelID: "deletion-test-model",
            attempt: 0
        )
    }

    func finishTurn(turnID: String) async throws {}
    func failTurn(turnID: String) async {}
    func cancelTurn(turnID: String) async throws {}
}

private actor SessionDeletionTurnDriver: OpenGrokShellTurnDriver {
    let blocked: Bool

    init(blocked: Bool) {
        self.blocked = blocked
    }

    func submit(
        providerSession: any OpenGrokShellProviderSession,
        request: OpenGrokShellTurnRequest,
        emit: @escaping @Sendable (OpenGrokShellTurnUpdateKind) async -> Void
    ) async throws -> OpenGrokShellTurnResult {
        let context = try await providerSession.beginTurn(turnID: request.turnID)
        if blocked {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            throw CancellationError()
        }
        let response = "accepted: \(request.text)"
        await emit(.assistantText(response))
        try await providerSession.finishTurn(turnID: request.turnID)
        return OpenGrokShellTurnResult(
            sessionID: SessionID(context.sessionID),
            turnID: request.turnID,
            output: response,
            stopReason: "test"
        )
    }

    func cancel(
        providerSession: any OpenGrokShellProviderSession,
        turnID: String
    ) async throws {
        try await providerSession.cancelTurn(turnID: turnID)
    }
}
