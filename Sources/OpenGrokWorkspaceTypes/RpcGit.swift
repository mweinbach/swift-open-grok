// RpcGit.swift
//
// Git methods (`workspace.git_*`, `workspace.detect_vcs_kind`). Ported
// from `crates/codegen/xai-grok-workspace-types/src/rpc/git.rs`.
//
// Note: `DetectedVcsKind` is the RPC detect-VCS enum (git /
// jujutsuColocated / none) and is distinct from the stream-side
// `VcsKind` (`git` / `jj`) in `WorkspaceTypes.swift`.

import Foundation
import OpenGrokShared

// MARK: - Requests

public struct GitStatusReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public init() {}
    public static let method: String = "workspace.git_status"
    public typealias Response = JSONValue
    public init(from decoder: Decoder) throws {
        _ = try? decoder.container(keyedBy: EmptyKey.self)
    }
    public func encode(to encoder: Encoder) throws {
        _ = encoder.container(keyedBy: EmptyKey.self)
    }
    private enum EmptyKey: CodingKey {}
}

public enum GitStatusFormat: Hashable, Sendable, Codable, Equatable {
    case structured
    case prompt

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        switch try c.decode(String.self) {
        case "structured": self = .structured
        case "prompt": self = .prompt
        default:
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown GitStatusFormat")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .structured: try c.encode("structured")
        case .prompt: try c.encode("prompt")
        }
    }
}

public struct GitStatusExtReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var gitRoot: String?
    public var includeUntracked: Bool
    public var includeStats: Bool
    public var ignoreSubmodules: Bool
    public var includePatches: Bool
    public var format: GitStatusFormat

    public init(
        gitRoot: String? = nil,
        includeUntracked: Bool = true,
        includeStats: Bool = false,
        ignoreSubmodules: Bool = true,
        includePatches: Bool = false,
        format: GitStatusFormat = .structured
    ) {
        self.gitRoot = gitRoot
        self.includeUntracked = includeUntracked
        self.includeStats = includeStats
        self.ignoreSubmodules = ignoreSubmodules
        self.includePatches = includePatches
        self.format = format
    }

    public static let method: String = "workspace.git_status_ext"
    public typealias Response = GitStatusExtResponse

    enum CodingKeys: String, CodingKey {
        case gitRoot = "git_root"
        case includeUntracked = "include_untracked"
        case includeStats = "include_stats"
        case ignoreSubmodules = "ignore_submodules"
        case includePatches = "include_patches"
        case format
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gitRoot = try c.decodeIfPresent(String.self, forKey: .gitRoot)
        includeUntracked = try c.decodeIfPresent(Bool.self, forKey: .includeUntracked) ?? true
        includeStats = try c.decodeIfPresent(Bool.self, forKey: .includeStats) ?? false
        ignoreSubmodules = try c.decodeIfPresent(Bool.self, forKey: .ignoreSubmodules) ?? true
        includePatches = try c.decodeIfPresent(Bool.self, forKey: .includePatches) ?? false
        format = try c.decodeIfPresent(GitStatusFormat.self, forKey: .format) ?? .structured
    }
}

public struct GitFilesReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var gitRoot: String?
    public var paths: [String]
    public var version: String

    public init(gitRoot: String? = nil, paths: [String], version: String = "HEAD") {
        self.gitRoot = gitRoot
        self.paths = paths
        self.version = version
    }

    public static let method: String = "workspace.git_files"
    public typealias Response = GitReadFilesData

    enum CodingKeys: String, CodingKey {
        case gitRoot = "git_root"
        case paths, version
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gitRoot = try c.decodeIfPresent(String.self, forKey: .gitRoot)
        paths = try c.decode([String].self, forKey: .paths)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "HEAD"
    }
}

