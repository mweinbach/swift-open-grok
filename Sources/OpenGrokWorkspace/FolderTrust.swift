// FolderTrust.swift
//
// Folder-trust decision + store seams for repo-local code-exec gating.
// Workspace roots require explicit trust; child workspaces do not inherit
// a parent's trust decision via the exact-match FolderTrustStore API.
// Durable cascade (most-specific wins) is available on DurableTrustStore
// for parity with Rust `trust.rs` when loading `trusted_folders.toml`.

import Foundation
import OpenGrokPaths

// FolderTrustState + FolderTrustStore live in PathBoundary.swift (exact-match).

/// Pure trust outcome for decide().
public enum TrustOutcome: String, Sendable, Equatable {
    case trusted
    case untrusted
    case prompt
}

/// Inputs to the pure decide() precedence function.
public struct FolderTrustDecideInputs: Sendable, Equatable {
    public var storeTrusted: Bool
    public var repoConfigsPresent: Bool
    public var isInteractive: Bool
    /// False when the workspace key is an over-broad root the store refuses.
    public var keyRecordable: Bool

    public init(
        storeTrusted: Bool,
        repoConfigsPresent: Bool,
        isInteractive: Bool,
        keyRecordable: Bool
    ) {
        self.storeTrusted = storeTrusted
        self.repoConfigsPresent = repoConfigsPresent
        self.isInteractive = isInteractive
        self.keyRecordable = keyRecordable
    }
}

/// Pure trust-decision precedence (no I/O).
///
/// 1. Feature flag OFF → trusted
/// 2. Store trusted → trusted
/// 3. Key unrecordable → trusted
/// 4. No repo-local code-exec configs → trusted
/// 5. Interactive → prompt
/// 6. Headless → untrusted
public func decideFolderTrust(featureEnabled: Bool, inputs: FolderTrustDecideInputs) -> TrustOutcome {
    if !featureEnabled { return .trusted }
    if inputs.storeTrusted { return .trusted }
    if !inputs.keyRecordable { return .trusted }
    if !inputs.repoConfigsPresent { return .trusted }
    if inputs.isInteractive { return .prompt }
    return .untrusted
}

/// Over-broad roots that must never be persisted as trusted.
public func isUnsafeTrustRoot(_ path: String, home: String? = nil) -> Bool {
    let p = normalizeLexically(path)
    if p.isEmpty || !p.hasPrefix("/") { return true }
    if p == "/" { return true }
    if let home {
        let h = normalizeLexically(home)
        if p == h { return true }
    }
    return false
}

/// Scan for repo-local code-exec config files under `cwd` / parents (shallow).
public func repoConfigsPresent(at cwd: URL) -> Bool {
    let names = [
        ".mcp.json",
        ".claude/settings.json",
        ".claude/settings.local.json",
        ".opengrok/hooks.toml",
        ".opengrok/mcp.toml",
        ".envrc",
        "CLAUDE.md",
    ]
    var dir = cwd
    for _ in 0..<8 {
        for name in names {
            let candidate = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return true
            }
        }
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { break }
        dir = parent
    }
    return false
}

/// In-memory durable trust store with most-specific cascade for lookups.
/// Explicit child untrust overrides an ancestor trust; workspace registration
/// via `FolderTrustStore` remains exact-match (children do not inherit).
public struct DurableTrustStore: Sendable {
    public struct Record: Sendable, Equatable {
        public var trusted: Bool
        public var decidedAt: Date?
        public init(trusted: Bool, decidedAt: Date? = Date()) {
            self.trusted = trusted
            self.decidedAt = decidedAt
        }
    }

    private var folders: [String: Record]

    public init(folders: [String: Record] = [:]) {
        self.folders = folders
    }

    public mutating func setTrusted(_ path: URL, home: String? = nil) {
        let key = normalizeLexically(path.path)
        if isUnsafeTrustRoot(key, home: home) { return }
        folders[key] = Record(trusted: true)
    }

    public mutating func setUntrusted(_ path: URL, home: String? = nil) {
        let key = normalizeLexically(path.path)
        if isUnsafeTrustRoot(key, home: home) { return }
        folders[key] = Record(trusted: false)
    }

    /// Most-specific (longest prefix) recorded decision. Cascade to children
    /// only when an ancestor record exists — an unrecorded child still
    /// inherits ancestor trust here; use `FolderTrustStore` for exact root
    /// registration that does not inherit.
    public func isTrusted(_ path: URL) -> Bool {
        let key = normalizeLexically(path.path)
        if isUnsafeTrustRoot(key) { return false }
        var bestDepth: Int?
        var trusted = false
        for (folder, record) in folders {
            if isUnsafeTrustRoot(folder) { continue }
            if key == folder || key.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/") {
                let depth = folder.split(separator: "/").count
                if let d = bestDepth {
                    if depth < d { continue }
                    if depth == d {
                        trusted = trusted && record.trusted
                        continue
                    }
                }
                bestDepth = depth
                trusted = record.trusted
            }
        }
        return trusted
    }
}

/// Project-scope allowance: only the exact trusted root may load project
/// MCP/hooks. Children of a trusted root do **not** inherit via this API.
public func projectScopeAllowed(
    workspaceRoot: URL,
    trustStore: FolderTrustStore
) -> Bool {
    trustStore.state(for: workspaceRoot) == .trusted
}
