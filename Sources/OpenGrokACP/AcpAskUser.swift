// AcpAskUser.swift
//
// Open Grok reverse-request wire types for `x.ai/ask_user_question`.
// Ported from `xai-grok-tools` ask_user_question types so ACP peers can
// round-trip ordered single-select / multi-select questionnaires.

import Foundation
import OpenGrokShared

// MARK: - Method name

public enum OpenGrokACPExtMethods {
    /// Blocking reverse request from agent → client for interactive Q&A.
    public static let askUserQuestion = "x.ai/ask_user_question"
}

// MARK: - Question model

/// A single option within a question.
public struct AskUserQuestionOption: Hashable, Sendable, Codable {
    /// Option text shown to the user. A few words at most.
    public var label: String
    /// What picking this option means or implies.
    public var description: String
    /// Optional content shown while the option is focused (single-select only).
    public var preview: String?
    /// Opaque id; hidden from the model. Open Grok callers leave it nil.
    public var id: String?

    public init(
        label: String,
        description: String,
        preview: String? = nil,
        id: String? = nil
    ) {
        self.label = label
        self.description = description
        self.preview = preview
        self.id = id
    }

    private enum CodingKeys: String, CodingKey {
        case label, description, preview, id
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        description = try container.decode(String.self, forKey: .description)
        preview = try container.decodeIfPresent(String.self, forKey: .preview)
        id = try container.decodeIfPresent(String.self, forKey: .id)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(label, forKey: .label)
        try container.encode(description, forKey: .description)
        try container.encodeIfPresent(preview, forKey: .preview)
        try container.encodeIfPresent(id, forKey: .id)
    }

    /// Append the canonical "(Recommended)" suffix used by the Ask tool
    /// prompt when an option is recommended. Idempotent if already present.
    public func withRecommendedLabel() -> AskUserQuestionOption {
        if label.contains("(Recommended)") {
            return self
        }
        var copy = self
        copy.label = "\(label) (Recommended)"
        return copy
    }
}

/// A single question with its options.
public struct AskUserQuestion: Hashable, Sendable, Codable {
    /// The question to ask, phrased as a full question.
    public var question: String
    /// The choices for this question.
    public var options: [AskUserQuestionOption]
    /// Let the user pick more than one option (default false).
    public var multiSelect: Bool?
    /// Opaque id; hidden from the model.
    public var id: String?

    public init(
        question: String,
        options: [AskUserQuestionOption],
        multiSelect: Bool? = nil,
        id: String? = nil
    ) {
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
        self.id = id
    }

    private enum CodingKeys: String, CodingKey {
        case question, options, multiSelect, multi_select, id
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        question = try container.decode(String.self, forKey: .question)
        options = try container.decode([AskUserQuestionOption].self, forKey: .options)
        // Accept both camelCase and snake_case wire spellings.
        if let value = try container.decodeIfPresent(Bool.self, forKey: .multiSelect) {
            multiSelect = value
        } else {
            multiSelect = try container.decodeIfPresent(Bool.self, forKey: .multi_select)
        }
        id = try container.decodeIfPresent(String.self, forKey: .id)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(question, forKey: .question)
        try container.encode(options, forKey: .options)
        try container.encodeIfPresent(multiSelect, forKey: .multiSelect)
        try container.encodeIfPresent(id, forKey: .id)
    }

    public var isMultiSelect: Bool {
        multiSelect ?? false
    }
}

// MARK: - Ext request / response

/// Mode context for the question UI.
public enum AskUserQuestionMode: String, Hashable, Sendable, Codable {
    /// Normal mode. Client shows only Accept and Cancel.
    case `default`
    /// Plan mode. Client shows Accept, Cancel, Chat about this, Skip interview.
    case plan
}

/// Annotation on a single question's answer.
public struct AskUserQuestionAnnotation: Hashable, Sendable, Codable {
    /// Verbatim `Option.preview` of the selected option (single-select only).
    public var preview: String?
    /// Free-text the user typed in the freeform / Other input.
    public var notes: String?

    public init(preview: String? = nil, notes: String? = nil) {
        self.preview = preview
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case preview, notes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preview = try container.decodeIfPresent(String.self, forKey: .preview)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(preview, forKey: .preview)
        try container.encodeIfPresent(notes, forKey: .notes)
    }
}

/// ACP `ext_method` request payload (agent → client).
///
/// Wire form: camelCase keys.
public struct AskUserQuestionExtRequest: Hashable, Sendable, Codable {
    public var sessionId: String
    public var toolCallId: String
    public var questions: [AskUserQuestion]
    public var mode: AskUserQuestionMode

    public init(
        sessionId: String,
        toolCallId: String,
        questions: [AskUserQuestion],
        mode: AskUserQuestionMode = .default
    ) {
        self.sessionId = sessionId
        self.toolCallId = toolCallId
        self.questions = questions
        self.mode = mode
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, toolCallId, questions, mode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        toolCallId = try container.decode(String.self, forKey: .toolCallId)
        questions = try container.decodeIfPresent([AskUserQuestion].self, forKey: .questions) ?? []
        mode = try container.decodeIfPresent(AskUserQuestionMode.self, forKey: .mode) ?? .default
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(toolCallId, forKey: .toolCallId)
        try container.encode(questions, forKey: .questions)
        try container.encode(mode, forKey: .mode)
    }
}

