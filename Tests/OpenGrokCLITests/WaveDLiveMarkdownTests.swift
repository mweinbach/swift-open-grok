import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

@Suite("Wave D live markdown")
struct WaveDLiveMarkdownTests {
    @Test("reasoning streams markdown, finishes before assistant text, and records elapsed")
    func reasoningLifecycle() {
        var conversation = LivePagerConversationState(markdown: PagerMarkdownRenderer())
        conversation.startTurn(prompt: "explain")
        conversation.appendReasoning("**Plan**\n\n```swift\nlet value = 1\n```")

        guard case .message(let streamingReasoning) = conversation.items.last else {
            Issue.record("expected streaming reasoning")
            return
        }
        #expect(streamingReasoning.role == .reasoning)
        #expect(streamingReasoning.isStreaming)
        #expect(streamingReasoning.styledLines.contains { $0.background == .code })

        conversation.appendAssistant("Final answer")
        let messages = conversation.items.compactMap { item -> PagerMessage? in
            if case .message(let message) = item { return message }
            return nil
        }
        let reasoning = messages.first { $0.role == .reasoning }
        let assistant = messages.last { $0.role == .assistant }
        #expect(reasoning?.isStreaming == false)
        #expect(reasoning?.isCollapsed == true)
        #expect(reasoning?.duration != nil)
        #expect(assistant?.text == "Final answer")
        #expect(assistant?.isStreaming == true)
    }

    @Test("Ctrl+E expansion preference keeps the next completed thinking open")
    func stickyThinkingExpansion() {
        var conversation = LivePagerConversationState(markdown: PagerMarkdownRenderer())
        conversation.startTurn(prompt: "first")
        conversation.appendReasoning("first thought")
        conversation.appendAssistant("first answer")

        var selection = LiveScrollbackSelection()
        selection.focus(itemCount: conversation.items.count)
        let outcome = conversation.withItems { items in
            selection.apply(.expandAllThinking, items: &items)
        }
        #expect(outcome.completedReasoningExpanded == true)
        conversation.setCompletedReasoningExpanded(true)

        conversation.finishAssistant()
        conversation.startTurn(prompt: "second")
        conversation.appendReasoning("second thought")
        conversation.appendAssistant("second answer")

        let reasoning = conversation.items.compactMap { item -> PagerMessage? in
            if case .message(let message) = item, message.role == .reasoning { return message }
            return nil
        }
        #expect(reasoning.count == 2)
        #expect(reasoning.allSatisfy { !$0.isCollapsed })
    }

    @Test("live content width reflows a six-column table without clipping borders")
    func liveTableWidth() {
        let table = """
        | A | B | C | D | E | F |
        | --- | --- | --- | --- | --- | --- |
        | alpha | beta | gamma | delta | epsilon | zeta |
        """
        var conversation = LivePagerConversationState(markdown: PagerMarkdownRenderer())
        conversation.startTurn(prompt: "table")
        conversation.appendAssistant(table)
        let widthChanged = conversation.setMarkdownWidth(32)
        #expect(widthChanged)

        guard let assistant = conversation.items.compactMap({ item -> PagerMessage? in
            if case .message(let message) = item, message.role == .assistant { return message }
            return nil
        }).last else {
            Issue.record("expected assistant table")
            return
        }
        let tableLines = assistant.styledLines.filter {
            $0.text.first == "┌" || $0.text.first == "├" || $0.text.first == "└" || $0.text.first == "│"
        }
        #expect(!tableLines.isEmpty)
        #expect(tableLines.allSatisfy { UnicodeDisplayWidth.width(of: $0.text) <= 32 })
        #expect(tableLines.first?.text.first == "┌")
        #expect(tableLines.last?.text.first == "└")
    }
}
