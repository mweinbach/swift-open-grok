import Foundation
import OpenGrokMarkdownCore

public enum MarkdownTextStyle: Sendable, Equatable {
    case plain
    case syntax
    case heading(Int)
    case strong
    case emphasis
    case strikethrough
    case code
    case quote
    case listMarker
    case tableBorder
    case link
    case image
}

public struct MarkdownRenderSegment: Sendable, Equatable {
    public let text: String
    public let style: MarkdownTextStyle

    public init(text: String, style: MarkdownTextStyle = .plain) {
        self.text = text
        self.style = style
    }
}

public struct MarkdownRenderLine: Sendable, Equatable {
    public let segments: [MarkdownRenderSegment]
    public let sourceLine: Int

    public init(segments: [MarkdownRenderSegment], sourceLine: Int) {
        self.segments = segments
        self.sourceLine = sourceLine
    }

    public var text: String {
        segments.map(\.text).joined()
    }
}

public struct MarkdownHyperlink: Sendable, Equatable {
    public let lineIndex: Int
    public let columnRange: Range<Int>
    public let url: String
    public let id: Int

    public init(lineIndex: Int, columnRange: Range<Int>, url: String, id: Int) {
        self.lineIndex = lineIndex
        self.columnRange = columnRange
        self.url = url
        self.id = id
    }
}

public struct MarkdownCodeBlockSpan: Sendable, Equatable {
    public let info: String
    public let body: String
    public let outputLineRange: Range<Int>
    public let sourceByteRange: Range<Int>

    public init(info: String, body: String, outputLineRange: Range<Int>, sourceByteRange: Range<Int>) {
        self.info = info
        self.body = body
        self.outputLineRange = outputLineRange
        self.sourceByteRange = sourceByteRange
    }
}

public struct MarkdownRenderOutput: Sendable, Equatable {
    public let lines: [MarkdownRenderLine]
    public let lineSourceMap: [Int]
    public let hyperlinks: [MarkdownHyperlink]
    public let codeBlocks: [MarkdownCodeBlockSpan]

    public init(
        lines: [MarkdownRenderLine] = [],
        lineSourceMap: [Int] = [],
        hyperlinks: [MarkdownHyperlink] = [],
        codeBlocks: [MarkdownCodeBlockSpan] = []
    ) {
        self.lines = lines
        self.lineSourceMap = lineSourceMap
        self.hyperlinks = hyperlinks
        self.codeBlocks = codeBlocks
    }

    public var lineCount: Int { lines.count }

    public var text: String {
        lines.map(\.text).joined(separator: "\n")
    }

    public func asView() -> MarkdownRenderView {
        MarkdownRenderView(output: self)
    }
}

public struct MarkdownRenderView: Sendable, Equatable {
    public let lines: [MarkdownRenderLine]
    public let lineSourceMap: [Int]
    public let hyperlinks: [MarkdownHyperlink]
    public let codeBlocks: [MarkdownCodeBlockSpan]

    public init(output: MarkdownRenderOutput) {
        lines = output.lines
        lineSourceMap = output.lineSourceMap
        hyperlinks = output.hyperlinks
        codeBlocks = output.codeBlocks
    }

    public var lineCount: Int { lines.count }
}

public struct MarkdownTableBorders: Sendable, Equatable {
    public var horizontal: Character
    public var vertical: Character
    public var topLeft: Character
    public var topRight: Character
    public var bottomLeft: Character
    public var bottomRight: Character
    public var topJoin: Character
    public var bottomJoin: Character
    public var leftJoin: Character
    public var rightJoin: Character
    public var cross: Character

    public init(
        horizontal: Character = "─",
        vertical: Character = "│",
        topLeft: Character = "┌",
        topRight: Character = "┐",
        bottomLeft: Character = "└",
        bottomRight: Character = "┘",
        topJoin: Character = "┬",
        bottomJoin: Character = "┴",
        leftJoin: Character = "├",
        rightJoin: Character = "┤",
        cross: Character = "┼"
    ) {
        self.horizontal = horizontal
        self.vertical = vertical
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
        self.topJoin = topJoin
        self.bottomJoin = bottomJoin
        self.leftJoin = leftJoin
        self.rightJoin = rightJoin
        self.cross = cross
    }
}

public struct MarkdownStyle: Sendable, Equatable {
    public var tableBorders: MarkdownTableBorders
    public var unorderedBullet: String
    public var checkedTaskMarker: String
    public var uncheckedTaskMarker: String
    public var quoteMarker: String
    public var codeIndent: String
    public var rule: String

