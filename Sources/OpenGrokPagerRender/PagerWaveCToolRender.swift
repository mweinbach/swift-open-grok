import Foundation
import OpenGrokTerminalCore

func appendWaveCToolCard(
    _ tool: PagerToolCard,
    width: Int,
    theme: PagerRenderTheme,
    motion: PagerMotionSnapshot,
    waveRows: Int,
    into lines: inout [PaintLine]
) -> Bool {
    if tool.kind != .generic,
       tool.kind != .xSearch,
       tool.waveCPayload == nil {
        return false
    }
    switch tool.kind {
    case .read:
        appendReadCard(tool, width: width, theme: theme, into: &lines)
    case .list:
        appendListCard(tool, width: width, theme: theme, into: &lines)
    case .search:
        appendSearchCard(tool, width: width, theme: theme, into: &lines)
    case .fetch:
        appendFetchCard(tool, width: width, theme: theme, motion: motion, waveRows: waveRows, into: &lines)
    case .webSearch, .xSearch:
        appendWebSearchCard(tool, width: width, theme: theme, motion: motion, waveRows: waveRows, into: &lines)
    case .memorySearch:
        appendMemorySearchCard(tool, width: width, theme: theme, motion: motion, waveRows: waveRows, into: &lines)
    case .integrationSearch:
        appendIntegrationSearchCard(tool, width: width, theme: theme, motion: motion, waveRows: waveRows, into: &lines)
    case .useTool:
        appendUseToolCard(tool, width: width, theme: theme, motion: motion, waveRows: waveRows, into: &lines)
    case .generic:
        appendOtherCard(tool, width: width, theme: theme, motion: motion, waveRows: waveRows, into: &lines)
    case .execute, .edit, .create, .skill:
        return false
    }
    return true
}

private struct WaveCHeaderSpan {
    var span: PagerStyledSpan
    var selectable: Bool
}

private struct WaveCHeaderRow {
    var spans: [PagerStyledSpan]
    var selectionText: String?
    var selectionStart: Int
}

private func appendWaveCHeader(
    tool: PagerToolCard,
    verb: String,
    argument: String,
    argumentColor: TerminalColor,
    argumentLeading: String = "",
    argumentTrailing: String = "",
    suffix: [PagerStyledSpan] = [],
    width: Int,
    theme: PagerRenderTheme,
    accentRail: Bool,
    motion: PagerMotionSnapshot? = nil,
    waveRows: Int = PagerMotion.defaultWaveRows,
    into lines: inout [PaintLine]
) {
    let accent = pagerToolAccent(tool, theme: theme)
    let muted = !tool.isExpanded
    let labelColor = muted ? theme.gray : theme.textPrimary
    let source = [
        WaveCHeaderSpan(
            span: PagerStyledSpan(text: PagerGlyphs.toolBullet + " ", foreground: accent),
            selectable: false
        ),
        WaveCHeaderSpan(
            span: PagerStyledSpan(text: verb + (argument.isEmpty ? "" : " "), foreground: labelColor, style: [.bold]),
            selectable: false
        ),
        WaveCHeaderSpan(
            span: PagerStyledSpan(text: argumentLeading, foreground: muted ? theme.gray : argumentColor),
            selectable: false
        ),
        WaveCHeaderSpan(
            span: PagerStyledSpan(text: argument, foreground: muted ? theme.gray : argumentColor),
            selectable: !argument.isEmpty
        ),
        WaveCHeaderSpan(
            span: PagerStyledSpan(text: argumentTrailing, foreground: muted ? theme.gray : argumentColor),
            selectable: false
        )
    ] + suffix.map { WaveCHeaderSpan(span: $0, selectable: false) }
    let rows = wrapWaveCHeader(source, width: width)
    let origin = lines.count
    for (index, row) in rows.enumerated() {
        let railColor: TerminalColor = {
            guard let motion, tool.state == .running else { return accent }
            return PagerMotion.runningAccentColor(
                theme: theme,
                accent: accent,
                tick: motion.tick,
                row: lines.count,
                waveRows: waveRows,
                motionEnabled: motion.enabled
            )
        }()
        lines.append(PaintLine(
            spans: row.spans,
            foreground: labelColor,
            accentGlyph: accentRail ? PagerGlyphs.accentBar : nil,
            accentColor: railColor,
            selection: row.selectionText.map {
                PaintLineSelectionSeed(
                    rangeID: 0,
                    blockLineIndex: lines.count - origin,
                    text: $0,
                    selectableColStart: row.selectionStart,
                    joinerToPrevious: index == 0 ? nil : ""
                )
            }
        ))
    }
}

