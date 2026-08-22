// ProviderCatalogActors.swift
//
// One actor per provider catalog partition. Actor isolation is the refresh
// lock: upstream gives every provider its own `tokio::sync::Mutex` plus an
// `AtomicU64` generation counter (`agent/models.rs:342-353`), and serialized
// actor execution plus a fingerprint recheck before publish reproduces both.
//
// Isolation invariants, each pinned by a test:
//   * An actor is constructed with a credential closure bound to its own
//     partition. It has no expressible way to name another partition's
//     credentials.
//   * An actor returns only its own provider's entries; the merge layer
//     additionally retains by provider (`CatalogResolution.swift`).
//   * Only Codex and xAI have disk caches, and they are separate files.
//     Kimi/Fireworks/DeepSeek/Meta/OpenCode Go/Wafer are process-lifetime
//     only — upstream has no cache file for them (see INTEGRATION-catalog.md).

import Foundation
import OpenGrokSamplingTypes
import OpenGrokVersion

// MARK: - Timeouts

public enum ModelCatalogTimeouts {
    /// `CODEX_MODELS_REQUEST_TIMEOUT` (`codex_models.rs:35`).
    public static let codex: TimeInterval = 5
    /// Every API-key provider uses 10s: `wafer_models.rs:18`,
    /// `kimi_models.rs:24`, `fireworks_models.rs:20`, `deepseek_models.rs:22`,
    /// `meta_models.rs:17`, `opencode_go_models.rs:23`.
    public static let apiKeyProvider: TimeInterval = 10
    /// `OPENROUTER_MODELS_REQUEST_TIMEOUT` (`openrouter_models.rs:22`).
    public static let openRouter: TimeInterval = 15
}

/// Truncate and redact a provider error body before it is surfaced.
/// `safe_error_excerpt` (`wafer_models.rs:193-198`) — replace the key, collapse
/// CR/LF, cap at 512 characters.
public func safeCatalogErrorExcerpt(_ body: String, apiKey: String?) -> String {
    var sanitized = body
    if let apiKey, !apiKey.isEmpty {
        sanitized = sanitized.replacingOccurrences(of: apiKey, with: "[REDACTED]")
    }
    sanitized = sanitized
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
    return String(sanitized.prefix(512))
}

// MARK: - Codex