public struct GitDiffRpcReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var gitRoot: String?
    public var paths: [String]?
    public var from: String
    public var to: String
    public var includePatch: Bool
    public var includeContent: Bool
    public var mergeBase: Bool

    public init(
        gitRoot: String? = nil,
        paths: [String]? = nil,
        from: String = "HEAD",
        to: String = "working",
        includePatch: Bool = false,
        includeContent: Bool = false,
        mergeBase: Bool = false
    ) {
        self.gitRoot = gitRoot
        self.paths = paths
        self.from = from
        self.to = to
        self.includePatch = includePatch
        self.includeContent = includeContent
        self.mergeBase = mergeBase
    }

    public static let method: String = "workspace.git_diff"
    public typealias Response = GitDiffsData

    enum CodingKeys: String, CodingKey {
        case gitRoot = "git_root"
        case paths, from, to
        case includePatch = "include_patch"
        case includeContent = "include_content"
        case mergeBase = "merge_base"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gitRoot = try c.decodeIfPresent(String.self, forKey: .gitRoot)
        paths = try c.decodeIfPresent([String].self, forKey: .paths)
        from = try c.decodeIfPresent(String.self, forKey: .from) ?? "HEAD"
        to = try c.decodeIfPresent(String.self, forKey: .to) ?? "working"
        includePatch = try c.decodeIfPresent(Bool.self, forKey: .includePatch) ?? false
        includeContent = try c.decodeIfPresent(Bool.self, forKey: .includeContent) ?? false
        mergeBase = try c.decodeIfPresent(Bool.self, forKey: .mergeBase) ?? false
    }
}

public struct GitStageReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var gitRoot: String?
    public var paths: [String]?
    public init(gitRoot: String? = nil, paths: [String]? = nil) {
        self.gitRoot = gitRoot
        self.paths = paths
    }
    public static let method: String = "workspace.git_stage"
    public typealias Response = StageData
    enum CodingKeys: String, CodingKey {
        case gitRoot = "git_root"
        case paths
    }
}

public struct GitStageContentReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var gitRoot: String?
    public var path: String
    public var content: String
    public init(gitRoot: String? = nil, path: String, content: String) {
        self.gitRoot = gitRoot
        self.path = path
        self.content = content
    }
    public static let method: String = "workspace.git_stage_content"
    public typealias Response = WorkspaceRpcUnit
    enum CodingKeys: String, CodingKey {
        case gitRoot = "git_root"
        case path, content
    }
}

public struct GitUnstageReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var gitRoot: String?
    public var paths: [String]?
    public init(gitRoot: String? = nil, paths: [String]? = nil) {
        self.gitRoot = gitRoot
        self.paths = paths
    }
    public static let method: String = "workspace.git_unstage"
    public typealias Response = WorkspaceRpcUnit
    enum CodingKeys: String, CodingKey {
        case gitRoot = "git_root"
        case paths
    }
}

public enum DiscardScope: Hashable, Sendable, Codable, Equatable {
    case working
    case staged
    case both

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        switch try c.decode(String.self) {
        case "working": self = .working
        case "staged": self = .staged
        case "both": self = .both
        default:
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown DiscardScope")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .working: try c.encode("working")
        case .staged: try c.encode("staged")
        case .both: try c.encode("both")
        }
    }
}

public struct GitDiscardReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var gitRoot: String?
    public var paths: [String]?
    public var scope: DiscardScope
    public var includeUntracked: Bool

    public init(
        gitRoot: String? = nil,
        paths: [String]? = nil,
        scope: DiscardScope = .both,
        includeUntracked: Bool = false
    ) {
        self.gitRoot = gitRoot
        self.paths = paths
        self.scope = scope
        self.includeUntracked = includeUntracked
    }

    public static let method: String = "workspace.git_discard"
    public typealias Response = WorkspaceRpcUnit

    enum CodingKeys: String, CodingKey {
        case gitRoot = "git_root"
        case paths, scope
        case includeUntracked = "include_untracked"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gitRoot = try c.decodeIfPresent(String.self, forKey: .gitRoot)
        paths = try c.decodeIfPresent([String].self, forKey: .paths)
        scope = try c.decodeIfPresent(DiscardScope.self, forKey: .scope) ?? .both
        includeUntracked = try c.decodeIfPresent(Bool.self, forKey: .includeUntracked) ?? false
    }
}

