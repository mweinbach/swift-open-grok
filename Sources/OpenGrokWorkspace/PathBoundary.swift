// PathBoundary.swift
//
// Workspace path boundary enforcement: traversal, symlink, case-folding,
// and Unicode-normalization resistant containment checks.

import Foundation
import OpenGrokPaths
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum PathBoundaryError: Error, Equatable, Sendable, CustomStringConvertible {
    case outsideWorkspace(String)
    case traversal(String)
    case symlinkEscape(String)
    case nullByte(String)
    case emptyPath
    case notAbsolute(String)

    public var description: String {
        switch self {
        case .outsideWorkspace(let p): return "path outside workspace: \(p)"
        case .traversal(let p): return "path traversal rejected: \(p)"
        case .symlinkEscape(let p): return "symlink escape rejected: \(p)"
        case .nullByte(let p): return "NUL in path rejected: \(p)"
        case .emptyPath: return "empty path"
        case .notAbsolute(let p): return "path is not absolute: \(p)"
        }
    }
}

/// Enforces that filesystem operations stay within a workspace root.
public struct PathBoundary: Sendable {
    public let root: URL
    /// When true, resolve symlinks before containment checks. Missing leaves
    /// are checked through their deepest existing ancestor so a symlink cannot
    /// hide an outbound parent before a writer creates the leaf.
    public var resolveSymlinks: Bool

    public init(root: URL, resolveSymlinks: Bool = true) {
        self.root = root.standardizedFileURL
        self.resolveSymlinks = resolveSymlinks
    }

    /// Canonicalize a user-supplied path relative to the workspace and ensure
    /// it remains inside the root.
    public func resolve(_ raw: String) throws -> URL {
        if raw.isEmpty { throw PathBoundaryError.emptyPath }
        if raw.contains("\0") { throw PathBoundaryError.nullByte(raw) }

        let candidate: URL
        if raw.hasPrefix("/") || isAbsolutePath(raw) {
            candidate = URL(fileURLWithPath: raw)
        } else {
            candidate = root.appendingPathComponent(raw)
        }

        // Lexical check first (catches `..` without filesystem).
        let lexical = normalizeLexically(candidate.path)
        let rootLex = normalizeLexically(root.path)
        let lexicalKey = normalizeForContainment(lexical)
        let rootKey = normalizeForContainment(rootLex)
        let containmentRoot: String
        if resolveSymlinks,
           let resolvedRoot = try? resolveCanonicalPath(URL(fileURLWithPath: rootLex))
        {
            containmentRoot = normalizeForContainment(resolvedRoot.path)
        } else {
            containmentRoot = rootKey
        }
        if !containsPath(root: rootKey, candidate: lexicalKey),
           !containsPath(root: containmentRoot, candidate: lexicalKey)
        {
            // Check for parentDir components specifically.
            let comps = splitComponents(candidate.path)
            if comps.contains(where: {
                if case .parentDir = $0 { return true }
                return false
            }) {
                throw PathBoundaryError.traversal(raw)
            }
            throw PathBoundaryError.outsideWorkspace(raw)
        }

        if resolveSymlinks {
            // realpath-style resolution via FileUtils when available. For a
            // missing leaf, canonicalize the deepest existing ancestor instead
            // of accepting a lexical path whose parent may be an outbound link.
            let probe = deepestExistingAncestor(URL(fileURLWithPath: lexical))
            if let probe, let resolved = try? resolveCanonicalPath(probe) {
                let resolvedLex = normalizeForContainment(resolved.path)
                if !containsPath(root: containmentRoot, candidate: resolvedLex) {
                    throw PathBoundaryError.symlinkEscape(raw)
                }
                if probe.path == lexical {
                    return resolved
                }
            }
        }
        return URL(fileURLWithPath: lexical)
    }

    /// Returns true when `path` is under the workspace (lexical).
    public func contains(_ path: URL) -> Bool {
        let rootLex = normalizeForContainment(root.path)
        let cand = normalizeForContainment(path.path)
        return containsPath(root: rootLex, candidate: cand)
    }
}

private func normalizeForContainment(_ path: String) -> String {
    var normalized = normalizeLexically(path)
    #if os(Windows)
    normalized = normalized.replacingOccurrences(of: "\\", with: "/").lowercased()
    #endif
    #if os(macOS)
    for directory in ["tmp", "var", "etc"] {
        let privatePrefix = "/private/\(directory)"
        if normalized == privatePrefix {
            return "/\(directory)"
        }
        if normalized.hasPrefix(privatePrefix + "/") {
            return String(normalized.dropFirst("/private".count))
        }
    }
    #endif
    return normalized
}