    public init(
        tableBorders: MarkdownTableBorders = MarkdownTableBorders(),
        unorderedBullet: String = "•",
        checkedTaskMarker: String = "☑",
        uncheckedTaskMarker: String = "☐",
        quoteMarker: String = "│",
        codeIndent: String = "  ",
        rule: String = "────────────────"
    ) {
        self.tableBorders = tableBorders
        self.unorderedBullet = unorderedBullet
        self.checkedTaskMarker = checkedTaskMarker
        self.uncheckedTaskMarker = uncheckedTaskMarker
        self.quoteMarker = quoteMarker
        self.codeIndent = codeIndent
        self.rule = rule
    }
}

public struct MarkdownRenderConfiguration: Sendable, Equatable {
    public var style: MarkdownStyle
    public var pretty: Bool
    public var collapseSoftBreaks: Bool
    public var showLinkDestinations: Bool
    public var maxTableWidth: Int?

    public init(
        style: MarkdownStyle = MarkdownStyle(),
        pretty: Bool = true,
        collapseSoftBreaks: Bool = true,
        showLinkDestinations: Bool = true,
        maxTableWidth: Int? = nil
    ) {
        self.style = style
        self.pretty = pretty
        self.collapseSoftBreaks = collapseSoftBreaks
        self.showLinkDestinations = showLinkDestinations
        self.maxTableWidth = maxTableWidth
    }
}

public struct MarkdownRenderer: Sendable {
    public var configuration: MarkdownRenderConfiguration

    public init(configuration: MarkdownRenderConfiguration = MarkdownRenderConfiguration()) {
        self.configuration = configuration
    }

    public init(style: MarkdownStyle = MarkdownStyle(), pretty: Bool = true) {
        configuration = MarkdownRenderConfiguration(style: style, pretty: pretty)
    }

    public func render(_ source: String) -> MarkdownRenderOutput {
        var engine = RenderEngine(configuration: configuration)
        return engine.render(source)
    }

    public func renderText(_ source: String) -> String {
        render(source).text
    }

    public static func render(_ source: String, configuration: MarkdownRenderConfiguration = MarkdownRenderConfiguration()) -> MarkdownRenderOutput {
        MarkdownRenderer(configuration: configuration).render(source)
    }
}

public func renderMarkdown(
    _ source: String,
    pretty: Bool = true,
    configuration: MarkdownRenderConfiguration? = nil
) -> String {
    var resolved = configuration ?? MarkdownRenderConfiguration()
    resolved.pretty = pretty
    return MarkdownRenderer(configuration: resolved).renderText(source)
}

public struct StreamingMarkdownRenderer: Sendable {
    private var sourceStorage = ""
    private var outputStorage = MarkdownRenderOutput()
    private var configuration: MarkdownRenderConfiguration
    private var frozenSourceByteCount = 0
    private var frozenOutputLineCount = 0

    public init(configuration: MarkdownRenderConfiguration = MarkdownRenderConfiguration()) {
        self.configuration = configuration
    }

    public init(style: MarkdownStyle = MarkdownStyle(), pretty: Bool = true) {
        configuration = MarkdownRenderConfiguration(style: style, pretty: pretty)
    }

    public var source: String { sourceStorage }
    public var pretty: Bool { configuration.pretty }
    public var view: MarkdownRenderView { outputStorage.asView() }
    public var output: MarkdownRenderOutput { outputStorage }
    public var frozenBytes: Int { frozenSourceByteCount }
    public var frozenLinesCount: Int { frozenOutputLineCount }

    public mutating func push(_ chunk: String) {
        sourceStorage.append(chunk)
    }

    @discardableResult
    public mutating func pushAndRender(_ chunk: String) -> MarkdownRenderOutput {
        push(chunk)
        return render()
    }

    @discardableResult
    public mutating func render() -> MarkdownRenderOutput {
        outputStorage = MarkdownRenderer(configuration: configuration).render(sourceStorage)
        updateFrozenBoundary()
        return outputStorage
    }

    @discardableResult
    public mutating func finish() -> MarkdownRenderOutput {
        render()
        frozenSourceByteCount = sourceStorage.utf8.count
        frozenOutputLineCount = outputStorage.lines.count
        return outputStorage
    }

    public mutating func clear() {
        sourceStorage = ""
        outputStorage = MarkdownRenderOutput()
        frozenSourceByteCount = 0
        frozenOutputLineCount = 0
    }

    public mutating func setStyle(_ style: MarkdownStyle) {
        configuration.style = style
        resetRenderedState()
    }

    public mutating func setPretty(_ pretty: Bool) {
        guard configuration.pretty != pretty else { return }
        configuration.pretty = pretty
        resetRenderedState()
    }

    public mutating func setMaxTableWidth(_ width: Int?) {
        guard configuration.maxTableWidth != width else { return }
        configuration.maxTableWidth = width
        resetRenderedState()
    }