private func wrapWaveCHeader(_ source: [WaveCHeaderSpan], width: Int) -> [WaveCHeaderRow] {
    let limit = max(1, width)
    var rows: [WaveCHeaderRow] = []
    var spans: [PagerStyledSpan] = []
    var used = 0
    var selectionText = ""
    var selectionStart: Int?

    func flush() {
        rows.append(WaveCHeaderRow(
            spans: spans,
            selectionText: selectionText.isEmpty ? nil : selectionText,
            selectionStart: selectionStart ?? 0
        ))
        spans.removeAll(keepingCapacity: true)
        used = 0
        selectionText = ""
        selectionStart = nil
    }

    for sourceSpan in source {
        for grapheme in sourceSpan.span.text {
            let text = String(grapheme)
            let graphemeWidth = max(0, UnicodeDisplayWidth.width(ofGrapheme: text))
            if grapheme == "\n" || (graphemeWidth > 0 && used > 0 && used + graphemeWidth > limit) {
                flush()
                if grapheme == "\n" { continue }
            }
            var span = sourceSpan.span
            span.text = text
            if let last = spans.last,
               last.foreground == span.foreground,
               last.background == span.background,
               last.style == span.style,
               last.url == span.url
            {
                spans[spans.count - 1].text += text
            } else {
                spans.append(span)
            }
            if sourceSpan.selectable {
                if selectionStart == nil { selectionStart = used }
                selectionText += text
            }
            used += graphemeWidth
        }
    }
    if !spans.isEmpty || rows.isEmpty { flush() }
    return rows
}

