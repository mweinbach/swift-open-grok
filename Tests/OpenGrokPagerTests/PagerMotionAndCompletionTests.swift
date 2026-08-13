// PagerMotionAndCompletionTests.swift
//
// The animation ticker and the slash-suggestion engine, asserted through the
// controller's live seam: real input events in, recorded render calls out.
// Per AGENTS.md §3 nothing here inspects controller internals — what the
// renderer was actually handed is the only evidence accepted.

import Foundation
import OpenGrokPager
import OpenGrokPagerCommandUI
import OpenGrokPagerRender
import OpenGrokTerminalCore
import Testing

@Suite("Wall-clock animation ticker")
struct PagerMotionTickerTests {
    @Test("with motion demand and no input events, ticks arrive and the spinner advances")
    func fastDemandTicksWithoutEvents() async throws {
        let renderer = MotionRecordingRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: openStream([]),
            runtime: InertRuntime(),
            renderer: renderer,
            output: SilentMotionOutput()
        )
        // Fast demand raised before the run: a background-task chip is
        // spinning. No input event will ever arrive on the stream.
        await controller.setMotionState(PagerMotionState(hasBackgroundTasks: true))

        let task = Task { try await controller.run(.init(prompt: "", mode: .inline)) }
        // Wait for the wall tick to span at least two spinner frames
        // (2 × SPINNER_DIVISOR ticks). The timeout only bounds a broken
        // ticker; a healthy one at 30 fps crosses tick 8 in ~270 ms.
        let reached = await renderer.waitForTickSpan(atLeast: 8, timeoutNanos: 10_000_000_000)
        await controller.shutdown()
        _ = try await task.value

