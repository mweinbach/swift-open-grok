// LiveUserQuestions.swift
//
// Bridges the `ask_user_question` tool (which speaks the ToolRegistry's
// `UserQuestionPresenting` seam in workspace types) to the pager's
// `PagerQuestionCoordinator` (which speaks render-model types). Mirrors how
// the permission side crosses the same layering: the workspace policy holds a
// prompter that forwards to `PagerPermissionCoordinator` without either layer
// importing the other.

import Foundation
import OpenGrokPagerRender
import OpenGrokToolRegistry
import OpenGrokWorkspaceTypes

struct LiveUserQuestionBroker: UserQuestionPresenting {
    let coordinator: PagerQuestionCoordinator

    /// Fail-closed signal: a coordinator with no presenter is a session where
    /// no one can answer (interactive launch whose renderer never came up),
    /// so the tool must error rather than suspend forever.
    var canPresent: Bool {
        get async { await coordinator.hasPresenter }
    }

    func ask(questions: [UserQuestion], toolCallID: String) async -> UserQuestionPromptOutcome {
        let request = PagerQuestionRequest(
            toolCallID: toolCallID,
            questions: questions.map { question in
                PagerQuestion(
                    text: question.question,
                    options: question.options.map { option in
                        PagerQuestionOption(
                            label: option.label,
                            description: option.description,
                            preview: option.preview
                        )
                    },
                    isMultiSelect: question.multiSelect
                )
            }
        )
        switch await coordinator.answers(for: request) {
        case .answered(let answers):
            return .answered(answers.compactMap { answer in
                // `PagerQuestionAnswer.labels` is non-empty by construction
                // (private setter, first-label initializer); the guard only
                // satisfies the optional without a force-unwrap.
                guard let first = answer.labels.first else { return nil }
                return AnsweredUserQuestion(
                    question: answer.question,
                    label: first,
                    extraLabels: Array(answer.labels.dropFirst()),
                    notes: answer.notes
                )
            })
        case .cancelled:
            return .cancelled
        }
    }
}
