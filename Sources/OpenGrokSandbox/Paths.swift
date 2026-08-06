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

/// Reject roots that contain raw `..` components (lexical traversal) or NUL.
///
/// Both checks read the percent-*decoded* path. `URL.path` renders a NUL as
/// "%00" on every platform, so testing the raw path against "\0" could never
/// fire — and on Linux that was not merely dead, it was fail-open: the root
/// `/workspace/..\0` came back as the single component "..%00", which is not
/// "..", so a traversable root passed the gate. macOS happened to survive only
/// because its `URL` drops the NUL and leaves a bare ".." for the first check.
public func rejectTraversableRoot(_ root: URL) throws {
    let decoded = root.path.removingPercentEncoding ?? root.path
    // NUL first: it is what hides a traversal from the component scan below.
    if decoded.contains("\0") {
        throw SandboxError.profileInvalid("Refusing profile with NUL in root: \(root.path)")
    }
    let components = decoded.split(separator: "/", omittingEmptySubsequences: false)
    if components.contains("..") {
        throw SandboxError.profileInvalid("Refusing profile with traversable root: \(root.path)")
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

/// Toggle the macOS `/private` firmlink prefix for `/tmp`, `/var`, `/etc`
/// (e.g. `/private/tmp/x` <-> `/tmp/x`). Returns `nil` for unaffected paths.
public func togglePrivatePrefix(_ path: String) -> String? {
    for dir in ["tmp", "var", "etc"] {
        let privatePrefix = "/private/\(dir)"
        if path == privatePrefix || path.hasPrefix("\(privatePrefix)/") {
            let rest = String(path.dropFirst(privatePrefix.count))
            return "/\(dir)\(rest)"
        }
        let publicPrefix = "/\(dir)"
        if path == publicPrefix || path.hasPrefix("\(publicPrefix)/") {
            let rest = String(path.dropFirst(publicPrefix.count))
            return "/private/\(dir)\(rest)"
        }
    }
    return nil
}

/// All literal paths a deny rule must cover on macOS: the as-given path, its
/// canonical form, and the `/private` firmlink alias of each (e.g. `/tmp/x` <->
/// `/private/tmp/x`) so a deny cannot be bypassed via an alias.
public func macosDenyAliases(_ path: URL) -> [URL] {
    var urls: [URL] = [path]
    let canonical = path.resolvingSymlinksInPath()
    if canonical.path != path.path {
        urls.append(canonical)
    }
    let snapshot = urls
    for url in snapshot {
        if let aliasStr = togglePrivatePrefix(url.path) {
            let aliasURL = URL(fileURLWithPath: aliasStr)
            if !urls.contains(where: { $0.path == aliasURL.path }) {
                urls.append(aliasURL)
            }
        }
    }
    return urls
}

/// Whether a deny path should be treated as a directory.
public func denyPathIsDir(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
        return isDir.boolValue
    }
    return url.path.hasSuffix("/")
}

