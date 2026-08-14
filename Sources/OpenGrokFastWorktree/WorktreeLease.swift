// WorktreeLease.swift
//
// Represents an acquired worktree lease from the pool for a subagent or session.

import Foundation

/// An active lease for a pre-warmed or on-demand Git worktree.
public struct WorktreeLease: Sendable, Identifiable, Equatable, Hashable, Codable, CustomStringConvertible {
    /// Unique identifier for this worktree lease.
    public let id: String
    /// Absolute URL to the checked-out worktree directory on disk.
    public let worktreePath: URL
    /// Branch or detached ref name checked out in this worktree.
    public let branchName: String
    /// True when the worktree is in a clean state (no untracked or modified files).
    public var isClean: Bool
    /// Timestamp when this lease was acquired.
    public let acquiredAt: Date

    public init(
        id: String = UUID().uuidString,
        worktreePath: URL,
        branchName: String,
        isClean: Bool = true,
        acquiredAt: Date = Date()
    ) {
        self.id = id
        self.worktreePath = worktreePath.standardizedFileURL
        self.branchName = branchName
        self.isClean = isClean
        self.acquiredAt = acquiredAt
    }

    public var description: String {
        "WorktreeLease(id: \(id), path: \(worktreePath.path), branch: \(branchName), clean: \(isClean), acquiredAt: \(acquiredAt))"
    }
}
