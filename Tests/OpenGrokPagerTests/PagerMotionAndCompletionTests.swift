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

    private func wait(
        timeoutNanos: UInt64,
        for check: @escaping @Sendable ([OpenGrokPagerAnimationFrame]) -> Bool
    ) async -> Bool {
        if check(frames) { return true }
        let timeout = Task {
            try? await Task.sleep(nanoseconds: timeoutNanos)
            await self.expireWaiters()
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

private struct SilentMotionOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
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
