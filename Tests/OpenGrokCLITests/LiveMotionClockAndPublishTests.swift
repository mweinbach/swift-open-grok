// LiveMotionClockAndPublishTests.swift
//
// Live-seam proofs for the motion-clock idle-gap fix and the ordered
// motion-state publisher on `LiveInteractiveControllerRenderer`.

import Foundation
import OpenGrokPager
import OpenGrokPagerMinimal
import OpenGrokPagerRender
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

private final class MotionCapturingSink: PagerTerminalSink, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes newBytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        bytes.append(contentsOf: newBytes)
    }

    func flush() throws {}
}

/// Records motion states; optionally parks inside the sink on a matching
/// delivery until `release()` — a deterministic stand-in for a slow consumer.
///
/// All `NSLock` use lives in synchronous helpers. Async methods only call
/// those helpers (Swift 6 forbids `lock`/`unlock` in async bodies).
private final class MotionDeliveryLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [PagerMotionState] = []
    private var entered = false
    private var enterWaiter: CheckedContinuation<Void, Never>?
    private var released = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private let shouldBlock: @Sendable (PagerMotionState) -> Bool

    init(shouldBlock: @escaping @Sendable (PagerMotionState) -> Bool) {
        self.shouldBlock = shouldBlock
    }

    var snapshot: [PagerMotionState] {
        lock.lock(); defer { lock.unlock() }
        return states
    }

    private func append(_ state: PagerMotionState) {
        lock.lock()
        defer { lock.unlock() }
        states.append(state)
    }

    private func hasEntered() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entered
    }

    private func hasReleased() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return released
    }

    /// Registers `continuation` unless already entered. Returns `true` when
    /// the caller must resume immediately (already entered).
    private func registerEnterWaiter(
        _ continuation: CheckedContinuation<Void, Never>
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if entered { return true }
        enterWaiter = continuation
        return false
    }

    /// Registers `continuation` unless already released. Returns `true` when
    /// the caller must resume immediately (already released).
    private func registerReleaseWaiter(
        _ continuation: CheckedContinuation<Void, Never>
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if released { return true }
        releaseWaiter = continuation
        return false
    }

    func waitUntilBlocked() async {
        if hasEntered() { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if registerEnterWaiter(continuation) {
                continuation.resume()
            }
        }
    }

    func release() {
        lock.lock()
        released = true
        let waiter = releaseWaiter
        releaseWaiter = nil
        lock.unlock()
        waiter?.resume()
    }

    private func noteEntered() {
        lock.lock()
        entered = true
        let waiter = enterWaiter
        enterWaiter = nil
        lock.unlock()
        waiter?.resume()
    }

    private func waitForRelease() async {
        if hasReleased() { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if registerReleaseWaiter(continuation) {
                continuation.resume()
            }
        }
    }

    func sink() -> @Sendable (PagerMotionState) async -> Void {
        { state in
            if self.shouldBlock(state) {
                self.noteEntered()
                await self.waitForRelease()
            }
            self.append(state)
        }
    }

    func waitUntil(
        timeout: TimeInterval = 2,
        _ predicate: ([PagerMotionState]) -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(snapshot) { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return predicate(snapshot)
    }
}

private struct MotionFixture {
    let home: URL
    let sink: MotionCapturingSink
    let renderer: LiveInteractiveControllerRenderer

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "opengrok-motion-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        sink = MotionCapturingSink()
        let terminal = OpenGrokLiveTerminal(
            isTTY: { true },
            size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
            write: { _ in }
        )
        renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: terminal,
            sink: sink,
            workingDirectory: home.path,
            modelName: "motion-model",
            modelCatalog: [
                LiveModelPickerEntry(id: "motion-model", providerID: "xai", name: "motion-model"),
            ],
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: [
                "HOME": home.path,
                "OPENGROK_HOME": home.path,
                "TERM": "xterm-256color",
            ]
        )
    }

    func dispose() {
        try? FileManager.default.removeItem(at: home)
    }
}

private func withMotionFixture(
    _ body: (MotionFixture) async throws -> Void
) async throws {
    let fixture = try MotionFixture()
    do {
        try await body(fixture)
        try await fixture.renderer.restoreTerminal()
        fixture.dispose()
    } catch {
        try? await fixture.renderer.restoreTerminal()
        fixture.dispose()
        throw error
    }
}