/// Live Codex catalog partition.
///
/// Fetch policy is upstream's `OnlineIfUncached`: a fresh matching cache is
/// used as-is, otherwise the network is hit and the result cached
/// (`load_fresh_or_fetch`, `codex_models.rs:398-404`). This is
/// fetch-on-miss-then-await, *not* stale-while-revalidate: a stale cache is
/// discarded rather than served while a refresh runs.
public actor CodexCatalogActor {
    private let transport: any ModelCatalogTransport
    private let cache: CodexModelsCacheManager
    private let credentialSource: @Sendable (Bool) async -> CodexCatalogCredential?
    private let baseURL: String
    private let clientVersion: String
    private let openGrokVersion: String
    private let conditionalRevalidation: Bool
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - credentialSource: bound to the Codex partition by the caller. The
    ///     `Bool` is `forceRefresh`, used exactly once after a 401.
    ///   - conditionalRevalidation: send `If-None-Match` and honor `304`.
    ///     Defaults to `false` because upstream never sends the header — see
    ///     the divergence note in INTEGRATION-catalog.md.
    public init(
        transport: any ModelCatalogTransport,
        cache: CodexModelsCacheManager,
        credentialSource: @escaping @Sendable (Bool) async -> CodexCatalogCredential?,
        baseURL: String = CodexModels.defaultInferenceBaseURL,
        clientVersion: String = CodexModels.clientVersion(),
        openGrokVersion: String = OpenGrokVersion.installed(),
        conditionalRevalidation: Bool = false,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.cache = cache
        self.credentialSource = credentialSource
        self.baseURL = baseURL
        self.clientVersion = clientVersion
        self.openGrokVersion = openGrokVersion
        self.conditionalRevalidation = conditionalRevalidation
        self.now = now
    }

    /// `{base}/models?client_version={version}` (`codex_models.rs:722-729`).
    public nonisolated func modelsURL(baseURL: String, clientVersion: String) -> String {
        let trimmed = trimTrailingSlashes(baseURL)
        let encoded = clientVersion.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        ) ?? clientVersion
        return "\(trimmed)/models?client_version=\(encoded)"
    }

    /// `codex_user_agent()` (`codex_models.rs:743-748`).
    private var userAgent: String { "\(CodexOriginator.value)/\(clientVersion)" }

    /// Request headers, in upstream's emission order (`codex_models.rs:487-515`).
    public nonisolated func buildRequest(
        credential: CodexCatalogCredential,
        clientVersion: String,
        baseURL: String,
        ifNoneMatch: String?
    ) -> ModelCatalogRequest {
        var headers: [ModelCatalogHeader] = [
            ModelCatalogHeader("Authorization", "Bearer \(credential.accessToken)"),
            ModelCatalogHeader("originator", CodexOriginator.value),
            ModelCatalogHeader("User-Agent", "\(CodexOriginator.value)/\(clientVersion)"),
            ModelCatalogHeader("version", clientVersion),
        ]
        if let accountID = credential.accountID, !accountID.isEmpty {
            headers.append(ModelCatalogHeader("ChatGPT-Account-ID", accountID))
        }
        if credential.accountIsFedramp {
            headers.append(ModelCatalogHeader("X-OpenAI-Fedramp", "true"))
        }
        if let ifNoneMatch {
            headers.append(ModelCatalogHeader("If-None-Match", ifNoneMatch))
        }
        return ModelCatalogRequest(
            url: modelsURL(baseURL: baseURL, clientVersion: clientVersion),
            headers: headers,
            timeout: ModelCatalogTimeouts.codex
        )
    }

    /// A fresh matching cache, if one exists.
    public func loadFreshCache() async -> CodexModelsCatalog? {
        guard let credential = await credentialSource(false) else { return nil }
        return cache.loadFresh(
            expectedAccountFingerprint: credential.fingerprint,
            openGrokVersion: openGrokVersion,
            clientVersion: clientVersion,
            baseURL: baseURL,
            now: now()
        )
    }

    /// `OnlineIfUncached`. Returns `nil` when there is no Codex session — never
    /// an error, so a missing login cannot block a session start.
    public func loadFreshOrFetch(
        cancellation: CancellationToken? = nil
    ) async throws -> CodexModelsCatalog? {
        if let cached = await loadFreshCache() { return cached }
        return try await fetchAndCache(cancellation: cancellation)
    }

    /// Unconditional network fetch. Used after an explicit Codex login
    /// (`acp_agent.rs:3785`).
    public func fetchAndCache(
        cancellation: CancellationToken? = nil
    ) async throws -> CodexModelsCatalog? {
        try cancellation?.throwIfCancelled()
        guard let credential = await credentialSource(false) else { return nil }

        // Only revalidate against an ETag the current principal produced.
        let priorETag: String? = conditionalRevalidation
            ? cache.loadAny()
                .flatMap { $0.accountFingerprint == credential.fingerprint ? $0.etag : nil }
            : nil

        var response = try await send(
            credential: credential,
            ifNoneMatch: priorETag,
            cancellation: cancellation
        )

        // One forced credential refresh and one retry on 401 — no more
        // (`codex_models.rs:373-382`).
        var effective = credential
        if response.status == 401 {
            guard let refreshed = await credentialSource(true) else {
                throw ModelsError.remoteMalformed("OpenAI Codex login is no longer available")
            }
            effective = refreshed
            response = try await send(
                credential: refreshed,
                ifNoneMatch: priorETag,
                cancellation: cancellation
            )
            if response.status == 401 {
                throw ModelsError.remoteMalformed("OpenAI Codex rejected the OAuth token")
            }
        }

        // 304: the server confirmed the cached snapshot. Keep it and renew the
        // TTL rather than dropping the catalog. Only reachable when
        // `conditionalRevalidation` is on.
        if response.status == 304, let priorETag {
            if let cached = cache.loadAny(),
               cached.accountFingerprint == effective.fingerprint,
               cached.etag == priorETag {
                try? cache.renewTTL(expectedAccountFingerprint: effective.fingerprint, now: now())
                return cached
            }
            return nil
        }

        guard response.isSuccess else {
            let body = String(decoding: response.body, as: UTF8.self)
            throw ModelsError.remoteMalformed(
                "Codex models request returned \(response.status): "
                    + safeCatalogErrorExcerpt(body, apiKey: effective.accessToken)
            )
        }

        try cancellation?.throwIfCancelled()
        let models = try parseCodexModelsResponse(response.body, baseURL: baseURL)
        let catalog = CodexModelsCatalog(
            models: models,
            etag: response.headerValue("ETag"),
            accountFingerprint: effective.fingerprint
        )

        // Recheck the principal before writing: a response that landed after an
        // account switch must not overwrite the new account's cache
        // (`codex_models.rs:388-394`).
        let current = await credentialSource(false)
        guard current?.fingerprint == effective.fingerprint else { return nil }

        // A read-only or full home directory must not make a fetched catalog
        // unavailable, so a cache write failure is not surfaced.
        try? cache.persist(
            catalog,
            openGrokVersion: openGrokVersion,
            clientVersion: clientVersion,
            baseURL: baseURL,
            now: now()
        )
        return catalog
    }

    public func invalidateCache() {
        cache.invalidate()
    }

    private func send(
        credential: CodexCatalogCredential,
        ifNoneMatch: String?,
        cancellation: CancellationToken?
    ) async throws -> ModelCatalogResponse {
        try cancellation?.throwIfCancelled()
        let request = buildRequest(
            credential: credential,
            clientVersion: clientVersion,
            baseURL: baseURL,
            ifNoneMatch: ifNoneMatch
        )
        return try await transport.send(request, cancellation: cancellation)
    }
}

