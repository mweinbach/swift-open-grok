// LiveActiveBackgroundWorkTests.swift
//
// Pure-sequence proofs for the active-background-work event/cache contract.
// No host or renderer wiring — those land in a later composition slice.
//
// Count definition under test matches Rust `TasksPane::running_count`
// (`tasks_pane.rs:1132-1149` @ `650c1db7`): shell (incl. monitor), running
// non-workflow subagents, all scheduled entries, active workflows. IDs keep
// duplicate upsert/remove and unordered delivery from corrupting the count.
//
// `#expect` captures its base immutably, so every mutating `apply` result is
// bound to a local before the macro sees it.

import Foundation
import Testing
@testable import OpenGrokCLI

@Suite("Active background work cache")
struct LiveActiveBackgroundWorkCacheTests {

    @Test("duplicate upsert and remove are idempotent")
    func duplicateUpsertRemove() throws {
        var cache = LiveActiveBackgroundWorkCache()
        let upsert = try #require(LiveActiveBackgroundWorkEvent.upsert(kind: .shell, id: "t1"))
        let remove = try #require(LiveActiveBackgroundWorkEvent.remove(kind: .shell, id: "t1"))

        let firstUpsert = cache.apply(upsert)
        #expect(firstUpsert == true)
        let duplicateUpsert = cache.apply(upsert)
        #expect(duplicateUpsert == false)
        #expect(cache.count == 1)
        #expect(cache.hasActive)

        let firstRemove = cache.apply(remove)
        #expect(firstRemove == true)
        let duplicateRemove = cache.apply(remove)
        #expect(duplicateRemove == false)
        #expect(cache.count == 0)
        #expect(!cache.hasActive)
    }

    @Test("same id under distinct kinds counts separately")
    func sameIDDistinctKinds() throws {
        var cache = LiveActiveBackgroundWorkCache()
        let shell = try #require(LiveActiveBackgroundWorkEvent.upsert(kind: .shell, id: "shared"))
        let subagent = try #require(LiveActiveBackgroundWorkEvent.upsert(kind: .subagent, id: "shared"))
        let scheduled = try #require(LiveActiveBackgroundWorkEvent.upsert(kind: .scheduled, id: "shared"))
        let workflow = try #require(LiveActiveBackgroundWorkEvent.upsert(kind: .workflow, id: "shared"))

        let shellChanged = cache.apply(shell)
        #expect(shellChanged)
        let subagentChanged = cache.apply(subagent)
        #expect(subagentChanged)
        let scheduledChanged = cache.apply(scheduled)
        #expect(scheduledChanged)
        let workflowChanged = cache.apply(workflow)
        #expect(workflowChanged)
        #expect(cache.count == 4)
        #expect(cache.count(of: .shell) == 1)
        #expect(cache.count(of: .subagent) == 1)
        #expect(cache.count(of: .scheduled) == 1)
        #expect(cache.count(of: .workflow) == 1)

        let removeShell = try #require(LiveActiveBackgroundWorkEvent.remove(kind: .shell, id: "shared"))
        let shellRemoved = cache.apply(removeShell)
        #expect(shellRemoved)
        #expect(cache.count == 3)
        #expect(cache.count(of: .shell) == 0)
        #expect(cache.count(of: .subagent) == 1)
    }

    @Test("counts match Rust status-chip kind mix")
    func statusChipCounts() throws {
        var cache = LiveActiveBackgroundWorkCache()
        // Shell kind covers both bash and monitor; emitting monitor as shell
        // is what avoids a double-count if a host ever sees both labels.
        let events: [LiveActiveBackgroundWorkEvent?] = [
            .upsert(kind: .shell, id: "bash-1"),
            .upsert(kind: .shell, id: "monitor-1"),
            .upsert(kind: .subagent, id: "child-1"),
            .upsert(kind: .scheduled, id: "loop-1"),
            .upsert(kind: .scheduled, id: "loop-2"),
            .upsert(kind: .workflow, id: "wf-1"),
        ]
        for event in events {
            let resolved = try #require(event)
            let changed = cache.apply(resolved)
            #expect(changed)
        }

        #expect(cache.count(of: .shell) == 2)
        #expect(cache.count(of: .subagent) == 1)
        #expect(cache.count(of: .scheduled) == 2)
        #expect(cache.count(of: .workflow) == 1)
        #expect(cache.count == 6)
        #expect(cache.hasActive)
    }

