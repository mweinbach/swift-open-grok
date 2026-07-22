// Wrapping.swift
//
// Deterministic word-wrap ranges for the text area (first-fit, break-words),
// without depending on textwrap / ratatui.

import Foundation
import OpenGrokTerminalCore

/// Compute UTF-8 byte ranges for wrapped lines of `text` at `width` columns.
///
/// Uses a first-fit algorithm: prefers breaking at spaces/hyphens; hard-breaks
/// long words when `breakWords` is true.
public func wrapRanges(
    _ text: String,
    width: Int,
    breakWords: Bool = true
) -> [Range<Int>] {
    if text.isEmpty { return [] }
    let width = max(width, 1)
    var lines: [Range<Int>] = []
    let utf8 = text.utf8
    let bytes = Array(utf8)

    // Process logical lines (split on \n) then wrap each.
    var lineStart = 0
    var i = 0
    while i <= bytes.count {
        let atEnd = i == bytes.count
        let isNL = !atEnd && bytes[i] == 0x0A
        if atEnd || isNL {
            let lineEnd = i
            // Exclude trailing \r before \n
            var contentEnd = lineEnd
            if contentEnd > lineStart && bytes[contentEnd - 1] == 0x0D {
                contentEnd -= 1
            }
            let wrapped = wrapOneLine(bytes: bytes, start: lineStart, end: contentEnd, width: width, breakWords: breakWords, text: text)
            if wrapped.isEmpty {
                lines.append(lineStart..<lineStart)
            } else {
                lines.append(contentsOf: wrapped)
            }
            if atEnd { break }
            i += 1
            lineStart = i
            continue
        }
        i += 1
    }
    return lines
}

private func wrapOneLine(
    bytes: [UInt8],
    start: Int,
    end: Int,
    width: Int,
    breakWords: Bool,
    text: String
) -> [Range<Int>] {
    if start >= end { return [start..<start] }
    var result: [Range<Int>] = []
    var pos = start
    while pos < end {
        var col = 0
        var cursor = pos
        var lastBreak: Int? = nil // byte index after a break opportunity
        var lastBreakCol = 0

        while cursor < end {
            // Decode one grapheme starting at cursor.
            let gStart = cursor
            // Advance at least one UTF-8 scalar, then expand to grapheme via String.
            var gEnd = nextUTF8ScalarEnd(bytes, from: cursor)
            // Use string grapheme for proper clusters.
            let probe = text.substring(utf8Range: gStart..<min(end, gStart + 16))
            if let first = probe.first {
                gEnd = gStart + String(first).utf8.count
            }
            gEnd = min(gEnd, end)
            let grapheme = text.substring(utf8Range: gStart..<gEnd)
            let w = max(1, UnicodeDisplayWidth.width(of: grapheme) == 0 && grapheme != " " ? 0 : UnicodeDisplayWidth.width(of: grapheme))
            let gw = grapheme == " " ? 1 : (w == 0 ? 0 : w)

            if col + gw > width && cursor > pos {
                break
            }
            col += gw
            cursor = gEnd
            if grapheme == " " || grapheme == "-" {
                lastBreak = cursor
                lastBreakCol = col
            }
            if col >= width { break }
        }

        if cursor == pos {
            // Force at least one grapheme.
            let gEnd = text.nextGraphemeBoundary(byte: pos)
            cursor = min(gEnd, end)
            if !breakWords && cursor < end {
                // allow overflow: take whole word
                while cursor < end {
                    let ch = text.substring(utf8Range: cursor..<text.nextGraphemeBoundary(byte: cursor))
                    if ch == " " { break }
                    cursor = text.nextGraphemeBoundary(byte: cursor)
                }
            }
        } else if let br = lastBreak, col > width || (cursor < end && lastBreakCol > 0) {
            // Prefer break if we still have more content
            if cursor < end && br > pos {
                cursor = br
            }
        }

        // Trim trailing spaces from the range end for next-line start, but keep
        // them in the range (wrap_ranges preserves trailing spaces).
        var rangeEnd = cursor
        result.append(pos..<rangeEnd)

        // Skip spaces at the start of the next visual line.
        pos = cursor
        while pos < end {
            if bytes[pos] == 0x20 {
                // spaces may belong to previous line already
                if result.last?.upperBound == pos {
                    // include? Rust wrap_ranges extends trailing spaces into range
                }
                // For subsequent line, skip leading spaces
                var skip = pos
                while skip < end && bytes[skip] == 0x20 { skip += 1 }
                if skip > pos && pos == rangeEnd {
                    // extend previous range with trailing spaces
                    let last = result.removeLast()
                    result.append(last.lowerBound..<skip)
                    pos = skip
                }
                break
            } else {
                break
            }
        }
        if pos == rangeEnd && pos < end && result.last?.upperBound == pos {
            // Progress guarantee
            let next = text.nextGraphemeBoundary(byte: pos)
            if next == pos { break }
            // already advanced
        }
        if pos >= end { break }
        // If we didn't advance, force progress
        if pos == result.last?.lowerBound {
            pos = min(end, text.nextGraphemeBoundary(byte: pos))
        }
    }
    return result
}

private func nextUTF8ScalarEnd(_ bytes: [UInt8], from i: Int) -> Int {
    guard i < bytes.count else { return i }
    let b = bytes[i]
    if b < 0x80 { return i + 1 }
    if b & 0xE0 == 0xC0 { return min(bytes.count, i + 2) }
    if b & 0xF0 == 0xE0 { return min(bytes.count, i + 3) }
    if b & 0xF8 == 0xF0 { return min(bytes.count, i + 4) }
    return i + 1
}
