import Foundation
import OpenGrokTerminalCore

/// Paint one full-screen frame.
///
/// The layout mirrors `AgentViewLayout::compute` (`views/agent.rs:158-300`):
/// a one-row status bar, the transcript, optional completion and turn-status
/// rows, the composer box, and a one-row shortcuts bar — with a single blank
/// row between each pair of occupied regions.
public func renderPagerFrame(_ state: PagerRenderState) -> PagerRenderResult {
    let bounds = TerminalRect(x: 0, y: 0, width: state.size.width, height: state.size.height)
    // The derived render-value compact flag — every compact read below
    // consumes it, exactly as upstream's paint sites read the derived
    // `appearance.prompt.compact` and never the user setting.
    let compact = state.compactMode
    let chrome = makeChromeLayout(bounds: bounds, state: state, compact: compact)

    let baseContentWidth = max(0, chrome.conversation.width - PagerLayoutMetrics.chromeWidth)
    // The timeline rail's eligibility, decided BEFORE wrapping because the
    // rail takes columns out of the wrap width. The turn list is the shared
    // enumeration `/jump` reads too, so the two navigators cannot disagree.
    // A disabled scrollbar config forces the rail off — it needs the
    // scrollbar's gutter geometry (`views/agent.rs:364-368`) — and a
    // viewport too short for 2 chevrons + 1 tick falls back to the
    // scrollbar layout, upstream's `compute_rail` None arm re-running
    // layout with `timeline_width: 0` (`agent_view/render.rs:1236-1268`).
    let turnBlockIndices = pagerTimelineTurnBlockIndices(state.conversation)
    var railWidth = state.showScrollbar
        ? pagerTimelineRailWidth(
            showTimeline: state.showTimeline,
            terminalWidth: state.size.width,
            turnCount: turnBlockIndices.count
        )
        : 0
    if chrome.conversation.height < 3 { railWidth = 0 }
    let hasTimelineRail = railWidth > 0

    var conversationLayout = makeConversationLayout(
        state.conversation,
        width: max(1, baseContentWidth - railWidth),
        theme: state.theme,
        selectedIndex: state.selectedBlockIndex,
        motion: state.motion,
        compact: compact,
        showTimestamps: state.showTimestamps
    )
    // The rail replaces the scrollbar in its gutter while shown
    // (`views/timeline.rs:1-2`; the paint-side half is
    // `agent_view/render.rs:1737-1749`, `if !rail_shown { render_scrollbar }`).
    let hasScrollbar = !hasTimelineRail && state.showScrollbar && baseContentWidth > 1
        && conversationLayout.lines.count > chrome.conversation.height
    if hasScrollbar {
        conversationLayout = makeConversationLayout(
            state.conversation,
            width: max(1, baseContentWidth - 1),
            theme: state.theme,
            selectedIndex: state.selectedBlockIndex,
            motion: state.motion,
            compact: compact,
            showTimestamps: state.showTimestamps
        )
    }
    let contentLines = conversationLayout.lines

    let contentWidth = max(0, baseContentWidth - (hasTimelineRail ? railWidth : (hasScrollbar ? 1 : 0)))
    let visibleHeight = chrome.conversation.height
    let maximumOffset = max(0, contentLines.count - visibleHeight)
    let scrollOffset: Int
    switch state.scrollPosition {
    case .followTail:
        scrollOffset = maximumOffset
    case .offset(let requested):
        // Page-flip on send may pin a prompt near the transcript tail with
        // fewer lines below it than the viewport height — upstream keeps that
        // offset (`follow_preserve_scroll`, nav.rs:1176-1205) instead of
        // clamping to `maximumOffset`, which would leave the viewport at the
        // tail and defeat the flip. Manual scroll paths clamp before storing.
        scrollOffset = max(requested, 0)
    }
    let visibleEnd = min(contentLines.count, scrollOffset + visibleHeight)
    let visibleRange = scrollOffset..<visibleEnd

    // Rail geometry, derived AFTER the scroll offset resolves because the
    // active turn is a viewport-top read. The prompt rows come from the same
    // laid-out lines the frame paints, so the partition can never disagree
    // with what is on screen (upstream partitions the layout cache's
    // `virtual_y` the same way, `scrollback/state/timeline.rs:120-137`).
    var timelineRail: PagerTimelineRail?
    if hasTimelineRail {
        let promptLineIndices = turnBlockIndices.map {
            conversationLayout.blockStartLines[$0]
        }
        timelineRail = pagerComputeTimelineRail(
            scrollbackArea: chrome.conversation,
            railX: chrome.conversation.x + PagerLayoutMetrics.chromeWidth + contentWidth,
            turnCount: turnBlockIndices.count,
            viewport: pagerTimelineViewport(
                promptLineIndices: promptLineIndices,
                scrollOffset: scrollOffset,
                maximumOffset: maximumOffset
            )
        )
    }

    var layout = PagerFrameLayout(
        bounds: bounds,
        statusBar: chrome.statusBar,
        announcementBanner: chrome.announcementBanner,
        conversation: chrome.conversation,
        completions: chrome.completions,
        turnStatus: chrome.turnStatus,
        input: chrome.input,
        shortcuts: chrome.shortcuts,
        contentWidth: contentWidth,
        totalContentLines: contentLines.count,
        visibleContentLines: visibleRange,
        scrollOffset: scrollOffset,
        hasScrollbar: hasScrollbar,
        timelineRail: timelineRail,
        // Click-to-select geometry from the same layout the frame paints —
        // content heights exclude the inter-block gap rows so a hit on a
        // gap returns nil, matching upstream's `entry_at_content_y`
        // (`scrollback/state/layout.rs:100-124`).
        conversationHit: PagerConversationHitModel(
            conversation: chrome.conversation,
            scrollOffset: scrollOffset,
            contentWidth: contentWidth,
            blockStartLines: conversationLayout.blockStartLines,
            blockHeights: conversationLayout.blockHeights
        )
    )

    var buffer = CellBuffer(area: bounds)
    var links: [LinkSpan] = []
    fill(&buffer, area: bounds, background: state.theme.bgBase, foreground: state.theme.textPrimary)
    layout.contextBar = renderStatusBar(
        state.statusBar,
        in: chrome.statusBar,
        buffer: &buffer,
        theme: state.theme,
        motion: state.motion
    )
    // Slot ownership, upstream's `privacy_banner_owns_slot`
    // (`agent_view/render.rs:2128-2148`): the flag plus enough rows to
    // paint the banner whole. When the privacy banner owns the slot the
    // announcement does not paint AND publishes no link span — upstream
    // clears the announcement hit rects for the same reason
    // (`render.rs:2134-2135`): a click where [hide] used to be must not
    // dismiss an announcement that is not on screen. When ownership fails
    // (flag off, or a squeezed slot below the banner's minimum height),
    // the announcement paints exactly as before and the banner arms no
    // rects (`render.rs:2130-2132`).
    // While the welcome takeover is up, the chrome has no announcement
    // surface: upstream's welcome and agent views are mutually exclusive
    // draw arms (`app/app_view.rs:4914` vs `:5158` at pin 650c1db7) and only
    // the agent arm sizes and paints the session banner (`:5221-5241`) — the
    // welcome shows the same slot selection in its hero info slot instead
    // (`:4937-4964`). Without this gate the full-screen welcome overpaints
    // the banner cells but the promo button's OSC 8 link span stays armed
    // over blank cells — a click target for a banner that is not on screen
    // (the same reason upstream clears banner hit rects when the privacy
    // banner owns the slot, `agent_view/render.rs:2134-2135`).
    let welcomeOwnsChrome = state.overlays.overlays.contains { overlay in
        if case .welcome = overlay.content { return true }
        return false
    }
    if state.privacyBanner, !welcomeOwnsChrome,
       chrome.announcementBanner.height >= pagerPrivacyBannerMinHeight {
        layout.privacyBanner = renderPagerPrivacyBanner(
            in: chrome.announcementBanner,
            buffer: &buffer,
            theme: state.theme
        )
    } else if !welcomeOwnsChrome {
        renderAnnouncementBanner(
            state.announcementBanner,
            in: chrome.announcementBanner,
            buffer: &buffer,
            theme: state.theme,
            links: &links
        )
    }
    if let tasksPane = state.tasksPane, chrome.tasksPane.height > 0 {
        drawTasksPane(tasksPane, in: chrome.tasksPane, buffer: &buffer, theme: state.theme)
    }
    renderConversation(
        contentLines,
        visibleRange: visibleRange,
        in: chrome.conversation,
        contentWidth: contentWidth,
        hasScrollbar: hasScrollbar,
        scrollOffset: scrollOffset,
        buffer: &buffer,
        theme: state.theme,
        links: &links
    )
    if let timelineRail {
        renderTimelineRail(timelineRail, buffer: &buffer, theme: state.theme)
    }
    renderTurnStatus(state.turnStatus, in: chrome.turnStatus, buffer: &buffer, theme: state.theme)
    // An active overlay owns input focus, so the composer paints unfocused and
    // surrenders the terminal cursor for as long as the stack is non-empty.
    var composer = state.input
    if state.overlays.isActive {
        composer.isFocused = false
        composer.cursorVisible = false
    }
    let composerCursor = renderComposer(
        composer,
        in: chrome.input,
        buffer: &buffer,
        theme: state.theme
    )
    renderShortcutsBar(state.shortcuts, in: chrome.shortcuts, buffer: &buffer, theme: state.theme)

    let overlayBounds = renderOverlays(
        state.overlays,
        layout: layout,
        buffer: &buffer,
        theme: state.theme,
        motion: state.motion
    )
    // On the WELCOME the privacy banner owns the tip slot above the prompt
    // instead of the chrome slot — upstream's welcome tip-slot priority
    // (`views/welcome/mod.rs:2112-2137` at pin 650c1db7: "Privacy banner
    // owns the tip slot when visible (above the prompt), except a
    // pending-update notification, which outranks it"; the pending-update
    // and foreign-resume tenants are ABSENT in this port — Wave 19 — so the
    // ordering is banner-vs-nothing today, carried here so those tenants
    // slot ABOVE this arm when they land, never below it). Painted AFTER
    // the overlays because the full-screen hero would overpaint it; rects
    // publish only from THIS visible paint, which is what lets the mouse
    // router route them under the non-capturing welcome without reopening
    // the invisible-banner click-through hazard (B9-c3's guard).
    if state.privacyBanner, welcomeOwnsChrome {
        let bannerHeight = pagerPrivacyBannerHeight(width: chrome.input.width)
        let tipY = chrome.input.y - bannerHeight
        if bannerHeight >= pagerPrivacyBannerMinHeight, tipY >= 0 {
            layout.privacyBanner = renderPagerPrivacyBanner(
                in: TerminalRect(
                    x: chrome.input.x,
                    y: tipY,
                    width: chrome.input.width,
                    height: bannerHeight
                ),
                buffer: &buffer,
                theme: state.theme
            )
        }
    }
    // After the overlays: the slash dropdown must win over the full-screen
    // welcome hero (upstream paints its dropdown beside the prompt regardless
    // of the hero). Safe with every other overlay because they capture input,
    // so no completion state can exist while one is up — only the
    // non-capturing welcome coexists with a focused composer.
    renderCompletions(state.completions, in: chrome.completions, buffer: &buffer, theme: state.theme)

    return PagerRenderResult(
        buffer: buffer,
        layout: layout,
        cursorPosition: state.overlays.isActive ? nil : composerCursor,
        links: links,
        overlays: overlayBounds
    )
}

