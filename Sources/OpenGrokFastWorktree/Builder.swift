// Builder.swift
//
// High-level builder API for creating fast git worktrees.
// Pipeline mirrors `xai-fast-worktree` execute.rs:
//   discover → validate → worktree add / standalone copy → populate → finalize
// with PartialWorktreeGuard reclaim on cancel/error.

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
    public var overlayMode: OverlayMode
    public var allowedPoolRoot: URL?
    public var preferCow: Bool
    /// Optional privileged delegate for forced BTRFS/overlay (Linux).
    public var snapshotDelegate: (any PrivilegedSnapshotDelegate)?

    public init(
        source: URL,
        dest: URL,
        gitRef: String = "HEAD",
        workingTree: WorkingTreeMode = .preserveWorkingTree,
        ignoredFiles: IgnoredFilesMode = .skip,
        creationMode: CreationMode = .linked,
        btrfsMode: BtrfsMode = .auto,
        overlayMode: OverlayMode = .auto,
        allowedPoolRoot: URL? = nil,
        preferCow: Bool = true,
        snapshotDelegate: (any PrivilegedSnapshotDelegate)? = nil
    ) {
        self.source = source
        self.dest = dest
        self.gitRef = gitRef
        self.workingTree = workingTree
        self.ignoredFiles = ignoredFiles
        self.creationMode = creationMode
        self.btrfsMode = btrfsMode
        self.overlayMode = overlayMode
        self.allowedPoolRoot = allowedPoolRoot
        self.preferCow = preferCow
        self.snapshotDelegate = snapshotDelegate
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
    public func withBtrfsMode(_ mode: BtrfsMode) -> WorktreeBuilder {
        var c = self; c.btrfsMode = mode; return c
    }
    public func withOverlayMode(_ mode: OverlayMode) -> WorktreeBuilder {
        var c = self; c.overlayMode = mode; return c
    }
    public func withSnapshotDelegate(_ delegate: (any PrivilegedSnapshotDelegate)?) -> WorktreeBuilder {
        var c = self; c.snapshotDelegate = delegate; return c
    }
    public func standalone(_ enabled: Bool = true) -> WorktreeBuilder {
        var c = self
        if enabled { c.creationMode = .standalone }
        return c
    }

    /// Create the worktree. Cancellation checked between major phases.
    public func create(
        isCancelled: () -> Bool = { false },
        onProgress: ((WorktreeProgress) -> Void)? = nil
    ) throws -> WorktreeReport {
        // Forced privileged paths fail closed without a typed delegate —
        // before any git discovery so the error is never masked by path/repo
        // validation failures.
        try rejectForcedPrivilegedModesWithoutDelegate()

        onProgress?(.discovering)
        let identity = try discoverGitRepo(at: source)
        let opRoot = identity.operationRoot

        onProgress?(.validatingDestination)
        let safety = WorktreeSafetyPolicy(
            primaryCheckout: identity.toplevel,
            allowedPoolRoot: allowedPoolRoot
        )
        try safety.validateDestination(dest)
        try ensureDestinationAvailable(dest, allowEmptyReuse: true)

        let commit = try resolveGitRef(gitRef, repo: opRoot)
        if isCancelled() { throw FastWorktreeError.cancelled }

        // Bare sources have no working tree to preserve.
        if identity.isBare {
            switch creationMode {
            case .standalone:
                throw FastWorktreeError.bareRepositoryUnsupported(
                    "standalone copy requires a non-bare working tree"
                )
            case .linked, .gitCheckout:
                break
            }
            if workingTree == .preserveWorkingTree {
                // Fall through with cleanAll semantics for bare (nothing to preserve).
            }
        }

        switch creationMode {
        case .gitCheckout:
            return try createGitCheckout(
                identity: identity,
                commit: commit,
                isCancelled: isCancelled,
                onProgress: onProgress
            )
        case .linked:
            return try createLinked(
                identity: identity,
                commit: commit,
                isCancelled: isCancelled,
                onProgress: onProgress
            )
        case .standalone:
            return try createStandalone(
                identity: identity,
                commit: commit,
                isCancelled: isCancelled,
                onProgress: onProgress
            )
        }
    }

    /// Copy ONLY ignored files from source to dest (no worktree create).
    public func copyIgnoredOnly(
        isCancelled: () -> Bool = { false }
    ) throws -> CopyReport {
        let identity = try discoverGitRepo(at: source)
        guard let root = identity.toplevel else {
            throw FastWorktreeError.bareRepositoryUnsupported("copyIgnoredOnly needs a worktree")
        }
        let skipPatterns: [String]
        switch ignoredFiles {
        case .skip: skipPatterns = []
        case .copy(let p), .copyOnly(let p): skipPatterns = p
        }
        return try copyTree(
            from: root,
            to: dest,
            options: CopyEngineOptions(
                skipGitDirectory: true,
                skipPatterns: skipPatterns,
                preferCow: preferCow,
                ignoredOnly: true
            ),
            isCancelled: isCancelled
        )
    }

    // MARK: - Modes

    /// Forced BTRFS/overlay is Linux-only. On Linux, force without a delegate
    /// fails closed; with a delegate, the snapshot path is taken later (and
    /// fails closed on delegate error — no silent CoW fallback). Auto without
    /// a delegate is a no-op skip.
    private func rejectForcedPrivilegedModesWithoutDelegate() throws {
        if btrfsMode == .force {
            #if os(Linux)
            if snapshotDelegate == nil {
                throw FastWorktreeError.unsupported(
                    "BTRFS snapshot force mode requires privileged delegate (not available in this build)"
                )
            }
            #else
            // Even with an injected delegate, force remains typed unsupported
            // off Linux (no BTRFS/overlay surface on macOS/other).
            throw FastWorktreeError.unsupported("BTRFS snapshots are Linux-only")
            #endif
        }
        if overlayMode == .force {
            #if os(Linux)
            if snapshotDelegate == nil {
                throw FastWorktreeError.unsupported(
                    "overlay force mode requires privileged mount delegate (not available in this build)"
                )
            }
            #else
            throw FastWorktreeError.unsupported("overlay snapshots are Linux-only")
            #endif
        }
    }

    /// When force + delegate (Linux), create via the privileged snapshot path
    /// and fail closed on any error. Returns `nil` when the snapshot path is
    /// not applicable (auto without success, disabled, non-force).
    private func tryPrivilegedSnapshotCreate(
        identity: GitRepoIdentity,
        commit: String,
        isCancelled: () -> Bool,
        onProgress: ((WorktreeProgress) -> Void)?
    ) throws -> WorktreeReport? {
        #if os(Linux)
        let forceSnapshot = btrfsMode == .force || overlayMode == .force
        let autoSnapshot = (btrfsMode == .auto || overlayMode == .auto) && snapshotDelegate != nil
        guard forceSnapshot || autoSnapshot, let delegate = snapshotDelegate else {
            return nil
        }

        let sourceRoot = identity.toplevel ?? identity.operationRoot
        onProgress?(.addingWorktree)
        do {
            let snap = try delegate.createSnapshot(source: sourceRoot, dest: dest)
            var reclaimArmed = true
            defer {
                if reclaimArmed {
                    onProgress?(.reclaiming)
                    _ = try? delegate.deleteSnapshot(worktreePath: dest)
                    reclaimPartialWorktree(source: nil, dest: dest)
                }
            }

            if isCancelled() { throw FastWorktreeError.cancelled }

            onProgress?(.finalizing)
            try finalizeSnapshotWorkingTree(commit: commit, cwd: snap.worktreePath)

            if isCancelled() { throw FastWorktreeError.cancelled }

            reclaimArmed = false
            clearPartialMarker(at: dest)
            onProgress?(.complete)
            return WorktreeReport(
                worktreePath: dest,
                commit: commit,
                creationMode: creationMode,
                isBareSource: identity.isBare,
                wasDetached: gitRef != "HEAD" || identity.isDetached,
                usedCow: false
            )
        } catch {
            if forceSnapshot {
                // Force: fail closed — never fall through to file-copy.
                // Best-effort reclaim if the delegate left partial state.
                _ = try? delegate.deleteSnapshot(worktreePath: dest)
                reclaimPartialWorktree(source: nil, dest: dest)
                if let e = error as? FastWorktreeError { throw e }
                throw FastWorktreeError.unsupported("privileged snapshot failed: \(error)")
            }
            // Auto: soft-fall through to copy strategies.
            return nil
        }
        #else
        _ = (identity, commit, isCancelled, onProgress)
        return nil
        #endif
    }

    private func finalizeSnapshotWorkingTree(commit: String, cwd: URL) throws {
        switch workingTree {
        case .preserveWorkingTree:
            break
        case .cleanTracked:
            let r = try runGit(["reset", "--hard", commit], cwd: cwd)
            if r.exitCode != 0 { throw FastWorktreeError.gitFailed(r.stderr) }
        case .cleanAll:
            let r = try runGit(["reset", "--hard", commit], cwd: cwd)
            if r.exitCode != 0 { throw FastWorktreeError.gitFailed(r.stderr) }
            let c = try runGit(["clean", "-fd"], cwd: cwd)
            if c.exitCode != 0 { throw FastWorktreeError.gitFailed(c.stderr) }
        }
        if gitRef != "HEAD" {
            let co = try runGit(["checkout", gitRef], cwd: cwd)
            if co.exitCode != 0 { throw FastWorktreeError.gitFailed(co.stderr) }
        }
    }

    private func createGitCheckout(
        identity: GitRepoIdentity,
        commit: String,
        isCancelled: () -> Bool,
        onProgress: ((WorktreeProgress) -> Void)?
    ) throws -> WorktreeReport {
        if let snap = try tryPrivilegedSnapshotCreate(
            identity: identity,
            commit: commit,
            isCancelled: isCancelled,
            onProgress: onProgress
        ) {
            return snap
        }

        let opRoot = identity.operationRoot
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // git worktree add requires dest to be absent; drop marker-only reuse.
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }

        onProgress?(.addingWorktree)
        do {
            try worktreeAddCheckout(source: opRoot, dest: dest, gitRef: commit)
        } catch {
            reclaimPartialWorktree(source: opRoot, dest: dest)
            throw error
        }

        // Armed from immediately after materialization until successful disarm.
        var reclaimArmed = true
        defer {
            if reclaimArmed {
                onProgress?(.reclaiming)
                reclaimPartialWorktree(source: opRoot, dest: dest)
            }
        }

        try writePartialMarker(
            PartialWorktreeMarker(
                sourcePath: opRoot.path,
                destPath: dest.path,
                creationMode: creationMode.rawValue,
                gitRef: gitRef,
                phase: "post_add"
            ),
            at: dest
        )

        if isCancelled() { throw FastWorktreeError.cancelled }

        clearPartialMarker(at: dest)
        reclaimArmed = false
        onProgress?(.complete)
        return WorktreeReport(
            worktreePath: dest,
            commit: commit,
            creationMode: .gitCheckout,
            isBareSource: identity.isBare,
            wasDetached: true
        )
    }

    private func createLinked(
        identity: GitRepoIdentity,
        commit: String,
        isCancelled: () -> Bool,
        onProgress: ((WorktreeProgress) -> Void)?
    ) throws -> WorktreeReport {
        if let snap = try tryPrivilegedSnapshotCreate(
            identity: identity,
            commit: commit,
            isCancelled: isCancelled,
            onProgress: onProgress
        ) {
            return snap
        }

        let opRoot = identity.operationRoot
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Clear marker-only reuse dir so git can create dest.
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }

        onProgress?(.addingWorktree)
        do {
            try worktreeAddNoCheckout(source: opRoot, dest: dest, gitRef: commit)
        } catch {
            reclaimPartialWorktree(source: opRoot, dest: dest)
            throw error
        }

        // PartialWorktreeGuard: armed after worktree add until clear+disarm.
        // Covers marker write, copy, finalize, ignored copy, and cancel.
        var reclaimArmed = true
        defer {
            if reclaimArmed {
                onProgress?(.reclaiming)
                reclaimPartialWorktree(source: opRoot, dest: dest)
            }
        }

        try writePartialMarker(
            PartialWorktreeMarker(
                sourcePath: opRoot.path,
                destPath: dest.path,
                creationMode: creationMode.rawValue,
                gitRef: gitRef,
                phase: "linked_copy"
            ),
            at: dest
        )

        if isCancelled() { throw FastWorktreeError.cancelled }

        var copyReport = CopyReport()
        var dirty: DirtyFilesReport?

        // Dirty scan (only for non-bare with a working tree).
        if let root = identity.toplevel {
            onProgress?(.scanningDirty)
            dirty = try? getModifiedFiles(repoPath: root)

            let skipFiles: Set<String>
            switch workingTree {
            case .preserveWorkingTree:
                skipFiles = []
            case .cleanTracked, .cleanAll:
                skipFiles = dirty?.allDirtyPaths ?? []
            }

            if workingTree != .cleanAll {
                onProgress?(.copying(filesCopied: 0))
                // Primary unignored population respects project .gitignore
                // (Rust ParallelCopyConfig.respect_gitignore = true).
                copyReport = try copyTree(
                    from: root,
                    to: dest,
                    options: CopyEngineOptions(
                        skipGitDirectory: true,
                        skipFiles: skipFiles,
                        preferCow: preferCow,
                        respectGitignore: true
                    ),
                    isCancelled: isCancelled,
                    onProgress: { n in onProgress?(.copying(filesCopied: n)) }
                )
            }
            copyReport.dirtyFiles = dirty

            onProgress?(.finalizing)
            try finalizeLinkedWorkingTree(root: root, commit: commit)
        } else {
            // Bare: rebuild tracked files via reset --hard (index after --no-checkout).
            onProgress?(.finalizing)
            let r = try runGit(["reset", "--hard", commit], cwd: dest)
            if r.exitCode != 0 {
                throw FastWorktreeError.gitFailed(r.stderr)
            }
        }

        if isCancelled() { throw FastWorktreeError.cancelled }

        var ignored: CopyReport?
        if case .copy(let patterns) = ignoredFiles, let root = identity.toplevel {
            onProgress?(.copyingIgnored)
            ignored = try copyTree(
                from: root,
                to: dest,
                options: CopyEngineOptions(
                    skipGitDirectory: true,
                    skipPatterns: patterns,
                    preferCow: preferCow,
                    ignoredOnly: true,
                    respectGitignore: false
                ),
                isCancelled: isCancelled
            )
        }

        clearPartialMarker(at: dest)
        reclaimArmed = false
        onProgress?(.complete)
        return WorktreeReport(
            worktreePath: dest,
            commit: commit,
            unignoredCopy: copyReport,
            ignoredCopy: ignored,
            creationMode: .linked,
            isBareSource: identity.isBare,
            wasDetached: true,
            usedCow: copyReport.usedCow || (ignored?.usedCow ?? false)
        )
    }

    /// Finalize linked worktree index / clean modes. Propagates hard git
    /// failures so the reclaim guard tears down the partial tree (Rust
    /// `finalize_worktree`).
    private func finalizeLinkedWorkingTree(root: URL, commit: String) throws {
        switch workingTree {
        case .preserveWorkingTree:
            // Preserve: copy source index so staged state is reflected.
            try copyGitIndex(from: root, to: dest)
        case .cleanTracked:
            // `git reset --hard` rebuilds the index after --no-checkout.
            let r = try runGit(["reset", "--hard", commit], cwd: dest)
            if r.exitCode != 0 {
                throw FastWorktreeError.gitFailed(r.stderr)
            }
        case .cleanAll:
            let r = try runGit(["reset", "--hard", commit], cwd: dest)
            if r.exitCode != 0 {
                throw FastWorktreeError.gitFailed(r.stderr)
            }
            let c = try runGit(["clean", "-fd"], cwd: dest)
            if c.exitCode != 0 {
                throw FastWorktreeError.gitFailed(c.stderr)
            }
        }
    }

    private func createStandalone(
        identity: GitRepoIdentity,
        commit: String,
        isCancelled: () -> Bool,
        onProgress: ((WorktreeProgress) -> Void)?
    ) throws -> WorktreeReport {
        if let snap = try tryPrivilegedSnapshotCreate(
            identity: identity,
            commit: commit,
            isCancelled: isCancelled,
            onProgress: onProgress
        ) {
            return snap
        }

        guard let root = identity.toplevel else {
            throw FastWorktreeError.bareRepositoryUnsupported("standalone")
        }
        let sourceGit = root.appendingPathComponent(".git")
        // Linked worktree source: resolve real git dir.
        var isDir: ObjCBool = false
        let realGit: URL
        if FileManager.default.fileExists(atPath: sourceGit.path, isDirectory: &isDir),
           isDir.boolValue
        {
            realGit = sourceGit
        } else if let resolved = readWorktreeGitdir(worktreePath: root) {
            // Point at common dir for standalone independence.
            realGit = identity.commonDir
            _ = resolved
        } else {
            throw FastWorktreeError.io("cannot locate .git directory for standalone copy")
        }

        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: dest.path) {
            // Only marker-only reuse is allowed.
            try? FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        // Armed from dest materialization until successful clear+disarm.
        var reclaimArmed = true
        defer {
            if reclaimArmed {
                onProgress?(.reclaiming)
                reclaimPartialWorktree(source: nil, dest: dest)
            }
        }

        try writePartialMarker(
            PartialWorktreeMarker(
                sourcePath: root.path,
                destPath: dest.path,
                creationMode: creationMode.rawValue,
                gitRef: gitRef,
                phase: "standalone"
            ),
            at: dest
        )

        if isCancelled() { throw FastWorktreeError.cancelled }

        onProgress?(.copying(filesCopied: 0))
        let destGit = dest.appendingPathComponent(".git")
        let gitReport = try copyGitDir(
            from: realGit,
            to: destGit,
            preferCow: preferCow,
            isCancelled: isCancelled
        )

        onProgress?(.scanningDirty)
        let dirty = try? getModifiedFiles(repoPath: root)
        let skipFiles: Set<String>
        switch workingTree {
        case .preserveWorkingTree:
            skipFiles = []
        case .cleanTracked, .cleanAll:
            skipFiles = dirty?.allDirtyPaths ?? []
        }

        var copyReport = try copyTree(
            from: root,
            to: dest,
            options: CopyEngineOptions(
                skipGitDirectory: true,
                skipFiles: skipFiles,
                preferCow: preferCow,
                respectGitignore: true
            ),
            isCancelled: isCancelled,
            onProgress: { n in onProgress?(.copying(filesCopied: n)) }
        )
        copyReport.merge(gitReport)
        copyReport.dirtyFiles = dirty

        onProgress?(.finalizing)
        switch workingTree {
        case .preserveWorkingTree:
            // Leave CoW'd .git/HEAD / index branch state intact (Rust:
            // no checkout when git_ref == "HEAD").
            break
        case .cleanTracked:
            let r = try runGit(["reset", "--hard", commit], cwd: dest)
            if r.exitCode != 0 { throw FastWorktreeError.gitFailed(r.stderr) }
        case .cleanAll:
            let r = try runGit(["reset", "--hard", commit], cwd: dest)
            if r.exitCode != 0 { throw FastWorktreeError.gitFailed(r.stderr) }
            let c = try runGit(["clean", "-fd"], cwd: dest)
            if c.exitCode != 0 { throw FastWorktreeError.gitFailed(c.stderr) }
        }

        // Phase 5 (Rust execute_standalone_worktree): checkout only when the
        // caller requested a ref other than HEAD, so a promote/rename over the
        // primary checkout keeps the source branch association.
        if gitRef != "HEAD" {
            let co = try runGit(["checkout", gitRef], cwd: dest)
            if co.exitCode != 0 {
                throw FastWorktreeError.gitFailed(co.stderr)
            }
        }

        if isCancelled() { throw FastWorktreeError.cancelled }

        // Phase 6: optional ignored-files copy (parity with linked + Rust).
        var ignored: CopyReport?
        if case .copy(let patterns) = ignoredFiles {
            onProgress?(.copyingIgnored)
            ignored = try copyTree(
                from: root,
                to: dest,
                options: CopyEngineOptions(
                    skipGitDirectory: true,
                    skipPatterns: patterns,
                    preferCow: preferCow,
                    ignoredOnly: true,
                    respectGitignore: false
                ),
                isCancelled: isCancelled
            )
        }

        // Source marker for consumers (Rust record_main_repo_marker).
        let marker = destGit.appendingPathComponent("grok-worktree-source")
        if !FileManager.default.fileExists(atPath: marker.path) {
            try? root.path.write(to: marker, atomically: true, encoding: .utf8)
        }

        // Reflect whether dest HEAD is still a symbolic branch ref.
        let symbolic = try runGit(["symbolic-ref", "-q", "HEAD"], cwd: dest)
        let detached = symbolic.exitCode != 0

        clearPartialMarker(at: dest)
        reclaimArmed = false
        onProgress?(.complete)
        return WorktreeReport(
            worktreePath: dest,
            commit: commit,
            unignoredCopy: copyReport,
            ignoredCopy: ignored,
            creationMode: .standalone,
            isBareSource: false,
            wasDetached: detached,
            usedCow: copyReport.usedCow || (ignored?.usedCow ?? false)
        )
    }

    private func copyGitIndex(from source: URL, to dest: URL) throws {
        let srcGit = try worktreeGitDir(for: source)
        let dstGit = try worktreeGitDir(for: dest)
        let srcIndex = srcGit.appendingPathComponent("index")
        let dstIndex = dstGit.appendingPathComponent("index")
        guard FileManager.default.fileExists(atPath: srcIndex.path) else { return }
        try FileManager.default.createDirectory(
            at: dstGit,
            withIntermediateDirectories: true
        )
        _ = try copyFile(from: srcIndex, to: dstIndex, preferCow: preferCow)
    }

    private func worktreeGitDir(for worktree: URL) throws -> URL {
        if let pointer = readWorktreeGitdir(worktreePath: worktree) {
            return pointer
        }
        return worktree.appendingPathComponent(".git")
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
    return try worktreeRemove(source: identity.operationRoot, dest: dest, force: force)
}

