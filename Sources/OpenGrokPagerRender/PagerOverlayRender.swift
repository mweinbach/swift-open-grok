import Foundation
import OpenGrokTerminalCore

// MARK: - Hit-test bounds

/// Where an overlay landed on screen, published on the render result the same
/// way `links` is so a mouse router can hit-test overlays without re-deriving
/// the layout.
///
/// The reference keeps render, hit-test and height on one shared derivation
/// (`ListOverlay`, `overlay_list.rs:20-24`) precisely so they cannot drift;
/// these bounds are produced *by* the painter for the same reason.
public struct PagerOverlayBounds: Sendable, Equatable, Hashable {
    public struct Row: Sendable, Equatable, Hashable {
        public var id: String
        public var frame: TerminalRect

        public init(id: String, frame: TerminalRect) {
            self.id = id
            self.frame = frame
        }
    }

    public struct Hint: Sendable, Equatable, Hashable {
        public var key: String
        public var label: String
        public var frame: TerminalRect

        public init(key: String, label: String, frame: TerminalRect) {
            self.key = key
            self.label = label
            self.frame = frame
        }
    }

    public var id: String
    /// The whole overlay including its border.
    public var frame: TerminalRect
    /// The body region, inside border, padding, and above the footer.
    public var content: TerminalRect
    public var footer: TerminalRect
    /// The `[✗]` cells, when the presentation draws one.
    public var closeButton: TerminalRect?
    /// One entry per painted row, in paint order.
    public var rows: [Row]
    public var hints: [Hint]

    public init(
        id: String,
        frame: TerminalRect,
        content: TerminalRect,
        footer: TerminalRect,
        closeButton: TerminalRect? = nil,
        rows: [Row] = [],
        hints: [Hint] = []
    ) {
        self.id = id
        self.frame = frame
        self.content = content
        self.footer = footer
        self.closeButton = closeButton
        self.rows = rows
        self.hints = hints
    }

    /// The row under a screen position, or `nil` off the rows.
    public func row(atX x: Int, y: Int) -> Row? {
        rows.first { $0.frame.contains(x: x, y: y) }
    }

    public func hitTest(x: Int, y: Int) -> Bool {
        frame.contains(x: x, y: y)
    }
}

// MARK: - Entry point

/// Paint the overlay stack over an already-painted frame.
///
/// Overlays paint bottom-of-stack first, so the topmost — the one holding input
/// focus — is the one fully visible.
func renderOverlays(
    _ stack: PagerOverlayStack,
    layout: PagerFrameLayout,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme,
    motion: PagerMotionSnapshot = PagerMotionSnapshot()
) -> [PagerOverlayBounds] {
    guard !stack.isEmpty else { return [] }
    var bounds: [PagerOverlayBounds] = []
    for overlay in stack.overlays {
        switch overlay.presentation {
        case .centeredModal(let sizing):
            if let result = renderCenteredModal(
                overlay,
                sizing: sizing,
                area: layout.bounds,
                buffer: &buffer,
                theme: theme,
                motion: motion
            ) {
                bounds.append(result)
            }
            // A too-small popup is not drawn and publishes no bounds, so a
            // router cannot act on a previous frame's geometry.
        case .bottomSheet:
            if let result = renderBottomSheet(
                overlay,
                layout: layout,
                buffer: &buffer,
                theme: theme,
                motion: motion
            ) {
                bounds.append(result)
            }
        case .fullScreen:
            if let result = renderFullScreenOverlay(
                overlay,
                layout: layout,
                buffer: &buffer,
                theme: theme,
                motion: motion
            ) {
                bounds.append(result)
            }
        }
    }
    return bounds
}

// MARK: - Centered modal

private func renderCenteredModal(
    _ overlay: PagerOverlay,
    sizing: PagerModalSizing,
    area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme,
    motion: PagerMotionSnapshot = PagerMotionSnapshot()
) -> PagerOverlayBounds? {
    guard let frame = sizing.frame(in: area) else { return nil }

    // The settings modal's title and footer follow its mode, so they are
    // derived here rather than read off the stored overlay — a chooser opened
    // three keystrokes ago must not still be titled "Settings".
    var title = overlay.title
    var hints = overlay.hints
    if case .settings(let settings) = overlay.content {
        title = pagerSettingsTitle(settings)
        hints = pagerSettingsHints(settings)
    }
    // The extensions modal's footer follows its search mode; the title stays
    // empty because the tab bar identifies the contents.
    if case .extensions(let extensions) = overlay.content {
        hints = pagerExtensionsHints(extensions)
    }
    // The agents modal's footer follows its search mode too.
    if case .agents(let agents) = overlay.content {
        hints = pagerAgentsHints(agents)
    }

    // Clear under the popup so the transcript does not bleed through. The
    // reference applies no backdrop dimming (`modal_window.rs:328`).
    paintBlank(
        &buffer,
        area: frame,
        foreground: theme.textPrimary,
        background: theme.bgBase
    )
    drawModalBorder(&buffer, frame: frame, title: title, theme: theme)
    let closeButton = drawCloseButton(&buffer, frame: frame, theme: theme)

    let inner = TerminalRect(
        x: frame.x + 1,
        y: frame.y + 1,
        width: max(0, frame.width - 2),
        height: max(0, frame.height - 2)
    )
    let footerWidth = max(0, inner.width - sizing.horizontalPadding * 2)
    let footerLines = max(
        sizing.footerLines,
        modalFooterRowCount(hints, width: footerWidth)
    )
    let reserved = sizing.verticalPadding + footerLines
    let content = TerminalRect(
        x: inner.x + sizing.horizontalPadding,
        y: inner.y + sizing.verticalPadding,
        width: footerWidth,
        height: max(0, inner.height - reserved)
    )
    let footerHeight = min(footerLines, inner.height)
    let footer = TerminalRect(
        x: inner.x + sizing.horizontalPadding,
        y: inner.y + max(0, inner.height - footerHeight),
        width: footerWidth,
        height: footerHeight
    )

    var rows: [PagerOverlayBounds.Row] = []
    switch overlay.content {
    case .list(let list):
        rows = drawListBody(list, in: content, buffer: &buffer, theme: theme)
    case .text(let text):
        drawTextBody(text, in: content, buffer: &buffer, theme: theme)
    case .permission(let prompt):
        rows = drawPermissionBody(
            prompt,
            in: content,
            background: theme.bgBase,
            buffer: &buffer,
            theme: theme
        )
    case .question(let prompt):
        drawQuestionBody(
            prompt,
            in: content,
            background: theme.bgBase,
            buffer: &buffer,
            theme: theme
        )
    case .planApproval(let prompt):
        drawPlanApprovalBody(
            prompt,
            in: content,
            background: theme.bgBase,
            buffer: &buffer,
            theme: theme
        )
    case .welcome(let welcome):
        rows = drawWelcomeBody(welcome, in: content, buffer: &buffer, theme: theme, motion: motion)
    case .workflows(let runs):
        rows = drawWorkflowsBody(
            runs,
            in: content,
            background: theme.bgBase,
            buffer: &buffer,
            theme: theme
        )
    case .settings(let settings):
        rows = drawSettingsBody(settings, in: content, buffer: &buffer, theme: theme)
    case .extensions(let extensions):
        rows = drawExtensionsBody(extensions, in: content, buffer: &buffer, theme: theme)
    case .agents(let agents):
        rows = drawAgentsBody(agents, in: content, buffer: &buffer, theme: theme)
    }

    let hintBounds = drawModalFooter(hints, in: footer, buffer: &buffer, theme: theme)

    return PagerOverlayBounds(
        id: overlay.id,
        frame: frame,
        content: content,
        footer: footer,
        closeButton: closeButton,
        rows: rows,
        hints: hintBounds
    )
}

