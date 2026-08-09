// Changelog.swift
//
// Changelog fetching from CDN with local disk cache — the faithful port of
// `xai-grok-shell-base/src/util/changelog.rs` at the pin.
//
// Both markdown (`*.external.md`) and JSON (`*.external.json`) changelogs
// are published per-version to the CDN at `x.ai/cli/changelogs/`.
//
// `ChangelogManager.fetch()` retrieves both formats in parallel and returns
// a `Changelog` with optional markdown + structured entries. Consumers pick
// the format they need:
// - `/release-notes` uses `changelog.markdown` for the document overlay
// - the welcome screen uses `changelog.entries` for bullet rendering
//   (that consumer is Wave 18 B2 territory and is NOT wired yet — see
//   `bulletsFromEntries`)
//
// ONE deliberate divergence from upstream, recorded in PORT_STATUS.md
// (Wave 18 B9): the CDN fetch is gated on the xAI export boundary
// (`XaiServicePolicy`), the same gate `LiveAnnouncementsComposition` takes.
// The changelog rides xAI infrastructure; when the active provider denies
// xAI export — a Codex session — the request is never made at all, because
// issuing it would tell xAI that this session exists. Upstream's changelog
// fetch does NOT carry this gate. Cost: a Codex-only session shows release
// notes only from the disk cache (a previous xAI session's fetch), and shows
// the offline error copy when no cache exists.

import Foundation
import OpenGrokHTTP
import OpenGrokPaths
import OpenGrokSamplingTypes
import OpenGrokVersion

// MARK: - Entry / payload types

/// A single structured changelog entry from the published JSON changelog.
///
/// Shape must match the output of `render_external_json` in upstream's
/// `changelog.sh`: `{category, description, breaking_change}`
/// (`changelog.rs:19-38`).
///
/// All fields decode with serde's `#[serde(default)]` semantics — a missing
/// field becomes its default rather than killing the entire array parse.
/// Entries with an empty description are filtered out by
/// `bulletsFromEntries`. (A wrong-TYPED field still fails the whole parse,
/// exactly as serde's per-field `default` does.)
public struct ChangelogEntry: Sendable, Equatable, Decodable {
    /// Category label (e.g. "features", "fixes", "breaking", "performance").
    public var category: String
    /// Human-readable description (may contain `**bold**` or backticks).
    public var description: String
    /// Whether this entry represents a breaking change.
    public var breakingChange: Bool

    enum CodingKeys: String, CodingKey {
        case category
        case description
        case breakingChange = "breaking_change"
    }

    public init(category: String = "", description: String = "", breakingChange: Bool = false) {
        self.category = category
        self.description = description
        self.breakingChange = breakingChange
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        breakingChange = try container.decodeIfPresent(Bool.self, forKey: .breakingChange) ?? false
    }
}

/// Both formats of a version's changelog, fetched together
/// (`changelog.rs:41-47`).
public struct Changelog: Sendable {
    /// Rendered markdown (for `/release-notes` display).
    public var markdown: String?
    /// Structured entries (for welcome screen bullets).
    public var entries: [ChangelogEntry]?

    public init(markdown: String? = nil, entries: [ChangelogEntry]? = nil) {
        self.markdown = markdown
        self.entries = entries
    }
}

// MARK: - Manager

/// Manages changelog retrieval from CDN with local disk caching
/// (`changelog.rs:49-56`).
///
/// Single entry point: `fetch(environment:)` returns both markdown and JSON
/// in one `Changelog`. Each format is fetched independently with its own
/// cache file, so a failure in one doesn't block the other.
public struct ChangelogManager: Sendable {
    /// CDN base for all changelogs (proxies to GCS, cache-friendly)
    /// (`changelog.rs:15`).
    public static let changelogBase = "https://x.ai/cli/changelogs"
    /// `FETCH_TIMEOUT` (`changelog.rs:16`).
    public static let fetchTimeout: TimeInterval = 3
    public static let markdownCacheFileName = "CHANGELOG.md"
    public static let jsonCacheFileName = "CHANGELOG.json"

    public let mdCache: URL
    public let jsonCache: URL
    /// `nil` in compositions without a live transport (headless launches):
    /// the fetch degrades to cache-only, upstream's offline arm.
    public let transport: (any HTTPTransport)?
    /// The active provider's xAI export policy — the recorded
    /// stricter-than-upstream gate (see the header comment).
    public let exportPolicy: XaiServicePolicy

