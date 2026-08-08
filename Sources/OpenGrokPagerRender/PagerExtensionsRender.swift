// PagerExtensionsRender.swift
//
// Painting the extensions modal.
// Ports the read-only surface of `render_extensions_modal`
// (`xai-grok-pager/src/views/extensions_modal.rs:2484+` at upstream
// 650c1db7): the tab bar, the search row with the status-filter indicator,
// the divider, and the entry list with group headers, right labels, badges,
// description lines, and expanded key-value fields. The footer hints carry
// only keys this port actually handles — no mutation verbs.

import Foundation
import OpenGrokTerminalCore

// MARK: - Metrics

enum PagerExtensionsMetrics {
    /// Upstream's `ModalSizing` for this modal (`extensions_modal.rs:3387-3395`):
    /// width_pct 0.65, max 160, min 40, v_margin 3, h_pad 2, v_pad 2, footer 2.
    static let sizing = PagerModalSizing(
        widthFraction: 0.65,
        maximumWidth: 160,
        minimumWidth: 40,
        verticalMargin: 3,
        horizontalPadding: 2,
        verticalPadding: 2,
        footerLines: 2
    )

    /// Indent per entry level — group children inset one stop.
    static let indentWidth = 2
    /// Expanded field lines indent under their row.
    static let fieldIndent = 4
}

// MARK: - Body

/// Paint the modal body. Returns row bounds for hit-testing.
func drawExtensionsBody(
    _ overlay: PagerExtensionsOverlay,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) -> [PagerOverlayBounds.Row] {
    guard area.width > 0, area.height > 0 else { return [] }
    var y = area.y

    // Tab bar — the modal title is empty on purpose ("the tab bar identifies
    // the modal contents", `extensions_modal.rs:3383`).
    if y < area.bottom {
        var spans: [PagerStyledSpan] = []
        for (index, tab) in PagerExtensionsTab.all.enumerated() {
            if index > 0 {
                spans.append(PagerStyledSpan(text: " \u{2502} ", foreground: theme.grayDim))
            }
            let isActive = tab == overlay.activeTab
            spans.append(PagerStyledSpan(
                text: tab.label,
                foreground: isActive ? theme.accentUser : theme.gray,
                style: isActive ? [.bold] : []
            ))
        }
        paintSpans(
            &buffer,
            spans: truncateSpans(spans, to: area.width),
            x: area.x, y: y, limit: area.right, background: theme.bgBase
        )
        y += 1
    }

    // Search row plus the right-aligned filter indicator (upstream's
    // `render_picker_search_bar` + `render_filter_indicator`,
    // `extensions_modal.rs:3421-3454`).
    if y < area.bottom {
        var spans: [PagerStyledSpan] = [
            PagerStyledSpan(
                text: " search: ",
                foreground: overlay.searchActive ? theme.accentUser : theme.gray
            )
        ]
        if overlay.searchQuery.isEmpty, !overlay.searchActive {
            spans.append(PagerStyledSpan(text: "/ to search", foreground: theme.grayDim))
        } else {
            spans.append(PagerStyledSpan(text: overlay.searchQuery, foreground: theme.textPrimary))
        }
        if overlay.searchActive {
            spans.append(PagerStyledSpan(text: "\u{258F}", foreground: theme.accentUser))
        }

        var filterWidth = 0
        if overlay.activeTab.hasStatusFilter {
            let filter = overlay.activeFilter
            let text = "f \(filter.label)"
            filterWidth = UnicodeDisplayWidth.width(of: text) + 1
            if filterWidth <= area.width {
                _ = buffer.setString(
                    x: area.right - filterWidth, y: y,
                    text: text,
                    style: filter == .all ? [] : [.bold],
                    foreground: filter == .all ? theme.grayDim : theme.accentUser,
                    background: theme.bgBase
                )
            }
        }
        paintSpans(
            &buffer,
            spans: truncateSpans(spans, to: max(0, area.width - filterWidth)),
            x: area.x, y: y, limit: area.right - filterWidth, background: theme.bgBase
        )
        y += 1
    }

    // Divider below the search row (`extensions_modal.rs:3458-3468`).
    if y < area.bottom {
        _ = buffer.setString(
            x: area.x, y: y,
            text: String(repeating: String(PagerGlyphs.borderHorizontal), count: area.width),
            style: [], foreground: theme.grayDim, background: theme.bgBase
        )
        y += 1
    }

    let entries = overlay.entries()
    let capacity = max(0, area.bottom - y)
    guard capacity > 0 else { return [] }

    // Upstream's picker empty state is the bare `"  No matches"`
    // (`picker.rs:2040-2046`) — an honest nothing, never fake rows.
    guard !entries.isEmpty else {
        _ = buffer.setString(
            x: area.x, y: y,
            text: truncateToWidth("  No matches", width: area.width),
            style: [], foreground: theme.grayDim, background: theme.bgBase
        )
        return []
    }

    let heights = entries.map { extensionsEntryHeight(overlay, entry: $0) }
    let offset = settingsScrollOffset(
        heights: heights, selected: overlay.selectedIndex, capacity: capacity
    )

    var bounds: [PagerOverlayBounds.Row] = []
    var cursor = y
    for index in offset..<entries.count {
        guard cursor < area.bottom else { break }
        let entry = entries[index]
        let height = heights[index]
        let rowArea = TerminalRect(
            x: area.x, y: cursor, width: area.width,
            height: min(height, area.bottom - cursor)
        )
        drawExtensionsEntry(
            overlay,
            entry: entry,
            isSelected: index == overlay.selectedIndex && entry.isSelectable,
            in: rowArea,
            buffer: &buffer,
            theme: theme
        )
        if entry.isSelectable {
            bounds.append(PagerOverlayBounds.Row(id: entry.id, frame: rowArea))
        }
        cursor += height
    }
    return bounds
}

