// PagerExecuteRender.swift
//
// Execute tool painter — description-first headers, `$ command` panel,
// ANSI-aware 2+3 truncation, rail/fold semantics.
//
// Port of `xai-grok-pager/src/scrollback/blocks/tool/execute.rs` at pin
// 650c1db7: header_display/description_display (:140-220), header_lines
// (:355-430), push_header_lines (:432-530), render_with_truncation
// (:532-650), BlockContent impl (:652-780). The terminal-output VTE
// (`xai-grok-pager-render/src/render/terminal_output.rs`) uses the existing
// `OpenGrokTerminalCore.splitIntoLineSegments` VTE boundary, then decodes SGR
// into styled spans while applying CR overwrite semantics before wrapping.

import Foundation
import OpenGrokTerminalCore

// MARK: - Execute painter entry

func appendExecuteCard(
    _ tool: PagerToolCard,
    width: Int,
    theme: PagerRenderTheme,
    motion: PagerMotionSnapshot,
    waveRows: Int = PagerMotion.defaultWaveRows,
    unboundedPreview: Bool = false,
    into lines: inout [PaintLine]
) {
    let accent = pagerToolAccent(tool, theme: theme)
    let isFlashing = motion.enabled
        && tool.state != .running && tool.state != .pending
        && tool.finishedAt.map { PagerMotion.isFlashing(finishedAt: $0, now: motion.seconds) } == true
    // Execute keeps its rail even when collapsed (Read does not) — backlog B1.
    // Muted still dims the label/command colors, but the accent bar remains.
    let muted = !tool.isExpanded && !isFlashing
    let labelColor = muted ? theme.gray : theme.textPrimary

    func railAccent(row: Int) -> TerminalColor {
        guard tool.state == .running else { return accent }
        return PagerMotion.runningAccentColor(
            theme: theme,
            accent: accent,
            tick: motion.tick,
            row: row,
            waveRows: waveRows,
            motionEnabled: motion.enabled
        )
    }

    let blockOrigin = lines.count
    // Header: description-first, then `$ command` when expanded.
    let headerRows = executeHeaderRows(
        tool: tool,
        width: width,
        theme: theme,
        muted: muted,
        labelColor: labelColor,
        accent: accent
    )
    for (index, row) in headerRows.enumerated() {
        let isFirst = index == 0 && lines.count == blockOrigin
        lines.append(PaintLine(
            spans: row,
            foreground: labelColor,
            accentGlyph: PagerGlyphs.accentBar,
            accentColor: railAccent(row: lines.count),
            selection: PaintLineSelectionSeed(
                rangeID: 0,
                blockLineIndex: lines.count - blockOrigin,
                text: pagerTrimEndDisplay(row.map(\.text).joined()),
                selectableColStart: 0,
                joinerToPrevious: isFirst ? nil : " "
            )
        ))
    }

    // Body: ANSI-aware dark panel with 2+3 head/tail truncation.
    guard tool.isExpanded else { return }
    guard let rawOutput = tool.output, !rawOutput.isEmpty else {
        // No output: if there's an error string inside output, painter would
        // show it via the panel. For now keep header-only when empty.
        return
    }
    // Blank separator (non-selectable, but keeps rail continuity).
    lines.append(PaintLine(
        "",
        foreground: theme.gray,
        accentGlyph: PagerGlyphs.accentBar,
        accentColor: railAccent(row: lines.count)
    ))

    let panelWidth = max(1, width - 2)
    let styledWrapped = executeStyledWrappedOutput(rawOutput, panelWidth: panelWidth)
    let head = PagerLayoutMetrics.executePreviewFirstLines
    let tail = PagerLayoutMetrics.executePreviewLastLines
    let previewColor: TerminalColor = tool.state == .failed ? theme.accentError : theme.textPrimary
    let bg = theme.bgDark

    // Truncated mode uses the 2+3 preview. Minimal committed Expanded passes
    // `unboundedPreview`, because its display-mode contract paints the whole
    // output and lets the commit-height cap add any overflow footer.
    let rowsForPanel: [[PagerStyledSpan]] = {
        if !(unboundedPreview || tool.isFullyExpanded), styledWrapped.count > head + tail + 1 {
            let hidden = styledWrapped.count - head - tail
            var out: [[PagerStyledSpan]] = []
            out.append(contentsOf: styledWrapped.prefix(head))
            out.append([PagerStyledSpan(
                text: "\(PagerGlyphs.ellipsis) +\(hidden) lines",
                foreground: theme.grayDim
            )])
            out.append(contentsOf: styledWrapped.suffix(tail))
            return out
        } else {
            return styledWrapped
        }
    }()

    var isFirstOutput = true
    for row in rowsForPanel {
        let text = row.map(\.text).joined()
        let isMarker = text.hasPrefix(PagerGlyphs.ellipsis)
        var spans = [PagerStyledSpan(text: "  ", foreground: previewColor)]
        spans.append(contentsOf: row)
        lines.append(PaintLine(
            spans: spans,
            foreground: isMarker ? theme.grayDim : previewColor,
            accentGlyph: PagerGlyphs.accentBar,
            accentColor: railAccent(row: lines.count),
            background: bg,
            selection: PaintLineSelectionSeed(
                rangeID: 1,
                blockLineIndex: lines.count - blockOrigin,
                text: text,
                selectableColStart: 2,
                joinerToPrevious: isFirstOutput ? nil : "\n"
            )
        ))
        isFirstOutput = false
    }
}

