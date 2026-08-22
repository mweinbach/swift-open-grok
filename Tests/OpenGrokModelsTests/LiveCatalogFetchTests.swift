// LiveCatalogFetchTests.swift
//
// Live model-catalog fetching: request shapes, cache identity/TTL/ETag,
// partition isolation, and merge order.
//
// Golden fixtures under `Fixtures/catalog/` are hand-derived from the Rust
// suites at pin 9ed09e2a; each test names its provenance.

import Foundation
import Testing
@testable import OpenGrokModels
import OpenGrokConfigTypes
import OpenGrokSamplingTypes

// MARK: - Harness

private func fixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/catalog/\(name)")
    return try Data(contentsOf: url)
}

/// Records every request and replays canned responses keyed by URL prefix.
private actor MockCatalogTransport: ModelCatalogTransport {
    struct Canned: Sendable {
        var responses: [ModelCatalogResponse]
    }

    private var routes: [String: Canned] = [:]
    private(set) var requests: [ModelCatalogRequest] = []

    init() {}

    func route(matching needle: String, responses: [ModelCatalogResponse]) {
        routes[needle] = Canned(responses: responses)
    }

    func recordedRequests() -> [ModelCatalogRequest] { requests }

    func send(
        _ request: ModelCatalogRequest,
        cancellation: CancellationToken?
    ) async throws -> ModelCatalogResponse {
        try cancellation?.throwIfCancelled()
        requests.append(request)
        for (needle, canned) in routes where request.url.contains(needle) {
            guard !canned.responses.isEmpty else { break }
            var remaining = canned.responses
            let next = remaining.removeFirst()
            // Last response repeats, so a cache-hit test can assert the
            // request count rather than exhausting the queue.
            if !remaining.isEmpty {
                routes[needle] = Canned(responses: remaining)
            }
            return next
        }
        return ModelCatalogResponse(status: 404, body: Data("no route".utf8))
    }
}

private func ok(_ body: Data, etag: String? = nil) -> ModelCatalogResponse {
    var headers: [ModelCatalogHeader] = []
    if let etag { headers.append(ModelCatalogHeader("ETag", etag)) }
    return ModelCatalogResponse(status: 200, headers: headers, body: body)
}

/// Vends per-partition credentials and records which partitions were asked
/// for. The recording is how partition isolation is proven: a Codex refresh
/// must never appear as a request for any other partition.
private actor RecordingCredentialBroker: ModelCatalogCredentialBroker {
    private var apiKeys: [ModelCatalogPartition: ProviderCatalogCredential] = [:]
    private var codex: CodexCatalogCredential?
    private(set) var askedPartitions: [ModelCatalogPartition] = []
    private(set) var askedCodex = 0
    private(set) var forcedCodexRefreshes = 0

    init() {}

    func setKey(_ partition: ModelCatalogPartition, apiKey: String, fingerprint: String) {
        apiKeys[partition] = ProviderCatalogCredential(apiKey: apiKey, fingerprint: fingerprint)
    }

    func setCodex(_ credential: CodexCatalogCredential?) {
        codex = credential
    }

    func asked() -> [ModelCatalogPartition] { askedPartitions }
    func codexAsks() -> Int { askedCodex }
    func forcedRefreshes() -> Int { forcedCodexRefreshes }

    func credential(for partition: ModelCatalogPartition) async -> ProviderCatalogCredential? {
        askedPartitions.append(partition)
        return apiKeys[partition]
    }

    func codexCredential(forceRefresh: Bool) async -> CodexCatalogCredential? {
        askedCodex += 1
        if forceRefresh { forcedCodexRefreshes += 1 }
        return codex
    }
}

private func tempHome() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("opengrok-catalog-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func codexCache(
    home: URL,
    ttl: TimeInterval = CodexModels.cacheTTLSeconds
) -> CodexModelsCacheManager {
    CodexModelsCacheManager(
        grokHome: home,
        ttl: ttl,
        versionProvider: { "test-version" },
        clientVersionProvider: { CodexModels.defaultClientVersion },
        baseURLProvider: { CodexModels.defaultInferenceBaseURL }
    )
}

private let testCodexCredential = CodexCatalogCredential(
    accessToken: "codex-access-token",
    accountID: "acct-123",
    accountIsFedramp: false,
    fingerprint: "fp-account-a"
)

// MARK: - Codex request shape