/// Square border with the title inlined as `─ Title ─`. An empty title leaves
/// the top border a continuous line (`modal_window.rs:337-384`).
private func drawModalBorder(
    _ buffer: inout CellBuffer,
    frame: TerminalRect,
    title: String,
    theme: PagerRenderTheme
) {
    guard frame.width >= 2, frame.height >= 2 else { return }
    let border = theme.grayDim
    func put(_ glyph: String, _ x: Int, _ y: Int, _ color: TerminalColor, _ style: CellStyle = []) {
        buffer.setCell(
            Cell(
                grapheme: glyph,
                style: style,
                foreground: color,
                background: theme.bgBase,
                displayWidth: 1
            ),
            x: x,
            y: y
        )
    }

    for x in frame.x..<frame.right {
        put(String(PagerGlyphs.borderHorizontal), x, frame.y, border)
        put(String(PagerGlyphs.borderHorizontal), x, frame.bottom - 1, border)
    }
    for y in frame.y..<frame.bottom {
        put(String(PagerGlyphs.borderVertical), frame.x, y, border)
        put(String(PagerGlyphs.borderVertical), frame.right - 1, y, border)
    }
    put(String(PagerGlyphs.modalTopLeft), frame.x, frame.y, border)
    put(String(PagerGlyphs.modalTopRight), frame.right - 1, frame.y, border)
    put(String(PagerGlyphs.modalBottomLeft), frame.x, frame.bottom - 1, border)
    put(String(PagerGlyphs.modalBottomRight), frame.right - 1, frame.bottom - 1, border)

    guard !title.isEmpty else { return }
    let spans = [
        PagerStyledSpan(text: "\(PagerGlyphs.borderHorizontal) ", foreground: border),
        PagerStyledSpan(text: title, foreground: theme.textPrimary, style: [.bold]),
        PagerStyledSpan(text: " \(PagerGlyphs.borderHorizontal)", foreground: border)
    ]
    // Stop short of the close button's five cells plus its two-column inset.
    let limit = max(frame.x + 1, frame.right - 8)
    paintSpans(
        &buffer,
        spans: spans,
        x: frame.x + 1,
        y: frame.y,
        limit: limit,
        background: theme.bgBase
    )
}

/// `[✗]` on the top-right border, five cells ending two columns from the edge
/// (`modal_window.rs:460-500`).
private func drawCloseButton(
    _ buffer: inout CellBuffer,
    frame: TerminalRect,
    theme: PagerRenderTheme
) -> TerminalRect? {
    let cells = [" ", "[", PagerGlyphs.ballotX, "]", " "]
    let x = frame.right - (cells.count + 2)
    guard x > frame.x else { return nil }
    for (offset, glyph) in cells.enumerated() {
        buffer.setCell(
            Cell(
                grapheme: glyph,
                foreground: glyph == " " ? theme.grayDim : theme.gray,
                background: theme.bgBase,
                displayWidth: 1
            ),
            x: x + offset,
            y: frame.y
        )
    }
    return TerminalRect(x: x, y: frame.y, width: cells.count, height: 1)
}

/// `"  |  "` — the ASCII pipe the *modal* footer uses, which is deliberately not
/// the `"  │  "` U+2502 of the bottom shortcuts bar (`modal_window.rs:764`).
private let modalHintSeparator = "  |  "

private func modalFooterRows(_ hints: [PagerOverlayHint], width: Int) -> [[PagerOverlayHint]] {
    guard width > 0, !hints.isEmpty else { return [] }
    let separatorWidth = UnicodeDisplayWidth.width(of: modalHintSeparator)
    var rows: [[PagerOverlayHint]] = [[]]
    var used = 0
    for hint in hints {
        let hintWidth = UnicodeDisplayWidth.width(of: hint.display)
        let needed = rows[rows.count - 1].isEmpty ? hintWidth : used + separatorWidth + hintWidth
        if needed > width, !rows[rows.count - 1].isEmpty {
            rows.append([hint])
            used = hintWidth
        } else {
            rows[rows.count - 1].append(hint)
            used = needed
        }
    }
    return rows
}

private func modalFooterRowCount(_ hints: [PagerOverlayHint], width: Int) -> Int {
    modalFooterRows(hints, width: width).count
}

/// Rows are centered and bottom-aligned, so a single row sits on the last line
/// (`modal_window.rs:812-816`).
private func drawModalFooter(
    _ hints: [PagerOverlayHint],
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) -> [PagerOverlayBounds.Hint] {
    guard area.width > 0, area.height > 0, !hints.isEmpty else { return [] }
    var rows = modalFooterRows(hints, width: area.width)
    if rows.count > area.height {
        rows = Array(rows.prefix(area.height))
    }
    let separatorWidth = UnicodeDisplayWidth.width(of: modalHintSeparator)
    var bounds: [PagerOverlayBounds.Hint] = []

    for (rowIndex, row) in rows.enumerated() {
        let y = area.bottom - rows.count + rowIndex
        let total = row.reduce(0) { $0 + UnicodeDisplayWidth.width(of: $1.display) }
            + separatorWidth * max(0, row.count - 1)
        var x = total > area.width ? area.x : area.x + (area.width - total) / 2

        for (index, hint) in row.enumerated() {
            let start = x
            var written = buffer.setString(
                x: x,
                y: y,
                text: hint.key,
                style: [.bold],
                foreground: theme.textSecondary,
                background: theme.bgBase
            )
            x += written
            if !hint.label.isEmpty {
                written = buffer.setString(
                    x: x,
                    y: y,
                    text: " \(hint.label)",
                    style: [],
                    foreground: theme.gray,
                    background: theme.bgBase
                )
                x += written
            }
            bounds.append(PagerOverlayBounds.Hint(
                key: hint.key,
                label: hint.label,
                frame: TerminalRect(x: start, y: y, width: max(0, x - start), height: 1)
            ))
            if index + 1 < row.count {
                x += buffer.setString(
                    x: x,
                    y: y,
                    text: modalHintSeparator,
                    style: [],
                    foreground: theme.grayDim,
                    background: theme.bgBase
                )
            }
        }
    }
    return bounds
}