/// Remove a worktree at `dest` using its embedded gitdir pointer when source
/// is unknown (orphan cleanup). Primary-checkout protection still applies when
/// `primaryCheckout` is provided.
public func removeWorktreeAt(
    dest: URL,
    primaryCheckout: URL? = nil,
    force: Bool = true
) throws -> RemoveReport {
    if let primary = primaryCheckout {
        let safety = WorktreeSafetyPolicy(primaryCheckout: primary)
        try safety.validateNotPrimary(dest)
    }
    // Prefer source from partial marker or gitdir.
    if let marker = readPartialMarker(at: dest) {
        let source = URL(fileURLWithPath: marker.sourcePath)
        return try worktreeRemove(source: source, dest: dest, force: force)
    }
    if let reg = readWorktreeGitdir(worktreePath: dest) {
        // Registration lives at <common>/worktrees/<name>.
        // For non-bare repos common is `<repo>/.git`; for bare repos common
        // *is* the repository directory. Prefer `gitCommon` as the operation
        // root so bare worktree teardown still works.
        let worktreesDir = reg.deletingLastPathComponent()
        let gitCommon = worktreesDir.deletingLastPathComponent()
        let nonBareRoot = gitCommon.deletingLastPathComponent()
        let source: URL
        if gitCommon.lastPathComponent == ".git",
           FileManager.default.fileExists(atPath: nonBareRoot.path)
        {
            source = nonBareRoot
        } else {
            source = gitCommon
        }
        return try worktreeRemove(source: source, dest: dest, force: force)
    }
    // Standalone / unknown: just delete the directory.
    let recovered = readPartialMarker(at: dest) != nil
    if FileManager.default.fileExists(atPath: dest.path) {
        try FileManager.default.removeItem(at: dest)
        return RemoveReport(path: dest, removed: true, recoveredPartialMarker: recovered)
    }
    return RemoveReport(path: dest, removed: true, recoveredPartialMarker: recovered)
}

