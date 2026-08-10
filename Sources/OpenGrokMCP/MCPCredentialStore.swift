// MCPCredentialStore.swift
//
// Port of `xai-grok-mcp/src/credentials.rs` (reference 650c1db7): the
// persistent credential store for MCP server OAuth tokens.
//
// Credentials live in `$OPENGROK_HOME/mcp_credentials.json`, keyed by the
// composite `"{server_name}:{server_url}"` (credentials.rs:83-85), keeping MCP
// OAuth tokens isolated from the user's xAI auth (`auth.json`). The on-disk
// entry shape is rmcp's `StoredCredentials` (rmcp-2.1.0 transport/auth.rs:
// 188-197) wrapping oauth2's `StandardTokenResponse` — ported field for field
// below, including vendor extra token fields, so a file written by the Rust
// build loads here unchanged and round-trips without dropping fields.
//
// Every path that takes a home directory takes it explicitly — no process-cwd
// or process-env default (AGENTS.md §2's silent-divergence footgun).

import Foundation
import OpenGrokFileUtils
import OpenGrokShared

// MARK: - Token response (oauth2 StandardTokenResponse<VendorExtraTokenFields, BasicTokenType>)

/// The token endpoint's response as persisted inside `mcp_credentials.json`.
///
/// Mirrors oauth2's `StandardTokenResponse` JSON: `access_token` and
/// `token_type` required; `expires_in` (seconds), `refresh_token` and `scope`
/// (space-delimited) optional and omitted when absent. Unknown keys are
/// vendor extra fields (rmcp `VendorExtraTokenFields`, auth.rs:325-329) and
/// are preserved verbatim so a store rewrite never drops them.
public struct MCPOAuthTokenResponse: Sendable, Equatable, Hashable, Codable {
    public var accessToken: String
    public var tokenType: String
    public var expiresIn: UInt64?
    public var refreshToken: String?
    /// Space-delimited scope string exactly as the server returned it.
    public var scope: String?
    /// Vendor-specific fields outside the standard OAuth response.
    public var extraFields: [String: JSONValue]

    public init(
        accessToken: String,
        tokenType: String = "bearer",
        expiresIn: UInt64? = nil,
        refreshToken: String? = nil,
        scope: String? = nil,
        extraFields: [String: JSONValue] = [:]
    ) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.expiresIn = expiresIn
        self.refreshToken = refreshToken
        self.scope = scope
        self.extraFields = extraFields
    }

    /// Scopes split on whitespace, mirroring oauth2's space-delimited codec.
    public var scopes: [String] {
        scope?.split(whereSeparator: \.isWhitespace).map(String.init) ?? []
    }

    private static let knownKeys: Set<String> = [
        "access_token", "token_type", "expires_in", "refresh_token", "scope",
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        accessToken = try c.decode(String.self, forKey: AnyCodingKey("access_token"))
        tokenType = try c.decode(String.self, forKey: AnyCodingKey("token_type"))
        // oauth2 accepts both a JSON number and a numeric string here.
        if let number = (try? c.decodeIfPresent(UInt64.self, forKey: AnyCodingKey("expires_in"))) ?? nil {
            expiresIn = number
        } else if let text = (try? c.decodeIfPresent(String.self, forKey: AnyCodingKey("expires_in"))) ?? nil {
            expiresIn = UInt64(text)
        } else {
            expiresIn = nil
        }
        refreshToken = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("refresh_token"))
        scope = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("scope"))
        var extras: [String: JSONValue] = [:]
        for key in c.allKeys where !Self.knownKeys.contains(key.stringValue) {
            extras[key.stringValue] = try c.decode(JSONValue.self, forKey: key)
        }
        extraFields = extras
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(accessToken, forKey: AnyCodingKey("access_token"))
        try c.encode(tokenType, forKey: AnyCodingKey("token_type"))
        try c.encodeIfPresent(expiresIn, forKey: AnyCodingKey("expires_in"))
        try c.encodeIfPresent(refreshToken, forKey: AnyCodingKey("refresh_token"))
        try c.encodeIfPresent(scope, forKey: AnyCodingKey("scope"))
        for (key, value) in extraFields {
            try c.encode(value, forKey: AnyCodingKey(key))
        }
    }
}

// MARK: - Stored credentials (rmcp StoredCredentials)

