import Foundation

public enum MarkdownAlignment: String, Sendable, Equatable {
    case none
    case left
    case center
    case right
}

public enum MarkdownTaskState: Sendable, Equatable {
    case none
    case unchecked
    case checked
}

public indirect enum MarkdownInline: Sendable, Equatable {
    case text(String)
    case strong([MarkdownInline])
    case emphasis([MarkdownInline])
    case strikethrough([MarkdownInline])
    case code(String)
    case link(text: [MarkdownInline], destination: String, title: String?)
    case image(alt: [MarkdownInline], destination: String, title: String?)
    case math(String, display: Bool)
    case softBreak
    case hardBreak
}

public struct MarkdownTable: Sendable, Equatable {
    public let header: [[MarkdownInline]]
    public let rows: [[[MarkdownInline]]]
    public let alignments: [MarkdownAlignment]
    public let sourceLines: [Int]

    public init(
        header: [[MarkdownInline]],
        rows: [[[MarkdownInline]]],
        alignments: [MarkdownAlignment],
        sourceLines: [Int]
    ) {
        self.header = header
        self.rows = rows
        self.alignments = alignments
        self.sourceLines = sourceLines
    }
}

public struct MarkdownCodeBlock: Sendable, Equatable {
    public let info: String
    public let body: String
    public let fenced: Bool
    public let closed: Bool
    public let sourceLine: Int
    public let sourceByteRange: Range<Int>

    public init(
        info: String,
        body: String,
        fenced: Bool,
        closed: Bool,
        sourceLine: Int,
        sourceByteRange: Range<Int>
    ) {
        self.info = info
        self.body = body
        self.fenced = fenced
        self.closed = closed
        self.sourceLine = sourceLine
        self.sourceByteRange = sourceByteRange
    }
}

public struct MarkdownListItem: Sendable, Equatable {
    public let blocks: [MarkdownBlock]
    public let task: MarkdownTaskState
    public let sourceLine: Int

    public init(blocks: [MarkdownBlock], task: MarkdownTaskState, sourceLine: Int) {
        self.blocks = blocks
        self.task = task
        self.sourceLine = sourceLine
    }
}

public indirect enum MarkdownBlockKind: Sendable, Equatable {
    case paragraph([MarkdownInline])
    case heading(level: Int, content: [MarkdownInline])
    case quote([MarkdownBlock])
    case list(ordered: Bool, start: Int, items: [MarkdownListItem])
    case code(MarkdownCodeBlock)
    case thematicBreak
    case table(MarkdownTable)
}

public struct MarkdownBlock: Sendable, Equatable {
    public let kind: MarkdownBlockKind
    public let sourceLine: Int

    public init(kind: MarkdownBlockKind, sourceLine: Int) {
        self.kind = kind
        self.sourceLine = sourceLine
    }
}

public struct MarkdownDocument: Sendable, Equatable {
    public let blocks: [MarkdownBlock]
    public let source: String

    public init(blocks: [MarkdownBlock], source: String) {
        self.blocks = blocks
        self.source = source
    }
}

public struct MarkdownParserOptions: Sendable, Equatable {
    public var tables: Bool
    public var maxNestingDepth: Int

    public init(tables: Bool = true, maxNestingDepth: Int = 32) {
        self.tables = tables
        self.maxNestingDepth = max(1, maxNestingDepth)
    }
}

public struct MarkdownParser: Sendable {
    public let options: MarkdownParserOptions

    public init(options: MarkdownParserOptions = MarkdownParserOptions()) {
        self.options = options
    }

    public func parse(_ text: String) -> MarkdownDocument {
        let normalized = normalizeLineEndings(text)
        let lines = sourceLines(normalized)
        let blocks = BlockParser(lines: lines, options: options).parse()
        return MarkdownDocument(blocks: blocks, source: normalized)
    }
}

public func parseMarkdown(_ text: String, options: MarkdownParserOptions = MarkdownParserOptions()) -> MarkdownDocument {
    MarkdownParser(options: options).parse(text)
}

public struct MarkdownStats: Sendable, Equatable {
    public var h1: Int = 0
    public var h2: Int = 0
    public var h3: Int = 0
    public var h4: Int = 0
    public var h5: Int = 0
    public var h6: Int = 0
    public var tables: Int = 0
    public var fencedCode: Int = 0
    public var indentedCode: Int = 0
    public var inlineCode: Int = 0
    public var strong: Int = 0
    public var emphasis: Int = 0
    public var strikethrough: Int = 0
    public var links: Int = 0
    public var images: Int = 0
    public var inlineMath: Int = 0
    public var displayMath: Int = 0
    public var blockquotes: Int = 0
    public var thematicBreaks: Int = 0
    public var taskListItems: Int = 0
    public var listItems: Int = 0

