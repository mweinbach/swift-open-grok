// LiveDashboardOverlay.swift
//
// Wave 18 B1-d: the Agent Dashboard roster — the port of `views/dashboard/`
// at pin 650c1db7. B1-w2 rebuilt the row surface on the B1-s state machinery
// (`PagerDashboardState`): grouping with focusable section headers, the
// pinned prefix, the idle fold, subagent overflow, filters, and DORMANT
// on-disk sessions as attachable Inactive rows (upstream parity —
// `dashboard_local_sessions` fills the roster from the session list; the
// port's feed is the same `LiveSessionCatalog` listing `/resume` trusts).
// Enter attaches through the SAME `/resume` machinery as the sessions
// picker; `x` arms/deletes through the close verb (C-1).

import Foundation
import OpenGrokPagerRender

/// One in-process session tab — B1-m's registry entry. Metadata only: the
/// pre-ruled divergence keeps background tabs idle, so a row needs no
/// retained conversation to be truthful.
struct LiveSessionTab: Sendable, Equatable {
    var sessionID: String
    var title: String
    var lastActivity: Date
    /// The tab's working directory — `Grouping::Directory`'s key. Every
    /// in-process tab shares the launch cwd (single runtime stack); dormant
    /// rows carry their own persisted cwds, which is what makes the
    /// directory grouping real.
    var cwd: String = ""
}

enum LiveDashboardOverlay {
    static let overlayID = "dashboard"

    /// Row id prefix for attachable sessions (live AND dormant); the select
    /// arm strips it and rides `/resume <id>`.
    static let attachPrefix = "attach:"
    /// The `x` close verb's row-action prefix (B1 C-1): the dispatched rowID
    /// is `close:attach:<sessionID>`.
    static let closePrefix = "close"
    /// Non-selectable child rows under the active session.
    static let subagentPrefix = "subagent:"
    /// Focusable section headers; Enter/Left/Right toggle collapse.
    static let sectionPrefix = "section:"
    /// The Idle group's fold toggle row (`idleOverflow`, render.rs:1424-1487).
    static let idleOverflowRowID = "idle-overflow"

    /// Build the roster from the live registry + the active session's
    /// subagents + the dormant catalog listings, through the full B1-s
    /// state machinery. Pure — every seam the composition's chords mutate
    /// (`state`) is a parameter.
    static func overlay(
        tabs: [LiveSessionTab],
        activeSessionID: String,
        activeTurnRunning: Bool,
        activeNeedsInput: Bool = false,
        subagents: [LiveSubagentSnapshot],
        dormant: [LiveSessionListing] = [],
        state: PagerDashboardState = PagerDashboardState(),
        armedCloseSessionID: String? = nil,
        searchQuery: String? = nil,
        now: Date = Date()
    ) -> PagerOverlay {
        let lines = state.lines(
            from: state.rows(from: rowInputs(
                tabs: tabs,
                activeSessionID: activeSessionID,
                activeTurnRunning: activeTurnRunning,
                activeNeedsInput: activeNeedsInput,
                subagents: subagents,
                dormant: dormant,
                now: now
            )),
            now: now
        )

        var rows: [PagerListRow] = []
        rows.reserveCapacity(lines.count)
        for line in lines {
            switch line {
            case .pinnedHeader(let count):
                rows.append(sectionRow(
                    id: sectionPrefix + "pinned",
                    label: "Pinned (\(count))",
                    collapsed: state.isCollapsed(.pinned)
                ))
            case .divider:
                rows.append(PagerListRow(id: "divider", label: "", isSelectable: false))
            case .header(let headerState, let count):
                rows.append(sectionRow(
                    id: sectionPrefix + token(for: headerState),
                    label: "\(headerState.groupLabel) (\(count))",
                    collapsed: state.isCollapsed(.state(headerState))
                ))
            case .row(let row):
                rows.append(listRow(
                    for: row,
                    activeSessionID: activeSessionID,
                    activeTurnRunning: activeTurnRunning,
                    armedCloseSessionID: armedCloseSessionID
                ))
            case .idleOverflow(let hidden, let expanded):
                // Upstream's fold line (`render.rs:1424-1487`): a focusable
                // toggle at the group's end.
                rows.append(PagerListRow(
                    id: idleOverflowRowID,
                    label: expanded ? "  show fewer idle" : "  \u{2026} \(hidden) more idle"
                ))
            }
        }

        // The search bar rides the modal title — the port's modal has no
        // spare chrome row; a live query the user cannot see would be the
        // invisible-state class. Recorded divergence: upstream paints a
        // dedicated search bar row.
        var title = "Agent Dashboard"
        if let searchQuery {
            title += " \u{2014} /\(searchQuery)"
        } else if state.filter.isActive {
            title += " \u{2014} filtered"
        }

        var overlay = PagerOverlay.list(
            id: overlayID,
            title: title,
            rows: rows,
            // The state machinery owns filtering (Ctrl+/ search, the a:/s:
            // grammar); leaving the list's own fuzzy filter on would
            // double-filter the same keystrokes.
            isFilterable: false,
            hints: [
                PagerOverlayHint(key: "enter", label: "attach"),
                PagerOverlayHint(key: "x", label: "delete"),
                PagerOverlayHint(key: "ctrl+t", label: "pin"),
                PagerOverlayHint(key: "ctrl+g", label: "group"),
                PagerOverlayHint(key: "ctrl+/", label: "search"),
                PagerOverlayHint(key: "esc", label: "close"),
            ]
        )
        if case .list(var list) = overlay.content {
            // `x` deletes the selected session row — upstream's Ctrl+X delete
            // leg (`dispatch_dashboard_stop`, dispatch/dashboard.rs:1980-2062).
            // Bare `x` is safe here because the list's own filter is off.
            list.rowActions = [PagerListRowAction(key: "x", rowIDPrefix: closePrefix)]
            // Open on the first SESSION row, not the section header above
            // it — Enter's first meaning is attach, and the header is still
            // one ↑ away. (Only the composition's in-place rebuild preserves
            // a moved cursor; a fresh open always re-anchors here.)
            if let first = rows.firstIndex(where: { row in
                row.isSelectable && row.id.hasPrefix(attachPrefix)
            }) {
                list.selectedIndex = first
            }
            overlay.content = .list(list)
        }
        return overlay
    }

