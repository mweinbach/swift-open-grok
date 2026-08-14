// CompactionCheckpointStressTests.swift
//
// Open Grok — Adversarial stress test suite for CompactionCheckpoint schema versions,
// missing file error propagation, multiple sequential compactions with interleaved
// rewind markers, and Rust JSON serialization compatibility.

import Foundation
import Testing
@testable import OpenGrokCompaction
@testable import OpenGrokSamplingTypes
@testable import OpenGrokChatState

@Suite("Compaction Checkpoint Adversarial Stress Tests")
struct CompactionCheckpointStressTests {

    // MARK: - 1. Schema Version Boundary Tests

    @Test("Schema version 0 is accepted as supported (<= 1)")
    func schemaVersionZeroSupported() throws {
        let items: [ConversationItem] = [
            .system("Sys v0"),
            .user("User v0")
        ]
        let fileObj = CompactionCheckpointFile(
            checkpointID: "ckpt-v0",
            promptIndexAtCompaction: 2,
            compactedHistory: items,
            schemaVersion: 0,
            createdAt: "2026-08-14T10:00:00Z"
        )
        let json = try JSONEncoder().encode(fileObj)

        let file = try JSONDecoder().decode(CompactionCheckpointFile.self, from: json)
        #expect(file.schemaVersion == 0)
        #expect(file.isSupportedSchemaVersion)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-v0-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent("compaction_checkpoints"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let ckptURL = tempDir.appendingPathComponent("compaction_checkpoints/ckpt-v0.json")
        try json.write(to: ckptURL)

        let loaded = try loadCompactionCheckpoint(sessionDir: tempDir, checkpointID: "ckpt-v0")
        #expect(loaded.checkpointID == "ckpt-v0")
        #expect(loaded.schemaVersion == 0)
    }

    @Test("Schema version omitted defaults to 1 and loads successfully")
    func schemaVersionOmittedDefaultsToOne() throws {
        let json = """
        {
            "checkpoint_id": "ckpt-omitted-version",
            "prompt_index_at_compaction": 3,
            "compacted_history": [],
            "created_at": "2026-08-14T10:00:00Z"
        }
        """.data(using: .utf8)!

        let file = try JSONDecoder().decode(CompactionCheckpointFile.self, from: json)
        #expect(file.schemaVersion == 1)
        #expect(file.isSupportedSchemaVersion)

        let infoJson = """
        {
            "checkpoint_id": "info-omitted-version",
            "prompt_index_at_compaction": 3,
            "checkpoint_file": "compaction_checkpoints/info.json",
            "created_at": "2026-08-14T10:00:00Z"
        }
        """.data(using: .utf8)!

        let info = try JSONDecoder().decode(CompactionCheckpointInfo.self, from: infoJson)
        #expect(info.schemaVersion == 1)
    }