// MARK: - Header construction (Label style, description-first)

private func executeHeaderRows(
    tool: PagerToolCard,
    width: Int,
    theme: PagerRenderTheme,
    muted: Bool,
    labelColor: TerminalColor,
    accent: TerminalColor
) -> [[PagerStyledSpan]] {
    let descRaw = tool.executeDescription
    let cmdRaw = tool.executeHeaderDisplay ?? tool.executeCommand ?? tool.input
    let displayDesc: String? = {
        guard let d = descRaw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !d.isEmpty else { return nil }
        let flat = d.replacingOccurrences(of: "\n", with: " ")
        let stripped = stripLeadingRunWord(flat)
        let trimmed = stripped.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }()

    let isBash = tool.isBashMode == true
    let commandText: String = {
        let t = cmdRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "…" }
        return t.replacingOccurrences(of: "\n", with: " ")
    }()

    var logicalRows: [[PagerStyledSpan]] = []

    if let desc = displayDesc {
        // Title row: "Run [(user) ]<desc>"
        var title: [PagerStyledSpan] = [
            PagerStyledSpan(text: PagerGlyphs.toolBullet + " ", foreground: accent)
        ]
        title.append(PagerStyledSpan(text: "Run ", foreground: labelColor, style: [.bold]))
        if isBash {
            title.append(PagerStyledSpan(text: "(user) ", foreground: theme.gray))
        }
        title.append(PagerStyledSpan(text: desc, foreground: labelColor))
        logicalRows.append(title)

        // Expanded second row: "$ <command>"
        if tool.isExpanded {
            let cmdSpans: [PagerStyledSpan] = [
                PagerStyledSpan(text: "$ ", foreground: theme.grayDim),
                PagerStyledSpan(text: commandText, foreground: muted ? theme.gray : theme.command)
            ]
            logicalRows.append(cmdSpans)
        }
    } else {
        // No description: single row "Run [(user) ]<command>"
        var row: [PagerStyledSpan] = [
            PagerStyledSpan(text: PagerGlyphs.toolBullet + " ", foreground: accent)
        ]
        row.append(PagerStyledSpan(text: "Run ", foreground: labelColor, style: [.bold]))
        if isBash {
            row.append(PagerStyledSpan(text: "(user) ", foreground: theme.gray))
        }
        row.append(PagerStyledSpan(text: commandText, foreground: muted ? theme.gray : theme.command))
        logicalRows.append(row)
    }

    // Wrap each logical row with hanging width awareness. For the
    // "$ command" row the hang is the "$ " prefix (2 cols); for the
    // title row the hang is "Run " (+ "(user) ") width. We reuse
    // `wrapStyledSpans` which is grapheme-wise and ANSI-free (headers
    // have no escapes).
    var wrapped: [[PagerStyledSpan]] = []
    for row in logicalRows {
        let rows = wrapStyledSpans(row, width: max(1, width))
        wrapped.append(contentsOf: rows)
    }
    return wrapped
}

