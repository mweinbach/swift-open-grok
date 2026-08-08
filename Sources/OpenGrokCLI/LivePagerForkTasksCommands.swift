// LivePagerForkTasksCommands.swift
//
// The live backings for the in-pager `/fork` and `/tasks` commands: the
// transcript copy `/fork`'s arms print, and the `/tasks` system-block
// formatter ported from upstream's `tasks_block_text`
// (`app/status_blocks.rs:48-178`). The dispatch itself lives on
// `LiveInteractiveControllerRenderer` (LiveComposition.swift); this file
// holds what tests must reach without a terminal.

import Foundation
import OpenGrokSessionRuntime
import OpenGrokShellBase

// MARK: - /fork copy

/// The `/fork` arms' transcript copy. Upstream's dispatch
/// (`dispatch_fork` / `dispatch_fork_resolved`) spawns a peer top-level
/// agent tab in the multi-agent dashboard; this port is a single-session
/// TUI, so the honest subset is the real on-disk session fork
/// (`LiveConversationStore.fork`) plus the exact commands that open the
/// result. Every arm the port cannot back refuses by name instead of
/// half-doing or silently dropping (AGENTS.md §3/§4).
enum LivePagerForkCommand {
    /// The success note. Upstream opens the peer tab itself; the port names
    /// both real open routes — the in-TUI `/resume <id>` swap and the
    /// separate-terminal resume, which is the closest thing to upstream's
    /// "peer" (the current session keeps running).
    static func forkedNote(sessionID: String) -> String {
        "Forked this session as \(sessionID). "
            + "Open it here with /resume \(sessionID) (replaces this conversation), "
            + "or run `open-grok --resume \(sessionID)` in another terminal to work "
            + "on both in parallel."
    }

    /// RECORDED DIVERGENCE: upstream `--worktree` forks the session into a
    /// fresh git worktree (`dispatch_fork_resolved`). The port's worktree
    /// launcher (`LiveWorktreeLaunch`) only starts *fresh* sessions at
    /// process launch — its own parser refuses `--fork-session --worktree`
    /// — so there is no backing that both forks and isolates. Refuse and
    /// name what exists rather than forking without the isolation the user
    /// asked for.
    static let worktreeRefusal =
        "/fork --worktree is not available in this version: the worktree "
        + "launcher only starts fresh sessions, and a session fork cannot be "
        + "combined with a worktree yet. Run /fork without flags to fork in "
        + "place, or `open-grok --worktree [name]` for a fresh worktree session."

    /// RECORDED DIVERGENCE: upstream's directive becomes the forked agent's
    /// first prompt. The port's session record persists no pending prompt
    /// (`LiveConversationRecord` carries items + rewind only), so nothing
    /// can carry the directive into the forked session — refuse the form
    /// instead of forking and silently dropping the text.
    static let directiveRefusal =
        "/fork with a directive is not available in this version: the forked "
        + "session's record cannot store a queued first prompt. Run /fork "
        + "without a directive, then open the fork and send it there."

    /// `tasks.rs:34` — the copy is upstream's, reused for `/fork` because
    /// both are session-scoped and this is the port's only session-less
    /// state (renderer constructions without a session id or store).
    static let noActiveSession = "No active session"
}

// MARK: - /tasks block

/// `tasks_block_text` (`app/status_blocks.rs:48-178`) for the sections the
/// port has task sources for: workflow runs (the `/workflows` registry),
/// subagents (the `spawn_subagent` host), and shell background tasks (the
/// session's owner-scoped `listTasks()`).
///
/// RECORDED DIVERGENCE: upstream's fourth section, scheduled `/loop` tasks
/// (`status_blocks.rs:150-166`), has no port source — `/loop` is not ported
/// and no scheduled-task store exists — so it renders nothing here rather
/// than a fabricated empty section.
enum LivePagerTasksBlock {
    /// Workflow row inputs, decoupled from `RhaiWorkflowRunView` so the
    /// formatter is testable with fixed clocks and so the elapsed rule
    /// (live for active, frozen at the last journal entry for terminal)
    /// lives in one visible place.
    struct WorkflowRow {
        var runID: String
        var name: String
        /// `PersistedWorkflowStatus.rawValue` — `active`, `completed`,
        /// `budget_exceeded`, …
        var status: String
        var currentPhase: String?
        var activeAgentCount: Int
        var createdAtMS: UInt64
        /// The last journal entry's `at_ms`, when any exists. A terminal
        /// run's elapsed freezes here — the record stores no end time, and
        /// "now minus created" would keep growing after completion.
        var lastEntryAtMS: UInt64?