public struct GitCommitReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var gitRoot: String?
    public var message: String
    public var amend: Bool
    public var signoff: Bool
    public var push: Bool
    public var sync: Bool

    public init(
        gitRoot: String? = nil,
        message: String,
        amend: Bool = false,
        signoff: Bool = false,
        push: Bool = false,
        sync: Bool = false
    ) {
        self.gitRoot = gitRoot
        self.message = message
        self.amend = amend
        self.signoff = signoff
        self.push = push
        self.sync = sync
    }

    public static let method: String = "workspace.git_commit"
    public typealias Response = CommitResult

    enum CodingKeys: String, CodingKey {
        case gitRoot = "git_root"
        case message, amend, signoff, push, sync
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gitRoot = try c.decodeIfPresent(String.self, forKey: .gitRoot)
        message = try c.decode(String.self, forKey: .message)
        amend = try c.decodeIfPresent(Bool.self, forKey: .amend) ?? false
        signoff = try c.decodeIfPresent(Bool.self, forKey: .signoff) ?? false
        push = try c.decodeIfPresent(Bool.self, forKey: .push) ?? false
        sync = try c.decodeIfPresent(Bool.self, forKey: .sync) ?? false
    }
}

public struct GitCheckoutReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var gitRoot: String?
    public var branch: String
    public var create: Bool
    public init(gitRoot: String? = nil, branch: String, create: Bool = false) {
        self.gitRoot = gitRoot
        self.branch = branch
        self.create = create
    }
    public static let method: String = "workspace.git_checkout"
    public typealias Response = WorkspaceRpcUnit
    enum CodingKeys: String, CodingKey {
        case gitRoot = "git_root"
        case branch, create
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gitRoot = try c.decodeIfPresent(String.self, forKey: .gitRoot)
        branch = try c.decode(String.self, forKey: .branch)
        create = try c.decodeIfPresent(Bool.self, forKey: .create) ?? false
    }
}

public struct GitStashReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var gitRoot: String?
    public var includeUntracked: Bool
    public init(gitRoot: String? = nil, includeUntracked: Bool = false) {
        self.gitRoot = gitRoot
        self.includeUntracked = includeUntracked
    }
    public static let method: String = "workspace.git_stash"
    public typealias Response = WorkspaceRpcUnit
    enum CodingKeys: String, CodingKey {
        case gitRoot = "git_root"
        case includeUntracked = "include_untracked"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gitRoot = try c.decodeIfPresent(String.self, forKey: .gitRoot)
        includeUntracked = try c.decodeIfPresent(Bool.self, forKey: .includeUntracked) ?? false
    }
}

public struct GitInfoReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var gitRoot: String?
    public init(gitRoot: String? = nil) { self.gitRoot = gitRoot }
    public static let method: String = "workspace.git_info"
    public typealias Response = GitInfoData
    enum CodingKeys: String, CodingKey { case gitRoot = "git_root" }
}

public struct GitBranchesReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var gitRoot: String?
    public init(gitRoot: String? = nil) { self.gitRoot = gitRoot }
    public static let method: String = "workspace.git_branches"
    public typealias Response = GitBranchListData
    enum CodingKeys: String, CodingKey { case gitRoot = "git_root" }
}

public struct GitResolveRootReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var cwd: String
    public init(cwd: String) { self.cwd = cwd }
    public static let method: String = "workspace.git_resolve_root"
    public typealias Response = String?
}

public struct GitCurrentCommitReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var gitRoot: String
    public init(gitRoot: String) { self.gitRoot = gitRoot }
    public static let method: String = "workspace.git_current_commit"
    public typealias Response = String?
    enum CodingKeys: String, CodingKey { case gitRoot = "git_root" }
}

public struct DetectVcsKindReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var path: String
    public init(path: String) { self.path = path }
    public static let method: String = "workspace.detect_vcs_kind"
    public typealias Response = DetectedVcsKind
}

public struct GitCheckoutCommitReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var gitRoot: String
    public var headCommit: String
    public var headBranch: String?
    public var stashIfDirty: Bool

    public init(gitRoot: String, headCommit: String, headBranch: String? = nil, stashIfDirty: Bool) {
        self.gitRoot = gitRoot
        self.headCommit = headCommit
        self.headBranch = headBranch
        self.stashIfDirty = stashIfDirty
    }

    public static let method: String = "workspace.git_checkout_commit"
    public typealias Response = CheckoutCommitResponse

    enum CodingKeys: String, CodingKey {
        case gitRoot = "git_root"
        case headCommit = "head_commit"
        case headBranch = "head_branch"
        case stashIfDirty = "stash_if_dirty"
    }
}

