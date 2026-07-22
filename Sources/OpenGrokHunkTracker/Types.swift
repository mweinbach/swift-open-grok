// Types.swift
//
// Core types for hunk tracking. Port of xai-hunk-tracker `types.rs`.

import Foundation

/// Unique identifier for a hunk (UUID string).
public struct HunkId: Hashable, Sendable, Codable, Equatable, CustomStringConvertible {
    public let raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    public static func generate() -> HunkId {
        HunkId(UUID().uuidString.lowercased())
    }

    public var description: String {
        String(raw.prefix(8))
    }
}

/// Line information for a hunk (mirrors unified diff header).
public struct HunkLineInfo: Hashable, Sendable, Codable, Equatable, CustomStringConvertible {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
    }

    public var description: String {
        "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
    }

    enum CodingKeys: String, CodingKey {
        case oldStart, oldCount, newStart, newCount
    }
}

/// Direct agent write attribution. Filesystem notifications never become this.
public struct AgentWriteAttribution: Hashable, Sendable, Codable, Equatable {
    public var promptIndex: Int
    public var sessionId: String
    public var agentId: String

    public init(promptIndex: Int, sessionId: String, agentId: String) {
        self.promptIndex = promptIndex
        self.sessionId = sessionId
        self.agentId = agentId
    }
}

/// Result of an agent tool write. Attribution is recorded only on success.
public struct AgentWriteResult: Hashable, Sendable, Codable, Equatable {
    public var succeeded: Bool
    public var path: String
    public var content: String
    public var previousContent: String?
    public var errorMessage: String?

    public init(
        succeeded: Bool,
        path: String,
        content: String,
        previousContent: String? = nil,
        errorMessage: String? = nil
    ) {
        self.succeeded = succeeded
        self.path = path
        self.content = content
        self.previousContent = previousContent
        self.errorMessage = errorMessage
    }

    public static func success(
        path: String,
        content: String,
        previousContent: String? = nil
    ) -> AgentWriteResult {
        AgentWriteResult(
            succeeded: true,
            path: path,
            content: content,
            previousContent: previousContent
        )
    }

    public static func failure(
        path: String,
        content: String,
        errorMessage: String,
        previousContent: String? = nil
    ) -> AgentWriteResult {
        AgentWriteResult(
            succeeded: false,
            path: path,
            content: content,
            previousContent: previousContent,
            errorMessage: errorMessage
        )
    }
}

/// Who made the change. Filesystem notifications never become `.agentEdit`.
public enum HunkSource: Hashable, Sendable, Codable, Equatable {
    case agentEdit(AgentWriteAttribution)
    case externalEditOnAgentFile
    case external

    /// Convenience for tests / simple call sites that only know the prompt index.
    public static func agentEdit(
        promptIndex: Int,
        sessionId: String = "",
        agentId: String = ""
    ) -> HunkSource {
        .agentEdit(AgentWriteAttribution(
            promptIndex: promptIndex,
            sessionId: sessionId,
            agentId: agentId
        ))
    }

    public var isAgentEdit: Bool {
        if case .agentEdit = self { return true }
        return false
    }

    public var isAgentTracked: Bool {
        switch self {
        case .agentEdit, .externalEditOnAgentFile: return true
        case .external: return false
        }
    }

    public var isExternal: Bool {
        switch self {
        case .external, .externalEditOnAgentFile: return true
        case .agentEdit: return false
        }
    }

    public var promptIndex: Int? {
        if case .agentEdit(let a) = self { return a.promptIndex }
        return nil
    }

    public var sessionId: String? {
        if case .agentEdit(let a) = self { return a.sessionId }
        return nil
    }

    public var agentId: String? {
        if case .agentEdit(let a) = self { return a.agentId }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case type, promptIndex, sessionId, agentId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "agentEdit":
            let idx = try c.decode(Int.self, forKey: .promptIndex)
            // Forward-compatible: missing identity fields default to empty.
            let sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
            let agentId = try c.decodeIfPresent(String.self, forKey: .agentId) ?? ""
            self = .agentEdit(promptIndex: idx, sessionId: sessionId, agentId: agentId)
        case "externalEditOnAgentFile":
            self = .externalEditOnAgentFile
        case "external":
            self = .external
        default:
            // Unknown future variant → treat as external (forward compatible).
            self = .external
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .agentEdit(let a):
            try c.encode("agentEdit", forKey: .type)
            try c.encode(a.promptIndex, forKey: .promptIndex)
            try c.encode(a.sessionId, forKey: .sessionId)
            try c.encode(a.agentId, forKey: .agentId)
        case .externalEditOnAgentFile:
            try c.encode("externalEditOnAgentFile", forKey: .type)
        case .external:
            try c.encode("external", forKey: .type)
        }
    }
}

