import Foundation
import OpenGrokPagerMinimal
import Testing

@Suite("Open Grok minimal pager")
struct OpenGrokPagerMinimalTests {
    @Test("forwards transcript events and restores the terminal once")
    func forwardsTranscriptAndRestores() async throws {
        let session = TestSession(sessionID: "session-1")
        await session.emit(.output("hello"))
        await session.emit(.completed(.init(sessionID: "session-1", summary: "done")))

        let runtime = TestRuntime(session: session)
        let renderer = RecordingRenderer()
        let output = RecordingOutput()
        let pager = OpenGrokPagerMinimal(runtime: runtime, renderer: renderer, output: output)

        let result = try await pager.run(.init(prompt: "say hello"))

        #expect(result.lifecycle == .completed)
        #expect(result.sessionID == "session-1")
        #expect(result.forwardedEventCount == 4)
        #expect(result.terminalRestored)
        #expect(await session.closeCount == 1)
        #expect(await renderer.beginCount == 1)
        #expect(await renderer.restoreCount == 1)
        #expect(await output.events == [
            .lifecycle(.starting),
            .lifecycle(.running),
            .output("hello"),
            .completed(.init(sessionID: "session-1", summary: "done"))
        ])
        #expect(await pager.currentLifecycle() == .completed)
    }

    @Test("cancellation forwards to the session and still restores the terminal")
    func cancellationRestoresTerminal() async throws {
        let session = TestSession(sessionID: "session-cancel")
        let runtime = TestRuntime(session: session)
        let renderer = RecordingRenderer()
        let output = RecordingOutput()
        let pager = OpenGrokPagerMinimal(runtime: runtime, renderer: renderer, output: output)

        let task = Task {
            try await pager.run(.init(prompt: "wait"))
        }
        await waitUntil { await runtime.didCreateSession }
        await pager.cancel()
        let result = try await task.value

        #expect(result.lifecycle == .cancelled)
        #expect(await session.cancelCount == 1)
        #expect(await session.closeCount == 1)
        #expect(await renderer.restoreCount == 1)
        #expect(await pager.currentLifecycle() == .cancelled)
    }

    @Test("restoration failure is surfaced after a completed transcript")
    func restorationFailureIsSurfaced() async {
        let session = TestSession(sessionID: "session-restore")
        await session.emit(.completed(.init(sessionID: "session-restore")))
        let runtime = TestRuntime(session: session)
        let renderer = RecordingRenderer(restoreError: TestError.restore)
        let output = RecordingOutput()
        let pager = OpenGrokPagerMinimal(runtime: runtime, renderer: renderer, output: output)

        do {
            _ = try await pager.run(.init(prompt: "finish"))
            Issue.record("expected terminal restoration to fail")
        } catch let error as OpenGrokPagerMinimalError {
            #expect(error == .terminalRestorationFailed("restore"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(await session.closeCount == 1)
        #expect(await renderer.restoreCount == 1)
        #expect(await pager.currentLifecycle() == .failed)
    }
}

private enum TestError: Error, Sendable, Equatable {
    case restore
}

private actor TestSession: OpenGrokPagerMinimalSessionAdapter {
    nonisolated let sessionID: String?
    nonisolated let events: AsyncThrowingStream<OpenGrokPagerMinimalEvent, Error>
    private let continuation: AsyncThrowingStream<OpenGrokPagerMinimalEvent, Error>.Continuation

    private(set) var cancelCount = 0
    private(set) var closeCount = 0

    init(sessionID: String?) {
        self.sessionID = sessionID
        var continuation: AsyncThrowingStream<OpenGrokPagerMinimalEvent, Error>.Continuation?
        self.events = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation!
    }

    func emit(_ event: OpenGrokPagerMinimalEvent) {
        continuation.yield(event)
    }

    func cancel() {
        cancelCount += 1
        continuation.yield(.cancelled)
        continuation.finish()
    }

    func close() {
        closeCount += 1
        continuation.finish()
    }
}

private actor TestRuntime: OpenGrokPagerMinimalRuntimeAdapter {
    let session: TestSession
    private(set) var didCreateSession = false

    init(session: TestSession) {
        self.session = session
    }

    func makeSession(
        for request: OpenGrokPagerMinimalRequest
    ) async throws -> any OpenGrokPagerMinimalSessionAdapter {
        didCreateSession = true
        return session
    }
}

private actor RecordingRenderer: OpenGrokPagerMinimalRenderAdapter {
    private(set) var beginCount = 0
    private(set) var restoreCount = 0
    private(set) var events: [OpenGrokPagerMinimalEvent] = []
    let restoreError: TestError?

    init(restoreError: TestError? = nil) {
        self.restoreError = restoreError
    }

    func begin() {
        beginCount += 1
    }

    func render(_ event: OpenGrokPagerMinimalEvent) {
        events.append(event)
    }

    func restoreTerminal() throws {
        restoreCount += 1
        if let restoreError {
            throw restoreError
        }
    }
}

private actor RecordingOutput: OpenGrokPagerMinimalOutputAdapter {
    private(set) var events: [OpenGrokPagerMinimalEvent] = []

    func forward(_ event: OpenGrokPagerMinimalEvent) {
        events.append(event)
    }
}

private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool
) async {
    for _ in 0..<1000 {
        if await condition() { return }
        await Task.yield()
    }
}