@Suite("Codex catalog request")
struct CodexCatalogRequestTests {
    /// Provenance: Rust `models_url` (`codex_models.rs:722-729`) and the header
    /// block at `codex_models.rs:487-515`, asserted upstream at 1172-1192.
    @Test("URL carries client_version and headers match codex-rs exactly")
    func requestShape() async throws {
        let home = try tempHome()
        let transport = MockCatalogTransport()
        await transport.route(
            matching: "/models",
            responses: [ok(try fixture("codex_models.json"), etag: "live-etag")]
        )
        let broker = RecordingCredentialBroker()
        await broker.setCodex(testCodexCredential)

        let actor = CodexCatalogActor(
            transport: transport,
            cache: codexCache(home: home),
            credentialSource: { await broker.codexCredential(forceRefresh: $0) },
            clientVersion: "0.144.5",
            openGrokVersion: "test-version"
        )
        _ = try await actor.fetchAndCache()

        let requests = await transport.recordedRequests()
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.method == "GET")
        #expect(
            request.url
                == "https://chatgpt.com/backend-api/codex/models?client_version=0.144.5"
        )
        #expect(request.timeout == 5)

        // Order is upstream's emission order.
        #expect(request.headers.map(\.name) == [
            "Authorization", "originator", "User-Agent", "version", "ChatGPT-Account-ID",
        ])
        #expect(request.headerValue("Authorization") == "Bearer codex-access-token")
        #expect(request.headerValue("originator") == "codex_cli_rs")
        #expect(request.headerValue("User-Agent") == "codex_cli_rs/0.144.5")
        #expect(request.headerValue("version") == "0.144.5")
        #expect(request.headerValue("ChatGPT-Account-ID") == "acct-123")
        // Not a fedramp account, so the header is absent entirely.
        #expect(request.headerValue("X-OpenAI-Fedramp") == nil)
    }

    /// Upstream never sends a conditional request: a repo-wide search for
    /// `If-None-Match` across the Rust crates finds nothing, and the ETag is
    /// only recorded through the cache. Pinned so adding one is a deliberate act.
    @Test("no conditional revalidation header by default")
    func noIfNoneMatchByDefault() async throws {
        let home = try tempHome()
        let transport = MockCatalogTransport()
        await transport.route(
            matching: "/models",
            responses: [ok(try fixture("codex_models.json"), etag: "live-etag")]
        )
        let broker = RecordingCredentialBroker()
        await broker.setCodex(testCodexCredential)
        let cache = codexCache(home: home)

        let actor = CodexCatalogActor(
            transport: transport,
            cache: cache,
            credentialSource: { await broker.codexCredential(forceRefresh: $0) },
            clientVersion: "0.144.5",
            openGrokVersion: "test-version"
        )
        _ = try await actor.fetchAndCache()
        // Second fetch: a cached ETag now exists and still must not be sent.
        _ = try await actor.fetchAndCache()

        let requests = await transport.recordedRequests()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.headerValue("If-None-Match") == nil })
    }

    @Test("fedramp accounts add X-OpenAI-Fedramp")
    func fedrampHeader() async throws {
        let home = try tempHome()
        let transport = MockCatalogTransport()
        await transport.route(
            matching: "/models",
            responses: [ok(try fixture("codex_models.json"))]
        )
        let broker = RecordingCredentialBroker()
        await broker.setCodex(
            CodexCatalogCredential(
                accessToken: "t",
                accountID: nil,
                accountIsFedramp: true,
                fingerprint: "fp"
            )
        )
        let actor = CodexCatalogActor(
            transport: transport,
            cache: codexCache(home: home),
            credentialSource: { await broker.codexCredential(forceRefresh: $0) },
            openGrokVersion: "test-version"
        )
        _ = try await actor.fetchAndCache()

        let request = try #require(await transport.recordedRequests().first)
        #expect(request.headerValue("X-OpenAI-Fedramp") == "true")
        // No account id configured, so that header is omitted.
        #expect(request.headerValue("ChatGPT-Account-ID") == nil)
    }
}

// MARK: - Golden parses

@Suite("Provider catalog golden fixtures")
struct CatalogGoldenFixtureTests {
    /// Provenance: the fixture body and expectations are the Rust test at
    /// `codex_models.rs:980-1028` with assertions at 1194-1226.
    @Test("Codex golden response drops unknown tool modes and scales context")
    func codexGolden() throws {
        let models = try parseCodexModelsResponse(try fixture("codex_models.json"))
        // `unknown-tool-mode` fails closed and is dropped; two remain.
        #expect(models.count == 2)
        #expect(models.map(\.slug) == ["gpt-5.6-sol", "hidden-model"])

        let live = try #require(models.first)
        // 372000 * 95 / 100.
        #expect(live.entry.info.contextWindow == 353_400)
        #expect(live.autoCompactTokenLimit == 300_123)
        #expect(live.compHash == "comp-v3")
        #expect(live.entry.info.apiBackend == .responses)
        #expect(live.entry.info.agentType == "codex")
        #expect(live.entry.info.provider == .codex)
        #expect(live.entry.info.toolMode == .codeModeOnly)
        #expect(live.entry.info.codexMultiAgentV2)
        #expect(live.entry.info.supportsBackendSearch)
        // Forced false locally: this transport is OAuth-only.
        #expect(!live.entry.info.supportedInApi)
        #expect(live.visibility == .list)
        #expect(models[1].visibility == .hide)

        let catalog = CodexModelsCatalog(models: models, accountFingerprint: "fp")
        #expect(catalog.isAuthoritative)
        // `entries()` keeps hidden models so live can hide a same-slug fallback.
        #expect(catalog.entries().count == 2)
        #expect(catalog.listVisibleEntries().count == 1)
    }

    /// Provenance: `wafer_models.rs:302-305`. `object` is ignored.
    @Test("Wafer golden response yields prefixed, authoritative entries")
    func waferGolden() throws {
        let entries = try WaferModels.parseCatalog(
            try fixture("wafer_models.json"),
            baseURL: WaferModels.apiBaseURLDefault
        )
        #expect(entries.keys == ["wafer:wafer-model"])
        let entry = try #require(entries["wafer:wafer-model"])
        #expect(entry.info.model == "wafer-model")
        #expect(entry.info.provider == .wafer)
        #expect(entry.info.apiBackend == .chatCompletions)
        #expect(!entry.info.supportsBackendSearch)

        // Empty is still authoritative: "Wafer serves no models", not "fall back".
        let empty = WaferModelsCatalog(entries: OrderedModelMap(), credentialFingerprint: "fp")
        #expect(empty.isAuthoritative)
    }

