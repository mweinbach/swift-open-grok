// PagerDashboardPeek.swift
//
// Wave 18 B1-p: the dashboard PEEK panel's render side — the port of
// `views/dashboard/peek_tail.rs` (dense live tail) and the live-tail half
// of `views/dashboard/peek.rs` + `views/dashboard/layout.rs` (sizing) at
// pin 650c1db7.
//
// Upstream the peek is a rounded box painted into the dashboard's dispatch
// rect, replacing the dispatch input while a row is selected
// (`peek.rs:525-531`, `render.rs:317-329`). This port has no dispatch box
// in its dashboard — the roster is a `.list` overlay — so the peek lands as
// a BAND inside the same modal, below the list and above the footer. It is
// still not a toggle: like upstream it is rebuilt every frame from the
// selection cursor (`render.rs:212-283`), so there is no open key and no
// peek state to keep in sync with the row list.
//
// The band carries the live reply row, single-select/freeform question mode,
// and truthful subagent status/transcript peeks. The bottom-border config
// badge remains absent because the retained record does not persist enough
// per-session model/mode state to paint it without guessing.
//
// The measure and the paint must agree row for row: that is the entire
// reason `desiredContentRows` and `liveTailMiddleBottom` exist as a pair
// upstream (`layout.rs:83-95` vs `peek.rs:29-39`). A disagreement does not
// look like a layout bug — it looks like the agent's newest output silently
// vanishing under a blank row.

import OpenGrokMinimalScrollback
import OpenGrokTerminalCore

// MARK: - Value

/// One selected row's peek content, rebuilt every refresh from the row the
/// cursor is on (`compute_peek_fields`, `peek.rs:238-377`).
///
/// It carries the transcript ITEMS, not pre-laid-out lines: the dense tail
/// is a function of the paint width and the allocated band height, both of
/// which are known only at render time. Densifying at build time and
/// storing the rows would re-introduce exactly the measure/paint drift the
/// pair above exists to prevent (and would restyle stale on a resize).
public struct PagerDashboardPeek: Sendable, Equatable, Hashable {
    /// The last-response TYPE, painted left on row 0 — `"Working"`,
    /// `"Thinking"`, `"Response"`, a tool label, `"Idle"`
    /// (`extract_last_response_type`, `peek.rs:948-1039`).
    public var statusLabel: String
    /// Relative age painted right on row 0. Empty paints nothing, which is
    /// also what a box too narrow for both columns falls back to.
    public var timeAgo: String
    /// The peeked session's transcript, oldest first.
    public var items: [PagerConversationItem]
    /// Shown in the middle when there is nothing to tail
    /// (`peek.rs:812-821`, whose fallback is `"No activity yet"`).
    public var emptyHint: String
    /// The live `❯ reply` draft painted at the bottom of the peek. `nil`
    /// means the row is visible with its placeholder; a non-nil value is the
    /// text currently owned by dashboard input.
    public var replyDraft: String?
    /// Pending question mode replaces the reply row with the question and
    /// its answer choices, matching the dashboard peek's modal input mode.
    public var questionPrompt: String?
    public var questionOptions: [String]
    public var questionSelectedIndex: Int?
    public var questionFreeformText: String
    public var questionFreeformFocused: Bool
    public var questionRequiresAttach: Bool

    public init(
        statusLabel: String,
        timeAgo: String = "",
        items: [PagerConversationItem] = [],
        emptyHint: String = PagerDashboardPeekTail.defaultEmptyHint,
        replyDraft: String? = nil,
        questionPrompt: String? = nil,
        questionOptions: [String] = [],
        questionSelectedIndex: Int? = nil,
        questionFreeformText: String = "",
        questionFreeformFocused: Bool = false,
        questionRequiresAttach: Bool = false
    ) {
        self.statusLabel = statusLabel
        self.timeAgo = timeAgo
        self.items = items
        self.emptyHint = emptyHint
        self.replyDraft = replyDraft
        self.questionPrompt = questionPrompt
        self.questionOptions = questionOptions
        self.questionSelectedIndex = questionSelectedIndex
        self.questionFreeformText = questionFreeformText
        self.questionFreeformFocused = questionFreeformFocused
        self.questionRequiresAttach = questionRequiresAttach
    }
}

