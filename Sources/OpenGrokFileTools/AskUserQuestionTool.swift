// AskUserQuestionTool.swift
//
// Live handler for `ask_user_question`. Upstream reference:
//   * `crates/codegen/xai-grok-tools/src/implementations/grok_build/ask_user_question/mod.rs`
//     — args schema, validation, and the blocking round-trip to the UI.
//   * `.../ask_user_question/format.rs` — the exact model-visible result
//     strings; the formatting below reproduces `format_accepted_tool_result`
//     and `CANCEL_TEXT` byte for byte.
//
// The port's tool and UI share one process, so the upstream mpsc→ACP
// ext-method hop collapses into a `UserQuestionPresenting` resource on
// `ToolResources` — the same seam shape `permissionPipeline` uses. Fail
// closed: with no presenting surface the tool errors (upstream's
// `missing_resource` arm, `mod.rs:397-401`) — but the registration site only
// advertises the tool when a surface exists, so the error arm is defense in
// depth, not the design.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime
import OpenGrokToolTypes
import OpenGrokWorkspaceTypes

/// Tool result when the user cancels / dismisses the question UI. Quoted from
/// `format.rs:22` — cancel is a normal user decision, not a tool failure.
public let askUserQuestionCancelText =
    "User declined to answer the questions. Continue with the task using your best judgment, or ask different questions."

/// ToolHandler for `ask_user_question`.
public struct AskUserQuestionToolHandler: ToolHandler {
    public init() {}

    public func invoke(
        clientName: String,
        args: JSONValue,
        ctx: ToolCallContext,
        resources: ToolResources
    ) async -> Result<TypedToolOutput, ToolError> {
        let parsed: [ParsedQuestion]
        switch parseQuestions(args) {
        case .success(let questions): parsed = questions
        case .failure(let error): return .failure(error)
        }

        // Zero questions is a soft success, not an error (`mod.rs:359-364`).
        guard !parsed.isEmpty else {
            let message = "No questions provided. Continue with the task."
            return .success(output(message: message, status: "questions_empty"))
        }

        // Duplicate question text is rejected (`mod.rs:366-377`): answers are
        // keyed by question text, so a duplicate would silently collapse two
        // answers into one.
        var seen = Set<String>()
        for question in parsed {
            guard seen.insert(question.text).inserted else {
                return .failure(.invalidArguments(
                    "Duplicate question text: \"\(question.text)\""
                ))
            }
        }

        // Fail closed: no surface means *cannot ask*, so error — never a
        // fabricated cancel, which would read as a real user decision.
        // Upstream's `missing_resource` arm (`mod.rs:397-401`).
        guard let presenter = resources.userQuestions, await presenter.canPresent else {
            return .failure(.custom(
                code: "missing_resource",
                detail: "'\(clientName)' has no interactive question surface in this session"
            ))
        }

        let outcome = await presenter.ask(
            questions: parsed.map(\.workspaceQuestion),
            toolCallID: ctx.callId.rawValue
        )
        switch outcome {
        case .answered(let answers):
            let message = formatAcceptedAnswers(answers, questions: parsed)
            return .success(output(message: message, status: "answered"))
        case .cancelled:
            return .success(output(message: askUserQuestionCancelText, status: "cancelled"))
        }
    }

    private func output(message: String, status: String) -> TypedToolOutput {
        TypedToolOutput(
            toolId: askUserQuestionToolId,
            value: .object([
                "status": .string(status),
                "message": .string(message),
            ]),
            modelOutput: [.text(text: message)]
        )
    }
}

// MARK: - Args parsing

/// One parsed question plus the option metadata the formatter needs (preview
/// lives on the option, and the answers only carry labels).
struct ParsedQuestion {
    var text: String
    var options: [UserQuestionOption]
    var isMultiSelect: Bool

    var workspaceQuestion: UserQuestion {
        UserQuestion(question: text, options: options, multiSelect: isMultiSelect)
    }
}