    @Test("removeAll clears every kind")
    func removeAllClears() throws {
        var cache = LiveActiveBackgroundWorkCache()
        for kind in LiveActiveBackgroundWorkKind.allCases {
            let event = try #require(LiveActiveBackgroundWorkEvent.upsert(kind: kind, id: "x"))
            let changed = cache.apply(event)
            #expect(changed)
        }
        #expect(cache.count == LiveActiveBackgroundWorkKind.allCases.count)

        cache.removeAll()
        #expect(cache.count == 0)
        #expect(!cache.hasActive)
        for kind in LiveActiveBackgroundWorkKind.allCases {
            #expect(cache.count(of: kind) == 0)
        }
        // Remove after clear stays a no-op.
        let remove = try #require(LiveActiveBackgroundWorkEvent.remove(kind: .shell, id: "x"))
        let changed = cache.apply(remove)
        #expect(changed == false)
    }

    @Test("upsert order across kinds does not change membership")
    func orderIndependence() throws {
        let upserts: [LiveActiveBackgroundWorkEvent] = [
            try #require(LiveActiveBackgroundWorkEvent.upsert(kind: .shell, id: "a")),
            try #require(LiveActiveBackgroundWorkEvent.upsert(kind: .subagent, id: "b")),
            try #require(LiveActiveBackgroundWorkEvent.upsert(kind: .scheduled, id: "c")),
            try #require(LiveActiveBackgroundWorkEvent.upsert(kind: .workflow, id: "d")),
        ]

        var forward = LiveActiveBackgroundWorkCache()
        for event in upserts {
            let changed = forward.apply(event)
            #expect(changed)
        }

        var reverse = LiveActiveBackgroundWorkCache()
        for event in upserts.reversed() {
            let changed = reverse.apply(event)
            #expect(changed)
        }

        #expect(forward == reverse)
        #expect(forward.count == 4)

        // Interleaved removes of distinct keys are also commutative.
        let removes: [LiveActiveBackgroundWorkEvent] = [
            try #require(LiveActiveBackgroundWorkEvent.remove(kind: .shell, id: "a")),
            try #require(LiveActiveBackgroundWorkEvent.remove(kind: .workflow, id: "d")),
        ]
        var afterForwardRemoves = forward
        for event in removes {
            let changed = afterForwardRemoves.apply(event)
            #expect(changed)
        }
        var afterReverseRemoves = reverse
        for event in removes.reversed() {
            let changed = afterReverseRemoves.apply(event)
            #expect(changed)
        }
        #expect(afterForwardRemoves == afterReverseRemoves)
        #expect(afterForwardRemoves.count == 2)
        #expect(afterForwardRemoves.count(of: .subagent) == 1)
        #expect(afterForwardRemoves.count(of: .scheduled) == 1)
    }