    public var headings: Int {
        h1 + h2 + h3 + h4 + h5 + h6
    }

    public func asPairs() -> [(String, Int)] {
        [
            ("headings", headings), ("h1", h1), ("h2", h2), ("h3", h3),
            ("h4", h4), ("h5", h5), ("h6", h6), ("tables", tables),
            ("fenced_code", fencedCode), ("indented_code", indentedCode),
            ("inline_code", inlineCode), ("strong", strong), ("emphasis", emphasis),
            ("strikethrough", strikethrough), ("links", links), ("images", images),
            ("blockquotes", blockquotes), ("thematic_breaks", thematicBreaks),
            ("inline_math", inlineMath), ("display_math", displayMath),
            ("task_list_items", taskListItems), ("list_items", listItems)
        ]
    }
}

public enum MarkdownStructuralIssue: Sendable, Equatable {
    case malformedTable
    case unterminatedCodeBlock
}

public struct MarkdownAnalysis: Sendable, Equatable {
    public let stats: MarkdownStats
    public let issues: [MarkdownStructuralIssue]

    public init(stats: MarkdownStats, issues: [MarkdownStructuralIssue]) {
        self.stats = stats
        self.issues = issues
    }
}

public func analyzeMarkdown(_ text: String, options: MarkdownParserOptions = MarkdownParserOptions()) -> MarkdownAnalysis {
    let normalized = normalizeLineEndings(text)
    let document = MarkdownParser(options: options).parse(normalized)
    var stats = MarkdownStats()
    for block in document.blocks {
        count(block.kind, into: &stats)
    }
    let lines = sourceLines(normalized)
    let issues = structuralIssues(lines: lines, options: options)
    return MarkdownAnalysis(stats: stats, issues: issues)
}

private struct SourceLine: Sendable {
    let text: String
    let number: Int
    let startByte: Int
    let endByte: Int
}

private struct FenceOpening {
    let character: Character
    let length: Int
    let info: String
}

private struct ListMarker {
    let indentation: Int
    let ordered: Bool
    let start: Int
    let markerWidth: Int
    let content: String
}

private struct BlockParser {
    let lines: [SourceLine]
    let options: MarkdownParserOptions

    func parse() -> [MarkdownBlock] {
        parseRange(lines, depth: 0)
    }