@Suite("Live motion clock and publishing", .serialized)
struct LiveMotionClockAndPublishTests {
    @Test("idle gap then turn start: first elapsed is near zero, not the idle duration")
    func idleGapTurnStartElapsedIsFresh() async throws {
        try await withMotionFixture { fixture in
            let renderer = fixture.renderer
            try await renderer.begin()
            try await renderer.renderAnimationTick(OpenGrokPagerAnimationFrame(
                tick: 30,
                seconds: 1.0,
                demand: .fast
            ))
            try await Task.sleep(nanoseconds: 300_000_000)

            try await renderer.render(.turnStarted(OpenGrokPagerRequest(
                prompt: "hello after idle",
                mode: .fullScreen
            )))
            #expect(await renderer.testingTurnElapsed()! < 0.05)

            // Resume the painted tick at the extrapolated clock. Without the
            // idle-gap fix, turnStartedAtSeconds stays at 1.0 and elapsed
            // jumps to ~the idle duration on this first resumed tick.
            let resumed = await renderer.testingMotionSeconds()
            #expect(resumed >= 1.25)
            try await renderer.renderAnimationTick(OpenGrokPagerAnimationFrame(
                tick: Int(resumed / PagerMotion.tickInterval(fps: PagerMotion.defaultFPS)),
                seconds: resumed,
                demand: .fast
            ))
            #expect(await renderer.testingTurnElapsed()! < 0.05)
        }
    }

    @Test("pre-first-tick idle after begin: turn elapsed stays near zero on the first aged frame")
    func beginAnchorKeepsPreFirstTickElapsedFresh() async throws {
        try await withMotionFixture { fixture in
            let renderer = fixture.renderer
            // No renderAnimationTick — resumed/non-welcome shape: begin seeds
            // the anchor, then idle, then the first frame carries run age.
            try await renderer.begin()
            try await Task.sleep(nanoseconds: 300_000_000)

            try await renderer.render(.turnStarted(OpenGrokPagerRequest(
                prompt: "first turn after idle",
                mode: .fullScreen
            )))
            #expect(await renderer.testingTurnElapsed()! < 0.05)

            let runAge = await renderer.testingMotionSeconds()
            #expect(runAge >= 0.25)
            try await renderer.renderAnimationTick(OpenGrokPagerAnimationFrame(
                tick: Int(runAge / PagerMotion.tickInterval(fps: PagerMotion.defaultFPS)),
                seconds: runAge,
                demand: .fast
            ))
            #expect(await renderer.testingTurnElapsed()! < 0.05)
        }
    }

    @Test("idle gap then tool completion: finish flash is visible and later expires")
    func idleGapToolFinishFlashSurvivesAndExpires() async throws {
        try await withMotionFixture { fixture in
            let renderer = fixture.renderer
            try await renderer.begin()
            try await renderer.renderAnimationTick(OpenGrokPagerAnimationFrame(
                tick: 30,
                seconds: 1.0,
                demand: .fast
            ))
            try await Task.sleep(nanoseconds: 250_000_000)

            try await renderer.render(.session(.tool(OpenGrokPagerToolUpdate(
                callID: "flash-1",
                name: "shell",
                input: "true",
                state: .running
            ))))
            try await renderer.render(.session(.tool(OpenGrokPagerToolUpdate(
                callID: "flash-1",
                name: "shell",
                input: "true",
                output: "ok",
                state: .succeeded
            ))))

            let finishedAt = try #require(await renderer.testingToolFinishedAt(callID: "flash-1"))
            let now = await renderer.testingMotionSeconds()
            // Stamp must be on the extrapolated clock, not the frozen tick.
            #expect(finishedAt >= 1.2)
            #expect(abs(finishedAt - now) < 0.05)
            #expect(await renderer.testingHasPendingFlash())

            // Flash expires on the extrapolated clock even before the next
            // painted tick — otherwise it would vanish only when ticks resume
            // and look like it never flashed.
            try await Task.sleep(nanoseconds: 450_000_000)
            #expect(await !renderer.testingHasPendingFlash())
        }
    }

    @Test("burst high→none motion states: sink observes final none, not a stale re-arm")
    func motionPublishCoalescesToFinalNone() async throws {
        try await withMotionFixture { fixture in
            let renderer = fixture.renderer
            try await renderer.begin()
            // Clear the welcome/.slow arm so the burst is turn demand only.
            try await renderer.render(.turnStarted(OpenGrokPagerRequest(
                prompt: "arm",
                mode: .fullScreen
            )))
            try await renderer.render(.turnFinished(OpenGrokPagerRuntimeResult(
                lifecycle: .completed,
                sessionID: nil,
                forwardedEventCount: 0,
                terminalRestored: false
            )))

            let latch = MotionDeliveryLatch { $0.demand >= .fast }
            await renderer.setMotionStateSink(latch.sink())
            // Drain the install-time publish before the burst so the block
            // gate lands on the high-demand delivery, not the idle one.
            #expect(await latch.waitUntil { states in
                states.contains { $0.demand == PagerTickDemand.none }
            })
            let baselineCount = latch.snapshot.count

