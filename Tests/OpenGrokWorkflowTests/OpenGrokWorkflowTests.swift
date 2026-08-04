import Foundation
import Testing
@testable import OpenGrokWorkflow
import OpenGrokShared
import OpenGrokToolTypes

@Suite("OpenGrokWorkflow")
struct OpenGrokWorkflowTests {
    private let validScript = """
    let meta = #{ name: "demo", description: "deterministic work", phases: [#{ title: "Scan" }] };
    let answer = agent("inspect");
    complete(answer.output);
    """

    @Test("metadata requires first statement and bounded kebab name")
    func metadataValidation() throws {
        let metadata = try extractWorkflowMetadata(from: validScript)
        #expect(metadata.name == "demo")
        #expect(metadata.phases == [WorkflowPhaseMetadata(title: "Scan")])
        #expect(throws: WorkflowMetadataError.self) {
            try extractWorkflowMetadata(from: "let value = 1; let meta = #{ name: \"demo\", description: \"x\" };")
        }
        #expect(throws: WorkflowMetadataError.self) {
            try extractWorkflowMetadata(from: "let meta = #{ name: \"bad_name\", description: \"x\" };")
        }
    }

    @Test("engine completes typed agent output")
    func completesAgentOutput() async throws {
        let journal = try WorkflowJournal()
        let host = InMemoryWorkflowHost()
        let outcome = await WorkflowEngine.run(WorkflowRunParameters(
            script: validScript,
            journal: journal,
            host: host
        ))
        guard case .completed(let result) = outcome else {
            Issue.record("expected completed outcome")
            return
        }
        #expect(result["prompt"]?.stringValue == "inspect")
        #expect(journal.count == 3)
    }

    @Test("journal replays matching calls and rejects divergence")
    func journalReplay() async throws {
        let journal = try WorkflowJournal()
        var calls = 0
        let first = try await journal.replayOrRecord(kind: "log", payload: .object(["x": .string("1")])) {
            calls += 1
            return .string("recorded")
        }
        journal.resetReplayCursor()
        let second = try await journal.replayOrRecord(kind: "log", payload: .object(["x": .string("1")])) {
            calls += 1
            return .string("unexpected")
        }
        #expect(first == second)
        #expect(calls == 1)
        journal.resetReplayCursor()
        do {
            _ = try await journal.replayOrRecord(kind: "phase", payload: .object([:])) { .null }
            Issue.record("expected replay divergence")
        } catch is WorkflowJournalError {
        }
    }

    @Test("journal restore truncates only a torn final tail")
    func journalRestoreTruncatesTornTail() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        let journal = try WorkflowJournal(path: path)
        _ = try await journal.replayOrRecord(kind: "log", payload: .object(["x": .string("1")])) { .null }
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"torn\":".utf8))
        try handle.close()
        let restored = try WorkflowJournal.load(path: path)
        #expect(restored.count == 1)
        let data = try Data(contentsOf: path)
        #expect(data.last == 10)
    }

    @Test("budget and pause outcomes are deterministic")
    func budgetAndPause() async throws {
        let budgetScript = """
        let meta = #{ name: "budget", description: "bounded" };
        parallel([agent("a"), agent("b")]);
        """
        let budgetOutcome = await WorkflowEngine.run(WorkflowRunParameters(
            script: budgetScript,
            agentBudget: 1,
            journal: try WorkflowJournal(),
            host: InMemoryWorkflowHost()
        ))
        guard case .budgetExceeded = budgetOutcome else {
            Issue.record("expected budget exceeded")
            return
        }
        let pauseScript = "let meta = #{ name: \"pause\", description: \"bounded\" }; pause(\"user\", \"needs input\");"
        let pauseOutcome = await WorkflowEngine.run(WorkflowRunParameters(
            script: pauseScript,
            journal: try WorkflowJournal(),
            host: InMemoryWorkflowHost()
        ))
        #expect(pauseOutcome.isResumable)
    }

    @Test("same run resumes only with immutable script and arguments")
    func immutableResume() async throws {
        let script = "let meta = #{ name: \"resume\", description: \"bounded\" }; pause(\"user\", \"continue\");"
        let run = WorkflowRun(script: script, arguments: .object(["x": .number(.int64(1))]), journal: try WorkflowJournal())
        let first = await run.start(agentBudget: 1, host: InMemoryWorkflowHost())
        #expect(first.isResumable)
        let mismatch = await run.resume(script: script + " ", arguments: .object(["x": .number(.int64(1))]), agentBudget: 1, host: InMemoryWorkflowHost())
        guard case .failed(let message) = mismatch else {
            Issue.record("expected immutable resume failure")
            return
        }
        #expect(message.contains("same immutable script"))
    }
}
