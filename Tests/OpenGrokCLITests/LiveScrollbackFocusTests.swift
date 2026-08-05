import Foundation
@testable import OpenGrokCLI
import OpenGrokCompaction
import OpenGrokPager
import OpenGrokPagerRender
import Testing

/// The scrollback's selection cursor and the effects the `ScrollbackFocused`
/// bindings have on the transcript.
@Suite("Live scrollback selection")
struct LiveScrollbackFocusTests {
    /// A user turn, a thinking block, a tool call, and a response — enough
    /// shape for turn/response navigation and folding to mean something.
    private func makeTranscript() -> [PagerConversationItem] {
        [
            .message(PagerMessage(role: .user, text: "first question")),
            .message(PagerMessage(role: .reasoning, text: "weighing options", isCollapsed: true)),
            .tool(PagerToolCard(name: "read", input: "README.md", output: "contents")),
            .message(PagerMessage(role: .assistant, text: "first answer")),
            .message(PagerMessage(role: .user, text: "second question")),
            .message(PagerMessage(role: .assistant, text: "see https://example.com/docs for more")),
        ]
    }

    @Test("focus lands on the newest block and unfocus clears the cursor")
    func focusAndUnfocus() {
        var selection = LiveScrollbackSelection()
        #expect(selection.index == nil)
        #expect(selection.isFocused == false)

        selection.focus(itemCount: 6)
        #expect(selection.index == 5)
        #expect(selection.isFocused)

        selection.unfocus()
        #expect(selection.index == nil)
    }

    @Test("selection movement clamps at both ends rather than wrapping")
    func movementClamps() {
        var items = makeTranscript()
        var selection = LiveScrollbackSelection()
        selection.focus(itemCount: items.count)

        _ = selection.apply(.selectNext, items: &items)
        #expect(selection.index == 5, "already at the end")

        _ = selection.apply(.selectFirst, items: &items)
        #expect(selection.index == 0)
        _ = selection.apply(.selectPrevious, items: &items)
        #expect(selection.index == 0, "already at the start")

        _ = selection.apply(.selectNext, items: &items)
        #expect(selection.index == 1)
        _ = selection.apply(.selectLast, items: &items)
        #expect(selection.index == 5)
    }

    @Test("turn and response navigation step between the right block kinds")
    func turnAndResponseNavigation() {
        var items = makeTranscript()
        var selection = LiveScrollbackSelection()
        selection.focus(itemCount: items.count)
        _ = selection.apply(.selectFirst, items: &items)

        // Turns are the user prompts: 0 and 4.
        _ = selection.apply(.nextTurn, items: &items)
        #expect(selection.index == 4)
        _ = selection.apply(.previousTurn, items: &items)
        #expect(selection.index == 0)

        // Responses are the assistant messages: 3 and 5.
        _ = selection.apply(.nextResponse, items: &items)
        #expect(selection.index == 3)
        _ = selection.apply(.nextResponse, items: &items)
        #expect(selection.index == 5)
        _ = selection.apply(.nextResponse, items: &items)
        #expect(selection.index == 5, "no response after the last one")
    }

    @Test("h and l fold and unfold the selected block")
    func foldSelectedBlock() {
        var items = makeTranscript()
        var selection = LiveScrollbackSelection()
        selection.focus(itemCount: items.count)
        _ = selection.apply(.selectFirst, items: &items)
        _ = selection.apply(.selectNext, items: &items)
        _ = selection.apply(.selectNext, items: &items)

        guard case .tool(let before) = items[2] else {
            Issue.record("expected a tool card")
            return
        }
        #expect(before.isExpanded == false)

        _ = selection.apply(.expand, items: &items)
        guard case .tool(let expanded) = items[2] else {
            Issue.record("expected a tool card")
            return
        }
        #expect(expanded.isExpanded)

        _ = selection.apply(.toggleFold, items: &items)
        guard case .tool(let folded) = items[2] else {
            Issue.record("expected a tool card")
            return
        }
        #expect(folded.isExpanded == false)
    }

