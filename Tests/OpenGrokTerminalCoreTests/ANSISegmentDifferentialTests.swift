// ANSISegmentDifferentialTests.swift
//
// Port of crates/codegen/xai-ratatui-inline/tests/segment_differential.rs
// at pin 650c1db7. Rust compares anstyle-parse vs termwiz; Swift asserts
// the same corpus against one-shot vs chunked feed, plus the wrap / OSC-8 /
// wide-char / empty / strip properties that corpus is meant to lock.

import Testing
@testable import OpenGrokTerminalCore

private let corpus: [String] = [
    "",
    "hello",
    "hello world, this is a longer line that will wrap several times",
    "line1\nline2\nline3",
    "line1\r\nline2\r\n",
    "12345\r67",
    "\r\r\n\n\r",
    "😊😊😊 emoji wall 😊😊😊",
    "hello 你好 混合 width",
    "\u{1B}[31mred\u{1B}[0m plain \u{1B}[1;32;44mstyled\u{1B}[m",
    "\u{1B}[31m\u{1B}[1m\u{1B}[4mnested styles no text\u{1B}[0m",
    "12345678\u{1B}[0m90",
    "text\u{1B}]8;;https://example.com\u{07}link\u{1B}]8;;\u{07} after",
    "osc title\u{1B}]0;window title\u{07}body",
    "cursor \u{1B}[2Amoves \u{1B}[10;20H everywhere",
    "tab\tand\u{08}backspace and \u{07}bell",
    "\u{1B}[38;5;196mext colors\u{1B}[38;2;10;20;30m truecolor\u{1B}[0m",
    "interrupted \u{1B}[3\nmid-sequence",
    "\u{1B}[31m\nstyle then newline",
    "trailing style 12345678\u{1B}[0m",
    "\u{1B}(Bcharset\u{1B})0 escapes",
    "zero\u{200B}width\u{FE0F}chars",
    "combining a\u{0301}e\u{0301} accents",
]

private let widths: [Int] = [1, 2, 3, 5, 8, 10, 20, 80, 200]

/// Tuple arrays are not `Equatable` under Swift Testing's `#expect`.
private func views(_ segments: [LineSegment]) -> [String] {
    encodeViews(segments.map { ($0.content, $0.endsWithCRLF) })
}

private func encodeViews(_ pairs: [(String, Bool)]) -> [String] {
    pairs.map { "\($0.0)\u{1}\($0.1 ? "1" : "0")" }
}

/// Split `input` at UTF-8 scalar boundaries of `chunkBytes` and feed the
/// incremental splitter. CSI/OSC can land across chunks; a code point cannot
/// (Swift `String` is valid UTF-8).
private func splitChunked(_ input: String, termWidth: Int, chunkBytes: Int) -> [LineSegment] {
    var splitter = ANSILineSplitter(termWidth: termWidth)
    let bytes = Array(input.utf8)
    var index = 0
    let want = max(chunkBytes, 1)
    while index < bytes.count {
        var end = min(index + want, bytes.count)
        if end < bytes.count {
            while end > index && bytes[end] & 0xC0 == 0x80 {
                end -= 1
            }
        }
        if end == index {
            end = index + 1
            while end < bytes.count && bytes[end] & 0xC0 == 0x80 {
                end += 1
            }
        }
        splitter.push(String(decoding: bytes[index..<end], as: UTF8.self))
        index = end
    }
    return splitter.finish()
}

@Suite("ANSISegment differential (pin 650c1db7 corpus)")
struct ANSISegmentDifferentialTests {
    @Test("empty input yields no segments")
    func emptyInput() {
        #expect(splitIntoLineSegments("", termWidth: 10).isEmpty)
        #expect(splitIntoLineSegments("", termWidth: 1).isEmpty)
        #expect(splitChunked("", termWidth: 80, chunkBytes: 1).isEmpty)
        #expect(stripAnsiSequences("").isEmpty)
    }

