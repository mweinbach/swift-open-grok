// PagerEditRender.swift
//
// Edit / create painter — hunks, separators, gutters, wrap-stable
// insertion/deletion backgrounds, no on-screen `@@`/`+/-`, trusted
// counts, `Creating` prefix, and unified-patch copy.
//
// Port of `xai-grok-pager/src/scrollback/blocks/tool/edit.rs` at pin
// 650c1db7: header_line (:838-920), wrap_edit_header (edit.rs wrap
// helpers), render_diff_hunks_core with DiffRenderConfig (:200-550),
// gutter_layout/render_gutter, assemble_diff_line_outputs (BG + wrap),
// hunk separators (`… N unchanged lines`), and BlockContent output/
// rendered_output (:1050-1250), plus the file-scoped highlight worker's
// semantic spans. Highlight foregrounds are layered over, never instead of,
// the insertion/deletion background bands.

import Foundation
import OpenGrokTerminalCore

// MARK: - Entry

func appendEditCard(
    _ tool: PagerToolCard,
    width: Int,
    theme: PagerRenderTheme,
    motion: PagerMotionSnapshot,
    waveRows: Int = PagerMotion.defaultWaveRows,
    into lines: inout [PaintLine]
) {
    let accent = pagerToolAccent(tool, theme: theme)
    let isFlashing = motion.enabled
        && tool.state != .running && tool.state != .pending
        && tool.finishedAt.map { PagerMotion.isFlashing(finishedAt: $0, now: motion.seconds) } == true
    let muted = !tool.isExpanded && !isFlashing
    let labelColor = muted ? theme.gray : theme.textPrimary
    let detailColor = theme.grayDim // collapsed diffstat even when muted keeps insert/delete FG on the counts below

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
    let isCreating = tool.kind == .create
    // Collapsed suffix: trusted +N/-N or (N edits) or detail fallback.
    let headerDetail: String? = {
        if !tool.isExpanded {
            if tool.editHunks != nil || tool.editCount != nil || tool.editLinesAdded != nil {
                return tool.editDetailForHeader
            }
            return tool.detail
        }
        // Legacy/running cards without structured hunks still use `detail`
        // for live status updates. Keep that text visible until typed diff
        // payloads arrive; structured expanded cards render the body instead.
        return tool.editHunks == nil ? tool.detail : nil
    }()

    let headerRows = editHeaderRows(
        tool: tool,
        isCreating: isCreating,
        width: width,
        muted: muted,
        labelColor: labelColor,
        detailColor: detailColor,
        theme: theme,
        collapsedDetail: headerDetail
    )
    let accentGlyph: String? = muted ? nil : PagerGlyphs.accentBar
    for (index, row) in headerRows.enumerated() {
        lines.append(PaintLine(
            spans: row,
            foreground: labelColor,
            accentGlyph: index == 0 || accentGlyph != nil ? accentGlyph : nil,
            accentColor: railAccent(row: lines.count),
            selection: PaintLineSelectionSeed(
                rangeID: 0,
                blockLineIndex: lines.count - blockOrigin,
                text: pagerTrimEndDisplay(row.map(\.text).joined()),
                selectableColStart: 0,
                joinerToPrevious: index == 0 ? nil : " "
            )
        ))
    }

    guard tool.isExpanded else { return }
    let editFiles: [PagerEditFile] = {
        if let files = tool.editFiles, !files.isEmpty { return files }
        if let hunks = tool.editHunks, !hunks.isEmpty {
            return [PagerEditFile(
                path: tool.editPath ?? (tool.input.isEmpty ? "file" : tool.input),
                hunks: hunks,
                isNewFile: tool.isNewFileForEdit ?? false
            )]
        }
        return []
    }()
    guard !editFiles.isEmpty else {
        // Legacy / error card without hunks: fall back to existing gray
        // preview so the card still shows something when expanded. No `@@`
        // is emitted here; if output exists show it as generic preview.
        if let output = tool.output, !output.isEmpty {
            lines.append(PaintLine("", foreground: theme.gray,
                                    accentGlyph: PagerGlyphs.accentBar,
                                    accentColor: railAccent(row: lines.count)))
            let preview = toolPreviewRows(output, width: max(1, width - 2), theme: theme, unbounded: false)
            for row in preview {
                lines.append(PaintLine(
                    spans: [PagerStyledSpan(text: "  " + row.text, foreground: theme.gray)],
                    foreground: theme.gray,
                    accentGlyph: PagerGlyphs.accentBar,
                    accentColor: railAccent(row: lines.count),
                    selection: PaintLineSelectionSeed(rangeID: 1, blockLineIndex: lines.count - blockOrigin, text: row.text, selectableColStart: 2, joinerToPrevious: "\n")
                ))
            }
        }
        return
    }

    // Separator blank row before diff content (non-selectable).
    lines.append(PaintLine("", foreground: theme.gray,
                            accentGlyph: PagerGlyphs.accentBar,
                            accentColor: railAccent(row: lines.count)))

    var nextRangeID: UInt16 = 1
    for (fileIndex, file) in editFiles.enumerated() {
        if editFiles.count > 1 {
            if fileIndex > 0 {
                lines.append(PaintLine(
                    "",
                    foreground: theme.gray,
                    accentGlyph: PagerGlyphs.accentBar,
                    accentColor: railAccent(row: lines.count)
                ))
            }
            lines.append(PaintLine(
                spans: [
                    PagerStyledSpan(text: "  "),
                    PagerStyledSpan(text: file.path, foreground: theme.path, style: [.bold])
                ],
                foreground: theme.path,
                accentGlyph: PagerGlyphs.accentBar,
                accentColor: railAccent(row: lines.count),
                selection: PaintLineSelectionSeed(
                    rangeID: nextRangeID,
                    blockLineIndex: lines.count - blockOrigin,
                    text: file.path,
                    selectableColStart: 2,
                    joinerToPrevious: nil
                )
            ))
            nextRangeID &+= 1
        }
        let stitched = stitchOverlappingHunks(file.hunks)
        let diffRows = editDiffRows(
            hunks: stitched,
            highlights: file.highlights,
            width: width,
            theme: theme,
            nextRangeID: &nextRangeID
        )
        for row in diffRows {
            if row.isSeparator {
                lines.append(PaintLine(
                    spans: row.spans,
                    foreground: theme.grayDim,
                    accentGlyph: PagerGlyphs.accentBar,
                    accentColor: railAccent(row: lines.count)
                ))
            } else {
                lines.append(PaintLine(
                    spans: row.spans,
                    foreground: row.foreground,
                    accentGlyph: PagerGlyphs.accentBar,
                    accentColor: railAccent(row: lines.count),
                    background: row.background,
                    selection: PaintLineSelectionSeed(
                        rangeID: row.rangeID,
                        blockLineIndex: lines.count - blockOrigin,
                        text: row.selectableText,
                        selectableColStart: row.selectableColStart,
                        joinerToPrevious: row.joiner
                    )
                ))
            }
        }
    }
}

