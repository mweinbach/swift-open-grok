// PagerMinimalFrameHost.swift
//
// Wave 18 B2-M4: the minimal frontend program — the port of
// `xai-grok-pager-minimal/src/lib.rs::draw` (:91-108, the ordered frame
// loop), `welcome.rs::maybe_commit_welcome` (:28-143, the one-shot card),
// and `guard.rs`'s terminal stance (main screen, mouse capture OFF; the
// terminal owns history) at pin 650c1db7.
//
// The host consumes the SAME `PagerRenderState` frames the interactive
// controller already produces — the controller does not know minimal
// exists, mirroring upstream's inversion-of-control seam (`minimal_hook`:
// the pager cannot depend on the minimal crate, so the composition root
// installs the draw hook; here the composition root constructs this host
// instead of the frame renderer). Finalized conversation blocks are
// printed ONCE into the terminal's native scrollback via
// `Terminal.insertBefore` (B2-N) and the M1-M3 pipeline; the pinned live
// viewport holds the uncommitted tail, the turn status, the completions
// dropdown, and the composer.

import Foundation
import OpenGrokMinimalScrollback
import OpenGrokTerminalCore

// MARK: - The ANSI backend over the pager sink

/// `TerminalBackend` that encodes the double-buffer's operations as ANSI
/// over a `PagerTerminalSink` — the bridge that lets B2-N's `Terminal`
/// (insertBefore, viewport moves, diff flush) drive the same byte stream
/// the pager renderer writes to.
///
/// Styling note: minimal's committed content is deliberately
/// terminal-native (named ANSI-16 + reset — the M2 stance), so this encoder
/// maps `TerminalColor` straight to SGR; `indexed`//`rgb` pass through for
/// the themed live-region rows and degrade downstream like any 256/truecolor
/// sequence.
final class MinimalSinkBackend: TerminalBackend {
    private let sink: any PagerTerminalSink
    private let sizeProvider: () -> TerminalSize
    private var cursor = TerminalPoint(x: 0, y: 0)
    private let bridgeWriter: SinkTerminalWriter

    init(sink: any PagerTerminalSink, sizeProvider: @escaping () -> TerminalSize) {
        self.sink = sink
        self.sizeProvider = sizeProvider
        self.bridgeWriter = SinkTerminalWriter(sink: sink)
    }

    var writer: TerminalWriter { bridgeWriter }

