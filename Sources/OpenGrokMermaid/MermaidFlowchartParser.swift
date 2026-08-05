// MermaidFlowchartParser.swift
//
// Open Grok — Swift port of `mermaid_to_svg::parser`
// (third_party/mermaid-to-svg/src/parser.rs, W8-S2).
//
// A line-oriented recursive-descent parser for the `graph`/`flowchart` grammar:
// node declarations with shape brackets, edge chains with several arrow styles
// and two label syntaxes, nested `subgraph ... end` blocks, and `style` lines.

import Foundation

/// Mermaid diagram families, and which of them this port renders.
public enum MermaidDiagramFamily {
    /// Leading tokens this port renders.
    public static let supported: Set<String> = [
        "graph", "flowchart", "stateDiagram", "stateDiagram-v2",
    ]

    /// Leading tokens Mermaid recognizes that this port does not render. The
    /// dispatcher reports these as `unsupportedDiagramType` rather than trying
    /// to parse them as a flowchart.
    public static let knownButUnsupported: Set<String> = [
        "sequenceDiagram", "classDiagram", "classDiagram-v2", "erDiagram", "journey",
        "gantt", "pie", "mindmap", "timeline", "info", "kanban", "gitGraph",
        "requirementDiagram", "C4Context", "C4Container", "C4Component", "C4Dynamic",
        "C4Deployment", "sankey-beta", "packet-beta", "xychart-beta", "radar-beta",
        "block-beta", "flowchart-elk", "quadrantChart",
    ]

    /// The leading token of `source`, ignoring blanks and `%%` comments.
    public static func firstToken(of source: String) -> String? {
        for rawLine in splitIntoLines(source) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("%%") { continue }
            return line.split(whereSeparator: \.isWhitespace).first.map(String.init)
        }
        return nil
    }
}

/// Parses a `graph`/`flowchart` source into a `FlowchartGraph`.
public func parseFlowchart(_ input: String) throws -> FlowchartGraph {
    if let token = MermaidDiagramFamily.firstToken(of: input),
       token != "graph", token != "flowchart",
       MermaidDiagramFamily.knownButUnsupported.contains(token) {
        throw MermaidError.unsupportedDiagramType(token)
    }

    var parser = FlowchartParser(input)
    return try parser.parse()
}

private struct FlowchartParser {
    private let lines: [String]
    private var currentLine = 0
    private var nextSubgraphIndex = 0

    init(_ input: String) {
        lines = splitIntoLines(input)
    }

    mutating func parse() throws -> FlowchartGraph {
        let direction = try parseGraphDeclaration()
        return FlowchartGraph(direction: direction, statements: try parseStatements())
    }

    private var currentContent: String? {
        currentLine < lines.count ? lines[currentLine].trimmingCharacters(in: .whitespaces) : nil
    }

    private mutating func advance() {
        currentLine += 1
    }

    private mutating func skipEmptyLines() {
        while let line = currentContent, line.isEmpty || line.hasPrefix("%%") {
            advance()
        }
    }

    private mutating func parseGraphDeclaration() throws -> GraphDirection {
        skipEmptyLines()

        guard let line = currentContent else {
            throw MermaidError.parse(line: currentLine + 1, message: "Expected graph declaration")
        }
        guard line.hasPrefix("graph ") || line.hasPrefix("flowchart ") else {
            throw MermaidError.parse(
                line: currentLine + 1,
                message: "Expected 'graph' or 'flowchart' declaration"
            )
        }

        let parts = line.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2 else {
            throw MermaidError.parse(
                line: currentLine + 1,
                message: "Expected direction after 'graph' or 'flowchart'"
            )
        }
        guard let direction = GraphDirection.parse(String(parts[1])) else {
            throw MermaidError.invalidDirection(String(parts[1]))
        }

        advance()
        return direction
    }

    private mutating func parseStatements() throws -> [FlowchartStatement] {
        var statements: [FlowchartStatement] = []

        while currentContent != nil {
            skipEmptyLines()
            guard let line = currentContent else { break }

            if line.isEmpty {
                advance()
                continue
            }
            if line == "end" { break }

            if line.hasPrefix("subgraph ") {
                statements.append(.subgraph(try parseSubgraph()))
            } else if line.hasPrefix("style ") {
                statements.append(.style(try parseStyle()))
            } else if findEdgeStart(line) != nil {
                statements.append(contentsOf: try parseEdgeChain(line))
                advance()
            } else {
                if let node = parseNode(line) {
                    statements.append(.node(node))
                }
                advance()
            }
        }

        return statements
    }