/// `CODEX_ORIGINATOR` (`codex_auth.rs:33`).
public enum CodexOriginator {
    public static let value = "codex_cli_rs"
}

// MARK: - API-key partitions

/// Shared fetch machinery for the five bearer-only provider catalogs.
///
/// Each instance is bound to one partition and one credential closure. The
/// projection closure turns a response body into that provider's entries, so
/// a Fireworks projection can never emit a Wafer entry.
public actor APIKeyCatalogActor {
    public typealias Projection = @Sendable (Data, String) throws -> OrderedModelMap

    private let partition: ModelCatalogPartition
    private let transport: any ModelCatalogTransport
    private let credentialSource: @Sendable () async -> ProviderCatalogCredential?
    private let baseURL: String
    private let project: Projection

    public init(
        partition: ModelCatalogPartition,
        transport: any ModelCatalogTransport,
        credentialSource: @escaping @Sendable () async -> ProviderCatalogCredential?,
        baseURL: String,
        project: @escaping Projection
    ) {
        self.partition = partition
        self.transport = transport
        self.credentialSource = credentialSource
        self.baseURL = baseURL
        self.project = project
    }

    /// Fetch and project this partition's catalog.
    ///
    /// Returns `nil` when the partition has no usable key — upstream skips the
    /// query entirely rather than erroring (`agent/models.rs:855-857`,
    /// `874-877`), so an unconfigured provider never blocks anything.
    public func fetch(
        cancellation: CancellationToken? = nil
    ) async throws -> (entries: OrderedModelMap, fingerprint: String)? {
        try cancellation?.throwIfCancelled()
        guard let credential = await credentialSource(),
              !credential.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let request = ModelCatalogRequests.bearerRequest(
            url: ModelCatalogRequests.modelsURL(baseURL: baseURL),
            apiKey: credential.apiKey,
            timeout: ModelCatalogTimeouts.apiKeyProvider
        )
        let response = try await transport.send(request, cancellation: cancellation)
        try cancellation?.throwIfCancelled()

        guard response.isSuccess else {
            let body = String(decoding: response.body, as: UTF8.self)
            throw ModelsError.remoteMalformed(
                "\(partition.rawValue) models request returned \(response.status): "
                    + safeCatalogErrorExcerpt(body, apiKey: credential.apiKey)
            )
        }

        var entries = try project(response.body, baseURL)
        // Defense in depth: a projection must not emit another partition.
        entries.retain { _, entry in entry.info.provider == partition.provider }

        // Recheck the credential before publishing: an in-flight response must
        // not be attributed to a key the user has since changed.
        let current = await credentialSource()
        guard current?.fingerprint == credential.fingerprint else { return nil }

        return (entries, credential.fingerprint)
    }
}

