// PagerComposerReadlineTests.swift
//
// Stage 3 composer readline: host-policy intercepts first, leftover keys
// route through the live controller into the sole TextArea.input API.
// Pin 650c1db7 `handle_prompt_key` / `xai-ratatui-textarea` TextArea::input.

import Foundation
import OpenGrokPager
import OpenGrokTerminalCore
import Testing

@Suite("PromptEditor Stage 3 readline (live controller)")
struct PagerComposerReadlineTests {
    @Test("Ctrl-A/E move to logical line ends, including Unicode")
    func ctrlAELogicalLine() async throws {
        let flag = "🇺🇸"
        let harness = try await ReadlineHarness.run([
            .paste("a" + flag + "b"),
            ctrl("a"),
            .key(KeyEvent(key: .char("X"), character: "X")),
            ctrl("e"),
            .key(KeyEvent(key: .char("Y"), character: "Y")),
        ])

        #expect(await harness.lastPrompt?.text == "Xa" + flag + "bY")
        #expect(await harness.lastPrompt?.cursorOffset == 5)
        #expect(await harness.viewportCommands.isEmpty)
    }

    @Test("Ctrl-W deletes a whitespace-delimited word")
    func ctrlWDeletesWord() async throws {
        let harness = try await ReadlineHarness.run([
            .paste("hello world"),
            ctrl("w"),
        ])

        #expect(await harness.lastPrompt?.text == "hello ")
        #expect(await harness.viewportCommands.isEmpty)
    }

    @Test("prompt-focused Ctrl-J inserts a newline (readline), not viewport line-down")
    func ctrlJInsertsNewline() async throws {
        let harness = try await ReadlineHarness.run([
            .paste("ab"),
            ctrl("j"),
            .paste("c"),
        ])
        #expect(await harness.lastPrompt?.text == "ab\nc")
        #expect(await harness.viewportCommands.isEmpty)
    }

    @Test("Ctrl-U/K/Y kill to line start/end and yank")
    func ctrlUKYKillYank() async throws {
        let flag = "🇺🇸"
        let killed = try await ReadlineHarness.run([
            .paste("keep " + flag),
            ctrl("u"),
        ])
        #expect(await killed.lastPrompt?.text == "")
        #expect(await killed.viewportCommands.isEmpty)

        let yanked = try await ReadlineHarness.run([
            .paste("keep " + flag),
            ctrl("u"),
            ctrl("y"),
        ])
        #expect(await yanked.lastPrompt?.text == "keep " + flag)

        let toEnd = try await ReadlineHarness.run([
            .paste("ab"),
            ctrl("a"),
            ctrl("k"),
        ])
        #expect(await toEnd.lastPrompt?.text == "")
        #expect(await toEnd.viewportCommands.isEmpty)
    }

    @Test("Ctrl-Z undoes and Ctrl-R redoes a kill")
    func undoRedoKill() async throws {
        let harness = try await ReadlineHarness.run([
            .paste("hello"),
            ctrl("w"),
            ctrl("z"),
            ctrl("r"),
        ])

        let texts = await harness.promptTexts
        #expect(texts.contains("hello"))
        #expect(await harness.lastPrompt?.text == "")
        #expect(texts.last(where: { $0 == "hello" }) != nil)
        #expect(await harness.viewportCommands.isEmpty)
    }

    @Test("Alt-B / Alt-Left move by word; Alt-D deletes forward")
    func altWordMotionAndDelete() async throws {
        let moved = try await ReadlineHarness.run([
            .paste("hello world"),
            .key(KeyEvent(key: .char("b"), modifiers: [.alt], character: "b")),
            .key(KeyEvent(key: .char("X"), character: "X")),
        ])
        #expect(await moved.lastPrompt?.text == "hello Xworld")

        let arrow = try await ReadlineHarness.run([
            .paste("hello world"),
            .key(KeyEvent(key: .left, modifiers: [.alt])),
            .key(KeyEvent(key: .char("Y"), character: "Y")),
        ])
        #expect(await arrow.lastPrompt?.text == "hello Yworld")

        let deleted = try await ReadlineHarness.run([
            .paste("hello world"),
            .key(KeyEvent(key: .left, modifiers: [.alt])),
            .key(KeyEvent(key: .char("d"), modifiers: [.alt], character: "d")),
        ])
        #expect(await deleted.lastPrompt?.text == "hello ")
        #expect(await deleted.viewportCommands.isEmpty)
    }