    func parseRange(_ input: [SourceLine], depth: Int) -> [MarkdownBlock] {
        guard depth < options.maxNestingDepth else {
            return input.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { MarkdownBlock(kind: .paragraph(InlineParser.parse($0.text)), sourceLine: $0.number) }
        }
        var result: [MarkdownBlock] = []
        var index = 0
        while index < input.count {
            let line = input[index]
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                index += 1
                continue
            }
            if let opening = fenceOpening(line.text) {
                let parsed = parseFence(input, at: index, opening: opening)
                result.append(parsed.block)
                index = parsed.nextIndex
                continue
            }
            if let heading = heading(line.text) {
                result.append(MarkdownBlock(kind: .heading(level: heading.level, content: InlineParser.parse(heading.content)), sourceLine: line.number))
                index += 1
                continue
            }
            if index + 1 < input.count, let level = setextLevel(input[index + 1].text), !trimmed.contains("|") {
                result.append(MarkdownBlock(kind: .heading(level: level, content: InlineParser.parse(trimmed)), sourceLine: line.number))
                index += 2
                continue
            }
            if isThematicBreak(line.text) {
                result.append(MarkdownBlock(kind: .thematicBreak, sourceLine: line.number))
                index += 1
                continue
            }
            if line.text.hasPrefix("    ") || line.text.hasPrefix("\t") {
                let parsed = parseIndentedCode(input, at: index)
                result.append(parsed.block)
                index = parsed.nextIndex
                continue
            }
            if isQuoteLine(line.text) {
                let parsed = parseQuote(input, at: index, depth: depth)
                result.append(parsed.block)
                index = parsed.nextIndex
                continue
            }
            if options.tables, index + 1 < input.count, let table = parseTable(input, at: index) {
                result.append(MarkdownBlock(kind: .table(table.table), sourceLine: line.number))
                index = table.nextIndex
                continue
            }
            if listMarker(line.text) != nil {
                let parsed = parseList(input, at: index, depth: depth)
                result.append(parsed.block)
                index = parsed.nextIndex
                continue
            }
            let parsed = parseParagraph(input, at: index)
            result.append(parsed.block)
            index = parsed.nextIndex
        }
        return result
    }

    private func parseParagraph(_ input: [SourceLine], at start: Int) -> (block: MarkdownBlock, nextIndex: Int) {
        var end = start + 1
        while end < input.count {
            let current = input[end]
            if current.text.trimmingCharacters(in: .whitespaces).isEmpty {
                break
            }
            if fenceOpening(current.text) != nil || heading(current.text) != nil ||
                isQuoteLine(current.text) || listMarker(current.text) != nil ||
                isThematicBreak(current.text) || (options.tables && end + 1 < input.count && parseTable(input, at: end) != nil) {
                break
            }
            end += 1
        }
        let content = input[start..<end].map(\.text).joined(separator: "\n")
        return (
            MarkdownBlock(kind: .paragraph(InlineParser.parse(content)), sourceLine: input[start].number),
            end
        )
    }

    private func parseFence(
        _ input: [SourceLine],
        at start: Int,
        opening: FenceOpening
    ) -> (block: MarkdownBlock, nextIndex: Int) {
        var closeIndex: Int?
        var cursor = start + 1
        while cursor < input.count {
            if isFenceClose(input[cursor].text, character: opening.character, minimumLength: opening.length) {
                closeIndex = cursor
                break
            }
            cursor += 1
        }
        let bodyEnd = closeIndex ?? input.count
        let bodyLines = input[(start + 1)..<bodyEnd].map(\.text)
        var body = bodyLines.joined(separator: "\n")
        if !bodyLines.isEmpty {
            body.append("\n")
        }
        let bodyStart = start + 1 < input.count ? input[start + 1].startByte : input[start].endByte + 1
        let bodyEndByte: Int
        if let closeIndex {
            bodyEndByte = input[closeIndex].startByte
        } else {
            bodyEndByte = input.last?.endByte ?? bodyStart
        }
        let code = MarkdownCodeBlock(
            info: opening.info,
            body: body,
            fenced: true,
            closed: closeIndex != nil,
            sourceLine: input[start].number,
            sourceByteRange: bodyStart..<max(bodyStart, bodyEndByte)
        )
        return (
            MarkdownBlock(kind: .code(code), sourceLine: input[start].number),
            (closeIndex ?? (input.count - 1)) + 1
        )
    }

    private func parseIndentedCode(_ input: [SourceLine], at start: Int) -> (block: MarkdownBlock, nextIndex: Int) {
        var end = start
        var bodyLines: [String] = []
        while end < input.count {
            let text = input[end].text
            if text.hasPrefix("    ") {
                bodyLines.append(String(text.dropFirst(4)))
                end += 1
            } else if text.hasPrefix("\t") {
                bodyLines.append(String(text.dropFirst()))
                end += 1
            } else if text.trimmingCharacters(in: .whitespaces).isEmpty {
                bodyLines.append("")
                end += 1
            } else {
                break
            }
        }
        while bodyLines.last?.isEmpty == true {
            bodyLines.removeLast()
        }
        var body = bodyLines.joined(separator: "\n")
        if !body.isEmpty {
            body.append("\n")
        }
        let code = MarkdownCodeBlock(
            info: "",
            body: body,
            fenced: false,
            closed: true,
            sourceLine: input[start].number,
            sourceByteRange: input[start].startByte..<((input[max(start, end - 1)].endByte))
        )
        return (MarkdownBlock(kind: .code(code), sourceLine: input[start].number), end)
    }

    private func parseQuote(_ input: [SourceLine], at start: Int, depth: Int) -> (block: MarkdownBlock, nextIndex: Int) {
        var quoted: [SourceLine] = []
        var end = start
        while end < input.count {
            let line = input[end]
            if let content = stripQuotePrefix(line.text) {
                quoted.append(SourceLine(text: content, number: line.number, startByte: line.startByte, endByte: line.endByte))
                end += 1
            } else if line.text.trimmingCharacters(in: .whitespaces).isEmpty {
                quoted.append(line)
                end += 1
            } else {
                break
            }
        }
        return (
            MarkdownBlock(kind: .quote(parseRange(quoted, depth: depth + 1)), sourceLine: input[start].number),
            end
        )
    }

    private func parseList(_ input: [SourceLine], at start: Int, depth: Int) -> (block: MarkdownBlock, nextIndex: Int) {
        guard let firstMarker = listMarker(input[start].text) else {
            return (MarkdownBlock(kind: .paragraph(InlineParser.parse(input[start].text)), sourceLine: input[start].number), start + 1)
        }
        var items: [MarkdownListItem] = []
        var index = start
        while index < input.count {
            guard let marker = listMarker(input[index].text), marker.indentation == firstMarker.indentation else {
                break
            }
            var itemLines: [SourceLine] = [
                SourceLine(
                    text: marker.content,
                    number: input[index].number,
                    startByte: input[index].startByte,
                    endByte: input[index].endByte
                )
            ]
            let itemSourceLine = input[index].number
            index += 1
            while index < input.count {
                let candidate = input[index]
                if let nextMarker = listMarker(candidate.text), nextMarker.indentation == firstMarker.indentation {
                    break
                }
                if candidate.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    itemLines.append(candidate)
                    index += 1
                    continue
                }
                let indentation = leadingSpaces(candidate.text)
                if indentation > firstMarker.indentation {
                    let remove = min(candidate.text.count, firstMarker.indentation + firstMarker.markerWidth)
                    itemLines.append(SourceLine(
                        text: String(candidate.text.dropFirst(remove)),
                        number: candidate.number,
                        startByte: candidate.startByte,
                        endByte: candidate.endByte
                    ))
                    index += 1
                    continue
                }
                break
            }
            var task = MarkdownTaskState.none
            if let taskMarker = taskMarker(itemLines.first?.text ?? "") {
                task = taskMarker.state
                itemLines[0] = SourceLine(
                    text: taskMarker.content,
                    number: itemLines[0].number,
                    startByte: itemLines[0].startByte,
                    endByte: itemLines[0].endByte
                )
            }
            let blocks = parseRange(itemLines, depth: depth + 1)
            if task != .none {
                items.append(MarkdownListItem(blocks: blocks, task: task, sourceLine: itemSourceLine))
            } else {
                items.append(MarkdownListItem(blocks: blocks, task: .none, sourceLine: itemSourceLine))
            }
        }
        return (
            MarkdownBlock(kind: .list(ordered: firstMarker.ordered, start: firstMarker.start, items: items), sourceLine: input[start].number),
            index
        )
    }

    private func parseTable(_ input: [SourceLine], at start: Int) -> (table: MarkdownTable, nextIndex: Int)? {
        guard start + 1 < input.count else { return nil }
        let header = splitTableCells(input[start].text)
        let delimiter = splitTableCells(input[start + 1].text)
        guard !header.isEmpty, header.count == delimiter.count else { return nil }
        guard delimiter.allSatisfy({ delimiterAlignment($0) != nil }) else { return nil }
        let alignments = delimiter.map { delimiterAlignment($0) ?? .none }
        var rows: [[[MarkdownInline]]] = []
        var sourceLines = [input[start].number, input[start + 1].number]
        var index = start + 2
        while index < input.count {
            let line = input[index]
            if line.text.trimmingCharacters(in: .whitespaces).isEmpty || line.text.first != "|" && !line.text.contains("|") {
                break
            }
            let cells = splitTableCells(line.text)
            if cells.isEmpty { break }
            var normalized = cells
            if normalized.count < header.count {
                normalized.append(contentsOf: Array(repeating: "", count: header.count - normalized.count))
            }
            if normalized.count > header.count {
                normalized = Array(normalized.prefix(header.count))
            }
            rows.append(normalized.map { InlineParser.parse($0) })
            sourceLines.append(line.number)
            index += 1
        }
        return (
            MarkdownTable(
                header: header.map { InlineParser.parse($0) },
                rows: rows,
                alignments: alignments,
                sourceLines: sourceLines
            ),
            index
        )
    }
}

