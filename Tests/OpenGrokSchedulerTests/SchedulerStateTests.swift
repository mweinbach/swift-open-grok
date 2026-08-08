// SchedulerStateTests.swift
//
// Parity with the in-memory halves of the actor command handlers
// (`actor.rs:770-883`) and the `max_task_limit_enforced` test
// (`actor.rs:1135-…`), against fixed clocks. Every status-returning call is
// asserted at the step it happens — a discarded create/delete/update result
// is exactly how a cap or not-found regression would hide.

import Foundation
import Testing
import OpenGrokScheduler

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

/// Tasks get distinct creation instants so their ids (hex ms timestamps)
/// stay distinct, as they do under upstream's real clock.
private func makeTask(offset: TimeInterval, prompt: String = "task") -> ScheduledTask {
    ScheduledTask(
        intervalSecs: 300, prompt: prompt, recurring: true, durable: false,
        now: t0.addingTimeInterval(offset)
    )
}

@Suite("SchedulerState")
struct SchedulerStateTests {
    // actor.rs:26, actor.rs:780-782, actor.rs:1135 (max_task_limit_enforced):
    // the 50th create succeeds, the 51st is refused and mutates nothing.
    @Test("max task limit enforced")
    func maxTaskLimitEnforced() throws {
        var state = SchedulerState()
        #expect(SchedulerState.maxScheduledTasks == 50)
        for i in 0..<SchedulerState.maxScheduledTasks {
            try state.create(makeTask(offset: TimeInterval(i), prompt: "task \(i)"))
        }
        #expect(state.tasks.count == 50)

        #expect(throws: SchedulerError.taskLimitReached(50)) {
            try state.create(makeTask(offset: 51, prompt: "one too many"))
        }
        #expect(state.tasks.count == 50)
    }

    @Test("create appends and list returns creation order")
    func createAppendsAndListReturns() throws {
        var state = SchedulerState()
        let a = makeTask(offset: 0, prompt: "a")
        let b = makeTask(offset: 1, prompt: "b")
        try state.create(a)
        try state.create(b)
        #expect(state.list() == [a, b])
    }

    // actor.rs:854-856: deleting a missing id replies Ok(false), not an error.
    @Test("delete missing id returns false")
    func deleteMissingReturnsFalse() {
        var state = SchedulerState()
        #expect(state.delete(id: "nonexistent") == false)
    }

    @Test("delete removes the task and returns true")
    func deleteRemoves() throws {
        var state = SchedulerState()
        let task = makeTask(offset: 0)
        try state.create(task)
        #expect(state.delete(id: task.id) == true)
        #expect(state.list().isEmpty)
        #expect(state.delete(id: task.id) == false)
    }

    // actor.rs:805-808: strict update — unknown id errors, never creates.
    @Test("update unknown id throws task not found")
    func updateUnknownId() {
        var state = SchedulerState()
        #expect(throws: SchedulerError.taskNotFound("nonexistent")) {
            try state.update(id: "nonexistent", prompt: "new prompt", intervalSecs: nil, now: t0)
        }
        #expect(state.tasks.isEmpty)
    }

    // actor.rs:811-819: a CHANGED prompt is a new job — chain reset pending,
    // iteration counter zeroed. The identical prompt is not a change.
    @Test("update with changed prompt sets chain reset pending")
    func updatePromptChange() throws {
        var state = SchedulerState()
        var task = makeTask(offset: 0, prompt: "check deploy")
        task.iterationsSinceFresh = 5
        try state.create(task)

        let unchanged = try state.update(
            id: task.id, prompt: "check deploy", intervalSecs: nil, now: t0
        )
        #expect(!unchanged.chainResetPending)
        #expect(unchanged.iterationsSinceFresh == 5)

        let updated = try state.update(
            id: task.id, prompt: "check rollback", intervalSecs: nil, now: t0
        )
        #expect(updated.prompt == "check rollback")
        #expect(updated.chainResetPending)
        #expect(updated.iterationsSinceFresh == 0)
    }

    // actor.rs:822-827: an interval change keeps the schedule's phase unless
    // the new interval makes the task already overdue — then the anchor
    // resets to now so it does not fire instantly.
    @Test("update interval keeps phase unless overdue, then re-anchors")
    func updateIntervalPhase() throws {
        var state = SchedulerState()
        let task = makeTask(offset: 0)  // created t0, interval 300
        try state.create(task)

        // Growing the interval keeps the anchor: next fire moves out, no
        // lastFiredAt is invented.
        let grown = try state.update(
            id: task.id, prompt: nil, intervalSecs: 600, now: t0.addingTimeInterval(100)
        )
        #expect(grown.lastFiredAt == nil)
        #expect(grown.nextFireAt() == t0.addingTimeInterval(600))

        // Shrinking so the task is already overdue re-anchors at now.
        let now = t0.addingTimeInterval(100)
        let shrunk = try state.update(id: task.id, prompt: nil, intervalSecs: 60, now: now)
        #expect(shrunk.lastFiredAt == now)
        #expect(shrunk.nextFireAt() == now.addingTimeInterval(60))
    }

    @Test("update returns the patched task stored in state")
    func updateReturnsStoredTask() throws {
        var state = SchedulerState()
        let task = makeTask(offset: 0)
        try state.create(task)
        let updated = try state.update(
            id: task.id, prompt: "new", intervalSecs: 900, now: t0
        )
        #expect(state.tasks.first == updated)
        #expect(updated.intervalSecs == 900)
    }
}

@Suite("SchedulerState Codable")
struct SchedulerStateCodableTests {
    // types.rs:295-296: `tasks` carries #[serde(default)] — an empty
    // document and a journal-only document both decode to no tasks.
    @Test("empty and journal-only documents decode to no tasks")
    func emptyDocumentDecodes() throws {
        let empty = try JSONDecoder().decode(SchedulerState.self, from: Data("{}".utf8))
        #expect(empty.tasks.isEmpty)

        let journalOnly = try JSONDecoder().decode(
            SchedulerState.self,
            from: Data(#"{"occurrenceJournal":{"entries":[]}}"#.utf8)
        )
        #expect(journalOnly.tasks.isEmpty)
    }

    @Test("round trip preserves tasks")
    func roundTrip() throws {
        var state = SchedulerState()
        try state.create(ScheduledTask(
            intervalSecs: 300, prompt: "check deploy", recurring: true, durable: false, now: t0
        ))
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SchedulerState.self, from: data)
        #expect(decoded == state)
    }

    // types.rs:305: register_resource!("grok_build", "Scheduler", ...)
    @Test("resource key matches upstream registration")
    func resourceKey() {
        #expect(SchedulerResourceKey.namespace == "grok_build")
        #expect(SchedulerResourceKey.name == "Scheduler")
    }

    // types.rs:230-232
    @Test("loop chaining constants match upstream")
    func loopConstants() {
        #expect(loopFreshChainEvery == 10)
        #expect(loopCompletionOutputCap == 4_000)
    }
}