/// Component-aware containment: candidate is root or a strict descendant.
public func containsPath(root: String, candidate: String) -> Bool {
    let normalizedRoot = normalizeForContainment(root)
    let normalizedCandidate = normalizeForContainment(candidate)
    if normalizedRoot == normalizedCandidate { return true }
    let prefix = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"
    return normalizedCandidate.hasPrefix(prefix)
}

/// Resolve a path with realpath when possible.
func resolveCanonicalPath(_ url: URL) throws -> URL {
    // Prefer OpenGrokFileUtils.canonicalPath if present.
    #if os(Windows)
    return url.standardizedFileURL
    #else
    return try url.withUnsafeFileSystemRepresentation { cstr -> URL in
        guard let cstr else { throw PathBoundaryError.notAbsolute(url.path) }
        guard let buf = realpath(cstr, nil) else {
            throw PathBoundaryError.outsideWorkspace(url.path)
        }
        defer { free(buf) }
        return URL(fileURLWithPath: String(cString: buf))
    }
    #endif
}

private func deepestExistingAncestor(_ url: URL) -> URL? {
    var probe = url
    while !probe.path.isEmpty {
        if FileManager.default.fileExists(atPath: probe.path) {
            return probe
        }
        let parent = probe.deletingLastPathComponent()
        if parent.path == probe.path { break }
        probe = parent
    }
    return nil
}

/// Folder trust decision for a workspace root.
public enum FolderTrustState: String, Codable, Sendable, Equatable {
    case trusted
    case untrusted
    case unknown
}

/// Exact-match trust registration for workspace roots.
///
/// **Does not inherit to children:** trusting `/proj` leaves `/proj/sub` as a
/// separate untrusted workspace root for project-scope MCP/hooks. Durable
/// cascade lookups live on `DurableTrustStore` (optional).
public struct FolderTrustStore: Sendable {
    private var trustedRoots: Set<String>
    private var untrustedRoots: Set<String>

    public init(trustedRoots: [URL] = []) {
        let home = ProcessInfo.processInfo.environment["HOME"]
        self.trustedRoots = Set(
            trustedRoots.map { trustPathKey($0.path) }
                .filter { !isUnsafeTrustRoot($0, home: home) }
        )
        self.untrustedRoots = []
    }

    public mutating func trust(_ root: URL) {
        let key = trustPathKey(root.path)
        if isUnsafeTrustRoot(key, home: ProcessInfo.processInfo.environment["HOME"]) { return }
        trustedRoots.insert(key)
        untrustedRoots.remove(key)
    }

    public mutating func untrust(_ root: URL) {
        let key = trustPathKey(root.path)
        trustedRoots.remove(key)
        untrustedRoots.insert(key)
    }

    public func state(for root: URL) -> FolderTrustState {
        let key = trustPathKey(root.path)
        if isUnsafeTrustRoot(key, home: ProcessInfo.processInfo.environment["HOME"]) {
            return .untrusted
        }
        if untrustedRoots.contains(key) { return .untrusted }
        if trustedRoots.contains(key) { return .trusted }
        // Parent trust does not automatically trust children (fail closed).
        return .untrusted
    }
}

func trustPathKey(_ path: String) -> String {
    var key = canonicalWorkspacePathKey(path)
    while key.count > 1, key.hasSuffix("/"), !key.hasSuffix(":/") {
        key.removeLast()
    }
    return key
}

/// Resolve existing ancestors before comparing security-sensitive path keys.
///
/// New files have no `realpath` yet, but their parents may already be symlink
/// aliases. Resolving the deepest existing ancestor keeps those aliases on the
/// same trust and resource-lock identity without rejecting legitimate creates.
func canonicalWorkspacePathKey(_ path: String) -> String {
    var key = normalizeLexically(path).replacingOccurrences(of: "\\", with: "/")
    if key.hasPrefix("/") || isAbsolutePath(key) {
        var ancestor = URL(fileURLWithPath: key)
        var missingComponents: [String] = []

        while !FileManager.default.fileExists(atPath: ancestor.path) {
            let parent = ancestor.deletingLastPathComponent()
            if parent.path == ancestor.path { break }
            missingComponents.append(ancestor.lastPathComponent)
            ancestor = parent
        }

        if let canonicalAncestor = try? resolveCanonicalPath(ancestor) {
            var canonical = canonicalAncestor
            for component in missingComponents.reversed() {
                canonical.appendPathComponent(component)
            }
            key = normalizeLexically(canonical.path)
                .replacingOccurrences(of: "\\", with: "/")
        }
    }
    #if os(Windows)
    key = key.lowercased()
    #endif
    return key
}