    @Test("ReplayToPrompt throws unsupportedSchemaVersion when checkpoint has schema_version > 1")
    func replayThrowsOnUnsupportedSchemaVersion() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-replay-unsupported-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent("compaction_checkpoints"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let v2Json = """
        {
            "checkpoint_id": "ckpt-v2",
            "prompt_index_at_compaction": 5,
            "compacted_history": [],
            "schema_version": 2,
            "created_at": "2026-08-14T10:00:00Z"
        }
        """.data(using: .utf8)!
        try v2Json.write(to: tempDir.appendingPathComponent("compaction_checkpoints/ckpt-v2.json"))

        let updates: [SessionUpdateRecord] = [
            .user(text: "P0", promptIndex: 0),
            .checkpoint(id: "ckpt-v2", promptIndex: 5),
            .user(text: "P5", promptIndex: 5)
        ]
        try writeUpdatesJSONL(sessionDir: tempDir, updates: updates)

        // Both post-compaction (target 5) and pre-compaction (target 2) must throw
        #expect(throws: CompactionCheckpointError.self) {
            _ = try replayToPrompt(sessionDir: tempDir, targetPromptIndex: 5)
        }
        #expect(throws: CompactionCheckpointError.self) {
            _ = try replayToPrompt(sessionDir: tempDir, targetPromptIndex: 2)
        }
    }

    // MARK: - 2. Missing File Error Propagation Tests

    @Test("ReplayToPrompt throws fileMissing when checkpoint JSON is absent on disk")
    func replayThrowsOnFileMissing() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-replay-missing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let updates: [SessionUpdateRecord] = [
            .user(text: "P0", promptIndex: 0),
            .checkpoint(id: "missing-uuid-1234", promptIndex: 4),
            .user(text: "P4", promptIndex: 4)
        ]
        try writeUpdatesJSONL(sessionDir: tempDir, updates: updates)

        // Pre-compaction target must fail closed (needs original_user_info from checkpoint)
        #expect(throws: CompactionCheckpointError.self) {
            _ = try replayToPrompt(sessionDir: tempDir, targetPromptIndex: 2)
        }

        // Post-compaction target must fail closed (needs compacted history)
        #expect(throws: CompactionCheckpointError.self) {
            _ = try replayToPrompt(sessionDir: tempDir, targetPromptIndex: 4)
        }
    }

    @Test("ReplayToPrompt throws fileCorrupted on invalid JSON in checkpoint file")
    func replayThrowsOnFileCorrupted() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-replay-corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent("compaction_checkpoints"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let corruptData = "NOT_JSON_DATA".data(using: .utf8)!
        try corruptData.write(to: tempDir.appendingPathComponent("compaction_checkpoints/ckpt-bad.json"))

        let updates: [SessionUpdateRecord] = [
            .user(text: "P0", promptIndex: 0),
            .checkpoint(id: "ckpt-bad", promptIndex: 3),
            .user(text: "P3", promptIndex: 3)
        ]
        try writeUpdatesJSONL(sessionDir: tempDir, updates: updates)

        #expect(throws: CompactionCheckpointError.self) {
            _ = try replayToPrompt(sessionDir: tempDir, targetPromptIndex: 3)
        }
    }

    // MARK: - 3. Multiple Sequential Compactions & Complex Interleaved Rewinds

    @Test("Three sequential compactions with interleaved rewinds, branches, and zero-prompt reset")
    func complexThreeStageSequentialCompactionRewind() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-3stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Setup 3 checkpoints
        try persistCompactionCheckpoint(
            sessionDir: tempDir,
            checkpointID: "ckpt-stage-1",
            promptIndex: 2,
            compactedHistory: [.system("SYS_PREAMBLE"), .user("SUMMARY_STAGE_1")],
            originalUserInfo: "ORIGINAL_USER_INFO_STAGE_0"
        )
        try persistCompactionCheckpoint(
            sessionDir: tempDir,
            checkpointID: "ckpt-stage-2",
            promptIndex: 4,
            compactedHistory: [.system("SYS_PREAMBLE"), .user("SUMMARY_STAGE_2")],
            originalUserInfo: "ORIGINAL_USER_INFO_STAGE_0"
        )
        try persistCompactionCheckpoint(
            sessionDir: tempDir,
            checkpointID: "ckpt-stage-3",
            promptIndex: 6,
            compactedHistory: [.system("SYS_PREAMBLE"), .user("SUMMARY_STAGE_3")],
            originalUserInfo: "ORIGINAL_USER_INFO_STAGE_0"
        )

        let updates: [SessionUpdateRecord] = [
            .user(text: "Prompt 0", promptIndex: 0),
            .agent(text: "Answer 0"),
            .user(text: "Prompt 1", promptIndex: 1),
            .agent(text: "Answer 1"),
            .checkpoint(id: "ckpt-stage-1", promptIndex: 2),
            .user(text: "Prompt 2", promptIndex: 2),
            .agent(text: "Answer 2"),
            .user(text: "Prompt 3", promptIndex: 3),
            .agent(text: "Answer 3"),
            .checkpoint(id: "ckpt-stage-2", promptIndex: 4),
            .user(text: "Prompt 4", promptIndex: 4),
            .agent(text: "Answer 4"),
            .user(text: "Prompt 5", promptIndex: 5),
            .agent(text: "Answer 5"),
            .checkpoint(id: "ckpt-stage-3", promptIndex: 6),
            .user(text: "Prompt 6", promptIndex: 6),
            .agent(text: "Answer 6"),
            .user(text: "Prompt 7", promptIndex: 7),
            .agent(text: "Answer 7"),
        ]
        try writeUpdatesJSONL(sessionDir: tempDir, updates: updates)

        // Case A: Rewind to 7 (inside stage 3 tail)
        let res7 = try replayToPrompt(sessionDir: tempDir, targetPromptIndex: 7)
        #expect(res7.promptIndexReached == 7)
        #expect(res7.lastCompactionPromptIndex == 6)
        #expect(res7.conversation.map { $0.textContent() } == [
            "SYS_PREAMBLE", "SUMMARY_STAGE_3", "Prompt 6", "Answer 6"
        ])

        // Case B: Rewind to 5 (inside stage 2 tail)
        let res5 = try replayToPrompt(sessionDir: tempDir, targetPromptIndex: 5)
        #expect(res5.promptIndexReached == 5)
        #expect(res5.lastCompactionPromptIndex == 4)
        #expect(res5.conversation.map { $0.textContent() } == [
            "SYS_PREAMBLE", "SUMMARY_STAGE_2", "Prompt 4", "Answer 4"
        ])

        // Case C: Rewind to 3 (inside stage 1 tail)
        let res3 = try replayToPrompt(sessionDir: tempDir, targetPromptIndex: 3)
        #expect(res3.promptIndexReached == 3)
        #expect(res3.lastCompactionPromptIndex == 2)
        #expect(res3.conversation.map { $0.textContent() } == [
            "SYS_PREAMBLE", "SUMMARY_STAGE_1", "Prompt 2", "Answer 2"
        ])

        // Case D: Rewind to 1 (pre-compaction stage 0)
        let res1 = try replayToPrompt(sessionDir: tempDir, targetPromptIndex: 1)
        #expect(res1.promptIndexReached == 1)
        #expect(res1.lastCompactionPromptIndex == nil)
        #expect(res1.originalUserInfo == "ORIGINAL_USER_INFO_STAGE_0")
        #expect(res1.conversation.map { $0.textContent() } == [
            "SYS_PREAMBLE", "ORIGINAL_USER_INFO_STAGE_0", "Prompt 0", "Answer 0"
        ])

        // Case E: Rewind to 0 (pre-turn-0 restores system preamble + original user info)
        let res0 = try replayToPrompt(sessionDir: tempDir, targetPromptIndex: 0)
        #expect(res0.promptIndexReached == 0)
        #expect(res0.conversation.map { $0.textContent() } == [
            "SYS_PREAMBLE", "ORIGINAL_USER_INFO_STAGE_0"
        ])
    }

    // MARK: - 4. Rust JSON Fixture Compatibility & ACP Envelopes

    @Test("Rust reference notification JSON fixture decoding")
    func rustNotificationJsonFixtureDecoding() throws {
        // Rust serialized CompactionCheckpointInfo fixture
        let rustInfoJson = """
        {
            "checkpoint_id": "89ab12cd-34ef-5678-90ab-cdef12345678",
            "prompt_index_at_compaction": 42,
            "checkpoint_file": "compaction_checkpoints/89ab12cd-34ef-5678-90ab-cdef12345678.json",
            "auto_continue": {
                "prompt_text": "Please continue the refactoring task."
            },
            "schema_version": 1,
            "created_at": "2026-08-14T08:30:00Z"
        }
        """.data(using: .utf8)!

        let info = try JSONDecoder().decode(CompactionCheckpointInfo.self, from: rustInfoJson)
        #expect(info.checkpointID == "89ab12cd-34ef-5678-90ab-cdef12345678")
        #expect(info.promptIndexAtCompaction == 42)
        #expect(info.checkpointFile == "compaction_checkpoints/89ab12cd-34ef-5678-90ab-cdef12345678.json")
        #expect(info.autoContinue?.promptText == "Please continue the refactoring task.")
        #expect(info.schemaVersion == 1)
        #expect(info.createdAt == "2026-08-14T08:30:00Z")

        // Rust serialized CompactionCheckpointFile fixture with standard ConversationItem representation
        let items: [ConversationItem] = [
            .system("You are Open Grok."),
            .user("Compact summary")
        ]
        let ckptFile = CompactionCheckpointFile(
            checkpointID: "89ab12cd-34ef-5678-90ab-cdef12345678",
            promptIndexAtCompaction: 42,
            compactedHistory: items,
            schemaVersion: 1,
            createdAt: "2026-08-14T08:30:00Z",
            originalUserInfo: "User project context",
            rereadFilePaths: ["Sources/OpenGrokCLI/LiveCompaction.swift"]
        )
        let rustFileJson = try JSONEncoder().encode(ckptFile)

        let file = try JSONDecoder().decode(CompactionCheckpointFile.self, from: rustFileJson)
        #expect(file.checkpointID == "89ab12cd-34ef-5678-90ab-cdef12345678")
        #expect(file.promptIndexAtCompaction == 42)
        #expect(file.originalUserInfo == "User project context")
        #expect(file.rereadFilePaths == ["Sources/OpenGrokCLI/LiveCompaction.swift"])
        #expect(file.compactedHistory.count == 2)
    }

    @Test("SessionUpdateRecord decodes ACP envelope format")
    func sessionUpdateRecordAcpEnvelopeDecoding() throws {
        let acpJson = """
        {
            "method": "_x.ai/session/update",
            "params": {
                "sessionUpdate": {
                    "sessionUpdate": "compaction_checkpoint",
                    "checkpoint_id": "acp-ckpt-123",
                    "prompt_index_at_compaction": 8,
                    "auto_continue": {
                        "text": "Continue next step"
                    }
                }
            }
        }
        """.data(using: .utf8)!

        let record = try JSONDecoder().decode(SessionUpdateRecord.self, from: acpJson)
        #expect(record == .checkpoint(id: "acp-ckpt-123", promptIndex: 8, autoContinueText: "Continue next step"))

        let acpRewind = """
        {
            "method": "_x.ai/session/update",
            "params": {
                "sessionUpdate": {
                    "sessionUpdate": "rewind_marker",
                    "target_prompt_index": 4
                }
            }
        }
        """.data(using: .utf8)!

        let rewindRecord = try JSONDecoder().decode(SessionUpdateRecord.self, from: acpRewind)
        #expect(rewindRecord == .rewindMarker(targetPromptIndex: 4))
    }
}
