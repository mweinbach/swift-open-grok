// MermaidTextWrap.swift
//
// Open Grok — Swift port of `mermaid_to_svg::text_wrap`
// (third_party/mermaid-to-svg/src/text_wrap.rs, W8-S2), which itself mirrors
// mermaid.js `rendering-util/splitText.ts` and `createText.ts`.
//
// Text is measured font-free: a fixed advance per narrow character, doubled for
// East Asian wide characters. That keeps layout deterministic and free of any
// system font enumeration — the only place real glyphs are involved is when a
// consumer rasterizes the finished SVG with a bundled font.

import Foundation
import OpenGrokTerminalCore

enum MermaidTextWrap {
    static let defaultFontSize: Double = 16
    static let defaultLineHeight: Double = 1.1
    static let defaultWrapWidth: Double = 200
    static let defaultCharWidth: Double = 8
    static let defaultTextHeight: Double = 24
    /// State diagrams use a tighter advance than flowcharts.
    static let stateCharWidth: Double = 6.7

    /// An unbreakable token is kept whole and its box widened to fit, matching
    /// mermaid's default `htmlLabels: true` rendering, unless it is wider than
    /// this many wrap-widths. Only past the cap is a token force-broken.
    private static let singleTokenWidthCapFactor: Double = 5

    /// Break points preferred when an over-cap token must be split, so long
    /// paths and identifiers break at a separator rather than mid-segment.
    private static let tokenBreakCharacters: Set<Character> = ["_", "-", ".", "/"]

    /// Display width of `text` in narrow-character units.
    static func displayWidthUnits(_ text: String) -> Double {
        Double(UnicodeDisplayWidth.width(of: text))
    }

    /// Rendered width of one already-assembled line.
    static func lineWidth(_ line: String, charWidth: Double) -> Double {
        line.isEmpty ? 0 : displayWidthUnits(line) * charWidth
    }

    static func lineWidth(words: [String], charWidth: Double) -> Double {
        lineWidth(words.joined(separator: " "), charWidth: charWidth)
    }

    /// Splits `text` into lines of words that fit `maxWidth`. Explicit newlines
    /// always break; an empty line is preserved as one empty word.
    static func wrapTextLines(_ text: String, maxWidth: Double, charWidth: Double) -> [[String]] {
        guard !text.isEmpty else { return [] }
        let maxWidth = maxWidth.isFinite ? maxWidth : .infinity

        var lines: [[String]] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                lines.append([""])
                continue
            }
            lines.append(contentsOf: splitLineToFitWidth(words(in: trimmed), maxWidth, charWidth))
        }
        return lines
    }

    /// Width of the widest line and total height of the block.
    static func measure(
        lines: [[String]],
        charWidth: Double,
        fontSize: Double
    ) -> (width: Double, height: Double) {
        let width = lines.map { lineWidth(words: $0, charWidth: charWidth) }.max() ?? 0
        return (width, wrappedTextHeight(lineCount: lines.count, fontSize: fontSize))
    }

    static func wrappedTextHeight(lineCount: Int, fontSize: Double) -> Double {
        guard lineCount > 0 else { return 0 }
        let fontSize = normalizedFontSize(fontSize)
        let textHeight = defaultTextHeight * fontSize / defaultFontSize
        let lineSpacing = fontSize * defaultLineHeight
        return textHeight + Double(lineCount - 1) * lineSpacing
    }

    /// Scales a per-character advance to a non-default font size.
    static func scaleCharWidth(_ charWidth: Double, fontSize: Double) -> Double {
        charWidth * normalizedFontSize(fontSize) / defaultFontSize
    }

    private static func normalizedFontSize(_ fontSize: Double) -> Double {
        fontSize.isFinite && fontSize > 0 ? fontSize : defaultFontSize
    }

    private static func words(in text: some StringProtocol) -> [String] {
        let words = String(text).split(whereSeparator: \.isWhitespace).map(String.init)
        return words.isEmpty ? [""] : words
    }

    private static func splitLineToFitWidth(
        _ words: [String],
        _ maxWidth: Double,
        _ charWidth: Double
    ) -> [[String]] {
        // Consumed front-to-back, with words pushed back when they must start a
        // new line; the counts here are per-label, so the O(n) inserts are fine.
        var remaining = words
        var lines: [[String]] = []
        var current: [String] = []

        while true {
            guard !remaining.isEmpty else {
                if !current.isEmpty { lines.append(current) }
                break
            }
            let nextWord = remaining.removeFirst()

            let candidate = current + [nextWord]
            if lineWidth(words: candidate, charWidth: charWidth) <= maxWidth {
                current = candidate
                continue
            }

            if !current.isEmpty {
                lines.append(current)
                current = []
                remaining.insert(nextWord, at: 0)
                continue
            }

            guard !nextWord.isEmpty else { continue }

            let cap = maxWidth * singleTokenWidthCapFactor
            if lineWidth(nextWord, charWidth: charWidth) <= cap {
                lines.append([nextWord])
            } else {
                let (first, rest) = splitToken(nextWord, atCap: cap, charWidth: charWidth)
                lines.append([first])
                if !rest.isEmpty {
                    remaining.insert(rest, at: 0)
                }
            }
        }

        return lines
    }

    /// Splits an over-cap token, preferring the last identifier boundary inside
    /// the cap-fitting prefix and falling back to a grapheme break.
    private static func splitToken(
        _ word: String,
        atCap cap: Double,
        charWidth: Double
    ) -> (first: String, rest: String) {
        let (graphemicFirst, graphemicRest) = splitWordToFitWidth(word, cap, charWidth)
        if let boundary = graphemicFirst.lastIndex(where: { tokenBreakCharacters.contains($0) }) {
            // `graphemicFirst` is a prefix of `word`, so its offsets carry over.
            // Keep the separator on the first line.
            let offset = graphemicFirst.distance(from: graphemicFirst.startIndex, to: boundary) + 1
            let splitPoint = word.index(word.startIndex, offsetBy: offset)
            return (String(word[..<splitPoint]), String(word[splitPoint...]))
        }
        return (graphemicFirst, graphemicRest)
    }

    /// The longest grapheme prefix of `word` that fits `maxWidth`, plus the rest.
    /// Always consumes at least one grapheme so callers make progress.
    private static func splitWordToFitWidth(
        _ word: String,
        _ maxWidth: Double,
        _ charWidth: Double
    ) -> (first: String, rest: String) {
        let graphemes = Array(word)
        guard !graphemes.isEmpty else { return ("", "") }

        var used: [Character] = []
        var remainingStart = graphemes.count
        for (index, grapheme) in graphemes.enumerated() {
            let candidate = used + [grapheme]
            if lineWidth(String(candidate), charWidth: charWidth) <= maxWidth || used.isEmpty {
                used = candidate
                continue
            }
            remainingStart = index
            break
        }

        if used.isEmpty {
            used = [graphemes[0]]
            remainingStart = 1
        }

        let rest = remainingStart < graphemes.count ? String(graphemes[remainingStart...]) : ""
        return (String(used), rest)
    }
}
