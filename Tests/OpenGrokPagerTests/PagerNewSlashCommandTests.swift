// PagerNewSlashCommandTests.swift
//
// Reachability for the slash commands this wave registered — `/resume`,
// `/usage`, `/btw`, `/mcps`, `/effort`, `/rename` — through the live seam
// (AGENTS.md §3): real input events into the real controller, and the only
// accepted evidence is what lands on the render adapter and the runtime.
// None of these assert registry membership; every test dispatches the
// command and observes its overlay or effect.

import Foundation
import OpenGrokPager
import OpenGrokTerminalCore
import Testing

@Suite("New slash commands at the controller seam")
struct PagerNewSlashCommandTests {
    // MARK: - /usage

    @Test("/usage opens the usage overlay and /cost is the same command")
    func usageOpensOverlay() async throws {
        let harness = try await CommandHarness.run(submitting: ["/usage", "/cost"])
        #expect(await harness.overlayRequests.filter { $0 == .usage }.count == 2)
    }

    @Test("/usage refuses arguments with upstream's non-consumer copy")
    func usageRefusesArguments() async throws {
        // usage.rs:57-61: without the billing surface, any argument —
        // including upstream's own `manage` — is refused.
        let harness = try await CommandHarness.run(submitting: ["/usage manage"])
        #expect(await harness.overlayRequests.isEmpty)
        #expect(await harness.notices.contains("Unknown argument: manage. Use /usage"))
    }

    // MARK: - /resume

    @Test("/resume opens the session picker")
    func resumeOpensPicker() async throws {
        let harness = try await CommandHarness.run(submitting: ["/resume"])
        #expect(await harness.overlayRequests.contains(.sessionPicker))
    }

    @Test("a picker selection reaches the runtime swap and repaints the resumed session")
    func resumeSelectionReachesRuntime() async throws {
        // The picker's row selection round-trips as `/resume <id>`; the
        // controller must call the runtime and announce the swap.
        let harness = try await CommandHarness.run(submitting: ["/resume stored-session"])
        #expect(await harness.runtimeResumes == ["stored-session"])
        #expect(await harness.sessionResumes == ["stored-session"])
    }

    @Test("a runtime that cannot resume yields a notice, not a dead run")
    func resumeFailureIsANotice() async throws {
        let harness = try await CommandHarness.run(
            submitting: ["/resume missing", "/help"],
            resumeOutcome: .failure
        )
        #expect(await harness.sessionResumes.isEmpty)
        #expect(await harness.notices.contains { $0.hasPrefix("Could not resume session missing:") })
        // The run survived to service the next command.
        #expect(await harness.overlayRequests.contains(.help))
    }

    // MARK: - /btw (side-question dispatch)