// MARK: - List body

/// Filter row, divider, then rows — the reference's picker-in-modal layout
/// (`picker.rs:1938-1990`).
private func drawListBody(
    _ list: PagerListOverlay,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) -> [PagerOverlayBounds.Row] {
    guard area.width > 0, area.height > 0 else { return [] }
    var y = area.y

    if list.isFilterable, y < area.bottom {
        var spans: [PagerStyledSpan] = [
            PagerStyledSpan(text: " search: ", foreground: theme.gray)
        ]
        if list.filterQuery.isEmpty {
            spans.append(PagerStyledSpan(text: "/ to search", foreground: theme.grayDim))
        } else {
            spans.append(PagerStyledSpan(text: list.filterQuery, foreground: theme.textPrimary))
        }
        paintSpans(
            &buffer,
            spans: truncateSpans(spans, to: area.width),
            x: area.x,
            y: y,
            limit: area.right,
            background: theme.bgBase
        )
        y += 1
        if y < area.bottom {
            _ = buffer.setString(
                x: area.x,
                y: y,
                text: String(repeating: String(PagerGlyphs.borderHorizontal), count: area.width),
                style: [],
                foreground: theme.grayDim,
                background: theme.bgBase
            )
            y += 1
        }
    }

    let visible = list.filteredRows
    let capacity = max(0, area.bottom - y)
    guard capacity > 0 else { return [] }

    guard !visible.isEmpty else {
        _ = buffer.setString(
            x: area.x,
            y: y,
            text: truncateToWidth("  \(list.emptyMessage)", width: area.width),
            style: [],
            foreground: theme.grayDim,
            background: theme.bgBase
        )
        return []
    }

    // Bottom-anchored window that keeps the cursor in frame, the rule
    // `ListOverlay::scroll_offset` uses (`overlay_list.rs:52-58`).
    let offset = list.selectedIndex >= capacity ? list.selectedIndex - capacity + 1 : 0
    var bounds: [PagerOverlayBounds.Row] = []

    for index in offset..<min(visible.count, offset + capacity) {
        let row = visible[index]
        let rowY = y + (index - offset)
        let isSelected = index == list.selectedIndex && row.isSelectable
        let rowFrame = TerminalRect(x: area.x, y: rowY, width: area.width, height: 1)

        if row.isHeader {
            var spans = [
                PagerStyledSpan(text: " \(row.label) ", foreground: theme.gray, style: [.bold])
            ]
            let used = UnicodeDisplayWidth.width(of: spans[0].text)
            if used < area.width {
                spans.append(PagerStyledSpan(
                    text: String(
                        repeating: String(PagerGlyphs.borderHorizontal),
                        count: area.width - used
                    ),
                    foreground: theme.grayDim
                ))
            }
            paintSpans(
                &buffer,
                spans: spans,
                x: area.x,
                y: rowY,
                limit: area.right,
                background: theme.bgBase
            )
            bounds.append(PagerOverlayBounds.Row(id: row.id, frame: rowFrame))
            continue
        }

        let background = isSelected ? theme.bgVisual : theme.bgBase
        if isSelected {
            paintBlank(&buffer, area: rowFrame, foreground: theme.textPrimary, background: background)
        }

        let detail = row.detail ?? ""
        let detailWidth = detail.isEmpty ? 0 : UnicodeDisplayWidth.width(of: detail) + 3
        let labelBudget = max(0, area.width - detailWidth)
        let spans: [PagerStyledSpan] = [
            PagerStyledSpan(
                text: isSelected ? PagerGlyphs.promptArrow : "  ",
                foreground: theme.accentUser,
                style: isSelected ? [.bold] : []
            ),
            PagerStyledSpan(
                text: row.label,
                foreground: row.isSelectable ? theme.textPrimary : theme.grayDim,
                style: isSelected ? [.bold] : []
            )
        ]
        paintSpans(
            &buffer,
            spans: truncateSpans(spans, to: labelBudget),
            x: area.x,
            y: rowY,
            limit: area.x + labelBudget,
            background: background
        )
        if !detail.isEmpty {
            let width = UnicodeDisplayWidth.width(of: detail)
            _ = buffer.setString(
                x: area.right - width - 1,
                y: rowY,
                text: detail,
                style: [],
                foreground: theme.gray,
                background: background
            )
        }
        bounds.append(PagerOverlayBounds.Row(id: row.id, frame: rowFrame))
    }
    return bounds
}

// MARK: - Text body

private func drawTextBody(
    _ text: PagerTextOverlay,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) {
    guard area.width > 0, area.height > 0 else { return }
    let start = min(max(0, text.scrollOffset), max(0, text.lines.count))
    for row in 0..<area.height {
        let index = start + row
        guard text.lines.indices.contains(index) else { break }
        paintSpans(
            &buffer,
            spans: truncateSpans(text.lines[index].spans, to: area.width),
            x: area.x,
            y: area.y + row,
            limit: area.right,
            background: theme.bgBase,
            inheritForeground: theme.textPrimary
        )
    }
}

// MARK: - Bottom sheet

/// Height of a bottom-sheet overlay: half the screen with a ten-row floor,
/// capped at 80% (`permission_view.rs:393-407`).
func pagerBottomSheetHeight(
    _ overlay: PagerOverlay,
    screenHeight: Int
) -> Int {
    let contentRows: Int
    switch overlay.content {
    case .permission(let prompt):
        let diffRows = min(prompt.request.diffPreview.count, PagerPermissionPrompt.collapsedDiffRows)
            + (prompt.request.diffPreview.count > PagerPermissionPrompt.collapsedDiffRows ? 1 : 0)
        // pad + title + optional detail + diff + gap + options + pad
        contentRows = 2 + 1 + (prompt.request.detail == nil ? 0 : 1)
            + diffRows + 1 + prompt.request.options.count
    case .question(let prompt):
        // pad + header + question + gap + option rows (incl. Other) + pad
        contentRows = 2 + 1 + 1 + 1 + prompt.rowCount
    case .planApproval(let prompt):
        // pad + title + status + gap + plan body (capped; the sheet's own
        // 80% ceiling is the real bound) + feedback row
        contentRows = 2 + 1 + 1 + 1 + min(prompt.bodyLines.count, 15) + 1
    case .list(let list):
        contentRows = 2 + min(list.filteredRows.count, 15) + 1
    case .text(let text):
        contentRows = 2 + text.lines.count
    case .welcome:
        contentRows = screenHeight
    case .workflows(let runs):
        contentRows = 2 + (runs.isDetailOpen ? runs.detailLines.count : max(1, runs.rows.count))
    case .settings:
        // The settings modal is only ever presented as a centered modal; if a
        // caller sheets it anyway, give it the full 80% rather than a stub.
        contentRows = screenHeight
    case .extensions:
        // Same shape as settings: centered-modal only, full budget if sheeted.
        contentRows = screenHeight
    case .agents:
        // Same shape as settings: centered-modal only, full budget if sheeted.
        contentRows = screenHeight
    }
    let ceiling = max(1, screenHeight * 80 / 100)
    let preferred = max(screenHeight / 2, 10)
    return min(max(contentRows, 1), min(preferred, ceiling), screenHeight)
}