        #expect(reached)
        let frames = await renderer.frames
        #expect(frames.count >= 2)
        #expect((frames.last?.tick ?? 0) > (frames.first?.tick ?? 0))
        // The spinner frame is a pure function of the tick; spanning eight
        // ticks must produce at least two distinct glyphs.
        #expect(Set(frames.map { PagerMotion.brailleFrame(tick: $0.tick) }).count >= 2)
        #expect(frames.allSatisfy { $0.demand == .fast })
        // Seconds ride the same clock as the tick, for shimmer and flash.
        #expect((frames.last?.seconds ?? 0) > 0)
    }

    @Test("slow demand ticks at the shimmer cadence, not the full frame rate")
    func slowDemandUsesSlowCadence() async throws {
        let renderer = MotionRecordingRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: openStream([]),
            runtime: InertRuntime(),
            renderer: renderer,
            output: SilentMotionOutput()
        )
        await controller.setMotionState(PagerMotionState(showsWelcomeLogo: true))

        let task = Task { try await controller.run(.init(prompt: "", mode: .inline)) }
        let reached = await renderer.waitForFrameCount(atLeast: 2, timeoutNanos: 10_000_000_000)
        await controller.shutdown()
        _ = try await task.value

        #expect(reached)
        let frames = await renderer.frames
        #expect(frames.allSatisfy { $0.demand == .slow })
    }

    @Test("no demand means no ticks — an idle screen costs no wakeups")
    func idleDemandNeverTicks() async throws {
        let renderer = MotionRecordingRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: openStream([]),
            runtime: InertRuntime(),
            renderer: renderer,
            output: SilentMotionOutput()
        )
        // No motion state, no running turn: demand stays `.none`.
        let task = Task { try await controller.run(.init(prompt: "", mode: .inline)) }
        try await Task.sleep(nanoseconds: 250_000_000)
        await controller.shutdown()
        _ = try await task.value

        #expect(await renderer.frames.isEmpty)
    }

    @Test("non-default setMotionFPS changes ticker cadence before run")
    func configuredFPSChangesCadence() async throws {
        // Through the controller seam only: lower fps must advance the
        // derived tick counter more slowly for the same wall seconds
        // (`makeAnimationFrame` divides by tickInterval(fps)).
        func lastTick(fps: Int, afterSeconds: Double) async throws -> (tick: Int, seconds: Double) {
            let renderer = MotionRecordingRenderer()
            let controller = OpenGrokPagerInteractiveController(
                input: openStream([]),
                runtime: InertRuntime(),
                renderer: renderer,
                output: SilentMotionOutput()
            )
            await controller.setMotionFPS(fps)
            await controller.setMotionState(PagerMotionState(hasBackgroundTasks: true))
            let task = Task { try await controller.run(.init(prompt: "", mode: .inline)) }
            let reached = await renderer.waitForSeconds(
                atLeast: afterSeconds,
                timeoutNanos: 10_000_000_000
            )
            #expect(reached)
            let frame = await renderer.frames.last
            await controller.shutdown()
            _ = try await task.value
            return (frame?.tick ?? -1, frame?.seconds ?? -1)
        }

        let slow = try await lastTick(fps: 10, afterSeconds: 0.35)
        let fast = try await lastTick(fps: 60, afterSeconds: 0.35)
        #expect(slow.seconds >= 0.35)
        #expect(fast.seconds >= 0.35)
        // At equal wall time, 60 fps must report a higher tick than 10 fps.
        #expect(fast.tick > slow.tick)
        // And the slow cadence must stay near seconds*fps (not the default 30).
        #expect(slow.tick <= Int(slow.seconds * 10) + 2)
        #expect(fast.tick >= Int(fast.seconds * 40))
    }

    @Test("suspend holds the ticker; setMotionState while held cannot re-arm; resume continues the clock")
    func suspendHoldsAndResumeContinues() async throws {
        let renderer = MotionRecordingRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: openStream([]),
            runtime: InertRuntime(),
            renderer: renderer,
            output: SilentMotionOutput()
        )
        await controller.setMotionState(PagerMotionState(hasBackgroundTasks: true))

        let task = Task { try await controller.run(.init(prompt: "", mode: .inline)) }
        let armed = await renderer.waitForFrameCount(atLeast: 2, timeoutNanos: 10_000_000_000)
        #expect(armed)

        // Bound well above two fast intervals (~33 ms) so a cancelled sleep
        // cannot be mistaken for a scheduled tick that merely overlapped the
        // suspend call — count stability is the assertion, not wall-clock
        // equality with the scheduler.
        let holdNanos: UInt64 = 250_000_000
        await controller.suspendMotionTicker()
        // Idempotent second suspend must not hang or re-arm.
        await controller.suspendMotionTicker()
        let countAtSuspend = await renderer.frames.count
        let lastAtSuspend = await renderer.frames.last
        try await Task.sleep(nanoseconds: holdNanos)
        #expect(await renderer.frames.count == countAtSuspend)

        // Rising demand during the hold must stay dark until resume.
        await controller.setMotionState(PagerMotionState(hasBackgroundTasks: true))
        try await Task.sleep(nanoseconds: holdNanos)
        #expect(await renderer.frames.count == countAtSuspend)

        await controller.resumeMotionTicker()
        // Idempotent resume — second call re-arms only if demand still holds.
        await controller.resumeMotionTicker()
        let resumed = await renderer.waitForFrameCount(
            atLeast: countAtSuspend + 2,
            timeoutNanos: 10_000_000_000
        )
        #expect(resumed)

        let frames = await renderer.frames
        let afterResume = Array(frames.dropFirst(countAtSuspend))
        #expect(afterResume.count >= 2)
        if let lastAtSuspend, let firstResumed = afterResume.first {
            // Epoch preserved: wall seconds/tick keep advancing past the hold.
            #expect(firstResumed.seconds >= lastAtSuspend.seconds)
            #expect(firstResumed.tick >= lastAtSuspend.tick)
        }
        if let first = afterResume.first, let last = afterResume.last {
            #expect(last.seconds > first.seconds)
            #expect(last.tick > first.tick)
        }

        await controller.shutdown()
        _ = try await task.value
    }

    @Test("idle suspend and resume never produce ticks")
    func idleSuspendResumeNeverTicks() async throws {
        let renderer = MotionRecordingRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: openStream([]),
            runtime: InertRuntime(),
            renderer: renderer,
            output: SilentMotionOutput()
        )
        let task = Task { try await controller.run(.init(prompt: "", mode: .inline)) }
        await controller.suspendMotionTicker()
        try await Task.sleep(nanoseconds: 250_000_000)
        await controller.resumeMotionTicker()
        try await Task.sleep(nanoseconds: 250_000_000)
        await controller.shutdown()
        _ = try await task.value

        #expect(await renderer.frames.isEmpty)
    }

    @Test("shutdown latch blocks resume re-arm while teardown still owns running")
    func shutdownLatchBlocksResumeDuringTeardown() async throws {
        // Deterministic seam: gate `restoreTerminal` so teardown has set
        // `motionShutdownLatched` while `running` is still true. A suspended
        // child's late `resumeMotionTicker` must not re-arm into restore.
        let gate = RestoreGate()
        let renderer = GatedRestoreMotionRenderer(gate: gate)
        let controller = OpenGrokPagerInteractiveController(
            input: openStream([]),
            runtime: InertRuntime(),
            renderer: renderer,
            output: SilentMotionOutput()
        )
        await controller.setMotionState(PagerMotionState(hasBackgroundTasks: true))

        let runTask = Task { try await controller.run(.init(prompt: "", mode: .inline)) }
        let armed = await renderer.waitForFrameCount(atLeast: 2, timeoutNanos: 10_000_000_000)
        #expect(armed)

        await controller.suspendMotionTicker()
        let countAtSuspend = await renderer.frames.count

        let shutdownTask = Task { await controller.shutdown() }
        await gate.waitUntilRestoreEntered()

        // Suspended-child cleanup racing teardown — must stay dark.
        await controller.resumeMotionTicker()
        await controller.resumeMotionTicker()
        await controller.setMotionState(PagerMotionState(hasBackgroundTasks: true))
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(await renderer.frames.count == countAtSuspend)

        await gate.allowRestore()
        _ = try await runTask.value
        await shutdownTask.value
        #expect(await renderer.frames.count == countAtSuspend)
    }
}

