// GraphemeSupport.swift
//
// UTF-8 byte-indexed grapheme helpers matching unicode-segmentation extended
// grapheme clusters (Swift `Character`).

import Foundation
import OpenGrokTerminalCore

// MARK: - UTF-8 byte indexing

extension String {
    /// UTF-8 byte length (Rust `str::len()`).
    var utf8Count: Int { utf8.count }

    /// All extended grapheme boundaries including 0 and end.
    func graphemeBoundaries() -> [Int] {
        var bounds: [Int] = [0]
        var offset = 0
        for g in self {
            offset += String(g).utf8.count
            bounds.append(offset)
        }
        return bounds
    }

    /// Substring for a UTF-8 byte range.
    func substring(utf8Range range: Range<Int>) -> String {
        let start = max(0, min(range.lowerBound, utf8Count))
        let end = max(start, min(range.upperBound, utf8Count))
        guard start < end else { return "" }
        let s = utf8.index(utf8.startIndex, offsetBy: start)
        let e = utf8.index(utf8.startIndex, offsetBy: end)
        return String(self[s..<e])
    }

    /// Whether `byte` is a valid extended grapheme boundary (or end).
    func isGraphemeBoundary(byte: Int) -> Bool {
        let byte = min(max(0, byte), utf8Count)
        if byte == 0 || byte == utf8Count { return true }
        return graphemeBoundaries().contains(byte)
    }

    func floorGraphemeBoundary(byte: Int) -> Int {
        let byte = min(max(0, byte), utf8Count)
        let bounds = graphemeBoundaries()
        return bounds.last(where: { $0 <= byte }) ?? 0
    }

    func ceilGraphemeBoundary(byte: Int) -> Int {
        let byte = min(max(0, byte), utf8Count)
        let bounds = graphemeBoundaries()
        return bounds.first(where: { $0 >= byte }) ?? utf8Count
    }

    func previousGraphemeBoundary(byte: Int) -> Int {
        let byte = min(max(0, byte), utf8Count)
        if byte == 0 { return 0 }
        let bounds = graphemeBoundaries()
        // Largest boundary strictly less than byte; if byte is a boundary, the previous one.
        if let idx = bounds.lastIndex(where: { $0 < byte }) {
            return bounds[idx]
        }
        return 0
    }

    func nextGraphemeBoundary(byte: Int) -> Int {
        let byte = min(max(0, byte), utf8Count)
        if byte >= utf8Count { return utf8Count }
        let bounds = graphemeBoundaries()
        // Smallest boundary strictly greater than byte.
        if let idx = bounds.firstIndex(where: { $0 > byte }) {
            return bounds[idx]
        }
        return utf8Count
    }

    /// Nearest grapheme boundary; ties go left.
    func normalizeExternalCursor(byte: Int) -> Int {
        let byte = min(max(0, byte), utf8Count)
        let before = floorGraphemeBoundary(byte: byte)
        let after = ceilGraphemeBoundary(byte: byte)
        if byte - before <= after - byte {
            return before
        }
        return after
    }

    /// Display width using unicode-width rules.
    var displayWidth: Int {
        UnicodeDisplayWidth.width(of: self)
    }
}

/// Expand tabs to fixed-width spaces (`tabWidth == 0` → passthrough).
public func expandTabs(_ text: String, tabWidth: UInt8) -> String {
    if tabWidth == 0 || !text.contains("\t") { return text }
    var out = String()
    out.reserveCapacity(text.utf8.count)
    var col = 0
    for ch in text {
        if ch == "\t" {
            let w = Int(tabWidth)
            let spaces = w == 0 ? 0 : w - (col % w)
            out.append(String(repeating: " ", count: spaces))
            col += spaces
        } else if ch == "\n" {
            out.append(ch)
            col = 0
        } else {
            out.append(ch)
            col += UnicodeDisplayWidth.width(of: String(ch))
        }
    }
    return out
}

public func graphemeDisplayWidth(_ grapheme: String, tabWidth: UInt8) -> Int {
    if grapheme == "\t" { return Int(tabWidth) }
    return UnicodeDisplayWidth.width(of: grapheme)
}

public func plainDisplayWidth(_ text: String, tabWidth: UInt8) -> Int {
    var total = 0
    for g in text {
        total += graphemeDisplayWidth(String(g), tabWidth: tabWidth)
    }
    return total
}
