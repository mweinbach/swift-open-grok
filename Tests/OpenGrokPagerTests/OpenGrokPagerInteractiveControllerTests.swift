import Foundation
import OpenGrokPager
import OpenGrokTerminalCore
import Testing

@Suite("Open Grok interactive pager controller")
struct OpenGrokPagerInteractiveControllerTests {
    @Test("leading bang runs locally and never submits a model prompt")
    func leadingBangRunsLocally() async throws {
        let capture = BashCommandCapture()
        let runtime = TestInteractiveRuntime(sessions: [])
        let controller = OpenGrokPagerInteractiveController(
            input: makeInputStream([
                .paste("! echo hello"),
                .key(KeyEvent(key: .enter)),
            ]),
            runtime: runtime,
            renderer: RecordingInteractiveRenderer(),
            output: RecordingInteractiveOutput(),
            bashCommandHandler: { command in
                await capture.record(command)
            }
        )

        let result = try await controller.run(.init(prompt: "", mode: .inline))

        #expect(result.lifecycle == .eof)
        #expect(result.submittedPrompts.isEmpty)
        #expect(await runtime.requests.isEmpty)
        #expect(await capture.commands == ["echo hello"])
    }

    @Test("edits and submits multiple prompts through reusable runtime sessions")
    func submitsMultipleTurns() async throws {
        let firstSession = TestInteractiveSession(sessionID: "session-1")
        await firstSession.emit(.output("first response"))
        await firstSession.emit(.completed(.init(sessionID: "session-1")))

        let secondSession = TestInteractiveSession(sessionID: "session-2")
        await secondSession.emit(.output("second response"))
        await secondSession.emit(.completed(.init(sessionID: "session-2")))

        let runtime = TestInteractiveRuntime(sessions: [firstSession, secondSession])
        let renderer = RecordingInteractiveRenderer()
        let output = RecordingInteractiveOutput()
        let input = makeInputStream([
            .paste("helo"),
            .key(KeyEvent(key: .left)),
            .key(KeyEvent(key: .char("l"), character: "l")),
            .key(KeyEvent(key: .enter)),
            .paste("second"),
            .key(KeyEvent(key: .enter)),
        ])
        let controller = OpenGrokPagerInteractiveController(
            input: input,
            runtime: runtime,
            renderer: renderer,
            output: output
        )

        let result = try await controller.run(.init(prompt: "", mode: .inline))

        #expect(result.lifecycle == .eof)
        #expect(result.submittedPrompts == ["hello", "second"])
        #expect(result.completedTurnCount == 2)
        #expect(result.sessionID == "session-2")
        #expect(result.terminalRestored)
        let requests = await runtime.requests
        #expect(requests.map(\.prompt) == ["hello", "second"])
        #expect(await firstSession.closeCount == 1)
        #expect(await secondSession.closeCount == 1)
        #expect(await renderer.beginCount == 1)
        #expect(await renderer.restoreCount == 1)
        let state = await controller.state()
        #expect(state.prompt == .init())
    }

    @Test("Ctrl+C during a turn cancels the turn and returns to the prompt")
    func interruptCancelsTurnNotRun() async throws {
        let session = TestInteractiveSession(sessionID: "cancel-session")
        let runtime = TestInteractiveRuntime(sessions: [session])
        let renderer = RecordingInteractiveRenderer()
        let output = RecordingInteractiveOutput()
        let input = makeInputStream([
            .paste("wait"),
            .key(KeyEvent(key: .enter)),
            .key(KeyEvent(key: .char("c"), modifiers: [.control], character: "c")),
        ])
        let controller = OpenGrokPagerInteractiveController(
            input: input,
            runtime: runtime,
            renderer: renderer,
            output: output
        )

        let result = try await controller.run(.init(prompt: "", mode: .inline))

        // Cancelling a turn is not cancelling the run: the loop returns to the
        // prompt and only the exhausted input stream ends it.
        #expect(result.lifecycle == .eof)
        #expect(result.submittedPrompts == ["wait"])
        #expect(await session.cancelCount == 1)
        #expect(await session.closeCount == 1)
        #expect(await renderer.restoreCount == 1)
        #expect(await renderer.events.contains(.turnCancelled))
    }

