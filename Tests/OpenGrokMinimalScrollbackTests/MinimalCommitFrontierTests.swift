// MinimalCommitFrontierTests.swift
//
// Port of the frontier half of `xai-grok-pager-minimal/src/commit_tests.rs`
// at the pin (650c1db7), plus the frontier-coherence tests that live with
// the state upstream (`scrollback/state/mod.rs:3228-3319`). Every table
// value and assertion below is copied from the Rust test, not re-derived.
// The renderer-dependent tests in `commit_tests.rs` (height-fitting,
// cap/footer paint, accent column, native-color lock) are the M2 slice's
// subject and are deliberately not here.

import Testing
import OpenGrokMinimalScrollback

/// `commit_tests.rs:17` — a finalized generic entry.
private func finalized(_ text: String) -> MinimalScrollbackEntry {
    MinimalScrollbackEntry(.stub(text))
}

/// `commit_tests.rs:21` — a still-running generic entry.
private func running(_ text: String) -> MinimalScrollbackEntry {
    .running(.stub(text))
}

/// `commit_tests.rs:37-44` — run a commit pass for a RUNNING turn,
/// returning the emitted indices.
@discardableResult
private func commitCollect(_ state: MinimalScrollbackState) -> [Int] {
    var seen: [Int] = []
    commitLeadingRun(state, turnRunning: true) { _, i in
        seen.append(i)
        return true
    }
    return seen
}

@Suite("Minimal commit frontier")
struct MinimalCommitFrontierTests {
    // commit_tests.rs:46-65
    @Test("commits leading finalized run and stops at running")
    func commitsLeadingFinalizedRunAndStopsAtRunning() {
        let s = MinimalScrollbackState()
        s.push(finalized("a"))
        s.push(finalized("b"))
        s.push(running("c"))
        s.push(finalized("d")) // after the running block — must NOT commit yet

        #expect(commitCollect(s) == [0, 1])
        #expect(s.commitScanCursor == 2)
        #expect(s.isCommitted(s.entry(at: 0)!.id))
        #expect(s.isCommitted(s.entry(at: 1)!.id))
        #expect(!s.isCommitted(s.entry(at: 2)!.id))
        #expect(!s.isCommitted(s.entry(at: 3)!.id))

        // Finalize "c"; the next pass commits "c" then "d".
        #expect(s.updateEntry(at: 2) { $0.markCompleted() })
        #expect(commitCollect(s) == [2, 3])
        #expect(s.commitScanCursor == 4)
    }

    // commit_tests.rs:67-81
    @Test("pending user input holds the frontier")
    func pendingUserInputHoldsTheFrontier() {
        let s = MinimalScrollbackState()
        s.push(finalized("a"))
        let tool = s.push(finalized("tool")) // finalized but awaiting permission
        s.push(finalized("after"))
        #expect(s.setPendingUserInput(tool, pending: true))

        // Stops before the pending tool, even though it (and "after") are
        // finalized.
        #expect(commitCollect(s) == [0])

        // Resolving the prompt releases the rest of the run.
        #expect(s.setPendingUserInput(tool, pending: false))
        #expect(commitCollect(s) == [1, 2])
    }

    // commit_tests.rs:83-107 — the tracker leaves an agent message's
    // isRunning flag set until turn end. Minimal must still commit that
    // message mid-turn once a later block proves it's complete — otherwise
    // the rest of the turn piles up in the fixed-height live tail and
    // scrolls instead of accumulating into native scrollback.
    @Test("running agent message commits once a later block exists")
    func runningAgentMessageCommitsOnceALaterBlockExists() {
        let s = MinimalScrollbackState()
        s.push(.running(.agentMessage("answer text")))

        // While it's the last entry it may still be streaming → stays live.
        #expect(commitCollect(s) == [])
        #expect(s.commitScanCursor == 0)

        // A later block (the tracker moved on) proves the message is done →
        // it commits even though its running flag still lingers. The new
        // last/running entry stays in the live tail.
        s.push(running("tool"))
        #expect(commitCollect(s) == [0])
        #expect(s.isCommitted(s.entry(at: 0)!.id))
        #expect(!s.isCommitted(s.entry(at: 1)!.id))
    }

