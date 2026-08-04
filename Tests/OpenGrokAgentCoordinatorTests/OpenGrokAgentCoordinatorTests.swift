import Foundation
import Testing
@testable import OpenGrokAgentCoordinator

@Suite("OpenGrokAgentCoordinator")
struct OpenGrokAgentCoordinatorTests {
    @Test("completion is buffered once and cancellation blocks late task spawns")
    func completionAndCancellation() async throws {
        let coordinator = OpenGrokAgentCoordinator()
        let request = OpenGrokChildRequest(id: "child", parentSessionID: "session", owner: .task)
        try await coordinator.spawn(request) {
            OpenGrokChildResult(id: "child", success: true, output: "done", tokensUsed: 3)
        }
        _ = try await coordinator.awaitResult("child", timeoutMS: 1_000)
        let completions = await coordinator.pollCompletions(parentSessionID: "session")
        #expect(completions.count == 1)
        #expect(await coordinator.pollCompletions(parentSessionID: "session").isEmpty)
        _ = await coordinator.cancel(.parentSession("session"))
        let late = OpenGrokChildRequest(id: "late", parentSessionID: "session", owner: .task)
        do {
            try await coordinator.spawn(late) { OpenGrokChildResult(id: "late", success: true) }
            Issue.record("expected late spawn rejection")
        } catch is OpenGrokCoordinatorError {
        }
    }
}
