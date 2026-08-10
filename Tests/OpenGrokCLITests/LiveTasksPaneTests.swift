// LiveTasksPaneTests.swift
//
// Wave 18 B1-t: the pane's entry builder — the live feeds mapped onto the
// pane model with `LivePagerTasksBlock`'s sort orders and status
// vocabulary, and the kill affordances (`agent_view/panes.rs:384-420`)
// bound only where a backing exists. The `y` copy affordance is asserted
// ABSENT: this port has no clipboard channel, and an advertised copy that
// lands nowhere is the §4 class.

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
        // The copy affordance stays unwired until a clipboard seam exists.
        #expect(entries.allSatisfy { $0.copyAction == nil })
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