private func appendReadCard(
    _ tool: PagerToolCard,
    width: Int,
    theme: PagerRenderTheme,
    into lines: inout [PaintLine]
) {
    let payload: PagerReadPayload = {
        if case .read(let payload) = tool.waveCPayload { return payload }
        return PagerReadPayload(path: tool.input, content: tool.output)
    }()
    let expandedPath = tool.input.isEmpty ? payload.path : tool.input
    let headerPath = tool.isExpanded ? expandedPath : URL(fileURLWithPath: expandedPath).lastPathComponent
    var suffix: [PagerStyledSpan] = []
    if let start = payload.startLine, let end = payload.endLine, end >= start {
        let range = start == end ? "\(start)" : "\(start)-\(end)"
        let detail: String
        if let total = payload.totalLines, total > end - start + 1 {
            detail = " (\(range) of \(total))"
        } else {
            detail = " (\(range))"
        }
        suffix.append(PagerStyledSpan(text: detail, foreground: theme.grayDim))
    }
    if payload.content == "" {
        suffix.append(PagerStyledSpan(text: " (empty)", foreground: theme.grayDim))
    } else if let media = payload.media {
        switch media {
        case .image:
            suffix.append(PagerStyledSpan(text: " (image)", foreground: theme.grayDim))
        case .pdf(let pages):
            suffix.append(PagerStyledSpan(text: " (\(pages) pages)", foreground: theme.grayDim))
        }
    }
    appendWaveCHeader(
        tool: tool,
        verb: "Read",
        argument: headerPath,
        argumentColor: theme.path,
        suffix: suffix,
        width: width,
        theme: theme,
        accentRail: false,
        into: &lines
    )
    guard tool.isExpanded, let content = payload.content, !content.isEmpty else { return }
    lines.append(PaintLine("", foreground: theme.gray))
    let physicalLines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let baseLine = payload.startLine ?? 1
    let gutterWidth = String(baseLine + max(0, physicalLines.count - 1)).count
    let contentWidth = max(1, width - gutterWidth - 2)
    var rendered: [(String, String, String?)] = []
    for (offset, text) in physicalLines.enumerated() {
        let wrapped = wrapDisplayLines(text, width: contentWidth)
        for (index, row) in wrapped.enumerated() {
            let gutter = index == 0
                ? String(format: "%\(gutterWidth)d  ", baseLine + offset)
                : String(repeating: " ", count: gutterWidth + 2)
            rendered.append((gutter, row, index == 0 ? "\n" : ""))
        }
    }
    let first = 5
    let last = 3
    let visible: [(String, String, String?)] = {
        guard rendered.count > first + last else { return rendered }
        return Array(rendered.prefix(first))
            + [("", PagerGlyphs.ellipsis, nil)]
            + Array(rendered.suffix(last))
    }()
    let origin = lines.count
    for (index, row) in visible.enumerated() {
        if row.1 == PagerGlyphs.ellipsis {
            lines.append(PaintLine(
                spans: [PagerStyledSpan(text: PagerGlyphs.ellipsis, foreground: theme.grayDim)],
                foreground: theme.grayDim,
                background: theme.bgDark
            ))
            continue
        }
        lines.append(PaintLine(
            spans: [
                PagerStyledSpan(text: row.0, foreground: theme.grayDim),
                PagerStyledSpan(text: row.1, foreground: theme.textPrimary)
            ],
            foreground: theme.textPrimary,
            background: theme.bgDark,
            selection: PaintLineSelectionSeed(
                rangeID: 1,
                blockLineIndex: lines.count - origin,
                text: row.1,
                selectableColStart: UnicodeDisplayWidth.width(of: row.0),
                joinerToPrevious: index == 0 ? nil : row.2
            )
        ))
    }
}

private func appendListCard(
    _ tool: PagerToolCard,
    width: Int,
    theme: PagerRenderTheme,
    into lines: inout [PaintLine]
) {
    let payload: PagerListPayload = {
        if case .list(let payload) = tool.waveCPayload { return payload }
        return PagerListPayload(path: tool.input, content: tool.output ?? "", entryCount: 0)
    }()
    let path = tool.input.isEmpty ? payload.path : tool.input
    let suffix: [PagerStyledSpan] = tool.state == .failed || payload.entryCount == 0
        ? []
        : [PagerStyledSpan(
            text: " (\(payload.entryCount) \(payload.entryCount == 1 ? "entry" : "entries"))",
            foreground: theme.grayDim
        )]
    appendWaveCHeader(
        tool: tool,
        verb: "List",
        argument: path,
        argumentColor: theme.path,
        suffix: suffix,
        width: width,
        theme: theme,
        accentRail: false,
        into: &lines
    )
    guard tool.isExpanded, tool.state != .failed, !payload.content.isEmpty else { return }
    lines.append(PaintLine("", foreground: theme.gray))
    let origin = lines.count
    for (index, physical) in payload.content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let text = String(physical)
        for (wrapIndex, row) in wrapDisplayLines(text, width: max(1, width)).enumerated() {
            let color = text.trimmingCharacters(in: .whitespaces).hasSuffix("/") ? theme.path : theme.textPrimary
            lines.append(PaintLine(
                row,
                foreground: color,
                selection: PaintLineSelectionSeed(
                    rangeID: 1,
                    blockLineIndex: lines.count - origin,
                    text: row,
                    selectableColStart: 0,
                    joinerToPrevious: index == 0 && wrapIndex == 0 ? nil : (wrapIndex == 0 ? "\n" : "")
                )
            ))
        }
    }
}

