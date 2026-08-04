import Foundation
import OpenGrokShared
import OpenGrokToolTypes

public struct WorkflowControlRequest: Codable, Sendable, Hashable {
    public var input: WorkflowToolInput
    public var sessionID: String?

    private enum CodingKeys: String, CodingKey {
        case input
        case sessionID = "session_id"
    }

    public init(input: WorkflowToolInput, sessionID: String? = nil) {
        self.input = input
        self.sessionID = sessionID
    }
}

public enum WorkflowWireStatus: String, Codable, Sendable, Hashable {
    case active
    case completed
    case paused
    case budgetExceeded = "budget_exceeded"
    case cancelled
    case failed
    case interrupted
}

public struct WorkflowControlResponse: Codable, Sendable, Hashable {
    public var output: WorkflowToolOutput
    public var status: WorkflowWireStatus

    public init(output: WorkflowToolOutput, status: WorkflowWireStatus) {
        self.output = output
        self.status = status
    }
}

public struct WorkflowCompletionNotification: Codable, Sendable, Hashable {
    public var runID: String
    public var status: WorkflowWireStatus
    public var result: JSONValue?
    public var message: String?

    private enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case status
        case result
        case message
    }

    public init(
        runID: String,
        status: WorkflowWireStatus,
        result: JSONValue? = nil,
        message: String? = nil
    ) {
        self.runID = runID
        self.status = status
        self.result = result
        self.message = message
    }
}
