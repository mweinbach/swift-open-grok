// Paths.swift
//
// `.git/` path classification. Component-based against the discovered
// `gitDir` (not substring matching), so `/tmp/.git-backup/HEAD` is safe
// and Windows separators work. Port of xai-fsnotify `paths.rs`.

import Foundation

/// Classify a path under a discovered git directory into a `GitMetaKind`.
///
/// Watched: `HEAD`, `index`, `refs/*`, `packed-refs`, `FETCH_HEAD`.
/// Skipped: `COMMIT_EDITMSG`, `MERGE_HEAD`, `REBASE_HEAD`, `objects/*`,
/// `index.lock` (handled by the lock state machine, not here).
public func classifyGitPath(path: String, gitDir: String) -> GitMetaKind? {
    let pathURL = URL(fileURLWithPath: path)
    let gitURL = URL(fileURLWithPath: gitDir)
    let pathComponents = pathURL.standardizedFileURL.pathComponents
    let gitComponents = gitURL.standardizedFileURL.pathComponents
    guard pathComponents.count > gitComponents.count else { return nil }
    guard Array(pathComponents.prefix(gitComponents.count)) == gitComponents else {
        return nil
    }
    let rel = pathComponents.dropFirst(gitComponents.count)
    guard let first = rel.first else { return nil }
    switch first {
    case "HEAD" where rel.count == 1:
        return .headChanged
    case "FETCH_HEAD" where rel.count == 1:
        return .fetchHeadChanged
    case "index" where rel.count == 1:
        return .indexChanged
    case "packed-refs" where rel.count == 1:
        return .refsChanged
    case "refs":
        return .refsChanged
    default:
        return nil
    }
}

/// Discover a `.git` directory governing `watchPath` by walking ancestors.
/// A real directory is returned; a `.git` file (gitdir pointer) is resolved
/// by reading `gitdir: <path>` without shelling out.
public func findGitDir(watchPath: String) -> String? {
    var current = URL(fileURLWithPath: watchPath)
    let fm = FileManager.default
    while true {
        let dotGit = current.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
            if isDir.boolValue {
                return (try? fm.destinationOfSymbolicLink(atPath: dotGit.path)).map {
                    URL(fileURLWithPath: $0).path
                } ?? canonicalizePath(dotGit.path)
            }
            // gitdir: pointer file (worktrees / submodules)
            if let text = try? String(contentsOf: dotGit, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("gitdir:") {
                    let raw = trimmed.dropFirst("gitdir:".count)
                        .trimmingCharacters(in: .whitespaces)
                    let resolved: URL
                    if raw.hasPrefix("/") || (raw.count > 1 && raw[raw.index(raw.startIndex, offsetBy: 1)] == ":") {
                        resolved = URL(fileURLWithPath: raw)
                    } else {
                        resolved = current.appendingPathComponent(raw)
                    }
                    return canonicalizePath(resolved.path)
                }
            }
        }
        let parent = current.deletingLastPathComponent()
        if parent.path == current.path { break }
        current = parent
    }
    return nil
}

/// Locate a `.sl` working-copy directory governing `watchPath`.
public func findSaplingDir(watchPath: String) -> String? {
    var current = URL(fileURLWithPath: watchPath)
    let fm = FileManager.default
    while true {
        let dotSL = current.appendingPathComponent(".sl")
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dotSL.path, isDirectory: &isDir), isDir.boolValue {
            // Reject symlinks: only real directories.
            if let attrs = try? fm.attributesOfItem(atPath: dotSL.path),
               let type = attrs[.type] as? FileAttributeType,
               type == .typeSymbolicLink {
                // fall through
            } else {
                return canonicalizePath(dotSL.path)
            }
        }
        let parent = current.deletingLastPathComponent()
        if parent.path == current.path { break }
        current = parent
    }
    return nil
}

func canonicalizePath(_ path: String) -> String {
    let url = URL(fileURLWithPath: path)
    return url.resolvingSymlinksInPath().standardizedFileURL.path
}

/// Whether Sapling (`.sl`) support is enabled (default on;
/// `OPENGROK_FSNOTIFY_SAPLING=0|false` disables — Open Grok branding; also
/// honors legacy `GROK_FSNOTIFY_SAPLING` for fixture compatibility).
public func saplingEnabled(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Bool {
    let raw = environment["OPENGROK_FSNOTIFY_SAPLING"]
        ?? environment["GROK_FSNOTIFY_SAPLING"]
    return !(raw == "0" || raw == "false")
}
