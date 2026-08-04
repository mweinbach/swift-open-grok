import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolTypes

public enum WorkflowControlToolError: Error, Sendable, Hashable, CustomStringConvertible {
    case invalidOperation(String)
    case missingField(String)
    case conflictingSelectors

    public var description: String {
        switch self {
        case .invalidOperation(let value): return "invalid workflow operation: \(value)"
        case .missingField(let value): return "workflow control is missing \(value)"
        case .conflictingSelectors: return "workflow selection fields are mutually exclusive"
        }
    }
}

public protocol WorkflowControlBackend: Sendable {
    func execute(_ input: WorkflowToolInput) async throws -> WorkflowToolOutput
}

public struct WorkflowControlTool: Sendable {
    public static let clientName = "workflow"
    public static let namespace = "GrokBuild"

    public static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "operation": .object(["type": .string("string")]),
            "name": .object(["type": .string("string")]),
            "path": .object(["type": .string("string")]),
            "script": .object(["type": .string("string")]),
            "arguments": .object(["type": .string("object")]),
            "run_id": .object(["type": .string("string")]),
            "agent_budget": .object(["type": .string("integer"), "minimum": .number(.int64(1)), "maximum": .number(.int64(1_024))])
        ]),
        "required": .array([.string("operation")])
    ])

    public init() {}

    public func validate(_ input: WorkflowToolInput) throws {
        switch input.operation {
        case .start:
            guard input.script != nil || input.name != nil || input.path != nil else {
                throw WorkflowControlToolError.missingField("name, path, or script")
            }
            if input.agentBudget.map({ $0 == 0 || $0 > 1_024 }) == true {
                throw WorkflowControlToolError.invalidOperation("agent budget must be between 1 and 1024")
            }
            try validateSelectors(input)
        case .pause, .resume, .stop, .inspect:
            guard let runID = input.runID, !runID.isEmpty else { throw WorkflowControlToolError.missingField("run_id") }
            if input.name != nil || input.path != nil || input.script != nil { throw WorkflowControlToolError.conflictingSelectors }
        case .list:
            if input.runID != nil || input.name != nil || input.path != nil || input.script != nil { throw WorkflowControlToolError.conflictingSelectors }
        }
    }

    public func execute(_ input: WorkflowToolInput, backend: any WorkflowControlBackend) async throws -> WorkflowToolOutput {
        try validate(input)
        return try await backend.execute(input)
    }

    private func validateSelectors(_ input: WorkflowToolInput) throws {
        let count = [input.name != nil, input.path != nil, input.script != nil].filter { $0 }.count
        guard count == 1 else { throw WorkflowControlToolError.conflictingSelectors }
    }
}

public struct WorkflowControlProtocolAdapter: Sendable {
    public var tool: WorkflowControlTool

    public init(tool: WorkflowControlTool = WorkflowControlTool()) {
        self.tool = tool
    }

    public func request(from input: WorkflowToolInput, sessionID: String? = nil) throws -> WorkflowControlRequest {
        try tool.validate(input)
        return WorkflowControlRequest(input: input, sessionID: sessionID)
    }

    public func output(_ output: WorkflowToolOutput) -> WorkflowControlResponse {
        let status = WorkflowWireStatus(rawValue: output.status) ?? .failed
        return WorkflowControlResponse(output: output, status: status)
    }
}