    @Test("an external cancel still ends the run")
    func externalCancelEndsRun() async throws {
        let session = TestInteractiveSession(sessionID: "external")
        let runtime = TestInteractiveRuntime(sessions: [session])
        let controller = OpenGrokPagerInteractiveController(
            input: makeOpenInputStream([
                .paste("wait"),
                .key(KeyEvent(key: .enter)),
            ]),
            runtime: runtime,
            renderer: RecordingInteractiveRenderer(),
            output: RecordingInteractiveOutput()
        )

        let task = Task { try await controller.run(.init(prompt: "", mode: .inline)) }
        // Wait for the turn to open by observing the runtime rather than
        // polling the controller actor, which would starve its own run loop.
        await runtime.waitForFirstRequest()
        await controller.cancel()

        let result = try await task.value
        #expect(result.lifecycle == .cancelled)
        #expect(await session.cancelCount >= 1)
    }

    @Test("a failed turn renders a marker and returns to the prompt")
    func failedTurnKeepsRunAlive() async throws {
        let failing = TestInteractiveSession(sessionID: "fails")
        let follow = TestInteractiveSession(sessionID: "next")
        await follow.emit(.completed(.init(sessionID: "next")))
        let runtime = TestInteractiveRuntime(sessions: [failing, follow])
        let renderer = RecordingInteractiveRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: makeOpenInputStream([
                .paste("alpha"),
                .key(KeyEvent(key: .enter)),
                .paste("beta"),
                .key(KeyEvent(key: .enter)),
            ]),
            runtime: runtime,
            renderer: renderer,
            output: RecordingInteractiveOutput()
        )

        let task = Task { try await controller.run(.init(prompt: "", mode: .inline)) }
        await runtime.waitForFirstRequest()
        await failing.fail("provider exploded")

