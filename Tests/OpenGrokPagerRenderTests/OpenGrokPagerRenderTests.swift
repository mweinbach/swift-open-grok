import Testing
@testable import OpenGrokPagerRender
import OpenGrokTerminalCore

@Suite("OpenGrokPagerRender")
struct OpenGrokPagerRenderTests {
    @Test("renders the reference chrome: status bar, transcript, composer box, shortcuts bar")
    func goldenFrame() {
        let state = PagerRenderState(
            size: TerminalSize(width: 40, height: 12),
            statusBar: PagerStatusBar(
                gitBranch: "main",
                workingDirectory: "~/work",
                contextUsedTokens: 8500,
                contextTotalTokens: 1_000_000
            ),
            conversation: [
                .message(PagerMessage(role: .user, text: "hello")),
                .message(PagerMessage(role: .assistant, text: "Hi there."))
            ],
            input: PagerComposerState(text: "next", modelName: "grok-4"),
            shortcuts: PagerShortcutsBar(hints: [
                PagerShortcutHint(key: "Enter", label: "send"),
                PagerShortcutHint(key: "Ctrl+c", label: "quit")
            ]),
            showScrollbar: false
        )

        let result = renderPagerFrame(state)
        let rows = result.snapshot().split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)

        // The status bar carries git and cwd on the left, the context
        // indicator right-aligned. There is no "Open Grok" banner.
        #expect(rows[0].hasPrefix("\u{2387} main ~/work"))
        #expect(rows[0].hasSuffix("8.5K / 1.0M"))

        // A user prompt is `❯ `-prefixed with a padded blank row on each side;
        // the assistant reply has no prefix at all.
        #expect(rows.contains { $0 == "   \u{276F} hello" })
        #expect(rows.contains { $0 == "   Hi there." })
        #expect(!rows.contains { $0.contains("You:") || $0.contains("Grok:") })

        // Composer: rounded borders, `❯ ` prompt, model name on the bottom
        // border.
        let composerTop = rows[result.layout.input.y]
        #expect(composerTop.hasPrefix("\u{256D}"))
        #expect(composerTop.hasSuffix("\u{256E}"))
        let composerText = rows[result.layout.input.y + 1]
        #expect(composerText.hasPrefix("\u{2502} \u{276F} next"))
        #expect(composerText.hasSuffix("\u{2502}"))
        let composerBottom = rows[result.layout.input.bottom - 1]
        #expect(composerBottom.hasPrefix("\u{2570}"))
        #expect(composerBottom.contains("grok-4"))
        #expect(composerBottom.hasSuffix("\u{256F}"))

