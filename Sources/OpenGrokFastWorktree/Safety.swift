// Safety.swift
//
// Path-escape, primary-checkout protection, pool-root containment,
// symlink-escape detection, and argument-injection rejection.

import Foundation
import OpenGrokFileUtils
import OpenGrokPaths

/// Ensure `dest` is not the primary checkout (`sourceToplevel`) and does not
/// nest inside it in a way that would destroy the user's tree, nor escape a
/// declared pool root.
public struct WorktreeSafetyPolicy: Sendable {
    public var primaryCheckout: URL?
    public var allowedPoolRoot: URL?

    public init(primaryCheckout: URL?, allowedPoolRoot: URL? = nil) {
        self.primaryCheckout = primaryCheckout?.standardizedFileURL
        self.allowedPoolRoot = allowedPoolRoot?.standardizedFileURL
    }

    public func validateDestination(_ dest: URL) throws {
        try rejectHostileDestination(dest)
        let d = dest.standardizedFileURL

        if let primary = primaryCheckout {
            // Never create/remove the primary checkout itself.
            if pathsEqual(d, primary) {
                throw FastWorktreeError.primaryCheckoutProtected(d.path)
            }
        }

        // Reject raw traversal components in the destination path.
        let components = splitComponents(d.path)
        if components.contains(where: { if case .parentDir = $0 { return true }; return false }) {
            throw FastWorktreeError.pathEscape(d.path)
        }

        if let pool = allowedPoolRoot {
            try validateInsidePool(dest: d, pool: pool)
        }

        // Refuse destinations that would replace the primary after resolving
        // an existing symlink parent — but if dest does not exist yet, only
        // lexical + parent-chain checks apply.
        if FileManager.default.fileExists(atPath: d.path) {
            let resolved = d.resolvingSymlinksInPath()
            if let primary = primaryCheckout, pathsEqual(resolved, primary) {
                throw FastWorktreeError.primaryCheckoutProtected(resolved.path)
            }
            if let pool = allowedPoolRoot {
                try validateInsidePool(dest: resolved, pool: pool, resolved: true)
            }
        }
    }

    public func validateNotPrimary(_ path: URL) throws {
        guard let primary = primaryCheckout else { return }
        if pathsEqual(path.standardizedFileURL, primary) {
            throw FastWorktreeError.primaryCheckoutProtected(path.path)
        }
        if FileManager.default.fileExists(atPath: path.path) {
            let resolved = path.resolvingSymlinksInPath()
            if pathsEqual(resolved, primary) {
                throw FastWorktreeError.primaryCheckoutProtected(resolved.path)
            }
        }
    }

    /// Lexical + parent-symlink containment under `pool`.
    private func validateInsidePool(dest: URL, pool: URL, resolved: Bool = false) throws {
        let poolPath = normalizeLexically(pool.path)
        let destPath = normalizeLexically(dest.path)
        let prefix = poolPath.hasSuffix("/") ? poolPath : poolPath + "/"
        if destPath != poolPath && !destPath.hasPrefix(prefix) {
            throw FastWorktreeError.pathEscape(
                "destination \(dest.path) is outside pool root \(pool.path)"
            )
        }

        // Walk parent chain: if any intermediate component is a symlink that
        // resolves outside the pool, fail closed (symlink escape).
        if !resolved {
            try rejectSymlinkEscape(dest: dest, poolPath: poolPath, poolPrefix: prefix)
        }
    }

    private func rejectSymlinkEscape(dest: URL, poolPath: String, poolPrefix: String) throws {
        var current = dest.standardizedFileURL
        // Walk up to the pool root, inspecting each existing component.
        while current.path != "/" {
            let parent = current.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: current.path) {
                if let isLink = try? PathSecurity.isSymlink(current), isLink {
                    let target = current.resolvingSymlinksInPath()
                    let targetPath = normalizeLexically(target.path)
                    if targetPath != poolPath && !targetPath.hasPrefix(poolPrefix) {
                        throw FastWorktreeError.pathEscape(
                            "symlink escape via \(current.path) -> \(target.path)"
                        )
                    }
                }
            }
            if normalizeLexically(current.path) == poolPath { break }
            if parent.path == current.path { break }
            current = parent
        }
    }
}

