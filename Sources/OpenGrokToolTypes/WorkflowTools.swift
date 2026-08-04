import Foundation
import OpenGrokShared

public enum WorkflowControlOperation: String, Codable, Sendable, Hashable, CaseIterable {
    case start
    case pause
    case resume
    case stop
    case list
    case inspect
}

public struct WorkflowAgentOptions: Codable, Sendable, Hashable {
    public var prompt: String
    public var label: String?
    public var model: String?
    public var reasoningEffort: String?
    public var maxOutputTokens: UInt64?
    public var agentType: String?
    public var capabilityMode: String?
    public var isolationWorktree: Bool
    public var forkContext: Bool
    public var resumeFrom: String?
    public var outputSchema: JSONValue?
    public var phase: String?

    private enum CodingKeys: String, CodingKey {
        case prompt
        case label
        case model
        case reasoningEffort = "reasoning_effort"
        case maxOutputTokens = "max_output_tokens"
        case agentType = "agent_type"
        case capabilityMode = "capability_mode"
        case isolationWorktree = "isolation_worktree"
        case forkContext = "fork_context"
        case resumeFrom = "resume_from"
        case outputSchema = "output_schema"
        case phase
    }

    public init(
        prompt: String,
        label: String? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil,
        maxOutputTokens: UInt64? = nil,
        agentType: String? = nil,
        capabilityMode: String? = nil,
        isolationWorktree: Bool = false,
        forkContext: Bool = false,
        resumeFrom: String? = nil,
        outputSchema: JSONValue? = nil,
        phase: String? = nil
    ) {
        self.prompt = prompt
        self.label = label
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.maxOutputTokens = maxOutputTokens
        self.agentType = agentType
        self.capabilityMode = capabilityMode
        self.isolationWorktree = isolationWorktree
        self.forkContext = forkContext
        self.resumeFrom = resumeFrom
        self.outputSchema = outputSchema
        self.phase = phase
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        label = try container.decodeIfPresent(String.self, forKey: .label)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        maxOutputTokens = try container.decodeIfPresent(UInt64.self, forKey: .maxOutputTokens)
        agentType = try container.decodeIfPresent(String.self, forKey: .agentType)
        capabilityMode = try container.decodeIfPresent(String.self, forKey: .capabilityMode)
        isolationWorktree = try container.decodeIfPresent(Bool.self, forKey: .isolationWorktree) ?? false
        forkContext = try container.decodeIfPresent(Bool.self, forKey: .forkContext) ?? false
        resumeFrom = try container.decodeIfPresent(String.self, forKey: .resumeFrom)
        outputSchema = try container.decodeIfPresent(JSONValue.self, forKey: .outputSchema)
        phase = try container.decodeIfPresent(String.self, forKey: .phase)
    }
}

public struct WorkflowToolInput: Codable, Sendable, Hashable {
    public var operation: WorkflowControlOperation
    public var name: String?
    public var path: String?
    public var script: String?
    public var arguments: JSONValue?
    public var runID: String?
    public var agentBudget: UInt64?

    private enum CodingKeys: String, CodingKey {
        case operation
        case name
        case path
        case script
        case arguments
        case runID = "run_id"
        case agentBudget = "agent_budget"
    }

    public init(
        operation: WorkflowControlOperation,
        name: String? = nil,
        path: String? = nil,
        script: String? = nil,
        arguments: JSONValue? = nil,
        runID: String? = nil,
        agentBudget: UInt64? = nil
    ) {
        self.operation = operation
        self.name = name
        self.path = path
        self.script = script
        self.arguments = arguments
        self.runID = runID
        self.agentBudget = agentBudget
    }
}

public struct WorkflowToolOutput: Codable, Sendable, Hashable {
    public var runID: String?
    public var status: String
    public var result: JSONValue?
    public var message: String?
    public var completionDelivered: Bool

    private enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case status
        case result
        case message
        case completionDelivered = "completion_delivered"
    }

    public init(
        runID: String? = nil,
        status: String,
        result: JSONValue? = nil,
        message: String? = nil,
        completionDelivered: Bool = false
    ) {
        self.runID = runID
        self.status = status
        self.result = result
        self.message = message
        self.completionDelivered = completionDelivered
    }
}
