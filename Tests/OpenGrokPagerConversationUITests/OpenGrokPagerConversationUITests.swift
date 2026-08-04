import Testing
@testable import OpenGrokPagerConversationUI

struct PagerConversationRowTests {
    @Test("conversation rows produce stable styled descriptions")
    func rendersMixedContent() {
        let row = PagerConversationRow(
            id: "turn-1",
            role: .assistant,
            kind: .message,
            title: "Grok",
            content: [
                .text("hello\nworld"),
                .citation(label: "source", target: "https://example.test"),
                .diff(summary: "Updated file", additions: 2, deletions: 1)
            ],
            status: .streaming
        )
        let description = row.renderDescription()
        #expect(description.isVisible)
        #expect(description.isFoldable)
        #expect(description.showsActivityIndicator)
        #expect(description.lines.map(\.plainText) == [
            "Grok", "hello", "world", "↗ source — https://example.test", "Updated file (+2/-1)"
        ])
    }

    @Test("transport rows remain in replay state but are not rendered")
    func hidesTransportRows() {
        let row = PagerConversationRow(
            id: "raw-1", role: .tool, kind: .tool,
            content: [.text("raw transport payload")], visibility: .hiddenTransport
        )
        let description = row.renderDescription()
        #expect(!description.isVisible)
        #expect(description.lines.isEmpty)
        #expect(description.accessibilityLabel.isEmpty)
    }
}

struct PagerConversationTranscriptTests {
    @Test("upsert preserves order and follow-tail selection")
    func upsertsRows() {
        var transcript = PagerConversationTranscriptViewModel()
        transcript.upsert(PagerConversationRow(id: "user", role: .user, kind: .message, title: "You"))
        transcript.upsert(PagerConversationRow(id: "assistant", role: .assistant, kind: .message, title: "Grok"))
        transcript.upsert(PagerConversationRow(id: "assistant", role: .assistant, kind: .message, title: "Grok", status: .completed))
        #expect(transcript.rows.map(\.id) == ["user", "assistant"])
        #expect(transcript.selectedRowID == "assistant")
    }

    @Test("collapse and visibility are deterministic")
    func collapsesVisibleRow() {
        var transcript = PagerConversationTranscriptViewModel()
        transcript.upsert(PagerConversationRow(
            id: "tool", role: .tool, kind: .tool, content: [.text("output")]
        ))
        let collapsed = transcript.setCollapsed(true, rowID: "tool")
        #expect(collapsed)
        #expect(transcript.renderDescriptions()[0].lines.map(\.plainText) == ["Tool"])
        let missing = transcript.setCollapsed(true, rowID: "missing")
        #expect(!missing)
    }
}
