// PagerScrollClockTests.swift
//
// Dedicated mouse-scroll clock on the interactive controller, asserted
// through the live seam: mouse input in, `scrollClockDeadline` /
// `handleScrollClockTick` out. Motion demand stays `.none` — scroll must
// not piggyback the animation ticker. Per AGENTS.md §3 nothing here
// inspects controller internals.
//
// Input is always an open `AsyncStream` continuation held until assertions
// finish. Prefilling a builder-closure stream finishes it when the closure
// returns, which EOF-tears down the run and cancels the scroll ticker
// before the first wake. Each subsequent yield waits on an explicit
// handleInput / deadline-query latch — not scheduler timing.

import Foundation
import OpenGrokPager
import OpenGrokTerminalCore
import Testing

@Suite("Dedicated mouse scroll clock")
struct PagerScrollClockTests {
    @Test("scroll event arms scroll ticker while motion demand is none")
    func scrollArmsWithoutMotion() async throws {
        let renderer = ScrollClockFakeRenderer(armDelay: 0.03, ticksUntilDisarm: 1)
        let (stream, continuation) = AsyncStream<InputEvent>.makeStream()
        let controller = OpenGrokPagerInteractiveController(
            input: stream,
            runtime: ScrollClockInertRuntime(),
            renderer: renderer,
            output: ScrollClockSilentOutput()
        )

        let task = Task { try await controller.run(.init(prompt: "", mode: .inline)) }
        await yieldScroll(
            .mouse(MouseEvent(kind: .scrollDown, x: 1, y: 1)),
            on: continuation,
            renderer: renderer,
            handleInputAtLeast: 1,
            deadlineQueryAtLeast: 1
        )
        // No motion state was raised — the animation ticker must stay dark.
        #expect(await renderer.animationFrames.isEmpty)

        let ticked = await renderer.waitForTickCount(atLeast: 1, timeoutNanos: 5_000_000_000)
        #expect(ticked)
        #expect(await renderer.animationFrames.isEmpty)

        continuation.finish()
        await controller.shutdown()
        _ = try await task.value
        await renderer.awaitCleanup()
    }

    @Test("tick calls renderer and disarms when deadline becomes nil")
    func tickCallsRendererThenDisarms() async throws {
        let renderer = ScrollClockFakeRenderer(armDelay: 0.02, ticksUntilDisarm: 1)
        let (stream, continuation) = AsyncStream<InputEvent>.makeStream()
        let controller = OpenGrokPagerInteractiveController(
            input: stream,
            runtime: ScrollClockInertRuntime(),
            renderer: renderer,
            output: ScrollClockSilentOutput()
        )

        let task = Task { try await controller.run(.init(prompt: "", mode: .inline)) }
        await yieldScroll(
            .mouse(MouseEvent(kind: .scrollUp, x: 0, y: 0)),
            on: continuation,
            renderer: renderer,
            handleInputAtLeast: 1,
            deadlineQueryAtLeast: 1
        )

        let ticked = await renderer.waitForTickCount(atLeast: 1, timeoutNanos: 5_000_000_000)
        #expect(ticked)
        #expect(await renderer.tickCount == 1)

        // Post-tick re-query returns nil and disarms — wait on that latch
        // rather than a wall-clock "no further ticks" guess.
        let disarmed = await renderer.waitForPostTickDisarm(timeoutNanos: 5_000_000_000)
        #expect(disarmed)
        #expect(await renderer.tickCount == 1)
        #expect(await renderer.deadlineAfterLastTickWasNil)

        continuation.finish()
        await controller.shutdown()
        _ = try await task.value
        await renderer.awaitCleanup()
    }