    // MARK: Row building

    /// Classification per `classify_top_level` (`row.rs:375-393`) reduced to
    /// the signals this runtime grounds: the ACTIVE session is needs-input
    /// (pending permission/question) or working (turn running) or idle;
    /// background tabs are IDLE BY CONSTRUCTION (the pre-ruled divergence —
    /// no parallel top-level turns in one process); dormant catalog rows are
    /// INACTIVE (`roster_activity_to_state`, `row.rs:258-269`). No session
    /// row is ever Completed/Failed/Blocked — upstream's classifier never
    /// emits them for live rows either.
    static func rowInputs(
        tabs: [LiveSessionTab],
        activeSessionID: String,
        activeTurnRunning: Bool,
        activeNeedsInput: Bool,
        subagents: [LiveSubagentSnapshot],
        dormant: [LiveSessionListing],
        now: Date = Date()
    ) -> [PagerDashboardRowInput] {
        var inputs: [PagerDashboardRowInput] = []
        let liveIDs = Set(tabs.map(\.sessionID))
        for tab in tabs {
            let isActive = tab.sessionID == activeSessionID
            let rowState: PagerDashboardRowState
            if isActive {
                rowState = activeNeedsInput ? .needsInput : (activeTurnRunning ? .working : .idle)
            } else {
                rowState = .idle
            }
            inputs.append(PagerDashboardRowInput(
                id: .session(tab.sessionID),
                label: tab.title,
                detail: shortID(tab.sessionID),
                state: rowState,
                cwd: tab.cwd,
                lastChangeAt: tab.lastActivity
            ))
            guard isActive else { continue }
            // The active session's subagent children — a recorded ADDITION
            // over upstream's live path (`build_rows_with_roster` lists no
            // subagent rows); the port keeps them per the B1-d entry.
            // Children must directly follow their parent: `build_clusters`
            // glues on input adjacency.
            let children = subagents.sorted { a, b in
                let (aRunning, bRunning) = (a.status == "running", b.status == "running")
                if aRunning != bRunning { return aRunning }
                return a.startedAt > b.startedAt
            }
            for child in children {
                let (typeLabel, description) = LivePagerTasksBlock.subagentLabel(
                    type: child.subagentType,
                    description: child.description
                )
                inputs.append(PagerDashboardRowInput(
                    id: .subagent(parent: tab.sessionID, child: child.subagentID),
                    label: description.isEmpty ? typeLabel : "\(typeLabel) \u{00B7} \(description)",
                    detail: child.status,
                    state: classifySubagent(child.status),
                    cwd: tab.cwd,
                    lastChangeAt: child.startedAt,
                    indent: 1,
                    parentLabel: tab.title
                ))
            }
        }
        // Dormant on-disk sessions, skipping ids already live in this
        // process (`append_roster_rows` skips local ids, `row.rs:145-167`).
        // Label chain: title, else cwd basename, else the id — sanitized to
        // one line.
        for listing in dormant where !liveIDs.contains(listing.sessionID) {
            let title = listing.title.flatMap { title -> String? in
                let line = LivePagerTasksBlock.firstNonEmptyLine(title)
                return line.isEmpty ? nil : line
            }
            let basename = (listing.workingDirectory as NSString).lastPathComponent
            inputs.append(PagerDashboardRowInput(
                id: .dormant(listing.sessionID),
                label: title ?? (basename.isEmpty ? listing.sessionID : basename),
                detail: listing.model,
                state: .inactive,
                cwd: listing.workingDirectory,
                lastChangeAt: listing.lastActivityAt
            ))
        }
        return inputs
    }