// MARK: - Sizing results

/// Live-tail height budget for a peek: `status + [pin?] + body + [blank?] +
/// reply` (`PeekLiveTailBudget`, `layout.rs:30-35`).
public struct PagerDashboardPeekBudget: Sendable, Equatable, Hashable {
    /// Body rows the tail may paint.
    public var liveTail: Int
    /// Whether a breathing blank sits below the body.
    public var blankRow: Bool
    /// Total inner content rows wanted (never above `maxContent`).
    public var contentRows: Int
}

/// Result of list-first band allocation (`PeekAllocation`,
/// `layout.rs:37-45`).
public struct PagerDashboardPeekAllocation: Sendable, Equatable, Hashable {
    public var showPeek: Bool
    /// Whole band height INCLUDING its 2 chrome rows; 0 when `!showPeek`.
    public var peekBoxHeight: Int
    /// Inner content rows a band at full allowed size would get
    /// (`peekBoxHeight - 2`) — reported even when the band is refused, since
    /// it is the input to the shrink-to-content measure.
    public var maxContentRows: Int
}

// MARK: - Tail + layout

public enum PagerDashboardPeekTail {
    /// Min list-band rows reserved BEFORE the peek is even evaluated
    /// (`LIST_FLOOR_ROWS`, `layout.rs:14`). List-first is the whole policy:
    /// the roster is the dashboard, the peek is commentary on it.
    public static let listFloorRows = 12
    /// Min whole band (chrome + status + body) for a live-tail peek
    /// (`PEEK_MIN_BOX_LIVE_TAIL`, `layout.rs:17`). Below this the band is
    /// refused outright rather than painted as a sliver.
    public static let peekMinBoxLiveTail = 8
    public static let peekMinBoxQuestion = 10
    /// Band max = ⌊H × 3/8⌋ (`PEEK_MAX_FRAC_NUM/DEN`, `layout.rs:23-24`).
    public static let peekMaxFractionNumerator = 3
    public static let peekMaxFractionDenominator = 8
    /// Secondary cap on body rows inside an allocated band
    /// (`MAX_LIVE_TAIL_ROWS`, `layout.rs:27`).
    public static let maxLiveTailRows = 28

    /// `peek.rs:814` — the fallback when a peeked row has no transcript.
    public static let defaultEmptyHint = "No activity yet"

    // MARK: Measure

    /// ⌊H × 3/8⌋ (`peek_max_box_rows`, `layout.rs:110-113`).
    public static func peekMaxBoxRows(_ height: Int) -> Int {
        max(0, height) * peekMaxFractionNumerator / peekMaxFractionDenominator
    }

