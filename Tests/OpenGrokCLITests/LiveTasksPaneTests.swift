// LiveTasksPaneTests.swift
//
// Wave 18 B1-t: the pane's entry builder — the live feeds mapped onto the
// pane model with `LivePagerTasksBlock`'s sort orders and status
// vocabulary, and the affordances (`agent_view/panes.rs:339-430`) bound only
// where a backing exists.
//
// The `y` copy used to be pinned ABSENT here on the claim that the port had
// no clipboard channel. That claim was false — `LivePagerClipboard.copy`
// (`LiveScrollbackFocus.swift:386-394`) is the OSC 52 seam `/copy`,
// `/export`, and the scrollback copy already ride — so the pin is replaced
// by the real gate: a copy target exists exactly when the snapshot holds
// output (upstream's `!task.stdout.is_empty()`, `panes.rs:427`), and the
// bytes that gate produces are asserted through the seam itself.

import Foundation
import OpenGrokPagerRender
import OpenGrokScheduler
import OpenGrokShellBase
import Testing
@testable import OpenGrokCLI

private let cwd = URL(fileURLWithPath: "/tmp")

@Suite("Tasks pane entry builder")
struct LiveTasksPaneBuilderTests {
    @Test("kinds map onto groups: monitors and loops share Watchers")
    func kindsMapOntoGroups() {
        // tasks_pane.rs:182-186: monitors and /loop rows share one section.
        let entries = LiveTasksPane.entries(
            workflowRows: [],
            subagents: [],
            tasks: [
                ShellTaskSnapshot(taskID: "bg-1", command: "sleep 60", cwd: cwd),
                ShellTaskSnapshot(taskID: "mon-1", command: "check api", cwd: cwd, kind: .monitor),
            ],
            scheduled: [ScheduledTaskInfo(
                taskId: "loop-1", prompt: "do the thing", humanSchedule: "every 5m",
                createdAt: Date(), nextFireAt: nil, tag: "loop", lastSubagentId: nil
            )]
        )
        #expect(entries.first { $0.id == "task:bg-1" }?.group == .tasks)
        #expect(entries.first { $0.id == "task:mon-1" }?.group == .watchers)
        #expect(entries.first { $0.id == "scheduled:loop-1" }?.group == .watchers)
    }

