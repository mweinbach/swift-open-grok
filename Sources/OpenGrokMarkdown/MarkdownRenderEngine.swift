import Foundation
import OpenGrokMarkdownCore
import OpenGrokTerminalCore

struct InternalLink: Sendable, Equatable {
    let range: Range<Int>
    let url: String
    let id: Int
}

struct WorkingLine: Sendable, Equatable {
    var segments: [MarkdownRenderSegment] = []
    var sourceLine: Int
    var links: [InternalLink] = []
    var background: MarkdownLineBackground?

    init(
        segments: [MarkdownRenderSegment] = [],
        sourceLine: Int,
        background: MarkdownLineBackground? = nil
    ) {
        self.segments = segments
        self.sourceLine = sourceLine
        self.background = background
    }

    var text: String {
        segments.map(\.text).joined()
    }

    var width: Int {
        UnicodeDisplayWidth.width(of: text)
    }

    mutating func append(_ value: String, style: MarkdownTextStyle = .plain, link: InternalLink? = nil) {
        guard !value.isEmpty else { return }
        if let last = segments.last, last.style == style {
            segments[segments.count - 1] = MarkdownRenderSegment(text: last.text + value, style: style)
        } else {
            segments.append(MarkdownRenderSegment(text: value, style: style))
        }
        if let link {
            let start = width - UnicodeDisplayWidth.width(of: value)
            links.append(InternalLink(range: start..<width, url: link.url, id: link.id))
        }
    }

    mutating func prepend(_ value: String, style: MarkdownTextStyle) {
        guard !value.isEmpty else { return }
        let shift = UnicodeDisplayWidth.width(of: value)
        segments.insert(MarkdownRenderSegment(text: value, style: style), at: 0)
        links = links.map { InternalLink(range: ($0.range.lowerBound + shift)..<($0.range.upperBound + shift), url: $0.url, id: $0.id) }
    }
}

struct InternalCodeSpan: Sendable, Equatable {
    let info: String
    let body: String
    let outputLineRange: Range<Int>
    let sourceByteRange: Range<Int>
}

struct RenderedFragment: Sendable, Equatable {
    var lines: [WorkingLine] = []
    var codeBlocks: [InternalCodeSpan] = []

    mutating func append(_ other: RenderedFragment) {
        let offset = lines.count
        lines.append(contentsOf: other.lines)
        codeBlocks.append(contentsOf: other.codeBlocks.map {
            InternalCodeSpan(
                info: $0.info,
                body: $0.body,
                outputLineRange: ($0.outputLineRange.lowerBound + offset)..<($0.outputLineRange.upperBound + offset),
                sourceByteRange: $0.sourceByteRange
            )
        })
    }
}

struct LinkContext {
    let url: String
    let id: Int
}

struct RenderEngine: Sendable {
    let configuration: MarkdownRenderConfiguration
    private var nextLinkID = 0

    init(configuration: MarkdownRenderConfiguration) {
        self.configuration = configuration
    }

    mutating func render(_ source: String) -> MarkdownRenderOutput {
        let document = MarkdownParser().parse(source)
        let fragment = renderBlocks(document.blocks)
        var lines: [MarkdownRenderLine] = []
        var hyperlinks: [MarkdownHyperlink] = []

        for (lineIndex, line) in fragment.lines.enumerated() {
            lines.append(MarkdownRenderLine(
                segments: line.segments,
                sourceLine: line.sourceLine,
                background: line.background
            ))
            for link in line.links {
                hyperlinks.append(MarkdownHyperlink(lineIndex: lineIndex, columnRange: link.range, url: link.url, id: link.id))
            }
        }

        let codeBlocks = fragment.codeBlocks.map {
            MarkdownCodeBlockSpan(info: $0.info, body: $0.body, outputLineRange: $0.outputLineRange, sourceByteRange: $0.sourceByteRange)
        }

        appendPlainURLLinks(to: &hyperlinks, lines: lines)

        return MarkdownRenderOutput(
            lines: lines,
            lineSourceMap: lines.map(\.sourceLine),
            hyperlinks: hyperlinks.sorted { ($0.lineIndex, $0.columnRange.lowerBound) < ($1.lineIndex, $1.columnRange.lowerBound) },
            codeBlocks: codeBlocks
        )
    }