    @Test("concurrent-looking delivery is a pure event sequence")
    func concurrentEventReplayAsSequence() throws {
        // Simulate unordered host completions arriving as an interleaved
        // list — the renderer applies them serially under its actor.
        let burst: [LiveActiveBackgroundWorkEvent] = [
            try #require(LiveActiveBackgroundWorkEvent.upsert(kind: .shell, id: "s1")),
            try #require(LiveActiveBackgroundWorkEvent.upsert(kind: .shell, id: "s2")),
            try #require(LiveActiveBackgroundWorkEvent.upsert(kind: .subagent, id: "sa1")),
            try #require(LiveActiveBackgroundWorkEvent.remove(kind: .shell, id: "s1")),
            try #require(LiveActiveBackgroundWorkEvent.upsert(kind: .shell, id: "s1")),
            try #require(LiveActiveBackgroundWorkEvent.remove(kind: .shell, id: "s1")),
            try #require(LiveActiveBackgroundWorkEvent.remove(kind: .shell, id: "s1")),
            try #require(LiveActiveBackgroundWorkEvent.remove(kind: .subagent, id: "sa1")),
            try #require(LiveActiveBackgroundWorkEvent.upsert(kind: .scheduled, id: "loop")),
            try #require(LiveActiveBackgroundWorkEvent.upsert(kind: .workflow, id: "wf")),
            try #require(LiveActiveBackgroundWorkEvent.remove(kind: .workflow, id: "wf")),
        ]

        var cache = LiveActiveBackgroundWorkCache()
        var changeFlags: [Bool] = []
        for event in burst {
            let changed = cache.apply(event)
            changeFlags.append(changed)
        }

        #expect(changeFlags == [
            true,  // s1 upsert
            true,  // s2 upsert
            true,  // sa1 upsert
            true,  // s1 remove
            true,  // s1 upsert again
            true,  // s1 remove
            false, // duplicate s1 remove
            true,  // sa1 remove
            true,  // loop upsert
            true,  // wf upsert
            true,  // wf remove
        ])
        #expect(cache.count == 2)
        #expect(cache.count(of: .shell) == 1) // s2
        #expect(cache.count(of: .scheduled) == 1)
        #expect(cache.count(of: .subagent) == 0)
        #expect(cache.count(of: .workflow) == 0)
        #expect(cache.hasActive)
    }

    @Test("empty ids are typed false and never counted")
    func emptyIDsIgnored() {
        #expect(LiveActiveBackgroundWorkKey(kind: .shell, id: "") == nil)
        #expect(LiveActiveBackgroundWorkEvent.upsert(kind: .shell, id: "") == nil)
        #expect(LiveActiveBackgroundWorkEvent.remove(kind: .subagent, id: "") == nil)

        // `let`: blank factories never produce an event, so nothing mutates.
        let cache = LiveActiveBackgroundWorkCache()
        #expect(cache.count == 0)
        #expect(!cache.hasActive)
    }

    @Test("replace swaps scheduled provisional→durable without transient 0/2")
    func replaceScheduledProvisionalWithDurable() throws {
        var cache = LiveActiveBackgroundWorkCache()
        // Other kinds must survive a scheduled replace.
        let shell = try #require(LiveActiveBackgroundWorkEvent.upsert(kind: .shell, id: "bash"))
        let shellChanged = cache.apply(shell)
        #expect(shellChanged)

        let provisional = try #require(
            LiveActiveBackgroundWorkEvent.upsert(kind: .scheduled, id: "prov-1")
        )
        let provisionalChanged = cache.apply(provisional)
        #expect(provisionalChanged)
        #expect(cache.count(of: .scheduled) == 1)
        #expect(cache.count == 2)

        // Atomic swap: one mutation, still exactly one scheduled id.
        let durable = LiveActiveBackgroundWorkEvent.replacing(
            kind: .scheduled,
            ids: ["durable-1"]
        )
        let replaced = cache.apply(durable)
        #expect(replaced)
        #expect(cache.count(of: .scheduled) == 1)
        #expect(cache.count == 2)
        #expect(cache.count(of: .shell) == 1)
        #expect(cache.hasActive)

        // Removing the old provisional id is a no-op after replace.
        let removeProvisional = try #require(
            LiveActiveBackgroundWorkEvent.remove(kind: .scheduled, id: "prov-1")
        )
        let removeChanged = cache.apply(removeProvisional)
        #expect(removeChanged == false)
        #expect(cache.count(of: .scheduled) == 1)
    }

    @Test("replace with the same sanitized set is idempotent")
    func replaceSameSetIdempotent() {
        var cache = LiveActiveBackgroundWorkCache()
        let first = LiveActiveBackgroundWorkEvent.replacing(
            kind: .scheduled,
            ids: ["loop-a", "loop-b"]
        )
        let firstChanged = cache.apply(first)
        #expect(firstChanged)
        #expect(cache.count(of: .scheduled) == 2)

        let again = LiveActiveBackgroundWorkEvent.replacing(
            kind: .scheduled,
            ids: ["loop-b", "loop-a"]
        )
        let againChanged = cache.apply(again)
        #expect(againChanged == false)
        #expect(cache.count(of: .scheduled) == 2)
        #expect(cache.count == 2)
    }

    @Test("empty replace clears only that kind")
    func emptyReplaceClearsOnlyKind() throws {
        var cache = LiveActiveBackgroundWorkCache()
        for kind in LiveActiveBackgroundWorkKind.allCases {
            let event = try #require(LiveActiveBackgroundWorkEvent.upsert(kind: kind, id: "x"))
            let changed = cache.apply(event)
            #expect(changed)
        }
        #expect(cache.count == LiveActiveBackgroundWorkKind.allCases.count)

        let clearScheduled = LiveActiveBackgroundWorkEvent.replacing(
            kind: .scheduled,
            ids: []
        )
        let cleared = cache.apply(clearScheduled)
        #expect(cleared)
        #expect(cache.count(of: .scheduled) == 0)
        #expect(cache.count(of: .shell) == 1)
        #expect(cache.count(of: .subagent) == 1)
        #expect(cache.count(of: .workflow) == 1)
        #expect(cache.count == 3)

        let clearAgain = cache.apply(clearScheduled)
        #expect(clearAgain == false)
    }

    @Test("replace factory trims and ignores blank ids")
    func replaceBlankIDsIgnored() {
        var cache = LiveActiveBackgroundWorkCache()
        let event = LiveActiveBackgroundWorkEvent.replacing(
            kind: .scheduled,
            ids: ["", "  ", "\t", "durable-1", "  durable-1  ", "durable-2"]
        )
        // Factory sanitizes before the case is built — blanks never land.
        #expect(event == .replace(kind: .scheduled, ids: ["durable-1", "durable-2"]))

        let changed = cache.apply(event)
        #expect(changed)
        #expect(cache.count(of: .scheduled) == 2)

        // Direct case with blanks is still sanitized on apply.
        let dirty = LiveActiveBackgroundWorkEvent.replace(
            kind: .scheduled,
            ids: ["durable-1", "", "durable-2", "   "]
        )
        let dirtyChanged = cache.apply(dirty)
        #expect(dirtyChanged == false)
        #expect(cache.count(of: .scheduled) == 2)
    }

    @Test("sink typealias is awaitable from a host-shaped optional hold")
    func sinkOptionalHold() async {
        // Hosts hold `LiveActiveBackgroundWorkSink?` and await without
        // importing the renderer; blank factory results stay typed false.
        let box = CacheBox()
        let held: LiveActiveBackgroundWorkSink? = { event in
            box.apply(event)
        }
        if let event = LiveActiveBackgroundWorkEvent.upsert(kind: .shell, id: "from-host") {
            await held?(event)
        }
        #expect(LiveActiveBackgroundWorkEvent.upsert(kind: .shell, id: "") == nil)
        #expect(box.cache.count == 1)
        #expect(box.cache.hasActive)
    }
}

/// Mutable box so an async sink closure can own cache state without capturing
/// an inout binding (illegal across `@Sendable` async closures).
private final class CacheBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _cache = LiveActiveBackgroundWorkCache()

    var cache: LiveActiveBackgroundWorkCache {
        lock.lock(); defer { lock.unlock() }
        return _cache
    }

    func apply(_ event: LiveActiveBackgroundWorkEvent) {
        lock.lock(); defer { lock.unlock() }
        _cache.apply(event)
    }
}
