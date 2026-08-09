// LiveSchedulerDetachedFireTests.swift
//
// The Detached (loop-subagent) fire path at its seams:
//
//   * the host-level fire-mode matrix against the injected clock and the
//     spawn seam — `foreground`, `background_loops`, the running-previous
//     skip, the chain anchor/restart bookkeeping, and the failed-dispatch
//     Cron fallback, each an arm of upstream's `fire_next_task` /
//     `fire_as_loop_subagent` (actor.rs:406-450, 511-733);
//   * one end-to-end fire through the REAL foundation: `scheduler_create`
//     via real executor dispatch, the composition-shaped spawner against the
//     REAL `LiveSubagentHost`, and the evidence read off the coordinator's
//     state, the recorded `lastSubagentId`, and the child's actual sampler
//     request (AGENTS.md §3 — never a composition type).
//
// Determinism: fixed clocks and `fireDue(now:)` everywhere; the only waits
// are bounded polls on a real child's completion (the
// LiveSchedulerFireTests fixture pattern), never a scheduler interval.

import Foundation
import OpenGrokPager
import OpenGrokSamplingTypes
import OpenGrokScheduler
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokTestSupport
import OpenGrokToolsAPI
import Testing
@testable import OpenGrokCLI

// MARK: - Host-level fixtures

private final class DetachedTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Date

    init(_ start: Date) { now = start }

    var current: Date {
        lock.withLock { now }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { now = now.addingTimeInterval(seconds) }
    }
}

private actor DetachedFireCollector {
    private(set) var fires: [LiveSchedulerFire] = []
    func record(_ fire: LiveSchedulerFire) { fires.append(fire) }
}

/// Records the spawn seam's traffic and answers with configured outcomes —
/// the stub sits exactly where the composition's closure over the real
/// subagent host sits, so what the host hands it is what the real seam gets.
private actor LoopSpawnRecorder {
    private(set) var probes: [String] = []
    private(set) var spawns: [LiveSchedulerLoopSpawn] = []
    private var probeAnswer: LiveSchedulerPreviousIteration = .gone
    private var spawnSucceeds = true

    func answerProbes(with answer: LiveSchedulerPreviousIteration) {
        probeAnswer = answer
    }

    func failSpawns() { spawnSucceeds = false }

    func probe(_ id: String) -> LiveSchedulerPreviousIteration {
        probes.append(id)
        return probeAnswer
    }

    func spawn(_ request: LiveSchedulerLoopSpawn) -> Bool {
        spawns.append(request)
        return spawnSucceeds
    }
}

private func spawner(_ recorder: LoopSpawnRecorder) -> LiveSchedulerLoopSpawner {
    LiveSchedulerLoopSpawner(
        probePrevious: { await recorder.probe($0) },
        spawn: { await recorder.spawn($0) }
    )
}

/// A host with both seams installed and no tasks yet, so `fireDue` returns
/// are inspectable per-fire.
private func makeDetachedHost(
    clock: DetachedTestClock,
    backgroundLoopsEnabled: Bool = true,
    recorder: LoopSpawnRecorder,
    collector: DetachedFireCollector
) async -> LiveSchedulerHost {
    let host = LiveSchedulerHost(
        clock: { clock.current },
        backgroundLoopsEnabled: backgroundLoopsEnabled
    )
    await host.setLoopSpawner(spawner(recorder))
    await host.setFireSink { fire in await collector.record(fire) }
    return host
}

// MARK: - Fire-mode selection (actor.rs:414-423)

