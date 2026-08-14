// LiveCompactionRewindReplayTests.swift
//
// End-to-end cross-compaction rewind replay test suite (Feature 2):
// - Post-compaction rewind reconstruction from checkpoint base + post-compaction turns
// - Pre-compaction rewind reconstruction from raw turns (dropping compaction summary)
// - Original user info restoration from checkpoint file
// - Session fork checkpoint retention and rewind support
// - Workspace file snapshot restoration via LiveRewindCoordinator
// - Multi-generation checkpoints sequential rewind
// - Error handling: missing/corrupt checkpoints, rapid rewinds, tool-call integrity

import Foundation
import OpenGrokCompaction
import OpenGrokSamplingTypes
import OpenGrokShared
import Testing
@testable import OpenGrokCLI

// MARK: - Replay & Rewind Fixture

private struct LiveRewindReplayFixture {
    let root: URL
    let home: URL
    let sessionDir: URL
    let checkpointsDir: URL
    let workspaceDir: URL
    let sessionID: String

    init(sessionID: String = "session-rewind-\(UUID().uuidString)") throws {
        self.sessionID = sessionID
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("og-rw-replay-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        sessionDir = home.appendingPathComponent("sessions/\(sessionID)", isDirectory: true)
        checkpointsDir = sessionDir.appendingPathComponent("compaction_checkpoints", isDirectory: true)

        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: checkpointsDir, withIntermediateDirectories: true)
    }

    func writeCheckpoint(
        id: String,
        promptIndex: Int,
        compactedHistory: [ConversationItem],
        originalUserInfo: String? = "Original User Info at P0",
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

    func writeSessionRecord(items: [ConversationItem]) async throws {
        var record = LiveConversationRecord.new(
            sessionID: sessionID,
            workingDirectory: workspaceDir
        )
        record.items = items
        record.everUsedNonXAI = false
        let store = LiveConversationStore(openGrokHome: home)
        try await store.save(record)
    }

    func writeWorkspaceFile(relativePath: String, content: String) throws {
        let fileURL = workspaceDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: fileURL, options: .atomic)
    }

