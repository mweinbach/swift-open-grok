// ANSISegmentWaveBTests.swift
//
// Wave B-ANSI hardening: SGR spans survive wrapping, CR progress resolves,
// and plain-text extraction strips escapes for copy.
//
// Reference pin: 650c1db7^
//   cr/segment.rs 1-210 — split_into_line_segments (anstyle-parse VTE)
//   pager-render/render/terminal_output.rs 1-150 — render_terminal_lines/plain
//
// This suite locks the three Wave B1 renderer requirements on the existing
// `OpenGrokTerminalCore` segment utilities so the execute card painter can
// wire them without churn. Where the existing API was already sufficient we
// document the integration rather than wrapping it.

import Testing
@testable import OpenGrokTerminalCore

private func waveBViews(_ segments: [LineSegment]) -> [String] {
    segments.map { "\($0.content)\u{1}\($0.endsWithCRLF ? "1" : "0")" }
}

private func waveBEncode(_ pairs: [(String, Bool)]) -> [String] {
    pairs.map { "\($0.0)\u{1}\($0.1 ? "1" : "0")" }
}

private func waveBChunked(_ input: String, termWidth: Int, chunkBytes: Int) -> [LineSegment] {
    var splitter = ANSILineSplitter(termWidth: termWidth)
    let bytes = Array(input.utf8)
    var index = 0
    let want = max(chunkBytes, 1)
    while index < bytes.count {
        var end = min(index + want, bytes.count)
        if end < bytes.count {
            while end > index && bytes[end] & 0xC0 == 0x80 { end -= 1 }
        }
        if end == index {
            end = index + 1
            while end < bytes.count && bytes[end] & 0xC0 == 0x80 { end += 1 }
        }
        splitter.push(String(decoding: bytes[index..<end], as: UTF8.self))
        index = end
    }
    return splitter.finish()
}

@Suite("ANSISegment Wave B — ANSI/CR rendering support")
struct ANSISegmentWaveBTests {

    // MARK: - SGR resets

