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
        lastCheckpointStorage = nil
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
    }

    private mutating func updateFrozenBoundary() {
        // Find top-level block boundaries where rendering is stable and can be frozen.
        let document = MarkdownParser().parse(sourceStorage)
        var lastValidCheckpoint: MarkdownCheckpoint?

        for block in document.blocks {
            switch block.kind {
            case let .table(table):
                // When a table block is complete, find its rendered line range
                let lastSrcLine = table.sourceLines.last ?? block.sourceLine
                if let tableIdx = document.blocks.firstIndex(where: { $0.sourceLine == block.sourceLine }),
                   tableIdx < document.blocks.count - 1 || sourceStorage.hasSuffix("\n\n") {
                    let linesCount = outputStorage.lines.lastIndex(where: { $0.sourceLine <= lastSrcLine + 20 }).map { $0 + 1 } ?? outputStorage.lines.count
                    let byteCount = sourceStorage[..<sourceStorage.endIndex].utf8.count
                    lastValidCheckpoint = MarkdownCheckpoint(sourceBytes: byteCount, outputLines: linesCount, kind: .table)
                }
            case .heading:
                lastValidCheckpoint = MarkdownCheckpoint(sourceBytes: sourceStorage.utf8.count, outputLines: outputStorage.lines.count, kind: .heading)
            case .thematicBreak:
                lastValidCheckpoint = MarkdownCheckpoint(sourceBytes: sourceStorage.utf8.count, outputLines: outputStorage.lines.count, kind: .thematicBreak)
            default:
                break
            }
        }

        if let boundary = sourceStorage.range(of: "\n\n", options: .backwards) {
            let byteCount = sourceStorage[..<boundary.upperBound].utf8.count
            let lineThreshold = sourceStorage[..<boundary.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).count
            let lineCount = outputStorage.lines.lastIndex(where: {
                $0.sourceLine < lineThreshold
            }).map { $0 + 1 } ?? 0

            frozenSourceByteCount = byteCount
            frozenOutputLineCount = lineCount
            lastCheckpointStorage = lastValidCheckpoint ?? MarkdownCheckpoint(sourceBytes: byteCount, outputLines: lineCount, kind: .paragraph)
        } else {
            frozenSourceByteCount = 0
            frozenOutputLineCount = 0
            lastCheckpointStorage = nil
        }
    }
}
