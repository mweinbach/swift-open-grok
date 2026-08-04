import Foundation
import Testing
@testable import OpenGrokAgentControlTools
import OpenGrokToolTypes

@Suite("Workflow control tools")
struct OpenGrokAgentControlToolsTests {
    @Test("start requires exactly one source selector")
    func validatesSelectors() {
        let tool = WorkflowControlTool()
        #expect(throws: WorkflowControlToolError.self) {
            try tool.validate(WorkflowToolInput(operation: .start))
        }
        #expect(throws: WorkflowControlToolError.self) {
            try tool.validate(WorkflowToolInput(operation: .start, name: "demo", script: "inline"))
        }
        #expect(throws: WorkflowControlToolError.self) {
            try tool.validate(WorkflowToolInput(operation: .resume))
        }
    }
}