@Suite("scheduler detached fires: mode selection")
struct LiveSchedulerDetachedModeTests {
    @Test("a background task's fire spawns a loop subagent and records the anchor")
    func detachedFireSpawnsAndRecordsAnchor() async throws {
        let clock = DetachedTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let recorder = LoopSpawnRecorder()
        let collector = DetachedFireCollector()
        let host = await makeDetachedHost(clock: clock, recorder: recorder, collector: collector)

        let task = try await host.createTask(
            intervalSecs: 300,
            prompt: "check deploy status",
            durable: false,
            foreground: false,
            fireImmediately: true
        )
        let fires = await host.fireDue(now: clock.current)

        try #require(fires.count == 1)
        let spawns = await recorder.spawns
        try #require(spawns.count == 1)
        // No probe on a first fire: there is no previous iteration to query.
        #expect(await recorder.probes.isEmpty)
        #expect(fires[0].subagentID == spawns[0].subagentID)
        // The Cron sink stays silent: a Detached fire never injects
        // (notification_bridge.rs:689 gates inject on subagent_id.is_none()).
        #expect(await collector.fires.isEmpty)
        // Request contents: the actor's SubagentRequest fields it decides
        // (actor.rs:637-643, 658-680).
        #expect(spawns[0].taskID == task.id)
        #expect(spawns[0].resumeFrom == nil)
        #expect(spawns[0].description == "loop: check deploy status (every 5 minutes)")
        #expect(spawns[0].framedPrompt == formatLoopIterationPrompt(
            "check deploy status",
            taskID: task.id,
            humanSchedule: "every 5 minutes",
            priorIterationSummary: nil
        ))
        // The anchor landed on the stored task (actor.rs:645-655) — the
        // field `/tasks` renders via ScheduledTaskInfo.
        let stored = try #require(await host.list().first)
        #expect(stored.lastSubagentId == spawns[0].subagentID)
        #expect(stored.iterationsSinceFresh == 1)
        #expect(stored.chainResetPending == false)
        let info = try #require(await host.displayInfos().first)
        #expect(info.lastSubagentId == spawns[0].subagentID)
    }

    @Test("foreground: true keeps the Cron path (actor.rs:417, test :2255-2277)")
    func foregroundTaskKeepsCronPath() async throws {
        let clock = DetachedTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let recorder = LoopSpawnRecorder()
        let collector = DetachedFireCollector()
        let host = await makeDetachedHost(clock: clock, recorder: recorder, collector: collector)

        _ = try await host.createTask(
            intervalSecs: 300,
            prompt: "in-session check",
            durable: false,
            foreground: true,
            fireImmediately: true
        )
        let fires = await host.fireDue(now: clock.current)

        try #require(fires.count == 1)
        #expect(fires[0].subagentID == nil)
        #expect(await recorder.spawns.isEmpty, "foreground fire must not touch the spawn seam")
        #expect(await recorder.probes.isEmpty)
        #expect(await collector.fires == fires)
        let stored = try #require(await host.list().first)
        #expect(stored.lastSubagentId == nil)
    }

    @Test("background_loops=false forces the in-session path (actor.rs:414-417, test :2197)")
    func backgroundLoopsDisabledForcesInSession() async throws {
        let clock = DetachedTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let recorder = LoopSpawnRecorder()
        let collector = DetachedFireCollector()
        let host = await makeDetachedHost(
            clock: clock,
            backgroundLoopsEnabled: false,
            recorder: recorder,
            collector: collector
        )

        _ = try await host.createTask(
            intervalSecs: 300,
            prompt: "legacy path",
            durable: false,
            foreground: false,
            fireImmediately: true
        )
        let fires = await host.fireDue(now: clock.current)

        try #require(fires.count == 1)
        #expect(fires[0].subagentID == nil)
        #expect(await recorder.spawns.isEmpty)
        #expect(await collector.fires == fires)
    }

    @Test("no spawn seam installed falls back to the Cron path (actor.rs:420-423)")
    func missingSpawnerFallsBackToCron() async throws {
        let clock = DetachedTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let collector = DetachedFireCollector()
        let host = LiveSchedulerHost(clock: { clock.current })
        await host.setFireSink { fire in await collector.record(fire) }

        _ = try await host.createTask(
            intervalSecs: 300,
            prompt: "unwired",
            durable: false,
            foreground: false,
            fireImmediately: true
        )
        let fires = await host.fireDue(now: clock.current)
        try #require(fires.count == 1)
        #expect(fires[0].subagentID == nil)
        #expect(await collector.fires == fires)
    }
}

// MARK: - The in-flight guard and chain bookkeeping (actor.rs:511-733)

@Suite("scheduler detached fires: chain anchor and skips")
struct LiveSchedulerDetachedChainTests {
    /// Fire once to seed an anchor, returning (host fixtures, first spawn).
    private func seededHost(
        clock: DetachedTestClock
    ) async throws -> (LiveSchedulerHost, LoopSpawnRecorder, DetachedFireCollector, LiveSchedulerLoopSpawn) {
        let recorder = LoopSpawnRecorder()
        let collector = DetachedFireCollector()
        let host = await makeDetachedHost(clock: clock, recorder: recorder, collector: collector)
        _ = try await host.createTask(
            intervalSecs: 300,
            prompt: "check ci",
            durable: false,
            foreground: false,
            fireImmediately: true
        )
        _ = await host.fireDue(now: clock.current)
        let first = try #require(await recorder.spawns.first)
        return (host, recorder, collector, first)
    }

