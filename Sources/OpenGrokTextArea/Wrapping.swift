// Wrapping.swift
//
// textwrap-compatible word wrap ranges (OptimalFit / FirstFit, separators,
// hyphen splitters, break-words, indentation, line endings).

import Foundation
import OpenGrokTerminalCore

// MARK: - Options model (Rust RtOptions / textwrap::Options)

public enum WrapLineEnding: Sendable, Equatable {
    case lf
    case crlf
}

public enum WordSeparatorKind: Sendable, Equatable {
    /// Split on runs of ASCII spaces (trailing spaces attach to the prior word).
    case asciiSpace
    /// Approximate Unicode line-break opportunities (spaces, CJK, emoji, hyphens).
    /// Matches textwrap `WordSeparator::new()` when unicode-linebreak is enabled.
    case unicodeBreakProperties
}

public enum WordSplitterKind: Sendable, Equatable {
    case noHyphenation
    case hyphenSplitter
}

public struct WrapPenalties: Sendable, Equatable {
    public var nlinePenalty: Int
    public var overflowPenalty: Int
    public var shortLastLineFraction: Int
    public var shortLastLinePenalty: Int
    public var hyphenPenalty: Int

    public init(
        nlinePenalty: Int = 1000,
        overflowPenalty: Int = 50 * 50,
        shortLastLineFraction: Int = 4,
        shortLastLinePenalty: Int = 25,
        hyphenPenalty: Int = 25
    ) {
        self.nlinePenalty = nlinePenalty
        self.overflowPenalty = overflowPenalty
        self.shortLastLineFraction = shortLastLineFraction
        self.shortLastLinePenalty = shortLastLinePenalty
        self.hyphenPenalty = hyphenPenalty
    }

    /// Rust RtOptions default: ~infinite overflow penalty (never overflow when avoidable).
    public static let neverOverflow = WrapPenalties(
        nlinePenalty: 1000,
        overflowPenalty: Int.max / 4,
        shortLastLineFraction: 4,
        shortLastLinePenalty: 25,
        hyphenPenalty: 25
    )
}

public enum WrapAlgorithmKind: Sendable, Equatable {
    case firstFit
    case optimalFit(WrapPenalties)
}

/// Full wrapping option surface (Rust `RtOptions` / textwrap `Options`).
public struct WrapOptions: Sendable, Equatable {
    public var width: Int
    public var lineEnding: WrapLineEnding
    public var initialIndent: String
    public var subsequentIndent: String
    public var breakWords: Bool
    public var wrapAlgorithm: WrapAlgorithmKind
    public var wordSeparator: WordSeparatorKind
    public var wordSplitter: WordSplitterKind

    public init(
        width: Int,
        lineEnding: WrapLineEnding = .lf,
        initialIndent: String = "",
        subsequentIndent: String = "",
        breakWords: Bool = true,
        wrapAlgorithm: WrapAlgorithmKind = .optimalFit(.neverOverflow),
        wordSeparator: WordSeparatorKind = .unicodeBreakProperties,
        wordSplitter: WordSplitterKind = .hyphenSplitter
    ) {
        self.width = width
        self.lineEnding = lineEnding
        self.initialIndent = initialIndent
        self.subsequentIndent = subsequentIndent
        self.breakWords = breakWords
        self.wrapAlgorithm = wrapAlgorithm
        self.wordSeparator = wordSeparator
        self.wordSplitter = wordSplitter
    }

    public static func width(_ width: Int) -> WrapOptions { WrapOptions(width: width) }
}

// MARK: - Public API

/// Compute UTF-8 byte ranges for wrapped lines of `text`.
///
/// Trailing spaces after a wrap point are included in the preceding range
/// (matches Rust `wrap_ranges`).
public func wrapRanges(_ text: String, width: Int, breakWords: Bool = true) -> [Range<Int>] {
    wrapRanges(text, options: WrapOptions(width: width, breakWords: breakWords))
}

