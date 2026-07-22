// RpcWorktree.swift
//
// Worktree lifecycle methods. Ported from
// `crates/codegen/xai-grok-workspace-types/src/rpc/worktree.rs`.

import Foundation
import OpenGrokShared

public enum WorktreeType: Hashable, Sendable, Codable, Equatable {
    case linked
    case standalone
    case git

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        switch try c.decode(String.self) {
        case "linked": self = .linked
        case "standalone": self = .standalone
        case "git": self = .git
        default:
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown WorktreeType")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .linked: try c.encode("linked")
        case .standalone: try c.encode("standalone")
        case .git: try c.encode("git")
        }
    }

    public static func parse(_ s: String) -> WorktreeType? {
        switch s {
        case "linked": return .linked
        case "standalone": return .standalone
        case "git": return .git
        default: return nil
        }
    }
}

public struct DirtyStateSummary: Hashable, Sendable, Codable, Equatable {
    public var stagedCount: UInt32
    public var modifiedCount: UInt32
    public var deletedCount: UInt32
    public var untrackedCount: UInt32
    public var hasPartiallyStaged: Bool
    public var skippedDirs: [String]

    public init(
        stagedCount: UInt32 = 0,
        modifiedCount: UInt32 = 0,
        deletedCount: UInt32 = 0,
        untrackedCount: UInt32 = 0,
        hasPartiallyStaged: Bool = false,
        skippedDirs: [String] = []
    ) {
        self.stagedCount = stagedCount
        self.modifiedCount = modifiedCount
        self.deletedCount = deletedCount
        self.untrackedCount = untrackedCount
        self.hasPartiallyStaged = hasPartiallyStaged
        self.skippedDirs = skippedDirs
    }

    enum CodingKeys: String, CodingKey {
        case stagedCount, modifiedCount, deletedCount, untrackedCount
        case hasPartiallyStaged, skippedDirs
    }
}

public struct CopiedChangesSummary: Hashable, Sendable, Codable, Equatable {
    public var stagedCopied: UInt32
    public var modifiedCopied: UInt32
    public var untrackedCopied: UInt32
    public var deletionsApplied: UInt32
    public var warnings: [String]

    public init(
        stagedCopied: UInt32 = 0,
        modifiedCopied: UInt32 = 0,
        untrackedCopied: UInt32 = 0,
        deletionsApplied: UInt32 = 0,
        warnings: [String] = []
    ) {
        self.stagedCopied = stagedCopied
        self.modifiedCopied = modifiedCopied
        self.untrackedCopied = untrackedCopied
        self.deletionsApplied = deletionsApplied
        self.warnings = warnings
    }

    enum CodingKeys: String, CodingKey {
        case stagedCopied, modifiedCopied, untrackedCopied, deletionsApplied, warnings
    }
}

public enum WorktreeCopyMode: Hashable, Sendable, Codable, Equatable {
    case clean
    case dirty

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        switch try c.decode(String.self) {
        case "clean": self = .clean
        case "dirty": self = .dirty
        default:
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown WorktreeCopyMode")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .clean: try c.encode("clean")
        case .dirty: try c.encode("dirty")
        }
    }
}