    /// Shrink-to-content inner rows for a live-tail peek — the port of
    /// `peek_live_tail_desired_content` (`layout.rs:57-108`).
    ///
    /// Recipe (must match what `drawDashboardPeekBand` paints):
    /// `status + [pin?] + body + [blank?] + reply`. An empty body still
    /// reserves one row for the hint line, so a peek never collapses to a
    /// bare status row that looks like a rendering failure.
    ///
    /// DIVERGENCE: upstream clamps `reply_rows.max(1)` because its `❯ reply`
    /// input is unconditional. This pure helper accepts an explicit 0 for
    /// transcript-only sizing probes; the live dashboard path passes 1.
    public static func desiredContentRows(
        maxContent: Int,
        replyRows: Int,
        bodyMeasured: Int,
        pinUser: Bool
    ) -> PagerDashboardPeekBudget {
        let maxContent = max(0, maxContent)
        let replyRows = max(0, replyRows)
        let pin = pinUser ? 1 : 0
        let fixed = 1 + replyRows + pin // status + reply + optional pin

        if maxContent < fixed {
            return PagerDashboardPeekBudget(
                liveTail: 0, blankRow: false, contentRows: maxContent
            )
        }

        let roomNoBlank = min(maxContent - fixed, maxLiveTailRows)
        if roomNoBlank == 0 {
            return PagerDashboardPeekBudget(
                liveTail: 0, blankRow: false, contentRows: fixed
            )
        }

        // Prefer a breathing blank whenever the body is non-empty and room
        // remains (`layout.rs:85-95`).
        let roomWithBlank = min(max(0, maxContent - (fixed + 1)), maxLiveTailRows)
        var blank = roomWithBlank > 0
        let bodyCap = blank ? roomWithBlank : roomNoBlank
        let body = bodyMeasured == 0 ? min(1, bodyCap) : min(bodyMeasured, bodyCap)
        // A body that collapsed to 0 gets no blank either.
        blank = blank && body > 0
        let contentRows = fixed + (blank ? 1 : 0) + body
        return PagerDashboardPeekBudget(
            liveTail: body,
            blankRow: blank,
            contentRows: min(contentRows, maxContent)
        )
    }

    /// List-first band allocation — the port of `allocate_peek`
    /// (`layout.rs:120-167`).
    ///
    /// 1. reserve `listFloorRows` for the list,
    /// 2. remainder → candidate band, capped at ⌊H × 3/8⌋,
    /// 3. candidate below `peekMinBox` → NO band at all,
    /// 4. else `min(max(desired + 2, peekMinBox), candidate)`.
    ///
    /// Step 3 is the load-bearing one: the refusal is why a short terminal
    /// shows a full roster instead of a two-row list under a cramped peek.
    /// `+2` is the band's own chrome (see `drawDashboardPeekBand`), the same
    /// two rows upstream's box spends on its top and bottom borders.
    ///
    /// In this port `areaHeight` is the modal's CONTENT rect height and
    /// `fixedOverhead` is 0 — the modal border, title and footer are already
    /// subtracted by `renderCenteredModal` (`PagerOverlayRender.swift:179-203`),
    /// which is exactly what upstream's `chrome_overhead` measures.
    public static func allocate(
        areaHeight: Int,
        fixedOverhead: Int,
        desiredContentRows: Int,
        peekMinBox: Int = peekMinBoxLiveTail
    ) -> PagerDashboardPeekAllocation {
        let after = max(0, areaHeight - max(0, fixedOverhead))
        if after == 0 {
            return PagerDashboardPeekAllocation(
                showPeek: false, peekBoxHeight: 0, maxContentRows: 0
            )
        }
        let listFloor = min(listFloorRows, after)
        let remainder = after - listFloor
        let maxPeek = min(remainder, peekMaxBoxRows(areaHeight))
        let maxContentRows = max(0, maxPeek - 2)

        if maxPeek < peekMinBox {
            return PagerDashboardPeekAllocation(
                showPeek: false, peekBoxHeight: 0, maxContentRows: maxContentRows
            )
        }
        let desiredBox = max(0, desiredContentRows) + 2
        return PagerDashboardPeekAllocation(
            showPeek: true,
            peekBoxHeight: min(max(desiredBox, peekMinBox), maxPeek),
            maxContentRows: maxContentRows
        )
    }

    /// Max inner rows a band could ever get here — the probe pass of
    /// `max_peek_content_rows` (`layout.rs:283-297`), which allocates with a
    /// deliberately oversized desire so the result is the CAP, not a
    /// content-dependent value. Feeding the shrink measure the cap is what
    /// makes the two-pass converge in one frame.
    public static func maxContentRows(areaHeight: Int, fixedOverhead: Int = 0) -> Int {
        guard areaHeight > 8 else { return 0 }
        return allocate(
            areaHeight: areaHeight,
            fixedOverhead: fixedOverhead,
            desiredContentRows: 255,
            peekMinBox: peekMinBoxLiveTail
        ).maxContentRows
    }

