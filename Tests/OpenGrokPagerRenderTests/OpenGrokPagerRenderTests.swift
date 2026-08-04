import Testing
@testable import OpenGrokPagerRender
import OpenGrokTerminalCore

@Suite("OpenGrokPagerRender")
struct OpenGrokPagerRenderTests {
    @Test("renders deterministic chrome and conversation snapshot")
    func goldenFrame() {
        let state = PagerRenderState(
            size: TerminalSize(width: 32, height: 9),
            header: PagerHeader(title: "Open Grok", subtitle: "chat", trailing: "grok-4"),
            conversation: [
                .message(PagerMessage(role: .user, text: "hello")),
                .message(PagerMessage(role: .assistant, text: "Hi there."))
            ],
            status: PagerStatusLine(text: "ready"),
            input: PagerInputState(text: "next"),
            footer: PagerFooter(leading: "Enter send", trailing: "Ctrl+C quit"),
            showScrollbar: false
        )

        let result = renderPagerFrame(state)

        let expectedRows = [
            "Open Grok · chat          grok-4",
            "You: hello",
            "Grok: Hi there.",
            "",
            "",
            "",
            "ready",
            "› next▌",
            "Enter send           Ctrl+C quit"
        ]
        #expect(result.snapshot() == expectedRows.joined(separator: "\n"))
        #expect(result.layout.header == TerminalRect(x: 0, y: 0, width: 32, height: 1))
        #expect(result.layout.conversation.height == 5)
        #expect(result.cursorPosition == TerminalPoint(x: 6, y: 7))
    }

    @Test("streams assistant content and renders expanded tool cards")
    func streamingAndToolCard() {
        let result = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 40, height: 10),
            conversation: [
                .message(PagerMessage(role: .assistant, text: "working", isStreaming: true)),
                .tool(PagerToolCard(
                    name: "read_file",
                    input: "/tmp/example.txt",
                    output: "line one\nline two",
                    state: .succeeded
                ))
            ],
            input: PagerInputState(text: "", isFocused: false),
            showScrollbar: false
        ))

        let snapshot = result.snapshot()
        #expect(snapshot.contains("Grok: working▌"))
        #expect(snapshot.contains("┌─ Tool: read_file [done]"))
        #expect(snapshot.contains("│ input: /tmp/example.txt"))
        #expect(snapshot.contains("│ result: line two"))
        #expect(snapshot.contains("└─"))
    }

    @Test("follows the tail and exposes a scrollbar when content overflows")
    func viewportAndScrollbar() {
        let items = (0..<12).map {
            PagerConversationItem.message(PagerMessage(role: .assistant, text: "line \($0)"))
        }
        let result = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 18, height: 6),
            conversation: items,
            input: PagerInputState(isFocused: false),
            scrollPosition: .followTail
        ))

        #expect(result.layout.hasScrollbar)
        #expect(result.layout.totalContentLines == 12)
        #expect(result.layout.scrollOffset == 7)
        #expect(result.snapshot().contains("Grok: line 11"))
        #expect(result.snapshot().contains("█"))
    }

    @Test("clips narrow and short terminals without invalid geometry")
    func narrowAndShort() {
        let result = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 8, height: 2),
            header: PagerHeader(title: "Long header", trailing: "right"),
            conversation: [.message(PagerMessage(role: .user, text: "你好世界"))],
            status: PagerStatusLine(text: "status"),
            input: PagerInputState(text: "input"),
            footer: PagerFooter(leading: "footer")
        ))

        #expect(result.buffer.width == 8)
        #expect(result.buffer.height == 2)
        #expect(result.layout.header.height == 1)
        #expect(result.layout.footer.height == 1)
        #expect(result.layout.input.height == 0)
        #expect(result.snapshot().split(separator: "\n", omittingEmptySubsequences: false).count == 2)
    }

    @Test("unicode wrapping and explicit scroll offsets are deterministic")
    func unicodeAndOffset() {
        let state = PagerRenderState(
            size: TerminalSize(width: 14, height: 4),
            conversation: [
                .message(PagerMessage(role: .user, text: "你 好 😊 123456789")),
                .separator(""),
                .message(PagerMessage(role: .assistant, text: "tail"))
            ],
            input: PagerInputState(isFocused: false),
            scrollPosition: .offset(1),
            showScrollbar: false
        )
        let first = renderPagerFrame(state)
        let second = renderPagerFrame(state)

        #expect(first == second)
        #expect(first.layout.scrollOffset == 1)
        #expect(first.snapshot().contains("Grok: tail"))
        #expect(first.snapshot().contains("123456789"))
    }
}