extension AskUserQuestionExtRequest: AcpRequest {
    public typealias Response = AskUserQuestionExtResponse
    public var methodName: String { OpenGrokACPExtMethods.askUserQuestion }

    /// Wrap as a generic extension request for transport layers that
    /// only understand `ExtRequest`.
    public func asExtRequest() throws -> ExtRequest {
        ExtRequest(method: methodName, params: try JSONValue.encode(self))
    }
}

/// One answered question entry, preserving insertion order.
public struct AskUserAnswer: Hashable, Sendable {
    public var question: String
    public var labels: [String]

    public init(question: String, labels: [String]) {
        self.question = question
        self.labels = labels
    }
}

/// ACP `ext_method` response payload (client → agent).
///
/// Internally tagged on `"outcome"` with snake_case variant names.
public enum AskUserQuestionExtResponse: Hashable, Sendable {
    /// User accepted and submitted answers.
    /// Answers preserve insertion order (question → selected labels).
    case accepted(
        answers: [AskUserAnswer],
        annotations: [String: AskUserQuestionAnnotation]?
    )
    /// User chose "Chat about this" (plan mode only).
    case chatAboutThis(partialAnswers: [String: String])
    /// User chose "Skip interview and plan immediately" (plan mode only).
    case skipInterview(partialAnswers: [String: String])
    /// User cancelled / dismissed. NOT an error.
    case cancelled
}

extension AskUserQuestionExtResponse: Codable {
    private enum CodingKeys: String, CodingKey {
        case outcome
        case answers
        case annotations
        case partialAnswers = "partial_answers"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let outcome = try container.decode(String.self, forKey: .outcome)
        switch outcome {
        case "accepted":
            let raw = try container.decode(JSONValue.self, forKey: .answers)
            let pairs = try Self.decodeOrderedAnswers(raw)
            let answers = pairs.map { AskUserAnswer(question: $0.question, labels: $0.labels) }
            let annotations = try container.decodeIfPresent(
                [String: AskUserQuestionAnnotation].self,
                forKey: .annotations
            )
            self = .accepted(answers: answers, annotations: annotations)
        case "chat_about_this":
            let partial = try container.decodeIfPresent([String: String].self, forKey: .partialAnswers) ?? [:]
            self = .chatAboutThis(partialAnswers: partial)
        case "skip_interview":
            let partial = try container.decodeIfPresent([String: String].self, forKey: .partialAnswers) ?? [:]
            self = .skipInterview(partialAnswers: partial)
        case "cancelled":
            self = .cancelled
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .outcome,
                in: container,
                debugDescription: "Unknown AskUserQuestion outcome: \(outcome)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .accepted(let answers, let annotations):
            try container.encode("accepted", forKey: .outcome)
            // Wire form is a JSON object of question → labels[].
            // Foundation does not guarantee object key order; callers that
            // need order hold the typed `[AskUserAnswer]` array.
            var object: [String: JSONValue] = [:]
            for answer in answers {
                object[answer.question] = .array(answer.labels.map { .string($0) })
            }
            try container.encode(JSONValue.object(object), forKey: .answers)
            try container.encodeIfPresent(annotations, forKey: .annotations)
        case .chatAboutThis(let partial):
            try container.encode("chat_about_this", forKey: .outcome)
            try container.encode(partial, forKey: .partialAnswers)
        case .skipInterview(let partial):
            try container.encode("skip_interview", forKey: .outcome)
            try container.encode(partial, forKey: .partialAnswers)
        case .cancelled:
            try container.encode("cancelled", forKey: .outcome)
        }
    }

    /// Accepts both `"value"` (legacy) and `["value"]` (current) answer forms.
    private static func decodeOrderedAnswers(
        _ value: JSONValue
    ) throws -> [(question: String, labels: [String])] {
        guard case .object(let object) = value else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "answers must be a JSON object"
                )
            )
        }
        // JSONValue.object is a Dictionary — order is not guaranteed by
        // Swift. We still accept the wire and return a stable ordered
        // array sorted by key only as a last resort for unordered sources.
        // Prefer the order of keys as decoded when using JSONSerialization
        // ordered containers — Foundation loses order, so tests that need
        // strict order assert via explicit insertion construction.
        var result: [(question: String, labels: [String])] = []
        for (question, raw) in object {
            switch raw {
            case .string(let s):
                result.append((question, [s]))
            case .array(let arr):
                let labels = arr.compactMap { $0.stringValue }
                result.append((question, labels))
            default:
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: [],
                        debugDescription: "answer for \(question) must be string or array of strings"
                    )
                )
            }
        }
        return result
    }

    /// Convenience: map of question → selected labels (unordered).
    public var answersMap: [String: [String]] {
        switch self {
        case .accepted(let answers, _):
            var map: [String: [String]] = [:]
            for answer in answers {
                map[answer.question] = answer.labels
            }
            return map
        default:
            return [:]
        }
    }
}

// MARK: - Freeform / Other helpers

public enum AskUserQuestionOther {
    /// Canonical freeform-only selection label used when the user types
    /// free text without choosing a listed option.
    public static let label = "Other"
}

extension AskUserQuestionExtResponse {
    /// Build an accepted response for a freeform-only Other answer.
    public static func acceptedOther(
        question: String,
        notes: String
    ) -> AskUserQuestionExtResponse {
        .accepted(
            answers: [AskUserAnswer(question: question, labels: [AskUserQuestionOther.label])],
            annotations: [question: AskUserQuestionAnnotation(notes: notes)]
        )
    }
}
