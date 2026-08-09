// OccurrenceJournalTests.swift
//
// Port of `xai-grok-tools/src/implementations/grok_build/scheduler/
// occurrence_journal_tests.rs` — every upstream test except
// `production_loader_preserves_tasks_and_quarantine_metadata`, which
// exercises the production resources loader and therefore lives with the
// composition's loader in
// `Tests/OpenGrokCLITests/LiveSchedulerPersistenceTests.swift`.
//
// Fixed instants throughout; every status-returning call is asserted at the
// step it happens. JSON fixtures are built through JSONSerialization so the
// decode path under test is the same lenient `decode_json` port production
// state files hit.

import Foundation
import Testing
import OpenGrokScheduler

/// `GENERATION` (`occurrence_journal_tests.rs:6`) — a valid UUIDv7 with the
/// RFC 4122 variant.
private let generation = "01890f42-7d5c-7c00-8000-000000000001"

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

/// `uuid(suffix)` (`occurrence_journal_tests.rs:8-10`).
private func uuid(_ suffix: UInt64) -> UUID {
    UUID(uuidString: String(format: "01890F42-7D5C-7C00-8000-%012llX", suffix))!
}

/// `task(id, recurring, durable)` (`occurrence_journal_tests.rs:12-27`).
private func task(_ id: String, recurring: Bool, durable: Bool) -> ScheduledTask {
    var task = ScheduledTask(
        intervalSecs: 300,
        prompt: "run \(id)",
        recurring: recurring,
        durable: durable,
        now: t0
    )
    task.id = id
    task.foreground = true
    task.expiresAt = nil
    return task
}

private func version(_ generation: String, _ revision: UInt64) -> SchedulerVersion {
    SchedulerVersion(generation: UUID(uuidString: generation)!, revision: revision)
}

/// `versions(revision)` (`occurrence_journal_tests.rs:33-39`).
private func versions(_ revision: UInt64) -> ScheduledOccurrenceVersions {
    try! ScheduledOccurrenceVersions(
        fire: version(generation, revision),
        removal: version(generation, revision + 1)
    )
}

private func taskJSON(_ task: ScheduledTask) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(task))
}

/// `occurrence_json` (`occurrence_journal_tests.rs:41-47`).
private func occurrenceJSON(_ id: String, task: Any, versions: Any) -> [String: Any] {
    ["occurrenceId": id, "task": task, "versions": versions]
}

/// `valid_occurrence_json` (`occurrence_journal_tests.rs:49-58`).
private func validOccurrenceJSON(
    _ idSuffix: UInt64, _ taskID: String, _ revision: UInt64
) throws -> [String: Any] {
    occurrenceJSON(
        uuid(idSuffix).uuidString.lowercased(),
        task: try taskJSON(task(taskID, recurring: false, durable: true)),
        versions: [
            "fire": ["generation": generation, "revision": revision],
            "removal": ["generation": generation, "revision": revision + 1],
        ]
    )
}

/// `state(tasks, journal)` (`occurrence_journal_tests.rs:60-66`): the state
/// document is built as JSON and decoded, so the journal takes the lenient
/// path production files take.
private func makeState(_ tasks: [ScheduledTask], journal: Any) throws -> SchedulerState {
    let document: [String: Any] = [
        "tasks": try tasks.map(taskJSON),
        "occurrenceJournal": journal,
    ]
    let data = try JSONSerialization.data(withJSONObject: document)
    return try JSONDecoder().decode(SchedulerState.self, from: data)
}

/// `prepare` (`occurrence_journal_tests.rs:68-76`).
private func prepare(
    _ state: inout SchedulerState, _ taskID: String, _ revision: UInt64
) throws -> OneShotOccurrence {
    try state.prepareOneShotOccurrence(
        occurrenceID: ScheduledOccurrenceId(uuid(100 + revision)),
        taskID: taskID,
        versions: versions(revision)
    )
}

@Suite("occurrence journal")
struct OccurrenceJournalTests {
    // occurrence_journal_tests.rs:78-112
    @Test("prepare, finish, and mutation failures preserve state")
    func prepareFinishAndMutationFailuresPreserveState() throws {
        var state = SchedulerState(tasks: [
            task("one-shot", recurring: false, durable: true),
            task("second", recurring: false, durable: true),
        ])
        let occurrence = try prepare(&state, "one-shot", 7)
        #expect(occurrence.task.id == "one-shot")
        let finished = try state.finishOneShotRemoval(occurrenceID: occurrence.occurrenceId)
        #expect(finished.occurrenceId == occurrence.occurrenceId)

        let second = try prepare(&state, "second", 1)
        #expect(second.task.id == "second")
        state.tasks.append(task("duplicate", recurring: false, durable: true))
        #expect(throws: OccurrenceJournalError.duplicateTransitionVersion) {
            try state.prepareOneShotOccurrence(
                taskID: "duplicate", versions: versions(1), now: t0
            )
        }

