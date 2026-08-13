// PagerComposerMouseTests.swift
//
// Stage 2 live seam: PromptEditor TextArea is the only mutable buffer.
// Controller applies `.composerMouse` with the last-painted content rect,
// copies via the renderer clipboard callback, and ticks drag autoscroll
// through the existing scroll clock. Assert statuses; no `_ =`.

import Foundation
import OpenGrokPager
import OpenGrokTerminalCore
import Testing

@Suite("PromptEditor composer mouse (Stage 2)")
struct PagerComposerMouseTests {
    private let content = TextAreaRect(x: 0, y: 0, width: 40, height: 4)

    @Test("drag copies exact selected text and keeps the highlight")
    func dragCopiesExactSelection() async throws {
        let renderer = ComposerMouseRenderer(content: content)
        let result = try await runController(
            prompt: "hello world",
            events: [
                .mouse(MouseEvent(kind: .down, x: 0, y: 0, button: .left)),
                .mouse(MouseEvent(kind: .drag, x: 5, y: 0, button: .left)),
                .mouse(MouseEvent(kind: .up, x: 5, y: 0, button: .left)),
            ],
            renderer: renderer
        )
        #expect(result.submittedPrompts.isEmpty)
        #expect(await renderer.clipboard == ["hello"])
        let last = await renderer.lastPrompt
        #expect(last?.selectedText == "hello")
        #expect(last?.selectionUTF8 == 0..<5)
        #expect(last?.text == "hello world")
    }

    @Test("typing replaces the mouse selection")
    func typingReplacesSelection() async throws {
        let renderer = ComposerMouseRenderer(content: content)
        let result = try await runController(
            prompt: "hello",
            events: [
                .mouse(MouseEvent(kind: .down, x: 0, y: 0, button: .left)),
                .mouse(MouseEvent(kind: .drag, x: 5, y: 0, button: .left)),
                .mouse(MouseEvent(kind: .up, x: 5, y: 0, button: .left)),
                .key(KeyEvent(key: .char("X"), character: "X")),
            ],
            renderer: renderer
        )
        #expect(result.submittedPrompts.isEmpty)
        #expect(await renderer.lastPrompt?.text == "X")
        #expect(await renderer.lastPrompt?.selectionUTF8 == nil)
    }

    @Test("paste replaces the mouse selection")
    func pasteReplacesSelection() async throws {
        let renderer = ComposerMouseRenderer(content: content)
        let result = try await runController(
            prompt: "hello",
            events: [
                .mouse(MouseEvent(kind: .down, x: 0, y: 0, button: .left)),
                .mouse(MouseEvent(kind: .drag, x: 5, y: 0, button: .left)),
                .mouse(MouseEvent(kind: .up, x: 5, y: 0, button: .left)),
                .paste("YZ"),
            ],
            renderer: renderer
        )
        #expect(result.submittedPrompts.isEmpty)
        #expect(await renderer.lastPrompt?.text == "YZ")
    }

    @Test("backspace deletes the mouse selection")
    func backspaceDeletesSelection() async throws {
        let renderer = ComposerMouseRenderer(content: content)
        let result = try await runController(
            prompt: "hello",
            events: [
                .mouse(MouseEvent(kind: .down, x: 0, y: 0, button: .left)),
                .mouse(MouseEvent(kind: .drag, x: 5, y: 0, button: .left)),
                .mouse(MouseEvent(kind: .up, x: 5, y: 0, button: .left)),
                .key(KeyEvent(key: .backspace)),
            ],
            renderer: renderer
        )
        #expect(result.submittedPrompts.isEmpty)
        #expect(await renderer.lastPrompt?.text == "")
    }

