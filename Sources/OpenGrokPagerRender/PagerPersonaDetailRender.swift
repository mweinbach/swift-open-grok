// PagerPersonaDetailRender.swift
//
// Painting the persona detail modal. Ports `render_persona_detail`
// (`xai-grok-pager/src/views/persona_detail.rs:375-668` at upstream
// 650c1db7): the labeled field rows with the 14-column label gutter
// (`:402`), the selected-row highlight, the inline editor row, the
// multi-line instructions with collapse-at-8 and scroll hints
// (`:467-557`), empty markers (`\u{2014}` / `(empty)`), word-wrapped long
// values, the Inputs/Outputs sections (`:599-653`), and the trailing
// `Source:` line (`:655-667`). Footer hints are `build_shortcuts`
// (`:683-724`); sizing is `persona_detail_sizing` (`:670-681`) — the same
// numbers as the agents modal.

import Foundation
import OpenGrokTerminalCore

enum PagerPersonaDetailMetrics {
    /// `persona_detail_sizing` (`persona_detail.rs:670-681`).
    static let sizing = PagerModalSizing(
        widthFraction: 0.70,
        maximumWidth: 100,
        minimumWidth: 44,
        verticalMargin: 4,
        horizontalPadding: 2,
        verticalPadding: 1,
        footerLines: 2
    )

    /// Label column width (`:402`).
    static let labelColumnWidth = 14
    /// Collapsed instructions cap (`:479`).
    static let collapsedInstructionLines = 8
}

// MARK: - Body

func drawPersonaDetailBody(
    _ overlay: PagerPersonaDetailOverlay,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) {
    guard area.width > 0, area.height > 0 else { return }
    let width = area.width
    var y = area.y
    let maxY = area.bottom
    let labelWidth = PagerPersonaDetailMetrics.labelColumnWidth

    // Message line (`:404-415`) — error accent regardless of content,
    // upstream's single style.
    if let message = overlay.message, y < maxY {
        _ = buffer.setString(
            x: area.x, y: y,
            text: truncateToWidth(message, width: width),
            style: [], foreground: theme.accentError, background: theme.bgBase
        )
        y += 2
    }

    for field in PagerPersonaDetailField.allCases {
        guard y < maxY else { break }
        let isSelected = overlay.selectedField == field
        let value = overlay.fieldValue(field)
        let rowBackground = isSelected ? theme.bgHighlight : theme.bgBase
        if isSelected {
            paintBlank(
                &buffer,
                area: TerminalRect(x: area.x, y: y, width: width, height: 1),
                foreground: theme.textPrimary,
                background: rowBackground
            )
        }
        _ = buffer.setString(
            x: area.x, y: y,
            text: truncateToWidth(field.label, width: width),
            style: isSelected ? [.bold] : [],
            foreground: isSelected ? theme.accentUser : theme.gray,
            background: rowBackground
        )
        let valueX = area.x + labelWidth
        let valueWidth = max(0, width - labelWidth)

        if isSelected, overlay.editingField == field {
            // The inline editor row (`:453-466`): text plus the port's
            // block-cursor glyph — the search row's stand-in for
            // upstream's inverted cursor cell; the append-only editor
            // keeps the cursor at the end.
            var spans = [PagerStyledSpan(
                text: overlay.editingText,
                foreground: theme.textPrimary
            )]
            spans.append(PagerStyledSpan(text: "\u{258F}", foreground: theme.textPrimary))
            paintSpans(
                &buffer,
                spans: truncateSpans(spans, to: valueWidth),
                x: valueX, y: y, limit: area.right, background: rowBackground
            )
        } else if field == .instructions {
            y = drawDetailInstructions(
                overlay,
                value: value,
                in: area,
                y: y,
                valueX: valueX,
                valueWidth: valueWidth,
                rowBackground: rowBackground,
                maxY: maxY,
                buffer: &buffer,
                theme: theme
            )
        } else if value.isEmpty {
            // `:558-564`.
            _ = buffer.setString(
                x: valueX, y: y, text: "\u{2014}",
                style: [], foreground: theme.grayDim, background: rowBackground
            )
        } else {
            // One line when it fits, word-wrapped below otherwise
            // (`:565-593`).
            let lines = personaDetailWordWrap(value, maxWidth: valueWidth)
            for (index, line) in lines.enumerated() {
                guard y + index < maxY else { break }
                _ = buffer.setString(
                    x: valueX, y: y + index,
                    text: truncateToWidth(line, width: valueWidth),
                    style: [], foreground: theme.textPrimary,
                    background: index == 0 ? rowBackground : theme.bgBase
                )
            }
            y += max(0, lines.count - 1)
        }
        y += 2 // spacing between fields (`:595`)
    }

    // Inputs/Outputs (`:599-653`).
    for (section, items) in [("Inputs", overlay.inputs), ("Outputs", overlay.outputs)] {
        guard !items.isEmpty, y < maxY else { continue }
        _ = buffer.setString(
            x: area.x, y: y,
            text: truncateToWidth(section, width: width),
            style: [.bold], foreground: theme.textPrimary, background: theme.bgBase
        )
        y += 1
        for entry in items {
            guard y < maxY else { break }
            let requiredSuffix = entry.required ? ", required" : ""
            let header = "  \u{2022} \(entry.name) (\(entry.ioType)\(requiredSuffix))"
            _ = buffer.setString(
                x: area.x, y: y,
                text: truncateToWidth(header, width: width),
                style: [.bold], foreground: theme.textPrimary, background: theme.bgBase
            )
            if !entry.description.isEmpty {
                let indent = 4
                let descriptionWidth = max(0, width - indent)
                if descriptionWidth > 0 {
                    y += 1
                    for line in personaDetailWordWrap(
                        entry.description, maxWidth: descriptionWidth
                    ) {
                        guard y < maxY else { break }
                        _ = buffer.setString(
                            x: area.x + indent, y: y,
                            text: truncateToWidth(line, width: descriptionWidth),
                            style: [], foreground: theme.textSecondary,
                            background: theme.bgBase
                        )
                        y += 1
                    }
                } else {
                    y += 1
                }
            } else {
                y += 1
            }
        }
        y += 1
    }

    // `Source: {path}` (`:655-667`), char-truncated like upstream's
    // `chars().take(w)`.
    if y < maxY, let path = overlay.sourcePath {
        _ = buffer.setString(
            x: area.x, y: y,
            text: String("Source: \(path)".prefix(width)),
            style: [], foreground: theme.grayDim, background: theme.bgBase
        )
    }
}

