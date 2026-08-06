// GitOps.swift
//
// Git discovery (bare + non-bare), worktree add/remove/list, dirty scanning,
// HEAD validation, and gitdir pointer helpers.

import Foundation

/// Locate the git common dir / worktree root for `path`.
/// Supports non-bare, bare, and nested subdirectory discovery.
public func discoverGitRepo(at path: URL) throws -> GitRepoIdentity {
    let isBareResult = try runGit(["rev-parse", "--is-bare-repository"], cwd: path)
    let isBare = isBareResult.exitCode == 0
        && isBareResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"

    let common = try runGit(["rev-parse", "--git-common-dir"], cwd: path)
    guard common.exitCode == 0 else {
        throw FastWorktreeError.notAGitRepository(path.path)
    }
    var commonDir = common.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if commonDir.isEmpty {
        throw FastWorktreeError.notAGitRepository(path.path)
    }

    var toplevel: URL?
    if isBare {
        // Bare: git-dir is the repo; no working tree root.
        if !commonDir.hasPrefix("/") {
            commonDir = path.appendingPathComponent(commonDir)
                .standardizedFileURL.path
        }
        toplevel = nil
    } else {
        let result = try runGit(["rev-parse", "--show-toplevel"], cwd: path)
        guard result.exitCode == 0 else {
            throw FastWorktreeError.notAGitRepository(path.path)
        }
        let top = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !top.isEmpty else {
            throw FastWorktreeError.notAGitRepository(path.path)
        }
        toplevel = URL(fileURLWithPath: top)
        if !commonDir.hasPrefix("/") {
            commonDir = URL(fileURLWithPath: commonDir, relativeTo: toplevel!)
                .standardizedFileURL.path
        }
    }

    let head = try runGit(["rev-parse", "HEAD"], cwd: path)
    let commit = head.exitCode == 0
        ? head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        : ""

    let detachedResult = try runGit(["symbolic-ref", "-q", "HEAD"], cwd: path)
    let isDetached = detachedResult.exitCode != 0

    return GitRepoIdentity(
        toplevel: toplevel,
        commonDir: URL(fileURLWithPath: commonDir),
        headCommit: commit,
        isBare: isBare,
        isDetached: isDetached
    )
}

public struct GitRepoIdentity: Sendable, Equatable {
    /// Working tree root for non-bare repos; `nil` for bare.
    public var toplevel: URL?
    public var commonDir: URL
    public var headCommit: String
    public var isBare: Bool
    public var isDetached: Bool

    /// Directory to use as `git -C` cwd for worktree operations.
    public var operationRoot: URL {
        toplevel ?? commonDir
    }
}

