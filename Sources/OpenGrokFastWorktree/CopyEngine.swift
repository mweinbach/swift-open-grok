// CopyEngine.swift
//
// Parallel-friendly file copy with CoW (clonefile) on APFS when available.
// Skips `.git` for linked worktrees (git owns that metadata). Selective
// standalone `.git/` copy skips locks and transient state (Rust gitdir.rs).

import Foundation

#if os(macOS)
import Darwin

/// APFS copy-on-write clone. Declared explicitly to avoid a system module dependency.
@_silgen_name("clonefile")
func openGrokClonefile(
    _ from: UnsafePointer<CChar>,
    _ to: UnsafePointer<CChar>,
    _ flags: UInt32
) -> Int32
#endif

public struct CopyEngineOptions: Sendable {
    public var skipGitDirectory: Bool
    public var skipPatterns: [String]
    /// Relative paths to skip (dirty files in clean modes, already-copied set).
    public var skipFiles: Set<String>
    public var preferCow: Bool
    /// When true, only copy paths that git reports as ignored.
    public var ignoredOnly: Bool

    public init(
        skipGitDirectory: Bool = true,
        skipPatterns: [String] = [],
        skipFiles: Set<String> = [],
        preferCow: Bool = true,
        ignoredOnly: Bool = false
    ) {
        self.skipGitDirectory = skipGitDirectory
        self.skipPatterns = skipPatterns
        self.skipFiles = skipFiles
        self.preferCow = preferCow
        self.ignoredOnly = ignoredOnly
    }
}