        init(view: RhaiWorkflowRunView) {
            runID = view.record.runID
            name = view.record.workflowName
            status = view.record.status.rawValue
            currentPhase = view.currentPhase
            activeAgentCount = view.agents.filter { $0.state == .running }.count
            createdAtMS = view.record.createdAtMS
            lastEntryAtMS = view.entries.map(\.atMS).max()
        }

        init(
            runID: String,
            name: String,
            status: String,
            currentPhase: String? = nil,
            activeAgentCount: Int = 0,
            createdAtMS: UInt64,
            lastEntryAtMS: UInt64? = nil
        ) {
            self.runID = runID
            self.name = name
            self.status = status
            self.currentPhase = currentPhase
            self.activeAgentCount = activeAgentCount
            self.createdAtMS = createdAtMS
            self.lastEntryAtMS = lastEntryAtMS
        }

        /// `WorkflowRunSnapshot::is_active` (`views/workflows.rs:55-57`).
        var isActive: Bool { status == "active" }

        /// The port of `live_elapsed_ms` (`views/workflows.rs:97-104`):
        /// counting for an active run, frozen for everything else.
        func elapsedSeconds(now: Date) -> TimeInterval {
            let created = TimeInterval(createdAtMS) / 1_000
            if isActive {
                return max(0, now.timeIntervalSince1970 - created)
            }
            guard let lastEntryAtMS else { return 0 }
            return max(0, TimeInterval(lastEntryAtMS) / 1_000 - created)
        }
    }

    static func text(
        workflows: [RhaiWorkflowRunView],
        subagents: [LiveSubagentSnapshot],
        tasks: [ShellTaskSnapshot],
        now: Date = Date()
    ) -> String {
        text(
            workflowRows: workflows.map(WorkflowRow.init(view:)),
            subagents: subagents,
            tasks: tasks,
            now: now
        )
    }

    static func text(
        workflowRows: [WorkflowRow],
        subagents: [LiveSubagentSnapshot],
        tasks: [ShellTaskSnapshot],
        now: Date = Date()
    ) -> String {
        var rows: [String] = []

        // ── Workflows (`status_blocks.rs:51-82`) ──
        let sortedWorkflows = workflowRows.sorted { a, b in
            if a.isActive != b.isActive { return a.isActive }
            if a.createdAtMS != b.createdAtMS { return a.createdAtMS > b.createdAtMS }
            return a.runID < b.runID
        }
        for run in sortedWorkflows {
            let agents: String
            switch run.activeAgentCount {
            case 0: agents = ""
            case 1: agents = " · 1 agent"
            case let n: agents = " · \(n) agents"
            }
            let phase = run.currentPhase
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : " · \($0)" } ?? ""
            let status = run.isActive
                ? "running"
                : run.status.replacingOccurrences(of: "_", with: " ")
            rows.append(
                "  \(padded(status))Workflow · \(run.name)\(phase)\(agents)"
                    + "  (\(formatDuration(run.elapsedSeconds(now: now))))"
            )
        }

        // ── Subagents (`status_blocks.rs:84-114`) ──
        //
        // Upstream filters out workflow-owned children
        // (`workflow_run_id.is_none()`); the port needs no filter because
        // workflow children run through `LiveWorkflowChildAgent`, never the
        // subagent host. RECORDED DIVERGENCE: upstream's "stopping" status
        // (`pending_kill`) is absent — the port's host tracks no
        // kill-in-flight flag, so a cancelled child shows "running" until
        // the coordinator lands it as "cancelled".
        let sortedSubagents = subagents.sorted { a, b in
            let (ar, br) = (a.status == "running", b.status == "running")
            if ar != br { return ar }
            if a.startedAt != b.startedAt { return a.startedAt > b.startedAt }
            return a.subagentID < b.subagentID
        }
        for info in sortedSubagents {
            let (typeLabel, desc) = subagentLabel(
                type: info.subagentType,
                description: info.description
            )
            let status = info.status == "running" ? "running" : info.status
            let label = desc.isEmpty ? typeLabel : "\(typeLabel) · \(desc)"
            let elapsed = info.status == "running"
                ? max(0, now.timeIntervalSince(info.startedAt))
                : TimeInterval(info.durationMS) / 1_000
            rows.append("  \(padded(status))\(label)  (\(formatDuration(elapsed)))")
        }