/// Validate that `ref` resolves inside the repository.
public func resolveGitRef(_ ref: String, repo: URL) throws -> String {
    try rejectHostileGitRef(ref)
    let result = try runGit(["rev-parse", "--verify", "\(ref)^{commit}"], cwd: repo)
    guard result.exitCode == 0 else {
        throw FastWorktreeError.invalidRef(ref)
    }
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Detect if `ref` names a local branch already checked out in another worktree.
/// Returns the colliding worktree path when a collision would occur for a
/// non-detached branch checkout.
public func detectBranchCollision(ref: String, source: URL) throws -> URL? {
    // Only local branch names can collide; commits / tags / detached are fine.
    let symbolic = try runGit(
        ["rev-parse", "--verify", "--symbolic-full-name", ref],
        cwd: source
    )
    guard symbolic.exitCode == 0 else { return nil }
    let full = symbolic.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard full.hasPrefix("refs/heads/") else { return nil }

    let infos = try listLinkedWorktrees(source: source)
    for info in infos {
        if info.branch == full {
            return info.path
        }
    }
    return nil
}

/// Create a linked worktree with `--no-checkout` (always detached).
public func worktreeAddNoCheckout(source: URL, dest: URL, gitRef: String) throws {
    try rejectHostileGitRef(gitRef)
    try rejectHostileDestination(dest)
    let result = try runGit(
        ["worktree", "add", "--detach", "--no-checkout", dest.path, gitRef],
        cwd: source
    )
    if result.exitCode != 0 {
        throw mapGitWorktreeError(result)
    }
}

/// Create a linked worktree with full checkout (always detached).
public func worktreeAddCheckout(source: URL, dest: URL, gitRef: String) throws {
    try rejectHostileGitRef(gitRef)
    try rejectHostileDestination(dest)
    let result = try runGit(
        ["worktree", "add", "--detach", dest.path, gitRef],
        cwd: source
    )
    if result.exitCode != 0 {
        throw mapGitWorktreeError(result)
    }
}

func mapGitWorktreeError(_ result: GitCommandResult) -> FastWorktreeError {
    let msg = result.stderr.isEmpty ? result.stdout : result.stderr
    let lower = msg.lowercased()
    if lower.contains("already used by worktree")
        || lower.contains("is already checked out")
        || lower.contains("already checked out")
    {
        return .branchCollision(msg.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    if lower.contains(enospcOSMessage.lowercased())
        || lower.contains("no space left")
    {
        return .outOfDisk
    }
    return .gitFailed(msg)
}

/// Remove a linked worktree via fast `rm -rf` + deregister (Rust parity).
/// Falls back to `git worktree remove` only when deregister alone is insufficient.
public func worktreeRemove(source: URL, dest: URL, force: Bool = true) throws -> RemoveReport {
    var issues: [String] = []
    var recoveredPartial = false

    if readPartialMarker(at: dest) != nil {
        recoveredPartial = true
    }

    // Read registration BEFORE deleting the tree.
    let registrationDir = readWorktreeGitdir(worktreePath: dest)

    // symlink_metadata: dangling symlink worktrees must be unlinked.
    if let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
       (attrs[.type] as? FileAttributeType) == .typeSymbolicLink
    {
        do {
            try FileManager.default.removeItem(at: dest)
        } catch {
            issues.append("remove symlink: \(error)")
            return RemoveReport(
                path: dest,
                removed: false,
                issues: issues,
                recoveredPartialMarker: recoveredPartial
            )
        }
    } else if FileManager.default.fileExists(atPath: dest.path) {
        do {
            try FileManager.default.removeItem(at: dest)
        } catch {
            issues.append("removeItem: \(error)")
            // Fall back to git worktree remove.
            var args = ["worktree", "remove"]
            if force { args.append("--force") }
            args.append(dest.path)
            let result = try runGit(args, cwd: source)
            if result.exitCode != 0 {
                issues.append(result.stderr.isEmpty ? result.stdout : result.stderr)
                return RemoveReport(
                    path: dest,
                    removed: false,
                    issues: issues,
                    recoveredPartialMarker: recoveredPartial
                )
            }
            return RemoveReport(
                path: dest,
                removed: true,
                issues: issues,
                recoveredPartialMarker: recoveredPartial
            )
        }
    }

    if let reg = registrationDir, FileManager.default.fileExists(atPath: reg.path) {
        try? FileManager.default.removeItem(at: reg)
    } else {
        // Best-effort prune for stale registrations.
        _ = try? runGit(["worktree", "prune"], cwd: source)
    }

    return RemoveReport(
        path: dest,
        removed: true,
        issues: issues,
        recoveredPartialMarker: recoveredPartial
    )
}

/// Read the `gitdir:` pointer from a linked worktree's `.git` file.
public func readWorktreeGitdir(worktreePath: URL) -> URL? {
    let gitFile = worktreePath.appendingPathComponent(".git")
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: gitFile.path, isDirectory: &isDir), isDir.boolValue {
        return gitFile
    }
    guard let content = try? String(contentsOf: gitFile, encoding: .utf8) else { return nil }
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("gitdir:") else { return nil }
    let raw = trimmed.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
    let path = URL(fileURLWithPath: raw, relativeTo: worktreePath).standardizedFileURL
    return path.resolvingSymlinksInPath()
}

/// List linked worktrees for a repository (includes main checkout).
public func listLinkedWorktrees(source: URL) throws -> [LinkedWorktreeInfo] {
    let result = try runGit(["worktree", "list", "--porcelain"], cwd: source)
    guard result.exitCode == 0 else {
        throw FastWorktreeError.gitFailed(result.stderr)
    }
    return parseWorktreePorcelain(result.stdout)
}

func parseWorktreePorcelain(_ text: String) -> [LinkedWorktreeInfo] {
    var infos: [LinkedWorktreeInfo] = []
    var currentPath: URL?
    var head: String?
    var branch: String?
    var locked = false
    var prunable = false
    var bare = false
    var detached = false

    func flush() {
        if let currentPath {
            infos.append(LinkedWorktreeInfo(
                path: currentPath,
                head: head,
                branch: branch,
                locked: locked,
                prunable: prunable,
                bare: bare,
                detached: detached || branch == nil
            ))
        }
        currentPath = nil
        head = nil
        branch = nil
        locked = false
        prunable = false
        bare = false
        detached = false
    }

    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let s = String(line)
        if s.isEmpty {
            flush()
            continue
        }
        if s.hasPrefix("worktree ") {
            flush()
            currentPath = URL(fileURLWithPath: String(s.dropFirst("worktree ".count)))
        } else if s.hasPrefix("HEAD ") {
            head = String(s.dropFirst("HEAD ".count))
        } else if s.hasPrefix("branch ") {
            branch = String(s.dropFirst("branch ".count))
            detached = false
        } else if s == "detached" {
            branch = nil
            detached = true
        } else if s.hasPrefix("locked") {
            locked = true
        } else if s.hasPrefix("prunable") {
            prunable = true
        } else if s == "bare" {
            bare = true
        }
    }
    flush()
    return infos
}

/// Scan dirty files via `git status --porcelain=v1 -z` for clean-mode skips.
public func getModifiedFiles(repoPath: URL) throws -> DirtyFilesReport {
    let result = try runGit(
        ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
        cwd: repoPath
    )
    guard result.exitCode == 0 else {
        throw FastWorktreeError.gitFailed(result.stderr)
    }
    return parsePorcelainStatus(result.stdout)
}

func parsePorcelainStatus(_ text: String) -> DirtyFilesReport {
    var modified: [String] = []
    var untracked: [String] = []
    var deleted: [String] = []

    // -z separates records with NUL; each record is "XY path" or "XY origin -> path"
    let records = text.split(separator: "\0", omittingEmptySubsequences: true)
    for record in records {
        let s = String(record)
        guard s.count >= 3 else { continue }
        let xy = s.prefix(2)
        var pathPart = String(s.dropFirst(3))
        // Rename form: "R  old\0new" is split already; handle "R  old -> new" space form.
        if pathPart.contains(" -> ") {
            pathPart = String(pathPart.split(separator: ">", maxSplits: 1).last ?? Substring(pathPart))
                .trimmingCharacters(in: .whitespaces)
        }
        let x = xy.first ?? " "
        let y = xy.dropFirst().first ?? " "
        if x == "?" || y == "?" {
            untracked.append(pathPart)
        } else if x == "D" || y == "D" {
            deleted.append(pathPart)
        } else {
            modified.append(pathPart)
        }
    }

    return DirtyFilesReport(
        modifiedCount: UInt64(modified.count),
        untrackedCount: UInt64(untracked.count),
        deletedCount: UInt64(deleted.count),
        modified: modified,
        untracked: untracked,
        deleted: deleted
    )
}

/// Count tracked files via `git ls-files` (O(n); good enough for pooling heuristics).
public func countTrackedFiles(repoPath: URL) throws -> Int {
    let result = try runGit(["ls-files"], cwd: repoPath)
    guard result.exitCode == 0 else {
        throw FastWorktreeError.gitFailed(result.stderr)
    }
    return result.stdout.split(separator: "\n", omittingEmptySubsequences: true).count
}

/// Best-effort reclaim of a partially built worktree.
public func reclaimPartialWorktree(source: URL?, dest: URL) {
    if let source {
        _ = try? worktreeRemove(source: source, dest: dest, force: true)
    } else if FileManager.default.fileExists(atPath: dest.path) {
        try? FileManager.default.removeItem(at: dest)
    }
    // Also prune if source known.
    if let source {
        _ = try? runGit(["worktree", "prune"], cwd: source)
    }
}

// MARK: - Process helper

public struct GitCommandResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
}

public func runGit(_ args: [String], cwd: URL) throws -> GitCommandResult {
    // Reject smuggled options in path-like args that are destinations.
    for arg in args {
        if arg.contains("\0") {
            throw FastWorktreeError.argumentInjection("NUL in git argument")
        }
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + args
    process.currentDirectoryURL = cwd
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.environment = ProcessInfo.processInfo.environment.merging([
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_OPTIONAL_LOCKS": "0",
    ]) { _, new in new }

    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in
        finished.signal()
    }
    do {
        try process.run()
    } catch {
        throw FastWorktreeError.gitFailed("failed to spawn git: \(error)")
    }
    finished.wait()
    let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return GitCommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
}