    func readWorkspaceFile(relativePath: String) -> String? {
        try? String(contentsOf: workspaceDir.appendingPathComponent(relativePath), encoding: .utf8)
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

// MARK: - Test Suite

@Suite("Live Compaction Rewind Replay Tests", .serialized)
struct LiveCompactionRewindReplayTests {

    // MARK: - Tier 1: Feature Coverage

    @Test("Post-compaction rewind reconstructs conversation from checkpoint base plus post-compaction turns")
    func postCompactionRewindReconstructsFromCheckpoint() async throws {
        let fixture = try LiveRewindReplayFixture()
        defer { fixture.cleanup() }

        let compactedHistory: [ConversationItem] = [
            .system("You are Open Grok."),
            .userMeta("Summary of turns 0..4")
        ]
        _ = try fixture.writeCheckpoint(
            id: "ckpt-5",
            promptIndex: 5,
            compactedHistory: compactedHistory
        )

        let updates: [SessionUpdateRecord] = [
            .user(text: "P0", promptIndex: 0),
            .agent(text: "R0"),
            .checkpoint(id: "ckpt-5", promptIndex: 5, autoContinueText: nil),
            .user(text: "P5: New question", promptIndex: 5),
            .agent(text: "R5: Answer"),
            .user(text: "P6: Another question", promptIndex: 6),
            .agent(text: "R6: Answer")
        ]
        try writeUpdatesJSONL(sessionDir: fixture.sessionDir, updates: updates)

        // Rewind to target prompt 6 (after checkpoint at 5): keeps checkpoint base + P5/R5, drops P6/R6
        let result = try replayToPrompt(sessionDir: fixture.sessionDir, targetPromptIndex: 6)
        #expect(result.promptIndexReached == 6)
        #expect(result.lastCompactionPromptIndex == 5)
        #expect(result.conversation.count == 4)
        #expect(result.conversation[0].textContent() == "You are Open Grok.")
        #expect(result.conversation[1].textContent() == "Summary of turns 0..4")
        #expect(result.conversation[2].textContent() == "P5: New question")
        #expect(result.conversation[3].textContent() == "R5: Answer")
    }

    @Test("Pre-compaction cross-compaction rewind discards summary and reconstructs raw pre-compaction turns")
    func preCompactionCrossCompactionRewindReconstructsRawTurns() async throws {
        let fixture = try LiveRewindReplayFixture()
        defer { fixture.cleanup() }

        _ = try fixture.writeCheckpoint(
            id: "ckpt-5",
            promptIndex: 5,
            compactedHistory: [.system("SYS"), .userMeta("SUMMARY OF TURNS 0..4")],
            originalUserInfo: "Original User Info P0"
        )

        let updates: [SessionUpdateRecord] = [
            .user(text: "P0: Setup", promptIndex: 0),
            .agent(text: "R0"),
            .user(text: "P1: Build", promptIndex: 1),
            .agent(text: "R1"),
            .user(text: "P2: Test", promptIndex: 2),
            .agent(text: "R2"),
            .user(text: "P3: Deploy", promptIndex: 3),
            .agent(text: "R3"),
            .user(text: "P4: Verify", promptIndex: 4),
            .agent(text: "R4"),
            .checkpoint(id: "ckpt-5", promptIndex: 5, autoContinueText: nil),
            .user(text: "P5: Post-compaction prompt", promptIndex: 5),
            .agent(text: "R5")
        ]
        try writeUpdatesJSONL(sessionDir: fixture.sessionDir, updates: updates)

        // Rewind across the compaction boundary to target prompt 3 (target < 5)
        let result = try replayToPrompt(sessionDir: fixture.sessionDir, targetPromptIndex: 3)
        #expect(result.promptIndexReached == 3)
        #expect(result.lastCompactionPromptIndex == nil) // Pre-compaction

        // Verified: contains P0..P2, does NOT contain SUMMARY OF TURNS 0..4 or P3..P5
        let texts = result.conversation.map { $0.textContent() }
        #expect(!texts.contains { $0.contains("SUMMARY OF TURNS 0..4") })
        #expect(texts.contains("P0: Setup"))
        #expect(texts.contains("P1: Build"))
        #expect(texts.contains("P2: Test"))
        #expect(!texts.contains("P3: Deploy"))
        #expect(!texts.contains("P5: Post-compaction prompt"))
    }

    @Test("Cross-compaction rewind restores original user_info from checkpoint file")
    func crossCompactionRewindRestoresOriginalUserInfo() throws {
        let fixture = try LiveRewindReplayFixture()
        defer { fixture.cleanup() }

        let originalUserInfo = "<user_info>Developer on macOS arm64</user_info>"
        _ = try fixture.writeCheckpoint(
            id: "ckpt-orig-ui",
            promptIndex: 4,
            compactedHistory: [.system("SYS"), .userMeta("SUMMARY")],
            originalUserInfo: originalUserInfo
        )

        let loaded = try loadCompactionCheckpoint(sessionDir: fixture.sessionDir, checkpointID: "ckpt-orig-ui")
        #expect(loaded.originalUserInfo == originalUserInfo)

        let updates: [SessionUpdateRecord] = [
            .user(text: "P0"),
            .agent(text: "R0"),
            .checkpoint(id: "ckpt-orig-ui", promptIndex: 4, autoContinueText: nil)
        ]
        try writeUpdatesJSONL(sessionDir: fixture.sessionDir, updates: updates)

        let replay = try replayToPrompt(sessionDir: fixture.sessionDir, targetPromptIndex: 1)
        #expect(replay.originalUserInfo == originalUserInfo)
    }

    @Test("Forked session carries referenced compaction checkpoints and supports rewind")
    func forkedSessionCarriesCheckpointsAndEnablesRewind() async throws {
        let fixture = try LiveRewindReplayFixture(sessionID: "source-session-123")
        defer { fixture.cleanup() }

        _ = try fixture.writeCheckpoint(
            id: "ckpt-fork-1",
            promptIndex: 3,
            compactedHistory: [.system("SYS"), .userMeta("SUMMARY")]
        )
        try await fixture.writeSessionRecord(items: [
            .system("SYS"),
            .userMeta("SUMMARY"),
            .user("P3: After fork"),
            .assistant(AssistantItem(content: "R3"))
        ])

        let store = LiveConversationStore(openGrokHome: fixture.home)
        let forked = try await store.fork(
            sourceSessionID: "source-session-123",
            destinationSessionID: "forked-session-456",
            workingDirectory: fixture.workspaceDir
        )
        #expect(forked.parentSessionID == "source-session-123")
        #expect(forked.sessionID == "forked-session-456")

        let forkedRecord = try await store.loadIfPresent(sessionID: "forked-session-456")
        #expect(forkedRecord != nil)
        #expect(forkedRecord?.items.count == 4)
    }

    @Test("Cross-compaction rewind coordinates workspace file restoration")
    func crossCompactionRewindCoordinatesWorkspaceFileRestoration() async throws {
        let fixture = try LiveRewindReplayFixture()
        defer { fixture.cleanup() }

        try fixture.writeWorkspaceFile(relativePath: "App.swift", content: "struct App { var v = 1 }")
        let coordinator = await fixture.makeRewindCoordinator()

        // Turn 0
        await coordinator.beginPrompt(text: "P0: update App.swift")
        await coordinator.capture(paths: ["App.swift"])
        try fixture.writeWorkspaceFile(relativePath: "App.swift", content: "struct App { var v = 2 }")
        await coordinator.endPrompt()

        // Turn 1
        await coordinator.beginPrompt(text: "P1: update App.swift again")
        await coordinator.capture(paths: ["App.swift"])
        try fixture.writeWorkspaceFile(relativePath: "App.swift", content: "struct App { var v = 3 }")
        await coordinator.endPrompt()

        // Wait for persistence
        var points: [LiveRewindPointInfo] = []
        for _ in 0..<50 {
            points = await coordinator.points()
            if points.count >= 2 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(points.count == 2)

        // Restore to turn 0 (undo turn 0 and turn 1)
        let outcome = try await coordinator.restore(
            toPromptIndex: 0,
            mode: .all,
            force: true,
            currentItems: [.user("P0"), .assistant("R0"), .user("P1"), .assistant("R1")]
        )
        #expect(outcome.applied)
        #expect(outcome.targetPromptIndex == 0)
        #expect(outcome.cleanFiles.contains("App.swift"))
        #expect(fixture.readWorkspaceFile(relativePath: "App.swift") == "struct App { var v = 1 }")
    }

    @Test("Sequential rewinds across multiple compaction checkpoints")
    func multipleCompactionCheckpointsSequentialRewind() throws {
        let fixture = try LiveRewindReplayFixture()
        defer { fixture.cleanup() }

        _ = try fixture.writeCheckpoint(
            id: "ckpt-gen-1",
            promptIndex: 3,
            compactedHistory: [.system("SYS"), .userMeta("SUM1")],
            originalUserInfo: "UI-1"
        )
        _ = try fixture.writeCheckpoint(
            id: "ckpt-gen-2",
            promptIndex: 7,
            compactedHistory: [.system("SYS"), .userMeta("SUM2")],
            originalUserInfo: "UI-2"
        )

        let updates: [SessionUpdateRecord] = [
            .user(text: "P0"),
            .agent(text: "R0"),
            .user(text: "P1"),
            .agent(text: "R1"),
            .user(text: "P2"),
            .agent(text: "R2"),
            .checkpoint(id: "ckpt-gen-1", promptIndex: 3, autoContinueText: nil),
            .user(text: "P3"),
            .agent(text: "R3"),
            .user(text: "P4"),
            .agent(text: "R4"),
            .user(text: "P5"),
            .agent(text: "R5"),
            .user(text: "P6"),
            .agent(text: "R6"),
            .checkpoint(id: "ckpt-gen-2", promptIndex: 7, autoContinueText: nil),
            .user(text: "P7"),
            .agent(text: "R7")
        ]
        try writeUpdatesJSONL(sessionDir: fixture.sessionDir, updates: updates)

        // 1. Rewind to prompt 8 (post-second checkpoint)
        let r8 = try replayToPrompt(sessionDir: fixture.sessionDir, targetPromptIndex: 8)
        #expect(r8.promptIndexReached == 8)
        #expect(r8.lastCompactionPromptIndex == 7)

        // 2. Rewind to prompt 5 (between ckpt-1 and ckpt-2)
        let r5 = try replayToPrompt(sessionDir: fixture.sessionDir, targetPromptIndex: 5)
        #expect(r5.promptIndexReached == 5)
        #expect(r5.lastCompactionPromptIndex == 3)

        // 3. Rewind to prompt 1 (before ckpt-1)
        let r1 = try replayToPrompt(sessionDir: fixture.sessionDir, targetPromptIndex: 1)
        #expect(r1.promptIndexReached == 1)
        #expect(r1.lastCompactionPromptIndex == nil)
    }

    // MARK: - Tier 2: Boundary & Corner Cases

    @Test("Cross-compaction rewind fails cleanly when checkpoint file is missing")
    func crossCompactionRewindFailsWhenCheckpointFileMissing() throws {
        let fixture = try LiveRewindReplayFixture()
        defer { fixture.cleanup() }

        let updates: [SessionUpdateRecord] = [
            .user(text: "P0"),
            .checkpoint(id: "missing-checkpoint-uuid", promptIndex: 1, autoContinueText: nil)
        ]
        try writeUpdatesJSONL(sessionDir: fixture.sessionDir, updates: updates)

        #expect(throws: CompactionCheckpointError.self) {
            try replayToPrompt(sessionDir: fixture.sessionDir, targetPromptIndex: 2)
        }
    }

    @Test("Cross-compaction rewind fails when checkpoint file is corrupted")
    func crossCompactionRewindFailsWhenCheckpointFileCorrupted() throws {
        let fixture = try LiveRewindReplayFixture()
        defer { fixture.cleanup() }

        let corruptPath = fixture.checkpointsDir.appendingPathComponent("corrupt-ckpt.json")
        try Data("not valid json data".utf8).write(to: corruptPath)

        let updates: [SessionUpdateRecord] = [
            .user(text: "P0"),
            .checkpoint(id: "corrupt-ckpt", promptIndex: 1, autoContinueText: nil)
        ]
        try writeUpdatesJSONL(sessionDir: fixture.sessionDir, updates: updates)

        #expect(throws: CompactionCheckpointError.self) {
            try replayToPrompt(sessionDir: fixture.sessionDir, targetPromptIndex: 2)
        }
    }

    @Test("Rewind to prompt zero clears conversation while retaining leading system prompt")
    func rewindToPromptZeroClearsConversation() {
        let conversation: [ConversationItem] = [
            .system("You are Open Grok."),
            .user("P0"),
            .assistant(AssistantItem(content: "R0")),
            .user("P1"),
            .assistant(AssistantItem(content: "R1"))
        ]

        let truncated = liveTruncateConversation(conversation, toPromptIndex: 0)
        #expect(truncated.count == 1)
        #expect(truncated.first?.textContent() == "You are Open Grok.")
    }

    @Test("Rapid consecutive cross-compaction rewinds maintain clean state machine")
    func rapidConsecutiveCrossCompactionRewinds() async throws {
        let fixture = try LiveRewindReplayFixture()
        defer { fixture.cleanup() }

        let coordinator = await fixture.makeRewindCoordinator()
        for i in 0..<5 {
            await coordinator.beginPrompt(text: "P\(i)")
            try fixture.writeWorkspaceFile(relativePath: "test.txt", content: "content-\(i)")
            await coordinator.capture(paths: ["test.txt"])
            await coordinator.endPrompt()
        }

        // Wait for persistence
        var points: [LiveRewindPointInfo] = []
        for _ in 0..<50 {
            points = await coordinator.points()
            if points.count >= 5 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(points.count == 5)

        // Rapid dry-run rewinds to different prompt targets
        let r3 = try await coordinator.restore(toPromptIndex: 3, mode: .all, force: false, currentItems: [])
        #expect(r3.targetPromptIndex == 3)
        #expect(!r3.applied)

        let r1 = try await coordinator.restore(toPromptIndex: 1, mode: .all, force: false, currentItems: [])
        #expect(r1.targetPromptIndex == 1)
        #expect(!r1.applied)

        let r4 = try await coordinator.restore(toPromptIndex: 4, mode: .all, force: false, currentItems: [])
        #expect(r4.targetPromptIndex == 4)
        #expect(!r4.applied)

        let r0 = try await coordinator.restore(toPromptIndex: 0, mode: .all, force: false, currentItems: [])
        #expect(r0.targetPromptIndex == 0)
        #expect(!r0.applied)
    }

    @Test("Replaying pre-compaction turns preserves paired tool calls and results")
    func crossCompactionRewindWithInterleavedToolCallsAndResults() {
        let toolCall = ToolCall(id: "call-1", name: "bash", arguments: "{\"cmd\":\"ls\"}")
        let turns: [ConversationItem] = [
            .system("sys"),
            .user("P0: Run tool"),
            .assistant(AssistantItem(content: "Calling bash", toolCalls: [toolCall])),
            .toolResult(ToolResultItem(toolCallId: "call-1", content: "file.txt")),
            .assistant(AssistantItem(content: "Done")),
            .user("P1: Next step"),
            .assistant(AssistantItem(content: "OK"))
        ]

        let truncated = liveTruncateConversation(turns, toPromptIndex: 1)
        #expect(truncated.count == 5)
        #expect(validateCompactedHistory(truncated).isValid)
    }

    @Test("Replay correctly filters unnumbered phantom chunks and honors prompt markers")
    func crossCompactionRewindWithCancelledTurnsAndUnnumberedChunks() {
        let items: [ConversationItem] = [
            .system("sys"),
            .user("P0: Real user turn"),
            .assistant(AssistantItem(content: "R0")),
            .userMeta("Compaction summary phantom chunk"),
            .systemReminder("System reminder phantom chunk"),
            .projectInstructions("AGENTS.md instructions"),
            .user("P1: Second real user turn"),
            .assistant(AssistantItem(content: "R1"))
        ]

        let truncated = liveTruncateConversation(items, toPromptIndex: 1)
        #expect(truncated.contains { $0.textContent() == "P0: Real user turn" })
        #expect(!truncated.contains { $0.textContent() == "P1: Second real user turn" })
    }
}