    /// Cache paths direct — upstream's test seam `manager_for(home)`
    /// (`changelog.rs` tests) and the building block of `fromEnvironment`.
    public init(
        mdCache: URL,
        jsonCache: URL,
        transport: (any HTTPTransport)? = nil,
        exportPolicy: XaiServicePolicy = .denied
    ) {
        self.mdCache = mdCache
        self.jsonCache = jsonCache
        self.transport = transport
        self.exportPolicy = exportPolicy
    }

    /// Resolve cache paths from the given environment — upstream's
    /// `from_env_home` (`changelog.rs:74-86`): `$OPENGROK_HOME` wins when set
    /// and non-empty, else the `~/.opengrok` fallback
    /// (`OpenGrokStatePaths.stateDirectory` is that exact rule).
    public static func fromEnvironment(
        _ environment: [String: String],
        transport: (any HTTPTransport)? = nil,
        exportPolicy: XaiServicePolicy = .denied
    ) -> ChangelogManager {
        let home = OpenGrokStatePaths.stateDirectory(environment: environment)
        return ChangelogManager(
            mdCache: home.appendingPathComponent(Self.markdownCacheFileName),
            jsonCache: home.appendingPathComponent(Self.jsonCacheFileName),
            transport: transport,
            exportPolicy: exportPolicy
        )
    }

    /// Fetch both markdown and JSON changelogs for the compiled version
    /// (`OpenGrokVersion.compiledVersion`, the analog of
    /// `xai_grok_version::VERSION`).
    ///
    /// Each format is fetched independently (CDN, 3 s timeout) and cached to
    /// disk. On failure, falls back to the cached copy. Either field may be
    /// `nil` if offline with no cache.
    ///
    /// When `GROK_CHANGELOG_OFFLINE` is set (PTY / integration tests), skip
    /// the CDN entirely and read only the disk cache so seeded fixtures win
    /// deterministically without network races.
    ///
    /// Cache paths are re-resolved from `environment` on EVERY call —
    /// upstream's `fetch` re-runs `from_env_home` so a harness-injected
    /// `$OPENGROK_HOME` always wins over paths this manager resolved earlier
    /// (`changelog.rs:100-104`). The caller passes its audited session
    /// environment, this port's standing rule (process-global reads are the
    /// silent-divergence footgun, AGENTS.md §2) — for the running executable
    /// that dictionary IS the live process environment.
    ///
    /// JSON is only cached after a successful parse to avoid poisoning the
    /// disk cache with malformed content (the markdown cache is
    /// write-through since it's consumed as raw text) (`changelog.rs:96-98`).
    public func fetch(environment: [String: String]) async -> Changelog {
        await Self.fromEnvironment(
            environment,
            transport: transport,
            exportPolicy: exportPolicy
        ).fetchWith(
            offline: Self.changelogOffline(environment: environment),
            base: Self.changelogBase
        )
    }

    /// Fetch using this manager's already-resolved cache paths, an explicit
    /// offline flag, and an explicit CDN base (`changelog.rs:107-152`).
    ///
    /// Split out of `fetch` so unit tests can drive it against a temp home
    /// without mutating process-global env (`OPENGROK_HOME` /
    /// `GROK_CHANGELOG_OFFLINE`), which races across the parallel test
    /// harness. Passing an unreachable `base` lets a test force a
    /// deterministic CDN miss instead of depending on whether the sandbox
    /// happens to block network. Production callers always go through
    /// `fetch`, so behaviour is unchanged.
    func fetchWith(offline: Bool, base: String) async -> Changelog {
        if offline {
            return Changelog(
                markdown: Self.readCache(mdCache),
                entries: readJSONCache()
            )
        }

        // The export boundary, checked BEFORE any request is built — the
        // `AnnouncementsService.refresh` gate order ("a denied provider must
        // not even consult the cache clock to decide whether to call out").
        // Denied degrades to the cache-only read, upstream's offline arm.
        // A composition without a transport takes the same arm: there is
        // nothing to fetch with.
        guard exportPolicy.allows, let transport else {
            return Changelog(
                markdown: Self.readCache(mdCache),
                entries: readJSONCache()
            )
        }

        let version = OpenGrokVersion.compiledVersion
        let mdURL = "\(base)/\(version).external.md"

        // Fetch both formats in parallel (3 s timeout each → 3 s total, not
        // 6 s) — upstream's `std::thread::scope` pair (`changelog.rs:126-133`).
        async let markdownTask = fetchAndCache(
            urlString: mdURL,
            cachePath: mdCache,
            transport: transport
        )
        async let entriesTask = fetchJSON(base: base, version: version, transport: transport)
        var markdown = await markdownTask
        var entries = await entriesTask

        // If the CDN is unreachable (CI sandboxes, airplane mode), fall back
        // to any on-disk seed under `$OPENGROK_HOME` even when offline mode
        // was not explicitly requested — keeps PTY/integration tests
        // deterministic (`changelog.rs:135-144`).
        if markdown == nil {
            markdown = Self.readCache(mdCache)
        }
        if entries == nil {
            entries = readJSONCache()
        }

        return Changelog(markdown: markdown, entries: entries)
    }

