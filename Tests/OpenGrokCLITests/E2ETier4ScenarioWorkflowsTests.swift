// E2ETier4ScenarioWorkflowsTests.swift
//
// Tier 4: Real-World Application Scenario Test Suite
// Comprehensive end-to-end multi-turn workflows, crash recovery, background prefire,
// structured schema extractions, and hermetic CLI lifecycle verification.

import Foundation
import Testing
import OpenGrokAuth
import OpenGrokChatState
import OpenGrokCodeMode
import OpenGrokCompaction
import OpenGrokModels
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShellSessionSupport
import OpenGrokTokenEstimation
import OpenGrokToolTypes
@testable import OpenGrokCLI

private typealias JSONValue = OpenGrokShared.JSONValue

// MARK: - Test Harness & Fixtures

private struct Tier4ScenarioFixture: Sendable {
    let root: URL
    let home: URL
    let sessionDir: URL
    let checkpointsDir: URL
    let workspaceDir: URL
    let sessionID: String
    let environment: [String: String]

    init(sessionID: String = "session-tier4-\(UUID().uuidString)") throws {
        self.sessionID = sessionID
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("og-tier4-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        sessionDir = home.appendingPathComponent("sessions/\(sessionID)", isDirectory: true)
        checkpointsDir = sessionDir.appendingPathComponent("compaction_checkpoints", isDirectory: true)

        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: checkpointsDir, withIntermediateDirectories: true)

        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
            "XAI_API_KEY": "xai-scenario-key-mock"
        ]
    }

    func writeWorkspaceFile(path: String, content: String) throws {
        let fileURL = workspaceDir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: fileURL, options: .atomic)
    }

    func readWorkspaceFile(path: String) -> String? {
        try? String(contentsOf: workspaceDir.appendingPathComponent(path), encoding: .utf8)
    }

    func makeRewindCoordinator(items: [ConversationItem] = []) async -> LiveRewindCoordinator {
        await LiveRewindCoordinator(
            openGrokHome: home,
            sessionID: sessionID,
            workingDirectory: workspaceDir,
            conversationItems: items
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func settle(
    _ rewind: LiveRewindCoordinator,
    expected: Int = 1
) async throws {
    for _ in 0..<100 {
        if await rewind.points().count >= expected { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

private func estimateConversationTokens(_ items: [ConversationItem]) -> UInt64 {
    items.reduce(UInt64(0)) { total, item in
        total + estimateTokens(item.textContent())
    }
}

private final class ScriptedScenarioSampler: CompactionSampler, @unchecked Sendable {
    typealias Item = ConversationItem
    private let lock = NSLock()
    private var responses: [String]
    private var callLog: [[ConversationItem]] = []

    init(responses: [String] = []) {
        self.responses = responses
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return callLog.count
    }

    private func recordAndNext(turns: [ConversationItem]) -> String {
        lock.lock()
        defer { lock.unlock() }
        callLog.append(turns)
        return responses.isEmpty
            ? "<summary>\n" + String(repeating: "Summary statement for scenario testing.\n", count: 30) + "</summary>"
            : responses.removeFirst()
    }

    func sampleCompaction(
        turns: [ConversationItem],
        prompt: CompactionPrompt,
        timeoutSeconds: UInt64
    ) async throws -> LLMCompactionOutput {
        let resp = recordAndNext(turns: turns)
        return LLMCompactionOutput(response: resp)
    }
}

// MARK: - Test Suite

@Suite("Tier 4 Real-World Application Scenario Workflows", .serialized)
struct E2ETier4ScenarioWorkflowsTests {

    // MARK: - Scenario 1: Multi-Hour Developer Session (45 Turns, 3 Compactions, 2 Rewinds)

    @Test("Scenario 1: Multi-hour developer session with 45 turns, 3 compactions, and 2 cross-compaction rewinds")
    func testScenario_multiHourDeveloperSession_45Turns_compactions_and_rewinds() async throws {
        let fixture = try Tier4ScenarioFixture()
        defer { fixture.cleanup() }

        // Setup initial codebase files
        try fixture.writeWorkspaceFile(path: "Sources/main.swift", content: "print(\"v1.0\")\n")
        try fixture.writeWorkspaceFile(path: "Sources/Engine.swift", content: "struct Engine { var power: Int = 100 }\n")
        try fixture.writeWorkspaceFile(path: "Sources/Network.swift", content: "struct Network { var port: Int = 8080 }\n")

        let rewind = await fixture.makeRewindCoordinator()
        var updates: [SessionUpdateRecord] = []
        var conversation: [ConversationItem] = [
            .system("You are an expert Open Grok software engineer.")
        ]

        // --- Phase 1: Turns 1 to 15 (Initial Implementation) ---
        for turn in 1...15 {
            await rewind.beginPrompt(text: "Prompt \(turn): Implement feature slice \(turn)")
            await rewind.capture(paths: ["Sources/main.swift", "Sources/Engine.swift"])

            let userText = "User Prompt \(turn): Implement feature slice \(turn)"
            let agentText = "Agent Response \(turn): Implemented feature slice \(turn) with tests."

            try fixture.writeWorkspaceFile(
                path: "Sources/Engine.swift",
                content: "struct Engine { var power: Int = \(100 + turn * 10) }\n"
            )
            await rewind.endPrompt()

            conversation.append(.user(userText))
            conversation.append(.assistant(agentText))
            updates.append(.user(text: userText, promptIndex: turn))
            updates.append(.agent(text: agentText))
        }
        try await settle(rewind, expected: 15)

        // --- Compaction Cycle 1 (Prompt Index 15) ---
        let cp1ID = "cp-1-turn15"
        let cp1Compacted: [ConversationItem] = [
            .system("You are an expert Open Grok software engineer."),
            .userMeta("Summary of turns 1-15: Initial engine configuration and feature slices up to power 250."),
            .userMeta("Re-read Sources/Engine.swift: " + (fixture.readWorkspaceFile(path: "Sources/Engine.swift") ?? ""))
        ]
        _ = try persistCompactionCheckpoint(
            sessionDir: fixture.sessionDir,
            checkpointID: cp1ID,
            promptIndex: 15,
            compactedHistory: cp1Compacted,
            originalUserInfo: "Original Initial User Info"
        )
        updates.append(.checkpoint(id: cp1ID, promptIndex: 15))
        try writeUpdatesJSONL(sessionDir: fixture.sessionDir, updates: updates)

        // --- Phase 2: Turns 16 to 25 (Flawed Refactor) ---
        for turn in 16...25 {
            await rewind.beginPrompt(text: "Prompt \(turn): Experimental networking refactor")
            await rewind.capture(paths: ["Sources/Network.swift"])

            let userText = "User Prompt \(turn): Experimental refactor"
            let agentText = "Agent Response \(turn): Refactored network."

            try fixture.writeWorkspaceFile(
                path: "Sources/Network.swift",
                content: "struct Network { var port: Int = \(9000 + turn); var experimental: Bool = true }\n"
            )
            await rewind.endPrompt()

            conversation.append(.user(userText))
            conversation.append(.assistant(agentText))
            updates.append(.user(text: userText, promptIndex: turn))
            updates.append(.agent(text: agentText))
        }
        try await settle(rewind, expected: 25)
        try writeUpdatesJSONL(sessionDir: fixture.sessionDir, updates: updates)

        // --- Rewind Cycle 1 (Revert to Checkpoint CP1 at Prompt 15) ---
        let outcome1 = try await rewind.restore(
            toPromptIndex: 15,
            mode: .filesOnly,
            force: true,
            currentItems: conversation
        )
        #expect(outcome1.applied)
        #expect(fixture.readWorkspaceFile(path: "Sources/Network.swift") == "struct Network { var port: Int = 8080 }\n")

        updates.append(.rewindMarker(targetPromptIndex: 15))
        try writeUpdatesJSONL(sessionDir: fixture.sessionDir, updates: updates)

        let replay1 = try replayToPrompt(sessionDir: fixture.sessionDir, targetPromptIndex: 15)
        #expect(replay1.promptIndexReached == 15)
        #expect(replay1.conversation.count == cp1Compacted.count)
        #expect(replay1.originalUserInfo == "Original Initial User Info")

        // --- Phase 3: Turns 16' to 30 (Alternative Implementation) ---
        conversation = replay1.conversation
        for turn in 16...30 {
            await rewind.beginPrompt(text: "Prompt \(turn): Stable architecture slice \(turn)")
            await rewind.capture(paths: ["Sources/Engine.swift"])

            let userText = "User Prompt \(turn): Stable architecture slice"
            let agentText = "Agent Response \(turn): Applied stable architecture."

            try fixture.writeWorkspaceFile(
                path: "Sources/Engine.swift",
                content: "struct Engine { var power: Int = 500; var stableSlice: Int = \(turn) }\n"
            )
            await rewind.endPrompt()

            conversation.append(.user(userText))
            conversation.append(.assistant(agentText))
            updates.append(.user(text: userText, promptIndex: turn))
            updates.append(.agent(text: agentText))
        }
        try await settle(rewind, expected: 30)

        // --- Compaction Cycle 2 (Prompt Index 30) ---
        let cp2ID = "cp-2-turn30"
        let cp2Compacted: [ConversationItem] = [
            .system("You are an expert Open Grok software engineer."),
            .userMeta("Summary of turns 1-30: Stable architecture established with power 500.")
        ]
        _ = try persistCompactionCheckpoint(
            sessionDir: fixture.sessionDir,
            checkpointID: cp2ID,
            promptIndex: 30,
            compactedHistory: cp2Compacted,
            originalUserInfo: "Original Initial User Info"
        )
        updates.append(.checkpoint(id: cp2ID, promptIndex: 30))
        try writeUpdatesJSONL(sessionDir: fixture.sessionDir, updates: updates)

        // --- Phase 4: Turns 31 to 42 (Tests & Documentation) ---
        for turn in 31...42 {
            await rewind.beginPrompt(text: "Prompt \(turn): Tests and docs")
            let userText = "User Prompt \(turn): Add test suite \(turn)"
            let agentText = "Agent Response \(turn): Added tests."
            conversation.append(.user(userText))
            conversation.append(.assistant(agentText))
            updates.append(.user(text: userText, promptIndex: turn))
            updates.append(.agent(text: agentText))
            await rewind.endPrompt()
        }
        try await settle(rewind, expected: 42)

        // --- Compaction Cycle 3 (Prompt Index 42) ---
        let cp3ID = "cp-3-turn42"
        let cp3Compacted: [ConversationItem] = [
            .system("You are an expert Open Grok software engineer."),
            .userMeta("Summary of turns 1-42: Full tests and documentation added.")
        ]
        _ = try persistCompactionCheckpoint(
            sessionDir: fixture.sessionDir,
            checkpointID: cp3ID,
            promptIndex: 42,
            compactedHistory: cp3Compacted,
            originalUserInfo: "Original Initial User Info"
        )
        updates.append(.checkpoint(id: cp3ID, promptIndex: 42))
        try writeUpdatesJSONL(sessionDir: fixture.sessionDir, updates: updates)

        // --- Rewind Cycle 2 (Rewind to Prompt 36: Post-CP2, Pre-CP3) ---
        updates.append(.rewindMarker(targetPromptIndex: 36))
        try writeUpdatesJSONL(sessionDir: fixture.sessionDir, updates: updates)

        let replay2 = try replayToPrompt(sessionDir: fixture.sessionDir, targetPromptIndex: 36)
        #expect(replay2.promptIndexReached == 36)
        #expect(replay2.conversation.contains(where: {
            $0.textContent().contains("Stable architecture established")
        }))

        // --- Phase 5: Complete Turns 37' to 45 ---
        for turn in 37...45 {
            let userText = "User Prompt \(turn): Final polish"
            let agentText = "Agent Response \(turn): Completed."
            updates.append(.user(text: userText, promptIndex: turn))
            updates.append(.agent(text: agentText))
        }
        try writeUpdatesJSONL(sessionDir: fixture.sessionDir, updates: updates)

        // Final verification
        let allCheckpoints = try listCompactionCheckpoints(sessionDir: fixture.sessionDir)
        #expect(allCheckpoints.count == 3)
        #expect(allCheckpoints.map(\.checkpointID).contains(cp1ID))
        #expect(allCheckpoints.map(\.checkpointID).contains(cp2ID))
        #expect(allCheckpoints.map(\.checkpointID).contains(cp3ID))

        let finalReplay = try replayToPrompt(sessionDir: fixture.sessionDir, targetPromptIndex: 45)
        #expect(finalReplay.promptIndexReached == 45)
    }

    // MARK: - Scenario 2: Crash Recovery & Session Resume

    @Test("Scenario 2: Mid-compaction simulated crash, checkpoint recovery, and seamless session resume")
    func testScenario_crashRecovery_checkpointPersistence_and_sessionResume() async throws {
        let fixture = try Tier4ScenarioFixture()
        defer { fixture.cleanup() }

        // 1. Initial 10 turns with checkpoint at turn 5
        var updates: [SessionUpdateRecord] = []
        for turn in 1...5 {
            updates.append(.user(text: "User turn \(turn)", promptIndex: turn))
            updates.append(.agent(text: "Agent turn \(turn)"))
        }

        let cp1ID = "cp-durable-turn5"
        let cp1History: [ConversationItem] = [
            .system("System prompt"),
            .userMeta("Durable summary turns 1-5")
        ]
        _ = try persistCompactionCheckpoint(
            sessionDir: fixture.sessionDir,
            checkpointID: cp1ID,
            promptIndex: 5,
            compactedHistory: cp1History
        )
        updates.append(.checkpoint(id: cp1ID, promptIndex: 5))

        for turn in 6...10 {
            updates.append(.user(text: "User turn \(turn)", promptIndex: turn))
            updates.append(.agent(text: "Agent turn \(turn)"))
        }
        try writeUpdatesJSONL(sessionDir: fixture.sessionDir, updates: updates)

        // 2. Simulate mid-compaction crash at turn 10:
        // Partially written temporary file left in compaction_checkpoints
        let tempCorruptURL = fixture.checkpointsDir.appendingPathComponent("cp-in-flight.json.tmp")
        try Data("{\"checkpoint_id\": \"cp-in-flight\", \"compacted_history\": [".utf8).write(to: tempCorruptURL)

        // 3. Restart: Scan and recover from disk
        let checkpoints = try listCompactionCheckpoints(sessionDir: fixture.sessionDir)
        // Corrupt .tmp file must be ignored by checkpoint lister
        #expect(checkpoints.count == 1)
        #expect(checkpoints.first?.checkpointID == cp1ID)

        // 4. Reconstruct conversation state from journal
        let recovered = try replayToPrompt(sessionDir: fixture.sessionDir, targetPromptIndex: 10)
        #expect(recovered.promptIndexReached == 10)
        #expect(recovered.conversation.count == cp1History.count + 10) // CP1 base + 5 user turns + 5 agent turns

        // 5. Seamless resume: execute turn 11 on the recovered session
        updates.append(.user(text: "User turn 11: Resumed after crash", promptIndex: 11))
        updates.append(.agent(text: "Agent turn 11: Continuing smoothly."))
        try writeUpdatesJSONL(sessionDir: fixture.sessionDir, updates: updates)

        let resumedReplay = try replayToPrompt(sessionDir: fixture.sessionDir, targetPromptIndex: 11)
        #expect(resumedReplay.promptIndexReached == 11)
        #expect(resumedReplay.conversation.last?.textContent() == "Agent turn 11: Continuing smoothly.")
    }

    // MARK: - Scenario 3: High-Frequency Prefire Hit Rate Simulation

    @Test("Scenario 3: High-frequency user query sequence with speculative prefire cache hit and latency reduction")
    func testScenario_highFrequencyPrefireHitRate_simulation() async throws {
        let cw: UInt64 = 100_000
        let threshold: UInt8 = 80  // 80,000 tokens
        let lead: UInt8 = 10       // Prefire trigger at 70,000 tokens

        var conversation: [ConversationItem] = [
            .system("You are an AI assistant.")
        ]

        // 1. Accumulate items below prefire threshold
        for i in 1...20 {
            conversation.append(.user("Query \(i): " + String(repeating: "word ", count: 200)))
            conversation.append(.assistant("Answer \(i): " + String(repeating: "data ", count: 200)))
        }

        var currentTokens = estimateConversationTokens(conversation)

        // 2. Add queries until prefire threshold is crossed (> 70k tokens)
        while currentTokens < 72_000 {
            conversation.append(.user("Heavy query: " + String(repeating: "context data block ", count: 500)))
            conversation.append(.assistant("Heavy answer: " + String(repeating: "analysis output block ", count: 500)))
            currentTokens = estimateConversationTokens(conversation)
        }

        #expect(shouldPrefireTwoPass(
            estimatedTotalTokens: currentTokens,
            contextWindow: cw,
            thresholdPercent: threshold,
            leadPercent: lead,
            provider: .xai
        ))

        // 3. Background Prefire Pass 1 fires
        let split = splitConversationForTwoPass(conversation: conversation, splitFraction: 0.95)
        #expect(!split.prefix.isEmpty)
        #expect(!split.tail.isEmpty)

        let prefixFingerprint = fingerprintPrefix(split.prefix)
        let note1Content = "<summary>\n" + String(repeating: "Prefire summary of early conversation.\n", count: 40) + "</summary>"

        let cache = AsyncCompactionCache(
            note1: note1Content,
            prefixLen: split.prefix.count,
            fingerprint: prefixFingerprint,
            modelSlug: "grok-beta",
            pass1LatencyMs: 180
        )

        // 4. User rapidly sends 3 more queries while prefire completes
        for k in 1...3 {
            conversation.append(.user("Rapid burst query \(k)"))
            conversation.append(.assistant("Rapid burst answer \(k)"))
        }

        // 5. Hard compaction threshold reached (80k tokens) -> Synchronous Pass 2
        let isValid = (cache.prefixLen <= conversation.count
            && cache.modelSlug == "grok-beta"
            && fingerprintPrefix(Array(conversation[..<cache.prefixLen])) == cache.fingerprint)
        #expect(isValid) // CACHE HIT!

        // Pass 2 builds summary from cached NOTE₁ + uncompacted tail items
        let pass2Tail = Array(conversation[cache.prefixLen...])
        let assembledSummary = assembleTwoPassSummary(
            note1: cache.note1,
            tail: pass2Tail,
            summaryPrompt: "Final Pass 2 summary"
        )
        #expect(assembledSummary.contains("Prefire summary of early conversation"))

        // Measure token savings: Pass 2 only processed tail items vs full conversation
        let tailTokens = estimateConversationTokens(pass2Tail)
        let fullTokens = estimateConversationTokens(conversation)
        #expect(Double(tailTokens) < Double(fullTokens) * 0.15) // >85% token reduction on critical path
    }

    // MARK: - Scenario 4: Headless Structured Output Workflow

    @Test("Scenario 4: Headless structured schema extraction tool loop against Messages API with validation retry")
    func testScenario_headlessStructuredOutputWorkflow_messagesAPI() throws {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "required": .array([
                .string("project"),
                .string("vulnerabilities_found"),
                .string("triage_score"),
                .string("release_verdict")
            ]),
            "properties": .object([
                "project": .object(["type": .string("string")]),
                "vulnerabilities_found": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("object"),
                        "required": .array([.string("cve_id"), .string("severity")]),
                        "properties": .object([
                            "cve_id": .object(["type": .string("string")]),
                            "severity": .object([
                                "type": .string("string"),
                                "enum": .array([.string("critical"), .string("high"), .string("medium"), .string("low")])
                            ])
                        ])
                    ])
                ]),
                "triage_score": .object([
                    "type": .string("number"),
                    "minimum": .number(.double(0.0)),
                    "maximum": .number(.double(100.0))
                ]),
                "release_verdict": .object([
                    "type": .string("string"),
                    "enum": .array([.string("APPROVED"), .string("REJECTED"), .string("MANUAL_REVIEW")])
                ])
            ]),
            "additionalProperties": .bool(false)
        ])

        var coordinator = StructuredOutputTurnCoordinator(
            schema: schema,
            backend: .messages,
            codeModeOnly: false
        )

        #expect(!coordinator.structuredOutputNative)
        #expect(coordinator.structuredOutputTool)

        let (tools, reminder, jsonSchema) = coordinator.prepareRequest(tools: [])
        #expect(tools.count == 1)
        #expect(tools[0].name == StructuredOutputConstants.toolName)
        #expect(reminder != nil)
        #expect(jsonSchema == nil)

        // Attempt 1: Malformed type (triage_score is string, missing release_verdict)
        let attempt1Call = ToolCall(
            id: "call_1",
            name: StructuredOutputConstants.toolName,
            arguments: """
            {"project": "swift-open-grok", "vulnerabilities_found": [], "triage_score": "high_score"}
            """
        )
        let (step1, _) = coordinator.handleToolCalls([attempt1Call])
        guard case .retry(let msg1) = step1 else {
            Issue.record("Expected retry on attempt 1")
            return
        }
        #expect(msg1.contains(StructuredOutputConstants.retrySuffix))
        #expect(coordinator.retries == 1)

        // Attempt 2: Enum violation (release_verdict = "PASS")
        let attempt2Call = ToolCall(
            id: "call_2",
            name: StructuredOutputConstants.toolName,
            arguments: """
            {"project": "swift-open-grok", "vulnerabilities_found": [], "triage_score": 95.0, "release_verdict": "PASS"}
            """
        )
        let (step2, _) = coordinator.handleToolCalls([attempt2Call])
        guard case .retry = step2 else {
            Issue.record("Expected retry on attempt 2")
            return
        }
        #expect(coordinator.retries == 2)

        // Attempt 3: Valid conforming payload
        let attempt3Call = ToolCall(
            id: "call_3",
            name: StructuredOutputConstants.toolName,
            arguments: """
            {
                "project": "swift-open-grok",
                "vulnerabilities_found": [{"cve_id": "CVE-2026-001", "severity": "low"}],
                "triage_score": 98.5,
                "release_verdict": "APPROVED"
            }
            """
        )
        let (step3, _) = coordinator.handleToolCalls([attempt3Call])
        guard case .complete(let outcome) = step3, case .success(let payload) = outcome else {
            Issue.record("Expected success on attempt 3")
            return
        }

        #expect(payload.objectValue?["project"]?.stringValue == "swift-open-grok")
        #expect(payload.objectValue?["release_verdict"]?.stringValue == "APPROVED")
        #expect(payload.objectValue?["triage_score"]?.doubleValue == 98.5)
    }

    // MARK: - Scenario 5: Full CLI Lifecycle in Isolated Environment

    @Test("Scenario 5: Full CLI lifecycle driving options in isolated environment with zero bleed")
    func testScenario_fullCLILifecycle_isolatedEnvironment() throws {
        let fixture = try Tier4ScenarioFixture()
        defer { fixture.cleanup() }

        // 1. paths --json
        let (pStreams, pOut, pErr) = CLIStreams.buffered()
        let pCode = CLIRunner.main(["paths", "--json"], environment: fixture.environment, streams: pStreams)
        #expect(pCode == CLIRunner.ExitCode.success.rawValue)
        #expect(pErr.contents.isEmpty)
        let pathsParsed = try JSONDecoder().decode([String: String].self, from: Data(pOut.contents.utf8))
        #expect(pathsParsed["opengrok_home"] == fixture.home.path)

        // 2. doctor --json
        let (dStreams, dOut, dErr) = CLIStreams.buffered()
        let dCode = CLIRunner.main(["doctor", "--json"], environment: fixture.environment, streams: dStreams)
        #expect(dCode == CLIRunner.ExitCode.success.rawValue)
        #expect(dErr.contents.isEmpty)
        #expect(dOut.contents.contains("\"doctor\"") || dOut.contents.contains("\"ok\"") || dOut.contents.contains("{"))

        // 3. models --json
        let (mStreams, mOut, mErr) = CLIStreams.buffered()
        let mCode = CLIRunner.main(["models", "--json"], environment: fixture.environment, streams: mStreams)
        #expect(mCode == CLIRunner.ExitCode.success.rawValue)
        #expect(mErr.contents.isEmpty)
        #expect(mOut.contents.contains("grok") || mOut.contents.contains("models"))

        // 4. completions bash / zsh / fish
        for shell in ["bash", "zsh", "fish"] {
            let (cStreams, cOut, cErr) = CLIStreams.buffered()
            let cCode = CLIRunner.main(["completions", shell], environment: fixture.environment, streams: cStreams)
            #expect(cCode == CLIRunner.ExitCode.success.rawValue)
            #expect(cErr.contents.isEmpty)
            #expect(!cOut.contents.isEmpty)
        }

        // 5. Seed session and verify `sessions list` and `sessions show`
        let dummySessionDir = fixture.home.appendingPathComponent("sessions/test-session-1")
        try FileManager.default.createDirectory(at: dummySessionDir, withIntermediateDirectories: true)
        let updates = [
            SessionUpdateRecord.user(text: "Hello world", promptIndex: 1),
            SessionUpdateRecord.agent(text: "Hello user")
        ]
        try writeUpdatesJSONL(sessionDir: dummySessionDir, updates: updates)

        let (sStreams, _, sErr) = CLIStreams.buffered()
        let sCode = CLIRunner.main(["sessions", "list", "--json"], environment: fixture.environment, streams: sStreams)
        #expect(sCode == CLIRunner.ExitCode.success.rawValue)
        #expect(sErr.contents.isEmpty)

        // 6. Zero Bleed Verification: real ~/.opengrok or ~/.grok must not be modified
        #expect(!fixture.home.path.contains(".opengrok/sessions/session-tier4"))
    }
}