        // The regression this guards: a session failure used to be rethrown
        // as `sessionFailed` and end the whole run — one bad provider request
        // took the whole TUI down. A failed turn returns to the composer and
        // the queue keeps draining, exactly like upstream's generic error
        // path (`TurnFailed` marker then `maybe_drain_queue`,
        // dispatch/prompt.rs:1399-1402, :1622).
        #expect(await waitUntil { await runtime.requests.count == 2 })
        #expect(await waitUntil {
            await renderer.turnFailures.contains { $0.contains("provider exploded") }
        })
        await controller.shutdown()
        let result = await runResult(of: task)

        #expect(result?.lifecycle == .shutdown)
        #expect(result?.submittedPrompts == ["alpha", "beta"])
        // Only the follow-up counts as completed; the failed turn does not.
        #expect(result?.completedTurnCount == 1)
    }

    @Test("Esc on an idle prompt arms a clear and never exits")
    func escapeArmsClear() async throws {
        let renderer = RecordingInteractiveRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: makeInputStream([
                .paste("draft"),
                .key(KeyEvent(key: .escape)),
                .key(KeyEvent(key: .escape)),
            ]),
            runtime: TestInteractiveRuntime(sessions: []),
            renderer: renderer,
            output: RecordingInteractiveOutput()
        )

        let result = try await controller.run(.init(prompt: "", mode: .inline))

        // The run survives both presses; the second clears the draft.
        #expect(result.lifecycle == .eof)
        #expect(result.submittedPrompts.isEmpty)
        let armed = await renderer.promptStates.contains {
            $0.pendingConfirmationKey == "Esc" && $0.pendingConfirmationLabel == "clear"
        }
        #expect(armed)
        #expect(await renderer.promptStates.last?.text == "")
    }

    @Test("Ctrl+C clears a draft first, then arms a quit")
    func interruptClearsThenQuits() async throws {
        let renderer = RecordingInteractiveRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: makeInputStream([
                .paste("draft"),
                .key(KeyEvent(key: .char("c"), modifiers: [.control], character: "c")),
                .key(KeyEvent(key: .char("c"), modifiers: [.control], character: "c")),
                .key(KeyEvent(key: .char("c"), modifiers: [.control], character: "c")),
            ]),
            runtime: TestInteractiveRuntime(sessions: []),
            renderer: renderer,
            output: RecordingInteractiveOutput()
        )

        let result = try await controller.run(.init(prompt: "", mode: .inline))

        #expect(result.lifecycle == .cancelled)
        let armed = await renderer.promptStates.contains {
            $0.pendingConfirmationKey == "Ctrl+c" && $0.pendingConfirmationLabel == "quit"
        }
        #expect(armed)
    }

    @Test("Up recalls prior prompts only on an empty composer")
    func historyRecall() async throws {
        let first = TestInteractiveSession(sessionID: "s1")
        await first.emit(.completed(.init(sessionID: "s1")))
        let second = TestInteractiveSession(sessionID: "s2")
        await second.emit(.completed(.init(sessionID: "s2")))

        let renderer = RecordingInteractiveRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: makeInputStream([
                .paste("alpha"),
                .key(KeyEvent(key: .enter)),
                .key(KeyEvent(key: .up)),
                .key(KeyEvent(key: .enter)),
            ]),
            runtime: TestInteractiveRuntime(sessions: [first, second]),
            renderer: renderer,
            output: RecordingInteractiveOutput()
        )

        let result = try await controller.run(.init(prompt: "", mode: .inline))

        #expect(result.submittedPrompts == ["alpha", "alpha"])
    }

    @Test("Down past the newest history entry restores the stashed draft")
    func historyRestoresDraft() async throws {
        let session = TestInteractiveSession(sessionID: "s1")
        await session.emit(.completed(.init(sessionID: "s1")))
        let renderer = RecordingInteractiveRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: makeInputStream([
                .paste("alpha"),
                .key(KeyEvent(key: .enter)),
                .key(KeyEvent(key: .up)),
                .key(KeyEvent(key: .down)),
            ]),
            runtime: TestInteractiveRuntime(sessions: [session]),
            renderer: renderer,
            output: RecordingInteractiveOutput()
        )

        _ = try await controller.run(.init(prompt: "", mode: .inline))

        let texts = await renderer.promptStates.map(\.text)
        #expect(texts.contains("alpha"))
        #expect(texts.last == "")
    }

    @Test("nonempty Up moves inside a multiline draft; PageUp/PageDown still page the viewport")
    func upMovesInsideDraft() async throws {
        // Pin 650c1db7: empty Up is history (`prompt.rs:465-486`); nonempty
        // Up/Down are textarea vertical motion. PageUp/PageDown stay host
        // viewport chords. The prior test pinned the opposite (draft Up =
        // lineUp) and is rewritten to the pin.
        let renderer = RecordingInteractiveRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: makeInputStream([
                .paste("first"),
                .key(KeyEvent(key: .enter, modifiers: [.shift])),
                .paste("second"),
                .key(KeyEvent(key: .up)),
                .key(KeyEvent(key: .char("X"), character: "X")),
                .key(KeyEvent(key: .pageUp)),
                .key(KeyEvent(key: .pageDown)),
            ]),
            runtime: TestInteractiveRuntime(sessions: []),
            renderer: renderer,
            output: RecordingInteractiveOutput()
        )

        _ = try await controller.run(.init(prompt: "", mode: .inline))

        #expect(await renderer.promptStates.last?.text == "firstX\nsecond")
        #expect(await renderer.viewportCommands == [.pageUp, .pageDown])
    }

    @Test("empty Home/End are textarea no-ops; nonempty Home/End move in the draft")
    func homeEndEditDraftNotTranscript() async throws {
        // Pin: Home/End are not GotoTop/GotoBottom (those are g/G,
        // `When::ScrollbackFocused`). Empty Home/End fall through to
        // TextArea.input and do nothing; they must not jump the transcript.
        let renderer = RecordingInteractiveRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: makeInputStream([
                .key(KeyEvent(key: .home)),
                .key(KeyEvent(key: .end)),
                .paste("ab"),
                .key(KeyEvent(key: .home)),
                .key(KeyEvent(key: .char("X"), character: "X")),
                .key(KeyEvent(key: .end)),
                .key(KeyEvent(key: .char("Y"), character: "Y")),
            ]),
            runtime: TestInteractiveRuntime(sessions: []),
            renderer: renderer,
            output: RecordingInteractiveOutput()
        )

        _ = try await controller.run(.init(prompt: "", mode: .inline))

        #expect(await renderer.viewportCommands.isEmpty)
        #expect(await renderer.promptStates.last?.text == "XabY")
    }

    @Test("typing a slash opens a completion menu that Tab accepts")
    func slashCompletion() async throws {
        let renderer = RecordingInteractiveRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: makeInputStream([
                .paste("/q"),
                .key(KeyEvent(key: .tab)),
            ]),
            runtime: TestInteractiveRuntime(sessions: []),
            renderer: renderer,
            output: RecordingInteractiveOutput()
        )

        _ = try await controller.run(.init(prompt: "", mode: .inline))

        let states = await renderer.promptStates
        #expect(states.contains { $0.completions.contains { $0.name == "/quit" } })
        // `/q` ties `queue` and `quit`; with no recency the display-order
        // tiebreak puts `/queue` first (`slash/mod.rs:996-1003`), so Tab
        // accepts it.
        #expect(states.last?.text == "/queue")
        #expect(states.last?.completions.isEmpty == true)
    }

    /// Once the command name is settled the dropdown belongs to the arguments.
    /// The controller cannot name a model, so it only decides *when* that phase
    /// has opened and hands the typed query to the host verbatim.
    @Test("a typed /model argument opens the argument dropdown and Tab accepts a row")
    func argumentCompletion() async throws {
        let renderer = RecordingInteractiveRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: makeInputStream([
                .paste("/model cod"),
                .key(KeyEvent(key: .tab)),
            ]),
            runtime: TestInteractiveRuntime(sessions: []),
            renderer: renderer,
            output: RecordingInteractiveOutput()
        )
        await controller.setArgumentSuggestions { command, query in
            [
                OpenGrokPagerCommandSuggestion(
                    // Echoed back so the assertions can see exactly what the
                    // controller decided the command and query were.
                    name: "\(command)|\(query)",
                    summary: "GPT-5.6 Sol",
                    insertText: "/model codex:gpt-5.6-sol"
                )
            ]
        }

        _ = try await controller.run(.init(prompt: "", mode: .inline))

        let states = await renderer.promptStates
        #expect(states.contains { $0.completions.contains { $0.name == "model|cod" } })
        // Accepting an argument row leaves a whole command behind. A bare
        // selector would submit as a prompt on the next Enter.
        #expect(states.last?.text == "/model codex:gpt-5.6-sol")
        #expect(states.last?.completions.isEmpty == true)
    }

    /// The argument phase opens at the first whitespace after the command name,
    /// which is upstream's rule too — a trailing space is what moves `/model`
    /// from the model list into the effort sub-menu. So `/model ` is a real
    /// query (empty), not an absent one.
    @Test("a trailing space alone opens the argument phase with an empty query")
    func argumentCompletionWithEmptyQuery() async throws {
        let renderer = RecordingInteractiveRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: makeInputStream([.paste("/model ")]),
            runtime: TestInteractiveRuntime(sessions: []),
            renderer: renderer,
            output: RecordingInteractiveOutput()
        )
        await controller.setArgumentSuggestions { command, query in
            [OpenGrokPagerCommandSuggestion(name: "\(command)|\(query)", summary: "")]
        }

        _ = try await controller.run(.init(prompt: "", mode: .inline))

        let states = await renderer.promptStates
        #expect(states.contains { $0.completions.contains { $0.name == "model|" } })
        // The command-name dropdown must not also fire — the name is settled.
        #expect(states.allSatisfy { !$0.completions.contains { $0.name == "/model" } })
    }

    /// With no host-supplied source, the argument phase offers nothing rather
    /// than falling back to command names, which would put `/model` in a
    /// dropdown the user has already left.
    @Test("the argument phase offers nothing when no source is installed")
    func argumentCompletionWithoutSource() async throws {
        let renderer = RecordingInteractiveRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: makeInputStream([.paste("/model cod")]),
            runtime: TestInteractiveRuntime(sessions: []),
            renderer: renderer,
            output: RecordingInteractiveOutput()
        )

        _ = try await controller.run(.init(prompt: "", mode: .inline))

        #expect(await renderer.promptStates.allSatisfy { $0.completions.isEmpty })
    }

    @Test("@-file completion triggers and accepts suggestion replacing @query")
    func atFileCompletionDropdownAndAccept() async throws {
        let renderer = RecordingInteractiveRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: makeInputStream([
                .paste("check @foo"),
                .key(KeyEvent(key: .tab)),
            ]),
            runtime: TestInteractiveRuntime(sessions: []),
            renderer: renderer,
            output: RecordingInteractiveOutput()
        )
        await controller.setFileSearchSuggestions { query, isDir, hidden in
            if query == "foo" {
                return [
                    OpenGrokPagerCommandSuggestion(
                        name: "@Sources/Foo.swift",
                        summary: "",
                        isAvailable: true,
                        insertText: "Sources/Foo.swift"
                    )
                ]
            }
            return []
        }

        _ = try await controller.run(.init(prompt: "", mode: .inline))

        let states = await renderer.promptStates
        #expect(states.contains { $0.completions.contains { $0.name == "@Sources/Foo.swift" } })
        // After accepting with Tab, the composer text has @Sources/Foo.swift with trailing space
        #expect(states.last?.text == "check @Sources/Foo.swift ")
        #expect(states.last?.completions.isEmpty == true)
    }

    @Test("/help opens the shortcuts modal and /quit ends the run without a session")
    func slashCommandsRunLocally() async throws {
        let runtime = TestInteractiveRuntime(sessions: [])
        let output = RecordingInteractiveOutput()
        let controller = OpenGrokPagerInteractiveController(
            input: makeInputStream([
                .paste("/help"),
                .key(KeyEvent(key: .enter)),
                .paste("/quit"),
                .key(KeyEvent(key: .enter)),
            ]),
            runtime: runtime,
            renderer: RecordingInteractiveRenderer(),
            output: output
        )

        let result = try await controller.run(.init(prompt: "", mode: .inline))

        #expect(result.lifecycle == .shutdown)
        // Neither command reaches the model.
        #expect(await runtime.requests.isEmpty)
        #expect(result.submittedPrompts.isEmpty)
        // `/help` is a modal now, not a transcript dump, so it reaches the
        // renderer as an overlay request rather than a notice.
        let overlays = await output.events.compactMap { event -> OpenGrokPagerOverlayRequest? in
            if case .overlay(let request) = event { return request }
            return nil
        }
        #expect(overlays == [.help])
        #expect(OpenGrokPagerInteractiveController.helpText.contains("/clear"))
    }

    /// The controller does not own the model catalog, so it cannot tell a
    /// unique selector from an ambiguous one. Its whole job is to hand the
    /// typed argument to the renderer intact; resolution happens there.
    @Test("/model carries its typed selector through to the overlay request")
    func modelSelectorReachesTheOverlayRequest() async throws {
        let overlays = try await modelOverlayRequests(for: [
            // Bare: no selector, the picker opens.
            "/model",
            // Whitespace-only arguments are the bare form too.
            "/model   ",
            "/model codex:gpt-5.6-sol",
            // A display name with a space survives the parser's tokenise and
            // this side's rejoin — otherwise `Grok 4.5` would arrive as `Grok`.
            "/model Grok 4.5",
            // Quoting is the parser's business; the selector comes out unquoted.
            #"/model "grok 4""#,
        ])

        #expect(overlays == [
            .modelPicker(query: nil),
            .modelPicker(query: nil),
            .modelPicker(query: "codex:gpt-5.6-sol"),
            .modelPicker(query: "Grok 4.5"),
            .modelPicker(query: "grok 4"),
        ])
    }

    /// Drive `commands` through the real input path and collect the overlay
    /// requests, one per command, in order.
    private func modelOverlayRequests(
        for commands: [String]
    ) async throws -> [OpenGrokPagerOverlayRequest] {
        let output = RecordingInteractiveOutput()
        var events: [InputEvent] = []
        for command in commands {
            events.append(.paste(command))
            events.append(.key(KeyEvent(key: .enter)))
        }
        events.append(.paste("/quit"))
        events.append(.key(KeyEvent(key: .enter)))
        let controller = OpenGrokPagerInteractiveController(
            input: makeInputStream(events),
            runtime: TestInteractiveRuntime(sessions: []),
            renderer: RecordingInteractiveRenderer(),
            output: output
        )
        _ = try await controller.run(.init(prompt: "", mode: .inline))
        return await output.events.compactMap { event in
            if case .overlay(let request) = event { return request }
            return nil
        }
    }

    @Test("input EOF restores the frontend without creating a session")
    func eofCleansUpWithoutSession() async throws {
        let runtime = TestInteractiveRuntime(sessions: [])
        let renderer = RecordingInteractiveRenderer()
        let output = RecordingInteractiveOutput()
        let controller = OpenGrokPagerInteractiveController(
            input: makeInputStream([]),
            runtime: runtime,
            renderer: renderer,
            output: output
        )

        let result = try await controller.run(.init(prompt: "", mode: .inline))

        #expect(result.lifecycle == .eof)
        #expect(result.submittedPrompts.isEmpty)
        #expect(result.completedTurnCount == 0)
        #expect(result.terminalRestored)
        let requests = await runtime.requests
        #expect(requests.isEmpty)
        #expect(await renderer.beginCount == 1)
        #expect(await renderer.restoreCount == 1)
        let events = await output.events
        #expect(events.contains(.eof))
    }

    @Test("resize reaches renderer during editing and active turns")
    func resizeReachesRenderer() async throws {
        let editingSize = TerminalSize(width: 100, height: 40)
        let runningSize = TerminalSize(width: 70, height: 20)
        let session = TestInteractiveSession(sessionID: "resize-session")
        let runtime = TestInteractiveRuntime(sessions: [session])
        let renderer = RecordingInteractiveRenderer()
        let output = RecordingInteractiveOutput()
        let input = makeInputStream([
            .resize(editingSize),
            .paste("wait"),
            .key(KeyEvent(key: .enter)),
            .resize(runningSize),
        ])
        let controller = OpenGrokPagerInteractiveController(
            input: input,
            runtime: runtime,
            renderer: renderer,
            output: output
        )

        let result = try await controller.run(.init(prompt: "", mode: .inline))

        #expect(result.lifecycle == .eof)
        #expect(await renderer.sizes == [editingSize, runningSize])
        #expect(await session.cancelCount == 1)
        #expect(await session.closeCount == 1)
        #expect(await renderer.restoreCount == 1)
    }
}