    // commit_tests.rs:109-120 — the agent-message relaxation must NOT
    // extend to tools: a running tool can still update its result, so
    // committing it (print-once) would lose the update.
    @Test("running tool still holds the frontier even with a later block")
    func runningToolStillHoldsTheFrontierEvenWithALaterBlock() {
        let s = MinimalScrollbackState()
        s.push(finalized("a"))
        s.push(running("running tool")) // stub == not an agent message
        s.push(finalized("after"))
        #expect(commitCollect(s) == [0])
        #expect(s.commitScanCursor == 1)
    }

    // commit_tests.rs:122-144
    @Test("plan body anchored above a parked tool commits while it is still running")
    func planBodyAnchoredAboveAParkedToolCommitsWhileRunning() {
        let s = MinimalScrollbackState()
        s.push(finalized("user prompt"))
        let tool = s.push(running("exit_plan_mode")) // parked on the decision
        s.insertBlockBefore(anchor: tool, block: .agentMessage("PLAN BODY"))

        // Prompt + plan commit; the running tool row still holds the frontier.
        #expect(commitCollect(s) == [0, 1])
        #expect(s.commitScanCursor == 2)
        if case .agentMessage = s.entry(at: 1)!.block {
        } else {
            Issue.record("expected the plan body at index 1")
        }
        #expect(s.isCommitted(s.entry(at: 1)!.id))
        #expect(!s.isCommitted(s.entry(at: 2)!.id))

        // Answering the prompt finalizes the tool row, which then commits
        // once, in its finished form — and the plan is NOT re-emitted.
        #expect(s.updateEntry(at: 2) { $0.markCompleted() })
        #expect(commitCollect(s) == [2])
        #expect(!scanFrontier(s, turnRunning: false).willCommit)
    }

    // commit_tests.rs:146-167 — whatever the commit pass prints must leave
    // the live tail, or the plan is painted under the prompt AND printed
    // above it.
    @Test("anchored plan body is not left in the live tail")
    func anchoredPlanBodyIsNotLeftInTheLiveTail() {
        let s = MinimalScrollbackState()
        s.push(finalized("user prompt"))
        let tool = s.push(running("exit_plan_mode"))
        s.insertBlockBefore(anchor: tool, block: .agentMessage("PLAN BODY"))

        // Sizing pass: the tail is just the tool row (index 2), and a
        // commit is pending for the two entries above it.
        let before = scanFrontier(s, turnRunning: true)
        #expect(before.tailStart == 2, "plan is excluded from the live tail")
        #expect(before.willCommit)

        commitLeadingRun(s, turnRunning: true) { _, _ in true }

        // Commit pass: same tail, nothing left to print.
        let after = scanFrontier(s, turnRunning: true)
        #expect(after.tailStart == before.tailStart, "tail must not move")
        #expect(!after.willCommit)
    }

    // commit_tests.rs:169-185
    @Test("revised plan anchors to its own tool row and neither plan re-emits")
    func revisedPlanAnchorsToItsOwnToolRowAndNeitherPlanReEmits() {
        let s = MinimalScrollbackState()
        let tool1 = s.push(running("exit_plan_mode #1"))
        s.insertBlockBefore(anchor: tool1, block: .agentMessage("PLAN ONE"))
        #expect(commitCollect(s) == [0]) // plan one

        #expect(s.updateEntry(at: 1) { $0.markCompleted() })
        let tool2 = s.push(running("exit_plan_mode #2"))
        s.insertBlockBefore(anchor: tool2, block: .agentMessage("PLAN TWO"))

        // Tool #1 and plan two commit; tool #2 holds the frontier.
        #expect(commitCollect(s) == [1, 2])
        // A third pass re-emits nothing.
        #expect(commitCollect(s).isEmpty)
        #expect(s.commitScanCursor == 3)
    }