    func draw(_ updates: [CellUpdate]) throws {
        guard !updates.isEmpty else { return }
        var out = ""
        var lastAttributes: CellAttributes?
        var lastPosition: TerminalPoint?
        for update in updates.sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) {
            let cell = update.cell
            if cell.skip { continue }
            if lastPosition != TerminalPoint(x: update.x, y: update.y) {
                out += ANSIOutput.moveTo(column: update.x, row: update.y)
            }
            let attributes = CellAttributes(
                style: cell.style, foreground: cell.foreground, background: cell.background
            )
            if attributes != lastAttributes {
                out += Self.sgr(attributes)
                lastAttributes = attributes
            }
            out += cell.grapheme
            lastPosition = TerminalPoint(x: update.x + max(1, cell.displayWidth), y: update.y)
        }
        out += "\u{1B}[0m"
        try sink.write(out)
        if let last = updates.last {
            cursor = TerminalPoint(x: last.x, y: last.y)
        }
    }

    func hideCursor() throws { try sink.write("\u{1B}[?25l") }
    func showCursor() throws { try sink.write("\u{1B}[?25h") }
    func cursorPosition() throws -> TerminalPoint { cursor }

    func setCursorPosition(_ position: TerminalPoint) throws {
        cursor = position
        try sink.write(ANSIOutput.moveTo(column: position.x, row: position.y))
    }

    func clear() throws { try sink.write("\u{1B}[2J") }

    func clearRegion(_ type: ClearType) throws {
        switch type {
        case .all: try sink.write("\u{1B}[2J")
        case .afterCursor: try sink.write(ANSIOutput.clearFromCursorDown)
        case .currentLine: try sink.write("\u{1B}[2K")
        case .untilNewLine: try sink.write("\u{1B}[K")
        }
    }

    /// Scroll the screen up by `n` rows: newlines written from the bottom
    /// row — the portable scroll that pushes the top rows into the
    /// terminal's NATIVE scrollback, which is the entire point of minimal
    /// mode (an `\e[S` scroll-region scroll would discard them instead).
    func appendLines(_ n: Int) throws {
        guard n > 0 else { return }
        let size = sizeProvider()
        try sink.write(
            ANSIOutput.moveTo(column: 0, row: max(0, size.height - 1))
                + String(repeating: "\n", count: n)
        )
    }

    func size() throws -> TerminalSize { sizeProvider() }
    func flush() throws { try sink.flush() }

    /// Compact SGR for a cell's full attributes (reset-then-set, so runs
    /// never inherit stale state).
    private static func sgr(_ attributes: CellAttributes) -> String {
        var codes = ["0"]
        let style = attributes.style
        if style.contains(.bold) { codes.append("1") }
        if style.contains(.dim) { codes.append("2") }
        if style.contains(.italic) { codes.append("3") }
        if style.contains(.underline) { codes.append("4") }
        if style.contains(.blink) { codes.append("5") }
        if style.contains(.reverse) { codes.append("7") }
        if style.contains(.hidden) { codes.append("8") }
        if style.contains(.strike) { codes.append("9") }
        codes.append(contentsOf: colorCodes(attributes.foreground, foreground: true))
        codes.append(contentsOf: colorCodes(attributes.background, foreground: false))
        return "\u{1B}[\(codes.joined(separator: ";"))m"
    }

    private static func colorCodes(_ color: TerminalColor, foreground: Bool) -> [String] {
        let base = foreground ? 30 : 40
        let bright = foreground ? 90 : 100
        switch color {
        case .reset: return []
        case .black: return ["\(base)"]
        case .red: return ["\(base + 1)"]
        case .green: return ["\(base + 2)"]
        case .yellow: return ["\(base + 3)"]
        case .blue: return ["\(base + 4)"]
        case .magenta: return ["\(base + 5)"]
        case .cyan: return ["\(base + 6)"]
        case .white: return ["\(base + 7)"]
        case .brightBlack: return ["\(bright)"]
        case .brightRed: return ["\(bright + 1)"]
        case .brightGreen: return ["\(bright + 2)"]
        case .brightYellow: return ["\(bright + 3)"]
        case .brightBlue: return ["\(bright + 4)"]
        case .brightMagenta: return ["\(bright + 5)"]
        case .brightCyan: return ["\(bright + 6)"]
        case .brightWhite: return ["\(bright + 7)"]
        case .indexed(let n): return ["\(foreground ? 38 : 48)", "5", "\(n)"]
        case .rgb(let r, let g, let b): return ["\(foreground ? 38 : 48)", "2", "\(r)", "\(g)", "\(b)"]
        }
    }
}

/// `TerminalWriter` face of the sink, for the terminal's raw-ANSI paths.
private final class SinkTerminalWriter: TerminalWriter {
    private let sink: any PagerTerminalSink
    init(sink: any PagerTerminalSink) { self.sink = sink }
    func write(bytes: [UInt8]) throws { try sink.write(bytes: bytes) }
    func write(string: String) throws { try sink.write(string) }
    func flush() throws { try sink.flush() }
}

// MARK: - The frame host

/// Session facts the one-shot welcome card prints (`welcome.rs:57-92`).
public struct MinimalWelcomeCardInfo: Sendable, Equatable {
    public var version: String
    public var workingDirectory: String
    public var model: String?

    public init(version: String, workingDirectory: String, model: String? = nil) {
        self.version = version
        self.workingDirectory = workingDirectory
        self.model = model
    }
}

public final class PagerMinimalFrameHost {
    let terminal: Terminal
    private let sink: any PagerTerminalSink
    private let transcript = MinimalTranscript()
    private let welcome: MinimalWelcomeCardInfo?
    private var welcomePending: Bool
    private let collapseThinking: Bool
    private let maxCommitRows: Int
    /// Entries this host marked pending, so a resolved prompt clears exactly
    /// the marks it set (the per-frame sync of `commit.rs:594-600`).
    private var pendingMarked: Set<MinimalEntryID> = []
    /// Folded-commit ids queued by Ctrl+E / `/expand` for a full re-print
    /// (`minimal_state.pending_expand`, drained by `expand_pending`,
    /// `commit.rs:518-582`).
    private var pendingExpand: [MinimalEntryID] = []