// MARK: - Header (Edit / Creating) — path elision, collapsed suffix

private func editHeaderRows(
    tool: PagerToolCard,
    isCreating: Bool,
    width: Int,
    muted: Bool,
    labelColor: TerminalColor,
    detailColor: TerminalColor,
    theme: PagerRenderTheme,
    collapsedDetail: String?
) -> [[PagerStyledSpan]] {
    let prefix = isCreating ? "Creating " : "Edit "
    let pathText: String = {
        guard let files = tool.editFiles, files.count > 1 else {
            return tool.editPath ?? tool.input
        }
        return "\(files.count) files"
    }()
    let pathColor: TerminalColor = muted ? theme.gray : theme.path

    // Detail suffix for collapsed only. When it is the trusted +N/-N form,
    // split the slashes and apply diff FG to the counts (edit.rs header_line).
    var detailSpans: [PagerStyledSpan] = []
    if let d = collapsedDetail, !d.isEmpty {
        let t = d.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("+"), t.contains("/-") {
            // "+a/-b"
            let parts = t.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if parts.count == 2 {
                detailSpans.append(PagerStyledSpan(text: " " + parts[0], foreground: theme.diffInsertForeground))
                detailSpans.append(PagerStyledSpan(text: "/", foreground: detailColor))
                detailSpans.append(PagerStyledSpan(text: parts[1], foreground: theme.diffDeleteForeground))
            } else {
                detailSpans.append(PagerStyledSpan(text: " " + t, foreground: detailColor))
            }
        } else {
            detailSpans.append(PagerStyledSpan(text: " " + t, foreground: detailColor))
        }
    }

    let header: [PagerStyledSpan] = {
        var spans: [PagerStyledSpan] = [
            PagerStyledSpan(text: prefix, foreground: labelColor, style: [.bold]),
            PagerStyledSpan(text: pathText, foreground: pathColor)
        ]
        spans.append(contentsOf: detailSpans)
        return spans
    }()

    // Word-wrap with indent on the prefix so continuations align under
    // the path body (wrap_edit_header parity). We approximate with
    // `wrapStyledSpans` and prefix indent via leading spaces in wrap rows.
    // For simplicity, when single-row we return one row; multi-row wrapping
    // uses the prefix width as indent (edit.rs `total_indent = extra + prefix_width`).
    let prefixWidth = UnicodeDisplayWidth.width(of: prefix)
    let contentWidth = max(1, width)
    let wrapped = wrapStyledSpans(header, width: contentWidth)
    guard wrapped.count > 1 else { return wrapped }
    // Add hanging indent to continuation rows (edit.rs `indent`).
    var out = wrapped
    let indent = String(repeating: " ", count: prefixWidth)
    for i in 1..<out.count {
        out[i].insert(PagerStyledSpan(text: indent), at: 0)
    }
    return out
}

