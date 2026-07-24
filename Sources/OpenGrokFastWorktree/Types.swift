// Types.swift
//
// Public enums and reports for fast worktree creation. Ported from
// `xai-fast-worktree/src/api.rs` and `copy/types.rs`.

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

/// How to handle overlay-on-FUSE snapshot optimization on Linux.
public enum OverlayMode: String, Sendable, Equatable, Codable, CaseIterable {
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

/// Progress events emitted between major create phases.
public enum WorktreeProgress: Sendable, Equatable {
    case discovering
    case validatingDestination
    case addingWorktree
    case scanningDirty
    case copying(filesCopied: UInt64)
    case finalizing
    case copyingIgnored
    case complete
    case reclaiming
}

/// A structured report for a copy phase.
public struct CopyReport: Sendable, Equatable {
    public var filesCopied: UInt64
    public var dirsCreated: UInt64
    public var symlinksCopied: UInt64
    public var filesSkipped: UInt64
    public var issues: [String]
    public var dirtyFiles: DirtyFilesReport?
    /// True when at least one regular file was cloned via CoW (clonefile/reflink).
    public var usedCow: Bool

    public init(
        filesCopied: UInt64 = 0,
        dirsCreated: UInt64 = 0,
        symlinksCopied: UInt64 = 0,
        filesSkipped: UInt64 = 0,
        issues: [String] = [],
        dirtyFiles: DirtyFilesReport? = nil,
        usedCow: Bool = false
    ) {
        self.filesCopied = filesCopied
        self.dirsCreated = dirsCreated
        self.symlinksCopied = symlinksCopied
        self.filesSkipped = filesSkipped
        self.issues = issues
        self.dirtyFiles = dirtyFiles
        self.usedCow = usedCow
    }

    public mutating func merge(_ other: CopyReport) {
        filesCopied += other.filesCopied
        dirsCreated += other.dirsCreated
        symlinksCopied += other.symlinksCopied
        filesSkipped += other.filesSkipped
        issues.append(contentsOf: other.issues)
        usedCow = usedCow || other.usedCow
    }
}

/// Categorized dirty-file summary (mirrors Rust `DirtyFilesReport` counts)
/// plus optional path samples for diagnostics.
public struct DirtyFilesReport: Sendable, Equatable {
    public var modifiedCount: UInt64
    public var untrackedCount: UInt64
    public var deletedCount: UInt64
    public var modified: [String]
    public var untracked: [String]
    public var deleted: [String]

    public init(
        modifiedCount: UInt64 = 0,
        untrackedCount: UInt64 = 0,
        deletedCount: UInt64 = 0,
        modified: [String] = [],
        untracked: [String] = [],
        deleted: [String] = []
    ) {
        self.modifiedCount = modifiedCount
        self.untrackedCount = untrackedCount
        self.deletedCount = deletedCount
        self.modified = modified
        self.untracked = untracked
        self.deleted = deleted
    }

    /// Relative paths that should be skipped when producing a clean tree.
    public var allDirtyPaths: Set<String> {
        Set(modified + untracked + deleted)
    }
}

/// Result of creating a worktree.
public struct WorktreeReport: Sendable, Equatable {
    public var worktreePath: URL
    public var commit: String
    public var unignoredCopy: CopyReport
    public var ignoredCopy: CopyReport?
    public var creationMode: CreationMode
    public var isBareSource: Bool
    public var wasDetached: Bool
    public var usedCow: Bool
    public var recoveredPartial: Bool

    public init(
        worktreePath: URL,
        commit: String,
        unignoredCopy: CopyReport = CopyReport(),
        ignoredCopy: CopyReport? = nil,
        creationMode: CreationMode = .linked,
        isBareSource: Bool = false,
        wasDetached: Bool = true,
        usedCow: Bool = false,
        recoveredPartial: Bool = false
    ) {
        self.worktreePath = worktreePath
        self.commit = commit
        self.unignoredCopy = unignoredCopy
        self.ignoredCopy = ignoredCopy
        self.creationMode = creationMode
        self.isBareSource = isBareSource
        self.wasDetached = wasDetached
        self.usedCow = usedCow
        self.recoveredPartial = recoveredPartial
    }
}

public struct RemoveReport: Sendable, Equatable {
    public var path: URL
    public var removed: Bool
    public var issues: [String]
    public var usedBtrfsDelete: Bool
    public var unmountedBind: Bool
    public var unmountedOverlay: Bool
    public var recoveredPartialMarker: Bool

    public init(
        path: URL,
        removed: Bool,
        issues: [String] = [],
        usedBtrfsDelete: Bool = false,
        unmountedBind: Bool = false,
        unmountedOverlay: Bool = false,
        recoveredPartialMarker: Bool = false
    ) {
        self.path = path
        self.removed = removed
        self.issues = issues
        self.usedBtrfsDelete = usedBtrfsDelete
        self.unmountedBind = unmountedBind
        self.unmountedOverlay = unmountedOverlay
        self.recoveredPartialMarker = recoveredPartialMarker
    }
}

public struct CleanupReport: Sendable, Equatable {
    public var removed: [URL]
    public var skipped: [URL]
    public var issues: [String]
    public var recoveredPartials: [URL]
    public var removedCount: UInt64
    public var errorCount: UInt64