/// A single hunk representing a contiguous change.
public struct Hunk: Sendable, Codable, Equatable {
    public var id: HunkId
    public var path: String
    public var lineInfo: HunkLineInfo
    public var source: HunkSource
    public var oldText: String?
    public var newText: String
    public var patch: String?
    public var createdAt: Date
    public var selected: Bool

    public init(
        id: HunkId = .generate(),
        path: String,
        lineInfo: HunkLineInfo,
        source: HunkSource,
        oldText: String? = nil,
        newText: String = "",
        patch: String? = nil,
        createdAt: Date = Date(),
        selected: Bool = false
    ) {
        self.id = id
        self.path = path
        self.lineInfo = lineInfo
        self.source = source
        self.oldText = oldText
        self.newText = newText
        self.patch = patch
        self.createdAt = createdAt
        self.selected = selected
    }

    public static func fileCreated(path: String, content: String, source: HunkSource) -> Hunk {
        let count = max(content.split(separator: "\n", omittingEmptySubsequences: false).count, 1)
        // empty content → no lines meaningfully; callers usually skip empty
        let lineCount = content.isEmpty ? 0 : max(content.components(separatedBy: "\n").count - (content.hasSuffix("\n") ? 1 : 0), 1)
        _ = count
        return Hunk(
            path: path,
            lineInfo: HunkLineInfo(oldStart: 0, oldCount: 0, newStart: 1, newCount: max(lineCount, 1)),
            source: source,
            oldText: nil,
            newText: content
        )
    }

    public static func fileDeleted(path: String, content: String, source: HunkSource) -> Hunk {
        let lineCount = max(content.components(separatedBy: "\n").count - (content.hasSuffix("\n") ? 1 : 0), 1)
        return Hunk(
            path: path,
            lineInfo: HunkLineInfo(oldStart: 1, oldCount: lineCount, newStart: 0, newCount: 0),
            source: source,
            oldText: content,
            newText: ""
        )
    }

    public var summary: String {
        let additions = newText.isEmpty ? 0 : newText.components(separatedBy: "\n").count - (newText.hasSuffix("\n") ? 1 : 0)
        let deletions: Int
        if let old = oldText, !old.isEmpty {
            deletions = old.components(separatedBy: "\n").count - (old.hasSuffix("\n") ? 1 : 0)
        } else {
            deletions = 0
        }
        return "+\(max(additions, newText.isEmpty ? 0 : 1))/-\(deletions)"
    }

    enum CodingKeys: String, CodingKey {
        case id, path, lineInfo, source, oldText, newText, patch, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(HunkId.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        lineInfo = try c.decode(HunkLineInfo.self, forKey: .lineInfo)
        source = try c.decode(HunkSource.self, forKey: .source)
        oldText = try c.decodeIfPresent(String.self, forKey: .oldText)
        newText = try c.decodeIfPresent(String.self, forKey: .newText) ?? ""
        patch = try c.decodeIfPresent(String.self, forKey: .patch)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        selected = false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(path, forKey: .path)
        try c.encode(lineInfo, forKey: .lineInfo)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(oldText, forKey: .oldText)
        try c.encode(newText, forKey: .newText)
        try c.encodeIfPresent(patch, forKey: .patch)
        try c.encode(createdAt, forKey: .createdAt)
    }
}

public enum HunkAction: String, Sendable, Equatable {
    case accept
    case reject
}

public enum HunkActionError: Error, Equatable, Sendable {
    case hunkNotFound(HunkId)
    case writeError(path: String, message: String)
    case deleteError(path: String, message: String)
    case readError(path: String, message: String)
}

public enum TrackingMode: String, Sendable, Equatable, Codable {
    case agentOnly = "agent_only"
    case allDirty = "all_dirty"
}

public enum HunkSourceFilter: String, Sendable, Equatable {
    case agent
    case external
}

public enum HunkRemovalReason: String, Sendable, Equatable, Codable {
    case accepted
    case rejected
    case superseded
}

public enum FileContentStatus: String, Sendable, Equatable, Codable {
    case missing
    case binary
    case tooLarge = "tooLarge"
    case lfsPointer = "lfsPointer"
    case symlink
    case full
}

public struct FileContentView: Sendable, Equatable, Codable {
    public var status: FileContentStatus
    public var byteLen: Int?
    public var content: String?

    public init(status: FileContentStatus, byteLen: Int? = nil, content: String? = nil) {
        self.status = status
        self.byteLen = byteLen
        self.content = content
    }