    // commit_tests.rs:187-206 — a fresh background task is pushed as a
    // running "started" block whose flag is animation-only: the block is a
    // finalized lifecycle event whose content never changes. It must commit
    // immediately even mid-turn, or it wedges the frontier and the task
    // (plus everything after it) stays hidden in the live tail until the
    // task finishes (the reported upstream dogfood bug).
    @Test("bg task started commits while running and does not wedge frontier")
    func bgTaskStartedCommitsWhileRunningAndDoesNotWedgeFrontier() {
        let s = MinimalScrollbackState()
        s.push(finalized("a"))
        s.push(.running(.bgTask(command: "sleep 60", taskID: "task-1")))
        s.push(running("later tool")) // more turn output after the bg task

        // "a" + the running bg task commit; only the trailing running tool
        // stays.
        #expect(commitCollect(s) == [0, 1])
        #expect(s.isCommitted(s.entry(at: 1)!.id))
        #expect(!s.isCommitted(s.entry(at: 2)!.id))
    }

    // commit_tests.rs:208-219 — even as the last entry of a still-running
    // turn the bg "started" block commits: a lifecycle block never streams
    // more content (completion is a separate block).
    @Test("bg task started commits as last running entry")
    func bgTaskStartedCommitsAsLastRunningEntry() {
        let s = MinimalScrollbackState()
        s.push(finalized("a"))
        s.push(.running(.bgTask(command: "sleep 60", taskID: "task-1")))
        #expect(commitCollect(s) == [0, 1])
    }

    // commit_tests.rs:221-240
    @Test("no double commit after mid-list shift remove")
    func noDoubleCommitAfterMidListShiftRemove() {
        let s = MinimalScrollbackState()
        let a = s.push(finalized("a"))
        s.push(finalized("b"))
        s.push(finalized("c"))
        #expect(commitCollect(s) == [0, 1, 2])
        #expect(s.commitScanCursor == 3)

        // Remove an already-committed entry below the cursor (the removal
        // shifts the remaining indices down). The cursor is clamped; the
        // per-entry committed flags travel with "b"/"c", so neither is
        // re-emitted.
        #expect(s.removeEntry(a))
        s.push(finalized("d")) // now at index 2

        #expect(commitCollect(s) == [2])
        #expect(s.isCommitted(s.entry(at: 0)!.id)) // b
        #expect(s.isCommitted(s.entry(at: 1)!.id)) // c
        #expect(s.isCommitted(s.entry(at: 2)!.id)) // d
    }

    // commit_tests.rs:242-281 — regression: a committed placeholder
    // ("Loading session...") is removed AFTER new uncommitted entries were
    // appended past the cursor — the `/resume` / reconnect ordering.
    // Removing below the cursor shifts the uncommitted entries down one;
    // without the cursor decrement in removeEntry the first of them slid
    // below the cursor and was never committed NOR drawn in the live tail
    // (silently missing from minimal mode).
    @Test("mid-list removal below cursor does not strand uncommitted entries")
    func midListRemovalBelowCursorDoesNotStrandUncommittedEntries() {
        let s = MinimalScrollbackState()
        s.push(finalized("old-1"))
        let placeholder = s.push(finalized("Loading session..."))

        // A draw commits both; cursor = 2.
        var seen: [Int] = []
        commitLeadingRun(s, turnRunning: false) { _, i in
            seen.append(i)
            return true
        }
        #expect(seen == [0, 1])
        #expect(s.commitScanCursor == 2)

        // Replay appends entries, then the placeholder is removed in the
        // same event cycle (before the next commit pass).
        s.push(finalized("replayed-A"))
        s.push(finalized("replayed-B"))
        #expect(s.removeEntry(placeholder))
        // The cursor moved down with the shifted entries.
        #expect(s.commitScanCursor == 1)

        // The next pass commits BOTH replayed entries — none stranded.
        var again: [Int] = []
        commitLeadingRun(s, turnRunning: false) { _, i in
            again.append(i)
            return true
        }
        #expect(again == [1, 2])
        #expect(s.isCommitted(s.entry(at: 1)!.id)) // replayed-A
        #expect(s.isCommitted(s.entry(at: 2)!.id)) // replayed-B
    }

