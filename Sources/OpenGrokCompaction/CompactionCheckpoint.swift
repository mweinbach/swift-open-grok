// CompactionCheckpoint.swift
//
// Open Grok — Swift port of compaction checkpoint persistence and cross-compaction
// rewind replay from `crates/codegen/xai-grok-shell/src/extensions/notification.rs`
// and `crates/codegen/xai-grok-shell/src/session/compaction.rs` / `replay.rs`.
//
// Checkpoints preserve the full conversation history at the time of compaction in
// a dedicated JSON file (`compaction_checkpoints/<id>.json`), while lightweight
// metadata is stored in session update journals (`updates.jsonl`).

import Foundation
import OpenGrokSamplingTypes
import OpenGrokShared

// MARK: - Checkpoint Data Structures

/// Information about the auto-continue prompt injected after auto-compaction.
public struct AutoContinueInfo: Codable, Sendable, Equatable, Hashable {
    /// The exact text of the auto-continue prompt that was added as a user message.
    public var promptText: String

    public init(promptText: String) {
        self.promptText = promptText
    }

    private enum CodingKeys: String, CodingKey {
        case promptText = "prompt_text"
    }
}

/// Metadata stored in `updates.jsonl` as a `CompactionCheckpoint` session update.
///
/// This is a lightweight reference; the full compacted conversation lives in a
/// separate file (`compaction_checkpoints/{checkpoint_id}.json`).
public struct CompactionCheckpointInfo: Codable, Sendable, Equatable, Hashable {
    /// Unique checkpoint identifier (UUID).
    public var checkpointID: String
    /// The prompt index at the time compaction completed.
    /// The next real user prompt will receive this index.
    public var promptIndexAtCompaction: Int
    /// Relative path to the checkpoint file inside the session directory
    /// (e.g., `"compaction_checkpoints/<uuid>.json"`).
    public var checkpointFile: String
    /// If this compaction was triggered by auto-compact, contains the
    /// auto-continue prompt that was injected after compaction.
    public var autoContinue: AutoContinueInfo?
    /// Schema version for forward compatibility.
    public var schemaVersion: UInt32
    /// ISO 8601 timestamp of when the checkpoint was created.
    public var createdAt: String

    public init(
        checkpointID: String,
        promptIndexAtCompaction: Int,
        checkpointFile: String,
        autoContinue: AutoContinueInfo? = nil,
        schemaVersion: UInt32 = 1,
        createdAt: String
    ) {
        self.checkpointID = checkpointID
        self.promptIndexAtCompaction = promptIndexAtCompaction
        self.checkpointFile = checkpointFile
        self.autoContinue = autoContinue
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case checkpointID = "checkpoint_id"
        case promptIndexAtCompaction = "prompt_index_at_compaction"
        case checkpointFile = "checkpoint_file"
        case autoContinue = "auto_continue"
        case schemaVersion = "schema_version"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.checkpointID = try container.decode(String.self, forKey: .checkpointID)
        self.promptIndexAtCompaction = try container.decode(Int.self, forKey: .promptIndexAtCompaction)
        self.checkpointFile = try container.decode(String.self, forKey: .checkpointFile)
        self.autoContinue = try container.decodeIfPresent(AutoContinueInfo.self, forKey: .autoContinue)
        self.schemaVersion = try container.decodeIfPresent(UInt32.self, forKey: .schemaVersion) ?? 1
        self.createdAt = try container.decode(String.self, forKey: .createdAt)
    }
}

/// The on-disk format for a compaction checkpoint file.
///
/// Stored at `{session_dir}/compaction_checkpoints/{checkpoint_id}.json`.
/// Contains the full compacted conversation history so the replay pipeline can
/// deterministically reconstruct the model's view without re-running compaction.
public struct CompactionCheckpointFile: Codable, Sendable, Equatable {
    /// Unique checkpoint identifier (matches [`CompactionCheckpointInfo.checkpointID`]).
    public var checkpointID: String
    /// The prompt index at the time compaction completed.
    public var promptIndexAtCompaction: Int
    /// The exact compacted conversation used by the model.
    public var compactedHistory: [ConversationItem]
    /// Schema version for forward compatibility.
    public var schemaVersion: UInt32
    /// ISO 8601 timestamp of when the checkpoint was created.
    public var createdAt: String
    /// The original User(user_info) text from before compaction.
    /// Used during cross-compaction rewind to restore the correct user_info
    /// that the model originally saw for pre-compaction turns, rather than
    /// the rebuilt user_info from the compacted conversation.
    public var originalUserInfo: String?
    /// File paths that were re-read and injected after compaction.
    public var rereadFilePaths: [String]

