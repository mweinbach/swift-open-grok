// ModelsManager.swift
//
// Thread-safe model catalog manager. Owns assembled catalog state, etag,
// current model selection, and provider-isolated remote partitions.
//
// Network transport and credentials are injected so this module stays free
// of OpenGrokAuth ownership and remains hermetically testable.

import Foundation
import OpenGrokConfigTypes
import OpenGrokPaths
import OpenGrokSamplingTypes
import OpenGrokVersion

// MARK: - Injection protocols

/// Provides bearer material for a provider without owning credential storage.
public protocol ModelCatalogCredentialSnapshot: Sendable {
    var hasXaiSession: Bool { get }
    var hasCodexSession: Bool { get }
    /// Non-secret digest for Codex account isolation (publish races).
    var codexAccountFingerprint: String? { get }
    /// Non-secret digest for Kimi credential isolation.
    var kimiCredentialFingerprint: String? { get }
    /// Non-secret digest for Fireworks credential isolation.
    var fireworksCredentialFingerprint: String? { get }
}

/// Default empty credential snapshot (offline / hermetic tests).
public struct EmptyCredentialSnapshot: ModelCatalogCredentialSnapshot {
    public var hasXaiSession: Bool
    public var hasCodexSession: Bool
    public var codexAccountFingerprint: String?
    public var kimiCredentialFingerprint: String?
    public var fireworksCredentialFingerprint: String?

    public init(
        hasXaiSession: Bool = false,
        hasCodexSession: Bool = false,
        codexAccountFingerprint: String? = nil,
        kimiCredentialFingerprint: String? = nil,
        fireworksCredentialFingerprint: String? = nil
    ) {
        self.hasXaiSession = hasXaiSession
        self.hasCodexSession = hasCodexSession
        self.codexAccountFingerprint = codexAccountFingerprint
        self.kimiCredentialFingerprint = kimiCredentialFingerprint
        self.fireworksCredentialFingerprint = fireworksCredentialFingerprint
    }
}

/// Fetches an xAI `/v1/models` payload. Implementations may hit the network
/// or return fixtures. Must honor cancellation.
public protocol XaiModelsTransport: Sendable {
    func fetchModels(
        listURL: String,
        fetchAuth: ModelFetchAuth,
        cancellation: CancellationToken?
    ) async throws -> FetchModelsResult
}

/// Fetches a Codex `/models` payload with Codex-only credentials.
public protocol CodexModelsTransport: Sendable {
    func fetchCodexModels(
        cancellation: CancellationToken?
    ) async throws -> (models: [CodexCatalogModel], etag: String?)
}

/// Simple cooperative cancellation token.
public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        _cancelled = true
    }

    public func throwIfCancelled() throws {
        if isCancelled { throw ModelsError.cancelled }
    }
}

/// No-op transport that never hits the network.
public struct OfflineModelsTransport: XaiModelsTransport, CodexModelsTransport {
    public init() {}
    public func fetchModels(
        listURL: String,
        fetchAuth: ModelFetchAuth,
        cancellation: CancellationToken?
    ) async throws -> FetchModelsResult {
        try cancellation?.throwIfCancelled()
        return FetchModelsResult(models: [], etag: nil)
    }
    public func fetchCodexModels(
        cancellation: CancellationToken?
    ) async throws -> (models: [CodexCatalogModel], etag: String?) {
        try cancellation?.throwIfCancelled()
        return ([], nil)
    }
}

// MARK: - Manager

/// Thread-safe model catalog manager.
public final class ModelsManager: @unchecked Sendable {
    private let lock = NSLock()

    private var prefetched: OrderedModelMap?
    private var codexCatalog: CodexModelsCatalog?
    private var kimiCatalog: KimiModelsCatalog?
    private var fireworksCatalog: FireworksModelsCatalog?
    private var models: OrderedModelMap
    private var currentModelID: String
    private var currentReasoningEffort: ReasoningEffort?
    private var etag: String?
    private var hasFetchedRealCatalog = false
    private var input: CatalogResolutionInput
    private var credentials: any ModelCatalogCredentialSnapshot
    private var allowlistExcludesAll = false
    private var modelSwitchGeneration: UInt64 = 0

    private let xaiCache: ModelsCacheManager
    private let codexCache: CodexModelsCacheManager
    private let xaiTransport: any XaiModelsTransport
    private let codexTransport: any CodexModelsTransport