@Suite("Renderer focusScrollback routing")
struct PagerFocusScrollbackRoutingTests {
    @Test("renderer focusScrollback moves controller focus and emits focusChanged")
    func focusScrollbackRoutesThroughPump() async throws {
        let renderer = FocusRoutingRenderer(routing: .focusScrollback)
        let controller = OpenGrokPagerInteractiveController(
            input: closedStream([
                .key(KeyEvent(key: .char("x"), character: "x")),
            ]),
            runtime: InertRuntime(),
            renderer: renderer,
            output: SilentMotionOutput()
        )

        _ = try await controller.run(.init(prompt: "", mode: .inline))

        #expect(await renderer.focusChanges == [.scrollback])
        #expect(await controller.state().focus == .scrollback)
        // The typed key must not reach the composer — the routing claim
        // resumed the pump after focus moved, without falling through.
        #expect(await renderer.promptTexts.allSatisfy { $0.isEmpty || $0 == "" })
    }

    @Test("focusScrollback is idempotent when already on the scrollback")
    func focusScrollbackWhenAlreadyFocused() async throws {
        let renderer = FocusRoutingRenderer(routing: .focusScrollback)
        let controller = OpenGrokPagerInteractiveController(
            input: closedStream([
                .key(KeyEvent(key: .char("a"), character: "a")),
                .key(KeyEvent(key: .char("b"), character: "b")),
            ]),
            runtime: InertRuntime(),
            renderer: renderer,
            output: SilentMotionOutput()
        )

        _ = try await controller.run(.init(prompt: "", mode: .inline))

        // First routing claim emits focusChanged; the second no-ops setFocus
        // because focus is already on the scrollback.
        #expect(await renderer.focusChanges == [.scrollback])
        #expect(await controller.state().focus == .scrollback)
    }