    /// `collapseThinking` is `[terminal] minimal_collapse_thinking` and
    /// `maxCommitRows` is `[terminal] minimal_max_commit_rows` (default 2000,
    /// `config.rs:1445-1446`).
    public init(
        sink: any PagerTerminalSink,
        sizeProvider: @escaping () -> TerminalSize,
        welcome: MinimalWelcomeCardInfo?,
        collapseThinking: Bool = false,
        maxCommitRows: Int = 2000
    ) throws {
        self.sink = sink
        self.welcome = welcome
        self.welcomePending = welcome != nil
        self.collapseThinking = collapseThinking
        self.maxCommitRows = maxCommitRows
        let backend = MinimalSinkBackend(sink: sink, sizeProvider: sizeProvider)
        let size = sizeProvider()
        self.terminal = try Terminal(
            backend: backend,
            options: TerminalOptions(viewport: .inline(
                height: min(MinimalLiveRender.minimalLiveRowsDefault, max(1, size.height - 1))
            ))
        )
    }

    /// The guard.rs stance is what `begin` does NOT emit: no alternate
    /// screen, no mouse capture — the terminal owns history and its native
    /// selection/scroll gestures keep working. (K6's other half — never
    /// re-emitting history through resize helpers — holds structurally: the
    /// host's only scrollback writes go through `insertBefore`, and the
    /// guard test scans these sources for the forbidden helpers.)
    public func begin() throws {
        try terminal.autoresize()
    }

    /// Arm or disarm the one-shot welcome card. The composition root arms it
    /// only for a FRESH session (upstream sets the pending flag at session
    /// creation, `welcome.rs:11-13`) — a resumed transcript replays into
    /// scrollback instead and must not get a second card.
    public func setWelcomePending(_ pending: Bool) {
        welcomePending = pending && welcome != nil
    }

    /// Queue the most-recently committed FOLDED block for a full re-print
    /// (`minimal_expand_last`, `app_view.rs:4697-4712`): committed terminal
    /// text cannot be mutated, so "expanding" is an honest re-print of the
    /// same block, fully expanded, below the conversation (K10). Walks the
    /// ring backwards on repeated presses; a no-op once nothing folded
    /// remains.
    public func expandMostRecentFolded() {
        if let id = transcript.state.takeExpandableCommitted() {
            pendingExpand.append(id)
        }
    }

    /// Hand the screen to a child ($EDITOR / $PAGER): park the cursor below
    /// the live region and re-show it. Committed history above is real
    /// scrollback and needs no save/restore — the child scrolls it like any
    /// shell output (the minimal advantage).
    public func suspendToChild() throws {
        let area = terminal.viewportArea
        try sink.write(ANSIOutput.moveTo(column: 0, row: area.bottom) + "\u{1B}[?25h\u{1B}[0m")
        try sink.flush()
    }

    /// Reclaim the screen after a child: re-adopt the size; the next frame's
    /// draw repaints the live region in place.
    public func resumeFromChild() throws {
        try terminal.autoresize()
    }

    /// Restore the terminal on exit: the live region's rows are left in
    /// place (they are real scrollback content in minimal), only the cursor
    /// is re-shown below the viewport.
    public func restore() throws {
        let area = terminal.viewportArea
        try sink.write(ANSIOutput.moveTo(column: 0, row: area.bottom) + "\u{1B}[?25h\u{1B}[0m\n")
        try sink.flush()
    }

