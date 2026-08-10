// MinimalCommitRenderTests.swift
//
// Wave 18 B2-M2: the committed-block paint path. Ports the
// renderer-dependent half of `xai-grok-pager-minimal/src/commit_tests.rs`
// at pin 650c1db7 that M1 deferred — the cap/footer family, the accent
// column rules, the collapsed-header affordance, and the K5 containment
// guard — adapted to the port's line-based layout (upstream renders through
// `EntryRenderer` into ratatui buffers; here the SAME `appendMessage` /
// `appendToolCard` calls that lay out the strip produce the committed
// lines, so height == lines.count by construction and the tests pin the
// PAINTER instead of a height/paint pair that can drift).

import Foundation
import Testing
import OpenGrokMinimalScrollback
import OpenGrokTerminalCore
@testable import OpenGrokPagerRender

private let theme = PagerRenderTheme.default

private func thinking(_ text: String, duration: TimeInterval? = 1.4) -> PagerConversationItem {
    .message(PagerMessage(role: .reasoning, text: text, duration: duration))
}

private func agentMessage(_ text: String) -> PagerConversationItem {
    .message(PagerMessage(role: .assistant, text: text))
}

/// Render `item` under the minimal committed stance and paint it into a
/// buffer of exactly `rows` rows (the shape `insertCommitted` allocates).
private func paint(
    _ block: MinimalCommittedBlock,
    rows: Int,
    width: Int
) -> CellBuffer {
    var buffer = CellBuffer.empty(TerminalRect(x: 0, y: 0, width: width, height: rows))
    MinimalCommitRender.paintCommitted(block, into: &buffer, theme: theme)
    return buffer
}

private func rowText(_ buffer: CellBuffer, _ y: Int, width: Int) -> String {
    var text = ""
    for x in 0..<width {
        guard let cell = buffer.cell(x: x, y: y), !cell.skip else { continue }
        text += cell.grapheme
    }
    return text
}