// MARK: - Diff rows (gutter + wrap-stable background)

private struct EditDiffRow {
    var spans: [PagerStyledSpan]
    var foreground: TerminalColor
    var background: TerminalColor?
    var selectableText: String
    var selectableColStart: Int
    var joiner: String?
    var rangeID: UInt16
    var isSeparator: Bool
}

private func editDiffRows(
    hunks: [DiffHunk],
    highlights: [PagerEditLineHighlight],
    width: Int,
    theme: PagerRenderTheme,
    nextRangeID: inout UInt16
) -> [EditDiffRow] {
    guard !hunks.isEmpty else { return [] }
    let indent = "  " // INDENT from edit.rs
    let contentGap = "  "
    // Compute max line number for gutter width (single column).
    var maxNum = 1
    for hunk in hunks {
        for line in hunk {
            maxNum = max(maxNum, line.lo)
            maxNum = max(maxNum, line.ln)
        }
    }
    let gutterWidth = String(maxNum).count
    // Gutter + gap: indent + number column + gap
    let gutterTotal = indent.count + gutterWidth + contentGap.count
    let contentWidth = max(1, width - gutterTotal)
    // Wrap budget is per content column; gutter is not counted again.

    var rows: [EditDiffRow] = []
    let highlightByLine = Dictionary(uniqueKeysWithValues: highlights.map { ($0.lineNumber, $0.spans) })

    for (hunkIndex, hunk) in hunks.enumerated() {
        if hunkIndex > 0 {
            let gap = hunkGapLinesText(prev: hunks[hunkIndex - 1], next: hunk)
            let text = gap ?? "…"
            rows.append(EditDiffRow(
                spans: [
                    PagerStyledSpan(text: indent),
                    PagerStyledSpan(text: text, foreground: theme.gray)
                ],
                foreground: theme.gray,
                background: nil,
                selectableText: "",
                selectableColStart: 0,
                joiner: nil,
                rangeID: nextRangeID,
                isSeparator: true
            ))
            nextRangeID &+= 1
        }
        for line in hunk {
            let bg: TerminalColor? = {
                switch line.tag {
                case .equal: return nil
                case .delete: return theme.diffDeleteBackground
                case .insert: return theme.diffInsertBackground
                }
            }()
            let fg: TerminalColor = {
                switch line.tag {
                case .equal: return theme.diffEqualForeground
                case .delete: return theme.diffDeleteForeground
                case .insert: return theme.diffInsertForeground
                }
            }()
            let gutter: String = {
                switch line.tag {
                case .equal:
                    return String(format: "%\(gutterWidth)d", line.ln)
                case .delete:
                    return String(format: "%\(gutterWidth)d", line.lo)
                case .insert:
                    return String(format: "%\(gutterWidth)d", line.ln)
                }
            }()
            // Gutter spans: indent + number (dim) + gap
            let gutterSpans = [
                PagerStyledSpan(text: indent),
                PagerStyledSpan(text: gutter, foreground: theme.diffGutterForeground),
                PagerStyledSpan(text: contentGap)
            ]
            let gutterColCount = indent.count + gutterWidth + contentGap.count
            let contentText = line.text.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
            let semantic = line.tag == .delete ? nil : highlightByLine[line.ln]
            let contentSpans = editHighlightedSpans(
                contentText,
                highlights: semantic ?? [],
                defaultForeground: fg,
                theme: theme
            )
            let wrappedContents = wrapStyledSpans(contentSpans, width: contentWidth)
            for (wrapIndex, content) in wrappedContents.enumerated() {
                let isFirstWrap = wrapIndex == 0
                var spans: [PagerStyledSpan] = []
                if isFirstWrap {
                    spans.append(contentsOf: gutterSpans)
                } else {
                    // Continuation keeps gutter width as spaces so BG band
                    // aligns and the eye tracks the gutter column.
                    spans.append(PagerStyledSpan(text: String(repeating: " ", count: gutterColCount)))
                }
                spans.append(contentsOf: content)
                let selectable = content.map(\.text).joined()
                rows.append(EditDiffRow(
                    spans: spans,
                    foreground: fg,
                    background: bg,
                    selectableText: selectable,
                    selectableColStart: gutterColCount,
                    joiner: isFirstWrap ? nil : "",
                    rangeID: nextRangeID,
                    isSeparator: false
                ))
            }
        }
        nextRangeID &+= 1
    }
    return rows
}