// MARK: - RunInfra

/// RunInfra alone keeps its reviewed fallback when authenticated discovery fails.
public actor RunInfraCatalogActor {
    private let transport: any ModelCatalogTransport
    private let credentialSource: @Sendable () async -> ProviderCatalogCredential?
    private let baseURL: String

    public init(
        transport: any ModelCatalogTransport,
        credentialSource: @escaping @Sendable () async -> ProviderCatalogCredential?,
        baseURL: String = RunInfraModels.apiBaseURLDefault
    ) {
        self.transport = transport
        self.credentialSource = credentialSource
        self.baseURL = baseURL
    }

    public func fetch(
        cancellation: CancellationToken? = nil
    ) async throws -> RunInfraModelsCatalog? {
        try cancellation?.throwIfCancelled()
        guard let credential = await credentialSource(),
              !credential.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let catalog: RunInfraModelsCatalog
        do {
            let request = ModelCatalogRequests.bearerRequest(
                url: ModelCatalogRequests.modelsURL(baseURL: baseURL),
                apiKey: credential.apiKey,
                timeout: ModelCatalogTimeouts.apiKeyProvider
            )
            let response = try await transport.send(request, cancellation: cancellation)
            try cancellation?.throwIfCancelled()

            guard response.isSuccess else {
                let body = String(decoding: response.body, as: UTF8.self)
                throw ModelsError.remoteMalformed(
                    "runinfra models request returned \(response.status): "
                        + safeCatalogErrorExcerpt(body, apiKey: credential.apiKey)
                )
            }

            var discovered = try RunInfraModels.parseCatalogSnapshot(
                response.body,
                baseURL: baseURL,
                credentialFingerprint: credential.fingerprint
            )
            discovered.entries.retain { _, entry in entry.info.provider == .runinfra }
            catalog = discovered
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw error
            }
            try cancellation?.throwIfCancelled()
            catalog = RunInfraModelsCatalog(
                entries: RunInfraModels.curatedCatalog(baseURL: baseURL),
                credentialFingerprint: nil
            )
        }

        let current = await credentialSource()
        guard current?.fingerprint == credential.fingerprint,
              current?.apiKey == credential.apiKey else {
            return nil
        }
        try cancellation?.throwIfCancelled()
        return catalog
    }
}

// MARK: - Gemini

/// Authenticated Gemini discovery enriches its fixed reviewed model set.
public actor GeminiCatalogActor {
    private let transport: any ModelCatalogTransport
    private let credentialSource: @Sendable () async -> ProviderCatalogCredential?
    private let baseURL: String

    public init(
        transport: any ModelCatalogTransport,
        credentialSource: @escaping @Sendable () async -> ProviderCatalogCredential?,
        baseURL: String = GeminiModels.apiBaseURLDefault
    ) {
        self.transport = transport
        self.credentialSource = credentialSource
        self.baseURL = baseURL
    }

    public func fetch(
        cancellation: CancellationToken? = nil
    ) async throws -> GeminiModelsCatalog? {
        try cancellation?.throwIfCancelled()
        guard let credential = await credentialSource(),
              !credential.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              credential.fingerprint == GeminiModels.credentialFingerprint(apiKey: credential.apiKey) else {
            return nil
        }

        let catalog: GeminiModelsCatalog
        do {
            let request = ModelCatalogRequests.bearerRequest(
                url: ModelCatalogRequests.modelsURL(baseURL: baseURL),
                apiKey: credential.apiKey,
                timeout: ModelCatalogTimeouts.apiKeyProvider
            )
            let response = try await transport.send(request, cancellation: cancellation)
            try cancellation?.throwIfCancelled()

            guard response.isSuccess else {
                let body = String(decoding: response.body, as: UTF8.self)
                throw ModelsError.remoteMalformed(
                    "gemini models request returned \(response.status): "
                        + safeCatalogErrorExcerpt(body, apiKey: credential.apiKey)
                )
            }

            var discovered = try GeminiModels.enrichedCatalog(
                response.body,
                baseURL: baseURL,
                credentialFingerprint: credential.fingerprint
            )
            discovered.entries.retain { _, entry in entry.info.provider == .gemini }
            catalog = discovered
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw error
            }
            try cancellation?.throwIfCancelled()
            catalog = GeminiModelsCatalog(
                entries: GeminiModels.curatedCatalog(baseURL: baseURL),
                credentialFingerprint: credential.fingerprint
            )
        }

        let current = await credentialSource()
        guard current?.fingerprint == credential.fingerprint,
              current?.apiKey == credential.apiKey else {
            return nil
        }
        try cancellation?.throwIfCancelled()
        return catalog
    }
}