    @Test("double-click selects a word including Unicode clusters")
    func doubleClickSelectsWord() async throws {
        let renderer = ComposerMouseRenderer(content: content)
        let result = try await runController(
            prompt: "hello world",
            events: [
                .mouse(MouseEvent(kind: .down, x: 1, y: 0, button: .left)),
                .mouse(MouseEvent(kind: .down, x: 1, y: 0, button: .left)),
            ],
            renderer: renderer
        )
        #expect(result.submittedPrompts.isEmpty)
        let last = await renderer.lastPrompt
        #expect(last?.selectedText == "hello")
        #expect(await renderer.clipboard.last == "hello")
    }

    @Test("double-click on an emoji selects that cluster only")
    func doubleClickSelectsEmojiCluster() async throws {
        let renderer = ComposerMouseRenderer(content: content)
        let text = "aa 😀bb"
        // "aa " is display columns 0..<3; 😀 occupies 3..<5.
        let result = try await runController(
            prompt: text,
            events: [
                .mouse(MouseEvent(kind: .down, x: 3, y: 0, button: .left)),
                .mouse(MouseEvent(kind: .down, x: 3, y: 0, button: .left)),
            ],
            renderer: renderer
        )
        #expect(result.submittedPrompts.isEmpty)
        let last = await renderer.lastPrompt
        #expect(last?.selectedText == "😀")
        #expect(await renderer.clipboard.last == "😀")
    }

    @Test("double-click on a wrapped word selects the whole word")
    func doubleClickSelectsWrappedWord() async throws {
        let narrow = TextAreaRect(x: 0, y: 0, width: 8, height: 4)
        let renderer = ComposerMouseRenderer(content: narrow)
        let result = try await runController(
            prompt: "abcdefghij",
            events: [
                .mouse(MouseEvent(kind: .down, x: 0, y: 1, button: .left)),
                .mouse(MouseEvent(kind: .down, x: 0, y: 1, button: .left)),
            ],
            renderer: renderer
        )
        #expect(result.submittedPrompts.isEmpty)
        let last = await renderer.lastPrompt
        #expect(last?.selectedText == "abcdefghij")
        #expect(await renderer.clipboard.last == "abcdefghij")
    }

    @Test("triple-click selects the line")
    func tripleClickSelectsLine() async throws {
        let renderer = ComposerMouseRenderer(content: content)
        let result = try await runController(
            prompt: "hello\nworld",
            events: [
                .mouse(MouseEvent(kind: .down, x: 1, y: 0, button: .left)),
                .mouse(MouseEvent(kind: .down, x: 1, y: 0, button: .left)),
                .mouse(MouseEvent(kind: .down, x: 1, y: 0, button: .left)),
            ],
            renderer: renderer
        )
        #expect(result.submittedPrompts.isEmpty)
        let last = await renderer.lastPrompt
        #expect(last?.selectedText == "hello\n")
        #expect(await renderer.clipboard.last == "hello\n")
    }

    @Test("whitespace double-click places the cursor only")
    func whitespaceDoubleClickPlacesCursor() async throws {
        let renderer = ComposerMouseRenderer(content: content)
        let result = try await runController(
            prompt: "aa bb",
            events: [
                .mouse(MouseEvent(kind: .down, x: 2, y: 0, button: .left)),
                .mouse(MouseEvent(kind: .down, x: 2, y: 0, button: .left)),
                .key(KeyEvent(key: .char("X"), character: "X")),
            ],
            renderer: renderer
        )
        #expect(result.submittedPrompts.isEmpty)
        #expect(await renderer.lastPrompt?.selectedText == nil)
        let typed = await renderer.lastPrompt?.text ?? ""
        #expect(typed.contains("X"))
        #expect(typed.hasPrefix("aa"))
        #expect(typed.contains("bb"))
    }

