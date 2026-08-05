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

    @Test("Ctrl+C during a turn cancels the turn and returns to the prompt")
    func interruptCancelsTurnNotRun() async throws {
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

        // Cancelling a turn is not cancelling the run: the loop returns to the
        // prompt and only the exhausted input stream ends it.
        #expect(result.lifecycle == .eof)
        #expect(result.submittedPrompts == ["wait"])
        #expect(await session.cancelCount == 1)
        #expect(await session.closeCount == 1)
        #expect(await renderer.restoreCount == 1)
        #expect(await renderer.events.contains(.turnCancelled))
    }

    @Test("an external cancel still ends the run")
    func externalCancelEndsRun() async throws {
        let session = TestInteractiveSession(sessionID: "external")
        let runtime = TestInteractiveRuntime(sessions: [session])
        let controller = OpenGrokPagerInteractiveController(
            input: makeOpenInputStream([
                .paste("wait"),
                .key(KeyEvent(key: .enter)),
            ]),
            runtime: runtime,
            renderer: RecordingInteractiveRenderer(),
            output: RecordingInteractiveOutput()
        )

        let task = Task { try await controller.run(.init(prompt: "", mode: .inline)) }
        // Wait for the turn to open by observing the runtime rather than
        // polling the controller actor, which would starve its own run loop.
        await runtime.waitForFirstRequest()
        await controller.cancel()

        let result = try await task.value
        #expect(result.lifecycle == .cancelled)
        #expect(await session.cancelCount >= 1)
    }

    @Test("Esc on an idle prompt arms a clear and never exits")
    func escapeArmsClear() async throws {
        let renderer = RecordingInteractiveRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: makeInputStream([
                .paste("draft"),
                .key(KeyEvent(key: .escape)),
                .key(KeyEvent(key: .escape)),
            ]),
            runtime: TestInteractiveRuntime(sessions: []),
            renderer: renderer,
            output: RecordingInteractiveOutput()
        )

        let result = try await controller.run(.init(prompt: "", mode: .inline))

        // The run survives both presses; the second clears the draft.
        #expect(result.lifecycle == .eof)
        #expect(result.submittedPrompts.isEmpty)
        let armed = await renderer.promptStates.contains {
            $0.pendingConfirmationKey == "Esc" && $0.pendingConfirmationLabel == "clear"
        }
        #expect(armed)
        #expect(await renderer.promptStates.last?.text == "")
    }

    @Test("Ctrl+C clears a draft first, then arms a quit")
    func interruptClearsThenQuits() async throws {
        let renderer = RecordingInteractiveRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: makeInputStream([
                .paste("draft"),
                .key(KeyEvent(key: .char("c"), modifiers: [.control], character: "c")),
                .key(KeyEvent(key: .char("c"), modifiers: [.control], character: "c")),
                .key(KeyEvent(key: .char("c"), modifiers: [.control], character: "c")),
            ]),
            runtime: TestInteractiveRuntime(sessions: []),
            renderer: renderer,
            output: RecordingInteractiveOutput()
        )

        let result = try await controller.run(.init(prompt: "", mode: .inline))

        #expect(result.lifecycle == .cancelled)
        let armed = await renderer.promptStates.contains {
            $0.pendingConfirmationKey == "Ctrl+c" && $0.pendingConfirmationLabel == "quit"
        }
        #expect(armed)
    }

    @Test("Up recalls prior prompts only on an empty composer")
    func historyRecall() async throws {
        let first = TestInteractiveSession(sessionID: "s1")
        await first.emit(.completed(.init(sessionID: "s1")))
        let second = TestInteractiveSession(sessionID: "s2")
        await second.emit(.completed(.init(sessionID: "s2")))

        let renderer = RecordingInteractiveRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: makeInputStream([
                .paste("alpha"),
                .key(KeyEvent(key: .enter)),
                .key(KeyEvent(key: .up)),
                .key(KeyEvent(key: .enter)),
            ]),
            runtime: TestInteractiveRuntime(sessions: [first, second]),
            renderer: renderer,
            output: RecordingInteractiveOutput()
        )

        let result = try await controller.run(.init(prompt: "", mode: .inline))

        #expect(result.submittedPrompts == ["alpha", "alpha"])
    }

    @Test("Down past the newest history entry restores the stashed draft")
    func historyRestoresDraft() async throws {
        let session = TestInteractiveSession(sessionID: "s1")
        await session.emit(.completed(.init(sessionID: "s1")))
        let renderer = RecordingInteractiveRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: makeInputStream([
                .paste("alpha"),
                .key(KeyEvent(key: .enter)),
                .key(KeyEvent(key: .up)),
                .key(KeyEvent(key: .down)),
            ]),
            runtime: TestInteractiveRuntime(sessions: [session]),
            renderer: renderer,
            output: RecordingInteractiveOutput()
        )

        _ = try await controller.run(.init(prompt: "", mode: .inline))

        let texts = await renderer.promptStates.map(\.text)
        #expect(texts.contains("alpha"))
        #expect(texts.last == "")
    }

    @Test("Up with a draft scrolls the transcript instead of recalling history")
    func upScrollsWithDraft() async throws {
        let renderer = RecordingInteractiveRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: makeInputStream([
                .paste("draft"),
                .key(KeyEvent(key: .up)),
                .key(KeyEvent(key: .pageUp)),
                .key(KeyEvent(key: .pageDown)),
            ]),
            runtime: TestInteractiveRuntime(sessions: []),
            renderer: renderer,
            output: RecordingInteractiveOutput()
        )

        _ = try await controller.run(.init(prompt: "", mode: .inline))

        let commands = await renderer.viewportCommands
        #expect(commands == [.lineUp, .pageUp, .pageDown])
    }

    @Test("Home and End jump the transcript when the composer is empty")
    func homeEndJumpTranscript() async throws {
        let renderer = RecordingInteractiveRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: makeInputStream([
                .key(KeyEvent(key: .home)),
                .key(KeyEvent(key: .end)),
            ]),
            runtime: TestInteractiveRuntime(sessions: []),
            renderer: renderer,
            output: RecordingInteractiveOutput()
        )

        _ = try await controller.run(.init(prompt: "", mode: .inline))

        #expect(await renderer.viewportCommands == [.top, .bottom])
    }

    @Test("typing a slash opens a completion menu that Tab accepts")
    func slashCompletion() async throws {
        let renderer = RecordingInteractiveRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: makeInputStream([
                .paste("/q"),
                .key(KeyEvent(key: .tab)),
            ]),
            runtime: TestInteractiveRuntime(sessions: []),
            renderer: renderer,
            output: RecordingInteractiveOutput()
        )

        _ = try await controller.run(.init(prompt: "", mode: .inline))

        let states = await renderer.promptStates
        #expect(states.contains { $0.completions.contains { $0.name == "/quit" } })
        #expect(states.last?.text == "/quit")
        #expect(states.last?.completions.isEmpty == true)
    }

    @Test("/help opens the shortcuts modal and /quit ends the run without a session")
    func slashCommandsRunLocally() async throws {
        let runtime = TestInteractiveRuntime(sessions: [])
        let output = RecordingInteractiveOutput()
        let controller = OpenGrokPagerInteractiveController(
            input: makeInputStream([
                .paste("/help"),
                .key(KeyEvent(key: .enter)),
                .paste("/quit"),
                .key(KeyEvent(key: .enter)),
            ]),
            runtime: runtime,
            renderer: RecordingInteractiveRenderer(),
            output: output
        )

        let result = try await controller.run(.init(prompt: "", mode: .inline))

        #expect(result.lifecycle == .shutdown)
        // Neither command reaches the model.
        #expect(await runtime.requests.isEmpty)
        #expect(result.submittedPrompts.isEmpty)
        // `/help` is a modal now, not a transcript dump, so it reaches the
        // renderer as an overlay request rather than a notice.
        let overlays = await output.events.compactMap { event -> OpenGrokPagerOverlayRequest? in
            if case .overlay(let request) = event { return request }
            return nil
        }
        #expect(overlays == [.help])
        #expect(OpenGrokPagerInteractiveController.helpText.contains("/clear"))
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

/// Poll `condition` until it holds or the deadline passes.
///
/// Every wait in the queue suite goes through here rather than through a
/// continuation the controller is expected to resume. A missed event then fails
/// one assertion instead of parking the whole test binary forever — these tests
/// drive a controller over input streams that deliberately never end, so an
/// unbounded await is a suite-wide hang waiting to happen.
private func waitUntil(
    seconds: Double = 10,
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

/// Await a controller run with a deadline, cancelling it if it overruns.
private func runResult(
    of task: Task<OpenGrokPagerInteractiveResult, Error>,
    seconds: Double = 10
) async -> OpenGrokPagerInteractiveResult? {
    let watchdog = Task {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        task.cancel()
    }
    defer { watchdog.cancel() }
    return try? await task.value
}

@Suite("Queued prompts")
struct OpenGrokPagerPromptQueueTests {
    @Test("Enter during a turn queues follow-ups that drain in order")
    func queuesAndDrainsInOrder() async throws {
        let first = TestInteractiveSession(sessionID: "q1")
        let second = TestInteractiveSession(sessionID: "q2")
        await second.emit(.completed(.init(sessionID: "q2")))
        let third = TestInteractiveSession(sessionID: "q3")
        await third.emit(.completed(.init(sessionID: "q3")))

        let runtime = TestInteractiveRuntime(sessions: [first, second, third])
        let renderer = RecordingInteractiveRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: makeOpenInputStream([
                .paste("alpha"),
                .key(KeyEvent(key: .enter)),
                .paste("beta"),
                .key(KeyEvent(key: .enter)),
                .paste("gamma"),
                .key(KeyEvent(key: .enter)),
            ]),
            runtime: runtime,
            renderer: renderer,
            output: RecordingInteractiveOutput()
        )

        let task = Task { try await controller.run(.init(prompt: "", mode: .inline)) }
        // Both follow-ups are queued behind the still-running first turn.
        #expect(await waitUntil { await renderer.queueCounts.contains(2) })
        #expect(await runtime.requests.map(\.prompt) == ["alpha"])
        await first.finish(sessionID: "q1")

        // Once the queue has drained, nothing is left to run.
        #expect(await waitUntil { await runtime.requests.count == 3 })
        await controller.shutdown()
        let result = await runResult(of: task)

        #expect(result?.submittedPrompts == ["alpha", "beta", "gamma"])
        #expect(await runtime.requests.map(\.prompt) == ["alpha", "beta", "gamma"])
    }

    @Test("cancelling a turn keeps the queue, quitting discards it")
    func cancelKeepsQueueAndQuitClearsIt() async throws {
        let running = TestInteractiveSession(sessionID: "keep")
        let runtime = TestInteractiveRuntime(sessions: [running])
        let renderer = RecordingInteractiveRenderer()
        let output = RecordingInteractiveOutput()
        let controller = OpenGrokPagerInteractiveController(
            input: makeOpenInputStream([
                .paste("alpha"),
                .key(KeyEvent(key: .enter)),
                .paste("beta"),
                .key(KeyEvent(key: .enter)),
                .key(KeyEvent(key: .char("c"), modifiers: [.control], character: "c")),
                .paste("/quit"),
                .key(KeyEvent(key: .enter)),
            ]),
            runtime: runtime,
            renderer: renderer,
            output: output
        )

        let task = Task { try await controller.run(.init(prompt: "", mode: .inline)) }
        let result = await runResult(of: task)

        #expect(result?.lifecycle == .shutdown)
        // The cancel returned to the composer without running the follow-up,
        // and never handed it to the runtime.
        #expect(await runtime.requests.map(\.prompt) == ["alpha"])
        #expect(await renderer.events.contains(.turnCancelled))
        // Quitting is what finally discards it, and says so.
        let notices = await output.notices
        #expect(notices.contains { $0.contains("discarded 1 queued prompt") })
    }

    @Test("Enter on an empty composer force-sends the head of the queue")
    func bareEnterForceSendsQueuedPrompt() async throws {
        let running = TestInteractiveSession(sessionID: "slow")
        let queued = TestInteractiveSession(sessionID: "next")
        await queued.emit(.completed(.init(sessionID: "next")))
        let runtime = TestInteractiveRuntime(sessions: [running, queued])
        let renderer = RecordingInteractiveRenderer()
        let output = RecordingInteractiveOutput()
        let controller = OpenGrokPagerInteractiveController(
            input: makeOpenInputStream([
                .paste("alpha"),
                .key(KeyEvent(key: .enter)),
                .paste("beta"),
                .key(KeyEvent(key: .enter)),
                // Composer is empty again — this Enter sends the follow-up now.
                .key(KeyEvent(key: .enter)),
            ]),
            runtime: runtime,
            renderer: renderer,
            output: output
        )

        let task = Task { try await controller.run(.init(prompt: "", mode: .inline)) }
        #expect(await waitUntil { await runtime.requests.count == 2 })
        await controller.shutdown()
        let result = await runResult(of: task)

        #expect(result?.submittedPrompts == ["alpha", "beta"])
        #expect(await running.cancelCount >= 1)
        #expect(await output.notices.contains { $0.contains("sending the queued prompt now") })
    }

    @Test("input EOF during a turn discards the queue")
    func eofDiscardsQueue() async throws {
        let running = TestInteractiveSession(sessionID: "eof")
        let runtime = TestInteractiveRuntime(sessions: [running])
        let output = RecordingInteractiveOutput()
        let controller = OpenGrokPagerInteractiveController(
            input: makeInputStream([
                .paste("alpha"),
                .key(KeyEvent(key: .enter)),
                .paste("beta"),
                .key(KeyEvent(key: .enter)),
                .key(KeyEvent(key: .char("d"), modifiers: [.control], character: "d")),
            ]),
            runtime: runtime,
            renderer: RecordingInteractiveRenderer(),
            output: output
        )

        let task = Task { try await controller.run(.init(prompt: "", mode: .inline)) }
        let result = await runResult(of: task)

        #expect(result?.lifecycle == .eof)
        #expect(await runtime.requests.map(\.prompt) == ["alpha"])
        #expect(await output.notices.contains { $0.contains("discarded 1 queued prompt") })
    }

    @Test("the queued count reaches the renderer as prompts arrive and drain")
    func publishesQueueCount() async throws {
        let running = TestInteractiveSession(sessionID: "count")
        let runtime = TestInteractiveRuntime(sessions: [running])
        let renderer = RecordingInteractiveRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: makeOpenInputStream([
                .paste("alpha"),
                .key(KeyEvent(key: .enter)),
                .paste("beta"),
                .key(KeyEvent(key: .enter)),
                .paste("gamma"),
                .key(KeyEvent(key: .enter)),
            ]),
            runtime: runtime,
            renderer: renderer,
            output: RecordingInteractiveOutput()
        )

        let task = Task { try await controller.run(.init(prompt: "", mode: .inline)) }
        #expect(await waitUntil { await renderer.queueCounts.contains(2) })
        await controller.shutdown()
        _ = await runResult(of: task)

        let counts = await renderer.queueCounts
        // 1 on the idle submit, 0 as it is dequeued, then 1 and 2 as the
        // follow-ups land behind the running turn.
        #expect(counts.prefix(4) == [1, 0, 1, 2])
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

    /// Complete the turn on demand, so a test can hold a turn open while it
    /// types follow-ups into the queue.
    func finish(sessionID: String) {
        continuation.yield(.completed(.init(sessionID: sessionID)))
        continuation.finish()
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
    private var firstRequestWaiters: [CheckedContinuation<Void, Never>] = []

    /// Suspends until `makeSession` has been called at least once.
    func waitForFirstRequest() async {
        guard requests.isEmpty else { return }
        await withCheckedContinuation { firstRequestWaiters.append($0) }
    }

    private func signalFirstRequest() {
        let waiters = firstRequestWaiters
        firstRequestWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private var sessions: [TestInteractiveSession]
    private(set) var requests: [OpenGrokPagerRequest] = []

    init(sessions: [TestInteractiveSession]) {
        self.sessions = sessions
    }

    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        requests.append(request)
        signalFirstRequest()
        guard !sessions.isEmpty else { throw TestInteractiveError.noSession }
        return sessions.removeFirst()
    }
}

private actor RecordingInteractiveRenderer: OpenGrokPagerInteractiveRenderAdapter {
    private(set) var events: [OpenGrokPagerInteractiveEvent] = []

    var promptStates: [OpenGrokPagerInteractivePromptState] {
        events.compactMap { event in
            if case .promptChanged(let state) = event { return state }
            return nil
        }
    }

    var viewportCommands: [OpenGrokPagerViewportCommand] {
        events.compactMap { event in
            if case .viewport(let command) = event { return command }
            return nil
        }
    }

    var queueCounts: [Int] {
        events.compactMap { event in
            if case .queueChanged(let count) = event { return count }
            return nil
        }
    }

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

    var notices: [String] {
        events.compactMap { event in
            if case .notice(let message) = event { return message }
            return nil
        }
    }

    func forward(_ event: OpenGrokPagerInteractiveEvent) {
        events.append(event)
    }
}

/// Yields `events` and then stays open, so the run ends only when something
/// other than input exhaustion terminates it.
private func makeOpenInputStream(_ events: [InputEvent]) -> AsyncStream<InputEvent> {
    AsyncStream { continuation in
        for event in events {
            continuation.yield(event)
        }
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
