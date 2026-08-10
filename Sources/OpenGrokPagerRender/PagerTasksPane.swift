// PagerTasksPane.swift
//
// Wave 18 B1-t: the Ctrl+G tasks pane — the port of
// `views/tasks_pane.rs` at pin 650c1db7 (the interactive band listing
// workflows, subagents, background tasks, and watchers) and its caller
// affordances (`agent_view/panes.rs:312-455`). Upstream this is a
// full-width horizontal band between the status bar and the scrollback
// (`views/agent.rs:210-213`, `Constraint::Length(tasks_height)`) that
// COEXISTS with the composer — glanceable while typing — which is why it
// is frame chrome here, not a capturing overlay (the B1 research ruling).
//
// The composition owns the feeds (actors) and prebuilds each entry's
// styled spans; this side owns grouping, collapse, selection, and the
// per-key affordances a generic list cannot carry: `x` kills the selected
// entry through whichever backing owns it, `y` copies a bg task's output,
// Enter toggles a group header, Tab hands focus back to the prompt.

import OpenGrokTerminalCore

/// Logical group a pane entry belongs to — order and labels verbatim
/// (`tasks_pane.rs:178-215`). Watchers = monitors + `/loop` scheduled
/// tasks, contiguous in one section.
public enum PagerTaskPaneGroup: String, Sendable, Equatable, Hashable, CaseIterable {
    case workflows
    case subagents
    case tasks
    case watchers

    public var label: String {
        switch self {
        case .workflows: return "Workflows"
        case .subagents: return "Subagents"
        case .tasks: return "Tasks"
        case .watchers: return "Watchers"
        }
    }
}

/// What `x` (kill) or `y` (copy) resolves to for an entry — one case per
/// backed affordance (`panes.rs:384-420` for the kill arms, `:422-430` for
/// the stdout copy).
public enum PagerTaskPaneAction: Sendable, Equatable {
    case killBgTask(taskID: String)
    case killSubagent(subagentID: String)
    case cancelScheduled(taskID: String)
    /// Rides the slash dispatch exactly as upstream does
    /// (`SendSlashCommandPreservingDraft("/workflow stop <name>")`).
    case stopWorkflow(name: String)
    case copyBgTaskOutput(taskID: String)
}

/// One pane entry, prebuilt by the composition from a feed snapshot.
public struct PagerTaskPaneEntry: Sendable, Equatable {
    public var id: String
    public var group: PagerTaskPaneGroup
    /// The styled label row (status word, kind tag, description).
    public var spans: [PagerStyledSpan]
    /// Right-aligned elapsed column, e.g. `(3m 12s)`.
    public var elapsed: String?
    public var running: Bool
    /// `x` target; nil when the entry is not killable (already finished).
    public var killAction: PagerTaskPaneAction?
    /// `y` target; nil when there is nothing to copy.
    public var copyAction: PagerTaskPaneAction?

    public init(
        id: String,
        group: PagerTaskPaneGroup,
        spans: [PagerStyledSpan],
        elapsed: String? = nil,
        running: Bool = false,
        killAction: PagerTaskPaneAction? = nil,
        copyAction: PagerTaskPaneAction? = nil
    ) {
        self.id = id
        self.group = group
        self.spans = spans
        self.elapsed = elapsed
        self.running = running
        self.killAction = killAction
        self.copyAction = copyAction
    }
}

/// One visible row: a collapsible group header or an entry (by index into
/// `entries`).
public enum PagerTaskPaneRow: Sendable, Equatable {
    case header(group: PagerTaskPaneGroup, count: Int, collapsed: Bool)
    case entry(index: Int)
}

public enum PagerTasksPaneOutcome: Sendable, Equatable {
    case redraw
    case consumed
    /// Ctrl+G / Esc — hide the pane and return focus to the prompt.
    case close
    /// Tab — keep the pane visible, focus the prompt (`panes.rs:431-434`).
    case focusPrompt
    case action(PagerTaskPaneAction)
}