/// Height of one entry: the label line, its description lines, and — when
/// pinned open — its detail fields.
func extensionsEntryHeight(
    _ overlay: PagerExtensionsOverlay,
    entry: PagerExtensionsEntry
) -> Int {
    var height = 1 + entry.descriptionLines.count
    if overlay.expandedRows.contains(entry.id) {
        height += entry.fields.count
    }
    return height
}

private func drawExtensionsEntry(
    _ overlay: PagerExtensionsOverlay,
    entry: PagerExtensionsEntry,
    isSelected: Bool,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) {
    let background = isSelected ? theme.bgVisual : theme.bgBase
    let lineArea = TerminalRect(x: area.x, y: area.y, width: area.width, height: 1)
    if isSelected {
        paintBlank(&buffer, area: lineArea, foreground: theme.textPrimary, background: background)
    }

    // Right side first so the label knows its budget: badge, then the
    // parenthesized right label.
    var rightSpans: [PagerStyledSpan] = []
    switch entry.badge {
    case .none:
        break
    case .disabled, .failed:
        rightSpans.append(PagerStyledSpan(text: entry.badge.text, foreground: theme.accentError))
    case .connected:
        rightSpans.append(PagerStyledSpan(text: entry.badge.text, foreground: theme.accentSuccess))
    }
    if !entry.rightLabel.isEmpty {
        if !rightSpans.isEmpty {
            rightSpans.append(PagerStyledSpan(text: " ", foreground: theme.gray))
        }
        rightSpans.append(PagerStyledSpan(text: entry.rightLabel, foreground: theme.gray))
    }
    let rightWidth = rightSpans.isEmpty
        ? 0
        : rightSpans.reduce(0) { $0 + UnicodeDisplayWidth.width(of: $1.text) } + 1

    let indent = String(repeating: " ", count: entry.indent * PagerExtensionsMetrics.indentWidth)
    // NEVER a leading empty span: `paintSpans` BREAKS the whole run on the
    // first empty-text span (OpenGrokPagerRender.swift:1631), so an
    // indent="" (every top-level row: group headers, skills, plugins) would
    // blank the entire line — the caret and label never paint. Only emit the
    // indent span when it has width.
    var labelSpans: [PagerStyledSpan] = indent.isEmpty
        ? []
        : [PagerStyledSpan(text: indent, foreground: theme.grayDim)]
    if let groupKey = entry.groupKey {
        // Group headers carry the collapse caret; searching forces groups
        // open, so the caret follows the painted truth.
        let searching = !overlay.searchQuery.isEmpty
        let collapsed = !searching && overlay.collapsedGroups.contains(groupKey)
        let caret = collapsed ? PagerGlyphs.chevronRight : PagerGlyphs.chevronDown
        labelSpans.append(PagerStyledSpan(
            text: "\(caret) ",
            foreground: isSelected ? theme.accentUser : theme.grayDim
        ))
        labelSpans.append(PagerStyledSpan(
            text: entry.label,
            foreground: theme.textPrimary,
            style: [.bold]
        ))
    } else {
        labelSpans.append(PagerStyledSpan(
            text: entry.label,
            foreground: entry.dimmed ? theme.gray : theme.textPrimary,
            style: isSelected ? [.bold] : []
        ))
    }

    let labelBudget = max(0, area.width - rightWidth)
    paintSpans(
        &buffer,
        spans: truncateSpans(labelSpans, to: labelBudget),
        x: area.x, y: area.y, limit: area.x + labelBudget, background: background
    )
    if !rightSpans.isEmpty, rightWidth <= area.width {
        paintSpans(
            &buffer, spans: rightSpans,
            x: area.right - rightWidth, y: area.y, limit: area.right, background: background
        )
    }

    // Description lines under the row, dim, one indent stop past the label.
    var y = area.y + 1
    let descriptionIndent = (entry.indent + 1) * PagerExtensionsMetrics.indentWidth
    for line in entry.descriptionLines {
        guard y < area.bottom else { return }
        _ = buffer.setString(
            x: area.x + descriptionIndent, y: y,
            text: truncateToWidth(line, width: max(0, area.width - descriptionIndent)),
            style: [],
            foreground: entry.dimmed ? theme.grayDim : theme.gray,
            background: theme.bgBase
        )
        y += 1
    }

    // Expanded key-value fields (`picker.rs` detail lines).
    guard overlay.expandedRows.contains(entry.id) else { return }
    let fieldIndent = PagerExtensionsMetrics.fieldIndent
    for field in entry.fields {
        guard y < area.bottom else { return }
        paintSpans(
            &buffer,
            spans: truncateSpans([
                PagerStyledSpan(text: String(repeating: " ", count: fieldIndent), foreground: theme.grayDim),
                PagerStyledSpan(text: "\(field.label): ", foreground: theme.grayDim, style: [.italic]),
                PagerStyledSpan(text: field.value, foreground: theme.gray)
            ], to: area.width),
            x: area.x, y: y, limit: area.right, background: theme.bgBase
        )
        y += 1
    }
}