        // Shortcuts bar: `key:label` joined by a padded pipe.
        #expect(rows[result.layout.shortcuts.y] == "Enter:send  \u{2502}  Ctrl+c:quit")
        #expect(result.cursorPosition == TerminalPoint(x: 8, y: result.layout.input.y + 1))
    }

    @Test("tool cards use an accent rail and diamond bullet, never a box")
    func toolCardPresentation() {
        let result = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 44, height: 16),
            conversation: [
                .message(PagerMessage(role: .assistant, text: "working", isStreaming: true)),
                .tool(PagerToolCard(
                    name: "read_file",
                    input: "/tmp/example.txt",
                    output: "line one\nline two",
                    detail: "(2 lines)",
                    state: .succeeded,
                    isExpanded: true
                ))
            ],
            input: PagerComposerState(isFocused: false),
            showScrollbar: false
        ))

        let snapshot = result.snapshot()
        #expect(snapshot.contains("working\u{258C}"))
        #expect(snapshot.contains("\u{25C6} Read /tmp/example.txt (2 lines)"))
        #expect(snapshot.contains("\u{2503}"))
        #expect(snapshot.contains("line two"))
        // The reference draws no rectangle around a tool call.
        #expect(!snapshot.contains("\u{250C}\u{2500}"))
        #expect(!snapshot.contains("\u{2514}\u{2500}"))
    }

    @Test("long tool output collapses to head, marker, and tail")
    func toolOutputTruncation() {
        let output = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let result = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 40, height: 20),
            conversation: [
                .tool(PagerToolCard(
                    name: "bash",
                    input: "ls -la",
                    output: output,
                    state: .succeeded,
                    isExpanded: true
                ))
            ],
            input: PagerComposerState(isFocused: false),
            showScrollbar: false
        ))

        let snapshot = result.snapshot()
        #expect(snapshot.contains("\u{25C6} Run ls -la"))
        #expect(snapshot.contains("line 1"))
        #expect(snapshot.contains("\u{2026} +15 lines"))
        #expect(snapshot.contains("line 20"))
        #expect(!snapshot.contains("line 10"))
    }

    @Test("thinking blocks stream a truncated tail and collapse to a timed header")
    func thinkingPresentation() {
        let streaming = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 40, height: 14),
            conversation: [
                .message(PagerMessage(
                    role: .reasoning,
                    text: "a\nb\nc\nd\ne",
                    isStreaming: true
                ))
            ],
            input: PagerComposerState(isFocused: false),
            showScrollbar: false
        )).snapshot()
        #expect(streaming.contains("\u{25C6} Thinking\u{2026}"))
        #expect(streaming.contains("\u{2026}"))
        #expect(streaming.contains("e"))

        let collapsed = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 40, height: 14),
            conversation: [
                .message(PagerMessage(
                    role: .reasoning,
                    text: "a\nb\nc",
                    duration: 1.44,
                    isCollapsed: true
                ))
            ],
            input: PagerComposerState(isFocused: false),
            showScrollbar: false
        )).snapshot()
        #expect(collapsed.contains("\u{25C6} Thought for 1.4s"))
        #expect(!collapsed.contains("\n   a"))
    }

    @Test("consecutive collapsed tool rows pack with no blank row between them")
    func collapsedToolsPackTight() {
        let lines = makeConversationLines(
            [
                .tool(PagerToolCard(name: "read", input: "a.txt", state: .succeeded)),
                .tool(PagerToolCard(name: "read", input: "b.txt", state: .succeeded)),
                .message(PagerMessage(role: .assistant, text: "done"))
            ],
            width: 40,
            theme: .grokNight
        )

        let texts = lines.map(\.text)
        #expect(texts[0].contains("a.txt"))
        #expect(texts[1].contains("b.txt"))
        // Blank row only before the non-groupable assistant message.
        #expect(texts[2].isEmpty)
        #expect(texts[3] == "done")
    }

    @Test("an armed confirmation replaces the whole shortcuts bar")
    func pendingConfirmationBar() {
        let result = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 40, height: 10),
            input: PagerComposerState(isFocused: false),
            shortcuts: PagerShortcutsBar(
                hints: [PagerShortcutHint(key: "Enter", label: "send")],
                pendingKey: "Ctrl+c",
                pendingLabel: "quit"
            ),
            showScrollbar: false
        ))

        let rows = result.snapshot().split(separator: "\n", omittingEmptySubsequences: false)
        #expect(rows[result.layout.shortcuts.y] == "Ctrl+c:press again to quit")
    }

    @Test("the turn status row shows a braille spinner, label, timer, and stop button")
    func turnStatusRow() {
        let result = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 60, height: 12),
            turnStatus: PagerTurnStatus(
                label: "Thinking\u{2026}",
                tick: 0,
                elapsed: 80,
                tokenCount: 12_000,
                queuedPromptCount: 1,
                queueIsSendable: true
            ),
            input: PagerComposerState(isFocused: false),
            showScrollbar: false
        ))

        let row = result.snapshot().split(separator: "\n", omittingEmptySubsequences: false)[
            result.layout.turnStatus.y
        ]
        #expect(row.hasPrefix("\u{280B} Thinking\u{2026}"))
        #expect(row.contains("1 queued — Enter to send now"))
        #expect(row.contains("1m20s"))
        #expect(row.contains("\u{21E3}12K"))
        #expect(row.hasSuffix("[stop]"))
    }

    @Test("the completion menu marks the selected row with the prompt arrow")
    func completionMenu() {
        let result = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 40, height: 14),
            completions: PagerCompletionMenu(
                rows: [
                    PagerCompletionRow(label: "/help", summary: "Browse commands"),
                    PagerCompletionRow(label: "/quit", summary: "Quit the application")
                ],
                selectedIndex: 1
            ),
            input: PagerComposerState(text: "/", isFocused: false),
            showScrollbar: false
        ))

        let rows = result.snapshot().split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        #expect(rows[result.layout.completions.y] == "  /help  Browse commands")
        #expect(rows[result.layout.completions.y + 1] == "\u{276F} /quit  Quit the application")
    }

    @Test("follows the tail and exposes a scrollbar when content overflows")
    func viewportAndScrollbar() {
        let items = (0..<40).map {
            PagerConversationItem.message(PagerMessage(role: .assistant, text: "line \($0)"))
        }
        let result = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 24, height: 12),
            conversation: items,
            input: PagerComposerState(isFocused: false),
            scrollPosition: .followTail
        ))

        #expect(result.layout.hasScrollbar)
        #expect(result.layout.scrollOffset == result.layout.totalContentLines
            - result.layout.conversation.height)
        #expect(result.snapshot().contains("line 39"))
        #expect(result.snapshot().contains("█"))
    }

    @Test("clips narrow and short terminals without invalid geometry")
    func narrowAndShort() {
        let result = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 8, height: 2),
            statusBar: PagerStatusBar(workingDirectory: "/very/long/path"),
            conversation: [.message(PagerMessage(role: .user, text: "你好世界"))],
            input: PagerComposerState(text: "input"),
            shortcuts: PagerShortcutsBar(hints: [PagerShortcutHint(key: "Enter", label: "send")])
        ))

        #expect(result.buffer.width == 8)
        #expect(result.buffer.height == 2)
        #expect(result.layout.statusBar.height == 1)
        #expect(result.layout.bounds.height == 2)
        #expect(result.snapshot().split(separator: "\n", omittingEmptySubsequences: false).count == 2)
    }

    @Test("unicode wrapping and explicit scroll offsets are deterministic")
    func unicodeAndOffset() {
        let state = PagerRenderState(
            size: TerminalSize(width: 24, height: 9),
            conversation: [
                .message(PagerMessage(role: .user, text: "你 好 😊 123456789")),
                .separator(""),
                .message(PagerMessage(role: .assistant, text: "tail"))
            ],
            input: PagerComposerState(isFocused: false),
            scrollPosition: .offset(1),
            showScrollbar: false
        )
        let first = renderPagerFrame(state)
        let second = renderPagerFrame(state)

        #expect(first == second)
        #expect(first.layout.scrollOffset == 1)
        // Wide graphemes wrap without splitting a cell.
        #expect(first.snapshot().contains("\u{4F60} \u{597D}"))
    }

    @Test("the composer floors at three rows and never exceeds its maximum")
    func composerHeight() {
        let short = PagerComposerState(text: "", maximumHeight: 8)
        #expect(pagerComposerHeight(short, width: 40) == 3)

        let tall = PagerComposerState(
            text: (0..<20).map { "line \($0)" }.joined(separator: "\n"),
            maximumHeight: 6
        )
        #expect(pagerComposerHeight(tall, width: 40) == 6)
    }

    @Test("token and duration formatting match the reference")
    func formatting() {
        #expect(pagerFormatTokens(999) == "999")
        #expect(pagerFormatTokens(8500) == "8.5K")
        #expect(pagerFormatTokens(120_000) == "120K")
        #expect(pagerFormatTokens(1_000_000) == "1.0M")
        #expect(pagerFormatTokens(12_000_000) == "12M")
        #expect(pagerFormatDuration(1.44) == "1.4s")
        #expect(pagerFormatDuration(80) == "1m20s")
    }
}
