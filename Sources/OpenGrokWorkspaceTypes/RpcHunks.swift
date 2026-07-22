// RpcHunks.swift
//
// Hunk tracker methods. Ported from
// `crates/codegen/xai-grok-workspace-types/src/rpc/hunks.rs`.

import Foundation
import OpenGrokShared

public enum HunkActionKind: Hashable, Sendable, Codable, Equatable {
    case accept
    case reject

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        switch try c.decode(String.self) {
        case "accept": self = .accept
        case "reject": self = .reject
        default:
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown HunkActionKind")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .accept: try c.encode("accept")
        case .reject: try c.encode("reject")
        }
    }
}

public struct HunkActionReq: Hashable, Sendable, Codable, Equatable {
    public var hunkId: String
    public var action: HunkActionKind
    public init(hunkId: String, action: HunkActionKind) {
        self.hunkId = hunkId
        self.action = action
    }
    enum CodingKeys: String, CodingKey {
        case hunkId = "hunk_id"
        case action
    }
}

public struct HunkSingleActionReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var action: HunkActionReq
    public init(action: HunkActionReq) { self.action = action }
    public static let method: String = "workspace.hunk_action"
    public typealias Response = HunkActionResponse
}

public struct HunkFileActionReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var path: String
    public var action: HunkActionKind
    public init(path: String, action: HunkActionKind) {
        self.path = path
        self.action = action
    }
    public static let method: String = "workspace.hunk_file_action"
    public typealias Response = BulkHunkActionResponse
}

public struct HunkTurnActionReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var promptIndex: UInt64
    public var action: HunkActionKind
    public init(promptIndex: UInt64, action: HunkActionKind) {
        self.promptIndex = promptIndex
        self.action = action
    }
    public static let method: String = "workspace.hunk_turn_action"
    public typealias Response = BulkHunkActionResponse
    enum CodingKeys: String, CodingKey {
        case promptIndex = "prompt_index"
        case action
    }
}

public struct HunkAllActionReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var action: HunkActionKind
    public init(action: HunkActionKind) { self.action = action }
    public static let method: String = "workspace.hunk_all_action"
    public typealias Response = BulkHunkActionResponse
}

public struct HunkGetStagedFilesReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public init() {}
    public static let method: String = "workspace.hunk_get_staged_files"
    public typealias Response = [String]
    public init(from decoder: Decoder) throws {
        _ = try? decoder.container(keyedBy: EmptyKey.self)
    }
    public func encode(to encoder: Encoder) throws {
        _ = encoder.container(keyedBy: EmptyKey.self)
    }
    private enum EmptyKey: CodingKey {}
}

public struct HunkGetFileSummariesReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public init() {}
    public static let method: String = "workspace.hunk_get_file_summaries"
    public typealias Response = [HunkFileSummary]
    public init(from decoder: Decoder) throws {
        _ = try? decoder.container(keyedBy: EmptyKey.self)
    }
    public func encode(to encoder: Encoder) throws {
        _ = encoder.container(keyedBy: EmptyKey.self)
    }
    private enum EmptyKey: CodingKey {}
}

public struct HunkActionResponse: Hashable, Sendable, Codable, Equatable {
    public init() {}
    public init(from decoder: Decoder) throws {
        _ = try? decoder.container(keyedBy: EmptyKey.self)
    }
    public func encode(to encoder: Encoder) throws {
        _ = encoder.container(keyedBy: EmptyKey.self)
    }
    private enum EmptyKey: CodingKey {}
}

public struct BulkHunkActionResponse: Hashable, Sendable, Codable, Equatable {
    public var affected: [String]
    public init(affected: [String] = []) { self.affected = affected }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        affected = try c.decodeIfPresent([String].self, forKey: .affected) ?? []
    }
    enum CodingKeys: String, CodingKey { case affected }
}

public struct HunkFileSummary: Hashable, Sendable, Codable, Equatable {
    public var path: String
    public var hunkCount: UInt64
    public var isAgentFile: Bool
    public init(path: String, hunkCount: UInt64, isAgentFile: Bool) {
        self.path = path
        self.hunkCount = hunkCount
        self.isAgentFile = isAgentFile
    }
    enum CodingKeys: String, CodingKey {
        case path
        case hunkCount = "hunk_count"
        case isAgentFile = "is_agent_file"
    }
}

public struct HunkGetAllHunksReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public init() {}
    public static let method: String = "workspace.get_all_hunks"
    public typealias Response = [HunkWire]
    public init(from decoder: Decoder) throws {
        _ = try? decoder.container(keyedBy: EmptyKey.self)
    }
    public func encode(to encoder: Encoder) throws {
        _ = encoder.container(keyedBy: EmptyKey.self)
    }
    private enum EmptyKey: CodingKey {}
}

public struct HunkGetAllFileContentsReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public init() {}
    public static let method: String = "workspace.hunk_get_all_file_contents"
    public typealias Response = [FileContentEntryWire]
    public init(from decoder: Decoder) throws {
        _ = try? decoder.container(keyedBy: EmptyKey.self)
    }
    public func encode(to encoder: Encoder) throws {
        _ = encoder.container(keyedBy: EmptyKey.self)
    }
    private enum EmptyKey: CodingKey {}
}

public struct HunkGetSessionSummaryReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public init() {}
    public static let method: String = "workspace.get_session_summary"
    public typealias Response = SessionSummaryWire
    public init(from decoder: Decoder) throws {
        _ = try? decoder.container(keyedBy: EmptyKey.self)
    }
    public func encode(to encoder: Encoder) throws {
        _ = encoder.container(keyedBy: EmptyKey.self)
    }
    private enum EmptyKey: CodingKey {}
}

public struct HunkGetFilteredHunksReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var path: String?
    public var source: String?
    public init(path: String? = nil, source: String? = nil) {
        self.path = path
        self.source = source
    }
    public static let method: String = "workspace.hunk_get_filtered_hunks"
    public typealias Response = FilteredHunksResponse
}

// MARK: - Wire mirrors

public struct HunkLineInfoWire: Hashable, Sendable, Codable, Equatable {
    public var oldStart: UInt64
    public var oldCount: UInt64
    public var newStart: UInt64
    public var newCount: UInt64
    public init(oldStart: UInt64, oldCount: UInt64, newStart: UInt64, newCount: UInt64) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
    }
    enum CodingKeys: String, CodingKey {
        case oldStart, oldCount, newStart, newCount
    }
}

/// Internally tagged (`type`) with camelCase variant names. Struct-variant
/// fields keep snake_case (`prompt_index`) per the Rust wire snapshot.
public enum HunkSourceWire: Hashable, Sendable, Codable, Equatable {
    case agentEdit(promptIndex: UInt64)
    case externalEditOnAgentFile
    case external
    case unknown

    private enum CodingKeys: String, CodingKey {
        case type
        case promptIndex = "prompt_index"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(String.self, forKey: .type)
        switch tag {
        case "agentEdit":
            self = .agentEdit(promptIndex: try c.decode(UInt64.self, forKey: .promptIndex))
        case "externalEditOnAgentFile":
            self = .externalEditOnAgentFile
        case "external":
            self = .external
        default:
            self = .unknown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .agentEdit(let promptIndex):
            try c.encode("agentEdit", forKey: .type)
            try c.encode(promptIndex, forKey: .promptIndex)
        case .externalEditOnAgentFile:
            try c.encode("externalEditOnAgentFile", forKey: .type)
        case .external:
            try c.encode("external", forKey: .type)
        case .unknown:
            try c.encode("unknown", forKey: .type)
        }
    }
}

public enum FileContentStatusWire: Hashable, Sendable, Codable, Equatable {
    case missing
    case binary
    case tooLarge
    case lfsPointer
    case symlink
    case full
    case unknown

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        switch try c.decode(String.self) {
        case "missing": self = .missing
        case "binary": self = .binary
        case "tooLarge": self = .tooLarge
        case "lfsPointer": self = .lfsPointer
        case "symlink": self = .symlink
        case "full": self = .full
        default: self = .unknown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .missing: try c.encode("missing")
        case .binary: try c.encode("binary")
        case .tooLarge: try c.encode("tooLarge")
        case .lfsPointer: try c.encode("lfsPointer")
        case .symlink: try c.encode("symlink")
        case .full: try c.encode("full")
        case .unknown: try c.encode("unknown")
        }
    }
}

public struct FileContentViewWire: Hashable, Sendable, Codable, Equatable {
    public var status: FileContentStatusWire
    public var byteLen: UInt64?
    public var content: String?

    public init(status: FileContentStatusWire = .missing, byteLen: UInt64? = nil, content: String? = nil) {
        self.status = status
        self.byteLen = byteLen
        self.content = content
    }

    enum CodingKeys: String, CodingKey { case status, byteLen, content }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(byteLen, forKey: .byteLen)
        try c.encodeIfPresent(content, forKey: .content)
    }
}

