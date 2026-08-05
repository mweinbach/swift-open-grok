// PagerSettingsRender.swift
//
// Painting the settings modal.
// Ports `xai-grok-pager/src/views/settings_modal/render.rs` at upstream
// 9ed09e2a.
//
// The browse list, the enum chooser, the group sheet, and the three editors all
// paint into the same content rect the modal chrome hands down, and all publish
// row bounds so a click lands on the row the eye is on.

import Foundation
import OpenGrokTerminalCore

// MARK: - Metrics

enum PagerSettingsMetrics {
    /// `ModalSizing` for the settings modal (`render.rs:112-124`).
    static let sizing = PagerModalSizing(
        widthFraction: 0.70,
        maximumWidth: 110,
        minimumWidth: 44,
        verticalMargin: 3,
        horizontalPadding: 2,
        verticalPadding: 1,
        footerLines: 2
    )

    /// `ROW_TRIANGLE_PREFIX_W` (`render.rs:2332`) — the expansion caret column
    /// plus its trailing space.
    static let trianglePrefixWidth = 2
    /// The chevron column is reserved on every row so values stay aligned even
    /// when only some rows are chevron-bearing (`render.rs:2336`).
    static let chevronWidth = 2
    /// `ROW_RESTART_PILL_W` (`render.rs:2337`).
    static let restartPill = " · restart"
    /// `PICKER_PREFIX_W` (`render.rs:905-912`).
    static let pickerPrefixFocused = " ●  "
    static let pickerPrefixUnfocused = " ○  "
    static let pickerSeparator = " · "
    /// Expanded descriptions indent four columns and are capped
    /// (`render.rs:2749-2785`).
    static let descriptionIndent = 4
    static let descriptionMaximumLines = 8
    static let zeroDataRetentionValue = "ZDR"
    static let policyManagedSuffix = " · Policy Managed"
}

// MARK: - Value display

/// `value_display` (`render.rs:2345-2367`).
func pagerSettingsValueDisplay(
    _ overlay: PagerSettingsOverlay,
    meta: PagerSettingMeta
) -> String? {
    if let lock = overlay.locks[meta.key], lock == .zeroDataRetention {
        return PagerSettingsMetrics.zeroDataRetentionValue
    }
    guard let value = overlay.value(for: meta.key) else { return nil }
    var text: String
    switch value {
    case .bool(let flag):
        text = flag ? "on" : "off"
    case .integer(let number):
        text = String(number)
    case .secret(let status):
        text = status.display
    case .string(let raw):
        if raw.isEmpty, case .dynamicEnum = meta.kind {
            text = "(no override)"
        } else if let choice = overlay.choices(for: meta).first(where: { $0.canonical == raw }) {
            text = choice.display
        } else {
            text = raw
        }
    }
    if overlay.locks[meta.key] == .policyManaged {
        text += PagerSettingsMetrics.policyManagedSuffix
    }
    return text
}

/// Whether the row's value is painted in the muted color rather than the accent
/// (`render.rs:2488-2497`) — off, unset, and locked all read as "nothing here".
private func pagerSettingsValueIsMuted(
    _ overlay: PagerSettingsOverlay,
    meta: PagerSettingMeta
) -> Bool {
    if overlay.isLocked(meta.key) { return true }
    switch overlay.value(for: meta.key) {
    case .bool(false): return true
    case .secret(.missing): return true
    default: return false
    }
}

/// Whether the row opens a sub-pane, which is what earns it a `›`
/// (`render.rs:2336`).
private func pagerSettingsHasChevron(_ meta: PagerSettingMeta) -> Bool {
    switch meta.kind {
    case .enumeration, .dynamicEnum, .string, .secret, .group, .dynamicMultiSelect: return true
    case .bool, .integer: return false
    }
}

// MARK: - Body