    /// Per-frame entry point — the ordered walk of `lib.rs::draw` (:91-108).
    ///
    /// 0. Open a synchronized update and adopt the current terminal size, so
    ///    commits AND the live region present atomically at the right
    ///    dimensions. Without the up-front resize, a block finalizing on a
    ///    resize frame would print at the stale width and the shrink would
    ///    hard-wrap the print-once committed copy forever (`lib.rs:71-90`).
    /// 1. Sync the transcript + pending marks ONCE, up front, so the
    ///    viewport sizing and the commit pass judge committability against
    ///    the same state (`commit::sync_pending_marks`).
    /// 2. Commit the pending welcome card so it lands above the first block.
    /// 3. Size the viewport to its POST-commit height (`sync_viewport`) —
    ///    BEFORE the commit, so `insertBefore` repositions the
    ///    correctly-sized viewport ("input snaps to the top" otherwise).
    /// 4. Commit finalized blocks into native scrollback.
    /// 5. Redraw the live region (tail · completions · status · composer).
    public func draw(_ state: PagerRenderState) {
        try? sink.write(ANSIOutput.beginSynchronizedUpdate)
        defer {
            try? sink.write(ANSIOutput.endSynchronizedUpdate)
            try? sink.flush()
        }
        try? terminal.autoresize()

        let theme = state.theme
        let turnRunning = state.turnStatus != nil
        syncTranscript(state)
        maybeCommitWelcome(theme: theme)

        let width = terminal.viewportArea.width
        guard width >= 4 else { return }

        // Stamp the still-uncommitted tail entries with the print-once
        // display policy they will commit with (`commit_active`'s trailing
        // loop, commit.rs:490-503) so a block's height does not snap when it
        // finalizes.
        var stampIndex = transcript.state.commitScanCursor
        while transcript.state.entry(at: stampIndex) != nil {
            transcript.state.updateEntry(at: stampIndex) {
                $0.setDisplayMode(minimalCommitDisplayMode(
                    for: $0.block, collapseThinking: collapseThinking
                ))
            }
            stampIndex += 1
        }

        // Commits hold while a centered overlay owns the live region — an
        // insertBefore underneath it would scroll the popup
        // (`commit_active`, commit.rs:418-422). Prompt-replacing overlays
        // (permission / question) do NOT hold: their tool is pinned in the
        // tail by its pending mark instead. The full-screen welcome overlay
        // is minimal's replaced surface — the card stands in for it.
        let holdCommits = state.overlays.overlays.contains { overlay in
            switch overlay.content {
            case .list, .text, .workflows, .settings, .extensions, .agents, .personaDetail:
                return true
            case .welcome, .permission, .question, .planApproval:
                return false
            }
        }

        let tailH = MinimalLiveRender.tailHeight(
            transcript, turnRunning: turnRunning, width: width, theme: theme
        )
        let promptH = pagerComposerHeight(state.input, width: width)
        let completionsRows = (state.completions?.isEmpty == false)
            ? state.completions!.visibleRowCount + 1
            : 0
        let screenH = terminal.lastKnownArea.height
        guard screenH >= 3 else { return }
        let ceiling = max(3, screenH - 1)
        var target = MinimalLiveRender.contentTarget(
            tailHeight: tailH,
            todosHeight: 0,
            btwHeight: 0,
            overlayHeight: completionsRows,
            promptHeight: promptH,
            ceiling: ceiling
        )
        // An open overlay (picker, settings, permission sheet) paints INSIDE
        // the live viewport in minimal — grow it to the moderate app-modal
        // height so the popup has room (`app_modal_target`,
        // `overlay.rs:274-282`: never the full ceiling; the blank band left
        // on close equals `target - base`, and committed rows scrolled into
        // native scrollback cannot be pulled back). A viewport-less overlay
        // would otherwise CAPTURE INPUT while painting nowhere — the
        // invisible-modal failure this port's §3 exists to catch.
        if !state.overlays.isEmpty {
            target = max(target, MinimalLiveRender.appModalTarget(base: target, ceiling: ceiling))
        }
        let willCommit = MinimalLiveRender.willCommit(
            transcript, turnRunning: turnRunning, holdCommits: holdCommits
        )
        MinimalLiveRender.syncViewport(terminal: terminal, target: target, willCommit: willCommit)

        if !holdCommits {
            commitLeadingRun(transcript.state, turnRunning: turnRunning) { [self] sb, index in
                guard let entry = sb.entry(at: index) else { return true }
                // Idle-stale running flag: finalize before rendering so the
                // block prints in its finished form (commit.rs:451-456).
                if entry.isRunning {
                    sb.setEntryRunning(entry.id, running: false)
                }
                let mode = minimalCommitDisplayMode(
                    for: entry.block, collapseThinking: collapseThinking
                )
                sb.updateEntry(at: index) { $0.setDisplayMode(mode) }
                guard let item = transcript.item(for: entry.id) else { return true }
                let block = MinimalCommitRender.committedLines(
                    item: item, displayMode: mode, width: width, theme: theme
                )
                do {
                    try MinimalCommitRender.insertCommitted(
                        block, into: terminal, maxRows: maxCommitRows, theme: theme
                    )
                } catch {
                    return false // retried next frame; never mark unprinted
                }
                if mode == .collapsed || mode == .truncated {
                    sb.recordCommittedForExpand(entry.id)
                }
                return true
            }
        }

        // Ctrl+E / `/expand` re-prints, after the commit pass exactly as
        // upstream orders them (`lib.rs:105-106`). Held whole while a
        // centered overlay owns the region — the user would not see the
        // re-print and an insert would scroll the popup (`expand_pending`,
        // `commit.rs:534-539`); a 0-width probe frame also leaves the queue
        // intact rather than silently dropping the request (`:543-546`).
        if !holdCommits, !pendingExpand.isEmpty {
            let queued = pendingExpand
            pendingExpand = []
            var requeue: [MinimalEntryID] = []
            for (position, id) in queued.enumerated() {
                guard let index = transcript.state.indexOfID(id) else {
                    continue // entry removed (rewind / clear) since the keypress
                }
                transcript.state.updateEntry(at: index) { $0.setDisplayMode(.expanded) }
                guard let item = transcript.item(for: id) else { continue }
                let block = MinimalCommitRender.committedLines(
                    item: item, displayMode: .expanded, width: width, theme: theme
                )
                do {
                    // UNCAPPED (`maxRows: 0`): the initial commit truncated
                    // the block under the cap, and this is the explicit
                    // "show me the whole thing" action — re-capping just
                    // reprints the same footer (`commit.rs:513-517`).
                    try MinimalCommitRender.insertCommitted(
                        block, into: terminal, maxRows: 0, theme: theme
                    )
                } catch {
                    // Terminal write failed: keep this id and the rest
                    // queued so the request retries instead of vanishing.
                    requeue.append(contentsOf: queued[position...])
                    break
                }
            }
            pendingExpand = requeue + pendingExpand
        }

        drawLiveRegion(state, turnRunning: turnRunning, completionsRows: completionsRows, theme: theme)
    }