    private mutating func appendPlainURLLinks(to links: inout [MarkdownHyperlink], lines: [MarkdownRenderLine]) {
        for (lineIndex, line) in lines.enumerated() {
            let lineStr = line.text
            let characters = Array(lineStr)
            var start = 0
            while start < characters.count {
                guard startsURL(at: start, in: characters) else {
                    start += 1
                    continue
                }
                var end = start
                while end < characters.count && !characters[end].isWhitespace {
                    end += 1
                }
                while end > start && ".,;:!?)]}".contains(characters[end - 1]) {
                    end -= 1
                }
                guard end > start else {
                    start += 1
                    continue
                }
                let prefixStr = String(characters[0..<start])
                let matchStr = String(characters[start..<end])
                let colStart = UnicodeDisplayWidth.width(of: prefixStr)
                let colEnd = colStart + UnicodeDisplayWidth.width(of: matchStr)
                let range = colStart..<colEnd

                if !links.contains(where: { $0.lineIndex == lineIndex && $0.columnRange.overlaps(range) }) {
                    links.append(MarkdownHyperlink(lineIndex: lineIndex, columnRange: range, url: matchStr, id: nextLinkID))
                    nextLinkID += 1
                }
                start = end
            }
        }
    }

    private func startsURL(at index: Int, in characters: [Character]) -> Bool {
        let http = Array("http://")
        let https = Array("https://")
        if index + http.count <= characters.count, Array(characters[index..<(index + http.count)]) == http {
            return true
        }
        return index + https.count <= characters.count && Array(characters[index..<(index + https.count)]) == https
    }

    private mutating func renderBlocks(_ blocks: [MarkdownBlock]) -> RenderedFragment {
        var result = RenderedFragment()
        for (index, block) in blocks.enumerated() {
            if index > 0, result.lines.last?.text.isEmpty == false {
                result.lines.append(WorkingLine(sourceLine: max(block.sourceLine - 1, result.lines.last?.sourceLine ?? block.sourceLine)))
            }
            result.append(renderBlock(block))
        }
        return result
    }

    private mutating func renderBlock(_ block: MarkdownBlock) -> RenderedFragment {
        switch block.kind {
        case let .paragraph(inlines):
            return renderParagraph(inlines, sourceLine: block.sourceLine)
        case let .heading(level, content):
            var line = WorkingLine(sourceLine: block.sourceLine)
            if !configuration.pretty {
                line.append(String(repeating: "#", count: level) + " ", style: .syntax)
            }
            appendInlines(content, to: &line, style: .heading(level), activeLink: nil)
            return RenderedFragment(lines: [line])
        case let .quote(blocks):
            var nested = renderBlocks(blocks)
            for index in nested.lines.indices {
                if configuration.pretty {
                    let alreadyQuoted = nested.lines[index].text.hasPrefix(configuration.style.quoteMarker)
                    nested.lines[index].prepend(alreadyQuoted ? configuration.style.quoteMarker : configuration.style.quoteMarker + " ", style: .quote)
                } else {
                    nested.lines[index].prepend("> ", style: .quote)
                }
            }
            return nested
        case let .list(ordered, start, items):
            return renderList(ordered: ordered, start: start, items: items)
        case let .code(code):
            return renderCode(code)
        case .thematicBreak:
            return RenderedFragment(lines: [WorkingLine(segments: [MarkdownRenderSegment(text: configuration.pretty ? configuration.style.rule : "---", style: .syntax)], sourceLine: block.sourceLine)])
        case let .table(table):
            return renderTable(table)
        }
    }

    private mutating func renderParagraph(_ inlines: [MarkdownInline], sourceLine: Int) -> RenderedFragment {
        var lines = [WorkingLine(sourceLine: sourceLine)]
        var current = 0
        appendInlines(inlines, to: &lines, current: &current, style: .plain, activeLink: nil)
        return RenderedFragment(lines: lines)
    }