private func stripLeadingRunWord(_ s: String) -> String {
    let lower = s.lowercased()
    if lower.hasPrefix("running") {
        let rest = String(lower.dropFirst(7))
        if rest.isEmpty { return "" }
        if rest.first?.isWhitespace == true {
            return String(s.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
    }
    if lower.hasPrefix("run") {
        let rest = String(lower.dropFirst(3))
        if rest.isEmpty { return "" }
        if rest.first?.isWhitespace == true {
            return String(s.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
    }
    return s
}

// MARK: - ANSI/CR-aware output wrapping

/// ANSI-aware, CR-collapsed plain output wrapped to `panelWidth`.
///
/// 1. Strip ANSI escapes (zero-width).
/// 2. Split on LF (hard breaks), then per line collapse bare CR overwrites
///    (`aaaa\rbb` → `bbaa`) so progress bars show their final state.
/// 3. Wrap each collapsed line with `wrapDisplayLines` (display-width aware).
func executeWrappedOutput(_ raw: String, panelWidth: Int) -> [String] {
    executeStyledWrappedOutput(raw, panelWidth: panelWidth).map { $0.map(\.text).joined() }
}

private struct ExecuteSGRState: Equatable {
    var foreground: TerminalColor?
    var background: TerminalColor?
    var style: CellStyle = []
}

private struct ExecuteStyledCell {
    var text: String
    var state: ExecuteSGRState
}

func executeStyledWrappedOutput(_ raw: String, panelWidth: Int) -> [[PagerStyledSpan]] {
    let segments = splitIntoLineSegments(raw, termWidth: Int.max)
    var state = ExecuteSGRState()
    var rows: [[PagerStyledSpan]] = []
    for segment in segments {
        let cells = executeStyledCells(segment.content, state: &state)
        let spans = executeSpans(from: cells)
        rows.append(contentsOf: wrapStyledSpans(spans, width: max(1, panelWidth)))
    }
    if rows.isEmpty, !raw.isEmpty { return [[]] }
    return rows
}

private func executeStyledCells(
    _ text: String,
    state: inout ExecuteSGRState
) -> [ExecuteStyledCell] {
    var cells: [ExecuteStyledCell] = []
    var cursor = 0
    var index = text.startIndex
    while index < text.endIndex {
        let character = text[index]
        if character == "\u{1B}" {
            index = consumeExecuteEscape(text, from: index, state: &state)
            continue
        }
        index = text.index(after: index)
        if character == "\r" {
            cursor = 0
            continue
        }
        let cell = ExecuteStyledCell(text: String(character), state: state)
        if cursor < cells.count {
            cells[cursor] = cell
        } else {
            cells.append(cell)
        }
        cursor += 1
    }
    return cells
}

private func consumeExecuteEscape(
    _ text: String,
    from escape: String.Index,
    state: inout ExecuteSGRState
) -> String.Index {
    var index = text.index(after: escape)
    guard index < text.endIndex else { return index }
    if text[index] == "[" {
        index = text.index(after: index)
        let paramsStart = index
        while index < text.endIndex {
            guard let scalar = text[index].unicodeScalars.first else {
                index = text.index(after: index)
                continue
            }
            if scalar.value >= 0x40 && scalar.value <= 0x7E {
                if text[index] == "m" {
                    let rawParams = String(text[paramsStart..<index])
                    applyExecuteSGR(rawParams, state: &state)
                }
                return text.index(after: index)
            }
            index = text.index(after: index)
        }
        return index
    }
    if text[index] == "]" {
        index = text.index(after: index)
        while index < text.endIndex {
            if text[index] == "\u{7}" { return text.index(after: index) }
            if text[index] == "\u{1B}" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "\\" {
                    return text.index(after: next)
                }
            }
            index = text.index(after: index)
        }
        return index
    }
    return text.index(after: index)
}

private func applyExecuteSGR(_ raw: String, state: inout ExecuteSGRState) {
    let params = raw.isEmpty ? [0] : raw.split(separator: ";", omittingEmptySubsequences: false).map {
        Int($0) ?? 0
    }
    var index = 0
    while index < params.count {
        let code = params[index]
        switch code {
        case 0: state = ExecuteSGRState()
        case 1: state.style.insert(.bold)
        case 2: state.style.insert(.dim)
        case 3: state.style.insert(.italic)
        case 4: state.style.insert(.underline)
        case 5: state.style.insert(.blink)
        case 7: state.style.insert(.reverse)
        case 8: state.style.insert(.hidden)
        case 9: state.style.insert(.strike)
        case 22:
            state.style.remove(.bold)
            state.style.remove(.dim)
        case 23: state.style.remove(.italic)
        case 24: state.style.remove(.underline)
        case 25: state.style.remove(.blink)
        case 27: state.style.remove(.reverse)
        case 28: state.style.remove(.hidden)
        case 29: state.style.remove(.strike)
        case 30...37: state.foreground = executeBasicColor(code - 30, bright: false)
        case 39: state.foreground = nil
        case 40...47: state.background = executeBasicColor(code - 40, bright: false)
        case 49: state.background = nil
        case 90...97: state.foreground = executeBasicColor(code - 90, bright: true)
        case 100...107: state.background = executeBasicColor(code - 100, bright: true)
        case 38, 48:
            let isForeground = code == 38
            if index + 2 < params.count, params[index + 1] == 5,
               let color = UInt8(exactly: params[index + 2]) {
                if isForeground { state.foreground = .indexed(color) }
                else { state.background = .indexed(color) }
                index += 2
            } else if index + 4 < params.count, params[index + 1] == 2,
                      let red = UInt8(exactly: params[index + 2]),
                      let green = UInt8(exactly: params[index + 3]),
                      let blue = UInt8(exactly: params[index + 4]) {
                if isForeground { state.foreground = .rgb(red, green, blue) }
                else { state.background = .rgb(red, green, blue) }
                index += 4
            }
        default: break
        }
        index += 1
    }
}

private func executeBasicColor(_ value: Int, bright: Bool) -> TerminalColor {
    let normal: [TerminalColor] = [.black, .red, .green, .yellow, .blue, .magenta, .cyan, .white]
    let brightColors: [TerminalColor] = [
        .brightBlack, .brightRed, .brightGreen, .brightYellow,
        .brightBlue, .brightMagenta, .brightCyan, .brightWhite
    ]
    return (bright ? brightColors : normal)[max(0, min(7, value))]
}

private func executeSpans(from cells: [ExecuteStyledCell]) -> [PagerStyledSpan] {
    guard !cells.isEmpty else { return [PagerStyledSpan(text: "")] }
    var spans: [PagerStyledSpan] = []
    for cell in cells {
        if let last = spans.indices.last,
           spans[last].foreground == cell.state.foreground,
           spans[last].background == cell.state.background,
           spans[last].style == cell.state.style {
            spans[last].text += cell.text
        } else {
            spans.append(PagerStyledSpan(
                text: cell.text,
                foreground: cell.state.foreground,
                style: cell.state.style,
                background: cell.state.background
            ))
        }
    }
    return spans
}

/// Collapse bare CR (`\r`) overwrites inside a single line (no LF).
///
/// Mirrors `xai-grok-pager-render/src/render/terminal_output.rs` CR handling:
/// `\r` resets the column to 0 and subsequent characters overwrite in place.
/// Wide graphemes are treated as width 1 for the overwrite index (display
/// width is handled later by `wrapDisplayLines`), which is sufficient for
/// the ASCII progress-bar case the backlog pins.
func collapseCarriageReturn(_ line: String) -> String {
    // Work on Unicode scalars so a single CRLF Character (which contains both
    // 0x0D and 0x0A scalars) is not mis-handled — but this function is called
    // per LF-split piece, so LF scalars are not present; only bare CR remains.
    var buffer: [Unicode.Scalar] = []
    var col = 0
    for scalar in line.unicodeScalars {
        if scalar.value == 13 { // CR
            col = 0
            continue
        }
        if col < buffer.count {
            buffer[col] = scalar
        } else {
            while buffer.count < col {
                buffer.append(Unicode.Scalar(32)!)
            }
            buffer.append(scalar)
        }
        col += 1
    }
    // Convert scalars back to String. Scalars that form multi-scalar
    // graphemes (e.g., emoji) survive as separate scalars; the wrap pass
    // will measure grapheme width correctly via `UnicodeDisplayWidth` on the
    // reconstituted String's Characters.
    return String(String.UnicodeScalarView(buffer))
}