    // MARK: - Transcript sync

    /// Positional sync of the controller's conversation onto the frontier
    /// store. The controller's conversation is append-mostly with in-place
    /// updates; a shrink is a rewind//clear and maps to `removeFrom`, whose
    /// cursor clamp M1 pinned. A mutated item BELOW the commit frontier
    /// updates the payload but can never reach the screen again —
    /// print-once, upstream's frozen-content contract (`commit.rs:466-473`).
    private func syncTranscript(_ state: PagerRenderState) {
        let items = state.conversation
        if items.count < transcript.state.count {
            if items.isEmpty {
                transcript.clear()
                pendingMarked.removeAll()
            } else {
                transcript.removeFrom(items.count)
            }
        }
        for (index, item) in items.enumerated() {
            if let entry = transcript.state.entry(at: index) {
                if transcript.item(for: entry.id) != item {
                    transcript.updateItem(entry.id, item)
                }
                let running = Self.itemIsRunning(item)
                if entry.isRunning != running {
                    transcript.state.setEntryRunning(entry.id, running: running)
                }
            } else {
                transcript.push(item, running: Self.itemIsRunning(item))
            }
        }

        // Pending marks: while a permission/question prompt is up, the tool
        // it blocks on is the LAST running tool — hold it (and everything
        // after) in the live region so the prompt's diff/command preview
        // stays visible (`sync_pending_marks`, commit.rs:584-600; the
        // overlay.rs:284-293 sizing rationale). Cleared when the prompt
        // resolves — only the marks this host set.
        let promptOpen = state.overlays.overlays.contains { overlay in
            switch overlay.content {
            case .permission, .question: return true
            default: return false
            }
        }
        if promptOpen {
            var index = transcript.state.count - 1
            while index >= 0 {
                guard let entry = transcript.state.entry(at: index) else { break }
                if case .toolCall = entry.block, entry.isRunning {
                    if transcript.state.setPendingUserInput(entry.id, pending: true) {
                        pendingMarked.insert(entry.id)
                    }
                    break
                }
                index -= 1
            }
        } else if !pendingMarked.isEmpty {
            for id in pendingMarked {
                transcript.state.setPendingUserInput(id, pending: false)
            }
            pendingMarked.removeAll()
        }
    }

