// Paths.swift
//
// Filesystem path tables for sandbox profiles. Ported from
// `xai-grok-sandbox/src/paths.rs`.

import Foundation
import OpenGrokPaths

/// Device files that need write access for normal tool operation.
public let sandboxDeviceFiles: [String] = [
    "/dev/null",
    "/dev/zero",
    "/dev/random",
    "/dev/urandom",
    "/dev/tty",
    "/dev/ptmx",
    "/dev/fd",
]

/// Device directories that need write access.
public let sandboxDeviceDirs: [String] = [
    "/dev/pts",
]

/// Grok state directory — always writable (`$OPENGROK_HOME` or `~/.opengrok`).
public func sandboxGrokHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
    OpenGrokStatePaths.stateDirectory(environment: environment)
}

/// Temporary directories that need write access.
public func tempWritablePaths(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
    var paths: [URL] = [
        URL(fileURLWithPath: "/tmp"),
        URL(fileURLWithPath: "/var/tmp"),
    ]

    #if os(macOS)
    for p in ["/private/tmp", "/private/var/tmp", "/private/var/folders"] {
        let url = URL(fileURLWithPath: p)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            paths.append(url)
        }
    }
    #endif

    if let tmpdir = environment["TMPDIR"], !tmpdir.isEmpty {
        let url = URL(fileURLWithPath: tmpdir)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
           isDir.boolValue,
           !paths.contains(where: { $0.path == url.path })
        {
            paths.append(url)
        }
    }
    return paths
}

/// Writable directory paths for profiles that allow workspace writes.
public func essentialWritablePaths(
    workspace: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> [URL] {
    var paths = [workspace, sandboxGrokHome(environment: environment)]
    paths.append(contentsOf: tempWritablePaths(environment: environment))
    return paths
}

/// Writable directory paths for the read-only profile (minimal).
public func essentialWritablePathsMinimal(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> [URL] {
    var paths = [sandboxGrokHome(environment: environment)]
    paths.append(contentsOf: tempWritablePaths(environment: environment))
    return paths
}

/// Reject roots that contain raw `..` components (lexical traversal).
public func rejectTraversableRoot(_ root: URL) throws {
    let components = root.path.split(separator: "/", omittingEmptySubsequences: false)
    if components.contains("..") {
        throw SandboxError.profileInvalid("Refusing profile with traversable root: \(root.path)")
    }
    // Null bytes and empty path components after normalization are hostile.
    if root.path.contains("\0") {
        throw SandboxError.profileInvalid("Refusing profile with NUL in root: \(root.path)")
    }
}

/// Lexically check whether `candidate` is under `root` without following
/// symlinks. Both paths are normalized with `normalizeLexically`.
public func pathIsUnderRoot(candidate: String, root: String) -> Bool {
    let cand = normalizeLexically(candidate)
    let base = normalizeLexically(root)
    if cand == base { return true }
    let prefix = base.hasSuffix("/") ? base : base + "/"
    return cand.hasPrefix(prefix)
}