    /// Parses `A --> B -- label --> C` into its node and edge statements, nodes
    /// first so the layout sees declarations before the connections.
    private func parseEdgeChain(_ line: String) throws -> [FlowchartStatement] {
        var edges: [FlowchartStatement] = []
        var remaining = Substring(line.trimmingCharacters(in: .whitespaces))
        var collected: [(id: String, node: FlowchartNode?)] = []

        let firstEnd = findEdgeStart(remaining) ?? remaining.endIndex
        let firstText = remaining[..<firstEnd].trimmingCharacters(in: .whitespaces)
        if let node = parseNode(firstText) {
            collected.append((node.id, node))
        } else {
            collected.append((extractNodeID(firstText), nil))
        }
        remaining = remaining[firstEnd...]

        while !remaining.isEmpty {
            let syntax = try parseEdgeSyntax(remaining)
            remaining = remaining[syntax.end...].drop(while: \.isWhitespace)

            let nextEnd = findEdgeStart(remaining) ?? remaining.endIndex
            let nextText = remaining[..<nextEnd].trimmingCharacters(in: .whitespaces)
            if nextText.isEmpty { break }

            let nextID: String
            let nextNode: FlowchartNode?
            if let node = parseNode(nextText) {
                (nextID, nextNode) = (node.id, node)
            } else {
                (nextID, nextNode) = (extractNodeID(nextText), nil)
            }

            if let previous = collected.last {
                edges.append(
                    .edge(
                        FlowchartEdge(
                            from: previous.id,
                            to: nextID,
                            label: syntax.label,
                            style: syntax.style
                        )
                    )
                )
            }

            collected.append((nextID, nextNode))
            remaining = remaining[nextEnd...]
        }

        return collected.compactMap { $0.node.map(FlowchartStatement.node) } + edges
    }

