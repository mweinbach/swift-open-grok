// Types.swift
//
// Public enums and reports for fast worktree creation. Ported from
// `xai-fast-worktree/src/api.rs`.

import Foundation

/// How to treat the source working tree when creating the destination worktree.
public enum WorkingTreeMode: String, Sendable, Equatable, Codable, CaseIterable {
    /// Replicate the working tree exactly as-is (including local modifications).
    case preserveWorkingTree = "preserve"
    /// Produce a clean checked-out working tree for tracked files.
    case cleanTracked = "clean_tracked"
    /// Produce a clean worktree and also remove untracked files.
    case cleanAll = "clean_all"
}

/// Whether (and how) to copy `.gitignore`'d files after the worktree is ready.
public enum IgnoredFilesMode: Sendable, Equatable {
    case skip
    case copy(skipPatterns: [String])
    case copyOnly(skipPatterns: [String])
}

/// How to handle BTRFS snapshot optimization on Linux.
public enum BtrfsMode: String, Sendable, Equatable, Codable, CaseIterable {
    case auto
    case force
    case disabled
}

/// Strategy for creating the worktree.
public enum CreationMode: String, Sendable, Equatable, Codable, CaseIterable {
    /// Linked worktree via `git worktree add --no-checkout` + file copy.
    case linked
    /// Standalone repository copy with independent `.git/`.
    case standalone
    /// Plain `git worktree add` with full checkout.
    case gitCheckout = "git"

    public var asDBString: String { rawValue }
}

/// A structured report for a copy phase.
public struct CopyReport: Sendable, Equatable {
    public var filesCopied: UInt64
    public var dirsCreated: UInt64
    public var symlinksCopied: UInt64
    public var filesSkipped: UInt64
    public var issues: [String]
    public var dirtyFiles: DirtyFilesReport?

    public init(
        filesCopied: UInt64 = 0,
        dirsCreated: UInt64 = 0,
        symlinksCopied: UInt64 = 0,
        filesSkipped: UInt64 = 0,
        issues: [String] = [],
        dirtyFiles: DirtyFilesReport? = nil
    ) {
        self.filesCopied = filesCopied
        self.dirsCreated = dirsCreated
        self.symlinksCopied = symlinksCopied
        self.filesSkipped = filesSkipped
        self.issues = issues
        self.dirtyFiles = dirtyFiles
    }
}

public struct DirtyFilesReport: Sendable, Equatable {
    public var modified: [String]
    public var untracked: [String]
    public var deleted: [String]

    public init(modified: [String] = [], untracked: [String] = [], deleted: [String] = []) {
        self.modified = modified
        self.untracked = untracked
        self.deleted = deleted
    }
}

/// Result of creating a worktree.
public struct WorktreeReport: Sendable, Equatable {
    public var worktreePath: URL
    public var commit: String
    public var unignoredCopy: CopyReport
    public var ignoredCopy: CopyReport?
    public var creationMode: CreationMode

    public init(
        worktreePath: URL,
        commit: String,
        unignoredCopy: CopyReport = CopyReport(),
        ignoredCopy: CopyReport? = nil,
        creationMode: CreationMode = .linked
    ) {
        self.worktreePath = worktreePath
        self.commit = commit
        self.unignoredCopy = unignoredCopy
        self.ignoredCopy = ignoredCopy
        self.creationMode = creationMode
    }
}

public struct RemoveReport: Sendable, Equatable {
    public var path: URL
    public var removed: Bool
    public var issues: [String]

    public init(path: URL, removed: Bool, issues: [String] = []) {
        self.path = path
        self.removed = removed
        self.issues = issues
    }
}

public struct CleanupReport: Sendable, Equatable {
    public var removed: [URL]
    public var skipped: [URL]
    public var issues: [String]

    public init(removed: [URL] = [], skipped: [URL] = [], issues: [String] = []) {
        self.removed = removed
        self.skipped = skipped
        self.issues = issues
    }
}

public struct LinkedWorktreeInfo: Sendable, Equatable {
    public var path: URL
    public var head: String?
    public var branch: String?
    public var locked: Bool
    public var prunable: Bool

    public init(
        path: URL,
        head: String? = nil,
        branch: String? = nil,
        locked: Bool = false,
        prunable: Bool = false
    ) {
        self.path = path
        self.head = head
        self.branch = branch
        self.locked = locked
        self.prunable = prunable
    }
}

public enum FastWorktreeError: Error, Equatable, Sendable, CustomStringConvertible {
    case notAGitRepository(String)
    case destinationExists(String)
    case primaryCheckoutProtected(String)
    case invalidRef(String)
    case pathEscape(String)
    case cancelled
    case gitFailed(String)
    case io(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .notAGitRepository(let p): return "not a git repository: \(p)"
        case .destinationExists(let p): return "destination already exists: \(p)"
        case .primaryCheckoutProtected(let p): return "refusing to modify primary checkout: \(p)"
        case .invalidRef(let r): return "invalid git ref: \(r)"
        case .pathEscape(let p): return "path escapes allowed root: \(p)"
        case .cancelled: return "worktree operation cancelled"
        case .gitFailed(let m): return "git failed: \(m)"
        case .io(let m): return "io error: \(m)"
        case .unsupported(let m): return "unsupported: \(m)"
        }
    }
}

public let enospcOSMessage = "No space left on device"
public let outOfDiskContext = "worktree creation ran out of disk space"