public struct CheckoutCommitResponse: Hashable, Sendable, Codable, Equatable {
    public var checkedOut: Bool
    public var stashed: Bool
    public var fetched: Bool
    public var error: String?

    public init(checkedOut: Bool, stashed: Bool, fetched: Bool, error: String? = nil) {
        self.checkedOut = checkedOut
        self.stashed = stashed
        self.fetched = fetched
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case checkedOut = "checked_out"
        case stashed, fetched, error
    }
}

public struct GitBranchInfoReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public init() {}
    public static let method: String = "workspace.git_branch_info"
    public typealias Response = GitInfoData?
    public init(from decoder: Decoder) throws {
        _ = try? decoder.container(keyedBy: EmptyKey.self)
    }
    public func encode(to encoder: Encoder) throws {
        _ = encoder.container(keyedBy: EmptyKey.self)
    }
    private enum EmptyKey: CodingKey {}
}

public struct GitMetadataReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public init() {}
    public static let method: String = "workspace.git_metadata"
    public typealias Response = JSONValue
    public init(from decoder: Decoder) throws {
        _ = try? decoder.container(keyedBy: EmptyKey.self)
    }
    public func encode(to encoder: Encoder) throws {
        _ = encoder.container(keyedBy: EmptyKey.self)
    }
    private enum EmptyKey: CodingKey {}
}

public struct GitCollectChangesReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var repoPath: String
    public var includeCommits: Bool
    public var includeUncommitted: Bool
    public var baseRef: String?
    public var maxFileBytes: UInt64
    public var forceIncludePaths: [String]

    public init(
        repoPath: String,
        includeCommits: Bool = true,
        includeUncommitted: Bool = true,
        baseRef: String? = nil,
        maxFileBytes: UInt64 = 0,
        forceIncludePaths: [String] = []
    ) {
        self.repoPath = repoPath
        self.includeCommits = includeCommits
        self.includeUncommitted = includeUncommitted
        self.baseRef = baseRef
        self.maxFileBytes = maxFileBytes
        self.forceIncludePaths = forceIncludePaths
    }

    public static let method: String = "workspace.git_collect_changes"
    public typealias Response = JSONValue

    enum CodingKeys: String, CodingKey {
        case repoPath = "repo_path"
        case includeCommits = "include_commits"
        case includeUncommitted = "include_uncommitted"
        case baseRef = "base_ref"
        case maxFileBytes = "max_file_bytes"
        case forceIncludePaths = "force_include_paths"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repoPath = try c.decode(String.self, forKey: .repoPath)
        includeCommits = try c.decodeIfPresent(Bool.self, forKey: .includeCommits) ?? true
        includeUncommitted = try c.decodeIfPresent(Bool.self, forKey: .includeUncommitted) ?? true
        baseRef = try c.decodeIfPresent(String.self, forKey: .baseRef)
        maxFileBytes = try c.decodeIfPresent(UInt64.self, forKey: .maxFileBytes) ?? 0
        forceIncludePaths = try c.decodeIfPresent([String].self, forKey: .forceIncludePaths) ?? []
    }
}

// MARK: - Enums / response shapes

/// RPC detect-VCS enum (camelCase wire values). Distinct from stream-side `VcsKind`.
public enum DetectedVcsKind: Hashable, Sendable, Codable, Equatable {
    case git
    case jujutsuColocated
    case none

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        switch try c.decode(String.self) {
        case "git": self = .git
        case "jujutsuColocated": self = .jujutsuColocated
        case "none": self = .none
        default:
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown DetectedVcsKind")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .git: try c.encode("git")
        case .jujutsuColocated: try c.encode("jujutsuColocated")
        case .none: try c.encode("none")
        }
    }

    public var isJj: Bool { self == .jujutsuColocated }
    public var isRepo: Bool { self != .none }
}

