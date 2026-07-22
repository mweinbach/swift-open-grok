// OpenGrokGitStatus.swift
//
// Pure Git status / index / worktree inspection and gix-status thread budget.
// Port of xai-gix-status. Never shells out on the pure path.

import Foundation

/// Convenience entry: scan `path` with default options on the pure path.
public func gitStatus(
    path: String,
    options: GitStatusOptions = GitStatusOptions()
) throws -> GitStatusSnapshot {
    try PureGitStatusScanner(options: options).scan(path: path)
}

/// Budget-aware wrapper: returns the thread limit that pure/gix scanners
/// should honor for produce workers. Always `>= 1`, never `0`.
public func budgetedStatusThreadLimit(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Int {
    computeGixStatusThreadLimit(environment: environment)
}
