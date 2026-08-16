import Foundation
import OpenGrokMarkdownCore
import OpenGrokTerminalCore

public enum MarkdownTextStyle: Sendable, Equatable {
    case plain
    case syntax
    case heading(Int)
    case strong
    case emphasis
    case strikethrough
    case code
    case syntaxKeyword
    case syntaxString
    case syntaxNumber
    case syntaxComment
    case syntaxType
    case quote
    case listMarker
    case tableBorder
    case link
    case image
}

public enum MarkdownLineBackground: Sendable, Equatable {
    case code
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
    public let background: MarkdownLineBackground?

    public init(
        segments: [MarkdownRenderSegment],
        sourceLine: Int,
        background: MarkdownLineBackground? = nil
    ) {
        self.segments = segments
        self.sourceLine = sourceLine
        self.background = background
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

// MARK: - Streaming Checkpoints

/// Block type that created a checkpoint boundary.
public enum MarkdownCheckpointKind: String, Sendable, Equatable {
    case heading
    case paragraph
    case codeBlock
    case blockQuote
    case list
    case thematicBreak
    case table
    case htmlBlock
}

/// A stable position in the source text where rendered content can be frozen.
public struct MarkdownCheckpoint: Sendable, Equatable {
    public let sourceBytes: Int
    public let outputLines: Int
    public let kind: MarkdownCheckpointKind

    public init(sourceBytes: Int, outputLines: Int, kind: MarkdownCheckpointKind) {
        self.sourceBytes = sourceBytes
        self.outputLines = outputLines
        self.kind = kind
    }
}

public struct StreamingMarkdownRenderer: Sendable {
    private var sourceStorage = ""
    private var outputStorage = MarkdownRenderOutput()
    private var configuration: MarkdownRenderConfiguration
    private var frozenSourceByteCount = 0
    private var frozenOutputLineCount = 0
    private var lastCheckpointStorage: MarkdownCheckpoint?
    private var lastRenderedSourceByteCountStorage = 0

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
    public var lastCheckpoint: MarkdownCheckpoint? { lastCheckpointStorage }
    /// Source bytes parsed by the most recent render. Once a prefix freezes,
    /// this is the unfrozen tail rather than the full accumulated document.
    public var lastRenderedSourceByteCount: Int { lastRenderedSourceByteCountStorage }

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
        if frozenSourceByteCount > 0,
           frozenOutputLineCount <= outputStorage.lines.count,
           let tailStart = sourceStorage.utf8Index(at: frozenSourceByteCount) {
            let frozen = outputStorage.prefix(
                lineCount: frozenOutputLineCount,
                sourceBytes: frozenSourceByteCount
            )
            let tailSource = String(sourceStorage[tailStart...])
            let sourceLineOffset = sourceStorage[..<tailStart]
                .split(separator: "\n", omittingEmptySubsequences: false)
                .count - 1
            let needsSeparator = !frozen.lines.isEmpty
                && !tailSource.isEmpty
                && frozen.lines.last?.text.isEmpty == false
            let separatorCount = needsSeparator ? 1 : 0
            let linkIDOffset = (frozen.hyperlinks.map(\.id).max() ?? -1) + 1
            let tail = MarkdownRenderer(configuration: configuration).render(tailSource)
                .offset(
                    sourceLines: sourceLineOffset,
                    outputLines: frozen.lines.count + separatorCount,
                    sourceBytes: frozenSourceByteCount,
                    linkIDs: linkIDOffset
                )
            outputStorage = frozen.appendingStreamingTail(
                tail,
                separatorSourceLine: needsSeparator ? max(0, sourceLineOffset - 1) : nil
            )
            lastRenderedSourceByteCountStorage = tailSource.utf8.count
        } else {
            outputStorage = MarkdownRenderer(configuration: configuration).render(sourceStorage)
            lastRenderedSourceByteCountStorage = sourceStorage.utf8.count
        }
        updateFrozenBoundary()
        return outputStorage
    }

    @discardableResult
    public mutating func finish() -> MarkdownRenderOutput {
        outputStorage = MarkdownRenderer(configuration: configuration).render(sourceStorage)
        lastRenderedSourceByteCountStorage = sourceStorage.utf8.count
        frozenSourceByteCount = sourceStorage.utf8.count
        frozenOutputLineCount = outputStorage.lines.count
        lastCheckpointStorage = MarkdownCheckpoint(
            sourceBytes: frozenSourceByteCount,
            outputLines: frozenOutputLineCount,
            kind: sourceStorage.lastMarkdownCheckpointKind()
        )
        return outputStorage
    }

    public mutating func clear() {
        sourceStorage = ""
        outputStorage = MarkdownRenderOutput()
        frozenSourceByteCount = 0
        frozenOutputLineCount = 0
        lastCheckpointStorage = nil
        lastRenderedSourceByteCountStorage = 0
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
        lastCheckpointStorage = nil
        lastRenderedSourceByteCountStorage = 0
    }

    private mutating func updateFrozenBoundary() {
        guard let boundary = sourceStorage.lastStableBlankLineBoundary() else {
            frozenSourceByteCount = 0
            frozenOutputLineCount = 0
            lastCheckpointStorage = nil
            return
        }
        let frozenSource = String(sourceStorage[..<boundary])
        let byteCount = frozenSource.utf8.count
        let tailSourceLine = max(0, frozenSource
            .split(separator: "\n", omittingEmptySubsequences: false)
            .count - 1)
        let lineCount = outputStorage.lines.lastIndex(where: {
            $0.sourceLine < tailSourceLine
        }).map { $0 + 1 } ?? 0
        frozenSourceByteCount = byteCount
        frozenOutputLineCount = lineCount
        lastCheckpointStorage = MarkdownCheckpoint(
            sourceBytes: byteCount,
            outputLines: lineCount,
            kind: frozenSource.lastMarkdownCheckpointKind()
        )
    }
}

private extension String {
    func utf8Index(at offset: Int) -> String.Index? {
        guard offset >= 0, offset <= utf8.count,
              let utf8Index = utf8.index(utf8.startIndex, offsetBy: offset, limitedBy: utf8.endIndex)
        else { return nil }
        return String.Index(utf8Index, within: self)
    }

