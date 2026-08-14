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
import OpenGrokShared
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
    /// Non-secret digest for DeepSeek credential isolation.
    var deepSeekCredentialFingerprint: String? { get }
    /// Non-secret digest for Meta credential isolation.
    var metaCredentialFingerprint: String? { get }
    /// Non-secret digest for OpenCode Go credential isolation.
    var openCodeGoCredentialFingerprint: String? { get }
    /// Non-secret digest for Wafer credential isolation.
    var waferCredentialFingerprint: String? { get }
    /// Non-secret digest for Z AI credential isolation.
    var zaiCredentialFingerprint: String? { get }
}

public extension ModelCatalogCredentialSnapshot {
    // Defaulted so existing conformers keep compiling; a snapshot that does not
    // model a provider simply never publishes that provider's live catalog.
    var deepSeekCredentialFingerprint: String? { nil }
    var metaCredentialFingerprint: String? { nil }
    var openCodeGoCredentialFingerprint: String? { nil }
    var waferCredentialFingerprint: String? { nil }
    var zaiCredentialFingerprint: String? { nil }
}

/// Default empty credential snapshot (offline / hermetic tests).
public struct EmptyCredentialSnapshot: ModelCatalogCredentialSnapshot {
    public var hasXaiSession: Bool
    public var hasCodexSession: Bool
    public var codexAccountFingerprint: String?
    public var kimiCredentialFingerprint: String?
    public var fireworksCredentialFingerprint: String?
    public var deepSeekCredentialFingerprint: String?
    public var metaCredentialFingerprint: String?
    public var openCodeGoCredentialFingerprint: String?
    public var waferCredentialFingerprint: String?
    public var zaiCredentialFingerprint: String?

