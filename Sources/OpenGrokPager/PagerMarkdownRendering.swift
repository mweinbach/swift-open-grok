import Foundation
import OpenGrokMarkdown
import OpenGrokPagerRender
import OpenGrokTerminalCore

/// Maps `OpenGrokMarkdown` render output onto the pager's styled-span model.
///
/// This is the only place markdown vocabulary meets terminal paint attributes;
/// the render layer stays markdown-agnostic and the sampler/provider layers
/// never see either.
public struct PagerMarkdownRenderer: Sendable {
    public var configuration: MarkdownRenderConfiguration

    public init(configuration: MarkdownRenderConfiguration = MarkdownRenderConfiguration()) {
        self.configuration = configuration
    }

    /// Render `source` into styled pager lines.
    ///
    /// Returns an empty array when the source renders to nothing usable, which
    /// callers treat as "paint the raw text instead". Markdown parsing is
    /// total — malformed input degrades to literal text rather than failing —
    /// so this is a content check, not an error check.
    public func render(_ source: String) -> [PagerStyledLine] {
        guard !source.isEmpty else { return [] }
        let lines = Self.map(MarkdownRenderer(configuration: configuration).render(source))
        // Never let styling swallow the answer: if the render produced nothing
        // visible for a source that had visible content, report no styled lines
        // so the caller paints the raw text instead.
        guard !lines.isEmpty else { return [] }
        let rendered = lines.map(\.text).joined()
        if rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return []
        }
        return lines
    }

    public func makeStreamingRenderer(
        maxTableWidth: Int? = nil
    ) -> PagerStreamingMarkdownRenderer {
        var resolved = configuration
        resolved.maxTableWidth = maxTableWidth
        return PagerStreamingMarkdownRenderer(configuration: resolved)
    }

    /// Map an already-rendered markdown document onto styled pager lines.
    public static func map(_ output: MarkdownRenderOutput) -> [PagerStyledLine] {
        guard !output.lines.isEmpty else { return [] }
        let linksByLine = Dictionary(grouping: output.hyperlinks, by: \.lineIndex)
        return output.lines.enumerated().map { lineIndex, line in
            let mappedSpans = spans(
                for: line,
                hyperlinks: linksByLine[lineIndex] ?? []
            )
            let renderedText = mappedSpans.map(\.text).joined()
            let hasQuoteDecoration = line.segments.first?.style == .quote
            return PagerStyledLine(
                spans: mappedSpans,
                background: line.background == .code ? .code : nil,
                selectionText: hasQuoteDecoration ? quoteSelectionText(renderedText) : nil
            )
        }
    }

    /// Paint attributes for one markdown inline style.
    ///
    /// `nil` foreground means "inherit the message role color", which keeps
    /// ordinary prose in the assistant's color and reserves explicit colors for
    /// runs that genuinely differ.
    public static func attributes(
        for style: MarkdownTextStyle
    ) -> (foreground: TerminalColor?, style: CellStyle) {
        switch style {
        case .plain:
            return (nil, [])
        case .syntax:
            return (.brightBlack, [.dim])
        case .heading(let level):
            return (.brightCyan, level <= 1 ? [.bold, .underline] : [.bold])
        case .strong:
            return (nil, [.bold])
        case .emphasis:
            return (nil, [.italic])
        case .strikethrough:
            return (nil, [.strike])
        case .code:
            return (.brightYellow, [])
        case .syntaxKeyword:
            return (.brightMagenta, [.bold])
        case .syntaxString:
            return (.brightGreen, [])
        case .syntaxNumber:
            return (.brightCyan, [])
        case .syntaxComment:
            return (.brightBlack, [.dim, .italic])
        case .syntaxType:
            return (.brightBlue, [])
        case .quote:
            return (.brightBlack, [.italic])
        case .listMarker:
            return (.brightCyan, [])
        case .tableBorder:
            return (.brightBlack, [])
        case .link:
            return (.brightBlue, [.underline])
        case .image:
            return (.brightMagenta, [])
        }
    }

    /// Split one rendered markdown line into styled spans, further splitting at
    /// hyperlink boundaries so each link becomes its own addressable span.
    ///
    /// Hyperlink column ranges are Character offsets into the line's text, so
    /// the walk here counts Characters rather than display columns.
    private static func spans(
        for line: MarkdownRenderLine,
        hyperlinks: [MarkdownHyperlink]
    ) -> [PagerStyledSpan] {
        var spans: [PagerStyledSpan] = []
        var column = 0
        for segment in line.segments {
            let (foreground, style) = attributes(for: segment.style)
            let characters = Array(segment.text)
            var offset = 0
            while offset < characters.count {
                let absolute = column + offset
                let link = hyperlinks.first { $0.columnRange.contains(absolute) }
                let boundary: Int
                if let link {
                    boundary = min(characters.count, link.columnRange.upperBound - column)
                } else {
                    boundary = hyperlinks
                        .map(\.columnRange.lowerBound)
                        .filter { $0 > absolute }
                        .min()
                        .map { min(characters.count, $0 - column) }
                        ?? characters.count
                }
                let end = max(offset + 1, boundary)
                spans.append(PagerStyledSpan(
                    text: String(characters[offset..<min(end, characters.count)]),
                    foreground: foreground,
                    style: style,
                    url: link?.url
                ))
                offset = end
            }
            column += characters.count
        }
        return spans
    }

    private static func quoteSelectionText(_ text: String) -> String {
        var remaining = text[...]
        while remaining.first == "│" {
            remaining = remaining.dropFirst()
            if remaining.first == " " { remaining = remaining.dropFirst() }
        }
        return String(remaining)
    }
}

public struct PagerStreamingMarkdownRenderer: Sendable {
    private var renderer: StreamingMarkdownRenderer

    public init(configuration: MarkdownRenderConfiguration = MarkdownRenderConfiguration()) {
        renderer = StreamingMarkdownRenderer(configuration: configuration)
    }

    public var source: String { renderer.source }
    public var frozenBytes: Int { renderer.frozenBytes }
    public var frozenLinesCount: Int { renderer.frozenLinesCount }
    public var lastRenderedSourceByteCount: Int { renderer.lastRenderedSourceByteCount }

    @discardableResult
    public mutating func pushAndRender(_ chunk: String) -> [PagerStyledLine] {
        PagerMarkdownRenderer.map(renderer.pushAndRender(chunk))
    }

    @discardableResult
    public mutating func render() -> [PagerStyledLine] {
        PagerMarkdownRenderer.map(renderer.render())
    }

    @discardableResult
    public mutating func finish() -> [PagerStyledLine] {
        PagerMarkdownRenderer.map(renderer.finish())
    }

    @discardableResult
    public mutating func setMaxTableWidth(_ width: Int?) -> [PagerStyledLine] {
        renderer.setMaxTableWidth(width)
        return render()
    }
}