/// Paint the modal body. Returns row bounds for hit-testing.
func drawSettingsBody(
    _ overlay: PagerSettingsOverlay,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) -> [PagerOverlayBounds.Row] {
    guard area.width > 0, area.height > 0 else { return [] }

    switch overlay.mode {
    case .browse, .filtering:
        return drawSettingsBrowse(overlay, in: area, buffer: &buffer, theme: theme)
    case .pickingEnum(let key, let index, _):
        guard let meta = overlay.registry.find(key) else { return [] }
        return drawSettingsChooser(
            overlay, meta: meta, focused: index, in: area, buffer: &buffer, theme: theme
        )
    case .pickingGroup(let key, let index):
        guard let meta = overlay.registry.find(key) else { return [] }
        return drawSettingsGroupSheet(
            overlay, meta: meta, focused: index, in: area, buffer: &buffer, theme: theme
        )
    case .editingString(let key, let buffer_, let cursor, let error):
        guard let meta = overlay.registry.find(key) else { return [] }
        drawSettingsEditor(
            overlay, meta: meta, text: buffer_, cursor: cursor, error: error,
            masked: false, in: area, buffer: &buffer, theme: theme
        )
        return []
    case .editingSecret(let key, let buffer_, let error):
        guard let meta = overlay.registry.find(key) else { return [] }
        drawSettingsEditor(
            overlay, meta: meta, text: buffer_, cursor: buffer_.count, error: error,
            masked: true, in: area, buffer: &buffer, theme: theme
        )
        return []
    case .editingInt(let key, let value):
        guard let meta = overlay.registry.find(key) else { return [] }
        drawSettingsStepper(
            overlay, meta: meta, value: value, in: area, buffer: &buffer, theme: theme
        )
        return []
    }
}

// MARK: - Browse

private func drawSettingsBrowse(
    _ overlay: PagerSettingsOverlay,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) -> [PagerOverlayBounds.Row] {
    var y = area.y

    // Row 0 is the search bar, row 1 the divider — but only when there is room
    // for at least one list row underneath (`render.rs:374-448`).
    if area.height >= 3 {
        let isFocused = overlay.mode == .filtering
        var spans: [PagerStyledSpan] = [
            PagerStyledSpan(text: " search: ", foreground: isFocused ? theme.accentUser : theme.gray)
        ]
        if overlay.filterQuery.isEmpty {
            spans.append(PagerStyledSpan(text: "/ to search", foreground: theme.grayDim))
        } else {
            spans.append(PagerStyledSpan(text: overlay.filterQuery, foreground: theme.textPrimary))
        }
        if isFocused {
            spans.append(PagerStyledSpan(text: "▏", foreground: theme.accentUser))
        }
        paintSpans(
            &buffer,
            spans: truncateSpans(spans, to: area.width),
            x: area.x, y: y, limit: area.right, background: theme.bgBase
        )
        y += 1
        _ = buffer.setString(
            x: area.x, y: y,
            text: String(repeating: String(PagerGlyphs.borderHorizontal), count: area.width),
            style: [], foreground: theme.grayDim, background: theme.bgBase
        )
        y += 1
    }

    let rows = overlay.visibleRows
    let capacity = max(0, area.bottom - y)
    guard capacity > 0 else { return [] }

    guard !rows.isEmpty else {
        let message = "No matches for \"\(overlay.filterQuery)\""
        let width = UnicodeDisplayWidth.width(of: message)
        _ = buffer.setString(
            x: area.x + max(0, (area.width - width) / 2),
            y: y + capacity / 2,
            text: truncateToWidth(message, width: area.width),
            style: [], foreground: theme.grayDim, background: theme.bgBase
        )
        return []
    }

    // Expanded descriptions make rows variable-height, so the window is laid
    // out by measuring forward from a scroll offset that keeps the cursor in
    // view rather than by a fixed rows-per-screen division.
    let heights = rows.map { settingsRowHeight(overlay, row: $0, width: area.width) }
    let offset = settingsScrollOffset(
        heights: heights, selected: overlay.selectedIndex, capacity: capacity
    )

    var bounds: [PagerOverlayBounds.Row] = []
    var cursor = y
    for index in offset..<rows.count {
        let height = heights[index]
        guard cursor + 1 <= area.bottom else { break }
        let rowArea = TerminalRect(
            x: area.x, y: cursor, width: area.width,
            height: min(height, area.bottom - cursor)
        )
        switch rows[index] {
        case .header(let category):
            drawSettingsHeader(category, in: rowArea, buffer: &buffer, theme: theme)
        case .setting(let key):
            guard let meta = overlay.registry.find(key) else { break }
            drawSettingsRow(
                overlay, meta: meta,
                isSelected: index == overlay.selectedIndex,
                in: rowArea, buffer: &buffer, theme: theme
            )
            bounds.append(PagerOverlayBounds.Row(id: key, frame: rowArea))
        }
        cursor += height
    }
    return bounds
}