/// `bg_light` fill, a `┃` rail on every row, `content_x = x + 3`,
/// `content_width = width - 5` (spec §16.3 / §16.7).
private func renderBottomSheet(
    _ overlay: PagerOverlay,
    layout: PagerFrameLayout,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme,
    motion: PagerMotionSnapshot = PagerMotionSnapshot()
) -> PagerOverlayBounds? {
    let area = layout.bounds
    guard area.width >= 10, area.height > 0 else { return nil }
    let height = pagerBottomSheetHeight(overlay, screenHeight: area.height)
    guard height > 0 else { return nil }

    // Anchored to the composer's bottom edge — the sheet stands where the
    // prompt would be.
    let bottom = layout.input.height > 0 ? layout.input.bottom : area.bottom
    let top = max(area.y, bottom - height)
    let frame = TerminalRect(x: area.x, y: top, width: area.width, height: bottom - top)
    guard frame.height > 0 else { return nil }

    paintBlank(&buffer, area: frame, foreground: theme.textPrimary, background: theme.bgLight)
    for y in frame.y..<frame.bottom {
        buffer.setCell(
            Cell(
                grapheme: PagerGlyphs.accentBar,
                foreground: theme.accentUser,
                background: theme.bgLight,
                displayWidth: 1
            ),
            x: frame.x,
            y: y
        )
    }

    let content = TerminalRect(
        x: frame.x + 3,
        y: frame.y + 1,
        width: max(0, frame.width - 5),
        height: max(0, frame.height - 2)
    )
    var rows: [PagerOverlayBounds.Row] = []
    switch overlay.content {
    case .permission(let prompt):
        rows = drawPermissionBody(
            prompt,
            in: content,
            background: theme.bgLight,
            buffer: &buffer,
            theme: theme
        )
    case .question(let prompt):
        drawQuestionBody(
            prompt,
            in: content,
            background: theme.bgLight,
            buffer: &buffer,
            theme: theme
        )
    case .planApproval(let prompt):
        drawPlanApprovalBody(
            prompt,
            in: content,
            background: theme.bgLight,
            buffer: &buffer,
            theme: theme
        )
    case .list(let list):
        if !overlay.title.isEmpty, content.height > 0 {
            _ = buffer.setString(
                x: content.x,
                y: content.y,
                text: truncateToWidth(overlay.title, width: content.width),
                style: [.bold],
                foreground: theme.accentUser,
                background: theme.bgLight
            )
        }
        let body = TerminalRect(
            x: content.x,
            y: content.y + 1,
            width: content.width,
            height: max(0, content.height - 1)
        )
        rows = drawSheetList(list, in: body, buffer: &buffer, theme: theme)
    case .text(let text):
        drawTextBody(text, in: content, buffer: &buffer, theme: theme)
    case .welcome(let welcome):
        rows = drawWelcomeBody(welcome, in: content, buffer: &buffer, theme: theme, motion: motion)
    case .workflows(let runs):
        rows = drawWorkflowsBody(
            runs,
            in: content,
            background: theme.bgLight,
            buffer: &buffer,
            theme: theme
        )
    case .settings(let settings):
        rows = drawSettingsBody(settings, in: content, buffer: &buffer, theme: theme)
    case .extensions(let extensions):
        rows = drawExtensionsBody(extensions, in: content, buffer: &buffer, theme: theme)
    case .agents(let agents):
        rows = drawAgentsBody(agents, in: content, buffer: &buffer, theme: theme)
    }

    return PagerOverlayBounds(
        id: overlay.id,
        frame: frame,
        content: content,
        footer: TerminalRect(x: frame.x, y: frame.bottom - 1, width: frame.width, height: 0),
        closeButton: nil,
        rows: rows
    )
}

/// A sheet list has no border to inset against, so the selected band spans
/// `content_x - 1` for `content_w + 2` (`overlay_list.rs:140-146`).
private func drawSheetList(
    _ list: PagerListOverlay,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) -> [PagerOverlayBounds.Row] {
    guard area.width > 0, area.height > 0 else { return [] }
    let visible = list.filteredRows
    guard !visible.isEmpty else {
        _ = buffer.setString(
            x: area.x,
            y: area.y,
            text: truncateToWidth("  \(list.emptyMessage)", width: area.width),
            style: [],
            foreground: theme.grayDim,
            background: theme.bgLight
        )
        return []
    }
    let capacity = area.height
    let offset = list.selectedIndex >= capacity ? list.selectedIndex - capacity + 1 : 0
    var bounds: [PagerOverlayBounds.Row] = []

    for index in offset..<min(visible.count, offset + capacity) {
        let row = visible[index]
        let y = area.y + (index - offset)
        let isSelected = index == list.selectedIndex && row.isSelectable
        let band = TerminalRect(
            x: max(0, area.x - 1),
            y: y,
            width: area.width + 2,
            height: 1
        )
        let background = isSelected ? theme.bgVisual : theme.bgLight
        if isSelected {
            paintBlank(&buffer, area: band, foreground: theme.textPrimary, background: background)
        }
        paintSpans(
            &buffer,
            spans: truncateSpans([
                PagerStyledSpan(
                    text: isSelected ? PagerGlyphs.promptArrow : "  ",
                    foreground: theme.accentUser,
                    style: isSelected ? [.bold] : []
                ),
                PagerStyledSpan(
                    text: row.label,
                    foreground: row.isSelectable ? theme.textPrimary : theme.grayDim,
                    style: isSelected ? [.bold] : []
                )
            ], to: area.width),
            x: area.x,
            y: y,
            limit: area.right,
            background: background
        )
        bounds.append(PagerOverlayBounds.Row(id: row.id, frame: band))
    }
    return bounds
}

// MARK: - Permission body