    /// Forward compatibility check: schema version 1 is supported.
    public var isSupportedSchemaVersion: Bool {
        schemaVersion <= 1
    }

    public init(
        checkpointID: String,
        promptIndexAtCompaction: Int,
        compactedHistory: [ConversationItem],
        schemaVersion: UInt32 = 1,
        createdAt: String,
        originalUserInfo: String? = nil,
        rereadFilePaths: [String] = []
    ) {
        self.checkpointID = checkpointID
        self.promptIndexAtCompaction = promptIndexAtCompaction
        self.compactedHistory = compactedHistory
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.originalUserInfo = originalUserInfo
        self.rereadFilePaths = rereadFilePaths
    }

    private enum CodingKeys: String, CodingKey {
        case checkpointID = "checkpoint_id"
        case promptIndexAtCompaction = "prompt_index_at_compaction"
        case compactedHistory = "compacted_history"
        case schemaVersion = "schema_version"
        case createdAt = "created_at"
        case originalUserInfo = "original_user_info"
        case rereadFilePaths = "reread_file_paths"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.checkpointID = try container.decode(String.self, forKey: .checkpointID)
        self.promptIndexAtCompaction = try container.decode(Int.self, forKey: .promptIndexAtCompaction)
        self.compactedHistory = try container.decode([ConversationItem].self, forKey: .compactedHistory)
        self.schemaVersion = try container.decodeIfPresent(UInt32.self, forKey: .schemaVersion) ?? 1
        self.createdAt = try container.decode(String.self, forKey: .createdAt)
        self.originalUserInfo = try container.decodeIfPresent(String.self, forKey: .originalUserInfo)
        self.rereadFilePaths = try container.decodeIfPresent([String].self, forKey: .rereadFilePaths) ?? []
    }
}

// MARK: - Checkpoint Errors

public enum CompactionCheckpointError: LocalizedError, Sendable, Equatable {
    case fileMissing(path: String)
    case fileCorrupted(path: String, message: String)
    case unsupportedSchemaVersion(version: UInt32, path: String)
    case ioError(String)

    public var errorDescription: String? {
        switch self {
        case .fileMissing(let path):
            return "Compaction checkpoint file missing: \(path). Cannot safely rewind past the compaction point."
        case .fileCorrupted(let path, let message):
            return "Compaction checkpoint file corrupt: \(path) (\(message)). Cannot safely rewind past the compaction point."
        case .unsupportedSchemaVersion(let version, let path):
            return "Unsupported checkpoint schema version \(version) at \(path). Cannot safely rewind past the compaction point."
        case .ioError(let msg):
            return "Compaction checkpoint I/O error: \(msg)"
        }
    }
}

// MARK: - Disk Persistence Operations

/// Persist a compaction checkpoint file to `{sessionDir}/compaction_checkpoints/{checkpointID}.json`.
@discardableResult
public func persistCompactionCheckpoint(
    sessionDir: URL,
    checkpointID: String? = nil,
    promptIndex: Int,
    compactedHistory: [ConversationItem],
    autoContinue: AutoContinueInfo? = nil,
    schemaVersion: UInt32 = 1,
    createdAt: String? = nil,
    originalUserInfo: String? = nil,
    rereadFilePaths: [String] = []
) throws -> CompactionCheckpointInfo {
    let id = checkpointID ?? UUID().uuidString.lowercased()
    let relativeFile = "compaction_checkpoints/\(id).json"
    let isoCreatedAt = createdAt ?? ISO8601DateFormatter().string(from: Date())

    let file = CompactionCheckpointFile(
        checkpointID: id,
        promptIndexAtCompaction: promptIndex,
        compactedHistory: compactedHistory,
        schemaVersion: schemaVersion,
        createdAt: isoCreatedAt,
        originalUserInfo: originalUserInfo,
        rereadFilePaths: rereadFilePaths
    )

    let checkpointsDir = sessionDir.appendingPathComponent("compaction_checkpoints")
    try FileManager.default.createDirectory(at: checkpointsDir, withIntermediateDirectories: true)
    let fileURL = checkpointsDir.appendingPathComponent("\(id).json")

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(file)
    try data.write(to: fileURL, options: .atomic)

    return CompactionCheckpointInfo(
        checkpointID: id,
        promptIndexAtCompaction: promptIndex,
        checkpointFile: relativeFile,
        autoContinue: autoContinue,
        schemaVersion: schemaVersion,
        createdAt: isoCreatedAt
    )
}