    @Test("corpus one-shot matches chunked feed at every pin width")
    func chunkedMatchesOneShot() {
        let chunkSizes = [1, 2, 3, 7, 16]
        for input in corpus {
            for width in widths {
                let oneShot = splitIntoLineSegments(input, termWidth: width)
                for chunk in chunkSizes {
                    let chunked = splitChunked(input, termWidth: width, chunkBytes: chunk)
                    #expect(
                        views(chunked) == views(oneShot),
                        "width \(width) chunk \(chunk) input \(input.debugDescription)"
                    )
                }
            }
        }
    }

    @Test("SGR after a filled line stays on that row; next visual wraps")
    func sgrAcrossWrap() {
        let input = "12345678\u{1B}[0m90"
        let segments = splitIntoLineSegments(input, termWidth: 8)
        #expect(views(segments) == encodeViews([
            ("12345678\u{1B}[0m", false),
            ("90", false),
        ]))
        #expect(stripAnsiSequences(segments[0].content) == "12345678")
        #expect(stripAnsiSequences(segments[1].content) == "90")

        let exact = splitIntoLineSegments("12345678\u{1B}[0m", termWidth: 8)
        #expect(views(exact) == encodeViews([("12345678\u{1B}[0m", false)]))
    }

    @Test("LF mid-CSI does not leak pending SGR; 'm' still finishes CSI")
    func sgrInterruptedByLineFeed() {
        let input = "interrupted \u{1B}[3\nmid-sequence"
        // "interrupted " is 12 cols; width 10 wraps, then LF emits the tail.
        // After LF the parser stays in CSI, so the following 'm' is the
        // finalizer (zero width) — wrap of the remainder uses 11, not 12.
        let at10 = splitIntoLineSegments(input, termWidth: 10)
        #expect(views(at10) == encodeViews([
            ("interrupte", false),
            ("d ", true),
            ("mid-sequenc", false),
            ("e", false),
        ]))
        // Joined segment text reconstructs the visible run: pending CSI
        // bytes before LF were dropped, so the leftover 'm' is just text.
        #expect(at10.map(\.content).joined() == "interrupted mid-sequence")
        // VTE strip of the raw input treats post-LF 'm' as the CSI finalizer.
        #expect(stripAnsiSequences(input) == "interrupted \nid-sequence")

        let at20 = splitIntoLineSegments(input, termWidth: 20)
        #expect(views(at20) == encodeViews([
            ("interrupted ", true),
            ("mid-sequence", false),
        ]))
    }

    @Test("OSC 8 hyperlink bytes stay with their visual run and strip to text")
    func osc8Links() {
        let input = "text\u{1B}]8;;https://example.com\u{07}link\u{1B}]8;;\u{07} after"
        #expect(stripAnsiSequences(input) == "textlink after")

        let wide = splitIntoLineSegments(input, termWidth: 80)
        #expect(wide.count == 1)
        #expect(wide[0].content == input)
        #expect(!wide[0].endsWithCRLF)

        let wrapped = splitIntoLineSegments(input, termWidth: 8)
        #expect(views(wrapped) == encodeViews([
            ("text\u{1B}]8;;https://example.com\u{07}link\u{1B}]8;;\u{07}", false),
            (" after", false),
        ]))
        #expect(stripAnsiSequences(wrapped[0].content) == "textlink")
        #expect(stripAnsiSequences(wrapped[1].content) == " after")

        let title = splitIntoLineSegments("osc title\u{1B}]0;window title\u{07}body", termWidth: 80)
        #expect(title.count == 1)
        #expect(stripAnsiSequences(title[0].content) == "osc titlebody")
    }

    @Test("wide characters wrap on display columns, not UTF-8 or Character count")
    func wideChars() {
        let emoji = splitIntoLineSegments("😊", termWidth: 1)
        #expect(views(emoji) == encodeViews([("😊", false)]))

        let mixed = "hello 你好"
        #expect(splitIntoLineSegments(mixed, termWidth: 10).count == 1)
        // "hello " = 6, 你 = 2 → 8; 好 = 2 would be 10, so wrap before 好.
        let wrapped = splitIntoLineSegments(mixed, termWidth: 9)
        #expect(views(wrapped) == encodeViews([
            ("hello 你", false),
            ("好", false),
        ]))
        #expect(UnicodeDisplayWidth.width(of: "你") == 2)

        let wall = splitIntoLineSegments("😊😊😊", termWidth: 4)
        #expect(views(wall) == encodeViews([
            ("😊😊", false),
            ("😊", false),
        ]))
    }

    @Test("CRLF is one Swift Character but two bytes; both LF and CRLF hard-break")
    func crlfIsOneCharacter() {
        let crlf = "\r\n"
        #expect(crlf.count == 1)

        let fromLF = splitIntoLineSegments("line1\nline2", termWidth: 20)
        let fromCRLF = splitIntoLineSegments("line1" + crlf + "line2", termWidth: 20)
        #expect(views(fromLF) == encodeViews([
            ("line1", true),
            ("line2", false),
        ]))
        #expect(views(fromCRLF) == views(fromLF))

        let mixed = splitIntoLineSegments("line1\r\nline2\nline3", termWidth: 20)
        #expect(views(mixed) == encodeViews([
            ("line1", true),
            ("line2", true),
            ("line3", false),
        ]))

        let bareCR = splitIntoLineSegments("12345\r67", termWidth: 10)
        #expect(views(bareCR) == encodeViews([("12345\r67", false)]))

        let crlfSoup = splitIntoLineSegments("\r\r\n\n\r", termWidth: 20)
        #expect(views(crlfSoup) == encodeViews([
            ("\r", true),
            ("", true),
            ("\r", false),
        ]))
    }

    @Test("stripAnsiSequences removes CSI/OSC and keeps visible text plus C0")
    func stripCsiOscAndControls() {
        #expect(stripAnsiSequences("\u{1B}[31mred\u{1B}[0m") == "red")
        #expect(stripAnsiSequences("a\r\nb\u{1B}[32mc") == "a\r\nbc")
        #expect(stripAnsiSequences("a\nb") == "a\nb")
        #expect(
            stripAnsiSequences("text\u{1B}]8;;https://example.com\u{07}link\u{1B}]8;;\u{1B}\\ after")
                == "textlink after"
        )
        #expect(stripAnsiSequences("tab\tx") == "tab\tx")
        #expect(stripAnsiSequences("\u{1B}[38;2;10;20;30mtrue\u{1B}[0m") == "true")
        #expect(stripAnsiSequences("cursor \u{1B}[2Amoves") == "cursor moves")
        #expect(stripAnsiSequences("\u{1B}(Bcharset\u{1B})0") == "charset")
    }

    @Test("randomized ANSI soup: chunked converges with one-shot")
    func randomizedAnsiSoupChunkedConverges() {
        var state: UInt64 = 0x243F_6A88_85A3_08D3
        func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }

        let pieces: [String] = [
            "word",
            "a",
            "longer-token",
            " ",
            "  ",
            "\n",
            "\r",
            "\r\n",
            "😊",
            "你好",
            "é",
            "\u{200B}",
            "\u{1B}[31m",
            "\u{1B}[0m",
            "\u{1B}[1;44;38;5;10m",
            "\u{1B}[2K",
            "\u{1B}[10D",
            "\u{1B}]0;title\u{07}",
            "\u{1B}]8;;http://x\u{07}",
            "\t",
            "\u{07}",
        ]

        for _ in 0..<2000 {
            var input = ""
            let length = Int(next() % 30)
            for _ in 0..<length {
                input += pieces[Int(next() % UInt64(pieces.count))]
            }
            let width = 1 + Int(next() % 40)
            let oneShot = splitIntoLineSegments(input, termWidth: width)
            let chunkBytes = 1 + Int(next() % 8)
            let chunked = splitChunked(input, termWidth: width, chunkBytes: chunkBytes)
            #expect(
                views(chunked) == views(oneShot),
                "width \(width) chunk \(chunkBytes) input \(input.debugDescription)"
            )
        }
    }
}