public func wrapRanges(_ text: String, options: WrapOptions) -> [Range<Int>] {
    if text.isEmpty { return [] }
    let width = max(options.width, 0)
    if width == 0 {
        // Degenerate: textwrap may yield empty static slices; skip them → no ranges.
        // For editor use, treat as hard-break every grapheme if breakWords.
        if !options.breakWords { return [0..<text.utf8Count] }
    }

    var lines: [Range<Int>] = []
    let bytes = Array(text.utf8)
    var lineStart = 0
    var i = 0
    let crlf = options.lineEnding == .crlf

    while i <= bytes.count {
        let atEnd = i == bytes.count
        let isNL: Bool
        if atEnd {
            isNL = false
        } else if crlf && bytes[i] == 0x0D, i + 1 < bytes.count, bytes[i + 1] == 0x0A {
            isNL = true
        } else if bytes[i] == 0x0A {
            isNL = true
        } else {
            isNL = false
        }

        if atEnd || isNL {
            var contentEnd = i
            if !atEnd && crlf && i > lineStart && bytes[i] == 0x0A && bytes[i - 1] == 0x0D {
                // content ends before CR of CRLF
            }
            // Strip trailing CR before LF for content
            if contentEnd > lineStart && contentEnd <= bytes.count {
                // When splitting on \n, exclude optional \r
                if !atEnd && contentEnd > lineStart && bytes[contentEnd - 1] == 0x0D {
                    contentEnd -= 1
                }
            }
            let wrapped = wrapOneParagraph(
                text: text,
                bytes: bytes,
                start: lineStart,
                end: contentEnd,
                options: options
            )
            if wrapped.isEmpty {
                lines.append(lineStart..<lineStart)
            } else {
                lines.append(contentsOf: wrapped)
            }
            if atEnd { break }
            // Advance past newline sequence
            if crlf && i + 1 < bytes.count && bytes[i] == 0x0D && bytes[i + 1] == 0x0A {
                i += 2
            } else if bytes[i] == 0x0A {
                i += 1
            } else {
                i += 1
            }
            lineStart = i
            continue
        }
        i += 1
    }
    return lines
}

/// Like `wrapRanges` but without extending ranges to include trailing spaces.
public func wrapRangesTrim(_ text: String, options: WrapOptions) -> [Range<Int>] {
    wrapRanges(text, options: options).map { range in
        var end = range.upperBound
        let bytes = Array(text.utf8)
        while end > range.lowerBound && end <= bytes.count && bytes[end - 1] == 0x20 {
            end -= 1
        }
        return range.lowerBound..<end
    }
}

// MARK: - Word fragments

private struct WordFrag {
    var start: Int
    var end: Int // exclusive, content without trailing whitespace
    var whitespaceEnd: Int // exclusive, includes trailing spaces
    var width: Int
    var whitespaceWidth: Int
    var penaltyWidth: Int // hyphen penalty width when split
    var endsWithHyphen: Bool
}

private func wrapOneParagraph(
    text: String,
    bytes: [UInt8],
    start: Int,
    end: Int,
    options: WrapOptions
) -> [Range<Int>] {
    if start >= end { return [start..<start] }
    let width = max(options.width, 1)
    let initialW = UnicodeDisplayWidth.width(of: options.initialIndent)
    let subsequentW = UnicodeDisplayWidth.width(of: options.subsequentIndent)
    let firstLineWidth = max(1, width - initialW)
    let nextLineWidth = max(1, width - subsequentW)

    var words = findWords(text: text, bytes: bytes, start: start, end: end, separator: options.wordSeparator)
    words = splitWords(words, text: text, bytes: bytes, splitter: options.wordSplitter, lineWidth: firstLineWidth, breakWords: options.breakWords)

    if words.isEmpty { return [start..<start] }

    let lineBreaks: [Int] // indices into words where a new line starts (after break)
    switch options.wrapAlgorithm {
    case .firstFit:
        lineBreaks = wrapFirstFit(words: words, firstWidth: firstLineWidth, nextWidth: nextLineWidth)
    case .optimalFit(let penalties):
        lineBreaks = wrapOptimalFit(
            words: words,
            firstWidth: firstLineWidth,
            nextWidth: nextLineWidth,
            penalties: penalties
        )
    }

    // Convert word groups to byte ranges, extending trailing spaces into the range.
    var ranges: [Range<Int>] = []
    var wi = 0
    var lineIdx = 0
    while wi < words.count {
        let lineStartWord = wi
        let nextBreak = lineIdx < lineBreaks.count ? lineBreaks[lineIdx] : words.count
        lineIdx += 1
        wi = nextBreak
        let first = words[lineStartWord]
        let last = words[nextBreak - 1]
        // Include trailing whitespace that belongs to the last word on this line
        // only if it doesn't start the next line (textwrap attaches spaces to words).
        var rangeEnd = last.whitespaceEnd
        // If this is not the last line, trailing spaces stay with this line (wrap_ranges).
        if nextBreak < words.count {
            rangeEnd = last.whitespaceEnd
        } else {
            rangeEnd = last.whitespaceEnd
        }
        ranges.append(first.start..<rangeEnd)
    }
    return ranges
}

