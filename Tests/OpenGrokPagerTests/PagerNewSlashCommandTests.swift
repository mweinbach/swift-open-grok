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

    // MARK: - /btw (mid-turn interjection dispatch)

    /// Idle `/btw` takes upstream's fallback (run_loop.rs:1980-1989): the
    /// question becomes its own front-of-queue prompt turn — raw text, an
    /// `interject-fallback-` id (surfaced through the request metadata that
    /// keeps its user echo persist-only), started immediately — after the
    /// optimistic echo and upstream's "Interjection sent" toast copy.
    @Test("/btw while idle runs the question as its own fallback prompt turn")
    func btwIdleRunsFallbackPromptTurn() async throws {
        let harness = try await CommandHarness.run(
            submitting: ["/btw is the cache warm"],
            expectedTurns: 1
        )
        #expect(await harness.turnPrompts == ["is the cache warm"])
        let metadata = await harness.turnRequests.first?.metadata[
            OpenGrokPagerInteractiveController.interjectionFallbackMetadataKey
        ]
        #expect(
            metadata?.hasPrefix(
                OpenGrokPagerInteractiveController.interjectFallbackPromptPrefix
            ) == true,
            "the fallback turn must carry the interject-fallback- id, got \(String(describing: metadata))"
        )
        #expect(await harness.interjectionEchoes == ["is the cache warm"])
        #expect(await harness.notices.contains("Interjection sent"))
    }

    /// Mid-turn `/btw` delivers through the installed seam into the RUNNING
    /// turn (run_loop.rs:1974-1979): the seam sees the question, and no
    /// fallback prompt turn ever runs.
    @Test("/btw mid-turn delivers into the running turn through the seam")
    func btwMidTurnDeliversThroughSeam() async throws {
        let seam = RecordingSeam(deliverResult: true)
        let harness = try await CommandHarness.run(
            submitting: ["first", "/btw hurry up"],
            seam: seam,
            holdFirstSession: true,
            choreography: { runtime, controller in
                _ = await seam.waitForDeliveries(atLeast: 1)
                await runtime.releaseHeldSessions()
                _ = await runtime.waitForRequestCountBounded(atLeast: 1)
                try? await Task.sleep(nanoseconds: 200_000_000)
                await controller.shutdown()
            }
        )
        #expect(await seam.delivered == ["hurry up"])
        // Delivered live: the only turn is the original prompt.
        #expect(await harness.turnPrompts == ["first"])
        #expect(await harness.interjectionEchoes == ["hurry up"])
        #expect(await harness.notices.contains("Interjection sent"))
    }

    /// The running check can lose the race with turn end (the seam refuses).
    /// The text must then run as a fallback prompt turn at the FRONT of the
    /// queue — ahead of an already-queued follow-up — with the fallback id
    /// (queue_interjection_fallback_prompt's send-now semantics,
    /// interjection.rs:38-45).
    @Test("/btw whose delivery is refused queues a fallback prompt ahead of follow-ups")
    func btwRefusedDeliveryQueuesFallbackAtFront() async throws {
        let seam = RecordingSeam(deliverResult: false)
        let harness = try await CommandHarness.run(
            submitting: ["first", "queued follow-up", "/btw hurry up"],
            seam: seam,
            holdFirstSession: true,
            choreography: { runtime, controller in
                _ = await seam.waitForDeliveries(atLeast: 1)
                await runtime.releaseHeldSessions()
                _ = await runtime.waitForRequestCountBounded(atLeast: 3)
                await controller.shutdown()
            }
        )
        #expect(await harness.turnPrompts == ["first", "hurry up", "queued follow-up"])
        let requests = await harness.turnRequests
        let fallbackID = requests.count > 1 ? requests[1].metadata[
            OpenGrokPagerInteractiveController.interjectionFallbackMetadataKey
        ] : nil
        #expect(
            fallbackID?.hasPrefix(
                OpenGrokPagerInteractiveController.interjectFallbackPromptPrefix
            ) == true,
            "the queue head after the turn must be the interject-fallback- prompt"
        )
        // The follow-up turn is a normal prompt: no fallback marker.
        #expect(requests.count > 2 && requests[2].metadata[
            OpenGrokPagerInteractiveController.interjectionFallbackMetadataKey
        ] == nil)
    }

    /// Interjections stranded past the completed turn's final drain flush
    /// into front-of-queue prompt turns in original order — the port of
    /// `flush_stranded_interjections` at the completion arm
    /// (run_loop.rs:432-447): entry 0 front-most, ahead of queued rows.
    @Test("stranded interjections flush to front prompt turns at turn end, in order")
    func strandedInterjectionsFlushAtTurnEnd() async throws {
        let seam = RecordingSeam(
            deliverResult: true,
            stranded: [["stranded one", "stranded two"]]
        )
        let harness = try await CommandHarness.run(
            submitting: ["first", "queued follow-up", "/btw hurry up"],
            seam: seam,
            holdFirstSession: true,
            choreography: { runtime, controller in
                _ = await seam.waitForDeliveries(atLeast: 1)
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

/// A recording stand-in for the live interjection seam: `deliver` answers
/// with a fixed running/idle verdict and records the text; `collectStranded`
/// pops one configured batch per turn end (then drains empty, like the real
/// buffer).
private actor RecordingSeam {
    private(set) var delivered: [String] = []
    private let deliverResult: Bool
    private var strandedQueue: [[String]]

    init(deliverResult: Bool, stranded: [[String]] = []) {
        self.deliverResult = deliverResult
        self.strandedQueue = stranded
    }

    func deliver(_ text: String) -> Bool {
        delivered.append(text)
        return deliverResult
    }

    func collectStranded() -> [String] {
        strandedQueue.isEmpty ? [] : strandedQueue.removeFirst()
    }

    func waitForDeliveries(atLeast count: Int, timeout: TimeInterval = 15) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if delivered.count >= count { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return delivered.count >= count
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
            @Sendable (CommandTestRuntime, OpenGrokPagerInteractiveController) async -> Void
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
            Task { await choreography(runtime, controller) }
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