    @Test("multiline Up/Down move inside the textarea, not the viewport")
    func multilineUpDownMoveInTextarea() async throws {
        let harness = try await ReadlineHarness.run([
            .paste("first"),
            .key(KeyEvent(key: .enter, modifiers: [.shift])),
            .paste("second"),
            .key(KeyEvent(key: .up)),
            .key(KeyEvent(key: .char("X"), character: "X")),
            .key(KeyEvent(key: .down)),
            .key(KeyEvent(key: .char("Y"), character: "Y")),
        ])

        #expect(await harness.lastPrompt?.text == "firstX\nsecondY")
        #expect(await harness.viewportCommands.isEmpty)
    }

    @Test("empty Up recalls history; empty Down does not open it")
    func emptyUpRecallsHistory() async throws {
        let session = ReadlineSession(sessionID: "s1")
        await session.emit(.completed(.init(sessionID: "s1")))
        let harness = try await ReadlineHarness.run(
            [
                .paste("alpha"),
                .key(KeyEvent(key: .enter)),
                .key(KeyEvent(key: .down)),
                .key(KeyEvent(key: .up)),
            ],
            sessions: [session]
        )

        #expect(harness.submittedPrompts == ["alpha"])
        #expect(await harness.lastPrompt?.text == "alpha")
        #expect(await harness.viewportCommands.isEmpty)
    }

    @Test("slash dropdown Up/Down never reach TextArea.input")
    func slashDropdownInterceptsArrows() async throws {
        let harness = try await ReadlineHarness.run([
            .paste("/q"),
            .key(KeyEvent(key: .down)),
        ])

        let last = await harness.lastPrompt
        #expect(last?.text == "/q")
        #expect((last?.completions.count ?? 0) >= 2)
        #expect(last?.selectedCompletion == 1)
        #expect(await harness.viewportCommands.isEmpty)
        #expect(await harness.focusChanges.isEmpty)
    }