/// Height of one browse row: one line, plus a blank spacer above every header
/// but the first, plus wrapped description lines when expanded.
func settingsRowHeight(
    _ overlay: PagerSettingsOverlay,
    row: PagerSettingsRow,
    width: Int
) -> Int {
    switch row {
    case .header:
        return 1
    case .setting(let key):
        guard let meta = overlay.registry.find(key) else { return 1 }
        guard overlay.expandedKeys.contains(key) else { return 1 }
        let body = overlay.locks[key]?.reason ?? meta.description
        let wrapWidth = max(1, width - PagerSettingsMetrics.descriptionIndent)
        let lines = min(
            pagerWrapText(body, width: wrapWidth).count,
            PagerSettingsMetrics.descriptionMaximumLines
        )
        return 1 + lines
    }
}

/// The first row index to paint so the selected row is fully visible.
func settingsScrollOffset(heights: [Int], selected: Int, capacity: Int) -> Int {
    guard heights.indices.contains(selected) else { return 0 }
    var offset = 0
    while true {
        var used = 0
        var reached = false
        for index in offset..<heights.count {
            used += heights[index]
            if index == selected {
                reached = used <= capacity
                break
            }
        }
        if reached || offset >= selected { return offset }
        offset += 1
    }
}

private func drawSettingsHeader(
    _ category: PagerSettingCategory,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) {
    let label = " \(category.label) "
    var spans = [PagerStyledSpan(text: label, foreground: theme.gray, style: [.bold])]
    let used = UnicodeDisplayWidth.width(of: label)
    if used < area.width {
        spans.append(PagerStyledSpan(
            text: String(repeating: String(PagerGlyphs.borderHorizontal), count: area.width - used),
            foreground: theme.grayDim
        ))
    }
    paintSpans(
        &buffer, spans: spans, x: area.x, y: area.y,
        limit: area.right, background: theme.bgBase
    )
}

private func drawSettingsRow(
    _ overlay: PagerSettingsOverlay,
    meta: PagerSettingMeta,
    isSelected: Bool,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) {
    let background = isSelected ? theme.bgVisual : theme.bgBase
    let isExpanded = overlay.expandedKeys.contains(meta.key)
    let lineArea = TerminalRect(x: area.x, y: area.y, width: area.width, height: 1)
    if isSelected {
        paintBlank(&buffer, area: lineArea, foreground: theme.textPrimary, background: background)
    }

    // Right side is laid out first so the label knows its budget.
    var rightSpans: [PagerStyledSpan] = []
    if let value = pagerSettingsValueDisplay(overlay, meta: meta) {
        rightSpans.append(PagerStyledSpan(
            text: value,
            foreground: pagerSettingsValueIsMuted(overlay, meta: meta) ? theme.gray : theme.accentUser
        ))
    }
    rightSpans.append(PagerStyledSpan(
        text: pagerSettingsHasChevron(meta) && !overlay.isLocked(meta.key) ? " \(PagerGlyphs.chevronRight)" : "  ",
        foreground: theme.grayDim
    ))
    // The restart pill only appears on an expanded row: the reference treats it
    // as an explanation of the description, not a permanent badge
    // (`render.rs:2517-2523`).
    if isExpanded, meta.restartRequired {
        rightSpans.append(PagerStyledSpan(
            text: PagerSettingsMetrics.restartPill,
            foreground: theme.grayDim,
            style: [.italic]
        ))
    }
    let rightWidth = rightSpans.reduce(0) { $0 + UnicodeDisplayWidth.width(of: $1.text) } + 1

    let caret = isExpanded ? PagerGlyphs.chevronDown : PagerGlyphs.chevronRight
    let labelSpans: [PagerStyledSpan] = [
        PagerStyledSpan(text: "\(caret) ", foreground: isSelected ? theme.accentUser : theme.grayDim),
        PagerStyledSpan(
            text: meta.label,
            foreground: overlay.isLocked(meta.key) ? theme.gray : theme.textPrimary,
            style: isSelected ? [.bold] : []
        )
    ]
    let labelBudget = max(0, area.width - rightWidth)
    paintSpans(
        &buffer,
        spans: truncateSpans(labelSpans, to: labelBudget),
        x: area.x, y: area.y, limit: area.x + labelBudget, background: background
    )
    if rightWidth <= area.width {
        paintSpans(
            &buffer, spans: rightSpans,
            x: area.right - rightWidth, y: area.y, limit: area.right, background: background
        )
    }

    guard isExpanded, area.height > 1 else { return }
    let body = overlay.locks[meta.key]?.reason ?? meta.description
    let indent = PagerSettingsMetrics.descriptionIndent
    let lines = pagerWrapText(body, width: max(1, area.width - indent))
        .prefix(PagerSettingsMetrics.descriptionMaximumLines)
    for (offset, line) in lines.enumerated() {
        let y = area.y + 1 + offset
        guard y < area.bottom else { break }
        _ = buffer.setString(
            x: area.x + indent, y: y,
            text: truncateToWidth(line, width: area.width - indent),
            style: [.italic],
            foreground: overlay.isLocked(meta.key) ? theme.warning : theme.gray,
            background: theme.bgBase
        )
    }
}