    public init(
        hasXaiSession: Bool = false,
        hasCodexSession: Bool = false,
        codexAccountFingerprint: String? = nil,
        kimiCredentialFingerprint: String? = nil,
        fireworksCredentialFingerprint: String? = nil,
        deepSeekCredentialFingerprint: String? = nil,
        metaCredentialFingerprint: String? = nil,
        openCodeGoCredentialFingerprint: String? = nil,
        waferCredentialFingerprint: String? = nil,
        zaiCredentialFingerprint: String? = nil
    ) {
        self.hasXaiSession = hasXaiSession
        self.hasCodexSession = hasCodexSession
        self.codexAccountFingerprint = codexAccountFingerprint
        self.kimiCredentialFingerprint = kimiCredentialFingerprint
        self.fireworksCredentialFingerprint = fireworksCredentialFingerprint
        self.deepSeekCredentialFingerprint = deepSeekCredentialFingerprint
        self.metaCredentialFingerprint = metaCredentialFingerprint
        self.openCodeGoCredentialFingerprint = openCodeGoCredentialFingerprint
        self.waferCredentialFingerprint = waferCredentialFingerprint
        self.zaiCredentialFingerprint = zaiCredentialFingerprint
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

public typealias CancellationToken = OpenGrokShared.CancellationToken

/// No-op transport that never hits the network.
public struct OfflineModelsTransport: XaiModelsTransport, CodexModelsTransport {
    public init() {}
    public func fetchModels(
        listURL: String,
        fetchAuth: ModelFetchAuth,
        cancellation: CancellationToken?
    ) async throws -> FetchModelsResult {
        try cancellation?.throwIfCancelled(ModelsError.cancelled)
        return FetchModelsResult(models: [], etag: nil)
    }
    public func fetchCodexModels(
        cancellation: CancellationToken?
    ) async throws -> (models: [CodexCatalogModel], etag: String?) {
        try cancellation?.throwIfCancelled(ModelsError.cancelled)
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
    private var deepSeekCatalog: DeepSeekModelsCatalog?
    private var metaCatalog: MetaModelsCatalog?
    private var openCodeGoCatalog: OpenCodeGoModelsCatalog?
    private var waferCatalog: WaferModelsCatalog?
    private var zaiCatalog: ZaiModelsCatalog?
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
    // Mutable (under `lock`) because a Kimi endpoint switch must rebuild the
    // Kimi partition actor at the new service's base URL — upstream rebuilds
    // its `kimi_client` inside `apply_config` (agent/models.rs:1029-1043).
    // A fixed refresher set would leave `open-grok/kimi/endpoint/apply`
    // refreshing against the OLD service while reporting the new one.
    private var liveCatalogs: LiveCatalogRefreshers

    public init(
        input: CatalogResolutionInput = .default,
        prefetched: OrderedModelMap? = nil,
        models: OrderedModelMap? = nil,
        currentModelID: String? = nil,
        credentials: any ModelCatalogCredentialSnapshot = EmptyCredentialSnapshot(),
        grokHome: URL? = nil,
        xaiTransport: any XaiModelsTransport = OfflineModelsTransport(),
        codexTransport: any CodexModelsTransport = OfflineModelsTransport(),
        liveCatalogs: LiveCatalogRefreshers = LiveCatalogRefreshers(),
        versionProvider: @escaping @Sendable () -> String = { OpenGrokVersion.installed() }
    ) {
        self.liveCatalogs = liveCatalogs
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

    /// The session-level reasoning effort. Port of
    /// `current_reasoning_effort` (agent/models.rs:1295-1297).
    public func currentReasoningEffortValue() -> ReasoningEffort? {
        lock.lock(); defer { lock.unlock() }
        return currentReasoningEffort
    }

    /// Record the effort a completed model switch applied. Port of
    /// `set_current_reasoning_effort` (agent/models.rs:1299-1301); upstream
    /// calls it right after `set_current_model_id` at the tail of
    /// `set_session_model` (handlers/model_switch.rs:299-303), which is why
    /// the CLI switch path calls the two together.
    public func setCurrentReasoningEffort(_ effort: ReasoningEffort?) {
        lock.lock(); defer { lock.unlock() }
        currentReasoningEffort = effort
    }

    public func allowlistExcludesAllModels() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return allowlistExcludesAll
    }

    /// Partition actors, for the refresh entry points in `LiveCatalogRefresh.swift`.
    var liveCatalogRefreshers: LiveCatalogRefreshers {
        lock.withLock { liveCatalogs }
    }

    /// Swap the partition actors — the Kimi endpoint switch's rebuild seam
    /// (upstream rebuilds `kimi_client` in `apply_config`,
    /// agent/models.rs:1029-1043). Callers pass a full set built by
    /// `LiveCatalogRefreshers.live`, so no partition is silently dropped.
    public func updateLiveCatalogRefreshers(_ refreshers: LiveCatalogRefreshers) {
        lock.withLock { liveCatalogs = refreshers }
    }

    /// The Kimi service partition a published live catalog belongs to.
    /// Platform and Code are non-interchangeable, so the snapshot records which.
    var kimiEndpointForRefresh: KimiApiEndpoint {
        lock.withLock { input.models.kimiEndpoint }
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

    public func applyDeepSeekCatalog(_ catalog: DeepSeekModelsCatalog?) {
        lock.lock()
        if let catalog,
           let expected = credentials.deepSeekCredentialFingerprint,
           catalog.credentialFingerprint != expected {
            lock.unlock()
            return
        }
        self.deepSeekCatalog = catalog
        lock.unlock()
        reassemble()
    }

    public func applyMetaCatalog(_ catalog: MetaModelsCatalog?) {
        lock.lock()
        if let catalog,
           let expected = credentials.metaCredentialFingerprint,
           catalog.credentialFingerprint != expected {
            lock.unlock()
            return
        }
        self.metaCatalog = catalog
        lock.unlock()
        reassemble()
    }

    public func applyOpenCodeGoCatalog(_ catalog: OpenCodeGoModelsCatalog?) {
        lock.lock()
        if let catalog,
           let expected = credentials.openCodeGoCredentialFingerprint,
           catalog.credentialFingerprint != expected {
            lock.unlock()
            return
        }
        self.openCodeGoCatalog = catalog
        lock.unlock()
        reassemble()
    }

    public func applyWaferCatalog(_ catalog: WaferModelsCatalog?) {
        lock.lock()
        if let catalog,
           let expected = credentials.waferCredentialFingerprint,
           catalog.credentialFingerprint != expected {
            lock.unlock()
            return
        }
        self.waferCatalog = catalog
        lock.unlock()
        reassemble()
    }

    public func applyZaiCatalog(_ catalog: ZaiModelsCatalog?) {
        lock.lock()
        if let catalog,
           let expected = credentials.zaiCredentialFingerprint,
           catalog.credentialFingerprint != expected {
            lock.unlock()
            return
        }
        self.zaiCatalog = catalog
        lock.unlock()
        reassemble()
    }

    /// Drop ONE provider's live catalog partition, report whether anything
    /// was actually dropped, and reselect if the current model vanished.
    ///
    /// Port of upstream's per-provider `clear_*_models` family
    /// (`agent/models.rs:556-570` codex, `:623-634` kimi, `:692-703`
    /// fireworks, `:768-779` deepseek, `:834-845` meta, `:911-922`
    /// opencode-go, `:977-988` wafer, `:1177-1188` zai): take the partition, rebuild, reselect
    /// if the current model is gone. Codex is the only partition with a
    /// disk cache; its arm also invalidates that cache and its `Bool` ORs
    /// in `had_cache` (`:560-562`), so "cleared: true" is honest when only
    /// the file existed. Upstream's per-partition generation counters are
    /// not ported — this manager serializes partition publishes under one
    /// lock, so the logout/publish race the counters guard cannot occur;
    /// the fingerprint gates in `apply*Catalog` still reject a stale-key
    /// publish.
    @discardableResult
    public func clearPartition(_ partition: ModelCatalogPartition) -> Bool {
        lock.lock()
        let hadCatalog: Bool
        var hadCache = false
        switch partition {
        case .codex:
            hadCatalog = codexCatalog != nil
            codexCatalog = nil
            hadCache = FileManager.default.fileExists(atPath: codexCache.path.path)
        case .kimi:
            hadCatalog = kimiCatalog != nil
            kimiCatalog = nil
        case .fireworks:
            hadCatalog = fireworksCatalog != nil
            fireworksCatalog = nil
        case .deepSeek:
            hadCatalog = deepSeekCatalog != nil
            deepSeekCatalog = nil
        case .meta:
            hadCatalog = metaCatalog != nil
            metaCatalog = nil
        case .openCodeGo:
            hadCatalog = openCodeGoCatalog != nil
            openCodeGoCatalog = nil
        case .wafer:
            hadCatalog = waferCatalog != nil
            waferCatalog = nil
        case .zai:
            hadCatalog = zaiCatalog != nil
            zaiCatalog = nil
        }
        lock.unlock()
        if partition == .codex {
            codexCache.invalidate()
        }
        reassemble()
        reselectAfterFetch(wasFirstFetch: false)
        return hadCatalog || hadCache
    }

    /// The `[models] kimi_endpoint` selection driving embedded-catalog
    /// assembly — the read half of `kimi_endpoint()`
    /// (`agent/models.rs:1168-1170`).
    public func kimiEndpointSelection() -> KimiApiEndpoint {
        lock.withLock { input.models.kimiEndpoint }
    }

    /// Apply a Kimi service selection to the resident catalog: swap the
    /// config knob and rebuild the embedded partition synchronously, exactly
    /// the config half of upstream's `apply_kimi_endpoint`
    /// (`agent/models.rs:1029-1036` — `cfg.models.kimi_endpoint = endpoint;
    /// self.apply_config(cfg)`). The live-refresh half stays with the caller,
    /// which must also swap the partition actors (`updateLiveCatalogRefreshers`)
    /// before refreshing, or the refresh hits the old service.
    public func applyKimiEndpointSelection(_ endpoint: KimiApiEndpoint) {
        lock.lock()
        input.models.kimiEndpoint = endpoint
        lock.unlock()
        reassemble()
        reselectAfterFetch(wasFirstFetch: false)
    }

    /// The configured OpenCode Go allowlist
    /// (`opencode_go_enabled_models`, agent/models.rs:1008-1015).
    public func openCodeGoEnabledModels() -> [String] {
        lock.withLock { input.models.opencodeGoEnabledModels }
    }

    /// Port of `apply_opencode_go_enabled_models` (agent/models.rs:1017-1023):
    /// sort + dedupe, swap the config knob, rebuild, reselect if the current
    /// model fell out of the allowlist.
    public func applyOpenCodeGoEnabledModels(_ enabledModels: [String]) {
        var enabled = enabledModels
        enabled.sort()
        var seen = Set<String>()
        enabled.removeAll { !seen.insert($0).inserted }
        lock.lock()
        input.models.opencodeGoEnabledModels = enabled
        lock.unlock()
        reassemble()
        reselectAfterFetch(wasFirstFetch: false)
    }

    /// The unfiltered OpenCode Go catalog descriptors for Settings
    /// (`opencode_go_models`, agent/models.rs:999-1006): empty when the
    /// partition has never been fetched.
    public func openCodeGoDescriptors() -> [OpenCodeGoModelDescriptor] {
        lock.withLock { openCodeGoCatalog?.descriptors ?? [] }
    }

    /// Clear provider-isolated remotes on identity change.
    public func clear(identityChange: Bool = true) {
        lock.lock()
        prefetched = nil
        codexCatalog = nil
        kimiCatalog = nil
        fireworksCatalog = nil
        deepSeekCatalog = nil
        metaCatalog = nil
        openCodeGoCatalog = nil
        waferCatalog = nil
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
            fireworksCatalog: fireworksCatalog,
            deepSeekCatalog: deepSeekCatalog,
            metaCatalog: metaCatalog,
            openCodeGoCatalog: openCodeGoCatalog,
            waferCatalog: waferCatalog,
            zaiCatalog: zaiCatalog
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