    @Test("a still-running previous iteration skips the fire but consumes the interval")
    func previousIterationRunningSkips() async throws {
        let clock = DetachedTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let (host, recorder, collector, first) = try await seededHost(clock: clock)

        clock.advance(by: 300)
        await recorder.answerProbes(with: .running)
        let fires = await host.fireDue(now: clock.current)

        // Skipped (actor.rs:568-580): nothing spawned, nothing injected,
        // the anchor untouched.
        #expect(fires.isEmpty)
        #expect(await recorder.spawns.count == 1)
        #expect(await recorder.probes == [first.subagentID])
        #expect(await collector.fires.isEmpty)
        let stored = try #require(await host.list().first)
        #expect(stored.lastSubagentId == first.subagentID)
        // The cadence advanced BEFORE the skip (actor.rs:406-408): the same
        // instant selects nothing more — the interval is consumed.
        #expect(await host.fireDue(now: clock.current).isEmpty)
    }

    @Test("an unanswerable probe skips rather than risking a double execution")
    func unknownProbeSkips() async throws {
        let clock = DetachedTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let (host, recorder, collector, _) = try await seededHost(clock: clock)

        clock.advance(by: 300)
        await recorder.answerProbes(with: .unknown)
        let fires = await host.fireDue(now: clock.current)

        // Upstream's channel-closed / query-timeout arms (actor.rs:538-563).
        #expect(fires.isEmpty)
        #expect(await recorder.spawns.count == 1)
        #expect(await collector.fires.isEmpty)
    }