/// Copy `source` tree into `dest`, returning a structured report.
public func copyTree(
    from source: URL,
    to dest: URL,
    options: CopyEngineOptions = CopyEngineOptions(),
    isCancelled: () -> Bool = { false },
    onProgress: ((UInt64) -> Void)? = nil
) throws -> CopyReport {
    var report = CopyReport()
    let fm = FileManager.default
    try fm.createDirectory(at: dest, withIntermediateDirectories: true)
    report.dirsCreated += 1

    guard let enumerator = fm.enumerator(
        at: source,
        includingPropertiesForKeys: [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
            .fileResourceIdentifierKey,
        ],
        options: [.skipsPackageDescendants]
    ) else {
        throw FastWorktreeError.io("failed to enumerate \(source.path)")
    }

    // Precompute ignored set when requested (uses git check-ignore via path walk).
    let ignoredSet: Set<String>? = options.ignoredOnly
        ? (try? collectIgnoredRelativePaths(repo: source))
        : nil

    while let item = enumerator.nextObject() as? URL {
        if isCancelled() { throw FastWorktreeError.cancelled }

        let rel = relativePath(of: item, from: source)
        if rel.isEmpty { continue }

        if options.skipGitDirectory {
            let first = rel.split(separator: "/").first.map(String.init) ?? ""
            if first == ".git" {
                enumerator.skipDescendants()
                report.filesSkipped += 1
                continue
            }
        }

        if options.skipFiles.contains(rel) {
            report.filesSkipped += 1
            // If this is a directory path in the skip set, skip descendants.
            enumerator.skipDescendants()
            continue
        }

        if options.skipPatterns.contains(where: { globMatch(pattern: $0, text: rel) }) {
            report.filesSkipped += 1
            enumerator.skipDescendants()
            continue
        }

        if let ignoredSet {
            // ignoredOnly: skip paths not in the ignored set.
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDir {
                // Keep walking if any ignored path is under this prefix.
                let prefix = rel + "/"
                let hasChild = ignoredSet.contains(where: { $0 == rel || $0.hasPrefix(prefix) })
                if !hasChild {
                    enumerator.skipDescendants()
                    report.filesSkipped += 1
                    continue
                }
                // Create dir if this dir itself is ignored or is a parent of one.
            } else if !ignoredSet.contains(rel) {
                report.filesSkipped += 1
                continue
            }
        }

        let destItem = dest.appendingPathComponent(rel)
        let values = try item.resourceValues(forKeys: [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
        ])

        if values.isSymbolicLink == true {
            let target = try fm.destinationOfSymbolicLink(atPath: item.path)
            try fm.createDirectory(
                at: destItem.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Replace existing (mirrors replace_symlink).
            try? fm.removeItem(at: destItem)
            try fm.createSymbolicLink(atPath: destItem.path, withDestinationPath: target)
            report.symlinksCopied += 1
            continue
        }

        if values.isDirectory == true {
            try fm.createDirectory(at: destItem, withIntermediateDirectories: true)
            report.dirsCreated += 1
            continue
        }

        try fm.createDirectory(
            at: destItem.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let usedCow = try copyFile(from: item, to: destItem, preferCow: options.preferCow)
        if usedCow { report.usedCow = true }
        report.filesCopied += 1
        if report.filesCopied % 64 == 0 {
            onProgress?(report.filesCopied)
        }
    }
    onProgress?(report.filesCopied)
    return report
}

/// Top-level `.git/` entries to skip when creating a standalone copy.
/// Mirrors Rust `copy/gitdir.rs` SKIP_TOP_LEVEL.
private let gitDirSkipTopLevel: Set<String> = [
    "worktrees",
    "FETCH_HEAD",
    "ORIG_HEAD",
    "MERGE_HEAD",
    "CHERRY_PICK_HEAD",
    "REVERT_HEAD",
    "REBASE_HEAD",
    "AUTO_MERGE",
    "BISECT_LOG",
    "sequencer",
    "rebase-merge",
    "rebase-apply",
    "gc.log",
    "fsmonitor--daemon",
    "fsmonitor--daemon.ipc",
]

/// Selective CoW copy of `.git/` for standalone repositories.
public func copyGitDir(
    from sourceGit: URL,
    to destGit: URL,
    preferCow: Bool = true,
    isCancelled: () -> Bool = { false }
) throws -> CopyReport {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: sourceGit.path, isDirectory: &isDir),
          isDir.boolValue
    else {
        throw FastWorktreeError.io(
            "source .git must be a directory (not a linked worktree .git file): \(sourceGit.path)"
        )
    }

    var report = CopyReport()
    try FileManager.default.createDirectory(at: destGit, withIntermediateDirectories: true)
    report.dirsCreated += 1

    try copyGitDirRecursive(
        source: sourceGit,
        dest: destGit,
        depth: 0,
        preferCow: preferCow,
        isCancelled: isCancelled,
        report: &report
    )
    return report
}

private func copyGitDirRecursive(
    source: URL,
    dest: URL,
    depth: Int,
    preferCow: Bool,
    isCancelled: () -> Bool,
    report: inout CopyReport
) throws {
    let entries = try FileManager.default.contentsOfDirectory(
        at: source,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey],
        options: []
    )
    for entry in entries {
        if isCancelled() { throw FastWorktreeError.cancelled }
        let name = entry.lastPathComponent
        if shouldSkipGitEntry(name: name, depth: depth) {
            report.filesSkipped += 1
            continue
        }
        let destEntry = dest.appendingPathComponent(name)
        let values = try entry.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey,
        ])
        if values.isSymbolicLink == true {
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
            try? FileManager.default.removeItem(at: destEntry)
            try FileManager.default.createSymbolicLink(
                atPath: destEntry.path,
                withDestinationPath: target
            )
            report.symlinksCopied += 1
        } else if values.isDirectory == true {
            try FileManager.default.createDirectory(at: destEntry, withIntermediateDirectories: true)
            report.dirsCreated += 1
            try copyGitDirRecursive(
                source: entry,
                dest: destEntry,
                depth: depth + 1,
                preferCow: preferCow,
                isCancelled: isCancelled,
                report: &report
            )
        } else if values.isRegularFile == true {
            let usedCow = try copyFile(from: entry, to: destEntry, preferCow: preferCow)
            if usedCow { report.usedCow = true }
            report.filesCopied += 1
        } else {
            // Sockets/FIFOs/devices: skip (host-local transient state).
            report.filesSkipped += 1
        }
    }
}

