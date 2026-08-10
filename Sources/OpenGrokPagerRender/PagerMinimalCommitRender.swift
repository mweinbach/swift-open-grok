// PagerMinimalCommitRender.swift
//
// The committed-block paint path for minimal mode (Wave 18 B2-M2): the
// renderer-facing half of `xai-grok-pager-minimal/src/commit.rs` at pin
// 650c1db7 — `committed_appearance` (:263-271), `minimal_renderer`
// (:282-306), `insert_committed` (:319-343), `insert_gap` (:348-353), and
// `paint_committed` (:361-393) — consuming `Terminal.insertBefore` (B2-N)
// and the pure pipeline's display-mode stamp (`OpenGrokMinimalScrollback`).
//
// The K5 height contract, and how this port keeps it: upstream must prove
// `EntryRenderer::desired_height` equals what `render` paints (its
// height-fitting test family exists because they CAN drift). Here the same
// layout call produces both the lines and the height — `height` IS
// `lines.count` — so reserved and painted rows agree by construction. What
// still needs pinning is the painter (footer, rail, flush-left) never
// writing outside the advertised rows; the M2 tests do that.
//
// It lives beside the strip's layout functions, not in the minimal frontend
// target, because the one-constructor discipline is the whole point:
// committed blocks and the live tail (M3) must wrap through the SAME
// `appendMessage`/`appendToolCard` code or a block's height flips as it
// crosses the commit frontier and the prompt jumps (`commit.rs:276-280`).

import OpenGrokMinimalScrollback
import OpenGrokTerminalCore

/// One block laid out under the minimal committed stance: the lines to
/// paint and the chrome column reserved to their left.
public struct MinimalCommittedBlock {
    var lines: [PaintLine]
    /// 1 for non-collapsed reasoning (the accent rail), else 0 — reserved
    /// only where it is actually painted (`commit.rs:289-296`): reserving a
    /// column nothing paints would indent the header over a blank gutter,
    /// and collapsed reasoning has no body to delimit anyway.
    public let chromeWidth: Int

    /// The rows `insertCommitted` reserves uncapped — `lines.count`, the
    /// port's `desired_height` (K5, by construction).
    public var height: Int { lines.count }

    /// Plain text of one laid-out row (tests and transcript assertions).
    public func rowText(_ index: Int) -> String {
        guard lines.indices.contains(index) else { return "" }
        return lines[index].spans.map(\.text).joined()
    }
}

public enum MinimalCommitRender {
    /// The committed-overflow footer text (`paint_committed`,
    /// `commit.rs:390`): the final row of a capped block names the hidden
    /// line count and the only way to see them in a print-once mode.
    static func overflowFooter(hiddenLines: Int) -> String {
        "\u{2026} \(hiddenLines) more lines \u{2014} /transcript to view"
    }

    /// The dim `(ctrl+e to expand)` affordance appended to a collapsed
    /// reasoning header (`thinking.rs:21-50`, switched on by
    /// `committed_appearance`'s `collapsed_expand_hint`): the only way into
    /// a print-once folded block must be advertised. Skipped when it does
    /// not fit — the header stays one row (K5), never truncated for a hint.
    static let expandHint = "  (ctrl+e to expand)"

