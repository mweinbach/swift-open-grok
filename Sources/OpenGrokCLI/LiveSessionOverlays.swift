// LiveSessionOverlays.swift
//
// The `/resume` and `/rewind` pickers, and the command handler bodies behind
// them.
//
// These are built here rather than in the pager because they need the session
// store and the rewind store, which are CLI-layer concerns. The pager owns the
// command registry and the overlay stack; this file gives it two ready-made
// `PagerOverlay` values and a set of pure functions that turn a selection back
// into an action. `LiveModelPicker` follows the same split, and this mirrors it
// deliberately so there is one shape for "a picker backed by live data".
//
// Rust reference: `/resume` opens a filterable session list that also searches
// full content as you type (user guide 17-sessions.md:85-87), and `/rewind`
// lists one entry per user prompt (17-sessions.md:133-150).

import Foundation
import OpenGrokPagerRender
import OpenGrokSamplingTypes

// MARK: - Session picker

enum LiveSessionPicker {
    static let overlayID = "sessions"

    /// Row IDs are session IDs, so `PagerOverlayOutcome.selected(id:rowID:)`
    /// hands the selection straight back without a lookup table.
    static func overlay(
        listings: [LiveSessionListing],
        title: String = "Resume a session"
    ) -> PagerOverlay {
        let rows: [PagerListRow] = listings.map { listing in
            PagerListRow(
                id: listing.sessionID,
                label: listing.title ?? "(untitled)",
                // The detail column carries the id prefix and turn count so the
                // list stays useful when several sessions share a first line —
                // which is common, because a title is just the first prompt.
                detail: "\(String(listing.sessionID.prefix(8)))  "
                    + "\(listing.userMessageCount) turns",
                summary: LiveSessionsComposition.day(listing.lastActivityAt)
            )
        }
        return PagerOverlay.list(
            id: overlayID,
            title: title,
            rows: rows.isEmpty
                ? [PagerListRow(
                    id: "none",
                    label: "No saved sessions",
                    isSelectable: false
                )]
                : rows,
            isFilterable: true,
            hints: [
                PagerOverlayHint(key: "↑↓", label: "select"),
                PagerOverlayHint(key: "type", label: "filter"),
                PagerOverlayHint(key: "enter", label: "resume"),
                PagerOverlayHint(key: "esc", label: "cancel"),
            ]
        )
    }

    /// Rows for a filter query that the built-in fuzzy filter cannot serve.
    ///
    /// `PagerListOverlay.filteredRows` matches on the row's own text, which is
    /// the title — so typing a word that appears only in the *body* of a
    /// session finds nothing. Rust's picker searches full content as you type,
    /// so when the built-in filter comes up empty the caller re-renders the
    /// overlay with the content-search hits from this function instead.
    static func contentSearchRows(
        query: String,
        documents: [LiveSessionDocument],
        limit: Int = 20
    ) -> [PagerListRow] {
        LiveSessionSearch.rank(documents: documents, query: query, limit: limit)
            .map { hit in
                PagerListRow(
                    id: hit.sessionID,
                    label: hit.title ?? "(untitled)",
                    detail: String(hit.sessionID.prefix(8)),
                    summary: hit.snippet
                )
            }
    }
}

// MARK: - Rewind picker

enum LiveRewindPicker {
    static let overlayID = "rewind"

    /// One row per rewind point, newest first.
    ///
    /// Row IDs are the prompt index as a string; the selection handler parses
    /// it back. Points that changed no files are still listed but marked, since
    /// rewinding to one is a history-only operation and the user should be able
    /// to tell that before choosing it.
    static func overlay(points: [LiveRewindPointInfo]) -> PagerOverlay {
        let rows: [PagerListRow] = points.reversed().map { point in
            var detail = "\(point.fileCount) file\(point.fileCount == 1 ? "" : "s")"
            if !point.hasFileChanges { detail = "no file changes" }
            if point.skippedCount > 0 {
                detail += ", \(point.skippedCount) not snapshotted"
            }
            return PagerListRow(
                id: String(point.promptIndex),
                label: point.preview,
                detail: detail,
                summary: LiveSessionsComposition.timestamp(point.createdAt)
            )
        }
        return PagerOverlay.list(
            id: overlayID,
            title: "Rewind to before…",
            rows: rows.isEmpty
                ? [PagerListRow(
                    id: "none",
                    label: "No rewind points recorded yet",
                    isSelectable: false
                )]
                : rows,
            isFilterable: true,
            hints: [
                PagerOverlayHint(key: "↑↓", label: "select"),
                PagerOverlayHint(key: "enter", label: "preview"),
                PagerOverlayHint(key: "esc", label: "cancel"),
            ]
        )
    }
}

