// LiveBackgroundWorkSpinnerTests.swift
//
// Live-seam proofs for the status-bar background-task chip and
// `PagerMotionState.hasBackgroundTasks` through `LiveInteractiveControllerRenderer`
// (AGENTS.md §3). Assert `PagerStatusBar` / motion demand — not raw ANSI
// (diff sinks split styled runs). Glyph spin paint stays in
// `PagerMotionRenderSiteTests.backgroundChipSpins`.

import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokScheduler
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

// MARK: - Capture / latch fixtures

/// Terminal sink required by the renderer. No chip parsing — ANSI diffs do
/// not keep `dot + count` contiguous.
private final class ChipCapturingSink: PagerTerminalSink, @unchecked Sendable {
    var capabilities: PagerTerminalCapabilities { .standard }
    func write(bytes _: [UInt8]) throws {}
    func flush() throws {}
}

/// Records motion states; optionally parks inside the sink on a matching
/// delivery until `release()` — deterministic stand-in for a slow consumer.
private final class ChipMotionLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [PagerMotionState] = []
    private var entered = false
    private var enterWaiter: CheckedContinuation<Void, Never>?
    private var released = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private let shouldBlock: @Sendable (PagerMotionState) -> Bool

    init(shouldBlock: @escaping @Sendable (PagerMotionState) -> Bool = { _ in false }) {
        self.shouldBlock = shouldBlock
    }

    var snapshot: [PagerMotionState] {
        lock.lock(); defer { lock.unlock() }
        return states
    }

    private func append(_ state: PagerMotionState) {
        lock.lock(); defer { lock.unlock() }
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

    private func registerEnterWaiter(
        _ continuation: CheckedContinuation<Void, Never>
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if entered { return true }
        enterWaiter = continuation
        return false
    }

    private func registerReleaseWaiter(
        _ continuation: CheckedContinuation<Void, Never>
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
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

/// Controllable backend so shell completion is latched (no interval sleeps).
private actor ControllableChipShellBackend: ShellProcessBackend {
    private var nextOrdinal = 0
    private var completed: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var owners: [String: String] = [:]

    func run(_ request: ShellCommandRequest) async throws -> ShellCommandResult {
        nextOrdinal += 1
        let taskID = "auto-\(nextOrdinal)"
        owners[taskID] = request.ownerSessionID ?? ""
        return ShellCommandResult(
            combinedOutput: "partial",
            backgrounded: true,
            taskID: taskID
        )
    }

    func runBackground(_ request: ShellCommandRequest) async throws -> ShellBackgroundHandle {
        nextOrdinal += 1
        let taskID = "bg-\(nextOrdinal)"
        owners[taskID] = request.ownerSessionID ?? ""
        return ShellBackgroundHandle(taskID: taskID)
    }

    func getTask(_ taskID: String) async -> ShellTaskSnapshot? {
        guard owners[taskID] != nil else { return nil }
        return snapshot(taskID: taskID)
    }

    func killTask(_ taskID: String) async -> ShellKillOutcome {
        guard owners[taskID] != nil else { return .notFound }
        if completed.contains(taskID) { return .alreadyExited }
        finish(taskID)
        return .killed
    }

    func killForegroundCommands() async {}
    func killForegroundCommands(ownerSessionID: String) async {}
    func killAllBackgroundTasks() async {
        for taskID in owners.keys where !completed.contains(taskID) {
            finish(taskID)
        }
    }

    func killAllBackgroundTasks(ownerSessionID: String) async {
        for (taskID, owner) in owners where owner == ownerSessionID && !completed.contains(taskID) {
            finish(taskID)
        }
    }

    func warmShell(at cwd: URL) async {}
    func backgroundForegroundCommand(toolCallID: String) async -> Bool { false }

    func waitForCompletion(_ taskID: String, timeout: ShellDuration?) async -> ShellTaskSnapshot? {
        guard owners[taskID] != nil else { return nil }
        if !completed.contains(taskID) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters[taskID, default: []].append(continuation)
            }
        }
        return snapshot(taskID: taskID)
    }

    func listTasks() async -> [ShellTaskSnapshot] {
        owners.keys.sorted().map { snapshot(taskID: $0) }
    }

    func shellCWD() async -> URL? { nil }

    func complete(_ taskID: String) {
        finish(taskID)
    }

    private func finish(_ taskID: String) {
        guard !completed.contains(taskID) else { return }
        completed.insert(taskID)
        let pending = waiters.removeValue(forKey: taskID) ?? []
        for continuation in pending {
            continuation.resume()
        }
    }

    private func snapshot(taskID: String) -> ShellTaskSnapshot {
        ShellTaskSnapshot(
            taskID: taskID,
            command: "controllable",
            cwd: URL(fileURLWithPath: "/tmp"),
            completed: completed.contains(taskID),
            ownerSessionID: owners[taskID],
            isBackgrounded: true
        )
    }
}