/// Title, detail, diff preview, then numbered radio option rows
/// `{digit} (●) Label` (`permission_view.rs:1895-1953`).
private func drawPermissionBody(
    _ prompt: PagerPermissionPrompt,
    in area: TerminalRect,
    background: TerminalColor,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) -> [PagerOverlayBounds.Row] {
    guard area.width > 0, area.height > 0 else { return [] }
    let request = prompt.request
    var y = area.y

    func writeSpans(_ spans: [PagerStyledSpan]) {
        guard y < area.bottom else { return }
        paintSpans(
            &buffer,
            spans: truncateSpans(spans, to: area.width),
            x: area.x,
            y: y,
            limit: area.right,
            background: background,
            inheritForeground: theme.textPrimary
        )
        y += 1
    }

    // Title: the verb and the target path, the path in `theme.path`.
    if let path = request.targetPath, !path.isEmpty {
        writeSpans([
            PagerStyledSpan(text: "Allow \(request.toolName) to ", foreground: theme.textPrimary, style: [.bold]),
            PagerStyledSpan(text: path, foreground: theme.path, style: [.bold]),
            PagerStyledSpan(text: "?", foreground: theme.textPrimary, style: [.bold])
        ])
    } else {
        writeSpans([
            PagerStyledSpan(
                text: "Allow \(request.toolName)?",
                foreground: theme.textPrimary,
                style: [.bold]
            )
        ])
    }

    if let detail = request.detail, !detail.isEmpty {
        writeSpans([PagerStyledSpan(text: detail, foreground: theme.command)])
    }

    // Diff preview. The reference has none in this view — the diff lives in the
    // transcript's edit block — so this follows the transcript's `+`/`-`
    // grammar rather than inventing new chrome.
    if !request.diffPreview.isEmpty {
        let budget = PagerPermissionPrompt.collapsedDiffRows
        let shown = min(request.diffPreview.count, budget)
        for line in request.diffPreview.prefix(shown) {
            let marker: String
            let color: TerminalColor
            switch line.kind {
            case .added:
                marker = "+"
                color = theme.accentSuccess
            case .removed:
                marker = "-"
                color = theme.accentError
            case .context:
                marker = " "
                color = theme.gray
            }
            writeSpans([PagerStyledSpan(text: "\(marker) \(line.text)", foreground: color)])
        }
        let hidden = request.diffPreview.count - shown
        if hidden > 0 {
            writeSpans([PagerStyledSpan(
                text: "\(PagerGlyphs.ellipsis) +\(hidden) lines",
                foreground: theme.gray
            )])
        }
    }

    // One blank gap row before the options (`permission_view.rs:718`).
    y += 1

    var rows: [PagerOverlayBounds.Row] = []
    for (index, option) in request.options.enumerated() {
        guard y < area.bottom else { break }
        let isCursor = index == prompt.selectedIndex
        let rowBackground = isCursor ? theme.bgVisual : background
        let frame = TerminalRect(x: max(0, area.x - 1), y: y, width: area.width + 2, height: 1)
        if isCursor {
            paintBlank(&buffer, area: frame, foreground: theme.textPrimary, background: rowBackground)
        }
        let digit = index < 9 ? String(index + 1) : " "
        paintSpans(
            &buffer,
            spans: truncateSpans([
                PagerStyledSpan(text: "\(digit) ", foreground: theme.accentUser),
                PagerStyledSpan(
                    text: isCursor ? "(\(PagerGlyphs.filledDot)) " : "(\(PagerGlyphs.emptyDot)) ",
                    foreground: isCursor ? theme.textPrimary : theme.gray,
                    style: isCursor ? [.bold] : []
                ),
                PagerStyledSpan(
                    text: option.label,
                    foreground: theme.textPrimary,
                    style: isCursor ? [.bold] : []
                )
            ], to: area.width),
            x: area.x,
            y: y,
            limit: area.right,
            background: rowBackground
        )
        rows.append(PagerOverlayBounds.Row(id: option.decision.rawValue, frame: frame))
        y += 1
    }
    return rows
}

// MARK: - Question body

/// `"Question i of n"`, the question text, then the option rows and the
/// trailing Other row.
///
/// Row grammar follows the permission sheet's cursor band; the selection
/// marker distinguishes single-select `(●)` from multi-select `[x]`, the
/// same radio/checkbox split upstream's question view draws
/// (`question_view.rs`, `build_flat_option_lines`).
///
/// Publishes no hit-test rows: mouse interaction with the question sheet is
/// deferred (recorded divergence — upstream supports click-to-select). The
/// generic mouse router treats an unknown overlay row id as "dismiss and
/// select", which would tear the sheet down without resolving the
/// coordinator, so no rows is the fail-safe shape until a real mouse path
/// exists.
private func drawQuestionBody(
    _ prompt: PagerQuestionPrompt,
    in area: TerminalRect,
    background: TerminalColor,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) {
    guard area.width > 0, area.height > 0, let question = prompt.currentQuestion else { return }
    var y = area.y

    func writeSpans(_ spans: [PagerStyledSpan], rowBackground: TerminalColor? = nil) {
        guard y < area.bottom else { return }
        paintSpans(
            &buffer,
            spans: truncateSpans(spans, to: area.width),
            x: area.x,
            y: y,
            limit: area.right,
            background: rowBackground ?? background,
            inheritForeground: theme.textPrimary
        )
        y += 1
    }

    writeSpans([
        PagerStyledSpan(text: prompt.title, foreground: theme.accentUser, style: [.bold])
    ])
    writeSpans([
        PagerStyledSpan(text: question.text, foreground: theme.textPrimary, style: [.bold])
    ])
    y += 1

    for (index, option) in question.options.enumerated() {
        guard y < area.bottom else { return }
        let isCursor = prompt.focus == .navigation && index == prompt.cursor
        let isSelected = prompt.selectedOptionIndices.contains(index)
        let rowBackground = isCursor ? theme.bgVisual : background
        if isCursor {
            paintBlank(
                &buffer,
                area: TerminalRect(x: max(0, area.x - 1), y: y, width: area.width + 2, height: 1),
                foreground: theme.textPrimary,
                background: rowBackground
            )
        }
        let marker: String
        if question.isMultiSelect {
            marker = isSelected ? "[x] " : "[ ] "
        } else {
            marker = isSelected ? "(\(PagerGlyphs.filledDot)) " : "(\(PagerGlyphs.emptyDot)) "
        }
        var spans: [PagerStyledSpan] = [
            PagerStyledSpan(
                text: isCursor ? PagerGlyphs.promptArrow : "  ",
                foreground: theme.accentUser,
                style: isCursor ? [.bold] : []
            ),
            PagerStyledSpan(
                text: marker,
                foreground: isSelected || isCursor ? theme.textPrimary : theme.gray,
                style: isCursor ? [.bold] : []
            ),
            PagerStyledSpan(
                text: option.label,
                foreground: theme.textPrimary,
                style: isCursor ? [.bold] : []
            )
        ]
        if !option.description.isEmpty {
            spans.append(PagerStyledSpan(text: "  \(option.description)", foreground: theme.gray))
        }
        writeSpans(spans, rowBackground: rowBackground)
    }

    // The Other row. In input mode it shows the live text plus a block
    // cursor, the minimal inline editor the settings string field also uses.
    guard y < area.bottom else { return }
    let onOther = prompt.isOnFreeformRow || prompt.focus == .freeformInput
    let otherBackground = onOther ? theme.bgVisual : background
    if onOther {
        paintBlank(
            &buffer,
            area: TerminalRect(x: max(0, area.x - 1), y: y, width: area.width + 2, height: 1),
            foreground: theme.textPrimary,
            background: otherBackground
        )
    }
    let otherMarker = question.isMultiSelect
        ? (prompt.freeformSelected ? "[x] " : "[ ] ")
        : (prompt.freeformSelected ? "(\(PagerGlyphs.filledDot)) " : "(\(PagerGlyphs.emptyDot)) ")
    var otherSpans: [PagerStyledSpan] = [
        PagerStyledSpan(
            text: onOther ? PagerGlyphs.promptArrow : "  ",
            foreground: theme.accentUser,
            style: onOther ? [.bold] : []
        ),
        PagerStyledSpan(
            text: otherMarker,
            foreground: prompt.freeformSelected || onOther ? theme.textPrimary : theme.gray,
            style: onOther ? [.bold] : []
        ),
        PagerStyledSpan(text: "Other", foreground: theme.textPrimary, style: onOther ? [.bold] : [])
    ]
    if prompt.focus == .freeformInput {
        otherSpans.append(PagerStyledSpan(text: ": \(prompt.freeformText)", foreground: theme.textPrimary))
        otherSpans.append(PagerStyledSpan(text: "▌", foreground: theme.accentUser))
    } else if !prompt.freeformText.isEmpty {
        otherSpans.append(PagerStyledSpan(text: ": \(prompt.freeformText)", foreground: theme.textPrimary))
    } else {
        otherSpans.append(PagerStyledSpan(text: "  type your own answer", foreground: theme.gray))
    }
    writeSpans(otherSpans, rowBackground: otherBackground)
}

