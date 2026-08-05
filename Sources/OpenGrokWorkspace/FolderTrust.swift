// FolderTrust.swift
//
// Folder-trust decision + store seams for repo-local code-exec gating.
// Workspace roots require explicit trust; child workspaces do not inherit
// a parent's trust decision via the exact-match FolderTrustStore API.
// Durable cascade (most-specific wins) is available on DurableTrustStore
// for parity with Rust `trust.rs` when loading `trusted_folders.toml`.

import Foundation
import OpenGrokConfig
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
        // `.opengrok/config.toml` belongs here: it can declare `[mcp_servers]`
        // — the exact table `LiveMCPComposition.connectConfiguredServers` reads
        // and spawns from — and `[permission]` rules that would widen this
        // session's own policy. Omitting it meant a repo carrying only a
        // config.toml scanned as "no code-exec config", resolved to trusted,
        // and had both honoured without anyone being asked.
        ".opengrok/config.toml",
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

    /// The recorded decisions, keyed by normalized absolute path. Exposed so
    /// `PersistentFolderTrustStore` can serialize them.
    public private(set) var folders: [String: Record]

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

// MARK: - Persistence (`trusted_folders.toml`)

/// Filename of the folder-trust store (`TRUST_FILE_NAME`, trust.rs:38).
public let trustedFoldersFileName = "trusted_folders.toml"

/// Path to the store, always under the **user** grok home.
///
/// Deliberately not `grokHome()`: a cloned repo carrying its own `./.opengrok`
/// must not be able to declare itself trusted (trust.rs:104-113). Returns nil
/// when no user home resolves, which the store reads as "trust nothing,
/// persist nothing".
public func trustedFoldersPath(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> URL? {
    userGrokHome(environment: environment)?.appendingPathComponent(trustedFoldersFileName)
}

/// Durable folder-trust store backed by `trusted_folders.toml`.
///
/// On-disk shape (trust.rs:8-13, 41-55):
/// ```toml
/// [folders."/abs/repo/root"]
/// trusted = true
/// decided_at = 1780000000
/// ```
/// Longest-matching-path-prefix wins and trust cascades to subdirectories;
/// over-broad keys (`$HOME`, filesystem root, relative paths) are dropped on
/// read so a corrupted store cannot trust the world.
public struct PersistentFolderTrustStore: Sendable {
    private var store: DurableTrustStore
    private let path: URL?
    private let home: String?

    public init(
        path: URL?,
        home: String? = ProcessInfo.processInfo.environment["HOME"]
    ) {
        self.path = path
        self.home = home
        self.store = PersistentFolderTrustStore.decode(path: path, home: home)
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(
            path: trustedFoldersPath(environment: environment),
            home: environment["HOME"]
        )
    }

    private static func decode(path: URL?, home: String?) -> DurableTrustStore {
        guard let path,
              let text = try? String(contentsOf: path, encoding: .utf8),
              let document = try? parseTOML(text),
              case .table(let root) = document,
              case .table(let folders)? = root["folders"]
        else { return DurableTrustStore() }

        var records: [String: DurableTrustStore.Record] = [:]
        for (rawPath, entry) in folders.pairs {
            guard case .table(let fields) = entry else { continue }
            guard case .boolean(let trusted)? = fields["trusted"] else { continue }
            let key = normalizeLexically(rawPath)
            if isUnsafeTrustRoot(key, home: home) { continue }
            var decidedAt: Date?
            if case .integer(let seconds)? = fields["decided_at"] {
                decidedAt = Date(timeIntervalSince1970: TimeInterval(seconds))
            }
            records[key] = DurableTrustStore.Record(trusted: trusted, decidedAt: decidedAt)
        }
        return DurableTrustStore(folders: records)
    }

    public func isTrusted(_ folder: URL) -> Bool {
        store.isTrusted(folder)
    }

    /// Record a decision and flush. A store with no resolvable home silently
    /// keeps the decision in memory only — never a hard failure at a prompt.
    public mutating func record(_ folder: URL, trusted: Bool) throws {
        if trusted {
            store.setTrusted(folder, home: home)
        } else {
            store.setUntrusted(folder, home: home)
        }
        try flush()
    }

    /// Serialize to `trusted_folders.toml` with `0600`, atomically.
    public func flush() throws {
        guard let path else { return }
        var folders = TOMLTable()
        for (folder, record) in store.folders {
            var fields = TOMLTable()
            fields["trusted"] = .boolean(record.trusted)
            if let decidedAt = record.decidedAt {
                fields["decided_at"] = .integer(Int64(decidedAt.timeIntervalSince1970))
            }
            folders[folder] = .table(fields)
        }
        var root = TOMLTable()
        root["folders"] = .table(folders)
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeAtomically(path, contents: TOMLEncoder.encode(.table(root)), mode: 0o600)
    }
}

// MARK: - Feature gate

/// Whether folder trust is enforced.
///
/// Precedence (workspace `folder_trust.rs:157-181`): env `GROK_FOLDER_TRUST` >
/// user config `[folder_trust] enabled` > managed config `[folder_trust]
/// enabled` > default **true**. Note the table is `[folder_trust]`, not
/// `[features]`.
public func folderTrustEnabled(
    document: TOMLValue?,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Bool {
    if let fromEnv = envBool("GROK_FOLDER_TRUST", environment: environment) {
        return fromEnv
    }
    if case .boolean(let enabled)? = document?[path: ["folder_trust", "enabled"]] {
        return enabled
    }
    return true
}
