import Foundation
import OpenGrokShared

public let sessionCollaborationMaximumMessageBytes = 32 * 1024
public let sessionCollaborationDefaultMaxUpdates = 30
public let sessionCollaborationMaximumUpdates = 200

public struct LiveSessionEntry: Codable, Sendable, Equatable, Hashable {
    public let sessionID: String
    public let cwd: String
    public let projectName: String
    public let modelID: String?
    public let title: String?
    public let status: String
    public let isSelf: Bool

    public init(
        sessionID: String,
        cwd: String,
        projectName: String,
        modelID: String? = nil,
        title: String? = nil,
        status: String,
        isSelf: Bool
    ) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.projectName = projectName
        self.modelID = modelID
        self.title = title
        self.status = status
        self.isSelf = isSelf
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case projectName = "project_name"
        case modelID = "model_id"
        case title
        case status
        case isSelf = "is_self"
    }
}

public struct ListSessionsOutput: Codable, Sendable, Equatable, Hashable {
    public let busEnabled: Bool
    public let sessions: [LiveSessionEntry]

    public init(busEnabled: Bool, sessions: [LiveSessionEntry]) {
        self.busEnabled = busEnabled
        self.sessions = sessions
    }

    enum CodingKeys: String, CodingKey {
        case busEnabled = "bus_enabled"
        case sessions
    }
}

public struct SessionCollaborationTranscriptEntry: Codable, Sendable, Equatable, Hashable {
    public let role: String
    public let text: String

    public init(role: String, text: String) {
        self.role = role
        self.text = text
    }
}

public struct ReadSessionOutput: Codable, Sendable, Equatable, Hashable {
    public let sessionID: String
    public let title: String?
    public let live: Bool
    public let updates: [SessionCollaborationTranscriptEntry]

    public init(
        sessionID: String,
        title: String? = nil,
        live: Bool,
        updates: [SessionCollaborationTranscriptEntry]
    ) {
        self.sessionID = sessionID
        self.title = title
        self.live = live
        self.updates = updates
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case title
        case live
        case updates
    }
}

public enum MessageSessionStatus: String, Codable, Sendable, Equatable, Hashable {
    case accepted
    case unknownSession = "unknown_session"
    case rejected
}

public struct MessageSessionOutput: Codable, Sendable, Equatable, Hashable {
    public let targetSessionID: String
    public let status: MessageSessionStatus

    public init(targetSessionID: String, status: MessageSessionStatus) {
        self.targetSessionID = targetSessionID
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case targetSessionID = "target_session_id"
        case status
    }
}

public protocol SessionCollaborationBackend: Sendable {
    func listSessions() async throws -> ListSessionsOutput

    func readSession(
        sessionID: String,
        maxUpdates: Int
    ) async throws -> ReadSessionOutput

    func messageSession(
        sessionID: String,
        message: String
    ) async throws -> MessageSessionStatus
}

private struct SessionCollaborationCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

private func rejectUnknownSessionFields(
    _ decoder: any Decoder,
    allowed: Set<String>
) throws {
    let container = try decoder.container(keyedBy: SessionCollaborationCodingKey.self)
    for key in container.allKeys where !allowed.contains(key.stringValue) {
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: container,
            debugDescription: "unknown field `\(key.stringValue)`"
        )
    }
}

public struct ReadSessionInput: Codable, Sendable, Equatable, Hashable {
    public let sessionID: String
    public let maxUpdates: Int?