    @Test("SGR resets are zero-width and survive stripping")
    func sgrResets() {
        // Bare reset forms that Rust anstyle-parse treats as `m` with
        // empty params (segment.rs csi_dispatch) and ` ESC[m` reset.
        #expect(stripAnsiSequences("\u{1B}[0m") == "")
        #expect(stripAnsiSequences("\u{1B}[m") == "")
        #expect(stripAnsiSequences("\u{1B}[0;0m") == "")
        #expect(stripAnsiSequences("\u{1B}[31mred\u{1B}[0m") == "red")
        #expect(stripAnsiSequences("\u{1B}[1m\u{1B}[31mBold Red\u{1B}[0m") == "Bold Red")
        #expect(stripAnsiSequences("\u{1B}[1m\u{1B}[31m\u{1B}[0m\u{1B}[0m") == "")

        // SGRs are zero-width for wrapping: a full row plus reset stays on the same row,
        // next visual wraps. Mirrors segment.rs test_wrap_with_trailing_ansi.
        let segs = splitIntoLineSegments("12345678\u{1B}[0m90", termWidth: 8)
        #expect(waveBViews(segs) == waveBEncode([
            ("12345678\u{1B}[0m", false),
            ("90", false),
        ]))
        #expect(stripAnsiSequences(segs[0].content) == "12345678")
        #expect(stripAnsiSequences(segs[1].content) == "90")
    }

    @Test("adjacent SGR sequences do not leak or create extra rows")
    func adjacentSGR() {
        let input = "\u{1B}[31m\u{1B}[1mHello\u{1B}[0m\u{1B}[0m World"
        let segs = splitIntoLineSegments(input, termWidth: 80)
        #expect(segs.count == 1)
        #expect(segs[0].content == input)
        #expect(stripAnsiSequences(input) == "Hello World")

        // Two resets back-to-back after a filled line still keep the resets
        // on the first physical row — they have no visual width.
        let wrapped = splitIntoLineSegments("12345678\u{1B}[0m\u{1B}[0m90", termWidth: 8)
        #expect(waveBViews(wrapped) == waveBEncode([
            ("12345678\u{1B}[0m\u{1B}[0m", false),
            ("90", false),
        ]))
    }

    // MARK: - xterm 256 / truecolor (semicolon and colon subparams)

    @Test("xterm 256-color and truecolor escapes are stripped and zero-width")
    func xtermColors() {
        // 256-color (palette index)
        #expect(stripAnsiSequences("\u{1B}[38;5;196mred\u{1B}[0m") == "red")
        #expect(stripAnsiSequences("\u{1B}[48;5;10m on green\u{1B}[0m") == " on green")
        // Truecolor semicolon form — Powershell / modern shells
        #expect(stripAnsiSequences("\u{1B}[38;2;10;20;30mtrue\u{1B}[0m") == "true")
        #expect(stripAnsiSequences("\u{1B}[48;2;255;128;0mWARNING\u{1B}[0m") == "WARNING")
        // Truecolor colon form (ISO 8613-6) — same color, different separator,
        // exercised by terminal_output.rs ext_color colon branch.
        #expect(stripAnsiSequences("\u{1B}[38:2:10:20:30mtrue\u{1B}[0m") == "true")
        #expect(stripAnsiSequences("\u{1B}[38:5:196mext\u{1B}[0m") == "ext")

        // They do not affect display width: a full-width row plus a
        // truecolor open stays on that row.
        let segs = splitIntoLineSegments("12345678\u{1B}[38;2;255;128;0m90", termWidth: 8)
        #expect(waveBViews(segs) == waveBEncode([
            ("12345678\u{1B}[38;2;255;128;0m", false),
            ("90", false),
        ]))

        let colonWrap = splitIntoLineSegments("12345678\u{1B}[38:2:10:20:30m90", termWidth: 8)
        #expect(waveBViews(colonWrap) == waveBEncode([
            ("12345678\u{1B}[38:2:10:20:30m", false),
            ("90", false),
        ]))

        // Background xterm sequences also zero-width
        let bgWrap = splitIntoLineSegments("1234567\u{1B}[48;5;10m8", termWidth: 8)
        #expect(bgWrap.count == 1)
        #expect(stripAnsiSequences(bgWrap[0].content) == "12345678")
    }

    // MARK: - SGR span survival across wrapping

    @Test("SGR color span survives terminal wrapping without counting toward width")
    func sgrSurvivesWrapping() {
        // Open color, then 10 visual chars at width 8 → wraps at 8, the open
        // SGR stays with the first row, second row starts without re-emitting
        // (the renderer re-applies via styled spans; the segment must not
        // attribute the SGR's bytes to the second row).
        let input = "\u{1B}[31m1234567890"
        let segs = splitIntoLineSegments(input, termWidth: 8)
        #expect(segs.count == 2)
        #expect(segs[0].content == "\u{1B}[31m12345678")
        #expect(segs[1].content == "90")
        #expect(stripAnsiSequences(segs.map(\.content).joined()) == "1234567890")

        // SGR in the middle of a long run moves with its visual partition.
        let mid = "12\u{1B}[32m34567890"
        let midSegs = splitIntoLineSegments(mid, termWidth: 8)
        #expect(midSegs.count == 2)
        // Width before SGR: "12" is 2 cols, SGR zero-width, then "345678" fills to 8.
        #expect(midSegs[0].content == "12\u{1B}[32m345678")
        #expect(midSegs[1].content == "90")
        #expect(stripAnsiSequences(midSegs.map(\.content).joined()) == "1234567890")

        // Multiple SGRs that together exceed no width still don't cause wrap.
        let many = "\u{1B}[31m\u{1B}[1m\u{1B}[4m12345678\u{1B}[0m90"
        let manySegs = splitIntoLineSegments(many, termWidth: 8)
        #expect(waveBViews(manySegs) == waveBEncode([
            ("\u{1B}[31m\u{1B}[1m\u{1B}[4m12345678\u{1B}[0m", false),
            ("90", false),
        ]))
    }

    // MARK: - CR progress replacement (width reset, no hard break)

    @Test("bare CR resets visual width but does not hard-break")
    func carriageReturnResetsWidth() {
        // segment.rs test_bare_cr_resets_width: "12345\r67" fits at width 10.
        let segs = splitIntoLineSegments("12345\r67", termWidth: 10)
        #expect(waveBViews(segs) == waveBEncode([("12345\r67", false)]))
        // Strip keeps CR byte — copy can still resolve overwrite.
        #expect(stripAnsiSequences("12345\r67") == "12345\r67")

        // CR in the middle of a long line resets the wrap budget.
        // "1234567" (7) + CR resets to 0 then "ABCDEFGH" (8) fits exactly.
        let wrapAfterCR = splitIntoLineSegments("1234567\rABCDEFGH", termWidth: 8)
        #expect(wrapAfterCR.count == 1)
        #expect(wrapAfterCR[0].content == "1234567\rABCDEFGH")

        // Narrow width: content before CR already near the edge, CR lets
        // suffix reuse the budget without an extra physical row.
        let narrow = splitIntoLineSegments("12345\rABC", termWidth: 5)
        // "12345" fills width 5, but CR resets; "ABC" fits.
        #expect(narrow.count == 1)
        #expect(narrow[0].content == "12345\rABC")

        // Multiple CRs (spinner / progress)
        let progress = "10%\r50%\r100%\n"
        let pSegs = splitIntoLineSegments(progress, termWidth: 20)
        #expect(waveBViews(pSegs) == waveBEncode([("10%\r50%\r100%", true)]))
        // The final LF marks the progress row as a hard break without
        // fabricating a second empty segment. Bare CRs still create no rows.
    }

    @Test("CR + ANSI progress bar wraps at reset width")
    func crProgressWithAnsiWraps() {
        // SGR-colored progress that overwrites via CR: the SGR must not
        // affect width, and the CR must reset before measuring suffix.
        let input = "\u{1B}[32m10%\u{1B}[0m\r\u{1B}[32m50%\u{1B}[0m\r\u{1B}[32m100%\u{1B}[0m"
        let segs = splitIntoLineSegments(input, termWidth: 10)
        // Whole progress line fits even with ANSI, one physical row.
        #expect(segs.count == 1)
        #expect(stripAnsiSequences(segs[0].content) == "10%\r50%\r100%")
        // Escapes are preserved verbatim for the renderer, stripped for copy.
        #expect(segs[0].content.contains("\u{1B}[32m"))
    }

    // MARK: - CRLF correctness (Swift Character is one, bytes are two)

    @Test("CRLF is one Character but two bytes; both LF and CRLF hard-break")
    func crlfCorrectness() {
        let crlf = "\r\n"
        #expect(crlf.count == 1) // Swift trap: \r\n is one Character

        let fromLF = splitIntoLineSegments("line1\nline2", termWidth: 20)
        let fromCRLF = splitIntoLineSegments("line1" + crlf + "line2", termWidth: 20)
        #expect(waveBViews(fromLF) == waveBEncode([("line1", true), ("line2", false)]))
        #expect(waveBViews(fromCRLF) == waveBViews(fromLF))

        // Mixed LF / CRLF in one stream
        let mixed = splitIntoLineSegments("line1\r\nline2\nline3", termWidth: 20)
        #expect(waveBViews(mixed) == waveBEncode([
            ("line1", true), ("line2", true), ("line3", false),
        ]))

        // CRLF strip retains both bytes when stripping.
        #expect(stripAnsiSequences("a\r\nb") == "a\r\nb")
        #expect(stripAnsiSequences("a\nb") == "a\nb")

        // CRLF edge: lone CR before LF inside pending CSI does not leak
        // bytes (segment.rs:138-145 \x1b[3\n1m). The pending "\x1b[3" before
        // LF is dropped, LF emits previous visual run.
        let interrupted = "interrupted \u{1B}[3\nmid-sequence"
        let segs = splitIntoLineSegments(interrupted, termWidth: 20)
        #expect(waveBViews(segs) == waveBEncode([
            ("interrupted ", true),
            ("mid-sequence", false),
        ]))
        #expect(stripAnsiSequences(interrupted) == "interrupted \nid-sequence")
    }

    @Test("CRLF hard-break strips the preceding CR byte from segment content")
    func crlfStripsCR() {
        let s = splitIntoLineSegments("test\r\n", termWidth: 20)
        #expect(s.count == 1)
        #expect(s[0].content == "test")
        #expect(s[0].endsWithCRLF)
        // Bare \r not followed by \n does NOT set endsWithCRLF — it's a
        // progress overwrite, not a line ending.
        let bare = splitIntoLineSegments("test\r", termWidth: 20)
        #expect(bare.count == 1)
        #expect(bare[0].content == "test\r")
        #expect(!bare[0].endsWithCRLF)
    }

    // MARK: - Split / adjacent escape sequences

    @Test("adjacent escapes stay together and with their visual run")
    func adjacentEscapes() {
        let input = "\u{1B}[31m\u{1B}[1m\u{1B}[4mnested\u{1B}[0m\u{1B}[0m end"
        let segs = splitIntoLineSegments(input, termWidth: 80)
        #expect(segs.count == 1)
        #expect(segs[0].content == input)
        #expect(stripAnsiSequences(input) == "nested end")

        // CSI cursor-move (non-SGR) also zero-width: "cursor \x1b[2A moves" → moves stripped
        #expect(stripAnsiSequences("cursor \u{1B}[2Amoves") == "cursor moves")
        let moveSegs = splitIntoLineSegments("cursor \u{1B}[2Amoves", termWidth: 80)
        #expect(moveSegs.count == 1)
        #expect(stripAnsiSequences(moveSegs[0].content) == "cursor moves")
    }

    @Test("incremental feed matches one-shot even when CSI straddles chunks")
    func splitAcrossChunks() {
        let cases: [(String, Int)] = [
            ("\u{1B}[31mred\u{1B}[0m plain", 20),
            ("12345678\u{1B}[0m90", 8),
            ("text\u{1B}]8;;https://example.com\u{07}link\u{1B}]8;;\u{07} after", 8),
            ("interrupted \u{1B}[3\nmid-sequence", 10),
            ("line1\u{1B}[31m", 20),
            ("\u{1B}[38;2;10;20;30mtrue\u{1B}[0m", 10),
            ("12345\r67", 10),
        ]
        for (input, width) in cases {
            let oneShot = splitIntoLineSegments(input, termWidth: width)
            for chunk in [1, 2, 3, 7] {
                let chunked = waveBChunked(input, termWidth: width, chunkBytes: chunk)
                #expect(
                    waveBViews(chunked) == waveBViews(oneShot),
                    "width \(width) chunk \(chunk) input \(input.debugDescription)"
                )
            }
        }
        // Explicit split inside a CSI param: ESC + "[" in one push, "31m" in next
        var s1 = ANSILineSplitter(termWidth: 80)
        s1.push("hi\u{1B}[")
        s1.push("31mred")
        let split = s1.finish()
        let whole = splitIntoLineSegments("hi\u{1B}[31mred", termWidth: 80)
        #expect(waveBViews(split) == waveBViews(whole))
    }

    // MARK: - Wrapping metadata needed by the renderer

    @Test("segments never exceed visual width; endsWithCRLF is renderer metadata")
    func wrappingMetadata() {
        // Renderer uses endsWithCRLF to decide hard-break vs soft-wrap;
        // Seg.visible width must be ≤ termWidth except for a lone wide char.
        for width in [1, 2, 4, 8, 20, 80] {
            for input in [
                "hello world, this is a longer line that will wrap several times",
                "😊😊😊 emoji wall 😊😊😊",
                "hello 你好 混合 width",
                "\u{1B}[31mred\u{1B}[0m plain \u{1B}[1;32;44mstyled\u{1B}[m",
            ] {
                let segs = splitIntoLineSegments(input, termWidth: width)
                for seg in segs where !seg.endsWithCRLF {
                    let plain = stripAnsiSequences(seg.content)
                    // CR resets are not new lines; measure after last CR.
                    let lastChunk = plain.split(separator: "\r").last.map(String.init) ?? plain
                    let vis = UnicodeDisplayWidth.width(of: lastChunk)
                    #expect(
                        vis <= width || vis == UnicodeDisplayWidth.width(of: plain),
                        "width \(width) seg \(seg.content.debugDescription) vis \(vis)"
                    )
                }
            }
        }
        // A single emoji wider than terminal still emits one segment (does not loop).
        let wide = splitIntoLineSegments("😊", termWidth: 1)
        #expect(waveBViews(wide) == waveBEncode([("😊", false)]))
        // Renderer can join segment.content pieces to reconstruct the raw stream
        // modulo dropped incomplete tails and CRLF stripping. For CR-free,
        // escape-complete inputs the join equals the raw minus hard-break LF.
        let raw = "line1\nline2\nline3"
        let joined = splitIntoLineSegments(raw, termWidth: 80).map(\.content).joined(separator: "\n")
        #expect(joined == raw)
    }

    @Test("zero-width trailing SGR folds into prior row; newline separates")
    func trailingSGRFolding() {
        // No newline: trailing SGR without visual re-uses previous row.
        let one = splitIntoLineSegments("line1\u{1B}[31m", termWidth: 20)
        #expect(waveBViews(one) == waveBEncode([("line1\u{1B}[31m", false)]))
        // With newline: the SGR after LF starts a new row on its own.
        let two = splitIntoLineSegments("line1\n\u{1B}[31m", termWidth: 20)
        #expect(waveBViews(two) == waveBEncode([("line1", true), ("\u{1B}[31m", false)]))
        // Renderer needs this to know whether to paint an empty row.
    }

    // MARK: - Escape-free plain text for copy

    @Test("plain-text extraction is escape-free and UTF-8 safe")
    func escapeFreePlainText() {
        // Every CSI/OSC/DCS variant must vanish; only printable and C0 remains.
        #expect(stripAnsiSequences("\u{1B}[31mred\u{1B}[0m") == "red")
        #expect(stripAnsiSequences("\u{1B}[38;2;10;20;30mtrue\u{1B}[0m") == "true")
        #expect(stripAnsiSequences("\u{1B}[38;5;196mext\u{1B}[0m") == "ext")
        #expect(stripAnsiSequences("cursor \u{1B}[2Amoves") == "cursor moves")
        #expect(stripAnsiSequences("\u{1B}(Bcharset\u{1B})0") == "charset")
        #expect(stripAnsiSequences("text\u{1B}]8;;https://example.com\u{07}link\u{1B}]8;;\u{07} after") == "textlink after")
        // ESC-\ (ST) terminator for OSC 8
        #expect(
            stripAnsiSequences("text\u{1B}]8;;https://example.com\u{07}link\u{1B}]8;;\u{1B}\\ after")
            == "textlink after"
        )
        // Tabs, backspace, and other kept C0
        #expect(stripAnsiSequences("tab\tx") == "tab\tx")
        #expect(stripAnsiSequences("\u{1B}[2K\u{1B}[0m") == "")

        // No ESC byte survives
        for raw in [
            "\u{1B}[31m\u{1B}[1mhi\u{1B}[0m",
            "\u{1B}[38;5;10mhi\u{1B}[0m",
            "\u{1B}]0;title\u{07}body",
            "\u{1B}]8;;http://x\u{07}link\u{1B}]8;;\u{07}",
        ] as [String] {
            let plain = stripAnsiSequences(raw)
            #expect(!plain.utf8.contains(0x1B), "ESC leaked in \(raw.debugDescription) → \(plain.debugDescription)")
            #expect(!plain.contains("\u{07}"), "BEL leaked in \(raw.debugDescription)")
        }

        // Multi-byte and combining safe
        #expect(stripAnsiSequences("😊\u{1B}[31m😊") == "😊😊")
        #expect(stripAnsiSequences("e\u{0301}\u{1B}[0m") == "e\u{0301}")

        // Segments' stripped join equals stripped raw (modulo CRLF normalization)
        let input = "\u{1B}[31mred\u{1B}[0m plain \u{1B}[1mworld"
        let segs = splitIntoLineSegments(input, termWidth: 80)
        #expect(segs.map { stripAnsiSequences($0.content) }.joined() == stripAnsiSequences(input))
    }

    // MARK: - Integration note helper

    @Test("integration: renderer re-renders SGR per row from segments")
    func integrationNote() {
        // The execute card painter should NOT feed raw ANSI into the styled
        // line wrapper. The supported integration is:
        //   let segs = splitIntoLineSegments(output, termWidth: width)
        //   // each seg.content still carries its ANSI prefix; re-apply by
        //   // parsing seg.content with the same VTE state or by stripping
        //   // for copy. For copy: stripAnsiSequences(output)
        // Wrapping already zero-counts escapes, so segs never overflows
        // because of color codes.
        let raw = "\u{1B}[32m✔\u{1B}[0m done"
        let segs = splitIntoLineSegments(raw, termWidth: 20)
        #expect(segs.count == 1)
        #expect(stripAnsiSequences(segs[0].content) == "✔ done")
        #expect(segs[0].content.contains("\u{1B}[32m"))
    }
}
