// LiveSchedulerPersistenceTests.swift
//
// E23 — scheduler persistence at the live seams (AGENTS.md §3): real
// `resources_state.json` files in isolated `$OPENGROK_HOME`s, mutated
// through the REAL `LiveToolExecutor.invoke` dispatch and reloaded into
// FRESH hosts. Fixed clocks, zero real sleeps; every status-returning call
// asserted at the step it happens.
//
// What this file pins, with the upstream sites:
//  * save-on-create + load-on-construction — `finalize_output`'s post-tool
//    save (registry/types.rs:1789-1792) and `persistence.load` at toolset
//    finalize (registry/types.rs:1140). ALL tasks persist, durable and not:
//    nothing at the pin filters `SchedulerState.tasks` at save or load.
//  * overdue-at-load fires ONCE and re-anchors from now (`fire_next_task`,
//    actor.rs:283-285, 406-408) — never once per missed interval.
//  * the durable-removal barrier: delete persists durably BEFORE
//    acknowledging; a failed write keeps the removal pending, suspends
//    fires (actor.rs:200) and refuses other mutations (actor.rs:773-777,
//    798-802, 846-850) until a retry of the SAME id lands
//    (`durable_delete_retries_persistence_and_reuses_version`,
//    actor.rs:2315-2368).
//  * corrupt/missing state files load fresh and never crash
//    (`ResourcesPersistence::load`, persistence.rs:113-144;
//    `resources_load_returns_false_on_corrupt_json`, persistence.rs:449-458).
//  * the occurrence journal rides the same file: quarantine metadata loads
//    and SURVIVES the port's own saves — the upstream production-loader pin
//    (`production_loader_preserves_tasks_and_quarantine_metadata`,
//    occurrence_journal_tests.rs:260-317).

import Foundation
import OpenGrokSamplingTypes
import OpenGrokScheduler
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import Testing
@testable import OpenGrokCLI

// MARK: - Fixtures

private actor InertShellBackend: ShellProcessBackend {
    func run(_ request: ShellCommandRequest) async throws -> ShellCommandResult {
        ShellCommandResult(combinedOutput: "", stdout: "", exitCode: 0)
    }

    func runBackground(_ request: ShellCommandRequest) async throws -> ShellBackgroundHandle {
        ShellBackgroundHandle(taskID: "bg")
    }

    func getTask(_ taskID: String) async -> ShellTaskSnapshot? { nil }
    func killTask(_ taskID: String) async -> ShellKillOutcome { .notFound }
    func killForegroundCommands() async {}
    func killForegroundCommands(ownerSessionID: String) async {}
    func killAllBackgroundTasks() async {}
    func killAllBackgroundTasks(ownerSessionID: String) async {}
    func warmShell(at cwd: URL) async {}
    func backgroundForegroundCommand(toolCallID: String) async -> Bool { false }
    func waitForCompletion(_ taskID: String, timeout: ShellDuration?) async -> ShellTaskSnapshot? { nil }
    func listTasks() async -> [ShellTaskSnapshot] { [] }
    func shellCWD() async -> URL? { nil }
}

/// Isolated workspace + `$OPENGROK_HOME` with a session directory — the
/// composition's `sessions/<id>/` shape the state file lives in.
private struct PersistenceWorkspace {
    let root: URL
    let grokHome: URL
    let sessionDirectory: URL
    let environment: [String: String]

    init() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-scheduler-persist-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("repo", isDirectory: true)
        let home = base.appendingPathComponent("home", isDirectory: true)
        grokHome = home.appendingPathComponent(".opengrok", isDirectory: true)
        sessionDirectory = grokHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("persist-session", isDirectory: true)
        for directory in [root, home, grokHome] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": grokHome.path,
        ]
    }

    var stateFileURL: URL {
        sessionDirectory.appendingPathComponent("resources_state.json", isDirectory: false)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}