public struct HunkWire: Hashable, Sendable, Codable, Equatable {
    public var id: String
    public var path: String
    public var lineInfo: HunkLineInfoWire
    public var source: HunkSourceWire
    public var oldText: String?
    public var newText: String
    public var patch: String?
    public var createdAt: Date

    public init(
        id: String,
        path: String,
        lineInfo: HunkLineInfoWire,
        source: HunkSourceWire,
        oldText: String? = nil,
        newText: String,
        patch: String? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.path = path
        self.lineInfo = lineInfo
        self.source = source
        self.oldText = oldText
        self.newText = newText
        self.patch = patch
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, path, lineInfo, source, oldText, newText, patch, createdAt
    }
}

public struct FileContentEntryWire: Hashable, Sendable, Codable, Equatable {
    public var path: String
    public var baseline: FileContentViewWire
    public var current: FileContentViewWire
    public var isAgentFile: Bool
    public var staged: Bool

    public init(
        path: String,
        baseline: FileContentViewWire,
        current: FileContentViewWire,
        isAgentFile: Bool,
        staged: Bool
    ) {
        self.path = path
        self.baseline = baseline
        self.current = current
        self.isAgentFile = isAgentFile
        self.staged = staged
    }

    enum CodingKeys: String, CodingKey {
        case path, baseline, current, isAgentFile, staged
    }
}

public struct SessionStatsWire: Hashable, Sendable, Codable, Equatable {
    public var acceptedHunks: UInt64
    public var rejectedHunks: UInt64
    public var acceptedLinesAdded: UInt64
    public var acceptedLinesRemoved: UInt64
    public var rejectedLinesAdded: UInt64
    public var rejectedLinesRemoved: UInt64

    public init(
        acceptedHunks: UInt64 = 0,
        rejectedHunks: UInt64 = 0,
        acceptedLinesAdded: UInt64 = 0,
        acceptedLinesRemoved: UInt64 = 0,
        rejectedLinesAdded: UInt64 = 0,
        rejectedLinesRemoved: UInt64 = 0
    ) {
        self.acceptedHunks = acceptedHunks
        self.rejectedHunks = rejectedHunks
        self.acceptedLinesAdded = acceptedLinesAdded
        self.acceptedLinesRemoved = acceptedLinesRemoved
        self.rejectedLinesAdded = rejectedLinesAdded
        self.rejectedLinesRemoved = rejectedLinesRemoved
    }

    enum CodingKeys: String, CodingKey {
        case acceptedHunks, rejectedHunks, acceptedLinesAdded, acceptedLinesRemoved
        case rejectedLinesAdded, rejectedLinesRemoved
    }
}

public struct TurnSummaryWire: Hashable, Sendable, Codable, Equatable {
    public var promptIndex: UInt64
    public var files: [String]
    public var pendingHunks: [HunkWire]
    public var linesAdded: UInt64
    public var linesRemoved: UInt64

    public init(
        promptIndex: UInt64,
        files: [String] = [],
        pendingHunks: [HunkWire] = [],
        linesAdded: UInt64 = 0,
        linesRemoved: UInt64 = 0
    ) {
        self.promptIndex = promptIndex
        self.files = files
        self.pendingHunks = pendingHunks
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
    }

    enum CodingKeys: String, CodingKey {
        case promptIndex, files, pendingHunks, linesAdded, linesRemoved
    }
}

public struct SessionSummaryWire: Hashable, Sendable, Codable, Equatable {
    public var stats: SessionStatsWire
    public var turns: [TurnSummaryWire]
    public var filesModified: UInt64
    public var filesWithPending: UInt64
    public var pendingHunks: UInt64
    public var pendingLinesAdded: UInt64
    public var pendingLinesRemoved: UInt64
    public var unattributedPending: UInt64

    public init(
        stats: SessionStatsWire = SessionStatsWire(),
        turns: [TurnSummaryWire] = [],
        filesModified: UInt64 = 0,
        filesWithPending: UInt64 = 0,
        pendingHunks: UInt64 = 0,
        pendingLinesAdded: UInt64 = 0,
        pendingLinesRemoved: UInt64 = 0,
        unattributedPending: UInt64 = 0
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

    enum CodingKeys: String, CodingKey {
        case stats, turns, filesModified, filesWithPending, pendingHunks
        case pendingLinesAdded, pendingLinesRemoved, unattributedPending
    }
}

public struct FilteredHunksResponse: Hashable, Sendable, Codable, Equatable {
    public var hunks: [HunkWire]
    public var total: UInt64
    public init(hunks: [HunkWire] = [], total: UInt64 = 0) {
        self.hunks = hunks
        self.total = total
    }
}
