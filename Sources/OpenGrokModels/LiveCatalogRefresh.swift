// LiveCatalogRefresh.swift
//
// Wiring between the per-partition catalog actors and `ModelsManager`.
//
// Blocking policy, ported exactly:
//   * Codex is the only catalog a session start awaits
//     (`acp_agent.rs:1129-1131` in `new_session`, `1608-1610` in
//     `load_session`), under `OnlineIfUncached` and a 5s request timeout. A
//     missing login returns immediately.
//   * Every other partition is fire-and-forget: upstream spawns them from
//     `set_gateway` (`agent/models.rs:460-468`) and each spawner returns
//     without awaiting. `refreshInBackground()` reproduces that; a failure
//     logs and keeps the current models.
//
// No partition refresh can fail a session start: `refreshInBackground` never
// throws, and `refreshCodexBlocking` swallows fetch errors the same way
// upstream's `if let Err(error) = … { tracing::warn!(…) }` does.

import Foundation
import OpenGrokSamplingTypes

/// The per-partition actors a `ModelsManager` may drive.
///
/// A `nil` partition is simply never refreshed, which is how an offline or
/// hermetic construction stays offline.
public struct LiveCatalogRefreshers: Sendable {
    public var codex: CodexCatalogActor?
    public var kimi: APIKeyCatalogActor?
    public var fireworks: APIKeyCatalogActor?
    public var deepSeek: APIKeyCatalogActor?
    public var meta: APIKeyCatalogActor?
    public var openCodeGo: OpenCodeGoCatalogActor?
    public var wafer: APIKeyCatalogActor?

    public init(
        codex: CodexCatalogActor? = nil,
        kimi: APIKeyCatalogActor? = nil,
        fireworks: APIKeyCatalogActor? = nil,
        deepSeek: APIKeyCatalogActor? = nil,
        meta: APIKeyCatalogActor? = nil,
        openCodeGo: OpenCodeGoCatalogActor? = nil,
        wafer: APIKeyCatalogActor? = nil
    ) {
        self.codex = codex
        self.kimi = kimi
        self.fireworks = fireworks
        self.deepSeek = deepSeek
        self.meta = meta
        self.openCodeGo = openCodeGo
        self.wafer = wafer
    }

    /// Build the full set from one transport and one credential broker.
    ///
    /// This is the isolation boundary: each actor is handed a closure already
    /// bound to its own partition, so no actor can name another's credentials.
    /// Partitions the broker has no key for still get an actor — it returns
    /// `nil` on refresh, leaving that partition embedded-only.
    public static func live(
        transport: any ModelCatalogTransport,
        broker: any ModelCatalogCredentialBroker,
        grokHome: URL,
        kimiEndpoint: KimiApiEndpoint = .platform,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        codexBaseURL: String? = nil
    ) -> LiveCatalogRefreshers {
        func source(_ partition: ModelCatalogPartition) -> @Sendable () async -> ProviderCatalogCredential? {
            { await broker.credential(for: partition) }
        }

        let kimiBase = KimiModels.apiBaseURL(kimiEndpoint, environment: environment)

        return LiveCatalogRefreshers(
            codex: CodexCatalogActor(
                transport: transport,
                cache: CodexModelsCacheManager(grokHome: grokHome),
                credentialSource: { force in await broker.codexCredential(forceRefresh: force) },
                baseURL: codexBaseURL ?? CodexModels.defaultInferenceBaseURL,
                clientVersion: CodexModels.clientVersion(environment: environment)
            ),
            kimi: ProviderCatalogActors.kimi(
                transport: transport,
                credentialSource: source(.kimi),
                endpoint: kimiEndpoint,
                baseURL: kimiBase
            ),
            fireworks: ProviderCatalogActors.fireworks(
                transport: transport,
                credentialSource: source(.fireworks),
                baseURL: FireworksModels.apiBaseURL(environment: environment)
            ),
            deepSeek: ProviderCatalogActors.deepSeek(
                transport: transport,
                credentialSource: source(.deepSeek),
                baseURL: DeepSeekModels.apiBaseURL(environment: environment)
            ),
            meta: ProviderCatalogActors.meta(
                transport: transport,
                credentialSource: source(.meta),
                baseURL: MetaModels.apiBaseURL(environment: environment)
            ),
            openCodeGo: ProviderCatalogActors.openCodeGo(
                transport: transport,
                credentialSource: source(.openCodeGo),
                baseURL: OpenCodeGoModels.apiBaseURL(environment: environment),
                modelsDevURL: OpenCodeGoModels.modelsDevURL(environment: environment)
            ),
            wafer: ProviderCatalogActors.wafer(
                transport: transport,
                credentialSource: source(.wafer),
                baseURL: WaferModels.apiBaseURL(environment: environment)
            )
        )
    }
}

/// Outcome of one partition refresh, for logging and tests.
public struct LiveCatalogRefreshOutcome: Sendable, Equatable {
    public var partition: ModelCatalogPartition
    /// `false` when the partition had no usable credential — expected, not a failure.
    public var published: Bool
    public var failure: String?