func shouldSkipGitEntry(name: String, depth: Int) -> Bool {
    if name.hasSuffix(".lock") { return true }
    if depth == 0 && gitDirSkipTopLevel.contains(name) { return true }
    return false
}

/// Returns true when CoW clonefile succeeded.
@discardableResult
func copyFile(from source: URL, to dest: URL, preferCow: Bool) throws -> Bool {
    #if os(macOS)
    if preferCow {
        // Remove dest first; clonefile fails if dest exists.
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }
        let rc = source.path.withCString { src in
            dest.path.withCString { dst in
                openGrokClonefile(src, dst, 0)
            }
        }
        if rc == 0 {
            // Propagate permissions (executable bit etc.).
            if let perms = try? FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: perms],
                    ofItemAtPath: dest.path
                )
            }
            return true
        }
    }
    #endif
    if FileManager.default.fileExists(atPath: dest.path) {
        try FileManager.default.removeItem(at: dest)
    }
    try FileManager.default.copyItem(at: source, to: dest)
    return false
}

func relativePath(of item: URL, from source: URL) -> String {
    let sourcePath = source.standardizedFileURL.path
    let itemPath = item.standardizedFileURL.path
    if itemPath == sourcePath { return "" }
    let prefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"
    if itemPath.hasPrefix(prefix) {
        return String(itemPath.dropFirst(prefix.count))
    }
    // Fallback: string replace (legacy behavior).
    return itemPath.replacingOccurrences(of: sourcePath, with: "")
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
}

/// Collect ignored relative paths via `git ls-files --others -i --exclude-standard`.
func collectIgnoredRelativePaths(repo: URL) throws -> Set<String> {
    let result = try runGit(
        ["ls-files", "--others", "-i", "--exclude-standard"],
        cwd: repo
    )
    guard result.exitCode == 0 else {
        throw FastWorktreeError.gitFailed(result.stderr)
    }
    let paths = result.stdout
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map(String.init)
    return Set(paths)
}

/// Simple glob: `*` does not cross `/`; `**` matches across segments.
func globMatch(pattern: String, text: String) -> Bool {
    fnmatchStyle(pattern: pattern, text: text)
}

private func fnmatchStyle(pattern: String, text: String) -> Bool {
    matchGlob(Array(pattern), Array(text))
}

private struct GlobMatchState: Hashable {
    let patternIndex: Int
    let textIndex: Int
}

private func matchGlob(_ pat: [Character], _ text: [Character]) -> Bool {
    var memo: [GlobMatchState: Bool] = [:]

    func matches(patternIndex: Int, textIndex: Int) -> Bool {
        let state = GlobMatchState(patternIndex: patternIndex, textIndex: textIndex)
        if let cached = memo[state] {
            return cached
        }

        let result: Bool
        if patternIndex == pat.count {
            result = textIndex == text.count
        } else if pat[patternIndex] == "*" {
            let isDoubleStar = patternIndex + 1 < pat.count && pat[patternIndex + 1] == "*"
            let nextPatternIndex = patternIndex + (isDoubleStar ? 2 : 1)
            if matches(patternIndex: nextPatternIndex, textIndex: textIndex) {
                result = true
            } else if textIndex < text.count,
                      isDoubleStar || text[textIndex] != "/"
            {
                result = matches(patternIndex: patternIndex, textIndex: textIndex + 1)
            } else {
                result = false
            }
        } else if textIndex < text.count,
                  pat[patternIndex] == text[textIndex]
                    || (pat[patternIndex] == "?" && text[textIndex] != "/")
        {
            result = matches(patternIndex: patternIndex + 1, textIndex: textIndex + 1)
        } else {
            result = false
        }

        memo[state] = result
        return result
    }

    return matches(patternIndex: 0, textIndex: 0)
}