    @Test("app-global chords are not stolen by readline")
    func globalsNotStolen() async throws {
        let harness = try await ReadlineHarness.run([
            .paste("draft"),
            ctrl("g"),
            ctrl("\\"),
            ctrl(";"),
        ])

        #expect(await harness.lastPrompt?.text == "draft")
        #expect(await harness.globals == [.toggleTasks, .openDashboard])
        #expect(await harness.overlayRequests.contains { request in
            if case .promptQueue = request { return true }
            return false
        })
        #expect(await harness.viewportCommands.isEmpty)
    }

    @Test("Left at the start of a draft does not publish a redundant promptChanged")
    func noopMotionDoesNotPublish() async throws {
        let harness = try await ReadlineHarness.run([
            .paste("a"),
            .key(KeyEvent(key: .home)),
        ])
        let afterHome = await harness.promptChangedCount
        let again = try await ReadlineHarness.run([
            .paste("a"),
            .key(KeyEvent(key: .home)),
            .key(KeyEvent(key: .left)),
        ])
        #expect(await again.promptChangedCount == afterHome)
        #expect(await again.lastPrompt?.text == "a")
        #expect(await again.lastPrompt?.cursorOffset == 0)
    }

    @Test("typing replaces a mouse-selected range, including a Unicode cluster")
    func selectedRangeReplacementAndUnicode() async throws {
        let ascii = try await ReadlineHarness.run(
            [
                .paste("hello"),
                .mouse(MouseEvent(kind: .down, x: 0, y: 0, button: .left)),
                .mouse(MouseEvent(kind: .drag, x: 5, y: 0, button: .left)),
                .mouse(MouseEvent(kind: .up, x: 5, y: 0, button: .left)),
                .key(KeyEvent(key: .char("X"), character: "X")),
            ],
            routeMouse: true
        )
        #expect(await ascii.lastPrompt?.text == "X")
        #expect(await ascii.lastPrompt?.selectedText == nil)

        let flag = "🇺🇸"
        let unicode = try await ReadlineHarness.run(
            [
                .paste("a" + flag + "b"),
                .mouse(MouseEvent(kind: .down, x: 1, y: 0, button: .left)),
                .mouse(MouseEvent(kind: .drag, x: 3, y: 0, button: .left)),
                .mouse(MouseEvent(kind: .up, x: 3, y: 0, button: .left)),
                .key(KeyEvent(key: .char("X"), character: "X")),
            ],
            routeMouse: true
        )
        #expect(await unicode.lastPrompt?.text == "aXb")
        #expect(await unicode.lastPrompt?.cursorOffset == 2)
    }

    @Test("Ctrl+J replaces a mouse selection with a newline")
    func ctrlJReplacesSelection() async throws {
        let harness = try await ReadlineHarness.run(
            [
                .paste("hello"),
                .mouse(MouseEvent(kind: .down, x: 0, y: 0, button: .left)),
                .mouse(MouseEvent(kind: .drag, x: 5, y: 0, button: .left)),
                .mouse(MouseEvent(kind: .up, x: 5, y: 0, button: .left)),
                ctrl("j"),
            ],
            routeMouse: true
        )
        #expect(await harness.lastPrompt?.text == "\n")
        #expect(await harness.lastPrompt?.selectedText == nil)
        #expect(await harness.viewportCommands.isEmpty)
    }

    @Test("Ctrl+H deletes a mouse selection")
    func ctrlHDeletesSelection() async throws {
        let harness = try await ReadlineHarness.run(
            [
                .paste("hello"),
                .mouse(MouseEvent(kind: .down, x: 0, y: 0, button: .left)),
                .mouse(MouseEvent(kind: .drag, x: 5, y: 0, button: .left)),
                .mouse(MouseEvent(kind: .up, x: 5, y: 0, button: .left)),
                ctrl("h"),
            ],
            routeMouse: true
        )
        #expect(await harness.lastPrompt?.text == "")
        #expect(await harness.lastPrompt?.selectedText == nil)
    }

    @Test("host-owned Ctrl+M/D remain unchanged with a mouse selection")
    func hostOwnedChordsUnchangedWithSelection() async throws {
        let multiline = try await ReadlineHarness.run(
            [
                .paste("hello"),
                .mouse(MouseEvent(kind: .down, x: 0, y: 0, button: .left)),
                .mouse(MouseEvent(kind: .drag, x: 5, y: 0, button: .left)),
                .mouse(MouseEvent(kind: .up, x: 5, y: 0, button: .left)),
                ctrl("m"),
            ],
            routeMouse: true
        )
        #expect(await multiline.lastPrompt?.text == "hello")
        #expect(await multiline.lastPrompt?.selectedText == "hello")

        let eof = try await ReadlineHarness.run(
            [
                .paste("hello"),
                .mouse(MouseEvent(kind: .down, x: 0, y: 0, button: .left)),
                .mouse(MouseEvent(kind: .drag, x: 5, y: 0, button: .left)),
                .mouse(MouseEvent(kind: .up, x: 5, y: 0, button: .left)),
                ctrl("d"),
            ],
            routeMouse: true
        )
        #expect(await eof.lastPrompt?.text == "hello")
        #expect(eof.submittedPrompts.isEmpty)
    }

    @Test("prompt Shift arrows select Unicode graphemes and plain arrows collapse the range")
    func keyboardGraphemeSelectionAndCollapse() async throws {
        let flag = "🇺🇸"
        let events: [InputEvent] = [
            .paste("a" + flag + "b"),
            .key(KeyEvent(key: .home)),
            .key(KeyEvent(key: .right, modifiers: [.shift])),
            .key(KeyEvent(key: .right, modifiers: [.shift])),
        ]

        let selected = try await ReadlineHarness.run(events)
        let selectedPrompt = await selected.lastPrompt
        #expect(selectedPrompt?.selectedText == "a" + flag)
        #expect(selectedPrompt?.selectionUTF8 == 0..<(1 + flag.utf8.count))
        #expect(selectedPrompt?.cursorOffset == 2)
        #expect(await selected.scrollbackCommands.isEmpty)

        let collapsed = try await ReadlineHarness.run(
            events + [.key(KeyEvent(key: .left))]
        )
        let collapsedPrompt = await collapsed.lastPrompt
        #expect(collapsedPrompt?.text == "a" + flag + "b")
        #expect(collapsedPrompt?.selectionUTF8 == nil)
        #expect(collapsedPrompt?.cursorOffset == 0)
    }

    @Test("Alt and Control Shift arrows select words through the real composer")
    func keyboardWordSelection() async throws {
        for modifier: KeyModifiers in [.alt, .control] {
            let harness = try await ReadlineHarness.run([
                .paste("alpha beta"),
                .key(KeyEvent(key: .home)),
                .key(KeyEvent(key: .right, modifiers: [.shift, modifier])),
            ])

            let prompt = await harness.lastPrompt
            #expect(prompt?.selectedText == "alpha")
            #expect(prompt?.selectionUTF8 == 0..<5)
            #expect(await harness.viewportCommands.isEmpty)
        }
    }

    @Test("Command and Meta Shift arrows use the painted composer wrap width")
    func keyboardSelectionUsesLiveWrappedRowGeometry() async throws {
        for modifier: KeyModifiers in [.superKey, .meta] {
            let harness = try await ReadlineHarness.run(
                [
                    .paste("abcdefghijk"),
                    .key(KeyEvent(key: .home)),
                    .key(KeyEvent(key: .right, modifiers: [.shift, modifier])),
                ],
                contentWidth: 5
            )

            let prompt = await harness.lastPrompt
            #expect(prompt?.selectedText == "abcde")
            #expect(prompt?.cursorOffset == 5)
        }

        let logicalLine = try await ReadlineHarness.run(
            [
                .paste("abcdefghijk"),
                .key(KeyEvent(key: .home)),
                .key(KeyEvent(key: .end, modifiers: [.shift])),
            ],
            contentWidth: 5
        )
        #expect(await logicalLine.lastPrompt?.selectedText == "abcdefghijk")
    }

    @Test("Shift vertical selection does not open history or navigate slash completions")
    func shiftVerticalSelectionBypassesHistoryAndDropdown() async throws {
        let selected = try await ReadlineHarness.run([
            .paste("one\ntwo\nthree"),
            .key(KeyEvent(key: .up, modifiers: [.shift])),
        ])
        let selectedPrompt = await selected.lastPrompt
        #expect(selectedPrompt?.text == "one\ntwo\nthree")
        #expect(selectedPrompt?.selectedText == "\nthree")

        let dropdown = try await ReadlineHarness.run([
            .paste("/q"),
            .key(KeyEvent(key: .down, modifiers: [.shift])),
        ])
        let dropdownPrompt = await dropdown.lastPrompt
        #expect(dropdownPrompt?.text == "/q")
        #expect(dropdownPrompt?.selectedCompletion == 0)

        let session = ReadlineSession(sessionID: "selected-history")
        await session.emit(.completed(.init(sessionID: "selected-history")))
        let history = try await ReadlineHarness.run(
            [
                .paste("alpha"),
                .key(KeyEvent(key: .enter)),
                .key(KeyEvent(key: .up, modifiers: [.shift])),
            ],
            sessions: [session]
        )
        #expect(history.submittedPrompts == ["alpha"])
        #expect(await history.lastPrompt?.text == "")

        let reserved = try await ReadlineHarness.run([
            .paste("one\ntwo"),
            .key(KeyEvent(key: .up, modifiers: [.shift, .superKey])),
        ])
        #expect(await reserved.lastPrompt?.selectionUTF8 == nil)
    }

    @Test("scrollback-focused Shift arrows retain previous and next turn navigation")
    func shiftArrowsRetainScrollbackBindings() async throws {
        let harness = try await ReadlineHarness.run([
            .paste("draft"),
            .key(KeyEvent(key: .tab)),
            .key(KeyEvent(key: .left, modifiers: [.shift])),
            .key(KeyEvent(key: .right, modifiers: [.shift])),
        ])

        #expect(await harness.focusChanges == [.scrollback])
        #expect(await harness.scrollbackCommands == [.previousTurn, .nextTurn])
        #expect(await harness.lastPrompt?.text == "draft")
        #expect(await harness.lastPrompt?.selectionUTF8 == nil)
    }

    @Test("Command and Meta copy preserve selection and cut reaches the renderer clipboard")
    func keyboardClipboardCopyAndCutUseLiveRenderer() async throws {
        for modifier: KeyModifiers in [.superKey, .meta] {
            let selecting: [InputEvent] = [
                .paste("alpha beta"),
                .key(KeyEvent(key: .home)),
                .key(KeyEvent(key: .right, modifiers: [.shift, .alt])),
            ]
            let copied = try await ReadlineHarness.run(
                selecting + [
                    .key(KeyEvent(key: .char("c"), modifiers: modifier, character: "c")),
                ]
            )
            #expect(await copied.clipboard == ["alpha"])
            #expect(await copied.lastPrompt?.selectedText == "alpha")
            #expect(await copied.lastPrompt?.text == "alpha beta")

            let cut = try await ReadlineHarness.run(
                selecting + [
                    .key(KeyEvent(key: .char("c"), modifiers: modifier, character: "c")),
                    .key(KeyEvent(key: .char("x"), modifiers: modifier, character: "x")),
                ]
            )
            #expect(await cut.clipboard == ["alpha", "alpha"])
            #expect(await cut.lastPrompt?.text == " beta")
            #expect(await cut.lastPrompt?.selectionUTF8 == nil)
            #expect(await cut.overlayRequests.isEmpty)
        }
    }

    @Test("Ctrl+X cuts a selection but remains the shortcuts binding without one")
    func ctrlXRespectsComposerSelectionAndGlobalShortcut() async throws {
        let cut = try await ReadlineHarness.run([
            .paste("alpha beta"),
            .key(KeyEvent(key: .home)),
            .key(KeyEvent(key: .right, modifiers: [.shift, .alt])),
            ctrl("x"),
        ])
        #expect(await cut.lastPrompt?.text == " beta")
        #expect(await cut.clipboard == ["alpha"])
        #expect(!(await cut.overlayRequests).contains(.shortcutsHelp))

        let shortcuts = try await ReadlineHarness.run([
            .paste("alpha beta"),
            ctrl("x"),
        ])
        #expect(await shortcuts.lastPrompt?.text == "alpha beta")
        #expect(await shortcuts.overlayRequests.contains(.shortcutsHelp))
        #expect(await shortcuts.clipboard.isEmpty)
    }

    @Test("Ghostty-only Command+A selects the full Unicode prompt while Ctrl+A remains readline")
    func selectAllIsGatedToGhostty() async throws {
        let text = "a🇺🇸b"
        let commandA = InputEvent.key(
            KeyEvent(key: .char("a"), modifiers: [.superKey], character: "a")
        )
        let enabled = try await ReadlineHarness.run(
            [.paste(text), .key(KeyEvent(key: .home)), commandA],
            promptSelectAllEnabled: true
        )
        let enabledPrompt = await enabled.lastPrompt
        #expect(enabledPrompt?.text == text)
        #expect(enabledPrompt?.selectedText == text)
        #expect(enabledPrompt?.selectionUTF8 == 0..<text.utf8.count)
        #expect(enabledPrompt?.cursorOffset == text.count)

        let disabled = try await ReadlineHarness.run(
            [.paste(text), .key(KeyEvent(key: .home)), commandA],
            promptSelectAllEnabled: false
        )
        let disabledPrompt = await disabled.lastPrompt
        #expect(disabledPrompt?.text == text)
        #expect(disabledPrompt?.selectionUTF8 == nil)
        #expect(disabledPrompt?.cursorOffset == 0)

        let meta = try await ReadlineHarness.run(
            [
                .paste(text),
                .key(KeyEvent(key: .char("a"), modifiers: [.meta], character: "a")),
            ],
            promptSelectAllEnabled: true
        )
        #expect(await meta.lastPrompt?.selectionUTF8 == nil)

        let readline = try await ReadlineHarness.run(
            [.paste(text), ctrl("a")],
            promptSelectAllEnabled: true
        )
        #expect(await readline.lastPrompt?.cursorOffset == 0)
        #expect(await readline.lastPrompt?.selectionUTF8 == nil)
    }

    @Test("bracketed paste replaces keyboard selection in a single undo operation")
    func bracketedPasteReplacesSelectionAtomically() async throws {
        let harness = try await ReadlineHarness.run([
            .paste("alpha beta"),
            .key(KeyEvent(key: .home)),
            .key(KeyEvent(key: .right, modifiers: [.shift, .alt])),
            .paste("🌍"),
            ctrl("z"),
        ])

        #expect(await harness.promptTexts.contains("🌍 beta"))
        #expect(await harness.lastPrompt?.text == "alpha beta")
        #expect(await harness.viewportCommands.isEmpty)
    }

    @Test("modal-consumed Command+C never forwards composer selection to the clipboard")
    func consumedModalInputCannotLeakPromptClipboard() async throws {
        let harness = try await ReadlineHarness.run(
            [
                .paste("private"),
                .key(KeyEvent(key: .home)),
                .key(KeyEvent(key: .right, modifiers: [.shift])),
                .key(KeyEvent(key: .char("c"), modifiers: [.superKey], character: "c")),
            ],
            consumeCommandCopy: true
        )

        #expect(await harness.clipboard.isEmpty)
        #expect(await harness.lastPrompt?.selectedText == "p")
    }

    @Test("renderer clipboard failures propagate instead of silently claiming a copy")
    func rendererClipboardFailurePropagates() async throws {
        do {
            let result = try await ReadlineHarness.run(
                [
                    .paste("alpha"),
                    .key(KeyEvent(key: .home)),
                    .key(KeyEvent(key: .right, modifiers: [.shift])),
                    .key(KeyEvent(key: .char("c"), modifiers: [.superKey], character: "c")),
                ],
                copyShouldFail: true
            )
            Issue.record("copy unexpectedly succeeded: \(result.submittedPrompts)")
        } catch {
            #expect(error is ReadlineClipboardFailure)
        }
    }
}