private func findWords(
    text: String,
    bytes: [UInt8],
    start: Int,
    end: Int,
    separator: WordSeparatorKind
) -> [WordFrag] {
    switch separator {
    case .asciiSpace:
        return findWordsAsciiSpace(text: text, bytes: bytes, start: start, end: end)
    case .unicodeBreakProperties:
        return findWordsUnicode(text: text, bytes: bytes, start: start, end: end)
    }
}

private func findWordsAsciiSpace(
    text: String,
    bytes: [UInt8],
    start: Int,
    end: Int
) -> [WordFrag] {
    var words: [WordFrag] = []
    var i = start
    while i < end {
        // skip is not needed — spaces attach to previous word
        let wordStart = i
        while i < end && bytes[i] != 0x20 {
            i = text.nextGraphemeBoundary(byte: i)
            if i > end { i = end; break }
        }
        let contentEnd = i
        while i < end && bytes[i] == 0x20 { i += 1 }
        let wsEnd = i
        if contentEnd == wordStart && wsEnd == wordStart { break }
        let content = text.substring(utf8Range: wordStart..<contentEnd)
        let ws = text.substring(utf8Range: contentEnd..<wsEnd)
        words.append(WordFrag(
            start: wordStart,
            end: contentEnd,
            whitespaceEnd: wsEnd,
            width: UnicodeDisplayWidth.width(of: content),
            whitespaceWidth: UnicodeDisplayWidth.width(of: ws),
            penaltyWidth: 0,
            endsWithHyphen: content.hasSuffix("-")
        ))
    }
    return words
}

private func findWordsUnicode(
    text: String,
    bytes: [UInt8],
    start: Int,
    end: Int
) -> [WordFrag] {
    // Practical UAX #14 subset used by terminals: break after spaces (spaces
    // attach to prior word), between CJK ideographs, between emoji graphemes,
    // and after hard hyphens (handled by splitter, not separator).
    var words: [WordFrag] = []
    var i = start
    while i < end {
        let wordStart = i
        // Consume one "atom" then greedily extend while no break opportunity.
        while i < end {
            let gStart = i
            let gEnd = min(end, text.nextGraphemeBoundary(byte: i))
            if gStart == gEnd { break }
            let g = text.substring(utf8Range: gStart..<gEnd)

            if g == " " {
                // Finish word content before spaces; spaces attach as whitespace.
                break
            }

            // Lookahead: if next grapheme is space, include current and stop content.
            let next = gEnd < end ? text.substring(utf8Range: gEnd..<min(end, text.nextGraphemeBoundary(byte: gEnd))) : ""
            i = gEnd

            // Break opportunity between CJK / emoji graphemes (no space).
            if gEnd < end && next != " " && shouldBreakBetween(g, next) {
                break
            }
            // Otherwise continue atom into same word for Latin etc.
            if next == " " { break }
        }
        let contentEnd = i
        while i < end && bytes[i] == 0x20 { i += 1 }
        let wsEnd = i
        if contentEnd == wordStart && wsEnd == wordStart {
            // Force progress on pathological input
            let next = min(end, text.nextGraphemeBoundary(byte: wordStart))
            if next == wordStart { break }
            let content = text.substring(utf8Range: wordStart..<next)
            words.append(WordFrag(
                start: wordStart, end: next, whitespaceEnd: next,
                width: UnicodeDisplayWidth.width(of: content),
                whitespaceWidth: 0, penaltyWidth: 0,
                endsWithHyphen: content.hasSuffix("-")
            ))
            i = next
            continue
        }
        if contentEnd == wordStart && wsEnd > wordStart {
            // Leading spaces only — treat as empty content + whitespace word
            words.append(WordFrag(
                start: wordStart, end: wordStart, whitespaceEnd: wsEnd,
                width: 0, whitespaceWidth: wsEnd - wordStart, penaltyWidth: 0, endsWithHyphen: false
            ))
            continue
        }
        let content = text.substring(utf8Range: wordStart..<contentEnd)
        let ws = text.substring(utf8Range: contentEnd..<wsEnd)
        words.append(WordFrag(
            start: wordStart,
            end: contentEnd,
            whitespaceEnd: wsEnd,
            width: UnicodeDisplayWidth.width(of: content),
            whitespaceWidth: UnicodeDisplayWidth.width(of: ws),
            penaltyWidth: 0,
            endsWithHyphen: content.hasSuffix("-")
        ))
    }
    return words
}