// MARK: - OpenRouter

/// OpenRouter carries mandatory attribution headers and its own BLAKE3 identity.
public actor OpenRouterCatalogActor {
    private let transport: any ModelCatalogTransport
    private let credentialSource: @Sendable () async -> ProviderCatalogCredential?
    private let baseURL: String

    public init(
        transport: any ModelCatalogTransport,
        credentialSource: @escaping @Sendable () async -> ProviderCatalogCredential?,
        baseURL: String = OpenRouterModels.apiBaseURLDefault
    ) {
        self.transport = transport
        self.credentialSource = credentialSource
        self.baseURL = baseURL
    }

    public func fetch(
        cancellation: CancellationToken? = nil
    ) async throws -> OpenRouterModelsCatalog? {
        try cancellation?.throwIfCancelled()
        guard let credential = await credentialSource(),
              !credential.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              credential.fingerprint == OpenRouterModels.credentialFingerprint(credential.apiKey) else {
            return nil
        }

        let request = OpenRouterModels.modelsRequest(
            apiKey: credential.apiKey,
            baseURL: baseURL
        )
        let response = try await transport.send(request, cancellation: cancellation)
        try cancellation?.throwIfCancelled()

        guard response.isSuccess else {
            let body = String(decoding: response.body, as: UTF8.self)
            throw ModelsError.remoteMalformed(
                "openrouter models request returned \(response.status): "
                    + safeCatalogErrorExcerpt(body, apiKey: credential.apiKey)
            )
        }

        var catalog = try OpenRouterModels.parseCatalogSnapshot(
            response.body,
            baseURL: baseURL,
            apiKey: credential.apiKey
        )
        catalog.entries.retain { _, entry in entry.info.provider == .openRouter }
        guard catalog.credentialFingerprint == credential.fingerprint else { return nil }

        let current = await credentialSource()
        guard current?.fingerprint == credential.fingerprint,
              current?.apiKey == credential.apiKey else {
            return nil
        }
        try cancellation?.throwIfCancelled()
        return catalog
    }
}

// MARK: - OpenCode Go