    public init(
        input: CatalogResolutionInput = .default,
        prefetched: OrderedModelMap? = nil,
        models: OrderedModelMap? = nil,
        currentModelID: String? = nil,
        credentials: any ModelCatalogCredentialSnapshot = EmptyCredentialSnapshot(),
        grokHome: URL? = nil,
        xaiTransport: any XaiModelsTransport = OfflineModelsTransport(),
        codexTransport: any CodexModelsTransport = OfflineModelsTransport(),
        versionProvider: @escaping @Sendable () -> String = { OpenGrokVersion.installed() }
    ) {
        let home = grokHome
            ?? OpenGrokStatePaths.stateDirectory(
                environment: ProcessInfo.processInfo.environment
            )
        self.input = input
        self.prefetched = prefetched
        self.credentials = credentials
        self.xaiCache = ModelsCacheManager(grokHome: home, versionProvider: versionProvider)
        self.codexCache = CodexModelsCacheManager(grokHome: home)
        self.xaiTransport = xaiTransport
        self.codexTransport = codexTransport

        let assembled = resolveModelCatalog(
            input: input,
            prefetched: prefetched
        )
        self.models = models ?? assembled
        let resolved = resolveDefaultModel(
            input: input,
            catalog: self.models,
            hasXaiSession: credentials.hasXaiSession,
            hasCodexSession: credentials.hasCodexSession
        )
        self.currentModelID = currentModelID ?? resolved.catalogKey
        self.currentReasoningEffort = input.models.defaultReasoningEffort
            ?? resolved.entry.info.reasoningEffort
    }

    // MARK: Snapshots

    public func catalogSnapshot() -> OrderedModelMap {
        lock.lock(); defer { lock.unlock() }
        return models
    }

    public func currentModel() -> (id: String, entry: ModelEntry?) {
        lock.lock(); defer { lock.unlock() }
        return (currentModelID, models[currentModelID] ?? findModelByID(models, modelID: currentModelID))
    }

    public func currentETag() -> String? {
        lock.lock(); defer { lock.unlock() }
        return etag
    }