/// Clean up worktrees under `poolRoot` that are missing from git's list,
/// marked prunable, or carry a recoverable partial marker.
public func cleanupWorktreesIn(
    source: URL,
    poolRoot: URL
) throws -> CleanupReport {
    let identity = try discoverGitRepo(at: source)
    let safety = WorktreeSafetyPolicy(
        primaryCheckout: identity.toplevel,
        allowedPoolRoot: poolRoot
    )
    let linked = try listLinkedWorktrees(source: identity.operationRoot)
    var report = CleanupReport()

    // Prune git's stale registrations first.
    _ = try? runGit(["worktree", "prune"], cwd: identity.operationRoot)

    // Remove prunable entries under the pool.
    for info in linked where info.prunable {
        do {
            try safety.validateDestination(info.path)
            let r = try worktreeRemove(
                source: identity.operationRoot,
                dest: info.path
            )
            if r.removed {
                report.removed.append(info.path)
                report.removedCount += 1
                if r.recoveredPartialMarker {
                    report.recoveredPartials.append(info.path)
                }
            } else {
                report.skipped.append(info.path)
                report.issues.append(contentsOf: r.issues)
                report.errorCount += 1
            }
        } catch {
            report.skipped.append(info.path)
            report.issues.append("\(error)")
            report.errorCount += 1
        }
    }

    // Scan pool (one or two levels) for orphans and partial markers.
    try scanPoolForCleanup(
        poolRoot: poolRoot,
        identity: identity,
        safety: safety,
        registered: Set(linked.map { $0.path.standardizedFileURL.path }),
        report: &report
    )
    return report
}