    /// Provenance: `kimi_models.rs:327-340`.
    @Test("Kimi golden response uses context_length")
    func kimiGolden() throws {
        let entries = try parseKimiModelsResponse(
            try fixture("kimi_models.json"),
            baseURL: KimiModels.platformAPIBaseURL,
            endpoint: .platform
        )
        let entry = try #require(entries["kimi-k3"])
        #expect(entry.info.contextWindow == 256_000)
        #expect(entry.info.provider == .kimi)
    }

    /// Provenance: `fireworks_models.rs:300-311` plus the projection comment at
    /// 257-258 — wire metadata only enriches, it never adds a model.
    @Test("Fireworks wire response enriches but never adds models")
    func fireworksGolden() throws {
        let enrichment = try FireworksModels.parseContextEnrichment(
            try fixture("fireworks_models.json")
        )
        #expect(enrichment == ["accounts/fireworks/models/glm-5p2": 1_040_000])

        let catalog = FireworksModels.curatedCatalog(contextBySlug: enrichment)
        // Every curated model is present regardless of what the wire named.
        #expect(catalog.count == FireworksModels.curated.count)
        #expect(catalog.values().allSatisfy { $0.info.provider == .fireworks })
    }

    /// Provenance: `deepseek_models.rs:292-301`. `/models` names which curated
    /// models the key may reach.
    @Test("DeepSeek availability list intersects the curated catalog")
    func deepSeekGolden() throws {
        let slugs = try DeepSeekModels.parseAvailableSlugs(try fixture("deepseek_models.json"))
        #expect(slugs == ["deepseek-v4-pro", "deepseek-v4-flash"])

        var catalog = DeepSeekModels.curatedCatalog()
        catalog.retain { _, entry in slugs.contains(entry.info.model) }
        #expect(catalog.count == 2)
        #expect(catalog.values().allSatisfy { $0.info.provider == .deepseek })
    }

    /// Provenance: `meta_models.rs:323-371`
    /// (`wire_catalog_preserves_curated_capabilities`): unknown future ids
    /// fail closed, and the curated capabilities survive the wire join.
    @Test("Meta availability list intersects the curated catalog")
    func metaGolden() throws {
        let slugs = try MetaModels.parseAvailableSlugs(try fixture("meta_models.json"))
        #expect(slugs == ["muse-spark-1.2", "muse-spark-1.1", "muse-spark-1.2-contributor"])

        var catalog = MetaModels.curatedCatalog()
        catalog.retain { _, entry in slugs.contains(entry.info.model) }
        #expect(catalog.count == 3)
        #expect(catalog.values().allSatisfy { $0.info.provider == .meta })

        let model = try #require(catalog["meta:muse-spark-1.2"])
        #expect(model.info.apiBackend == .responses)
        #expect(model.info.contextWindow == 1_000_000)
        #expect(model.info.supportsBackendSearch)
        #expect(model.info.reasoningEffort == .medium)
        #expect(model.info.reasoningEfforts.map(\.value) == [.low, .medium, .high, .xhigh])
        #expect(model.envKey?.primary == MetaModels.apiKeyEnv)
    }

    /// Provenance: `opencode_go_models.rs:313-337`. Fails closed on missing
    /// metadata and on an SDK with no known wire protocol.
    @Test("OpenCode Go joins availability with models.dev and fails closed")
    func openCodeGoGolden() throws {
        let ids = try OpenCodeGoModels.parseAvailableIDs(try fixture("opencode_go_models.json"))
        #expect(ids == ["claude-sonnet-4-5", "gpt-5-codex", "orphan-no-metadata"])

        let metadata = try OpenCodeGoModels.parseModelsDev(try fixture("models_dev.json"))
        let built = OpenCodeGoModels.catalog(
            availableIDs: ids,
            metadata: metadata,
            baseURL: OpenCodeGoModels.apiBaseURLDefault
        )

        // `orphan-no-metadata` is available but undocumented, so it is dropped.
        #expect(built.entries.keys == ["opencode-go:claude-sonnet-4-5", "opencode-go:gpt-5-codex"])
        #expect(built.warnings.count == 1)
        #expect(built.warnings[0].contains("orphan-no-metadata"))

        // One provider key, two wire protocols: the per-model SDK wins over the
        // provider-level npm default.
        let sonnet = try #require(built.entries["opencode-go:claude-sonnet-4-5"])
        #expect(sonnet.info.apiBackend == .messages)
        #expect(sonnet.info.authScheme == .xApiKey)
        #expect(sonnet.info.contextWindow == 200_000)

        let codex = try #require(built.entries["opencode-go:gpt-5-codex"])
        #expect(codex.info.apiBackend == .chatCompletions)
        #expect(codex.info.authScheme == .bearer)
    }
}

// MARK: - Cache semantics

