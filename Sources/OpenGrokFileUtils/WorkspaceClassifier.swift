// WorkspaceClassifier.swift
//
// Port of `xai-file-utils::workspace_classifier` pure path classification
// (project vs excluded/system/home directories). Used by upload/event
// collection and workspace safety gates.

import Foundation

/// Classify a working directory as a project tree vs excluded system/home
/// locations.
public enum WorkspaceClassifier: Sendable {
    /// Directory names that never qualify as project roots when present as a
    /// path component.
    public static let excludedDirNames: Set<String> = [
        ".opengrok",
        ".cache",
        ".daemon",
        ".config",
        ".npm",
        ".cargo",
        ".rustup",
        ".vscode",
        ".gemini",
        ".hermes",
        ".claude",
    ]

    /// Whether `cwd` looks like a project directory (mirrors Rust
    /// `is_project_dir`).
    public static func isProjectDir(_ cwd: URL) -> Bool {
        let path = cwd.path
        if path.isEmpty { return false }
        // Root / no parent.
        if cwd.pathComponents.count <= 1 { return false }

        // Any ancestor with `.git` → project.
        // Note: `URL.deletingLastPathComponent` on `/` yields `/..` (not `/`),
        // so terminate on root / empty / path-component exhaustion rather than
        // path-string equality alone.
        var cursor = cwd.standardizedFileURL
        var guardCount = 0
        while guardCount < 64 {
            guardCount += 1
            if FileManager.default.fileExists(atPath: cursor.appendingPathComponent(".git").path) {
                return true
            }
            let path = cursor.path
            if path == "/" || path.isEmpty || cursor.pathComponents.count <= 1 {
                break
            }
            let parent = cursor.deletingLastPathComponent().standardizedFileURL
            if parent.path == path || parent.pathComponents.count >= cursor.pathComponents.count {
                break
            }
            cursor = parent
        }

        if hasExcludedComponent(cwd) { return false }
        if isPlatformSystemDir(cwd) { return false }

        let home = FileManager.default.homeDirectoryForCurrentUser
        if cwd.standardizedFileURL == home.standardizedFileURL { return false }
        if isPlatformHomeExcluded(cwd, home: home) { return false }

        for known in knownOSDirs() {
            if cwd.standardizedFileURL == known.standardizedFileURL { return false }
        }
        return true
    }
}

private func hasExcludedComponent(_ cwd: URL) -> Bool {
    for component in cwd.pathComponents {
        if WorkspaceClassifier.excludedDirNames.contains(component) {
            return true
        }
    }
    return false
}

private func knownOSDirs() -> [URL] {
    let fm = FileManager.default
    var urls: [URL] = []
    let home = fm.homeDirectoryForCurrentUser
    for name in ["Desktop", "Downloads", "Documents", "Music", "Movies", "Pictures", "Public"] {
        urls.append(home.appendingPathComponent(name))
    }
    return urls
}

private func isPlatformSystemDir(_ cwd: URL) -> Bool {
    let path = cwd.path
    #if os(Windows)
    let lower = path.lowercased()
    return lower.hasPrefix("c:\\windows") || lower.hasPrefix("c:\\program files")
    #else
    if path == "/tmp" || path.hasPrefix("/tmp/")
        || path == "/var/tmp" || path.hasPrefix("/var/tmp/")
        || path.hasPrefix("/var/folders/")
    {
        return true
    }
    #if os(macOS)
    if path == "/private/tmp" || path.hasPrefix("/private/tmp/") {
        return true
    }
    #endif
    return false
    #endif
}

private func isPlatformHomeExcluded(_ cwd: URL, home: URL) -> Bool {
    let path = cwd.path
    let homePath = home.path
    // Direct children of home that are config-ish.
    let excludedHomeChildren = [
        ".ssh", ".gnupg", ".local", ".Trash", "Library",
    ]
    for name in excludedHomeChildren {
        let candidate = home.appendingPathComponent(name)
        if path == candidate.path || path.hasPrefix(candidate.path + "/") {
            return true
        }
    }
    _ = homePath
    return false
}
