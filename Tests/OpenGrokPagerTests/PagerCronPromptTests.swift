// PagerCronPromptTests.swift
//
// The Cron half of the prompt queue at the controller seam: a scheduler fire
// enters through `enqueueCronPrompt` and must drain into a REAL turn through
// the runtime adapter — the single-process port of
// `x.ai/scheduled_task_inject_prompt` → `enqueue_cron_prompt` →
// `maybe_drain_queue` (acp_handler/background.rs:439-509). Driven against
// the real controller with a scripted runtime; asserted on the requests the
// RUNTIME receives (prompt + cron metadata) — never on the enqueue return
// alone, which would pass just as happily if nothing ever drained.
//
// No test here sleeps a scheduler interval: fires are injected calls, and
// every wait is a bounded poll on observable state.

import Foundation
import OpenGrokPager
import OpenGrokPagerMinimal
import OpenGrokTerminalCore
import Testing

@Suite("cron prompts at the controller seam", .serialized)
struct PagerCronPromptTests {
    @Test("an idle controller drains a cron enqueue into a real turn with cron metadata")
    func idleEnqueueDrainsIntoTurn() async throws {
        let runtime = CronRecordingRuntime(sessions: [CronScriptedSession(id: "cron-1")])
        let controller = OpenGrokPagerInteractiveController(
            input: openInputStream(),
            runtime: runtime,
            renderer: CronRecordingRenderer(),
            output: CronSilentOutput()
        )
        let task = Task { try await controller.run(.init(prompt: "", mode: .inline)) }
        #expect(await waitUntil { await controller.state().lifecycle == .editing })

        let outcome = await controller.enqueueCronPrompt(
            prompt: "check deploy status",
            taskID: "task-1",
            humanSchedule: "every 5 minutes"
        )
        #expect(outcome == .enqueued)

        // The fire becomes a REAL turn: the runtime sees the RAW prompt (the
        // user echo paints it) and the scheduler identity in metadata (the
        // adapter frames the wire text and prompt id from these).
        #expect(await waitUntil { await runtime.requests.count == 1 })
        let request = try #require(await runtime.requests.first)
        #expect(request.prompt == "check deploy status")
        #expect(request.metadata[
            OpenGrokPagerInteractiveController.cronTaskIDMetadataKey
        ] == "task-1")
        #expect(request.metadata[
            OpenGrokPagerInteractiveController.cronHumanScheduleMetadataKey
        ] == "every 5 minutes")

        await controller.shutdown()
        _ = try? await task.value
    }

    @Test("a mid-turn fire waits in the queue and drains at turn end")
    func midTurnFireWaitsForTurnEnd() async throws {
        let running = CronScriptedSession(id: "user-turn", completeImmediately: false)
        let runtime = CronRecordingRuntime(sessions: [
            running,
            CronScriptedSession(id: "cron-turn"),
        ])
        let controller = OpenGrokPagerInteractiveController(
            input: openInputStream([
                .paste("work on this"),
                .key(KeyEvent(key: .enter)),
            ]),
            runtime: runtime,
            renderer: CronRecordingRenderer(),
            output: CronSilentOutput()
        )
        let task = Task { try await controller.run(.init(prompt: "", mode: .inline)) }
        #expect(await waitUntil { await runtime.requests.count == 1 })

        // Fire while the user turn is running: queued, not started.
        #expect(await controller.enqueueCronPrompt(
            prompt: "check ci",
            taskID: "task-9",
            humanSchedule: "every 1 hour"
        ) == .enqueued)
        #expect(await runtime.requests.count == 1, "a running turn must not be preempted")

        // The turn completes; the completion arm's drain starts the cron turn
        // (upstream: the busy-agent case leaves the entry queued,
        // acp_handler/tests/scheduled_tasks.rs:150-158).
        await running.finish()
        #expect(await waitUntil { await runtime.requests.count == 2 })
        let cronRequest = try #require(await runtime.requests.last)
        #expect(cronRequest.prompt == "check ci")
        #expect(cronRequest.metadata[
            OpenGrokPagerInteractiveController.cronTaskIDMetadataKey
        ] == "task-9")

        await controller.shutdown()
        _ = try? await task.value
    }

    @Test("a re-fire of a queued task is skipped; a different task queues")
    func queuedTaskDedupes() async throws {
        let running = CronScriptedSession(id: "user-turn", completeImmediately: false)
        let runtime = CronRecordingRuntime(sessions: [
            running,
            CronScriptedSession(id: "cron-a"),
            CronScriptedSession(id: "cron-b"),
        ])
        let controller = OpenGrokPagerInteractiveController(
            input: openInputStream([
                .paste("work on this"),
                .key(KeyEvent(key: .enter)),
            ]),
            runtime: runtime,
            renderer: CronRecordingRenderer(),
            output: CronSilentOutput()
        )
        let task = Task { try await controller.run(.init(prompt: "", mode: .inline)) }
        #expect(await waitUntil { await runtime.requests.count == 1 })

        #expect(await controller.enqueueCronPrompt(
            prompt: "check ci", taskID: "task-1", humanSchedule: "every 5 minutes"
        ) == .enqueued)
        // The de-dup guard (background.rs:488-496): a re-fire of a task that
        // is already queued must not pile up…
        #expect(await controller.enqueueCronPrompt(
            prompt: "check ci", taskID: "task-1", humanSchedule: "every 5 minutes"
        ) == .skippedTaskAlreadyQueued)
        // …while a DIFFERENT task queues alongside it.
        #expect(await controller.enqueueCronPrompt(
            prompt: "watch deploy", taskID: "task-2", humanSchedule: "every 1 hour"
        ) == .enqueued)

        await running.finish()
        #expect(await waitUntil { await runtime.requests.count == 3 })
        let cronPrompts = await runtime.requests.dropFirst().map(\.prompt)
        #expect(cronPrompts == ["check ci", "watch deploy"], "one turn per task, in order")

        await controller.shutdown()
        _ = try? await task.value
    }

    @Test("a re-fire of the RUNNING cron task is skipped, then accepted after it ends")
    func runningTaskDedupes() async throws {
        let cronTurn = CronScriptedSession(id: "cron-run", completeImmediately: false)
        let runtime = CronRecordingRuntime(sessions: [
            cronTurn,
            CronScriptedSession(id: "cron-again"),
        ])
        let controller = OpenGrokPagerInteractiveController(
            input: openInputStream(),
            runtime: runtime,
            renderer: CronRecordingRenderer(),
            output: CronSilentOutput()
        )
        let task = Task { try await controller.run(.init(prompt: "", mode: .inline)) }
        #expect(await waitUntil { await controller.state().lifecycle == .editing })

        #expect(await controller.enqueueCronPrompt(
            prompt: "check ci", taskID: "task-1", humanSchedule: "every 5 minutes"
        ) == .enqueued)
        #expect(await waitUntil { await runtime.requests.count == 1 })

        // The cron turn is RUNNING its own task: a re-fire is the second
        // de-dup guard (`agent.cron_task_id`, background.rs:483-487).
        #expect(await controller.enqueueCronPrompt(
            prompt: "check ci", taskID: "task-1", humanSchedule: "every 5 minutes"
        ) == .skippedTaskAlreadyRunning)

        // Once the cron turn ends, the same task may fire again.
        await cronTurn.finish()
        #expect(await waitUntil { await controller.enqueueCronPrompt(
            prompt: "check ci", taskID: "task-1", humanSchedule: "every 5 minutes"
        ) == .enqueued })
        #expect(await waitUntil { await runtime.requests.count == 2 })

        await controller.shutdown()
        _ = try? await task.value
    }

    @Test("a cron prompt that looks like a slash command still runs as a prompt")
    func cronTextIsNeverParsedAsCommand() async throws {
        let runtime = CronRecordingRuntime(sessions: [CronScriptedSession(id: "cron-slash")])
        let controller = OpenGrokPagerInteractiveController(
            input: openInputStream(),
            runtime: runtime,
            renderer: CronRecordingRenderer(),
            output: CronSilentOutput()
        )
        let task = Task { try await controller.run(.init(prompt: "", mode: .inline)) }
        #expect(await waitUntil { await controller.state().lifecycle == .editing })

        // Upstream's Cron drain arm never parses commands
        // (app/dispatch/queue.rs:518-560): the stored prompt is model input
        // even when it starts with "/".
        #expect(await controller.enqueueCronPrompt(
            prompt: "/compact then summarize",
            taskID: "task-slash",
            humanSchedule: "every 1 day"
        ) == .enqueued)
        #expect(await waitUntil { await runtime.requests.count == 1 })
        #expect(await runtime.requests.first?.prompt == "/compact then summarize")

        await controller.shutdown()
        _ = try? await task.value
    }
}