// MARK: - Sub-pane header

/// `render_sub_pane_header` (`render.rs:924-968`): bold label, wrapped
/// description, then a blank row. Returns the rows consumed.
private func drawSubPaneHeader(
    _ meta: PagerSettingMeta,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) -> Int {
    guard area.height > 0 else { return 0 }
    _ = buffer.setString(
        x: area.x, y: area.y,
        text: truncateToWidth(meta.label, width: area.width),
        style: [.bold], foreground: theme.textPrimary, background: theme.bgBase
    )
    var consumed = 1
    let lines = pagerWrapText(meta.description, width: area.width)
        .prefix(PagerSettingsMetrics.descriptionMaximumLines)
    for line in lines {
        let y = area.y + consumed
        guard y < area.bottom - 1 else { break }
        _ = buffer.setString(
            x: area.x, y: y,
            text: truncateToWidth(line, width: area.width),
            style: [], foreground: theme.grayDim, background: theme.bgBase
        )
        consumed += 1
    }
    return min(consumed + 1, area.height)
}

// MARK: - Enum chooser

private func drawSettingsChooser(
    _ overlay: PagerSettingsOverlay,
    meta: PagerSettingMeta,
    focused: Int,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) -> [PagerOverlayBounds.Row] {
    let headerRows = drawSubPaneHeader(meta, in: area, buffer: &buffer, theme: theme)
    let listArea = TerminalRect(
        x: area.x, y: area.y + headerRows,
        width: area.width, height: max(0, area.height - headerRows)
    )
    guard listArea.height > 0 else { return [] }

    let choices = overlay.choices(for: meta)
    let committed = overlay.stringValue(for: meta.key)
    let capacity = listArea.height
    let offset = focused >= capacity ? focused - capacity + 1 : 0

    var bounds: [PagerOverlayBounds.Row] = []
    for index in offset..<min(choices.count, offset + capacity) {
        let choice = choices[index]
        let y = listArea.y + (index - offset)
        let isFocused = index == focused
        let frame = TerminalRect(x: listArea.x, y: y, width: listArea.width, height: 1)
        let background = isFocused ? theme.bgVisual : theme.bgBase
        if isFocused {
            paintBlank(&buffer, area: frame, foreground: theme.textPrimary, background: background)
        }
        // The filled dot marks what is *committed*, not what is focused: while
        // previewing a theme the user needs to see where they started.
        var spans: [PagerStyledSpan] = [
            PagerStyledSpan(
                text: choice.canonical == committed
                    ? PagerSettingsMetrics.pickerPrefixFocused
                    : PagerSettingsMetrics.pickerPrefixUnfocused,
                foreground: choice.canonical == committed ? theme.accentUser : theme.gray
            ),
            PagerStyledSpan(
                text: choice.display,
                foreground: theme.textPrimary,
                style: isFocused ? [.bold] : []
            )
        ]
        if !choice.summary.isEmpty {
            spans.append(PagerStyledSpan(
                text: PagerSettingsMetrics.pickerSeparator + choice.summary,
                foreground: theme.gray
            ))
        }
        paintSpans(
            &buffer,
            spans: truncateSpans(spans, to: listArea.width),
            x: listArea.x, y: y, limit: listArea.right, background: background
        )
        bounds.append(PagerOverlayBounds.Row(id: choice.canonical, frame: frame))
    }

    let hidden = choices.count - min(choices.count, offset + capacity)
    if hidden > 0, listArea.bottom - 1 >= listArea.y {
        _ = buffer.setString(
            x: listArea.x, y: listArea.bottom - 1,
            text: truncateToWidth("\(PagerGlyphs.ellipsis) \(hidden) more", width: listArea.width),
            style: [], foreground: theme.grayDim, background: theme.bgBase
        )
    }
    return bounds
}