private actor BashCommandCapture {
    private(set) var commands: [String] = []

    func record(_ command: String) {
        commands.append(command)
    }
}

/// Poll `condition` until it holds or the deadline passes.
///
/// Every wait in the queue suite goes through here rather than through a
/// continuation the controller is expected to resume. A missed event then fails
/// one assertion instead of parking the whole test binary forever — these tests
/// drive a controller over input streams that deliberately never end, so an
/// unbounded await is a suite-wide hang waiting to happen.
private func waitUntil(
    seconds: Double = 10,
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

/// Await a controller run with a deadline, cancelling it if it overruns.
private func runResult(
    of task: Task<OpenGrokPagerInteractiveResult, Error>,
    seconds: Double = 10
) async -> OpenGrokPagerInteractiveResult? {
    let watchdog = Task {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        task.cancel()
    }
    defer { watchdog.cancel() }
    return try? await task.value
}

@Suite("Queued prompts")
struct OpenGrokPagerPromptQueueTests {
    @Test("Enter during a turn queues follow-ups that drain in order")
    func queuesAndDrainsInOrder() async throws {
        let first = TestInteractiveSession(sessionID: "q1")
        let second = TestInteractiveSession(sessionID: "q2")
        await second.emit(.completed(.init(sessionID: "q2")))
        let third = TestInteractiveSession(sessionID: "q3")
        await third.emit(.completed(.init(sessionID: "q3")))

        let runtime = TestInteractiveRuntime(sessions: [first, second, third])
        let renderer = RecordingInteractiveRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: makeOpenInputStream([
                .paste("alpha"),
                .key(KeyEvent(key: .enter)),
                .paste("beta"),
                .key(KeyEvent(key: .enter)),
                .paste("gamma"),
                .key(KeyEvent(key: .enter)),
            ]),
            runtime: runtime,
            renderer: renderer,
            output: RecordingInteractiveOutput()
        )

        let task = Task { try await controller.run(.init(prompt: "", mode: .inline)) }
        // Both follow-ups are queued behind the still-running first turn.
        #expect(await waitUntil { await renderer.queueCounts.contains(2) })
        #expect(await runtime.requests.map(\.prompt) == ["alpha"])
        await first.finish(sessionID: "q1")

        // Once the queue has drained, nothing is left to run.
        #expect(await waitUntil { await runtime.requests.count == 3 })
        await controller.shutdown()
        let result = await runResult(of: task)

        #expect(result?.submittedPrompts == ["alpha", "beta", "gamma"])
        #expect(await runtime.requests.map(\.prompt) == ["alpha", "beta", "gamma"])
    }

    @Test("cancelling a turn keeps the queue, quitting discards it")
    func cancelKeepsQueueAndQuitClearsIt() async throws {
        let running = TestInteractiveSession(sessionID: "keep")
        let runtime = TestInteractiveRuntime(sessions: [running])
        let renderer = RecordingInteractiveRenderer()
        let output = RecordingInteractiveOutput()
        let controller = OpenGrokPagerInteractiveController(
            input: makeOpenInputStream([
                .paste("alpha"),
                .key(KeyEvent(key: .enter)),
                .paste("beta"),
                .key(KeyEvent(key: .enter)),
                .key(KeyEvent(key: .char("c"), modifiers: [.control], character: "c")),
                .paste("/quit"),
                .key(KeyEvent(key: .enter)),
            ]),
            runtime: runtime,
            renderer: renderer,
            output: output
        )

        let task = Task { try await controller.run(.init(prompt: "", mode: .inline)) }
        let result = await runResult(of: task)

        #expect(result?.lifecycle == .shutdown)
        // The cancel returned to the composer without running the follow-up,
        // and never handed it to the runtime.
        #expect(await runtime.requests.map(\.prompt) == ["alpha"])
        #expect(await renderer.events.contains(.turnCancelled))
        // Quitting is what finally discards it, and says so.
        let notices = await output.notices
        #expect(notices.contains { $0.contains("discarded 1 queued prompt") })
    }

    @Test("Enter on an empty composer force-sends the head of the queue")
    func bareEnterForceSendsQueuedPrompt() async throws {
        let running = TestInteractiveSession(sessionID: "slow")
        let queued = TestInteractiveSession(sessionID: "next")
        await queued.emit(.completed(.init(sessionID: "next")))
        let runtime = TestInteractiveRuntime(sessions: [running, queued])
        let renderer = RecordingInteractiveRenderer()
        let output = RecordingInteractiveOutput()
        let controller = OpenGrokPagerInteractiveController(
            input: makeOpenInputStream([
                .paste("alpha"),
                .key(KeyEvent(key: .enter)),
                .paste("beta"),
                .key(KeyEvent(key: .enter)),
                // Composer is empty again — this Enter sends the follow-up now.
                .key(KeyEvent(key: .enter)),
            ]),
            runtime: runtime,
            renderer: renderer,
            output: output
        )

        let task = Task { try await controller.run(.init(prompt: "", mode: .inline)) }
        #expect(await waitUntil { await runtime.requests.count == 2 })
        await controller.shutdown()
        let result = await runResult(of: task)

        #expect(result?.submittedPrompts == ["alpha", "beta"])
        #expect(await running.cancelCount >= 1)
        #expect(await output.notices.contains { $0.contains("sending the queued prompt now") })
    }

    @Test("input EOF during a turn discards the queue")
    func eofDiscardsQueue() async throws {
        let running = TestInteractiveSession(sessionID: "eof")
        let runtime = TestInteractiveRuntime(sessions: [running])
        let output = RecordingInteractiveOutput()
        let controller = OpenGrokPagerInteractiveController(
            input: makeInputStream([
                .paste("alpha"),
                .key(KeyEvent(key: .enter)),
                .paste("beta"),
                .key(KeyEvent(key: .enter)),
                .key(KeyEvent(key: .char("d"), modifiers: [.control], character: "d")),
            ]),
            runtime: runtime,
            renderer: RecordingInteractiveRenderer(),
            output: output
        )

        let task = Task { try await controller.run(.init(prompt: "", mode: .inline)) }
        let result = await runResult(of: task)

        #expect(result?.lifecycle == .eof)
        #expect(await runtime.requests.map(\.prompt) == ["alpha"])
        #expect(await output.notices.contains { $0.contains("discarded 1 queued prompt") })
    }

    @Test("the queued count reaches the renderer as prompts arrive and drain")
    func publishesQueueCount() async throws {
        let running = TestInteractiveSession(sessionID: "count")
        let runtime = TestInteractiveRuntime(sessions: [running])
        let renderer = RecordingInteractiveRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: makeOpenInputStream([
                .paste("alpha"),
                .key(KeyEvent(key: .enter)),
                .paste("beta"),
                .key(KeyEvent(key: .enter)),
                .paste("gamma"),
                .key(KeyEvent(key: .enter)),
            ]),
            runtime: runtime,
            renderer: renderer,
            output: RecordingInteractiveOutput()
        )

        let task = Task { try await controller.run(.init(prompt: "", mode: .inline)) }
        #expect(await waitUntil { await renderer.queueCounts.contains(2) })
        await controller.shutdown()
        _ = await runResult(of: task)

        let counts = await renderer.queueCounts
        // 1 on the idle submit, 0 as it is dequeued, then 1 and 2 as the
        // follow-ups land behind the running turn.
        #expect(counts.prefix(4) == [1, 0, 1, 2])
    }
}