    @Test("drag outside the content rect edge-scrolls")
    func dragOutsideEdgeScrolls() async throws {
        let tall = TextAreaRect(x: 0, y: 5, width: 20, height: 2)
        let renderer = ComposerMouseRenderer(content: tall)
        let body = (0..<12).map { "line\($0)xxxx" }.joined(separator: "\n")
        let result = try await runController(
            prompt: body,
            events: [
                .mouse(MouseEvent(kind: .down, x: 0, y: 5, button: .left)),
                .mouse(MouseEvent(kind: .drag, x: 0, y: 2, button: .left)),
            ],
            renderer: renderer
        )
        #expect(result.submittedPrompts.isEmpty)
        let last = await renderer.lastPrompt
        #expect(last?.scrollOverride != nil)
        #expect(last?.selectionUTF8 != nil)
    }

    @Test("wheel over composer is applied to TextArea")
    func wheelForwardsToTextArea() async throws {
        let tall = TextAreaRect(x: 0, y: 0, width: 20, height: 2)
        let renderer = ComposerMouseRenderer(content: tall)
        let body = (0..<12).map { "line\($0)xxxx" }.joined(separator: "\n")
        let result = try await runController(
            prompt: body,
            events: [
                .mouse(MouseEvent(kind: .scrollUp, x: 1, y: 0, button: .none)),
            ],
            renderer: renderer
        )
        #expect(result.submittedPrompts.isEmpty)
        let last = await renderer.lastPrompt
        #expect(last?.scrollOverride != nil)
        #expect(await renderer.clipboard.isEmpty)
    }

    @Test("copyToClipboard failure propagates")
    func copyFailurePropagates() async throws {
        let renderer = ComposerMouseRenderer(content: content, copyShouldFail: true)
        do {
            let result = try await runController(
                prompt: "hello",
                events: [
                    .mouse(MouseEvent(kind: .down, x: 0, y: 0, button: .left)),
                    .mouse(MouseEvent(kind: .drag, x: 5, y: 0, button: .left)),
                    .mouse(MouseEvent(kind: .up, x: 5, y: 0, button: .left)),
                ],
                renderer: renderer
            )
            Issue.record("expected copy failure to fail the run")
            #expect(result.submittedPrompts.isEmpty)
        } catch let error as OpenGrokPagerInteractiveError {
            guard case .inputFailed(let message) = error else {
                Issue.record("expected inputFailed, got \(error)")
                return
            }
            #expect(message.contains("clipboard-failed"))
        }
    }

    @Test("slash Tab Enter after a click opens the help overlay and clears the draft")
    func slashTabEnterAfterClickOpensHelpOverlay() async throws {
        let renderer = ComposerMouseRenderer(content: content)
        let result = try await runController(
            prompt: "",
            events: [
                .mouse(MouseEvent(kind: .down, x: 0, y: 0, button: .left)),
                .paste("/hel"),
                .key(KeyEvent(key: .tab)),
                .key(KeyEvent(key: .enter)),
            ],
            renderer: renderer
        )
        #expect(result.submittedPrompts.isEmpty)
        #expect(await renderer.lastPrompt?.text == "")
        #expect(await renderer.overlayRequests == [.help])
    }

    @Test("history Up after a content click still recalls into the same buffer")
    func historyAfterClickUsesSameBuffer() async throws {
        let session = BufferSession(sessionID: "s1")
        await session.emit(.completed(.init(sessionID: "s1")))
        let renderer = ComposerMouseRenderer(content: content)
        let result = try await runController(
            prompt: "",
            events: [
                .mouse(MouseEvent(kind: .down, x: 0, y: 0, button: .left)),
                .paste("alpha"),
                .key(KeyEvent(key: .enter)),
                .key(KeyEvent(key: .up)),
                .key(KeyEvent(key: .char("X"), character: "X")),
            ],
            renderer: renderer,
            sessions: [session]
        )
        #expect(result.submittedPrompts == ["alpha"])
        #expect(await renderer.lastPrompt?.text == "alphaX")
    }

