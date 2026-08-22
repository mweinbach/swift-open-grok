// PagerSwarmCommandTests.swift
//
// `/swarm` at the controller seam (AGENTS.md §3): real input events into
// the real controller, asserted on the overlay requests and turn starts
// that land on the render adapter. The upstream contract is
// `slash/commands/swarm.rs` and `app/dispatch/router.rs:1052-1093`; every
// copy assertion is byte-exact. Also here: the orchestration-wait
// send-now exemption (`prompt_queue.rs:222-233`) — a prompt arriving
// while an `agent_swarm` cohort holds the turn is promoted, never
// cancelled. The live halves (the tracker the toggle reaches, the
// reminder it injects) are pinned in
// `Tests/OpenGrokCLITests/LiveSwarmModeSessionTests.swift`.

import Foundation
@testable import OpenGrokPager
import OpenGrokPagerMinimal
import OpenGrokTerminalCore
import Testing

@Suite("/swarm at the controller seam")
struct PagerSwarmCommandTests {
    // MARK: - Registry

    @Test("the registry row carries upstream's name, summary and usage verbatim")
    func registryRowIsVerbatim() {
        let commands = OpenGrokPagerInteractiveController.builtinCommands
        let swarm = commands.first { $0.name == "swarm" }
        // `swarm.rs:9-17` (name, description), `:15-17` (usage).
        #expect(swarm?.summary == "Toggle swarm mode or run a one-shot swarm task")
        #expect(swarm?.usage == "/swarm [on|off|task]")
        #expect(swarm?.aliases.isEmpty == true)
        // Every argument form is optional (`swarm.rs:42-44`: bare toggles),
        // so a bare Enter dispatches instead of parking in argument phase.
        #expect(swarm?.requiresArguments == false)

        // Visible in `/help` — a registered command invisible there was
        // the D1 regression.
        #expect(OpenGrokPagerInteractiveController.helpText.contains("/swarm [on|off|task]"))
    }

    // MARK: - Dispatch

    @Test("bare /swarm toggles off the live tracker state")
    func bareSwarmToggles() async throws {
        // Tracker off → toggle enables (`swarm.rs:45-49`: `!swarm_mode`).
        let offHarness = try await SwarmCommandHarness.run(
            submitting: ["/swarm"], swarmModeActive: false
        )
        #expect(await offHarness.overlayRequests == [.setSwarmMode(enabled: true)])
        #expect(await offHarness.turnPrompts.isEmpty)

        // Tracker on → toggle disables.
        let onHarness = try await SwarmCommandHarness.run(
            submitting: ["/swarm"], swarmModeActive: true
        )
        #expect(await onHarness.overlayRequests == [.setSwarmMode(enabled: false)])
    }

    @Test("bare /swarm with no live state provider resolves off and enables")
    func bareSwarmWithoutProviderEnables() async throws {
        let harness = try await SwarmCommandHarness.run(submitting: ["/swarm"])
        #expect(await harness.overlayRequests == [.setSwarmMode(enabled: true)])
    }

