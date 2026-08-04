import Foundation
import OpenGrokPager
import OpenGrokTerminalCore
import Testing

@Suite("Open Grok interactive pager controller")
struct OpenGrokPagerInteractiveControllerTests {
    @Test("edits and submits multiple prompts through reusable runtime sessions")
    func submitsMultipleTurns() async throws {
        let firstSession = TestInteractiveSession(sessionID: "session-1")
        await firstSession.emit(.output("first response"))
        await firstSession.emit(.completed(.init(sessionID: "session-1")))

        let secondSession = TestInteractiveSession(sessionID: "session-2")
        await secondSession.emit(.output("second response"))
        await secondSession.emit(.completed(.init(sessionID: "session-2")))

        let runtime = TestInteractiveRuntime(sessions: [firstSession, secondSession])
        let renderer = RecordingInteractiveRenderer()
        let output = RecordingInteractiveOutput()
        let input = makeInputStream([
            .paste("helo"),
            .key(KeyEvent(key: .left)),
            .key(KeyEvent(key: .char("l"), character: "l")),
            .key(KeyEvent(key: .enter)),
            .paste("second"),
            .key(KeyEvent(key: .enter)),
        ])
        let controller = OpenGrokPagerInteractiveController(
            input: input,
            runtime: runtime,
            renderer: renderer,
            output: output
        )

        let result = try await controller.run(.init(prompt: "", mode: .inline))

        #expect(result.lifecycle == .eof)
        #expect(result.submittedPrompts == ["hello", "second"])
        #expect(result.completedTurnCount == 2)
        #expect(result.sessionID == "session-2")
        #expect(result.terminalRestored)
        let requests = await runtime.requests
        #expect(requests.map(\.prompt) == ["hello", "second"])
        #expect(await firstSession.closeCount == 1)
        #expect(await secondSession.closeCount == 1)
        #expect(await renderer.beginCount == 1)
        #expect(await renderer.restoreCount == 1)
        let state = await controller.state()
        #expect(state.prompt == .init())
    }

    @Test("cancel input cancels and closes the active turn")
    func inputCancellationCleansUp() async throws {
        let session = TestInteractiveSession(sessionID: "cancel-session")
        let runtime = TestInteractiveRuntime(sessions: [session])
        let renderer = RecordingInteractiveRenderer()
        let output = RecordingInteractiveOutput()
        let input = makeInputStream([
            .paste("wait"),
            .key(KeyEvent(key: .enter)),
            .key(KeyEvent(key: .char("c"), modifiers: [.control], character: "c")),
        ])
        let controller = OpenGrokPagerInteractiveController(
            input: input,
            runtime: runtime,
            renderer: renderer,
            output: output
        )

        let result = try await controller.run(.init(prompt: "", mode: .inline))

        #expect(result.lifecycle == .cancelled)
        #expect(result.submittedPrompts == ["wait"])
        #expect(await session.cancelCount == 1)
        #expect(await session.closeCount == 1)
        #expect(await renderer.restoreCount == 1)
        let state = await controller.state()
        #expect(state.lifecycle == .cancelled)
    }

    @Test("input EOF restores the frontend without creating a session")
    func eofCleansUpWithoutSession() async throws {
        let runtime = TestInteractiveRuntime(sessions: [])
        let renderer = RecordingInteractiveRenderer()
        let output = RecordingInteractiveOutput()
        let controller = OpenGrokPagerInteractiveController(
            input: makeInputStream([]),
            runtime: runtime,
            renderer: renderer,
            output: output
        )

        let result = try await controller.run(.init(prompt: "", mode: .inline))

        #expect(result.lifecycle == .eof)
        #expect(result.submittedPrompts.isEmpty)
        #expect(result.completedTurnCount == 0)
        #expect(result.terminalRestored)
        let requests = await runtime.requests
        #expect(requests.isEmpty)
        #expect(await renderer.beginCount == 1)
        #expect(await renderer.restoreCount == 1)
        let events = await output.events
        #expect(events.contains(.eof))
    }

    @Test("resize reaches renderer during editing and active turns")
    func resizeReachesRenderer() async throws {
        let editingSize = TerminalSize(width: 100, height: 40)
        let runningSize = TerminalSize(width: 70, height: 20)
        let session = TestInteractiveSession(sessionID: "resize-session")
        let runtime = TestInteractiveRuntime(sessions: [session])
        let renderer = RecordingInteractiveRenderer()
        let output = RecordingInteractiveOutput()
        let input = makeInputStream([
            .resize(editingSize),
            .paste("wait"),
            .key(KeyEvent(key: .enter)),
            .resize(runningSize),
        ])
        let controller = OpenGrokPagerInteractiveController(
            input: input,
            runtime: runtime,
            renderer: renderer,
            output: output
        )

        let result = try await controller.run(.init(prompt: "", mode: .inline))

        #expect(result.lifecycle == .eof)
        #expect(await renderer.sizes == [editingSize, runningSize])
        #expect(await session.cancelCount == 1)
        #expect(await session.closeCount == 1)
        #expect(await renderer.restoreCount == 1)
    }
}

private actor TestInteractiveSession: OpenGrokPagerSessionAdapter {
    nonisolated let sessionID: String?
    nonisolated let events: AsyncThrowingStream<OpenGrokPagerEvent, Error>

    private let continuation: AsyncThrowingStream<OpenGrokPagerEvent, Error>.Continuation
    private(set) var cancelCount = 0
    private(set) var closeCount = 0

    init(sessionID: String?) {
        self.sessionID = sessionID
        var continuation: AsyncThrowingStream<OpenGrokPagerEvent, Error>.Continuation?
        self.events = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation!
    }

    func emit(_ event: OpenGrokPagerEvent) {
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

private actor TestInteractiveRuntime: OpenGrokPagerRuntimeAdapter {
    private var sessions: [TestInteractiveSession]
    private(set) var requests: [OpenGrokPagerRequest] = []

    init(sessions: [TestInteractiveSession]) {
        self.sessions = sessions
    }

    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        requests.append(request)
        guard !sessions.isEmpty else { throw TestInteractiveError.noSession }
        return sessions.removeFirst()
    }
}

private actor RecordingInteractiveRenderer: OpenGrokPagerInteractiveRenderAdapter {
    private(set) var events: [OpenGrokPagerInteractiveEvent] = []
    private(set) var sizes: [TerminalSize] = []
    private(set) var beginCount = 0
    private(set) var restoreCount = 0

    func begin() {
        beginCount += 1
    }

    func render(_ event: OpenGrokPagerInteractiveEvent) {
        events.append(event)
    }

    func resize(to size: TerminalSize) {
        sizes.append(size)
    }

    func restoreTerminal() {
        restoreCount += 1
    }
}

private actor RecordingInteractiveOutput: OpenGrokPagerInteractiveOutputAdapter {
    private(set) var events: [OpenGrokPagerInteractiveEvent] = []

    func forward(_ event: OpenGrokPagerInteractiveEvent) {
        events.append(event)
    }
}

private func makeInputStream(_ events: [InputEvent]) -> AsyncStream<InputEvent> {
    AsyncStream { continuation in
        for event in events {
            continuation.yield(event)
        }
        continuation.finish()
    }
}

private enum TestInteractiveError: Error, Sendable {
    case noSession
}