    static func itemIsRunning(_ item: PagerConversationItem) -> Bool {
        switch item {
        case .message(let message): return message.isStreaming
        case .tool(let card): return card.state == .running || card.state == .pending
        case .separator: return false
        }
    }

    // MARK: - Welcome card

    /// Commit the one-shot welcome card (`maybe_commit_welcome`,
    /// `welcome.rs:28-143`): minimal skips the full-screen welcome entirely,
    /// so a fresh session is otherwise invisible. The pending flag clears
    /// only after the insert SUCCEEDS — clearing up front meant a failed
    /// insert silently dropped the card forever (upstream's bugbot). The
    /// viewport is reset to the TOP of the screen first so the card commits
    /// at row 0 and commits flow downward; pre-existing native scrollback is
    /// untouched.
    private func maybeCommitWelcome(theme: PagerRenderTheme) {
        guard welcomePending, let welcome else { return }
        let width = terminal.viewportArea.width
        guard width >= 8 else { return }

        let liveHeight = terminal.viewportArea.height
        terminal.setViewportArea(TerminalRect(x: 0, y: 0, width: width, height: liveHeight))
        try? terminal.clear()

        var info: [[PagerStyledSpan]] = []
        info.append([
            PagerStyledSpan(text: "Open Grok", foreground: theme.accentUser, style: [.bold]),
            PagerStyledSpan(text: "  v\(welcome.version)", foreground: theme.gray),
        ])
        if !welcome.workingDirectory.isEmpty {
            info.append([PagerStyledSpan(text: welcome.workingDirectory, foreground: theme.gray)])
        }
        if let model = welcome.model {
            info.append([PagerStyledSpan(text: "Model \u{00B7} \(model)", foreground: theme.gray)])
        }
        info.append([PagerStyledSpan(text: "/help for commands", foreground: theme.grayDim, style: [.dim])])

        // Border + one row of vertical padding top and bottom (welcome.rs:97;
        // the port has no compact-logo asset — recorded, the card is border +
        // info lines).
        let height = 2 + 1 + info.count + 1
        let borderColor = theme.grayDim
        do {
            try terminal.insertBefore(height) { buffer in
                let area = buffer.area
                let horizontal = String(repeating: String(PagerGlyphs.borderHorizontal), count: max(0, area.width - 2))
                _ = buffer.setString(
                    x: 0, y: 0,
                    text: String(PagerGlyphs.borderTopLeft) + horizontal + String(PagerGlyphs.borderTopRight),
                    style: [.dim], foreground: borderColor
                )
                _ = buffer.setString(
                    x: 0, y: area.height - 1,
                    text: String(PagerGlyphs.borderBottomLeft) + horizontal + String(PagerGlyphs.borderBottomRight),
                    style: [.dim], foreground: borderColor
                )
                for y in 1..<(area.height - 1) {
                    _ = buffer.setString(
                        x: 0, y: y, text: String(PagerGlyphs.borderVertical),
                        style: [.dim], foreground: borderColor
                    )
                    _ = buffer.setString(
                        x: area.width - 1, y: y, text: String(PagerGlyphs.borderVertical),
                        style: [.dim], foreground: borderColor
                    )
                }
                for (row, spans) in info.enumerated() {
                    _ = paintSpans(
                        &buffer, spans: spans, x: 2, y: 2 + row,
                        limit: max(2, area.width - 2), background: .reset
                    )
                }
            }
        } catch {
            return // keep the flag pending; the card retries next frame
        }
        welcomePending = false
        MinimalCommitRender.insertGap(into: terminal)
    }