/// Reject destination / ref payloads that look like argument injection or
/// hostile paths (NUL, leading dashes for git args, newlines).
public func rejectHostileDestination(_ dest: URL) throws {
    let path = dest.path
    do {
        try PathSecurity.rejectHostileLexical(path)
    } catch {
        throw FastWorktreeError.pathEscape(path)
    }
    if path.contains("\n") || path.contains("\r") {
        throw FastWorktreeError.argumentInjection("newline in destination path")
    }
}

/// Validate a git ref for injection before shelling out.
public func rejectHostileGitRef(_ ref: String) throws {
    if ref.isEmpty {
        throw FastWorktreeError.invalidRef(ref)
    }
    if ref.contains("\0") {
        throw FastWorktreeError.argumentInjection("NUL in git ref")
    }
    if ref.contains("\n") || ref.contains("\r") {
        throw FastWorktreeError.argumentInjection("newline in git ref")
    }
    // Git interprets leading `-` as options when passed positionally without
    // `--`. Fail closed rather than relying on argument order.
    if ref.hasPrefix("-") {
        throw FastWorktreeError.argumentInjection("git ref looks like a flag: \(ref)")
    }
    // Reject obvious path-escape attempts smuggled as refs.
    if ref.contains("..") && (ref.contains("/") || ref.contains("\\")) {
        // Allow names like `feature/foo..bar`? Git range syntax is invalid as
        // a single commit-ish for worktree add; still reject `../` style.
        if ref.split(separator: "/").contains("..")
            || ref.split(separator: "\\").contains("..")
        {
            throw FastWorktreeError.argumentInjection("path traversal in git ref: \(ref)")
        }
    }
}

func pathsEqual(_ a: URL, _ b: URL) -> Bool {
    a.standardizedFileURL.path == b.standardizedFileURL.path
}

/// Ensure destination does not already exist (unless empty and reusable).
public func ensureDestinationAvailable(_ dest: URL, allowEmptyReuse: Bool = false) throws {
    var isDir: ObjCBool = false
    // Use lstat-equivalent: treat a dangling/existing symlink as occupied.
    if let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path) {
        let type = attrs[.type] as? FileAttributeType
        if type == .typeSymbolicLink {
            throw FastWorktreeError.destinationExists(dest.path)
        }
    }
    if FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDir) {
        if allowEmptyReuse, isDir.boolValue,
           let contents = try? FileManager.default.contentsOfDirectory(atPath: dest.path),
           contents.isEmpty
        {
            return
        }
        // Allow reuse only when the sole content is our partial marker (recoverable).
        if allowEmptyReuse, isDir.boolValue,
           let contents = try? FileManager.default.contentsOfDirectory(atPath: dest.path),
           contents.count == 1,
           contents[0] == partialMarkerFileName
        {
            return
        }
        throw FastWorktreeError.destinationExists(dest.path)
    }
}

/// Write a recoverable partial-creation marker under `dest`.
public func writePartialMarker(_ marker: PartialWorktreeMarker, at dest: URL) throws {
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    let url = dest.appendingPathComponent(PartialWorktreeMarker.fileName)
    let data = try JSONEncoder().encode(marker)
    try data.write(to: url, options: .atomic)
}

/// Read a partial marker if present.
public func readPartialMarker(at dest: URL) -> PartialWorktreeMarker? {
    let url = dest.appendingPathComponent(PartialWorktreeMarker.fileName)
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(PartialWorktreeMarker.self, from: data)
}

/// Remove the partial marker after successful creation.
public func clearPartialMarker(at dest: URL) {
    let url = dest.appendingPathComponent(PartialWorktreeMarker.fileName)
    try? FileManager.default.removeItem(at: url)
}

/// True when `path` looks like a half-created worktree we can reclaim.
public func isRecoverablePartialWorktree(_ path: URL) -> Bool {
    readPartialMarker(at: path) != nil
}