private func shouldBreakBetween(_ a: String, _ b: String) -> Bool {
    guard let ca = a.unicodeScalars.first, let cb = b.unicodeScalars.first else { return false }
    let wa = UnicodeDisplayWidth.width(of: a)
    let wb = UnicodeDisplayWidth.width(of: b)
    // CJK / wide ideographs
    if isCJK(ca) && isCJK(cb) { return true }
    // Emoji-ish wide symbols
    if wa >= 2 && wb >= 2 && (isEmojiish(ca) || isEmojiish(cb)) { return true }
    return false
}

private func isCJK(_ s: Unicode.Scalar) -> Bool {
    let v = s.value
    return (0x2E80...0x9FFF).contains(v)
        || (0xF900...0xFAFF).contains(v)
        || (0xFE30...0xFE4F).contains(v)
        || (0xFF00...0xFFEF).contains(v)
        || (0x20000...0x3FFFD).contains(v)
}

private func isEmojiish(_ s: Unicode.Scalar) -> Bool {
    let v = s.value
    return (0x1F300...0x1FAFF).contains(v) || (0x2600...0x27BF).contains(v)
}

private func splitWords(
    _ words: [WordFrag],
    text: String,
    bytes: [UInt8],
    splitter: WordSplitterKind,
    lineWidth: Int,
    breakWords: Bool
) -> [WordFrag] {
    var out: [WordFrag] = []
    for w in words {
        let contentLen = w.end - w.start
        if contentLen == 0 {
            out.append(w)
            continue
        }
        var pieces: [WordFrag] = [w]
        switch splitter {
        case .noHyphenation:
            break
        case .hyphenSplitter:
            pieces = splitOnHyphens(w, text: text)
        }
        // break_words: hard-split pieces wider than line
        if breakWords {
            var broken: [WordFrag] = []
            for p in pieces {
                if p.width <= lineWidth || lineWidth <= 0 {
                    broken.append(p)
                } else {
                    broken.append(contentsOf: hardBreak(p, text: text, maxWidth: lineWidth))
                }
            }
            pieces = broken
        }
        out.append(contentsOf: pieces)
    }
    return out
}

private func splitOnHyphens(_ w: WordFrag, text: String) -> [WordFrag] {
    let content = text.substring(utf8Range: w.start..<w.end)
    guard content.contains("-") else { return [w] }
    var parts: [WordFrag] = []
    var bytePos = w.start
    var pieceStart = w.start
    let bytes = Array(text.utf8)
    while bytePos < w.end {
        if bytes[bytePos] == 0x2D { // '-'
            let pieceEnd = bytePos + 1 // include hyphen
            let c = text.substring(utf8Range: pieceStart..<pieceEnd)
            let isLast = pieceEnd >= w.end
            parts.append(WordFrag(
                start: pieceStart,
                end: pieceEnd,
                whitespaceEnd: isLast ? w.whitespaceEnd : pieceEnd,
                width: UnicodeDisplayWidth.width(of: c),
                whitespaceWidth: isLast ? w.whitespaceWidth : 0,
                penaltyWidth: isLast ? 0 : 1,
                endsWithHyphen: true
            ))
            pieceStart = pieceEnd
            bytePos = pieceEnd
        } else {
            bytePos = min(w.end, text.nextGraphemeBoundary(byte: bytePos))
        }
    }
    if pieceStart < w.end || parts.isEmpty {
        let c = text.substring(utf8Range: pieceStart..<w.end)
        parts.append(WordFrag(
            start: pieceStart,
            end: w.end,
            whitespaceEnd: w.whitespaceEnd,
            width: UnicodeDisplayWidth.width(of: c),
            whitespaceWidth: w.whitespaceWidth,
            penaltyWidth: 0,
            endsWithHyphen: c.hasSuffix("-")
        ))
    } else if let last = parts.indices.last {
        parts[last].whitespaceEnd = w.whitespaceEnd
        parts[last].whitespaceWidth = w.whitespaceWidth
    }
    return parts
}