    @Test("/swarm on and /swarm off set the mode explicitly")
    func onAndOffSetExplicitly() async throws {
        // `swarm.rs:50-59`: explicit set regardless of current state.
        let harness = try await SwarmCommandHarness.run(
            submitting: ["/swarm on", "/swarm off"], swarmModeActive: true
        )
        #expect(await harness.overlayRequests == [
            .setSwarmMode(enabled: true),
            .setSwarmMode(enabled: false),
        ])
        #expect(await harness.turnPrompts.isEmpty)
    }

    @Test("/swarm <task> enters swarm task mode BEFORE the task's turn starts")
    func taskArmOrdersModeThenPrompt() async throws {
        let harness = try await SwarmCommandHarness.run(
            submitting: ["/swarm investigate auth races"]
        )
        let events = await harness.events
        // The mode-switch intent must be emitted (and, since `emit` awaits
        // the renderer, handled) before the turn starts — the port of
        // upstream's ordered `SwarmModeThenPrompt` effect
        // (`router.rs:1052-1093`, `effects/mod.rs:3148-3188`).
        let armIndex = events.firstIndex(of: .overlay(.swarmTaskMode))
        let turnIndex = events.firstIndex { event in
            if case .turnStarted(let request) = event {
                return request.prompt == "investigate auth races"
            }
            return false
        }
        #expect(armIndex != nil, "the mode-switch intent must be emitted")
        #expect(turnIndex != nil, "the task must run as a turn")
        if let armIndex, let turnIndex {
            #expect(armIndex < turnIndex,
                    "the session must observe swarm mode before the prompt")
        }
        // Upstream preserves the trimmed task text
        // (`swarm.rs:60-61`, pinned by its
        // `task_is_preserved_as_a_one_shot_prompt` test).
        #expect(harness.result.submittedPrompts == ["investigate auth races"])
    }

    @Test("whitespace-only arguments are treated as the bare toggle")
    func whitespaceOnlyArgsAreBare() async throws {
        let harness = try await SwarmCommandHarness.run(
            submitting: ["/swarm    "], swarmModeActive: false
        )
        #expect(await harness.overlayRequests == [.setSwarmMode(enabled: true)])
        #expect(await harness.turnPrompts.isEmpty)
    }

    // MARK: - The orchestration-wait send-now exemption

    /// With `enter_steers` on, Enter during a turn normally cancels it and
    /// runs the draft next. While the turn is parked in an orchestration
    /// wait (an `agent_swarm` cohort), the draft is promoted but the turn
    /// is NOT cancelled (`prompt_queue.rs:222-233`; upstream's actor test
    /// `queue_input_during_agent_swarm_orchestration_wait_does_not_cancel`).
    @Test("enter-steers during an orchestration wait promotes without cancelling")
    func steerDuringOrchestrationWaitDoesNotCancel() async throws {
        let harness = try await SwarmCommandHarness.runSteering(
            orchestrationActive: true
        )
        // Probed MID-TURN by the trailing `/queue` keystrokes: the steered
        // draft was promoted to the queue head while the swarm turn kept
        // the wheel. Had the turn been preempted, the queue would have
        // drained "steer me" into its own turn before `/queue` processed
        // and the listing would be empty. (End-of-input teardown may still
        // drain the queue afterwards, so final-state asserts like
        // `turnPrompts` cannot pin this — only the mid-turn probe can.)
        #expect(await harness.queueListings.contains(["steer me"]))
    }

    @Test("enter-steers outside an orchestration wait keeps its cancel-and-send role")
    func steerWithoutOrchestrationWaitPreempts() async throws {
        let harness = try await SwarmCommandHarness.runSteering(
            orchestrationActive: false
        )
        #expect(await harness.turnPrompts == ["long swarm turn", "steer me"],
                "the steered draft must run immediately after the preempted turn")
        // The replacement turn completes immediately, so shutdown may beat
        // the optional `/queue` overlay. Its ordered start and the explicit
        // send-now notice prove cancellation and dispatch without that race.
        #expect(await harness.notices.contains("sending the queued prompt now"))
    }
}

// MARK: - Harness

private actor SwarmCommandHarness {
    private let renderer: SwarmRecordingRenderer
    let result: OpenGrokPagerInteractiveResult

    private init(
        renderer: SwarmRecordingRenderer,
        result: OpenGrokPagerInteractiveResult
    ) {
        self.renderer = renderer
        self.result = result
    }

    var events: [OpenGrokPagerInteractiveEvent] {
        get async { await renderer.allEvents }
    }
    var overlayRequests: [OpenGrokPagerOverlayRequest] {
        get async { await renderer.overlayRequests }
    }
    var notices: [String] { get async { await renderer.notices } }
    var turnPrompts: [String] { get async { await renderer.turnPrompts } }
    var queueListings: [[String]] { get async { await renderer.queueListings } }

    /// Type a line, close the dropdown, and press Enter — the same typed-
    /// path discipline as the plan-command harness.
    static func run(
        submitting lines: [String],
        swarmModeActive: Bool? = nil
    ) async throws -> SwarmCommandHarness {
        var events: [InputEvent] = []
        for line in lines {
            events.append(.paste(line))
            events.append(.key(KeyEvent(key: .escape)))
            events.append(.key(KeyEvent(key: .enter)))
        }
        let renderer = SwarmRecordingRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: AsyncStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            },
            runtime: SwarmCompletingRuntime(),
            renderer: renderer,
            output: SwarmSilentOutput()
        )
        if let swarmModeActive {
            await controller.setSwarmModeStateProvider { swarmModeActive }
        }
        let result = try await controller.run(.init(prompt: "", mode: .inline))
        return SwarmCommandHarness(renderer: renderer, result: result)
    }

    /// A running turn (parked session), `enter_steers` on, and a steering
    /// draft submitted mid-turn. The turn starts at `run` entry (the
    /// initial-session form the live composition uses for a non-empty
    /// launch prompt), so the steering events can only be consumed by the
    /// running-turn input path. An explicit Ctrl+D after the queue snapshot
    /// tears down the parked turn; natural input exhaustion deliberately
    /// preserves queued prompts and cannot finish an indefinitely held turn.
    static func runSteering(orchestrationActive: Bool) async throws -> SwarmCommandHarness {
        let events: [InputEvent] = [
            // NO Escape after the steer text: plain text opens no dropdown,
            // and a bare Esc mid-turn is the INTERRUPT — it cancels the
            // running turn (`handleInterrupt`, dropdown-close first, then
            // `.cancelTurn`), which is exactly the preemption these tests
            // must observe NOT happening.
            .paste("steer me"),
            .key(KeyEvent(key: .enter)),
            // The mid-turn probe: `/queue` is UI-only, so it runs
            // immediately while the (parked or restarted) turn holds the
            // wheel, snapshotting the queue BEFORE end-of-input teardown
            // can drain it. Its Esc is safe: the slash dropdown is open,
            // and the dropdown intercepts Esc ahead of the cancel ladder.
            .paste("/queue"),
            .key(KeyEvent(key: .escape)),
            .key(KeyEvent(key: .enter)),
            .key(KeyEvent(key: .char("d"), modifiers: [.control], character: "d")),
        ]
        let renderer = SwarmRecordingRenderer()
        let runtime = SwarmParkedRuntime()
        let controller = OpenGrokPagerInteractiveController(
            input: AsyncStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            },
            runtime: runtime,
            renderer: renderer,
            output: SwarmSilentOutput()
        )
        await controller.setInputModes(OpenGrokPagerInputModes(enterSteers: true))
        await controller.setOrchestrationWaitStateProvider { orchestrationActive }
        let request = OpenGrokPagerRequest(prompt: "long swarm turn", mode: .inline)
        let initialSession = try await runtime.makeSession(for: request)
        let result = try await controller.run(
            initialSession: initialSession,
            request: request
        )
        return SwarmCommandHarness(renderer: renderer, result: result)
    }
}