    @Test("focusScrollback setFocus failure propagates through the input pump")
    func focusScrollbackSetFocusFailurePropagates() async throws {
        // A silent `try?` would swallow this and leave the run green with
        // composer focus — the pump must surface emit failures as inputFailed.
        let renderer = FocusRoutingRenderer(routing: .focusScrollback)
        let controller = OpenGrokPagerInteractiveController(
            input: closedStream([
                .key(KeyEvent(key: .char("x"), character: "x")),
            ]),
            runtime: InertRuntime(),
            renderer: renderer,
            output: FocusFailingOutput()
        )

        do {
            _ = try await controller.run(.init(prompt: "", mode: .inline))
            Issue.record("expected setFocus failure to fail the run")
        } catch let error as OpenGrokPagerInteractiveError {
            guard case .inputFailed(let message) = error else {
                Issue.record("expected inputFailed, got \(error)")
                return
            }
            #expect(message.contains("focus-emit-failed"))
        }
    }

    @Test("throwing renderer handleInput fails the run as inputFailed")
    func handleInputFailurePropagatesThroughPump() async throws {
        // A wrapping `try?` would swallow restore/terminal errors from
        // handleInput, leave motion holds latched, and keep the run green.
        let renderer = ThrowingHandleInputRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: closedStream([
                .key(KeyEvent(key: .char("x"), character: "x")),
            ]),
            runtime: InertRuntime(),
            renderer: renderer,
            output: SilentMotionOutput()
        )

        do {
            _ = try await controller.run(.init(prompt: "", mode: .inline))
            Issue.record("expected handleInput failure to fail the run")
        } catch let error as OpenGrokPagerInteractiveError {
            guard case .inputFailed(let message) = error else {
                Issue.record("expected inputFailed, got \(error)")
                return
            }
            #expect(message.contains("handle-input-failed"))
        }
    }
}

@Suite("Slash suggestion engine at the controller seam")
struct PagerCompletionEngineTests {
    @Test("a bare slash lists the curated order uncapped, and paging clamps at the ends")
    func bareSlashUncappedAndPaged() async throws {
        let renderer = MotionRecordingRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: closedStream([
                .key(KeyEvent(key: .char("/"), character: "/")),
                .key(KeyEvent(key: .pageDown)),
                .key(KeyEvent(key: .pageDown)),
                .key(KeyEvent(key: .pageUp)),
                .key(KeyEvent(key: .pageUp)),
                .key(KeyEvent(key: .pageUp)),
            ]),
            runtime: InertRuntime(),
            renderer: renderer,
            output: SilentMotionOutput()
        )
        _ = try await controller.run(.init(prompt: "", mode: .inline))