    /// `/btw` is a SIDE question (`Action::SendBtw`, btw.rs:40-42 →
    /// `x.ai/btw` → `handle_side_question`): the controller emits the
    /// `.sideQuestion` intent for the render layer's off-conversation
    /// sample. Idle, NO prompt turn may start — the question does not enter
    /// the queue — and nothing rides the interjection machinery.
    @Test("/btw while idle emits the side-question intent and starts no turn")
    func btwIdleEmitsSideQuestionIntent() async throws {
        let harness = try await CommandHarness.run(submitting: ["/btw is the cache warm"])
        #expect(await harness.overlayRequests == [
            .sideQuestion(question: "is the cache warm"),
        ])
        #expect(await harness.turnPrompts.isEmpty)
        #expect(await harness.interjectionEchoes.isEmpty)
        #expect(!(await harness.notices.contains("Interjection sent")))
    }

    /// Mid-turn `/btw` bypasses the prompt queue WITHOUT touching the
    /// running turn or the interjection seam (upstream fires the ext method
    /// directly, notes.rs:282-329): the intent emits while the first turn
    /// is still holding, the seam sees nothing, and the only turn is the
    /// original prompt.
    @Test("/btw mid-turn emits the intent without a fallback turn or seam delivery")
    func btwMidTurnEmitsIntentWithoutSeamDelivery() async throws {
        let seam = RecordingSeam(stranded: [])
        let harness = try await CommandHarness.run(
            submitting: ["first", "/btw hurry up"],
            seam: seam,
            holdFirstSession: true,
            choreography: { runtime, controller, renderer in
                _ = await renderer.waitForOverlayCount(atLeast: 1)
                await runtime.releaseHeldSessions()
                _ = await runtime.waitForRequestCountBounded(atLeast: 1)
                try? await Task.sleep(nanoseconds: 200_000_000)
                await controller.shutdown()
            }
        )
        #expect(await harness.overlayRequests == [.sideQuestion(question: "hurry up")])
        #expect(await seam.delivered.isEmpty)
        #expect(await harness.turnPrompts == ["first"])
        #expect(await harness.interjectionEchoes.isEmpty)
    }

    /// Interjections stranded past the completed turn's final drain flush
    /// into front-of-queue prompt turns in original order — the port of
    /// `flush_stranded_interjections` at the completion arm
    /// (run_loop.rs:432-447): entry 0 front-most, ahead of queued rows.
    /// (The seam's live producer is the subagent collaboration quartet;
    /// `/btw` left it when it became a real side question.)
    @Test("stranded interjections flush to front prompt turns at turn end, in order")
    func strandedInterjectionsFlushAtTurnEnd() async throws {
        let seam = RecordingSeam(stranded: [["stranded one", "stranded two"]])
        let harness = try await CommandHarness.run(
            submitting: ["first", "queued follow-up"],
            seam: seam,
            holdFirstSession: true,
            choreography: { runtime, controller, _ in
                _ = await runtime.waitForRequestCountBounded(atLeast: 1)
                await runtime.releaseHeldSessions()
                _ = await runtime.waitForRequestCountBounded(atLeast: 4)
                await controller.shutdown()
            }
        )
        #expect(await harness.turnPrompts == [
            "first", "stranded one", "stranded two", "queued follow-up",
        ])
        let requests = await harness.turnRequests
        for index in [1, 2] where requests.count > index {
            #expect(
                requests[index].metadata[
                    OpenGrokPagerInteractiveController.interjectionFallbackMetadataKey
                ]?.hasPrefix(
                    OpenGrokPagerInteractiveController.interjectFallbackPromptPrefix
                ) == true,
                "stranded flush turn \(index) must carry the fallback id"
            )
        }
    }

    @Test("/btw without a question is refused with its usage line")
    func btwRequiresAQuestion() async throws {
        // The trailing space lands the draft in the argument phase, where
        // Enter is a plain send; a bare "/btw" Enter now completes into that
        // phase instead of dispatching (upstream's `is_command_complete`).
        let harness = try await CommandHarness.run(submitting: ["/btw "])
        #expect(await harness.notices.contains("Usage: /btw <question>"))
        #expect(await harness.overlayRequests.isEmpty)
    }

    // MARK: - /mcps

    @Test("/mcps opens the MCP status overlay")
    func mcpsOpensOverlay() async throws {
        let harness = try await CommandHarness.run(submitting: ["/mcps"])
        #expect(await harness.overlayRequests.contains(.mcpServers))
    }

    // MARK: - /effort

    @Test("/effort forwards the level query to the render layer, nil when bare")
    func effortForwardsQuery() async throws {
        // Trailing space on the bare form: a bare "/effort" Enter completes
        // into the argument phase now, so the dispatching press is the one
        // from the phase itself (upstream's `is_command_complete`).
        let harness = try await CommandHarness.run(submitting: ["/effort ", "/effort high"])
        #expect(await harness.overlayRequests == [
            .reasoningEffort(query: nil),
            .reasoningEffort(query: "high"),
        ])
    }

    // MARK: - /rename

    @Test("/rename forwards the title and /title is the same command")
    func renameForwardsTitle() async throws {
        let harness = try await CommandHarness.run(
            submitting: ["/rename My refactor session", "/title Two"]
        )
        #expect(await harness.overlayRequests == [
            .renameSession(title: "My refactor session"),
            .renameSession(title: "Two"),
        ])
    }

    @Test("/rename without a title is refused with upstream's usage copy")
    func renameRequiresTitle() async throws {
        // rename.rs:48-50. Trailing space: see btwRequiresAQuestion.
        let harness = try await CommandHarness.run(submitting: ["/rename "])
        #expect(await harness.overlayRequests.isEmpty)
        #expect(await harness.notices.contains("Usage: /rename <new title>"))
    }
}