    public static func missing() -> FileContentView {
        FileContentView(status: .missing, byteLen: nil, content: nil)
    }
    public static func binary(_ len: Int?) -> FileContentView {
        FileContentView(status: .binary, byteLen: len, content: nil)
    }
    public static func tooLarge(_ len: Int) -> FileContentView {
        FileContentView(status: .tooLarge, byteLen: len, content: nil)
    }
    public static func lfsPointer(_ len: Int) -> FileContentView {
        FileContentView(status: .lfsPointer, byteLen: len, content: nil)
    }
    public static func symlink() -> FileContentView {
        FileContentView(status: .symlink, byteLen: nil, content: nil)
    }
    public static func full(_ content: String) -> FileContentView {
        FileContentView(status: .full, byteLen: content.utf8.count, content: content)
    }
}

public struct FileHunkData: Sendable, Equatable {
    public var hunks: [Hunk]
    public var baseline: FileContentView
    public var current: FileContentView

    public init(
        hunks: [Hunk] = [],
        baseline: FileContentView = .missing(),
        current: FileContentView = .missing()
    ) {
        self.hunks = hunks
        self.baseline = baseline
        self.current = current
    }
}

public struct SessionStats: Sendable, Equatable, Codable {
    public var acceptedHunks: Int
    public var rejectedHunks: Int
    public var acceptedLinesAdded: Int
    public var acceptedLinesRemoved: Int
    public var rejectedLinesAdded: Int
    public var rejectedLinesRemoved: Int

    public init(
        acceptedHunks: Int = 0,
        rejectedHunks: Int = 0,
        acceptedLinesAdded: Int = 0,
        acceptedLinesRemoved: Int = 0,
        rejectedLinesAdded: Int = 0,
        rejectedLinesRemoved: Int = 0
    ) {
        self.acceptedHunks = acceptedHunks
        self.rejectedHunks = rejectedHunks
        self.acceptedLinesAdded = acceptedLinesAdded
        self.acceptedLinesRemoved = acceptedLinesRemoved
        self.rejectedLinesAdded = rejectedLinesAdded
        self.rejectedLinesRemoved = rejectedLinesRemoved
    }
}

public struct TurnSummary: Sendable, Equatable {
    public var promptIndex: Int
    public var files: [String]
    public var pendingHunks: [Hunk]
    public var linesAdded: Int
    public var linesRemoved: Int

    public init(
        promptIndex: Int,
        files: [String] = [],
        pendingHunks: [Hunk] = [],
        linesAdded: Int = 0,
        linesRemoved: Int = 0
    ) {
        self.promptIndex = promptIndex
        self.files = files
        self.pendingHunks = pendingHunks
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
    }
}

public struct SessionSummary: Sendable, Equatable {
    public var stats: SessionStats
    public var turns: [TurnSummary]
    public var filesModified: Int
    public var filesWithPending: Int
    public var pendingHunks: Int
    public var pendingLinesAdded: Int
    public var pendingLinesRemoved: Int
    public var unattributedPending: Int

    public init(
        stats: SessionStats = SessionStats(),
        turns: [TurnSummary] = [],
        filesModified: Int = 0,
        filesWithPending: Int = 0,
        pendingHunks: Int = 0,
        pendingLinesAdded: Int = 0,
        pendingLinesRemoved: Int = 0,
        unattributedPending: Int = 0
    ) {
        self.stats = stats
        self.turns = turns
        self.filesModified = filesModified
        self.filesWithPending = filesWithPending
        self.pendingHunks = pendingHunks
        self.pendingLinesAdded = pendingLinesAdded
        self.pendingLinesRemoved = pendingLinesRemoved
        self.unattributedPending = unattributedPending
    }
}

/// Explicit file content storage state.
public enum FileContentState: Sendable, Equatable, Codable {
    case missing
    case binary(byteLen: Int?)
    case tooLarge(byteLen: Int)
    case lfsPointer(byteLen: Int)
    case symlink
    case full(String)

    public var isDiffable: Bool {
        if case .full = self { return true }
        return false
    }

    public var asString: String? {
        if case .full(let s) = self { return s }
        return nil
    }

    public func asView() -> FileContentView {
        switch self {
        case .missing: return .missing()
        case .binary(let n): return .binary(n)
        case .tooLarge(let n): return .tooLarge(n)
        case .lfsPointer(let n): return .lfsPointer(n)
        case .symlink: return .symlink()
        case .full(let s): return .full(s)
        }
    }
}

public let maxTrackedTextBytes: Int = 1_024 * 1_024

public struct FileHunkStateSnapshot: Sendable, Equatable, Codable {
    public var baseline: FileContentState
    public var currentContent: FileContentState
    public var hunks: [Hunk]
    public var isAgentFile: Bool
    public var baselineAccepted: Bool

