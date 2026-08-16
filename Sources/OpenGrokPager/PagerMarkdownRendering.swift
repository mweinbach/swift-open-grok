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
    public var mermaidWorker: PagerMermaidWorker?

    public init(
        configuration: MarkdownRenderConfiguration = MarkdownRenderConfiguration(),
        mermaidWorker: PagerMermaidWorker? = .shared
    ) {
        self.configuration = configuration
        self.mermaidWorker = mermaidWorker
    }

    /// Render `source` into styled pager lines.
    ///
    /// Returns an empty array when the source renders to nothing usable, which
    /// callers treat as "paint the raw text instead". Markdown parsing is
    /// total — malformed input degrades to literal text rather than failing —
    /// so this is a content check, not an error check.
    public func render(_ source: String) -> [PagerStyledLine] {
        guard !source.isEmpty else { return [] }
        let lines = Self.map(
            MarkdownRenderer(configuration: configuration).render(source),
            mermaidWorker: mermaidWorker,
            width: configuration.maxTableWidth ?? 80,
            source: source
        )
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
        return PagerStreamingMarkdownRenderer(
            configuration: resolved,
            mermaidWorker: mermaidWorker
        )
    }

    /// Map an already-rendered markdown document onto styled pager lines.
    public static func map(_ output: MarkdownRenderOutput) -> [PagerStyledLine] {
        map(output, mermaidWorker: .shared, width: 80, source: nil)
    }

    static func map(
        _ output: MarkdownRenderOutput,
        mermaidWorker: PagerMermaidWorker?,
        width: Int,
        source: String?
    ) -> [PagerStyledLine] {
        guard !output.lines.isEmpty else { return [] }
        let linksByLine = Dictionary(grouping: output.hyperlinks, by: \.lineIndex)
        let mermaidPairs: [(Int, MarkdownCodeBlockSpan)] = output.codeBlocks.compactMap { span in
            guard isMermaidInfo(span.info) else { return nil }
            return (span.outputLineRange.lowerBound, span)
        }
        let mermaidByStart = Dictionary(uniqueKeysWithValues: mermaidPairs)
        var closedBodies = source.map(closedMermaidBodyCounts)
        var result: [PagerStyledLine] = []
        var lineIndex = 0
        while lineIndex < output.lines.count {
            if let span = mermaidByStart[lineIndex],
               consumeClosedMermaid(span.body, from: &closedBodies),
               let rendered = mermaidWorker?.render(source: span.body, width: width)
            {
                result.append(contentsOf: rendered.lines.map {
                    PagerStyledLine(
                        text: $0,
                        foreground: .brightCyan,
                        background: .code,
                        selectionText: $0
                    )
                })
                result.append(mermaidAffordanceLine(width: width))
                lineIndex = max(lineIndex + 1, span.outputLineRange.upperBound)
                continue
            }

            result.append(mappedLine(
                output.lines[lineIndex],
                hyperlinks: linksByLine[lineIndex] ?? []
            ))
            lineIndex += 1
        }
        return result
    }

    private static func mappedLine(
        _ line: MarkdownRenderLine,
        hyperlinks: [MarkdownHyperlink]
    ) -> PagerStyledLine {
        let mappedSpans = spans(for: line, hyperlinks: hyperlinks)
        let renderedText = mappedSpans.map(\.text).joined()
        let hasQuoteDecoration = line.segments.first?.style == .quote
        return PagerStyledLine(
            spans: mappedSpans,
            background: line.background == .code ? .code : nil,
            selectionText: hasQuoteDecoration ? quoteSelectionText(renderedText) : nil
        )
    }

    private static func isMermaidInfo(_ info: String) -> Bool {
        info.split(whereSeparator: \.isWhitespace).first?.lowercased() == "mermaid"
    }

    private static func consumeClosedMermaid(
        _ body: String,
        from counts: inout [String: Int]?
    ) -> Bool {
        guard var counts else { return true }
        let key = normalizedMermaidBody(body)
        guard let count = counts[key], count > 0 else { return false }
        if count == 1 {
            counts.removeValue(forKey: key)
        } else {
            counts[key] = count - 1
        }
        return true
    }

    private static func closedMermaidBodyCounts(_ source: String) -> [String: Int] {
        struct Fence {
            var marker: Character
            var length: Int
            var isMermaid: Bool
            var body: [String]
        }

        var counts: [String: Int] = [:]
        var fence: Fence?
        for line in source.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var current = fence {
                let closingLength = trimmed.prefix { $0 == current.marker }.count
                let remainder = trimmed.dropFirst(closingLength)
                if closingLength >= current.length,
                   remainder.trimmingCharacters(in: .whitespaces).isEmpty
                {
                    if current.isMermaid {
                        counts[normalizedMermaidBody(current.body.joined(separator: "\n")), default: 0] += 1
                    }
                    fence = nil
                } else {
                    current.body.append(line)
                    fence = current
                }
                continue
            }

            guard let marker = trimmed.first, marker == "`" || marker == "~" else { continue }
            let length = trimmed.prefix { $0 == marker }.count
            guard length >= 3 else { continue }
            let info = trimmed.dropFirst(length).trimmingCharacters(in: .whitespaces)
            fence = Fence(
                marker: marker,
                length: length,
                isMermaid: isMermaidInfo(info),
                body: []
            )
        }
        return counts
    }

    private static func normalizedMermaidBody(_ body: String) -> String {
        body.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .newlines)
    }

    private static func mermaidAffordanceLine(width: Int) -> PagerStyledLine {
        let labels = ["[Open Image]", "[Copy Image Path]", "[Copy Source]"]
        var spans = [PagerStyledSpan(text: "◇ mermaid", foreground: .brightBlack, style: [.dim])]
        var used = UnicodeDisplayWidth.width(of: "◇ mermaid")
        for label in labels {
            let gap = "   "
            let needed = UnicodeDisplayWidth.width(of: gap + label)
            guard used + needed <= max(1, width) else { break }
            spans.append(PagerStyledSpan(text: gap, foreground: .brightBlack))
            spans.append(PagerStyledSpan(text: label, foreground: .brightBlue, style: [.bold]))
            used += needed
        }
        return PagerStyledLine(spans: spans, selectionText: "")
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
    private let mermaidWorker: PagerMermaidWorker?
    private var maxWidth: Int

    public init(
        configuration: MarkdownRenderConfiguration = MarkdownRenderConfiguration(),
        mermaidWorker: PagerMermaidWorker? = .shared
    ) {
        renderer = StreamingMarkdownRenderer(configuration: configuration)
        self.mermaidWorker = mermaidWorker
        maxWidth = configuration.maxTableWidth ?? 80
    }

    public var source: String { renderer.source }
    public var frozenBytes: Int { renderer.frozenBytes }
    public var frozenLinesCount: Int { renderer.frozenLinesCount }
    public var lastRenderedSourceByteCount: Int { renderer.lastRenderedSourceByteCount }

    @discardableResult
    public mutating func pushAndRender(_ chunk: String) -> [PagerStyledLine] {
        PagerMarkdownRenderer.map(
            renderer.pushAndRender(chunk),
            mermaidWorker: mermaidWorker,
            width: maxWidth,
            source: renderer.source
        )
    }

    @discardableResult
    public mutating func render() -> [PagerStyledLine] {
        PagerMarkdownRenderer.map(
            renderer.render(),
            mermaidWorker: mermaidWorker,
            width: maxWidth,
            source: renderer.source
        )
    }

    @discardableResult
    public mutating func finish() -> [PagerStyledLine] {
        PagerMarkdownRenderer.map(
            renderer.finish(),
            mermaidWorker: mermaidWorker,
            width: maxWidth,
            source: renderer.source
        )
    }

    @discardableResult
    public mutating func setMaxTableWidth(_ width: Int?) -> [PagerStyledLine] {
        renderer.setMaxTableWidth(width)
        maxWidth = width ?? 80
        return render()
    }
}