private actor SwarmRecordingRenderer: OpenGrokPagerInteractiveRenderAdapter {
    private var events: [OpenGrokPagerInteractiveEvent] = []

    func begin() {}
    func restoreTerminal() {}

    func render(_ event: OpenGrokPagerInteractiveEvent) {
        events.append(event)
    }

    var allEvents: [OpenGrokPagerInteractiveEvent] { events }

    var overlayRequests: [OpenGrokPagerOverlayRequest] {
        events.compactMap { if case .overlay(let request) = $0 { return request } else { return nil } }
    }

    var notices: [String] {
        events.compactMap { if case .notice(let message) = $0 { return message } else { return nil } }
    }

    var turnPrompts: [String] {
        events.compactMap { if case .turnStarted(let request) = $0 { return request.prompt } else { return nil } }
    }

    var queueListings: [[String]] {
        events.compactMap {
            if case .overlay(.promptQueue(let entries)) = $0 { return entries } else { return nil }
        }
    }
}

/// Sessions complete immediately — the dispatch-shape tests need
/// `.turnStarted` to be emitted for the one-shot task arm.
private struct SwarmCompletingRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        _ = request
        return SwarmCompletingSession()
    }
}

private struct SwarmCompletingSession: OpenGrokPagerSessionAdapter {
    var sessionID: String? { "swarm-turn" }
    var events: AsyncThrowingStream<OpenGrokPagerEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.completed(OpenGrokPagerMinimalCompletion()))
            continuation.finish()
        }
    }
    func cancel() async {}
    func close() async {}
}

/// The FIRST session parks (a swarm-length turn); later sessions (the
/// steered draft after a preempt) complete immediately.
private actor SwarmParkedRuntimeState {
    var madeSessions = 0

    func noteSession() -> Int {
        madeSessions += 1
        return madeSessions
    }
}

private struct SwarmParkedRuntime: OpenGrokPagerRuntimeAdapter {
    private let state = SwarmParkedRuntimeState()

    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        _ = request
        let index = await state.noteSession()
        if index == 1 {
            return SwarmParkedSession()
        }
        return SwarmCompletingSession()
    }
}

/// A session whose event stream never terminates on its own: it ends only
/// when `cancel()` is called, exactly like a turn parked in a long
/// orchestration wait.
private struct SwarmParkedSession: OpenGrokPagerSessionAdapter {
    private let continuationBox = SwarmContinuationBox()

    var sessionID: String? { "parked-swarm-turn" }
    var events: AsyncThrowingStream<OpenGrokPagerEvent, Error> {
        AsyncThrowingStream { continuation in
            continuationBox.store(continuation)
        }
    }

    func cancel() async {
        continuationBox.finishCancelled()
    }

    func close() async {
        continuationBox.finishCancelled()
    }
}

private final class SwarmContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<OpenGrokPagerEvent, Error>.Continuation?

    func store(_ continuation: AsyncThrowingStream<OpenGrokPagerEvent, Error>.Continuation) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
    }

    func finishCancelled() {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.yield(.cancelled)
        pending?.finish()
    }
}

private struct SwarmSilentOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}
