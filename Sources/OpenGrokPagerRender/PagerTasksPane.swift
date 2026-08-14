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
// styled spans; this side owns grouping, collapse, selection, filtering,
// and the per-key affordances a generic list cannot carry: `x` kills the
// selected entry through whichever backing owns it, `y` copies a bg task's
// output, Enter toggles a group header or opens the selected entry's
// viewer, `f` opens the filter bar, Tab hands focus back to the prompt.
//
// `/` (Search) is DEFERRED on purpose. Upstream's `ListPane` runs two
// input-bar modes (`list_pane/state/mod.rs:171-205`): `f` Filter HIDES
// non-matching rows, while `/` Search keeps every row visible, highlights
// the match spans, and jumps to the nearest match
// (`list_pane/state/methods.rs:2118-2140`). Shipping `/` with Filter's
// hide semantics would bind the key to upstream's OTHER meaning — a
// wrong-meaning key is worse than an absent one — so `/` lands when span
// highlighting and match-jumping do. Recorded in the ledger.

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

/// What `x` (kill), `y` (copy), or Enter (open) resolves to for an entry —
/// one case per backed affordance (`panes.rs:384-420` for the kill arms,
/// `:422-430` for the stdout copy, `:339-383` for the open arms).
public enum PagerTaskPaneAction: Sendable, Equatable {
    case killBgTask(taskID: String)
    case killSubagent(subagentID: String)
    case cancelScheduled(taskID: String)
    /// Rides the slash dispatch exactly as upstream does
    /// (`SendSlashCommandPreservingDraft("/workflow stop <name>")`).
    case stopWorkflow(name: String)
    case copyBgTaskOutput(taskID: String)
    /// Enter on a bg-task or monitor row: the block viewer over its stdout
    /// (`panes.rs:344-360`). No running gate upstream and none here — a
    /// finished task's output is exactly what a user wants to read back.
    case openBgTaskOutput(taskID: String)
    /// Enter on a workflow row (`panes.rs:373-377`, `open_workflow_detail`).
    case openWorkflowDetail(name: String)
}

/// Hit-test entry identity for inline buttons (`kill_button_rects` and `view_button_rects`).
public enum PagerTaskEntryId: Sendable, Equatable, Hashable {
    case bgTask(String)
    case subagent(String)
    case scheduled(String)
    case workflow(String)
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
    /// `y` target; nil when there is nothing to copy — upstream gates the
    /// copy on `!task.stdout.is_empty()` (`panes.rs:422-430`), so a row with
    /// no output advertises nothing.
    public var copyAction: PagerTaskPaneAction?
    /// Enter target; nil for the rows upstream opens nothing for (Scheduled,
    /// `panes.rs:371`) and for the subagent fullscreen this port lacks.
    public var openAction: PagerTaskPaneAction?
    /// What the `f` filter matches against — upstream's `search_text`, which
    /// is the row's label (`tasks_pane.rs:305-312`; the `Task ` prefix is
    /// baked into the label there precisely so it stays searchable).
    /// Defaults to this entry's concatenated span text so a new call site
    /// cannot silently ship a row the filter can never match; that default
    /// is a superset of upstream's label (it also carries the trailing
    /// status word), a recorded divergence.
    public var searchText: String

    public init(
        id: String,
        group: PagerTaskPaneGroup,
        spans: [PagerStyledSpan],
        elapsed: String? = nil,
        running: Bool = false,
        killAction: PagerTaskPaneAction? = nil,
        copyAction: PagerTaskPaneAction? = nil,
        openAction: PagerTaskPaneAction? = nil,
        searchText: String? = nil
    ) {
        self.id = id
        self.group = group
        self.spans = spans
        self.elapsed = elapsed
        self.running = running
        self.killAction = killAction
        self.copyAction = copyAction
        self.openAction = openAction
        self.searchText = searchText ?? spans.map(\.text).joined()
    }