private func editHighlightedSpans(
    _ text: String,
    highlights: [PagerEditHighlightSpan],
    defaultForeground: TerminalColor,
    theme: PagerRenderTheme
) -> [PagerStyledSpan] {
    let characters = Array(text)
    guard !characters.isEmpty, !highlights.isEmpty else {
        return [PagerStyledSpan(text: text, foreground: defaultForeground)]
    }
    let sorted = highlights
        .filter { $0.length > 0 && $0.start < characters.count }
        .sorted { lhs, rhs in lhs.start == rhs.start ? lhs.length < rhs.length : lhs.start < rhs.start }
    guard !sorted.isEmpty else {
        return [PagerStyledSpan(text: text, foreground: defaultForeground)]
    }

    func color(for kind: PagerEditHighlightKind) -> TerminalColor {
        switch kind {
        case .comment: return theme.gray
        case .string: return theme.accentSuccess
        case .number: return theme.accentVerify
        case .keyword: return theme.accentModel
        case .type: return theme.path
        }
    }

    var result: [PagerStyledSpan] = []
    var cursor = 0
    for highlight in sorted {
        let start = max(cursor, max(0, highlight.start))
        let end = min(characters.count, max(start, highlight.start + highlight.length))
        guard start < end else { continue }
        if cursor < start {
            result.append(PagerStyledSpan(
                text: String(characters[cursor..<start]),
                foreground: defaultForeground
            ))
        }
        result.append(PagerStyledSpan(
            text: String(characters[start..<end]),
            foreground: color(for: highlight.kind)
        ))
        cursor = end
    }
    if cursor < characters.count {
        result.append(PagerStyledSpan(
            text: String(characters[cursor...]),
            foreground: defaultForeground
        ))
    }
    return result
}

private func hunkGapLinesText(prev: DiffHunk, next: DiffHunk) -> String? {
    // Use ln (post-state) borders; mirror edit.rs hunk_gap_lines.
    guard let prevLast = prev.reversed().first(where: { $0.tag != .delete })?.ln,
          let nextFirst = next.first(where: { $0.tag != .delete })?.ln else {
        return nil
    }
    let d: Int
    if nextFirst > prevLast + 1 {
        d = nextFirst - prevLast - 1
    } else {
        return nil
    }
    if d == 1 {
        return "… 1 unchanged line"
    } else {
        return "… \(d) unchanged lines"
    }
}