// MARK: - Plan approval body

/// "Plan approval", the waiting/empty status label, then the plan body from
/// `scrollOffset` and — while the user is typing revision feedback, or has a
/// stashed draft — a trailing feedback row with the same inline editor the
/// question sheet's Other row uses.
///
/// Publishes no hit-test rows, for the question sheet's reason: the generic
/// mouse router treats an unknown row id as "dismiss and select", which
/// would tear the sheet down without resolving the coordinator.
private func drawPlanApprovalBody(
    _ prompt: PagerPlanApprovalPrompt,
    in area: TerminalRect,
    background: TerminalColor,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) {
    guard area.width > 0, area.height > 0 else { return }
    var y = area.y

    func writeSpans(_ spans: [PagerStyledSpan], rowBackground: TerminalColor? = nil) {
        guard y < area.bottom else { return }
        paintSpans(
            &buffer,
            spans: truncateSpans(spans, to: area.width),
            x: area.x,
            y: y,
            limit: area.right,
            background: rowBackground ?? background,
            inheritForeground: theme.textPrimary
        )
        y += 1
    }

    writeSpans([
        PagerStyledSpan(text: "Plan approval", foreground: theme.accentUser, style: [.bold])
    ])
    writeSpans([
        PagerStyledSpan(text: prompt.statusLabel, foreground: theme.gray)
    ])
    y += 1

    let showFeedbackRow = prompt.focus == .feedbackInput || !prompt.feedbackText.isEmpty
    let bodyBottom = showFeedbackRow ? area.bottom - 1 : area.bottom
    let lines = prompt.bodyLines
    var index = min(max(0, prompt.scrollOffset), max(0, lines.count))
    while y < bodyBottom, lines.indices.contains(index) {
        writeSpans([
            PagerStyledSpan(text: lines[index], foreground: theme.textPrimary)
        ])
        index += 1
    }

    guard showFeedbackRow else { return }
    y = max(y, area.bottom - 1)
    var feedbackSpans: [PagerStyledSpan] = [
        PagerStyledSpan(
            text: "Feedback: ",
            foreground: theme.accentUser,
            style: prompt.focus == .feedbackInput ? [.bold] : []
        ),
        PagerStyledSpan(text: prompt.feedbackText, foreground: theme.textPrimary)
    ]
    if prompt.focus == .feedbackInput {
        feedbackSpans.append(PagerStyledSpan(text: "▌", foreground: theme.accentUser))
    }
    writeSpans(feedbackSpans, rowBackground: theme.bgVisual)
}

// MARK: - Welcome

/// The braille logo and hero box, drawn over the region above the composer.
private func renderFullScreenOverlay(
    _ overlay: PagerOverlay,
    layout: PagerFrameLayout,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme,
    motion: PagerMotionSnapshot = PagerMotionSnapshot()
) -> PagerOverlayBounds? {
    let area = layout.bounds
    let bottom = layout.input.height > 0 ? layout.input.y : area.bottom
    let frame = TerminalRect(
        x: area.x,
        y: area.y,
        width: area.width,
        height: max(0, bottom - area.y)
    )
    guard frame.width > 0, frame.height > 0 else { return nil }

    paintBlank(&buffer, area: frame, foreground: theme.textPrimary, background: theme.bgBase)

    var rows: [PagerOverlayBounds.Row] = []
    switch overlay.content {
    case .welcome(let welcome):
        rows = drawWelcomeBody(welcome, in: frame, buffer: &buffer, theme: theme, motion: motion)
    case .workflows(let runs):
        rows = drawWorkflowsBody(
            runs,
            in: frame,
            background: theme.bgBase,
            buffer: &buffer,
            theme: theme
        )
    default:
        break
    }
    return PagerOverlayBounds(
        id: overlay.id,
        frame: frame,
        content: frame,
        footer: TerminalRect(x: frame.x, y: frame.bottom, width: frame.width, height: 0),
        closeButton: nil,
        rows: rows
    )
}