    public func modelSwitchGenerationValue() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return modelSwitchGeneration
    }

    public func allowlistExcludesAllModels() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return allowlistExcludesAll
    }

    public func capabilities(for modelID: String) -> ModelCapabilities? {
        lock.lock(); defer { lock.unlock() }
        return capabilitySnapshot(for: modelID, in: models)
    }

    // MARK: Mutation

    public func updateCredentials(_ credentials: any ModelCatalogCredentialSnapshot) {
        lock.lock()
        self.credentials = credentials
        lock.unlock()
        reassemble()
    }

    public func updateInput(_ input: CatalogResolutionInput) {
        lock.lock()
        self.input = input
        lock.unlock()
        reassemble()
    }

    public func setCurrentModelID(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        if currentModelID != id {
            currentModelID = id
            modelSwitchGeneration &+= 1
            if let entry = models[id] ?? findModelByID(models, modelID: id) {
                currentReasoningEffort = entry.info.reasoningEffort
            }
        }
    }

    public func applyPrefetched(_ prefetched: OrderedModelMap?, etag: String?) {
        lock.lock()
        self.prefetched = prefetched
        if let etag { self.etag = etag }
        let wasFirst = !hasFetchedRealCatalog
        if prefetched != nil { hasFetchedRealCatalog = true }
        lock.unlock()
        reassemble()
        reselectAfterFetch(wasFirstFetch: wasFirst)
    }

    public func applyCodexCatalog(_ catalog: CodexModelsCatalog?) {
        lock.lock()
        // Reject publish if account fingerprint no longer matches.
        if let catalog,
           let expected = credentials.codexAccountFingerprint,
           catalog.accountFingerprint != expected {
            lock.unlock()
            return
        }
        self.codexCatalog = catalog
        lock.unlock()
        reassemble()
    }

    public func applyKimiCatalog(_ catalog: KimiModelsCatalog?) {
        lock.lock()
        if let catalog,
           let expected = credentials.kimiCredentialFingerprint,
           catalog.credentialFingerprint != expected {
            lock.unlock()
            return
        }
        self.kimiCatalog = catalog
        lock.unlock()
        reassemble()
    }

    public func applyFireworksCatalog(_ catalog: FireworksModelsCatalog?) {
        lock.lock()
        if let catalog,
           let expected = credentials.fireworksCredentialFingerprint,
           catalog.credentialFingerprint != expected {
            lock.unlock()
            return
        }
        self.fireworksCatalog = catalog
        lock.unlock()
        reassemble()
    }

    /// Clear provider-isolated remotes on identity change.
    public func clear(identityChange: Bool = true) {
        lock.lock()
        prefetched = nil
        codexCatalog = nil
        kimiCatalog = nil
        fireworksCatalog = nil
        etag = nil
        hasFetchedRealCatalog = false
        lock.unlock()
        if identityChange {
            xaiCache.invalidate()
            codexCache.invalidate()
        }
        reassemble()
    }

    // MARK: Refresh

    /// Refresh the xAI catalog using the configured strategy.
    public func refreshXai(
        strategy: RefreshStrategy = .onlineIfUncached,
        cancellation: CancellationToken? = nil
    ) async throws {
        try cancellation?.throwIfCancelled()
        let snap = lock.withLock { (input, credentials) }
        let fetchAuth = ModelFetchAuth.resolve(
            endpoints: snap.0.endpoints,
            hasCachedSession: snap.1.hasXaiSession,
            hasXaiApiKeyEnv: ProcessInfo.processInfo.environment["XAI_API_KEY"] != nil
        )
        let origin = modelsListURL(endpoints: snap.0.endpoints, fetchAuth: fetchAuth)
        let cacheAuth = fetchAuth.cacheAuthMethod()

        if strategy != .online {
            if let cached = xaiCache.loadFresh(expectedAuth: cacheAuth, expectedOrigin: origin) {
                applyPrefetched(cached.models, etag: cached.etag)
                return
            }
            if strategy == .offline { return }
        }

        try cancellation?.throwIfCancelled()
        let result = try await xaiTransport.fetchModels(
            listURL: origin,
            fetchAuth: fetchAuth,
            cancellation: cancellation
        )
        try cancellation?.throwIfCancelled()
        guard !result.models.isEmpty else { return }

        let apiBaseOverride: String? = fetchAuth == .apiKey ? snap.0.endpoints.xaiApiBaseURL : nil
        let map = buildPrefetchedMap(models: result.models, apiBaseURLOverride: apiBaseOverride)
        try? xaiCache.persist(
            models: map,
            etag: result.etag,
            authMethod: cacheAuth,
            origin: origin
        )
        applyPrefetched(map, etag: result.etag)
    }

    /// Refresh the Codex catalog (isolated cache + credentials).
    public func refreshCodex(
        strategy: RefreshStrategy = .onlineIfUncached,
        cancellation: CancellationToken? = nil
    ) async throws {
        try cancellation?.throwIfCancelled()
        let fingerprint = lock.withLock { credentials.codexAccountFingerprint }
        guard let fingerprint else { return }

        if strategy != .online {
            if let cached = codexCache.loadFresh(expectedAccountFingerprint: fingerprint) {
                applyCodexCatalog(cached)
                return
            }
            if strategy == .offline { return }
        }

        try cancellation?.throwIfCancelled()
        let (models, etag) = try await codexTransport.fetchCodexModels(cancellation: cancellation)
        try cancellation?.throwIfCancelled()
        // Re-check fingerprint before publish.
        let still = lock.withLock { credentials.codexAccountFingerprint }
        guard still == fingerprint else { return }
        let catalog = CodexModelsCatalog(
            models: models,
            etag: etag,
            accountFingerprint: fingerprint
        )
        try? codexCache.persist(catalog)
        applyCodexCatalog(catalog)
    }

    // MARK: Internals

    private func reassemble() {
        lock.lock()
        let assembled = resolveModelCatalog(
            input: input,
            prefetched: prefetched,
            codexCatalog: codexCatalog,
            kimiCatalog: kimiCatalog,
            fireworksCatalog: fireworksCatalog
        )
        models = assembled
        allowlistExcludesAll = allowlistMatchesNothing(input: input, catalog: assembled)
        lock.unlock()
    }

    private func reselectAfterFetch(wasFirstFetch: Bool) {
        lock.lock()
        let cfg = input
        let catalog = models
        let creds = credentials
        let current = currentModelID
        lock.unlock()

        if wasFirstFetch {
            // First real catalog: re-resolve the default preference.
            let resolved = resolveDefaultModel(
                input: cfg,
                catalog: catalog,
                hasXaiSession: creds.hasXaiSession,
                hasCodexSession: creds.hasCodexSession
            )
            setCurrentModelID(resolved.catalogKey)
        } else {
            // Subsequent: reselect only if current is missing.
            let stillPresent = catalog[current] != nil
                || findModelByID(catalog, modelID: current) != nil
            if !stillPresent {
                let resolved = resolveDefaultModel(
                    input: cfg,
                    catalog: catalog,
                    hasXaiSession: creds.hasXaiSession,
                    hasCodexSession: creds.hasCodexSession
                )
                setCurrentModelID(resolved.catalogKey)
            }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}

