import Foundation
import OpenGrokMarkdownCore
import OpenGrokTerminalCore

/// 11-glyph box-drawing characters for markdown table borders.
public struct MarkdownTableBorders: Sendable, Equatable {
    public var horizontal: Character  // ─
    public var vertical: Character    // │
    public var topLeft: Character     // ┌
    public var topRight: Character    // ┐
    public var bottomLeft: Character  // └
    public var bottomRight: Character // ┘
    public var topJoin: Character     // ┬
    public var bottomJoin: Character  // ┴
    public var leftJoin: Character    // ├
    public var rightJoin: Character   // ┤
    public var cross: Character       // ┼

    public static let `box` = MarkdownTableBorders()

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

// MARK: - Internal Table Data Structures

struct TableCellLink: Sendable, Equatable {
    var url: String
    var id: Int
}

struct TableCellSpan: Sendable, Equatable {
    var text: String
    var bold: Bool
    var italic: Bool
    var strikethrough: Bool
    var code: Bool
    var link: TableCellLink?
    var isHeader: Bool
}

struct StyledTableCell: Sendable, Equatable {
    var spans: [TableCellSpan]

    var plainText: String {
        spans.map(\.text).joined()
    }
}

struct TableHyperlinkTarget: Sendable, Equatable {
    var lineOffset: Int
    var columnRange: Range<Int>
    var url: String
    var id: Int
}

struct WordToken: Sendable, Equatable {
    let text: String
    let whitespace: String
}

// MARK: - Word Splitting & Grapheme Wrapping

/// Split text into word tokens with boundary detection matching upstream Rust `cell_word_separator`.
func cellWordSeparator(_ line: String) -> [WordToken] {
    if line.isEmpty { return [] }

    // Pass 1: find break points between punctuation/symbol and letter, or non-formatting digits.
    var breaks: [(attachLeft: Int, attachRight: Int)] = []

    var inWhitespace = false
    var afterBreakChar = false
    var prevIsDigit = false
    var digitBeforeBreak = false
    var lastBreakCh: Character = "\0"
    var breakCharStart = 0

    let chars = Array(line)
    for (idx, ch) in chars.enumerated() {
        let isSpace = ch == " "
        let isBreakChar = !isSpace && !ch.isLetter && !ch.isNumber

        var shouldBreak = false
        if inWhitespace && !isSpace {
            shouldBreak = true
        } else if afterBreakChar {
            if ch.isLetter {
                shouldBreak = true
            } else if ch.isNumber && digitBeforeBreak {
                // digit-punct-digit: only break for non-formatting punct (not comma or period)
                shouldBreak = (lastBreakCh != "," && lastBreakCh != ".")
            }
        }

        if shouldBreak {
            if inWhitespace {
                breaks.append((idx, idx))
            } else {
                breaks.append((idx, breakCharStart))
            }
        }

        if isBreakChar {
            breakCharStart = idx
            lastBreakCh = ch
            digitBeforeBreak = prevIsDigit
        }
        prevIsDigit = ch.isNumber
        inWhitespace = isSpace
        afterBreakChar = isBreakChar
    }

    // Filter out break points that fall strictly inside a valid URL.
    var urlRanges: [Range<Int>] = []
    var pos = 0
    let lineStr = line
    for token in lineStr.split(whereSeparator: \.isWhitespace) {
        let tokenStr = String(token)
        if let subRange = lineStr[lineStr.index(lineStr.startIndex, offsetBy: pos)...].range(of: tokenStr) {
            let start = lineStr.distance(from: lineStr.startIndex, to: subRange.lowerBound)
            let end = lineStr.distance(from: lineStr.startIndex, to: subRange.upperBound)
            if isProtectedURL(tokenStr) {
                urlRanges.append(start..<end)
            }
            pos = end
        }
    }

    breaks.removeAll { b in
        urlRanges.contains { r in b.attachLeft > r.lowerBound && b.attachLeft < r.upperBound }
    }

    // Pass 2: choose attachment for each break point to minimize max(left_len, right_len).
    var splitPositions: [Int] = []
    splitPositions.reserveCapacity(breaks.count)
    let len = chars.count

    for (i, b) in breaks.enumerated() {
        if b.attachLeft == b.attachRight {
            splitPositions.append(b.attachLeft)
        } else {
            let segStart = (i == 0) ? 0 : splitPositions[i - 1]
            let segEnd = (i + 1 < breaks.count) ? breaks[i + 1].attachLeft : len

            let leftSliceAttachLeft = String(chars[segStart..<b.attachLeft])
            let rightSliceAttachLeft = String(chars[b.attachLeft..<segEnd])
            let leftIfAttachLeft = UnicodeDisplayWidth.width(of: leftSliceAttachLeft)
            let rightIfAttachLeft = UnicodeDisplayWidth.width(of: rightSliceAttachLeft)
            let maxAttachLeft = max(leftIfAttachLeft, rightIfAttachLeft)

            let leftSliceAttachRight = String(chars[segStart..<b.attachRight])
            let rightSliceAttachRight = String(chars[b.attachRight..<segEnd])
            let leftIfAttachRight = UnicodeDisplayWidth.width(of: leftSliceAttachRight)
            let rightIfAttachRight = UnicodeDisplayWidth.width(of: rightSliceAttachRight)
            let maxAttachRight = max(leftIfAttachRight, rightIfAttachRight)

            if maxAttachRight < maxAttachLeft {
                splitPositions.append(b.attachRight)
            } else {
                splitPositions.append(b.attachLeft)
            }
        }
    }

    // Pass 3: emit WordTokens at split positions
    var tokens: [WordToken] = []
    var cur = 0
    for splitPos in splitPositions {
        if splitPos > cur {
            let segment = String(chars[cur..<splitPos])
            tokens.append(extractWordToken(segment))
            cur = splitPos
        }
    }
    if cur < len {
        let segment = String(chars[cur..<len])
        tokens.append(extractWordToken(segment))
    }

    return tokens
}

private func isProtectedURL(_ token: String) -> Bool {
    guard let url = URL(string: token), let scheme = url.scheme, !scheme.isEmpty else {
        return false
    }
    return scheme == "http" || scheme == "https" || scheme == "ftp" || scheme == "file" || token.contains("://")
}

private func extractWordToken(_ raw: String) -> WordToken {
    let chars = Array(raw)
    var end = chars.count
    while end > 0 && chars[end - 1] == " " {
        end -= 1
    }
    let word = String(chars[0..<end])
    let whitespace = String(chars[end..<chars.count])
    return WordToken(text: word, whitespace: whitespace)
}

/// Word-wrap a cell's plain text into lines of at most `width` display columns.
/// Uses Unicode display width and emergency grapheme cluster hard-splitting for unbreakable words.
func wrapCellText(_ text: String, width: Int) -> [String] {
    if width <= 0 {
        return [""]
    }
    if text.isEmpty {
        return [""]
    }

    let words = cellWordSeparator(text)
    if words.isEmpty {
        return [""]
    }

    // First-fit line wrapping
    var lines: [String] = []
    var currentLine = ""
    var currentLineWidth = 0
    var prevWhitespace = ""

    for word in words {
        if word.text.isEmpty {
            prevWhitespace = word.whitespace
            continue
        }
        let wordWidth = UnicodeDisplayWidth.width(of: word.text)
        let spaceWidth = UnicodeDisplayWidth.width(of: prevWhitespace)

        if currentLine.isEmpty {
            currentLine = word.text
            currentLineWidth = wordWidth
        } else if currentLineWidth + spaceWidth + wordWidth <= width {
            currentLine.append(prevWhitespace)
            currentLine.append(word.text)
            currentLineWidth += spaceWidth + wordWidth
        } else {
            lines.append(currentLine)
            currentLine = word.text
            currentLineWidth = wordWidth
        }
        prevWhitespace = word.whitespace
    }
    if !currentLine.isEmpty {
        lines.append(currentLine)
    }

    // Grapheme cluster emergency hard-splitting if an unbreakable word exceeds column width
    var resultLines: [String] = []
    for line in lines {
        let lineWidth = UnicodeDisplayWidth.width(of: line)
        if lineWidth <= width {
            resultLines.append(line)
            continue
        }

        var piece = ""
        var pieceWidth = 0
        for grapheme in line {
            let gStr = String(grapheme)
            let gWidth = UnicodeDisplayWidth.width(ofGrapheme: gStr)
            if pieceWidth > 0 && pieceWidth + gWidth > width {
                resultLines.append(piece)
                piece = ""
                pieceWidth = 0
            }
            piece.append(gStr)
            pieceWidth += gWidth
        }
        if !piece.isEmpty {
            resultLines.append(piece)
        }
    }

    return resultLines.isEmpty ? [""] : resultLines
}

// MARK: - Two-Tier Column Width Budget Distribution

/// Two-tier column width distribution matching upstream `xai-grok-markdown/src/parse.rs:1595-1701`.
func computeTableColumnWidths(
    allRows: [[StyledTableCell]],
    numCols: Int,
    padding: Int,
    maxTableWidth: Int?
) -> [Int] {
    guard numCols > 0 else { return [] }

    var colWidths = Array(repeating: 0, count: numCols)
    for row in allRows {
        for colIdx in 0..<min(numCols, row.count) {
            let text = row[colIdx].plainText
            let cellWidth = text.components(separatedBy: "\n")
                .map { UnicodeDisplayWidth.width(of: $0) }
                .max() ?? 0
            colWidths[colIdx] = max(colWidths[colIdx], cellWidth)
        }
    }

    guard let maxWidth = maxTableWidth else {
        return colWidths
    }

    let overhead = numCols * (2 * padding + 1) + 1
    let contentBudget = max(0, maxWidth - overhead)
    let totalContent = colWidths.reduce(0, +)

    if totalContent > contentBudget && totalContent > 0 {
        var minColWidths = Array(repeating: 1, count: numCols)
        var hardFloors = Array(repeating: 0, count: numCols)

        for row in allRows {
            for col in 0..<min(numCols, row.count) {
                let text = row[col].plainText
                for word in cellWordSeparator(text) {
                    let w = UnicodeDisplayWidth.width(of: word.text)
                    minColWidths[col] = max(minColWidths[col], w)
                }
                if !text.isEmpty {
                    let widestGrapheme = text.map { UnicodeDisplayWidth.width(ofGrapheme: String($0)) }.max() ?? 0
                    hardFloors[col] = max(hardFloors[col], max(widestGrapheme, 1))
                }
            }
        }

        let minTotal = minColWidths.reduce(0, +)
        let hardTotal = hardFloors.reduce(0, +)

        let baseWidths: [Int]
        let targetWidths: [Int]
        if minTotal > contentBudget && hardTotal <= contentBudget {
            baseWidths = hardFloors
            targetWidths = minColWidths
        } else {
            baseWidths = minColWidths
            targetWidths = colWidths
        }

        let baseTotal = baseWidths.reduce(0, +)
        let extraBudget = max(0, contentBudget - baseTotal)

        let extraWants = (0..<numCols).map { max(0, targetWidths[$0] - baseWidths[$0]) }
        let totalExtraWant = extraWants.reduce(0, +)

        var newWidths = baseWidths
        if totalExtraWant > 0 && extraBudget > 0 {
            for i in 0..<numCols {
                let share = Int(floor(Double(extraWants[i]) * Double(extraBudget) / Double(totalExtraWant)))
                newWidths[i] += share
            }

            let used = newWidths.reduce(0, +)
            var remaining = max(0, contentBudget - used)
            if remaining > 0 {
                var indices = Array(0..<numCols)
                let unmet: (Int) -> Int = { i in max(0, targetWidths[i] - newWidths[i]) }
                indices.sort { unmet($0) > unmet($1) }
                for idx in indices {
                    if remaining == 0 { break }
                    if newWidths[idx] < targetWidths[idx] {
                        newWidths[idx] += 1
                        remaining -= 1
                    }
                }
            }
        }

        colWidths = newWidths
    }

    return colWidths
}

// MARK: - Border and Content Formatting

/// Format a horizontal border line with box-drawing glyphs.
func formatTableBorderLine(
    colWidths: [Int],
    padding: Int,
    left: Character,
    mid: Character,
    right: Character,
    horizontal: Character
) -> String {
    var line = String()
    line.append(left)
    for (i, width) in colWidths.enumerated() {
        let totalWidth = width + padding * 2
        line.append(String(repeating: horizontal, count: totalWidth))
        if i < colWidths.count - 1 {
            line.append(mid)
        }
    }
    line.append(right)
    return line
}

struct FormattedTableRowResult {
    var plainLines: [String]
    var renderLines: [MarkdownRenderLine]
    var hyperlinks: [TableHyperlinkTarget]
}

/// Format a table row that may span multiple visual lines when cells wrap,
/// slicing styled spans and tracking table hyperlinks with monotonic source cursor alignment.
func formatStyledTableRow(
    cells: [StyledTableCell],
    colWidths: [Int],
    alignments: [MarkdownAlignment],
    padding: Int,
    borders: MarkdownTableBorders,
    isHeader: Bool,
    sourceLine: Int
) -> FormattedTableRowResult {
    let numCols = colWidths.count
    let wrappedCells: [[String]] = (0..<numCols).map { i in
        let text = i < cells.count ? cells[i].plainText : ""
        return wrapCellText(text, width: colWidths[i])
    }

    let numVisualLines = max(1, wrappedCells.map(\.count).max() ?? 1)
    var allPlain: [String] = []
    var allRenderLines: [MarkdownRenderLine] = []
    var allHyperlinks: [TableHyperlinkTarget] = []

    // Monotonic per-column source cursors: each fragment is searched strictly forward
    // from previous match end to prevent repeated tokens from backwards re-matching.
    var sourceCursors = Array(repeating: 0, count: numCols)

    for visLine in 0..<numVisualLines {
        var plain = String()
        var segments: [MarkdownRenderSegment] = []
        var displayCol = 0

        let vStr = String(borders.vertical)
        plain.append(vStr)
        segments.append(MarkdownRenderSegment(text: vStr, style: .tableBorder))
        displayCol += UnicodeDisplayWidth.width(of: vStr)

        for i in 0..<numCols {
            let cellLineText = visLine < wrappedCells[i].count ? wrappedCells[i][visLine] : ""
            let cellLineWidth = UnicodeDisplayWidth.width(of: cellLineText)
            let width = colWidths[i]
            let totalPadding = max(0, width - cellLineWidth)

            let alignment = i < alignments.count ? alignments[i] : .none
            let leftPad: Int
            let rightPad: Int
            switch alignment {
            case .right:
                leftPad = totalPadding
                rightPad = 0
            case .center:
                leftPad = totalPadding / 2
                rightPad = totalPadding - leftPad
            case .left, .none:
                leftPad = 0
                rightPad = totalPadding
            }

            // Left padding
            let leftSpace = String(repeating: " ", count: padding + leftPad)
            let leftSpaceWidth = UnicodeDisplayWidth.width(of: leftSpace)
            plain.append(leftSpace)
            segments.append(MarkdownRenderSegment(text: leftSpace, style: .plain))
            displayCol += leftSpaceWidth

            // Cell text slicing
            if !cellLineText.isEmpty, i < cells.count {
                let cell = cells[i]
                let fullText = cell.plainText

                // Find byte/character range of cellLineText starting from cursor
                let cursor = min(sourceCursors[i], fullText.count)
                let startSearchIdx = fullText.index(fullText.startIndex, offsetBy: cursor)
                let subText = fullText[startSearchIdx...]

                let lineStart: Int
                let lineEnd: Int
                if let match = subText.range(of: cellLineText) {
                    lineStart = fullText.distance(from: fullText.startIndex, to: match.lowerBound)
                    lineEnd = fullText.distance(from: fullText.startIndex, to: match.upperBound)
                } else {
                    lineStart = cursor
                    lineEnd = min(fullText.count, cursor + cellLineText.count)
                }
                sourceCursors[i] = lineEnd

                // Walk cell's spans and emit overlapping slices
                var spanOffset = 0
                for cellSpan in cell.spans {
                    let spanStart = spanOffset
                    let spanEnd = spanOffset + cellSpan.text.count
                    spanOffset = spanEnd

                    let start = max(spanStart, lineStart)
                    let end = min(spanEnd, lineEnd)
                    if start >= end {
                        continue
                    }

                    let sliceStartIdx = fullText.index(fullText.startIndex, offsetBy: start)
                    let sliceEndIdx = fullText.index(fullText.startIndex, offsetBy: end)
                    let slice = String(fullText[sliceStartIdx..<sliceEndIdx])
                    if slice.isEmpty { continue }

                    var style: MarkdownTextStyle = .plain
                    if isHeader || cellSpan.bold {
                        style = .strong
                    } else if cellSpan.italic {
                        style = .emphasis
                    } else if cellSpan.strikethrough {
                        style = .strikethrough
                    } else if cellSpan.code {
                        style = .code
                    }

                    if let link = cellSpan.link {
                        style = .link
                        let sliceWidth = UnicodeDisplayWidth.width(of: slice)
                        allHyperlinks.append(TableHyperlinkTarget(
                            lineOffset: visLine,
                            columnRange: displayCol..<(displayCol + sliceWidth),
                            url: link.url,
                            id: link.id
                        ))
                    }

                    let sliceWidth = UnicodeDisplayWidth.width(of: slice)
                    plain.append(slice)
                    segments.append(MarkdownRenderSegment(text: slice, style: style))
                    displayCol += sliceWidth
                }
            } else if !cellLineText.isEmpty {
                plain.append(cellLineText)
                segments.append(MarkdownRenderSegment(text: cellLineText, style: isHeader ? .strong : .plain))
                displayCol += cellLineWidth
            }

            // Right padding
            let rightSpace = String(repeating: " ", count: rightPad + padding)
            let rightSpaceWidth = UnicodeDisplayWidth.width(of: rightSpace)
            plain.append(rightSpace)
            segments.append(MarkdownRenderSegment(text: rightSpace, style: .plain))
            displayCol += rightSpaceWidth

            // Column separator
            plain.append(vStr)
            segments.append(MarkdownRenderSegment(text: vStr, style: .tableBorder))
            displayCol += UnicodeDisplayWidth.width(of: vStr)
        }

        allPlain.append(plain)
        allRenderLines.append(MarkdownRenderLine(segments: segments, sourceLine: sourceLine))
    }

    return FormattedTableRowResult(
        plainLines: allPlain,
        renderLines: allRenderLines,
        hyperlinks: allHyperlinks
    )
}
