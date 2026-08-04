import Foundation
import Testing
@testable import OpenGrokPagerRuntime

private actor RecordingModel: PagerModelAdapter {
    private(set) var actions: [PagerModelAction] = []
    private var revision: UInt64 = 0
    private var effectsForNextAction: [[PagerModelEffect]] = []

    func queueEffects(_ effects: [PagerModelEffect]) {
        effectsForNextAction.append(effects)
    }

    func apply(_ action: PagerModelAction) async throws -> [PagerModelEffect] {
        actions.append(action)
        if !effectsForNextAction.isEmpty {
            return effectsForNextAction.removeFirst()
        }
        switch action {
        case .input:
            return [.invalidate(.input)]
        case .resize:
            return [.invalidate(.resize)]
        case .tick:
            return [.invalidate(.tick)]
        case .cancel, .shutdown:
            return []
        }
    }

    func snapshot() async throws -> PagerRenderFrame {
        revision += 1
        return PagerRenderFrame(revision: revision, content: "frame-\(revision)")
    }

    func recordedActions() -> [PagerModelAction] {
        actions
    }
}

private actor RecordingBackend: PagerRenderBackend {
    private(set) var frames: [PagerRenderFrame] = []
    private(set) var flushCount = 0
    private(set) var shutdownCount = 0

    func render(_ frame: PagerRenderFrame) async throws {
        frames.append(frame)
    }

    func flush() async throws {
        flushCount += 1
    }

    func shutdown() async {
        shutdownCount += 1
    }

    func renderedFrames() -> [PagerRenderFrame] {
        frames
    }
}

private actor ManualClock: PagerRuntimeClock {
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    private var cancelledWaiters: Set<UUID> = []

    func sleep(for _: TimeInterval) async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if cancelledWaiters.remove(waiterID) != nil {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((waiterID, continuation))
                }
            }
        }, onCancel: {
            Task { await self.cancel(waiterID: waiterID) }
        })
    }

    func advance() {
        guard !waiters.isEmpty else { return }
        let (_, continuation) = waiters.removeFirst()
        continuation.resume()
    }

    func waitingCount() -> Int {
        waiters.count
    }

    private func cancel(waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == waiterID }) else {
            cancelledWaiters.insert(waiterID)
            return
        }
        let (_, continuation) = waiters.remove(at: index)
        continuation.resume(throwing: CancellationError())
    }
}

private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async {
    for _ in 0..<100 {
        if await condition() { return }
        await Task.yield()
    }
}

@Suite("Pager runtime")
struct OpenGrokPagerRuntimeTests {
    @Test("serializes input, resize, and clock ticks with coalesced invalidation")
    func serializesEventsAndRenders() async throws {
        let model = RecordingModel()
        let backend = RecordingBackend()
        let clock = ManualClock()
        let runtime = PagerRuntime(
            model: model,
            backend: backend,
            configuration: PagerRuntimeConfiguration(queueCapacity: 8, tickInterval: 1),
            clock: clock
        )

        let runTask = Task { await runtime.run() }
        await waitUntil { await clock.waitingCount() == 1 }
        _ = try await runtime.enqueue(.input(.key(.character("a"))))
        _ = try await runtime.enqueue(.resize(PagerSize(width: 100, height: 30)))
        await clock.advance()
        await waitUntil { (await model.recordedActions()).count >= 3 }

        await runtime.shutdown()
        let report = await runTask.value
        let actions = await model.recordedActions()
        let frames = await backend.renderedFrames()

        #expect(actions.prefix(3) == [
            .input(.key(.character("a"))),
            .resize(PagerSize(width: 100, height: 30)),
            .tick,
        ])
        #expect(actions.last == .shutdown)
        #expect(frames.count == 3)
        #expect(report.renderedFrameCount == 3)
        #expect(report.invalidationCount == 3)
        #expect(report.termination == .shutdown(.requested))
        #expect(await backend.flushCount == 3)
        #expect(await backend.shutdownCount == 1)
    }

    @Test("bounded mailbox applies backpressure while control events coalesce")
    func boundedMailbox() async throws {
        let model = RecordingModel()
        let backend = RecordingBackend()
        let runtime = PagerRuntime(
            model: model,
            backend: backend,
            configuration: PagerRuntimeConfiguration(queueCapacity: 1)
        )

        #expect(await runtime.tryEnqueue(.input(.text("first"))) == .accepted)
        #expect(await runtime.tryEnqueue(.tick) == .coalesced)
        #expect(await runtime.tryEnqueue(.resize(PagerSize(width: 80, height: 24))) == .backpressured)

        let blockedSender = Task {
            try await runtime.enqueue(.input(.text("second")))
        }
        await Task.yield()
        #expect(!blockedSender.isCancelled)

        let runTask = Task { await runtime.run() }
        let blockedResult = try await blockedSender.value
        #expect(blockedResult == .accepted)
        await waitUntil { (await model.recordedActions()).count >= 2 }
        await runtime.shutdown()
        let report = await runTask.value

        #expect(report.processedEventCount == 3)
        #expect(await model.recordedActions().prefix(2) == [
            .input(.text("first")),
            .input(.text("second")),
        ])
    }

    @Test("task cancellation wakes the event loop and shuts down the backend")
    func cancellation() async {
        let model = RecordingModel()
        let backend = RecordingBackend()
        let runtime = PagerRuntime(model: model, backend: backend)
        let runTask = Task { await runtime.run() }

        await Task.yield()
        runTask.cancel()
        let report = await runTask.value

        #expect(report.termination == .cancelled)
        #expect(await model.recordedActions().isEmpty)
        #expect(await backend.shutdownCount == 1)
        #expect(await runtime.state == .stopped)
    }

    @Test("explicit cancellation is delivered to the model before termination")
    func explicitCancellation() async {
        let model = RecordingModel()
        let backend = RecordingBackend()
        let runtime = PagerRuntime(model: model, backend: backend)
        let runTask = Task { await runtime.run() }

        await Task.yield()
        await runtime.cancel()
        let report = await runTask.value

        #expect(report.termination == .cancelled)
        #expect(await model.recordedActions() == [.cancel])
        #expect(await backend.shutdownCount == 1)
    }

    @Test("model effects can render directly or invalidate for a snapshot")
    func modelEffects() async throws {
        let model = RecordingModel()
        await model.queueEffects([
            .render(PagerRenderFrame(revision: 7, content: "direct")),
            .invalidate([.model, .input]),
            .invalidate(.tick),
        ])
        let backend = RecordingBackend()
        let runtime = PagerRuntime(model: model, backend: backend)
        let runTask = Task { await runtime.run() }

        _ = try await runtime.enqueue(.input(.text("render")))
        await waitUntil { !(await backend.renderedFrames()).isEmpty }
        await runtime.shutdown()
        let report = await runTask.value
        let frames = await backend.renderedFrames()

        #expect(frames.map(\.content) == ["direct", "frame-1"])
        #expect(report.renderedFrameCount == 2)
        #expect(report.invalidationCount == 2)
    }
}