    /// The whole two-pass allocation for one peek, so callers cannot get the
    /// order wrong: cap → shrink-to-content → allocate (`render.rs:204-250`).
    public static func band(
        for peek: PagerDashboardPeek,
        contentHeight: Int,
        width: Int,
        theme: PagerRenderTheme = .default
    ) -> PagerDashboardPeekAllocation {
        let cap = maxContentRows(areaHeight: contentHeight)
        guard cap > 0 else {
            return PagerDashboardPeekAllocation(
                showPeek: false, peekBoxHeight: 0, maxContentRows: 0
            )
        }
        if peek.questionPrompt != nil {
            let contentRows = 2 + max(1, peek.questionOptions.count)
                + (peek.questionRequiresAttach ? 1 : 0)
            return allocate(
                areaHeight: contentHeight,
                fixedOverhead: 0,
                desiredContentRows: min(contentRows, cap),
                peekMinBox: peekMinBoxQuestion
            )
        }
        let budget = desiredContentRows(
            maxContent: cap,
            replyRows: 1,
            bodyMeasured: densifiedBodyLineCount(items: peek.items, width: width, theme: theme),
            pinUser: hasLastUser(items: peek.items)
        )
        return allocate(
            areaHeight: contentHeight,
            fixedOverhead: 0,
            desiredContentRows: budget.contentRows
        )
    }

    /// Exclusive bottom y of the tail middle — the port of
    /// `live_tail_middle_bottom` (`peek.rs:29-39`).
    ///
    /// The blank above the band's bottom chrome is spent only when the
    /// middle still has ≥2 rows after it, so pin AND body can share. With
    /// exactly one row left the blank is given back rather than starving the
    /// current turn — the paint-side half of the `blank_row = false` arm in
    /// `desiredContentRows`.
    ///
    /// `replyTopY` is both the reply row and the exclusive end of the middle
    /// content region.
    static func liveTailMiddleBottom(middleTop: Int, replyTopY: Int) -> Int {
        let withBlank = max(0, replyTopY - 1)
        let heightWithBlank = max(0, withBlank - middleTop)
        if heightWithBlank > 1 { return withBlank }
        if replyTopY > middleTop { return replyTopY }
        return withBlank
    }

    // MARK: Densification

    /// Index of the newest user message — `find_last_user_idx`
    /// (`peek_tail.rs:131-137`).
    static func lastUserIndex(items: [PagerConversationItem]) -> Int? {
        items.lastIndex { item in
            if case .message(let message) = item, message.role == .user { return true }
            return false
        }
    }

    /// Whether a pin row must be budgeted — `scrollback_has_last_user`
    /// (`peek_tail.rs:49-51`).
    public static func hasLastUser(items: [PagerConversationItem]) -> Bool {
        lastUserIndex(items: items) != nil
    }

    /// Densified CURRENT-TURN body rows: everything after the last user
    /// message — `densified_body_line_count` (`peek_tail.rs:39-45`). Pin and
    /// the `…` marker are chrome and are budgeted separately.
    ///
    /// Current-turn only is not an optimization: a prior turn's bulk pulled
    /// up under a fresh prompt reads as the agent having answered when it has
    /// not (`peek_tail.rs:16-19`).
    public static func densifiedBodyLineCount(
        items: [PagerConversationItem],
        width: Int,
        theme: PagerRenderTheme = .default
    ) -> Int {
        guard width > 0, !items.isEmpty else { return 0 }
        let start = lastUserIndex(items: items).map { $0 + 1 } ?? 0
        return densifiedLines(items: items, from: start, width: width, theme: theme).count
    }

