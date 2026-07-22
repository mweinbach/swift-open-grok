// GitOps.swift
//
// Git discovery, worktree add/remove, and HEAD validation helpers.

import Foundation
import OpenGrokPaths

/// Locate the git common dir / worktree root for `path`.
public func discoverGitRepo(at path: URL) throws -> GitRepoIdentity {
    let result = try runGit(["rev-parse", "--show-toplevel"], cwd: path)
    guard result.exitCode == 0 else {
        throw FastWorktreeError.notAGitRepository(path.path)
    }
    let toplevel = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !toplevel.isEmpty else {
        throw FastWorktreeError.notAGitRepository(path.path)
    }
    let common = try runGit(["rev-parse", "--git-common-dir"], cwd: path)
    var commonDir = common.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if !commonDir.hasPrefix("/") {
        commonDir = URL(fileURLWithPath: commonDir, relativeTo: URL(fileURLWithPath: toplevel))
            .standardizedFileURL.path
    }
    let head = try runGit(["rev-parse", "HEAD"], cwd: path)
    let commit = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    return GitRepoIdentity(
        toplevel: URL(fileURLWithPath: toplevel),
        commonDir: URL(fileURLWithPath: commonDir),
        headCommit: commit
    )
}

public struct GitRepoIdentity: Sendable, Equatable {
    public var toplevel: URL
    public var commonDir: URL
    public var headCommit: String
}

/// Validate that `ref` resolves inside the repository.
public func resolveGitRef(_ ref: String, repo: URL) throws -> String {
    guard !ref.isEmpty, !ref.contains("\0"), !ref.hasPrefix("-") else {
        throw FastWorktreeError.invalidRef(ref)
    }
    let result = try runGit(["rev-parse", "--verify", "\(ref)^{commit}"], cwd: repo)
    guard result.exitCode == 0 else {
        throw FastWorktreeError.invalidRef(ref)
    }
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Create a linked worktree with `--no-checkout`.
public func worktreeAddNoCheckout(source: URL, dest: URL, gitRef: String) throws {
    let result = try runGit(
        ["worktree", "add", "--detach", "--no-checkout", dest.path, gitRef],
        cwd: source
    )
    if result.exitCode != 0 {
        throw FastWorktreeError.gitFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
    }
}

/// Create a linked worktree with full checkout.
public func worktreeAddCheckout(source: URL, dest: URL, gitRef: String) throws {
    let result = try runGit(
        ["worktree", "add", "--detach", dest.path, gitRef],
        cwd: source
    )
    if result.exitCode != 0 {
        throw FastWorktreeError.gitFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
    }
}

/// Remove a linked worktree registration and directory.
public func worktreeRemove(source: URL, dest: URL, force: Bool = true) throws -> RemoveReport {
    var args = ["worktree", "remove"]
    if force { args.append("--force") }
    args.append(dest.path)
    let result = try runGit(args, cwd: source)
    var issues: [String] = []
    var removed = result.exitCode == 0
    if !removed {
        issues.append(result.stderr.isEmpty ? result.stdout : result.stderr)
        // Fall back to deleting the directory and pruning.
        if FileManager.default.fileExists(atPath: dest.path) {
            do {
                try FileManager.default.removeItem(at: dest)
                removed = true
            } catch {
                issues.append("removeItem: \(error)")
            }
        }
        _ = try? runGit(["worktree", "prune"], cwd: source)
    }
    return RemoveReport(path: dest, removed: removed, issues: issues)
}

/// List linked worktrees for a repository.
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

    func flush() {
        if let currentPath {
            infos.append(LinkedWorktreeInfo(
                path: currentPath,
                head: head,
                branch: branch,
                locked: locked,
                prunable: prunable
            ))
        }
        currentPath = nil
        head = nil
        branch = nil
        locked = false
        prunable = false
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
        } else if s == "detached" {
            branch = nil
        } else if s.hasPrefix("locked") {
            locked = true
        } else if s.hasPrefix("prunable") {
            prunable = true
        }
    }
    flush()
    return infos
}

/// Count tracked files via `git ls-files` (O(n); good enough for pooling heuristics).
public func countTrackedFiles(repoPath: URL) throws -> Int {
    let result = try runGit(["ls-files"], cwd: repoPath)
    guard result.exitCode == 0 else {
        throw FastWorktreeError.gitFailed(result.stderr)
    }
    return result.stdout.split(separator: "\n", omittingEmptySubsequences: true).count
}

// MARK: - Process helper

public struct GitCommandResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
}

public func runGit(_ args: [String], cwd: URL) throws -> GitCommandResult {
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

    do {
        try process.run()
    } catch {
        throw FastWorktreeError.gitFailed("failed to spawn git: \(error)")
    }
    process.waitUntilExit()
    let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return GitCommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
}