@Suite("Codex cache identity, TTL and ETag")
struct CodexCacheTests {
    /// `load_fresh_or_fetch` (`codex_models.rs:398-404`): a fresh matching
    /// cache is used and the network is not touched a second time.
    @Test("a fresh cache is served without a second request")
    func cacheRoundTrip() async throws {
        let home = try tempHome()
        let transport = MockCatalogTransport()
        await transport.route(
            matching: "/models",
            responses: [ok(try fixture("codex_models.json"), etag: "live-etag")]
        )
        let broker = RecordingCredentialBroker()
        await broker.setCodex(testCodexCredential)

        let actor = CodexCatalogActor(
            transport: transport,
            cache: codexCache(home: home),
            credentialSource: { await broker.codexCredential(forceRefresh: $0) },
            openGrokVersion: "test-version"
        )

        let first = try #require(try await actor.loadFreshOrFetch())
        #expect(first.models.count == 2)
        #expect(first.etag == "live-etag")
        #expect(await transport.recordedRequests().count == 1)

        // The cache file is real and round-trips the full catalog plus the ETag.
        let second = try #require(try await actor.loadFreshOrFetch())
        #expect(await transport.recordedRequests().count == 1)
        #expect(second.models.map(\.slug) == first.models.map(\.slug))
        #expect(second.etag == "live-etag")
        #expect(second.accountFingerprint == "fp-account-a")
        #expect(second.models[0].entry.info.contextWindow == 353_400)
    }

    /// `is_fresh` (`codex_models.rs:288-296`): age must lie in `[0, ttl)`.
    /// Both bounds are pinned with an injected clock.
    @Test("TTL expiry and clock skew both force a refetch")
    func ttlExpiry() async throws {
        let home = try tempHome()
        let cache = codexCache(home: home, ttl: 300)
        let catalog = CodexModelsCatalog(
            models: try parseCodexModelsResponse(try fixture("codex_models.json")),
            etag: "e1",
            accountFingerprint: "fp-account-a"
        )
        let written = Date(timeIntervalSince1970: 1_000_000)
        try cache.persist(
            catalog,
            openGrokVersion: "test-version",
            clientVersion: CodexModels.defaultClientVersion,
            baseURL: CodexModels.defaultInferenceBaseURL,
            now: written
        )

        func load(at offset: TimeInterval) -> CodexModelsCatalog? {
            cache.loadFresh(
                expectedAccountFingerprint: "fp-account-a",
                openGrokVersion: "test-version",
                clientVersion: CodexModels.defaultClientVersion,
                baseURL: CodexModels.defaultInferenceBaseURL,
                now: written.addingTimeInterval(offset)
            )
        }

        #expect(load(at: 0) != nil)
        #expect(load(at: 299) != nil)
        // Exactly at the TTL the entry is stale: the bound is exclusive.
        #expect(load(at: 300) == nil)
        #expect(load(at: 10_000) == nil)
        // A cache stamped in the future is a miss, not an eternally fresh one.
        #expect(load(at: -1) == nil)
    }

    /// `load_fresh_cache_for` (`codex_models.rs:445-485`): version, client
    /// version, endpoint and account are all part of cache identity.
    @Test("every identity component is part of the cache key")
    func identityMisses() async throws {
        let home = try tempHome()
        let cache = codexCache(home: home)
        let catalog = CodexModelsCatalog(
            models: try parseCodexModelsResponse(try fixture("codex_models.json")),
            etag: "e1",
            accountFingerprint: "fp-account-a"
        )
        let now = Date()
        try cache.persist(
            catalog,
            openGrokVersion: "test-version",
            clientVersion: "0.144.5",
            baseURL: CodexModels.defaultInferenceBaseURL,
            now: now
        )

        func load(
            version: String = "test-version",
            clientVersion: String = "0.144.5",
            baseURL: String = CodexModels.defaultInferenceBaseURL,
            fingerprint: String = "fp-account-a"
        ) -> CodexModelsCatalog? {
            cache.loadFresh(
                expectedAccountFingerprint: fingerprint,
                openGrokVersion: version,
                clientVersion: clientVersion,
                baseURL: baseURL,
                now: now
            )
        }

        #expect(load() != nil)
        #expect(load(version: "other-build") == nil)
        #expect(load(clientVersion: "0.144.6") == nil)
        #expect(load(baseURL: "https://chatgpt.com/backend-api/other") == nil)
        // The account switch case: same login, different workspace.
        #expect(load(fingerprint: "fp-account-b") == nil)
    }

    /// Conditional revalidation is opt-in because upstream never sends the
    /// header. With it on, a 304 keeps the last-good catalog and renews the TTL
    /// rather than dropping the partition.
    @Test("304 keeps the cached catalog and renews its TTL")
    func notModifiedPath() async throws {
        let home = try tempHome()
        let cache = codexCache(home: home, ttl: 300)
        let broker = RecordingCredentialBroker()
        await broker.setCodex(testCodexCredential)

        let transport = MockCatalogTransport()
        await transport.route(
            matching: "/models",
            responses: [
                ok(try fixture("codex_models.json"), etag: "live-etag"),
                ModelCatalogResponse(status: 304),
            ]
        )

        let clock = ClockBox(Date(timeIntervalSince1970: 2_000_000))
        let actor = CodexCatalogActor(
            transport: transport,
            cache: cache,
            credentialSource: { await broker.codexCredential(forceRefresh: $0) },
            openGrokVersion: "test-version",
            conditionalRevalidation: true,
            now: { clock.value }
        )

        let first = try #require(try await actor.fetchAndCache())
        #expect(first.etag == "live-etag")

        // Move past the TTL so the entry would otherwise be stale, then
        // revalidate.
        clock.value = clock.value.addingTimeInterval(400)
        let revalidated = try #require(try await actor.fetchAndCache())
        #expect(revalidated.models.map(\.slug) == first.models.map(\.slug))
        #expect(revalidated.etag == "live-etag")

        let requests = await transport.recordedRequests()
        #expect(requests.count == 2)
        // The first request has no prior ETag; the second revalidates with it.
        #expect(requests[0].headerValue("If-None-Match") == nil)
        #expect(requests[1].headerValue("If-None-Match") == "live-etag")

        // The TTL was renewed, so the entry is fresh again at the new clock.
        let reloaded = cache.loadFresh(
            expectedAccountFingerprint: "fp-account-a",
            openGrokVersion: "test-version",
            clientVersion: CodexModels.defaultClientVersion,
            baseURL: CodexModels.defaultInferenceBaseURL,
            now: clock.value
        )
        #expect(reloaded != nil)
    }