    public init(sessionID: String, maxUpdates: Int? = nil) {
        self.sessionID = sessionID
        self.maxUpdates = maxUpdates
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case maxUpdates = "max_updates"
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownSessionFields(decoder, allowed: ["session_id", "max_updates"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        maxUpdates = try container.decodeIfPresent(Int.self, forKey: .maxUpdates)
        if let maxUpdates, maxUpdates < 0 {
            throw DecodingError.dataCorruptedError(
                forKey: .maxUpdates,
                in: container,
                debugDescription: "max_updates must be a non-negative integer"
            )
        }
    }
}

public struct MessageSessionInput: Codable, Sendable, Equatable, Hashable {
    public let sessionID: String
    public let message: String

    public init(sessionID: String, message: String) {
        self.sessionID = sessionID
        self.message = message
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case message
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownSessionFields(decoder, allowed: ["session_id", "message"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        message = try container.decode(String.self, forKey: .message)
    }
}

public enum SessionCollaborationError: Error, Sendable, Equatable, CustomStringConvertible {
    case emptySessionID
    case emptyMessage
    case messageTooLarge
    case negativeMaxUpdates

    public var description: String {
        switch self {
        case .emptySessionID:
            return "session_id must not be empty"
        case .emptyMessage:
            return "message must not be empty"
        case .messageTooLarge:
            return "message exceeds the \(sessionCollaborationMaximumMessageBytes)-byte limit"
        case .negativeMaxUpdates:
            return "max_updates must be a non-negative integer"
        }
    }
}

public enum SessionCollaborationTool: String, CaseIterable, Sendable {
    case listSessions = "list_sessions"
    case readSession = "read_session"
    case messageSession = "message_session"

    public var descriptionTemplate: String {
        switch self {
        case .listSessions:
            return "List the Open Grok sessions live on this machine's session bus — across every project, terminal, and process, including this one. Each entry carries a session id, project, model, title, and busy/idle status. Session ids are the addressing unit: use them verbatim with read_session and message_session. The roster changes as sessions open and close, so call this again when an id stops working."
        case .readSession:
            return "Read the recent conversation of another live Open Grok session from its persisted history — the last user and agent messages, newest last. Use it to understand what another session is doing before deciding to message it. The target must be live on the session bus (it appears in list_sessions)."
        case .messageSession:
            return "Send a message to another live Open Grok session on this machine. A recipient mid-turn receives it at its next turn boundary; an idle recipient wakes with it as a prompt. The recipient model decides what to do and can reply through message_session addressed to this session's id. Keep messages concise and self-contained, and never resend an accepted message."
        }
    }

    public var isReadOnly: Bool { self != .messageSession }
}

public struct SessionCollaborationToolSurface: Sendable {
    public init() {}

    public static let listSessionsSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([:]),
    ])

    public static let readSessionSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "session_id": .object([
                "type": .string("string"),
                "description": .string("Session id from list_sessions."),
            ]),
            "max_updates": .object([
                "type": .string("integer"),
                "minimum": .number(.int64(0)),
                "description": .string(
                    "Maximum conversation entries to return (newest last). Omit for 30; hard cap 200."
                ),
            ]),
        ]),
        "required": .array([.string("session_id")]),
        "additionalProperties": .bool(false),
    ])

    public static let messageSessionSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "session_id": .object([
                "type": .string("string"),
                "description": .string("Target session id from list_sessions."),
            ]),
            "message": .object([
                "type": .string("string"),
                "description": .string("Message body for the recipient session's model."),
            ]),
        ]),
        "required": .array([.string("session_id"), .string("message")]),
        "additionalProperties": .bool(false),
    ])

    public static func inputSchema(for tool: SessionCollaborationTool) -> JSONValue {
        switch tool {
        case .listSessions: return listSessionsSchema
        case .readSession: return readSessionSchema
        case .messageSession: return messageSessionSchema
        }
    }

    public func validatedReadInput(_ input: ReadSessionInput) throws -> ReadSessionInput {
        let sessionID = input.sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty else {
            throw SessionCollaborationError.emptySessionID
        }
        if let maxUpdates = input.maxUpdates, maxUpdates < 0 {
            throw SessionCollaborationError.negativeMaxUpdates
        }
        let maxUpdates = min(
            max(input.maxUpdates ?? sessionCollaborationDefaultMaxUpdates, 1),
            sessionCollaborationMaximumUpdates
        )
        return ReadSessionInput(sessionID: sessionID, maxUpdates: maxUpdates)
    }

    public func validatedMessageInput(_ input: MessageSessionInput) throws -> MessageSessionInput {
        let sessionID = input.sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty else {
            throw SessionCollaborationError.emptySessionID
        }
        let message = input.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            throw SessionCollaborationError.emptyMessage
        }
        guard message.utf8.count <= sessionCollaborationMaximumMessageBytes else {
            throw SessionCollaborationError.messageTooLarge
        }
        return MessageSessionInput(sessionID: sessionID, message: message)
    }

    public func listSessions(
        backend: any SessionCollaborationBackend
    ) async throws -> ListSessionsOutput {
        try await backend.listSessions()
    }

    public func readSession(
        input: ReadSessionInput,
        backend: any SessionCollaborationBackend
    ) async throws -> ReadSessionOutput {
        let validated = try validatedReadInput(input)
        return try await backend.readSession(
            sessionID: validated.sessionID,
            maxUpdates: validated.maxUpdates ?? sessionCollaborationDefaultMaxUpdates
        )
    }

    public func messageSession(
        input: MessageSessionInput,
        backend: any SessionCollaborationBackend
    ) async throws -> MessageSessionOutput {
        let validated = try validatedMessageInput(input)
        let status = try await backend.messageSession(
            sessionID: validated.sessionID,
            message: validated.message
        )
        return MessageSessionOutput(targetSessionID: validated.sessionID, status: status)
    }
}