public struct CreateWorktreeRequest: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var sessionId: String
    public var sourcePath: String
    public var worktreePath: String?
    public var copyMode: WorktreeCopyMode
    public var gitRef: String?
    public var copyIgnoredInBackground: Bool
    public var ignoredSkipPatterns: [String]
    public var worktreeType: WorktreeType?
    public var label: String?

    public init(
        sessionId: String,
        sourcePath: String,
        worktreePath: String? = nil,
        copyMode: WorktreeCopyMode = .dirty,
        gitRef: String? = nil,
        copyIgnoredInBackground: Bool = false,
        ignoredSkipPatterns: [String] = [],
        worktreeType: WorktreeType? = nil,
        label: String? = nil
    ) {
        self.sessionId = sessionId
        self.sourcePath = sourcePath
        self.worktreePath = worktreePath
        self.copyMode = copyMode
        self.gitRef = gitRef
        self.copyIgnoredInBackground = copyIgnoredInBackground
        self.ignoredSkipPatterns = ignoredSkipPatterns
        self.worktreeType = worktreeType
        self.label = label
    }

    public static let method: String = "workspace.create_worktree"
    public typealias Response = JSONValue

    enum CodingKeys: String, CodingKey {
        case sessionId, sourcePath, worktreePath, copyMode, gitRef
        case copyIgnoredInBackground, ignoredSkipPatterns, worktreeType, label
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        sourcePath = try c.decode(String.self, forKey: .sourcePath)
        worktreePath = try c.decodeIfPresent(String.self, forKey: .worktreePath)
        copyMode = try c.decodeIfPresent(WorktreeCopyMode.self, forKey: .copyMode) ?? .dirty
        gitRef = try c.decodeIfPresent(String.self, forKey: .gitRef)
        copyIgnoredInBackground = try c.decodeIfPresent(Bool.self, forKey: .copyIgnoredInBackground) ?? false
        ignoredSkipPatterns = try c.decodeIfPresent([String].self, forKey: .ignoredSkipPatterns) ?? []
        worktreeType = try c.decodeIfPresent(WorktreeType.self, forKey: .worktreeType)
        label = try c.decodeIfPresent(String.self, forKey: .label)
    }
}

public enum CreateWorktreeResponse: Hashable, Sendable, Codable, Equatable {
    case creating(sessionId: String, worktreePath: String, sourceGitRoot: String?)
    case exists(sessionId: String, worktreePath: String, commit: String, sourceGitRoot: String?)

    private enum CodingKeys: String, CodingKey {
        case status, sessionId, worktreePath, commit, sourceGitRoot
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let status = try c.decode(String.self, forKey: .status)
        switch status {
        case "creating":
            self = .creating(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                worktreePath: try c.decode(String.self, forKey: .worktreePath),
                sourceGitRoot: try c.decodeIfPresent(String.self, forKey: .sourceGitRoot)
            )
        case "exists":
            self = .exists(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                worktreePath: try c.decode(String.self, forKey: .worktreePath),
                commit: try c.decode(String.self, forKey: .commit),
                sourceGitRoot: try c.decodeIfPresent(String.self, forKey: .sourceGitRoot)
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .status, in: c, debugDescription: "unknown CreateWorktreeResponse status")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .creating(let sessionId, let worktreePath, let sourceGitRoot):
            try c.encode("creating", forKey: .status)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(worktreePath, forKey: .worktreePath)
            try c.encodeIfPresent(sourceGitRoot, forKey: .sourceGitRoot)
        case .exists(let sessionId, let worktreePath, let commit, let sourceGitRoot):
            try c.encode("exists", forKey: .status)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(worktreePath, forKey: .worktreePath)
            try c.encode(commit, forKey: .commit)
            try c.encodeIfPresent(sourceGitRoot, forKey: .sourceGitRoot)
        }
    }
}

/// Transparent wrapper over `CreateWorktreeRequest`.
public struct WorktreeCreateSyncReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var request: CreateWorktreeRequest
    public init(_ request: CreateWorktreeRequest) { self.request = request }
    public static let method: String = "workspace.worktree_create_sync"
    public typealias Response = JSONValue

    public init(from decoder: Decoder) throws {
        request = try CreateWorktreeRequest(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try request.encode(to: encoder)
    }
}

public struct RemoveWorktreeRequest: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var worktreePath: String?
    public var idOrPath: String?
    public var force: Bool
    public var dryRun: Bool

    public init(worktreePath: String? = nil, idOrPath: String? = nil, force: Bool = false, dryRun: Bool = false) {
        self.worktreePath = worktreePath
        self.idOrPath = idOrPath
        self.force = force
        self.dryRun = dryRun
    }

    public static let method: String = "workspace.remove_worktree"
    public typealias Response = JSONValue

    enum CodingKeys: String, CodingKey {
        case worktreePath, idOrPath, force, dryRun
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        worktreePath = try c.decodeIfPresent(String.self, forKey: .worktreePath)
        idOrPath = try c.decodeIfPresent(String.self, forKey: .idOrPath)
        force = try c.decodeIfPresent(Bool.self, forKey: .force) ?? false
        dryRun = try c.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false
    }
}

