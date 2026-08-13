// PagerFocusComposerRoutingTests.swift
//
// Controller pump handling of `.focusComposer` (chrome / focus-only) and
// `.composerMouse` (content). Exercises the live seam through a sequencing
// renderer (AGENTS.md §3).

import Foundation
import OpenGrokPager
import OpenGrokTerminalCore
import Testing

@Suite("Renderer composer mouse routing")
struct PagerFocusComposerRoutingTests {
    @Test("composerMouse places cursor and typed character inserts there")
    func composerMousePlacesCursorThenTypes() async throws {
        let content = TextAreaRect(x: 0, y: 0, width: 40, height: 3)
        let renderer = SequencingFocusRenderer(routings: [
            .notHandled, // Tab → editor focusScrollback
            .composerMouse(OpenGrokPagerComposerMouse(
                event: MouseEvent(kind: .down, x: 2, y: 0, button: .left),
                content: content
            )),
            .notHandled, // char "X" reaches the editor
        ])
        let controller = OpenGrokPagerInteractiveController(
            input: closedComposerStream([
                .key(KeyEvent(key: .tab)),
                .mouse(MouseEvent(kind: .down, x: 2, y: 0, button: .left)),
                .key(KeyEvent(key: .char("X"), character: "X")),
            ]),
            runtime: InertComposerRuntime(),
            renderer: renderer,
            output: SilentComposerOutput()
        )

        let result = try await controller.run(.init(prompt: "hello", mode: .inline))
        #expect(result.submittedPrompts.isEmpty)

        #expect(await renderer.focusChanges == [.scrollback, .prompt])
        #expect(await controller.state().focus == .prompt)
        #expect(await renderer.promptTexts.last == "heXllo")
        let lastCursor = await renderer.promptCursorOffsets.last
        #expect(lastCursor == 3)
        #expect(await renderer.promptUTF8.last == 3)
    }

    @Test("focusComposer chrome click focuses without moving caret")
    func focusOnlyLeavesCursor() async throws {
        let renderer = SequencingFocusRenderer(routings: [
            .focusComposer,
            .notHandled,
        ])
        let controller = OpenGrokPagerInteractiveController(
            input: closedComposerStream([
                .mouse(MouseEvent(kind: .down, x: 0, y: 0, button: .left)),
                .key(KeyEvent(key: .char("Z"), character: "Z")),
            ]),
            runtime: InertComposerRuntime(),
            renderer: renderer,
            output: SilentComposerOutput()
        )

        let result = try await controller.run(.init(prompt: "ab", mode: .inline))
        #expect(result.submittedPrompts.isEmpty)

        let focusChanges = await renderer.focusChanges
        let focus = await controller.state().focus
        #expect(focusChanges.contains(.prompt) || focus == .prompt)
        #expect(await renderer.promptTexts.last == "abZ")
    }

    @Test("focusComposer setFocus failure propagates through the input pump")
    func focusComposerSetFocusFailurePropagates() async throws {
        let renderer = SequencingFocusRenderer(routings: [
            .notHandled, // Tab → scrollback first so setFocus(.prompt) must emit
            .focusComposer,
        ])
        let controller = OpenGrokPagerInteractiveController(
            input: closedComposerStream([
                .key(KeyEvent(key: .tab)),
                .mouse(MouseEvent(kind: .down, x: 0, y: 0, button: .left)),
            ]),
            runtime: InertComposerRuntime(),
            renderer: renderer,
            output: PromptFocusFailingOutput()
        )

        do {
            let result = try await controller.run(.init(prompt: "hi", mode: .inline))
            Issue.record("expected setFocus failure to fail the run")
            #expect(result.submittedPrompts.isEmpty)
        } catch let error as OpenGrokPagerInteractiveError {
            guard case .inputFailed(let message) = error else {
                Issue.record("expected inputFailed, got \(error)")
                return
            }
            #expect(message.contains("focus-emit-failed"))
        }
    }