private func hardBreak(_ w: WordFrag, text: String, maxWidth: Int) -> [WordFrag] {
    var parts: [WordFrag] = []
    var pos = w.start
    while pos < w.end {
        var col = 0
        var cursor = pos
        while cursor < w.end {
            let next = min(w.end, text.nextGraphemeBoundary(byte: cursor))
            let g = text.substring(utf8Range: cursor..<next)
            let gw = UnicodeDisplayWidth.width(of: g)
            if col > 0 && col + gw > maxWidth { break }
            col += max(gw, 0)
            cursor = next
            if col >= maxWidth { break }
        }
        if cursor == pos {
            cursor = min(w.end, text.nextGraphemeBoundary(byte: pos))
        }
        let isLast = cursor >= w.end
        let c = text.substring(utf8Range: pos..<cursor)
        parts.append(WordFrag(
            start: pos,
            end: cursor,
            whitespaceEnd: isLast ? w.whitespaceEnd : cursor,
            width: UnicodeDisplayWidth.width(of: c),
            whitespaceWidth: isLast ? w.whitespaceWidth : 0,
            penaltyWidth: 0,
            endsWithHyphen: false
        ))
        pos = cursor
    }
    return parts.isEmpty ? [w] : parts
}

// MARK: - Algorithms

/// Returns word indices where each new line starts (excluding 0).
private func wrapFirstFit(words: [WordFrag], firstWidth: Int, nextWidth: Int) -> [Int] {
    var breaks: [Int] = []
    var i = 0
    var lineWidth = firstWidth
    while i < words.count {
        var j = i + 1
        while j <= words.count {
            let w = lineContentWidth(words: words, from: i, to: j)
            if w > lineWidth && j > i + 1 {
                j -= 1
                break
            }
            if j == words.count { break }
            let withNext = w + words[j - 1].whitespaceWidth + words[j].width
            if withNext > lineWidth { break }
            j += 1
        }
        if j <= i { j = min(i + 1, words.count) }
        if j < words.count {
            breaks.append(j)
        }
        i = j
        lineWidth = nextWidth
    }
    return breaks
}

private func lineContentWidth(words: [WordFrag], from: Int, to: Int) -> Int {
    guard from < to else { return 0 }
    var w = words[from].width
    var i = from + 1
    while i < to {
        w += words[i - 1].whitespaceWidth + words[i].width
        i += 1
    }
    return w
}

private func wrapOptimalFit(
    words: [WordFrag],
    firstWidth: Int,
    nextWidth: Int,
    penalties: WrapPenalties
) -> [Int] {
    let n = words.count
    if n == 0 { return [] }
    // minima[i] = (prev_break_index, cost) for packing words[0..<i]
    var prev = Array(repeating: 0, count: n + 1)
    var cost = Array(repeating: Int.max / 4, count: n + 1)
    cost[0] = 0

    for i in 0..<n {
        if cost[i] >= Int.max / 8 { continue }
        var width = 0
        for j in i..<n {
            let lineW = (i == 0) ? firstWidth : nextWidth
            if j == i {
                width = words[j].width
            } else {
                width += words[j - 1].whitespaceWidth + words[j].width
            }
            var gap = lineW - width
            var c = cost[i]
            if gap < 0 {
                // overflow
                let over = -gap
                let add = over.multipliedReportingOverflow(by: penalties.overflowPenalty)
                if add.overflow { continue }
                c = c.addingReportingOverflow(add.partialValue).partialValue
            } else {
                let gapCost = gap.multipliedReportingOverflow(by: gap)
                if gapCost.overflow { continue }
                c = c.addingReportingOverflow(gapCost.partialValue).partialValue
            }
            c = c.addingReportingOverflow(penalties.nlinePenalty).partialValue
            if words[j].endsWithHyphen {
                c = c.addingReportingOverflow(penalties.hyphenPenalty).partialValue
            }
            // short last line
            if j + 1 == n && i == j {
                let frac = max(penalties.shortLastLineFraction, 1)
                if words[j].width * frac < lineW {
                    c = c.addingReportingOverflow(penalties.shortLastLinePenalty).partialValue
                }
            }
            if c < cost[j + 1] {
                cost[j + 1] = c
                prev[j + 1] = i
            }
            // If even empty rest overflows badly, still try further words when breakWords already split.
        }
    }

    // Reconstruct breaks
    var ends: [Int] = []
    var idx = n
    while idx > 0 {
        ends.append(idx)
        let p = prev[idx]
        if p >= idx { break }
        idx = p
    }
    ends.reverse()
    // ends are word-counts at line ends; convert to break indices (start of next line)
    var breaks: [Int] = []
    for e in ends.dropLast() {
        breaks.append(e)
    }
    return breaks
}