private func appendSearchCard(
    _ tool: PagerToolCard,
    width: Int,
    theme: PagerRenderTheme,
    into lines: inout [PaintLine]
) {
    let payload: PagerSearchPayload = {
        if case .search(let payload) = tool.waveCPayload { return payload }
        return PagerSearchPayload(pattern: tool.input)
    }()
    let detail = searchDetail(payload)
    appendWaveCHeader(
        tool: tool,
        verb: "Search",
        argument: payload.pattern,
        argumentColor: theme.textPrimary,
        argumentLeading: payload.mode == .glob ? "" : "\"",
        argumentTrailing: payload.mode == .glob ? "" : "\"",
        suffix: detail.isEmpty ? [] : [PagerStyledSpan(text: " (\(detail))", foreground: theme.grayDim)],
        width: width,
        theme: theme,
        accentRail: false,
        into: &lines
    )
    guard tool.isExpanded, tool.state != .failed else { return }
    lines.append(PaintLine("", foreground: theme.gray))
    if let path = payload.path, !path.isEmpty {
        lines.append(PaintLine(spans: [
            PagerStyledSpan(text: "Path: ", foreground: theme.grayDim),
            PagerStyledSpan(text: path, foreground: theme.path)
        ], foreground: theme.textPrimary))
    }
    if let glob = payload.glob, !glob.isEmpty {
        lines.append(PaintLine(spans: [
            PagerStyledSpan(text: "Glob: ", foreground: theme.grayDim),
            PagerStyledSpan(text: glob, foreground: theme.textPrimary)
        ], foreground: theme.textPrimary))
    }
    if payload.mode != .content {
        lines.append(PaintLine("Mode: \(searchModeLabel(payload.mode))", foreground: theme.gray))
    }
    if payload.caseInsensitive { lines.append(PaintLine("Case insensitive", foreground: theme.gray)) }
    if payload.multiline { lines.append(PaintLine("Multiline", foreground: theme.gray)) }
    guard !payload.matches.isEmpty else {
        lines.append(PaintLine("(no results)", foreground: theme.grayDim))
        return
    }
    lines.append(PaintLine("", foreground: theme.gray))
    switch payload.mode {
    case .glob, .filesWithMatches:
        for match in payload.matches {
            lines.append(PaintLine(match.path, foreground: theme.path))
        }
    case .count:
        for match in payload.matches {
            lines.append(PaintLine(spans: [
                PagerStyledSpan(text: match.path, foreground: theme.path),
                PagerStyledSpan(text: ": ", foreground: theme.grayDim),
                PagerStyledSpan(text: match.text, foreground: theme.textPrimary)
            ], foreground: theme.textPrimary))
        }
    case .content:
        var grouped: [(String, [PagerSearchMatch])] = []
        for match in payload.matches {
            if grouped.last?.0 == match.path {
                grouped[grouped.count - 1].1.append(match)
            } else {
                grouped.append((match.path, [match]))
            }
        }
        for (groupIndex, group) in grouped.enumerated() {
            if groupIndex > 0 { lines.append(PaintLine("", foreground: theme.gray)) }
            lines.append(PaintLine(group.0, foreground: theme.path))
            let gutterWidth = String(group.1.compactMap(\.lineNumber).max() ?? 1).count
            for match in group.1 {
                let number = match.lineNumber.map { String(format: "%\(gutterWidth)d  ", $0) }
                    ?? String(repeating: " ", count: gutterWidth + 2)
                let contentWidth = max(1, width - gutterWidth - 2)
                for (index, row) in wrapDisplayLines(match.text, width: contentWidth).enumerated() {
                    lines.append(PaintLine(spans: [
                        PagerStyledSpan(
                            text: index == 0 ? number : String(repeating: " ", count: gutterWidth + 2),
                            foreground: theme.grayDim
                        ),
                        PagerStyledSpan(text: row, foreground: theme.textPrimary)
                    ], foreground: theme.textPrimary))
                }
            }
        }
    }
}