/// Parse the upstream `AskUserQuestionInput` shape (`mod.rs:144-217`) from
/// raw tool arguments. The model-facing schema spells `multi_select`; the
/// legacy/ACP camelCase `multiSelect` is accepted as an alias, matching the
/// serde alias upstream keeps for wire compatibility (`mod.rs:185-189`).
func parseQuestions(_ args: JSONValue) -> Result<[ParsedQuestion], ToolError> {
    guard case .object(let root) = args else {
        return .failure(.invalidArguments("ask_user_question arguments must be a JSON object"))
    }
    guard let rawQuestions = root["questions"] else {
        return .failure(.invalidArguments("missing required field `questions`"))
    }
    guard case .array(let questionValues) = rawQuestions else {
        return .failure(.invalidArguments("`questions` must be an array"))
    }
    var parsed: [ParsedQuestion] = []
    for (index, value) in questionValues.enumerated() {
        guard case .object(let question) = value else {
            return .failure(.invalidArguments("questions[\(index)] must be an object"))
        }
        guard case .string(let text)? = question["question"] else {
            return .failure(.invalidArguments("questions[\(index)] is missing `question`"))
        }
        guard case .array(let optionValues)? = question["options"] else {
            return .failure(.invalidArguments("questions[\(index)] is missing `options`"))
        }
        var options: [UserQuestionOption] = []
        for (optionIndex, optionValue) in optionValues.enumerated() {
            guard case .object(let option) = optionValue,
                  case .string(let label)? = option["label"]
            else {
                return .failure(.invalidArguments(
                    "questions[\(index)].options[\(optionIndex)] is missing `label`"
                ))
            }
            let description: String
            if case .string(let value)? = option["description"] {
                description = value
            } else {
                description = ""
            }
            var preview: String?
            if case .string(let value)? = option["preview"] {
                preview = value
            }
            options.append(UserQuestionOption(
                label: label,
                description: description,
                preview: preview
            ))
        }
        let multiSelect: Bool
        switch (question["multi_select"], question["multiSelect"]) {
        case (.bool(let value)?, _): multiSelect = value
        case (_, .bool(let value)?): multiSelect = value
        default: multiSelect = false
        }
        parsed.append(ParsedQuestion(
            text: text,
            options: options,
            isMultiSelect: multiSelect
        ))
    }
    return .success(parsed)
}

// MARK: - Result formatting

/// `format_accepted_tool_result` (`format.rs:43-72`), with the preview
/// annotation resolved here instead of arriving from the UI: upstream's pager
/// copies the selected option's preview into `annotations[q].preview`
/// (`question_view.rs:924-936`, single-select only); the port resolves it
/// from the same parsed questions, so the model-visible string is identical.
func formatAcceptedAnswers(
    _ answers: [AnsweredUserQuestion],
    questions: [ParsedQuestion]
) -> String {
    let questionsByText = Dictionary(
        questions.map { ($0.text, $0) },
        uniquingKeysWith: { first, _ in first }
    )
    let entries = answers.map { answer -> String in
        var parts = ["\"\(answer.question)\"=\"\(answer.selectedLabels.joined(separator: ", "))\""]
        if let question = questionsByText[answer.question],
           !question.isMultiSelect,
           let selected = answer.selectedLabels.first,
           let preview = question.options.first(where: { $0.label == selected })?.preview {
            parts.append("selected preview:\n\(preview)")
        }
        if let notes = answer.notes {
            parts.append("user notes: \(notes)")
        }
        return parts.joined(separator: " ")
    }
    return "User has answered your questions: \(entries.joined(separator: ", ")). "
        + "You can now continue with the user's answers in mind."
}

// MARK: - ToolId

private let askUserQuestionToolId: ToolId = {
    do { return try ToolId("ask_user_question") }
    catch { preconditionFailure("invalid tool id: ask_user_question") }
}()