public enum GitChangeType: Hashable, Sendable, Codable, Equatable {
    case create, edit, delete, rename, copy, typechange, untracked

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        switch try c.decode(String.self) {
        case "create": self = .create
        case "edit": self = .edit
        case "delete": self = .delete
        case "rename": self = .rename
        case "copy": self = .copy
        case "typechange": self = .typechange
        case "untracked": self = .untracked
        default:
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown GitChangeType")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .create: try c.encode("create")
        case .edit: try c.encode("edit")
        case .delete: try c.encode("delete")
        case .rename: try c.encode("rename")
        case .copy: try c.encode("copy")
        case .typechange: try c.encode("typechange")
        case .untracked: try c.encode("untracked")
        }
    }
}

public struct CommitData: Hashable, Sendable, Codable, Equatable {
    public var commitHash: String?
    public var output: String?
    public init(commitHash: String? = nil, output: String? = nil) {
        self.commitHash = commitHash
        self.output = output
    }
    enum CodingKeys: String, CodingKey { case commitHash, output }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(commitHash, forKey: .commitHash)
        try c.encodeIfPresent(output, forKey: .output)
    }
}

public struct CommitResult: Hashable, Sendable, Codable, Equatable {
    public var data: CommitData
    public var warning: String?
    public init(data: CommitData = CommitData(), warning: String? = nil) {
        self.data = data
        self.warning = warning
    }
}

public struct StageData: Hashable, Sendable, Codable, Equatable {
    public var paths: [String]
    public init(paths: [String] = []) { self.paths = paths }
    enum CodingKeys: String, CodingKey { case paths }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? []
    }
}

public struct GitFileChange: Hashable, Sendable, Codable, Equatable {
    public var path: String
    public var oldPath: String?
    public var changeType: GitChangeType
    public var staged: Bool?
    public var additions: UInt64
    public var deletions: UInt64
    public var patch: String?
    public var patchBytes: UInt64?
    public var patchLines: UInt64?
    public var oldText: String?
    public var newText: String?

    public init(
        path: String,
        oldPath: String? = nil,
        changeType: GitChangeType,
        staged: Bool? = nil,
        additions: UInt64 = 0,
        deletions: UInt64 = 0,
        patch: String? = nil,
        patchBytes: UInt64? = nil,
        patchLines: UInt64? = nil,
        oldText: String? = nil,
        newText: String? = nil
    ) {
        self.path = path
        self.oldPath = oldPath
        self.changeType = changeType
        self.staged = staged
        self.additions = additions
        self.deletions = deletions
        self.patch = patch
        self.patchBytes = patchBytes
        self.patchLines = patchLines
        self.oldText = oldText
        self.newText = newText
    }

    enum CodingKeys: String, CodingKey {
        case path, oldPath
        case changeType = "type"
        case staged, additions, deletions, patch, patchBytes, patchLines, oldText, newText
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encodeIfPresent(oldPath, forKey: .oldPath)
        try c.encode(changeType, forKey: .changeType)
        try c.encodeIfPresent(staged, forKey: .staged)
        try c.encode(additions, forKey: .additions)
        try c.encode(deletions, forKey: .deletions)
        try c.encodeIfPresent(patch, forKey: .patch)
        try c.encodeIfPresent(patchBytes, forKey: .patchBytes)
        try c.encodeIfPresent(patchLines, forKey: .patchLines)
        try c.encodeIfPresent(oldText, forKey: .oldText)
        try c.encodeIfPresent(newText, forKey: .newText)
    }
}

public struct GitStatusData: Hashable, Sendable, Codable, Equatable {
    public var root: String?
    public var mainRoot: String?
    public var isWorktree: Bool?
    public var branch: String?
    public var commit: String?
    public var upstream: String?
    public var remoteUrl: String?
    public var ahead: UInt64?
    public var behind: UInt64?
    public var staged: [GitFileChange]
    public var unstaged: [GitFileChange]