// MARK: - Footer

/// The footer lists exactly the keys `PagerExtensionsOverlay.handle` acts on.
/// Upstream's per-tab mutation verbs (`extensions_action_keys`,
/// `extensions_modal.rs:1112-1137`) are deliberately absent: this port backs
/// none of them, and an advertised key with no backing is a no-op row.
func pagerExtensionsHints(_ overlay: PagerExtensionsOverlay) -> [PagerOverlayHint] {
    if overlay.searchActive {
        return [
            PagerOverlayHint(key: "type", label: "to search"),
            PagerOverlayHint(key: "\u{2191}/\u{2193}", label: "nav"),
            PagerOverlayHint(key: "Enter", label: "commit"),
            PagerOverlayHint(key: "Esc", label: "clear")
        ]
    }
    var hints = [
        PagerOverlayHint(key: "Tab", label: "tabs"),
        PagerOverlayHint(key: "\u{2191}/\u{2193}", label: "nav"),
        PagerOverlayHint(key: "e", label: "expand"),
        PagerOverlayHint(key: "/", label: "search")
    ]
    if overlay.activeTab.hasStatusFilter {
        hints.append(PagerOverlayHint(key: "f", label: "filter"))
    }
    switch overlay.activeTab {
    case .hooks, .plugins, .skills:
        hints.append(PagerOverlayHint(key: "r", label: "reload"))
    case .mcpServers:
        // Upstream labels the MCP key "refresh" (`MCP_SERVERS_ACTION_KEYS`,
        // `extensions_modal.rs:1075-1081`).
        hints.append(PagerOverlayHint(key: "r", label: "refresh"))
    case .marketplace:
        break
    }
    hints.append(PagerOverlayHint(key: "Esc", label: "close"))
    return hints
}