    public init(
        baseline: FileContentState,
        currentContent: FileContentState,
        hunks: [Hunk] = [],
        isAgentFile: Bool = false,
        baselineAccepted: Bool = false
    ) {
        self.baseline = baseline
        self.currentContent = currentContent
        self.hunks = hunks
        self.isAgentFile = isAgentFile
        self.baselineAccepted = baselineAccepted
    }
}

/// Current on-disk schema version for `HunkTrackerSnapshot`.
public let hunkTrackerSnapshotSchemaVersion: Int = 1

public struct HunkTrackerSnapshot: Sendable, Equatable, Codable {
    /// Schema version for forward-compatible persistence.
    public var schemaVersion: Int
    public var sessionId: String
    public var fileStates: [String: FileHunkStateSnapshot]
    public var turnIndex: [Int: Set<HunkId>]
    public var sessionStats: SessionStats

    public init(
        schemaVersion: Int = hunkTrackerSnapshotSchemaVersion,
        sessionId: String = "",
        fileStates: [String: FileHunkStateSnapshot] = [:],
        turnIndex: [Int: Set<HunkId>] = [:],
        sessionStats: SessionStats = SessionStats()
    ) {
        self.schemaVersion = schemaVersion
        self.sessionId = sessionId
        self.fileStates = fileStates
        self.turnIndex = turnIndex
        self.sessionStats = sessionStats
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, sessionId, fileStates, turnIndex, sessionStats
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Forward-compatible: unknown/missing schemaVersion defaults to 1.
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? hunkTrackerSnapshotSchemaVersion
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
        fileStates = try c.decodeIfPresent([String: FileHunkStateSnapshot].self, forKey: .fileStates) ?? [:]
        // turnIndex keys are Int; JSON object keys are strings.
        if let raw = try c.decodeIfPresent([String: [HunkId]].self, forKey: .turnIndex) {
            var mapped: [Int: Set<HunkId>] = [:]
            for (k, v) in raw {
                if let i = Int(k) { mapped[i] = Set(v) }
            }
            turnIndex = mapped
        } else {
            turnIndex = [:]
        }
        sessionStats = try c.decodeIfPresent(SessionStats.self, forKey: .sessionStats) ?? SessionStats()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(fileStates, forKey: .fileStates)
        var turnMap: [String: [HunkId]] = [:]
        for (k, v) in turnIndex {
            turnMap[String(k)] = Array(v)
        }
        try c.encode(turnMap, forKey: .turnIndex)
        try c.encode(sessionStats, forKey: .sessionStats)
    }

    /// Pure path rewrite for worktree/fork transfers.
    public mutating func rewritePaths(oldCwd: String, canonicalOldCwd: String, newCwd: String) {
        var rewritten: [String: FileHunkStateSnapshot] = [:]
        for (path, var state) in fileStates {
            let newPath = rewriteSinglePath(path, oldCwd: oldCwd, canonicalOld: canonicalOldCwd, newCwd: newCwd) ?? path
            for i in state.hunks.indices {
                state.hunks[i].path = newPath
            }
            rewritten[newPath] = state
        }
        fileStates = rewritten
    }
}

/// Atomic on-disk persistence for restart survival.
public enum HunkTrackerStore {
    public static func save(_ snapshot: HunkTrackerSnapshot, to path: String) throws {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        let tmp = path + ".tmp-\(UUID().uuidString)"
        try data.write(to: URL(fileURLWithPath: tmp), options: .atomic)
        // Atomic replace.
        if fm.fileExists(atPath: path) {
            _ = try fm.replaceItemAt(
                URL(fileURLWithPath: path),
                withItemAt: URL(fileURLWithPath: tmp)
            )
        } else {
            try fm.moveItem(atPath: tmp, toPath: path)
        }
    }

    public static func load(from path: String) throws -> HunkTrackerSnapshot {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HunkTrackerSnapshot.self, from: data)
    }
}

public struct HunkTurnDelta: Sendable, Equatable {
    public var promptIndex: Int
    public var fileStates: [String: FileHunkStateSnapshot]
    public var hunkIds: Set<HunkId>

    public init(
        promptIndex: Int,
        fileStates: [String: FileHunkStateSnapshot] = [:],
        hunkIds: Set<HunkId> = []
    ) {
        self.promptIndex = promptIndex
        self.fileStates = fileStates
        self.hunkIds = hunkIds
    }
}

func rewriteSinglePath(_ path: String, oldCwd: String, canonicalOld: String, newCwd: String) -> String? {
    if path.hasPrefix(canonicalOld) {
        let rel = String(path.dropFirst(canonicalOld.count).drop(while: { $0 == "/" }))
        return (newCwd as NSString).appendingPathComponent(rel)
    }
    if path.hasPrefix(oldCwd) {
        let rel = String(path.dropFirst(oldCwd.count).drop(while: { $0 == "/" }))
        return (newCwd as NSString).appendingPathComponent(rel)
    }
    return nil
}
