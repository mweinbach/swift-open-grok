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
    let chrome = makeChromeLayout(bounds: bounds, state: state)

    let baseContentWidth = max(0, chrome.conversation.width - PagerLayoutMetrics.chromeWidth)
    var contentLines = makeConversationLines(
        state.conversation,
        width: max(1, baseContentWidth),
        theme: state.theme
    )
    let hasScrollbar = state.showScrollbar && baseContentWidth > 1
        && contentLines.count > chrome.conversation.height
    if hasScrollbar {
        contentLines = makeConversationLines(
            state.conversation,
            width: max(1, baseContentWidth - 1),
            theme: state.theme
        )
    }

    let contentWidth = max(0, baseContentWidth - (hasScrollbar ? 1 : 0))
    let visibleHeight = chrome.conversation.height
    let maximumOffset = max(0, contentLines.count - visibleHeight)
    let scrollOffset: Int
    switch state.scrollPosition {
    case .followTail:
        scrollOffset = maximumOffset
    case .offset(let requested):
        scrollOffset = min(max(requested, 0), maximumOffset)
    }
    let visibleEnd = min(contentLines.count, scrollOffset + visibleHeight)
    let visibleRange = scrollOffset..<visibleEnd

    let layout = PagerFrameLayout(
        bounds: bounds,
        statusBar: chrome.statusBar,
        conversation: chrome.conversation,
        completions: chrome.completions,
        turnStatus: chrome.turnStatus,
        input: chrome.input,
        shortcuts: chrome.shortcuts,
        contentWidth: contentWidth,
        totalContentLines: contentLines.count,
        visibleContentLines: visibleRange,
        scrollOffset: scrollOffset,
        hasScrollbar: hasScrollbar
    )

    var buffer = CellBuffer(area: bounds)
    var links: [LinkSpan] = []
    fill(&buffer, area: bounds, background: state.theme.bgBase, foreground: state.theme.textPrimary)
    renderStatusBar(state.statusBar, in: chrome.statusBar, buffer: &buffer, theme: state.theme)
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
    renderCompletions(state.completions, in: chrome.completions, buffer: &buffer, theme: state.theme)
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
        theme: state.theme
    )

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