/// Load a compaction checkpoint file from `{sessionDir}/compaction_checkpoints/{checkpointID}.json` or direct path.
public func loadCompactionCheckpoint(
    sessionDir: URL,
    checkpointID: String
) throws -> CompactionCheckpointFile {
    let fileURL: URL
    if checkpointID.contains("/") || checkpointID.hasSuffix(".json") {
        fileURL = sessionDir.appendingPathComponent(checkpointID)
    } else {
        fileURL = sessionDir.appendingPathComponent("compaction_checkpoints").appendingPathComponent("\(checkpointID).json")
    }

    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        throw CompactionCheckpointError.fileMissing(path: fileURL.path)
    }

    let data: Data
    do {
        data = try Data(contentsOf: fileURL)
    } catch {
        throw CompactionCheckpointError.ioError(error.localizedDescription)
    }

    let file: CompactionCheckpointFile
    do {
        file = try JSONDecoder().decode(CompactionCheckpointFile.self, from: data)
    } catch {
        throw CompactionCheckpointError.fileCorrupted(path: fileURL.path, message: error.localizedDescription)
    }

    guard file.isSupportedSchemaVersion else {
        throw CompactionCheckpointError.unsupportedSchemaVersion(version: file.schemaVersion, path: fileURL.path)
    }

    return file
}

/// List all compaction checkpoints found in `{sessionDir}/compaction_checkpoints`.
public func listCompactionCheckpoints(
    sessionDir: URL
) throws -> [CompactionCheckpointFile] {
    let checkpointsDir = sessionDir.appendingPathComponent("compaction_checkpoints")
    guard FileManager.default.fileExists(atPath: checkpointsDir.path) else {
        return []
    }
    let contents = try FileManager.default.contentsOfDirectory(at: checkpointsDir, includingPropertiesForKeys: nil)
    var results: [CompactionCheckpointFile] = []
    for fileURL in contents where fileURL.pathExtension == "json" {
        if let data = try? Data(contentsOf: fileURL),
           let file = try? JSONDecoder().decode(CompactionCheckpointFile.self, from: data) {
            results.append(file)
        }
    }
    return results.sorted { $0.promptIndexAtCompaction < $1.promptIndexAtCompaction }
}

/// Copy checkpoint files from `sourceDir` to `destinationDir`.
@discardableResult
public func copyCheckpoints(
    from sourceDir: URL,
    to destinationDir: URL,
    checkpointFiles: [String]? = nil
) throws -> Int {
    let srcCheckpointsDir = sourceDir.appendingPathComponent("compaction_checkpoints")
    guard FileManager.default.fileExists(atPath: srcCheckpointsDir.path) else {
        return 0
    }
    let destCheckpointsDir = destinationDir.appendingPathComponent("compaction_checkpoints")
    try FileManager.default.createDirectory(at: destCheckpointsDir, withIntermediateDirectories: true)

    var count = 0
    if let checkpointFiles {
        for file in checkpointFiles {
            let relativeName = (file as NSString).lastPathComponent
            let src = srcCheckpointsDir.appendingPathComponent(relativeName)
            let dst = destCheckpointsDir.appendingPathComponent(relativeName)
            if FileManager.default.fileExists(atPath: src.path) && !FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.copyItem(at: src, to: dst)
                count += 1
            }
        }
    } else {
        let contents = try FileManager.default.contentsOfDirectory(at: srcCheckpointsDir, includingPropertiesForKeys: nil)
        for src in contents where src.pathExtension == "json" {
            let dst = destCheckpointsDir.appendingPathComponent(src.lastPathComponent)
            if !FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.copyItem(at: src, to: dst)
                count += 1
            }
        }
    }
    return count
}

// MARK: - Replay & Cross-Compaction Rewind