    // MARK: - Live region

    /// The pinned live region: tail · completions · status · composer
    /// (`draw_live`, `live.rs:96-403`, reduced to the arms whose backings
    /// exist in the frame model — todos//btw//panels//app-modals are
    /// deferred, recorded in the ledger).
    private func drawLiveRegion(
        _ state: PagerRenderState,
        turnRunning: Bool,
        completionsRows: Int,
        theme: PagerRenderTheme
    ) {
        _ = try? terminal.draw { frame in
            let area = frame.viewportArea
            guard area.height > 0, area.width >= 4 else { return }
            var buffer = CellBuffer.empty(area)

            let statusH = min(1, area.height)
            let promptH = min(
                pagerComposerHeight(state.input, width: area.width),
                max(1, area.height - statusH)
            )
            let overlayH = min(completionsRows, max(0, area.height - statusH - promptH))
            let tailH = max(0, area.height - statusH - promptH - overlayH)

            if tailH > 0 {
                MinimalLiveRender.drawTail(
                    transcript,
                    turnRunning: turnRunning,
                    area: TerminalRect(x: area.x, y: area.y, width: area.width, height: tailH),
                    theme: theme,
                    into: &buffer
                )
            }
            if overlayH > 1 {
                renderCompletions(
                    state.completions,
                    in: TerminalRect(
                        x: area.x, y: area.y + tailH, width: area.width, height: overlayH - 1
                    ),
                    buffer: &buffer,
                    theme: theme
                )
            }
            let statusArea = TerminalRect(
                x: area.x, y: area.y + tailH + overlayH, width: area.width, height: statusH
            )
            if let status = state.turnStatus {
                renderTurnStatus(status, in: statusArea, buffer: &buffer, theme: theme)
            } else {
                renderMinimalIdleHint(in: statusArea, buffer: &buffer, theme: theme)
            }
            let composerArea = TerminalRect(
                x: area.x, y: area.y + tailH + overlayH + statusH,
                width: area.width, height: promptH
            )
            let cursor = renderComposer(
                state.input, in: composerArea, buffer: &buffer, theme: theme
            )
            // Overlays (pickers, settings, permission/question sheets) paint
            // INSIDE the live viewport — the shared popup renderers, exactly
            // as upstream's minimal reuses the full-TUI modal painters
            // (`render_app_modal`//`render_modal`, live.rs:163-237). The
            // synthetic layout scopes them to the viewport: `bounds` centers
            // the modals here, `input` anchors the bottom sheets.
            if !state.overlays.isEmpty {
                let empty = TerminalRect(x: area.x, y: area.y, width: area.width, height: 0)
                _ = renderOverlays(
                    state.overlays,
                    layout: PagerFrameLayout(
                        bounds: area,
                        statusBar: empty,
                        announcementBanner: empty,
                        conversation: TerminalRect(
                            x: area.x, y: area.y, width: area.width, height: tailH
                        ),
                        completions: empty,
                        turnStatus: statusArea,
                        input: composerArea,
                        shortcuts: empty,
                        contentWidth: area.width,
                        totalContentLines: 0,
                        visibleContentLines: 0..<0,
                        scrollOffset: 0,
                        hasScrollbar: false,
                        timelineRail: nil
                    ),
                    buffer: &buffer,
                    theme: theme,
                    motion: state.motion
                )
            }
            frame.buffer = buffer
            frame.setCursorPosition(cursor)
        }
    }
}

/// Idle status: `minimal · /help` (`render_idle_hint`, `live.rs:586-604`).
/// The `/fullscreen to go back` arm is S2's — advertising the command before
/// it exists is the §4 rule this program ordering exists to respect.
private func renderMinimalIdleHint(
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) {
    guard area.height > 0, area.width > 0 else { return }
    _ = paintSpans(
        &buffer,
        spans: [PagerStyledSpan(
            text: "minimal \u{00B7} /help", foreground: theme.grayDim, style: [.dim]
        )],
        x: area.x,
        y: area.y,
        limit: area.right,
        background: .reset
    )
}
