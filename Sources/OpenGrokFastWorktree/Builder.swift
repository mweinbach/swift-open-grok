// Builder.swift
//
// High-level builder API for creating fast git worktrees.

import Foundation

/// Builder for creating fast git worktrees.
public struct WorktreeBuilder: Sendable {
    public var source: URL
    public var dest: URL
    public var gitRef: String
    public var workingTree: WorkingTreeMode
    public var ignoredFiles: IgnoredFilesMode
    public var creationMode: CreationMode
    public var btrfsMode: BtrfsMode
    public var allowedPoolRoot: URL?
    public var preferCow: Bool

    public init(
        source: URL,
        dest: URL,
        gitRef: String = "HEAD",
        workingTree: WorkingTreeMode = .preserveWorkingTree,
        ignoredFiles: IgnoredFilesMode = .skip,
        creationMode: CreationMode = .linked,
        btrfsMode: BtrfsMode = .auto,
        allowedPoolRoot: URL? = nil,
        preferCow: Bool = true
    ) {
        self.source = source
        self.dest = dest
        self.gitRef = gitRef
        self.workingTree = workingTree
        self.ignoredFiles = ignoredFiles
        self.creationMode = creationMode
        self.btrfsMode = btrfsMode
        self.allowedPoolRoot = allowedPoolRoot
        self.preferCow = preferCow
    }

    public func withGitRef(_ ref: String) -> WorktreeBuilder {
        var c = self; c.gitRef = ref; return c
    }
    public func withWorkingTree(_ mode: WorkingTreeMode) -> WorktreeBuilder {
        var c = self; c.workingTree = mode; return c
    }
    public func withCreationMode(_ mode: CreationMode) -> WorktreeBuilder {
        var c = self; c.creationMode = mode; return c
    }
    public func withPoolRoot(_ root: URL?) -> WorktreeBuilder {
        var c = self; c.allowedPoolRoot = root; return c
    }

    /// Create the worktree. Cancellation checked between major phases.
    public func create(isCancelled: () -> Bool = { false }) throws -> WorktreeReport {
        let identity = try discoverGitRepo(at: source)
        let safety = WorktreeSafetyPolicy(
            primaryCheckout: identity.toplevel,
            allowedPoolRoot: allowedPoolRoot
        )
        try safety.validateDestination(dest)
        try ensureDestinationAvailable(dest)

        let commit = try resolveGitRef(gitRef, repo: identity.toplevel)
        if isCancelled() { throw FastWorktreeError.cancelled }

        #if os(Linux)
        if btrfsMode == .force {
            throw FastWorktreeError.unsupported(
                "BTRFS snapshot force mode requires privileged delegate (not available in this build)"
            )
        }
        #else
        if btrfsMode == .force {
            throw FastWorktreeError.unsupported("BTRFS snapshots are Linux-only")
        }
        #endif

        switch creationMode {
        case .gitCheckout:
            try worktreeAddCheckout(source: identity.toplevel, dest: dest, gitRef: commit)
            return WorktreeReport(
                worktreePath: dest,
                commit: commit,
                creationMode: .gitCheckout
            )

        case .linked:
            try worktreeAddNoCheckout(source: identity.toplevel, dest: dest, gitRef: commit)
            if isCancelled() {
                _ = try? worktreeRemove(source: identity.toplevel, dest: dest)
                throw FastWorktreeError.cancelled
            }
            var copyReport = CopyReport()
            if workingTree != .cleanAll {
                // Populate working tree from source (skip .git — linked worktree has its own).
                do {
                    copyReport = try copyTree(
                        from: identity.toplevel,
                        to: dest,
                        options: CopyEngineOptions(
                            skipGitDirectory: true,
                            preferCow: preferCow
                        ),
                        isCancelled: isCancelled
                    )
                } catch {
                    _ = try? worktreeRemove(source: identity.toplevel, dest: dest)
                    throw error
                }
            }
            // Finalize index: sparse checkout of tracked files for clean modes.
            if workingTree == .cleanTracked || workingTree == .cleanAll {
                let co = try runGit(["checkout", "--force", commit, "--", "."], cwd: dest)
                if co.exitCode != 0 {
                    copyReport.issues.append(co.stderr)
                }
            }
            var ignored: CopyReport?
            if case .copy(let patterns) = ignoredFiles {
                ignored = try? copyTree(
                    from: identity.toplevel,
                    to: dest,
                    options: CopyEngineOptions(
                        skipGitDirectory: true,
                        skipPatterns: patterns,
                        preferCow: preferCow
                    ),
                    isCancelled: isCancelled
                )
            }
            return WorktreeReport(
                worktreePath: dest,
                commit: commit,
                unignoredCopy: copyReport,
                ignoredCopy: ignored,
                creationMode: .linked
            )

        case .standalone:
            // Full tree copy including .git, then point HEAD at commit.
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let copyReport = try copyTree(
                from: identity.toplevel,
                to: dest,
                options: CopyEngineOptions(skipGitDirectory: false, preferCow: preferCow),
                isCancelled: isCancelled
            )
            // Detach from source worktree list if this was a linked copy of gitdir.
            let co = try runGit(["checkout", "--detach", commit], cwd: dest)
            if co.exitCode != 0 {
                throw FastWorktreeError.gitFailed(co.stderr)
            }
            return WorktreeReport(
                worktreePath: dest,
                commit: commit,
                unignoredCopy: copyReport,
                creationMode: .standalone
            )
        }
    }
}

