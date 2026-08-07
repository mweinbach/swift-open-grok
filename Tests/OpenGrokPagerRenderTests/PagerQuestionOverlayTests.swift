// PagerQuestionOverlayTests.swift
//
// The question bottom sheet's key grammar and the coordinator that joins it
// to the blocking `ask_user_question` tool call. Key semantics under test are
// upstream's `handle_question_key` (`agent_view/interactions.rs:301-619`)
// reduced to the port's sequential flow — see the divergence note on
// `PagerQuestionPrompt`.

import Foundation
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokPagerRender

// MARK: - Fixtures

private func key(_ code: KeyCode, _ modifiers: KeyModifiers = []) -> KeyEvent {
    KeyEvent(key: code, modifiers: modifiers)
}

private func character(_ value: Character) -> KeyEvent {
    KeyEvent(key: .char(value), character: value)
}

private let ctrlC = KeyEvent(key: .char("c"), modifiers: [.control], character: "c")

private func twoQuestionRequest() -> PagerQuestionRequest {
    PagerQuestionRequest(
        id: "req-1",
        toolCallID: "call-1",
        questions: [
            PagerQuestion(
                text: "Which database?",
                options: [
                    PagerQuestionOption(label: "Redis", description: "In-memory"),
                    PagerQuestionOption(label: "Postgres", description: "Relational"),
                    PagerQuestionOption(label: "SQLite", description: "Embedded"),
                ]
            ),
            PagerQuestion(
                text: "Which features?",
                options: [
                    PagerQuestionOption(label: "Auth", description: ""),
                    PagerQuestionOption(label: "Logging", description: ""),
                    PagerQuestionOption(label: "Cache", description: ""),
                ],
                isMultiSelect: true
            ),
        ]
    )
}

private func questionStack(_ request: PagerQuestionRequest) -> PagerOverlayStack {
    PagerOverlayStack([.question(request)])
}

private func prompt(in stack: PagerOverlayStack) -> PagerQuestionPrompt? {
    guard case .question(let prompt)? = stack.topmost?.content else { return nil }
    return prompt
}

// MARK: - Keyboard grammar