// MARK: - Harness

/// Poll `condition` until it holds or the deadline passes — the suite-wide
/// discipline: these controllers run over input streams that never end, so
/// an unbounded await is a hang waiting to happen.
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

/// Yields `events` and stays open, so only shutdown ends the run.
private func openInputStream(_ events: [InputEvent] = []) -> AsyncStream<InputEvent> {
    AsyncStream { continuation in
        for event in events {
            continuation.yield(event)
        }
    }
}

/// A session that either completes immediately or waits for `finish()`, so a
/// test can hold a turn open while fires arrive.
private actor CronScriptedSession: OpenGrokPagerSessionAdapter {
    nonisolated let sessionID: String?
    nonisolated let events: AsyncThrowingStream<OpenGrokPagerEvent, Error>
    private let continuation: AsyncThrowingStream<OpenGrokPagerEvent, Error>.Continuation

    init(id: String, completeImmediately: Bool = true) {
        sessionID = id
        var continuation: AsyncThrowingStream<OpenGrokPagerEvent, Error>.Continuation?
        events = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation!
        if completeImmediately {
            self.continuation.yield(.completed(.init(sessionID: id)))
            self.continuation.finish()
        }
    }

    func finish() {
        continuation.yield(.completed(.init(sessionID: sessionID ?? "")))
        continuation.finish()
    }

    func cancel() {
        continuation.yield(.cancelled)
        continuation.finish()
    }

    func close() {
        continuation.finish()
    }
}

/// Records every request the controller hands the runtime — the seam a cron
/// fire must reach as a real turn.
private actor CronRecordingRuntime: OpenGrokPagerRuntimeAdapter {
    private var sessions: [CronScriptedSession]
    private(set) var requests: [OpenGrokPagerRequest] = []

    init(sessions: [CronScriptedSession]) {
        self.sessions = sessions
    }

    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        requests.append(request)
        guard !sessions.isEmpty else { throw CronHarnessError.noSession }
        return sessions.removeFirst()
    }
}

private actor CronRecordingRenderer: OpenGrokPagerInteractiveRenderAdapter {
    private(set) var events: [OpenGrokPagerInteractiveEvent] = []
    func begin() {}
    func restoreTerminal() {}
    func render(_ event: OpenGrokPagerInteractiveEvent) {
        events.append(event)
    }
}

private struct CronSilentOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}

private enum CronHarnessError: Error {
    case noSession
}