// MARK: - Group / multi-select sheet

private func drawSettingsGroupSheet(
    _ overlay: PagerSettingsOverlay,
    meta: PagerSettingMeta,
    focused: Int,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) -> [PagerOverlayBounds.Row] {
    let headerRows = drawSubPaneHeader(meta, in: area, buffer: &buffer, theme: theme)
    let listArea = TerminalRect(
        x: area.x, y: area.y + headerRows,
        width: area.width, height: max(0, area.height - headerRows)
    )
    guard listArea.height > 0 else { return [] }

    // Both shapes render as `label … on/off`; only where the label and the
    // on/off state come from differs.
    struct Entry { var id: String; var label: String; var isOn: Bool }
    let entries: [Entry]
    if case .dynamicMultiSelect = meta.kind {
        let enabled = overlay.multiSelectEnabled[meta.key] ?? []
        entries = overlay.choices(for: meta).map {
            Entry(id: $0.canonical, label: $0.display, isOn: enabled.contains($0.canonical))
        }
    } else {
        entries = overlay.children(of: meta).map { child in
            var isOn = false
            if case .bool(let flag)? = overlay.value(for: child.key) { isOn = flag }
            return Entry(id: child.key, label: child.label, isOn: isOn)
        }
    }

    let capacity = listArea.height
    let offset = focused >= capacity ? focused - capacity + 1 : 0
    var bounds: [PagerOverlayBounds.Row] = []
    for index in offset..<min(entries.count, offset + capacity) {
        let entry = entries[index]
        let y = listArea.y + (index - offset)
        let isFocused = index == focused
        let frame = TerminalRect(x: listArea.x, y: y, width: listArea.width, height: 1)
        let background = isFocused ? theme.bgVisual : theme.bgBase
        if isFocused {
            paintBlank(&buffer, area: frame, foreground: theme.textPrimary, background: background)
        }
        let state = entry.isOn ? "on" : "off"
        let stateWidth = UnicodeDisplayWidth.width(of: state) + 1
        paintSpans(
            &buffer,
            spans: truncateSpans([
                PagerStyledSpan(
                    text: entry.isOn
                        ? PagerSettingsMetrics.pickerPrefixFocused
                        : PagerSettingsMetrics.pickerPrefixUnfocused,
                    foreground: entry.isOn ? theme.accentUser : theme.gray
                ),
                PagerStyledSpan(
                    text: entry.label,
                    foreground: theme.textPrimary,
                    style: isFocused ? [.bold] : []
                )
            ], to: max(0, listArea.width - stateWidth)),
            x: listArea.x, y: y, limit: listArea.right, background: background
        )
        _ = buffer.setString(
            x: listArea.right - stateWidth, y: y, text: state,
            style: [], foreground: entry.isOn ? theme.accentUser : theme.gray,
            background: background
        )
        bounds.append(PagerOverlayBounds.Row(id: entry.id, frame: frame))
    }
    return bounds
}

// MARK: - Editors