        for invalid in [
            task("recurring", recurring: true, durable: true),
            task("ephemeral", recurring: false, durable: false),
        ] {
            var state = SchedulerState(tasks: [invalid])
            #expect(throws: OccurrenceJournalError.notDurableOneShot(invalid.id)) {
                try state.prepareOneShotOccurrence(
                    taskID: invalid.id, versions: versions(3), now: t0
                )
            }
        }
    }

    // occurrence_journal_tests.rs:114-142
    @Test("validation rejects impossible versions and non-RFC identity")
    func validationRejectsImpossibleVersionsAndNonRFCIdentity() throws {
        // Zero fire revision; a gap; a generation mismatch; a non-RFC4122
        // variant generation.
        let cases: [(String, String, UInt64, UInt64)] = [
            (generation, generation, 0, 1),
            (generation, generation, 1, 3),
            (generation, "01890f42-7d5c-7c00-8000-000000000002", 1, 2),
            ("01890f42-7d5c-7c00-c000-000000000001", generation, 1, 2),
        ]
        for (fireGeneration, removalGeneration, fire, removal) in cases {
            #expect(throws: OccurrenceJournalError.invalidVersions) {
                _ = try ScheduledOccurrenceVersions(
                    fire: version(fireGeneration, fire),
                    removal: version(removalGeneration, removal)
                )
            }
        }

        // An occurrence id with a non-RFC variant fails identity decode and
        // quarantines its task id.
        let invalid = occurrenceJSON(
            "01890f42-7d5c-7c00-c000-000000000001",
            task: try taskJSON(task("bad-id", recurring: false, durable: true)),
            versions: [
                "fire": ["generation": generation, "revision": 1],
                "removal": ["generation": generation, "revision": 2],
            ]
        )
        let state = try makeState([], journal: [invalid])
        let plan = state.reconcileOneShotOccurrences()
        #expect(plan.recoveryRequired)
        #expect(plan.blockedTaskIds.contains("bad-id"))
    }

    // occurrence_journal_tests.rs:144-174
    @Test("exactly fifty round-trips and mutation reports journal full")
    func exactlyFiftyRoundTripsAndMutationReportsJournalFull() throws {
        let entries = try (0..<maxPendingOneShots).map { index in
            try validOccurrenceJSON(
                100 + UInt64(index), "task-\(index)", UInt64(index) * 2 + 1
            )
        }
        var state = try makeState([], journal: entries)
        #expect(state.occurrenceJournal.entries.count == maxPendingOneShots)

        let encoded = try JSONEncoder().encode(state)
        let reloaded = try JSONDecoder().decode(SchedulerState.self, from: encoded)
        #expect(reloaded.occurrenceJournal.entries.count == maxPendingOneShots)

        state.tasks.append(task("new", recurring: false, durable: true))
        #expect(throws: OccurrenceJournalError.journalFull) {
            try state.prepareOneShotOccurrence(taskID: "new", versions: versions(3), now: t0)
        }
    }

    // occurrence_journal_tests.rs:176-213
    @Test("overflow tail suppresses globally and never serializes a fifty-first entry")
    func overflowTailSuppressesGlobally() throws {
        var entries = try (0..<maxPendingOneShots).map { index in
            try validOccurrenceJSON(200 + UInt64(index), "task-\(index)", 1)
        }
        entries.append(try validOccurrenceJSON(999, "tail-task", 3))
        let state = try makeState(
            [
                task("tail-task", recurring: false, durable: true),
                task("other", recurring: false, durable: true),
            ],
            journal: entries
        )

        let plan = state.reconcileOneShotOccurrences()
        #expect(plan.blockAllOneShots && plan.recoveryRequired)
        #expect(!plan.requiresResourcesPersistence)
        #expect(plan.blockedTaskIds.contains("tail-task"))
        #expect(plan.overflowError != nil)

        let encoded = try JSONEncoder().encode(state)
        let object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let journal = try #require(object["occurrenceJournal"] as? [String: Any])
        let serializedEntries = try #require(journal["entries"] as? [Any])
        #expect(serializedEntries.count == maxPendingOneShots)

        var reloaded = try JSONDecoder().decode(SchedulerState.self, from: encoded)
        let reloadedPlan = reloaded.reconcileOneShotOccurrences()
        #expect(reloadedPlan.blockAllOneShots && reloadedPlan.recoveryRequired)
        reloaded.tasks.append(task("new", recurring: false, durable: true))
        let before = reloaded.tasks.count
        #expect(throws: OccurrenceJournalError.recoveryRequired) {
            try reloaded.prepareOneShotOccurrence(taskID: "new", versions: versions(5), now: t0)
        }
        #expect(reloaded.tasks.count == before)
    }

    // occurrence_journal_tests.rs:215-237
    @Test("malformed missing task identity blocks all one-shots across reload")
    func malformedMissingTaskIdentityBlocksAll() throws {
        let malformed = occurrenceJSON(
            uuid(20).uuidString.lowercased(),
            task: ["prompt": "missing id"],
            versions: [
                "fire": ["generation": generation, "revision": 1],
                "removal": ["generation": generation, "revision": 2],
            ]
        )
        let state = try makeState(
            [
                task("due", recurring: false, durable: true),
                task("recurring", recurring: true, durable: true),
            ],
            journal: [malformed]
        )
        let plan = state.reconcileOneShotOccurrences()
        #expect(plan.blockAllOneShots && plan.recoveryRequired)
        #expect(plan.blockedTaskIds.contains("due"))

        let encoded = try JSONEncoder().encode(state)
        let reloaded = try JSONDecoder().decode(SchedulerState.self, from: encoded)
        let reloadedPlan = reloaded.reconcileOneShotOccurrences()
        #expect(reloadedPlan.blockAllOneShots && reloadedPlan.recoveryRequired)
    }

    // occurrence_journal_tests.rs:239-258
    @Test("inconsistent overflow metadata normalizes and round-trips")
    func inconsistentOverflowMetadataNormalizes() throws {
        let current: [String: Any] = [
            "entries": [] as [Any],
            "overflowed": true,
            "blockAllOneShots": false,
        ]
        let state = try makeState(
            [task("due", recurring: false, durable: true)], journal: current
        )
        let plan = state.reconcileOneShotOccurrences()
        #expect(plan.blockAllOneShots && plan.recoveryRequired)

        let encoded = try JSONEncoder().encode(state)
        let object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let journal = try #require(object["occurrenceJournal"] as? [String: Any])
        #expect(journal["blockAllOneShots"] as? Bool == true)
        let reloaded = try JSONDecoder().decode(SchedulerState.self, from: encoded)
        #expect(reloaded.reconcileOneShotOccurrences().recoveryRequired)
    }

    // occurrence_journal_tests.rs:319-329
    @Test("reconciliation exposes only persistence and suppression foundation")
    func reconciliationExposesOnlyFoundation() throws {
        let state = try makeState(
            [task("resurrected", recurring: false, durable: true)],
            journal: [try validOccurrenceJSON(10, "resurrected", 1)]
        )
        let plan = state.reconcileOneShotOccurrences()
        #expect(plan.requiresResourcesPersistence)
        #expect(plan.taskIdsToRemove == ["resurrected"])
        // The plan is pure: the resurrected task is still in the store.
        #expect(state.tasks[0].id == "resurrected")
    }

    // occurrence_journal_tests.rs:331-381
    @Test("conflict receipts produce diagnostics and suppress every task")
    func conflictReceiptsProduceDiagnostics() throws {
        let cases: [([[String: Any]], OneShotJournalConflict)] = [
            (
                [
                    try validOccurrenceJSON(10, "first", 1),
                    try validOccurrenceJSON(10, "second", 3),
                ],
                .occurrenceId
            ),
            (
                [
                    try validOccurrenceJSON(10, "same", 1),
                    try validOccurrenceJSON(11, "same", 3),
                ],
                .taskId
            ),
            (
                [
                    try validOccurrenceJSON(10, "first", 1),
                    try validOccurrenceJSON(11, "second", 1),
                ],
                .transitionVersion
            ),
        ]
        for (entries, expected) in cases {
            let ids = try entries.map { entry -> String in
                let task = try #require(entry["task"] as? [String: Any])
                return try #require(task["id"] as? String)
            }
            var state = try makeState(
                ids.map { task($0, recurring: false, durable: true) },
                journal: entries
            )
            let plan = state.reconcileOneShotOccurrences()
            #expect(plan.recoveryRequired)
            #expect(plan.taskIdsToRemove.isEmpty)
            #expect(plan.conflicts == [expected, expected])
            #expect(ids.allSatisfy { plan.blockedTaskIds.contains($0) })
            #expect(state.tasks.count == ids.count)

            state.tasks.append(task("unrelated", recurring: false, durable: true))
            let before = state.tasks.count
            #expect(throws: OccurrenceJournalError.recoveryRequired) {
                try state.prepareOneShotOccurrence(
                    taskID: "unrelated", versions: versions(9), now: t0
                )
            }
            #expect(state.tasks.count == before)
        }
    }

    // occurrence_journal_tests.rs:383-391
    @Test("empty journal omits the legacy field")
    func emptyJournalOmitsLegacyField() throws {
        let state = SchedulerState(tasks: [task("legacy", recurring: true, durable: true)])
        let encoded = try JSONEncoder().encode(state)
        let object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(object["occurrenceJournal"] == nil)
    }
}