    /// `codex_models.rs:373-382`: exactly one forced credential refresh and one
    /// retry. A second 401 is fatal for that refresh, not an infinite loop.
    @Test("401 forces one credential refresh and one retry")
    func unauthorizedRetry() async throws {
        let home = try tempHome()
        let broker = RecordingCredentialBroker()
        await broker.setCodex(testCodexCredential)

        let transport = MockCatalogTransport()
        await transport.route(
            matching: "/models",
            responses: [
                ModelCatalogResponse(status: 401, body: Data("nope".utf8)),
                ok(try fixture("codex_models.json"), etag: "after-refresh"),
            ]
        )
        let actor = CodexCatalogActor(
            transport: transport,
            cache: codexCache(home: home),
            credentialSource: { await broker.codexCredential(forceRefresh: $0) },
            openGrokVersion: "test-version"
        )

        let catalog = try #require(try await actor.fetchAndCache())
        #expect(catalog.etag == "after-refresh")
        #expect(await transport.recordedRequests().count == 2)
        #expect(await broker.forcedRefreshes() == 1)
    }

    @Test("a persistent 401 fails without retrying forever")
    func unauthorizedTwice() async throws {
        let home = try tempHome()
        let broker = RecordingCredentialBroker()
        await broker.setCodex(testCodexCredential)

        let transport = MockCatalogTransport()
        await transport.route(
            matching: "/models",
            responses: [ModelCatalogResponse(status: 401, body: Data("nope".utf8))]
        )
        let actor = CodexCatalogActor(
            transport: transport,
            cache: codexCache(home: home),
            credentialSource: { await broker.codexCredential(forceRefresh: $0) },
            openGrokVersion: "test-version"
        )

        await #expect(throws: ModelsError.self) {
            _ = try await actor.fetchAndCache()
        }
        #expect(await transport.recordedRequests().count == 2)
        #expect(await broker.forcedRefreshes() == 1)
    }

    /// `codex_models.rs:388-394`: a response that lands after an account switch
    /// must not overwrite the new account's cache.
    @Test("a response landing after an account switch is discarded")
    func publishRace() async throws {
        let home = try tempHome()
        let cache = codexCache(home: home)
        let broker = RecordingCredentialBroker()
        await broker.setCodex(testCodexCredential)

        // Switch the account as soon as the request is in flight.
        let transport = SwitchingTransport(
            body: try fixture("codex_models.json"),
            onSend: {
                await broker.setCodex(
                    CodexCatalogCredential(
                        accessToken: "other",
                        accountID: "acct-999",
                        fingerprint: "fp-account-b"
                    )
                )
            }
        )

        let actor = CodexCatalogActor(
            transport: transport,
            cache: cache,
            credentialSource: { await broker.codexCredential(forceRefresh: $0) },
            openGrokVersion: "test-version"
        )

        #expect(try await actor.fetchAndCache() == nil)
        // Account B's cache was never written by account A's in-flight response.
        #expect(cache.loadAny() == nil)
    }

    @Test("no Codex session yields no catalog and no request")
    func missingCredentialsNeverBlock() async throws {
        let home = try tempHome()
        let transport = MockCatalogTransport()
        let broker = RecordingCredentialBroker()
        // Deliberately no Codex credential set.

        let actor = CodexCatalogActor(
            transport: transport,
            cache: codexCache(home: home),
            credentialSource: { await broker.codexCredential(forceRefresh: $0) },
            openGrokVersion: "test-version"
        )
        #expect(try await actor.loadFreshOrFetch() == nil)
        #expect(await transport.recordedRequests().isEmpty)
    }
}

/// Mutable clock for TTL tests.
private final class ClockBox: @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
}

/// Transport that mutates credential state while the request is "in flight".
private struct SwitchingTransport: ModelCatalogTransport {
    let body: Data
    let onSend: @Sendable () async -> Void

    func send(
        _ request: ModelCatalogRequest,
        cancellation: CancellationToken?
    ) async throws -> ModelCatalogResponse {
        await onSend()
        return ok(body, etag: "raced")
    }
}

// MARK: - Partition isolation

@Suite("Catalog partition isolation")
struct CatalogPartitionIsolationTests {
    /// A Codex refresh must not read any other partition's credentials. The
    /// actor is constructed with a Codex-bound closure, so this is structural,
    /// and the recording broker proves it at runtime too.
    @Test("a Codex refresh never reads another partition's credentials")
    func codexReadsOnlyCodexCredentials() async throws {
        let home = try tempHome()
        let broker = RecordingCredentialBroker()
        await broker.setCodex(testCodexCredential)
        await broker.setKey(.wafer, apiKey: "wafer-secret", fingerprint: "fp-wafer")

        let transport = MockCatalogTransport()
        await transport.route(
            matching: "/models",
            responses: [ok(try fixture("codex_models.json"), etag: "e")]
        )
        let actor = CodexCatalogActor(
            transport: transport,
            cache: codexCache(home: home),
            credentialSource: { await broker.codexCredential(forceRefresh: $0) },
            openGrokVersion: "test-version"
        )
        _ = try await actor.fetchAndCache()

        // No API-key partition was consulted at all.
        #expect(await broker.asked().isEmpty)
        #expect(await broker.codexAsks() > 0)

        // And no other provider's secret reached the wire.
        let requests = await transport.recordedRequests()
        for request in requests {
            for header in request.headers {
                #expect(!header.value.contains("wafer-secret"))
            }
        }
    }