// MARK: - Layout

private struct ChromeLayout {
    var statusBar: TerminalRect
    var announcementBanner: TerminalRect
    var tasksPane: TerminalRect
    var conversation: TerminalRect
    var completions: TerminalRect
    var turnStatus: TerminalRect
    var input: TerminalRect
    var shortcuts: TerminalRect
}

/// Composer height per `prompt_widget/mod.rs:1475-1499`: one border row, at
/// least one text row, one info-border row — a three-row floor — clamped to
/// the caller's maximum.
func pagerComposerHeight(_ input: PagerComposerState, width: Int) -> Int {
    let borderRows = input.showBorders ? 2 : 0
    let textWidth = max(1, pagerComposerTextWidth(input, width: width))
    let rendered = wrapDisplayLines(input.text, width: textWidth)
    let textRows = max(1, rendered.count)
    let total = borderRows + textRows
    let minimum = borderRows + 1
    return max(min(total, input.maximumHeight), min(minimum, input.maximumHeight))
}

/// Columns available to the composer's text, after borders, the one-column
/// inner gutter on each side, and the two-column prompt prefix.
func pagerComposerTextWidth(_ input: PagerComposerState, width: Int) -> Int {
    let chrome = input.showBorders ? 4 : 0
    return max(1, width - chrome - PagerGlyphs.promptArrowWidth)
}

private func makeChromeLayout(
    bounds: TerminalRect,
    state: PagerRenderState,
    compact: Bool
) -> ChromeLayout {
    let empty = TerminalRect(x: bounds.x, y: bounds.y, width: bounds.width, height: 0)
    guard bounds.height > 0, bounds.width > 0 else {
        return ChromeLayout(
            statusBar: empty,
            announcementBanner: empty,
            tasksPane: empty,
            conversation: empty,
            completions: empty,
            turnStatus: empty,
            input: empty,
            shortcuts: empty
        )
    }

    var remaining = bounds.height

    func take(_ rows: Int) -> Int {
        let taken = max(0, min(rows, remaining))
        remaining -= taken
        return taken
    }

    let statusHeight = state.statusBar != nil ? take(1) : 0
    // One blank row between the status bar and the banner (or transcript
    // when no banner is showing). Compact collapses it: upstream's
    // `status_gap` is 0 whenever `top_vpad` is (`views/agent.rs:222`), and
    // compact zeroes `top_vpad` through `eff_outer_vpad`
    // (`appearance/config.rs:222-224`).
    let statusGap = statusHeight > 0 && !compact ? take(1) : 0

    // Announcement banner: 0, 1, or 2 rows, slotted between the status bar
    // and the transcript — same precedence as upstream's agent view
    // (`app_view.rs:5222-5241`): critical (2 rows) wins, then promo (1 row).
    // Its gap is NOT compact-dependent: upstream pushes an unconditional
    // `Length(1)` before the banner (`views/agent.rs:237-238`), and the same
    // holds for the turn-status and completions gaps below.
    //
    // The privacy banner is the slot's second tenant: when its flag is up,
    // the slot grows to whichever tenant needs more rows — upstream's
    // `banner_height.max(privacy_banner::height(inner_width))` fold
    // (`agent_view/render.rs:888-892`). The banner sizes from its exported
    // height-for-width, never a constant, because its body wraps.
    let announcementRows = state.announcementBanner?.height ?? 0
    let privacyBannerRows = state.privacyBanner
        ? pagerPrivacyBannerHeight(width: bounds.width)
        : 0
    let bannerRows = max(announcementRows, privacyBannerRows)
    let announcementHeight = bannerRows > 0 ? take(bannerRows) : 0
    let announcementGap = announcementHeight > 0 ? take(1) : 0

    // The Ctrl+G tasks pane (B1-t): a full-width band directly below the
    // status bar/banner, upstream's `Constraint::Length(tasks_height)` slot
    // between the status bar and the scrollback (`views/agent.rs:210-213`,
    // gap row included via `pane_gap`). Sized by the pane's own
    // `desired_height` rule so a short terminal hides it entirely.
    let tasksPaneRows = state.tasksPane?.desiredHeight(viewHeight: bounds.height) ?? 0
    let tasksPaneHeight = tasksPaneRows > 0 ? take(tasksPaneRows) : 0
    let tasksPaneGap = tasksPaneHeight > 0 ? take(1) : 0

    let shortcutsHeight = state.shortcuts != nil ? take(1) : 0
    // The reference drops the bottom padding row on short terminals, and in
    // compact mode: `shortcuts_gap` is 0 whenever `bottom_vpad` is
    // (`views/agent.rs:256`), and compact zeroes `bottom_vpad` the same way
    // it zeroes `top_vpad`.
    let bottomGap = shortcutsHeight > 0 && !compact
        && bounds.height > PagerLayoutMetrics.shortTerminalRows
        ? take(1)
        : 0

    let composerHeight = take(pagerComposerHeight(state.input, width: bounds.width))
    // `prompt_gap` is 0 in compact mode (`agent_view/render.rs:1138-1145`;
    // the turn-status-gap and short-terminal arms of that expression have no
    // port seam yet — this port's turn status always keeps its own gap row).
    let promptGap = composerHeight > 0 && !compact ? take(1) : 0

    let turnStatusHeight = state.turnStatus != nil ? take(1) : 0
    let turnStatusGap = turnStatusHeight > 0 ? take(1) : 0

    let completionsHeight = (state.completions?.isEmpty == false)
        ? take(state.completions!.visibleRowCount)
        : 0
    let completionsGap = completionsHeight > 0 ? take(1) : 0

    let conversationHeight = max(0, remaining)
    _ = (statusGap, announcementGap, bottomGap, promptGap, turnStatusGap, completionsGap)

    var y = bounds.y
    func place(_ height: Int, gapAfter: Int = 0) -> TerminalRect {
        let rect = TerminalRect(x: bounds.x, y: y, width: bounds.width, height: height)
        y += height + gapAfter
        return rect
    }

    let statusBar = place(statusHeight, gapAfter: statusGap)
    let announcementBanner = place(announcementHeight, gapAfter: announcementGap)
    let tasksPane = place(tasksPaneHeight, gapAfter: tasksPaneGap)
    let conversation = place(conversationHeight, gapAfter: completionsGap)
    let completions = place(completionsHeight, gapAfter: turnStatusGap)
    let turnStatus = place(turnStatusHeight, gapAfter: promptGap)
    let input = place(composerHeight, gapAfter: bottomGap)
    let shortcuts = place(shortcutsHeight)

    return ChromeLayout(
        statusBar: statusBar,
        announcementBanner: announcementBanner,
        tasksPane: tasksPane,
        conversation: conversation,
        completions: completions,
        turnStatus: turnStatus,
        input: input,
        shortcuts: shortcuts
    )
}

// MARK: - Transcript lines

/// One painted transcript row: an optional accent-rail glyph, an optional
/// full-row background band, and the styled content spans.
struct PaintLine {
    var accentGlyph: String?
    var accentColor: TerminalColor?
    var background: TerminalColor?
    var foreground: TerminalColor
    var style: CellStyle
    var spans: [PagerStyledSpan]

    init(
        _ text: String,
        foreground: TerminalColor,
        style: CellStyle = [],
        accentGlyph: String? = nil,
        accentColor: TerminalColor? = nil,
        background: TerminalColor? = nil
    ) {
        self.init(
            spans: [PagerStyledSpan(text: text)],
            foreground: foreground,
            style: style,
            accentGlyph: accentGlyph,
            accentColor: accentColor,
            background: background
        )
    }

    init(
        spans: [PagerStyledSpan],
        foreground: TerminalColor,
        style: CellStyle = [],
        accentGlyph: String? = nil,
        accentColor: TerminalColor? = nil,
        background: TerminalColor? = nil
    ) {
        self.spans = spans
        self.foreground = foreground
        self.style = style
        self.accentGlyph = accentGlyph
        self.accentColor = accentColor
        self.background = background
    }

    var text: String { spans.map(\.text).joined() }
}

func makeConversationLines(
    _ items: [PagerConversationItem],
    width: Int,
    theme: PagerRenderTheme,
    selectedIndex: Int? = nil,
    motion: PagerMotionSnapshot = PagerMotionSnapshot(),
    compact: Bool = false,
    showTimestamps: Bool = false
) -> [PaintLine] {
    makeConversationLayout(
        items,
        width: width,
        theme: theme,
        selectedIndex: selectedIndex,
        motion: motion,
        compact: compact,
        showTimestamps: showTimestamps
    ).lines
}

/// The laid-out transcript plus each block's first line index and content-only
/// height — the port's counterpart of upstream's layout cache `virtual_y`
/// rows and per-entry heights (`scrollback/state/layout.rs`), which the
/// timeline rail partitions to find the viewport-top turn and click-to-select
/// uses to reject gap rows. One entry per item; starts and heights are
/// recorded as the lines are appended so they can never drift from what paints.
struct ConversationLayout {
    var lines: [PaintLine]
    var blockStartLines: [Int]
    /// Content rows only — recorded before each inter-block gap so a hit on
    /// the gap returns nil (`entry_at_content_y`, layout.rs:118-123).
    var blockHeights: [Int]
}