    private mutating func renderList(ordered: Bool, start: Int, items: [MarkdownListItem]) -> RenderedFragment {
        var result = RenderedFragment()
        for (offset, item) in items.enumerated() {
            if offset > 0, result.lines.last?.text.isEmpty == false {
                result.lines.append(WorkingLine(sourceLine: item.sourceLine))
            }
            var itemFragment = renderBlocks(item.blocks)
            if itemFragment.lines.isEmpty {
                itemFragment.lines = [WorkingLine(sourceLine: item.sourceLine)]
            }
            let taskPrefix: String
            switch item.task {
            case .none:
                taskPrefix = ""
            case .checked:
                taskPrefix = configuration.pretty ? configuration.style.checkedTaskMarker + " " : "[x] "
            case .unchecked:
                taskPrefix = configuration.pretty ? configuration.style.uncheckedTaskMarker + " " : "[ ] "
            }
            let marker: String
            if ordered {
                marker = "\(start + offset). " + taskPrefix
            } else {
                marker = (configuration.pretty ? configuration.style.unorderedBullet : "-") + " " + taskPrefix
            }
            itemFragment.lines[0].prepend(marker, style: .listMarker)
            let indentation = String(repeating: " ", count: UnicodeDisplayWidth.width(of: marker))
            for index in itemFragment.lines.indices.dropFirst() {
                itemFragment.lines[index].prepend(indentation, style: .listMarker)
            }
            let lineOffset = result.lines.count
            result.lines.append(contentsOf: itemFragment.lines)
            result.codeBlocks.append(contentsOf: itemFragment.codeBlocks.map {
                InternalCodeSpan(info: $0.info, body: $0.body, outputLineRange: ($0.outputLineRange.lowerBound + lineOffset)..<($0.outputLineRange.upperBound + lineOffset), sourceByteRange: $0.sourceByteRange)
            })
        }
        return result
    }

    private mutating func renderCode(_ code: MarkdownCodeBlock) -> RenderedFragment {
        var result = RenderedFragment()
        let rawFence = String(repeating: Character(UnicodeScalar(96)!), count: 3)
        let bodyLines = code.body.hasSuffix("\n") ? String(code.body.dropLast()).components(separatedBy: "\n") : code.body.components(separatedBy: "\n")
        let bodyStart: Int
        if configuration.pretty {
            bodyStart = 0
            if !bodyLines.isEmpty && !(bodyLines.count == 1 && bodyLines[0].isEmpty) {
                result.lines = bodyLines.map { bodyLine in
                    var line = WorkingLine(
                        sourceLine: code.sourceLine,
                        background: .code
                    )
                    line.append(configuration.style.codeIndent, style: .code)
                    for segment in markdownHighlightFenceLine(bodyLine, info: code.info) {
                        line.append(segment.text, style: segment.style)
                    }
                    return line
                }
            }
        } else {
            var opening = WorkingLine(sourceLine: code.sourceLine)
            opening.append(rawFence + code.info, style: .syntax)
            result.lines.append(opening)
            bodyStart = result.lines.count
            for (offset, value) in bodyLines.enumerated() {
                var line = WorkingLine(
                    sourceLine: code.sourceLine + offset + 1,
                    background: .code
                )
                for segment in markdownHighlightFenceLine(value, info: code.info) {
                    line.append(segment.text, style: segment.style)
                }
                result.lines.append(line)
            }
            if code.closed {
                var closing = WorkingLine(sourceLine: code.sourceLine + bodyLines.count + 1)
                closing.append(rawFence, style: .syntax)
                result.lines.append(closing)
            }
        }
        if configuration.pretty && !bodyLines.isEmpty && !(bodyLines.count == 1 && bodyLines[0].isEmpty) {
            for index in result.lines.indices {
                result.lines[index].sourceLine = code.sourceLine + index + 1
            }
        }
        let bodyEnd = bodyStart + (configuration.pretty ? result.lines.count : bodyLines.count)
        result.codeBlocks = [
            InternalCodeSpan(
                info: code.info,
                body: code.body,
                outputLineRange: bodyStart..<bodyEnd,
                sourceByteRange: code.sourceByteRange
            )
        ]
        return result
    }

    // MARK: - Table Rendering

