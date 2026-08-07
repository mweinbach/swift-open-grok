// UserQuestions.swift
//
// The seam between the `ask_user_question` tool handler and whatever surface
// can actually put a question in front of a human.
//
// Upstream the tool reaches its UI through a `UserQuestionSender` resource
// looked up from `SharedResources` (`ask_user_question/mod.rs:379-402`); the
// port's analog is this protocol hanging off `ToolResources`, mirroring how
// `permissionPipeline` reaches tools. The interactive TUI composition installs
// a presenter-backed implementation; every other composition leaves the slot
// `nil`, which is what makes "no one can answer" mean "the tool is not
// advertised" rather than "the tool errors" (see the registration site in
// `LiveComposition.swift`).

import Foundation
import OpenGrokWorkspaceTypes

/// The user's answer to one question, as the tool consumes it.
///
/// `selectedLabels` is non-empty by construction — the initializer takes the
/// first label separately — because upstream's UI cannot confirm a question
/// without at least one selection, and an empty answer would silently format
/// as `"q"=""` in the tool result.
public struct AnsweredUserQuestion: Sendable, Equatable {
    public var question: String
    public var selectedLabels: [String]
    /// Free text from the "Other" row (upstream `annotations[q].notes`).
    public var notes: String?

    public init(question: String, label: String, extraLabels: [String] = [], notes: String? = nil) {
        self.question = question
        self.selectedLabels = [label] + extraLabels
        self.notes = notes
    }
}

/// What became of one questionnaire. Cancel is a normal user decision, not a
/// failure (`format.rs:16-22`); transport-level failure is the tool's own
/// error path, not an outcome the presenter can produce.
public enum UserQuestionPromptOutcome: Sendable, Equatable {
    case answered([AnsweredUserQuestion])
    case cancelled
}

/// A surface that can present a questionnaire and block until the user
/// answers or dismisses it.
public protocol UserQuestionPresenting: Sendable {
    /// Whether a live presenter is attached. The tool checks this before
    /// asking and fails closed when nobody could ever answer — the same
    /// fail-closed role `PagerPermissionCoordinator.hasPresenter` plays for
    /// the mutation gate.
    var canPresent: Bool { get async }

    /// Present `questions` and suspend until the user answers or cancels.
    func ask(questions: [UserQuestion], toolCallID: String) async -> UserQuestionPromptOutcome
}