    public mutating func setCollapseSoftBreaks(_ collapse: Bool) {
        guard configuration.collapseSoftBreaks != collapse else { return }
        configuration.collapseSoftBreaks = collapse
        resetRenderedState()
    }

    public consuming func intoOutput() -> MarkdownRenderOutput {
        outputStorage
    }

    private mutating func resetRenderedState() {
        outputStorage = MarkdownRenderOutput()
        frozenSourceByteCount = 0
        frozenOutputLineCount = 0
    }

    private mutating func updateFrozenBoundary() {
        guard let boundary = sourceStorage.range(of: "\n\n", options: .backwards) else {
            frozenSourceByteCount = 0
            frozenOutputLineCount = 0
            return
        }
        frozenSourceByteCount = sourceStorage[..<boundary.upperBound].utf8.count
        frozenOutputLineCount = outputStorage.lines.lastIndex(where: {
            $0.sourceLine < sourceStorage[..<boundary.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).count
        }).map { $0 + 1 } ?? 0
    }
}

private struct InternalLink: Sendable, Equatable {
    let range: Range<Int>
    let url: String
    let id: Int
}

private struct WorkingLine: Sendable, Equatable {
    var segments: [MarkdownRenderSegment] = []
    var sourceLine: Int
    var links: [InternalLink] = []

    init(segments: [MarkdownRenderSegment] = [], sourceLine: Int) {
        self.segments = segments
        self.sourceLine = sourceLine
    }

    var text: String {
        segments.map(\.text).joined()
    }

    var width: Int {
        text.count
    }

    mutating func append(_ value: String, style: MarkdownTextStyle = .plain, link: InternalLink? = nil) {
        guard !value.isEmpty else { return }
        if let last = segments.last, last.style == style {
            segments[segments.count - 1] = MarkdownRenderSegment(text: last.text + value, style: style)
        } else {
            segments.append(MarkdownRenderSegment(text: value, style: style))
        }
        if let link {
            links.append(InternalLink(range: (width - value.count)..<width, url: link.url, id: link.id))
        }
    }

    mutating func prepend(_ value: String, style: MarkdownTextStyle) {
        guard !value.isEmpty else { return }
        let shift = value.count
        segments.insert(MarkdownRenderSegment(text: value, style: style), at: 0)
        links = links.map { InternalLink(range: ($0.range.lowerBound + shift)..<($0.range.upperBound + shift), url: $0.url, id: $0.id) }
    }
}

private struct InternalCodeSpan: Sendable, Equatable {
    let info: String
    let body: String
    let outputLineRange: Range<Int>
    let sourceByteRange: Range<Int>
}