    @Test("E collapses everything when anything is open and opens everything otherwise")
    func toggleExpandAll() {
        var items = makeTranscript()
        var selection = LiveScrollbackSelection()
        selection.focus(itemCount: items.count)

        // Nothing is open, so the first press opens the foldable blocks.
        let opened = selection.apply(.toggleExpandAll, items: &items)
        #expect(opened.notice == "Expanded every block.")
        guard case .tool(let tool) = items[2] else {
            Issue.record("expected a tool card")
            return
        }
        #expect(tool.isExpanded)

        let closed = selection.apply(.toggleExpandAll, items: &items)
        #expect(closed.notice == "Collapsed every block.")
        guard case .tool(let reclosed) = items[2] else {
            Issue.record("expected a tool card")
            return
        }
        #expect(reclosed.isExpanded == false)

        // User and assistant messages are not foldable and must be untouched.
        guard case .message(let user) = items[0] else {
            Issue.record("expected a message")
            return
        }
        #expect(user.isCollapsed == false)
    }

    @Test("Ctrl+E expands every thinking block and collapses them again")
    func expandAllThinking() {
        var items = makeTranscript()
        var selection = LiveScrollbackSelection()
        selection.focus(itemCount: items.count)

        _ = selection.apply(.expandAllThinking, items: &items)
        guard case .message(let opened) = items[1] else {
            Issue.record("expected a message")
            return
        }
        #expect(opened.isCollapsed == false)

        _ = selection.apply(.expandAllThinking, items: &items)
        guard case .message(let reclosed) = items[1] else {
            Issue.record("expected a message")
            return
        }
        #expect(reclosed.isCollapsed)
    }

    @Test("r strips the rendering and restores exactly what it stripped")
    func toggleRawRoundTrips() {
        let styled = [PagerStyledLine(text: "rendered")]
        var items: [PagerConversationItem] = [
            .message(PagerMessage(role: .assistant, text: "# heading", styledLines: styled))
        ]
        var selection = LiveScrollbackSelection()
        selection.focus(itemCount: items.count)

        let stripped = selection.apply(.toggleRaw, items: &items)
        #expect(stripped.notice == "Raw.")
        guard case .message(let raw) = items[0] else {
            Issue.record("expected a message")
            return
        }
        #expect(raw.styledLines.isEmpty)
        #expect(raw.text == "# heading", "the source is never touched")

        let rendered = selection.apply(.toggleRaw, items: &items)
        #expect(rendered.notice == "Rendered.")
        guard case .message(let restored) = items[0] else {
            Issue.record("expected a message")
            return
        }
        #expect(restored.styledLines == styled)
    }

    @Test("y copies the block body and Y copies the command or path")
    func copyContentAndMetadata() {
        var items = makeTranscript()
        var selection = LiveScrollbackSelection()
        selection.focus(itemCount: items.count)
        _ = selection.apply(.selectFirst, items: &items)
        _ = selection.apply(.selectNext, items: &items)
        _ = selection.apply(.selectNext, items: &items)

        let body = selection.apply(.copyBlockContent, items: &items)
        #expect(body.clipboard == "contents")
        let command = selection.apply(.copyBlockMetadata, items: &items)
        #expect(command.clipboard == "README.md")

        // A message has a body but no command or path.
        _ = selection.apply(.selectLast, items: &items)
        let meta = selection.apply(.copyBlockMetadata, items: &items)
        #expect(meta.clipboard == nil)
        #expect(meta.notice?.contains("no command or path") == true)
    }

    @Test("o surfaces a link in the selected block and says so when there is none")
    func openLink() {
        var items = makeTranscript()
        var selection = LiveScrollbackSelection()
        selection.focus(itemCount: items.count)

        let found = selection.apply(.openNextLink, items: &items)
        #expect(found.url == "https://example.com/docs")

        _ = selection.apply(.selectFirst, items: &items)
        let missing = selection.apply(.openNextLink, items: &items)
        #expect(missing.url == nil)
        #expect(missing.notice == "No links in that block.")
    }

