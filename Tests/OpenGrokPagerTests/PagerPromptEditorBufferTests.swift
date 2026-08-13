// PagerPromptEditorBufferTests.swift
//
// Stage 1 composer migration: PromptEditor's sole store is a TextArea, but
// the live seam still publishes Character cursorOffset. These tests drive the
// real controller (AGENTS.md §3) — no TextArea handles leave the actor.

import Foundation
import OpenGrokPager
import OpenGrokTerminalCore
import Testing

@Suite("PromptEditor TextArea store (Stage 1)")
struct PagerPromptEditorBufferTests {
    @Test("promptState cursorOffset is Character count, not UTF-8, after an emoji paste")
    func emojiPastePublishesCharacterCursor() async throws {
        let zwj = "👩🏽\u{200D}💻"
        let harness = try await BufferHarness.run([.paste(zwj)])

        let last = await harness.lastPrompt
        #expect(last?.text == zwj)
        #expect(last?.cursorOffset == 1)
        #expect(zwj.utf8.count > 1)
        #expect(last?.cursorOffset == last?.text.count)
    }

    @Test("left then type inserts at a grapheme boundary, not mid-cluster")
    func leftThenTypeStaysOnGraphemeBoundary() async throws {
        let zwj = "👩🏽\u{200D}💻"
        let harness = try await BufferHarness.run([
            .paste("a" + zwj + "b"),
            .key(KeyEvent(key: .left)),
            .key(KeyEvent(key: .char("X"), character: "X")),
        ])

        let last = await harness.lastPrompt
        #expect(last?.text == "a" + zwj + "X" + "b")
        #expect(last?.cursorOffset == 3)
        #expect(last?.text.count == 4)
    }

    @Test("backspace deletes a whole emoji cluster")
    func backspaceDeletesWholeCluster() async throws {
        let flag = "🇺🇸"
        let harness = try await BufferHarness.run([
            .paste("a" + flag),
            .key(KeyEvent(key: .backspace)),
        ])

        let last = await harness.lastPrompt
        #expect(last?.text == "a")
        #expect(last?.cursorOffset == 1)
    }

    @Test("CRLF is one Character for cursor motion")
    func crlfIsOneCharacter() async throws {
        let harness = try await BufferHarness.run([
            .paste("ab\r\ncd"),
            .key(KeyEvent(key: .left)),
            .key(KeyEvent(key: .left)),
            .key(KeyEvent(key: .left)),
            .key(KeyEvent(key: .char("X"), character: "X")),
        ])

        let last = await harness.lastPrompt
        // Characters: a b \r\n c d. Three lefts land before CRLF.
        #expect(last?.text == "abX\r\ncd")
        #expect(last?.cursorOffset == 3)
        #expect(last?.text.count == 6)
        #expect(last?.text.utf8.count == 7)
    }

    @Test("Home and End move by Character ends of a unicode draft")
    func homeEndWithUnicode() async throws {
        let flag = "🇺🇸"
        let home = try await BufferHarness.run([
            .paste("a" + flag + "b"),
            .key(KeyEvent(key: .home)),
            .key(KeyEvent(key: .char("X"), character: "X")),
        ])
        #expect(await home.lastPrompt?.text == "Xa" + flag + "b")
        #expect(await home.lastPrompt?.cursorOffset == 1)

        let end = try await BufferHarness.run([
            .paste("a" + flag + "b"),
            .key(KeyEvent(key: .home)),
            .key(KeyEvent(key: .end)),
            .key(KeyEvent(key: .char("Y"), character: "Y")),
        ])
        #expect(await end.lastPrompt?.text == "a" + flag + "bY")
        #expect(await end.lastPrompt?.cursorOffset == 4)
    }

    @Test("paste in the middle of a draft uses the same buffer")
    func pasteInMiddle() async throws {
        let harness = try await BufferHarness.run([
            .paste("helo"),
            .key(KeyEvent(key: .left)),
            .paste("l"),
        ])

        let last = await harness.lastPrompt
        #expect(last?.text == "hello")
        #expect(last?.cursorOffset == 4)
    }

    @Test("Tab on /hel replaces the draft with the completion insert text")
    func slashCompletionReplacesDraft() async throws {
        let harness = try await BufferHarness.run([
            .paste("/hel"),
            .key(KeyEvent(key: .tab)),
        ])

        let last = await harness.lastPrompt
        #expect(last?.text == "/help")
        #expect(last?.cursorOffset == 5)
        #expect(last?.completions.isEmpty == true)
    }

    @Test("history replace loads the recalled prompt at the end, then typing appends")
    func historyReplaceThenTypeUsesSameBuffer() async throws {
        let first = BufferSession(sessionID: "s1")
        await first.emit(.completed(.init(sessionID: "s1")))
        let harness = try await BufferHarness.run(
            [
                .paste("alpha"),
                .key(KeyEvent(key: .enter)),
                .key(KeyEvent(key: .up)),
                .key(KeyEvent(key: .char("X"), character: "X")),
            ],
            sessions: [first]
        )

        let last = await harness.lastPrompt
        #expect(last?.text == "alphaX")
        #expect(last?.cursorOffset == 6)
    }