private struct InlineParser {
    static func parse(_ source: String) -> [MarkdownInline] {
        var parser = InlineParser(source: source)
        return parser.parse(until: nil)
    }

    private let characters: [Character]
    private var index: Int = 0

    private init(source: String) {
        characters = Array(source)
    }

    private mutating func parse(until closing: Character?) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        while index < characters.count {
            if let closing, characters[index] == closing {
                index += 1
                break
            }
            if characters[index] == "\n" {
                let previousIsSpace = !result.isEmpty && textValue(result.last).last == " "
                if previousIsSpace {
                    result.append(.softBreak)
                } else if index >= 2 && characters[index - 1] == " " && characters[index - 2] == " " {
                    removeTrailingSpaces(&result)
                    result.append(.hardBreak)
                } else {
                    result.append(.softBreak)
                }
                index += 1
                continue
            }
            if characters[index] == "\\" && index + 1 < characters.count {
                if characters[index + 1] == "\n" {
                    result.append(.hardBreak)
                    index += 2
                    continue
                }
                if isMarkdownPunctuation(characters[index + 1]) {
                    appendText(String(characters[index + 1]), to: &result)
                    index += 2
                    continue
                }
            }
            let backtick = Character(UnicodeScalar(96)!)
            if characters[index] == backtick, let code = consumeCodeSpan(delimiter: backtick) {
                result.append(.code(code))
                continue
            }
            if characters[index] == "!" && index + 1 < characters.count && characters[index + 1] == "[",
               let image = consumeLink(image: true) {
                result.append(image)
                continue
            }
            if characters[index] == "[", let link = consumeLink(image: false) {
                result.append(link)
                continue
            }
            if characters[index] == "<", let link = consumeAutolink() {
                result.append(link)
                continue
            }
            if consumeDelimited("**", into: &result, kind: .strong) ||
                consumeDelimited("__", into: &result, kind: .strong) ||
                consumeDelimited("~~", into: &result, kind: .strikethrough) ||
                consumeDelimited("*", into: &result, kind: .emphasis) ||
                consumeDelimited("_", into: &result, kind: .emphasis) {
                continue
            }
            if let entity = consumeEntity() {
                appendText(entity, to: &result)
                continue
            }
            appendText(String(characters[index]), to: &result)
            index += 1
        }
        return result
    }

    private mutating func consumeCodeSpan(delimiter: Character) -> String? {
        let start = index
        var run = 0
        while index < characters.count && characters[index] == delimiter {
            run += 1
            index += 1
        }
        guard run > 0 else { return nil }
        var cursor = index
        while cursor < characters.count {
            if characters[cursor] == delimiter {
                var closeRun = 0
                while cursor + closeRun < characters.count && characters[cursor + closeRun] == delimiter {
                    closeRun += 1
                }
                if closeRun == run {
                    let raw = String(characters[index..<cursor]).replacingOccurrences(of: "\n", with: " ")
                    index = cursor + closeRun
                    if raw.count >= 2 && raw.first == " " && raw.last == " " && raw.dropLast().dropFirst().contains(where: { !$0.isWhitespace }) {
                        return String(raw.dropFirst().dropLast())
                    }
                    return raw
                }
                cursor += closeRun
            } else {
                cursor += 1
            }
        }
        index = start
        return nil
    }

    private mutating func consumeLink(image: Bool) -> MarkdownInline? {
        let opening = image ? index + 1 : index
        guard opening < characters.count, characters[opening] == "[" else { return nil }
        var cursor = opening + 1
        var depth = 1
        while cursor < characters.count {
            if characters[cursor] == "[" { depth += 1 }
            if characters[cursor] == "]" {
                depth -= 1
                if depth == 0 { break }
            }
            cursor += 1
        }
        guard cursor < characters.count, cursor + 1 < characters.count, characters[cursor + 1] == "(" else { return nil }
        var close = cursor + 2
        var parentheses = 1
        while close < characters.count {
            if characters[close] == "(" { parentheses += 1 }
            if characters[close] == ")" {
                parentheses -= 1
                if parentheses == 0 { break }
            }
            close += 1
        }
        guard close < characters.count else { return nil }
        let label = String(characters[(opening + 1)..<cursor])
        let destinationAndTitle = String(characters[(cursor + 2)..<close]).trimmingCharacters(in: .whitespaces)
        let parsedDestination = parseDestinationAndTitle(destinationAndTitle)
        guard !parsedDestination.destination.isEmpty else { return nil }
        index = close + 1
        let inline = InlineParser.parse(label)
        if image {
            return .image(alt: inline, destination: parsedDestination.destination, title: parsedDestination.title)
        }
        return .link(text: inline, destination: parsedDestination.destination, title: parsedDestination.title)
    }

    private mutating func consumeAutolink() -> MarkdownInline? {
        var cursor = index + 1
        while cursor < characters.count && characters[cursor] != ">" {
            cursor += 1
        }
        guard cursor < characters.count else { return nil }
        let value = String(characters[(index + 1)..<cursor])
        guard value.hasPrefix("http://") || value.hasPrefix("https://") || value.contains("@") else { return nil }
        index = cursor + 1
        return .link(text: [.text(value)], destination: value.contains("@") && !value.contains("://") ? "mailto:\(value)" : value, title: nil)
    }

    private mutating func consumeMath() -> MarkdownInline? {
        let display = index + 1 < characters.count && characters[index + 1] == "$"
        let delimiterLength = display ? 2 : 1
        var cursor = index + delimiterLength
        while cursor + delimiterLength <= characters.count {
            if display {
                if characters[cursor] == "$" && cursor + 1 < characters.count && characters[cursor + 1] == "$" {
                    let content = String(characters[(index + delimiterLength)..<cursor])
                    guard !content.isEmpty else { return nil }
                    index = cursor + 2
                    return .math(content, display: true)
                }
            } else if characters[cursor] == "$" {
                let content = String(characters[(index + 1)..<cursor])
                guard !content.isEmpty, !content.contains("\n") else { return nil }
                index = cursor + 1
                return .math(content, display: false)
            }
            cursor += 1
        }
        return nil
    }

    private mutating func consumeDelimited(
        _ delimiter: String,
        into result: inout [MarkdownInline],
        kind: DelimitedKind
    ) -> Bool {
        let chars = Array(delimiter)
        guard index + chars.count <= characters.count,
              Array(characters[index..<(index + chars.count)]) == chars else { return false }
        let start = index
        var cursor = index + chars.count
        while cursor + chars.count <= characters.count {
            if Array(characters[cursor..<(cursor + chars.count)]) == chars, cursor > index + chars.count {
                let content = String(characters[(index + chars.count)..<cursor])
                index = cursor + chars.count
                let parsed = InlineParser.parse(content)
                switch kind {
                case .strong: result.append(.strong(parsed))
                case .emphasis: result.append(.emphasis(parsed))
                case .strikethrough: result.append(.strikethrough(parsed))
                }
                return true
            }
            cursor += 1
        }
        index = start
        return false
    }

    private mutating func consumeEntity() -> String? {
        guard characters[index] == "&" else { return nil }
        var cursor = index + 1
        while cursor < characters.count && cursor - index <= 12 && characters[cursor] != ";" {
            cursor += 1
        }
        guard cursor < characters.count, characters[cursor] == ";" else { return nil }
        let raw = String(characters[index...cursor])
        guard let decoded = decodeEntity(raw) else { return nil }
        index = cursor + 1
        return decoded
    }

    private func appendText(_ value: String, to result: inout [MarkdownInline]) {
        guard !value.isEmpty else { return }
        if case let .text(previous)? = result.last {
            result[result.count - 1] = .text(previous + value)
        } else {
            result.append(.text(value))
        }
    }

    private func removeTrailingSpaces(_ result: inout [MarkdownInline]) {
        guard case let .text(value)? = result.last else { return }
        let trimmed = String(value.drop(while: { $0 == " " }).reversed().drop(while: { $0 == " " }).reversed())
        result[result.count - 1] = .text(trimmed)
    }

    private func textValue(_ inline: MarkdownInline?) -> String {
        guard let inline else { return "" }
        if case let .text(value) = inline { return value }
        return ""
    }

    private enum DelimitedKind {
        case strong
        case emphasis
        case strikethrough
    }
}