/// The pane's whole state. A value snapshot — the composition rebuilds
/// `entries` from its feeds and calls `updateEntries` so collapse and
/// selection survive a refresh.
public struct PagerTasksPaneState: Sendable, Equatable {
    public private(set) var entries: [PagerTaskPaneEntry]
    public private(set) var collapsed: Set<PagerTaskPaneGroup>
    /// Index into `visibleRows`.
    public private(set) var selectedIndex: Int
    /// Focused = keys route here; unfocused the pane stays visible beside a
    /// focused composer (the coexistence that makes it a pane, not a modal).
    public var focused: Bool

    public init(entries: [PagerTaskPaneEntry] = [], focused: Bool = true) {
        self.entries = []
        self.collapsed = []
        self.selectedIndex = 0
        self.focused = focused
        updateEntries(entries)
    }

    /// Replace the entries from a fresh feed snapshot, preserving collapse
    /// state and re-anchoring the selection to the same row id when it
    /// still exists (the in-place refresh convention from B2-W2).
    public mutating func updateEntries(_ newEntries: [PagerTaskPaneEntry]) {
        let selectedID = selectedEntry?.id
        // Group order is fixed (`GroupKind::order`, tasks_pane.rs:203-210);
        // within a group the composition's order is kept.
        entries = PagerTaskPaneGroup.allCases.flatMap { group in
            newEntries.filter { $0.group == group }
        }
        if let selectedID,
           let row = visibleRows.firstIndex(where: { row in
               if case .entry(let index) = row { return entries[index].id == selectedID }
               return false
           }) {
            selectedIndex = row
        } else {
            selectedIndex = min(selectedIndex, max(0, visibleRows.count - 1))
        }
    }

    /// Headers for every non-empty group, then that group's entries unless
    /// collapsed — the flat list the renderer paints and the selection
    /// walks.
    public var visibleRows: [PagerTaskPaneRow] {
        var rows: [PagerTaskPaneRow] = []
        for group in PagerTaskPaneGroup.allCases {
            let indices = entries.indices.filter { entries[$0].group == group }
            guard !indices.isEmpty else { continue }
            let isCollapsed = collapsed.contains(group)
            rows.append(.header(group: group, count: indices.count, collapsed: isCollapsed))
            if !isCollapsed {
                rows.append(contentsOf: indices.map { PagerTaskPaneRow.entry(index: $0) })
            }
        }
        return rows
    }

    public var selectedEntry: PagerTaskPaneEntry? {
        guard visibleRows.indices.contains(selectedIndex),
              case .entry(let index) = visibleRows[selectedIndex] else { return nil }
        return entries[index]
    }

    public var selectedHeaderGroup: PagerTaskPaneGroup? {
        guard visibleRows.indices.contains(selectedIndex),
              case .header(let group, _, _) = visibleRows[selectedIndex] else { return nil }
        return group
    }

    /// Rows the pane wants (`desired_height`, `tasks_pane.rs:1168-1190`):
    /// hidden entirely under 12 terminal rows; one row when empty; else the
    /// entry count capped at min(8, 15% of the view). The upstream `+1`
    /// filter-bar row is absent — the pane's `/` filter is deferred,
    /// recorded in the ledger.
    public func desiredHeight(viewHeight: Int) -> Int {
        if viewHeight < 12 { return 0 }
        let count = visibleRows.count
        if count == 0 { return 1 }
        let fractionCap = Int((Double(viewHeight) * 0.15).rounded(.down))
        let max = Swift.max(1, Swift.min(8, fractionCap))
        return Swift.min(count, max)
    }

    public mutating func toggleGroup(_ group: PagerTaskPaneGroup) {
        if collapsed.contains(group) {
            collapsed.remove(group)
        } else {
            collapsed.insert(group)
        }
        selectedIndex = min(selectedIndex, max(0, visibleRows.count - 1))
    }