/// Hero layout at ≥90 columns (logo left, text right, inside a rounded box);
/// stacked layout below that.
private func drawWelcomeBody(
    _ welcome: PagerWelcomeOverlay,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme,
    motion: PagerMotionSnapshot = PagerMotionSnapshot()
) -> [PagerOverlayBounds.Row] {
    guard area.width > 0, area.height > 0 else { return [] }
    let logo = PagerWelcomeLogo.art(forHeight: area.height)
    // The hero box always uses the full logo regardless of the height tier
    // (`hero_box.rs:326`), but it only appears once the logo itself does.
    if area.width >= PagerWelcomeLogo.heroBoxMinimumWidth, logo != nil {
        return drawWelcomeHero(
            welcome,
            logo: PagerWelcomeLogo.full,
            in: area,
            buffer: &buffer,
            theme: theme,
            motion: motion
        )
    }
    return drawWelcomeStacked(
        welcome,
        logo: logo,
        in: area,
        buffer: &buffer,
        theme: theme,
        motion: motion
    )
}

/// Paint one logo line, shimmering when motion is on.
///
/// With motion enabled each glyph is colored by its diagonal position and the
/// wall clock (`shine_opacity`, `welcome/logo.rs:86-107`), which is the
/// travelling glint. Disabled, the whole line paints in one call in
/// `textPrimary` — byte-identical to what this port always drew.
private func drawWelcomeLogoLine(
    _ buffer: inout CellBuffer,
    line: String,
    x: Int,
    y: Int,
    rowIndex: Int,
    rowCount: Int,
    logoWidth: Int,
    theme: PagerRenderTheme,
    motion: PagerMotionSnapshot
) {
    guard motion.enabled else {
        _ = buffer.setString(
            x: x,
            y: y,
            text: line,
            style: [],
            foreground: theme.textPrimary,
            background: theme.bgBase
        )
        return
    }
    // Diagonal runs 0 at the bottom-left glyph to 1 at the top-right, so the
    // band sweeps corner to corner (`welcome/logo.rs:126-152`).
    let diagonalSpan = Double(max(1, (logoWidth - 1) + (rowCount - 1)))
    var column = x
    for grapheme in line {
        let glyph = String(grapheme)
        let width = max(0, UnicodeDisplayWidth.width(ofGrapheme: glyph))
        let diagonal = Double((column - x) + (rowCount - 1 - rowIndex)) / diagonalSpan
        _ = buffer.setString(
            x: column,
            y: y,
            text: glyph,
            style: [],
            foreground: PagerMotion.shimmerColor(
                theme: theme,
                diagonal: diagonal,
                seconds: motion.seconds
            ),
            background: theme.bgBase
        )
        column += width
    }
}

private func drawWelcomeHero(
    _ welcome: PagerWelcomeOverlay,
    logo: [String],
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme,
    motion: PagerMotionSnapshot = PagerMotionSnapshot()
) -> [PagerOverlayBounds.Row] {
    let boxWidth = min(max(0, area.width - 6), 120)
    let rightRows = 1 + (welcome.subtitle.isEmpty ? 0 : 1) + 1 + welcome.menu.count
    let boxHeight = 4 + max(logo.count, rightRows)
    guard boxWidth >= 20, boxHeight <= area.height else {
        return drawWelcomeStacked(
            welcome,
            logo: logo,
            in: area,
            buffer: &buffer,
            theme: theme,
            motion: motion
        )
    }

    let x = area.x + (area.width - boxWidth) / 2
    let y = area.y + max(0, (area.height - boxHeight) / 3)
    let frame = TerminalRect(x: x, y: y, width: boxWidth, height: boxHeight)
    let border = blendPagerColors(theme.bgBase, theme.grayDim, 0.45)

    // Rounded box (`BorderType::Rounded`, `hero_box.rs:320-324`).
    for column in frame.x..<frame.right {
        drawWelcomeCell(&buffer, String(PagerGlyphs.borderHorizontal), column, frame.y, border, theme)
        drawWelcomeCell(
            &buffer,
            String(PagerGlyphs.borderHorizontal),
            column,
            frame.bottom - 1,
            border,
            theme
        )
    }
    for row in frame.y..<frame.bottom {
        drawWelcomeCell(&buffer, String(PagerGlyphs.borderVertical), frame.x, row, border, theme)
        drawWelcomeCell(&buffer, String(PagerGlyphs.borderVertical), frame.right - 1, row, border, theme)
    }
    drawWelcomeCell(&buffer, String(PagerGlyphs.borderTopLeft), frame.x, frame.y, border, theme)
    drawWelcomeCell(&buffer, String(PagerGlyphs.borderTopRight), frame.right - 1, frame.y, border, theme)
    drawWelcomeCell(&buffer, String(PagerGlyphs.borderBottomLeft), frame.x, frame.bottom - 1, border, theme)
    drawWelcomeCell(
        &buffer,
        String(PagerGlyphs.borderBottomRight),
        frame.right - 1,
        frame.bottom - 1,
        border,
        theme
    )

    // Left column: the logo, padded two columns to optically center it
    // (`hero_box.rs:207`).
    let logoX = frame.x + 1 + 2
    let logoWidth = logo.map { UnicodeDisplayWidth.width(of: $0) }.max() ?? 0
    for (index, line) in logo.enumerated() {
        let row = frame.y + 2 + index
        guard row < frame.bottom - 1 else { break }
        drawWelcomeLogoLine(
            &buffer,
            line: line,
            x: logoX,
            y: row,
            rowIndex: index,
            rowCount: logo.count,
            logoWidth: logoWidth,
            theme: theme,
            motion: motion
        )
    }

    // Right column.
    let rightX = frame.x + 1 + logoWidth + 5
    let rightWidth = max(0, frame.right - 1 - rightX)
    var row = frame.y + 2
    func writeRight(_ spans: [PagerStyledSpan]) {
        guard row < frame.bottom - 1, rightWidth > 0 else { return }
        paintSpans(
            &buffer,
            spans: truncateSpans(spans, to: rightWidth),
            x: rightX,
            y: row,
            limit: rightX + rightWidth,
            background: theme.bgBase
        )
        row += 1
    }

    writeRight([
        PagerStyledSpan(text: "\(welcome.productName)  ", foreground: theme.textPrimary, style: [.bold]),
        PagerStyledSpan(text: welcome.version, foreground: theme.gray)
    ])
    if !welcome.subtitle.isEmpty {
        writeRight([PagerStyledSpan(text: welcome.subtitle, foreground: theme.gray)])
    }
    row += 1

    var rows: [PagerOverlayBounds.Row] = []
    for (index, item) in welcome.menu.enumerated() {
        guard row < frame.bottom - 1 else { break }
        let isSelected = index == welcome.selectedIndex
        let itemFrame = TerminalRect(x: rightX, y: row, width: rightWidth, height: 1)
        if isSelected {
            paintBlank(
                &buffer,
                area: itemFrame,
                foreground: theme.textPrimary,
                background: theme.bgHighlight
            )
        }
        let background = isSelected ? theme.bgHighlight : theme.bgBase
        _ = buffer.setString(
            x: rightX,
            y: row,
            text: truncateToWidth(item.label, width: rightWidth),
            style: [.bold],
            foreground: theme.textPrimary,
            background: background
        )
        if !item.key.isEmpty {
            let keyWidth = UnicodeDisplayWidth.width(of: item.key)
            if keyWidth < rightWidth {
                _ = buffer.setString(
                    x: rightX + rightWidth - keyWidth,
                    y: row,
                    text: item.key,
                    style: [],
                    foreground: theme.grayBright,
                    background: background
                )
            }
        }
        rows.append(PagerOverlayBounds.Row(id: item.id, frame: itemFrame))
        row += 1
    }
    return rows
}