private final class TestClock: @unchecked Sendable {
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

private actor FireCollector {
    private(set) var fires: [LiveSchedulerFire] = []
    func record(_ fire: LiveSchedulerFire) { fires.append(fire) }
}

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

/// Bounded poll for an asynchronous effect — the repo's established await
/// pattern (LiveSchedulerFireTests.swift). Used only where the effect is
/// delivered by the host's own timer task; every deterministic fire in this
/// file goes through `fireDue(now:)` with a fixed clock.
private func poll(
    seconds: TimeInterval = 5,
    until condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

private func makeExecutor(
    _ workspace: PersistenceWorkspace,
    schedulerHost: LiveSchedulerHost?
) async throws -> LiveToolExecutor {
    try await LiveToolExecutor(
        processBackend: InertShellBackend(),
        sessionID: "persist-session",
        workingDirectory: workspace.root,
        toolPolicy: nil,
        telemetryBootstrapContext: .empty,
        fileAccessPolicy: .allowAll,
        environment: workspace.environment,
        schedulerHost: schedulerHost
    )
}

private func schedulerCall(_ name: String, _ arguments: [String: Any]) -> ToolCall {
    ToolCall(
        id: "sched-persist-call",
        name: name,
        arguments: String(
            data: try! JSONSerialization.data(withJSONObject: arguments),
            encoding: .utf8
        )!
    )
}

private func invoke(
    _ executor: LiveToolExecutor,
    _ workspace: PersistenceWorkspace,
    _ call: ToolCall
) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
    await executor.invoke(
        sessionID: "persist-session",
        workingDirectory: workspace.root,
        call: call
    )
}

/// The on-disk document, decoded loosely for shape assertions.
private func readStateDocument(_ workspace: PersistenceWorkspace) throws -> [String: Any] {
    let data = try Data(contentsOf: workspace.stateFileURL)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func persistedTasks(_ document: [String: Any]) throws -> [[String: Any]] {
    let state = try #require(document["state"] as? [String: Any])
    let scheduler = try #require(state["grok_build.Scheduler"] as? [String: Any])
    return try #require(scheduler["tasks"] as? [[String: Any]])
}

// MARK: - Reload through the live seams

@Suite("scheduler persistence: state file and reload", .serialized)
struct LiveSchedulerPersistenceReloadTests {
    @Test("creates persist durable AND non-durable tasks; a fresh host reloads both with phase intact")
    func createsPersistAndReloadRestores() async throws {
        let workspace = PersistenceWorkspace()
        defer { workspace.cleanup() }
        let persistence = try #require(
            LiveSchedulerPersistence.forSessionDirectory(workspace.sessionDirectory)
        )
        let clock = TestClock(t0)
        let host = LiveSchedulerHost(clock: { clock.current }, persistence: persistence)
        let executor = try await makeExecutor(workspace, schedulerHost: host)

        let durable = await invoke(executor, workspace, schedulerCall(
            "scheduler_create",
            ["interval": "5m", "prompt": "durable loop", "durable": true]
        ))
        guard case .success = durable else {
            Issue.record("durable create failed through live dispatch: \(durable)")
            return
        }
        // Distinct creation instant: task ids are millisecond timestamps.
        clock.advance(by: 1)
        let session = await invoke(executor, workspace, schedulerCall(
            "scheduler_create",
            ["interval": "10m", "prompt": "session loop"]
        ))
        guard case .success = session else {
            Issue.record("non-durable create failed through live dispatch: \(session)")
            return
        }
        await executor.shutdown()

        // The file has upstream's resources shape and — upstream's actual
        // rule at the pin, verified across resources.rs/persistence.rs —
        // BOTH tasks, not only the durable one. `durable` gates the removal
        // barriers, never the save filter.
        let tasks = try persistedTasks(try readStateDocument(workspace))
        try #require(tasks.count == 2)
        #expect(tasks[0]["durable"] as? Bool == true)
        #expect(tasks[0]["prompt"] as? String == "durable loop")
        #expect(tasks[1]["durable"] as? Bool == false)
        #expect(tasks[1]["prompt"] as? String == "session loop")

        let originals = await host.list()
        try #require(originals.count == 2)

        // A fresh host on the same session directory — the `--resume`
        // shape — restores both tasks with identical cadence anchors.
        let laterClock = TestClock(t0.addingTimeInterval(120))
        let reloaded = LiveSchedulerHost(
            clock: { laterClock.current }, persistence: persistence
        )
        let restored = await reloaded.list()
        try #require(restored.count == 2)
        for (original, loaded) in zip(originals, restored) {
            #expect(loaded.id == original.id)
            #expect(loaded.prompt == original.prompt)
            #expect(loaded.durable == original.durable)
            #expect(loaded.createdAt == original.createdAt)
            #expect(loaded.lastFiredAt == original.lastFiredAt)
            #expect(loaded.nextFireAt() == original.nextFireAt())
        }

        // The loaded tasks reach the surfaces through the REAL executor:
        // scheduler_list…
        let listExecutor = try await makeExecutor(workspace, schedulerHost: reloaded)
        let listed = await invoke(listExecutor, workspace, schedulerCall("scheduler_list", [:]))
        guard case .success(let listOutput) = listed else {
            Issue.record("scheduler_list failed on the reloaded host: \(listed)")
            return
        }
        #expect(listOutput.promptText.contains(originals[0].id))
        #expect(listOutput.promptText.contains(originals[1].id))
        await listExecutor.shutdown()

        // …and the `/tasks` Scheduled section renders both rows off the
        // same display map.
        let tasksBlock = LivePagerTasksBlock.text(
            workflowRows: [],
            subagents: [],
            tasks: [],
            scheduled: await reloaded.displayInfos()
        )
        #expect(tasksBlock.contains("scheduledloop · every 5 minutes · durable loop"))
        #expect(tasksBlock.contains("scheduledloop · every 10 minutes · session loop"))
    }

    @Test("a task overdue at load fires exactly once and re-anchors from now")
    func overdueAtLoadFiresOnce() async throws {
        let workspace = PersistenceWorkspace()
        defer { workspace.cleanup() }
        let persistence = try #require(
            LiveSchedulerPersistence.forSessionDirectory(workspace.sessionDirectory)
        )
        let seedClock = TestClock(t0)
        let seedHost = LiveSchedulerHost(clock: { seedClock.current }, persistence: persistence)
        let task = try await seedHost.createTask(
            intervalSecs: 60,
            prompt: "overdue loop",
            durable: true,
            foreground: true,
            fireImmediately: false
        )

        // Reload sixty intervals later. Upstream computes a zero delay for
        // an overdue task (actor.rs:266-271) and `fire_next_task` re-anchors
        // `last_fired_at = now` (actor.rs:406-408): ONE catch-up fire, not
        // sixty.
        let now = t0.addingTimeInterval(3_600)
        let clock = TestClock(now)
        let host = LiveSchedulerHost(clock: { clock.current }, persistence: persistence)
        let collector = FireCollector()
        // The fire-sink install is the wired moment (the E18 wiring-grace
        // seam): the held-over fire delivers here, through the same path a
        // live session's startup uses.
        await host.setFireSink { fire in await collector.record(fire) }

        let fires = await collector.fires
        try #require(fires.count == 1)
        #expect(fires[0].taskID == task.id)
        #expect(fires[0].prompt == "overdue loop")
        #expect(fires[0].nextFireAt == RFC3339.string(from: now.addingTimeInterval(60)))
        let restored = await host.list()
        try #require(restored.count == 1)
        #expect(restored[0].lastFiredAt == now)

        // The re-anchored cadence is persisted too: a third host sees the
        // fired anchor, not the stale one.
        let third = LiveSchedulerHost(clock: { clock.current }, persistence: persistence)
        let persisted = await third.list()
        try #require(persisted.count == 1)
        #expect(persisted[0].lastFiredAt == now)
    }
}