    public init(
        root: String? = nil,
        mainRoot: String? = nil,
        isWorktree: Bool? = nil,
        branch: String? = nil,
        commit: String? = nil,
        upstream: String? = nil,
        remoteUrl: String? = nil,
        ahead: UInt64? = nil,
        behind: UInt64? = nil,
        staged: [GitFileChange] = [],
        unstaged: [GitFileChange] = []
    ) {
        self.root = root
        self.mainRoot = mainRoot
        self.isWorktree = isWorktree
        self.branch = branch
        self.commit = commit
        self.upstream = upstream
        self.remoteUrl = remoteUrl
        self.ahead = ahead
        self.behind = behind
        self.staged = staged
        self.unstaged = unstaged
    }

    enum CodingKeys: String, CodingKey {
        case root, mainRoot, isWorktree, branch, commit, upstream, remoteUrl
        case ahead, behind, staged, unstaged
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        root = try c.decodeIfPresent(String.self, forKey: .root)
        mainRoot = try c.decodeIfPresent(String.self, forKey: .mainRoot)
        isWorktree = try c.decodeIfPresent(Bool.self, forKey: .isWorktree)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        commit = try c.decodeIfPresent(String.self, forKey: .commit)
        upstream = try c.decodeIfPresent(String.self, forKey: .upstream)
        remoteUrl = try c.decodeIfPresent(String.self, forKey: .remoteUrl)
        ahead = try c.decodeIfPresent(UInt64.self, forKey: .ahead)
        behind = try c.decodeIfPresent(UInt64.self, forKey: .behind)
        staged = try c.decodeIfPresent([GitFileChange].self, forKey: .staged) ?? []
        unstaged = try c.decodeIfPresent([GitFileChange].self, forKey: .unstaged) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(root, forKey: .root)
        try c.encodeIfPresent(mainRoot, forKey: .mainRoot)
        try c.encodeIfPresent(isWorktree, forKey: .isWorktree)
        try c.encodeIfPresent(branch, forKey: .branch)
        try c.encodeIfPresent(commit, forKey: .commit)
        try c.encodeIfPresent(upstream, forKey: .upstream)
        try c.encodeIfPresent(remoteUrl, forKey: .remoteUrl)
        try c.encodeIfPresent(ahead, forKey: .ahead)
        try c.encodeIfPresent(behind, forKey: .behind)
        try c.encode(staged, forKey: .staged)
        try c.encode(unstaged, forKey: .unstaged)
    }
}

/// Response envelope for `git_status_ext`. Accepts the new envelope and
/// legacy flat `GitStatusData` payloads (version-skew tolerance).
public struct GitStatusExtResponse: Hashable, Sendable, Codable, Equatable {
    public var format: GitStatusFormat
    public var data: GitStatusData?
    public var prompt: String?

    public init(format: GitStatusFormat = .structured, data: GitStatusData? = nil, prompt: String? = nil) {
        self.format = format
        self.data = data
        self.prompt = prompt
    }

    public static func structured(_ data: GitStatusData) -> GitStatusExtResponse {
        GitStatusExtResponse(format: .structured, data: data, prompt: nil)
    }

    public static func prompt(_ text: String) -> GitStatusExtResponse {
        GitStatusExtResponse(format: .prompt, data: nil, prompt: text)
    }

    public init(from decoder: Decoder) throws {
        // Peek as JSONValue to distinguish envelope vs legacy flat payload.
        let value = try JSONValue(from: decoder)
        if case .object(let obj) = value,
           obj.keys.contains("format") || obj.keys.contains("data") || obj.keys.contains("prompt") {
            // New envelope.
            if case .object = value {
                let data = try JSONEncoder().encode(value)
                let env = try JSONDecoder().decode(Envelope.self, from: data)
                self.format = env.format
                self.data = env.data
                self.prompt = env.prompt
                return
            }
        }
        // Legacy flat payload.
        let data = try JSONEncoder().encode(value)
        let flat = try JSONDecoder().decode(GitStatusData.self, from: data)
        self.format = .structured
        self.data = flat
        self.prompt = nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encodeIfPresent(data, forKey: .data)
        try c.encodeIfPresent(prompt, forKey: .prompt)
    }

    private struct Envelope: Decodable {
        var format: GitStatusFormat
        var data: GitStatusData?
        var prompt: String?