func makeConversationLayout(
    _ items: [PagerConversationItem],
    width: Int,
    theme: PagerRenderTheme,
    selectedIndex: Int? = nil,
    motion: PagerMotionSnapshot = PagerMotionSnapshot(),
    compact: Bool = false,
    showTimestamps: Bool = false
) -> ConversationLayout {
    guard width > 0 else {
        return ConversationLayout(lines: [], blockStartLines: [], blockHeights: [])
    }
    var lines: [PaintLine] = []
    var blockStartLines: [Int] = []
    var blockHeights: [Int] = []
    blockStartLines.reserveCapacity(items.count)
    blockHeights.reserveCapacity(items.count)
    for (index, item) in items.enumerated() {
        let blockStart = lines.count
        blockStartLines.append(blockStart)
        switch item {
        case .message(let message):
            appendMessage(
                message,
                width: width,
                theme: theme,
                compact: compact,
                showTimestamps: showTimestamps,
                into: &lines
            )
        case .tool(let tool):
            appendToolCard(tool, width: width, theme: theme, motion: motion, into: &lines)
        case .separator(let text):
            let separator = text.isEmpty ? String(repeating: "─", count: width) : text
            lines.append(PaintLine(separator, foreground: theme.grayDim))
        }
        // Content-only height: capture before the gap row so packed tools
        // abut (height reaches the next start) and gapped neighbors leave a
        // nil-hit row between them.
        blockHeights.append(lines.count - blockStart)
        // The selected block wears the accent rail and the visual band, which
        // is how the reference marks it under `When::ScrollbackFocused`. Rows
        // that already carry a band — a user prompt's `bg_light` — keep theirs,
        // so the marker reads as a selection rather than a repaint.
        if index == selectedIndex {
            for line in blockStart..<lines.count {
                lines[line].accentGlyph = PagerGlyphs.accentBar
                lines[line].accentColor = theme.selectionBorder
                if lines[line].background == nil {
                    lines[line].background = theme.bgVisual
                }
            }
        }
        // Gap rule (`scrollback/state/layout.rs:1375-1428`): consecutive
        // groupable-and-collapsed blocks pack tight; everything else gets one
        // blank row.
        guard index < items.count - 1 else { continue }
        let next = items[index + 1]
        let packs = item.isGroupable && next.isGroupable && item.isCollapsed && next.isCollapsed
        if !packs {
            lines.append(PaintLine("", foreground: theme.textPrimary))
        }
    }
    return ConversationLayout(
        lines: lines,
        blockStartLines: blockStartLines,
        blockHeights: blockHeights
    )
}