private func appendFetchCard(
    _ tool: PagerToolCard,
    width: Int,
    theme: PagerRenderTheme,
    motion: PagerMotionSnapshot,
    waveRows: Int,
    into lines: inout [PaintLine]
) {
    let payload: PagerFetchPayload = {
        if case .fetch(let payload) = tool.waveCPayload { return payload }
        return PagerFetchPayload(url: tool.input, content: tool.output)
    }()
    appendWaveCHeader(
        tool: tool,
        verb: "Fetch",
        argument: payload.url,
        argumentColor: theme.textPrimary,
        width: width,
        theme: theme,
        accentRail: tool.isExpanded,
        motion: motion,
        waveRows: waveRows,
        into: &lines
    )
    guard tool.isExpanded else { return }
    let accent = pagerToolAccent(tool, theme: theme)
    let metadata = [
        payload.statusCode.map(String.init),
        payload.contentType.map(normalizedContentType),
        payload.totalBytes.map(formatBytes)
    ].compactMap { $0 }
    if !metadata.isEmpty {
        lines.append(PaintLine(
            metadata.joined(separator: " · "),
            foreground: theme.gray,
            accentGlyph: PagerGlyphs.accentBar,
            accentColor: accent
        ))
    }
    appendLimitedPanel(
        payload.content,
        maximumLines: 10,
        width: width,
        tool: tool,
        theme: theme,
        accentRail: true,
        into: &lines
    )
}

private func appendWebSearchCard(
    _ tool: PagerToolCard,
    width: Int,
    theme: PagerRenderTheme,
    motion: PagerMotionSnapshot,
    waveRows: Int,
    into lines: inout [PaintLine]
) {
    let payload: PagerWebSearchPayload = {
        if case .webSearch(let payload) = tool.waveCPayload { return payload }
        return PagerWebSearchPayload(query: tool.input, content: tool.output, isXSearch: tool.kind == .xSearch)
    }()
    let domains = uniqueDomains(payload.citations)
    let suffix: [PagerStyledSpan] = payload.isXSearch || domains.isEmpty
        ? []
        : [PagerStyledSpan(
            text: " (\(domains.count) \(domains.count == 1 ? "site" : "sites"))",
            foreground: theme.grayDim
        )]
    appendWaveCHeader(
        tool: tool,
        verb: payload.isXSearch ? "X Search" : "Web Search",
        argument: payload.query,
        argumentColor: theme.textPrimary,
        suffix: suffix,
        width: width,
        theme: theme,
        accentRail: tool.isExpanded && !payload.isXSearch,
        motion: motion,
        waveRows: waveRows,
        into: &lines
    )
    guard tool.isExpanded, !payload.isXSearch else { return }
    if !domains.isEmpty {
        let shown = Array(domains.prefix(3))
        var text = "Sources: " + shown.joined(separator: ", ")
        if domains.count > shown.count { text += " (+\(domains.count - shown.count) more)" }
        lines.append(PaintLine(
            text,
            foreground: theme.gray,
            accentGlyph: PagerGlyphs.accentBar,
            accentColor: pagerToolAccent(tool, theme: theme)
        ))
    }
    appendLimitedPanel(
        payload.content,
        maximumLines: 10,
        width: width,
        tool: tool,
        theme: theme,
        accentRail: true,
        into: &lines
    )
}