    /// Lay out ONE block for native scrollback under the minimal committed
    /// stance — the port of `minimal_renderer` + `committed_appearance`
    /// (`commit.rs:263-306`), driving the SAME `appendMessage` /
    /// `appendToolCard` the strip uses:
    ///
    /// - timestamps forced off (`commit.rs:264-266`),
    /// - flush-left: no block padding, glyphs start at column 0 except the
    ///   reasoning rail (`commit.rs:266-268`),
    /// - motion stilled — the `COMMITTED_TICK` analog (`commit.rs:273`),
    /// - reasoning body de-emphasized dim+italic (`body_dim_italic`,
    ///   `thinking.rs:52-71`; attributes not color, because the
    ///   terminal-native look makes color de-emphasis unreliable),
    /// - the display-mode stamp applied structurally: collapsed reasoning is
    ///   its one-line header plus the expand hint; expanded reasoning is the
    ///   FULL body (K9); a collapsed tool is its header row; a truncated
    ///   tool keeps the head/tail preview; an expanded tool paints its whole
    ///   output — the commit CAP is the footer's job, not the preview's.
    public static func committedLines(
        item: PagerConversationItem,
        displayMode: MinimalDisplayMode,
        width: Int,
        theme: PagerRenderTheme
    ) -> MinimalCommittedBlock {
        let isReasoning: Bool
        if case .message(let message) = item, message.role == .reasoning {
            isReasoning = true
        } else {
            isReasoning = false
        }
        // `hide_accent` inverted (`commit.rs:289-296`): only reasoning with
        // a painted rail spends the column.
        let chromeWidth = (isReasoning && displayMode != .collapsed) ? 1 : 0
        let contentWidth = max(1, width - chromeWidth)

        var lines: [PaintLine] = []
        switch item {
        case .message(var message):
            if message.role == .reasoning {
                message.isCollapsed = displayMode == .collapsed
            }
            appendMessage(
                message,
                width: contentWidth,
                theme: theme,
                compact: false,
                showTimestamps: false,
                thinkingBodyBudget: displayMode == .expanded ? nil : PagerLayoutMetrics.thinkingTruncatedLines,
                into: &lines
            )
            if message.role == .reasoning {
                if displayMode == .collapsed {
                    appendExpandHint(to: &lines, contentWidth: contentWidth, theme: theme)
                } else {
                    applyBodyEmphasisPatch(to: &lines)
                }
            }
        case .tool(var tool):
            tool.isExpanded = displayMode != .collapsed
            appendToolCard(
                tool,
                width: contentWidth,
                theme: theme,
                motion: PagerMotionSnapshot(),
                unboundedPreview: displayMode == .expanded,
                into: &lines
            )
        case .separator(let text):
            let separator = text.isEmpty ? String(repeating: "─", count: contentWidth) : text
            lines.append(PaintLine(separator, foreground: theme.grayDim))
        }
        return MinimalCommittedBlock(lines: lines, chromeWidth: chromeWidth)
    }

    /// Append the dim expand affordance to the collapsed header's single
    /// line, only when it fits (`append_expand_hint`, `thinking.rs:31-50`).
    private static func appendExpandHint(
        to lines: inout [PaintLine],
        contentWidth: Int,
        theme: PagerRenderTheme
    ) {
        guard var header = lines.first, lines.count == 1 else { return }
        let used = header.spans.reduce(0) { $0 + UnicodeDisplayWidth.width(of: $1.text) }
        guard used + UnicodeDisplayWidth.width(of: expandHint) <= contentWidth else { return }
        header.spans.append(PagerStyledSpan(
            text: expandHint,
            foreground: theme.gray,
            style: [.dim]
        ))
        lines[0] = header
    }

    /// Dim+italic every reasoning BODY row — the header keeps its own look
    /// (`body_emphasis_patch`, `thinking.rs:52-71`). Applied to the line's
    /// inherited style so every span in the row carries it.
    private static func applyBodyEmphasisPatch(to lines: inout [PaintLine]) {
        guard lines.count > 1 else { return }
        for index in 1..<lines.count {
            lines[index].style.insert([.dim, .italic])
        }
    }

