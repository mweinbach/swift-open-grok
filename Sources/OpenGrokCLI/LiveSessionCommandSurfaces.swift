// LiveSessionCommandSurfaces.swift
//
// The overlays and pure helpers behind the session-scoped slash commands the
// renderer registers: `/jump` and `/delete`.
//
// `LiveSessionOverlays.swift` holds the `/resume` and `/rewind` pickers; this
// file is separate so the two waves do not contend over one file, and because
// what lives here is renderer-facing rather than store-facing.
//
// Rust reference:
//   * `slash/commands/jump.rs` — `/jump` opens a turn picker and is
//     `ModeSupport::FullscreenOnly` ("minimal scrolls with your terminal's
//     native scrollback").
//   * `slash/commands/delete.rs` — `/delete` removes the session and returns
//     home; it errors when there is no active session.

import Foundation
import OpenGrokPagerRender

// MARK: - Jump

enum LiveJumpPicker {
    static let overlayID = "jump"

    /// One row per user prompt, newest first.
    ///
    /// Row IDs are the *block index* into the rendered conversation rather than
    /// the prompt number, because the only thing the selection handler does with
    /// the answer is scroll to that block. Carrying the index the caller already
    /// needs removes a lookup that could go stale between building the overlay
    /// and acting on it — the transcript grows while a modal is open.
    ///
    /// The turn list is `pagerTimelineTurnBlockIndices` — the same
    /// enumeration the timeline rail's geometry partitions — so the two
    /// navigators can never disagree about what a turn is (upstream's
    /// counterpart: both `/jump` and the rail read `ScrollbackState::turns`,
    /// `dispatch/jump.rs:22` and `agent_view/render.rs:1209-1213`).
    static func overlay(items: [PagerConversationItem]) -> PagerOverlay {
        var rows: [PagerListRow] = []
        for (turn, index) in pagerTimelineTurnBlockIndices(items).enumerated() {
            guard case .message(let message) = items[index] else { continue }
            rows.append(PagerListRow(
                id: String(index),
                label: LivePagerOverlayText.singleLine(message.text),
                detail: "turn \(turn + 1)"
            ))
        }
        return PagerOverlay.list(
            id: overlayID,
            title: "Jump to a turn",
            rows: rows.isEmpty
                ? [PagerListRow(
                    id: "none",
                    label: "No turns in this conversation yet",
                    isSelectable: false
                )]
                : rows.reversed(),
            isFilterable: true,
            hints: [
                PagerOverlayHint(key: "↑↓", label: "select"),
                PagerOverlayHint(key: "type", label: "filter"),
                PagerOverlayHint(key: "enter", label: "jump"),
                PagerOverlayHint(key: "esc", label: "cancel"),
            ]
        )
    }
}

// MARK: - Delete

enum LiveSessionDeleteConfirmation {
    static let overlayID = "delete-session"
    /// The row id the renderer treats as "yes". Anything else cancels, so a
    /// mis-parsed id can only ever fail closed.
    static let confirmRowID = "confirm"

    /// Deleting a transcript is not undoable and there is no second copy, so it
    /// takes an explicit second step. This is the same shape as the `Ctrl+N`
    /// confirmation upstream requires for discarding a session
    /// (`defaults.rs:758`), moved onto a modal because a command has no chord to
    /// re-press.
    static func overlay(sessionID: String, itemCount: Int) -> PagerOverlay {
        PagerOverlay.list(
            id: overlayID,
            title: "Delete this session?",
            rows: [
                PagerListRow(
                    id: confirmRowID,
                    label: "Delete \(String(sessionID.prefix(8))) and its \(itemCount) stored item"
                        + (itemCount == 1 ? "" : "s"),
                    detail: "not undoable",
                    summary: "Also removes this session's rewind snapshots."
                ),
                PagerListRow(id: "cancel", label: "Keep it", detail: "esc"),
            ],
            hints: [
                PagerOverlayHint(key: "↑↓", label: "select"),
                PagerOverlayHint(key: "enter", label: "confirm"),
                PagerOverlayHint(key: "esc", label: "cancel"),
            ]
        )
    }
}