/// Session update record representation for replay streams (`updates.jsonl`).
public enum SessionUpdateRecord: Codable, Sendable, Equatable {
    case user(text: String, promptIndex: Int? = nil)
    case agent(text: String)
    case checkpoint(id: String, promptIndex: Int, autoContinueText: String? = nil)
    case rewindMarker(targetPromptIndex: Int)
    case raw(JSONValue)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case promptIndex = "prompt_index"
        case id
        case autoContinueText = "auto_continue_text"
        case targetPromptIndex = "target_prompt_index"
        case sessionUpdate = "sessionUpdate"
        case checkpointID = "checkpoint_id"
        case promptIndexAtCompaction = "prompt_index_at_compaction"
        case checkpointFile = "checkpoint_file"
        case autoContinue = "auto_continue"
        case promptText = "prompt_text"
        case update
        case content
        case metadata = "_meta"
        case canonicalPromptIndex = "promptIndex"
        case method
        case params
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Case 1: Check for method / params envelope (e.g. `_x.ai/session/update`)
        if container.contains(.params) {
            let params = try container.nestedContainer(keyedBy: CodingKeys.self, forKey: .params)
            if params.contains(.update) {
                let update = try params.nestedContainer(keyedBy: CodingKeys.self, forKey: .update)
                if let updateType = try update.decodeIfPresent(String.self, forKey: .sessionUpdate) {
                    switch updateType {
                    case "compaction_checkpoint":
                        let id = try update.decode(String.self, forKey: .checkpointID)
                        let promptIndex = try update.decode(Int.self, forKey: .promptIndexAtCompaction)
                        let autoText: String?
                        if update.contains(.autoContinue) {
                            let autoContinue = try update.nestedContainer(
                                keyedBy: CodingKeys.self,
                                forKey: .autoContinue
                            )
                            autoText = try autoContinue.decodeIfPresent(String.self, forKey: .promptText)
                                ?? autoContinue.decodeIfPresent(String.self, forKey: .text)
                        } else {
                            autoText = nil
                        }
                        self = .checkpoint(id: id, promptIndex: promptIndex, autoContinueText: autoText)
                        return
                    case "rewind_marker":
                        self = .rewindMarker(targetPromptIndex: try update.decode(
                            Int.self,
                            forKey: .targetPromptIndex
                        ))
                        return
                    case "user_message_chunk", "agent_message_chunk":
                        let content = try update.nestedContainer(
                            keyedBy: CodingKeys.self,
                            forKey: .content
                        )
                        guard try content.decodeIfPresent(String.self, forKey: .type) == "text" else {
                            break
                        }
                        let text = try content.decode(String.self, forKey: .text)
                        if updateType == "agent_message_chunk" {
                            self = .agent(text: text)
                            return
                        }
                        let promptIndex: Int?
                        if update.contains(.metadata) {
                            let metadata = try update.nestedContainer(
                                keyedBy: CodingKeys.self,
                                forKey: .metadata
                            )
                            promptIndex = try metadata.decodeIfPresent(Int.self, forKey: .canonicalPromptIndex)
                        } else {
                            promptIndex = nil
                        }
                        self = .user(text: text, promptIndex: promptIndex)
                        return
                    default:
                        break
                    }
                }
            }
        }

        // Case 2: Check direct sessionUpdate tag
        if let updateType = try? container.decode(String.self, forKey: .sessionUpdate) {
            if updateType == "compaction_checkpoint" {
                let id = try container.decode(String.self, forKey: .checkpointID)
                let promptIndex = try container.decode(Int.self, forKey: .promptIndexAtCompaction)
                let autoText: String?
                if container.contains(.autoContinue) {
                    let autoContinue = try container.nestedContainer(
                        keyedBy: CodingKeys.self,
                        forKey: .autoContinue
                    )
                    autoText = try autoContinue.decodeIfPresent(String.self, forKey: .promptText)
                        ?? autoContinue.decodeIfPresent(String.self, forKey: .text)
                } else {
                    autoText = nil
                }
                self = .checkpoint(id: id, promptIndex: promptIndex, autoContinueText: autoText)
                return
            } else if updateType == "rewind_marker" {
                let target = try container.decode(Int.self, forKey: .targetPromptIndex)
                self = .rewindMarker(targetPromptIndex: target)
                return
            }
        }