@Suite("Question overlay keys")
struct PagerQuestionOverlayKeyTests {
    @Test("Down/Up and j/k move the cursor over option rows and the Other row")
    func navigation() {
        var stack = questionStack(twoQuestionRequest())
        #expect(stack.handle(key(.down)) == .redraw)
        #expect(prompt(in: stack)?.cursor == 1)
        #expect(stack.handle(character("j")) == .redraw)
        #expect(prompt(in: stack)?.cursor == 2)
        #expect(stack.handle(key(.up)) == .redraw)
        #expect(stack.handle(character("k")) == .redraw)
        #expect(prompt(in: stack)?.cursor == 0)
        // Clamped at the last row (3 options + Other = rows 0...3).
        for _ in 0..<10 { #expect(stack.handle(key(.down)) == .redraw) }
        #expect(prompt(in: stack)?.cursor == 3)
        #expect(prompt(in: stack)?.isOnFreeformRow == true)
    }

    @Test("Enter on a single-select option answers it and advances to the next question")
    func singleSelectEnterAdvances() {
        var stack = questionStack(twoQuestionRequest())
        #expect(prompt(in: stack)?.title == "Question 1 of 2")
        #expect(stack.handle(key(.down)) == .redraw)
        #expect(stack.handle(key(.enter)) == .redraw)
        let advanced = prompt(in: stack)
        #expect(advanced?.title == "Question 2 of 2")
        #expect(advanced?.answeredSoFar == [
            PagerQuestionAnswer(question: "Which database?", label: "Postgres")
        ])
        // The working state resets for the new question.
        #expect(advanced?.cursor == 0)
        #expect(advanced?.selectedOptionIndices.isEmpty == true)
    }

    @Test("multi-select: Space toggles, Enter on the last question submits the toggled set")
    func multiSelectSpaceThenEnterSubmits() {
        var stack = questionStack(twoQuestionRequest())
        #expect(stack.handle(key(.enter)) == .redraw)
        #expect(prompt(in: stack)?.title == "Question 2 of 2")

        #expect(stack.handle(character(" ")) == .redraw)
        #expect(stack.handle(key(.down)) == .redraw)
        #expect(stack.handle(key(.down)) == .redraw)
        #expect(stack.handle(character(" ")) == .redraw)
        #expect(prompt(in: stack)?.selectedOptionIndices == [0, 2])

        let outcome = stack.handle(key(.enter))
        guard case .question("question:req-1", "req-1", .answered(let answers)) = outcome else {
            Issue.record("expected an answered outcome, got \(outcome)")
            return
        }
        #expect(answers == [
            PagerQuestionAnswer(question: "Which database?", label: "Redis"),
            PagerQuestionAnswer(question: "Which features?", label: "Auth", extraLabels: ["Cache"]),
        ])
    }

    @Test("multi-select: Enter with nothing toggled is refused, not an empty answer")
    func emptyMultiSelectRefused() {
        let request = PagerQuestionRequest(
            id: "req-multi",
            toolCallID: "call-multi",
            questions: [
                PagerQuestion(
                    text: "Pick any",
                    options: [
                        PagerQuestionOption(label: "A"),
                        PagerQuestionOption(label: "B"),
                    ],
                    isMultiSelect: true
                )
            ]
        )
        var stack = questionStack(request)
        #expect(stack.handle(key(.enter)) == .redraw)
        // Still showing, nothing answered: the refusal left no partial state.
        let state = prompt(in: stack)
        #expect(state?.answeredSoFar.isEmpty == true)
        #expect(stack.contains(id: "question:req-multi"))

        // Toggling one option unblocks the same Enter.
        #expect(stack.handle(character(" ")) == .redraw)
        let outcome = stack.handle(key(.enter))
        #expect(outcome == .question(
            id: "question:req-multi",
            requestID: "req-multi",
            outcome: .answered([PagerQuestionAnswer(question: "Pick any", label: "A")])
        ))
    }

    @Test("Esc and Ctrl+C cancel the questionnaire instead of dismissing the overlay")
    func cancelKeys() {
        var stack = questionStack(twoQuestionRequest())
        let escaped = stack.handle(key(.escape))
        #expect(escaped == .question(id: "question:req-1", requestID: "req-1", outcome: .cancelled))
        // The overlay stays until the resolver dismisses it — the stack must
        // never drop a sheet whose tool is still awaiting the outcome.
        #expect(stack.contains(id: "question:req-1"))

        var second = questionStack(twoQuestionRequest())
        let interrupted = second.handle(ctrlC)
        #expect(interrupted == .question(id: "question:req-1", requestID: "req-1", outcome: .cancelled))
    }

    @Test("question i of n advances to submit across the whole questionnaire")
    func sequencingAdvancesToSubmit() {
        let request = PagerQuestionRequest(
            id: "req-3",
            toolCallID: "call-3",
            questions: (1...3).map { index in
                PagerQuestion(
                    text: "Q\(index)?",
                    options: [
                        PagerQuestionOption(label: "Yes"),
                        PagerQuestionOption(label: "No"),
                    ]
                )
            }
        )
        var stack = questionStack(request)
        #expect(prompt(in: stack)?.title == "Question 1 of 3")
        #expect(stack.handle(key(.enter)) == .redraw)
        #expect(prompt(in: stack)?.title == "Question 2 of 3")
        #expect(stack.handle(key(.enter)) == .redraw)
        #expect(prompt(in: stack)?.title == "Question 3 of 3")
        let outcome = stack.handle(key(.enter))
        guard case .question(_, _, .answered(let answers)) = outcome else {
            Issue.record("expected the last Enter to submit, got \(outcome)")
            return
        }
        #expect(answers.map(\.question) == ["Q1?", "Q2?", "Q3?"])
        #expect(answers.allSatisfy { $0.labels == ["Yes"] })
    }

    @Test("typing on the Other row records a freeform answer with notes")
    func freeformOtherRow() {
        let request = PagerQuestionRequest(
            id: "req-other",
            toolCallID: "call-other",
            questions: [
                PagerQuestion(
                    text: "Which database?",
                    options: [PagerQuestionOption(label: "Redis")]
                )
            ]
        )
        var stack = questionStack(request)
        #expect(stack.handle(key(.down)) == .redraw)
        #expect(prompt(in: stack)?.isOnFreeformRow == true)
        for letter in "Dynamo" {
            #expect(stack.handle(character(letter)) == .redraw)
        }
        #expect(prompt(in: stack)?.focus == .freeformInput)
        #expect(prompt(in: stack)?.freeformText == "Dynamo")

        let outcome = stack.handle(key(.enter))
        #expect(outcome == .question(
            id: "question:req-other",
            requestID: "req-other",
            outcome: .answered([
                PagerQuestionAnswer(question: "Which database?", label: "Other", notes: "Dynamo")
            ])
        ))
    }

    @Test("Esc leaves freeform input without cancelling; the text survives")
    func escapeLeavesFreeformInput() {
        var stack = questionStack(twoQuestionRequest())
        for _ in 0..<3 { #expect(stack.handle(key(.down)) == .redraw) }
        #expect(stack.handle(character("x")) == .redraw)
        #expect(prompt(in: stack)?.focus == .freeformInput)
        #expect(stack.handle(key(.escape)) == .redraw)
        let state = prompt(in: stack)
        #expect(state?.focus == .navigation)
        #expect(state?.freeformText == "x")
        #expect(state?.freeformSelected == true)
        // The questionnaire is still alive — the Esc was consumed by the
        // editor, not treated as a cancel.
        #expect(stack.contains(id: "question:req-1"))
    }

    @Test("the sheet paints the header, question text, options, and Other row")
    func rendersQuestionSheet() {
        let result = renderPagerFrame(PagerRenderState(
            size: TerminalSize(width: 80, height: 24),
            conversation: [.message(PagerMessage(role: .assistant, text: "behind"))],
            input: PagerComposerState(text: "draft"),
            shortcuts: PagerShortcutsBar(hints: []),
            showScrollbar: false,
            overlays: questionStack(twoQuestionRequest())
        ))
        let text = result.snapshot()
        #expect(text.contains("Question 1 of 2"))
        #expect(text.contains("Which database?"))
        #expect(text.contains("Redis"))
        #expect(text.contains("Other"))
    }
}