private func ctrl(_ character: Character) -> InputEvent {
    .key(KeyEvent(key: .char(character), modifiers: [.control], character: character))
}

private struct ReadlineHarness {
    private let renderer: ReadlineRecordingRenderer
    let submittedPrompts: [String]

    var lastPrompt: OpenGrokPagerInteractivePromptState? {
        get async { await renderer.promptStates.last }
    }

    var promptStates: [OpenGrokPagerInteractivePromptState] {
        get async { await renderer.promptStates }
    }

    var promptTexts: [String] {
        get async { await renderer.promptStates.map(\.text) }
    }

    var promptChangedCount: Int {
        get async { await renderer.promptStates.count }
    }

    var viewportCommands: [OpenGrokPagerViewportCommand] {
        get async { await renderer.viewportCommands }
    }

    var scrollbackCommands: [OpenGrokPagerScrollbackCommand] {
        get async { await renderer.scrollbackCommands }
    }

    var clipboard: [String] {
        get async { await renderer.clipboard }
    }

    var globals: [OpenGrokPagerGlobalCommand] {
        get async { await renderer.globals }
    }

    var focusChanges: [OpenGrokPagerFocusRegion] {
        get async { await renderer.focusChanges }
    }

    var overlayRequests: [OpenGrokPagerOverlayRequest] {
        get async { await renderer.overlayRequests }
    }