    /// Where the first edge token starts, skipping tokens nested inside a node
    /// label's brackets or quotes so `A["x --> y"]` is not read as an edge.
    private func findEdgeStart(_ text: some StringProtocol) -> String.Index? {
        let patterns = ["-.->", "-.-", "-->", "---", "==>", "===", "--", "==", "-."]
        var depth = 0
        var inQuote = false

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if inQuote {
                if character == "\"" { inQuote = false }
                index = text.index(after: index)
                continue
            }
            switch character {
            case "\"":
                inQuote = true
            case "[", "(", "{":
                depth += 1
            case "]", ")", "}":
                depth = max(depth - 1, 0)
            default:
                if depth == 0, patterns.contains(where: { text[index...].hasPrefix($0) }) {
                    return index
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private struct EdgeSyntax {
        var style: EdgeStyle
        var label: String?
        /// Index just past the consumed edge token.
        var end: String.Index
    }

    private func parseEdgeSyntax(_ input: Substring) throws -> EdgeSyntax {
        let text = input.drop(while: \.isWhitespace)

        // Bracketed-label forms: `-->|text|`.
        let bracketed: [(pattern: String, style: EdgeStyle)] = [
            ("-->|", .arrow), ("---|", .line), ("-.->|", .dottedArrow),
            ("-.-|", .dottedLine), ("==>|", .thickArrow), ("===|", .thickLine),
        ]
        // Bare forms, matched in the same order as upstream so `-->` wins over
        // the `--` open form.
        let bare: [(pattern: String, style: EdgeStyle)] = [
            ("-->", .arrow), ("---", .line), ("-.->", .dottedArrow),
            ("-.-", .dottedLine), ("==>", .thickArrow), ("===", .thickLine),
        ]

        for (pattern, style) in bracketed {
            guard text.hasPrefix(pattern) else { continue }
            let afterPattern = text.dropFirst(pattern.count)
            guard let labelEnd = afterPattern.firstIndex(of: "|") else { continue }
            return EdgeSyntax(
                style: style,
                label: normalizeLabel(String(afterPattern[..<labelEnd])),
                end: afterPattern.index(after: labelEnd)
            )
        }

        for (pattern, style) in bare where text.hasPrefix(pattern) {
            return EdgeSyntax(style: style, label: nil, end: text.index(text.startIndex, offsetBy: pattern.count))
        }

        // Open-label forms: `-- text -->`, `== text ===`, `-. text .->`.
        let open: [(opener: String, closers: [(closer: String, style: EdgeStyle)])] = [
            ("--", [("-->", .arrow), ("---", .line)]),
            ("==", [("==>", .thickArrow), ("===", .thickLine)]),
            ("-.", [(".->", .dottedArrow), (".-", .dottedLine)]),
        ]
        for (opener, closers) in open {
            guard text.hasPrefix(opener) else { continue }
            let after = text.dropFirst(opener.count)

            var best: (range: Range<String.Index>, style: EdgeStyle)?
            for (closer, style) in closers {
                guard let range = after.range(of: closer) else { continue }
                let isBetter: Bool
                if let current = best {
                    // Earliest closer wins; on a tie the longer one does, so
                    // `---` is preferred over a `-->` starting at the same spot.
                    isBetter = range.lowerBound < current.range.lowerBound
                        || (range.lowerBound == current.range.lowerBound
                            && after.distance(from: range.lowerBound, to: range.upperBound)
                                > after.distance(from: current.range.lowerBound, to: current.range.upperBound))
                } else {
                    isBetter = true
                }
                if isBetter { best = (range, style) }
            }

            if let best {
                return EdgeSyntax(
                    style: best.style,
                    label: normalizeLabel(String(after[..<best.range.lowerBound])),
                    end: best.range.upperBound
                )
            }
        }

        throw MermaidError.parse(line: currentLine + 1, message: "Invalid edge syntax: \(text)")
    }

    /// The bare id preceding a node's shape brackets.
    private func extractNodeID(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        for opener: Character in ["[", "(", "{", "<"] {
            if let index = trimmed.firstIndex(of: opener) {
                return String(trimmed[..<index]).trimmingCharacters(in: .whitespaces)
            }
        }
        return trimmed
    }

    /// Parses `id[label]` and friends. Returns nil when `text` is not a node.
    private func parseNode(_ text: String) -> FlowchartNode? {
        let s = text.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }

        // Two-character brackets first: `A[[x]]` must not be read as `A[[x]`.
        let paired: [(open: String, close: String, shape: NodeShape)] = [
            ("((", "))", .circle),
            ("([", "])", .stadium),
            ("[(", ")]", .cylinder),
            ("[[", "]]", .subroutine),
            ("{{", "}}", .hexagon),
        ]
        for (open, close, shape) in paired {
            guard let start = s.range(of: open), s.hasSuffix(close) else { continue }
            let labelRange = start.upperBound..<s.index(s.endIndex, offsetBy: -close.count)
            guard labelRange.lowerBound <= labelRange.upperBound else { continue }
            return makeNode(
                id: String(s[..<start.lowerBound]),
                label: normalizeLabel(String(s[labelRange])),
                shape: shape
            )
        }

        let single: [(open: Character, close: Character, forbiddenSuffix: String?, shape: NodeShape)] = [
            ("[", "]", nil, .rectangle),
            ("(", ")", "))", .roundedRectangle),
            ("{", "}", "}}", .diamond),
        ]
        for (open, close, forbiddenSuffix, shape) in single {
            guard let start = s.firstIndex(of: open), s.hasSuffix(String(close)) else { continue }
            if let forbiddenSuffix, s.hasSuffix(forbiddenSuffix) { continue }
            let labelRange = s.index(after: start)..<s.index(before: s.endIndex)
            guard labelRange.lowerBound <= labelRange.upperBound else { continue }
            return makeNode(
                id: String(s[..<start]),
                label: normalizeLabel(String(s[labelRange])),
                shape: shape
            )
        }

        // Asymmetric flag: `A>text]`.
        if s.contains(">"), s.hasSuffix("]"), let gt = s.firstIndex(of: ">") {
            let labelRange = s.index(after: gt)..<s.index(before: s.endIndex)
            if labelRange.lowerBound <= labelRange.upperBound {
                return FlowchartNode(
                    id: String(s[..<gt]).trimmingCharacters(in: .whitespaces),
                    label: normalizeLabel(String(s[labelRange])),
                    shape: .asymmetric
                )
            }
        }

        // A bare identifier is a rectangle labelled with its own id.
        if s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
            return FlowchartNode(id: s, label: nil, shape: .rectangle)
        }

        return nil
    }

    /// Builds a node, deriving an id from the label when the source omitted one.
    private func makeNode(id: String, label: String, shape: NodeShape) -> FlowchartNode {
        let trimmedID = id.trimmingCharacters(in: .whitespaces)
        let resolvedID = trimmedID.isEmpty
            ? String(label.filter { $0.isLetter || $0.isNumber })
            : trimmedID
        return FlowchartNode(id: resolvedID, label: label, shape: shape)
    }

    private mutating func parseSubgraph() throws -> FlowchartSubgraph {
        guard let line = currentContent else {
            throw MermaidError.parse(line: currentLine + 1, message: "Expected subgraph")
        }

        let afterKeyword = String(line.dropFirst("subgraph ".count))
            .trimmingCharacters(in: .whitespaces)

        var id: String
        var title: String?
        if let bracket = afterKeyword.firstIndex(of: "["), afterKeyword.hasSuffix("]") {
            id = String(afterKeyword[..<bracket]).trimmingCharacters(in: .whitespaces)
            let labelRange = afterKeyword.index(after: bracket)..<afterKeyword.index(before: afterKeyword.endIndex)
            title = normalizeLabel(String(afterKeyword[labelRange]))
        } else if afterKeyword.split(whereSeparator: \.isWhitespace).count > 1 {
            // A multi-word title with no id: Mermaid synthesizes `subGraphN`.
            id = "subGraph\(nextSubgraphIndex)"
            nextSubgraphIndex += 1
            title = normalizeLabel(afterKeyword)
        } else {
            id = afterKeyword
        }

        advance()
        let statements = try parseStatements()
        if currentContent == "end" { advance() }

        return FlowchartSubgraph(id: id, title: title, statements: statements)
    }

    private mutating func parseStyle() throws -> StyleStatement {
        guard let line = currentContent else {
            throw MermaidError.parse(line: currentLine + 1, message: "Expected style statement")
        }

        let afterKeyword = String(line.dropFirst("style ".count)).trimmingCharacters(in: .whitespaces)
        let parts = afterKeyword.split(separator: " ", maxSplits: 1).map(String.init)
        guard let nodeID = parts.first else {
            throw MermaidError.parse(line: currentLine + 1, message: "Expected node id after 'style'")
        }

        var properties: [(key: String, value: String)] = []
        if parts.count > 1 {
            for property in parts[1].split(separator: ",") {
                let pair = property.split(separator: ":", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                properties.append(
                    (
                        pair[0].trimmingCharacters(in: .whitespaces),
                        pair[1].trimmingCharacters(in: .whitespaces)
                    )
                )
            }
        }

        advance()
        return StyleStatement(nodeID: nodeID, properties: properties)
    }
}

/// Splits `text` the way Rust's `str::lines` does: an empty string has no
/// lines, a trailing newline does not add an empty one, and `\r\n` is handled.
/// Line numbers in `MermaidError.parse` are indices into this.
func splitIntoLines(_ text: String) -> [String] {
    guard !text.isEmpty else { return [] }
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.last == "" { lines.removeLast() }
    return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
}

/// Strips wrapping quotes, decodes the HTML entities Mermaid accepts, and turns
/// the several line-break spellings into real newlines.
func normalizeLabel(_ label: String) -> String {
    var text = label.trimmingCharacters(in: .whitespaces)
    if text.count >= 2,
       let first = text.first, let last = text.last,
       (first == "\"" && last == "\"") || (first == "'" && last == "'") {
        text = String(text.dropFirst().dropLast())
    }

    for (entity, replacement) in [
        ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
        ("&apos;", "'"), ("&amp;", "&"),
    ] {
        text = text.replacingOccurrences(of: entity, with: replacement)
    }

    for lineBreak in ["\\n", "<br/>", "<br />", "<br>", "<BR/>", "<BR />", "<BR>"] {
        text = text.replacingOccurrences(of: lineBreak, with: "\n")
    }

    return text
}