    public var entryId: PagerTaskEntryId {
        switch group {
        case .workflows: return .workflow(id)
        case .subagents: return .subagent(id)
        case .tasks: return .bgTask(id)
        case .watchers: return .scheduled(id)
        }
    }
}

/// One visible row: a collapsible group header or an entry (by index into
/// `entries`).
public enum PagerTaskPaneRow: Sendable, Equatable {
    case header(group: PagerTaskPaneGroup, count: Int, collapsed: Bool)
    case entry(index: Int)
}

/// Hit-test button geometry for tasks pane inline buttons.
public struct PagerTaskButtonRect: Sendable, Equatable, Hashable {
    public var id: PagerTaskEntryId
    public var rect: TerminalRect

    public init(id: PagerTaskEntryId, rect: TerminalRect) {
        self.id = id
        self.rect = rect
    }
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
    /// The `f` bar's live buffer while it is open, `nil` when closed —
    /// upstream's `input_mode()` (`list_pane/state/mod.rs:171-180`), the
    /// flag every other key arm is gated on.
    public private(set) var filterQuery: String?
    /// Upstream's `matcher` (`list_pane/state/methods.rs:2107-2118`): rebuilt
    /// live on every keystroke, KEPT when Enter accepts, dropped when Esc
    /// cancels. `visibleRows` reads this and not `filterQuery` because the
    /// list restructures as you type, before anything is accepted.
    public private(set) var acceptedFilter: String?
    public var killButtonRects: [PagerTaskButtonRect] = []
    public var viewButtonRects: [PagerTaskButtonRect] = []

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
        clampSelection(preferring: selectedID)
    }

    /// Headers for every non-empty group, then that group's entries unless
    /// collapsed — the flat list the renderer paints and the selection
    /// walks.
    ///
    /// An active `f` matcher hides non-matching entries, and with them any
    /// header left holding nothing. Upstream filters the flat item list
    /// including headers (a header's `search_text` is its group label,
    /// `tasks_pane.rs:305-312`), so upstream can leave a matching header
    /// stranded above zero rows; here that header would be a claim about a
    /// group the pane is no longer showing, so it goes. Recorded divergence.
    public var visibleRows: [PagerTaskPaneRow] {
        var rows: [PagerTaskPaneRow] = []
        let needle = acceptedFilter.map { $0.lowercased() }
        for group in PagerTaskPaneGroup.allCases {
            let indices = entries.indices.filter { index in
                guard entries[index].group == group else { return false }
                guard let needle, !needle.isEmpty else { return true }
                // Case-insensitive substring, not upstream's regex
                // (`ListMatcher::new(.., QueryKind::Regex, ..)`): a typo'd
                // regex there silently matches nothing, and the pane has no
                // place to report a compile error. Recorded divergence.
                return entries[index].searchText.lowercased().contains(needle)
            }
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
    /// entry count capped at min(8, 15% of the view), PLUS one row while the
    /// filter bar is open or a matcher is accepted (`tasks_pane.rs:1181-1190`
    /// — the bar is carved out of the bottom of the area, so without the
    /// extra row pressing `f` would silently drop the last entry).
    public func desiredHeight(viewHeight: Int) -> Int {
        if viewHeight < 12 { return 0 }
        let bar = (filterQuery != nil || acceptedFilter != nil) ? 1 : 0
        let count = visibleRows.count
        // Upstream returns 1 before adding the bar because its `count` is the
        // unfiltered entry list; ours is the filtered row list, so a query
        // that hides everything still has to leave its own bar on screen —
        // otherwise the user cannot see or edit the query doing the hiding.
        if count == 0 { return 1 + bar }
        let fractionCap = Int((Double(viewHeight) * 0.15).rounded(.down))
        let max = Swift.max(1, Swift.min(8, fractionCap))
        return Swift.min(count, max) + bar
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
    /// whose backings exist — the subagent-fullscreen open and the `/`
    /// search bar are deferred with the ledger entry).
    public mutating func handle(_ event: KeyEvent) -> PagerTasksPaneOutcome {
        // Ctrl+G first, and deliberately NOT behind the filter-bar guard:
        // upstream checks `ActionId::ToggleTasks` before everything else and
        // it is the ONE arm it does not put behind `input_mode().is_none()`
        // (`panes.rs:318-326`, versus the guard sweep at `:327-431`). A user
        // reaching for the toggle wants the band gone, not a control byte
        // swallowed by a text field they would then have to Esc out of.
        if event.modifiers.contains(.control), controlCharacter(event) == "g" {
            return .close
        }
        // An open filter bar consumes everything else — that total
        // consumption IS upstream's guard sweep (`methods.rs:1551-1660`,
        // "always consume when input bar is open"), which is why the arms
        // below do not each repeat an `input_mode().is_none()` check.
        if filterQuery != nil {
            return handleFilterBar(event)
        }
        // Esc closes the pane (`panes.rs:319-325` toggle-off arm).
        if event.key == .escape, event.modifiers.isEmpty {
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
            // Enter on an ENTRY opens its viewer (`panes.rs:339-383`): the
            // block viewer for a bg task, the workflow detail for a workflow.
            // Rows upstream opens nothing for (Scheduled) carry no target.
            if let action = selectedEntry?.openAction {
                return .action(action)
            }
            return .consumed
        case .char(let character):
            // `f` opens the filter bar (`methods.rs:1672-1677`). Upstream
            // ignores it while the pane holds no entries at all
            // (`tasks_pane.rs:1213-1216`), and so does this. `F` (follow) and
            // `/` (search) are not bound — see the file header.
            if character == "f", event.modifiers.isEmpty {
                guard !entries.isEmpty else { return .consumed }
                // Reopening on top of a live matcher keeps the buffer text
                // (`open_input`, `methods.rs:1873-1889`), so `f` is a way
                // back into the query you are already filtering by.
                filterQuery = acceptedFilter ?? ""
                return .redraw
            }
            switch String(character).lowercased() {
            case "x":
                // Kill the selected entry through its backing
                // (`panes.rs:384-420`); a finished entry has no target.
                if let action = selectedEntry?.killAction {
                    return .action(action)
                }
                return .consumed
            case "y":
                // Copy the selected bg task's stdout (`panes.rs:422-430`).
                // The builder sets a target only when the snapshot holds
                // output, so a `y` that fires always has bytes to write.
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

    /// The filter bar's own key handling (`methods.rs:1551-1660`, the
    /// Search/Filter branch). Every key is consumed while it is open.
    private mutating func handleFilterBar(_ event: KeyEvent) -> PagerTasksPaneOutcome {
        guard let query = filterQuery else { return .consumed }
        // The row the user was on, so the selection can land back on it once
        // the visible set changes under them.
        let anchor = selectedEntry?.id
        if event.modifiers.contains(.control), let control = controlCharacter(event) {
            switch control {
            case "c":
                // Ctrl+C clears a non-empty query and closes an empty one
                // (`methods.rs:1626-1634`) — two presses to get out, so a
                // half-typed query is never lost to a single keystroke.
                if query.isEmpty {
                    cancelFilter(anchor: anchor)
                } else {
                    applyFilter("", anchor: anchor)
                }
                return .redraw
            case "w":
                // Ctrl+W twins Backspace: closes on empty (`methods.rs:1636-1641`),
                // otherwise deletes the trailing word the way the textarea it
                // routes to would.
                if query.isEmpty {
                    cancelFilter(anchor: anchor)
                } else {
                    applyFilter(droppingTrailingWord(of: query), anchor: anchor)
                }
                return .redraw
            default:
                return .consumed
            }
        }
        switch event.key {
        case .enter:
            // Accept: the bar closes, the matcher survives it (`accept_input`,
            // `methods.rs:1893-1907`); an empty query accepts nothing.
            filterQuery = nil
            acceptedFilter = query.isEmpty ? nil : query
            clampSelection(preferring: anchor)
            return .redraw
        case .escape:
            cancelFilter(anchor: anchor)
            return .redraw
        case .backspace:
            // Backspace on an empty query closes the bar, nvim-style
            // (`methods.rs:1636-1641`).
            if query.isEmpty {
                cancelFilter(anchor: anchor)
            } else {
                applyFilter(String(query.dropLast()), anchor: anchor)
            }
            return .redraw
        case .char(let character):
            // The bar is single-line: upstream strips `\n`/`\r` out of the
            // textarea after every keystroke (`methods.rs:1645-1655`), so a
            // bracketed-paste newline can never split the query.
            guard event.modifiers.subtracting(.shift).isEmpty, !character.isNewline else {
                return .consumed
            }
            applyFilter(query + String(character), anchor: anchor)
            return .redraw
        default:
            return .consumed
        }
    }

    /// Rebuild the live matcher from the bar's buffer (`apply_input_buffer`,
    /// `methods.rs:2107-2118`): an empty query means no matcher at all.
    private mutating func applyFilter(_ query: String, anchor: String?) {
        filterQuery = query
        acceptedFilter = query.isEmpty ? nil : query
        clampSelection(preferring: anchor)
    }

    /// Esc, or Ctrl+C/Backspace on an empty query: the bar closes AND the
    /// matcher goes with it (`cancel_input`, `methods.rs:1910-1915`).
    private mutating func cancelFilter(anchor: String?) {
        filterQuery = nil
        acceptedFilter = nil
        clampSelection(preferring: anchor)
    }

    private func droppingTrailingWord(of query: String) -> String {
        var remaining = Substring(query)
        while let last = remaining.last, last == " " { remaining = remaining.dropLast() }
        while let last = remaining.last, last != " " { remaining = remaining.dropLast() }
        return String(remaining)
    }

    /// Keep the selection on the same entry while it survives, otherwise on
    /// whatever row now sits at that index. The clamp is the load-bearing
    /// half: a filter that hides the selected row must not leave the index
    /// pointing past the end of the list the renderer is about to paint.
    private mutating func clampSelection(preferring id: String?) {
        let rows = visibleRows
        if let id,
           let index = rows.firstIndex(where: { row in
               if case .entry(let entryIndex) = row { return entries[entryIndex].id == id }
               return false
           }) {
            selectedIndex = index
            return
        }
        selectedIndex = Swift.min(Swift.max(0, selectedIndex), Swift.max(0, rows.count - 1))
    }

    private func controlCharacter(_ event: KeyEvent) -> String? {
        switch event.key {
        case .char(let value): return String(value).lowercased()
        default: return event.character.map { String($0).lowercased() }
        }
    }
}

/// Paint the pane band: group headers (`▾ Subagents 2`), entries with a
/// selection band while focused, the right-aligned elapsed column, and the
/// filter bar on the bottom row when one is open or accepted. The window
/// follows the selection when the band is shorter than the row list.
public func drawTasksPane(
    _ pane: inout PagerTasksPaneState,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) {
    guard area.height > 0, area.width > 0 else { return }
    pane.killButtonRects.removeAll()
    pane.viewButtonRects.removeAll()
    // The bar is carved out of the BOTTOM of the area the pane was given,
    // exactly as `ListPane` does (`list_pane/render.rs:94-108`); the matching
    // `+1` lives in `desiredHeight`.
    let barVisible = pane.filterQuery != nil || pane.acceptedFilter != nil
    let listHeight = barVisible ? area.height - 1 : area.height
    if barVisible {
        drawTasksPaneFilterBar(pane, y: area.bottom - 1, in: area, buffer: &buffer, theme: theme)
    }
    guard listHeight > 0 else { return }
    let rows = pane.visibleRows
    if rows.isEmpty {
        // "No background work" would be a lie while a filter is hiding the
        // work, so the two empties say which one this is.
        let message = pane.acceptedFilter == nil
            ? "  No background work"
            : "  No matching work"
        _ = paintSpans(
            &buffer,
            spans: [PagerStyledSpan(text: message, foreground: theme.grayDim)],
            x: area.x, y: area.y, limit: area.right, background: theme.bgBase
        )
        return
    }
    var start = 0
    if pane.selectedIndex >= listHeight {
        start = pane.selectedIndex - listHeight + 1
    }
    start = min(start, max(0, rows.count - listHeight))
    for (offset, rowIndex) in (start..<min(rows.count, start + listHeight)).enumerated() {
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
        var currentEntry: PagerTaskPaneEntry?
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
            currentEntry = entry
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
        var rightLimit = area.right - 1
        if let entry = currentEntry {
            if entry.killAction != nil || entry.running {
                let kx = area.right - 4
                if kx > area.x + 1 {
                    _ = paintSpans(
                        &buffer,
                        spans: [PagerStyledSpan(text: "[×]", foreground: theme.accentUser)],
                        x: kx, y: y, limit: area.right, background: background
                    )
                    pane.killButtonRects.append(PagerTaskButtonRect(id: entry.entryId, rect: TerminalRect(x: kx, y: y, width: 3, height: 1)))
                    rightLimit = kx - 1
                }
            }
            if entry.openAction != nil {
                let vx = (entry.killAction != nil || entry.running) ? area.right - 8 : area.right - 4
                if vx > area.x + 1 {
                    _ = paintSpans(
                        &buffer,
                        spans: [PagerStyledSpan(text: "[⤢]", foreground: theme.textSecondary)],
                        x: vx, y: y, limit: area.right, background: background
                    )
                    pane.viewButtonRects.append(PagerTaskButtonRect(id: entry.entryId, rect: TerminalRect(x: vx, y: y, width: 3, height: 1)))
                    rightLimit = vx - 1
                }
            }
        }
        if let elapsed {
            let width = UnicodeDisplayWidth.width(of: elapsed)
            if width + 2 < rightLimit - area.x {
                _ = paintSpans(
                    &buffer,
                    spans: [PagerStyledSpan(text: elapsed, foreground: theme.grayDim)],
                    x: rightLimit - width,
                    y: y,
                    limit: rightLimit,
                    background: background
                )
            }
        }
    }
}

/// The bottom bar (`list_pane/render.rs:535-598`): while the bar is open it
/// is the left-aligned editable prompt (`InputBarMode::prompt()` is `f>`,
/// `list_pane/state/mod.rs:186-194`); once accepted it is the dim
/// right-aligned matcher status, which is how a filtered pane says why it is
/// showing fewer rows than the user's work.
private func drawTasksPaneFilterBar(
    _ pane: PagerTasksPaneState,
    y: Int,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) {
    guard y >= area.y, y < area.bottom else { return }
    paintBlank(
        &buffer,
        area: TerminalRect(x: area.x, y: y, width: area.width, height: 1),
        foreground: theme.textPrimary,
        background: theme.bgBase
    )
    if let query = pane.filterQuery {
        _ = paintSpans(
            &buffer,
            spans: truncateSpans(
                [
                    PagerStyledSpan(text: "f> ", foreground: theme.gray),
                    PagerStyledSpan(text: query, foreground: theme.textPrimary),
                ],
                to: max(0, area.width - 1)
            ),
            x: area.x + 1,
            y: y,
            limit: area.right,
            background: theme.bgBase
        )
        return
    }
    guard let accepted = pane.acceptedFilter else { return }
    let status = "[filter: \(accepted)]"
    let width = UnicodeDisplayWidth.width(of: status)
    _ = paintSpans(
        &buffer,
        spans: truncateSpans(
            [PagerStyledSpan(text: status, foreground: theme.grayDim)],
            to: max(0, area.width - 1)
        ),
        x: max(area.x, area.right - width - 1),
        y: y,
        limit: area.right,
        background: theme.bgBase
    )
}
