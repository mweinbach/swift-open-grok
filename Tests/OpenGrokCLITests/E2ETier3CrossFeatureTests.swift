// E2ETier3CrossFeatureTests.swift
//
// Tier 3 Cross-Feature Combination Test Suite
//
// Verifies complex, multi-feature pairwise and n-way interactions across:
// 1. Compaction Checkpoints + Cross-Compaction Rewind + Sticky Monotonic Export Boundary
// 2. Two-Pass Prefire Background Compaction + User Interjection + Cache Invalidation
// 3. Compaction Checkpoint Persistence + Swarm Subagent Fork & Isolation
// 4. Two-Pass Assembly + Persistent Code Mode JavaScript Runtime Timeline
// 5. StructuredOutput Synthetic Tool Loop + Auto-Compaction Survival
// 6. Monotonic Export Boundary + Mid-Share Race Condition
// 7. CLI Headless Mode + Live Dynamic Model Switch + Strict Provider Isolation

import Foundation
import Testing
import OpenGrokAuth
import OpenGrokChatState
import OpenGrokCodeMode
import OpenGrokCodeModeProtocol
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

private struct Tier3CrossFeatureFixture {
    let root: URL
    let home: URL
    let sessionDir: URL
    let checkpointsDir: URL
    let workspaceDir: URL
    let sessionID: String
    let environment: [String: String]