@Suite("Minimal committed paint path")
struct MinimalCommitRenderTests {
    // commit_tests.rs:709-747 — a block taller than the cap keeps its top
    // `cap - 1` content rows and the final row becomes the overflow footer
    // naming the hidden line count and pointing at /transcript.
    @Test("large commit is capped with footer")
    func largeCommitIsCappedWithFooter() {
        let lines = (0..<60).map { "line \($0)" }.joined(separator: "\n")
        let width = 80
        let block = MinimalCommitRender.committedLines(
            item: agentMessage(lines),
            displayMode: .expanded,
            width: width,
            theme: theme
        )
        let fullH = block.height
        #expect(fullH > 12, "expected a tall block, got \(fullH)")

        let cap = 12
        let buffer = paint(block, rows: cap, width: width)
        let last = rowText(buffer, cap - 1, width: width)
        #expect(last.contains("more lines"), "footer row: \(last)")
        #expect(last.contains("/transcript"), "footer row: \(last)")
        let hidden = fullH - (cap - 1)
        #expect(
            last.contains("\(hidden)"),
            "footer should name \(hidden) hidden lines: \(last)"
        )
        // The kept rows are the SAME rows an uncapped commit would paint
        // (K5: one layout produced both), and the row above the footer is
        // still content.
        #expect(rowText(buffer, 0, width: width).contains("line 0"))
        #expect(rowText(buffer, cap - 2, width: width).contains("line \(cap - 2)"))
    }

    // commit_tests.rs:749-778 — a buffer exactly the block's height paints
    // no footer (the uncapped path).
    @Test("small commit is not capped")
    func smallCommitIsNotCapped() {
        let width = 80
        let block = MinimalCommitRender.committedLines(
            item: agentMessage("one short line"),
            displayMode: .expanded,
            width: width,
            theme: theme
        )
        let buffer = paint(block, rows: block.height, width: width)
        var all = ""
        for y in 0..<block.height {
            all += rowText(buffer, y, width: width)
        }
        #expect(!all.contains("more lines"), "no footer when uncapped: \(all)")
    }

    // Adapted from commit_tests.rs:498-538 (`assert_committed_fits`): the
    // painter must never write real content outside the advertised height —
    // rows past `height` in an over-tall buffer stay blank. Upstream needs
    // this because desired_height and render can drift; here it pins the
    // painter (footer placement, rail, flush-left) against future bugs.
    @Test("committed blocks fit their advertised height")
    func committedBlocksFitTheirAdvertisedHeight() {
        let long = "Hello there — this is a longer message that should wrap across "
            + "several lines at narrow widths to exercise the wrapping math, with "
            + "enough words to overflow eighty columns comfortably."
        let items: [(String, PagerConversationItem, MinimalDisplayMode)] = [
            ("user_prompt", .message(PagerMessage(role: .user, text: long)), .expanded),
            ("agent_message", agentMessage(long + "\n\n- bullet one\n- bullet two"), .expanded),
            ("thinking", thinking(long), .expanded),
            ("system", .message(PagerMessage(role: .system, text: "Session restored")), .expanded),
            (
                "execute",
                .tool(PagerToolCard(
                    name: "Run",
                    kind: .execute,
                    input: "cargo build --release",
                    output: "line 1\nline 2\nline 3\nline 4\nline 5\nline 6",
                    state: .succeeded
                )),
                .truncated
            ),
            (
                "edit",
                .tool(PagerToolCard(name: "Edit", kind: .edit, input: "src/main.rs", state: .succeeded)),
                .expanded
            ),
            (
                "search",
                .tool(PagerToolCard(
                    name: "Search", kind: .search, input: "TODO",
                    detail: "(0 matches)", state: .succeeded
                )),
                .collapsed
            ),
            ("separator", .separator(""), .expanded),
        ]
        for width in [40, 80, 120] {
            for (label, item, mode) in items {
                let block = MinimalCommitRender.committedLines(
                    item: item, displayMode: mode, width: width, theme: theme
                )
                #expect(block.height > 0, "\(label)@\(width): height was 0")
                let extra = 8
                let buffer = paint(block, rows: block.height + extra, width: width)
                for y in block.height..<(block.height + extra) {
                    let text = rowText(buffer, y, width: width)
                    #expect(
                        text.trimmingCharacters(in: .whitespaces).isEmpty,
                        "\(label)@\(width): content \(text) painted at row \(y), past height \(block.height) — insertBefore would clip it"
                    )
                }
            }
        }
    }

    // commit_tests.rs:853-930 — reserved only where painted: non-collapsed
    // reasoning keeps the 1-column rail; everything else starts at column 0.
    @Test("only thinking spends the accent column")
    func onlyThinkingSpendsTheAccentColumn() {
        let reasoningBody = "reasoning long enough to wrap over a couple of rows at sixty columns"
        #expect(
            MinimalCommitRender.committedLines(
                item: thinking(reasoningBody), displayMode: .expanded, width: 60, theme: theme
            ).chromeWidth == 1,
            "expanded reasoning reserves the 1-col accent gutter"
        )
        #expect(
            MinimalCommitRender.committedLines(
                item: thinking(reasoningBody), displayMode: .collapsed, width: 60, theme: theme
            ).chromeWidth == 0,
            "collapsed reasoning has no body to delimit — no reserved column"
        )

        let others: [(String, PagerConversationItem)] = [
            ("agent_message", agentMessage("answer")),
            ("user_prompt", .message(PagerMessage(role: .user, text: "ask"))),
            ("system", .message(PagerMessage(role: .system, text: "Session restored"))),
            ("execute", .tool(PagerToolCard(name: "Run", kind: .execute, input: "ls", state: .succeeded))),
            ("edit", .tool(PagerToolCard(name: "Edit", kind: .edit, input: "src/main.rs", state: .succeeded))),
        ]
        for (label, item) in others {
            let block = MinimalCommitRender.committedLines(
                item: item, displayMode: .expanded, width: 60, theme: theme
            )
            #expect(block.chromeWidth == 0, "only reasoning may spend the accent column: \(label)")
        }
    }

    // commit_tests.rs:932-994 adapted to the port's thinking stance: the
    // rail rows are the BODY rows (the header carries the `◆ Thought` bullet
    // instead — the port's landed strip look; upstream rails every row).
    // Every painted rail cell must be the accent bar, DIM — under the
    // flat/native look a full-brightness rail would shout. Assistant output
    // must not wear a rail.
    @Test("committed thinking paints a dim rail in column zero")
    func committedThinkingPaintsADimRailInColumnZero() {
        let width = 40
        let block = MinimalCommitRender.committedLines(
            item: thinking("a reasoning body long enough to wrap over several rows at this width"),
            displayMode: .expanded,
            width: width,
            theme: theme
        )
        #expect(block.height > 1, "expected a multi-row reasoning block, got \(block.height)")
        let buffer = paint(block, rows: block.height, width: width)
        var railRows = 0
        for y in 1..<block.height {
            guard let cell = buffer.cell(x: 0, y: y), cell.grapheme == PagerGlyphs.accentBar else {
                continue
            }
            railRows += 1
            #expect(
                cell.style.contains(.dim),
                "row \(y): rail must be dim, got \(cell.style)"
            )
        }
        #expect(railRows == block.height - 1, "every body row wears the rail")

        let answer = MinimalCommitRender.committedLines(
            item: agentMessage("the answer"), displayMode: .expanded, width: width, theme: theme
        )
        let answerBuffer = paint(answer, rows: answer.height, width: width)
        #expect(
            answerBuffer.cell(x: 0, y: 0)?.grapheme != PagerGlyphs.accentBar,
            "assistant output must not wear a rail"
        )
    }

    // commit_tests.rs:1090-1140 — a collapsed reasoning commit is ONE row
    // advertising the only way into a print-once folded block; too narrow
    // for the hint, the header still wins and it is still one row.
    @Test("collapsed thinking commit is one advertised row")
    func collapsedThinkingCommitIsOneAdvertisedRow() {
        let body = "a long reasoning body that would otherwise occupy many rows in the transcript"
        for width in [40, 80, 120] {
            let block = MinimalCommitRender.committedLines(
                item: thinking(body), displayMode: .collapsed, width: width, theme: theme
            )
            #expect(block.height == 1, "collapsed reasoning is one row @\(width)")
            let row = block.rowText(0)
            #expect(row.contains("Thought"), "@\(width): \(row)")
            #expect(
                row.contains("ctrl+e to expand"),
                "@\(width): the only way into a print-once folded block must be advertised: \(row)"
            )
        }

        let narrow = MinimalCommitRender.committedLines(
            item: thinking(body), displayMode: .collapsed, width: 16, theme: theme
        )
        #expect(narrow.height == 1, "too narrow for the hint: header still wins, one row")
        #expect(!narrow.rowText(0).contains("ctrl+e"), "hint dropped, not wrapped")
    }

    // The K9 escape M2 adds to the shared layout: a committed-Expanded
    // reasoning block renders its FULL body (the strip's 3-line truncation
    // must not leak into the print-once transcript), de-emphasized
    // dim+italic (`body_dim_italic`, thinking.rs:52-71).
    @Test("expanded thinking commits the full body, dim italic")
    func expandedThinkingCommitsTheFullBodyDimItalic() {
        let body = (0..<10).map { "reasoning row \($0)" }.joined(separator: "\n")
        let block = MinimalCommitRender.committedLines(
            item: thinking(body), displayMode: .expanded, width: 80, theme: theme
        )
        // Header + all ten body rows — no `…` truncation marker row.
        #expect(block.height == 11, "full body: got \(block.height) rows")
        for row in 0..<block.height {
            #expect(!block.rowText(row).contains("\u{2026}"), "no truncation marker")
        }
        let buffer = paint(block, rows: block.height, width: 80)
        // Body glyph cells carry dim+italic (probe a cell inside "reasoning").
        let probe = buffer.cell(x: 4, y: 1)
        #expect(probe?.style.contains(.dim) == true, "body must be dim")
        #expect(probe?.style.contains(.italic) == true, "body must be italic")
    }

    // The display-mode structural mapping for tools: collapsed = header
    // row only; truncated keeps the strip's head/tail preview with the
    // `… +n lines` marker; expanded paints EVERY output row (K9) — the cap
    // is the footer's job, not the preview's.
    @Test("tool display modes map to header, preview, and full output")
    func toolDisplayModesMapToHeaderPreviewAndFullOutput() {
        let output = (0..<20).map { "out \($0)" }.joined(separator: "\n")
        let card = PagerToolCard(
            name: "Run", kind: .execute, input: "make test", output: output, state: .succeeded
        )
        let width = 80

        let collapsed = MinimalCommitRender.committedLines(
            item: .tool(card), displayMode: .collapsed, width: width, theme: theme
        )
        #expect(collapsed.height == 1, "collapsed tool is its header row")

        let truncated = MinimalCommitRender.committedLines(
            item: .tool(card), displayMode: .truncated, width: width, theme: theme
        )
        let truncatedText = (0..<truncated.height).map(truncated.rowText).joined(separator: "\n")
        #expect(truncatedText.contains("+15 lines"), "head/tail preview marker: \(truncatedText)")

        let expanded = MinimalCommitRender.committedLines(
            item: .tool(card), displayMode: .expanded, width: width, theme: theme
        )
        let expandedText = (0..<expanded.height).map(expanded.rowText).joined(separator: "\n")
        #expect(!expandedText.contains("lines"), "no preview marker when expanded")
        for i in 0..<20 {
            #expect(expandedText.contains("out \(i)"), "expanded output keeps row \(i)")
        }
    }

    // Committed rows paint over `.reset` — the flat, terminal-native look
    // (`commit.rs:301`, insert_gap doc: rows inherit the terminal's own
    // background). Only line-carried bands (the user prompt) keep a color.
    @Test("committed rows keep the terminal-native background")
    func committedRowsKeepTheTerminalNativeBackground() {
        let width = 40
        let block = MinimalCommitRender.committedLines(
            item: agentMessage("plain answer"), displayMode: .expanded, width: width, theme: theme
        )
        let buffer = paint(block, rows: block.height, width: width)
        for x in 0..<width {
            #expect(
                buffer.cell(x: x, y: 0)?.background == TerminalColor.reset,
                "column \(x): committed content must not fill a background"
            )
        }

        let prompt = MinimalCommitRender.committedLines(
            item: .message(PagerMessage(role: .user, text: "run the tests")),
            displayMode: .expanded,
            width: width,
            theme: theme
        )
        let promptBuffer = paint(prompt, rows: prompt.height, width: width)
        #expect(
            promptBuffer.cell(x: 0, y: 1)?.background == theme.bgLight,
            "the user prompt keeps its band"
        )
    }
}
