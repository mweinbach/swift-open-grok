// LiveTasksPane.swift
//
// Wave 18 B1-t: the live half of the Ctrl+G tasks pane — the feed snapshot
// → `PagerTaskPaneEntry` builder, sharing `LivePagerTasksBlock`'s sort
// orders, labels, and status vocabulary so the pane and the read-only
// `/tasks` block can never describe the same task differently (upstream's
// `TaskEntry::from_*` constructors and the block's `status_blocks.rs`
// formatters read the same stores for the same reason).
//
// Kill affordances (`agent_view/panes.rs:384-420`): a running bg task or
// monitor kills through the session execution's `killTask`, a running
// subagent through the coordinator's cancel, a scheduled `/loop` through
// the scheduler host's delete, and a stoppable workflow rides
// `/workflow stop <name>` — upstream's own dispatch shape. The `y`
// stdout-copy affordance is NOT wired: this port has no clipboard channel
// (the OSC 52 divergence recorded at `openExternalURL`), and advertising a
// copy that lands nowhere is the §4 class. `copyAction` stays nil until a
// clipboard seam exists.

import Foundation
import OpenGrokPagerRender
import OpenGrokScheduler
import OpenGrokShellBase
import OpenGrokSessionRuntime

enum LiveTasksPane {
    /// Build the pane entries from the same four feeds `/tasks` reads
    /// (`presentTasksBlock`), in the block's sort orders. Group order
    /// itself (Workflows → Subagents → Tasks → Watchers) is applied by
    /// `PagerTasksPaneState.updateEntries`.
    static func entries(
        workflows: [RhaiWorkflowRunView],
        subagents: [LiveSubagentSnapshot],
        tasks: [ShellTaskSnapshot],
        scheduled: [ScheduledTaskInfo],
        now: Date = Date()
    ) -> [PagerTaskPaneEntry] {
        entries(
            workflowRows: workflows.map(LivePagerTasksBlock.WorkflowRow.init(view:)),
            subagents: subagents,
            tasks: tasks,
            scheduled: scheduled,
            now: now
        )
    }

    static func entries(
        workflowRows: [LivePagerTasksBlock.WorkflowRow],
        subagents: [LiveSubagentSnapshot],
        tasks: [ShellTaskSnapshot],
        scheduled: [ScheduledTaskInfo],
        now: Date = Date()
    ) -> [PagerTaskPaneEntry] {
        var entries: [PagerTaskPaneEntry] = []
        let theme = PagerRenderTheme.default

        // ── Workflows: active first, newest first (the block's order) ──
        let sortedWorkflows = workflowRows.sorted { a, b in
            if a.isActive != b.isActive { return a.isActive }
            if a.createdAtMS != b.createdAtMS { return a.createdAtMS > b.createdAtMS }
            return a.runID < b.runID
        }
        for run in sortedWorkflows {
            let status = run.isActive
                ? "running"
                : run.status.replacingOccurrences(of: "_", with: " ")
            let phase = run.currentPhase
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : " \u{00B7} \($0)" } ?? ""
            entries.append(PagerTaskPaneEntry(
                id: "workflow:\(run.runID)",
                group: .workflows,
                spans: [
                    PagerStyledSpan(
                        text: "Workflow ",
                        foreground: run.isActive ? theme.accentRunning : theme.gray,
                        style: [.bold]
                    ),
                    PagerStyledSpan(text: run.name, foreground: theme.textPrimary),
                    PagerStyledSpan(text: "\(phase) \u{00B7} \(status)", foreground: theme.gray),
                ],
                elapsed: "(\(LivePagerTasksBlock.formatDuration(run.elapsedSeconds(now: now))))",
                running: run.isActive,
                killAction: run.isActive ? .stopWorkflow(name: run.name) : nil
            ))
        }