public struct RemoveWorktreeResponse: Hashable, Sendable, Codable, Equatable {
    public var removed: Bool
    public var resolvedPath: String?
    public init(removed: Bool, resolvedPath: String? = nil) {
        self.removed = removed
        self.resolvedPath = resolvedPath
    }
    enum CodingKeys: String, CodingKey { case removed, resolvedPath }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(removed, forKey: .removed)
        try c.encodeIfPresent(resolvedPath, forKey: .resolvedPath)
    }
}

public struct CreateWorktreeFromWorktreeRequestWire: Hashable, Sendable, Codable, Equatable {
    public var sourceWorktreePath: String
    public var newSessionId: String
    public var copyMode: WorktreeCopyMode
    public var gitRef: String?
    public var worktreeType: WorktreeType?
    public var label: String?

    public init(
        sourceWorktreePath: String,
        newSessionId: String,
        copyMode: WorktreeCopyMode = .dirty,
        gitRef: String? = nil,
        worktreeType: WorktreeType? = nil,
        label: String? = nil
    ) {
        self.sourceWorktreePath = sourceWorktreePath
        self.newSessionId = newSessionId
        self.copyMode = copyMode
        self.gitRef = gitRef
        self.worktreeType = worktreeType
        self.label = label
    }

    enum CodingKeys: String, CodingKey {
        case sourceWorktreePath, newSessionId, copyMode, gitRef, worktreeType, label
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceWorktreePath = try c.decode(String.self, forKey: .sourceWorktreePath)
        newSessionId = try c.decode(String.self, forKey: .newSessionId)
        copyMode = try c.decodeIfPresent(WorktreeCopyMode.self, forKey: .copyMode) ?? .dirty
        gitRef = try c.decodeIfPresent(String.self, forKey: .gitRef)
        worktreeType = try c.decodeIfPresent(WorktreeType.self, forKey: .worktreeType)
        label = try c.decodeIfPresent(String.self, forKey: .label)
    }
}

public struct CreateWorktreeFromWorktreeResponse: Hashable, Sendable, Codable, Equatable {
    public var status: String
    public var newSessionId: String
    public var worktreePath: String
    public var commit: String?
    public var copiedChanges: CopiedChangesSummary?
    public var sourceGitRoot: String?

    public init(
        status: String,
        newSessionId: String,
        worktreePath: String,
        commit: String? = nil,
        copiedChanges: CopiedChangesSummary? = nil,
        sourceGitRoot: String? = nil
    ) {
        self.status = status
        self.newSessionId = newSessionId
        self.worktreePath = worktreePath
        self.commit = commit
        self.copiedChanges = copiedChanges
        self.sourceGitRoot = sourceGitRoot
    }

    enum CodingKeys: String, CodingKey {
        case status, newSessionId, worktreePath, commit, copiedChanges
        case sourceGitRoot
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status)
        try c.encode(newSessionId, forKey: .newSessionId)
        try c.encode(worktreePath, forKey: .worktreePath)
        try c.encodeIfPresent(commit, forKey: .commit)
        try c.encodeIfPresent(copiedChanges, forKey: .copiedChanges)
        try c.encodeIfPresent(sourceGitRoot, forKey: .sourceGitRoot)
    }
}

/// Keeps the `{ "inner": { … } }` wrapper (not transparent).
public struct CreateWorktreeFromWorktreeSyncReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var inner: CreateWorktreeFromWorktreeRequestWire
    public init(inner: CreateWorktreeFromWorktreeRequestWire) { self.inner = inner }
    public static let method: String = "workspace.worktree_create_from_worktree_sync"
    public typealias Response = CreateWorktreeFromWorktreeResponse
}

public enum ApplyMode: Hashable, Sendable, Codable, Equatable {
    case overwrite
    case merge

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        switch try c.decode(String.self) {
        case "overwrite": self = .overwrite
        case "merge": self = .merge
        default:
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown ApplyMode")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .overwrite: try c.encode("overwrite")
        case .merge: try c.encode("merge")
        }
    }
}