/// One server's persisted OAuth state (rmcp auth.rs:188-197).
public struct MCPStoredCredentials: Sendable, Equatable, Hashable, Codable {
    public var clientId: String
    public var tokenResponse: MCPOAuthTokenResponse?
    /// Scopes actually granted at the last exchange (`#[serde(default)]`).
    public var grantedScopes: [String]
    /// Epoch seconds of the last token receipt (`#[serde(default)]`); drives
    /// both the expiry check and the stale-save freshness guard.
    public var tokenReceivedAt: UInt64?

    public init(
        clientId: String,
        tokenResponse: MCPOAuthTokenResponse? = nil,
        grantedScopes: [String] = [],
        tokenReceivedAt: UInt64? = nil
    ) {
        self.clientId = clientId
        self.tokenResponse = tokenResponse
        self.grantedScopes = grantedScopes
        self.tokenReceivedAt = tokenReceivedAt
    }

    private enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case tokenResponse = "token_response"
        case grantedScopes = "granted_scopes"
        case tokenReceivedAt = "token_received_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clientId = try c.decode(String.self, forKey: .clientId)
        tokenResponse = try c.decodeIfPresent(MCPOAuthTokenResponse.self, forKey: .tokenResponse)
        grantedScopes = try c.decodeIfPresent([String].self, forKey: .grantedScopes) ?? []
        tokenReceivedAt = try c.decodeIfPresent(UInt64.self, forKey: .tokenReceivedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clientId, forKey: .clientId)
        // Rust serializes `token_response: null` for entries without tokens
        // (no skip attribute on the Option); match it so the legacy fixture's
        // `"token_response": null` round-trips byte-compatibly.
        if let tokenResponse {
            try c.encode(tokenResponse, forKey: .tokenResponse)
        } else {
            try c.encodeNil(forKey: .tokenResponse)
        }
        try c.encode(grantedScopes, forKey: .grantedScopes)
        // Same explicit-null rationale as `token_response`: rmcp's derive has
        // no skip attribute on this Option (auth.rs:195-196).
        if let tokenReceivedAt {
            try c.encode(tokenReceivedAt, forKey: .tokenReceivedAt)
        } else {
            try c.encodeNil(forKey: .tokenReceivedAt)
        }
    }
}

/// `true` when the on-disk `existing` entry is strictly newer than `incoming`
/// by `token_received_at` (credentials.rs:326-337). Missing timestamps on
/// either side compare as "not newer" so expiry-less tokens keep writing.
func mcpDiskEntryIsNewer(
    existing: MCPStoredCredentials?,
    incoming: MCPStoredCredentials
) -> Bool {
    guard let existingAt = existing?.tokenReceivedAt,
          let incomingAt = incoming.tokenReceivedAt else {
        return false
    }
    return existingAt > incomingAt
}

// MARK: - Store

public enum MCPCredentialStoreError: Error, Sendable, CustomStringConvertible {
    case json(String)
    case io(String)
    case other(String)

    public var description: String {
        switch self {
        case .json(let detail): return "JSON error: \(detail)"
        case .io(let detail): return "I/O error: \(detail)"
        case .other(let detail): return detail
        }
    }
}

/// On-disk credential store: `$OPENGROK_HOME/mcp_credentials.json`
/// (credentials.rs:61-71). The file is a single JSON object whose keys are
/// `"{server_name}:{server_url}"` (the Rust `#[serde(flatten)] BTreeMap`).
public struct MCPCredentialStore: Sendable, Equatable {
    public var entries: [String: MCPStoredCredentials]

    public init(entries: [String: MCPStoredCredentials] = [:]) {
        self.entries = entries
    }

    /// File name inside `$OPENGROK_HOME` (credentials.rs:61).
    public static let credentialsFileName = "mcp_credentials.json"
    /// Cross-process lock beside the store. Rust derives it via
    /// `path.with_extension("lock")`, which REPLACES `.json` —
    /// `mcp_credentials.lock`, not `mcp_credentials.json.lock`
    /// (credentials.rs:133).
    public static let lockFileName = "mcp_credentials.lock"

    public static func defaultPath(home: URL) -> URL {
        home.appendingPathComponent(credentialsFileName)
    }

    static func lockPath(home: URL) -> URL {
        home.appendingPathComponent(lockFileName)
    }

