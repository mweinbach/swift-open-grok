// Types.swift
//
// Pure Git status entry types for pure-path inspection (no shell).

import Foundation

/// Kind of a single path's status relative to HEAD / index / worktree.
public enum GitPathStatus: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case unmodified
    case modified
    case added
    case deleted
    case renamed
    case copied
    case typeChange = "type_change"
    case unmerged
    case untracked
    case ignored
}

/// Where a change lives.
public enum GitChangeLocation: String, Sendable, Equatable, Hashable, Codable {
    case staged
    case unstaged
    case untracked
    case ignored
    case conflict
}

/// One status entry for a path.
public struct GitStatusEntry: Sendable, Equatable, Hashable, Codable {
    public var path: String
    public var status: GitPathStatus
    public var location: GitChangeLocation
    /// For renames/copies: the other path.
    public var otherPath: String?
    /// Submodule flag when the path is a gitlink.
    public var isSubmodule: Bool
    /// Conflict stages present (1/2/3) when `status == .unmerged`.
    public var conflictStages: [Int]

    public init(
        path: String,
        status: GitPathStatus,
        location: GitChangeLocation,
        otherPath: String? = nil,
        isSubmodule: Bool = false,
        conflictStages: [Int] = []
    ) {
        self.path = path
        self.status = status
        self.location = location
        self.otherPath = otherPath
        self.isSubmodule = isSubmodule
        self.conflictStages = conflictStages
    }
}

/// Full status snapshot for a repository / worktree.
public struct GitStatusSnapshot: Sendable, Equatable, Codable {
    public var root: String
    public var gitDir: String
    public var branch: String?
    public var headCommit: String?
    public var isBare: Bool
    public var isDetached: Bool
    public var isSparseCheckout: Bool
    public var isLinkedWorktree: Bool
    public var entries: [GitStatusEntry]

    public init(
        root: String,
        gitDir: String,
        branch: String? = nil,
        headCommit: String? = nil,
        isBare: Bool = false,
        isDetached: Bool = false,
        isSparseCheckout: Bool = false,
        isLinkedWorktree: Bool = false,
        entries: [GitStatusEntry] = []
    ) {
        self.root = root
        self.gitDir = gitDir
        self.branch = branch
        self.headCommit = headCommit
        self.isBare = isBare
        self.isDetached = isDetached
        self.isSparseCheckout = isSparseCheckout
        self.isLinkedWorktree = isLinkedWorktree
        self.entries = entries
    }

    public var staged: [GitStatusEntry] {
        entries.filter { $0.location == .staged }
    }
    public var unstaged: [GitStatusEntry] {
        entries.filter { $0.location == .unstaged }
    }
    public var untracked: [GitStatusEntry] {
        entries.filter { $0.location == .untracked }
    }
    public var ignored: [GitStatusEntry] {
        entries.filter { $0.location == .ignored }
    }
    public var conflicts: [GitStatusEntry] {
        entries.filter { $0.location == .conflict }
    }
    public var clean: Bool { entries.isEmpty }
}

/// Options controlling a pure-path status scan.
public struct GitStatusOptions: Sendable, Equatable {
    public var includeUntracked: Bool
    public var includeIgnored: Bool
    public var pathspecs: [String]
    /// Thread budget for parallel produce workers (`nil` = compute default).
    public var threadLimit: Int?

    public init(
        includeUntracked: Bool = true,
        includeIgnored: Bool = false,
        pathspecs: [String] = [],
        threadLimit: Int? = nil
    ) {
        self.includeUntracked = includeUntracked
        self.includeIgnored = includeIgnored
        self.pathspecs = pathspecs
        self.threadLimit = threadLimit
    }
}

public enum GitPackDeltaKind: String, Sendable, Equatable {
    case offset
    case reference
}

public enum GitStatusError: Error, Equatable, Sendable {
    case notARepository(String)
    case corruptIndex(String)
    case unsupportedIndexVersion(Int)
    case io(String)
    case cancelled
    case unsupportedPackIndexVersion(path: String, version: Int)
    case corruptPackIndex(path: String, reason: String)
    case corruptPack(path: String, reason: String)
    case packedObjectTooLarge(oid: String, declaredSize: UInt64, limit: Int)
    case packedDeltaUnsupported(oid: String, kind: GitPackDeltaKind)
    /// Pack files exist, but no usable v2 index contains the requested object.
    case packedObjectUnsupported(oid: String)
}