    /// `classify_subagent` (`row.rs:430-442`).
    static func classifySubagent(_ status: String) -> PagerDashboardRowState {
        switch status {
        case "running": return .working
        case "failed", "cancelled", "canceled", "error": return .failed
        default: return .completed
        }
    }

    private static func sectionRow(id: String, label: String, collapsed: Bool) -> PagerListRow {
        // Selectable ON PURPOSE: upstream's section headers are focusables
        // (`render.rs:1490-1516`) — the cursor lands on them and
        // Enter/Left/Right toggle collapse. `isHeader` would force
        // non-selectable, so these are regular rows wearing the chevron.
        PagerListRow(
            id: id,
            label: "\(collapsed ? "\u{25B8}" : "\u{25BE}") \(label)"
        )
    }

    private static func listRow(
        for row: PagerDashboardRow,
        activeSessionID: String,
        activeTurnRunning: Bool,
        armedCloseSessionID: String?
    ) -> PagerListRow {
        switch row.id {
        case .subagent(_, let child):
            if row.isMorePlaceholder {
                return PagerListRow(
                    id: subagentPrefix + child,
                    label: "    \(row.label)",
                    isSelectable: false
                )
            }
            return PagerListRow(
                id: subagentPrefix + child,
                label: "    \u{21B3} \(row.label)",
                detail: row.detail,
                // Peek/attach-to-subagent are deferred surfaces; a row that
                // dispatches nowhere must not be selectable (§4).
                isSelectable: false
            )
        case .session(let sessionID), .dormant(let sessionID):
            let isActive = sessionID == activeSessionID
            let stateWord: String
            if isActive {
                stateWord = activeTurnRunning ? "running" : "attached"
            } else {
                switch row.state {
                case .inactive: stateWord = "inactive"
                default: stateWord = "idle"
                }
            }
            // An armed close shows its confirmation ON the row — the port's
            // press-again-no-timer analog of upstream's 2 s arm window
            // (`arm_or_delete`, dispatch/dashboard.rs:2125-2140).
            let detail: String
            if sessionID == armedCloseSessionID {
                detail = "press x again to delete"
            } else {
                let meta = row.cwdDisplay.isEmpty ? (row.detail ?? "") : row.cwdDisplay
                detail = meta.isEmpty
                    ? stateWord
                    : "\(meta) \u{00B7} \(stateWord)"
            }
            let marker = isActive ? "\u{25CF} " : "  "
            let pin = row.pinned ? "\u{2299} " : ""
            return PagerListRow(
                id: attachPrefix + sessionID,
                label: marker + pin + row.label,
                detail: detail
            )
        }
    }

    // MARK: Chord-side mapping

    /// Map a painted list-row id back to its state-machinery identity, for
    /// the composition's pin/reorder chords. Live ids are `.session`, the
    /// rest of the attach namespace is `.dormant` — the same split the
    /// builder used going forward.
    static func dashboardRowID(
        forListRowID id: String,
        activeSessionID: String,
        liveSessionIDs: Set<String>
    ) -> PagerDashboardRowID? {
        if id.hasPrefix(attachPrefix) {
            let sessionID = String(id.dropFirst(attachPrefix.count))
            return liveSessionIDs.contains(sessionID)
                ? .session(sessionID)
                : .dormant(sessionID)
        }
        if id.hasPrefix(subagentPrefix) {
            return .subagent(
                parent: activeSessionID,
                child: String(id.dropFirst(subagentPrefix.count))
            )
        }
        return nil
    }

    /// Map a painted section-header row id back to its section key, for the
    /// collapse chords. Nil for anything that is not a header.
    static func sectionKey(forListRowID id: String) -> PagerDashboardSectionKey? {
        guard id.hasPrefix(sectionPrefix) else { return nil }
        let tokenText = String(id.dropFirst(sectionPrefix.count))
        if tokenText == "pinned" { return .pinned }
        return PagerDashboardRowState.parseToken(tokenText).map(PagerDashboardSectionKey.state)
    }

    /// Round-trippable through `parseToken` — the section ids reuse the
    /// filter grammar's state vocabulary rather than inventing a second one.
    static func token(for state: PagerDashboardRowState) -> String {
        switch state {
        case .needsInput: return "needsinput"
        case .working: return "working"
        case .idle: return "idle"
        case .inactive: return "inactive"
        case .completed: return "completed"
        case .failed: return "failed"
        case .blocked: return "blocked"
        }
    }

    private static func shortID(_ id: String) -> String {
        id.count > 8 ? String(id.prefix(8)) : id
    }
}