    private mutating func renderTable(_ table: MarkdownTable) -> RenderedFragment {
        var headerCells: [StyledTableCell] = []
        for cellInlines in table.header {
            headerCells.append(buildStyledTableCell(from: cellInlines, isHeader: true))
        }

        var bodyRows: [[StyledTableCell]] = []
        for rowInlines in table.rows {
            var rowCells: [StyledTableCell] = []
            for cellInlines in rowInlines {
                rowCells.append(buildStyledTableCell(from: cellInlines, isHeader: false))
            }
            bodyRows.append(rowCells)
        }

        let allRows = [headerCells] + bodyRows
        let numCols = max(1, allRows.map(\.count).max() ?? 1)
        let padding = 1
        let colWidths = computeTableColumnWidths(
            allRows: allRows,
            numCols: numCols,
            padding: padding,
            maxTableWidth: configuration.maxTableWidth
        )

        var lines: [WorkingLine] = []

        if configuration.pretty {
            let borders = configuration.style.tableBorders
            let headerSourceLine = table.sourceLines.first ?? 0
            let separatorSourceLine = table.sourceLines.dropFirst().first ?? headerSourceLine

            // 1. Top border
            let topBorderText = formatTableBorderLine(
                colWidths: colWidths,
                padding: padding,
                left: borders.topLeft,
                mid: borders.topJoin,
                right: borders.topRight,
                horizontal: borders.horizontal
            )
            var topBorderLine = WorkingLine(sourceLine: headerSourceLine)
            topBorderLine.append(topBorderText, style: .tableBorder)
            lines.append(topBorderLine)

            // 2. Header row (multi-line layout)
            if !headerCells.isEmpty {
                let formattedHeader = formatStyledTableRow(
                    cells: headerCells,
                    colWidths: colWidths,
                    alignments: table.alignments,
                    padding: padding,
                    borders: borders,
                    isHeader: true,
                    sourceLine: headerSourceLine
                )
                for (visIdx, rLine) in formattedHeader.renderLines.enumerated() {
                    var wLine = WorkingLine(segments: rLine.segments, sourceLine: headerSourceLine)
                    for hl in formattedHeader.hyperlinks where hl.lineOffset == visIdx {
                        wLine.links.append(InternalLink(range: hl.columnRange, url: hl.url, id: hl.id))
                    }
                    lines.append(wLine)
                }

                // 3. Header separator
                let headerSepText = formatTableBorderLine(
                    colWidths: colWidths,
                    padding: padding,
                    left: borders.leftJoin,
                    mid: borders.cross,
                    right: borders.rightJoin,
                    horizontal: borders.horizontal
                )
                var headerSepLine = WorkingLine(sourceLine: separatorSourceLine)
                headerSepLine.append(headerSepText, style: .tableBorder)
                lines.append(headerSepLine)
            }

            // 4. Body rows with intermediate row dividers
            for (bodyIdx, row) in bodyRows.enumerated() {
                let rowSourceLine = table.sourceLines.dropFirst(2 + bodyIdx).first ?? table.sourceLines.last ?? separatorSourceLine
                let formattedRow = formatStyledTableRow(
                    cells: row,
                    colWidths: colWidths,
                    alignments: table.alignments,
                    padding: padding,
                    borders: borders,
                    isHeader: false,
                    sourceLine: rowSourceLine
                )
                for (visIdx, rLine) in formattedRow.renderLines.enumerated() {
                    var wLine = WorkingLine(segments: rLine.segments, sourceLine: rowSourceLine)
                    for hl in formattedRow.hyperlinks where hl.lineOffset == visIdx {
                        wLine.links.append(InternalLink(range: hl.columnRange, url: hl.url, id: hl.id))
                    }
                    lines.append(wLine)
                }

                // Intermediate body row divider (between consecutive body rows)
                if bodyIdx < bodyRows.count - 1 {
                    let rowSepText = formatTableBorderLine(
                        colWidths: colWidths,
                        padding: padding,
                        left: borders.leftJoin,
                        mid: borders.cross,
                        right: borders.rightJoin,
                        horizontal: borders.horizontal
                    )
                    var rowSepLine = WorkingLine(sourceLine: rowSourceLine)
                    rowSepLine.append(rowSepText, style: .tableBorder)
                    lines.append(rowSepLine)
                }
            }

            // 5. Bottom border
            let bottomSourceLine = table.sourceLines.last ?? separatorSourceLine
            let bottomBorderText = formatTableBorderLine(
                colWidths: colWidths,
                padding: padding,
                left: borders.bottomLeft,
                mid: borders.bottomJoin,
                right: borders.bottomRight,
                horizontal: borders.horizontal
            )
            var bottomBorderLine = WorkingLine(sourceLine: bottomSourceLine)
            bottomBorderLine.append(bottomBorderText, style: .tableBorder)
            lines.append(bottomBorderLine)
        } else {
            // Raw / Markdown mode
            let headerTexts = headerCells.map(\.plainText)
            lines.append(rawTableLine(headerTexts, sourceLine: table.sourceLines.first ?? 0))
            lines.append(rawTableLine(table.alignments.map { _ in "---" }, sourceLine: table.sourceLines.dropFirst().first ?? table.sourceLines.first ?? 0))
            for (index, row) in bodyRows.enumerated() {
                let rowTexts = row.map(\.plainText)
                lines.append(rawTableLine(rowTexts, sourceLine: table.sourceLines.dropFirst(2 + index).first ?? table.sourceLines.last ?? 0))
            }
        }

        return RenderedFragment(lines: lines)
    }