private actor TestInteractiveSession: OpenGrokPagerSessionAdapter {
    nonisolated let sessionID: String?
    nonisolated let events: AsyncThrowingStream<OpenGrokPagerEvent, Error>

    private let continuation: AsyncThrowingStream<OpenGrokPagerEvent, Error>.Continuation
    private(set) var cancelCount = 0
    private(set) var closeCount = 0

    init(sessionID: String?) {
        self.sessionID = sessionID
        var continuation: AsyncThrowingStream<OpenGrokPagerEvent, Error>.Continuation?
        self.events = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation!
    }

    func emit(_ event: OpenGrokPagerEvent) {
        continuation.yield(event)
    }

    /// Complete the turn on demand, so a test can hold a turn open while it
    /// types follow-ups into the queue.
    func finish(sessionID: String) {
        continuation.yield(.completed(.init(sessionID: sessionID)))
        continuation.finish()
    }

    /// Fail the turn on demand — the shape a provider error arrives in
    /// (`LivePagerSession` finishes its stream throwing on `.turnFailed`).
    func fail(_ message: String) {
        continuation.finish(throwing: TestInteractiveError.turnExploded(message))
    }

    func cancel() {
        cancelCount += 1
        continuation.yield(.cancelled)
        continuation.finish()
    }

    func close() {
        closeCount += 1
        continuation.finish()
    }
}