        // Case 3: Standard `type` tag
        if let type = try? container.decode(String.self, forKey: .type) {
            switch type {
            case "user":
                let text = try container.decode(String.self, forKey: .text)
                let promptIndex = try container.decodeIfPresent(Int.self, forKey: .promptIndex)
                self = .user(text: text, promptIndex: promptIndex)
                return
            case "agent":
                let text = try container.decode(String.self, forKey: .text)
                self = .agent(text: text)
                return
            case "checkpoint":
                let id = try container.decode(String.self, forKey: .id)
                let promptIndex = try container.decode(Int.self, forKey: .promptIndex)
                let autoText = try container.decodeIfPresent(String.self, forKey: .autoContinueText)
                self = .checkpoint(id: id, promptIndex: promptIndex, autoContinueText: autoText)
                return
            case "rewind_marker":
                let target = try container.decode(Int.self, forKey: .targetPromptIndex)
                self = .rewindMarker(targetPromptIndex: target)
                return
            default:
                break
            }
        }

        // Fallback: decode raw JSONValue
        let single = try decoder.singleValueContainer()
        let val = try single.decode(JSONValue.self)
        self = .raw(val)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .user(let text, let promptIndex):
            try container.encode("user", forKey: .type)
            try container.encode(text, forKey: .text)
            if let promptIndex {
                try container.encode(promptIndex, forKey: .promptIndex)
            }
        case .agent(let text):
            try container.encode("agent", forKey: .type)
            try container.encode(text, forKey: .text)
        case .checkpoint(let id, let promptIndex, let autoContinueText):
            try container.encode("checkpoint", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(promptIndex, forKey: .promptIndex)
            if let autoContinueText {
                try container.encode(autoContinueText, forKey: .autoContinueText)
            }
        case .rewindMarker(let targetPromptIndex):
            try container.encode("rewind_marker", forKey: .type)
            try container.encode(targetPromptIndex, forKey: .targetPromptIndex)
        case .raw(let val):
            var single = encoder.singleValueContainer()
            try single.encode(val)
        }
    }
}

/// Helper to write update records to `updates.jsonl` in `sessionDir`.
public func writeUpdatesJSONL(sessionDir: URL, updates: [SessionUpdateRecord]) throws {
    let fileURL = sessionDir.appendingPathComponent("updates.jsonl")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var lines: [String] = []
    for update in updates {
        let data = try encoder.encode(update)
        if let line = String(data: data, encoding: .utf8) {
            lines.append(line)
        }
    }
    let content = lines.joined(separator: "\n") + "\n"
    try content.write(to: fileURL, atomically: true, encoding: .utf8)
}

/// Replay outcome returned by `replayToPrompt`.
public struct ReplayResult: Sendable, Equatable {
    public var conversation: [ConversationItem]
    public var promptIndexReached: Int
    public var originalUserInfo: String?
    public var lastCompactionPromptIndex: Int?

    public init(
        conversation: [ConversationItem],
        promptIndexReached: Int,
        originalUserInfo: String? = nil,
        lastCompactionPromptIndex: Int? = nil
    ) {
        self.conversation = conversation
        self.promptIndexReached = promptIndexReached
        self.originalUserInfo = originalUserInfo
        self.lastCompactionPromptIndex = lastCompactionPromptIndex
    }
}