    @Test("link extraction trims trailing punctuation")
    func linkExtraction() {
        let item = PagerConversationItem.message(PagerMessage(
            role: .assistant,
            text: "See (https://example.com/a), then https://example.com/b."
        ))
        #expect(LiveScrollbackSelection.links(in: item) == [
            "https://example.com/a",
            "https://example.com/b",
        ])
    }

    @Test("find matches case-insensitively and reports the first block")
    func findFirstMatch() {
        let items = makeTranscript()
        #expect(LiveScrollbackSelection.firstMatch(for: "SECOND", in: items) == 4)
        #expect(LiveScrollbackSelection.firstMatch(for: "nothing here", in: items) == nil)
        #expect(LiveScrollbackSelection.firstMatch(for: "", in: items) == nil)
    }

    @Test("the cursor stays inside the transcript as it grows and shrinks")
    func clampKeepsCursorValid() {
        var selection = LiveScrollbackSelection()
        selection.focus(itemCount: 6)
        #expect(selection.index == 5)

        selection.clamp(itemCount: 3)
        #expect(selection.index == 2)

        selection.clamp(itemCount: 0)
        #expect(selection.index == 0)
    }

    @Test("an empty transcript answers every command without moving")
    func emptyTranscriptIsSafe() {
        var items: [PagerConversationItem] = []
        var selection = LiveScrollbackSelection()
        selection.focus(itemCount: 0)
        let outcome = selection.apply(.selectNext, items: &items)
        #expect(outcome.notice == nil)
        #expect(outcome.revealsSelection == false)
    }

    @Test("copy destinations resolve against the session directory")
    func resolveDestination() {
        let absolute = LivePagerClipboard.resolve("/tmp/out.md", relativeTo: "/work")
        #expect(absolute.path == "/tmp/out.md")

        let relative = LivePagerClipboard.resolve("notes/out.md", relativeTo: "/work")
        #expect(relative.path == "/work/notes/out.md")
    }

    @Test("the context report shows measured tokens, not an estimate")
    func contextReportUsesRealUsage() {
        let usage = ContextUsage(
            modelID: "grok-4-5",
            usedTokens: 48_000,
            contextWindow: 256_000,
            triggerTokenLimit: 184_320,
            targetTokenLimit: 128_000,
            budgetSource: "model",
            compactionCount: 1,
            strategy: .local,
            compactionsRemaining: nil
        )
        let text = LivePagerContextReport.lines(usage: usage, itemCount: 12)
            .map(\.text)
            .joined(separator: "\n")

        #expect(text.contains("grok-4-5"))
        // Thousands separators: a bare 256000 is hard to compare at a glance.
        #expect(text.contains("48,000 of 256,000 tokens (18%)"))
        #expect(text.contains("184,320 tokens (model)"))
        // Singular for one compaction, not "1 times".
        #expect(text.contains("Compacted so far   1 time"))
        // No row for a limit the catalog does not publish.
        #expect(text.contains("Compactions left") == false)
    }

    @Test("the context gauge fills in proportion and never overflows")
    func contextGaugeIsProportional() {
        func gauge(used: UInt64, window: UInt64) -> String {
            LivePagerContextReport.lines(
                usage: ContextUsage(
                    modelID: "m",
                    usedTokens: used,
                    contextWindow: window,
                    triggerTokenLimit: window,
                    targetTokenLimit: window,
                    budgetSource: "default",
                    compactionCount: 0,
                    strategy: .local,
                    compactionsRemaining: nil
                ),
                itemCount: 0
            ).map(\.text).first { $0.contains("[") } ?? ""
        }

        #expect(gauge(used: 0, window: 100).contains("█") == false)
        #expect(gauge(used: 100, window: 100).contains("·") == false)
        // Over-budget clamps rather than drawing past the bracket.
        let over = gauge(used: 500, window: 100)
        #expect(over.contains("·") == false)
        #expect(over.filter { $0 == "█" }.count == 40)
        // A zero window is a divide-by-zero waiting to happen.
        #expect(gauge(used: 10, window: 0).isEmpty)
    }

    @Test("clipboard writes go out as an OSC 52 sequence")
    func clipboardUsesOsc52() throws {
        var written = Data()
        try LivePagerClipboard.copy("hello", to: { written.append($0) }, environment: [:])
        let text = String(decoding: written, as: UTF8.self)
        #expect(text.contains("52;"))
        // "hello" base64-encoded.
        #expect(text.contains("aGVsbG8="))
    }
}