    private mutating func buildStyledTableCell(from inlines: [MarkdownInline], isHeader: Bool) -> StyledTableCell {
        var spans: [TableCellSpan] = []

        func visit(
            _ items: [MarkdownInline],
            bold: Bool,
            italic: Bool,
            strike: Bool,
            code: Bool,
            link: TableCellLink?
        ) {
            for item in items {
                switch item {
                case let .text(text):
                    if !text.isEmpty {
                        spans.append(TableCellSpan(
                            text: text.replacingOccurrences(of: "\n", with: " "),
                            bold: bold,
                            italic: italic,
                            strikethrough: strike,
                            code: code,
                            link: link,
                            isHeader: isHeader
                        ))
                    }
                case let .strong(children):
                    visit(children, bold: true, italic: italic, strike: strike, code: code, link: link)
                case let .emphasis(children):
                    visit(children, bold: bold, italic: true, strike: strike, code: code, link: link)
                case let .strikethrough(children):
                    visit(children, bold: bold, italic: italic, strike: true, code: code, link: link)
                case let .code(codeText):
                    if !codeText.isEmpty {
                        spans.append(TableCellSpan(
                            text: codeText.replacingOccurrences(of: "\n", with: " "),
                            bold: bold,
                            italic: italic,
                            strikethrough: strike,
                            code: true,
                            link: link,
                            isHeader: isHeader
                        ))
                    }
                case let .link(text, destination, _):
                    let linkID = nextLinkID
                    nextLinkID += 1
                    visit(text, bold: bold, italic: italic, strike: strike, code: code, link: TableCellLink(url: destination, id: linkID))
                case let .image(alt, destination, _):
                    let linkID = nextLinkID
                    nextLinkID += 1
                    visit(alt, bold: bold, italic: italic, strike: strike, code: code, link: TableCellLink(url: destination, id: linkID))
                case let .math(val, display):
                    let mathText = display ? "$$\(val)$$" : "$\(val)$"
                    spans.append(TableCellSpan(
                        text: mathText,
                        bold: bold,
                        italic: italic,
                        strikethrough: strike,
                        code: code,
                        link: link,
                        isHeader: isHeader
                    ))
                case .softBreak:
                    let brText = configuration.collapseSoftBreaks ? " " : "\n"
                    spans.append(TableCellSpan(
                        text: brText,
                        bold: bold,
                        italic: italic,
                        strikethrough: strike,
                        code: code,
                        link: link,
                        isHeader: isHeader
                    ))
                case .hardBreak:
                    spans.append(TableCellSpan(
                        text: "\n",
                        bold: bold,
                        italic: italic,
                        strikethrough: strike,
                        code: code,
                        link: link,
                        isHeader: isHeader
                    ))
                }
            }
        }

        visit(inlines, bold: false, italic: false, strike: false, code: false, link: nil)
        return StyledTableCell(spans: spans)
    }

    private func rawTableLine(_ row: [String], sourceLine: Int) -> WorkingLine {
        var line = WorkingLine(sourceLine: sourceLine)
        line.append("| " + row.joined(separator: " | ") + " |", style: .syntax)
        return line
    }