private func drawSettingsEditor(
    _ overlay: PagerSettingsOverlay,
    meta: PagerSettingMeta,
    text: String,
    cursor: Int,
    error: String?,
    masked: Bool,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) {
    let headerRows = drawSubPaneHeader(meta, in: area, buffer: &buffer, theme: theme)
    let inputY = area.y + headerRows
    guard inputY < area.bottom else { return }

    let inputArea = TerminalRect(x: area.x, y: inputY, width: area.width, height: 1)
    paintBlank(&buffer, area: inputArea, foreground: theme.textPrimary, background: theme.bgVisual)

    // A secret is masked at paint time; the plaintext never reaches a cell.
    let display = masked ? String(repeating: "*", count: text.count) : text
    if display.isEmpty {
        // The cursor sits at column 0 on an empty field, so the placeholder
        // starts one column over — painting it under the cursor would eat its
        // leading `<` and leave the hint looking like a typo.
        let placeholder = pagerSettingsPlaceholder(for: meta)
        _ = buffer.setString(
            x: area.x + 1, y: inputY,
            text: truncateToWidth(placeholder, width: max(0, area.width - 1)),
            style: [], foreground: theme.grayDim, background: theme.bgVisual
        )
    } else {
        _ = buffer.setString(
            x: area.x, y: inputY,
            text: truncateToWidth(display, width: area.width),
            style: [],
            foreground: error == nil ? theme.textPrimary : theme.accentError,
            background: theme.bgVisual
        )
    }
    let cursorColumn = area.x + min(max(0, cursor), max(0, area.width - 1))
    buffer.setCell(
        Cell(
            grapheme: "▏", foreground: theme.accentUser,
            background: theme.bgVisual, displayWidth: 1
        ),
        x: cursorColumn, y: inputY
    )

    if let error, inputY + 1 < area.bottom {
        _ = buffer.setString(
            x: area.x, y: inputY + 1,
            text: truncateToWidth(error, width: area.width),
            style: [], foreground: theme.accentError, background: theme.bgBase
        )
    }
}

/// `render.rs:1729-1739`.
func pagerSettingsPlaceholder(for meta: PagerSettingMeta) -> String {
    switch meta.kind {
    case .secret: return "<paste or type a key>"
    case .string(_, .knownModel): return "<empty — use shell default>"
    default: return "<type a value>"
    }
}

private func drawSettingsStepper(
    _ overlay: PagerSettingsOverlay,
    meta: PagerSettingMeta,
    value: Int,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) {
    let headerRows = drawSubPaneHeader(meta, in: area, buffer: &buffer, theme: theme)
    let y = area.y + headerRows
    guard y < area.bottom else { return }

    // `‹  N  ›` centered (`render_int_stepper`, `render.rs:1809-1954`). Below
    // eight columns there is no room for the adornments and only the number
    // is drawn.
    let number = String(value)
    let text = area.width >= 8 ? "\u{2039}  \(number)  \u{203A}" : number
    let width = UnicodeDisplayWidth.width(of: text)
    let x = area.x + max(0, (area.width - width) / 2)
    let row = TerminalRect(x: area.x, y: y, width: area.width, height: 1)
    paintBlank(&buffer, area: row, foreground: theme.textPrimary, background: theme.bgVisual)
    _ = buffer.setString(
        x: x, y: y, text: text, style: [.bold],
        foreground: theme.accentUser, background: theme.bgVisual
    )
}

// MARK: - Footer