    @Test("promptChanged render failure after composerMouse propagates")
    func promptChangedRenderFailurePropagates() async throws {
        let renderer = ComposerMouseRenderer(content: content, renderShouldFail: true)
        do {
            let result = try await runController(
                prompt: "hello",
                events: [
                    .mouse(MouseEvent(kind: .down, x: 0, y: 0, button: .left)),
                ],
                renderer: renderer
            )
            Issue.record("expected render failure to fail the run")
            #expect(result.submittedPrompts.isEmpty)
        } catch let error as OpenGrokPagerInteractiveError {
            guard case .inputFailed(let message) = error else {
                Issue.record("expected inputFailed, got \(error)")
                return
            }
            #expect(message.contains("render-failed"))
        }
    }

    @Test("X10 up-none copies a left drag; middle up does not")
    func x10UpCopiesLeftDrag() async throws {
        let renderer = ComposerMouseRenderer(content: content)
        let result = try await runController(
            prompt: "hello world",
            events: [
                .mouse(MouseEvent(kind: .down, x: 0, y: 0, button: .left)),
                .mouse(MouseEvent(kind: .drag, x: 5, y: 0, button: .left)),
                .mouse(MouseEvent(kind: .up, x: 5, y: 0, button: 1)),
                .mouse(MouseEvent(kind: .up, x: 5, y: 0, button: MouseEvent.noButton)),
            ],
            renderer: renderer
        )
        #expect(result.submittedPrompts.isEmpty)
        #expect(await renderer.clipboard == ["hello"])
        #expect(await renderer.lastPrompt?.selectedText == "hello")
    }

    @Test("wheel over composer does not steal prompt focus from scrollback")
    func wheelDoesNotStealPromptFocus() async throws {
        let tall = TextAreaRect(x: 0, y: 0, width: 20, height: 2)
        let renderer = ComposerMouseRenderer(content: tall)
        let body = (0..<12).map { "line\($0)xxxx" }.joined(separator: "\n")
        let result = try await runController(
            prompt: body,
            events: [
                .key(KeyEvent(key: .tab)),
                .mouse(MouseEvent(kind: .scrollUp, x: 1, y: 0, button: .none)),
            ],
            renderer: renderer
        )
        #expect(result.submittedPrompts.isEmpty)
        let focusChanges = await renderer.focusChanges
        #expect(focusChanges == [.scrollback])
        let last = await renderer.lastPrompt
        #expect(last?.scrollOverride != nil)
        let clipboard = await renderer.clipboard
        #expect(clipboard.isEmpty)
    }

    @Test("holding an edge drag ticks autoscroll with no further mouse events")
    func edgeDragTicksWithoutMoreEvents() async throws {
        let tall = TextAreaRect(x: 0, y: 5, width: 20, height: 2)
        let renderer = ComposerMouseRenderer(content: tall)
        let body = (0..<12).map { "line\($0)xxxx" }.joined(separator: "\n")
        let (stream, continuation) = AsyncStream<InputEvent>.makeStream()
        let controller = OpenGrokPagerInteractiveController(
            input: stream,
            runtime: ComposerMouseRuntime(sessions: []),
            renderer: renderer,
            output: SilentComposerMouseOutput()
        )
        let task = Task { try await controller.run(.init(prompt: body, mode: .inline)) }
        continuation.yield(.mouse(MouseEvent(kind: .down, x: 0, y: 5, button: .left)))
        continuation.yield(.mouse(MouseEvent(kind: .drag, x: 0, y: 2, button: .left)))
        let afterDrag = await renderer.waitForPromptCount(atLeast: 3, timeoutNanos: 5_000_000_000)
        #expect(afterDrag)
        let scrollAtDrag = await renderer.lastPrompt?.scrollOverride
        #expect(scrollAtDrag != nil)
        let ticked = await renderer.waitForPromptCount(atLeast: 4, timeoutNanos: 5_000_000_000)
        #expect(ticked)
        continuation.finish()
        await controller.shutdown()
        let result = try await task.value
        #expect(result.submittedPrompts.isEmpty)
    }