    public init(
        removed: [URL] = [],
        skipped: [URL] = [],
        issues: [String] = [],
        recoveredPartials: [URL] = [],
        removedCount: UInt64 = 0,
        errorCount: UInt64 = 0
    ) {
        self.removed = removed
        self.skipped = skipped
        self.issues = issues
        self.recoveredPartials = recoveredPartials
        self.removedCount = removedCount
        self.errorCount = errorCount
    }
}

public struct LinkedWorktreeInfo: Sendable, Equatable {
    public var path: URL
    public var head: String?
    public var branch: String?
    public var locked: Bool
    public var prunable: Bool
    public var bare: Bool
    public var detached: Bool

    public init(
        path: URL,
        head: String? = nil,
        branch: String? = nil,
        locked: Bool = false,
        prunable: Bool = false,
        bare: Bool = false,
        detached: Bool = false
    ) {
        self.path = path
        self.head = head
        self.branch = branch
        self.locked = locked
        self.prunable = prunable
        self.bare = bare
        self.detached = detached
    }
}

/// Result from a delegated privileged snapshot creation.
public struct DelegateSnapshotResult: Sendable, Equatable {
    public var snapshotPath: URL
    public var worktreePath: URL
    public var bindMounted: Bool

    public init(snapshotPath: URL, worktreePath: URL, bindMounted: Bool = false) {
        self.snapshotPath = snapshotPath
        self.worktreePath = worktreePath
        self.bindMounted = bindMounted
    }
}

/// Privileged BTRFS/overlay delegate. Without a concrete implementation,
/// forced BTRFS/overlay modes fail closed as typed unsupported.
public protocol PrivilegedSnapshotDelegate: Sendable {
    func createSnapshot(source: URL, dest: URL) throws -> DelegateSnapshotResult
    func deleteSnapshot(worktreePath: URL) throws -> RemoveReport
    func mountOverlay(lower: URL, upper: URL, work: URL, target: URL) throws
    func unmountOverlay(target: URL) throws
}

/// Default fail-closed methods for overlay when only BTRFS is implemented.
public extension PrivilegedSnapshotDelegate {
    func mountOverlay(lower: URL, upper: URL, work: URL, target: URL) throws {
        _ = (lower, upper, work, target)
        throw FastWorktreeError.unsupported(
            "overlay mount delegation not supported by this delegate"
        )
    }

    func unmountOverlay(target: URL) throws {
        _ = target
        throw FastWorktreeError.unsupported(
            "overlay unmount delegation not supported by this delegate"
        )
    }
}

/// On-disk recovery marker for partially created worktrees.
/// Written as `<dest>/.opengrok-worktree-partial` (JSON lines) so cleanup
/// can reclaim half-built trees after cancel/crash.
public struct PartialWorktreeMarker: Sendable, Equatable, Codable {
    public var version: Int
    public var sourcePath: String
    public var destPath: String
    public var creationMode: String
    public var gitRef: String
    public var startedAtEpochSecs: Int64
    public var phase: String

    public static let fileName = ".opengrok-worktree-partial"
    public static let currentVersion = 1

    public init(
        sourcePath: String,
        destPath: String,
        creationMode: String,
        gitRef: String,
        startedAtEpochSecs: Int64 = Int64(Date().timeIntervalSince1970),
        phase: String = "started",
        version: Int = PartialWorktreeMarker.currentVersion
    ) {
        self.version = version
        self.sourcePath = sourcePath
        self.destPath = destPath
        self.creationMode = creationMode
        self.gitRef = gitRef
        self.startedAtEpochSecs = startedAtEpochSecs
        self.phase = phase
    }
}

public enum FastWorktreeError: Error, Equatable, Sendable, CustomStringConvertible {
    case notAGitRepository(String)
    case destinationExists(String)
    case primaryCheckoutProtected(String)
    case invalidRef(String)
    case pathEscape(String)
    case argumentInjection(String)
    case branchCollision(String)
    case bareRepositoryUnsupported(String)
    case cancelled
    case gitFailed(String)
    case io(String)
    case unsupported(String)
    case outOfDisk

    public var description: String {
        switch self {
        case .notAGitRepository(let p): return "not a git repository: \(p)"
        case .destinationExists(let p): return "destination already exists: \(p)"
        case .primaryCheckoutProtected(let p): return "refusing to modify primary checkout: \(p)"
        case .invalidRef(let r): return "invalid git ref: \(r)"
        case .pathEscape(let p): return "path escapes allowed root: \(p)"
        case .argumentInjection(let d): return "argument injection rejected: \(d)"
        case .branchCollision(let d): return "branch already checked out: \(d)"
        case .bareRepositoryUnsupported(let d): return "bare repository unsupported for mode: \(d)"
        case .cancelled: return "worktree operation cancelled"
        case .gitFailed(let m): return "git failed: \(m)"
        case .io(let m): return "io error: \(m)"
        case .unsupported(let m): return "unsupported: \(m)"
        case .outOfDisk: return outOfDiskContext
        }
    }
}

/// Error context attached when worktree creation fails on a full disk.
public let outOfDiskContext = "not enough free disk space"
/// POSIX disk-full text `git` prints to stderr.
public let enospcOSMessage = "No space left on device"
/// Marker filename written under partial destinations.
public let partialMarkerFileName = PartialWorktreeMarker.fileName