    /// Paint a committed block into `buffer` (a `commitH`-row buffer),
    /// capping when the buffer is shorter than the block: the top
    /// `commitH - 1` rows are content and the final row becomes the
    /// `… N more lines — /transcript to view` footer (`paint_committed`,
    /// `commit.rs:361-393`). The kept rows come from the SAME layout as an
    /// uncapped commit, so their wrapping is identical (K5). Extracted from
    /// `insertCommitted` so the cap is unit-testable without a live
    /// terminal, exactly as upstream extracted it.
    ///
    /// Flat background (`commit.rs:301`): rows paint over `.reset` so the
    /// terminal's own background shows through; only line-carried bands
    /// (the user-prompt band) keep their color. The reasoning rail paints
    /// DIM (`commit.rs:303-305`: under the terminal-native palette the
    /// accent resolves to full-brightness default fg, which would shout).
    public static func paintCommitted(
        _ block: MinimalCommittedBlock,
        into buffer: inout CellBuffer,
        theme: PagerRenderTheme
    ) {
        let commitH = buffer.area.height
        guard commitH > 0 else { return }
        let width = buffer.area.width
        let fullH = block.height
        let capped = commitH < fullH
        let contentRows = capped ? commitH - 1 : min(commitH, fullH)

        for row in 0..<contentRows {
            paintRow(block.lines[row], at: row, chrome: block.chromeWidth, width: width, into: &buffer)
        }
        if capped {
            // Hidden = everything past the kept content rows, including the
            // row the footer replaced (`commit.rs:378`).
            let hidden = fullH - (commitH - 1)
            let footer = PaintLine(
                overflowFooter(hiddenLines: hidden),
                foreground: theme.gray,
                style: [.dim]
            )
            paintRow(footer, at: commitH - 1, chrome: 0, width: width, into: &buffer)
        }
    }

    /// Shared with the M3 live tail (`PagerMinimalLiveRender`), which paints
    /// the same laid-out lines at a viewport offset — one painter on both
    /// sides of the frontier, like one layout, is what keeps a block
    /// pixel-identical as it crosses.
    static func paintRow(
        _ line: PaintLine,
        at y: Int,
        originX: Int = 0,
        chrome: Int,
        width: Int,
        into buffer: inout CellBuffer
    ) {
        if let background = line.background {
            for x in 0..<width {
                _ = buffer.setString(
                    x: originX + x, y: y, text: " ",
                    style: [], foreground: line.foreground, background: background
                )
            }
        }
        if chrome > 0, let glyph = line.accentGlyph {
            _ = buffer.setString(
                x: originX, y: y, text: glyph,
                style: line.style.union([.dim]),
                foreground: line.accentColor ?? .reset,
                background: line.background ?? .reset
            )
        }
        _ = paintSpans(
            &buffer,
            spans: line.spans,
            x: originX + chrome,
            y: y,
            limit: originX + width,
            background: line.background ?? .reset,
            inheritForeground: line.foreground,
            inheritStyle: line.style
        )
    }

    /// Emit one committed block into native scrollback via `insertBefore`,
    /// capping its height at `maxRows` (0 = unbounded) — `insert_committed`
    /// (`commit.rs:319-343`). A zero-height block inserts nothing. Errors
    /// PROPAGATE, never swallowed: the caller must not mark the entry
    /// committed when the terminal write failed — print-once means a
    /// marked-but-unprinted block can never be emitted again
    /// (`commitLeadingRun`'s false-return contract).
    public static func insertCommitted(
        _ block: MinimalCommittedBlock,
        into terminal: Terminal,
        maxRows: Int,
        theme: PagerRenderTheme
    ) throws {
        let fullH = block.height
        guard fullH > 0 else { return }
        let commitH = (maxRows > 0 && fullH > maxRows) ? maxRows : fullH
        try terminal.insertBefore(commitH) { buffer in
            paintCommitted(block, into: &buffer, theme: theme)
        }
        insertGap(into: terminal)
    }

    /// Emit `minimalBlockGap` blank rows as the trailing gap after a
    /// committed block (`insert_gap`, `commit.rs:348-353`). The rows are
    /// left unpainted so they inherit the terminal's own background. Gap
    /// failures are deliberately swallowed as upstream's are — a lost blank
    /// row is cosmetic, and failing the commit for it would strand a block
    /// that DID print.
    public static func insertGap(into terminal: Terminal) {
        guard minimalBlockGap > 0 else { return }
        try? terminal.insertBefore(Int(minimalBlockGap)) { _ in }
    }
}
