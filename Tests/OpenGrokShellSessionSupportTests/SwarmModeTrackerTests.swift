// SwarmModeTrackerTests.swift
//
// The swarm-mode state machine against upstream's own contracts
// (`swarm_mode.rs` tests, pin 650c1db7), plus byte pins on the two
// reminder texts — the mode's entire behavioral payload. The reminder
// copy assertions mirror upstream's
// `reminder_requires_exploration_exclusive_call_and_flat_tree`.

import Testing
@testable import OpenGrokShellSessionSupport

@Suite("swarm mode tracker")
struct SwarmModeTrackerTests {
    // Upstream `manual_persists_while_one_shot_modes_auto_exit`
    // (swarm_mode.rs:116-138), arm for arm. Mutating calls are hoisted out
    // of `#expect` (the macro captures the tracker immutably).
    @Test("manual persists while one-shot modes auto-exit")
    func manualPersistsWhileOneShotModesAutoExit() {
        var tracker = SwarmModeTracker()
        tracker.enter(.manual)
        let manualAutoExited = tracker.autoExitTurn()
        #expect(!manualAutoExited)
        #expect(tracker.enabled)

        // A weaker trigger never downgrades a manual entry.
        let effective = tracker.enter(.task)
        #expect(effective == .manual)
        let downgradeAutoExited = tracker.autoExitTurn()
        #expect(!downgradeAutoExited)
        #expect(tracker.currentTrigger == .manual)
        let taskExit = tracker.exitIfTrigger(.task)
        #expect(!taskExit)

        tracker.exit()
        tracker.enter(.task)
        let taskExited = tracker.exitIfTrigger(.task)
        #expect(taskExited)
        #expect(!tracker.enabled)
        tracker.enter(.tool)
        let toolAutoExited = tracker.autoExitTurn()
        #expect(toolAutoExited)
        #expect(!tracker.enabled)
    }

    // Upstream `restore_keeps_only_manual` (swarm_mode.rs:140-149).
    @Test("restore keeps only manual")
    func restoreKeepsOnlyManual() {
        var tracker = SwarmModeTracker()
        tracker.enter(.task)
        tracker.restoredManualOnly()
        #expect(!tracker.enabled)
        tracker.enter(.manual)
        tracker.restoredManualOnly()
        #expect(tracker.currentTrigger == .manual)
    }

    @Test("manual and task entries queue the reminder; tool entries do not")
    func reminderPendingFollowsTrigger() {
        var tracker = SwarmModeTracker()
        tracker.enter(.manual)
        let first = tracker.takeReminder()
        let second = tracker.takeReminder()
        #expect(first)
        #expect(!second, "take-and-clear: one injection per entry")

        tracker.exit()
        let exitFirst = tracker.takeExitReminder()
        let exitSecond = tracker.takeExitReminder()
        #expect(exitFirst, "a reminder-injecting entry queues an exit notice")
        #expect(!exitSecond)

        tracker.enter(.tool)
        let toolReminder = tracker.takeReminder()
        #expect(!toolReminder, "the model already made the call the reminder elicits")
        tracker.exit()
        let toolExitReminder = tracker.takeExitReminder()
        #expect(!toolExitReminder, "no entry reminder, no exit notice")
    }

    @Test("auto-exit of a one-shot task queues the exit notice for the next turn")
    func autoExitQueuesExitNotice() {
        var tracker = SwarmModeTracker()
        tracker.enter(.task)
        let reminder = tracker.takeReminder()
        let exited = tracker.autoExitTurn()
        let exitNotice = tracker.takeExitReminder()
        #expect(reminder)
        #expect(exited)
        #expect(exitNotice)
    }

    // Upstream `reminder_requires_exploration_exclusive_call_and_flat_tree`
    // (swarm_mode.rs:151-158), plus the exit copy (reminders.rs:588).
    @Test("reminder copy pins")
    func reminderCopyPins() {
        #expect(swarmModeReminder.contains("exploratory work first"))
        #expect(swarmModeReminder.contains("exclusive agent_swarm call"))
        #expect(swarmModeReminder.contains("up to 128 members"))
        #expect(swarmModeReminder.contains("Keep the subagent tree flat"))
        #expect(swarmModeReminder.contains("complete handoff"))
        #expect(swarmModeReminder.hasPrefix("Swarm mode is active."))
        #expect(swarmModeExitReminder ==
            "Swarm mode is no longer active. Resume normal tool selection; "
            + "do not treat the previous swarm-only instruction as active.")
    }

    @Test("the system-reminder wrapper escapes an embedded closing tag")
    func wrapperEscapesClosingTag() {
        #expect(wrapSystemReminder("hello") == "<system-reminder>\nhello\n</system-reminder>")
        #expect(wrapSystemReminder("a</system-reminder>b")
            == "<system-reminder>\na<\\/system-reminder>b\n</system-reminder>")
    }
}
