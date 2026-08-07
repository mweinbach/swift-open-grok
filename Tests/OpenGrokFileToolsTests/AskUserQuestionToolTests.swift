// AskUserQuestionToolTests.swift
//
// The `ask_user_question` handler through the live registry seam: real
// `FileToolSession.makeResources` → finalize with the handler installed →
// `prepareAndCall`, with a scripted `UserQuestionPresenting` standing in for
// the pager. Result strings are pinned against the upstream captures in
// `ask_user_question/format.rs` — drift there is drift the model sees.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime
import OpenGrokToolTypes
import OpenGrokWorkspace
import OpenGrokWorkspaceTypes
import Testing
@testable import OpenGrokFileTools

// MARK: - Fixtures

private actor ScriptedQuestionPresenter: UserQuestionPresenting {
    private let outcome: UserQuestionPromptOutcome
    private let presentable: Bool
    private(set) var askedQuestions: [[UserQuestion]] = []
    private(set) var askedToolCallIDs: [String] = []

    init(outcome: UserQuestionPromptOutcome, presentable: Bool = true) {
        self.outcome = outcome
        self.presentable = presentable
    }

    var canPresent: Bool { presentable }

    func ask(questions: [UserQuestion], toolCallID: String) async -> UserQuestionPromptOutcome {
        askedQuestions.append(questions)
        askedToolCallIDs.append(toolCallID)
        return outcome
    }

    func recordedQuestions() -> [[UserQuestion]] { askedQuestions }
}