    /// Fetch and parse the JSON changelog, caching ONLY after a successful
    /// parse (`changelog.rs:155-176`) — a malformed CDN response must not
    /// poison the disk cache that every later offline launch reads.
    func fetchJSON(
        base: String,
        version: String,
        transport: any HTTPTransport
    ) async -> [ChangelogEntry]? {
        let url = "\(base)/\(version).external.json"

        if let raw = await Self.fetchString(urlString: url, transport: transport),
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let data = raw.data(using: .utf8) {
            if let entries = try? JSONDecoder().decode([ChangelogEntry].self, from: data) {
                // Cache-write failures are swallowed like the announcements
                // store's: the fetched entries are still returned, the next
                // fetch retries the write.
                try? Data(raw.utf8).write(to: jsonCache)
                return entries
            }
            // Parse failed: fall through to the cached copy, cache untouched.
        }

        return readJSONCache()
    }

    func readJSONCache() -> [ChangelogEntry]? {
        guard let cached = Self.readCache(jsonCache),
              let data = cached.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([ChangelogEntry].self, from: data)
    }

    /// Shared fetch-and-cache: try remote (3 s timeout), cache on success
    /// (write-through — consumed as raw text), fall back to the disk cache
    /// on failure (`changelog.rs:179-192`).
    func fetchAndCache(
        urlString: String,
        cachePath: URL,
        transport: any HTTPTransport
    ) async -> String? {
        if let content = await Self.fetchString(urlString: urlString, transport: transport),
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? Data(content.utf8).write(to: cachePath)
            return content
        }
        return Self.readCache(cachePath)
    }

    /// When set, `fetch` skips the CDN and only reads the disk cache. Used
    /// by harness tests that seed `CHANGELOG.{md,json}` under a temp home
    /// (`changelog.rs:196-198`: non-empty and not `"0"`).
    static func changelogOffline(environment: [String: String]) -> Bool {
        guard let value = environment["GROK_CHANGELOG_OFFLINE"] else { return false }
        return !value.isEmpty && value != "0"
    }

    static func readCache(_ path: URL) -> String? {
        guard let content = try? String(contentsOf: path, encoding: .utf8),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return content
    }

    /// The blocking-HTTP analog (`fetch_blocking`, `changelog.rs:225-236`):
    /// one GET with the 3 s timeout, success (2xx) required, body as UTF-8.
    static func fetchString(
        urlString: String,
        transport: any HTTPTransport
    ) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        let request = HTTPRequest(method: .get, url: url, timeout: fetchTimeout)
        guard let response = try? await transport.send(request),
              (200..<300).contains(response.metadata.statusCode) else {
            return nil
        }
        return String(data: response.body, encoding: .utf8)
    }
}

// MARK: - Welcome-screen bullets (consumer deferred)

/// Strip `**bold**` markers and backticks from a description string
/// (`changelog.rs:206-208`).
func stripMarkdownInline(_ s: String) -> String {
    s.replacingOccurrences(of: "**", with: "")
        .replacingOccurrences(of: "`", with: "")
}

/// Convert changelog entries to plain-text bullet strings
/// (`changelog.rs:210-223`): strips `**bold**` and backtick formatting from
/// each description, skips entries with empty descriptions (from tolerant
/// deserialization), and returns at most `max` entries.
///
/// NOT an advertised surface yet: upstream's consumer is the welcome
/// screen's bullet list, which this port's welcome overlay has no slot for —
/// Wave 18 B2 territory, deferred in the ledger. Ported now because it is
/// part of this file and its unit tests; wiring it early would invent UX the
/// port's welcome screen does not have.
public func bulletsFromEntries(_ entries: [ChangelogEntry], max: Int) -> [String] {
    entries
        .filter { !$0.description.isEmpty }
        .prefix(max)
        .map { stripMarkdownInline($0.description) }
}