private func makeChromeLayout(bounds: TerminalRect, state: PagerRenderState) -> ChromeLayout {
    let empty = TerminalRect(x: bounds.x, y: bounds.y, width: bounds.width, height: 0)
    guard bounds.height > 0, bounds.width > 0 else {
        return ChromeLayout(
            statusBar: empty,
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
    // One blank row between the status bar and the transcript.
    let statusGap = statusHeight > 0 ? take(1) : 0

    let shortcutsHeight = state.shortcuts != nil ? take(1) : 0
    // The reference drops the bottom padding row on short terminals.
    let bottomGap = shortcutsHeight > 0 && bounds.height > PagerLayoutMetrics.shortTerminalRows
        ? take(1)
        : 0

    let composerHeight = take(pagerComposerHeight(state.input, width: bounds.width))
    let promptGap = composerHeight > 0 ? take(1) : 0

    let turnStatusHeight = state.turnStatus != nil ? take(1) : 0
    let turnStatusGap = turnStatusHeight > 0 ? take(1) : 0

    let completionsHeight = (state.completions?.isEmpty == false)
        ? take(state.completions!.visibleRowCount)
        : 0
    let completionsGap = completionsHeight > 0 ? take(1) : 0

    let conversationHeight = max(0, remaining)
    _ = (statusGap, bottomGap, promptGap, turnStatusGap, completionsGap)

    var y = bounds.y
    func place(_ height: Int, gapAfter: Int = 0) -> TerminalRect {
        let rect = TerminalRect(x: bounds.x, y: y, width: bounds.width, height: height)
        y += height + gapAfter
        return rect
    }

    let statusBar = place(statusHeight, gapAfter: statusGap)
    let conversation = place(conversationHeight, gapAfter: completionsGap)
    let completions = place(completionsHeight, gapAfter: turnStatusGap)
    let turnStatus = place(turnStatusHeight, gapAfter: promptGap)
    let input = place(composerHeight, gapAfter: bottomGap)
    let shortcuts = place(shortcutsHeight)

    return ChromeLayout(
        statusBar: statusBar,
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
    theme: PagerRenderTheme
) -> [PaintLine] {
    guard width > 0 else { return [] }
    var lines: [PaintLine] = []
    for (index, item) in items.enumerated() {
        switch item {
        case .message(let message):
            appendMessage(message, width: width, theme: theme, into: &lines)
        case .tool(let tool):
            appendToolCard(tool, width: width, theme: theme, into: &lines)
        case .separator(let text):
            let separator = text.isEmpty ? String(repeating: "─", count: width) : text
            lines.append(PaintLine(separator, foreground: theme.grayDim))
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
    return lines
}

private func appendMessage(
    _ message: PagerMessage,
    width: Int,
    theme: PagerRenderTheme,
    into lines: inout [PaintLine]
) {
    switch message.role {
    case .user:
        appendUserPrompt(message, width: width, theme: theme, into: &lines)
    case .assistant:
        appendAssistantMessage(message, width: width, theme: theme, into: &lines)
    case .reasoning:
        appendThinking(message, width: width, theme: theme, into: &lines)
    case .system:
        appendPlain(message, width: width, foreground: theme.accentSystem, theme: theme, into: &lines)
    case .error:
        appendPlain(message, width: width, foreground: theme.accentError, theme: theme, into: &lines)
    }
}

/// User prompts carry a `❯ ` prefix, a `bg_light` band behind every row, and
/// one padded blank row above and below (`blocks/user.rs`).
private func appendUserPrompt(
    _ message: PagerMessage,
    width: Int,
    theme: PagerRenderTheme,
    into lines: inout [PaintLine]
) {
    let band = theme.bgLight
    lines.append(PaintLine("", foreground: theme.textPrimary, background: band))
    let prefixWidth = PagerGlyphs.promptArrowWidth
    let bodyWidth = max(1, width - prefixWidth)
    let indentation = String(repeating: " ", count: prefixWidth)
    var isFirstRow = true
    for physical in message.text.split(separator: "\n", omittingEmptySubsequences: false) {
        let wrapped = wrapDisplayLines(String(physical), width: bodyWidth)
        for row in (wrapped.isEmpty ? [""] : wrapped) {
            var spans: [PagerStyledSpan] = []
            if isFirstRow {
                spans.append(PagerStyledSpan(
                    text: PagerGlyphs.promptArrow,
                    foreground: theme.accentUser
                ))
            } else {
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
            spans: [PagerStyledSpan(text: PagerGlyphs.promptArrow, foreground: theme.accentUser)],
            foreground: theme.textPrimary,
            background: band
        ))
    }
    lines.append(PaintLine("", foreground: theme.textPrimary, background: band))
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
    for styledLine in styledLines {
        for row in wrapStyledSpans(styledLine.spans, width: width) {
            lines.append(PaintLine(spans: row, foreground: theme.textPrimary))
        }
    }
}

/// `Thinking…` while streaming, collapsing to `Thought for 1.4s` when the turn
/// ends. Truncated mode shows a lone `…` and the last three lines
/// (`blocks/thinking.rs`).
private func appendThinking(
    _ message: PagerMessage,
    width: Int,
    theme: PagerRenderTheme,
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
    let budget = PagerLayoutMetrics.thinkingTruncatedLines
    if body.count > budget {
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

private func appendToolCard(
    _ tool: PagerToolCard,
    width: Int,
    theme: PagerRenderTheme,
    into lines: inout [PaintLine]
) {
    let accent = pagerToolAccent(tool, theme: theme)
    // A collapsed row renders entirely muted and drops the accent rail; the
    // bullet alone carries the status color.
    let muted = !tool.isExpanded
    let labelColor = muted ? theme.gray : theme.textPrimary
    let argumentColor = muted
        ? theme.gray
        : (tool.kind.argumentIsPath ? theme.path : theme.textPrimary)

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
            accentColor: accent
        ))
    }

    guard tool.isExpanded, let output = tool.output, !output.isEmpty else { return }
    lines.append(PaintLine(
        "",
        foreground: theme.gray,
        accentGlyph: PagerGlyphs.accentBar,
        accentColor: accent
    ))
    let previewColor = tool.state == .failed ? theme.accentError : theme.gray
    for row in toolPreviewRows(output, width: max(1, width - 2), theme: theme) {
        lines.append(PaintLine(
            spans: [PagerStyledSpan(text: "  " + row.text, foreground: row.foreground ?? previewColor)],
            foreground: previewColor,
            accentGlyph: PagerGlyphs.accentBar,
            accentColor: accent
        ))
    }
}

/// Head/tail preview with the reference's `… +{n} lines` marker
/// (`execute.rs:551-620`).
private func toolPreviewRows(
    _ output: String,
    width: Int,
    theme: PagerRenderTheme
) -> [PagerStyledSpan] {
    var wrapped: [String] = []
    for physical in output.split(separator: "\n", omittingEmptySubsequences: false) {
        wrapped.append(contentsOf: wrapDisplayLines(String(physical), width: width))
    }
    let head = PagerLayoutMetrics.executePreviewFirstLines
    let tail = PagerLayoutMetrics.executePreviewLastLines
    guard wrapped.count > head + tail + 1 else {
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

private func renderStatusBar(
    _ status: PagerStatusBar?,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) {
    guard let status, area.height > 0, area.width > 0 else { return }
    paintBlank(&buffer, area: area, foreground: theme.gray, background: theme.bgBase)

    let right = statusBarRightSpans(status, theme: theme)
    let rightWidth = right.reduce(0) { $0 + UnicodeDisplayWidth.width(of: $1.text) }
    let leftBudget = max(0, area.width - rightWidth - 1)
    let left = truncateSpans(statusBarLeftSpans(status, theme: theme), to: leftBudget)

    paintSpans(&buffer, spans: left, x: area.x, y: area.y, limit: area.right, background: theme.bgBase)
    if rightWidth > 0, rightWidth <= area.width {
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

private func statusBarRightSpans(
    _ status: PagerStatusBar,
    theme: PagerRenderTheme
) -> [PagerStyledSpan] {
    var groups: [[PagerStyledSpan]] = []
    if status.backgroundTaskCount > 0 {
        groups.append([PagerStyledSpan(
            text: "\(PagerGlyphs.dotSpinner[0]) \(status.backgroundTaskCount)",
            foreground: theme.accentRunning
        )])
    }
    if status.isPlanMode {
        groups.append([PagerStyledSpan(text: "plan", foreground: theme.accentPlan)])
    }
    if let context = contextIndicatorSpan(status, theme: theme) {
        groups.append([context])
    }
    if status.queuedPromptCount > 0 {
        groups.append([PagerStyledSpan(
            text: "+\(status.queuedPromptCount)",
            foreground: theme.accentUser
        )])
    }
    guard !groups.isEmpty else { return [] }
    var spans: [PagerStyledSpan] = []
    for (index, group) in groups.enumerated() {
        if index > 0 {
            spans.append(PagerStyledSpan(
                text: " \(PagerGlyphs.statusSeparator) ",
                foreground: theme.grayDim
            ))
        }
        spans.append(contentsOf: group)
    }
    return spans
}

/// `"8.5K / 1.0M"`, right-padded to at least six columns, colored by the
/// context ramp (`views/context_bar.rs`).
private func contextIndicatorSpan(
    _ status: PagerStatusBar,
    theme: PagerRenderTheme
) -> PagerStyledSpan? {
    guard let used = status.contextUsedTokens,
          let total = status.contextTotalTokens,
          total > 0
    else { return nil }
    var text = "\(pagerFormatTokens(used)) / \(pagerFormatTokens(total))"
    while UnicodeDisplayWidth.width(of: text) < 6 { text += " " }
    let fraction = min(1.0, Double(used) / Double(total))
    return PagerStyledSpan(text: text, foreground: pagerContextColor(fraction: fraction, theme: theme))
}

// MARK: - Turn status

private func renderTurnStatus(
    _ status: PagerTurnStatus?,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) {
    guard let status, area.height > 0, area.width > 0 else { return }
    paintBlank(&buffer, area: area, foreground: theme.gray, background: theme.bgBase)

    let labelColor = status.isCancelling ? theme.accentError : theme.textSecondary
    var left: [PagerStyledSpan] = [
        PagerStyledSpan(
            text: PagerGlyphs.brailleSpinnerFrame(status.tick) + " ",
            foreground: labelColor
        ),
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

private func renderCompletions(
    _ menu: PagerCompletionMenu?,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) {
    guard let menu, !menu.isEmpty, area.height > 0, area.width > 0 else { return }
    let start = min(max(0, menu.scrollOffset), max(0, menu.rows.count - 1))
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

private func renderComposer(
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
    if let model = input.modelName, !model.isEmpty {
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
            background: background
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