/// OpenCode Go catalog partition.
///
/// The models.dev metadata document is public and is fetched with **no**
/// Authorization header — the OpenCode Go key must not travel to a
/// third-party metadata host.
public actor OpenCodeGoCatalogActor {
    private let transport: any ModelCatalogTransport
    private let credentialSource: @Sendable () async -> ProviderCatalogCredential?
    private let baseURL: String
    private let modelsDevURL: String

    public init(
        transport: any ModelCatalogTransport,
        credentialSource: @escaping @Sendable () async -> ProviderCatalogCredential?,
        baseURL: String,
        modelsDevURL: String
    ) {
        self.transport = transport
        self.credentialSource = credentialSource
        self.baseURL = baseURL
        self.modelsDevURL = modelsDevURL
    }

    public func fetch(
        cancellation: CancellationToken? = nil
    ) async throws -> OpenCodeGoModelsCatalog? {
        try cancellation?.throwIfCancelled()
        guard let credential = await credentialSource() else { return nil }

        let listRequest = ModelCatalogRequests.bearerRequest(
            url: ModelCatalogRequests.modelsURL(baseURL: baseURL),
            apiKey: credential.apiKey,
            timeout: ModelCatalogTimeouts.apiKeyProvider
        )
        let metadataRequest = ModelCatalogRequest(
            url: modelsDevURL,
            headers: [],
            timeout: ModelCatalogTimeouts.apiKeyProvider
        )

        let transport = self.transport
        async let listTask = transport.send(listRequest, cancellation: cancellation)
        async let metadataTask = transport.send(metadataRequest, cancellation: cancellation)
        let (listResponse, metadataResponse) = try await (listTask, metadataTask)
        try cancellation?.throwIfCancelled()

        guard listResponse.isSuccess else {
            let body = String(decoding: listResponse.body, as: UTF8.self)
            throw ModelsError.remoteMalformed(
                "openCodeGo models request returned \(listResponse.status): "
                    + safeCatalogErrorExcerpt(body, apiKey: credential.apiKey)
            )
        }
        guard metadataResponse.isSuccess else {
            let body = String(decoding: metadataResponse.body, as: UTF8.self)
            throw ModelsError.remoteMalformed(
                "models.dev request returned \(metadataResponse.status): "
                    + safeCatalogErrorExcerpt(body, apiKey: credential.apiKey)
            )
        }

        let availableIDs = try OpenCodeGoModels.parseAvailableIDs(listResponse.body)
        let metadata = try OpenCodeGoModels.parseModelsDev(metadataResponse.body)
        var built = OpenCodeGoModels.catalog(
            availableIDs: availableIDs,
            metadata: metadata,
            baseURL: baseURL
        )
        built.entries.retain { _, entry in entry.info.provider == .openCodeGo }

        let current = await credentialSource()
        guard current?.fingerprint == credential.fingerprint else { return nil }

        return OpenCodeGoModelsCatalog(
            entries: built.entries,
            descriptors: built.descriptors,
            warnings: built.warnings,
            credentialFingerprint: credential.fingerprint
        )
    }
}

// MARK: - Partition factories

public enum ProviderCatalogActors {
    public static func wafer(
        transport: any ModelCatalogTransport,
        credentialSource: @escaping @Sendable () async -> ProviderCatalogCredential?,
        baseURL: String = WaferModels.apiBaseURLDefault
    ) -> APIKeyCatalogActor {
        APIKeyCatalogActor(
            partition: .wafer,
            transport: transport,
            credentialSource: credentialSource,
            baseURL: baseURL,
            project: { data, base in try WaferModels.parseCatalog(data, baseURL: base) }
        )
    }

    public static func kimi(
        transport: any ModelCatalogTransport,
        credentialSource: @escaping @Sendable () async -> ProviderCatalogCredential?,
        endpoint: KimiApiEndpoint,
        baseURL: String
    ) -> APIKeyCatalogActor {
        APIKeyCatalogActor(
            partition: .kimi,
            transport: transport,
            credentialSource: credentialSource,
            baseURL: baseURL,
            project: { data, base in
                try parseKimiModelsResponse(data, baseURL: base, endpoint: endpoint)
            }
        )
    }

    /// Fireworks queries `/models` only to enrich curated entries' context
    /// windows; the wire response never adds a model
    /// (`fireworks_models.rs:1-6, 257-290`).
    public static func fireworks(
        transport: any ModelCatalogTransport,
        credentialSource: @escaping @Sendable () async -> ProviderCatalogCredential?,
        baseURL: String = FireworksModels.apiBaseURLDefault
    ) -> APIKeyCatalogActor {
        APIKeyCatalogActor(
            partition: .fireworks,
            transport: transport,
            credentialSource: credentialSource,
            baseURL: baseURL,
            project: { data, base in
                let enrichment = try FireworksModels.parseContextEnrichment(data)
                return FireworksModels.curatedCatalog(
                    baseURL: base,
                    contextBySlug: enrichment
                )
            }
        )
    }