    /// Composite entry key (credentials.rs:83-85). The URL side matches Rust
    /// `url::Url` Display for the shapes MCP configs use: lowercase scheme and
    /// host, default port dropped, and a bare authority gains the "/" path.
    public static func key(serverName: String, serverURL: URL) -> String {
        "\(serverName):\(canonicalURLString(serverURL))"
    }

    static func canonicalURLString(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if let port = components.port {
            let isDefault = (components.scheme == "https" && port == 443)
                || (components.scheme == "http" && port == 80)
            if isDefault { components.port = nil }
        }
        if components.path.isEmpty, components.host != nil {
            components.path = "/"
        }
        return components.string ?? url.absoluteString
    }

    // MARK: Load / save

    /// Load from a path. Missing file → empty store; a world-readable file is
    /// tightened to 0600 best-effort on load (credentials.rs:98-114); corrupt
    /// JSON throws (call sites that must survive corruption use
    /// ``loadOrEmpty(from:)``, mirroring the Rust `.unwrap_or_default()`).
    public static func load(from path: URL) throws -> MCPCredentialStore {
        guard FileManager.default.fileExists(atPath: path.path) else {
            return MCPCredentialStore()
        }
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw MCPCredentialStoreError.io(String(describing: error))
        }
        // Best-effort tighten: chmod failure must not block using tokens.
        try? SecureFile.ensureOwnerOnlyPermissions(at: path)
        do {
            let raw = try JSONDecoder().decode([String: MCPStoredCredentials].self, from: data)
            return MCPCredentialStore(entries: raw)
        } catch {
            throw MCPCredentialStoreError.json(String(describing: error))
        }
    }

    /// The `.unwrap_or_default()` load every adapter path uses
    /// (credentials.rs:383,400): corruption yields an empty store rather than
    /// blocking auth.
    public static func loadOrEmpty(from path: URL) -> MCPCredentialStore {
        (try? load(from: path)) ?? MCPCredentialStore()
    }

    /// Save atomically: owner-only temp file + rename, then a best-effort
    /// re-tighten after publish (credentials.rs:212-258). The temp file is
    /// 0600 from creation — no window where secrets are world-readable.
    public func save(to path: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(entries)
        } catch {
            throw MCPCredentialStoreError.json(String(describing: error))
        }
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try AtomicFile.write(path, data: data, options: .ownerOnly)
        } catch {
            throw MCPCredentialStoreError.io(String(describing: error))
        }
        // Best-effort after rename: the new tokens are already published.
        try? SecureFile.ensureOwnerOnlyPermissions(at: path)
    }

    // MARK: Entry access

    public func get(serverName: String, serverURL: URL) -> MCPStoredCredentials? {
        entries[Self.key(serverName: serverName, serverURL: serverURL)]
    }

    public mutating func insert(
        serverName: String, serverURL: URL, credentials: MCPStoredCredentials
    ) {
        entries[Self.key(serverName: serverName, serverURL: serverURL)] = credentials
    }

    public func hasCredentials(serverName: String, serverURL: URL) -> Bool {
        entries[Self.key(serverName: serverName, serverURL: serverURL)] != nil
    }

    public mutating func remove(serverName: String, serverURL: URL) {
        entries.removeValue(forKey: Self.key(serverName: serverName, serverURL: serverURL))
    }

    /// Remove all credentials for a server by name, any URL
    /// (credentials.rs:304-309). Returns the number removed.
    @discardableResult
    public mutating func removeByServerName(_ serverName: String) -> Int {
        let prefix = "\(serverName):"
        let before = entries.count
        entries = entries.filter { !$0.key.hasPrefix(prefix) }
        return before - entries.count
    }

    public var isEmpty: Bool { entries.isEmpty }

    // MARK: Locked read-modify-write

    /// Read-modify-write the store under the cross-process
    /// `mcp_credentials.lock` flock: reload from disk (merging concurrent
    /// writers), apply `mutate`, save atomically (credentials.rs:129-180).
    /// On lock failure, falls back to an unlocked load-mutate-save — the
    /// pre-lock behavior upstream also degrades to.
    @discardableResult
    public static func lockedMutate(
        home: URL,
        _ mutate: (inout MCPCredentialStore) -> Void
    ) throws -> MCPCredentialStore {
        let path = defaultPath(home: home)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let lock = try? AdvisoryFileLock.acquire(
            at: lockPath(home: home),
            options: AdvisoryLockOptions(nonBlocking: false, create: true, mode: 0o600)
        )
        defer { lock?.release() }

        // Reload under the lock so concurrent writers' entries merge instead
        // of being clobbered by a stale in-memory snapshot.
        var fresh = loadOrEmpty(from: path)
        mutate(&fresh)
        try fresh.save(to: path)
        return fresh
    }

    /// Locked insert with the freshness guard: skipped when the disk entry is
    /// strictly newer by `token_received_at` (credentials.rs:188-205) —
    /// otherwise a slow writer (canonically a refresh suspended across system
    /// sleep) rolls the stored refresh token back to a rotated-out value.
    @discardableResult
    public static func insertAndSave(
        home: URL,
        serverName: String,
        serverURL: URL,
        credentials: MCPStoredCredentials
    ) throws -> MCPCredentialStore {
        let key = key(serverName: serverName, serverURL: serverURL)
        return try lockedMutate(home: home) { store in
            if mcpDiskEntryIsNewer(existing: store.entries[key], incoming: credentials) {
                return
            }
            store.entries[key] = credentials
        }
    }

    /// Locked remove + persist (credentials.rs:296-301): an unlocked
    /// whole-file rewrite could drop other processes' concurrent writes for
    /// unrelated servers.
    @discardableResult
    public static func removeAndSave(
        home: URL,
        serverName: String,
        serverURL: URL
    ) throws -> MCPCredentialStore {
        let key = key(serverName: serverName, serverURL: serverURL)
        return try lockedMutate(home: home) { store in
            store.entries.removeValue(forKey: key)
        }
    }

    /// Locked removal of every credential entry for one server name, across
    /// URL changes. Returns the number removed and does not create an empty
    /// credential file when no store exists.
    @discardableResult
    public static func removeByServerNameAndSave(
        home: URL,
        serverName: String
    ) throws -> Int {
        let path = defaultPath(home: home)
        guard FileManager.default.fileExists(atPath: path.path) else { return 0 }
        var removed = 0
        _ = try lockedMutate(home: home) { store in
            removed = store.removeByServerName(serverName)
        }
        return removed
    }
}