            try await renderer.render(.turnStarted(OpenGrokPagerRequest(
                prompt: "burst",
                mode: .fullScreen
            )))
            // Deterministic overlap: wait until the sink has entered the
            // `.fast` await, then publish `.none` while it is still held.
            await latch.waitUntilBlocked()
            do {
                try await renderer.render(.turnFinished(OpenGrokPagerRuntimeResult(
                    lifecycle: .completed,
                    sessionID: nil,
                    forwardedEventCount: 0,
                    terminalRestored: false
                )))
            } catch {
                latch.release()
                throw error
            }
            latch.release()

            #expect(await latch.waitUntil { states in
                states.count > baselineCount
                    && states.last?.demand == PagerTickDemand.none
            })

            let states = latch.snapshot
            #expect(states.last?.demand == PagerTickDemand.none)
            #expect(states.contains { $0.demand >= .fast })
            if let noneIndex = states.lastIndex(where: {
                $0.demand == PagerTickDemand.none
            }) {
                let afterNone = states.suffix(from: states.index(after: noneIndex))
                #expect(!afterNone.contains { $0.demand >= .fast })
            }

            await renderer.setMotionStateSink(nil)
        }
    }

    @Test("sink replacement awaits the in-flight old delivery and drops it afterward")
    func sinkReplacementAwaitsOldDelivery() async throws {
        try await withMotionFixture { fixture in
            let renderer = fixture.renderer
            try await renderer.begin()
            try await renderer.render(.turnStarted(OpenGrokPagerRequest(
                prompt: "arm",
                mode: .fullScreen
            )))
            try await renderer.render(.turnFinished(OpenGrokPagerRuntimeResult(
                lifecycle: .completed,
                sessionID: nil,
                forwardedEventCount: 0,
                terminalRestored: false
            )))

            let oldLatch = MotionDeliveryLatch { $0.demand >= .fast }
            await renderer.setMotionStateSink(oldLatch.sink())
            #expect(await oldLatch.waitUntil { states in
                states.contains { $0.demand == PagerTickDemand.none }
            })
            let oldCountAfterInstall = oldLatch.snapshot.count

            try await renderer.render(.turnStarted(OpenGrokPagerRequest(
                prompt: "hold",
                mode: .fullScreen
            )))
            await oldLatch.waitUntilBlocked()

            let clearDone = LockedFlag()
            let clearTask = Task {
                await renderer.setMotionStateSink(nil)
                clearDone.set()
            }
            // Replacement must park on the in-flight sink await — not return
            // after a cancel that leaves the old delivery running. Before
            // release, the teardown flag cannot be set.
            #expect(!clearDone.value)

            oldLatch.release()
            await clearTask.value
            #expect(clearDone.value)
            #expect(oldLatch.snapshot.count == oldCountAfterInstall + 1)
            let held = try #require(oldLatch.snapshot.last)
            #expect(held.demand >= .fast)

            // A fresh sink after clear must be the only observer; the old
            // latch must not grow from later publishes.
            let next = MotionDeliveryLatch { _ in false }
            await renderer.setMotionStateSink(next.sink())
            let installCount = next.snapshot.count
            try await renderer.render(.turnStarted(OpenGrokPagerRequest(
                prompt: "after-clear",
                mode: .fullScreen
            )))
            #expect(await next.waitUntil(timeout: 5) { states in
                states.dropFirst(installCount).contains { $0.demand >= .fast }
            })
            let startedCount = next.snapshot.count
            try await renderer.render(.turnFinished(OpenGrokPagerRuntimeResult(
                lifecycle: .completed,
                sessionID: nil,
                forwardedEventCount: 0,
                terminalRestored: false
            )))
            #expect(await next.waitUntil(timeout: 5) { states in
                states.count > startedCount
                    && states.last?.demand == PagerTickDemand.none
            })
            #expect(oldLatch.snapshot.count == oldCountAfterInstall + 1)

            await renderer.setMotionStateSink(nil)
        }
    }
}

/// Synchronous Bool flag for asserting an async teardown has not returned yet.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}