    // commit_tests.rs:283-311 — a block awaiting a permission / question
    // answer must never commit, even if the turn state reads idle (e.g. a
    // prompt outliving its turn): its rendered form still changes when the
    // prompt resolves, and a committed copy is frozen. The idle relaxation
    // only applies to stale-running flags, not pending-input marks.
    @Test("pending user input holds the frontier even when idle")
    func pendingUserInputHoldsTheFrontierEvenWhenIdle() {
        let s = MinimalScrollbackState()
        s.push(finalized("a"))
        let tool = s.push(finalized("tool"))
        #expect(s.setPendingUserInput(tool, pending: true))

        var seen: [Int] = []
        commitLeadingRun(s, turnRunning: false) { _, i in
            seen.append(i)
            return true
        }
        #expect(seen == [0], "pending entry must hold the frontier")
        #expect(!s.isCommitted(s.entry(at: 1)!.id))

        // Resolving the prompt releases it.
        #expect(s.setPendingUserInput(tool, pending: false))
        var again: [Int] = []
        commitLeadingRun(s, turnRunning: false) { _, i in
            again.append(i)
            return true
        }
        #expect(again == [1])
    }

    // commit_tests.rs:313-339 — regression: a terminal write failure must
    // NOT mark the entry committed — print-once means a marked-but-unprinted
    // block can never be emitted again. The walk stops with the cursor
    // before the failed entry and retries next frame.
    @Test("failed emit leaves entry uncommitted for retry")
    func failedEmitLeavesEntryUncommittedForRetry() {
        let s = MinimalScrollbackState()
        s.push(finalized("a"))
        s.push(finalized("b"))

        // First pass: the emit fails on the first entry.
        var calls = 0
        let n = commitLeadingRun(s, turnRunning: false) { _, _ in
            calls += 1
            return false
        }
        #expect(n == 0, "nothing committed on failure")
        #expect(calls == 1, "walk stops at the first failure")
        #expect(!s.isCommitted(s.entry(at: 0)!.id))
        #expect(s.commitScanCursor == 0, "cursor holds")

        // Retry pass succeeds and commits both.
        let retried = commitLeadingRun(s, turnRunning: false) { _, _ in true }
        #expect(retried == 2)
        #expect(s.isCommitted(s.entry(at: 0)!.id))
        #expect(s.isCommitted(s.entry(at: 1)!.id))
    }

    // commit_tests.rs:341-369 — scanFrontier (read-only: viewport sizing +
    // the will-commit gate) must agree exactly with the mutating walk, in
    // every phase.
    @Test("scan frontier mirrors commit leading run")
    func scanFrontierMirrorsCommitLeadingRun() {
        let s = MinimalScrollbackState()
        s.push(finalized("a"))
        s.push(finalized("b"))
        s.push(running("c"))
        s.push(finalized("d"))

        // Pre-commit: the pass would commit a+b and stop at the running
        // entry.
        let scan = scanFrontier(s, turnRunning: true)
        #expect(scan.willCommit)
        #expect(scan.tailStart == 2)

        let n = commitLeadingRun(s, turnRunning: true) { _, _ in true }
        #expect(n == 2)
        #expect(s.commitScanCursor == scan.tailStart)

        // Post-commit: nothing left to commit; the tail starts at the
        // cursor.
        let after = scanFrontier(s, turnRunning: true)
        #expect(!after.willCommit)
        #expect(after.tailStart == 2)

        // Idle with no entries pending: everything committable.
        let idle = scanFrontier(s, turnRunning: false)
        #expect(idle.willCommit)
        #expect(idle.tailStart == 4)
    }

    // commit_tests.rs:371-388 — rewind: drop everything from index 1.
    // Without the cursor clamp this would strand the cursor at 3 and
    // silently skip the next pushes.
    @Test("remove from below frontier then push still commits")
    func removeFromBelowFrontierThenPushStillCommits() {
        let s = MinimalScrollbackState()
        s.push(finalized("a"))
        s.push(finalized("b"))
        s.push(finalized("c"))
        #expect(commitCollect(s) == [0, 1, 2])

        let removed = s.removeFrom(1)
        #expect(removed.count == 2)
        #expect(s.commitScanCursor == 1)

        s.push(finalized("d")) // index 1
        #expect(commitCollect(s) == [1])
    }