    /// The rows a dense tail paints into a `height`-row middle, top to
    /// bottom: `[pin] + [… marker] + body` — the layout half of
    /// `paint_peek_live_tail` (`peek_tail.rs:57-112`).
    static func lines(
        items: [PagerConversationItem],
        width: Int,
        height: Int,
        theme: PagerRenderTheme = .default
    ) -> [PaintLine] {
        guard width >= 1, height > 0, !items.isEmpty else { return [] }

        let lastUser = lastUserIndex(items: items)
        // Always current-turn when a last user exists; the full stream
        // otherwise (`peek_tail.rs:69-71`).
        let bodyStart = lastUser.map { $0 + 1 } ?? 0
        let flat = densifiedLines(items: items, from: bodyStart, width: width, theme: theme)

        // The pin is the FIRST densified line of the last user message —
        // one row, whatever the prompt's length (`peek_tail.rs:74-78`).
        let pin: PaintLine? = lastUser.flatMap { index in
            denseItemLines(items[index], width: width, theme: theme).first
        }
        let bodyBudget = max(0, height - (pin == nil ? 0 : 1))
        let (ellipsis, body) = pureTailWithEllipsis(flat, budget: bodyBudget)

        var rows: [PaintLine] = []
        if let pin { rows.append(pin) }
        if ellipsis {
            rows.append(PaintLine(PagerGlyphs.ellipsis, foreground: theme.grayDim))
        }
        rows.append(contentsOf: body)
        return Array(rows.prefix(height))
    }

    /// Take a pure tail into `budget` rows, reserving one for a top `…` when
    /// content is omitted above — `pure_tail_with_ellipsis`
    /// (`peek_tail.rs:116-129`).
    ///
    /// The `budget == 1` arm drops the MARKER, not the content: one row of
    /// `…` tells the user nothing, where one row of the newest line is the
    /// entire point of a live tail.
    static func pureTailWithEllipsis(
        _ flat: [PaintLine],
        budget: Int
    ) -> (ellipsis: Bool, body: [PaintLine]) {
        if budget <= 0 { return (false, []) }
        if flat.count <= budget { return (false, flat) }
        if budget == 1 { return (false, [flat[flat.count - 1]]) }
        return (true, Array(flat.suffix(budget - 1)))
    }

    /// Densified lines from `start` (inclusive) to the end
    /// (`densified_lines_from`, `peek_tail.rs:139-156`).
    ///
    /// RECORDED ABSENCE: upstream skips thinking blocks hidden by the
    /// `show_thinking_blocks` appearance toggle (`is_hidden_thinking`,
    /// `entry.rs:569-571`). This module takes no appearance config, and dense
    /// mode already folds reasoning to its one-line header, so the toggle
    /// would cost at most one row per block — not worth threading config
    /// through the render layer for.
    private static func densifiedLines(
        items: [PagerConversationItem],
        from start: Int,
        width: Int,
        theme: PagerRenderTheme
    ) -> [PaintLine] {
        guard start < items.count else { return [] }
        var flat: [PaintLine] = []
        for index in start..<items.count {
            flat.append(contentsOf: denseItemLines(items[index], width: width, theme: theme))
        }
        return flat
    }

    /// Upstream's foldable set (`RenderBlock::is_foldable`, default true with
    /// user prompts and agent messages overriding to false): tool calls and
    /// thinking. Foldable blocks project Collapsed in dense mode and lose
    /// their blank lines; messages keep their full expanded body
    /// (`peek_tail.rs:7-9`).
    private static func isFoldable(_ item: PagerConversationItem) -> Bool {
        switch item {
        case .tool: return true
        case .block(let block): return block.isFoldable
        case .message(let message): return message.role == .reasoning
        case .separator: return false
        }
    }

    private static func isUserPrompt(_ item: PagerConversationItem) -> Bool {
        if case .message(let message) = item, message.role == .user { return true }
        return false
    }

    /// `dense_mode` (`peek_tail.rs:158-166`): foldable → its collapse mode,
    /// user prompt → Collapsed (one line is all a pin needs), everything else
    /// → Expanded.
    private static func denseMode(for item: PagerConversationItem) -> MinimalDisplayMode {
        if isFoldable(item) || isUserPrompt(item) { return .collapsed }
        return .expanded
    }