    /// A Codex refresh may replace only the Codex partition. xAI models are
    /// neither added nor removed by it.
    @Test("a Codex refresh cannot add or remove xAI models")
    func codexCannotTouchXai() throws {
        let input = CatalogResolutionInput.default
        let before = resolveModelCatalog(input: input)
        let xaiBefore = before.pairs().filter { $0.1.info.provider == .xai }.map(\.0)
        #expect(!xaiBefore.isEmpty)

        let codexCatalog = CodexModelsCatalog(
            models: try parseCodexModelsResponse(try fixture("codex_models.json")),
            etag: "e",
            accountFingerprint: "fp"
        )
        let after = resolveModelCatalog(input: input, codexCatalog: codexCatalog)
        let xaiAfter = after.pairs().filter { $0.1.info.provider == .xai }.map(\.0)

        #expect(xaiAfter == xaiBefore)
        for key in xaiBefore {
            #expect(after[key]?.info == before[key]?.info)
        }
        // The Codex partition itself did change.
        #expect(after["gpt-5.6-sol"]?.info.provider == .codex)
    }

    /// The reverse direction: a Wafer refresh may not disturb Codex or xAI.
    @Test("a Wafer refresh replaces only the Wafer partition")
    func waferReplacesOnlyItself() throws {
        let input = CatalogResolutionInput.default
        let codexCatalog = CodexModelsCatalog(
            models: try parseCodexModelsResponse(try fixture("codex_models.json")),
            etag: "e",
            accountFingerprint: "fp"
        )
        let before = resolveModelCatalog(input: input, codexCatalog: codexCatalog)

        let waferEntries = try WaferModels.parseCatalog(
            try fixture("wafer_models.json"),
            baseURL: WaferModels.apiBaseURLDefault
        )
        let after = resolveModelCatalog(
            input: input,
            codexCatalog: codexCatalog,
            waferCatalog: WaferModelsCatalog(
                entries: waferEntries,
                credentialFingerprint: "fp-wafer"
            )
        )

        let nonWaferBefore = before.pairs().filter { $0.1.info.provider != .wafer }.map(\.0)
        let nonWaferAfter = after.pairs().filter { $0.1.info.provider != .wafer }.map(\.0)
        #expect(nonWaferBefore == nonWaferAfter)
        #expect(after["wafer:wafer-model"] != nil)
    }

    /// Provenance: `meta_models.rs:380-414` (`model_query_uses_bearer_auth`).
    /// The Meta query bearer-auths against `{base}/models` with only the Meta
    /// partition's key.
    @Test("the Meta query bearer-auths with only the Meta key")
    func metaQueryUsesBearerAuth() async throws {
        let broker = RecordingCredentialBroker()
        await broker.setKey(.meta, apiKey: "meta-query-canary", fingerprint: "fp-meta")
        await broker.setKey(.wafer, apiKey: "wafer-secret", fingerprint: "fp-wafer")

        let transport = MockCatalogTransport()
        await transport.route(
            matching: "/models",
            responses: [ok(try fixture("meta_models.json"))]
        )

        let actor = ProviderCatalogActors.meta(
            transport: transport,
            credentialSource: { await broker.credential(for: .meta) }
        )
        let result = try #require(try await actor.fetch())
        #expect(result.entries.contains("meta:muse-spark-1.2"))
        #expect(result.fingerprint == "fp-meta")

        let request = try #require(await transport.recordedRequests().first)
        #expect(request.url == "https://api.meta.ai/v1/models")
        #expect(request.timeout == 10)
        #expect(request.headerValue("Authorization") == "Bearer meta-query-canary")
        // Only the Meta partition's credential was consulted.
        #expect(await broker.asked().allSatisfy { $0 == .meta })
    }

    /// A projection that tried to emit another provider's entry is filtered by
    /// the actor before publication, independently of the merge layer.
    @Test("an actor drops entries outside its own partition")
    func actorFiltersForeignEntries() async throws {
        let broker = RecordingCredentialBroker()
        await broker.setKey(.wafer, apiKey: "k", fingerprint: "fp")

        let transport = MockCatalogTransport()
        await transport.route(matching: "/models", responses: [ok(Data("{}".utf8))])

        // A deliberately misbehaving projection.
        var foreign = ModelInfo.fallback(slug: "smuggled")
        foreign.provider = .xai
        let smuggled = ModelEntry(info: foreign)

        let actor = APIKeyCatalogActor(
            partition: .wafer,
            transport: transport,
            credentialSource: { await broker.credential(for: .wafer) },
            baseURL: WaferModels.apiBaseURLDefault,
            project: { _, base in
                var map = try WaferModels.parseCatalog(
                    Data("{\"data\":[{\"id\":\"real\"}]}".utf8),
                    baseURL: base
                )
                map["smuggled"] = smuggled
                return map
            }
        )

        let result = try #require(try await actor.fetch())
        #expect(result.entries.keys == ["wafer:real"])
    }
}

// MARK: - Merge order