    @Test("suspend freezes the scroll ticker; resume re-arms a pending deadline")
    func suspendFreezesAndResumeRearms() async throws {
        // Long delay so suspend wins the race against the first wake.
        let renderer = ScrollClockFakeRenderer(armDelay: 10.0, ticksUntilDisarm: 1)
        let (stream, continuation) = AsyncStream<InputEvent>.makeStream()
        let controller = OpenGrokPagerInteractiveController(
            input: stream,
            runtime: ScrollClockInertRuntime(),
            renderer: renderer,
            output: ScrollClockSilentOutput()
        )

        let task = Task { try await controller.run(.init(prompt: "", mode: .inline)) }
        await yieldScroll(
            .mouse(MouseEvent(kind: .scrollDown, x: 2, y: 2)),
            on: continuation,
            renderer: renderer,
            handleInputAtLeast: 1,
            deadlineQueryAtLeast: 1
        )

        await controller.suspendMotionTicker()
        await controller.suspendMotionTicker()
        let ticksAtSuspend = await renderer.tickCount
        #expect(ticksAtSuspend == 0)

        let queriesAtSuspend = await renderer.deadlineQueryCount
        // Suspended: no tick, and no further deadline re-arm queries.
        let stayedDark = await renderer.waitForTickCount(atLeast: ticksAtSuspend + 1, timeoutNanos: 200_000_000)
        #expect(!stayedDark)
        #expect(await renderer.tickCount == ticksAtSuspend)
        #expect(await renderer.deadlineQueryCount == queriesAtSuspend)

        // Keep a pending relative deadline across the hold — resume must
        // re-query and re-arm without needing another mouse event.
        await renderer.setArmDelay(0.02)
        await controller.resumeMotionTicker()
        await controller.resumeMotionTicker()

        let resumeQuery = await renderer.waitForDeadlineQueryCount(
            atLeast: queriesAtSuspend + 1,
            timeoutNanos: 5_000_000_000
        )
        #expect(resumeQuery)

        let resumed = await renderer.waitForTickCount(atLeast: 1, timeoutNanos: 5_000_000_000)
        #expect(resumed)
        #expect(await renderer.tickCount >= 1)

        continuation.finish()
        await controller.shutdown()
        _ = try await task.value
        await renderer.awaitCleanup()
    }

    @Test("shutdown latch blocks scroll re-arm from a late resume")
    func shutdownLatchBlocksScrollResume() async throws {
        let gate = ScrollRestoreGate()
        // Long initial delay so suspend/teardown win the race against the
        // first wake; the late resume then tries to re-arm a short delay.
        let renderer = ScrollClockFakeRenderer(
            armDelay: 10.0,
            ticksUntilDisarm: 100,
            restoreGate: gate
        )
        let (stream, continuation) = AsyncStream<InputEvent>.makeStream()
        let controller = OpenGrokPagerInteractiveController(
            input: stream,
            runtime: ScrollClockInertRuntime(),
            renderer: renderer,
            output: ScrollClockSilentOutput()
        )

        let runTask = Task { try await controller.run(.init(prompt: "", mode: .inline)) }
        await yieldScroll(
            .mouse(MouseEvent(kind: .scrollDown, x: 1, y: 1)),
            on: continuation,
            renderer: renderer,
            handleInputAtLeast: 1,
            deadlineQueryAtLeast: 1
        )

        await controller.suspendMotionTicker()
        let ticksAtSuspend = await renderer.tickCount
        let queriesAtSuspend = await renderer.deadlineQueryCount

        let shutdownTask = Task { await controller.shutdown() }
        await gate.waitUntilRestoreEntered()

        // Child cleanup racing teardown — must not re-arm scroll wakeups
        // into restoreTerminal.
        await renderer.setArmDelay(0.01)
        await controller.resumeMotionTicker()
        await controller.resumeMotionTicker()
        let lateRearm = await renderer.waitForDeadlineQueryCount(
            atLeast: queriesAtSuspend + 1,
            timeoutNanos: 200_000_000
        )
        #expect(!lateRearm)
        #expect(await renderer.tickCount == ticksAtSuspend)

        await gate.allowRestore()
        continuation.finish()
        _ = try await runTask.value
        await shutdownTask.value
        #expect(await renderer.tickCount == ticksAtSuspend)
        await renderer.awaitCleanup()
    }