    @Test("a completed previous iteration resumes the chain from its anchor")
    func chainResumesFromAnchor() async throws {
        let clock = DetachedTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let (host, recorder, _, first) = try await seededHost(clock: clock)

        clock.advance(by: 300)
        await recorder.answerProbes(with: .completed(output: "ci was green"))
        let fires = await host.fireDue(now: clock.current)

        try #require(fires.count == 1)
        let second = try #require(await recorder.spawns.last)
        #expect(second.resumeFrom == first.subagentID, "the chain resumes (actor.rs:633-635)")
        #expect(
            !second.framedPrompt.contains("previous iteration"),
            "a resumed chain carries no summary — the transcript is the context"
        )
        let stored = try #require(await host.list().first)
        #expect(stored.lastSubagentId == second.subagentID)
        #expect(stored.iterationsSinceFresh == 2)
    }

    @Test("a failed or vanished previous iteration starts a fresh chain, no summary")
    func goneAnchorStartsFresh() async throws {
        let clock = DetachedTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let (host, recorder, _, _) = try await seededHost(clock: clock)

        clock.advance(by: 300)
        await recorder.answerProbes(with: .gone)
        _ = await host.fireDue(now: clock.current)

        let second = try #require(await recorder.spawns.last)
        #expect(second.resumeFrom == nil, "an unusable anchor cannot be resumed (actor.rs:625-632)")
        #expect(!second.framedPrompt.contains("previous iteration"))
        let stored = try #require(await host.list().first)
        #expect(stored.iterationsSinceFresh == 1)
    }

    @Test("after 10 iterations the chain restarts fresh, seeded with a 600-char summary")
    func chainRestartsAfterTenIterations() async throws {
        let clock = DetachedTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let (host, recorder, _, _) = try await seededHost(clock: clock)

        // Iterations 2...10 resume the chain.
        await recorder.answerProbes(with: .completed(output: String(repeating: "x", count: 700)))
        for _ in 2...10 {
            clock.advance(by: 300)
            _ = await host.fireDue(now: clock.current)
        }
        let afterTen = try #require(await host.list().first)
        #expect(afterTen.iterationsSinceFresh == 10)

        // The 11th fire: `iterations_since_fresh >= LOOP_FRESH_CHAIN_EVERY`
        // → fresh chain with the previous output truncated to 600 chars
        // (actor.rs:624-632).
        clock.advance(by: 300)
        _ = await host.fireDue(now: clock.current)
        let eleventh = try #require(await recorder.spawns.last)
        #expect(eleventh.resumeFrom == nil)
        #expect(eleventh.framedPrompt.contains(
            "\nYour previous iteration ended with:\n"
                + String(repeating: "x", count: 600) + "\u{2026}\n"
        ))
        let restarted = try #require(await host.list().first)
        #expect(restarted.iterationsSinceFresh == 1)
    }

    @Test("a prompt update forces the next fire onto a fresh chain")
    func promptUpdateForcesFreshChain() async throws {
        let clock = DetachedTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let (host, recorder, _, first) = try await seededHost(clock: clock)

        let created = try #require(await host.list().first)
        _ = try await host.updateTask(id: created.id, prompt: "check ci twice", intervalSecs: nil)
        let updated = try #require(await host.list().first)
        #expect(updated.chainResetPending == true)

        clock.advance(by: 300)
        // The old iteration completed — but the pending reset wins
        // (actor.rs:626-627): fresh chain, no summary, no resume.
        await recorder.answerProbes(with: .completed(output: "old chain output"))
        _ = await host.fireDue(now: clock.current)
        let second = try #require(await recorder.spawns.last)
        #expect(second.resumeFrom == nil)
        #expect(!second.framedPrompt.contains("previous iteration"))
        #expect(second.subagentID != first.subagentID)
        let stored = try #require(await host.list().first)
        #expect(stored.chainResetPending == false)
        #expect(stored.iterationsSinceFresh == 1)
    }

    @Test("a failed spawn dispatch restores the pre-fire anchor and falls back to Cron")
    func spawnFailureFallsBackAndRestores() async throws {
        let clock = DetachedTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let (host, recorder, collector, first) = try await seededHost(clock: clock)

        clock.advance(by: 300)
        await recorder.answerProbes(with: .completed(output: "done"))
        await recorder.failSpawns()
        let fires = await host.fireDue(now: clock.current)

        // The Foreground fallback (actor.rs:690-702): the fire injects
        // in-session instead, and the FULL pre-fire snapshot is restored.
        try #require(fires.count == 1)
        #expect(fires[0].subagentID == nil)
        #expect(await collector.fires == fires)
        let stored = try #require(await host.list().first)
        #expect(stored.lastSubagentId == first.subagentID)
        #expect(stored.iterationsSinceFresh == 1)
    }

    @Test("clearChainAnchor drops the anchor a failed iteration left behind")
    func clearChainAnchorDropsFailedIteration() async throws {
        let clock = DetachedTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let (host, recorder, _, first) = try await seededHost(clock: clock)

        // A non-matching id is a no-op (the task's anchor already moved on,
        // actor.rs:722-726).
        await host.clearChainAnchor(spawnedSubagentID: "someone-else")
        let untouched = try #require(await host.list().first)
        #expect(untouched.lastSubagentId == first.subagentID)

        await host.clearChainAnchor(spawnedSubagentID: first.subagentID)
        let stored = try #require(await host.list().first)
        #expect(stored.lastSubagentId == nil)
        #expect(stored.iterationsSinceFresh == 0)
        _ = recorder
    }
}

// MARK: - Framing pins (reminders/mod.rs:63-83, actor.rs:46-52, 640-643)

@Suite("loop iteration framing")
struct LoopIterationFramingTests {
    @Test("format_loop_iteration_prompt, byte-exact (reminders tests :160-181)")
    func loopIterationPromptPins() {
        let out = formatLoopIterationPrompt(
            "check ci",
            taskID: "task-9",
            humanSchedule: "every 5 minutes",
            priorIterationSummary: nil
        )
        #expect(out == "<system-reminder>\n"
            + "Scheduled task task-9 (every 5 minutes). Earlier iterations, if any, appear above.\n"
            + "Run the task below. End with a short status: what changed or needs attention. "
            + "The status is relayed to the main agent.\n"
            + "</system-reminder>\n"
            + "\n"
            + "check ci")