    @Test("Enter still sends; Ctrl+U kills to line start then yank restores (readline, not viewport)")
    func enterSendsAndCtrlUKillsLine() async throws {
        // Pin 650c1db7: Ctrl-U is `When::ScrollbackFocused` half-page-up only.
        // Prompt-focused it is `DeleteToLineStart` via TextArea.input
        // (`editor_keys.rs` Ctrl-U, `prompt.rs` AgentScreen skip for text keys).
        let session = BufferSession(sessionID: "s1")
        await session.emit(.completed(.init(sessionID: "s1")))
        let harness = try await BufferHarness.run(
            [
                .paste("keep me"),
                .key(KeyEvent(key: .char("u"), modifiers: [.control], character: "u")),
                .key(KeyEvent(key: .char("y"), modifiers: [.control], character: "y")),
                .key(KeyEvent(key: .enter)),
            ],
            sessions: [session]
        )

        #expect(await harness.viewportCommands.isEmpty)
        #expect(harness.submittedPrompts == ["keep me"])
        #expect(await harness.lastPrompt?.text == "")
    }

    @Test("Tab with a closed dropdown still hands focus to the scrollback")
    func tabWithoutDropdownFocusesScrollback() async throws {
        let harness = try await BufferHarness.run([
            .key(KeyEvent(key: .tab)),
        ])
        #expect(await harness.focusChanges == [.scrollback])
        #expect(await harness.lastPrompt?.text == "")
    }
}

private struct BufferHarness {
    private let renderer: BufferRecordingRenderer
    let submittedPrompts: [String]

    var lastPrompt: OpenGrokPagerInteractivePromptState? {
        get async { await renderer.promptStates.last }
    }

    var viewportCommands: [OpenGrokPagerViewportCommand] {
        get async { await renderer.viewportCommands }
    }

    var focusChanges: [OpenGrokPagerFocusRegion] {
        get async { await renderer.focusChanges }
    }

    static func run(
        _ events: [InputEvent],
        sessions: [BufferSession] = []
    ) async throws -> BufferHarness {
        let renderer = BufferRecordingRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: closedBufferStream(events),
            runtime: BufferRuntime(sessions: sessions),
            renderer: renderer,
            output: SilentBufferOutput()
        )
        let result = try await controller.run(.init(prompt: "", mode: .inline))
        return BufferHarness(renderer: renderer, submittedPrompts: result.submittedPrompts)
    }
}

private actor BufferRecordingRenderer: OpenGrokPagerInteractiveRenderAdapter {
    private(set) var events: [OpenGrokPagerInteractiveEvent] = []

    func begin() {}
    func restoreTerminal() {}
    func render(_ event: OpenGrokPagerInteractiveEvent) { events.append(event) }

    var promptStates: [OpenGrokPagerInteractivePromptState] {
        events.compactMap {
            if case .promptChanged(let state) = $0 { return state }
            return nil
        }
    }

    var viewportCommands: [OpenGrokPagerViewportCommand] {
        events.compactMap {
            if case .viewport(let command) = $0 { return command }
            return nil
        }
    }

    var focusChanges: [OpenGrokPagerFocusRegion] {
        events.compactMap {
            if case .focusChanged(let region) = $0 { return region }
            return nil
        }
    }
}

private struct SilentBufferOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}

private actor BufferRuntime: OpenGrokPagerRuntimeAdapter {
    private var sessions: [BufferSession]
    init(sessions: [BufferSession]) { self.sessions = sessions }

    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        _ = request
        guard !sessions.isEmpty else {
            throw OpenGrokPagerInteractiveError.sessionFailed("test runtime has no sessions")
        }
        return sessions.removeFirst()
    }
}

private actor BufferSession: OpenGrokPagerSessionAdapter {
    nonisolated let sessionID: String?
    nonisolated let events: AsyncThrowingStream<OpenGrokPagerEvent, Error>
    private let continuation: AsyncThrowingStream<OpenGrokPagerEvent, Error>.Continuation

    init(sessionID: String) {
        self.sessionID = sessionID
        var continuation: AsyncThrowingStream<OpenGrokPagerEvent, Error>.Continuation?
        self.events = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation!
    }

    func emit(_ event: OpenGrokPagerEvent) {
        continuation.yield(event)
    }

    func cancel() {
        continuation.yield(.cancelled)
        continuation.finish()
    }

    func close() {
        continuation.finish()
    }
}

private func closedBufferStream(_ events: [InputEvent]) -> AsyncStream<InputEvent> {
    AsyncStream { continuation in
        for event in events { continuation.yield(event) }
        continuation.finish()
    }
}