// MARK: - Coordinator

private actor QuestionPresenterRecorder {
    private(set) var presented: [PagerQuestionRequest?] = []

    func record(_ request: PagerQuestionRequest?) {
        presented.append(request)
    }

    func snapshot() -> [PagerQuestionRequest?] { presented }
}

@Suite("Question coordinator")
struct PagerQuestionCoordinatorTests {
    private func request(_ id: String) -> PagerQuestionRequest {
        PagerQuestionRequest(
            id: id,
            toolCallID: "call-\(id)",
            questions: [PagerQuestion(text: "Q?", options: [PagerQuestionOption(label: "A")])]
        )
    }

    private func waitUntil(
        _ condition: @escaping () async -> Bool,
        timeout: TimeInterval = 5
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await condition()
    }

    @Test("a waiter resumes with the outcome resolve() delivers")
    func waiterResumesOnResolve() async {
        let coordinator = PagerQuestionCoordinator()
        let answer = PagerQuestionAnswer(question: "Q?", label: "A")
        let waiter = Task { await coordinator.answers(for: request("r1")) }
        #expect(await waitUntil { await coordinator.currentRequest?.id == "r1" })
        await coordinator.resolve(requestID: "r1", outcome: .answered([answer]))
        #expect(await waiter.value == .answered([answer]))
    }

    @Test("a queued second questionnaire presents after the first resolves")
    func queuedRequestPresentsAfterFirst() async {
        let coordinator = PagerQuestionCoordinator()
        let recorder = QuestionPresenterRecorder()
        await coordinator.setPresenter { request in
            await recorder.record(request)
        }
        let first = Task { await coordinator.answers(for: request("r1")) }
        #expect(await waitUntil { await recorder.snapshot().last??.id == "r1" })
        let second = Task { await coordinator.answers(for: request("r2")) }
        #expect(await waitUntil { await coordinator.pendingCount == 2 })

        await coordinator.resolve(requestID: "r1", outcome: .cancelled)
        #expect(await first.value == .cancelled)
        #expect(await waitUntil { await recorder.snapshot().last??.id == "r2" })

        await coordinator.resolve(
            requestID: "r2",
            outcome: .answered([PagerQuestionAnswer(question: "Q?", label: "A")])
        )
        #expect(await second.value == .answered([PagerQuestionAnswer(question: "Q?", label: "A")]))
    }

    @Test("resolveAll cancels every outstanding questionnaire")
    func resolveAllCancels() async {
        let coordinator = PagerQuestionCoordinator()
        let first = Task { await coordinator.answers(for: request("r1")) }
        let second = Task { await coordinator.answers(for: request("r2")) }
        #expect(await waitUntil { await coordinator.pendingCount == 2 })
        await coordinator.resolveAll()
        #expect(await first.value == .cancelled)
        #expect(await second.value == .cancelled)
        #expect(await coordinator.pendingCount == 0)
    }

    @Test("a stale request id cannot resolve the head questionnaire")
    func staleIDIgnored() async {
        let coordinator = PagerQuestionCoordinator()
        let waiter = Task { await coordinator.answers(for: request("r1")) }
        #expect(await waitUntil { await coordinator.pendingCount == 1 })
        await coordinator.resolve(requestID: "not-r1", outcome: .cancelled)
        #expect(await coordinator.pendingCount == 1)
        await coordinator.resolve(requestID: "r1", outcome: .cancelled)
        #expect(await waiter.value == .cancelled)
    }
}