        // ── Background tasks (`status_blocks.rs:116-148`) ──
        //
        // Every row is "Task": the port has no monitor tool, so upstream's
        // `is_monitor` arm has no source. Status vocabulary: upstream's
        // running/done/failed where states correspond, plus the port's own
        // "cancelled" for an explicitly killed task (upstream folds those
        // into done/failed after its "stopping" interlude).
        let sortedTasks = tasks.sorted { a, b in
            if a.completed != b.completed { return !a.completed }
            if a.startTime != b.startTime { return a.startTime > b.startTime }
            return a.taskID < b.taskID
        }
        for task in sortedTasks {
            let oneLine = task.description
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? firstNonEmptyLine(task.displayCommand ?? task.command)
            let status: String
            switch LiveBackgroundTaskTools.status(for: task) {
            case "running": status = "running"
            case "completed": status = "done"
            case "cancelled": status = "cancelled"
            default: status = "failed"
            }
            rows.append(
                "  \(padded(status))Task · \(oneLine)  (\(formatDuration(task.duration(at: now))))"
            )
        }

        // Empty state and header (`status_blocks.rs:168-177`), byte-exact.
        guard !rows.isEmpty else {
            return "No background tasks, workflows, or subagents."
        }
        let header = "Task\(rows.count == 1 ? "" : "s") (\(rows.count)):"
        return ([header] + rows).joined(separator: "\n")
    }

    /// `format_subagent_label` (`app/subagent.rs:404-433`) for the fields
    /// the port's snapshot carries. Precedence for the label:
    /// `subagent_type` when it is not the meaningless `general-purpose`
    /// default, then a `[tag]` parsed off the description, then "general";
    /// first character uppercased. RECORDED DIVERGENCE: upstream's higher
    /// arms — persona, then role — have no port source (the spawn surface
    /// takes neither), so they cannot be reached.
    static func subagentLabel(type: String, description: String) -> (String, String) {
        let (tag, cleanDescription) = parseTagPrefix(description)
        let rawLabel: String
        if type != "general-purpose" {
            // `format_type_label` (`subagent.rs:356-361`) maps only
            // `general-purpose` to "general"; every other type passes
            // through.
            rawLabel = type
        } else if let tag {
            rawLabel = tag
        } else {
            rawLabel = "general"
        }
        guard let first = rawLabel.first else { return (rawLabel, cleanDescription) }
        return (first.uppercased() + rawLabel.dropFirst(), cleanDescription)
    }

    /// `parse_tag_prefix` (`subagent.rs:373-383`): a leading `[<non-empty>]`
    /// becomes the tag; anything else leaves the description alone.
    static func parseTagPrefix(_ description: String) -> (String?, String) {
        guard description.hasPrefix("[") else { return (nil, description) }
        let rest = description.dropFirst()
        guard let close = rest.firstIndex(of: "]") else { return (nil, description) }
        let tag = rest[..<close].trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty else { return (nil, description) }
        return (tag, String(rest[rest.index(after: close)...].drop(while: \.isWhitespace)))
    }

    /// `format_duration` (`xai-grok-pager-render/src/util.rs:81-97`) — the
    /// formatter `tasks_block_text` imports as `crate::util::format_duration`.
    /// Not `pagerFormatDuration` (PagerTheme.swift), which ports the
    /// *different* upstream `thinking.rs::format_time` and lacks the whole-
    /// second and hour buckets.
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = UInt64(max(0, seconds))
        if totalSeconds < 10 {
            return String(format: "%.1fs", max(0, seconds))
        }
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        if minutes < 60 {
            return "\(minutes)m\(secs)s"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return "\(hours)h\(remainingMinutes)m"
    }

    /// `first_nonempty_line` (`status_blocks.rs:251-256`).
    static func firstNonEmptyLine(_ text: String) -> String {
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    /// Rust's `{:<9}` — left-justified, space-padded to at least 9 columns,
    /// never truncated.
    private static func padded(_ status: String) -> String {
        status.count >= 9 ? status : status + String(repeating: " ", count: 9 - status.count)
    }
}