// MARK: - Durable-removal barrier

@Suite("scheduler persistence: durable-removal barrier", .serialized)
struct LiveSchedulerRemovalBarrierTests {
    @Test("delete through real dispatch lands on disk before acknowledging; reload cannot resurrect")
    func deleteDoesNotResurrectAcrossReload() async throws {
        let workspace = PersistenceWorkspace()
        defer { workspace.cleanup() }
        let persistence = try #require(
            LiveSchedulerPersistence.forSessionDirectory(workspace.sessionDirectory)
        )
        let clock = TestClock(t0)
        let host = LiveSchedulerHost(clock: { clock.current }, persistence: persistence)
        let executor = try await makeExecutor(workspace, schedulerHost: host)

        let created = await invoke(executor, workspace, schedulerCall(
            "scheduler_create",
            ["interval": "5m", "prompt": "delete me", "durable": true]
        ))
        guard case .success = created else {
            Issue.record("create failed: \(created)")
            return
        }
        let taskID = try #require(await host.list().first).id

        let deleted = await invoke(executor, workspace, schedulerCall(
            "scheduler_delete", ["id": taskID]
        ))
        guard case .success(let output) = deleted else {
            Issue.record("scheduler_delete failed through live dispatch: \(deleted)")
            return
        }
        #expect(output.promptText.contains("\"success\":true"))
        await executor.shutdown()