private func appendMemorySearchCard(
    _ tool: PagerToolCard,
    width: Int,
    theme: PagerRenderTheme,
    motion: PagerMotionSnapshot,
    waveRows: Int,
    into lines: inout [PaintLine]
) {
    let payload: PagerMemorySearchPayload = {
        if case .memorySearch(let payload) = tool.waveCPayload { return payload }
        return PagerMemorySearchPayload(query: tool.input, results: [])
    }()
    appendWaveCHeader(
        tool: tool,
        verb: "Memory Search",
        argument: payload.query,
        argumentColor: theme.textPrimary,
        suffix: [PagerStyledSpan(
            text: " (\(payload.results.count) \(payload.results.count == 1 ? "result" : "results"))",
            foreground: theme.grayDim
        )],
        width: width,
        theme: theme,
        accentRail: tool.isExpanded,
        motion: motion,
        waveRows: waveRows,
        into: &lines
    )
    guard tool.isExpanded else { return }
    if payload.results.isEmpty {
        lines.append(PaintLine("(no results)", foreground: theme.grayDim))
        return
    }
    for (offset, result) in payload.results.enumerated() {
        lines.append(PaintLine("", foreground: theme.gray, accentGlyph: PagerGlyphs.accentBar, accentColor: pagerToolAccent(tool, theme: theme)))
        var heading = "\(offset + 1). \(result.path)"
        if let start = result.startLine, let end = result.endLine { heading += " (lines \(start)-\(end))" }
        lines.append(PaintLine(
            heading,
            foreground: theme.path,
            accentGlyph: PagerGlyphs.accentBar,
            accentColor: pagerToolAccent(tool, theme: theme)
        ))
        let metadata = [
            result.score.map { String(format: "score %.2f", $0) },
            result.source.map { "source \($0)" }
        ].compactMap { $0 }.joined(separator: " · ")
        if !metadata.isEmpty {
            lines.append(PaintLine(
                metadata,
                foreground: theme.grayDim,
                accentGlyph: PagerGlyphs.accentBar,
                accentColor: pagerToolAccent(tool, theme: theme)
            ))
        }
        let snippets = result.snippet.split(separator: "\n").map(String.init).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        for snippet in snippets.prefix(3) {
            for row in wrapDisplayLines(snippet, width: max(1, width - 2)) {
                lines.append(PaintLine(
                    "  " + row,
                    foreground: theme.textPrimary,
                    accentGlyph: PagerGlyphs.accentBar,
                    accentColor: pagerToolAccent(tool, theme: theme),
                    background: theme.bgDark
                ))
            }
        }
    }
}

private func appendIntegrationSearchCard(
    _ tool: PagerToolCard,
    width: Int,
    theme: PagerRenderTheme,
    motion: PagerMotionSnapshot,
    waveRows: Int,
    into lines: inout [PaintLine]
) {
    let payload: PagerIntegrationSearchPayload = {
        if case .integrationSearch(let payload) = tool.waveCPayload { return payload }
        return PagerIntegrationSearchPayload(query: tool.input, results: [])
    }()
    appendWaveCHeader(
        tool: tool,
        verb: "Search Tools",
        argument: payload.query,
        argumentColor: theme.textPrimary,
        suffix: [PagerStyledSpan(
            text: " (\(payload.results.count) \(payload.results.count == 1 ? "result" : "results"))",
            foreground: theme.grayDim
        )],
        width: width,
        theme: theme,
        accentRail: tool.isExpanded,
        motion: motion,
        waveRows: waveRows,
        into: &lines
    )
    guard tool.isExpanded else { return }
    for result in payload.results {
        let action = integrationAction(result.toolName, server: result.server)
        lines.append(PaintLine(spans: [
            PagerStyledSpan(text: titleized(action), foreground: theme.textPrimary, style: [.bold]),
            PagerStyledSpan(text: result.server.isEmpty ? "" : "  \(result.server)", foreground: theme.grayDim)
        ], foreground: theme.textPrimary, accentGlyph: PagerGlyphs.accentBar, accentColor: pagerToolAccent(tool, theme: theme)))
        if !result.description.isEmpty {
            for row in wrapDisplayLines(result.description, width: max(1, width - 2)).prefix(2) {
                lines.append(PaintLine(
                    "  " + row,
                    foreground: theme.gray,
                    accentGlyph: PagerGlyphs.accentBar,
                    accentColor: pagerToolAccent(tool, theme: theme)
                ))
            }
        }
    }
}

