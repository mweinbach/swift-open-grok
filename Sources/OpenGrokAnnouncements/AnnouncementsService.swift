// AnnouncementsService.swift
//
// Fetching and caching announcements without blocking startup.
//
// The module already had the models, the hide-key state store, and the CTA and
// banner helpers, but nothing ever fetched a feed, so none of it ran. This adds
// the missing half.
//
// Two properties matter more than the feature itself:
//
//   * **Startup is never blocked.** The fetch runs detached and the cache is
//     what startup reads. A slow or unreachable feed must cost a user exactly
//     zero milliseconds of launch time, so nothing here is awaited on the
//     launch path.
//   * **The export boundary is checked before the request, not after.** The
//     feed rides xAI infrastructure. When the active provider denies xAI export
//     — a Codex session — the request is never made at all, because issuing it
//     would tell xAI that this session exists. A gate applied to the *response*
//     would be too late.

import Foundation
import OpenGrokHTTP
import OpenGrokSamplingTypes

// MARK: - Cache

/// The announcements feed as last seen, with the time it was fetched.
public struct AnnouncementsCache: Sendable, Equatable, Codable {
    public var gen: UInt64
    public var announcements: [RemoteAnnouncement]
    public var fetchedAt: Date

    public init(gen: UInt64, announcements: [RemoteAnnouncement], fetchedAt: Date) {
        self.gen = gen
        self.announcements = announcements
        self.fetchedAt = fetchedAt
    }

    public func isFresh(at now: Date, ttl: TimeInterval) -> Bool {
        // A future timestamp means a clock change; treat it as stale rather
        // than trusting it and never refreshing again.
        guard fetchedAt <= now else { return false }
        return now.timeIntervalSince(fetchedAt) < ttl
    }
}

/// Reads and writes the announcements cache under `OPENGROK_HOME`.
public struct AnnouncementsCacheStore: Sendable {
    public static let fileName = "announcements-cache.json"

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public init(openGrokHome: URL) {
        self.fileURL = openGrokHome.appendingPathComponent(Self.fileName)
    }

    public func read() -> AnnouncementsCache? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AnnouncementsCache.self, from: data)
    }

    public func write(_ cache: AnnouncementsCache) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(cache) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Write-then-rename so a crash mid-write cannot leave a truncated cache
        // that would be silently discarded on every later launch.
        let temporary = fileURL.appendingPathExtension("tmp")
        guard (try? data.write(to: temporary, options: .atomic)) != nil else { return }
        _ = try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.moveItem(at: temporary, to: fileURL)
    }
}

// MARK: - Service

public struct AnnouncementsService: Sendable {
    public static let defaultTTL: TimeInterval = 60 * 60
    /// The settings endpoint the feed rides on, relative to the chat proxy.
    public static let settingsPath = "/v1/settings"

    public let transport: any HTTPTransport
    public let store: AnnouncementsCacheStore
    public let stateStore: AnnouncementStateStore
    public let ttl: TimeInterval

    public init(
        transport: any HTTPTransport,
        store: AnnouncementsCacheStore,
        stateStore: AnnouncementStateStore,
        ttl: TimeInterval = AnnouncementsService.defaultTTL
    ) {
        self.transport = transport
        self.store = store
        self.stateStore = stateStore
        self.ttl = ttl
    }

    /// What startup should render, read entirely from cache.
    ///
    /// Synchronous and local by construction: this is the launch path.
    public func cachedStartupAnnouncements(
        hiddenIDs: Set<String>,
        now: Date = Date()
    ) -> [RemoteAnnouncement] {
        guard let cache = store.read() else { return [] }
        let live = filterExpiredAt(cache.announcements, now: now)
        return visibleAnnouncements(live).filter { !hiddenIDs.contains(announcementHideKey($0)) }
    }

    /// Kick off a background refresh if the cache is stale and the export
    /// boundary permits it. Returns immediately.
    ///
    /// - Parameter exportPolicy: the active provider's xAI export policy. When
    ///   `.denied`, no request is issued.
    public func refreshInBackground(
        baseURL: URL,
        exportPolicy: XaiServicePolicy,
        authorization: String?,
        now: Date = Date()
    ) {
        guard shouldRefresh(exportPolicy: exportPolicy, now: now) else { return }
        Task.detached(priority: .background) {
            _ = try? await self.refresh(
                baseURL: baseURL,
                exportPolicy: exportPolicy,
                authorization: authorization,
                now: now
            )
        }
    }

    /// Whether a refresh is permitted and due.
    public func shouldRefresh(exportPolicy: XaiServicePolicy, now: Date = Date()) -> Bool {
        // The boundary is checked first, before freshness: a denied provider
        // must not even consult the cache clock to decide whether to call out.
        guard exportPolicy.allows else { return false }
        guard let cache = store.read() else { return true }
        return !cache.isFresh(at: now, ttl: ttl)
    }

    /// Fetch the feed and update the cache. Throws only on transport failure;
    /// callers on the launch path should discard the error.
    @discardableResult
    public func refresh(
        baseURL: URL,
        exportPolicy: XaiServicePolicy,
        authorization: String?,
        now: Date = Date()
    ) async throws -> AnnouncementsCache? {
        guard exportPolicy.allows else { return nil }

        var headers = ["Accept": "application/json"]
        if let authorization { headers["Authorization"] = authorization }
        let request = HTTPRequest(
            method: .get,
            url: baseURL.appendingPathComponent(Self.settingsPath.trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )),
            headers: headers,
            timeout: 10
        )
        let response = try await transport.send(request)
        guard (200..<300).contains(response.metadata.statusCode) else { return nil }
        guard let refreshed = try? JSONDecoder().decode(
            AnnouncementsRefreshed.self,
            from: response.body
        ) else { return nil }

        let cache = AnnouncementsCache(
            gen: refreshed.gen,
            announcements: refreshed.announcements,
            fetchedAt: now
        )
        store.write(cache)

        // Drop hide-keys for announcements that no longer exist, so the state
        // file cannot grow without bound across releases.
        let live = Set(refreshed.announcements.map(announcementHideKey))
        let hidden = await stateStore.read()
        let pruned = hidden.intersection(live)
        if pruned != hidden { await stateStore.write(pruned) }

        return cache
    }

    /// Apply a pushed `x.ai/announcements/update` notification.
    ///
    /// A push is only accepted when its generation is at least the cached one,
    /// so a delayed or replayed notification cannot roll the feed backwards.
    @discardableResult
    public func applyPush(
        _ refreshed: AnnouncementsRefreshed,
        now: Date = Date()
    ) -> AnnouncementsCache? {
        if let existing = store.read(), refreshed.gen < existing.gen { return nil }
        let cache = AnnouncementsCache(
            gen: refreshed.gen,
            announcements: refreshed.announcements,
            fetchedAt: now
        )
        store.write(cache)
        return cache
    }
}