private func drawWelcomeStacked(
    _ welcome: PagerWelcomeOverlay,
    logo: [String]?,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme,
    motion: PagerMotionSnapshot = PagerMotionSnapshot()
) -> [PagerOverlayBounds.Row] {
    var row = area.y + 1
    if let logo {
        let width = logo.map { UnicodeDisplayWidth.width(of: $0) }.max() ?? 0
        let x = area.x + max(0, (area.width - width) / 2)
        for (index, line) in logo.enumerated() {
            guard row < area.bottom else { break }
            drawWelcomeLogoLine(
                &buffer,
                line: line,
                x: x,
                y: row,
                rowIndex: index,
                rowCount: logo.count,
                logoWidth: width,
                theme: theme,
                motion: motion
            )
            row += 1
        }
        row += 1
    }

    func writeCentered(_ spans: [PagerStyledSpan]) {
        guard row < area.bottom else { return }
        let clipped = truncateSpans(spans, to: area.width)
        let width = clipped.reduce(0) { $0 + UnicodeDisplayWidth.width(of: $1.text) }
        let x = area.x + max(0, (area.width - width) / 2)
        paintSpans(&buffer, spans: clipped, x: x, y: row, limit: area.right, background: theme.bgBase)
        row += 1
    }

    writeCentered([
        PagerStyledSpan(text: "\(welcome.productName)  ", foreground: theme.textPrimary, style: [.bold]),
        PagerStyledSpan(text: welcome.version, foreground: theme.gray)
    ])
    if !welcome.subtitle.isEmpty {
        writeCentered([PagerStyledSpan(text: welcome.subtitle, foreground: theme.gray)])
    }
    row += 1

    let menuWidth = min(area.width, 51)
    let menuX = area.x + max(0, (area.width - menuWidth) / 2)
    var rows: [PagerOverlayBounds.Row] = []
    for (index, item) in welcome.menu.enumerated() {
        guard row < area.bottom else { break }
        let isSelected = index == welcome.selectedIndex
        let frame = TerminalRect(x: menuX, y: row, width: menuWidth, height: 1)
        let background = isSelected ? theme.bgHighlight : theme.bgBase
        if isSelected {
            paintBlank(&buffer, area: frame, foreground: theme.textPrimary, background: background)
        }
        _ = buffer.setString(
            x: menuX,
            y: row,
            text: truncateToWidth(item.label, width: menuWidth),
            style: [.bold],
            foreground: theme.textPrimary,
            background: background
        )
        if !item.key.isEmpty {
            let keyWidth = UnicodeDisplayWidth.width(of: item.key)
            if keyWidth < menuWidth {
                _ = buffer.setString(
                    x: menuX + menuWidth - keyWidth,
                    y: row,
                    text: item.key,
                    style: [],
                    foreground: theme.grayBright,
                    background: background
                )
            }
        }
        rows.append(PagerOverlayBounds.Row(id: item.id, frame: frame))
        row += 1
    }
    return rows
}

private func drawWelcomeCell(
    _ buffer: inout CellBuffer,
    _ glyph: String,
    _ x: Int,
    _ y: Int,
    _ color: TerminalColor,
    _ theme: PagerRenderTheme
) {
    buffer.setCell(
        Cell(grapheme: glyph, foreground: color, background: theme.bgBase, displayWidth: 1),
        x: x,
        y: y
    )
}


// MARK: - Workflows dashboard

/// One row per run, or the selected run's detail when it is open.
///
/// Rows are emitted as hit-test bounds so a click selects a run, matching the
/// list overlay; the detail view publishes none, because nothing in it is a
/// target.
private func drawWorkflowsBody(
    _ runs: PagerWorkflowsOverlay,
    in area: TerminalRect,
    background: TerminalColor,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) -> [PagerOverlayBounds.Row] {
    guard area.width > 0, area.height > 0 else { return [] }

    if runs.isDetailOpen {
        let lines = runs.detailLines
        let start = min(max(0, runs.scrollOffset), max(0, lines.count))
        for row in 0..<area.height {
            let index = start + row
            guard lines.indices.contains(index) else { break }
            _ = buffer.setString(
                x: area.x,
                y: area.y + row,
                text: truncateToWidth(lines[index], width: area.width),
                style: [],
                foreground: theme.textPrimary,
                background: background
            )
        }
        return []
    }

    guard !runs.rows.isEmpty else {
        _ = buffer.setString(
            x: area.x,
            y: area.y,
            text: truncateToWidth(runs.emptyMessage, width: area.width),
            style: [],
            foreground: theme.gray,
            background: background
        )
        return []
    }

    var bounds: [PagerOverlayBounds.Row] = []
    let start = min(max(0, runs.scrollOffset), max(0, runs.rows.count - 1))
    for offset in 0..<area.height {
        let index = start + offset
        guard runs.rows.indices.contains(index) else { break }
        let run = runs.rows[index]
        let selected = index == runs.selectedIndex
        let y = area.y + offset
        let rowBackground = selected ? theme.bgVisual : background
        paintBlank(
            &buffer,
            area: TerminalRect(x: area.x, y: y, width: area.width, height: 1),
            foreground: theme.textPrimary,
            background: rowBackground
        )
        var text = selected ? "\u{276F} " : "  "
        text += run.name
        text += "  [\(run.status)]"
        if let phase = run.phase { text += "  \(phase)" }
        text += "  \(run.agentsFinished)/\(run.agentBudget) agents"
        if run.tokensUsed > 0 { text += "  ~\(run.tokensUsed)t" }
        _ = buffer.setString(
            x: area.x,
            y: y,
            text: truncateToWidth(text, width: area.width),
            style: selected ? [.bold] : [],
            foreground: selected ? theme.accentUser : theme.textPrimary,
            background: rowBackground
        )
        bounds.append(PagerOverlayBounds.Row(
            id: run.runID,
            frame: TerminalRect(x: area.x, y: y, width: area.width, height: 1)
        ))
    }
    return bounds
}
