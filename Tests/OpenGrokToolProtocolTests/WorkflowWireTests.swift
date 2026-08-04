import Foundation
import Testing
@testable import OpenGrokToolProtocol
import OpenGrokToolTypes

@Suite("Workflow protocol wire")
struct WorkflowWireTests {
    @Test("control request and completion notification round trip")
    func roundTrip() throws {
        let request = WorkflowControlRequest(
            input: WorkflowToolInput(operation: .resume, runID: "run-1"),
            sessionID: "session-1"
        )
        let decoded = try JSONDecoder().decode(WorkflowControlRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded == request)
        let notification = WorkflowCompletionNotification(runID: "run-1", status: .completed, result: .string("done"))
        #expect(try JSONDecoder().decode(WorkflowCompletionNotification.self, from: JSONEncoder().encode(notification)) == notification)
    }
}