public struct ApplyWorktreeRequest: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var sessionId: String
    public var worktreePath: String
    public var mode: ApplyMode

    public init(sessionId: String, worktreePath: String, mode: ApplyMode = .overwrite) {
        self.sessionId = sessionId
        self.worktreePath = worktreePath
        self.mode = mode
    }

    public static let method: String = "workspace.apply_worktree"
    public typealias Response = JSONValue

    enum CodingKeys: String, CodingKey { case sessionId, worktreePath, mode }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        worktreePath = try c.decode(String.self, forKey: .worktreePath)
        mode = try c.decodeIfPresent(ApplyMode.self, forKey: .mode) ?? .overwrite
    }
}

public struct WorktreeShowReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var idOrPath: String
    public init(idOrPath: String) { self.idOrPath = idOrPath }
    public static let method: String = "workspace.worktree_show"
    public typealias Response = JSONValue
    enum CodingKeys: String, CodingKey { case idOrPath = "id_or_path" }
}

public struct WorktreeGcReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var dryRun: Bool
    public var maxAgeSecs: Int64?
    public var force: Bool

    public init(dryRun: Bool = false, maxAgeSecs: Int64? = nil, force: Bool = false) {
        self.dryRun = dryRun
        self.maxAgeSecs = maxAgeSecs
        self.force = force
    }

    public static let method: String = "workspace.worktree_gc"
    public typealias Response = JSONValue

    enum CodingKeys: String, CodingKey {
        case dryRun = "dry_run"
        case maxAgeSecs = "max_age_secs"
        case force
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dryRun = try c.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false
        maxAgeSecs = try c.decodeIfPresent(Int64.self, forKey: .maxAgeSecs)
        force = try c.decodeIfPresent(Bool.self, forKey: .force) ?? false
    }
}

public struct WorktreeListReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var repo: String?
    public var types: [String]
    public var includeAll: Bool

    public init(repo: String? = nil, types: [String] = [], includeAll: Bool = false) {
        self.repo = repo
        self.types = types
        self.includeAll = includeAll
    }

    public static let method: String = "workspace.worktree_list"
    public typealias Response = JSONValue

    enum CodingKeys: String, CodingKey {
        case repo
        case types = "type"
        case includeAll = "include_all"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repo = try c.decodeIfPresent(String.self, forKey: .repo)
        types = try c.decodeIfPresent([String].self, forKey: .types) ?? []
        includeAll = try c.decodeIfPresent(Bool.self, forKey: .includeAll) ?? false
    }
}

public struct WorktreeDbRebuildReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public init() {}
    public static let method: String = "workspace.worktree_db_rebuild"
    public typealias Response = JSONValue
    public init(from decoder: Decoder) throws {
        _ = try? decoder.container(keyedBy: CodingKeys.self)
    }
    public func encode(to encoder: Encoder) throws {
        _ = encoder.container(keyedBy: CodingKeys.self)
    }
    private enum CodingKeys: CodingKey {}
}

public struct WorktreeDbPathReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public init() {}
    public static let method: String = "workspace.worktree_db_path"
    public typealias Response = WorktreeDbPathResponse
    public init(from decoder: Decoder) throws {
        _ = try? decoder.container(keyedBy: CodingKeys.self)
    }
    public func encode(to encoder: Encoder) throws {
        _ = encoder.container(keyedBy: CodingKeys.self)
    }
    private enum CodingKeys: CodingKey {}
}

public struct WorktreeDbPathResponse: Hashable, Sendable, Codable, Equatable {
    public var path: String?
    public init(path: String? = nil) { self.path = path }
}

public struct WorktreeDbStatsReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public init() {}
    public static let method: String = "workspace.worktree_db_stats"
    public typealias Response = JSONValue
    public init(from decoder: Decoder) throws {
        _ = try? decoder.container(keyedBy: CodingKeys.self)
    }
    public func encode(to encoder: Encoder) throws {
        _ = encoder.container(keyedBy: CodingKeys.self)
    }
    private enum CodingKeys: CodingKey {}
}