/// Map a screen Y into a conversation block index using the last-frame hit
/// geometry. Pure: no mutable state. Gap rows, empty/malformed arrays, and
/// positions outside the conversation area return `nil` without trapping —
/// the Swift counterpart of upstream's `entry_at_content_y`
/// (`scrollback/state/layout.rs:100-124`) plus the screen-row reject in
/// `entry_index_at_screen_row` (`layout.rs:285-288`).
public func pagerConversationBlockIndex(
    screenY: Int,
    conversation: TerminalRect,
    scrollOffset: Int,
    blockStartLines: [Int],
    blockHeights: [Int]
) -> Int? {
    // Vertical reject only — click-to-select is a row hit, not a text drag.
    guard conversation.height > 0,
          screenY >= conversation.y,
          screenY < conversation.y + conversation.height
    else { return nil }

    let count = min(blockStartLines.count, blockHeights.count)
    guard count > 0 else { return nil }

    let viewportY = screenY - conversation.y
    // Clamp a negative offset the same way paint does (`max(requested, 0)`);
    // a malformed producer must not underflow content Y into traps.
    let contentY = viewportY + max(scrollOffset, 0)

    // partition_point: first index with start > contentY → prior start.
    var lo = 0
    var hi = count
    while lo < hi {
        let mid = lo + (hi - lo) / 2
        if blockStartLines[mid] <= contentY {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    guard lo > 0 else { return nil }
    let idx = lo - 1
    let start = blockStartLines[idx]
    let height = blockHeights[idx]
    // Non-positive / nonsense heights never contain a row. Subtract rather
    // than `start + height` so a pathological height cannot overflow.
    guard height > 0, contentY >= start, contentY - start < height else { return nil }
    return idx
}

func appendMessage(
    _ message: PagerMessage,
    width: Int,
    theme: PagerRenderTheme,
    compact: Bool = false,
    showTimestamps: Bool = false,
    thinkingBodyBudget: Int? = PagerLayoutMetrics.thinkingTruncatedLines,
    into lines: inout [PaintLine]
) {
    // The timestamp role gate, `EntryRenderer::should_show_timestamp`
    // (`entry_renderer.rs:376-382`): user and agent messages only — never
    // thinking traces, tool calls, or system messages. Upstream's third
    // stamped arm, `RenderBlock::Btw`, has no port counterpart: this port's
    // `/btw` answers ride system notes (a recorded divergence predating this
    // reader), so they fall outside the gate here too.
    switch message.role {
    case .user:
        appendUserPrompt(
            message,
            width: width,
            theme: theme,
            compact: compact,
            showTimestamps: showTimestamps,
            into: &lines
        )
    case .assistant:
        appendAssistantMessage(
            message,
            width: width,
            theme: theme,
            showTimestamps: showTimestamps,
            into: &lines
        )
    case .reasoning:
        appendThinking(message, width: width, theme: theme, bodyBudget: thinkingBodyBudget, into: &lines)
    case .system:
        appendPlain(message, width: width, foreground: theme.accentSystem, theme: theme, into: &lines)
    case .error:
        appendPlain(message, width: width, foreground: theme.accentError, theme: theme, into: &lines)
    }
}

/// User prompts carry a `❯ ` prefix, a `bg_light` band behind every row, and
/// one padded blank row above and below (`blocks/user.rs`).
///
/// Compact mode drops both the padding rows (`has_vpad_for`,
/// `blocks/user.rs:513-515`: `prompt.vpad && !appearance.prompt.compact`) and
/// the prefix column (`blocks/user.rs:490-494`: `show_prefix && !compact`) —
/// the banded body rows are all that remain.
private func appendUserPrompt(
    _ message: PagerMessage,
    width: Int,
    theme: PagerRenderTheme,
    compact: Bool = false,
    showTimestamps: Bool = false,
    into lines: inout [PaintLine]
) {
    let band = theme.bgLight
    if !compact {
        lines.append(PaintLine("", foreground: theme.textPrimary, background: band))
    }
    // The timestamp column is reserved out of the wrap width whenever the
    // setting is on for this role — with or without a stamp to paint
    // (`timestamp_reserved`, entry_renderer.rs:384-393; the same subtraction
    // upstream applies before wrapping, scrollback_pane.rs:660-670).
    let tsReserved = showTimestamps ? PagerLayoutMetrics.timestampReservedColumns : 0
    let prefixWidth = compact ? 0 : PagerGlyphs.promptArrowWidth
    let bodyWidth = max(1, width - prefixWidth - tsReserved)
    let indentation = String(repeating: " ", count: prefixWidth)
    // The stamp overlays the FIRST CONTENT line — the row after the top
    // padding row when one exists (`first_content_y = content_area.y + if
    // vpad_top_visible { 1 } else { 0 }`, entry_renderer.rs:941-942).
    let firstContentIndex = lines.count
    var isFirstRow = true
    for physical in message.text.split(separator: "\n", omittingEmptySubsequences: false) {
        let wrapped = wrapDisplayLines(String(physical), width: bodyWidth)
        for row in (wrapped.isEmpty ? [""] : wrapped) {
            var spans: [PagerStyledSpan] = []
            if isFirstRow, !compact {
                spans.append(PagerStyledSpan(
                    text: PagerGlyphs.promptArrow,
                    foreground: theme.accentUser
                ))
            } else if !indentation.isEmpty {
                spans.append(PagerStyledSpan(text: indentation))
            }
            isFirstRow = false
            spans.append(contentsOf: userBodySpans(row, theme: theme))
            lines.append(PaintLine(
                spans: spans,
                foreground: theme.textPrimary,
                background: band
            ))
        }
    }
    if isFirstRow {
        lines.append(PaintLine(
            spans: compact
                ? []
                : [PagerStyledSpan(text: PagerGlyphs.promptArrow, foreground: theme.accentUser)],
            foreground: theme.textPrimary,
            background: band
        ))
    }
    if showTimestamps, firstContentIndex < lines.count {
        overlayTimestamp(
            message.createdAt,
            width: width,
            theme: theme,
            on: &lines[firstContentIndex]
        )
    }
    if !compact {
        lines.append(PaintLine("", foreground: theme.textPrimary, background: band))
    }
}

/// A recognized leading `/slash` token is painted in `accent_skill`
/// (`blocks/user.rs:230-244`).
private func userBodySpans(_ row: String, theme: PagerRenderTheme) -> [PagerStyledSpan] {
    guard row.hasPrefix("/") else {
        return [PagerStyledSpan(text: row, foreground: theme.textPrimary)]
    }
    let token = row.prefix { !$0.isWhitespace }
    let rest = String(row.dropFirst(token.count))
    var spans = [PagerStyledSpan(text: String(token), foreground: theme.accentSkill)]
    if !rest.isEmpty {
        spans.append(PagerStyledSpan(text: rest, foreground: theme.textPrimary))
    }
    return spans
}

/// Assistant messages have no prefix, no bullet and no accent rail — just
/// markdown at the content column (`blocks/agent.rs:203-217`).
private func appendAssistantMessage(
    _ message: PagerMessage,
    width: Int,
    theme: PagerRenderTheme,
    showTimestamps: Bool = false,
    into lines: inout [PaintLine]
) {
    var styledLines = message.styledLines
    if styledLines.isEmpty {
        styledLines = message.text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { PagerStyledLine(text: String($0)) }
        if styledLines.isEmpty { styledLines = [PagerStyledLine(text: "")] }
    }
    if message.isStreaming {
        let cursor = PagerStyledSpan(text: "▌", foreground: theme.accentUser)
        if styledLines.isEmpty {
            styledLines = [PagerStyledLine(spans: [cursor])]
        } else {
            styledLines[styledLines.count - 1].spans.append(cursor)
        }
    }
    // Same reserve-then-overlay shape as the user prompt: wrap at the
    // reduced width (`timestamp_reserved`, entry_renderer.rs:384-393), stamp
    // the first content line. An agent message has no padding rows, so the
    // first appended line is the first content line.
    let tsReserved = showTimestamps ? PagerLayoutMetrics.timestampReservedColumns : 0
    let firstContentIndex = lines.count
    for styledLine in styledLines {
        for row in wrapStyledSpans(styledLine.spans, width: max(1, width - tsReserved)) {
            lines.append(PaintLine(spans: row, foreground: theme.textPrimary))
        }
    }
    if showTimestamps, firstContentIndex < lines.count {
        overlayTimestamp(
            message.createdAt,
            width: width,
            theme: theme,
            on: &lines[firstContentIndex]
        )
    }
}

/// Right-align the short timestamp on one content line — the port of the
/// overlay at `entry_renderer.rs:930-960`: gated on the flag (call sites),
/// on the block carrying an instant (`let Some(ts) = self.entry.created_at`,
/// entry_renderer.rs:939 — `nil` paints nothing), and on the line being wide
/// enough (`content_area.width > ts_width + 1`, entry_renderer.rs:956), with
/// `theme.gray` as the stamp color (entry_renderer.rs:958).
///
/// Divergence from upstream's buffer overlay: this painter appends spans, it
/// cannot overwrite cells, so a first line that already reaches into the
/// reserved column — only the streaming cursor can get there, since text is
/// wrapped short of it — skips the stamp for that frame instead of painting
/// over content. Cost: a one-column collision upstream would overpaint is a
/// missing stamp here until the next repaint moves the cursor.
private func overlayTimestamp(
    _ createdAt: Date?,
    width: Int,
    theme: PagerRenderTheme,
    on line: inout PaintLine
) {
    guard let createdAt else { return }
    let stamp = pagerFormatTimestamp(createdAt)
    let stampWidth = UnicodeDisplayWidth.width(of: stamp)
    guard width > stampWidth + 1 else { return }
    let pad = width - stampWidth - UnicodeDisplayWidth.width(of: line.text)
    guard pad >= 0 else { return }
    if pad > 0 {
        line.spans.append(PagerStyledSpan(text: String(repeating: " ", count: pad)))
    }
    line.spans.append(PagerStyledSpan(text: stamp, foreground: theme.gray))
}

/// `Thinking…` while streaming, collapsing to `Thought for 1.4s` when the turn
/// ends. Truncated mode shows a lone `…` and the last three lines
/// (`blocks/thinking.rs`).
///
/// `bodyBudget` is the truncation escape hatch for minimal mode's committed
/// blocks (upstream `DisplayMode::Expanded`, `thinking.rs`: "Expanded: full
/// content" — K9 commits reasoning in full): `nil` renders the whole body.
/// The strip's callers keep the default truncated budget.
func appendThinking(
    _ message: PagerMessage,
    width: Int,
    theme: PagerRenderTheme,
    bodyBudget: Int? = PagerLayoutMetrics.thinkingTruncatedLines,
    into lines: inout [PaintLine]
) {
    var header: [PagerStyledSpan] = [
        PagerStyledSpan(text: PagerGlyphs.toolBullet + " ", foreground: theme.grayDim)
    ]
    if message.isStreaming {
        header.append(PagerStyledSpan(
            text: "Thinking\(PagerGlyphs.ellipsis)",
            foreground: theme.gray,
            style: [.bold]
        ))
    } else {
        header.append(PagerStyledSpan(text: "Thought", foreground: theme.gray, style: [.bold]))
        if let duration = message.duration {
            header.append(PagerStyledSpan(
                text: " for \(pagerFormatDuration(duration))",
                foreground: theme.gray
            ))
        }
    }
    lines.append(PaintLine(spans: header, foreground: theme.gray))
    guard !message.isCollapsed, !message.text.isEmpty else { return }

    let accent = message.isStreaming ? theme.accentThinking : theme.grayDim
    let bodyWidth = max(1, width - 2)
    var body: [String] = []
    for physical in message.text.split(separator: "\n", omittingEmptySubsequences: false) {
        body.append(contentsOf: wrapDisplayLines(String(physical), width: bodyWidth))
    }
    if let budget = bodyBudget, body.count > budget {
        lines.append(PaintLine(
            spans: [PagerStyledSpan(text: "  " + PagerGlyphs.ellipsis, foreground: theme.gray)],
            foreground: theme.gray,
            accentGlyph: PagerGlyphs.accentBar,
            accentColor: accent
        ))
        body = Array(body.suffix(budget))
    }
    for row in body {
        lines.append(PaintLine(
            spans: [PagerStyledSpan(text: "  " + row, foreground: theme.grayDim)],
            foreground: theme.grayDim,
            accentGlyph: PagerGlyphs.accentBar,
            accentColor: accent
        ))
    }
}

private func appendPlain(
    _ message: PagerMessage,
    width: Int,
    foreground: TerminalColor,
    theme: PagerRenderTheme,
    into lines: inout [PaintLine]
) {
    for physical in message.text.split(separator: "\n", omittingEmptySubsequences: false) {
        let wrapped = wrapDisplayLines(String(physical), width: width)
        for row in (wrapped.isEmpty ? [""] : wrapped) {
            lines.append(PaintLine(row, foreground: foreground))
        }
    }
}

// MARK: - Tool cards

/// Accent color for a tool row (`blocks/tool/*`): status is carried by color
/// alone — there are no per-status glyphs.
func pagerToolAccent(_ tool: PagerToolCard, theme: PagerRenderTheme) -> TerminalColor {
    switch tool.state {
    case .failed: return theme.accentError
    case .cancelled: return theme.accentError
    case .running: return theme.accentRunning
    case .succeeded: return tool.kind == .execute ? theme.accentSuccess : theme.accentTool
    case .pending: return theme.grayDim
    }
}

func appendToolCard(
    _ tool: PagerToolCard,
    width: Int,
    theme: PagerRenderTheme,
    motion: PagerMotionSnapshot,
    unboundedPreview: Bool = false,
    into lines: inout [PaintLine]
) {
    let accent = pagerToolAccent(tool, theme: theme)
    // Finish flash (`scrollback/state/types.rs:84`): a block that just reached
    // a terminal state keeps its bright accent — rail included — for 400 ms,
    // then settles into the static look below. Flashes ride along on frames
    // that were happening anyway; they never demand a tick of their own
    // (`scrollback/state/mod.rs:507-518`).
    let isFlashing = motion.enabled
        && tool.state != .running && tool.state != .pending
        && tool.finishedAt.map { PagerMotion.isFlashing(finishedAt: $0, now: motion.seconds) } == true
    // A collapsed row renders entirely muted and drops the accent rail; the
    // bullet alone carries the status color.
    let muted = !tool.isExpanded && !isFlashing
    let labelColor = muted ? theme.gray : theme.textPrimary
    let argumentColor = muted
        ? theme.gray
        : (tool.kind.argumentIsPath ? theme.path : theme.textPrimary)

    // The accent wave (`tokyonight.rs:300-312`): a running block's rail rows
    // shift phase with their on-screen row, so the accent travels down the
    // block instead of blinking. The paint-line index is the phase input —
    // stable while the transcript is still, advancing as content scrolls,
    // which is the same thing the reference's per-row phase does.
    func railAccent(row: Int) -> TerminalColor {
        guard tool.state == .running else { return accent }
        return PagerMotion.runningAccentColor(
            theme: theme,
            accent: accent,
            tick: motion.tick,
            row: row,
            motionEnabled: motion.enabled
        )
    }

    var header: [PagerStyledSpan] = [
        PagerStyledSpan(text: PagerGlyphs.toolBullet + " ", foreground: accent)
    ]
    if let verb = tool.kind.headerVerb {
        header.append(PagerStyledSpan(text: verb + " ", foreground: labelColor, style: [.bold]))
    } else {
        header.append(PagerStyledSpan(text: tool.name, foreground: labelColor, style: [.bold]))
        if !tool.input.isEmpty {
            header.append(PagerStyledSpan(text: " ", foreground: labelColor))
        }
    }
    if !tool.input.isEmpty {
        header.append(PagerStyledSpan(
            text: singleLineSummary(tool.input),
            foreground: argumentColor
        ))
    }
    if let detail = tool.detail, !detail.isEmpty {
        header.append(PagerStyledSpan(text: " " + detail, foreground: theme.grayDim))
    }

    let accentGlyph = muted ? nil : PagerGlyphs.accentBar
    for (index, row) in wrapStyledSpans(header, width: width).enumerated() {
        lines.append(PaintLine(
            spans: row,
            foreground: labelColor,
            accentGlyph: index == 0 || accentGlyph != nil ? accentGlyph : nil,
            accentColor: railAccent(row: lines.count)
        ))
    }

    guard tool.isExpanded, let output = tool.output, !output.isEmpty else { return }
    lines.append(PaintLine(
        "",
        foreground: theme.gray,
        accentGlyph: PagerGlyphs.accentBar,
        accentColor: railAccent(row: lines.count)
    ))
    let previewColor = tool.state == .failed ? theme.accentError : theme.gray
    for row in toolPreviewRows(output, width: max(1, width - 2), theme: theme, unbounded: unboundedPreview) {
        lines.append(PaintLine(
            spans: [PagerStyledSpan(text: "  " + row.text, foreground: row.foreground ?? previewColor)],
            foreground: previewColor,
            accentGlyph: PagerGlyphs.accentBar,
            accentColor: railAccent(row: lines.count)
        ))
    }
}

/// Head/tail preview with the reference's `… +{n} lines` marker
/// (`execute.rs:551-620`). `unbounded` is minimal mode's committed-Expanded
/// escape (K9 "diffs always full", `commit.rs:128`): every wrapped row, no
/// marker — the CAP on a committed block is applied downstream by the
/// `… N more lines` footer, not here. The strip's callers keep the preview.
private func toolPreviewRows(
    _ output: String,
    width: Int,
    theme: PagerRenderTheme,
    unbounded: Bool = false
) -> [PagerStyledSpan] {
    var wrapped: [String] = []
    for physical in output.split(separator: "\n", omittingEmptySubsequences: false) {
        wrapped.append(contentsOf: wrapDisplayLines(String(physical), width: width))
    }
    let head = PagerLayoutMetrics.executePreviewFirstLines
    let tail = PagerLayoutMetrics.executePreviewLastLines
    guard !unbounded, wrapped.count > head + tail + 1 else {
        return wrapped.map { PagerStyledSpan(text: $0) }
    }
    let hidden = wrapped.count - head - tail
    var rows = wrapped.prefix(head).map { PagerStyledSpan(text: $0) }
    rows.append(PagerStyledSpan(
        text: "\(PagerGlyphs.ellipsis) +\(hidden) lines",
        foreground: theme.grayDim
    ))
    rows.append(contentsOf: wrapped.suffix(tail).map { PagerStyledSpan(text: $0) })
    return rows
}

private func singleLineSummary(_ value: String) -> String {
    guard let first = value.split(separator: "\n", omittingEmptySubsequences: false).first else {
        return value
    }
    return String(first)
}

// MARK: - Status bar

@discardableResult
private func renderStatusBar(
    _ status: PagerStatusBar?,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme,
    motion: PagerMotionSnapshot = PagerMotionSnapshot()
) -> TerminalRect? {
    guard let status, area.height > 0, area.width > 0 else { return nil }
    paintBlank(&buffer, area: area, foreground: theme.gray, background: theme.bgBase)

    let run = statusBarRightSpans(status, theme: theme, motion: motion)
    let right = run.spans
    let rightWidth = right.reduce(0) { $0 + UnicodeDisplayWidth.width(of: $1.text) }
    let leftBudget = max(0, area.width - rightWidth - 1)
    let left = truncateSpans(statusBarLeftSpans(status, theme: theme), to: leftBudget)

    paintSpans(&buffer, spans: left, x: area.x, y: area.y, limit: area.right, background: theme.bgBase)
    var contextBar: TerminalRect?
    if rightWidth > 0, rightWidth <= area.width {
        let runX = area.right - rightWidth
        paintSpans(
            &buffer,
            spans: right,
            x: runX,
            y: area.y,
            limit: area.right,
            background: theme.bgBase
        )
        if let range = run.contextRange {
            contextBar = TerminalRect(
                x: runX + range.lowerBound,
                y: area.y,
                width: range.count,
                height: 1
            )
        }
    }
    return contextBar
}

// MARK: - Announcement banner

/// The dim `hide: /announcements hide` affordance text, shared by both
/// painters. Upstream's `HIDE_CTA` (`views/announcements.rs:44`).
private let announcementHideCTA = "hide: /announcements hide"
/// The right-aligned clickable hide button. Upstream's `HIDE_BUTTON` (`:46`).
private let announcementHideButton = "[hide]"
/// The alert prefix leading a critical title row. Upstream's `TITLE_PREFIX`
/// (`:48`); the message row indents by its width so its column matches the
/// title's.
private let announcementTitlePrefix = "! "
/// Columns between text and the right-aligned button/CTA. Upstream's `GAP`
/// (`:50`).
private let announcementGap = 2

/// Paint the in-session announcement banner slot. Mirrors
/// `views/announcements.rs::render_banner` (`:441-458`): critical is two rows
/// (`! Title` + message), promo is one row (CTA button + optional caption).
/// `dismissible == false` pins the banner — neither hide affordance paints
/// and the title/message reclaim the reserved columns. The promo `message` is
/// not painted here (upstream paints it on the welcome hero), so a promo with
/// no usable CTA renders only its hide affordances.
///
/// The renderer is given the already-resolved slot selection; it does not
/// re-derive critical-wins-over-promo or hidden filtering. A `nil` banner or a
/// zero-sized slot paints nothing.
private func renderAnnouncementBanner(
    _ banner: PagerAnnouncementBanner?,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme,
    links: inout [LinkSpan]
) {
    guard let banner, area.height > 0, area.width > 0 else { return }
    paintBlank(&buffer, area: area, foreground: theme.textPrimary, background: theme.bgBase)
    switch banner.severity {
    case .critical:
        renderCriticalAnnouncementRows(banner, in: area, buffer: &buffer, theme: theme)
    case .promo:
        renderPromoAnnouncementRow(banner, in: area, buffer: &buffer, theme: theme, links: &links)
    }
}

/// Critical layout (2 rows): row 0 `! Title` (error red, bold) with a
/// right-aligned dim `[hide]` button when dismissible; row 1 the message
/// (default fg) indented to the title column, then the dim
/// `hide: /announcements hide` CTA. The CTA width is reserved up front so a
/// long message truncates with `…` instead of pushing the CTA off-screen.
/// Non-dismissible paints neither hide affordance and reclaims the reserved
/// widths (`W−2` for both rows).
private func renderCriticalAnnouncementRows(
    _ banner: PagerAnnouncementBanner,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) {
    let maxW = area.width
    let prefixW = UnicodeDisplayWidth.width(of: announcementTitlePrefix)
    let buttonW = UnicodeDisplayWidth.width(of: announcementHideButton)
    let row0 = area.y
    let row1 = area.y + 1
    let maxY = area.y + area.height
    let alertStyle: CellStyle = [.bold]
    let alertFG = theme.accentError
    let dimFG = theme.gray
    let dismissible = banner.dismissible

    if row0 < maxY {
        // `! ` prefix anchors the alert even when the title is missing.
        buffer.setString(
            x: area.x,
            y: row0,
            text: truncateToWidth(announcementTitlePrefix, width: maxW),
            style: alertStyle,
            foreground: alertFG,
            background: theme.bgBase
        )

        var hideRectEnd: Int? = nil
        if dismissible {
            // Right-aligned [hide] button, painted first so its width is
            // reserved before the title budget is computed.
            if maxW >= buttonW {
                let hideX = area.x + (maxW - buttonW)
                buffer.setString(
                    x: hideX,
                    y: row0,
                    text: announcementHideButton,
                    style: [.dim],
                    foreground: dimFG,
                    background: theme.bgBase
                )
                hideRectEnd = hideX
            }
        }

        let titleBudget: Int
        if dismissible, let hideX = hideRectEnd {
            titleBudget = max(0, maxW - prefixW - buttonW - announcementGap)
            _ = hideX
        } else {
            titleBudget = max(0, maxW - prefixW)
        }
        if let title = banner.title, titleBudget > 0 {
            buffer.setString(
                x: area.x + prefixW,
                y: row0,
                text: truncateToWidth(title, width: titleBudget),
                style: alertStyle,
                foreground: alertFG,
                background: theme.bgBase
            )
        }
    }

    if row1 < maxY {
        // Message column == title column: indent past the `! ` prefix.
        var x = area.x + prefixW
        var remaining = max(0, maxW - prefixW)
        let ctaW = UnicodeDisplayWidth.width(of: announcementHideCTA)

        let msgBudget: Int
        if dismissible {
            msgBudget = max(0, remaining - ctaW - announcementGap)
        } else {
            msgBudget = remaining
        }
        if let message = banner.message, msgBudget > 0 {
            let msgDisp = truncateToWidth(message, width: msgBudget)
            let msgW = min(UnicodeDisplayWidth.width(of: msgDisp), msgBudget)
            if msgW > 0 {
                buffer.setString(
                    x: x,
                    y: row1,
                    text: msgDisp,
                    style: [],
                    foreground: theme.textPrimary,
                    background: theme.bgBase
                )
                x += msgW + announcementGap
                remaining = max(0, remaining - msgW - announcementGap)
            }
        }
        if dismissible, remaining > 0 {
            buffer.setString(
                x: x,
                y: row1,
                text: truncateToWidth(announcementHideCTA, width: remaining),
                style: [.dim],
                foreground: dimFG,
                background: theme.bgBase
            )
        }
    }
}

/// Promo layout (1 row): the `[Label]` CTA button (semantic warning yellow)
/// leads the row and is omitted when the promo has no usable CTA. The dim
/// `ctaCaption` follows the button only for a *pinned* promo
/// (`dismissible == false`); a dismissible promo keeps `Ctrl+O` on YOLO so the
/// caption is suppressed. The right-hand `[hide]` + `hide: /announcements hide`
/// affordances are reserved first (dismissible only) so the button + caption
/// never overpaint them. The promo `message` is not painted here.
private func renderPromoAnnouncementRow(
    _ banner: PagerAnnouncementBanner,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme,
    links: inout [LinkSpan]
) {
    let maxW = area.width
    let row = area.y
    let buttonW = UnicodeDisplayWidth.width(of: announcementHideButton)
    let hideCTAW = UnicodeDisplayWidth.width(of: announcementHideCTA)
    let dimFG = theme.gray
    let dismissible = banner.dismissible

    // Non-dismissible: neither hide affordance paints and `rightReserved`
    // stays 0, so the button reclaims the right-hand columns.
    var rightReserved = 0
    if dismissible {
        if maxW >= buttonW {
            let hideX = area.x + (maxW - buttonW)
            buffer.setString(
                x: hideX,
                y: row,
                text: announcementHideButton,
                style: [.dim],
                foreground: dimFG,
                background: theme.bgBase
            )
        }
        // Dim hide CTA directly left of the button; skipped whole when it
        // cannot fit (redundant with [hide], so no partial paint).
        if maxW >= buttonW + announcementGap + hideCTAW {
            let hideCTAX = area.x + (maxW - buttonW - announcementGap - hideCTAW)
            buffer.setString(
                x: hideCTAX,
                y: row,
                text: announcementHideCTA,
                style: [.dim],
                foreground: dimFG,
                background: theme.bgBase
            )
            rightReserved = buttonW + announcementGap + hideCTAW
        } else if maxW >= buttonW {
            rightReserved = buttonW + announcementGap
        }
    }

    let remaining: Int
    if rightReserved > 0 {
        remaining = max(0, maxW - rightReserved - announcementGap)
    } else {
        remaining = maxW
    }
    guard remaining > 0, let label = banner.ctaLabel, !label.isEmpty else { return }

    // Caption only for a pinned promo whose `Ctrl+O` actually opens the CTA.
    let caption: String? = (!dismissible) ? banner.ctaCaption : nil
    guard let rect = drawAnnouncementCTAButton(
        &buffer,
        x: area.x,
        y: row,
        maxWidth: remaining,
        label: label,
        caption: caption,
        hovered: false,
        theme: theme
    ) else { return }
    if let url = banner.ctaURL, !url.isEmpty {
        links.append(LinkSpan(row: row, colStart: rect.x, colEnd: rect.x + rect.width, url: url))
    }
}

/// Paint the promo upgrade `[label]` button (semantic warning yellow; hovered
/// → `bgHover` behind it), then the dim ` caption` one space after when it
/// fits — dropped WHOLE when it does not (never a partial). Returns the
/// clickable button rect (caption excluded), or `nil` when not even a clipped
/// button fits. The ONE painter every surface shares — upstream's
/// `render_cta_button` (`views/announcements.rs:71-118` at pin 650c1db7:
/// "the ONE painter every surface (banner, hero, in-session header,
/// dashboard) shares so the button/caption style, truncation, and clamping
/// can't drift") — used by the chrome banner's promo row and the welcome
/// hero/stacked announcement arm. The over-narrow label truncates WITH the
/// `…` (upstream `truncate_str`, `line_utils.rs:83-104`).
@discardableResult
func drawAnnouncementCTAButton(
    _ buffer: inout CellBuffer,
    x: Int,
    y: Int,
    maxWidth: Int,
    label: String,
    caption: String?,
    hovered: Bool,
    theme: PagerRenderTheme
) -> TerminalRect? {
    guard maxWidth > 0 else { return nil }
    let button = "[\(label)]"
    let disp = truncateWithEllipsis(button, width: maxWidth)
    let dispW = min(UnicodeDisplayWidth.width(of: disp), maxWidth)
    guard dispW > 0 else { return nil }
    buffer.setString(
        x: x,
        y: y,
        text: disp,
        style: [],
        foreground: theme.warning,
        background: hovered ? theme.bgHover : theme.bgBase
    )
    // Reservation-first: the button is already painted; the dim caption
    // follows one space later, whole-or-not (`announcements.rs:99-116`).
    if let caption, !caption.isEmpty {
        let cap = " \(caption)"
        let capW = UnicodeDisplayWidth.width(of: cap)
        if dispW + capW <= maxWidth {
            buffer.setString(
                x: x + dispW,
                y: y,
                text: cap,
                style: [.dim],
                foreground: theme.gray,
                background: theme.bgBase
            )
        }
    }
    return TerminalRect(x: x, y: y, width: dispW, height: 1)
}

private func statusBarLeftSpans(
    _ status: PagerStatusBar,
    theme: PagerRenderTheme
) -> [PagerStyledSpan] {
    var spans: [PagerStyledSpan] = []
    if status.isDetached || status.gitBranch != nil {
        let branch = status.gitBranch ?? "detached"
        spans.append(PagerStyledSpan(
            text: "\u{2387} \(status.isDetached ? "detached" : branch)",
            foreground: theme.textPrimary,
            style: [.dim]
        ))
        spans.append(PagerStyledSpan(text: " ", foreground: theme.gray))
    }
    if status.isWorktree {
        spans.append(PagerStyledSpan(text: "worktree ", foreground: theme.accentUser))
    }
    if let sandbox = status.sandboxProfile, !sandbox.isEmpty {
        spans.append(PagerStyledSpan(text: "sandbox:\(sandbox) ", foreground: theme.warning))
    }
    if let cwd = status.workingDirectory, !cwd.isEmpty {
        spans.append(PagerStyledSpan(text: cwd, foreground: theme.grayDim))
    }
    if let main = status.mainRepository, !main.isEmpty, status.isWorktree {
        spans.append(PagerStyledSpan(text: " (worktree of \(main))", foreground: theme.grayDim))
    }
    return spans
}

private struct StatusBarRightRun {
    var spans: [PagerStyledSpan]
    /// The context segment's display-column range within the run, for the
    /// hover router's rect (B6).
    var contextRange: Range<Int>?
}

private func statusBarRightSpans(
    _ status: PagerStatusBar,
    theme: PagerRenderTheme,
    motion: PagerMotionSnapshot = PagerMotionSnapshot()
) -> StatusBarRightRun {
    var groups: [[PagerStyledSpan]] = []
    var contextGroupIndex: Int?
    if status.backgroundTaskCount > 0 {
        // The chip spins while background tasks run (`agent_status.rs:278,317`
        // draws `dot_spinner_frames()[tick / SPINNER_DIVISOR]`). With motion
        // disabled the tick is pinned at 0 and this renders the first frame —
        // the exact glyph this row always showed.
        groups.append([PagerStyledSpan(
            text: "\(PagerMotion.dotFrame(tick: motion.enabled ? motion.tick : 0)) \(status.backgroundTaskCount)",
            foreground: theme.accentRunning
        )])
    }
    if status.isPlanMode {
        groups.append([PagerStyledSpan(text: "plan", foreground: theme.accentPlan)])
    }
    if let context = contextIndicatorSpans(status, theme: theme) {
        contextGroupIndex = groups.count
        groups.append(context)
    }
    if status.queuedPromptCount > 0 {
        groups.append([PagerStyledSpan(
            text: "+\(status.queuedPromptCount)",
            foreground: theme.accentUser
        )])
    }
    guard !groups.isEmpty else { return StatusBarRightRun(spans: [], contextRange: nil) }
    var spans: [PagerStyledSpan] = []
    var contextRange: Range<Int>?
    var column = 0
    for (index, group) in groups.enumerated() {
        if index > 0 {
            let separator = PagerStyledSpan(
                text: " \(PagerGlyphs.statusSeparator) ",
                foreground: theme.grayDim
            )
            spans.append(separator)
            column += UnicodeDisplayWidth.width(of: separator.text)
        }
        let width = group.reduce(0) { $0 + UnicodeDisplayWidth.width(of: $1.text) }
        if index == contextGroupIndex {
            contextRange = column..<(column + width)
        }
        spans.append(contentsOf: group)
        column += width
    }
    return StatusBarRightRun(spans: spans, contextRange: contextRange)
}

/// `"8.5K / 1.0M"`, right-padded to at least six columns, colored by the
/// context ramp (`views/context_bar.rs`).
/// `fmt_pct5` (`context_bar.rs:25-33`): always five characters, so the
/// hovered line's width never depends on the value. HARDENED past
/// upstream: 99.95–99.99 round-formats to "100.0%" — six characters —
/// through upstream's own arms (a latent width-invariant break there);
/// the port clamps any over-wide result to the MAX form instead.
func pagerFormatPct5(_ pct: Double) -> String {
    if pct >= 100 { return "MAX %" }
    let formatted = pct < 10
        ? String(format: "%.2f%%", pct)
        : String(format: "%.1f%%", pct)
    return formatted.count > 5 ? "MAX %" : formatted
}

/// One span per cell of a `width`-cell progress bar at `value` fill —
/// eighth-cell resolution via the LEFT-fractional blocks
/// (`progress_bar.rs:36-58`; the port's `PagerGlyphs.progressBlocks` is the
/// same 9-glyph table). Unfilled cells carry the highlight background so
/// the bar's extent reads even at low fill.
func pagerProgressBarSpans(
    width: Int,
    value: Double,
    color: TerminalColor,
    theme: PagerRenderTheme
) -> [PagerStyledSpan] {
    guard width > 0 else { return [] }
    let clamped = min(1.0, max(0.0, value))
    let totalEighths = Int((clamped * Double(width) * 8.0).rounded())
    let full = min(totalEighths / 8, width)
    let remainder = totalEighths % 8
    return (0..<width).map { index in
        if index < full {
            return PagerStyledSpan(text: PagerGlyphs.progressBlocks[8], foreground: color)
        }
        if index == full, remainder > 0 {
            return PagerStyledSpan(text: PagerGlyphs.progressBlocks[remainder], foreground: color)
        }
        return PagerStyledSpan(text: " ", background: theme.bgVisual)
    }
}

/// The context segment: `8.5K / 1.0M` colored by the urgency gradient, or —
/// hovered — `█████ 42.0%` at the SAME total width so nothing shifts under
/// the pointer (`context_bar_line`, `context_bar.rs:182-260`: the default's
/// ≥6-column pad is what makes the invariant hold for every input).
private func contextIndicatorSpans(
    _ status: PagerStatusBar,
    theme: PagerRenderTheme
) -> [PagerStyledSpan]? {
    guard let used = status.contextUsedTokens,
          let total = status.contextTotalTokens,
          total > 0
    else { return nil }
    var text = "\(pagerFormatTokens(used)) / \(pagerFormatTokens(total))"
    while UnicodeDisplayWidth.width(of: text) < 6 { text += " " }
    let fraction = min(1.0, Double(used) / Double(total))
    let color = pagerContextColor(fraction: fraction, theme: theme)
    guard status.contextBarHovered else {
        return [PagerStyledSpan(text: text, foreground: color)]
    }
    let totalWidth = UnicodeDisplayWidth.width(of: text)
    var spans = pagerProgressBarSpans(
        width: totalWidth - 6, value: fraction, color: color, theme: theme
    )
    spans.append(PagerStyledSpan(text: " "))
    spans.append(PagerStyledSpan(
        text: pagerFormatPct5(fraction * 100), foreground: theme.textSecondary
    ))
    return spans
}

// MARK: - Turn status

func renderTurnStatus(
    _ status: PagerTurnStatus?,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) {
    guard let status, area.height > 0, area.width > 0 else { return }
    paintBlank(&buffer, area: area, foreground: theme.gray, background: theme.bgBase)

    let labelColor = status.isCancelling ? theme.accentError : theme.textSecondary
    // Which cue leads the row (`turn_status.rs`): the braille spinner for a
    // live turn (`:420`), the `◆` pulsing dim→bright in `accent_user` while
    // the turn is parked on the user (`:484-486`), or the calm `○ ◎ ◉ ◎`
    // monitor pulse for idle watcher work (`:322-325`).
    let indicator: PagerStyledSpan
    switch status.indicator {
    case .spinner:
        indicator = PagerStyledSpan(
            text: PagerGlyphs.brailleSpinnerFrame(status.tick) + " ",
            foreground: labelColor
        )
    case .pendingUserDiamond:
        indicator = PagerStyledSpan(
            text: PagerGlyphs.toolBullet + " ",
            foreground: PagerMotion.pendingDiamondColor(
                theme: theme,
                accent: theme.accentUser,
                tick: status.tick
            )
        )
    case .idleMonitor:
        indicator = PagerStyledSpan(
            text: PagerMotion.monitorPulseFrame(tick: status.tick) + " ",
            foreground: theme.accentSystem
        )
    }
    var left: [PagerStyledSpan] = [
        indicator,
        PagerStyledSpan(text: status.label, foreground: labelColor)
    ]
    if status.queuedPromptCount > 0 {
        let suffix = status.queueIsSendable
            ? " \u{00B7} \(status.queuedPromptCount) queued — Enter to send now"
            : " \u{00B7} \(status.queuedPromptCount) queued"
        left.append(PagerStyledSpan(text: suffix, foreground: theme.gray))
    }

    var right: [PagerStyledSpan] = []
    if let elapsed = status.elapsed {
        right.append(PagerStyledSpan(text: pagerFormatDuration(elapsed), foreground: theme.gray))
    }
    if let tokens = status.tokenCount, tokens > 0 {
        if !right.isEmpty { right.append(PagerStyledSpan(text: " ", foreground: theme.gray)) }
        right.append(PagerStyledSpan(
            text: "\(PagerGlyphs.tokenArrow)\(pagerFormatTokens(tokens))",
            foreground: theme.gray
        ))
    }
    right.append(PagerStyledSpan(text: " [stop]", foreground: theme.gray))

    let rightWidth = right.reduce(0) { $0 + UnicodeDisplayWidth.width(of: $1.text) }
    let leftBudget = max(0, area.width - rightWidth - 1)
    paintSpans(
        &buffer,
        spans: truncateSpans(left, to: leftBudget),
        x: area.x,
        y: area.y,
        limit: area.right,
        background: theme.bgBase
    )
    if rightWidth <= area.width {
        paintSpans(
            &buffer,
            spans: right,
            x: area.right - rightWidth,
            y: area.y,
            limit: area.right,
            background: theme.bgBase
        )
    }
}

// MARK: - Completion menu

func renderCompletions(
    _ menu: PagerCompletionMenu?,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) {
    guard let menu, !menu.isEmpty, area.height > 0, area.width > 0 else { return }
    // The dropdown paints at most `maxDropdownRows` rows but the match list is
    // no longer capped upstream of here, so the window follows the selection:
    // a selected row below the fold pulls the window down, one above pulls it
    // up. This is what makes row seven reachable from a bare `/` — upstream
    // leaves the same job to the dropdown renderer (`slash/mod.rs:866`,
    // "No cap here -- the dropdown renderer handles scrolling").
    var start = min(max(0, menu.scrollOffset), max(0, menu.rows.count - 1))
    if let selected = menu.selectedIndex, menu.rows.indices.contains(selected) {
        if selected < start {
            start = selected
        } else if selected >= start + area.height {
            start = selected - area.height + 1
        }
    }
    start = min(start, max(0, menu.rows.count - area.height))
    let end = min(menu.rows.count, start + area.height)
    let labelWidth = menu.rows[start..<end]
        .reduce(0) { max($0, UnicodeDisplayWidth.width(of: $1.label)) }

    for (row, index) in (start..<end).enumerated() {
        guard row < area.height else { break }
        let entry = menu.rows[index]
        let isSelected = index == menu.selectedIndex
        let background = isSelected ? theme.bgVisual : theme.bgBase
        let rowArea = TerminalRect(x: area.x, y: area.y + row, width: area.width, height: 1)
        paintBlank(&buffer, area: rowArea, foreground: theme.textPrimary, background: background)

        let labelColor = entry.isAvailable ? theme.textPrimary : theme.grayDim
        var spans: [PagerStyledSpan] = [
            PagerStyledSpan(
                text: isSelected ? PagerGlyphs.promptArrow : "  ",
                foreground: theme.accentUser,
                style: isSelected ? [.bold] : []
            ),
            PagerStyledSpan(
                text: entry.label.padding(
                    toDisplayWidth: labelWidth,
                    ifShorter: true
                ),
                foreground: labelColor,
                style: isSelected ? [.bold] : []
            )
        ]
        if !entry.summary.isEmpty {
            spans.append(PagerStyledSpan(text: "  " + entry.summary, foreground: theme.gray))
        }
        paintSpans(
            &buffer,
            spans: spans,
            x: area.x,
            y: rowArea.y,
            limit: area.right,
            background: background
        )
    }
}

// MARK: - Composer

func renderComposer(
    _ input: PagerComposerState,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) -> TerminalPoint? {
    guard area.height > 0, area.width >= 4 else { return nil }
    let borderColor = input.isFocused ? theme.promptBorderActive : theme.promptBorder
    let captionColor = blendPagerColors(
        theme.bgBase,
        theme.textSecondary,
        input.isFocused ? 0.6 : 0.4
    )

    for row in 0..<area.height {
        paintBlank(
            &buffer,
            area: TerminalRect(x: area.x, y: area.y + row, width: area.width, height: 1),
            foreground: theme.textPrimary,
            background: theme.bgBase
        )
    }

    let hasBorders = input.showBorders && area.height >= 3
    let textTop = hasBorders ? area.y + 1 : area.y
    let textBottom = hasBorders ? area.bottom - 1 : area.bottom
    let textX = area.x + (hasBorders ? 2 : 0)
    let textRight = area.right - (hasBorders ? 2 : 0)

    if hasBorders {
        drawBorderRow(
            &buffer,
            y: area.y,
            area: area,
            left: PagerGlyphs.borderTopLeft,
            right: PagerGlyphs.borderTopRight,
            color: borderColor,
            theme: theme
        )
        drawBorderRow(
            &buffer,
            y: area.bottom - 1,
            area: area,
            left: PagerGlyphs.borderBottomLeft,
            right: PagerGlyphs.borderBottomRight,
            color: borderColor,
            theme: theme
        )
        for y in textTop..<textBottom {
            setCharacter(&buffer, x: area.x, y: y, PagerGlyphs.borderVertical, color: borderColor, theme: theme)
            setCharacter(&buffer, x: area.right - 1, y: y, PagerGlyphs.borderVertical, color: borderColor, theme: theme)
        }
        // Session title inlined in the top border, right-aligned three cells
        // from the edge (`prompt_widget/mod.rs:2971-2993`).
        if let title = input.title, !title.isEmpty, area.width - 6 >= 6 {
            let label = " \(truncateToWidth(title, width: max(0, area.width - 9))) "
            let labelWidth = UnicodeDisplayWidth.width(of: label)
            _ = buffer.setString(
                x: area.right - (3 + labelWidth),
                y: area.y,
                text: label,
                style: [],
                foreground: captionColor,
                background: theme.bgBase
            )
        }
        renderComposerInfoLine(
            input,
            y: area.bottom - 1,
            area: area,
            buffer: &buffer,
            theme: theme,
            captionColor: captionColor,
            borderColor: borderColor
        )
    }

    let textWidth = max(1, textRight - textX - PagerGlyphs.promptArrowWidth)
    let visibleRows = max(0, textBottom - textTop)
    guard visibleRows > 0 else { return nil }

    // The placeholder stands in for an empty composer.
    if input.text.isEmpty, !input.placeholder.isEmpty {
        _ = buffer.setString(
            x: textX,
            y: textTop,
            text: input.prefix,
            style: [],
            foreground: input.isFocused ? theme.accentUser : theme.grayDim,
            background: theme.bgBase
        )
        _ = buffer.setString(
            x: textX + PagerGlyphs.promptArrowWidth,
            y: textTop,
            text: truncateToWidth(input.placeholder, width: textWidth),
            style: [],
            foreground: theme.gray,
            background: theme.bgBase
        )
        guard input.isFocused, input.cursorVisible else { return nil }
        return TerminalPoint(x: textX + PagerGlyphs.promptArrowWidth, y: textTop)
    }

    let rows = wrapDisplayLines(input.text, width: textWidth)
    let cursor = composerCursorRowColumn(input, width: textWidth)
    let firstVisibleRow = max(0, min(cursor.row, rows.count - visibleRows))

    for offset in 0..<visibleRows {
        let index = firstVisibleRow + offset
        let y = textTop + offset
        if offset == 0 {
            _ = buffer.setString(
                x: textX,
                y: y,
                text: input.prefix,
                style: [],
                foreground: input.isFocused ? theme.accentUser : theme.grayDim,
                background: theme.bgBase
            )
        }
        guard rows.indices.contains(index) else { continue }
        _ = buffer.setString(
            x: textX + PagerGlyphs.promptArrowWidth,
            y: y,
            text: truncateToWidth(rows[index], width: textWidth),
            style: [],
            foreground: input.isFocused ? theme.textPrimary : theme.grayDim,
            background: theme.bgBase
        )
    }

    guard input.isFocused, input.cursorVisible else { return nil }
    let cursorRow = cursor.row - firstVisibleRow
    guard cursorRow >= 0, cursorRow < visibleRows else { return nil }
    return TerminalPoint(
        x: min(textRight - 1, textX + PagerGlyphs.promptArrowWidth + cursor.column),
        y: textTop + cursorRow
    )
}

/// Map the composer's character offset onto a wrapped (row, column) position.
func composerCursorRowColumn(_ input: PagerComposerState, width: Int) -> (row: Int, column: Int) {
    let characters = Array(input.text)
    let offset = min(max(input.cursorCharacterOffset ?? characters.count, 0), characters.count)
    let before = String(characters[..<offset])
    let rows = wrapDisplayLines(before, width: max(1, width))
    let row = max(0, rows.count - 1)
    let column = UnicodeDisplayWidth.width(of: rows.last ?? "")
    // A cursor sitting exactly at the wrap boundary belongs on the next row.
    if column >= width, before.last != "\n" {
        return (row + 1, 0)
    }
    return (row, column)
}

private func renderComposerInfoLine(
    _ input: PagerComposerState,
    y: Int,
    area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme,
    captionColor: TerminalColor,
    borderColor: TerminalColor
) {
    let separatorColor = input.isFocused
        ? theme.grayDim
        : blendPagerColors(theme.bgBase, theme.grayDim, 0.6)

    var right: [PagerStyledSpan] = []
    if input.isMultiline {
        right = [
            PagerStyledSpan(text: " multiline ", foreground: theme.gray)
        ]
    }
    let rightWidth = right.reduce(0) { $0 + UnicodeDisplayWidth.width(of: $1.text) }

    var left: [PagerStyledSpan] = []
    if let model = input.modelDisplay {
        left.append(PagerStyledSpan(text: " ", foreground: separatorColor))
        left.append(PagerStyledSpan(text: model, foreground: captionColor))
    }
    for flag in input.flags {
        if left.isEmpty { left.append(PagerStyledSpan(text: " ", foreground: separatorColor)) }
        left.append(PagerStyledSpan(text: " \u{00B7} ", foreground: separatorColor))
        left.append(PagerStyledSpan(
            text: flag.label,
            foreground: flag.foreground ?? theme.gray,
            style: flag.isBold ? [.bold] : []
        ))
    }
    guard !left.isEmpty || !right.isEmpty else { return }
    if !left.isEmpty { left.append(PagerStyledSpan(text: " ", foreground: separatorColor)) }
    _ = borderColor

    let leftWidth = left.reduce(0) { $0 + UnicodeDisplayWidth.width(of: $1.text) }
    // The left group is right-aligned against the right group with a one-column
    // gap, per `prompt_widget/mod.rs:3444-3455`.
    let leftX = area.right - 3 - rightWidth - (rightWidth > 0 ? 1 : 0) - leftWidth
    if leftWidth > 0, leftX > area.x {
        paintSpans(&buffer, spans: left, x: leftX, y: y, limit: area.right - 1, background: theme.bgBase)
    }
    if rightWidth > 0 {
        paintSpans(
            &buffer,
            spans: right,
            x: area.right - 3 - rightWidth,
            y: y,
            limit: area.right - 1,
            background: theme.bgBase
        )
    }
}

private func drawBorderRow(
    _ buffer: inout CellBuffer,
    y: Int,
    area: TerminalRect,
    left: Character,
    right: Character,
    color: TerminalColor,
    theme: PagerRenderTheme
) {
    for x in area.x..<area.right {
        let glyph: Character
        if x == area.x {
            glyph = left
        } else if x == area.right - 1 {
            glyph = right
        } else {
            glyph = PagerGlyphs.borderHorizontal
        }
        setCharacter(&buffer, x: x, y: y, glyph, color: color, theme: theme)
    }
}

private func setCharacter(
    _ buffer: inout CellBuffer,
    x: Int,
    y: Int,
    _ glyph: Character,
    color: TerminalColor,
    theme: PagerRenderTheme
) {
    buffer.setCell(
        Cell(
            grapheme: String(glyph),
            foreground: color,
            background: theme.bgBase,
            displayWidth: 1
        ),
        x: x,
        y: y
    )
}

// MARK: - Shortcuts bar

private func renderShortcutsBar(
    _ bar: PagerShortcutsBar?,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) {
    guard let bar, area.height > 0, area.width > 0 else { return }
    paintBlank(&buffer, area: area, foreground: theme.gray, background: theme.bgBase)

    var spans: [PagerStyledSpan] = []
    if let key = bar.pendingKey, let label = bar.pendingLabel {
        // An armed confirmation replaces the entire bar.
        spans = [
            PagerStyledSpan(text: key, foreground: theme.textSecondary, style: [.bold]),
            PagerStyledSpan(text: ":", foreground: theme.gray),
            PagerStyledSpan(text: "press again to \(label)", foreground: theme.gray)
        ]
    } else {
        for (index, hint) in bar.effectiveHints().enumerated() {
            if index > 0 {
                spans.append(PagerStyledSpan(
                    text: "  \(PagerGlyphs.statusSeparator)  ",
                    foreground: theme.gray,
                    style: [.dim]
                ))
            }
            spans.append(PagerStyledSpan(
                text: hint.keyDisplay,
                foreground: theme.textSecondary,
                style: [.bold]
            ))
            spans.append(PagerStyledSpan(text: ":", foreground: theme.gray))
            spans.append(PagerStyledSpan(text: hint.label, foreground: theme.gray))
        }
    }

    let trailing = bar.trailing.map { "\($0) " } ?? ""
    let trailingWidth = UnicodeDisplayWidth.width(of: trailing)
    let budget = max(0, area.width - (trailingWidth > 0 ? trailingWidth + 1 : 0))
    paintSpans(
        &buffer,
        spans: truncateSpans(spans, to: budget),
        x: area.x,
        y: area.y,
        limit: area.right,
        background: theme.bgBase
    )
    if trailingWidth > 0, trailingWidth <= area.width {
        _ = buffer.setString(
            x: area.right - trailingWidth,
            y: area.y,
            text: trailing,
            style: [],
            foreground: theme.gray,
            background: theme.bgBase
        )
    }
}

// MARK: - Conversation painting

private func renderConversation(
    _ lines: [PaintLine],
    visibleRange: Range<Int>,
    in area: TerminalRect,
    contentWidth: Int,
    hasScrollbar: Bool,
    scrollOffset: Int,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme,
    links: inout [LinkSpan]
) {
    guard area.height > 0, area.width > 0 else { return }
    for row in 0..<area.height {
        paintBlank(
            &buffer,
            area: TerminalRect(x: area.x, y: area.y + row, width: area.width, height: 1),
            foreground: theme.textPrimary,
            background: theme.bgBase
        )
    }

    let contentX = area.x + PagerLayoutMetrics.accentWidth + PagerLayoutMetrics.blockPadLeft
    for (row, lineIndex) in visibleRange.enumerated() {
        guard row < area.height, lines.indices.contains(lineIndex) else { continue }
        let line = lines[lineIndex]
        let y = area.y + row

        if let background = line.background {
            let bandWidth = PagerLayoutMetrics.chromeWidth + contentWidth
            paintBlank(
                &buffer,
                area: TerminalRect(x: area.x, y: y, width: min(bandWidth, area.width), height: 1),
                foreground: line.foreground,
                background: background
            )
        }
        if let glyph = line.accentGlyph {
            _ = buffer.setString(
                x: area.x,
                y: y,
                text: glyph,
                style: [],
                foreground: line.accentColor ?? theme.grayDim,
                background: line.background ?? theme.bgBase
            )
        }
        let rowLinks = paintSpans(
            &buffer,
            spans: line.spans,
            x: contentX,
            y: y,
            limit: contentX + contentWidth,
            background: line.background ?? theme.bgBase,
            inheritForeground: line.foreground,
            inheritStyle: line.style
        )
        links.append(contentsOf: rowLinks)
    }

    guard hasScrollbar, area.height > 0 else { return }
    let scrollbarX = area.x + PagerLayoutMetrics.chromeWidth + contentWidth
    guard scrollbarX < area.right else { return }
    let total = max(lines.count, 1)
    let thumbHeight = max(1, (area.height * area.height) / total)
    let maximumOffset = max(0, lines.count - area.height)
    let trackTravel = max(0, area.height - thumbHeight)
    let thumbStart = maximumOffset == 0
        ? 0
        : min(trackTravel, (scrollOffset * trackTravel) / maximumOffset)
    for row in 0..<area.height {
        let isThumb = row >= thumbStart && row < thumbStart + thumbHeight
        _ = buffer.setString(
            x: scrollbarX,
            y: area.y + row,
            text: isThumb ? "█" : "│",
            style: [],
            foreground: isThumb ? theme.scrollbarForeground : theme.bgLight,
            background: theme.bgBase
        )
    }
}

/// Paint the timeline rail: chevrons + one tick row per windowed turn. The
/// rail draws directly on the scrollback background — no dark track strip
/// (`render_rail`, `views/timeline.rs:207-267`). Chevron dim state derives
/// from the same `pagerTimelineChevronTarget` the click handler uses, so a
/// dim chevron is guaranteed to be a no-op (`views/timeline.rs:220-223`).
///
/// Upstream's hover arms — the bright hovered tick/chevron
/// (`views/timeline.rs:224-237,255-263`) and the tick preview popup
/// (`render_tick_hover_popup`, `:275-357`) — are NOT ported: they need the
/// mouse position at paint time, a seam `PagerRenderState` does not carry
/// (the same missing channel recorded for `/timestamps`' hover-expanded
/// format). Cost: the rail gives no visual feedback under the pointer and
/// no turn preview; clicks still jump.
private func renderTimelineRail(
    _ rail: PagerTimelineRail,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) {
    let upEnabled = pagerTimelineChevronTarget(rail, .up) != nil
    let downEnabled = pagerTimelineChevronTarget(rail, .down) != nil
    // Chevrons live in the rail's rightmost cell (`views/timeline.rs:238`).
    let chevronX = rail.rect.x + PagerTimelineMetrics.railWidth - 1
    _ = buffer.setString(
        x: chevronX,
        y: rail.upY,
        text: PagerGlyphs.timelineChevronUp,
        style: [],
        foreground: upEnabled ? theme.gray : theme.grayDim,
        background: theme.bgBase
    )
    _ = buffer.setString(
        x: chevronX,
        y: rail.downY,
        text: PagerGlyphs.timelineChevronDown,
        style: [],
        foreground: downEnabled ? theme.gray : theme.grayDim,
        background: theme.bgBase
    )
    for (row, turnIndex) in rail.window.enumerated() {
        let isActive = rail.active == turnIndex
        _ = buffer.setString(
            x: rail.rect.x,
            y: rail.ticksY + row,
            text: isActive ? PagerGlyphs.timelineTickActive : PagerGlyphs.timelineTickIdle,
            style: [],
            foreground: isActive ? theme.textPrimary : theme.grayDim,
            background: theme.bgBase
        )
    }
}

// MARK: - Painting primitives

private func fill(
    _ buffer: inout CellBuffer,
    area: TerminalRect,
    background: TerminalColor,
    foreground: TerminalColor
) {
    guard area.width > 0, area.height > 0 else { return }
    let blank = Cell(
        grapheme: " ",
        foreground: foreground,
        background: background,
        displayWidth: 1
    )
    for y in area.y..<area.bottom {
        for x in area.x..<area.right {
            buffer.setCell(blank, x: x, y: y)
        }
    }
}

func paintBlank(
    _ buffer: inout CellBuffer,
    area: TerminalRect,
    foreground: TerminalColor,
    background: TerminalColor,
    style: CellStyle = []
) {
    guard area.width > 0, area.height > 0 else { return }
    let blank = Cell(
        grapheme: " ",
        style: style,
        foreground: foreground,
        background: background,
        displayWidth: 1
    )
    for y in area.y..<area.bottom {
        for x in area.x..<area.right {
            buffer.setCell(blank, x: x, y: y)
        }
    }
}

@discardableResult
func paintSpans(
    _ buffer: inout CellBuffer,
    spans: [PagerStyledSpan],
    x: Int,
    y: Int,
    limit: Int,
    background: TerminalColor,
    inheritForeground: TerminalColor? = nil,
    inheritStyle: CellStyle = []
) -> [LinkSpan] {
    var links: [LinkSpan] = []
    var column = x
    for span in spans {
        guard !span.text.isEmpty, column < limit else { break }
        // `setString` reports the number of columns it wrote, not an absolute
        // column, so the run cursor has to advance by that width.
        let written = buffer.setString(
            x: column,
            y: y,
            text: truncateToWidth(span.text, width: limit - column),
            style: inheritStyle.union(span.style),
            foreground: span.foreground ?? inheritForeground ?? .reset,
            background: span.background ?? background
        )
        let next = min(column + written, limit)
        if let url = span.url, written > 0 {
            links.append(LinkSpan(row: y, colStart: column, colEnd: next, url: url))
        }
        column = next
    }
    return links
}

/// Clip a span run to `width` display columns, dropping whole spans past the
/// budget and trimming the one that straddles it.
func truncateSpans(_ spans: [PagerStyledSpan], to width: Int) -> [PagerStyledSpan] {
    guard width > 0 else { return [] }
    var result: [PagerStyledSpan] = []
    var used = 0
    for span in spans {
        let spanWidth = UnicodeDisplayWidth.width(of: span.text)
        if used + spanWidth <= width {
            result.append(span)
            used += spanWidth
            continue
        }
        var trimmed = span
        trimmed.text = truncateToWidth(span.text, width: width - used)
        if !trimmed.text.isEmpty { result.append(trimmed) }
        break
    }
    return result
}

func truncateToWidth(_ text: String, width: Int) -> String {
    guard width > 0 else { return "" }
    guard UnicodeDisplayWidth.width(of: text) > width else { return text }
    var result = ""
    var used = 0
    for grapheme in text {
        let graphemeWidth = max(0, UnicodeDisplayWidth.width(ofGrapheme: String(grapheme)))
        if used + graphemeWidth > width { break }
        result.append(grapheme)
        used += graphemeWidth
    }
    return result
}

func wrapDisplayLines(_ text: String, width: Int) -> [String] {
    guard width > 0 else { return [] }
    let physicalLines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let physical = physicalLines.isEmpty ? [""] : physicalLines.map(String.init)
    var result: [String] = []
    for line in physical {
        if line.isEmpty {
            result.append("")
            continue
        }
        var current = ""
        var currentWidth = 0
        for grapheme in line {
            let string = String(grapheme)
            let graphemeWidth = max(0, UnicodeDisplayWidth.width(ofGrapheme: string))
            if graphemeWidth > 0 && !current.isEmpty && currentWidth + graphemeWidth > width {
                result.append(current)
                current = ""
                currentWidth = 0
            }
            current += string
            currentWidth += graphemeWidth
            if graphemeWidth > width {
                result.append(current)
                current = ""
                currentWidth = 0
            }
        }
        if !current.isEmpty || result.isEmpty { result.append(current) }
    }
    return result
}

private extension String {
    func padding(toDisplayWidth width: Int, ifShorter: Bool) -> String {
        guard ifShorter else { return self }
        var result = self
        var current = UnicodeDisplayWidth.width(of: result)
        while current < width {
            result += " "
            current += 1
        }
        return result
    }
}