@Suite("Live catalog merge order")
struct LiveCatalogMergeOrderTests {
    /// `config.rs:3653-3654`: config `[model.*]` > remote > hardcoded defaults.
    @Test("embedded < live < user override")
    func mergePrecedence() throws {
        let waferEntries = try WaferModels.parseCatalog(
            try fixture("wafer_models.json"),
            baseURL: WaferModels.apiBaseURLDefault
        )

        // Embedded only.
        let embeddedOnly = resolveModelCatalog(input: .default)
        #expect(embeddedOnly["wafer:wafer-model"] == nil)

        // Live adds the partition.
        let withLive = resolveModelCatalog(
            input: .default,
            waferCatalog: WaferModelsCatalog(entries: waferEntries, credentialFingerprint: "fp")
        )
        #expect(withLive["wafer:wafer-model"] != nil)

        // A user override of a *Kimi* key beats the live Kimi catalog, since
        // Kimi merges before the override loop.
        var override = ConfigModelOverride()
        override.name = "User Renamed"
        let kimiLive = try parseKimiModelsResponse(
            try fixture("kimi_models.json"),
            baseURL: KimiModels.platformAPIBaseURL,
            endpoint: .platform
        )
        let liveKimiCatalog = KimiModelsCatalog(
            entries: kimiLive,
            endpoint: .platform,
            credentialFingerprint: "fp"
        )
        let liveNoOverride = resolveModelCatalog(input: .default, kimiCatalog: liveKimiCatalog)
        // The live entry replaced the embedded one: the live catalog owns the
        // display name.
        #expect(liveNoOverride["kimi-k3"]?.info.name == "kimi-k3")

        let overridden = resolveModelCatalog(
            input: CatalogResolutionInput(configModels: [("kimi-k3", override)]),
            kimiCatalog: liveKimiCatalog
        )
        #expect(overridden["kimi-k3"]?.info.name == "User Renamed")
    }

    /// A live `context_length` of exactly `DEFAULT_CONTEXT_WINDOW` (256_000) is
    /// indistinguishable from "the provider omitted it", so the embedded
    /// donor's value wins — `inherit_donor_metadata` guards on
    /// `== DEFAULT_CONTEXT_WINDOW` (`config.rs:3592-3597`), and Kimi's parser
    /// falls back to that same 256_000 when `context_length` is missing
    /// (`kimi_models.rs:279-317`). Pinned because it looks like a bug at the
    /// call site and is not one.
    @Test("a live context window equal to the sentinel defers to the donor")
    func sentinelContextWindowDefersToDonor() throws {
        func catalog(contextLength: UInt64) throws -> OrderedModelMap {
            let body = Data(#"{"data":[{"id":"kimi-k3","context_length":\#(contextLength)}]}"#.utf8)
            let entries = try parseKimiModelsResponse(
                body,
                baseURL: KimiModels.platformAPIBaseURL,
                endpoint: .platform
            )
            return resolveModelCatalog(
                input: .default,
                kimiCatalog: KimiModelsCatalog(
                    entries: entries,
                    endpoint: .platform,
                    credentialFingerprint: "fp"
                )
            )
        }

        // A distinctive live value is authoritative.
        #expect(try catalog(contextLength: 1_000_000)["kimi-k3"]?.info.contextWindow == 1_000_000)

        // The sentinel value is treated as unset, so the embedded donor wins.
        let sentinel = try #require(try catalog(contextLength: DEFAULT_CONTEXT_WINDOW)["kimi-k3"])
        let embedded = try #require(resolveModelCatalog(input: .default)["kimi-k3"])
        #expect(sentinel.info.contextWindow == embedded.info.contextWindow)
        #expect(sentinel.info.contextWindow != DEFAULT_CONTEXT_WINDOW)
    }

    /// Current upstream re-applies `[model.*]` after every late provider
    /// partition replacement (`agent/models/resolution.rs:450-453`).
    @Test("a configured Wafer override survives its authoritative live catalog")
    func waferUserOverrideSurvivesLiveCatalog() throws {
        var override = ConfigModelOverride()
        override.name = "User Renamed Wafer"
        let waferEntries = try WaferModels.parseCatalog(
            try fixture("wafer_models.json"),
            baseURL: WaferModels.apiBaseURLDefault
        )

        let catalog = resolveModelCatalog(
            input: CatalogResolutionInput(configModels: [("wafer:wafer-model", override)]),
            waferCatalog: WaferModelsCatalog(entries: waferEntries, credentialFingerprint: "fp")
        )
        let liveEntry = try #require(catalog["wafer:wafer-model"])
        #expect(liveEntry.info.name == "User Renamed Wafer")
        #expect(liveEntry.info.provider == .wafer)
        #expect(liveEntry.info.model == "wafer-model")

        // Without a live Wafer catalog the override stands.
        let noLive = resolveModelCatalog(
            input: CatalogResolutionInput(configModels: [("wafer:wafer-model", override)])
        )
        #expect(noLive["wafer:wafer-model"]?.info.name == "User Renamed Wafer")
    }
}

// MARK: - Manager wiring

@Suite("ModelsManager live refresh")
struct ModelsManagerLiveRefreshTests {
    /// Missing credentials mean embedded-only, never an error that blocks
    /// launch (`agent/models.rs:855-857`).
    @Test("unconfigured partitions publish nothing and never throw")
    func unconfiguredPartitionsAreSilent() async throws {
        let home = try tempHome()
        let transport = MockCatalogTransport()
        let manager = ModelsManager(
            grokHome: home,
            liveCatalogs: LiveCatalogRefreshers.live(
                transport: transport,
                broker: EmptyCredentialBroker(),
                grokHome: home
            )
        )
        let before = manager.catalogSnapshot().keys

        let outcomes = await manager.refreshBackgroundPartitions()
        #expect(outcomes.count == 7)
        #expect(outcomes.allSatisfy { !$0.published })
        #expect(outcomes.allSatisfy { $0.failure == nil })
        // No request was ever attempted.
        #expect(await transport.recordedRequests().isEmpty)
        #expect(manager.catalogSnapshot().keys == before)

        let codex = await manager.refreshCodexBlocking()
        #expect(!codex.published)
        #expect(codex.failure == nil)
    }