// MARK: - Harness

/// A recording stand-in for the live interjection seam: `deliver` records
/// the text (no slash command produces into the seam since `/btw` became a
/// real side question — the recording proves exactly that); `collectStranded`
/// pops one configured batch per turn end (then drains empty, like the real
/// buffer).
private actor RecordingSeam {
    private(set) var delivered: [String] = []
    private var strandedQueue: [[String]]

    init(stranded: [[String]] = []) {
        self.strandedQueue = stranded
    }

    func deliver(_ text: String) -> Bool {
        delivered.append(text)
        return true
    }

    func collectStranded() -> [String] {
        strandedQueue.isEmpty ? [] : strandedQueue.removeFirst()
    }
}

private actor CommandHarness {
    private let renderer: CommandRecordingRenderer
    private let runtime: CommandTestRuntime

    private init(renderer: CommandRecordingRenderer, runtime: CommandTestRuntime) {
        self.renderer = renderer
        self.runtime = runtime
    }

    var overlayRequests: [OpenGrokPagerOverlayRequest] {
        get async { await renderer.overlayRequests }
    }
    var notices: [String] { get async { await renderer.notices } }
    var interjectionEchoes: [String] { get async { await renderer.interjectionEchoes } }
    var sessionResumes: [String] { get async { await renderer.sessionResumes } }
    var runtimeResumes: [String] { get async { await runtime.resumedSessionIDs } }
    var turnPrompts: [String] { get async { await runtime.requests.map(\.prompt) } }
    var turnRequests: [OpenGrokPagerRequest] { get async { await runtime.requests } }

    enum ResumeOutcome {
        case success
        case failure
    }

    /// Type each line and press Enter, then let input exhaustion end the run
    /// (or, when a turn is expected, shut down once it has landed). A
    /// `choreography` drives mid-turn scenarios (held sessions, seam waits)
    /// and owns the shutdown.
    static func run(
        submitting lines: [String],
        resumeOutcome: ResumeOutcome = .success,
        expectedTurns: Int? = nil,
        seam: RecordingSeam? = nil,
        holdFirstSession: Bool = false,
        choreography: (
            @Sendable (
                CommandTestRuntime,
                OpenGrokPagerInteractiveController,
                CommandRecordingRenderer
            ) async -> Void
        )? = nil
    ) async throws -> CommandHarness {
        var events: [InputEvent] = []
        for line in lines {
            events.append(.paste(line))
            events.append(.key(KeyEvent(key: .enter)))
        }
        let renderer = CommandRecordingRenderer()
        let runtime = CommandTestRuntime(
            resumeFails: resumeOutcome == .failure,
            holdFirstSession: holdFirstSession
        )
        let controller = OpenGrokPagerInteractiveController(
            input: makeStream(events, stayOpen: expectedTurns != nil || choreography != nil),
            runtime: runtime,
            renderer: renderer,
            output: SilentCommandOutput()
        )
        if let seam {
            await controller.setInterjectionSeam(OpenGrokPagerInterjectionSeam(
                deliver: { text in await seam.deliver(text) },
                collectStranded: { await seam.collectStranded() }
            ))
        }
        let stopper: Task<Void, Never>? = choreography.map { choreography in
            Task { await choreography(runtime, controller, renderer) }
        } ?? expectedTurns.map { turns in
            Task {
                await runtime.waitForRequestCount(atLeast: turns)
                await controller.shutdown()
            }
        }
        _ = try await controller.run(.init(prompt: "", mode: .inline))
        stopper?.cancel()
        return CommandHarness(renderer: renderer, runtime: runtime)
    }
}