    // commit_tests.rs:390-421 — the commit callback sees the block's
    // original content, and the block emits exactly once across repeated
    // frontier passes.
    @Test("btw block emits once across repeated frontier passes")
    func btwBlockEmitsOnceAcrossRepeatedFrontierPasses() {
        let s = MinimalScrollbackState()
        s.push(MinimalScrollbackEntry(
            .btw(question: "original question", answer: "original answer")
        ))

        var emitted: [Int] = []
        let n = commitLeadingRun(s, turnRunning: false) { state, i in
            guard case let .btw(question, answer) = state.entry(at: i)?.block else {
                Issue.record("expected a btw block")
                return false
            }
            #expect(question == "original question")
            #expect(answer == "original answer")
            emitted.append(i)
            return true
        }
        #expect(n == 1)
        #expect(s.isCommitted(s.entry(at: 0)!.id))

        let again = commitLeadingRun(s, turnRunning: false) { _, i in
            emitted.append(i)
            return true
        }
        #expect(again == 0)
        #expect(emitted == [0])
        #expect(!scanFrontier(s, turnRunning: false).willCommit)
    }

    // commit_tests.rs:423-448
    @Test("commit leading run advances frontier and marks committed once")
    func commitLeadingRunAdvancesFrontierAndMarksCommittedOnce() {
        let s = MinimalScrollbackState()
        s.push(finalized("h1"))
        s.push(finalized("h2"))
        s.push(finalized("h3"))

        // Advances the frontier, marking the leading finalized run
        // committed.
        var emitted: [Int] = []
        let n = commitLeadingRun(s, turnRunning: false) { _, i in
            emitted.append(i)
            return true
        }
        #expect(n == 3)
        #expect(emitted == [0, 1, 2])
        #expect(s.commitScanCursor == 3)
        #expect((0..<3).allSatisfy { s.isCommitted(s.entry(at: $0)!.id) })

        // A second pass commits nothing (already-committed entries are
        // skipped).
        var again: [Int] = []
        commitLeadingRun(s, turnRunning: false) { _, i in
            again.append(i)
            return true
        }
        #expect(again.isEmpty)
    }

    // commit_tests.rs:450-479 — regression for the missing-edit /
    // stuck-spinner bug: the tracker can leave an entry's running flag set
    // after the turn ends (a finalize missed at the thinking→tool
    // transition). While the turn runs, that entry correctly holds the
    // frontier; once the turn is idle the frontier must advance past it.
    @Test("idle turn commits past stale running entry")
    func idleTurnCommitsPastStaleRunningEntry() {
        let s = MinimalScrollbackState()
        s.push(finalized("a"))
        s.push(running("stale")) // stale running flag
        s.push(finalized("c"))

        // Running turn: blocked at the running entry.
        var seen: [Int] = []
        commitLeadingRun(s, turnRunning: true) { _, i in
            seen.append(i)
            return true
        }
        #expect(seen == [0])
        #expect(s.commitScanCursor == 1)

        // Idle turn: commit everything past the stale flag.
        var idle: [Int] = []
        commitLeadingRun(s, turnRunning: false) { _, i in
            idle.append(i)
            return true
        }
        #expect(idle == [1, 2])
        #expect(s.commitScanCursor == 3)
    }

    // commit_tests.rs:481-490
    @Test("clear resets the frontier")
    func clearResetsTheFrontier() {
        let s = MinimalScrollbackState()
        s.push(finalized("a"))
        commitCollect(s)
        #expect(s.commitScanCursor == 1)

        s.clear()
        #expect(s.commitScanCursor == 0)
    }
}