        let withPrior = formatLoopIterationPrompt(
            "check ci",
            taskID: "task-9",
            humanSchedule: "every 5 minutes",
            priorIterationSummary: "ci was green"
        )
        #expect(withPrior.contains("\nYour previous iteration ended with:\nci was green\n"))
        #expect(withPrior.hasSuffix("check ci"))
    }

    @Test("the description truncates the first line at 60 chars (actor.rs:640-643)")
    func loopDescriptionPins() {
        #expect(
            loopIterationDescription(prompt: "short", humanSchedule: "every 1 hour")
                == "loop: short (every 1 hour)"
        )
        // The first LINE only; CRLF is a scalar-level boundary, not a
        // Character-level one (the repo's own recorded trap).
        #expect(
            loopIterationDescription(prompt: "first\r\nsecond", humanSchedule: "every 1 hour")
                == "loop: first (every 1 hour)"
        )
        let long = String(repeating: "a", count: 70)
        #expect(
            loopIterationDescription(prompt: long, humanSchedule: "every 1 hour")
                == "loop: \(String(repeating: "a", count: 60))\u{2026} (every 1 hour)"
        )
    }

    @Test("truncate_chars counts scalars, not bytes (actor.rs:46-52)")
    func truncateCharsPins() {
        #expect(truncateChars("abc", maxChars: 3) == "abc")
        #expect(truncateChars("abcd", maxChars: 3) == "abc\u{2026}")
        // 3-byte CJK scalars: 4 scalars is 12 bytes, but only the COUNT of
        // scalars matters.
        let cjk = String(repeating: "\u{4E16}", count: 4)
        #expect(truncateChars(cjk, maxChars: 4) == cjk)
        #expect(truncateChars(cjk + "x", maxChars: 4)
            == String(repeating: "\u{4E16}", count: 4) + "\u{2026}")
    }

    @Test("/loop injects the Detached instruction when background_loops resolves true")
    func loopCommandDetachedInstruction() {
        guard case .schedule(let instruction, _) = LiveLoopCommand.dispatch(
            rawArgumentTail: "5m check deploy status",
            fireMode: .detached
        ) else {
            Issue.record("expected a schedule dispatch")
            return
        }
        #expect(instruction == loopScheduleInstruction("5m check deploy status", mode: .detached))
        #expect(instruction.contains("detached background subagent"))

        guard case .schedule(let inSession, _) = LiveLoopCommand.dispatch(
            rawArgumentTail: "5m check deploy status",
            fireMode: .inSession
        ) else {
            Issue.record("expected a schedule dispatch")
            return
        }
        #expect(inSession == loopScheduleInstruction("5m check deploy status", mode: .inSession))
        #expect(inSession.contains("new turn in this conversation"))
    }
}

// MARK: - End to end: a Detached fire dispatches a REAL subagent

private struct DetachedFireFixture {
    let home: URL
    let workspace: URL
    let server: MockInferenceServer
    let environment: [String: String]

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-detached-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        server = try MockInferenceServer()
        try """
        [endpoints]
        xai_api_base_url = "\(server.url)"
        """.write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
            "XAI_API_KEY": "test-xai-key",
        ]
    }

    func dispose() {
        server.stop()
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    func launchOptions() throws -> CLIExecutionOptions {
        let command = try CLICommandParser.parseOrThrow(
            ["headless", "--prompt", "hello", "--cwd", workspace.path, "--model", "grok-4.5"]
        )
        guard case .launch(let options) = command else {
            throw CLIApplicationError.failed("fixture did not parse to a launch")
        }
        return options
    }

    func context() -> CLIApplicationContext {
        CLIApplicationContext(
            environment: environment,
            streams: CLIStreams(out: { _ in }, err: { _ in }),
            control: .never
        )
    }
}

/// Records every agent-turn request; answers "done" with no tool calls.
private actor DetachedSamplerStore {
    private(set) var agentRequests: [OpenGrokLiveSamplingRequest] = []

    func next(_ request: OpenGrokLiveSamplingRequest) -> OpenGrokLiveSamplingResponse {
        if request.tools.isEmpty || request.turnID.hasPrefix("compaction-") {
            return OpenGrokLiveSamplingResponse(output: "compacted summary")
        }
        agentRequests.append(request)
        return OpenGrokLiveSamplingResponse(output: "done")
    }
}