    func lastStableBlankLineBoundary() -> String.Index? {
        var fence: Character?
        var lastBoundary: String.Index?
        var lineStart = startIndex
        while lineStart < endIndex {
            let lineEnd = self[lineStart...].firstIndex(of: "\n") ?? endIndex
            let line = self[lineStart..<lineEnd]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if fence == nil {
                    fence = "`"
                } else if fence == "`" {
                    fence = nil
                }
            } else if trimmed.hasPrefix("~~~") {
                if fence == nil {
                    fence = "~"
                } else if fence == "~" {
                    fence = nil
                }
            }
            let next = lineEnd < endIndex ? index(after: lineEnd) : endIndex
            if fence == nil, trimmed.isEmpty {
                lastBoundary = next
            }
            lineStart = next
        }
        return lastBoundary
    }

    func lastMarkdownCheckpointKind() -> MarkdownCheckpointKind {
        let blocks = components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let last = blocks.last else { return .paragraph }
        let lines = last.components(separatedBy: "\n")
        if lines.count >= 2,
           lines[0].contains("|"),
           lines[1].replacingOccurrences(of: "|", with: "")
            .trimmingCharacters(in: .whitespaces)
            .allSatisfy({ $0 == "-" || $0 == ":" || $0.isWhitespace }) {
            return .table
        }
        if last.hasPrefix("#") { return .heading }
        if ["---", "***", "___"].contains(last) { return .thematicBreak }
        if last.hasPrefix("```") || last.hasPrefix("~~~") { return .codeBlock }
        if last.hasPrefix(">") { return .blockQuote }
        if last.hasPrefix("- ") || last.hasPrefix("* ") || last.hasPrefix("+ ") { return .list }
        return .paragraph
    }
}

private extension MarkdownRenderOutput {
    func prefix(lineCount: Int, sourceBytes: Int) -> MarkdownRenderOutput {
        let count = min(max(0, lineCount), lines.count)
        return MarkdownRenderOutput(
            lines: Array(lines.prefix(count)),
            lineSourceMap: Array(lineSourceMap.prefix(count)),
            hyperlinks: hyperlinks.filter { $0.lineIndex < count },
            codeBlocks: codeBlocks.filter {
                $0.outputLineRange.upperBound <= count
                    && $0.sourceByteRange.upperBound <= sourceBytes
            }
        )
    }

    func offset(
        sourceLines: Int,
        outputLines: Int,
        sourceBytes: Int,
        linkIDs: Int
    ) -> MarkdownRenderOutput {
        MarkdownRenderOutput(
            lines: lines.map {
                MarkdownRenderLine(
                    segments: $0.segments,
                    sourceLine: $0.sourceLine + sourceLines,
                    background: $0.background
                )
            },
            lineSourceMap: lineSourceMap.map { $0 + sourceLines },
            hyperlinks: hyperlinks.map {
                MarkdownHyperlink(
                    lineIndex: $0.lineIndex + outputLines,
                    columnRange: $0.columnRange,
                    url: $0.url,
                    id: $0.id + linkIDs
                )
            },
            codeBlocks: codeBlocks.map {
                MarkdownCodeBlockSpan(
                    info: $0.info,
                    body: $0.body,
                    outputLineRange: ($0.outputLineRange.lowerBound + outputLines)..<($0.outputLineRange.upperBound + outputLines),
                    sourceByteRange: ($0.sourceByteRange.lowerBound + sourceBytes)..<($0.sourceByteRange.upperBound + sourceBytes)
                )
            }
        )
    }

    func appendingStreamingTail(
        _ other: MarkdownRenderOutput,
        separatorSourceLine: Int?
    ) -> MarkdownRenderOutput {
        let separatorLines: [MarkdownRenderLine]
        let separatorMap: [Int]
        if let separatorSourceLine {
            separatorLines = [MarkdownRenderLine(segments: [], sourceLine: separatorSourceLine)]
            separatorMap = [separatorSourceLine]
        } else {
            separatorLines = []
            separatorMap = []
        }
        return MarkdownRenderOutput(
            lines: lines + separatorLines + other.lines,
            lineSourceMap: lineSourceMap + separatorMap + other.lineSourceMap,
            hyperlinks: hyperlinks + other.hyperlinks,
            codeBlocks: codeBlocks + other.codeBlocks
        )
    }
}