private func normalizeLineEndings(_ text: String) -> String {
    text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
}

private func isMarkdownPunctuation(_ character: Character) -> Bool {
    "#$%&'()*+,-./:;<=>?@[\u{005C}]\u{005E}_\u{0060}{|}~!".contains(character)
}

private func parseDestinationAndTitle(_ value: String) -> (destination: String, title: String?) {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    if trimmed.first == "<", let end = trimmed.firstIndex(of: ">") {
        let destination = String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
        let remainder = String(trimmed[trimmed.index(after: end)...]).trimmingCharacters(in: .whitespaces)
        return (destination, parseTitle(remainder))
    }
    let parts = trimmed.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
    guard let first = parts.first else { return ("", nil) }
    return (String(first), parts.count == 2 ? parseTitle(String(parts[1])) : nil)
}

private func parseTitle(_ value: String) -> String? {
    guard value.count >= 2 else { return nil }
    let first = value.first
    let last = value.last
    guard (first == "\"" && last == "\"") || (first == "'" && last == "'") || (first == "(" && last == ")") else {
        return nil
    }
    return String(value.dropFirst().dropLast())
}

private func decodeEntity(_ value: String) -> String? {
    let named: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
        "&#39;": "'", "&apos;": "'", "&nbsp;": "\u{00A0}"
    ]
    if let replacement = named[value] { return replacement }
    if value.hasPrefix("&#x") || value.hasPrefix("&#X"), value.hasSuffix(";") {
        let digits = String(value.dropFirst(3).dropLast())
        if let scalar = UInt32(digits, radix: 16), let unicode = UnicodeScalar(scalar) {
            return String(unicode)
        }
    }
    if value.hasPrefix("&#"), value.hasSuffix(";") {
        let digits = String(value.dropFirst(2).dropLast())
        if let scalar = UInt32(digits), let unicode = UnicodeScalar(scalar) {
            return String(unicode)
        }
    }
    return nil
}