private struct RenderedFragment: Sendable, Equatable {
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

private struct LinkContext {
    let url: String
    let id: Int
}

private struct RenderEngine: Sendable {
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
            lines.append(MarkdownRenderLine(segments: line.segments, sourceLine: line.sourceLine))
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
            let characters = Array(line.text)
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
                let range = start..<end
                if !links.contains(where: { $0.lineIndex == lineIndex && $0.columnRange.overlaps(range) }) {
                    links.append(MarkdownHyperlink(lineIndex: lineIndex, columnRange: range, url: String(characters[range]), id: nextLinkID))
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
            let indentation = String(repeating: " ", count: marker.count)
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
                result.lines = bodyLines.map {
                    var line = WorkingLine(sourceLine: code.sourceLine)
                    line.append(configuration.style.codeIndent + $0, style: .code)
                    return line
                }
            }
        } else {
            var opening = WorkingLine(sourceLine: code.sourceLine)
            opening.append(rawFence + code.info, style: .syntax)
            result.lines.append(opening)
            bodyStart = result.lines.count
            for (offset, value) in bodyLines.enumerated() {
                var line = WorkingLine(sourceLine: code.sourceLine + offset + 1)
                line.append(value, style: .code)
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

    private mutating func renderTable(_ table: MarkdownTable) -> RenderedFragment {
        let header = table.header.map { inlineText($0) }
        let rows = table.rows.map { $0.map { inlineText($0) } }
        let allRows = [header] + rows
        let count = max(1, header.count)
        var widths = Array(repeating: 1, count: count)
        for row in allRows {
            for column in 0..<min(count, row.count) {
                widths[column] = max(widths[column], row[column].count)
            }
        }
        if let limit = configuration.maxTableWidth {
            shrink(&widths, to: max(1, limit), borderCount: configuration.pretty ? count + 1 : count + 2)
        }
        var lines: [WorkingLine] = []
        if configuration.pretty {
            let borders = configuration.style.tableBorders
            lines.append(tableBorderLine(widths: widths, left: borders.topLeft, join: borders.topJoin, right: borders.topRight, sourceLine: table.sourceLines.first ?? 0))
            lines.append(tableDataLine(header, widths: widths, alignments: table.alignments, borders: borders, sourceLine: table.sourceLines.first ?? 0))
            lines.append(tableBorderLine(widths: widths, left: borders.leftJoin, join: borders.cross, right: borders.rightJoin, sourceLine: table.sourceLines.dropFirst().first ?? table.sourceLines.first ?? 0))
            for (index, row) in rows.enumerated() {
                lines.append(tableDataLine(row, widths: widths, alignments: table.alignments, borders: borders, sourceLine: table.sourceLines.dropFirst(2 + index).first ?? table.sourceLines.last ?? 0))
            }
            lines.append(tableBorderLine(widths: widths, left: borders.bottomLeft, join: borders.bottomJoin, right: borders.bottomRight, sourceLine: table.sourceLines.last ?? 0))
        } else {
            lines.append(rawTableLine(header, sourceLine: table.sourceLines.first ?? 0))
            lines.append(rawTableLine(table.alignments.map { _ in "---" }, sourceLine: table.sourceLines.dropFirst().first ?? table.sourceLines.first ?? 0))
            for (index, row) in rows.enumerated() {
                lines.append(rawTableLine(row, sourceLine: table.sourceLines.dropFirst(2 + index).first ?? table.sourceLines.last ?? 0))
            }
        }
        return RenderedFragment(lines: lines)
    }

    private func inlineText(_ inlines: [MarkdownInline]) -> String {
        var value = ""
        for inline in inlines {
            switch inline {
            case let .text(text): value += text
            case let .strong(children), let .emphasis(children), let .strikethrough(children): value += inlineText(children)
            case let .code(text): value += text
            case let .link(text, destination, _):
                value += inlineText(text)
                if configuration.pretty && configuration.showLinkDestinations { value += " (\(destination))" }
            case let .image(alt, destination, _):
                value += inlineText(alt)
                if configuration.pretty && configuration.showLinkDestinations { value += " (\(destination))" }
            case let .math(mathValue, display):
                value += configuration.pretty ? mathValue : (display ? "$$\(mathValue)$$" : "$\(mathValue)$")
            case .softBreak: value += configuration.collapseSoftBreaks ? " " : "\n"
            case .hardBreak: value += "\n"
            }
        }
        return value.replacingOccurrences(of: "\n", with: " ")
    }

    private func tableBorderLine(widths: [Int], left: Character, join: Character, right: Character, sourceLine: Int) -> WorkingLine {
        var line = WorkingLine(sourceLine: sourceLine)
        line.append(String(left), style: .tableBorder)
        for (index, width) in widths.enumerated() {
            line.append(String(repeating: configuration.style.tableBorders.horizontal, count: width + 2), style: .tableBorder)
            line.append(String(index == widths.count - 1 ? right : join), style: .tableBorder)
        }
        return line
    }

    private func tableDataLine(
        _ row: [String],
        widths: [Int],
        alignments: [MarkdownAlignment],
        borders: MarkdownTableBorders,
        sourceLine: Int
    ) -> WorkingLine {
        var line = WorkingLine(sourceLine: sourceLine)
        line.append(String(borders.vertical), style: .tableBorder)
        for index in widths.indices {
            let value = fit(row[safe: index] ?? "", width: widths[index], alignment: alignments[safe: index] ?? .none)
            line.append(" " + value + " ", style: .plain)
            line.append(String(borders.vertical), style: .tableBorder)
        }
        return line
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
                    lines[current].links[lines[current].links.count - 1] = InternalLink(range: (end - value.count)..<end, url: activeLink.url, id: activeLink.id)
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
                    lines[current].links[lines[current].links.count - 1] = InternalLink(range: (end - value.count)..<end, url: activeLink.url, id: activeLink.id)
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

private func shrink(_ widths: inout [Int], to limit: Int, borderCount: Int) {
    guard !widths.isEmpty else { return }
    let overhead = borderCount + widths.count * 2
    while widths.reduce(0, +) + overhead > limit, let index = widths.indices.max(by: { widths[$0] < widths[$1] }), widths[index] > 1 {
        widths[index] -= 1
    }
}

private func fit(_ value: String, width: Int, alignment: MarkdownAlignment) -> String {
    let clipped: String
    if value.count > width {
        let suffix = width > 1 ? "…" : ""
        clipped = String(value.prefix(max(0, width - suffix.count))) + suffix
    } else {
        clipped = value
    }
    let padding = max(0, width - clipped.count)
    switch alignment {
    case .right:
        return String(repeating: " ", count: padding) + clipped
    case .center:
        let left = padding / 2
        return String(repeating: " ", count: left) + clipped + String(repeating: " ", count: padding - left)
    default:
        return clipped + String(repeating: " ", count: padding)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