    /// A refreshed partition reaches the assembled catalog, and a failing
    /// sibling does not prevent it.
    @Test("one partition failing does not stop the others")
    func partialFailureIsIsolated() async throws {
        let home = try tempHome()
        let broker = RecordingCredentialBroker()
        await broker.setKey(.wafer, apiKey: "wafer-key", fingerprint: "fp-wafer")
        await broker.setKey(.deepSeek, apiKey: "ds-key", fingerprint: "fp-ds")

        let transport = MockCatalogTransport()
        await transport.route(
            matching: "pass.wafer.ai",
            responses: [ok(try fixture("wafer_models.json"))]
        )
        await transport.route(
            matching: "api.deepseek.com",
            responses: [ModelCatalogResponse(status: 500, body: Data("boom ds-key".utf8))]
        )

        let manager = ModelsManager(
            credentials: EmptyCredentialSnapshot(
                deepSeekCredentialFingerprint: "fp-ds",
                waferCredentialFingerprint: "fp-wafer"
            ),
            grokHome: home,
            liveCatalogs: LiveCatalogRefreshers.live(
                transport: transport,
                broker: broker,
                grokHome: home
            )
        )

        let outcomes = await manager.refreshBackgroundPartitions()
        let wafer = try #require(outcomes.first { $0.partition == .wafer })
        let deepSeek = try #require(outcomes.first { $0.partition == .deepSeek })

        #expect(wafer.published)
        #expect(!deepSeek.published)
        let failure = try #require(deepSeek.failure)
        #expect(failure.contains("500"))
        // The key is redacted out of the surfaced error body.
        #expect(!failure.contains("ds-key"))
        #expect(failure.contains("[REDACTED]"))

        // Wafer's models landed despite DeepSeek failing.
        #expect(manager.catalogSnapshot()["wafer:wafer-model"] != nil)
    }

    /// A published catalog whose fingerprint no longer matches the manager's
    /// credential snapshot is rejected rather than shown.
    @Test("a catalog from a superseded credential is not published")
    func staleFingerprintRejected() throws {
        let home = try tempHome()
        let manager = ModelsManager(
            credentials: EmptyCredentialSnapshot(waferCredentialFingerprint: "fp-current"),
            grokHome: home
        )
        let entries = try WaferModels.parseCatalog(
            try fixture("wafer_models.json"),
            baseURL: WaferModels.apiBaseURLDefault
        )

        let rejected = manager.applyWaferCatalog(
            WaferModelsCatalog(entries: entries, credentialFingerprint: "fp-stale")
        )
        #expect(!rejected)
        #expect(manager.catalogSnapshot()["wafer:wafer-model"] == nil)

        let accepted = manager.applyWaferCatalog(
            WaferModelsCatalog(entries: entries, credentialFingerprint: "fp-current")
        )
        #expect(accepted)
        #expect(manager.catalogSnapshot()["wafer:wafer-model"] != nil)
    }

    @Test("a fetched catalog rejected by its credential gate reports unpublished")
    func refreshOutcomeDoesNotClaimRejectedCatalogWasPublished() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let broker = RecordingCredentialBroker()
        await broker.setKey(.wafer, apiKey: "wafer-key", fingerprint: "fp-old")

        let transport = MockCatalogTransport()
        await transport.route(
            matching: "pass.wafer.ai",
            responses: [ok(try fixture("wafer_models.json"))]
        )

        let manager = ModelsManager(
            credentials: EmptyCredentialSnapshot(waferCredentialFingerprint: "fp-current"),
            grokHome: home,
            liveCatalogs: LiveCatalogRefreshers.live(
                transport: transport,
                broker: broker,
                grokHome: home
            )
        )

        let result = await manager.refreshPartition(.wafer)
        #expect(!result.published)
        #expect(result.failure == nil)
        #expect(manager.catalogSnapshot()["wafer:wafer-model"] == nil)
    }

    @Test("a Codex catalog rejected for a different account reports unpublished")
    func codexRefreshOutcomeDoesNotClaimRejectedAccountWasPublished() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let broker = RecordingCredentialBroker()
        await broker.setCodex(testCodexCredential)

        let transport = MockCatalogTransport()
        await transport.route(
            matching: "/models",
            responses: [ok(try fixture("codex_models.json"))]
        )

        let manager = ModelsManager(
            credentials: EmptyCredentialSnapshot(
                hasCodexSession: true,
                codexAccountFingerprint: "fp-different-account"
            ),
            grokHome: home,
            liveCatalogs: LiveCatalogRefreshers.live(
                transport: transport,
                broker: broker,
                grokHome: home
            )
        )

        let result = await manager.refreshCodexBlocking(forceOnline: true)
        #expect(!result.published)
        #expect(result.failure == nil)
    }
}
