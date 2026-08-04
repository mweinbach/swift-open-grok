import Foundation
import Testing
@testable import OpenGrokToolTypes
import OpenGrokShared

@Suite("Workflow tool types")
struct WorkflowToolTypesTests {
    @Test("workflow input and output preserve snake case fields")
    func wireRoundTrip() throws {
        let input = WorkflowToolInput(
            operation: .start,
            name: "demo",
            arguments: .object(["query": .string("x")]),
            agentBudget: 12
        )
        let data = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(WorkflowToolInput.self, from: data)
        #expect(decoded == input)
        let output = WorkflowToolOutput(runID: "run-1", status: "completed", result: .string("ok"), completionDelivered: true)
        #expect(try JSONDecoder().decode(WorkflowToolOutput.self, from: JSONEncoder().encode(output)) == output)
    }
}