    @Test("re-arming replaces the prior scroll ticker — no duplicate wakeups")
    func noDuplicateScrollTicker() async throws {
        // First arm uses a long delay; a second scroll shortens it. Only the
        // replacement generation may tick — overlapping ticks would mean two
        // live ticker tasks. The second yield waits until the first event's
        // handleInput + deadline refresh have latched (pump past that event).
        let renderer = ScrollClockFakeRenderer(armDelay: 10.0, ticksUntilDisarm: 1)
        let (stream, continuation) = AsyncStream<InputEvent>.makeStream()
        let controller = OpenGrokPagerInteractiveController(
            input: stream,
            runtime: ScrollClockInertRuntime(),
            renderer: renderer,
            output: ScrollClockSilentOutput()
        )

        let task = Task { try await controller.run(.init(prompt: "", mode: .inline)) }
        await yieldScroll(
            .mouse(MouseEvent(kind: .scrollDown, x: 0, y: 0)),
            on: continuation,
            renderer: renderer,
            handleInputAtLeast: 1,
            deadlineQueryAtLeast: 1
        )

        await renderer.setArmDelay(0.02)
        await yieldScroll(
            .mouse(MouseEvent(kind: .scrollDown, x: 0, y: 1)),
            on: continuation,
            renderer: renderer,
            handleInputAtLeast: 2,
            deadlineQueryAtLeast: 2
        )

        let ticked = await renderer.waitForTickCount(atLeast: 1, timeoutNanos: 5_000_000_000)
        #expect(ticked)
        // Post-tick disarm proves the replacement generation finished; a
        // cancelled long-delay twin would still be sleeping and must not tick.
        let disarmed = await renderer.waitForPostTickDisarm(timeoutNanos: 5_000_000_000)
        #expect(disarmed)
        #expect(await renderer.tickCount == 1)
        #expect(await renderer.maxConcurrentTicks == 1)

        continuation.finish()
        await controller.shutdown()
        _ = try await task.value
        await renderer.awaitCleanup()
    }
}

// MARK: - Harness

/// Yield one scroll event, then wait until the controller has both offered it
/// to `handleInput` and refreshed the scroll deadline. That pair is the
/// pump-past-this-event latch — safe to yield the next event afterward.
private func yieldScroll(
    _ event: InputEvent,
    on continuation: AsyncStream<InputEvent>.Continuation,
    renderer: ScrollClockFakeRenderer,
    handleInputAtLeast: Int,
    deadlineQueryAtLeast: Int
) async {
    continuation.yield(event)
    let handled = await renderer.waitForHandleInputCount(
        atLeast: handleInputAtLeast,
        timeoutNanos: 5_000_000_000
    )
    #expect(handled)
    let refreshed = await renderer.waitForDeadlineQueryCount(
        atLeast: deadlineQueryAtLeast,
        timeoutNanos: 5_000_000_000
    )
    #expect(refreshed)
}

