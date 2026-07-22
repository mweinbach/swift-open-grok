// ModelsCache.swift
//
// xAI models disk cache (`$OPENGROK_HOME/models_cache.json`).
//
// Cache keys: grok_version + auth_method + origin URL + TTL.
// A foreign-origin cache is always a miss so absolute base_urls cannot
// silently re-point inference. Codex uses `codex_models_cache.json` instead.

import Foundation
import OpenGrokPaths
import OpenGrokVersion

public let MODELS_CACHE_FILE = "models_cache.json"
public let MODELS_CACHE_TTL_SECONDS: TimeInterval = 300

/// Credential shape that produced a cached xAI catalog.
public enum CacheAuthMethod: String, Codable, Sendable, Equatable, Hashable {
    case session
    case apiKey = "api_key"
    case deployment
}

/// How to resolve the model list.
public enum RefreshStrategy: String, Sendable, Equatable, Hashable {
    /// Always fetch from network, ignore cache.
    case online
    /// Only use cached data, never fetch.
    case offline
    /// Use cache if fresh, otherwise fetch.
    case onlineIfUncached
}

/// On-disk xAI models cache document.
public struct ModelsCacheDocument: Sendable, Equatable, Codable {
    public var fetchedAt: Date
    public var grokVersion: String?
    public var authMethod: CacheAuthMethod?
    /// Models-list URL this catalog was fetched from.
    public var origin: String?
    public var etag: String?
    /// Catalog keyed by id; encoded as a JSON object (order not preserved on
    /// disk — restored as Dictionary iteration order on load).
    public var models: [String: ModelEntry]

    public init(
        fetchedAt: Date,
        grokVersion: String?,
        authMethod: CacheAuthMethod?,
        origin: String?,
        etag: String?,
        models: [String: ModelEntry]
    ) {
        self.fetchedAt = fetchedAt
        self.grokVersion = grokVersion
        self.authMethod = authMethod
        self.origin = origin
        self.etag = etag
        self.models = models
    }

    public enum CodingKeys: String, CodingKey {
        case fetchedAt = "fetched_at"
        case grokVersion = "grok_version"
        case authMethod = "auth_method"
        case origin, etag, models
    }

    public func isFresh(ttl: TimeInterval, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        return age >= 0 && age < ttl
    }
}

public struct CacheLoadResult: Sendable, Equatable {
    public var models: OrderedModelMap
    public var etag: String?

    public init(models: OrderedModelMap, etag: String?) {
        self.models = models
        self.etag = etag
    }
}

/// Manages the xAI `models_cache.json` file.
public struct ModelsCacheManager: Sendable {
    public let path: URL
    public let ttl: TimeInterval
    public let versionProvider: @Sendable () -> String

    public init(
        grokHome: URL,
        ttl: TimeInterval = MODELS_CACHE_TTL_SECONDS,
        versionProvider: @escaping @Sendable () -> String = { OpenGrokVersion.installed() }
    ) {
        self.path = grokHome.appendingPathComponent(MODELS_CACHE_FILE)
        self.ttl = ttl
        self.versionProvider = versionProvider
    }

    /// Convenience: resolve `$OPENGROK_HOME` from the process environment.
    public static func inDefaultHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ModelsCacheManager {
        ModelsCacheManager(grokHome: OpenGrokStatePaths.stateDirectory(environment: environment))
    }

    public func loadFresh(
        expectedAuth: CacheAuthMethod,
        expectedOrigin: String,
        now: Date = Date()
    ) -> CacheLoadResult? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let cache = try? decoder.decode(ModelsCacheDocument.self, from: data) else {
            return nil
        }
        if cache.grokVersion != versionProvider() { return nil }
        if cache.authMethod != expectedAuth { return nil }
        if cache.origin != expectedOrigin { return nil }
        if !cache.isFresh(ttl: ttl, now: now) { return nil }

        var map = OrderedModelMap()
        // Stable order by key for determinism after unordered JSON object load.
        for key in cache.models.keys.sorted() {
            if let entry = cache.models[key] {
                map[key] = entry
            }
        }
        return CacheLoadResult(models: map, etag: cache.etag)
    }

    /// Load without freshness/auth checks (for offline inspection / tests).
    public func loadRaw() throws -> ModelsCacheDocument {
        let data = try Data(contentsOf: path)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(ModelsCacheDocument.self, from: data)
        } catch {
            throw ModelsError.cacheCorrupt(String(describing: error))
        }
    }

    public func persist(
        models: OrderedModelMap,
        etag: String?,
        authMethod: CacheAuthMethod,
        origin: String,
        now: Date = Date()
    ) throws {
        var dict: [String: ModelEntry] = [:]
        for (key, entry) in models.pairs() {
            dict[key] = entry
        }
        let doc = ModelsCacheDocument(
            fetchedAt: now,
            grokVersion: versionProvider(),
            authMethod: authMethod,
            origin: origin,
            etag: etag,
            models: dict
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(doc)
        try writeAtomicallyData(path, contents: data)
    }

    public func renewTTL(
        expectedAuth: CacheAuthMethod,
        expectedOrigin: String,
        now: Date = Date()
    ) throws {
        var doc = try loadRaw()
        guard doc.authMethod == expectedAuth, doc.origin == expectedOrigin else { return }
        doc.fetchedAt = now
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(doc)
        try writeAtomicallyData(path, contents: data)
    }

    public func invalidate() {
        try? FileManager.default.removeItem(at: path)
    }
}

// MARK: - Prefetch map

/// Build a prefetched model map from a flat list of config entries.
/// Keyed by `id` (falling back to `model` slug).
public func buildPrefetchedMap(
    models: [ModelEntryConfig],
    apiBaseURLOverride: String? = nil
) -> OrderedModelMap {
    var map = OrderedModelMap()
    map.reserveCapacity(models.count)
    for m in models {
        let key = m.id ?? m.model
        let info = ModelInfo.fromConfig(m)
        let entry = ModelEntry(
            info: info,
            apiKey: nil,
            envKey: nil,
            apiBaseURL: m.apiBaseURL ?? apiBaseURLOverride
        )
        map[key] = entry
    }
    return map
}