    /// The pane's key handling (`panes.rs:312-455`, reduced to the arms
    /// whose backings exist — Enter-opens-the-block-viewer and the `/`
    /// filter are deferred with the ledger entry).
    public mutating func handle(_ event: KeyEvent) -> PagerTasksPaneOutcome {
        // Esc / Ctrl+G close the pane (`panes.rs:319-325` toggle-off arm).
        if event.key == .escape, event.modifiers.isEmpty {
            return .close
        }
        if event.modifiers.contains(.control), controlCharacter(event) == "g" {
            return .close
        }
        if event.key == .tab {
            return .focusPrompt
        }
        switch event.key {
        case .up:
            guard selectedIndex > 0 else { return .consumed }
            selectedIndex -= 1
            return .redraw
        case .down:
            guard selectedIndex < visibleRows.count - 1 else { return .consumed }
            selectedIndex += 1
            return .redraw
        case .left:
            // Collapse the selected header (`panes.rs:327-337`).
            if let group = selectedHeaderGroup, !collapsed.contains(group) {
                toggleGroup(group)
                return .redraw
            }
            return .consumed
        case .right:
            if let group = selectedHeaderGroup, collapsed.contains(group) {
                toggleGroup(group)
                return .redraw
            }
            return .consumed
        case .enter:
            if let group = selectedHeaderGroup {
                toggleGroup(group)
                return .redraw
            }
            return .consumed
        case .char(let character):
            switch String(character).lowercased() {
            case "x":
                // Kill the selected entry through its backing
                // (`panes.rs:384-420`); a finished entry has no target.
                if let action = selectedEntry?.killAction {
                    return .action(action)
                }
                return .consumed
            case "y":
                if let action = selectedEntry?.copyAction {
                    return .action(action)
                }
                return .consumed
            default:
                return .consumed
            }
        default:
            return .consumed
        }
    }

    private func controlCharacter(_ event: KeyEvent) -> String? {
        switch event.key {
        case .char(let value): return String(value).lowercased()
        default: return event.character.map { String($0).lowercased() }
        }
    }
}

/// Paint the pane band: group headers (`▾ Subagents 2`), entries with a
/// selection band while focused, and the right-aligned elapsed column.
/// The window follows the selection when the band is shorter than the row
/// list.
func drawTasksPane(
    _ pane: PagerTasksPaneState,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) {
    guard area.height > 0, area.width > 0 else { return }
    let rows = pane.visibleRows
    if rows.isEmpty {
        _ = paintSpans(
            &buffer,
            spans: [PagerStyledSpan(text: "  No background work", foreground: theme.grayDim)],
            x: area.x, y: area.y, limit: area.right, background: theme.bgBase
        )
        return
    }
    var start = 0
    if pane.selectedIndex >= area.height {
        start = pane.selectedIndex - area.height + 1
    }
    start = min(start, max(0, rows.count - area.height))
    for (offset, rowIndex) in (start..<min(rows.count, start + area.height)).enumerated() {
        let y = area.y + offset
        let isSelected = rowIndex == pane.selectedIndex && pane.focused
        let background = isSelected ? theme.bgVisual : theme.bgBase
        paintBlank(
            &buffer,
            area: TerminalRect(x: area.x, y: y, width: area.width, height: 1),
            foreground: theme.textPrimary,
            background: background
        )
        var spans: [PagerStyledSpan]
        var elapsed: String?
        switch rows[rowIndex] {
        case .header(let group, let count, let collapsed):
            spans = [
                PagerStyledSpan(
                    text: collapsed ? "\(PagerGlyphs.chevronRight) " : "\(PagerGlyphs.chevronDown) ",
                    foreground: theme.gray
                ),
                PagerStyledSpan(text: group.label, foreground: theme.textSecondary, style: [.bold]),
                PagerStyledSpan(text: "  \(count)", foreground: theme.grayDim),
            ]
        case .entry(let index):
            let entry = pane.entries[index]
            spans = [PagerStyledSpan(
                text: entry.running ? "\(PagerGlyphs.filledDot) " : "  ",
                foreground: entry.running ? theme.accentRunning : theme.grayDim
            )]
            spans.append(contentsOf: entry.spans)
            elapsed = entry.elapsed
        }
        _ = paintSpans(
            &buffer,
            spans: spans,
            x: area.x + 1,
            y: y,
            limit: area.right - 1,
            background: background
        )
        if let elapsed {
            let width = UnicodeDisplayWidth.width(of: elapsed)
            if width + 2 < area.width {
                _ = paintSpans(
                    &buffer,
                    spans: [PagerStyledSpan(text: elapsed, foreground: theme.grayDim)],
                    x: area.right - width - 1,
                    y: y,
                    limit: area.right,
                    background: background
                )
            }
        }
    }
}