private actor CommandRecordingRenderer: OpenGrokPagerInteractiveRenderAdapter {
    private var events: [OpenGrokPagerInteractiveEvent] = []

    func begin() {}
    func restoreTerminal() {}

    func render(_ event: OpenGrokPagerInteractiveEvent) {
        events.append(event)
    }

    var overlayRequests: [OpenGrokPagerOverlayRequest] {
        events.compactMap { if case .overlay(let request) = $0 { return request } else { return nil } }
    }

    /// Bounded poll for overlay intents — the sync point for mid-turn
    /// dispatch scenarios (the `.sideQuestion` emission has no turn or seam
    /// side effect to wait on, by design).
    func waitForOverlayCount(atLeast count: Int, timeout: TimeInterval = 15) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if overlayRequests.count >= count { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return overlayRequests.count >= count
    }

    var notices: [String] {
        events.compactMap { if case .notice(let message) = $0 { return message } else { return nil } }
    }

    var interjectionEchoes: [String] {
        events.compactMap { if case .interjected(let text) = $0 { return text } else { return nil } }
    }

    var sessionResumes: [String] {
        events.compactMap {
            if case .sessionResumed(let sessionID) = $0 { return sessionID }
            return nil
        }
    }
}

private struct SilentCommandOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}

private actor CommandTestRuntime: OpenGrokPagerRuntimeAdapter {
    private(set) var requests: [OpenGrokPagerRequest] = []
    private(set) var resumedSessionIDs: [String] = []
    private let resumeFails: Bool
    /// Hold the FIRST session open (a deterministically running turn) until
    /// `releaseHeldSessions`; later sessions complete immediately so the
    /// drain after release cannot stall.
    private let holdFirstSession: Bool
    private var heldSessions: [ImmediateSession] = []
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(resumeFails: Bool, holdFirstSession: Bool = false) {
        self.resumeFails = resumeFails
        self.holdFirstSession = holdFirstSession
    }

    func waitForRequestCount(atLeast count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }

    /// Bounded-poll twin for choreography: a stalled scenario ends in failed
    /// assertions instead of a hung run.
    func waitForRequestCountBounded(
        atLeast count: Int,
        timeout: TimeInterval = 15
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if requests.count >= count { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return requests.count >= count
    }

    func releaseHeldSessions() {
        for session in heldSessions { session.finish() }
        heldSessions.removeAll()
    }

    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        requests.append(request)
        let ready = requestWaiters.filter { $0.0 <= requests.count }
        requestWaiters.removeAll { $0.0 <= requests.count }
        for waiter in ready { waiter.1.resume() }
        let session = ImmediateSession(sessionID: request.sessionID ?? "auto")
        if holdFirstSession, requests.count == 1 {
            heldSessions.append(session)
        } else {
            session.finish()
        }
        return session
    }

    func replaceSession(from request: OpenGrokPagerRequest) async throws -> String {
        _ = request
        return "replacement"
    }

    func resumeSession(sessionID: String) async throws -> String {
        guard !resumeFails else {
            throw OpenGrokPagerError.sessionResumeUnsupported
        }
        resumedSessionIDs.append(sessionID)
        return sessionID
    }
}

private final class ImmediateSession: OpenGrokPagerSessionAdapter, @unchecked Sendable {
    let sessionID: String?
    let events: AsyncThrowingStream<OpenGrokPagerEvent, Error>
    private let continuation: AsyncThrowingStream<OpenGrokPagerEvent, Error>.Continuation

    init(sessionID: String) {
        self.sessionID = sessionID
        var captured: AsyncThrowingStream<OpenGrokPagerEvent, Error>.Continuation!
        events = AsyncThrowingStream { captured = $0 }
        continuation = captured
    }

    func finish() {
        continuation.yield(.completed(.init(sessionID: sessionID)))
        continuation.finish()
    }

    func cancel() async {
        continuation.yield(.cancelled)
        continuation.finish()
    }

    func close() async {
        continuation.finish()
    }
}

private func makeStream(_ events: [InputEvent], stayOpen: Bool) -> AsyncStream<InputEvent> {
    AsyncStream { continuation in
        for event in events { continuation.yield(event) }
        if !stayOpen { continuation.finish() }
    }
}