@Suite("Minimal frontier state coherence")
struct MinimalFrontierStateCoherenceTests {
    // state/mod.rs:3228-3252 — the shape minimal produces: a committed
    // prefix, the cursor parked at the first uncommitted entry, and a block
    // anchored above that entry. The cursor must be pulled back to (at
    // most) the insertion point or the inserted entry is scanned by nobody.
    @Test("insert block before never strands the entry below the commit frontier")
    func insertBlockBeforeNeverStrandsTheEntryBelowTheCommitFrontier() {
        let s = MinimalScrollbackState()
        let a = s.pushBlock(.stub("a"))
        let b = s.pushBlock(.stub("b"))
        let anchor = s.push(.running(.stub("running tool")))
        s.markCommitted(at: 0)
        s.markCommitted(at: 1)
        s.setCommitScanCursor(2)

        let inserted = s.insertBlockBefore(anchor: anchor, block: .stub("inserted"))

        #expect(s.indexOfID(inserted) == 2)
        #expect(
            s.commitScanCursor <= 2,
            "cursor must be pulled back to (at most) the insertion point, got \(s.commitScanCursor)"
        )
        #expect(s.isCommitted(a))
        #expect(s.isCommitted(b))
        #expect(!s.isCommitted(inserted))
        #expect(!s.isCommitted(anchor))
    }

    // state/mod.rs:3280-3305, minus the clear-all arm — that op's consumer
    // (the per-frame AgentView mark sync) is M3/M4 territory and lands with
    // it. The upstream `should_panic` committed-anchor test
    // (state/mod.rs:3255-3261) is not portable: the precondition is a
    // debug-only `assert`, and Swift Testing cannot observe an assertion
    // trap in-process.
    @Test("set pending user input toggles the flag and reports change")
    func setPendingUserInputTogglesTheFlagAndReportsChange() {
        let s = MinimalScrollbackState()
        let id = s.pushBlock(.stub("waiting"))

        // First flip from default false → true reports a change.
        #expect(s.setPendingUserInput(id, pending: true))
        #expect(s.entry(at: 0)!.isPendingUserInput)

        // Repeated set with the same value is a no-op.
        #expect(!s.setPendingUserInput(id, pending: true))

        // Flip back.
        #expect(s.setPendingUserInput(id, pending: false))
        #expect(!s.entry(at: 0)!.isPendingUserInput)

        // Unknown id is silently a no-op (returns false, no trap).
        let missing = MinimalEntryID(99999)
        #expect(!s.setPendingUserInput(missing, pending: true))
    }

    // state/mod.rs:3307-3319 — a finishing tool must drop its pending
    // mark, otherwise a tool that completes between two render frames
    // would hold the frontier forever. Exercised through the public seam
    // (upstream pokes the field directly).
    @Test("mark completed clears pending user input")
    func markCompletedClearsPendingUserInput() {
        let s = MinimalScrollbackState()
        let id = s.push(.running(.stub("tool")))
        #expect(s.setPendingUserInput(id, pending: true))

        #expect(s.updateEntry(at: 0) { $0.markCompleted() })

        #expect(!s.entry(at: 0)!.isRunning)
        #expect(!s.entry(at: 0)!.isPendingUserInput)
    }

    // No upstream unit test pins the expand ring; the behavior is pinned
    // here against its implementation (state/mod.rs:1125-1149): LIFO,
    // stale ids skipped, bounded at 256, reset by clear.
    @Test("expand ring is LIFO, skips stale ids, bounded, and cleared")
    func expandRingIsLIFOSkipsStaleIDsBoundedAndCleared() {
        let s = MinimalScrollbackState()
        let a = s.pushBlock(.stub("a"))
        let b = s.pushBlock(.stub("b"))
        s.recordCommittedForExpand(a)
        s.recordCommittedForExpand(b)

        // Most-recent first; a removed entry's id is skipped.
        #expect(s.removeEntry(b))
        #expect(s.takeExpandableCommitted() == a)
        #expect(s.takeExpandableCommitted() == nil)

        // Bounded at 256: the oldest recorded ids fall off the front.
        var ids: [MinimalEntryID] = []
        for i in 0..<300 {
            let id = s.pushBlock(.stub("entry \(i)"))
            ids.append(id)
            s.recordCommittedForExpand(id)
        }
        var taken: [MinimalEntryID] = []
        while let id = s.takeExpandableCommitted() {
            taken.append(id)
        }
        #expect(taken.count == 256)
        #expect(taken == Array(ids.suffix(256)).reversed())

        // clear() empties the ring along with the frontier.
        s.recordCommittedForExpand(ids.last!)
        s.clear()
        #expect(s.takeExpandableCommitted() == nil)
    }
}