private func sourceLines(_ text: String) -> [SourceLine] {
    if text.isEmpty { return [] }
    var result: [SourceLine] = []
    var offset = 0
    for (number, line) in text.components(separatedBy: "\n").enumerated() {
        let length = line.utf8.count
        result.append(SourceLine(text: line, number: number, startByte: offset, endByte: offset + length))
        offset += length + 1
    }
    if result.last?.text.isEmpty == true && text.hasSuffix("\n") {
        result.removeLast()
    }
    return result
}

private func heading(_ line: String) -> (level: Int, content: String)? {
    let trimmed = line.drop(while: { $0 == " " }).prefix(while: { $0 != "\n" })
    let characters = Array(trimmed)
    var count = 0
    while count < characters.count && count < 6 && characters[count] == "#" {
        count += 1
    }
    guard count > 0, count == characters.count || characters[count] == " " || characters[count] == "\t" else { return nil }
    var content = String(characters.dropFirst(count)).trimmingCharacters(in: .whitespaces)
    if content.hasSuffix("#") {
        let candidate = String(content.dropLast())
        if candidate.last?.isWhitespace == true || candidate.isEmpty {
            content = candidate.trimmingCharacters(in: .whitespaces)
        }
    }
    return (count, content)
}

private func setextLevel(_ line: String) -> Int? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.count >= 1 else { return nil }
    if trimmed.allSatisfy({ $0 == "=" }) { return 1 }
    if trimmed.allSatisfy({ $0 == "-" }) { return 2 }
    return nil
}