    @Test("kill actions bind per kind, only while running")
    func killActionsBindPerKind() {
        let now = Date()
        let entries = LiveTasksPane.entries(
            workflowRows: [
                LivePagerTasksBlock.WorkflowRow(
                    runID: "run-1", name: "audit", status: "active",
                    createdAtMS: 1_000
                ),
                LivePagerTasksBlock.WorkflowRow(
                    runID: "run-2", name: "done-flow", status: "completed",
                    createdAtMS: 900, lastEntryAtMS: 2_000
                ),
            ],
            subagents: [],
            tasks: [
                ShellTaskSnapshot(taskID: "bg-1", command: "sleep 60", cwd: cwd),
                ShellTaskSnapshot(
                    taskID: "bg-2", command: "true", cwd: cwd,
                    endTime: now, exitCode: 0, completed: true
                ),
            ],
            scheduled: [ScheduledTaskInfo(
                taskId: "loop-1", prompt: "p", humanSchedule: "every 5m",
                createdAt: now, nextFireAt: nil, tag: "loop", lastSubagentId: nil
            )],
            now: now
        )
        #expect(
            entries.first { $0.id == "workflow:run-1" }?.killAction
                == .stopWorkflow(name: "audit")
        )
        #expect(
            entries.first { $0.id == "workflow:run-2" }?.killAction == nil,
            "a finished workflow is not stoppable"
        )
        #expect(
            entries.first { $0.id == "task:bg-1" }?.killAction
                == .killBgTask(taskID: "bg-1")
        )
        #expect(
            entries.first { $0.id == "task:bg-2" }?.killAction == nil,
            "a completed task has nothing to kill"
        )
        #expect(
            entries.first { $0.id == "scheduled:loop-1" }?.killAction
                == .cancelScheduled(taskID: "loop-1"),
            "a scheduled loop is always cancellable"
        )
    }

    @Test("y binds only to a bg task that has output; monitors on the same terms")
    func copyActionsFollowTheOutputGate() {
        let now = Date()
        let entries = LiveTasksPane.entries(
            workflowRows: [
                LivePagerTasksBlock.WorkflowRow(
                    runID: "run-1", name: "audit", status: "active", createdAtMS: 1_000
                ),
            ],
            subagents: [],
            tasks: [
                ShellTaskSnapshot(
                    taskID: "loud", command: "echo hi", cwd: cwd, output: "hi there\n"
                ),
                ShellTaskSnapshot(taskID: "silent", command: "sleep 60", cwd: cwd),
                ShellTaskSnapshot(
                    taskID: "mon-1", command: "watch api", cwd: cwd,
                    output: "200 OK", kind: .monitor
                ),
                // A finished task keeps its copy target: the output is the
                // whole reason to reach for `y` after it exits.
                ShellTaskSnapshot(
                    taskID: "done", command: "true", cwd: cwd,
                    endTime: now, output: "done\n", exitCode: 0, completed: true
                ),
            ],
            scheduled: [ScheduledTaskInfo(
                taskId: "loop-1", prompt: "p", humanSchedule: "every 5m",
                createdAt: now, nextFireAt: nil, tag: "loop", lastSubagentId: nil
            )],
            now: now
        )
        #expect(
            entries.first { $0.id == "task:loud" }?.copyAction
                == .copyBgTaskOutput(taskID: "loud")
        )
        #expect(
            entries.first { $0.id == "task:silent" }?.copyAction == nil,
            "no output means no copy target (panes.rs:427 !task.stdout.is_empty())"
        )
        #expect(
            entries.first { $0.id == "task:mon-1" }?.copyAction
                == .copyBgTaskOutput(taskID: "mon-1"),
            "monitors are bg tasks upstream too"
        )
        #expect(
            entries.first { $0.id == "task:done" }?.copyAction
                == .copyBgTaskOutput(taskID: "done")
        )
        // Nothing else in the pane has a stdout to copy.
        #expect(entries.first { $0.id == "workflow:run-1" }?.copyAction == nil)
        #expect(entries.first { $0.id == "scheduled:loop-1" }?.copyAction == nil)
    }

    @Test("the copy payload leaves through the OSC 52 seam, tmux envelope included")
    func copyPayloadRidesOsc52() throws {
        // The composition's `y` arm re-reads the snapshot and hands its
        // output to the same clipboard seam `/copy` uses. Assert the bytes
        // that seam writes, so "Copied task output" can never be a claim
        // about a write that never happened.
        let snapshot = ShellTaskSnapshot(
            taskID: "bg-1", command: "echo hi", cwd: cwd, output: "hi there\n"
        )
        let entries = LiveTasksPane.entries(
            workflowRows: [], subagents: [], tasks: [snapshot], scheduled: []
        )
        #expect(
            entries.first { $0.id == "task:bg-1" }?.copyAction
                == .copyBgTaskOutput(taskID: "bg-1")
        )
        var written = Data()
        try LivePagerClipboard.copy(snapshot.output, to: { written.append($0) }, environment: [:])
        let plain = String(decoding: written, as: UTF8.self)
        #expect(plain.hasPrefix("\u{1b}]52;c;"))
        #expect(plain.contains(Data(snapshot.output.utf8).base64EncodedString()))

        var inTmux = Data()
        try LivePagerClipboard.copy(
            snapshot.output,
            to: { inTmux.append($0) },
            environment: ["TMUX": "/tmp/tmux-501/default,123,0"]
        )
        let tmux = String(decoding: inTmux, as: UTF8.self)
        #expect(
            tmux.hasPrefix("\u{1b}Ptmux;") && tmux.hasSuffix("\u{1b}\\"),
            "inside tmux the OSC rides the DCS passthrough envelope or the pane eats it"
        )
        #expect(tmux.contains(Data(snapshot.output.utf8).base64EncodedString()))
    }

    @Test("Enter targets: bg tasks and workflows open, scheduled and subagents do not")
    func openActionsBindPerKind() {
        let now = Date()
        let entries = LiveTasksPane.entries(
            workflowRows: [
                LivePagerTasksBlock.WorkflowRow(
                    runID: "run-1", name: "audit", status: "active", createdAtMS: 1_000
                ),
                LivePagerTasksBlock.WorkflowRow(
                    runID: "run-2", name: "done-flow", status: "completed",
                    createdAtMS: 900, lastEntryAtMS: 2_000
                ),
            ],
            subagents: [],
            tasks: [
                ShellTaskSnapshot(taskID: "bg-1", command: "sleep 60", cwd: cwd),
                ShellTaskSnapshot(
                    taskID: "bg-2", command: "true", cwd: cwd,
                    endTime: now, exitCode: 0, completed: true
                ),
            ],
            scheduled: [ScheduledTaskInfo(
                taskId: "loop-1", prompt: "p", humanSchedule: "every 5m",
                createdAt: now, nextFireAt: nil, tag: "loop", lastSubagentId: nil
            )],
            now: now
        )
        #expect(
            entries.first { $0.id == "task:bg-1" }?.openAction
                == .openBgTaskOutput(taskID: "bg-1")
        )
        #expect(
            entries.first { $0.id == "task:bg-2" }?.openAction
                == .openBgTaskOutput(taskID: "bg-2"),
            "a finished task still opens — upstream has no is_running gate (panes.rs:344-360)"
        )
        #expect(
            entries.first { $0.id == "workflow:run-1" }?.openAction
                == .openWorkflowDetail(name: "audit"),
            "the detail opens by NAME (open_workflow_detail, panes.rs:373-377)"
        )
        #expect(
            entries.first { $0.id == "workflow:run-2" }?.openAction
                == .openWorkflowDetail(name: "done-flow")
        )
        #expect(
            entries.first { $0.id == "scheduled:loop-1" }?.openAction == nil,
            "Scheduled rows open nothing (panes.rs:371)"
        )
    }

    @Test("filter text carries the row's label, prefix and status included")
    func searchTextCarriesTheRowLabel() {
        // tasks_pane.rs:305-312: the `Task ` prefix is baked into the label
        // precisely so the filter can match it. Here the label is the row's
        // spans, so `f` matches everything the row shows.
        let entries = LiveTasksPane.entries(
            workflowRows: [],
            subagents: [],
            tasks: [ShellTaskSnapshot(
                taskID: "bg-1", command: "sleep 60", cwd: cwd, description: "reindex the corpus"
            )],
            scheduled: []
        )
        let entry = entries.first { $0.id == "task:bg-1" }
        #expect(entry?.searchText.hasPrefix("Task ") == true)
        #expect(entry?.searchText.contains("reindex the corpus") == true)
        #expect(entry?.searchText == entry?.spans.map(\.text).joined())
    }

    @Test("active workflows sort before finished, newest first")
    func workflowSortOrder() {
        let entries = LiveTasksPane.entries(
            workflowRows: [
                LivePagerTasksBlock.WorkflowRow(
                    runID: "old-done", name: "a", status: "completed",
                    createdAtMS: 100, lastEntryAtMS: 200
                ),
                LivePagerTasksBlock.WorkflowRow(
                    runID: "newer-active", name: "b", status: "active", createdAtMS: 300
                ),
                LivePagerTasksBlock.WorkflowRow(
                    runID: "older-active", name: "c", status: "active", createdAtMS: 200
                ),
            ],
            subagents: [],
            tasks: [],
            scheduled: []
        )
        #expect(entries.map(\.id) == [
            "workflow:newer-active", "workflow:older-active", "workflow:old-done",
        ])
    }

    @Test("status vocabulary matches the /tasks block")
    func statusVocabularyMatchesTheBlock() {
        let now = Date()
        let entries = LiveTasksPane.entries(
            workflowRows: [],
            subagents: [],
            tasks: [
                ShellTaskSnapshot(
                    taskID: "failed-1", command: "false", cwd: cwd,
                    endTime: now, exitCode: 1, completed: true
                ),
            ],
            scheduled: [],
            now: now
        )
        let text = entries[0].spans.map(\.text).joined()
        #expect(text.contains("failed"), "exit 1 renders the block's vocabulary: \(text)")
        #expect(entries[0].running == false)
    }
}