    static func run(
        _ events: [InputEvent],
        sessions: [ReadlineSession] = [],
        routeMouse: Bool = false,
        promptSelectAllEnabled: Bool = false,
        contentWidth: Int = 40,
        consumeCommandCopy: Bool = false,
        copyShouldFail: Bool = false
    ) async throws -> ReadlineHarness {
        let renderer = ReadlineRecordingRenderer(
            routeMouse: routeMouse,
            contentWidth: contentWidth,
            consumeCommandCopy: consumeCommandCopy,
            copyShouldFail: copyShouldFail
        )
        let controller = OpenGrokPagerInteractiveController(
            input: closedReadlineStream(events),
            runtime: ReadlineRuntime(sessions: sessions),
            renderer: renderer,
            output: SilentReadlineOutput(),
            promptSelectAllEnabled: promptSelectAllEnabled
        )
        let result = try await controller.run(.init(prompt: "", mode: .inline))
        return ReadlineHarness(renderer: renderer, submittedPrompts: result.submittedPrompts)
    }
}

private actor ReadlineRecordingRenderer: OpenGrokPagerInteractiveRenderAdapter {
    private let routeMouse: Bool
    private let content: TextAreaRect
    private let consumeCommandCopy: Bool
    private let copyShouldFail: Bool
    private(set) var events: [OpenGrokPagerInteractiveEvent] = []
    private(set) var clipboard: [String] = []

    init(
        routeMouse: Bool,
        contentWidth: Int,
        consumeCommandCopy: Bool,
        copyShouldFail: Bool
    ) {
        self.routeMouse = routeMouse
        self.content = TextAreaRect(x: 0, y: 0, width: contentWidth, height: 3)
        self.consumeCommandCopy = consumeCommandCopy
        self.copyShouldFail = copyShouldFail
    }

    func begin() {}
    func restoreTerminal() {}
    func render(_ event: OpenGrokPagerInteractiveEvent) { events.append(event) }

    func handleInput(_ event: InputEvent) -> OpenGrokPagerInputRouting {
        if consumeCommandCopy,
           case .key(let key) = event,
           case .char("c") = key.key,
           key.modifiers.contains(.superKey) || key.modifiers.contains(.meta) {
            return .consumed
        }
        guard routeMouse, case .mouse(let mouse) = event else { return .notHandled }
        return .composerMouse(OpenGrokPagerComposerMouse(event: mouse, content: content))
    }

    func lastComposerContentRect() -> TextAreaRect? { content }

    func copyToClipboard(_ text: String) throws {
        if copyShouldFail { throw ReadlineClipboardFailure() }
        clipboard.append(text)
    }

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

    var scrollbackCommands: [OpenGrokPagerScrollbackCommand] {
        events.compactMap {
            if case .scrollback(let command) = $0 { return command }
            return nil
        }
    }

    var globals: [OpenGrokPagerGlobalCommand] {
        events.compactMap {
            if case .global(let command) = $0 { return command }
            return nil
        }
    }

    var focusChanges: [OpenGrokPagerFocusRegion] {
        events.compactMap {
            if case .focusChanged(let region) = $0 { return region }
            return nil
        }
    }

    var overlayRequests: [OpenGrokPagerOverlayRequest] {
        events.compactMap {
            if case .overlay(let request) = $0 { return request }
            return nil
        }
    }
}

private struct ReadlineClipboardFailure: Error {}

private struct SilentReadlineOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}

private actor ReadlineRuntime: OpenGrokPagerRuntimeAdapter {
    private var sessions: [ReadlineSession]
    init(sessions: [ReadlineSession]) { self.sessions = sessions }

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

private actor ReadlineSession: OpenGrokPagerSessionAdapter {
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

private func closedReadlineStream(_ events: [InputEvent]) -> AsyncStream<InputEvent> {
    AsyncStream { continuation in
        for event in events { continuation.yield(event) }
        continuation.finish()
    }
}