@Suite("ask_user_question tool (live seam)")
struct AskUserQuestionToolTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-askuser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Build a live-seam toolset with the ask handler registered the way
    /// `LiveComposition` registers it. `presenter: nil` models the headless
    /// composition, where the resource slot stays empty.
    private func buildSet(
        at root: URL,
        presenter: (any UserQuestionPresenting)?
    ) throws -> FinalizedToolset {
        let resources = FileToolSession.makeResources(
            workspaceRoot: root.path,
            sessionId: "ask-user-test",
            agentId: "main",
            policy: .allowAll,
            planMode: PlanModeTracker(
                state: .inactive,
                planFilePath: ".opengrok/plan.md",
                sessionDirectory: root.path
            )
        )
        resources.userQuestions = presenter
        var builder = FileToolPack.makeBuilder()
        builder.setHandler(
            qualifiedId: BuiltinToolCatalog.askUserQuestionQualifiedId,
            handler: AskUserQuestionToolHandler()
        )
        var toolConfig = toolServerConfig(for: .build, catalogKinds: builder.knownToolKinds())
        toolConfig.tools.append(ToolConfig.fromId(
            BuiltinToolCatalog.askUserQuestionQualifiedId,
            kind: BuiltinToolCatalog.askUserQuestionToolKinds[
                BuiltinToolCatalog.askUserQuestionQualifiedId
            ]
        ))
        switch builder.finalize(
            config: toolConfig,
            resources: resources,
            options: FinalizeOptions(capabilityMode: .readWrite)
        ) {
        case .success(let set): return set
        case .failure(let errors):
            throw ToolBridgeError.finalizeFailed(errors.errors)
        }
    }

    private func message(_ result: Result<TypedToolOutput, ToolError>) throws -> String {
        switch result {
        case .success(let output):
            guard case .object(let object) = output.value,
                  case .string(let message)? = object["message"]
            else {
                throw ToolError.execution(
                    toolId: try ToolId("ask_user_question"),
                    detail: "output value carried no message: \(output.value)"
                )
            }
            return message
        case .failure(let error):
            throw error
        }
    }

    private func questionArgs(_ question: String, labels: [String], multiSelect: Bool? = nil) -> JSONValue {
        var body: [String: JSONValue] = [
            "question": .string(question),
            "options": .array(labels.map { label in
                .object([
                    "label": .string(label),
                    "description": .string("Description for \(label)"),
                ])
            }),
        ]
        if let multiSelect {
            body["multi_select"] = .bool(multiSelect)
        }
        return .object(body)
    }

    // MARK: Args parsing

    @Test("malformed args are rejected with invalid_arguments")
    func malformedArgsRejected() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = try buildSet(at: dir, presenter: ScriptedQuestionPresenter(outcome: .cancelled))

        let notAnArray = await set.prepareAndCall(
            clientName: "ask_user_question",
            args: .object(["questions": .string("nope")])
        )
        guard case .failure(let arrayError) = notAnArray else {
            Issue.record("expected `questions` type error, got \(notAnArray)")
            return
        }
        #expect(arrayError.kind == .invalidArguments)
        #expect(arrayError.detail.contains("`questions` must be an array"))

        let missingLabel = await set.prepareAndCall(
            clientName: "ask_user_question",
            args: .object(["questions": .array([
                .object([
                    "question": .string("Q?"),
                    "options": .array([.object(["description": .string("no label")])]),
                ])
            ])])
        )
        guard case .failure(let labelError) = missingLabel else {
            Issue.record("expected missing-label error, got \(missingLabel)")
            return
        }
        #expect(labelError.kind == .invalidArguments)
        #expect(labelError.detail.contains("options[0]"))
    }

    @Test("duplicate question text is rejected with upstream's error copy")
    func duplicateQuestionTextRejected() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = try buildSet(at: dir, presenter: ScriptedQuestionPresenter(outcome: .cancelled))

        let result = await set.prepareAndCall(
            clientName: "ask_user_question",
            args: .object(["questions": .array([
                questionArgs("Same question?", labels: ["A"]),
                questionArgs("Same question?", labels: ["B"]),
            ])])
        )
        guard case .failure(let error) = result else {
            Issue.record("expected duplicate-text rejection, got \(result)")
            return
        }
        // `mod.rs:366-377`.
        #expect(error.detail.contains("Duplicate question text: \"Same question?\""))
    }

    @Test("zero questions is a soft success, not an error")
    func emptyQuestionsSoftSuccess() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let presenter = ScriptedQuestionPresenter(outcome: .cancelled)
        let set = try buildSet(at: dir, presenter: presenter)

        let result = await set.prepareAndCall(
            clientName: "ask_user_question",
            args: .object(["questions": .array([])])
        )
        #expect(try message(result) == "No questions provided. Continue with the task.")
        // Nothing reached the UI (`mod.rs:359-364` returns before sending).
        #expect(await presenter.recordedQuestions().isEmpty)
    }

    @Test("multi_select is honored in both spellings and reaches the presenter")
    func multiSelectSpellings() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let presenter = ScriptedQuestionPresenter(outcome: .cancelled)
        let set = try buildSet(at: dir, presenter: presenter)

        let snake = await set.prepareAndCall(
            clientName: "ask_user_question",
            args: .object(["questions": .array([
                questionArgs("Pick any?", labels: ["A"], multiSelect: true)
            ])])
        )
        _ = try message(snake)
        let camel = await set.prepareAndCall(
            clientName: "ask_user_question",
            args: .object(["questions": .array([
                .object([
                    "question": .string("Pick one?"),
                    "options": .array([.object([
                        "label": .string("A"),
                        "description": .string("d"),
                    ])]),
                    "multiSelect": .bool(true),
                ])
            ])])
        )
        _ = try message(camel)
        let recorded = await presenter.recordedQuestions()
        #expect(recorded.count == 2)
        #expect(recorded.first?.first?.multiSelect == true)
        #expect(recorded.last?.first?.multiSelect == true)
    }

    // MARK: Result formatting

    @Test("an accepted answer formats exactly as upstream's capture")
    func acceptedFormatting() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let presenter = ScriptedQuestionPresenter(outcome: .answered([
            AnsweredUserQuestion(question: "Which database?", label: "Redis (Recommended)")
        ]))
        let set = try buildSet(at: dir, presenter: presenter)

        let result = await set.prepareAndCall(
            clientName: "ask_user_question",
            args: .object(["questions": .array([
                questionArgs("Which database?", labels: ["Redis (Recommended)", "Memcached"])
            ])])
        )
        // `format.rs` test `format_accepted_single_no_annotations`.
        #expect(try message(result) == "User has answered your questions: \"Which database?\"=\"Redis (Recommended)\". You can now continue with the user's answers in mind.")
    }

    @Test("multi-select labels join with a comma and freeform notes append")
    func multiSelectAndNotesFormatting() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let presenter = ScriptedQuestionPresenter(outcome: .answered([
            AnsweredUserQuestion(question: "Which features?", label: "Auth", extraLabels: ["Logging"]),
            AnsweredUserQuestion(question: "Which database?", label: "Other", notes: "I want to use DynamoDB"),
        ]))
        let set = try buildSet(at: dir, presenter: presenter)

        let result = await set.prepareAndCall(
            clientName: "ask_user_question",
            args: .object(["questions": .array([
                questionArgs("Which features?", labels: ["Auth", "Logging"], multiSelect: true),
                questionArgs("Which database?", labels: ["Redis"]),
            ])])
        )
        // `format.rs` tests `format_accepted_multi_select` and
        // `format_accepted_freeform_only`, combined.
        #expect(try message(result) == "User has answered your questions: \"Which features?\"=\"Auth, Logging\", \"Which database?\"=\"Other\" user notes: I want to use DynamoDB. You can now continue with the user's answers in mind.")
    }

    @Test("a single-select answer carries the selected option's preview")
    func previewFormatting() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let presenter = ScriptedQuestionPresenter(outcome: .answered([
            AnsweredUserQuestion(question: "Which layout?", label: "Grid")
        ]))
        let set = try buildSet(at: dir, presenter: presenter)

        let result = await set.prepareAndCall(
            clientName: "ask_user_question",
            args: .object(["questions": .array([
                .object([
                    "question": .string("Which layout?"),
                    "options": .array([
                        .object([
                            "label": .string("Grid"),
                            "description": .string("CSS grid"),
                            "preview": .string("<div class=\"grid\">...</div>"),
                        ]),
                        .object([
                            "label": .string("Flex"),
                            "description": .string("Flexbox"),
                        ]),
                    ]),
                ])
            ])])
        )
        // `format.rs` test `format_accepted_preview_and_notes`, notes-free.
        #expect(try message(result) == "User has answered your questions: \"Which layout?\"=\"Grid\" selected preview:\n<div class=\"grid\">...</div>. You can now continue with the user's answers in mind.")
    }

    @Test("cancel returns upstream's cancel text verbatim")
    func cancelledFormatting() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = try buildSet(at: dir, presenter: ScriptedQuestionPresenter(outcome: .cancelled))

        let result = await set.prepareAndCall(
            clientName: "ask_user_question",
            args: .object(["questions": .array([
                questionArgs("Q?", labels: ["A"])
            ])])
        )
        // `format.rs:22` — cancel is a user decision, not a failure.
        #expect(try message(result) == "User declined to answer the questions. Continue with the task using your best judgment, or ask different questions.")
    }

    // MARK: Fail-closed

    @Test("no question surface fails closed with an error, never a fabricated cancel")
    func noSurfaceFailsClosed() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let set = try buildSet(at: dir, presenter: nil)

        let result = await set.prepareAndCall(
            clientName: "ask_user_question",
            args: .object(["questions": .array([
                questionArgs("Q?", labels: ["A"])
            ])])
        )
        guard case .failure(let error) = result else {
            Issue.record("expected fail-closed error with no surface, got \(result)")
            return
        }
        #expect(error.detail.contains("no interactive question surface"))
    }

    @Test("a surface whose presenter never attached also fails closed")
    func detachedPresenterFailsClosed() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let presenter = ScriptedQuestionPresenter(outcome: .cancelled, presentable: false)
        let set = try buildSet(at: dir, presenter: presenter)

        let result = await set.prepareAndCall(
            clientName: "ask_user_question",
            args: .object(["questions": .array([
                questionArgs("Q?", labels: ["A"])
            ])])
        )
        guard case .failure(let error) = result else {
            Issue.record("expected fail-closed error with a detached presenter, got \(result)")
            return
        }
        #expect(error.detail.contains("no interactive question surface"))
        #expect(await presenter.recordedQuestions().isEmpty)
    }
}