        let states = await renderer.promptStates.filter { !$0.completions.isEmpty }
        guard let opened = states.first else {
            Issue.record("the dropdown never opened")
            return
        }
        // Uncapped: the whole registry rides through, not six rows.
        #expect(opened.completions.count > PagerLayoutMetrics.maxDropdownRows)
        // Curated: registration order leads with /quit, and /theme — buried
        // by the alphabetical prefix(6) before — is reachable.
        #expect(opened.completions.first?.name == "/quit")
        #expect(opened.completions.contains { $0.name == "/theme" })
        // Paging: +6, +6, then three -6 presses clamping at zero
        // (`slash_scroll_selection` clamps, `prompt_widget/mod.rs:1185-1190`).
        #expect(states.map(\.selectedCompletion) == [0, 6, 12, 6, 0, 0])
    }

    @Test("Esc closes the dropdown without arming the clear ladder; typing reopens it")
    func escClosesDropdown() async throws {
        let renderer = MotionRecordingRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: closedStream([
                .key(KeyEvent(key: .char("/"), character: "/")),
                .key(KeyEvent(key: .escape)),
                .key(KeyEvent(key: .char("q"), character: "q")),
            ]),
            runtime: InertRuntime(),
            renderer: renderer,
            output: SilentMotionOutput()
        )
        _ = try await controller.run(.init(prompt: "", mode: .inline))

        let states = await renderer.promptStates
        guard let openedIndex = states.firstIndex(where: { !$0.completions.isEmpty }) else {
            Issue.record("the dropdown never opened")
            return
        }
        // Esc closed the menu, kept the draft, and did not arm "clear" —
        // the dropdown intercept runs ahead of the esc ladder
        // (`prompt.rs:229-233`).
        guard let closed = states[(openedIndex + 1)...].first(where: { $0.completions.isEmpty })
        else {
            Issue.record("Esc never closed the dropdown")
            return
        }
        #expect(closed.text == "/")
        #expect(closed.pendingConfirmationKey == nil)
        // Typing lifts the dismissal: `/q` reopens with the fuzzy matches.
        let reopened = states.last
        #expect(reopened?.text == "/q")
        #expect(reopened?.completions.isEmpty == false)
    }

    @Test("theme names complete for /theme and accept as the full composer text")
    func themeArgumentSuggestions() async throws {
        let renderer = MotionRecordingRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: closedStream([
                .paste("/theme "),
                .paste("tok"),
                .key(KeyEvent(key: .tab)),
            ]),
            runtime: InertRuntime(),
            renderer: renderer,
            output: SilentMotionOutput()
        )
        _ = try await controller.run(.init(prompt: "", mode: .inline))

        let states = await renderer.promptStates
        // The bare argument phase offers the whole catalog: auto first, then
        // the selectable themes in catalog order (`theme.rs:81-110`).
        let catalog = states.first { $0.text == "/theme " && !$0.completions.isEmpty }
        #expect(catalog?.completions.first?.name == "auto")
        #expect(catalog?.completions.contains { $0.name == "Tokyo Night" } == true)
        // The typed fragment ranks Tokyo Night first, and accepting leaves
        // the whole composer text behind, not the bare argument.
        let filtered = states.first { $0.text == "/theme tok" && !$0.completions.isEmpty }
        #expect(filtered?.completions.first?.name == "Tokyo Night")
        #expect(states.last?.text == "/theme Tokyo Night")
    }

    @Test("accepting a command records MRU and boosts it over an equal-score tie")
    func mruReordersAfterAccept() async throws {
        let renderer = MotionRecordingRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: closedStream([
                // `/q` ties /queue and /quit; display order puts /queue first.
                .paste("/q"),
                .key(KeyEvent(key: .down)),
                .key(KeyEvent(key: .tab)),
                // Clear the accepted draft, then retype the same query.
                .key(KeyEvent(key: .char("c"), modifiers: [.control], character: "c")),
                .paste("/q"),
            ]),
            runtime: InertRuntime(),
            renderer: renderer,
            output: SilentMotionOutput()
        )
        _ = try await controller.run(.init(prompt: "", mode: .inline))

        let states = await renderer.promptStates.filter {
            $0.text == "/q" && !$0.completions.isEmpty
        }
        // Cold: display order (`slash/mod.rs:1003`).
        #expect(states.first?.completions.map(\.name).prefix(2) == ["/queue", "/quit"])
        // After accepting /quit, its recency outranks the tie
        // (`slash/mod.rs:996-1002`; recorded at accept,
        // `prompt_widget/mod.rs:1206-1211`).
        #expect(states.last?.completions.map(\.name).prefix(2) == ["/quit", "/queue"])
    }
}

// MARK: - Harness

/// Gates `restoreTerminal` so tests can observe teardown after the shutdown
/// motion latch and before `running` flips false.
private actor RestoreGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var allowed = false
    private var allowWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilRestoreEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func noteRestoreEntered() async {
        entered = true
        let waiting = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiting { waiter.resume() }
        if allowed { return }
        await withCheckedContinuation { continuation in
            allowWaiters.append(continuation)
        }
    }

    func allowRestore() {
        allowed = true
        let waiting = allowWaiters
        allowWaiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }
}