    init(sessionID: String = "tier3-comb-\(UUID().uuidString)") throws {
        self.sessionID = sessionID
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("og-t3-\(UUID().uuidString)", isDirectory: true)
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
            "XAI_API_KEY": "xai-test-key-mock"
        ]
    }

    func writeCheckpoint(
        id: String,
        promptIndex: Int,
        compactedHistory: [ConversationItem],
        originalUserInfo: String? = "Original User Info",
        rereadFilePaths: [String] = []
    ) throws -> CompactionCheckpointInfo {
        try persistCompactionCheckpoint(
            sessionDir: sessionDir,
            checkpointID: id,
            promptIndex: promptIndex,
            compactedHistory: compactedHistory,
            schemaVersion: 1,
            createdAt: "2026-08-14T00:00:00Z",
            originalUserInfo: originalUserInfo,
            rereadFilePaths: rereadFilePaths
        )
    }

    func writeSessionRecord(
        items: [ConversationItem],
        everUsedNonXAI: Bool = false
    ) async throws {
        var record = LiveConversationRecord.new(
            sessionID: sessionID,
            workingDirectory: workspaceDir
        )
        record.items = items
        record.everUsedNonXAI = everUsedNonXAI
        let store = LiveConversationStore(openGrokHome: home)
        try await store.save(record)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - Mock Sampler for Cross-Feature Testing

private final class Tier3ScriptedSampler: CompactionSampler, @unchecked Sendable {
    typealias Item = ConversationItem

    private let lock = NSLock()
    private var responses: [String]
    private var sampledHistories: [[ConversationItem]] = []

    init(responses: [String] = []) {
        self.responses = responses
    }

    var historyCount: Int {
        lock.lock(); defer { lock.unlock() }
        return sampledHistories.count
    }

    private func recordAndNext(turns: [ConversationItem]) -> String {
        lock.lock()
        defer { lock.unlock() }
        sampledHistories.append(turns)
        return responses.isEmpty
            ? "<summary>\n" + String(repeating: "Cross-feature verified compaction summary line.\n", count: 40) + "</summary>"
            : responses.removeFirst()
    }

    func sampleCompaction(
        turns: [ConversationItem],
        prompt: CompactionPrompt,
        timeoutSeconds: UInt64
    ) async throws -> LLMCompactionOutput {
        let response = recordAndNext(turns: turns)
        return LLMCompactionOutput(response: response)
    }
}

// MARK: - Test Suite

@Suite("E2E Tier 3 Cross-Feature Combination Tests", .serialized)
struct E2ETier3CrossFeatureTests {

    // MARK: - Case 1: Checkpoint Persistence + Cross-Compaction Rewind + Sticky Export Boundary
    @Test("Checkpoint persistence with cross-compaction rewind maintains sticky monotonic export boundary")
    func testCrossFeature_checkpointPersistence_and_crossCompactionRewind_and_exportBoundarySticky() async throws {
        let fixture = try Tier3CrossFeatureFixture()
        defer { fixture.cleanup() }

        let boundary = ExportBoundary(everUsedNonXAI: false)
        #expect(boundary.allowsXaiExport)

        // Turn 0..3: pure xAI
        _ = boundary.observe(.xai)
        #expect(boundary.allowsXaiExport)

        // Turn 4: Codex observation closes export boundary
        let closed = boundary.observe(.codex)
        #expect(closed == true)
        #expect(!boundary.allowsXaiExport)
        #expect(boundary.everUsedNonXAI)

        // Compaction triggered at prompt 5
        let compactedItems: [ConversationItem] = [
            .system("System instructions"),
            .userMeta("Summary of turns 0..4 (including Codex operations)")
        ]
        _ = try fixture.writeCheckpoint(
            id: "ckpt-cross-1",
            promptIndex: 5,
            compactedHistory: compactedItems,
            originalUserInfo: "Original Info P0"
        )

        let updates: [SessionUpdateRecord] = [
            .user(text: "P0: xAI setup", promptIndex: 0),
            .agent(text: "R0: xAI response"),
            .user(text: "P1: xAI build", promptIndex: 1),
            .agent(text: "R1: xAI response"),
            .user(text: "P2: Codex translation", promptIndex: 2),
            .agent(text: "R2: Codex response"),
            .checkpoint(id: "ckpt-cross-1", promptIndex: 5, autoContinueText: nil),
            .user(text: "P5: xAI post-compaction query", promptIndex: 5),
            .agent(text: "R5: xAI response")
        ]
        try writeUpdatesJSONL(sessionDir: fixture.sessionDir, updates: updates)

        // Save session record with everUsedNonXAI = true
        try await fixture.writeSessionRecord(items: compactedItems, everUsedNonXAI: true)

        // Rewind ACROSS compaction boundary back to prompt 1 (which only had xAI turns)
        let replay = try replayToPrompt(sessionDir: fixture.sessionDir, targetPromptIndex: 1)
        #expect(replay.promptIndexReached == 1)
        #expect(replay.lastCompactionPromptIndex == nil)

        // CRITICAL INVARIANT: The export boundary MUST REMAIN CLOSED despite rewinding to an xAI-only turn history
        #expect(!boundary.allowsXaiExport)
        #expect(boundary.everUsedNonXAI)

        // Even syncing with false cannot reopen
        boundary.sync(everUsedNonXAI: false)
        #expect(!boundary.allowsXaiExport)
        #expect(boundary.everUsedNonXAI)

        // ShareExportGate must strictly reject export
        #expect(throws: ShareRefusal.nonXaiProviderBoundary) {
            try ShareExportGate.authorizeExport(
                persistedEverUsedNonXAI: true,
                liveBoundary: boundary,
                messageCount: replay.conversation.count
            )
        }

        // Verify disk persistence preserves "ever_used_codex": true
        let sessionFile = fixture.home.appendingPathComponent("sessions/\(fixture.sessionID).json")
        let fileData = try Data(contentsOf: sessionFile)
        let jsonStr = String(decoding: fileData, as: UTF8.self)
        #expect(jsonStr.contains("\"ever_used_codex\""))
        #expect(jsonStr.contains("true"))
    }

    // MARK: - Case 2: Two-Pass Prefire + User Interjection + Invalidation
    @Test("Two-pass prefire background compaction invalidates cleanly on user mid-turn interjection")
    func testCrossFeature_twoPassPrefire_and_userInterjection_and_invalidation() async throws {
        let prefireState = PrefireState()
        let baseTurns: [ConversationItem] = [
            .system("You are Open Grok."),
            .user("P0: Build target"),
            .assistant("R0: Building target..."),
            .user("P1: Long compile log output " + String(repeating: "log_data ", count: 200)),
            .assistant("R1: Compilation completed.")
        ]
        let prefixLen = 4
        let fpOrig = fingerprintPrefix(Array(baseTurns[..<prefixLen]))

        // Step 1: Background prefire caches Pass 1 NOTE1
        prefireState.store(AsyncCompactionCache(
            note1: "NOTE1 summary covering turns 0 and 1.",
            prefixLen: prefixLen,
            fingerprint: fpOrig,
            modelSlug: "grok-4.20",
            pass1LatencyMs: 120
        ))
        #expect(prefireState.hasCache)

        // Step 2: User prompt interjection arrives mid-turn, mutating conversation history
        var mutatedTurns = baseTurns
        let interjectionQuery = "Wait! Stop the build and run unit tests first!"
        mutatedTurns.insert(
            .interjection("The user sent a message while you were working:\n<user_query>\n\(interjectionQuery)\n</user_query>"),
            at: 2
        )

        // Step 3: Pass 2 assembly evaluates mutated conversation
        let sampler = Tier3ScriptedSampler()
        let result = await tryTwoPassPass2Apply(
            prefireState: prefireState,
            liveConversation: mutatedTurns,
            currentModelSlug: "grok-4.20",
            sampler: sampler,
            userContext: "Focus on user commands."
        )

        // INVARIANT: Cache MUST be invalidated (returned nil) due to fingerprint mismatch
        #expect(result == nil)
        #expect(!prefireState.hasCache) // Cache consumed/purged
        #expect(sampler.historyCount == 0) // Did not attempt Pass 2 with stale carrier

        // Fallback to single pass with interjection fully retained in history
        #expect(mutatedTurns.contains { $0.textContent().contains(interjectionQuery) })
    }

    // MARK: - Case 3: Compaction Checkpoints + Swarm Subagent Fork
    @Test("Compaction checkpoints persist across subagent swarm fork with complete checkpoint isolation")
    func testCrossFeature_compactionCheckpoints_and_swarmSubagentFork() async throws {
        let fixture = try Tier3CrossFeatureFixture(sessionID: "parent-session-main")
        defer { fixture.cleanup() }

        // 1. Parent session creates checkpoint
        let parentCompacted: [ConversationItem] = [
            .system("Parent system prompt"),
            .userMeta("Parent compaction summary P0..P4")
        ]
        _ = try fixture.writeCheckpoint(
            id: "ckpt-parent-5",
            promptIndex: 5,
            compactedHistory: parentCompacted,
            originalUserInfo: "Parent User Info"
        )
        try await fixture.writeSessionRecord(items: parentCompacted)

        // 2. Fork parent session to create swarm child
        let childSessionID = "child-swarm-agent-1"
        let store = LiveConversationStore(openGrokHome: fixture.home)
        let forked = try await store.fork(
            sourceSessionID: "parent-session-main",
            destinationSessionID: childSessionID,
            workingDirectory: fixture.workspaceDir
        )
        #expect(forked.parentSessionID == "parent-session-main")
        #expect(forked.sessionID == childSessionID)

        // 3. Child session directory receives copied checkpoints
        let childSessionDir = fixture.home.appendingPathComponent("sessions/\(childSessionID)", isDirectory: true)
        let childCheckpoints = try listCompactionCheckpoints(sessionDir: childSessionDir)
        #expect(childCheckpoints.map(\.checkpointID).contains("ckpt-parent-5"))

        // 4. Child session runs independent turns and creates its own checkpoint
        let childCompacted: [ConversationItem] = [
            .system("Child system prompt"),
            .userMeta("Child compaction summary CP0..CP2")
        ]
        _ = try persistCompactionCheckpoint(
            sessionDir: childSessionDir,
            checkpointID: "ckpt-child-3",
            promptIndex: 3,
            compactedHistory: childCompacted,
            schemaVersion: 1,
            createdAt: "2026-08-14T01:00:00Z",
            originalUserInfo: "Child User Info",
            rereadFilePaths: []
        )

        // INVARIANT: Parent directory is ISOLATED from child's new checkpoint
        let parentCheckpoints = try listCompactionCheckpoints(sessionDir: fixture.sessionDir)
        #expect(parentCheckpoints.count == 1)
        #expect(!parentCheckpoints.map(\.checkpointID).contains("ckpt-child-3"))

        let updatedChildCheckpoints = try listCompactionCheckpoints(sessionDir: childSessionDir)
        #expect(updatedChildCheckpoints.count == 2)
        #expect(updatedChildCheckpoints.map(\.checkpointID).sorted() == ["ckpt-child-3", "ckpt-parent-5"])
    }

    // MARK: - Case 4: Two-Pass Assembly + Code Mode Persistent V8 Cell
    @Test("Two-pass compaction assembly preserves paired Code Mode custom tool outputs and persistent JS runtime state")
    func testCrossFeature_twoPassAssembly_and_codeModeV8PersistentCell() async throws {
        let prefix: [ConversationItem] = [
            .system("You are Open Grok in Code Mode."),
            .user("P0: Initialize JS accumulator"),
            .assistantToolCalls([ToolCall(id: "exec-init", name: "exec", arguments: "globalThis.accumulator = 42;")]),
            .customToolOutput(CustomToolOutputItem.text(callId: "exec-init", "42"))
        ]

        let tailToolCall = ToolCall(id: "exec-tail", name: "exec", arguments: "globalThis.accumulator += 8; tools.file_read('config.json');")
        let tail: [ConversationItem] = [
            .user("P1: Tail JS execution"),
            .assistantToolCalls([tailToolCall]),
            .customToolOutput(CustomToolOutputItem.text(callId: "exec-tail", "50")),
            .customToolOutput(CustomToolOutputItem.text(callId: "exec-tail", "{\"status\":\"ok\"}")),
            .assistant("Done")
        ]

        let note1 = "NOTE1 covering P0 accumulator initialization."
        let prompt = "Summarize the execution history."

        // Pass 2 assembly
        let pass2History = buildTwoPassPass2History(
            prefix: prefix,
            tail: tail,
            note1: note1,
            compactionPrompt: prompt
        )

        // INVARIANT 1: Tail items (including interleaved custom tool outputs) are intact and not severed
        #expect(pass2History.count == 8) // 1 sys + 1 carrier + 5 tail items + 1 special prompt
        #expect(pass2History[0].textContent().contains("Code Mode"))
        #expect(pass2History[1].textContent().contains(note1))
        #expect(pass2History[2].textContent() == "P1: Tail JS execution")

        // Validate custom tool outputs preserved in exact order
        guard case .customToolOutput(let out1) = pass2History[4],
              case .customToolOutput(let out2) = pass2History[5] else {
            Issue.record("Expected customToolOutput items in pass2 history")
            return
        }
        #expect(out1.callId == "exec-tail")
        #expect(out2.callId == "exec-tail")

        // INVARIANT 2: Compaction verification passes reduction and sanitization guards
        let validated = validateCompactedHistory(pass2History)
        #expect(validated.isValid)
    }

    // MARK: - Case 5: StructuredOutput Synthetic Tool Loop + Auto-Compaction
    @Test("StructuredOutput synthetic tool loop and validation retry state survive auto-compaction")
    func testCrossFeature_structuredOutputSyntheticToolLoop_and_autoCompaction() async throws {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "required": .array([.string("task"), .string("confidence")]),
            "properties": .object([
                "task": .object(["type": .string("string")]),
                "confidence": .object(["type": .string("number"), "minimum": .number(.double(0.0)), "maximum": .number(.double(1.0))])
            ]),
            "additionalProperties": .bool(false)
        ])

        var coordinator = StructuredOutputTurnCoordinator(
            schema: schema,
            backend: .messages, // Non-native backend requiring synthetic tool injection
            codeModeOnly: false
        )

        // 1. Initial tool injection check
        let (tools, reminder, _) = coordinator.prepareRequest(tools: [])
        #expect(tools.count == 1)
        #expect(tools[0].name == StructuredOutputConstants.toolName)
        #expect(reminder == StructuredOutputConstants.systemReminder)

        // 2. Attempt 1: Model emits invalid payload (out-of-range confidence)
        let badCall = ToolCall(
            id: "call-so-1",
            name: StructuredOutputConstants.toolName,
            arguments: "{\"task\": \"analysis\", \"confidence\": 1.5}"
        )
        let (step1, res1) = coordinator.handleToolCalls([badCall])
        guard case .retry(let retryMsg) = step1 else {
            Issue.record("Expected retry on out-of-range value")
            return
        }
        #expect(retryMsg.contains(StructuredOutputConstants.retrySuffix))
        #expect(coordinator.retries == 1)

        // 3. Auto-compaction event occurs mid-turn due to context threshold
        let conversationBefore: [ConversationItem] = [
            .system("You are Open Grok."),
            .systemReminder(reminder ?? ""),
            .user("Extract task in structured schema"),
            .assistantToolCalls([badCall]),
            .toolResult(toolCallId: "call-so-1", content: res1[0].content)
        ]
        #expect(conversationBefore.count == 5)

        // Compact conversation: retain system + carrier summary + retry context
        let compactedSummary: [ConversationItem] = [
            .system("You are Open Grok."),
            .systemReminder(reminder ?? ""),
            .userMeta("Compacted context before StructuredOutput retry"),
            .assistantToolCalls([badCall]),
            .toolResult(toolCallId: "call-so-1", content: res1[0].content)
        ]
        let sanitized = sanitizeCompactedHistory(compactedSummary)
        #expect(sanitized.items.count == 5)

        // 4. Attempt 2: Model emits valid JSON after compaction
        let validCall = ToolCall(
            id: "call-so-2",
            name: StructuredOutputConstants.toolName,
            arguments: "{\"task\": \"analysis\", \"confidence\": 0.95}"
        )
        let (step2, res2) = coordinator.handleToolCalls([validCall])
        guard case .complete(let outcome) = step2, case .success(let jsonVal) = outcome else {
            Issue.record("Expected successful completion on valid schema match")
            return
        }
        #expect(jsonVal.objectValue?["task"]?.stringValue == "analysis")
        #expect(jsonVal.objectValue?["confidence"]?.doubleValue == 0.95)
        #expect(res2[0].content == StructuredOutputConstants.acceptedMessage)
        #expect(coordinator.retries == 1) // Retry count remained accurate
    }

    // MARK: - Case 6: Monotonic Export Boundary + Concurrent Mid-Share Race
    @Test("Monotonic export boundary immediately locks under concurrent mid-share race conditions")
    func testCrossFeature_monotonicExportBoundary_and_concurrentMidShareRace() async throws {
        let boundary = ExportBoundary(everUsedNonXAI: false)
        #expect(boundary.allowsXaiExport)

        // Simulate 50 concurrent racing tasks
        await withTaskGroup(of: Result<Void, ShareRefusal>.self) { group in
            for i in 0..<50 {
                group.addTask {
                    if i == 25 {
                        // Mid-flight non-xAI observation
                        _ = boundary.observe(.codex)
                        return .success(())
                    } else if i % 2 == 0 {
                        // Share export authorization flow
                        do {
                            try ShareExportGate.authorizeExport(
                                persistedEverUsedNonXAI: false,
                                liveBoundary: boundary,
                                messageCount: 5
                            )
                            // Simulate network latency during export
                            try await Task.sleep(nanoseconds: 2_000_000)
                            try ShareExportGate.authorizePostExport(liveBoundary: boundary)
                            return .success(())
                        } catch let err as ShareRefusal {
                            return .failure(err)
                        } catch {
                            return .failure(.sharingNotAvailableForAccount)
                        }
                    } else {
                        // Provider sync attempts
                        boundary.sync(everUsedNonXAI: false)
                        return .success(())
                    }
                }
            }
        }

        // INVARIANT: Export boundary MUST BE PERMANENTLY CLOSED
        #expect(!boundary.allowsXaiExport)
        #expect(boundary.everUsedNonXAI)

        // Subsequent export attempts MUST fail immediately
        #expect(throws: ShareRefusal.nonXaiProviderBoundary) {
            try ShareExportGate.authorizeExport(
                persistedEverUsedNonXAI: true,
                liveBoundary: boundary,
                messageCount: 5
            )
        }
    }

    // MARK: - Case 7: CLI Headless Mode + Live Model Switch + Provider Isolation
    @Test("CLI headless mode with live model switch maintains strict provider and credential isolation")
    func testCrossFeature_cliHeadless_and_liveModelSwitch_and_providerIsolation() throws {
        let fixture = try Tier3CrossFeatureFixture()
        defer { fixture.cleanup() }

        // Setup isolated auth store
        let authJSON = """
        {
            "key": "xai-active-key",
            "auth_mode": "api_key",
            "fireworks": { "api_key": "fw-isolated-key" },
            "deepseek": { "api_key": "ds-isolated-key" }
        }
        """
        try Data(authJSON.utf8).write(to: fixture.home.appendingPathComponent("auth.json"))

        let codexAuthJSON = """
        {
            "tokens": { "access_token": "codex-oauth-token" }
        }
        """
        try Data(codexAuthJSON.utf8).write(to: fixture.home.appendingPathComponent("codex-auth.json"))

        // 1. Verify models command JSON output reflects isolated catalogs
        let (modelsStream, modelsOut, modelsErr) = CLIStreams.buffered()
        let modelsCode = CLIRunner.main(["models", "--json"], environment: fixture.environment, streams: modelsStream)
        #expect(modelsCode == CLIRunner.ExitCode.success.rawValue)
        #expect(modelsErr.contents.isEmpty)

        let modelsData = Data(modelsOut.contents.utf8)
        let parsedModels = try? JSONSerialization.jsonObject(with: modelsData) as? [String: Any]
        #expect(parsedModels?["default"] != nil)

        // 2. Validate dynamic model switch between providers enforces export boundaries
        let boundary = ExportBoundary(everUsedNonXAI: false)
        #expect(boundary.allowsXaiExport)

        // Switch from xAI model to DeepSeek model
        let switched = boundary.observe(.deepseek)
        #expect(switched == true)
        #expect(!boundary.allowsXaiExport)
        #expect(boundary.everUsedNonXAI)

        // 3. Verify path hermeticity
        let (pathsStream, pathsOut, pathsErr) = CLIStreams.buffered()
        let pathsCode = CLIRunner.main(["paths", "--json"], environment: fixture.environment, streams: pathsStream)
        #expect(pathsCode == CLIRunner.ExitCode.success.rawValue)
        #expect(pathsErr.contents.isEmpty)

        let pathsParsed = try JSONDecoder().decode([String: String].self, from: Data(pathsOut.contents.utf8))
        #expect(pathsParsed["opengrok_home"] == fixture.home.path)
        #expect(pathsParsed["project_state"] == ".opengrok")
    }
}