/// Replay `updates.jsonl` in `sessionDir` to reconstruct conversation at `targetPromptIndex`.
public func replayToPrompt(
    sessionDir: URL,
    targetPromptIndex: Int
) throws -> ReplayResult {
    let updatesURL = sessionDir.appendingPathComponent("updates.jsonl")
    guard FileManager.default.fileExists(atPath: updatesURL.path) else {
        return ReplayResult(
            conversation: [],
            promptIndexReached: 0,
            originalUserInfo: nil,
            lastCompactionPromptIndex: nil
        )
    }

    let rawData = try Data(contentsOf: updatesURL)
    guard let text = String(data: rawData, encoding: .utf8) else {
        throw CompactionCheckpointError.ioError("Malformed UTF-8 in updates.jsonl")
    }

    let lines = text.split(whereSeparator: \.isNewline)
    var updates: [SessionUpdateRecord] = []
    let decoder = JSONDecoder()
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }
        if let data = trimmed.data(using: .utf8),
           let record = try? decoder.decode(SessionUpdateRecord.self, from: data) {
            updates.append(record)
        }
    }

    var conversation: [ConversationItem] = []
    var promptCounter = 0
    var checkpointActive = false
    var checkpointBaseLen = 0
    var checkpointPromptIndex = 0
    var originalUserInfo: String?
    var systemPreamble: ConversationItem?

    for update in updates {
        switch update {
        case .user(let userText, _):
            conversation.append(.user(userText))
            promptCounter += 1

        case .agent(let agentText):
            conversation.append(.assistant(agentText))

        case .checkpoint(let checkpointID, let promptIndexAtCompaction, let autoContinueText):
            let file = try loadCompactionCheckpoint(sessionDir: sessionDir, checkpointID: checkpointID)
            if originalUserInfo == nil {
                originalUserInfo = file.originalUserInfo
            }
            if let firstSys = file.compactedHistory.first(where: { if case .system = $0 { return true } else { return false } }) {
                if systemPreamble == nil {
                    systemPreamble = firstSys
                }
            }

            if targetPromptIndex < promptIndexAtCompaction {
                // Pre-compaction target: skip compacted history; keep raw turns.
                continue
            } else {
                // Post-compaction target: load compacted history base.
                conversation = file.compactedHistory
                promptCounter = promptIndexAtCompaction
                checkpointActive = true
                checkpointBaseLen = conversation.count
                checkpointPromptIndex = promptIndexAtCompaction

                if let autoContinueText, !autoContinueText.isEmpty {
                    conversation.append(.user(autoContinueText))
                }
            }

        case .rewindMarker(let markerTarget):
            if promptCounter <= markerTarget {
                continue
            }
            if checkpointActive && markerTarget >= checkpointPromptIndex {
                let turnsToKeep = markerTarget - checkpointPromptIndex
                var userCount = 0
                var cutPos = conversation.count
                for (i, item) in conversation[checkpointBaseLen...].enumerated() {
                    if case .user = item {
                        userCount += 1
                        if userCount > turnsToKeep {
                            cutPos = checkpointBaseLen + i
                            break
                        }
                    }
                }
                conversation = Array(conversation[..<cutPos])
            } else if markerTarget == 0 {
                conversation.removeAll()
                checkpointActive = false
            } else {
                checkpointActive = false
                var userCount = 0
                var cutPos = conversation.count
                for (i, item) in conversation.enumerated() {
                    if case .user = item {
                        userCount += 1
                        if userCount > markerTarget {
                            cutPos = i
                            break
                        }
                    }
                }
                conversation = Array(conversation[..<cutPos])
            }
            promptCounter = markerTarget

        case .raw:
            break
        }
    }

    // Final truncation if promptCounter exceeded targetPromptIndex
    if promptCounter > targetPromptIndex {
        if checkpointActive && targetPromptIndex >= checkpointPromptIndex {
            let turnsToKeep = targetPromptIndex - checkpointPromptIndex
            var userCount = 0
            var cutPos = conversation.count
            for (i, item) in conversation[checkpointBaseLen...].enumerated() {
                if case .user = item {
                    userCount += 1
                    if userCount > turnsToKeep {
                        cutPos = checkpointBaseLen + i
                        break
                    }
                }
            }
            conversation = Array(conversation[..<cutPos])
        } else if targetPromptIndex == 0 {
            conversation.removeAll()
            checkpointActive = false
        } else {
            checkpointActive = false
            var userCount = 0
            var cutPos = conversation.count
            for (i, item) in conversation.enumerated() {
                if case .user = item {
                    userCount += 1
                    if userCount > targetPromptIndex {
                        cutPos = i
                        break
                    }
                }
            }
            conversation = Array(conversation[..<cutPos])
        }
        promptCounter = targetPromptIndex
    }

    // For pre-compaction reconstructions, prepend System preamble + originalUserInfo if present and missing
    if !checkpointActive && (originalUserInfo != nil || systemPreamble != nil) {
        var preambleItems: [ConversationItem] = []
        if let systemPreamble {
            preambleItems.append(systemPreamble)
        }
        if let originalUserInfo {
            preambleItems.append(.user(originalUserInfo))
        }

        // If conversation already starts with system, don't duplicate
        if let first = conversation.first, case .system = first {
            // Already has system prompt
        } else if !preambleItems.isEmpty {
            conversation = preambleItems + conversation
        }
    }

    return ReplayResult(
        conversation: conversation,
        promptIndexReached: promptCounter,
        originalUserInfo: originalUserInfo,
        lastCompactionPromptIndex: checkpointActive ? checkpointPromptIndex : nil
    )
}