    /// OpenCode Go is the one partition needing two documents: the
    /// authenticated `/models` id list and the unauthenticated models.dev
    /// metadata, joined concurrently (`opencode_go_models.rs:165-195`,
    /// `tokio::try_join!`). It fails closed: a model with no metadata, or with
    /// an SDK whose wire protocol is unknown, is dropped with a warning.
    public static func openCodeGo(
        transport: any ModelCatalogTransport,
        credentialSource: @escaping @Sendable () async -> ProviderCatalogCredential?,
        baseURL: String = OpenCodeGoModels.apiBaseURLDefault,
        modelsDevURL: String = OpenCodeGoModels.modelsDevURL()
    ) -> OpenCodeGoCatalogActor {
        OpenCodeGoCatalogActor(
            transport: transport,
            credentialSource: credentialSource,
            baseURL: baseURL,
            modelsDevURL: modelsDevURL
        )
    }

    /// DeepSeek's `/models` names which curated models the key may reach.
    public static func deepSeek(
        transport: any ModelCatalogTransport,
        credentialSource: @escaping @Sendable () async -> ProviderCatalogCredential?,
        baseURL: String = DeepSeekModels.apiBaseURLDefault
    ) -> APIKeyCatalogActor {
        APIKeyCatalogActor(
            partition: .deepSeek,
            transport: transport,
            credentialSource: credentialSource,
            baseURL: baseURL,
            project: { data, base in
                let available = try DeepSeekModels.parseAvailableSlugs(data)
                var catalog = DeepSeekModels.curatedCatalog(baseURL: base)
                catalog.retain { _, entry in available.contains(entry.info.model) }
                return catalog
            }
        )
    }

    /// Meta's `/models` names which curated Muse Spark models the key may
    /// reach (`catalog_from_wire`, `meta_models.rs:203-224`).
    public static func meta(
        transport: any ModelCatalogTransport,
        credentialSource: @escaping @Sendable () async -> ProviderCatalogCredential?,
        baseURL: String = MetaModels.apiBaseURLDefault
    ) -> APIKeyCatalogActor {
        APIKeyCatalogActor(
            partition: .meta,
            transport: transport,
            credentialSource: credentialSource,
            baseURL: baseURL,
            project: { data, base in
                let available = try MetaModels.parseAvailableSlugs(data)
                var catalog = MetaModels.curatedCatalog(baseURL: base)
                catalog.retain { _, entry in available.contains(entry.info.model) }
                return catalog
            }
        )
    }

    /// Z AI's `/models` queries GLM models and falls back to curated models.
    public static func zai(
        transport: any ModelCatalogTransport,
        credentialSource: @escaping @Sendable () async -> ProviderCatalogCredential?,
        baseURL: String = ZaiModels.apiBaseURLDefault
    ) -> APIKeyCatalogActor {
        APIKeyCatalogActor(
            partition: .zai,
            transport: transport,
            credentialSource: credentialSource,
            baseURL: baseURL,
            project: { data, base in try ZaiModels.parseCatalog(data, baseURL: base) }
        )
    }

    public static func runinfra(
        transport: any ModelCatalogTransport,
        credentialSource: @escaping @Sendable () async -> ProviderCatalogCredential?,
        baseURL: String = RunInfraModels.apiBaseURLDefault
    ) -> RunInfraCatalogActor {
        RunInfraCatalogActor(
            transport: transport,
            credentialSource: credentialSource,
            baseURL: baseURL
        )
    }

    public static func gemini(
        transport: any ModelCatalogTransport,
        credentialSource: @escaping @Sendable () async -> ProviderCatalogCredential?,
        baseURL: String = GeminiModels.apiBaseURLDefault
    ) -> GeminiCatalogActor {
        GeminiCatalogActor(
            transport: transport,
            credentialSource: credentialSource,
            baseURL: baseURL
        )
    }

    public static func openRouter(
        transport: any ModelCatalogTransport,
        credentialSource: @escaping @Sendable () async -> ProviderCatalogCredential?,
        baseURL: String = OpenRouterModels.apiBaseURLDefault
    ) -> OpenRouterCatalogActor {
        OpenRouterCatalogActor(
            transport: transport,
            credentialSource: credentialSource,
            baseURL: baseURL
        )
    }
}