    @Test("cancel mid-drag parks the ticker; next down starts fresh")
    func cancelParksTickerAndNextDownIsFresh() async throws {
        let tall = TextAreaRect(x: 0, y: 5, width: 20, height: 2)
        let renderer = ComposerMouseRenderer(content: tall, consumeAfter: 2)
        let body = (0..<12).map { "line\($0)xxxx" }.joined(separator: "\n")
        let (stream, continuation) = AsyncStream<InputEvent>.makeStream()
        let controller = OpenGrokPagerInteractiveController(
            input: stream,
            runtime: ComposerMouseRuntime(sessions: []),
            renderer: renderer,
            output: SilentComposerMouseOutput()
        )
        let task = Task { try await controller.run(.init(prompt: body, mode: .inline)) }
        continuation.yield(.mouse(MouseEvent(kind: .down, x: 0, y: 5, button: .left)))
        continuation.yield(.mouse(MouseEvent(kind: .drag, x: 0, y: 2, button: .left)))
        let armed = await renderer.waitForPromptCount(atLeast: 3, timeoutNanos: 5_000_000_000)
        #expect(armed)
        let countAtCancel = await renderer.promptChangeCount
        continuation.yield(.mouse(MouseEvent(kind: .move, x: 0, y: 2, button: .none)))
        let consumed = await renderer.waitForConsumedCount(atLeast: 1, timeoutNanos: 5_000_000_000)
        #expect(consumed)
        try? await Task.sleep(nanoseconds: 250_000_000)
        #expect(await renderer.promptChangeCount == countAtCancel)
        continuation.yield(.mouse(MouseEvent(kind: .down, x: 3, y: 5, button: .left)))
        continuation.yield(.key(KeyEvent(key: .char("Z"), character: "Z")))
        let typed = await renderer.waitForPromptContaining("Z", timeoutNanos: 5_000_000_000)
        #expect(typed)
        let text = await renderer.lastPrompt?.text ?? ""
        #expect(text.contains("Z"))
        continuation.finish()
        await controller.shutdown()
        let result = try await task.value
        #expect(result.submittedPrompts.isEmpty)
    }
}

private func runController(
    prompt: String,
    events: [InputEvent],
    renderer: ComposerMouseRenderer,
    sessions: [BufferSession] = []
) async throws -> OpenGrokPagerInteractiveResult {
    let controller = OpenGrokPagerInteractiveController(
        input: closedComposerMouseStream(events),
        runtime: ComposerMouseRuntime(sessions: sessions),
        renderer: renderer,
        output: SilentComposerMouseOutput()
    )
    return try await controller.run(.init(prompt: prompt, mode: .inline))
}

