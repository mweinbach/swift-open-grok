// CompactionCheckpointTests.swift
//
// Open Grok — Comprehensive test suite for compaction checkpoints, schema serialization,
// disk persistence, and cross-compaction rewind replay.

import Foundation
import Testing
@testable import OpenGrokCompaction
@testable import OpenGrokSamplingTypes
@testable import OpenGrokChatState

@Suite("Compaction Checkpoint & Cross-Compaction Rewind Tests")
struct CompactionCheckpointTests {

    // MARK: - 1. Serialization & Schema Tests

    @Test("CompactionCheckpointFile JSON round-trip serialization")
    func checkpointFileRoundTrip() throws {
        let items: [ConversationItem] = [
            .system("System prompt"),
            .user("Summary of turns 0..4"),
        ]
        let file = CompactionCheckpointFile(
            checkpointID: "ckpt-uuid-1234",
            promptIndexAtCompaction: 5,
            compactedHistory: items,
            schemaVersion: 1,
            createdAt: "2026-08-14T12:00:00Z",
            originalUserInfo: "User info v0",
            rereadFilePaths: ["Sources/Main.swift"]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(file)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(CompactionCheckpointFile.self, from: data)

        #expect(decoded.checkpointID == file.checkpointID)
        #expect(decoded.promptIndexAtCompaction == 5)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.createdAt == "2026-08-14T12:00:00Z")
        #expect(decoded.originalUserInfo == "User info v0")
        #expect(decoded.rereadFilePaths == ["Sources/Main.swift"])
        #expect(decoded.compactedHistory.count == 2)
        #expect(decoded.isSupportedSchemaVersion)
    }

    @Test("CompactionCheckpointInfo JSON round-trip serialization")
    func checkpointInfoRoundTrip() throws {
        let info = CompactionCheckpointInfo(
            checkpointID: "ckpt-uuid-5678",
            promptIndexAtCompaction: 10,
            checkpointFile: "compaction_checkpoints/ckpt-uuid-5678.json",
            autoContinue: AutoContinueInfo(promptText: "Continue working"),
            schemaVersion: 1,
            createdAt: "2026-08-14T12:00:00Z"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(info)
        let decoded = try JSONDecoder().decode(CompactionCheckpointInfo.self, from: data)

        #expect(decoded.checkpointID == "ckpt-uuid-5678")
        #expect(decoded.promptIndexAtCompaction == 10)
        #expect(decoded.checkpointFile == "compaction_checkpoints/ckpt-uuid-5678.json")
        #expect(decoded.autoContinue?.promptText == "Continue working")
        #expect(decoded.schemaVersion == 1)
    }

    @Test("Unsupported schema version (> 1) throws invalid data error")
    func unsupportedSchemaVersion() throws {
        let json = """
        {
            "checkpoint_id": "ckpt-future",
            "prompt_index_at_compaction": 5,
            "compacted_history": [],
            "schema_version": 2,
            "created_at": "2026-08-14T12:00:00Z"
        }
        """.data(using: .utf8)!

        let file = try JSONDecoder().decode(CompactionCheckpointFile.self, from: json)
        #expect(file.schemaVersion == 2)
        #expect(!file.isSupportedSchemaVersion)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-unsupported-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent("compaction_checkpoints"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let ckptURL = tempDir.appendingPathComponent("compaction_checkpoints/ckpt-future.json")
        try json.write(to: ckptURL)

        #expect(throws: CompactionCheckpointError.self) {
            _ = try loadCompactionCheckpoint(sessionDir: tempDir, checkpointID: "ckpt-future")
        }
    }

    // MARK: - 2. Disk Persistence Tests

    @Test("Persist, load, list, and copy checkpoints on disk")
    func diskPersistenceOperations() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-compaction-ckpt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let items: [ConversationItem] = [.system("Sys"), .user("Summary")]
        let info1 = try persistCompactionCheckpoint(
            sessionDir: tempDir,
            checkpointID: "ckpt-1",
            promptIndex: 3,
            compactedHistory: items,
            originalUserInfo: "UI1"
        )
        let info2 = try persistCompactionCheckpoint(
            sessionDir: tempDir,
            checkpointID: "ckpt-2",
            promptIndex: 7,
            compactedHistory: items,
            originalUserInfo: "UI1"
        )

        #expect(info1.checkpointFile == "compaction_checkpoints/ckpt-1.json")
        #expect(info2.checkpointFile == "compaction_checkpoints/ckpt-2.json")

        let loaded1 = try loadCompactionCheckpoint(sessionDir: tempDir, checkpointID: "ckpt-1")
        #expect(loaded1.checkpointID == "ckpt-1")
        #expect(loaded1.promptIndexAtCompaction == 3)
        #expect(loaded1.originalUserInfo == "UI1")

        let listed = try listCompactionCheckpoints(sessionDir: tempDir)
        #expect(listed.count == 2)
        #expect(listed.map(\.checkpointID).sorted() == ["ckpt-1", "ckpt-2"])

        // Test copyCheckpoints to destination directory
        let destDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-dest-ckpt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destDir) }

        let copied = try copyCheckpoints(from: tempDir, to: destDir)
        #expect(copied == 2)
        let destListed = try listCompactionCheckpoints(sessionDir: destDir)
        #expect(destListed.count == 2)
    }

    @Test("Loading missing checkpoint throws missing file error")
    func loadingMissingCheckpoint() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-missing-ckpt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        #expect(throws: CompactionCheckpointError.self) {
            _ = try loadCompactionCheckpoint(sessionDir: tempDir, checkpointID: "nonexistent")
        }
    }

    // MARK: - 3. Cross-Compaction Rewind Replay Tests

    @Test("Rewind to pre-compaction prompt truncates summary and restores original user info")
    func rewindPreCompaction() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-rw-pre-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Fixture: P0..P4 -> Compaction at 5 -> P5, P6
        try persistCompactionCheckpoint(
            sessionDir: tempDir,
            checkpointID: "ckpt-5",
            promptIndex: 5,
            compactedHistory: [.system("SYS"), .user("SUMMARY")],
            originalUserInfo: "UI0"
        )

        let updates: [SessionUpdateRecord] = [
            .user(text: "P0", promptIndex: 0),
            .agent(text: "R0"),
            .user(text: "P1", promptIndex: 1),
            .agent(text: "R1"),
            .user(text: "P2", promptIndex: 2),
            .agent(text: "R2"),
            .user(text: "P3", promptIndex: 3),
            .agent(text: "R3"),
            .user(text: "P4", promptIndex: 4),
            .checkpoint(id: "ckpt-5", promptIndex: 5),
            .user(text: "P5", promptIndex: 5),
            .agent(text: "R5"),
            .user(text: "P6", promptIndex: 6),
        ]
        try writeUpdatesJSONL(sessionDir: tempDir, updates: updates)

        // Replay to prompt 3 (pre-compaction)
        let result = try replayToPrompt(
            sessionDir: tempDir,
            targetPromptIndex: 3
        )

        #expect(result.promptIndexReached == 3)
        #expect(result.lastCompactionPromptIndex == nil)
        #expect(result.originalUserInfo == "UI0")

        let texts = result.conversation.map { $0.textContent() }
        #expect(texts == ["SYS", "UI0", "P0", "R0", "P1", "R1", "P2", "R2"])
        #expect(!texts.contains("SUMMARY"))
        #expect(!texts.contains("P3"))
        #expect(!texts.contains("P5"))
    }

    @Test("Rewind to post-compaction prompt preserves checkpoint base and truncates tail")
    func rewindPostCompaction() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-rw-post-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try persistCompactionCheckpoint(
            sessionDir: tempDir,
            checkpointID: "ckpt-5",
            promptIndex: 5,
            compactedHistory: [.system("SYS"), .user("SUMMARY")],
            originalUserInfo: "UI0"
        )

        let updates: [SessionUpdateRecord] = [
            .user(text: "P0", promptIndex: 0),
            .user(text: "P1", promptIndex: 1),
            .user(text: "P2", promptIndex: 2),
            .user(text: "P3", promptIndex: 3),
            .user(text: "P4", promptIndex: 4),
            .checkpoint(id: "ckpt-5", promptIndex: 5),
            .user(text: "P5", promptIndex: 5),
            .agent(text: "R5"),
            .user(text: "P6", promptIndex: 6),
            .agent(text: "R6"),
            .user(text: "P7", promptIndex: 7),
        ]
        try writeUpdatesJSONL(sessionDir: tempDir, updates: updates)

        // Replay to prompt 6 (post-compaction)
        let result = try replayToPrompt(
            sessionDir: tempDir,
            targetPromptIndex: 6
        )

        #expect(result.promptIndexReached == 6)
        #expect(result.lastCompactionPromptIndex == 5)

        let texts = result.conversation.map { $0.textContent() }
        #expect(texts == ["SYS", "SUMMARY", "P5", "R5"])
        #expect(!texts.contains("P6"))
        #expect(!texts.contains("P7"))
    }

    @Test("Rewind across multiple compactions restores correct intermediate stage")
    func rewindMultipleCompactions() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-rw-multi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try persistCompactionCheckpoint(
            sessionDir: tempDir,
            checkpointID: "ckpt-1",
            promptIndex: 2,
            compactedHistory: [.system("SYS"), .user("SUMMARY_1")],
            originalUserInfo: "UI0"
        )
        try persistCompactionCheckpoint(
            sessionDir: tempDir,
            checkpointID: "ckpt-2",
            promptIndex: 4,
            compactedHistory: [.system("SYS"), .user("SUMMARY_2")],
            originalUserInfo: "UI0"
        )

        let updates: [SessionUpdateRecord] = [
            .user(text: "P0", promptIndex: 0),
            .user(text: "P1", promptIndex: 1),
            .checkpoint(id: "ckpt-1", promptIndex: 2),
            .user(text: "P2", promptIndex: 2),
            .agent(text: "R2"),
            .user(text: "P3", promptIndex: 3),
            .agent(text: "R3"),
            .checkpoint(id: "ckpt-2", promptIndex: 4),
            .user(text: "P4", promptIndex: 4),
            .agent(text: "R4"),
        ]
        try writeUpdatesJSONL(sessionDir: tempDir, updates: updates)

        // Case A: Rewind to 1 (before first compaction)
        let res1 = try replayToPrompt(sessionDir: tempDir, targetPromptIndex: 1)
        #expect(res1.promptIndexReached == 1)
        #expect(res1.lastCompactionPromptIndex == nil)
        #expect(res1.conversation.map { $0.textContent() } == ["SYS", "UI0", "P0"])

        // Case B: Rewind to 3 (between checkpoint 1 and 2)
        let res2 = try replayToPrompt(sessionDir: tempDir, targetPromptIndex: 3)
        #expect(res2.promptIndexReached == 3)
        #expect(res2.lastCompactionPromptIndex == 2)
        #expect(res2.conversation.map { $0.textContent() } == ["SYS", "SUMMARY_1", "P2", "R2"])
    }

    @Test("Rewind with RewindMarker correctly branches timelines")
    func rewindWithRewindMarker() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-rw-branch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try persistCompactionCheckpoint(
            sessionDir: tempDir,
            checkpointID: "ckpt-1",
            promptIndex: 2,
            compactedHistory: [.system("SYS"), .user("SUMMARY_1")],
            originalUserInfo: "UI0"
        )

        let updates: [SessionUpdateRecord] = [
            .user(text: "P0", promptIndex: 0),
            .user(text: "P1", promptIndex: 1),
            .checkpoint(id: "ckpt-1", promptIndex: 2),
            .user(text: "P2", promptIndex: 2),
            .agent(text: "R2"),
            .user(text: "P3", promptIndex: 3),
            .agent(text: "R3"),
            .rewindMarker(targetPromptIndex: 2),
            .user(text: "P2_prime", promptIndex: 2),
            .agent(text: "R2_prime"),
        ]
        try writeUpdatesJSONL(sessionDir: tempDir, updates: updates)

        let result = try replayToPrompt(sessionDir: tempDir, targetPromptIndex: 3)
        #expect(result.promptIndexReached == 3)
        let texts = result.conversation.map { $0.textContent() }
        #expect(texts == ["SYS", "SUMMARY_1", "P2_prime", "R2_prime"])
        #expect(!texts.contains("P2"))
        #expect(!texts.contains("P3"))
    }

    // MARK: - 4. History Sanitization & Guard Tests

    @Test("Compacted history sanitization strips orphaned tool results and custom outputs")
    func checkpointHistorySanitization() {
        let items: [ConversationItem] = [
            .system("System instructions"),
            .toolResult(ToolResultItem(toolCallId: "orphan-call-1", content: "Orphaned result")),
            .customToolOutput(CustomToolOutputItem.text(callId: "orphan-custom-1", "Orphaned custom")),
            .assistant(AssistantItem(content: "Calling tool", toolCalls: [ToolCall(id: "valid-call", name: "read", arguments: "{}")])),
            .toolResult(ToolResultItem(toolCallId: "valid-call", content: "Valid result")),
            .user("Follow-up prompt")
        ]

        let sanitized = sanitizeCompactedHistory(items)
        #expect(sanitized.strippedToolCallIDs.sorted() == ["orphan-call-1", "orphan-custom-1"])
        #expect(sanitized.items.count == 4)
        #expect(!sanitized.items.contains { item in
            if case .toolResult(let r) = item { return r.toolCallId == "orphan-call-1" }
            return false
        })
    }

    @Test("Compaction reduction guard boundary evaluation")
    func checkpointReductionGuardBoundaries() {
        #expect(compactionMeetsReductionGuard(tokensBefore: 10_000, tokensAfter: 8_000, maxReductionRatio: 0.8))
        #expect(!compactionMeetsReductionGuard(tokensBefore: 10_000, tokensAfter: 8_001, maxReductionRatio: 0.8))
        #expect(compactionMeetsReductionGuard(tokensBefore: 10_000, tokensAfter: 1_000, maxReductionRatio: 0.8))
        #expect(!compactionMeetsReductionGuard(tokensBefore: 0, tokensAfter: 0, maxReductionRatio: 0.8))
        #expect(!compactionMeetsReductionGuard(tokensBefore: 100, tokensAfter: 200, maxReductionRatio: 0.8))
    }

    @Test("AutoContinueInfo encoding and CompactionCheckpointInfo optional auto_continue round-trip")
    func checkpointAutoContinueInfoEncoding() throws {
        let infoWithPrompt = AutoContinueInfo(promptText: "Please analyze the compiler errors.")
        let data1 = try JSONEncoder().encode(infoWithPrompt)
        let decoded1 = try JSONDecoder().decode(AutoContinueInfo.self, from: data1)
        #expect(decoded1.promptText == "Please analyze the compiler errors.")

        let jsonWithoutAutoContinue = """
        {
            "checkpoint_id": "ckpt-no-ac",
            "prompt_index_at_compaction": 5,
            "checkpoint_file": "compaction_checkpoints/ckpt-no-ac.json",
            "schema_version": 1,
            "created_at": "2026-08-14T12:00:00Z"
        }
        """.data(using: .utf8)!
        let decoded2 = try JSONDecoder().decode(CompactionCheckpointInfo.self, from: jsonWithoutAutoContinue)
        #expect(decoded2.autoContinue == nil)
    }
}