    private mutating func appendInlines(
        _ inlines: [MarkdownInline],
        to line: inout WorkingLine,
        style: MarkdownTextStyle,
        activeLink: LinkContext?
    ) {
        var lines = [line]
        var current = 0
        appendInlines(inlines, to: &lines, current: &current, style: style, activeLink: activeLink)
        line = lines[current]
    }

    private mutating func appendInlines(
        _ inlines: [MarkdownInline],
        to lines: inout [WorkingLine],
        current: inout Int,
        style: MarkdownTextStyle,
        activeLink: LinkContext?
    ) {
        for inline in inlines {
            switch inline {
            case let .text(value):
                lines[current].append(value, style: style, link: activeLink.map { InternalLink(range: 0..<0, url: $0.url, id: $0.id) })
                if let activeLink, !value.isEmpty {
                    let end = lines[current].width
                    lines[current].links[lines[current].links.count - 1] = InternalLink(range: (end - UnicodeDisplayWidth.width(of: value))..<end, url: activeLink.url, id: activeLink.id)
                }
            case let .strong(children):
                if !configuration.pretty { lines[current].append("**", style: .syntax) }
                appendInlines(children, to: &lines, current: &current, style: .strong, activeLink: activeLink)
                if !configuration.pretty { lines[current].append("**", style: .syntax) }
            case let .emphasis(children):
                if !configuration.pretty { lines[current].append("*", style: .syntax) }
                appendInlines(children, to: &lines, current: &current, style: .emphasis, activeLink: activeLink)
                if !configuration.pretty { lines[current].append("*", style: .syntax) }
            case let .strikethrough(children):
                if !configuration.pretty { lines[current].append("~~", style: .syntax) }
                appendInlines(children, to: &lines, current: &current, style: .strikethrough, activeLink: activeLink)
                if !configuration.pretty { lines[current].append("~~", style: .syntax) }
            case let .code(value):
                let backtick = String(repeating: Character(UnicodeScalar(96)!), count: 1)
                if !configuration.pretty { lines[current].append(backtick, style: .syntax) }
                lines[current].append(value, style: .code, link: activeLink.map { InternalLink(range: 0..<0, url: $0.url, id: $0.id) })
                if let activeLink, !value.isEmpty {
                    let end = lines[current].width
                    lines[current].links[lines[current].links.count - 1] = InternalLink(range: (end - UnicodeDisplayWidth.width(of: value))..<end, url: activeLink.url, id: activeLink.id)
                }
                if !configuration.pretty { lines[current].append(backtick, style: .syntax) }
            case let .link(children, destination, title):
                let context = LinkContext(url: destination, id: nextLinkID)
                nextLinkID += 1
                if !configuration.pretty { lines[current].append("[", style: .syntax) }
                appendInlines(children, to: &lines, current: &current, style: .link, activeLink: context)
                if !configuration.pretty {
                    lines[current].append("](" + destination + (title.map { " \"\($0)\"" } ?? "") + ")", style: .syntax)
                } else if configuration.showLinkDestinations {
                    lines[current].append(" (\(destination))", style: .syntax)
                }
            case let .image(alt, destination, title):
                let context = LinkContext(url: destination, id: nextLinkID)
                nextLinkID += 1
                if !configuration.pretty { lines[current].append("![", style: .syntax) }
                appendInlines(alt, to: &lines, current: &current, style: .image, activeLink: context)
                if !configuration.pretty {
                    lines[current].append("](" + destination + (title.map { " \"\($0)\"" } ?? "") + ")", style: .syntax)
                } else if configuration.showLinkDestinations {
                    lines[current].append(" (\(destination))", style: .syntax)
                }
            case let .math(value, display):
                if !configuration.pretty {
                    lines[current].append(display ? "$$\(value)$$" : "$\(value)$", style: .syntax)
                } else {
                    lines[current].append(value, style: .plain)
                }
            case .softBreak:
                if configuration.pretty && configuration.collapseSoftBreaks {
                    lines[current].append(" ", style: .plain)
                } else {
                    current += 1
                    lines.append(WorkingLine(sourceLine: lines[current - 1].sourceLine + 1))
                }
            case .hardBreak:
                current += 1
                lines.append(WorkingLine(sourceLine: lines[current - 1].sourceLine + 1))
            }
        }
    }
}