        // The success reply means the write already committed: the file on
        // disk has no tasks even though no further save ran ("kill" the
        // session here — nothing else flushes).
        let tasks = try persistedTasks(try readStateDocument(workspace))
        #expect(tasks.isEmpty)

        // A fresh session on the same directory does not resurrect it.
        let reloaded = LiveSchedulerHost(clock: { clock.current }, persistence: persistence)
        #expect(await reloaded.list().isEmpty)
    }

    @Test("a failed barrier write keeps the removal pending: fires suspend and mutations refuse until the retry lands")
    func failedBarrierKeepsRemovalPending() async throws {
        let workspace = PersistenceWorkspace()
        defer { workspace.cleanup() }
        let persistence = try #require(
            LiveSchedulerPersistence.forSessionDirectory(workspace.sessionDirectory)
        )
        let clock = TestClock(t0)
        let host = LiveSchedulerHost(clock: { clock.current }, persistence: persistence)
        let doomed = try await host.createTask(
            intervalSecs: 60, prompt: "doomed", durable: true,
            foreground: true, fireImmediately: false
        )
        clock.advance(by: 1)
        let survivor = try await host.createTask(
            intervalSecs: 60, prompt: "survivor", durable: false,
            foreground: true, fireImmediately: false
        )

        // Break the disk under the barrier — upstream's missing-parent
        // arrangement (`durable_delete_retries_persistence_and_reuses_
        // version`, actor.rs:2316-2330).
        try FileManager.default.removeItem(at: workspace.sessionDirectory)

        do {
            _ = try await host.deleteTask(id: doomed.id)
            Issue.record("delete must fail while the barrier write cannot land")
        } catch let error as SchedulerError {
            guard case .persistence = error else {
                Issue.record("expected a persistence error, got \(error)")
                return
            }
            #expect(error.description.hasPrefix("failed to persist scheduler resources: "))
        }
        // The task left the store first (actor.rs:863) — the barrier holds
        // the ACKNOWLEDGEMENT, not the in-memory removal.
        #expect(await host.list().map(\.id) == [survivor.id])

        // Every other mutation is refused while the removal is pending
        // (actor.rs:773-777, 798-802, 846-850), with upstream's display
        // string.
        do {
            _ = try await host.createTask(
                intervalSecs: 60, prompt: "blocked", durable: false,
                foreground: true, fireImmediately: false
            )
            Issue.record("create must be refused while a removal is pending")
        } catch let error as SchedulerError {
            #expect(error == .removalPending(doomed.id))
            #expect(error.description == "scheduler removal for \(doomed.id) is pending")
        }
        do {
            _ = try await host.updateTask(id: survivor.id, prompt: "patched", intervalSecs: nil)
            Issue.record("update must be refused while a removal is pending")
        } catch let error as SchedulerError {
            #expect(error == .removalPending(doomed.id))
        }
        do {
            _ = try await host.deleteTask(id: survivor.id)
            Issue.record("deleting a DIFFERENT id must be refused while a removal is pending")
        } catch let error as SchedulerError {
            #expect(error == .removalPending(doomed.id))
        }

        // Fires are suspended while pending (actor.rs:200): the survivor is
        // due, and nothing fires.
        let collector = FireCollector()
        await host.setFireSink { fire in await collector.record(fire) }
        clock.advance(by: 120)
        #expect(await host.fireDue(now: clock.current).isEmpty)
        #expect(await collector.fires.isEmpty)

        // Repair the disk; retrying the SAME delete completes the barrier
        // (actor.rs:838-845) and unblocks everything: the re-armed timer
        // finds the due survivor and fires it on its own — the suspension
        // lifting IS the observable effect, so this one assertion awaits
        // the timer rather than calling `fireDue` and racing it.
        try FileManager.default.createDirectory(
            at: workspace.sessionDirectory, withIntermediateDirectories: true
        )
        #expect(try await host.deleteTask(id: doomed.id))
        #expect(await poll { await collector.fires.count == 1 })
        #expect(await collector.fires.map(\.taskID) == [survivor.id])

        // The committed file carries the survivor and not the deleted task.
        let tasks = try persistedTasks(try readStateDocument(workspace))
        try #require(tasks.count == 1)
        #expect(tasks[0]["id"] as? String == survivor.id)
    }

    @Test("scheduler_delete surfaces the barrier failure text through real dispatch")
    func deleteBarrierFailureSurfacesThroughDispatch() async throws {
        let workspace = PersistenceWorkspace()
        defer { workspace.cleanup() }
        let persistence = try #require(
            LiveSchedulerPersistence.forSessionDirectory(workspace.sessionDirectory)
        )
        let clock = TestClock(t0)
        let host = LiveSchedulerHost(clock: { clock.current }, persistence: persistence)
        let executor = try await makeExecutor(workspace, schedulerHost: host)
        let task = try await host.createTask(
            intervalSecs: 300, prompt: "stuck", durable: true,
            foreground: true, fireImmediately: false
        )
        try FileManager.default.removeItem(at: workspace.sessionDirectory)

        let result = await invoke(executor, workspace, schedulerCall(
            "scheduler_delete", ["id": task.id]
        ))
        guard case .failure(let error) = result else {
            Issue.record("delete must fail through dispatch while the write cannot land: \(result)")
            return
        }
        // Upstream maps `SchedulerError::Persistence` through
        // `scheduler_tool_error` and the thrown display string is the
        // model-facing text (types.rs:169-170, 188-201).
        #expect(error.description.contains("failed to persist scheduler resources: "))
        await executor.shutdown()
    }
}