/// Remove a worktree with primary-checkout protection.
public func removeWorktree(
    source: URL,
    dest: URL,
    force: Bool = true
) throws -> RemoveReport {
    let identity = try discoverGitRepo(at: source)
    let safety = WorktreeSafetyPolicy(primaryCheckout: identity.toplevel)
    try safety.validateNotPrimary(dest)
    try safety.validateDestination(dest)
    return try worktreeRemove(source: identity.toplevel, dest: dest, force: force)
}

/// Clean up worktrees under `poolRoot` that are missing from git's list or
/// marked prunable.
public func cleanupWorktreesIn(
    source: URL,
    poolRoot: URL
) throws -> CleanupReport {
    let identity = try discoverGitRepo(at: source)
    let safety = WorktreeSafetyPolicy(
        primaryCheckout: identity.toplevel,
        allowedPoolRoot: poolRoot
    )
    let linked = try listLinkedWorktrees(source: identity.toplevel)
    var report = CleanupReport()

    // Prune git's stale registrations first.
    _ = try? runGit(["worktree", "prune"], cwd: identity.toplevel)

    // Remove prunable entries under the pool.
    for info in linked where info.prunable {
        do {
            try safety.validateDestination(info.path)
            let r = try worktreeRemove(source: identity.toplevel, dest: info.path)
            if r.removed {
                report.removed.append(info.path)
            } else {
                report.skipped.append(info.path)
                report.issues.append(contentsOf: r.issues)
            }
        } catch {
            report.skipped.append(info.path)
            report.issues.append("\(error)")
        }
    }

    // Orphan directories under poolRoot that are not registered.
    let registered = Set(linked.map { $0.path.standardizedFileURL.path })
    if let children = try? FileManager.default.contentsOfDirectory(
        at: poolRoot,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) {
        for child in children {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: child.path, isDirectory: &isDir),
                  isDir.boolValue
            else { continue }
            if registered.contains(child.standardizedFileURL.path) { continue }
            if pathsEqual(child, identity.toplevel) {
                report.skipped.append(child)
                continue
            }
            do {
                try safety.validateDestination(child)
                try FileManager.default.removeItem(at: child)
                report.removed.append(child)
            } catch {
                report.skipped.append(child)
                report.issues.append("\(error)")
            }
        }
    }
    return report
}