    /// One item's dense rows (`dense_entry_lines`, `peek_tail.rs:168-187`),
    /// laid out through the SAME `MinimalCommitRender.committedLines` the
    /// minimal commit path uses — one constructor, so a block cannot change
    /// height between the transcript and the peek.
    private static func denseItemLines(
        _ item: PagerConversationItem,
        width: Int,
        theme: PagerRenderTheme
    ) -> [PaintLine] {
        var lines = MinimalCommitRender.committedLines(
            item: item,
            displayMode: denseMode(for: item),
            width: width,
            theme: theme
        ).lines

        if isUserPrompt(item) {
            // DIVERGENCE FORCED BY THE PORT'S LAYOUT: `appendUserPrompt`
            // bakes the block's vertical padding into its lines
            // (`OpenGrokPagerRender.swift:597-600`), where upstream's vpad is
            // entry-renderer chrome outside `output.lines`. Dense paint
            // declares "no vpad" (`peek_tail.rs:7-9`), and without this trim
            // the pin — the FIRST line — would be a blank band row instead of
            // the prompt the user just sent.
            while let first = lines.first, isBlank(first) { lines.removeFirst() }
            while let last = lines.last, isBlank(last) { lines.removeLast() }
        }
        if isFoldable(item) {
            // `keep_blanks = !entry.is_foldable()` (`peek_tail.rs:180`):
            // blanks are structure inside a message and padding inside a
            // collapsed tool block.
            lines = lines.filter { !isBlank($0) }
        }
        return lines
    }

    private static func isBlank(_ line: PaintLine) -> Bool {
        line.spans.allSatisfy { span in
            span.text.allSatisfy(\.isWhitespace)
        }
    }
}

// MARK: - Paint