// MARK: - Per-server storage adapter (credentials.rs:339-408)

/// Load/save/clear for one MCP server's credentials, the seam
/// `MCPAuthorizationManager` persists through (rmcp's `CredentialStore`
/// trait). Every operation goes through the real on-disk store so tokens
/// written by another process are observed on the next load.
public protocol MCPServerCredentialStorage: Sendable {
    func load() throws -> MCPStoredCredentials?
    func save(_ credentials: MCPStoredCredentials) throws
    func clear() throws
}

/// File-backed adapter scoped to a single server (name + URL), rooted at an
/// explicit home directory.
public struct MCPFileCredentialStorage: MCPServerCredentialStorage, Sendable {
    public let home: URL
    public let serverName: String
    public let serverURL: URL

    public init(home: URL, serverName: String, serverURL: URL) {
        self.home = home
        self.serverName = serverName
        self.serverURL = serverURL
    }

    public func load() throws -> MCPStoredCredentials? {
        MCPCredentialStore
            .loadOrEmpty(from: MCPCredentialStore.defaultPath(home: home))
            .get(serverName: serverName, serverURL: serverURL)
    }

    public func save(_ credentials: MCPStoredCredentials) throws {
        try MCPCredentialStore.insertAndSave(
            home: home,
            serverName: serverName,
            serverURL: serverURL,
            credentials: credentials
        )
    }

    public func clear() throws {
        try MCPCredentialStore.removeAndSave(
            home: home, serverName: serverName, serverURL: serverURL
        )
    }
}

/// In-memory storage for tests and non-persistent flows (rmcp
/// `InMemoryCredentialStore`, auth.rs:249-277).
public final class MCPInMemoryCredentialStorage: MCPServerCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: MCPStoredCredentials?

    public init(_ initial: MCPStoredCredentials? = nil) {
        self.credentials = initial
    }

    public func load() throws -> MCPStoredCredentials? {
        lock.lock(); defer { lock.unlock() }
        return credentials
    }

    public func save(_ credentials: MCPStoredCredentials) throws {
        lock.lock(); defer { lock.unlock() }
        self.credentials = credentials
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        credentials = nil
    }
}