private func appendUseToolCard(
    _ tool: PagerToolCard,
    width: Int,
    theme: PagerRenderTheme,
    motion: PagerMotionSnapshot,
    waveRows: Int,
    into lines: inout [PaintLine]
) {
    let payload: PagerUseToolPayload = {
        if case .useTool(let payload) = tool.waveCPayload { return payload }
        return PagerUseToolPayload(qualifiedName: tool.input, server: tool.input, action: tool.input, output: tool.output)
    }()
    appendWaveCHeader(
        tool: tool,
        verb: titleized(payload.server),
        argument: titleized(payload.action),
        argumentColor: theme.textPrimary,
        width: width,
        theme: theme,
        accentRail: tool.isExpanded,
        motion: motion,
        waveRows: waveRows,
        into: &lines
    )
    guard tool.isExpanded else { return }
    let accent = pagerToolAccent(tool, theme: theme)
    for argument in payload.arguments {
        lines.append(PaintLine(spans: [
            PagerStyledSpan(text: argument.key + ": ", foreground: theme.grayDim),
            PagerStyledSpan(text: argument.value, foreground: theme.textPrimary)
        ], foreground: theme.textPrimary, accentGlyph: PagerGlyphs.accentBar, accentColor: accent))
    }
    appendLimitedPanel(
        payload.output,
        maximumLines: 10,
        width: width,
        tool: tool,
        theme: theme,
        accentRail: true,
        into: &lines
    )
}

private func appendOtherCard(
    _ tool: PagerToolCard,
    width: Int,
    theme: PagerRenderTheme,
    motion: PagerMotionSnapshot,
    waveRows: Int,
    into lines: inout [PaintLine]
) {
    let question = firstQuestion(in: tool.rawInput)
    let isQuestion = tool.name == "ask_user_question"
    let splitName: (label: String, content: String?) = {
        guard let separator = tool.name.range(of: ": ") else {
            return (titleized(tool.name), nil)
        }
        let label = String(tool.name[..<separator.lowerBound])
        let content = String(tool.name[separator.upperBound...])
        return (titleized(label), content.isEmpty ? nil : content)
    }()
    let verb = isQuestion ? "Ask" : splitName.label
    let argument = isQuestion ? (question ?? "") : (splitName.content ?? tool.input)
    appendWaveCHeader(
        tool: tool,
        verb: verb,
        argument: argument,
        argumentColor: theme.textPrimary,
        width: width,
        theme: theme,
        accentRail: tool.isExpanded,
        motion: motion,
        waveRows: waveRows,
        into: &lines
    )
    guard tool.isExpanded else { return }
    let accent = pagerToolAccent(tool, theme: theme)
    if case .questions(let pairs) = tool.waveCPayload, !pairs.isEmpty {
        for (offset, pair) in pairs.enumerated() {
            lines.append(PaintLine(spans: [
                PagerStyledSpan(text: "  \(offset + 1). ", foreground: theme.grayDim),
                PagerStyledSpan(text: pair.question, foreground: theme.textPrimary)
            ], foreground: theme.textPrimary, accentGlyph: PagerGlyphs.accentBar, accentColor: accent))
            let answer = pair.answer.isEmpty ? "     (no answer)" : "     → \(pair.answer)"
            lines.append(PaintLine(
                answer,
                foreground: pair.answer.isEmpty ? theme.grayDim : theme.accentUser,
                accentGlyph: PagerGlyphs.accentBar,
                accentColor: accent
            ))
        }
        return
    }
    guard let output = tool.output, !output.isEmpty else { return }
    lines.append(PaintLine("", foreground: theme.gray, accentGlyph: PagerGlyphs.accentBar, accentColor: accent))
    for physical in output.split(separator: "\n", omittingEmptySubsequences: false) {
        for row in wrapDisplayLines(String(physical), width: max(1, width)) {
            lines.append(PaintLine(row, foreground: tool.state == .failed ? theme.accentError : theme.gray, accentGlyph: PagerGlyphs.accentBar, accentColor: accent))
        }
    }
}

