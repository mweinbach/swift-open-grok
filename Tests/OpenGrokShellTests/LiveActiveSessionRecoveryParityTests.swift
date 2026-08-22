import Foundation
import OpenGrokFileUtils
import OpenGrokShared
import OpenGrokShellBase
import OpenGrokShellSessionSupport
import Testing
@testable import OpenGrokShell

@Suite("Live shell active-session recovery parity")
struct LiveActiveSessionRecoveryParityTests {
    @Test("real shell startup collects dead sessions before publishing its active count")
    func startupReapsDeadSessionsAndExposesRecoveryRecords() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = ActiveSessionRegistry(root: root)
        try await seed.register(
            ActiveSessionRecord(
                sessionID: SessionID("previous-crash"),
                pid: 2_000_000_000,
                cwd: "/previous"
            )
        )
        try await seed.register(
            ActiveSessionRecord(
                sessionID: SessionID("other-live-process"),
                pid: currentProcessID,
                cwd: "/live"
            )
        )

        let shell = makeShell(root: root)
        let report = try await shell.start()

        #expect(report.state == .running)
        #expect(report.crashedSessions.map(\.sessionID.rawValue) == ["previous-crash"])
        #expect(report.activeSessionCount == 1)
        #expect(try await ActiveSessionRegistry(root: root).list().map(\.sessionID.rawValue) == [
            "other-live-process"
        ])
        #expect(try await shell.start() == report)
        let shutdown = await shell.shutdown(timeout: ShellDuration(timeInterval: 1))
        #expect(shutdown.deferredSessionCleanupCount == 0)
    }

    @Test("a subsequent shell cannot repeatedly rediscover a removed crashed session")
    func recoveredCrashIsRemovedBeforeNextLaunch() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ActiveSessionRegistry(root: root)
        try await registry.register(
            ActiveSessionRecord(sessionID: SessionID("orphan"), pid: 0, cwd: "/orphan")
        )

        let first = makeShell(root: root)
        let firstReport = try await first.start()
        #expect(firstReport.crashedSessions.map(\.sessionID.rawValue) == ["orphan"])
        let firstShutdown = await first.shutdown(timeout: ShellDuration(timeInterval: 1))
        #expect(firstShutdown.state == .closed)

        let second = makeShell(root: root)
        let secondReport = try await second.start()
        #expect(secondReport.crashedSessions.isEmpty)
        #expect(secondReport.activeSessionCount == 0)
        let secondShutdown = await second.shutdown(timeout: ShellDuration(timeInterval: 1))
        #expect(secondShutdown.state == .closed)
    }

    @Test("real shell shutdown reports a contended registry cleanup without blocking")
    func shutdownDefersContendedCleanupWithoutHanging() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = makeShell(root: root)
        let startup = try await shell.start()
        #expect(startup.state == .running)
        let sessionID = SessionID("contended-shutdown")
        let session = try await shell.createSession(
            OpenGrokShellSessionRequest(sessionID: sessionID, cwd: root)
        )
        #expect(session.sessionID == sessionID)

        let lock = try AdvisoryFileLock.acquire(
            at: root.appendingPathComponent(ActiveSessionRegistry.lockFileName)
        )
        let began = Date()
        let report = await shell.shutdown(timeout: ShellDuration(timeInterval: 1))
        let elapsed = Date().timeIntervalSince(began)
        #expect(report.state == .closed)
        #expect(report.closedSessionCount == 1)
        #expect(report.deferredSessionCleanupCount == 1)
        #expect(elapsed < 1)
        lock.release()

        let deferred = try await ActiveSessionRegistry(root: root).list()
        #expect(deferred.map(\.sessionID.rawValue) == ["contended-shutdown"])
        #expect(try await ActiveSessionRegistry(root: root).unregister(sessionID: sessionID))
    }

    private var currentProcessID: UInt32 {
        UInt32(ProcessInfo.processInfo.processIdentifier)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("live-active-session-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeShell(root: URL) -> OpenGrokShell {
        OpenGrokShell(configuration: OpenGrokShellConfiguration(
            openGrokHome: root,
            processBackend: LocalShellProcessBackend(),
            providerFactory: ActiveSessionParityProviderFactory(),
            turnDriver: ActiveSessionParityTurnDriver()
        ))
    }
}

private struct ActiveSessionParityProviderFactory: OpenGrokShellProviderFactory {
    func makeSession(
        for request: OpenGrokShellSessionRequest
    ) throws -> any OpenGrokShellProviderSession {
        ActiveSessionParityProvider(sessionID: request.sessionID.rawValue)
    }
}

private struct ActiveSessionParityProvider: OpenGrokShellProviderSession {
    let sessionID: String

    func snapshot() async -> OpenGrokShellProviderSessionSnapshot {
        OpenGrokShellProviderSessionSnapshot(
            sessionID: sessionID,
            modelID: "parity-model",
            provider: "parity-provider",
            generation: 0,
            everUsedNonXAI: false
        )
    }

    func beginTurn(turnID: String) async throws -> OpenGrokShellProviderTurnContext {
        OpenGrokShellProviderTurnContext(
            sessionID: sessionID,
            turnID: turnID,
            modelID: "parity-model",
            attempt: 0
        )
    }

    func finishTurn(turnID: String) async throws {}
    func failTurn(turnID: String) async {}
    func cancelTurn(turnID: String) async throws {}
}

private struct ActiveSessionParityTurnDriver: OpenGrokShellTurnDriver {
    func submit(
        providerSession: any OpenGrokShellProviderSession,
        request: OpenGrokShellTurnRequest,
        emit: @escaping @Sendable (OpenGrokShellTurnUpdateKind) async -> Void
    ) async throws -> OpenGrokShellTurnResult {
        throw OpenGrokShellError.invalidTurnRequest("recovery fixture never submits turns")
    }

    func cancel(
        providerSession: any OpenGrokShellProviderSession,
        turnID: String
    ) async throws {}
}