private actor GatedRestoreMotionRenderer: OpenGrokPagerInteractiveRenderAdapter {
    private struct Waiter {
        let id: UUID
        let check: @Sendable ([OpenGrokPagerAnimationFrame]) -> Bool
        let continuation: CheckedContinuation<Void, Never>
    }

    private let gate: RestoreGate
    private(set) var frames: [OpenGrokPagerAnimationFrame] = []
    private var waiters: [Waiter] = []

    init(gate: RestoreGate) {
        self.gate = gate
    }

    func begin() {}
    func restoreTerminal() async {
        await gate.noteRestoreEntered()
    }

    func render(_ event: OpenGrokPagerInteractiveEvent) {
        _ = event
    }

    func renderAnimationTick(_ frame: OpenGrokPagerAnimationFrame) {
        frames.append(frame)
        let readyIDs = Set(waiters.filter { $0.check(frames) }.map(\.id))
        guard !readyIDs.isEmpty else { return }
        let ready = waiters.filter { readyIDs.contains($0.id) }
        waiters.removeAll { readyIDs.contains($0.id) }
        for waiter in ready { waiter.continuation.resume() }
    }

    func waitForFrameCount(atLeast count: Int, timeoutNanos: UInt64) async -> Bool {
        await wait(timeoutNanos: timeoutNanos) { $0.count >= count }
    }

    private func wait(
        timeoutNanos: UInt64,
        for check: @escaping @Sendable ([OpenGrokPagerAnimationFrame]) -> Bool
    ) async -> Bool {
        if check(frames) { return true }
        let timeout = Task {
            try? await Task.sleep(nanoseconds: timeoutNanos)
            self.expireWaiters()
        }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(id: UUID(), check: check, continuation: continuation))
        }
        timeout.cancel()
        return check(frames)
    }

    private func expireWaiters() {
        let expired = waiters
        waiters.removeAll()
        for waiter in expired { waiter.continuation.resume() }
    }
}

private actor MotionRecordingRenderer: OpenGrokPagerInteractiveRenderAdapter {
    private struct Waiter {
        let id: UUID
        let check: @Sendable ([OpenGrokPagerAnimationFrame]) -> Bool
        let continuation: CheckedContinuation<Void, Never>
    }

    private(set) var frames: [OpenGrokPagerAnimationFrame] = []
    private var events: [OpenGrokPagerInteractiveEvent] = []
    private var waiters: [Waiter] = []

    func begin() {}
    func restoreTerminal() {}

    func render(_ event: OpenGrokPagerInteractiveEvent) {
        events.append(event)
    }

    func renderAnimationTick(_ frame: OpenGrokPagerAnimationFrame) {
        frames.append(frame)
        let readyIDs = Set(waiters.filter { $0.check(frames) }.map(\.id))
        guard !readyIDs.isEmpty else { return }
        let ready = waiters.filter { readyIDs.contains($0.id) }
        waiters.removeAll { readyIDs.contains($0.id) }
        for waiter in ready { waiter.continuation.resume() }
    }

    var promptStates: [OpenGrokPagerInteractivePromptState] {
        events.compactMap {
            if case .promptChanged(let state) = $0 { return state }
            return nil
        }
    }

    /// Wait until the recorded ticks span at least `span`, or the timeout
    /// elapses. Returns whether the span was reached — the timeout exists to
    /// bound a broken ticker, not to be the assertion.
    func waitForTickSpan(atLeast span: Int, timeoutNanos: UInt64) async -> Bool {
        await wait(timeoutNanos: timeoutNanos) { frames in
            guard let first = frames.first, let last = frames.last else { return false }
            return last.tick - first.tick >= span
        }
    }

    func waitForFrameCount(atLeast count: Int, timeoutNanos: UInt64) async -> Bool {
        await wait(timeoutNanos: timeoutNanos) { $0.count >= count }
    }

    func waitForSeconds(atLeast seconds: Double, timeoutNanos: UInt64) async -> Bool {
        await wait(timeoutNanos: timeoutNanos) { frames in
            (frames.last?.seconds ?? 0) >= seconds
        }
    }

    private func wait(
        timeoutNanos: UInt64,
        for check: @escaping @Sendable ([OpenGrokPagerAnimationFrame]) -> Bool
    ) async -> Bool {
        if check(frames) { return true }
        let timeout = Task {
            try? await Task.sleep(nanoseconds: timeoutNanos)
            self.expireWaiters()
        }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(id: UUID(), check: check, continuation: continuation))
        }
        timeout.cancel()
        return check(frames)
    }

    private func expireWaiters() {
        let expired = waiters
        waiters.removeAll()
        for waiter in expired { waiter.continuation.resume() }
    }
}