private struct ChipFixture {
    let home: URL
    let sink: ChipCapturingSink
    let renderer: LiveInteractiveControllerRenderer

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "opengrok-chip-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        sink = ChipCapturingSink()
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
            modelName: "chip-model",
            modelCatalog: [
                LiveModelPickerEntry(id: "chip-model", providerID: "xai", name: "chip-model"),
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

private func withChipFixture(
    _ body: (ChipFixture) async throws -> Void
) async throws {
    let fixture = try ChipFixture()
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

private func waitForStatusBarCount(
    _ renderer: LiveInteractiveControllerRenderer,
    _ count: Int,
    timeout: TimeInterval = 5
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await renderer.testingStatusBarBackgroundTaskCount() == count {
            return true
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await renderer.testingStatusBarBackgroundTaskCount() == count
}

private func bridgeRequest(
    command: String,
    callID: String,
    cwd: URL
) -> ShellCommandRequest {
    ShellCommandRequest(
        command: command,
        workingDirectory: cwd,
        timeout: .seconds(30),
        toolCallID: callID,
        autoBackgroundOnTimeout: false,
        kind: .bash,
        ownerSessionID: nil
    )
}

// MARK: - Suite

@Suite("Live background-work spinner", .serialized)
struct LiveBackgroundWorkSpinnerTests {

    @Test("synthetic per-kind events update count/chip/motion; upserts are idempotent")
    func syntheticPerKindIdempotent() async throws {
        try await withChipFixture { fixture in
            let renderer = fixture.renderer
            try await renderer.begin()
            try await renderer.testingDismissWelcomeOverlay()

            let latch = ChipMotionLatch()
            await renderer.setMotionStateSink(latch.sink())
            #expect(await latch.waitUntil { states in
                states.contains { $0.demand == PagerTickDemand.none }
            })

            let shell = try #require(LiveActiveBackgroundWorkEvent.upsert(
                kind: .shell, id: "shell-1"
            ))
            let subagent = try #require(LiveActiveBackgroundWorkEvent.upsert(
                kind: .subagent, id: "child-1"
            ))
            let scheduled = try #require(LiveActiveBackgroundWorkEvent.upsert(
                kind: .scheduled, id: "loop-1"
            ))
            let workflow = try #require(LiveActiveBackgroundWorkEvent.upsert(
                kind: .workflow, id: "wf-1"
            ))

            await renderer.applyActiveBackgroundWork(shell)
            #expect(await renderer.testingPagerStatusBar()?.backgroundTaskCount == 1)
            #expect(await renderer.testingPublishedHasBackgroundTasks() == true)
            #expect(await renderer.testingPublishedMotionDemand() == PagerTickDemand.fast)

            await renderer.applyActiveBackgroundWork(shell) // idempotent
            #expect(await renderer.testingStatusBarBackgroundTaskCount() == 1)
            #expect(await renderer.testingActiveBackgroundWorkCount(of: .shell) == 1)

            await renderer.applyActiveBackgroundWork(subagent)
            await renderer.applyActiveBackgroundWork(scheduled)
            await renderer.applyActiveBackgroundWork(workflow)
            #expect(await renderer.testingPagerStatusBar()?.backgroundTaskCount == 4)
            #expect(await renderer.testingPublishedMotionDemand() == PagerTickDemand.fast)

            let removeShell = try #require(LiveActiveBackgroundWorkEvent.remove(
                kind: .shell, id: "shell-1"
            ))
            await renderer.applyActiveBackgroundWork(removeShell)
            await renderer.applyActiveBackgroundWork(removeShell) // idempotent
            #expect(await renderer.testingStatusBarBackgroundTaskCount() == 3)
            #expect(await renderer.testingActiveBackgroundWorkCount(of: .shell) == 0)

            await renderer.setMotionStateSink(nil)
        }
    }

    @Test("two simultaneous kinds count 2; remove one leaves count 1")
    func twoKindsThenRemoveOne() async throws {
        try await withChipFixture { fixture in
            let renderer = fixture.renderer
            try await renderer.begin()
            try await renderer.testingDismissWelcomeOverlay()

            let a = try #require(LiveActiveBackgroundWorkEvent.upsert(
                kind: .shell, id: "a"
            ))
            let b = try #require(LiveActiveBackgroundWorkEvent.upsert(
                kind: .scheduled, id: "b"
            ))
            await renderer.applyActiveBackgroundWork(a)
            await renderer.applyActiveBackgroundWork(b)
            #expect(await renderer.testingPagerStatusBar()?.backgroundTaskCount == 2)
            #expect(await renderer.testingPublishedMotionDemand() == PagerTickDemand.fast)

            let removeA = try #require(LiveActiveBackgroundWorkEvent.remove(
                kind: .shell, id: "a"
            ))
            await renderer.applyActiveBackgroundWork(removeA)
            #expect(await renderer.testingPagerStatusBar()?.backgroundTaskCount == 1)
            #expect(await renderer.testingPublishedHasBackgroundTasks() == true)
            #expect(await renderer.testingPublishedMotionDemand() == PagerTickDemand.fast)
        }
    }

    @Test("background alone (no turn/welcome) produces fast motion; last remove → none")
    func backgroundAloneFastThenNone() async throws {
        try await withChipFixture { fixture in
            let renderer = fixture.renderer
            try await renderer.begin()
            try await renderer.testingDismissWelcomeOverlay()

            // Nonblocking: this test only observes demand transitions. A
            // parked sink without release hangs `setMotionStateSink(nil)`.
            let latch = ChipMotionLatch()
            await renderer.setMotionStateSink(latch.sink())
            #expect(await latch.waitUntil { states in
                states.contains {
                    $0.demand == PagerTickDemand.none && !$0.hasBackgroundTasks
                }
            })
            let baseline = latch.snapshot.count

            let upsert = try #require(LiveActiveBackgroundWorkEvent.upsert(
                kind: .shell, id: "solo"
            ))
            await renderer.applyActiveBackgroundWork(upsert)
            #expect(await latch.waitUntil { states in
                states.count > baseline
                    && states.last?.hasBackgroundTasks == true
                    && states.last?.demand == PagerTickDemand.fast
            })
            #expect(await renderer.testingPagerStatusBar()?.backgroundTaskCount == 1)
            #expect(await renderer.testingPublishedMotionDemand() == PagerTickDemand.fast)

            let remove = try #require(LiveActiveBackgroundWorkEvent.remove(
                kind: .shell, id: "solo"
            ))
            await renderer.applyActiveBackgroundWork(remove)
            #expect(await latch.waitUntil { states in
                states.last?.hasBackgroundTasks == false
                    && states.last?.demand == PagerTickDemand.none
            })
            #expect(await renderer.testingStatusBarBackgroundTaskCount() == 0)
            #expect(await renderer.testingPublishedMotionDemand() == PagerTickDemand.none)

            await renderer.setMotionStateSink(nil)
        }
    }

    @Test("real shell background arms count 1 / fast; completion removes and parks")
    func realShellBackgroundChip() async throws {
        try await withChipFixture { fixture in
            let renderer = fixture.renderer
            let cwd = fixture.home
            try await renderer.begin()
            try await renderer.testingDismissWelcomeOverlay()

            let latch = ChipMotionLatch()
            await renderer.setMotionStateSink(latch.sink())
            #expect(await latch.waitUntil {
                $0.contains { $0.demand == PagerTickDemand.none }
            })

            let backend = ControllableChipShellBackend()
            let process = try OpenGrokShellOwnedProcessExecution(
                sessionID: "chip-shell",
                workingDirectory: cwd,
                backend: backend
            )
            let abwSink = await renderer.makeActiveBackgroundWorkSink()
            await LiveShellActiveBackgroundWork.setActiveBackgroundWorkSink(
                abwSink,
                on: process
            )

            let handle = try await process.runBackground(
                bridgeRequest(command: "sleep 60", callID: "chip-bg", cwd: cwd)
            )
            #expect(await waitForStatusBarCount(renderer, 1))
            #expect(await renderer.testingPagerStatusBar()?.backgroundTaskCount == 1)
            #expect(await renderer.testingPublishedHasBackgroundTasks() == true)
            #expect(await renderer.testingPublishedMotionDemand() == PagerTickDemand.fast)

            await backend.complete(handle.taskID)
            #expect(await waitForStatusBarCount(renderer, 0))
            #expect(await renderer.testingPublishedHasBackgroundTasks() == false)
            #expect(await renderer.testingPublishedMotionDemand() == PagerTickDemand.none)

            await LiveShellActiveBackgroundWork.setActiveBackgroundWorkSink(nil, on: process)
            await process.cancelAll()
            await renderer.setMotionStateSink(nil)
        }
    }

    @Test("scheduler install reseeds existing ids into the live chip")
    func schedulerInstallReseeds() async throws {
        try await withChipFixture { fixture in
            let renderer = fixture.renderer
            try await renderer.begin()
            try await renderer.testingDismissWelcomeOverlay()

            let host = LiveSchedulerHost(clock: { Date(timeIntervalSince1970: 1_700_000_000) })
            let task = try await host.createTask(
                intervalSecs: 300,
                prompt: "reseed chip",
                durable: false,
                foreground: true,
                fireImmediately: false
            )
            // Install after create — host must reseed the visible id.
            let abwSink = await renderer.makeActiveBackgroundWorkSink()
            await host.setActiveBackgroundWorkSink(abwSink)

            #expect(await waitForStatusBarCount(renderer, 1))
            #expect(await renderer.testingPagerStatusBar()?.backgroundTaskCount == 1)
            #expect(await renderer.testingActiveBackgroundWorkCount(of: .scheduled) == 1)
            #expect(await renderer.testingPublishedMotionDemand() == PagerTickDemand.fast)

            #expect(try await host.deleteTask(id: task.id))
            #expect(await waitForStatusBarCount(renderer, 0))
            #expect(await renderer.testingPublishedMotionDemand() == PagerTickDemand.none)

            await host.setActiveBackgroundWorkSink(nil)
            await host.shutdown()
        }
    }

    @Test("restored/teardown ignores late upsert; motion sink ends with ordered none")
    func restoreIgnoresLateEventOrderedNone() async throws {
        try await withChipFixture { fixture in
            let renderer = fixture.renderer
            try await renderer.begin()
            try await renderer.testingDismissWelcomeOverlay()

            let latch = ChipMotionLatch {
                $0.hasBackgroundTasks && $0.demand == PagerTickDemand.fast
            }
            await renderer.setMotionStateSink(latch.sink())
            #expect(await latch.waitUntil { states in
                states.contains { $0.demand == PagerTickDemand.none }
            })

            let abwSink = await renderer.makeActiveBackgroundWorkSink()
            let upsert = try #require(LiveActiveBackgroundWorkEvent.upsert(
                kind: .shell, id: "late"
            ))
            await abwSink(upsert)
            #expect(await renderer.testingStatusBarBackgroundTaskCount() == 1)

            // Park on the fast delivery so restore's final none is ordered
            // behind it (same latch pattern as motion publish tests).
            await latch.waitUntilBlocked()
            let restoreTask = Task {
                try await renderer.restoreTerminal()
            }
            // Restore awaits the delivery loop before clearing the motion
            // sink; release so the pending `.none` can land, then restore
            // finishes.
            latch.release()
            try await restoreTask.value

            #expect(await latch.waitUntil { states in
                states.last?.demand == PagerTickDemand.none
                    && states.last?.hasBackgroundTasks == false
            })
            let states = latch.snapshot
            #expect(states.last?.demand == PagerTickDemand.none)
            #expect(states.contains {
                $0.hasBackgroundTasks && $0.demand == PagerTickDemand.fast
            })
            if let noneIndex = states.lastIndex(where: {
                $0.demand == PagerTickDemand.none && !$0.hasBackgroundTasks
            }) {
                let after = states.suffix(from: states.index(after: noneIndex))
                #expect(!after.contains { $0.hasBackgroundTasks })
            }

            // Stale upsert after restore must not re-arm.
            await abwSink(upsert)
            #expect(await renderer.testingRestored())
            #expect(await renderer.testingStatusBarBackgroundTaskCount() == 0)
            #expect(await renderer.testingActiveBackgroundWorkCount() == 0)
        }
    }
}