/// `build_shortcuts` (`render.rs:2880-3090`) — the footer reflects the mode, so
/// the keys on screen are always the keys that work.
func pagerSettingsHints(_ overlay: PagerSettingsOverlay) -> [PagerOverlayHint] {
    switch overlay.mode {
    case .browse:
        var hints = [
            PagerOverlayHint(key: "↑/↓", label: "nav"),
            PagerOverlayHint(key: "g/G", label: "top/btm")
        ]
        if let meta = overlay.selectedMeta, !overlay.isLocked(meta.key) {
            if case .bool = meta.kind {
                hints.append(PagerOverlayHint(key: "Space", label: "toggle"))
            } else if meta.kind.isEditable {
                hints.append(PagerOverlayHint(key: "Enter", label: "edit"))
            } else {
                hints.append(PagerOverlayHint(key: "Enter", label: "open"))
            }
        }
        hints.append(PagerOverlayHint(key: "→", label: "expand"))
        hints.append(PagerOverlayHint(key: "/", label: "search"))
        if let meta = overlay.selectedMeta, meta.kind.isEditable, !overlay.isLocked(meta.key) {
            hints.append(PagerOverlayHint(key: "d", label: "reset"))
        }
        hints.append(PagerOverlayHint(key: "F2/Esc", label: "close"))
        return hints
    case .filtering:
        return [
            PagerOverlayHint(key: "type", label: "to filter"),
            PagerOverlayHint(key: "↑/↓", label: "nav"),
            PagerOverlayHint(key: "Enter", label: "commit"),
            PagerOverlayHint(key: "Esc", label: "clear")
        ]
    case .pickingEnum(let key, _, _):
        let previews = overlay.registry.find(key).map { overlay.supportsPreview($0) } ?? false
        var hints = [
            PagerOverlayHint(key: "↑/↓", label: previews ? "try" : "nav"),
            PagerOverlayHint(key: "Enter", label: "select"),
            PagerOverlayHint(key: "Esc", label: previews ? "revert" : "cancel")
        ]
        if !overlay.isConsentChooser(key) {
            hints.append(PagerOverlayHint(key: "d", label: "reset"))
        }
        return hints
    case .pickingGroup:
        return [
            PagerOverlayHint(key: "↑/↓", label: "nav"),
            PagerOverlayHint(key: "Space/Enter", label: "toggle"),
            PagerOverlayHint(key: "Esc", label: "back")
        ]
    case .editingString:
        return [
            PagerOverlayHint(key: "type", label: "to edit"),
            PagerOverlayHint(key: "←/→", label: "cursor"),
            PagerOverlayHint(key: "Enter", label: "commit"),
            PagerOverlayHint(key: "Esc", label: "cancel")
        ]
    case .editingSecret:
        return [
            PagerOverlayHint(key: "type/paste", label: "key"),
            PagerOverlayHint(key: "Enter", label: "save"),
            PagerOverlayHint(key: "Esc", label: "cancel")
        ]
    case .editingInt(let key, _):
        guard let meta = overlay.registry.find(key),
              case .integer(_, let minimum, let maximum) = meta.kind
        else { return [] }
        let (small, large) = PagerSettingsOverlay.stepSizes(minimum: minimum, maximum: maximum)
        return [
            PagerOverlayHint(key: "↑/↓", label: "±\(small)"),
            PagerOverlayHint(key: "←/→", label: "±\(large)"),
            PagerOverlayHint(key: "Enter", label: "commit"),
            PagerOverlayHint(key: "Esc", label: "cancel"),
            PagerOverlayHint(key: "d", label: "reset")
        ]
    }
}

/// The modal title, which becomes a breadcrumb inside any sub-pane
/// (`render.rs:55-95`).
func pagerSettingsTitle(_ overlay: PagerSettingsOverlay) -> String {
    guard let key = overlay.mode.settingKey, let meta = overlay.registry.find(key) else {
        return "Settings"
    }
    return "Settings \u{203A} \(meta.label)"
}

// MARK: - Wrapping

/// Greedy word wrap. Words longer than the width are hard-split rather than
/// overflowing, so a long URL in a description cannot push the value column off
/// the row.
func pagerWrapText(_ text: String, width: Int) -> [String] {
    guard width > 0 else { return [] }
    guard !text.isEmpty else { return [""] }
    var lines: [String] = []
    var current = ""
    for word in text.split(separator: " ", omittingEmptySubsequences: true) {
        var piece = String(word)
        while UnicodeDisplayWidth.width(of: piece) > width {
            var head = ""
            for character in piece {
                if UnicodeDisplayWidth.width(of: head + String(character)) > width { break }
                head.append(character)
            }
            if head.isEmpty { break }
            if !current.isEmpty { lines.append(current); current = "" }
            lines.append(head)
            piece = String(piece.dropFirst(head.count))
        }
        if current.isEmpty {
            current = piece
        } else if UnicodeDisplayWidth.width(of: current + " " + piece) <= width {
            current += " " + piece
        } else {
            lines.append(current)
            current = piece
        }
    }
    if !current.isEmpty { lines.append(current) }
    return lines.isEmpty ? [""] : lines
}