private func appendLimitedPanel(
    _ content: String?,
    maximumLines: Int,
    width: Int,
    tool: PagerToolCard,
    theme: PagerRenderTheme,
    accentRail: Bool,
    into lines: inout [PaintLine]
) {
    guard let content, !content.isEmpty else { return }
    let accent = pagerToolAccent(tool, theme: theme)
    lines.append(PaintLine(
        "",
        foreground: theme.gray,
        accentGlyph: accentRail ? PagerGlyphs.accentBar : nil,
        accentColor: accent
    ))
    lines.append(PaintLine(
        "",
        foreground: theme.gray,
        accentGlyph: accentRail ? PagerGlyphs.accentBar : nil,
        accentColor: accent,
        background: theme.bgDark
    ))
    var wrapped: [String] = []
    for physical in content.split(separator: "\n", omittingEmptySubsequences: false) {
        wrapped.append(contentsOf: wrapDisplayLines(String(physical), width: max(1, width - 2)))
    }
    for row in wrapped.prefix(maximumLines) {
        lines.append(PaintLine(
            "  " + row,
            foreground: tool.state == .failed ? theme.accentError : theme.textPrimary,
            accentGlyph: accentRail ? PagerGlyphs.accentBar : nil,
            accentColor: accent,
            background: theme.bgDark
        ))
    }
    if wrapped.count > maximumLines {
        lines.append(PaintLine(
            "  ... (\(wrapped.count - maximumLines) more lines, press Enter to view)",
            foreground: theme.grayDim,
            accentGlyph: accentRail ? PagerGlyphs.accentBar : nil,
            accentColor: accent,
            background: theme.bgDark
        ))
    }
}

private func searchDetail(_ payload: PagerSearchPayload) -> String {
    switch payload.mode {
    case .glob, .filesWithMatches:
        return "\(payload.fileCount) \(payload.fileCount == 1 ? "file" : "files")"
    case .count, .content:
        let matches = "\(payload.matchCount) \(payload.matchCount == 1 ? "match" : "matches")"
        guard payload.fileCount > 0 else { return matches }
        return matches + " in \(payload.fileCount) \(payload.fileCount == 1 ? "file" : "files")"
    }
}

private func searchModeLabel(_ mode: PagerSearchOutputMode) -> String {
    switch mode {
    case .content: return "Content"
    case .filesWithMatches: return "FilesWithMatches"
    case .count: return "Count"
    case .glob: return "Glob"
    }
}

private func normalizedContentType(_ value: String) -> String {
    value.split(separator: ";", maxSplits: 1).first.map(String.init) ?? value
}

private func formatBytes(_ bytes: Int) -> String {
    if bytes < 1_024 { return "\(bytes) B" }
    if bytes < 1_048_576 { return String(format: "%.1f KB", Double(bytes) / 1_024) }
    return String(format: "%.1f MB", Double(bytes) / 1_048_576)
}

private func uniqueDomains(_ citations: [PagerWebCitation]) -> [String] {
    var seen: Set<String> = []
    var domains: [String] = []
    for citation in citations {
        guard let host = URL(string: citation.url)?.host, seen.insert(host).inserted else { continue }
        domains.append(host)
    }
    return domains
}

private func integrationAction(_ name: String, server: String) -> String {
    let prefix = server.isEmpty ? "" : server + "__"
    if !prefix.isEmpty, name.hasPrefix(prefix) { return String(name.dropFirst(prefix.count)) }
    if let separator = name.range(of: "__") { return String(name[separator.upperBound...]) }
    return name
}

private func titleized(_ value: String) -> String {
    value.replacingOccurrences(of: "__", with: " ")
        .replacingOccurrences(of: "_", with: " ")
        .replacingOccurrences(of: "-", with: " ")
        .split(separator: " ")
        .map { word in
            guard let first = word.first else { return "" }
            return String(first).uppercased() + word.dropFirst()
        }
        .joined(separator: " ")
}

private func firstQuestion(in rawInput: String) -> String? {
    guard let data = rawInput.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let questions = root["questions"] as? [[String: Any]],
          let question = questions.first?["question"] as? String
    else { return nil }
    return question
}