private func fenceOpening(_ line: String) -> FenceOpening? {
    let spaces = min(3, leadingSpaces(line))
    let value = String(line.dropFirst(spaces))
    guard let character = value.first, character == Character(UnicodeScalar(96)!) || character == "~" else { return nil }
    let length = value.prefix(while: { $0 == character }).count
    guard length >= 3 else { return nil }
    let info = String(value.dropFirst(length)).trimmingCharacters(in: .whitespaces)
    return FenceOpening(character: character, length: length, info: info)
}

private func isFenceClose(_ line: String, character: Character, minimumLength: Int) -> Bool {
    let spaces = min(3, leadingSpaces(line))
    let value = String(line.dropFirst(spaces)).trimmingCharacters(in: .whitespaces)
    guard value.count >= minimumLength else { return false }
    return value.allSatisfy { $0 == character }
}

private func isThematicBreak(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.count >= 3 else { return false }
    let candidates = Set(trimmed.filter { $0 != " " && $0 != "\t" })
    guard candidates.count == 1, let character = candidates.first else { return false }
    return character == "-" || character == "*" || character == "_"
}

private func isQuoteLine(_ line: String) -> Bool {
    stripQuotePrefix(line) != nil
}

private func stripQuotePrefix(_ line: String) -> String? {
    let spaces = min(3, leadingSpaces(line))
    let value = String(line.dropFirst(spaces))
    guard value.first == ">" else { return nil }
    let content = String(value.dropFirst()).first == " " ? String(value.dropFirst(2)) : String(value.dropFirst())
    return content
}

private func leadingSpaces(_ value: String) -> Int {
    value.prefix(while: { $0 == " " || $0 == "\t" }).count
}

private func listMarker(_ line: String) -> ListMarker? {
    let indentation = leadingSpaces(line)
    let value = String(line.dropFirst(indentation))
    guard !value.isEmpty else { return nil }
    if let first = value.first, first == "-" || first == "+" || first == "*" {
        guard value.dropFirst().first?.isWhitespace == true else { return nil }
        return ListMarker(indentation: indentation, ordered: false, start: 1, markerWidth: 2, content: String(value.dropFirst(1)).trimmingCharacters(in: .whitespaces))
    }
    var digits = ""
    for character in value {
        if character.isNumber { digits.append(character) } else { break }
    }
    guard !digits.isEmpty, let delimiter = value.dropFirst(digits.count).first, delimiter == "." || delimiter == ")" else { return nil }
    let remainder = value.dropFirst(digits.count + 1)
    guard remainder.first?.isWhitespace == true else { return nil }
    return ListMarker(
        indentation: indentation,
        ordered: true,
        start: Int(digits) ?? 1,
        markerWidth: digits.count + 2,
        content: String(remainder).trimmingCharacters(in: .whitespaces)
    )
}

private func taskMarker(_ line: String) -> (state: MarkdownTaskState, content: String)? {
    guard line.count >= 3, line.first == "[", line.dropFirst(2).first == "]", line.dropFirst(3).first?.isWhitespace == true else { return nil }
    let marker = Array(line)[1]
    guard marker == " " || marker == "x" || marker == "X" else { return nil }
    return (marker == " " ? .unchecked : .checked, String(line.dropFirst(4)))
}

private func splitTableCells(_ line: String) -> [String] {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.contains("|") else { return [] }
    var value = trimmed
    if value.first == "|" { value.removeFirst() }
    if value.last == "|" { value.removeLast() }
    var cells: [String] = []
    var current = ""
    var escaped = false
    for character in value {
        if escaped {
            current.append("\\")
            current.append(character)
            escaped = false
        } else if character == "\\" {
            escaped = true
        } else if character == "|" {
            cells.append(current.trimmingCharacters(in: .whitespaces))
            current = ""
        } else {
            current.append(character)
        }
    }
    if escaped { current.append("\\") }
    cells.append(current.trimmingCharacters(in: .whitespaces))
    return cells
}