private func waitUntil(
    seconds: Double = 15,
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

@Suite("scheduler detached fire: real subagent end to end", .serialized)
struct LiveSchedulerDetachedFireTests {
    @Test("a due background task's fire runs a REAL loop subagent and records its id")
    func detachedFireDispatchesRealSubagent() async throws {
        let fixture = try DetachedFireFixture()
        defer { fixture.dispose() }
        let store = DetachedSamplerStore()
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in OpenGrokLiveSampler { request, _ in await store.next(request) } }
        )
        let foundation = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: fixture.launchOptions(),
            context: fixture.context(),
            dependencies: dependencies,
            interactiveSurfaceAvailable: true
        )
        let schedulerHost = try #require(foundation.toolExecutor.schedulerHost)
        let subagentHost = try #require(
            foundation.toolExecutor.subagentHost,
            "the fixture's interactive foundation must carry the spawn surface"
        )
        // The fixture writes no [scheduler] table and no env override, so
        // the session resolves upstream's default: background loops ON.
        #expect(foundation.schedulerBackgroundLoops == true)
        // The monitor tool is advertised on the same interactive foundation
        // (host present + terminal surface + no profile filter).
        #expect(foundation.toolExecutor.tools.contains { $0.name == "monitor" })

        // 1. `scheduler_create` through REAL dispatch, default foreground
        //    (false) so the fire resolves Detached, `fire_immediately` so it
        //    is due at creation — no wall-clock interval.
        let created = await foundation.toolExecutor.invoke(
            sessionID: foundation.sessionID,
            workingDirectory: foundation.cwd,
            call: ToolCall(
                id: "sched-detached-e2e",
                name: "scheduler_create",
                arguments: #"{"interval":"5m","prompt":"check deploy status","fire_immediately":true}"#
            )
        )
        guard case .success = created else {
            Issue.record("scheduler_create failed through live dispatch: \(created)")
            return
        }
        let taskID = try #require(await schedulerHost.list().first).id

        // 2. The composition-shaped seams: the spawner drives the REAL
        //    subagent host, the Cron sink records what must stay silent.
        let cronFires = DetachedFireCollector()
        await schedulerHost.setLoopSpawner(LiveSchedulerLoopSpawner(
            probePrevious: { [weak subagentHost] subagentID in
                guard let subagentHost else { return .unknown }
                let active = await subagentHost.coordinator.listActive(
                    parentSessionID: subagentHost.context.sessionID
                )
                if active.contains(where: { $0.request.id == subagentID }) {
                    return .running
                }
                guard let completed = await subagentHost.coordinator.listCompleted()
                    .first(where: { $0.request.id == subagentID }),
                    completed.state == "completed",
                    let result = completed.result
                else { return .gone }
                return .completed(output: result.output)
            },
            spawn: { [weak subagentHost] request in
                guard let subagentHost else { return false }
                // Qualified: OpenGrokTestSupport also exports a JSONValue.
                var arguments: [String: OpenGrokShared.JSONValue] = [
                    "prompt": .string(request.framedPrompt),
                    "description": .string(request.description),
                    "subagent_type": .string("general-purpose"),
                    "background": .bool(true),
                    "task_id": .string(request.subagentID),
                ]
                if let resumeFrom = request.resumeFrom {
                    arguments["resume_from"] = .string(resumeFrom)
                }
                switch await subagentHost.spawn(
                    args: .object(arguments),
                    toolCallID: "scheduler-fire-\(request.subagentID)"
                ) {
                case .success: return true
                case .failure: return false
                }
            }
        ))
        // 3. Installing the sink delivers the due fire (the wiring-grace
        //    path) — the deterministic trigger.
        await schedulerHost.setFireSink { fire in await cronFires.record(fire) }

        // 4. The anchor landed on the stored task, and it names a child the
        //    REAL coordinator owns.
        let firedTask = try #require(await schedulerHost.list().first)
        let anchor = try #require(
            firedTask.lastSubagentId,
            "a Detached fire must record lastSubagentId"
        )
        #expect(await cronFires.fires.isEmpty, "a Detached fire must not inject a Cron prompt")

        // 5. The child is real: it completes through the canned sampler and
        //    is queryable through the host's own snapshot seam.
        #expect(await waitUntil {
            await subagentHost.subagentSnapshot(id: anchor)?.completed == true
        }, "the loop subagent must run to completion on the real coordinator")
        let snapshot = try #require(await subagentHost.subagentSnapshot(id: anchor))
        #expect(snapshot.status == "completed")
        #expect(snapshot.subagentType == "general-purpose")
        #expect(snapshot.description == "loop: check deploy status (every 5 minutes)")

        // 6. Wire evidence: the child's sampler request ends with the FRAMED
        //    loop-iteration prompt — what the model actually saw.
        let framed = formatLoopIterationPrompt(
            "check deploy status",
            taskID: taskID,
            humanSchedule: "every 5 minutes",
            priorIterationSummary: nil
        )
        let childRequest = try #require(await store.agentRequests.first)
        let lastItem = try #require(childRequest.items.last)
        guard case .user(let user) = lastItem else {
            Issue.record("the child's last item must be its user prompt, got \(lastItem)")
            return
        }
        #expect(user.content == [.text(text: framed)])

        await foundation.toolExecutor.shutdown()
    }
}