        // ── Subagents: running first, newest first ──
        let sortedSubagents = subagents.sorted { a, b in
            let (aRunning, bRunning) = (a.status == "running", b.status == "running")
            if aRunning != bRunning { return aRunning }
            if a.startedAt != b.startedAt { return a.startedAt > b.startedAt }
            return a.subagentID < b.subagentID
        }
        for info in sortedSubagents {
            let (typeLabel, description) = LivePagerTasksBlock.subagentLabel(
                type: info.subagentType,
                description: info.description
            )
            let running = info.status == "running"
            let elapsed = running
                ? max(0, now.timeIntervalSince(info.startedAt))
                : TimeInterval(info.durationMS) / 1_000
            var spans = [PagerStyledSpan(
                text: "\(typeLabel) ",
                foreground: running ? theme.accentTool : theme.gray,
                style: [.bold]
            )]
            if !description.isEmpty {
                spans.append(PagerStyledSpan(text: description, foreground: theme.textPrimary))
            }
            spans.append(PagerStyledSpan(text: " \u{00B7} \(info.status)", foreground: theme.gray))
            entries.append(PagerTaskPaneEntry(
                id: "subagent:\(info.subagentID)",
                group: .subagents,
                spans: spans,
                elapsed: "(\(LivePagerTasksBlock.formatDuration(elapsed)))",
                running: running,
                killAction: running ? .killSubagent(subagentID: info.subagentID) : nil
            ))
        }

        // ── Background tasks and monitors: running first, newest first.
        // Monitors sort into the Watchers group with the `/loop` rows
        // (`tasks_pane.rs:182-186`: "monitor tasks and /loop scheduled
        // tasks share one section … monitors first, then loops"). ──
        let sortedTasks = tasks.sorted { a, b in
            if a.completed != b.completed { return !a.completed }
            if a.startTime != b.startTime { return a.startTime > b.startTime }
            return a.taskID < b.taskID
        }
        for task in sortedTasks {
            let isMonitor = task.kind == .monitor
            let oneLine = task.description
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? LivePagerTasksBlock.firstNonEmptyLine(task.displayCommand ?? task.command)
            let status: String
            switch LiveBackgroundTaskTools.status(for: task) {
            case "running": status = "running"
            case "completed": status = "done"
            case "cancelled": status = "cancelled"
            default: status = "failed"
            }
            let running = status == "running"
            entries.append(PagerTaskPaneEntry(
                id: "task:\(task.taskID)",
                group: isMonitor ? .watchers : .tasks,
                spans: [
                    PagerStyledSpan(
                        text: isMonitor ? "Monitor " : "Task ",
                        foreground: isMonitor
                            ? theme.accentSystem
                            : (running ? theme.accentSuccess : theme.gray),
                        style: [.bold]
                    ),
                    PagerStyledSpan(text: oneLine, foreground: theme.textPrimary),
                    PagerStyledSpan(text: " \u{00B7} \(status)", foreground: theme.gray),
                ],
                elapsed: "(\(LivePagerTasksBlock.formatDuration(task.duration(at: now))))",
                running: running,
                killAction: running ? .killBgTask(taskID: task.taskID) : nil
            ))
        }

        // ── Scheduled /loop rows: the block's tag/schedule/id order ──
        let sortedScheduled = scheduled.sorted { a, b in
            if a.tag != b.tag { return a.tag < b.tag }
            if a.humanSchedule != b.humanSchedule { return a.humanSchedule < b.humanSchedule }
            return a.taskId < b.taskId
        }
        for info in sortedScheduled {
            entries.append(PagerTaskPaneEntry(
                id: "scheduled:\(info.taskId)",
                group: .watchers,
                spans: [
                    PagerStyledSpan(text: "\(info.tag) ", foreground: theme.accentSystem, style: [.bold]),
                    PagerStyledSpan(
                        text: "\(info.humanSchedule) \u{00B7} "
                            + LivePagerTasksBlock.firstNonEmptyLine(info.prompt),
                        foreground: theme.textPrimary
                    ),
                ],
                running: true,
                killAction: .cancelScheduled(taskID: info.taskId)
            ))
        }

        return entries
    }
}