/// Paint the peek band: a rule, status/time, dense tail, and reply/question.
///
/// Band chrome is the two rows `allocate` charges for, standing in for the
/// rounded box's top and bottom borders (`peek.rs:585-616`). The first row
/// is a rule separating the band from the roster above it; the terminal row
/// stays blank because the retained record cannot truthfully supply the
/// upstream model/mode badge.
///
/// The degenerate gate is upstream's (`peek.rs:577-579`): under 3 rows or 20
/// columns nothing is painted at all, because a peek too small to carry both
/// a status and a line of content is worse than none.
func drawDashboardPeekBand(
    _ peek: PagerDashboardPeek,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) {
    guard area.height >= 3, area.width >= 20 else { return }

    // Blank the whole band to `bg_base` first (`peek_tail.rs:83-91`): the
    // tail is shorter than its area most frames, and an unpainted row would
    // show the roster rows this band just displaced.
    paintBlank(&buffer, area: area, foreground: theme.textPrimary, background: theme.bgBase)

    _ = paintSpans(
        &buffer,
        spans: [PagerStyledSpan(
            text: String(repeating: String(PagerGlyphs.borderHorizontal), count: area.width),
            foreground: theme.grayDim
        )],
        x: area.x,
        y: area.y,
        limit: area.right,
        background: theme.bgBase
    )

    let contentTop = area.y + 1
    let contentRows = area.height - 2
    guard contentRows >= 1 else { return }

    // Row 0: last-response TYPE on the LEFT, time-ago on the FAR RIGHT
    // (`peek.rs:755-795`). Both are chrome and paint dim so the tail below
    // is the brightest thing in the band; `Working` alone gets the secondary
    // colour, because it is the one label that means "still going".
    let timeWidth = UnicodeDisplayWidth.width(of: peek.timeAgo)
    let showTime = timeWidth > 0 && timeWidth + 1 < area.width
    // Reserve the time column (+1 gap); when the band is too narrow for
    // both, the LABEL wins and the time is dropped.
    let labelLimit = showTime ? area.right - timeWidth - 1 : area.right
    _ = paintSpans(
        &buffer,
        spans: [PagerStyledSpan(
            text: peek.statusLabel,
            foreground: peek.statusLabel == "Working" ? theme.textSecondary : theme.grayDim
        )],
        x: area.x,
        y: contentTop,
        limit: labelLimit,
        background: theme.bgBase
    )
    if showTime {
        _ = paintSpans(
            &buffer,
            spans: [PagerStyledSpan(text: peek.timeAgo, foreground: theme.grayDim)],
            x: area.right - timeWidth,
            y: contentTop,
            limit: area.right,
            background: theme.bgBase
        )
    }

    if let question = peek.questionPrompt {
        _ = paintSpans(
            &buffer,
            spans: [PagerStyledSpan(text: "\u{25B8} \(question)", foreground: theme.warning)],
            x: area.x,
            y: contentTop + 1,
            limit: area.right,
            background: theme.bgBase
        )
        for (offset, option) in peek.questionOptions.enumerated() {
            let y = contentTop + 2 + offset
            guard y < contentTop + contentRows else { break }
            let isSelected = peek.questionSelectedIndex == offset
            let isOther = offset + 1 == peek.questionOptions.count
            let freeform = isOther && !peek.questionFreeformText.isEmpty
                ? ": \(peek.questionFreeformText)"
                : ""
            let cursor = isOther && peek.questionFreeformFocused ? "\u{258F}" : ""
            _ = paintSpans(
                &buffer,
                spans: [PagerStyledSpan(
                    text: "\(isSelected ? "\u{276F}" : " ") \(offset + 1). \(option)\(freeform)\(cursor)",
                    foreground: isSelected ? theme.accentUser : theme.textPrimary,
                    style: isSelected ? [.bold] : []
                )],
                x: area.x,
                y: y,
                limit: area.right,
                background: theme.bgBase
            )
        }
        if peek.questionRequiresAttach {
            let y = contentTop + 2 + peek.questionOptions.count
            if y < contentTop + contentRows {
                _ = paintSpans(
                    &buffer,
                    spans: [PagerStyledSpan(text: "Open the session to answer this question", foreground: theme.grayDim)],
                    x: area.x,
                    y: y,
                    limit: area.right,
                    background: theme.bgBase
                )
            }
        }
        return
    }

    let replyTop = contentTop + contentRows - 1
    let reply = peek.replyDraft ?? ""
    _ = paintSpans(
        &buffer,
        spans: [
            PagerStyledSpan(text: "\u{276F} ", foreground: theme.accentUser),
            PagerStyledSpan(
                text: reply.isEmpty ? "reply\u{2026}" : reply,
                foreground: reply.isEmpty ? theme.grayDim : theme.textPrimary
            ),
        ],
        x: area.x,
        y: replyTop,
        limit: area.right,
        background: theme.bgBase
    )

    let middleTop = contentTop + 1
    let middleBottom = PagerDashboardPeekTail.liveTailMiddleBottom(
        middleTop: middleTop,
        replyTopY: replyTop
    )
    let middleHeight = max(0, middleBottom - middleTop)
    guard middleHeight > 0 else { return }

    guard !peek.items.isEmpty else {
        _ = paintSpans(
            &buffer,
            spans: [PagerStyledSpan(text: peek.emptyHint, foreground: theme.grayDim)],
            x: area.x,
            y: middleTop,
            limit: area.right,
            background: theme.bgBase
        )
        return
    }

    let rows = PagerDashboardPeekTail.lines(
        items: peek.items,
        width: area.width,
        height: middleHeight,
        theme: theme
    )
    for (offset, line) in rows.enumerated() where offset < middleHeight {
        // Chrome column 0: dense mode collapses reasoning, the only block
        // that reserves the accent rail, so there is never a rail to paint.
        MinimalCommitRender.paintRow(
            line,
            at: middleTop + offset,
            originX: area.x,
            chrome: 0,
            width: area.width,
            into: &buffer
        )
    }
}