    public init(partition: ModelCatalogPartition, published: Bool, failure: String? = nil) {
        self.partition = partition
        self.published = published
        self.failure = failure
    }
}

public extension ModelsManager {
    /// Refresh Codex and await it — the one catalog a session start blocks on.
    ///
    /// Never throws: a failed refresh keeps the cached/embedded models, exactly
    /// like upstream's `tracing::warn!` at `acp_agent.rs:1129-1131`.
    @discardableResult
    func refreshCodexBlocking(
        forceOnline: Bool = false,
        cancellation: CancellationToken? = nil
    ) async -> LiveCatalogRefreshOutcome {
        guard let actor = liveCatalogRefreshers.codex else {
            return LiveCatalogRefreshOutcome(partition: .codex, published: false)
        }
        do {
            let catalog = forceOnline
                ? try await actor.fetchAndCache(cancellation: cancellation)
                : try await actor.loadFreshOrFetch(cancellation: cancellation)
            guard let catalog else {
                return LiveCatalogRefreshOutcome(partition: .codex, published: false)
            }
            applyCodexCatalog(catalog)
            return LiveCatalogRefreshOutcome(partition: .codex, published: true)
        } catch {
            return LiveCatalogRefreshOutcome(
                partition: .codex,
                published: false,
                failure: String(describing: error)
            )
        }
    }

    /// Refresh one non-Codex partition. Never throws.
    @discardableResult
    func refreshPartition(
        _ partition: ModelCatalogPartition,
        cancellation: CancellationToken? = nil
    ) async -> LiveCatalogRefreshOutcome {
        let refreshers = liveCatalogRefreshers
        do {
            switch partition {
            case .codex:
                return await refreshCodexBlocking(cancellation: cancellation)

            case .kimi:
                guard let actor = refreshers.kimi,
                      let result = try await actor.fetch(cancellation: cancellation) else {
                    return LiveCatalogRefreshOutcome(partition: partition, published: false)
                }
                applyKimiCatalog(
                    KimiModelsCatalog(
                        entries: result.entries,
                        endpoint: kimiEndpointForRefresh,
                        credentialFingerprint: result.fingerprint
                    )
                )

            case .fireworks:
                guard let actor = refreshers.fireworks,
                      let result = try await actor.fetch(cancellation: cancellation) else {
                    return LiveCatalogRefreshOutcome(partition: partition, published: false)
                }
                applyFireworksCatalog(
                    FireworksModelsCatalog(
                        entries: result.entries,
                        credentialFingerprint: result.fingerprint
                    )
                )

            case .deepSeek:
                guard let actor = refreshers.deepSeek,
                      let result = try await actor.fetch(cancellation: cancellation) else {
                    return LiveCatalogRefreshOutcome(partition: partition, published: false)
                }
                applyDeepSeekCatalog(
                    DeepSeekModelsCatalog(
                        entries: result.entries,
                        credentialFingerprint: result.fingerprint
                    )
                )

            case .meta:
                guard let actor = refreshers.meta,
                      let result = try await actor.fetch(cancellation: cancellation) else {
                    return LiveCatalogRefreshOutcome(partition: partition, published: false)
                }
                applyMetaCatalog(
                    MetaModelsCatalog(
                        entries: result.entries,
                        credentialFingerprint: result.fingerprint
                    )
                )

            case .openCodeGo:
                guard let actor = refreshers.openCodeGo,
                      let catalog = try await actor.fetch(cancellation: cancellation) else {
                    return LiveCatalogRefreshOutcome(partition: partition, published: false)
                }
                applyOpenCodeGoCatalog(catalog)

            case .wafer:
                guard let actor = refreshers.wafer,
                      let result = try await actor.fetch(cancellation: cancellation) else {
                    return LiveCatalogRefreshOutcome(partition: partition, published: false)
                }
                applyWaferCatalog(
                    WaferModelsCatalog(
                        entries: result.entries,
                        credentialFingerprint: result.fingerprint
                    )
                )
            }
            return LiveCatalogRefreshOutcome(partition: partition, published: true)
        } catch {
            return LiveCatalogRefreshOutcome(
                partition: partition,
                published: false,
                failure: String(describing: error)
            )
        }
    }

    /// Refresh every non-Codex partition concurrently.
    ///
    /// Upstream spawns these and never awaits them, so a caller that wants
    /// upstream's timing detaches this call rather than awaiting it. Returning
    /// the outcomes keeps the behavior testable without a sleep.
    @discardableResult
    func refreshBackgroundPartitions(
        cancellation: CancellationToken? = nil
    ) async -> [LiveCatalogRefreshOutcome] {
        await withTaskGroup(of: LiveCatalogRefreshOutcome.self) { group in
            for partition in ModelCatalogPartition.allCases where partition != .codex {
                group.addTask { await self.refreshPartition(partition, cancellation: cancellation) }
            }
            var outcomes: [LiveCatalogRefreshOutcome] = []
            for await outcome in group { outcomes.append(outcome) }
            return outcomes.sorted { $0.partition.rawValue < $1.partition.rawValue }
        }
    }
}