// MARK: - Corrupt and missing files

@Suite("scheduler persistence: corrupt and foreign files", .serialized)
struct LiveSchedulerCorruptFileTests {
    @Test("a corrupt state file loads fresh, never crashes, and the next create overwrites it")
    func corruptFileLoadsFresh() async throws {
        let workspace = PersistenceWorkspace()
        defer { workspace.cleanup() }
        let persistence = try #require(
            LiveSchedulerPersistence.forSessionDirectory(workspace.sessionDirectory)
        )
        // `resources_load_returns_false_on_corrupt_json`
        // (persistence.rs:449-458), through the live composition seam.
        try Data("{ this is not valid json }".utf8).write(to: workspace.stateFileURL)

        let clock = TestClock(t0)
        let host = LiveSchedulerHost(clock: { clock.current }, persistence: persistence)
        #expect(await host.list().isEmpty)

        let executor = try await makeExecutor(workspace, schedulerHost: host)
        let listed = await invoke(executor, workspace, schedulerCall("scheduler_list", [:]))
        guard case .success(let output) = listed else {
            Issue.record("scheduler_list must survive a corrupt state file: \(listed)")
            return
        }
        #expect(output.promptText.contains("\"tasks\":[]"))

        let created = await invoke(executor, workspace, schedulerCall(
            "scheduler_create", ["interval": "5m", "prompt": "fresh start"]
        ))
        guard case .success = created else {
            Issue.record("create must succeed over a corrupt file: \(created)")
            return
        }
        await executor.shutdown()
        let tasks = try persistedTasks(try readStateDocument(workspace))
        try #require(tasks.count == 1)
        #expect(tasks[0]["prompt"] as? String == "fresh start")
    }

    @Test("wrong shapes and undecodable scheduler values load fresh")
    func wrongShapesLoadFresh() throws {
        let workspace = PersistenceWorkspace()
        defer { workspace.cleanup() }
        let persistence = try #require(
            LiveSchedulerPersistence.forSessionDirectory(workspace.sessionDirectory)
        )
        // Missing file (persistence.rs:114-117).
        #expect(persistence.load() == nil)
        // Top level not an object-of-objects (`value_to_nested_map`,
        // persistence.rs:215-231).
        for document in [
            #"["array"]"#,
            #"{"state": "foo"}"#,
            #""just a string""#,
        ] {
            try Data(document.utf8).write(to: workspace.stateFileURL)
            #expect(persistence.load() == nil, "document \(document) must load fresh")
        }
        // A scheduler value the strict decoder refuses — upstream's
        // `if let Ok` deserialize_fn skips it (resources.rs:307-314).
        try Data(
            #"{"state":{"grok_build.Scheduler":{"tasks":[{"id":7}]}}}"#.utf8
        ).write(to: workspace.stateFileURL)
        #expect(persistence.load() == nil)
        // Absent scheduler key: other resources present, scheduler fresh.
        try Data(
            #"{"state":{"grok_build.WebCitation":{"counter":7}}}"#.utf8
        ).write(to: workspace.stateFileURL)
        #expect(persistence.load() == nil)
    }

    @Test("upstream's production-loader pin: tasks and quarantine metadata survive the load")
    func productionLoaderPreservesQuarantine() throws {
        let workspace = PersistenceWorkspace()
        defer { workspace.cleanup() }
        let persistence = try #require(
            LiveSchedulerPersistence.forSessionDirectory(workspace.sessionDirectory)
        )
        // The invalid receipt: a RECURRING task inside a one-shot journal
        // entry (occurrence_journal_tests.rs:264-271).
        var recurringTask = ScheduledTask(
            intervalSecs: 300, prompt: "run recurring", recurring: true, durable: true, now: t0
        )
        recurringTask.id = "recurring"
        var badTask = ScheduledTask(
            intervalSecs: 300, prompt: "run bad", recurring: true, durable: true, now: t0
        )
        badTask.id = "bad"
        let generation = "01890f42-7d5c-7c00-8000-000000000001"
        let invalid: [String: Any] = [
            "occurrenceId": "01890f42-7d5c-7c00-8000-00000000001e",
            "task": try JSONSerialization.jsonObject(with: JSONEncoder().encode(badTask)),
            "versions": [
                "fire": ["generation": generation, "revision": 1],
                "removal": ["generation": generation, "revision": 2],
            ],
        ]
        let document: [String: Any] = [
            "state": ["grok_build.Scheduler": [
                "tasks": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(recurringTask))],
                "occurrenceJournal": [invalid],
            ]],
        ]
        try JSONSerialization.data(withJSONObject: document).write(to: workspace.stateFileURL)

        let state = try #require(persistence.load())
        #expect(state.tasks[0].id == "recurring")
        let (taskIds, isGlobalBlock, isOverflowed) = state.occurrenceJournal.quarantineDiagnostics()
        #expect(taskIds == ["bad"])
        #expect(!isGlobalBlock && !isOverflowed)

        // The three malformed journals (occurrence_journal_tests.rs:294-316):
        // each loads with tasks intact and the global block set.
        let malformedJournals: [Any] = [
            ["entries": "bad", "blockAllOneShots": [] as [Any]],
            ["quarantinedTaskIds": ["kept-id", 7]],
            "wrong-shape",
        ]
        var keptTask = ScheduledTask(
            intervalSecs: 300, prompt: "run kept", recurring: true, durable: true, now: t0
        )
        keptTask.id = "kept"
        for journal in malformedJournals {
            let document: [String: Any] = [
                "state": ["grok_build.Scheduler": [
                    "tasks": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(keptTask))],
                    "occurrenceJournal": journal,
                ]],
            ]
            try JSONSerialization.data(withJSONObject: document).write(to: workspace.stateFileURL)
            let state = try #require(persistence.load())
            #expect(state.tasks[0].id == "kept")
            #expect(state.occurrenceJournal.blockAllOneShots)
        }
    }

    @Test("a loaded journal survives the host's own saves — written, preserved, and never consumed")
    func journalPreservedAcrossHostSaves() async throws {
        let workspace = PersistenceWorkspace()
        defer { workspace.cleanup() }
        let persistence = try #require(
            LiveSchedulerPersistence.forSessionDirectory(workspace.sessionDirectory)
        )
        var existing = ScheduledTask(
            intervalSecs: 300, prompt: "run existing", recurring: true, durable: true, now: t0
        )
        existing.id = "existing"
        let document: [String: Any] = [
            "state": ["grok_build.Scheduler": [
                "tasks": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(existing))],
                "occurrenceJournal": ["quarantinedTaskIds": ["quarantined-id"]],
            ]],
        ]
        try JSONSerialization.data(withJSONObject: document).write(to: workspace.stateFileURL)

        let clock = TestClock(t0.addingTimeInterval(10))
        let host = LiveSchedulerHost(clock: { clock.current }, persistence: persistence)
        let created = try await host.createTask(
            intervalSecs: 60, prompt: "new task", durable: false,
            foreground: true, fireImmediately: false
        )
        #expect(created.prompt == "new task")

        // The create's save re-emitted the journal it never read: an unread
        // journal that upstream also writes is parity; dropping it on save
        // would be silent data loss in the shared file format.
        let reread = try readStateDocument(workspace)
        let state = try #require(reread["state"] as? [String: Any])
        let scheduler = try #require(state["grok_build.Scheduler"] as? [String: Any])
        let journal = try #require(scheduler["occurrenceJournal"] as? [String: Any])
        #expect(journal["quarantinedTaskIds"] as? [String] == ["quarantined-id"])
        let tasks = try #require(scheduler["tasks"] as? [[String: Any]])
        #expect(tasks.count == 2)
    }
}
