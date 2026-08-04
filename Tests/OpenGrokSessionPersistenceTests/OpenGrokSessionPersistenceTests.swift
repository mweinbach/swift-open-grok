import Foundation
import Testing
@testable import OpenGrokSessionPersistence
import OpenGrokShared

@Suite("Workflow session persistence")
struct OpenGrokSessionPersistenceTests {
    @Test("restore terminalizes active runs and completion claim is one-shot")
    func restoreAndCompletionClaim() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkflowSessionStore(directory: directory)
        let record = WorkflowRunRecord(
            runID: "run-1",
            workflowName: "demo",
            scriptHash: "script",
            argumentsHash: "args",
            agentBudget: 4,
            createdAtMS: 1
        )
        try await store.insert(record)
        let restored = try await store.restore()
        #expect(restored.first?.status == .interrupted)
        #expect(restored.first?.completionDelivered == true)
        var completed = restored[0]
        completed.status = .completed
        completed.revision += 1
        completed.completionDelivered = false
        try await store.update(completed)
        #expect(try await store.claimCompletion(runID: "run-1", revision: completed.revision))
        #expect(!(try await store.claimCompletion(runID: "run-1", revision: completed.revision)))
    }
}