// MARK: - Command handlers

/// Bodies for `/rewind`, `/resume` and `/usage`.
///
/// Each returns text or a request the controller acts on, so the pager never
/// has to know how rewind or the session store work.
enum LiveSessionCommands {
    enum Outcome: Sendable, Equatable {
        /// Print this and stay put.
        case message(String)
        /// Open this overlay.
        case overlay(PagerOverlay)
        /// A rewind was applied. The controller truncates its transcript to
        /// `targetPromptIndex` and pre-fills the composer with `promptText`.
        case rewound(targetPromptIndex: Int, promptText: String, summary: String)
    }

    /// `/rewind` with no argument opens the picker; `/rewind <n>` previews;
    /// `/rewind <n> --force` applies.
    ///
    /// The two-step shape is Rust's: a non-forced execute is a pure dry run
    /// that reports what would change and mutates nothing. Restoring files is
    /// not undoable, so it does not happen on a single keystroke.
    static func rewind(
        argument: String,
        rewind coordinator: LiveRewindCoordinator?,
        currentItems: [ConversationItem]
    ) async -> Outcome {
        guard let coordinator else {
            return .message("Rewind is disabled for this session (OPENGROK_REWIND=0).")
        }
        var tokens = argument
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        let force = tokens.contains("--force") || tokens.contains("-f")
        tokens.removeAll { $0 == "--force" || $0 == "-f" }

        var mode = LiveRewindMode.all
        if let index = tokens.firstIndex(where: { $0.hasPrefix("--mode=") }) {
            let raw = String(tokens[index].dropFirst("--mode=".count))
            guard let parsed = LiveRewindMode.parse(raw) else {
                return .message("Unknown rewind mode \"\(raw)\". Use all, files, or conversation.")
            }
            mode = parsed
            tokens.remove(at: index)
        }

        guard let first = tokens.first else {
            return .overlay(LiveRewindPicker.overlay(points: await coordinator.points()))
        }
        guard let target = Int(first) else {
            return .message("Usage: /rewind [<prompt-number>] [--mode=all|files|conversation] [--force]")
        }
        return await apply(
            target: target,
            mode: mode,
            force: force,
            coordinator: coordinator,
            currentItems: currentItems
        )
    }

    /// Shared by the `/rewind <n>` path and the picker's selection handler.
    static func apply(
        target: Int,
        mode: LiveRewindMode,
        force: Bool,
        coordinator: LiveRewindCoordinator,
        currentItems: [ConversationItem]
    ) async -> Outcome {
        let outcome: LiveRewindOutcome
        do {
            outcome = try await coordinator.restore(
                toPromptIndex: target,
                mode: mode,
                force: force,
                currentItems: currentItems
            )
        } catch {
            return .message("\(error)")
        }
        let summary = describe(outcome)
        guard outcome.applied else { return .message(summary) }
        return .rewound(
            targetPromptIndex: outcome.targetPromptIndex,
            promptText: outcome.promptText,
            summary: summary
        )
    }

    static func describe(_ outcome: LiveRewindOutcome) -> String {
        var lines: [String] = []
        let verb = outcome.applied ? "Rewound" : "Would rewind"
        lines.append("\(verb) to before prompt \(outcome.targetPromptIndex): \(outcome.promptText.prefix(57))")

        if outcome.mode != .conversationOnly {
            let files = outcome.applied ? outcome.revertedFiles : outcome.cleanFiles
            if files.isEmpty {
                lines.append("  No files to restore.")
            } else {
                lines.append("  \(files.count) file\(files.count == 1 ? "" : "s"):")
                for path in files.prefix(20) {
                    lines.append("    \(path)")
                }
                if files.count > 20 {
                    lines.append("    … and \(files.count - 20) more")
                }
            }
        }
        if outcome.mode != .filesOnly {
            lines.append("  \(outcome.removedItemCount) conversation items removed.")
        }
        if !outcome.conflicts.isEmpty {
            lines.append("  Skipped — changed outside this session:")
            for conflict in outcome.conflicts.prefix(10) {
                lines.append("    \(conflict.path) (\(conflict.describedReason))")
            }
        }
        if !outcome.unrestorable.isEmpty {
            lines.append("  Not snapshotted, so not restorable:")
            for skip in outcome.unrestorable.prefix(10) {
                lines.append("    \(skip.path) (\(skip.reason.rawValue))")
            }
        }
        if !outcome.applied {
            lines.append("")
            lines.append("Re-run with --force to apply.")
        }
        return lines.joined(separator: "\n")
    }
}