/// The multi-line instructions block (`:467-557`). Returns the y of the
/// LAST painted row of the block (the caller adds the shared `+= 2`).
private func drawDetailInstructions(
    _ overlay: PagerPersonaDetailOverlay,
    value: String,
    in area: TerminalRect,
    y: Int,
    valueX: Int,
    valueWidth: Int,
    rowBackground: TerminalColor,
    maxY: Int,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) -> Int {
    var y = y
    if value.isEmpty {
        _ = buffer.setString(
            x: valueX, y: y, text: "(empty)",
            style: [], foreground: theme.grayDim, background: rowBackground
        )
        return y
    }
    let lines = personaDetailWordWrap(value, maxWidth: valueWidth)
    let total = lines.count
    let maxCollapsed = PagerPersonaDetailMetrics.collapsedInstructionLines
    let isLong = total > maxCollapsed
    let availableLines = max(0, maxY - y)
    let viewportHeight = isLong ? max(0, availableLines - 1) : availableLines

    if !overlay.instructionsExpanded {
        let show = min(total, maxCollapsed, viewportHeight)
        for (index, line) in lines.prefix(show).enumerated() {
            let x = index == 0 ? valueX : area.x + 2
            _ = buffer.setString(
                x: x, y: y + index,
                text: truncateToWidth(line, width: max(0, area.right - x)),
                style: [], foreground: theme.textSecondary,
                background: index == 0 ? rowBackground : theme.bgBase
            )
        }
        y += max(0, show - 1)
        if isLong {
            y += 1
            if y < maxY {
                let hint = "  ... (\(total - maxCollapsed) more lines \u{2014} "
                    + "e to expand, j/k to scroll)"
                _ = buffer.setString(
                    x: area.x + 2, y: y,
                    text: truncateToWidth(hint, width: max(0, area.width - 2)),
                    style: [], foreground: theme.grayDim, background: theme.bgBase
                )
            }
        }
        return y
    }

    // Expanded: viewport with the stored scroll clamped to the wrapped
    // total (`:519-534`; upstream clamps the stored value in place, this
    // painter clamps per frame).
    let scroll = min(overlay.instructionsScroll, max(0, total - viewportHeight))
    let visible = Array(lines[scroll..<min(total, scroll + viewportHeight)])
    for (index, line) in visible.enumerated() {
        let x = (index == 0 && scroll == 0) ? valueX : area.x + 2
        _ = buffer.setString(
            x: x, y: y + index,
            text: truncateToWidth(line, width: max(0, area.right - x)),
            style: [], foreground: theme.textSecondary,
            background: (index == 0 && scroll == 0) ? rowBackground : theme.bgBase
        )
    }
    y += max(0, visible.count - 1)
    y += 1
    if y < maxY {
        let positionHint: String
        if total > viewportHeight {
            positionHint = " [\(scroll + 1)\u{2013}\(min(scroll + viewportHeight, total))/ \(total)]"
        } else {
            positionHint = ""
        }
        let hint = "  (e to collapse, j/k to scroll\(positionHint))"
        _ = buffer.setString(
            x: area.x + 2, y: y,
            text: truncateToWidth(hint, width: max(0, area.width - 2)),
            style: [], foreground: theme.grayDim, background: theme.bgBase
        )
    }
    return y
}

// MARK: - Footer

/// `build_shortcuts` (`persona_detail.rs:683-724`): editing shows only
/// save/cancel; browse advertises `e edit field` and `i $EDITOR` only
/// when their backings exist.
func pagerPersonaDetailHints(_ overlay: PagerPersonaDetailOverlay) -> [PagerOverlayHint] {
    if overlay.isEditing {
        return [
            PagerOverlayHint(key: "Enter", label: "save"),
            PagerOverlayHint(key: "Esc", label: "cancel")
        ]
    }
    var hints = [PagerOverlayHint(key: "j/k", label: "nav")]
    if overlay.editable {
        hints.append(PagerOverlayHint(key: "e", label: "edit field"))
    }
    if overlay.sourcePath != nil, overlay.editable {
        hints.append(PagerOverlayHint(key: "i", label: "$EDITOR"))
    }
    hints.append(PagerOverlayHint(key: "Esc", label: "back"))
    return hints
}