private func delimiterAlignment(_ cell: String) -> MarkdownAlignment? {
    let value = cell.trimmingCharacters(in: .whitespaces)
    guard !value.isEmpty else { return nil }
    let left = value.first == ":"
    let right = value.last == ":"
    let core = value.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
    guard !core.isEmpty, core.allSatisfy({ $0 == "-" }) else { return nil }
    if left && right { return .center }
    if left { return .left }
    if right { return .right }
    return MarkdownAlignment.none
}

private func isTableDelimiterLine(_ line: String) -> Bool {
    let cells = splitTableCells(line)
    return !cells.isEmpty && cells.allSatisfy { delimiterAlignment($0) != nil }
}

private func structuralIssues(lines: [SourceLine], options: MarkdownParserOptions) -> [MarkdownStructuralIssue] {
    var issues: [MarkdownStructuralIssue] = []
    var fence: FenceOpening?
    var codeStart = 0
    for (index, line) in lines.enumerated() {
        if let active = fence {
            if isFenceClose(line.text, character: active.character, minimumLength: active.length) {
                fence = nil
            }
        } else if let opening = fenceOpening(line.text) {
            fence = opening
            codeStart = index
        }
    }
    if fence != nil && !lines.isEmpty {
        _ = codeStart
        issues.append(.unterminatedCodeBlock)
    }
    guard options.tables else { return issues }
    var inFence: FenceOpening?
    for index in 1..<lines.count {
        if let active = inFence {
            if isFenceClose(lines[index].text, character: active.character, minimumLength: active.length) {
                inFence = nil
            }
            continue
        }
        if let opening = fenceOpening(lines[index].text) {
            inFence = opening
            continue
        }
        let delimiterLine = structuralTableLine(lines[index].text)
        guard isTableDelimiterLine(delimiterLine) else { continue }
        let previous = structuralTableLine(lines[index - 1].text)
        guard !previous.trimmingCharacters(in: .whitespaces).isEmpty, previous.contains("|") else { continue }
        let headerCount = splitTableCells(previous).count
        let delimiterCount = splitTableCells(delimiterLine).count
        if headerCount != delimiterCount {
            issues.append(.malformedTable)
        }
    }
    return issues
}

private func structuralTableLine(_ line: String) -> String {
    var value = line
    while let stripped = stripQuotePrefix(value) {
        value = stripped
    }
    return value
}

private func count(_ kind: MarkdownBlockKind, into stats: inout MarkdownStats) {
    switch kind {
    case let .paragraph(inlines), let .heading(_, inlines):
        if case let .heading(level, _) = kind {
            switch level {
            case 1: stats.h1 += 1
            case 2: stats.h2 += 1
            case 3: stats.h3 += 1
            case 4: stats.h4 += 1
            case 5: stats.h5 += 1
            default: stats.h6 += 1
            }
        }
        count(inlines, into: &stats)
    case let .quote(blocks):
        stats.blockquotes += 1
        for block in blocks { count(block.kind, into: &stats) }
    case let .list(_, _, items):
        for item in items {
            stats.listItems += 1
            if item.task != .none { stats.taskListItems += 1 }
            for block in item.blocks { count(block.kind, into: &stats) }
        }
    case let .code(code):
        if code.fenced { stats.fencedCode += 1 } else { stats.indentedCode += 1 }
    case .thematicBreak:
        stats.thematicBreaks += 1
    case let .table(table):
        stats.tables += 1
        for cell in table.header { count(cell, into: &stats) }
        for row in table.rows {
            for cell in row { count(cell, into: &stats) }
        }
    }
}

private func count(_ inlines: [MarkdownInline], into stats: inout MarkdownStats) {
    for inline in inlines {
        switch inline {
        case .text, .softBreak, .hardBreak:
            continue
        case let .strong(children):
            stats.strong += 1
            count(children, into: &stats)
        case let .emphasis(children):
            stats.emphasis += 1
            count(children, into: &stats)
        case let .strikethrough(children):
            stats.strikethrough += 1
            count(children, into: &stats)
        case .code:
            stats.inlineCode += 1
        case let .link(children, _, _):
            stats.links += 1
            count(children, into: &stats)
        case let .image(alt, _, _):
            stats.images += 1
            count(alt, into: &stats)
        case let .math(_, display):
            if display { stats.displayMath += 1 } else { stats.inlineMath += 1 }
        }
    }
}