/// Cleanup without a source repo — removes partial markers and git-looking
/// dirs under `poolRoot` (session teardown path).
public func cleanupWorktreesIn(poolRoot: URL) -> CleanupReport {
    var report = CleanupReport()
    let safety = WorktreeSafetyPolicy(primaryCheckout: nil, allowedPoolRoot: poolRoot)
    let emptyRegistered = Set<String>()
    // Synthetic identity not available; only local reclaim.
    do {
        try scanPoolLocal(poolRoot: poolRoot, safety: safety, registered: emptyRegistered, report: &report)
    } catch {
        report.issues.append("\(error)")
        report.errorCount += 1
    }
    return report
}

private func scanPoolForCleanup(
    poolRoot: URL,
    identity: GitRepoIdentity,
    safety: WorktreeSafetyPolicy,
    registered: Set<String>,
    report: inout CleanupReport
) throws {
    guard let children = try? FileManager.default.contentsOfDirectory(
        at: poolRoot,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
    ) else { return }

    for child in children {
        // Symlink worktrees (incl. dangling).
        if let isLink = try? PathSecurityProbe.isSymlink(child), isLink {
            do {
                try safety.validateDestination(child)
                let r = try worktreeRemove(source: identity.operationRoot, dest: child)
                if r.removed {
                    report.removed.append(child)
                    report.removedCount += 1
                }
            } catch {
                report.skipped.append(child)
                report.issues.append("\(error)")
                report.errorCount += 1
            }
            continue
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: child.path, isDirectory: &isDir),
              isDir.boolValue
        else { continue }

        if let primary = identity.toplevel, pathsEqual(child, primary) {
            report.skipped.append(child)
            continue
        }

        let hasGit = FileManager.default.fileExists(
            atPath: child.appendingPathComponent(".git").path
        )
        let isPartial = isRecoverablePartialWorktree(child)

        if hasGit || isPartial {
            if registered.contains(child.standardizedFileURL.path) && !isPartial {
                continue
            }
            do {
                try safety.validateDestination(child)
                let r = try worktreeRemove(source: identity.operationRoot, dest: child)
                if r.removed {
                    report.removed.append(child)
                    report.removedCount += 1
                    if isPartial || r.recoveredPartialMarker {
                        report.recoveredPartials.append(child)
                    }
                } else {
                    report.skipped.append(child)
                    report.issues.append(contentsOf: r.issues)
                    report.errorCount += 1
                }
            } catch {
                report.skipped.append(child)
                report.issues.append("\(error)")
                report.errorCount += 1
            }
        } else {
            // Nested repo/<session>/ layout (two levels).
            if let subs = try? FileManager.default.contentsOfDirectory(
                at: child,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for sub in subs {
                    let subHasGit = FileManager.default.fileExists(
                        atPath: sub.appendingPathComponent(".git").path
                    )
                    let subPartial = isRecoverablePartialWorktree(sub)
                    guard subHasGit || subPartial else { continue }
                    do {
                        try safety.validateDestination(sub)
                        let r = try worktreeRemove(source: identity.operationRoot, dest: sub)
                        if r.removed {
                            report.removed.append(sub)
                            report.removedCount += 1
                            if subPartial || r.recoveredPartialMarker {
                                report.recoveredPartials.append(sub)
                            }
                        }
                    } catch {
                        report.skipped.append(sub)
                        report.issues.append("\(error)")
                        report.errorCount += 1
                    }
                }
            }
            // Remove empty intermediate dir.
            if let left = try? FileManager.default.contentsOfDirectory(atPath: child.path),
               left.isEmpty
            {
                try? FileManager.default.removeItem(at: child)
            }
        }
    }
}

private func scanPoolLocal(
    poolRoot: URL,
    safety: WorktreeSafetyPolicy,
    registered: Set<String>,
    report: inout CleanupReport
) throws {
    guard let children = try? FileManager.default.contentsOfDirectory(
        at: poolRoot,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else { return }

    for child in children {
        let isPartial = isRecoverablePartialWorktree(child)
        let hasGit = FileManager.default.fileExists(
            atPath: child.appendingPathComponent(".git").path
        )
        guard isPartial || hasGit else { continue }
        if registered.contains(child.standardizedFileURL.path) { continue }
        do {
            try safety.validateDestination(child)
            let r = try removeWorktreeAt(dest: child)
            if r.removed {
                report.removed.append(child)
                report.removedCount += 1
                if isPartial {
                    report.recoveredPartials.append(child)
                }
            }
        } catch {
            report.skipped.append(child)
            report.issues.append("\(error)")
            report.errorCount += 1
        }
    }
}

/// Local probe avoiding importing FileUtils name collisions in this file.
private enum PathSecurityProbe {
    static func isSymlink(_ url: URL) throws -> Bool {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.type] as? FileAttributeType) == .typeSymbolicLink
    }
}