private actor TestInteractiveRuntime: OpenGrokPagerRuntimeAdapter {
    private var firstRequestWaiters: [CheckedContinuation<Void, Never>] = []

    /// Suspends until `makeSession` has been called at least once.
    func waitForFirstRequest() async {
        guard requests.isEmpty else { return }
        await withCheckedContinuation { firstRequestWaiters.append($0) }
    }

    private func signalFirstRequest() {
        let waiters = firstRequestWaiters
        firstRequestWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private var sessions: [TestInteractiveSession]
    private(set) var requests: [OpenGrokPagerRequest] = []

    init(sessions: [TestInteractiveSession]) {
        self.sessions = sessions
    }

    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        requests.append(request)
        signalFirstRequest()
        guard !sessions.isEmpty else { throw TestInteractiveError.noSession }
        return sessions.removeFirst()
    }
}

private actor RecordingInteractiveRenderer: OpenGrokPagerInteractiveRenderAdapter {
    private(set) var events: [OpenGrokPagerInteractiveEvent] = []

    var promptStates: [OpenGrokPagerInteractivePromptState] {
        events.compactMap { event in
            if case .promptChanged(let state) = event { return state }
            return nil
        }
    }

    var viewportCommands: [OpenGrokPagerViewportCommand] {
        events.compactMap { event in
            if case .viewport(let command) = event { return command }
            return nil
        }
    }

    var queueCounts: [Int] {
        events.compactMap { event in
            if case .queueChanged(let count) = event { return count }
            return nil
        }
    }

    var turnFailures: [String] {
        events.compactMap { event in
            if case .turnFailed(let message) = event { return message }
            return nil
        }
    }

    private(set) var sizes: [TerminalSize] = []
    private(set) var beginCount = 0
    private(set) var restoreCount = 0

    func begin() {
        beginCount += 1
    }

    func render(_ event: OpenGrokPagerInteractiveEvent) {
        events.append(event)
    }

    func resize(to size: TerminalSize) {
        sizes.append(size)
    }

    func restoreTerminal() {
        restoreCount += 1
    }
}

private actor RecordingInteractiveOutput: OpenGrokPagerInteractiveOutputAdapter {
    private(set) var events: [OpenGrokPagerInteractiveEvent] = []

    var notices: [String] {
        events.compactMap { event in
            if case .notice(let message) = event { return message }
            return nil
        }
    }

    func forward(_ event: OpenGrokPagerInteractiveEvent) {
        events.append(event)
    }
}

/// Yields `events` and then stays open, so the run ends only when something
/// other than input exhaustion terminates it.
private func makeOpenInputStream(_ events: [InputEvent]) -> AsyncStream<InputEvent> {
    AsyncStream { continuation in
        for event in events {
            continuation.yield(event)
        }
    }
}

private func makeInputStream(_ events: [InputEvent]) -> AsyncStream<InputEvent> {
    AsyncStream { continuation in
        for event in events {
            continuation.yield(event)
        }
        continuation.finish()
    }
}

private enum TestInteractiveError: Error, Sendable {
    case noSession
    case turnExploded(String)
}