        enum CodingKeys: String, CodingKey { case format, data, prompt }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            format = try c.decodeIfPresent(GitStatusFormat.self, forKey: .format) ?? .structured
            data = try c.decodeIfPresent(GitStatusData.self, forKey: .data)
            prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        }
    }

    enum CodingKeys: String, CodingKey { case format, data, prompt }
}

public struct GitError: Hashable, Sendable, Codable, Equatable {
    public var path: String?
    public var code: String
    public var message: String
    public init(path: String? = nil, code: String, message: String) {
        self.path = path
        self.code = code
        self.message = message
    }
    enum CodingKeys: String, CodingKey { case path, code, message }
}

public struct GitReadFile: Hashable, Sendable, Codable, Equatable {
    public var path: String
    public var version: String
    public var content: String
    public var isBinary: Bool?
    public init(path: String, version: String, content: String, isBinary: Bool? = nil) {
        self.path = path
        self.version = version
        self.content = content
        self.isBinary = isBinary
    }
    enum CodingKeys: String, CodingKey { case path, version, content, isBinary }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encode(version, forKey: .version)
        try c.encode(content, forKey: .content)
        try c.encodeIfPresent(isBinary, forKey: .isBinary)
    }
}

public struct GitReadFilesData: Hashable, Sendable, Codable, Equatable {
    public var files: [GitReadFile]
    public var errors: [GitError]
    public init(files: [GitReadFile] = [], errors: [GitError] = []) {
        self.files = files
        self.errors = errors
    }
    enum CodingKeys: String, CodingKey { case files, errors }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        files = try c.decodeIfPresent([GitReadFile].self, forKey: .files) ?? []
        errors = try c.decodeIfPresent([GitError].self, forKey: .errors) ?? []
    }
}

public struct GitDiffsData: Hashable, Sendable, Codable, Equatable {
    public var files: [GitFileChange]
    public init(files: [GitFileChange] = []) { self.files = files }
    enum CodingKeys: String, CodingKey { case files }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        files = try c.decodeIfPresent([GitFileChange].self, forKey: .files) ?? []
    }

    public func collectPatches() -> String? {
        let patches = files.compactMap(\.patch)
        return patches.isEmpty ? nil : patches.joined(separator: "\n")
    }
}

public struct GitInfoData: Hashable, Sendable, Codable, Equatable {
    public var root: String
    public var remotes: [String]
    public var currentBranch: String?
    public var defaultBranch: String?
    public var vcsKind: DetectedVcsKind?

    public init(
        root: String,
        remotes: [String] = [],
        currentBranch: String? = nil,
        defaultBranch: String? = nil,
        vcsKind: DetectedVcsKind? = nil
    ) {
        self.root = root
        self.remotes = remotes
        self.currentBranch = currentBranch
        self.defaultBranch = defaultBranch
        self.vcsKind = vcsKind
    }

    enum CodingKeys: String, CodingKey {
        case root, remotes, currentBranch, defaultBranch, vcsKind
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(root, forKey: .root)
        try c.encode(remotes, forKey: .remotes)
        try c.encode(currentBranch, forKey: .currentBranch)
        try c.encodeIfPresent(defaultBranch, forKey: .defaultBranch)
        try c.encodeIfPresent(vcsKind, forKey: .vcsKind)
    }
}

public struct GitBranchEntry: Hashable, Sendable, Codable, Equatable {
    public var name: String
    public var current: Bool
    public var remote: Bool
    public init(name: String, current: Bool, remote: Bool) {
        self.name = name
        self.current = current
        self.remote = remote
    }
    enum CodingKeys: String, CodingKey { case name, current, remote }
}

public struct GitBranchListData: Hashable, Sendable, Codable, Equatable {
    public var currentBranch: String?
    public var repoRoot: String
    public var branches: [GitBranchEntry]
    public init(currentBranch: String? = nil, repoRoot: String, branches: [GitBranchEntry] = []) {
        self.currentBranch = currentBranch
        self.repoRoot = repoRoot
        self.branches = branches
    }
    enum CodingKeys: String, CodingKey { case currentBranch, repoRoot, branches }
}