/// Gates `restoreTerminal` so tests can observe teardown after the shutdown
/// latch and before `running` flips false.
private actor ScrollRestoreGate {
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

/// Fake render adapter that owns a virtual scroll deadline. Mouse scroll
/// input arms a relative delay; each tick decrements a remaining-tick
/// budget and returns `nil` when spent — the controller must disarm.
private actor ScrollClockFakeRenderer: OpenGrokPagerInteractiveRenderAdapter {
    private struct Snapshot: Sendable {
        var handleInputCount: Int
        var deadlineQueryCount: Int
        var tickCount: Int
        var deadlineAfterLastTickWasNil: Bool
    }

    private struct Waiter {
        let id: UUID
        let check: @Sendable (Snapshot) -> Bool
        let continuation: CheckedContinuation<Void, Never>
    }

    private var armDelay: TimeInterval
    private var remainingTicks: Int
    private let restoreGate: ScrollRestoreGate?

    private(set) var tickCount = 0
    private(set) var handleInputCount = 0
    private(set) var deadlineQueryCount = 0
    private(set) var animationFrames: [OpenGrokPagerAnimationFrame] = []
    private(set) var deadlineAfterLastTickWasNil = false
    private(set) var maxConcurrentTicks = 0
    private var ticksInFlight = 0
    private var armed = false
    private var ticksSeen = 0
    private var waiters: [Waiter] = []

    init(
        armDelay: TimeInterval,
        ticksUntilDisarm: Int,
        restoreGate: ScrollRestoreGate? = nil
    ) {
        self.armDelay = armDelay
        self.remainingTicks = ticksUntilDisarm
        self.restoreGate = restoreGate
    }

    func begin() {}

    func restoreTerminal() async {
        if let restoreGate {
            await restoreGate.noteRestoreEntered()
        }
    }

    func render(_ event: OpenGrokPagerInteractiveEvent) {
        _ = event
    }

    func renderAnimationTick(_ frame: OpenGrokPagerAnimationFrame) {
        animationFrames.append(frame)
    }

    func handleInput(_ event: InputEvent) -> OpenGrokPagerInputRouting {
        handleInputCount += 1
        notifyWaiters()
        guard case .mouse(let mouse) = event else { return .notHandled }
        switch mouse.kind {
        case .scrollUp, .scrollDown, .scrollLeft, .scrollRight:
            armed = true
            return .consumed
        default:
            return .notHandled
        }
    }

    func scrollClockDeadline(at now: TimeInterval) -> TimeInterval? {
        _ = now
        deadlineQueryCount += 1
        let result: TimeInterval?
        if armed, remainingTicks > 0 {
            result = armDelay
        } else {
            result = nil
        }
        if ticksSeen > 0, result == nil {
            deadlineAfterLastTickWasNil = true
        }
        notifyWaiters()
        return result
    }

    func handleScrollClockTick(at now: TimeInterval) async {
        _ = now
        ticksInFlight += 1
        maxConcurrentTicks = max(maxConcurrentTicks, ticksInFlight)
        tickCount += 1
        ticksSeen += 1
        remainingTicks = max(0, remainingTicks - 1)
        if remainingTicks == 0 {
            armed = false
        }
        notifyWaiters()
        ticksInFlight -= 1
    }

    func setArmDelay(_ delay: TimeInterval) {
        armDelay = delay
        if remainingTicks == 0 {
            remainingTicks = 1
        }
        armed = true
    }

    func waitForHandleInputCount(atLeast count: Int, timeoutNanos: UInt64) async -> Bool {
        await wait(timeoutNanos: timeoutNanos) { $0.handleInputCount >= count }
    }

    func waitForDeadlineQueryCount(atLeast count: Int, timeoutNanos: UInt64) async -> Bool {
        await wait(timeoutNanos: timeoutNanos) { $0.deadlineQueryCount >= count }
    }

    func waitForTickCount(atLeast count: Int, timeoutNanos: UInt64) async -> Bool {
        await wait(timeoutNanos: timeoutNanos) { $0.tickCount >= count }
    }

    /// The controller's post-tick `scrollClockDeadline` returned `nil`.
    func waitForPostTickDisarm(timeoutNanos: UInt64) async -> Bool {
        await wait(timeoutNanos: timeoutNanos) { $0.deadlineAfterLastTickWasNil }
    }

    /// Drain any waiter bookkeeping so a finished test does not leave a
    /// continuation parked on a cancelled timeout task.
    func awaitCleanup() {
        expireAllWaiters()
    }

    private var snapshot: Snapshot {
        Snapshot(
            handleInputCount: handleInputCount,
            deadlineQueryCount: deadlineQueryCount,
            tickCount: tickCount,
            deadlineAfterLastTickWasNil: deadlineAfterLastTickWasNil
        )
    }

    private func wait(
        timeoutNanos: UInt64,
        for check: @escaping @Sendable (Snapshot) -> Bool
    ) async -> Bool {
        if check(snapshot) { return true }
        let waiterID = UUID()
        // Cancellation must return without expiring anyone: `try? Task.sleep`
        // used to swallow cancel and then `expireWaiters()` resumed the
        // *next* assertion's waiter (~1 ms false). Each timeout owns only
        // its waiter ID.
        let timeout = Task {
            do {
                try await Task.sleep(nanoseconds: timeoutNanos)
            } catch {
                return
            }
            self.expireWaiter(id: waiterID)
        }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(id: waiterID, check: check, continuation: continuation))
            // Re-check after enqueue: a tick may have landed between the
            // initial check and the waiter append.
            notifyWaiters()
        }
        timeout.cancel()
        return check(snapshot)
    }

    private func notifyWaiters() {
        let current = snapshot
        let readyIDs = Set(waiters.filter { $0.check(current) }.map(\.id))
        guard !readyIDs.isEmpty else { return }
        let ready = waiters.filter { readyIDs.contains($0.id) }
        waiters.removeAll { readyIDs.contains($0.id) }
        for waiter in ready { waiter.continuation.resume() }
    }

    /// Resume a single timed-out waiter. No-op if it already succeeded and
    /// was removed by `notifyWaiters` — never touches other waiters.
    private func expireWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume()
    }

    private func expireAllWaiters() {
        let expired = waiters
        waiters.removeAll()
        for waiter in expired { waiter.continuation.resume() }
    }
}

private struct ScrollClockSilentOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}

private actor ScrollClockInertRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        _ = request
        throw OpenGrokPagerInteractiveError.sessionFailed("scroll-clock test runtime has no sessions")
    }

    func replaceSession(from request: OpenGrokPagerRequest) async throws -> String {
        _ = request
        throw OpenGrokPagerInteractiveError.sessionFailed("scroll-clock test runtime has no sessions")
    }
}