    @Test("composerMouse setFocus failure propagates")
    func composerMouseSetFocusFailurePropagates() async throws {
        let content = TextAreaRect(x: 0, y: 0, width: 40, height: 3)
        let renderer = SequencingFocusRenderer(routings: [
            .notHandled,
            .composerMouse(OpenGrokPagerComposerMouse(
                event: MouseEvent(kind: .down, x: 0, y: 0, button: .left),
                content: content
            )),
        ])
        let controller = OpenGrokPagerInteractiveController(
            input: closedComposerStream([
                .key(KeyEvent(key: .tab)),
                .mouse(MouseEvent(kind: .down, x: 0, y: 0, button: .left)),
            ]),
            runtime: InertComposerRuntime(),
            renderer: renderer,
            output: PromptFocusFailingOutput()
        )

        do {
            let result = try await controller.run(.init(prompt: "hi", mode: .inline))
            Issue.record("expected setFocus failure to fail the run")
            #expect(result.submittedPrompts.isEmpty)
        } catch let error as OpenGrokPagerInteractiveError {
            guard case .inputFailed(let message) = error else {
                Issue.record("expected inputFailed, got \(error)")
                return
            }
            #expect(message.contains("focus-emit-failed"))
        }
    }

    @Test("composer wheel does not setFocus prompt")
    func composerWheelDoesNotSetFocus() async throws {
        let content = TextAreaRect(x: 0, y: 0, width: 20, height: 2)
        let renderer = SequencingFocusRenderer(routings: [
            .notHandled,
            .composerMouse(OpenGrokPagerComposerMouse(
                event: MouseEvent(kind: .scrollDown, x: 1, y: 0, button: .none),
                content: content
            )),
        ])
        let controller = OpenGrokPagerInteractiveController(
            input: closedComposerStream([
                .key(KeyEvent(key: .tab)),
                .mouse(MouseEvent(kind: .scrollDown, x: 1, y: 0, button: .none)),
            ]),
            runtime: InertComposerRuntime(),
            renderer: renderer,
            output: SilentComposerOutput()
        )
        let result = try await controller.run(.init(
            prompt: (0..<12).map { "line\($0)xxxx" }.joined(separator: "\n"),
            mode: .inline
        ))
        #expect(result.submittedPrompts.isEmpty)
        #expect(await renderer.focusChanges == [.scrollback])
        #expect(await controller.state().focus == .scrollback)
        #expect(await renderer.promptTexts.last != nil)
    }
}

/// Returns sequenced routings then `.notHandled`, so later keys reach the editor.
private actor SequencingFocusRenderer: OpenGrokPagerInteractiveRenderAdapter {
    private var routings: [OpenGrokPagerInputRouting]
    private var events: [OpenGrokPagerInteractiveEvent] = []

    init(routings: [OpenGrokPagerInputRouting]) {
        self.routings = routings
    }

    func begin() {}
    func restoreTerminal() {}

    func render(_ event: OpenGrokPagerInteractiveEvent) {
        events.append(event)
    }

    func handleInput(_ event: InputEvent) -> OpenGrokPagerInputRouting {
        _ = event
        guard !routings.isEmpty else { return .notHandled }
        return routings.removeFirst()
    }

    var focusChanges: [OpenGrokPagerFocusRegion] {
        events.compactMap {
            if case .focusChanged(let region) = $0 { return region }
            return nil
        }
    }

    var promptTexts: [String] {
        events.compactMap {
            if case .promptChanged(let state) = $0 { return state.text }
            return nil
        }
    }

    var promptCursorOffsets: [Int] {
        events.compactMap {
            if case .promptChanged(let state) = $0 { return state.cursorOffset }
            return nil
        }
    }

    var promptUTF8: [Int] {
        events.compactMap {
            if case .promptChanged(let state) = $0 { return state.cursorUTF8 }
            return nil
        }
    }
}

private struct SilentComposerOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}

/// Fails `.focusChanged(.prompt)` so applyFocusComposer cannot hide emit errors.
private struct PromptFocusFailingOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws {
        if case .focusChanged(.prompt) = event {
            throw ComposerFocusEmitFailure()
        }
    }
}

private struct ComposerFocusEmitFailure: Error, CustomStringConvertible {
    var description: String { "focus-emit-failed" }
}

private actor InertComposerRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        _ = request
        throw OpenGrokPagerInteractiveError.sessionFailed("test runtime has no sessions")
    }

    func replaceSession(from request: OpenGrokPagerRequest) async throws -> String {
        _ = request
        throw OpenGrokPagerInteractiveError.sessionFailed("test runtime has no sessions")
    }
}

private func closedComposerStream(_ events: [InputEvent]) -> AsyncStream<InputEvent> {
    AsyncStream { continuation in
        for event in events { continuation.yield(event) }
        continuation.finish()
    }
}
