import Foundation
import Testing
@testable import OpenGrokSessionRuntime
import OpenGrokSessionPersistence
import OpenGrokWorkflow

@Suite("OpenGrokSessionRuntime")
struct OpenGrokSessionRuntimeTests {
    @Test("background run persists completion and injects it once")
    func backgroundCompletionIsDeliveredOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = OpenGrokSessionRuntime(store: WorkflowSessionStore(directory: directory))
        let host = InMemoryWorkflowHost()
        let record = try await runtime.startInline(
            script: "let meta = #{ name: \"runtime\", description: \"d\" }; complete(\"ok\");",
            host: host
        )
        let finished = try await runtime.awaitCompletion(runID: record.runID, timeoutMS: 2_000)
        #expect(finished.status == .completed)
        let first = try await runtime.pollCompletions()
        #expect(first.count == 1)
        #expect(try await runtime.pollCompletions().isEmpty)
    }
}