/// Returns a fixed routing once per input event so the controller pump's
/// `focusScrollback` arm can be asserted through the live seam.
private actor FocusRoutingRenderer: OpenGrokPagerInteractiveRenderAdapter {
    private let routing: OpenGrokPagerInputRouting
    private var events: [OpenGrokPagerInteractiveEvent] = []

    init(routing: OpenGrokPagerInputRouting) {
        self.routing = routing
    }

    func begin() {}
    func restoreTerminal() {}

    func render(_ event: OpenGrokPagerInteractiveEvent) {
        events.append(event)
    }

    func handleInput(_ event: InputEvent) -> OpenGrokPagerInputRouting {
        _ = event
        return routing
    }

    var focusChanges: [OpenGrokPagerFocusRegion] {
        events.compactMap {
            if case .focusChanged(let region) = $0 { return region }
            return nil
        }
    }

    var promptTexts: [String] {
        events.compactMap {
            if case .promptChanged(let state) = $0 { return state.text }
            return nil
        }
    }
}

/// Throws from `handleInput` so the pump cannot hide restore/terminal
/// failures behind `try?` and continue with latched motion holds.
private actor ThrowingHandleInputRenderer: OpenGrokPagerInteractiveRenderAdapter {
    func begin() {}
    func restoreTerminal() {}
    func render(_ event: OpenGrokPagerInteractiveEvent) { _ = event }

    func handleInput(_ event: InputEvent) throws -> OpenGrokPagerInputRouting {
        _ = event
        throw HandleInputFailure()
    }
}

private struct HandleInputFailure: Error, CustomStringConvertible {
    var description: String { "handle-input-failed" }
}

private struct SilentMotionOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}

/// Fails the first `.focusChanged` emit so the pump's focusScrollback arm
/// cannot hide a setFocus error behind `try?`.
private struct FocusFailingOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws {
        if case .focusChanged = event {
            throw FocusEmitFailure()
        }
    }
}

private struct FocusEmitFailure: Error, CustomStringConvertible {
    var description: String { "focus-emit-failed" }
}

/// A runtime these tests must never reach: nothing here submits a prompt.
private actor InertRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        _ = request
        throw OpenGrokPagerInteractiveError.sessionFailed("test runtime has no sessions")
    }

    func replaceSession(from request: OpenGrokPagerRequest) async throws -> String {
        _ = request
        throw OpenGrokPagerInteractiveError.sessionFailed("test runtime has no sessions")
    }
}

/// Yields `events` and then stays open, so only an explicit shutdown ends the
/// run.
private func openStream(_ events: [InputEvent]) -> AsyncStream<InputEvent> {
    AsyncStream { continuation in
        for event in events { continuation.yield(event) }
    }
}

private func closedStream(_ events: [InputEvent]) -> AsyncStream<InputEvent> {
    AsyncStream { continuation in
        for event in events { continuation.yield(event) }
        continuation.finish()
    }
}