private actor ComposerMouseRenderer: OpenGrokPagerInteractiveRenderAdapter {
    private let content: TextAreaRect
    private let copyShouldFail: Bool
    private let renderShouldFail: Bool
    private let consumeAfter: Int?
    private var promptChangeCountStorage = 0
    private var composerMouseCount = 0
    private var consumedCount = 0
    private var didConsumeOnce = false
    private(set) var clipboard: [String] = []
    private var events: [OpenGrokPagerInteractiveEvent] = []
    private var promptWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var consumedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var containingWaiters: [(String, CheckedContinuation<Void, Never>)] = []

    init(
        content: TextAreaRect,
        copyShouldFail: Bool = false,
        renderShouldFail: Bool = false,
        consumeAfter: Int? = nil
    ) {
        self.content = content
        self.copyShouldFail = copyShouldFail
        self.renderShouldFail = renderShouldFail
        self.consumeAfter = consumeAfter
    }

    func begin() {}
    func restoreTerminal() {}

    func render(_ event: OpenGrokPagerInteractiveEvent) throws {
        if case .promptChanged = event {
            promptChangeCountStorage += 1
            if renderShouldFail, promptChangeCountStorage > 1 {
                throw ComposerRenderFailure()
            }
        }
        events.append(event)
        notifyWaiters()
    }

    func handleInput(_ event: InputEvent) -> OpenGrokPagerInputRouting {
        guard case .mouse(let mouse) = event else { return .notHandled }
        if let consumeAfter, composerMouseCount >= consumeAfter, !didConsumeOnce {
            didConsumeOnce = true
            consumedCount += 1
            notifyWaiters()
            return .consumed
        }
        composerMouseCount += 1
        return .composerMouse(OpenGrokPagerComposerMouse(event: mouse, content: content))
    }

    func lastComposerContentRect() async -> TextAreaRect? {
        content
    }

    func copyToClipboard(_ text: String) async throws {
        if copyShouldFail {
            throw ComposerClipboardFailure()
        }
        clipboard.append(text)
    }

    var lastPrompt: OpenGrokPagerInteractivePromptState? {
        events.compactMap {
            if case .promptChanged(let state) = $0 { return state }
            return nil
        }.last
    }

    var promptChangeCount: Int { promptChangeCountStorage }

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

    func waitForPromptCount(atLeast count: Int, timeoutNanos: UInt64) async -> Bool {
        if promptChangeCountStorage >= count { return true }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            promptWaiters.append((count, continuation))
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanos)
                self.timeoutPromptWaiter(count)
            }
        }
        return promptChangeCountStorage >= count
    }

    func waitForConsumedCount(atLeast count: Int, timeoutNanos: UInt64) async -> Bool {
        if consumedCount >= count { return true }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            consumedWaiters.append((count, continuation))
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanos)
                self.timeoutConsumedWaiter(count)
            }
        }
        return consumedCount >= count
    }

    func waitForPromptContaining(_ needle: String, timeoutNanos: UInt64) async -> Bool {
        if lastPrompt?.text.contains(needle) == true { return true }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            containingWaiters.append((needle, continuation))
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanos)
                self.timeoutContainingWaiter(needle)
            }
        }
        return lastPrompt?.text.contains(needle) == true
    }

    private func notifyWaiters() {
        let promptReady = promptWaiters.filter { promptChangeCountStorage >= $0.0 }
        promptWaiters.removeAll { promptChangeCountStorage >= $0.0 }
        for waiter in promptReady { waiter.1.resume() }
        let consumedReady = consumedWaiters.filter { consumedCount >= $0.0 }
        consumedWaiters.removeAll { consumedCount >= $0.0 }
        for waiter in consumedReady { waiter.1.resume() }
        let text = lastPrompt?.text ?? ""
        let containingReady = containingWaiters.filter { text.contains($0.0) }
        containingWaiters.removeAll { text.contains($0.0) }
        for waiter in containingReady { waiter.1.resume() }
    }

    private func timeoutPromptWaiter(_ count: Int) {
        if let index = promptWaiters.firstIndex(where: { $0.0 == count }) {
            promptWaiters.remove(at: index).1.resume()
        }
    }

    private func timeoutConsumedWaiter(_ count: Int) {
        if let index = consumedWaiters.firstIndex(where: { $0.0 == count }) {
            consumedWaiters.remove(at: index).1.resume()
        }
    }

    private func timeoutContainingWaiter(_ needle: String) {
        if let index = containingWaiters.firstIndex(where: { $0.0 == needle }) {
            containingWaiters.remove(at: index).1.resume()
        }
    }
}

private struct ComposerClipboardFailure: Error, CustomStringConvertible {
    var description: String { "clipboard-failed" }
}

private struct ComposerRenderFailure: Error, CustomStringConvertible {
    var description: String { "render-failed" }
}

private struct SilentComposerMouseOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws {
        switch event {
        case .promptChanged, .focusChanged, .lifecycle, .eof, .shutdown, .cancelled:
            return
        default:
            return
        }
    }
}

private actor ComposerMouseRuntime: OpenGrokPagerRuntimeAdapter {
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

private func closedComposerMouseStream(_ events: [InputEvent]) -> AsyncStream<InputEvent> {
    AsyncStream { continuation in
        for event in events { continuation.yield(event) }
        continuation.finish()
    }
}
