import Testing
@testable import OpenGrokCLI
import OpenGrokPager
import OpenGrokPagerRender

@Suite("Live pager overlay text")
struct LivePagerOverlayTextTests {
    @Test("a multi-line prompt collapses to one row")
    func singleLineFlattens() {
        #expect(LivePagerOverlayText.singleLine("first\n\n  second  \nthird")
            == "first second third")
        #expect(LivePagerOverlayText.singleLine("  plain  ") == "plain")
    }

    @Test("command rows are parsed out of the controller's own help text")
    func commandRowsTrackHelp() {
        let rows = LivePagerOverlayText.commandRows()
        #expect(!rows.isEmpty)
        // Every row is a slash command, and the id is the bare command name so
        // it can be inserted into the composer.
        #expect(rows.allSatisfy { $0.label.hasPrefix("/") })
        #expect(rows.allSatisfy { $0.id.hasPrefix("/") && !$0.id.contains(" ") })
        #expect(rows.contains { $0.id == "/model" })
        #expect(rows.contains { $0.id == "/help" })

        // Aliases stay in the label; the summary is only the description.
        guard let model = rows.first(where: { $0.id == "/model" }) else {
            Issue.record("expected a /model row")
            return
        }
        #expect(model.label.contains("/m"))
        #expect(model.summary == "Switch the active model")
        #expect(rows.first { $0.id == "/help" }?.summary
            == "Browse commands and keyboard shortcuts")
    }

    @Test("copy counts assistant responses backwards from the end, 1-based")
    func assistantResponseCountsBackwards() {
        let items: [PagerConversationItem] = [
            .message(PagerMessage(role: .user, text: "q1")),
            .message(PagerMessage(role: .assistant, text: "a1")),
            .message(PagerMessage(role: .user, text: "q2")),
            .message(PagerMessage(role: .assistant, text: "a2"))
        ]
        #expect(LivePagerOverlayText.assistantResponse(fromLast: 1, in: items) == "a2")
        #expect(LivePagerOverlayText.assistantResponse(fromLast: 2, in: items) == "a1")
        #expect(LivePagerOverlayText.assistantResponse(fromLast: 3, in: items) == nil)
        #expect(LivePagerOverlayText.assistantResponse(fromLast: 0, in: items) == nil)
    }

    @Test("search matches case-insensitively and labels each hit with its role")
    func searchMatches() {
        let items: [PagerConversationItem] = [
            .message(PagerMessage(role: .user, text: "Find the Widget")),
            .message(PagerMessage(role: .assistant, text: "no match here\nwidget again")),
            .tool(PagerToolCard(name: "read", input: "widget.swift"))
        ]
        let rows = LivePagerOverlayText.search("widget", in: items)
        #expect(rows.count == 2)
        #expect(rows[0].label == "Find the Widget")
        #expect(rows[0].detail == "you")
        #expect(rows[1].label == "widget again")
        #expect(rows[1].detail == "grok")
        // Row ids are unique so the list overlay can key on them.
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(LivePagerOverlayText.search("absent", in: items).isEmpty)
    }

    @Test("session info reports the active modes, or 'default' when none are on")
    func sessionInfoModes() {
        let plain = LivePagerOverlayText.sessionInfoLines(
            workingDirectory: "~/work",
            modelName: "grok-4",
            itemCount: 1,
            queuedPromptCount: 0,
            modes: OpenGrokPagerInputModes()
        )
        #expect(plain.contains { $0.text.contains("default") })
        #expect(plain.contains { $0.text.contains("grok-4") })
        // Singular/plural on the block count.
        #expect(plain.contains { $0.text.contains("1 block") })

        let busy = LivePagerOverlayText.sessionInfoLines(
            workingDirectory: "~/work",
            modelName: "grok-4",
            itemCount: 2,
            queuedPromptCount: 3,
            modes: OpenGrokPagerInputModes(isMultiline: true, isVimMode: true)
        )
        #expect(busy.contains { $0.text.contains("multiline, vim") })
        #expect(busy.contains { $0.text.contains("2 blocks") })
    }

    @Test("context lines say plainly that token accounting is unavailable")
    func contextLinesAreHonest() {
        let lines = LivePagerOverlayText.contextLines(
            modelName: "grok-4",
            itemCount: 3,
            transcriptCharacters: 1234
        )
        #expect(lines.contains { $0.text.contains("1234 characters") })
        // No invented percentage — the renderer is not told the real usage.
        #expect(!lines.contains { $0.text.contains("%") })
        #expect(lines.contains { $0.text.contains("not reported") })
    }

    @Test("the shortcuts sheet covers the composer, transcript and overlay groups")
    func shortcutsSections() {
        let lines = LivePagerOverlayText.shortcutsLines()
        for section in ["Composer", "Transcript", "Overlays"] {
            #expect(lines.contains { $0.text == section })
        }
        #expect(lines.contains { $0.text.contains("Esc") })
    }
}
