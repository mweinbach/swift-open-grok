// LiveModelSwitch.swift
//
// Live `/model` switching for the interactive composition.
//
// The reference shell rebuilds the harness in place when `/model` picks a new
// model: the provider-dependent state (credential, base URL, backend, sampler)
// is rebuilt, and the session — its id, its ownership, its conversation — is
// kept. PORT_PLAN.md W?-"live model switches rebuild only provider-dependent
// state, preserve session ownership/history, hide incompatible tools/media, and
// never leak credentials or opaque history".
//
// Two rules do the load-bearing work here:
//
//  1. **Fail closed.** Nothing mutates until the new model has resolved *and*
//     its credential has resolved *and* the sampler has been built. A switch to
//     a provider the machine cannot authenticate leaves the old model running
//     and reports why.
//  2. **Opaque history never crosses a provider boundary.** Reasoning items,
//     backend tool calls and tool plumbing are provider-native carriers; replayed
//     to a different provider they are at best rejected and at worst leak state.
//     A provider change rewrites history to its provider-neutral text spine.

import Foundation
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokHTTP
import OpenGrokModels
import OpenGrokProviderSession
import OpenGrokSamplingTypes

func liveConfiguredModelCatalog(
    workingDirectory: URL,
    environment: [String: String]
) -> ConfiguredModelCatalog {
    let authority = try? loadAuthorityComposition(
        cwd: workingDirectory,
        environment: environment
    )
    let trusted = (try? ConfigLayers.load(environment: environment))
        .map { parseProviderDefinitions(from: $0.effectiveConfigBase()) }
    return parseConfiguredModelCatalog(
        from: authority?.effective() ?? .table(TOMLTable()),
        trustedProviderDefinitions: trusted,
        environment: environment
    )
}

/// A model resolved against the embedded catalog together with the credential
/// its provider requires.
struct LiveModelResolution: Sendable {
    let sampling: OpenGrokLiveSamplingConfiguration
    let credential: LiveResolvedCredential
}

enum LiveModelSwitchError: Error, Sendable, Equatable, CustomStringConvertible {
    case unknownModel(String)
    case unsupportedBackend(provider: ModelProvider, backend: ApiBackend)
    case unsupportedBaseURL(provider: ModelProvider, baseURL: String)
    case credentialsUnavailable(provider: ModelProvider, detail: String)

    var description: String {
        switch self {
        case .unknownModel(let id):
            return "unknown model '\(id)'"
        case .unsupportedBackend(let provider, let backend):
            return "provider \(provider.asString) does not support \(backend.rawValue)"
        case .unsupportedBaseURL(let provider, let baseURL):
            return "provider \(provider.asString) cannot use endpoint \(baseURL)"
        case .credentialsUnavailable(let provider, let detail):
            return "\(provider.asString) is not authenticated: \(detail)"
        }
    }
}

/// Resolves a model id from the embedded catalog into everything a live
/// sampling session needs, including a freshly resolved provider credential.
///
/// This is the same ladder the launcher walks at startup, reduced to the one
/// input `/model` supplies — a model id — so a mid-session switch and a cold
/// start cannot drift apart.
struct LiveModelCatalogResolver: Sendable {
    let environment: [String: String]
    let openGrokHome: URL
    let sessionID: String
    /// Project root for the `[endpoints]` config lookup. A mid-session switch
    /// has to read the same config chain the cold start did, or the two
    /// disagree about the endpoint for the same model.
    ///
    /// Deliberately has no default. The process cwd is *not* the session's
    /// working directory — `--cwd` is a supported flag, which is why
    /// `makeSessionFoundation` resolves it through
    /// `resolveWorkingDirectory(options.common.cwd)`. A defaulted parameter
    /// would let a future call site silently read the config chain from the
    /// wrong directory, reintroducing exactly the cold-start/switch divergence
    /// this field exists to prevent, with no compiler error and no test
    /// failure. Requiring it turns that into a build error instead.
    let workingDirectory: URL
    let catalogSource: @Sendable () -> OrderedModelMap
    let authProviderDefinitions: @Sendable () -> [(String, AuthProviderConfig)]
    /// Injection seam for tests; production passes the real resolver.
    let makeCredentialResolver: @Sendable (
        [String: String],
        URL
    ) -> LiveCredentialResolver

    init(
        environment: [String: String],
        openGrokHome: URL,
        sessionID: String,
        workingDirectory: URL,
        catalogSource: @escaping @Sendable () -> OrderedModelMap = {
            resolveModelCatalog(input: .default)
        },
        authProviderDefinitions: @escaping @Sendable () -> [(String, AuthProviderConfig)] = { [] },
        makeCredentialResolver: @escaping @Sendable (
            [String: String],
            URL
        ) -> LiveCredentialResolver = { environment, openGrokHome in
            // The SAME resolver the cold start builds (LiveComposition.swift
            // `resolveSamplingConfiguration`), live Codex refresh included.
            // The default `.storeOnly` service hands back whatever token is
            // on disk — expired included — so a mid-session switch to Codex
            // would ship a stale bearer the cold start would have refreshed,
            // violating the resolver's no-stale-fallback contract on exactly
            // one of the two paths.
            LiveCredentialResolver(
                environment: environment,
                openGrokHome: openGrokHome,
                codexRefreshService: .live(
                    endpoints: CodexEndpoints.fromEnvironment(environment),
                    transport: URLSessionHTTPTransport()
                )
            )
        }
    ) {
        self.environment = environment
        self.openGrokHome = openGrokHome
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.catalogSource = catalogSource
        self.authProviderDefinitions = authProviderDefinitions
        self.makeCredentialResolver = makeCredentialResolver
    }

    /// Every model the `/model` picker should offer. Hidden entries stay hidden.
    ///
    /// Ordering is left to `LiveModelPicker.rows`, which sorts by provider then
    /// name — sorting by raw id here would interleave providers.
    static func catalog() -> [LiveModelPickerEntry] {
        entries(from: resolveModelCatalog(input: .default))
    }

    func catalogEntries() -> [LiveModelPickerEntry] {
        Self.entries(from: catalogSource())
    }

    static func entries(from catalog: OrderedModelMap) -> [LiveModelPickerEntry] {
        catalog.pairs().compactMap { key, entry in
            guard !entry.info.hidden, entry.info.userSelectable else { return nil }
            return LiveModelPickerEntry(
                id: key,
                providerID: entry.info.provider.asString,
                name: entry.info.name ?? entry.info.model,
                description: entry.info.description,
                contextWindow: entry.info.contextWindow,
                supportsReasoningEffort: entry.info.supportsReasoningEffort,
                defaultReasoningEffort: entry.info.reasoningEffort,
                reasoningEfforts: entry.info.reasoningEfforts,
                serviceTiers: entry.info.serviceTiers
            )
        }
    }

    /// `effort` is a validated per-switch reasoning-effort override
    /// (`/model <name> <effort>`). It applies only when the catalog entry
    /// declares effort support; on a non-supporting model it is ignored and
    /// the switch proceeds, exactly like upstream's meta override
    /// (`set_session_model`, handlers/model_switch.rs:139-158).
    ///
    /// `serviceTier` is the session's tier selection (`/fast`). It survives
    /// the switch only when the target entry advertises the tier id; a model
    /// without it resolves to standard routing, which is upstream's
    /// clear-if-unsupported rule (`set_current`, acp/model_state.rs:199-212).
    func resolve(
        modelID: String,
        effort: ReasoningEffort? = nil,
        serviceTier: String? = nil
    ) async throws -> LiveModelResolution {
        let catalog = catalogSource()
        guard let entry = findModelByID(catalog, modelID: modelID) else {
            throw LiveModelSwitchError.unknownModel(modelID)
        }
        let profile = DefaultModelJSON.fromCatalogEntry(entry)
        let provider = profile.provider
        let backend = profile.apiBackend
        guard provider.profile.supportsBackend(backend) else {
            throw LiveModelSwitchError.unsupportedBackend(provider: provider, backend: backend)
        }
        // Upstream ranks the config file above the environment for the one
        // endpoint override it defines (`from_config_value` deep-merges
        // `[endpoints]` over the env-derived default, agent/config.rs:365).
        // The cold start applies that leg, so a `/model` switch has to as well
        // — otherwise the same model reaches a different endpoint depending on
        // whether you started on it or switched to it. The key is xAI-only
        // upstream; every other provider keeps its own `*_API_BASE_URL` env var.
        let baseURL: String
        if provider == .xai, entry.apiBaseURL == XAI_API_BASE_URL_DEFAULT {
            baseURL = OpenGrokLiveApplicationLauncher.resolveProviderBaseURL(
                provider: provider,
                model: profile,
                environment: environment,
                configuredXaiBaseURL: OpenGrokLiveApplicationLauncher.configuredXaiAPIBaseURL(
                    workingDirectory: workingDirectory,
                    openGrokHome: openGrokHome,
                    environment: environment
                )
            )
        } else if provider != .xai,
                  let envOverride = OpenGrokLiveApplicationLauncher.providerBaseURLEnvironmentOverride(
                      provider: provider,
                      environment: environment
                  ) {
            // The env override outranks the catalog entry's URL for non-xAI
            // providers, matching the cold start's ladder — without this rung
            // a switched-to model reached the entry's endpoint while a
            // started-on model honored the override. (xAI keeps its
            // config-beats-env branch above.)
            baseURL = envOverride
        } else if let apiBaseURL = entry.apiBaseURL {
            baseURL = apiBaseURL
        } else if !entry.info.baseURL.isEmpty {
            baseURL = entry.info.baseURL
        } else {
            baseURL = OpenGrokLiveApplicationLauncher.resolveProviderBaseURL(
                provider: provider,
                model: profile,
                environment: environment,
                configuredXaiBaseURL: provider == .xai
                    ? OpenGrokLiveApplicationLauncher.configuredXaiAPIBaseURL(
                        workingDirectory: workingDirectory,
                        openGrokHome: openGrokHome,
                        environment: environment
                    )
                    : nil
            )
        }
        if provider == .kimi,
           let modelBaseURL = profile.baseURL,
           let modelEndpoint = KimiModels.endpoint(forBaseURL: modelBaseURL),
           let resolvedEndpoint = KimiModels.endpoint(forBaseURL: baseURL),
           modelEndpoint != resolvedEndpoint {
            throw LiveModelSwitchError.unsupportedBaseURL(provider: provider, baseURL: baseURL)
        }
        let namedAuthResolver: NamedAuthProviderResolver?
        if let authProvider = entry.authProvider {
            guard let definition = authProviderDefinitions().first(where: { $0.0 == authProvider })?.1 else {
                throw LiveModelSwitchError.credentialsUnavailable(
                    provider: provider,
                    detail: "named auth provider '\(authProvider)' is unavailable"
                )
            }
            namedAuthResolver = NamedAuthProviderResolver(configuration: definition)
        } else {
            namedAuthResolver = nil
        }
        let explicitAPIKey: String?
        if namedAuthResolver != nil {
            explicitAPIKey = nil
        } else if let own = entry.ownCredential(environment: environment) {
            explicitAPIKey = own
        } else {
            explicitAPIKey = try OpenGrokLiveApplicationLauncher.resolveProviderAPIKey(
                provider: provider,
                model: profile,
                baseURL: baseURL,
                environment: environment
            )
        }
        let credential: LiveResolvedCredential
        if let namedAuthResolver {
            guard let token = namedAuthResolver.currentToken(), !token.isEmpty else {
                throw LiveModelSwitchError.credentialsUnavailable(
                    provider: provider,
                    detail: "named auth provider did not return a usable credential"
                )
            }
            credential = LiveResolvedCredential(
                provider: provider,
                scope: "cli:\(sessionID)",
                source: .namedAuthProvider,
                authKind: .apiKeyOnly,
                bearer: token,
                binding: .apiKey(scope: "cli:\(sessionID)", key: token)
            )
        } else {
            do {
                // The resolved endpoint travels with the request so a stored
                // provider key can be withheld from an untrusted host
                // (upstream resolve_credentials, agent/config.rs:5486-5503).
                credential = try await makeCredentialResolver(environment, openGrokHome).resolve(
                    provider: provider,
                    explicitAPIKey: explicitAPIKey,
                    baseURL: baseURL,
                    scope: "cli:\(sessionID)"
                )
            } catch let error as LiveCredentialError {
                throw LiveModelSwitchError.credentialsUnavailable(
                    provider: provider,
                    detail: error.description
                )
            }
        }
        // The cold start's guarded merge, not a plain overlay: a configured
        // entry's `extra_headers` must not override the credential's
        // Authorization or Codex account-pinning headers mid-switch when the
        // startup path would have refused the same override.
        let headers = OpenGrokLiveApplicationLauncher.mergeCredentialHeaders(
            provider: provider,
            credentialHeaders: credential.extraHeaders,
            configuredHeaders: entry.info.extraHeaders
        )
        return LiveModelResolution(
            sampling: OpenGrokLiveSamplingConfiguration(
                model: profile.model,
                baseURL: baseURL,
                apiKey: credential.bearer,
                provider: provider,
                apiBackend: backend,
                extraHeaders: headers,
                queryParams: entry.queryParams,
                tuning: OpenGrokLiveSamplingTuning(
                    entry: entry,
                    effortOverride: effort,
                    serviceTier: serviceTier
                ),
                bearerResolver: namedAuthResolver.map(NamedAuthBearerResolver.init),
                credentialProvider: credential.binding.authCredentialProvider
            ),
            credential: credential
        )
    }
}

/// What a `/model` selection did.
enum LiveModelSwitchOutcome: Sendable, Equatable {
    /// The picked model is already the active one.
    case unchanged(modelID: String)
    case switched(LiveModelSwitchSummary)
    /// The switch was refused; the previous model is still active.
    case failed(modelID: String, message: String)
}

/// What a mid-session credential rebind did
/// (`LiveModelSwitchCoordinator.rebindCredential`).
enum LiveCredentialRebindOutcome: Sendable, Equatable {
    /// The session is on a different provider; its sampler holds no
    /// credential of the applied provider, so there is nothing to rebind.
    case notActive(activeProvider: ModelProvider)
    /// The active route re-resolved and the sampler was swapped; the next
    /// sampling request carries the freshly resolved credential.
    case rebound(provider: ModelProvider)
    /// Resolution or sampler construction failed; the previous sampler and
    /// its previous credential remain live.
    case failed(message: String)
}

struct LiveModelSwitchSummary: Sendable, Equatable {
    /// The wire model name now being sent. This is what the composer's border
    /// shows, so it has to be the name the provider actually receives.
    let modelID: String
    /// The catalog id the user picked (`glm-5.2`), used in prose.
    let requestedID: String
    let provider: ModelProvider
    let previousModelID: String
    let previousProvider: ModelProvider
    /// Provider-opaque history items dropped because the provider changed.
    let droppedOpaqueItems: Int
    /// The reasoning effort the new sampling stack sends — the chosen override
    /// when one was given, else the model's catalog default, `nil` on models
    /// with no selectable effort. The composer's border renders this.
    let reasoningEffort: ReasoningEffort?
    /// The effort before this switch, for the tier-only-toggle classification
    /// below (upstream's `model_or_effort_changed`, lifecycle.rs:1407-1408).
    let previousReasoningEffort: ReasoningEffort?
    /// The service tier the new sampling stack sends (`"priority"` when Fast
    /// mode is on); `nil` is standard routing.
    let serviceTier: String?
    /// The tier before this switch, so the renderer can tell a tier-only
    /// toggle (which upstream reports as "Fast mode enabled/disabled",
    /// dispatch/session/lifecycle.rs:1412-1417) from a model change.
    let previousServiceTier: String?
    /// Whether Fast mode is on after this switch — the tier equals the fast
    /// wire value (or its `fast` alias) AND the model still advertises it
    /// (`fast_mode_enabled`, acp/model_state.rs:232-237).
    let fastModeEnabled: Bool

    var changedProvider: Bool { provider != previousProvider }
    var serviceTierChanged: Bool { serviceTier != previousServiceTier }

    /// The system message the transcript records for this switch.
    ///
    /// A tier-only toggle takes upstream's copy byte-for-byte
    /// (lifecycle.rs:1413-1417); a model/effort change keeps this port's
    /// message shape with upstream's " · Fast" marker appended while Fast
    /// mode stays on (lifecycle.rs:1424-1426).
    var transcriptMessage: String {
        if modelID == previousModelID,
           reasoningEffort == previousReasoningEffort,
           serviceTierChanged {
            return fastModeEnabled ? "Fast mode enabled" : "Fast mode disabled"
        }
        var text = "Switched to \(requestedID)"
        if changedProvider {
            text += " (\(previousProvider.asString) → \(provider.asString))"
        }
        text += "."
        if droppedOpaqueItems > 0 {
            let plural = droppedOpaqueItems == 1 ? "item" : "items"
            text += " Dropped \(droppedOpaqueItems) provider-specific history "
                + "\(plural); the conversation text is preserved."
        }
        if fastModeEnabled {
            text += " · Fast"
        }
        return text
    }
}

/// Owns the sampler the live turn driver uses, so `/model` can replace it
/// between turns without rebuilding the shell, the session or the tool runtime.
actor LiveModelSwitchCoordinator {
    /// The provider-dependent state one turn runs against. Taken once at the
    /// start of a turn so a switch cannot swap providers mid tool loop.
    struct Snapshot: Sendable {
        let sampler: OpenGrokLiveSampler
        let modelID: String
        let provider: ModelProvider
        /// The full provider configuration this turn runs against. Compaction
        /// needs the base URL and credential headers to reach Codex's
        /// server-side compaction endpoint, which is not a sampling call and so
        /// cannot borrow the sampler's already-built client.
        let configuration: OpenGrokLiveSamplingConfiguration
    }

    private var sampling: OpenGrokLiveSamplingConfiguration
    private var sampler: OpenGrokLiveSampler
    private let resolver: LiveModelCatalogResolver
    private let makeSampler: @Sendable (OpenGrokLiveSamplingConfiguration) throws -> OpenGrokLiveSampler
    private let history: LiveConversationHistory?
    /// Notified after a successful switch so the Code Mode runtime can drop
    /// cells that belong to the provider being left behind.
    private var codeMode: LiveCodeModeCoordinator?

    init(
        sampling: OpenGrokLiveSamplingConfiguration,
        sampler: OpenGrokLiveSampler,
        resolver: LiveModelCatalogResolver,
        makeSampler: @escaping @Sendable (OpenGrokLiveSamplingConfiguration) throws -> OpenGrokLiveSampler,
        history: LiveConversationHistory?
    ) {
        self.sampling = sampling
        self.sampler = sampler
        self.resolver = resolver
        self.makeSampler = makeSampler
        self.history = history
    }

    func attachCodeMode(_ coordinator: LiveCodeModeCoordinator?) {
        codeMode = coordinator
    }

    func snapshot() -> Snapshot {
        Snapshot(
            sampler: sampler,
            modelID: sampling.model,
            provider: sampling.provider,
            configuration: sampling
        )
    }

    var activeModelID: String { sampling.model }
    var activeProvider: ModelProvider { sampling.provider }
    /// The tier the live sampler is actually built with — the `/fast` state
    /// derives from here, never from a controller-side mirror.
    var activeServiceTier: String? { sampling.serviceTier }

    /// Rebuild the sampling stack for `modelID`.
    ///
    /// Resolution, credential lookup and sampler construction all happen before
    /// any state changes, so a failure leaves the session exactly as it was.
    ///
    /// `effort` is a validated reasoning-effort override from
    /// `/model <name> <effort>`. Re-picking the active model is only a no-op
    /// when the effort would not change either — upstream applies an effort
    /// override through the same SetSessionModel path even when the model id
    /// is unchanged (handlers/model_switch.rs:139-158, :280).
    ///
    /// `serviceTier` follows upstream's `SwitchModel.service_tier:
    /// Option<Option<String>>` (app/actions.rs via fast.rs:39-51): the outer
    /// `nil` preserves the session's tier across the switch (cleared by the
    /// resolver when the target model does not advertise it), `.some(nil)` is
    /// the explicit return to standard routing, and `.some(.some(id))`
    /// selects a tier. `/fast` is a switch to the SAME model with a different
    /// tier — the toggle rides this path rather than a parallel tier-set one.
    func apply(
        modelID: String,
        effort: ReasoningEffort? = nil,
        serviceTier: String?? = nil
    ) async -> LiveModelSwitchOutcome {
        let previous = sampling
        let requestedTier: String?
        switch serviceTier {
        case .none: requestedTier = previous.serviceTier
        case .some(let selection): requestedTier = selection
        }
        let requestedProvider = findModelByID(
            resolver.catalogSource(),
            modelID: modelID
        )?.info.provider
        let picksActiveModel = requestedProvider == previous.provider
            && (modelID == previous.model || modelID == activeCatalogID(for: previous))
        if picksActiveModel,
           effort == nil || effort == previous.reasoningEffort,
           requestedTier == previous.serviceTier {
            return .unchanged(modelID: modelID)
        }
        let resolution: LiveModelResolution
        do {
            resolution = try await resolver.resolve(
                modelID: modelID,
                effort: effort,
                serviceTier: requestedTier
            )
        } catch let error as LiveModelSwitchError {
            return .failed(modelID: modelID, message: error.description)
        } catch {
            return .failed(modelID: modelID, message: String(describing: error))
        }
        guard !hasSameSamplingRoute(resolution.sampling, previous) else {
            return .unchanged(modelID: modelID)
        }
        let rebuilt: OpenGrokLiveSampler
        do {
            rebuilt = try makeSampler(resolution.sampling)
        } catch {
            return .failed(modelID: modelID, message: String(describing: error))
        }

        var dropped = 0
        if let history {
            do {
                dropped = try await history.reconcileRoute(
                    modelID: resolution.sampling.model,
                    provider: resolution.sampling.provider
                )
            } catch {
                return .failed(
                    modelID: modelID,
                    message: "provider isolation failed: \(String(describing: error))"
                )
            }
        }
        sampling = resolution.sampling
        sampler = rebuilt
        await codeMode?.noteModelSwitch(
            from: previous.provider,
            to: resolution.sampling.provider
        )
        return .switched(LiveModelSwitchSummary(
            modelID: resolution.sampling.model,
            requestedID: modelID,
            provider: resolution.sampling.provider,
            previousModelID: previous.model,
            previousProvider: previous.provider,
            droppedOpaqueItems: dropped,
            reasoningEffort: resolution.sampling.reasoningEffort,
            previousReasoningEffort: previous.reasoningEffort,
            serviceTier: resolution.sampling.serviceTier,
            previousServiceTier: previous.serviceTier,
            fastModeEnabled: liveFastModeEnabled(
                serviceTier: resolution.sampling.serviceTier,
                supportsFast: resolvedEntrySupportsFast(resolution.sampling)
            )
        ))
    }

    /// Apply a `reconcileModelState` result as an exact (model, effort, tier)
    /// tuple. Unlike `apply`, this path does not treat `effort == nil` as
    /// "no effort change" — that would short-circuit the lost-support clear
    /// branch (`model_state.rs:178-188`) and leave a 400-bound effort live.
    /// Callers must only invoke this when `samplerNeedsRebuild` is true.
    func applyReconciled(
        modelID: String,
        effort: ReasoningEffort?,
        serviceTier: String?
    ) async -> LiveModelSwitchOutcome {
        let previous = sampling
        let resolution: LiveModelResolution
        do {
            resolution = try await resolver.resolve(
                modelID: modelID,
                effort: effort,
                serviceTier: serviceTier
            )
        } catch let error as LiveModelSwitchError {
            return .failed(modelID: modelID, message: error.description)
        } catch {
            return .failed(modelID: modelID, message: String(describing: error))
        }
        guard !hasSameSamplingRoute(resolution.sampling, previous) else {
            return .unchanged(modelID: modelID)
        }
        let rebuilt: OpenGrokLiveSampler
        do {
            rebuilt = try makeSampler(resolution.sampling)
        } catch {
            return .failed(modelID: modelID, message: String(describing: error))
        }

        var dropped = 0
        if let history {
            do {
                dropped = try await history.reconcileRoute(
                    modelID: resolution.sampling.model,
                    provider: resolution.sampling.provider
                )
            } catch {
                return .failed(
                    modelID: modelID,
                    message: "provider isolation failed: \(String(describing: error))"
                )
            }
        }
        sampling = resolution.sampling
        sampler = rebuilt
        await codeMode?.noteModelSwitch(
            from: previous.provider,
            to: resolution.sampling.provider
        )
        return .switched(LiveModelSwitchSummary(
            modelID: resolution.sampling.model,
            requestedID: modelID,
            provider: resolution.sampling.provider,
            previousModelID: previous.model,
            previousProvider: previous.provider,
            droppedOpaqueItems: dropped,
            reasoningEffort: resolution.sampling.reasoningEffort,
            previousReasoningEffort: previous.reasoningEffort,
            serviceTier: resolution.sampling.serviceTier,
            previousServiceTier: previous.serviceTier,
            fastModeEnabled: liveFastModeEnabled(
                serviceTier: resolution.sampling.serviceTier,
                supportsFast: resolvedEntrySupportsFast(resolution.sampling)
            )
        ))
    }

    /// Re-resolve the ACTIVE model's credential from its stores and swap the
    /// sampler, without changing model, effort, or tier.
    ///
    /// This is the port's live-session half of
    /// `open-grok/{provider}/models/apply`. Upstream needs no explicit rebind
    /// for the resident root session because its provider stack re-reads the
    /// stored key at use time (`api_key_for_base_url` →
    /// `stored_api_key()` reads disk per call, fireworks_models.rs:113-140);
    /// only spawn-captured subagent samplers get cancelled
    /// (acp_agent.rs:3835-3850). This port's sampler captures the key when
    /// the sampler is BUILT (the E6 measurement: a static API-key session
    /// kept the old key until a re-pick or restart), so the same observable
    /// contract — "the next sampling request carries the applied key" —
    /// requires rebuilding the sampler here.
    ///
    /// Fail-closed like `apply`: nothing mutates unless resolution AND
    /// sampler construction succeed. In particular, applying a CLEARED key
    /// leaves the old sampler (and its old credential) live and reports the
    /// failure — the session is not torn down mid-turn, matching upstream,
    /// where a resident root session also keeps working until its next
    /// credential read fails.
    func rebindCredential(provider: ModelProvider) async -> LiveCredentialRebindOutcome {
        let active = sampling
        guard active.provider == provider else {
            return .notActive(activeProvider: active.provider)
        }
        let modelID = activeCatalogID(for: active) ?? active.model
        let resolution: LiveModelResolution
        do {
            resolution = try await resolver.resolve(
                modelID: modelID,
                effort: active.reasoningEffort,
                serviceTier: active.serviceTier
            )
        } catch let error as LiveModelSwitchError {
            return .failed(message: error.description)
        } catch {
            return .failed(message: String(describing: error))
        }
        let rebuilt: OpenGrokLiveSampler
        do {
            rebuilt = try makeSampler(resolution.sampling)
        } catch {
            return .failed(message: String(describing: error))
        }
        // Same model and provider by construction: no history reconcile and
        // no Code Mode invalidation — only the credential route changed.
        sampling = resolution.sampling
        sampler = rebuilt
        return .rebound(provider: provider)
    }

    /// Whether the (post-switch) active model still advertises a fast tier —
    /// the second conjunct of `fast_mode_enabled` (acp/model_state.rs:232-237).
    private func resolvedEntrySupportsFast(
        _ configuration: OpenGrokLiveSamplingConfiguration
    ) -> Bool {
        resolver.catalogSource().pairs()
            .first {
                $0.1.model == configuration.model
                    && $0.1.info.provider == configuration.provider
            }?
            .1.info.supportsFastServiceTier ?? false
    }

    /// The catalog id (`glm-5.2`) for a wire model name
    /// (`accounts/fireworks/models/glm-5p2`), so re-picking the active row is
    /// recognised as a no-op whichever name the picker used.
    private func activeCatalogID(for configuration: OpenGrokLiveSamplingConfiguration) -> String? {
        resolver.catalogSource().pairs()
            .first {
                $0.1.model == configuration.model
                    && $0.1.info.provider == configuration.provider
            }
            .map { $0.0 }
    }

    private func hasSameSamplingRoute(
        _ lhs: OpenGrokLiveSamplingConfiguration,
        _ rhs: OpenGrokLiveSamplingConfiguration
    ) -> Bool {
        lhs.model == rhs.model
            && lhs.provider == rhs.provider
            && lhs.baseURL == rhs.baseURL
            && lhs.apiKey == rhs.apiKey
            && lhs.apiBackend == rhs.apiBackend
            && lhs.extraHeaders == rhs.extraHeaders
            && lhs.queryParams == rhs.queryParams
            && lhs.tuning == rhs.tuning
    }

    /// The `/recap` side-call's sampling route, resolved WITHOUT switching the
    /// session (`prepare_auxiliary_sampling`, sampler_turn.rs:1100-1197).
    ///
    /// * An explicit `[models] recap` pin (or the Codex Automatic helper)
    ///   resolves through the SAME catalog/credential ladder `/model` uses,
    ///   with `serviceTier` pinned to nil: the aux sampler config upstream
    ///   builds sets `service_tier: None` (`sampling_config_for_model`,
    ///   agent/config.rs:6097), so an explicitly resolved recap never rides
    ///   the session's Fast tier.
    /// * An automatic helper choice is provider-local by contract; an explicit
    ///   choice is the only opt-in to sending recap content to another
    ///   provider (sampler_turn.rs:1133-1138). Any resolution failure —
    ///   unknown model, missing credentials, wrong provider — falls back to
    ///   the active model, mirroring upstream's warn-and-use-active arms
    ///   (sampler_turn.rs:1140-1159).
    /// * The active-model fallback keeps the session's full config — service
    ///   tier included (`reconstruct_full_config` carries it,
    ///   sampler_turn.rs:850) — with only the reasoning effort adjusted to
    ///   the auxiliary policy (sampler_turn.rs:1162-1175). Never `nil`: a
    ///   recap must not fail merely because no helper resolved.
    func auxiliaryRecapRoute(
        explicitModelID: String?
    ) async -> (configuration: OpenGrokLiveSamplingConfiguration, sampler: OpenGrokLiveSampler) {
        let active = sampling
        let catalog = resolver.catalogSource()
        if let desired = LiveRecap.desiredModel(
            configured: explicitModelID,
            activeProvider: active.provider
        ), let entry = findModelByID(catalog, modelID: desired.modelID) {
            let effort = acceptedAuxiliaryEffort(info: entry.info)
            do {
                let resolution = try await resolver.resolve(
                    modelID: desired.modelID,
                    effort: effort,
                    serviceTier: nil
                )
                if desired.explicit || resolution.sampling.provider == active.provider {
                    return (resolution.sampling, try makeSampler(resolution.sampling))
                }
            } catch {
                // Fall through to the active model — upstream's
                // no-credentials arm (sampler_turn.rs:1147-1151).
            }
        }

        // config = active (sampler_turn.rs:1162): the session's own route,
        // reasoning effort re-derived under the auxiliary policy.
        let activeInfo = resolver.catalogSource().pairs()
            .first {
                $0.1.model == active.model && $0.1.info.provider == active.provider
            }?.1.info
        var tuning = active.tuning
        tuning.reasoningEffort = activeInfo.flatMap(acceptedAuxiliaryEffort(info:))
        guard tuning != active.tuning else { return (active, sampler) }
        let adjusted = OpenGrokLiveSamplingConfiguration(
            model: active.model,
            baseURL: active.baseURL,
            apiKey: active.apiKey,
            provider: active.provider,
            apiBackend: active.apiBackend,
            extraHeaders: active.extraHeaders,
            queryParams: active.queryParams,
            tuning: tuning,
            bearerResolver: active.bearerResolver,
            credentialProvider: active.credentialProvider,
            transport: active.transport
        )
        guard let rebuilt = try? makeSampler(adjusted) else { return (active, sampler) }
        return (adjusted, rebuilt)
    }

    /// The auxiliary effort for one catalog entry, dropped when the model's
    /// declared effort menu does not accept it — the port of the
    /// `model_accepts_reasoning_effort` filter (sampler_turn.rs:1169-1174).
    private func acceptedAuxiliaryEffort(info: ModelInfo) -> ReasoningEffort? {
        let effort = LiveRecap.auxiliaryReasoningEffort(
            provider: info.provider,
            supported: info.supportsReasoningEffort,
            modelDefault: info.reasoningEffort
        )
        guard let effort else { return nil }
        guard info.reasoningEfforts.isEmpty
            || info.reasoningEfforts.contains(where: { $0.value == effort })
        else { return nil }
        return effort
    }
}

/// Whether a session tier selection means Fast mode is on: the tier is the
/// fast wire value (or its `fast` alias) AND the active model still advertises
/// a fast tier. Port of `fast_mode_enabled` (pager acp/model_state.rs:232-237)
/// over the live coordinator's state instead of a controller-side mirror.
func liveFastModeEnabled(serviceTier: String?, supportsFast: Bool) -> Bool {
    guard let tier = serviceTier else { return false }
    let isFastTier = tier == SERVICE_TIER_FAST_REQUEST_VALUE
        || tier.lowercased() == SERVICE_TIER_FAST_NAME
    return isFastTier && supportsFast
}

/// Shared live catalog owner. The manager is the source of truth for both the
/// picker and switch resolver, so a provider partition can never bypass the
/// final catalog filters.
final class LiveModelCatalogStore: @unchecked Sendable {
    private let manager: ModelsManager
    private let lock = NSLock()
    private var backgroundRefresh: Task<Void, Never>?
    /// Retained so `refreshCredentialSnapshot` recomputes the fingerprint from
    /// the same inputs the initializer used — a snapshot rebuilt against a
    /// different home would gate publishes on a key nobody stored.
    private let environment: [String: String]
    private let openGrokHome: URL
    /// Retained so a Kimi endpoint switch can rebuild the partition actors
    /// against the SAME transport the boot set used — upstream rebuilds its
    /// `kimi_client` inside `apply_config` (agent/models.rs:1029-1043), and
    /// a rebuild over a different transport would silently unhook the
    /// hermetic transport a test (or offline composition) injected.
    private let catalogTransport: any ModelCatalogTransport
    /// OAuth refreshes must use the same injected transport as catalog fetches;
    /// a store-only resolver can never recover from an expired or rejected token.
    private let httpTransport: any HTTPTransport
    /// The service the LIVE Kimi partition actor is currently built against —
    /// the port of `effective_kimi_endpoint` (the endpoint of the resident
    /// `kimi_client`, agent/models.rs:1172-1174). Guarded by `lock`.
    private var liveKimiEndpoint: KimiApiEndpoint

    init(
        input: CatalogResolutionInput,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        openGrokHome: URL? = nil,
        transport: any HTTPTransport = URLSessionHTTPTransport()
    ) {
        let home = openGrokHome ?? Self.resolveOpenGrokHome(environment: environment)
        self.environment = environment
        self.openGrokHome = home
        self.httpTransport = transport
        let catalogTransport = LiveModelCatalogHTTPTransport(transport: transport)
        self.catalogTransport = catalogTransport
        // The boot refreshers honor the configured `[models] kimi_endpoint`
        // rather than assuming Platform, so `effective` == `selected` from
        // the first fetch (upstream's client is likewise built from
        // `cfg.models.kimi_endpoint`).
        let bootKimiEndpoint = input.models.kimiEndpoint
        self.liveKimiEndpoint = bootKimiEndpoint
        manager = ModelsManager(
            input: input,
            credentials: Self.credentialSnapshot(
                environment: environment,
                openGrokHome: home,
                kimiEndpoint: bootKimiEndpoint
            ),
            // Explicit, never defaulted: the manager's own cache managers
            // otherwise resolve against the PROCESS environment
            // (`OpenGrokStatePaths.stateDirectory(ProcessInfo...)`), and
            // `clearPartition(.codex)` deletes the codex cache file — a
            // hermetic composition handed a temp home must never reach the
            // user's real `~/.opengrok` (AGENTS §2's ambient-default footgun).
            grokHome: home,
            liveCatalogs: Self.buildRefreshers(
                transport: catalogTransport,
                httpTransport: transport,
                environment: environment,
                openGrokHome: home,
                kimiEndpoint: bootKimiEndpoint
            )
        )
    }

    private static func buildRefreshers(
        transport: any ModelCatalogTransport,
        httpTransport: any HTTPTransport,
        environment: [String: String],
        openGrokHome: URL,
        kimiEndpoint: KimiApiEndpoint
    ) -> LiveCatalogRefreshers {
        let broker = LiveModelCatalogCredentialBroker(
            resolver: LiveCredentialResolver(
                environment: environment,
                openGrokHome: openGrokHome,
                codexAuthFile: openGrokHome.appendingPathComponent(
                    OpenGrokAuthPaths.codexAuthFileName
                ),
                codexRefreshService: .live(
                    endpoints: CodexEndpoints.fromEnvironment(environment),
                    transport: httpTransport
                )
            ),
            environment: environment,
            kimiEndpoint: kimiEndpoint
        )
        return LiveCatalogRefreshers.live(
            transport: transport,
            broker: broker,
            grokHome: openGrokHome,
            kimiEndpoint: kimiEndpoint,
            environment: environment,
            codexBaseURL: codexInferenceBaseURL(environment: environment)
        )
    }

    func snapshot() -> OrderedModelMap {
        manager.catalogSnapshot()
    }

    func pickerEntries() -> [LiveModelPickerEntry] {
        LiveModelCatalogResolver.entries(from: snapshot())
    }

    func updateInput(_ input: CatalogResolutionInput) {
        manager.updateInput(input)
    }

    func applyOpenCodeGoCatalog(_ catalog: OpenCodeGoModelsCatalog?) {
        manager.applyOpenCodeGoCatalog(catalog)
    }

    /// Publish a Fireworks provider catalog into the manager — the same
    /// mutation the store's own background refresh performs, exposed so a
    /// hermetic composition (tests, offline tools) can model the
    /// post-refresh catalog without network. The manager's fingerprint
    /// gate still applies.
    func applyFireworksCatalog(_ catalog: FireworksModelsCatalog?) {
        manager.applyFireworksCatalog(catalog)
    }

    @discardableResult
    func applyRunInfraCatalog(_ catalog: RunInfraModelsCatalog?) -> Bool {
        manager.applyRunInfraCatalog(catalog)
    }

    @discardableResult
    func applyGeminiCatalog(_ catalog: GeminiModelsCatalog?) -> Bool {
        manager.applyGeminiCatalog(catalog)
    }

    @discardableResult
    func applyOpenRouterCatalog(_ catalog: OpenRouterModelsCatalog?) -> Bool {
        manager.applyOpenRouterCatalog(catalog)
    }

    // MARK: ACP credential-family seams
    //
    // Backings for the `open-grok/*/models/*` extension methods
    // (`LiveModelsACPHandler`), mirroring the upstream handlers'
    // models-manager calls at the acp_agent.rs:3794+ dispatch.

    /// The catalog key of the tracked session model — upstream's
    /// `current_model_id()` (agent/models.rs:1232-1234), which every family
    /// payload embeds as `models.currentModelId`.
    func currentModelID() -> String {
        manager.currentModel().id
    }

    /// One live partition refetch, publish-gated by the manager. The
    /// `open-grok/{provider}/models/apply` handlers call this AFTER
    /// `refreshCredentialSnapshot()`, mirroring upstream's
    /// `refresh_*_models` half of `apply_*_credential_change`
    /// (agent/models.rs:708-715 fireworks; :781-788 deepseek; :847-854
    /// meta; :924-931 opencode-go; :990-997 wafer).
    func refreshPartition(_ partition: ModelCatalogPartition) async -> LiveCatalogRefreshOutcome {
        await manager.refreshPartition(partition)
    }

    /// The forced-online Codex refresh behind `open-grok/codex/models/refresh`
    /// (`refresh_codex_models(true)`, acp_agent.rs:3796-3800).
    func refreshCodexForced() async -> LiveCatalogRefreshOutcome {
        await manager.refreshCodexBlocking(forceOnline: true)
    }

    /// The clear arm of the family (`clear_*_models`); returns upstream's
    /// "was there anything to clear" bool. Discardable because the
    /// no-usable-key arm of `apply_*_credential_change` drops it upstream
    /// too (`self.clear_fireworks_models();`, agent/models.rs:712) — it is
    /// a had-anything report, not a success/failure status.
    @discardableResult
    func clearPartition(_ partition: ModelCatalogPartition) -> Bool {
        manager.clearPartition(partition)
    }

    /// Whether the applied provider currently has a usable credential, from
    /// the SAME env+store inputs the partition broker resolves with — the
    /// port of `has_usable_api_key` deciding refresh-vs-clear in
    /// `apply_*_credential_change` (agent/models.rs:708-715). Env keys
    /// resolve unconditionally; a stored key counts only for the partition's
    /// own (trusted) endpoint, exactly like the broker's fetch-time resolve.
    func hasUsableCredential(for partition: ModelCatalogPartition) async -> Bool {
        let kimiEndpoint = lock.withLock { liveKimiEndpoint }
        let broker = LiveModelCatalogCredentialBroker(
            resolver: LiveCredentialResolver(
                environment: environment,
                openGrokHome: openGrokHome,
                codexAuthFile: openGrokHome.appendingPathComponent(
                    OpenGrokAuthPaths.codexAuthFileName
                ),
                codexRefreshService: .live(
                    endpoints: CodexEndpoints.fromEnvironment(environment),
                    transport: httpTransport
                )
            ),
            environment: environment,
            kimiEndpoint: kimiEndpoint
        )
        return await broker.credential(for: partition) != nil
    }

    /// Apply a Kimi service selection: swap the config knob, rebuild the
    /// partition actors at the new service's base URL, then attempt a live
    /// `/models` refresh — the port of `apply_kimi_endpoint`
    /// (agent/models.rs:1029-1043; both services support the query,
    /// kimi_models.rs:231-236).
    func applyKimiEndpoint(_ endpoint: KimiApiEndpoint) async -> LiveCatalogRefreshOutcome {
        manager.applyKimiEndpointSelection(endpoint)
        guard manager.kimiEndpointSelection() == endpoint else {
            // Upstream's readback bail (agent/models.rs:1034-1036). The
            // Swift knob-swap cannot currently reject, so this arm is
            // unreachable today; it stays so a future validating
            // `applyKimiEndpointSelection` fails loudly here instead of
            // refreshing against a service the manager refused.
            return LiveCatalogRefreshOutcome(
                partition: .kimi,
                published: false,
                failure: "Kimi endpoint change was rejected by model catalog validation"
            )
        }
        manager.updateLiveCatalogRefreshers(Self.buildRefreshers(
            transport: catalogTransport,
            httpTransport: httpTransport,
            environment: environment,
            openGrokHome: openGrokHome,
            kimiEndpoint: endpoint
        ))
        lock.withLock { liveKimiEndpoint = endpoint }
        refreshCredentialSnapshot()
        return await manager.refreshPartition(.kimi)
    }

    /// The service the live Kimi partition actor is on
    /// (`effective_kimi_endpoint`, agent/models.rs:1172-1174).
    func effectiveKimiEndpoint() -> KimiApiEndpoint {
        lock.withLock { liveKimiEndpoint }
    }

    /// OpenCode Go settings surface (`opencode_go_models` /
    /// `opencode_go_enabled_models` / `apply_opencode_go_enabled_models`,
    /// agent/models.rs:999-1023).
    func openCodeGoDescriptors() -> [OpenCodeGoModelDescriptor] {
        manager.openCodeGoDescriptors()
    }

    func openCodeGoEnabledModels() -> [String] {
        manager.openCodeGoEnabledModels()
    }

    func applyOpenCodeGoEnabledModels(_ enabledModels: [String]) {
        manager.applyOpenCodeGoEnabledModels(enabledModels)
    }

    func openRouterDescriptors() -> [OpenRouterModelDescriptor] {
        manager.openRouterDescriptors()
    }

    func openRouterEnabledModels() -> [String] {
        manager.openRouterEnabledModels()
    }

    func applyOpenRouterEnabledModels(_ enabledModels: [String]) {
        manager.applyOpenRouterEnabledModels(enabledModels)
    }

    /// Record a completed live model switch, mirroring the tail of upstream's
    /// `set_session_model` (handlers/model_switch.rs:299-303):
    /// `set_current_model_id` then `set_current_reasoning_effort`.
    func noteModelSwitch(catalogID: String, effort: ReasoningEffort?) {
        manager.setCurrentModelID(catalogID)
        manager.setCurrentReasoningEffort(effort)
    }

    /// The session-level effort the manager tracks — the read half of the
    /// `/effort` surface (`current_reasoning_effort`, agent/models.rs:
    /// 1295-1297). Correct only after `noteModelSwitch` has seeded the
    /// session's route, which the interactive composition does at startup.
    func currentReasoningEffort() -> ReasoningEffort? {
        manager.currentReasoningEffortValue()
    }

    /// The picker entry for the manager's tracked session model, for the
    /// `/effort` dropdown (`EffortCommand::suggest_args`, effort.rs:44-55).
    func currentModelEntry() -> LiveModelPickerEntry? {
        entryForWireModel(manager.currentModel().id)
    }

    /// The picker entry whose *wire* model name (or catalog key) is `model`.
    ///
    /// The composer border carries the wire name (`glm-5p2`'s full path, not
    /// `glm-5.2`), so `/effort` has to resolve the current model back to its
    /// catalog entry before it can read the effort menu.
    func entryForWireModel(
        _ model: String,
        provider: ModelProvider? = nil
    ) -> LiveModelPickerEntry? {
        let entries = pickerEntries()
        if let match = entries.first(where: {
            $0.id == model && (provider == nil || $0.providerID == provider?.asString)
        }) {
            return match
        }
        guard let key = snapshot().pairs().first(where: {
            $0.1.model == model && (provider == nil || $0.1.info.provider == provider)
        })?.0 else {
            return nil
        }
        return entries.first { $0.id == key }
    }

    /// Recompute the credential fingerprint snapshot from disk — called after
    /// a settings-modal secret save so the new key is visible to the catalog
    /// publish gate and to the next background refresh, mirroring upstream's
    /// post-store `apply_meta_models` re-read (effects/mod.rs:832-861).
    func refreshCredentialSnapshot() {
        let kimiEndpoint = lock.withLock { liveKimiEndpoint }
        manager.updateCredentials(Self.credentialSnapshot(
            environment: environment,
            openGrokHome: openGrokHome,
            kimiEndpoint: kimiEndpoint
        ))
    }

    /// One-shot background catalog refresh after session readiness — the port
    /// of `spawn_background_refresh` (xai-grok-shell agent/models.rs:1817-1835
    /// at HEAD), which upstream fires post-readiness from the pager spawn
    /// (acp/spawn.rs:210) and app run (agent/app.rs:194, :1250) without ever
    /// awaiting it. Fire-and-forget: a failed partition logs nothing louder
    /// than its outcome and the embedded models stay in place.
    ///
    /// The task handle is retained (`backgroundRefreshTask`) so the
    /// reachability test can await completion instead of sleeping; production
    /// callers ignore it. Codex starts beside the API-key partitions, matching
    /// `set_gateway` (`agent/models.rs:645-657`); its own refresh remains
    /// awaited inside this detached task, never on the interactive caller.
    func spawnBackgroundRefresh() {
        let manager = self.manager
        let task = Task<Void, Never> {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await manager.refreshCodexBlocking() }
                group.addTask { await manager.refreshBackgroundPartitions() }
            }
        }
        lock.lock()
        backgroundRefresh = task
        lock.unlock()
    }

    /// The in-flight (or finished) background refresh, for tests.
    var backgroundRefreshTask: Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return backgroundRefresh
    }

    fileprivate static func resolveOpenGrokHome(environment: [String: String]) -> URL {
        if let path = environment["OPENGROK_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        let home = environment["HOME"] ?? environment["USERPROFILE"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".opengrok", isDirectory: true)
            .standardizedFileURL
    }

    /// Publish fences must describe exactly the credentials the live brokers
    /// resolve, otherwise an account/key switch can publish another principal's
    /// response or silently suppress every legitimate provider refresh.
    private static func credentialSnapshot(
        environment: [String: String],
        openGrokHome: URL,
        kimiEndpoint: KimiApiEndpoint
    ) -> EmptyCredentialSnapshot {
        let codexAuthFile = openGrokHome.appendingPathComponent(
            OpenGrokAuthPaths.codexAuthFileName
        )
        let resolver = LiveCredentialResolver(
            environment: environment,
            openGrokHome: openGrokHome,
            codexAuthFile: codexAuthFile
        )
        let broker = LiveModelCatalogCredentialBroker(
            resolver: resolver,
            environment: environment,
            kimiEndpoint: kimiEndpoint
        )

        let authFile: URL
        if let override = environment["OPENGROK_AUTH_PATH"], !override.isEmpty {
            authFile = URL(fileURLWithPath: override)
        } else {
            authFile = openGrokHome.appendingPathComponent(OpenGrokAuthPaths.authFileName)
        }
        let xaiSession: Bool
        if let authStore = try? readAuthJSONOrEmpty(at: authFile) {
            let scope = GrokComConfig.default(environment: environment).authScope
            xaiSession = lookupAuth(authStore, scope: scope)?.isSessionAuth == true
        } else {
            xaiSession = false
        }
        let codexCredentials = try? loadCodexCredentials(at: codexAuthFile)

        func fingerprint(_ partition: ModelCatalogPartition) -> String? {
            broker.selectedAPIKey(for: partition).map {
                liveCatalogCredentialFingerprint($0, partition: partition)
            }
        }

        return EmptyCredentialSnapshot(
            hasXaiSession: xaiSession,
            hasCodexSession: codexCredentials != nil,
            codexAccountFingerprint: codexCredentials.flatMap(liveCodexAccountFingerprint),
            kimiCredentialFingerprint: fingerprint(.kimi),
            fireworksCredentialFingerprint: fingerprint(.fireworks),
            deepSeekCredentialFingerprint: fingerprint(.deepSeek),
            metaCredentialFingerprint: fingerprint(.meta),
            openCodeGoCredentialFingerprint: fingerprint(.openCodeGo),
            waferCredentialFingerprint: fingerprint(.wafer),
            zaiCredentialFingerprint: fingerprint(.zai),
            runinfraCredentialFingerprint: fingerprint(.runinfra),
            geminiCredentialFingerprint: fingerprint(.gemini),
            openRouterCredentialFingerprint: fingerprint(.openRouter)
        )
    }
}

private struct LiveModelCatalogHTTPTransport: ModelCatalogTransport {
    let transport: any HTTPTransport

    func send(
        _ request: ModelCatalogRequest,
        cancellation: CancellationToken?
    ) async throws -> ModelCatalogResponse {
        try cancellation?.throwIfCancelled()
        guard let url = URL(string: request.url) else {
            throw ModelsError.remoteMalformed("invalid catalog URL")
        }
        let response = try await transport.send(HTTPRequest(
            method: .get,
            url: url,
            headers: Dictionary(uniqueKeysWithValues: request.headers.map { ($0.name, $0.value) }),
            timeout: request.timeout
        ))
        try cancellation?.throwIfCancelled()
        return ModelCatalogResponse(
            status: response.metadata.statusCode,
            headers: response.metadata.headers.map { ModelCatalogHeader($0.key, $0.value) },
            body: response.body
        )
    }
}

private struct LiveModelCatalogCredentialBroker: ModelCatalogCredentialBroker {
    let resolver: LiveCredentialResolver
    let environment: [String: String]
    /// The Kimi service this broker resolves for. Platform and Code carry
    /// non-interchangeable keys and endpoints (kimi_models.rs:26-34), so the
    /// broker built for one service must not hand its key to the other's
    /// base URL after an endpoint switch.
    var kimiEndpoint: KimiApiEndpoint = .platform

    func credential(for partition: ModelCatalogPartition) async -> ProviderCatalogCredential? {
        let provider = partition.provider
        let explicit = environmentKey(for: provider)
        guard let credential = try? await resolver.resolve(
            provider: provider,
            explicitAPIKey: explicit,
            // The endpoint the partition actor will actually fetch from, so a
            // stored provider key is withheld when an env override points the
            // partition at an untrusted host (`select_api_key`,
            // meta_models.rs:78-88; env keys still resolve unconditionally).
            baseURL: partitionBaseURL(for: partition),
            scope: "catalog:\(partition.rawValue)"
        ) else {
            return nil
        }
        return ProviderCatalogCredential(
            apiKey: credential.bearer,
            fingerprint: liveCatalogCredentialFingerprint(
                credential.bearer,
                partition: partition
            )
        )
    }

    func codexCredential(forceRefresh: Bool) async -> CodexCatalogCredential? {
        guard let resolved = try? await resolver.resolve(
            provider: .codex,
            baseURL: partitionBaseURL(for: .codex),
            forceRefresh: forceRefresh,
            scope: "catalog:codex"
        ),
        resolved.source == .codexOAuth,
        let credentials = try? loadCodexCredentials(at: resolver.codexAuthFile),
        credentials.accessToken == resolved.bearer,
        resolved.extraHeaders["ChatGPT-Account-ID"] == credentials.accountID,
        let fingerprint = liveCodexAccountFingerprint(credentials)
        else {
            return nil
        }

        return CodexCatalogCredential(
            accessToken: credentials.accessToken,
            accountID: credentials.accountID,
            accountIsFedramp: credentials.accountIsFedramp,
            fingerprint: fingerprint
        )
    }

    /// Synchronous mirror of `LiveCredentialResolver.resolve` for the manager's
    /// publish snapshot. Explicit env keys outrank stored keys; stored keys
    /// never travel to a configured non-provider endpoint.
    func selectedAPIKey(for partition: ModelCatalogPartition) -> String? {
        guard partition != .codex else { return nil }
        let provider = partition.provider
        if let key = nonEmptyCredential(environmentKey(for: provider)) {
            return key
        }
        guard trustedBuiltInSessionEndpoint(
            provider: provider,
            baseURL: partitionBaseURL(for: partition)
        ) else {
            return nil
        }
        return nonEmptyCredential(readProviderAPIKey(
            grokHome: resolver.openGrokHome,
            provider: provider.asString
        ))
    }

    private func nonEmptyCredential(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    private func environmentKey(for provider: ModelProvider) -> String? {
        if provider == .kimi {
            switch kimiEndpoint {
            case .platform:
                // Preserves the pre-endpoint-switch fallback chain the boot
                // path always used; Code is strict because its key must not
                // be inferred from the Platform variable.
                return environment[KimiModels.platformAPIKeyEnv]
                    ?? environment[KimiModels.codeAPIKeyEnv]
            case .code:
                return environment[KimiModels.codeAPIKeyEnv]
            }
        }
        let key: String?
        switch provider {
        case .fireworks:
            key = FireworksModels.apiKeyEnv
        case .deepseek:
            key = DeepSeekModels.apiKeyEnv
        case .openCodeGo:
            key = OpenCodeGoModels.apiKeyEnv
        case .wafer:
            key = WaferModels.apiKeyEnv
        case .zai:
            key = ZaiModels.apiKeyEnv
        case .meta:
            // Upstream's Meta credential env key (meta_models.rs:16, :74-76).
            key = MetaModels.apiKeyEnv
        case .runinfra:
            return RunInfraModels.environmentAPIKey(environment: environment)
        case .gemini:
            return GeminiModels.environmentAPIKey(environment: environment)
        case .openRouter:
            key = OpenRouterModels.apiKeyEnv
        case .kimi, .xai, .codex:
            key = nil
        }
        return key.flatMap { environment[$0] }
    }

    /// The same per-partition base URL `LiveCatalogRefreshers.live` hands each
    /// actor, recomputed from the same environment — the two cannot disagree
    /// because both read the identical `*ApiBaseURL(environment:)` helper.
    private func partitionBaseURL(for partition: ModelCatalogPartition) -> String {
        switch partition {
        case .codex:
            return codexInferenceBaseURL(environment: environment)
        case .kimi:
            return KimiModels.apiBaseURL(kimiEndpoint, environment: environment)
        case .fireworks:
            return FireworksModels.apiBaseURL(environment: environment)
        case .deepSeek:
            return DeepSeekModels.apiBaseURL(environment: environment)
        case .meta:
            return MetaModels.apiBaseURL(environment: environment)
        case .openCodeGo:
            return OpenCodeGoModels.apiBaseURL(environment: environment)
        case .wafer:
            return WaferModels.apiBaseURL(environment: environment)
        case .zai:
            return ZaiModels.apiBaseURL(environment: environment)
        case .runinfra:
            return RunInfraModels.apiBaseURL(environment: environment)
        case .gemini:
            return GeminiModels.apiBaseURL(environment: environment)
        case .openRouter:
            return OpenRouterModels.apiBaseURL(environment: environment)
        }
    }
}

/// Byte-for-byte principal identity from `codex_models.rs:916-937`: bearer
/// rotation cannot invalidate a cache, and missing principal claims fail shut.
private func liveCodexAccountFingerprint(_ credentials: CodexCredentials) -> String? {
    guard credentials.accountID != nil
        || credentials.chatgptUserID != nil
        || credentials.email != nil
    else { return nil }

    var bytes = Array("open-grok-codex-model-cache-account-v1\0".utf8)
    for component in [credentials.accountID, credentials.chatgptUserID, credentials.email] {
        let value = Array((component ?? "").utf8)
        var length = UInt64(value.count).littleEndian
        withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
        bytes.append(contentsOf: value)
    }
    bytes.append(credentials.isWorkspaceAccount ? 1 : 0)
    return Blake3.hexDigest(bytes)
}

private func liveCatalogCredentialFingerprint(_ value: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return String(hash, radix: 16)
}

private func liveCatalogCredentialFingerprint(
    _ value: String,
    partition: ModelCatalogPartition
) -> String {
    switch partition {
    case .runinfra:
        return RunInfraModels.credentialFingerprint(apiKey: value)
    case .gemini:
        return GeminiModels.credentialFingerprint(apiKey: value)
    case .openRouter:
        return OpenRouterModels.credentialFingerprint(value)
    default:
        return liveCatalogCredentialFingerprint(value)
    }
}

func liveCatalogResolutionInput(
    workingDirectory: URL,
    environment: [String: String]
) -> CatalogResolutionInput {
    let document = (try? loadAuthorityComposition(
        cwd: workingDirectory,
        environment: environment
    ).effective()) ?? .table(TOMLTable())
    let openCodeGoEnabled = document[path: ["models", "opencode_go_enabled_models"]]?.arrayValue?
        .compactMap(\.stringValue) ?? []
    let openRouterEnabled = document[path: ["models", "openrouter_enabled_models"]]?.arrayValue?
        .compactMap(\.stringValue) ?? []
    let configured = liveConfiguredModelCatalog(
        workingDirectory: workingDirectory,
        environment: environment
    )
    var modelOverrides = configured.modelOverrides
    let openGrokHome = LiveModelCatalogStore.resolveOpenGrokHome(environment: environment)
    let savedOverrides = (try? loadCustomModelOverrides(grokHome: openGrokHome)) ?? []
    for (key, override) in savedOverrides {
        if let index = modelOverrides.firstIndex(where: { $0.0 == key }) {
            modelOverrides[index] = (key, override)
        } else {
            modelOverrides.append((key, override))
        }
    }
    let endpoints = EndpointsConfig(
        xaiApiBaseURL: document[path: ["endpoints", "xai_api_base_url"]]?.stringValue
            ?? XAI_API_BASE_URL_DEFAULT,
        modelsBaseURL: document[path: ["endpoints", "models_base_url"]]?.stringValue,
        modelsListURL: document[path: ["endpoints", "models_list_url"]]?.stringValue,
        deploymentKey: document[path: ["endpoints", "deployment_key"]]?.stringValue
    )
    return CatalogResolutionInput(
        endpoints: endpoints,
        models: ModelsSectionConfig(
            default: document[path: ["models", "default"]]?.stringValue,
            opencodeGoEnabledModels: openCodeGoEnabled,
            openRouterEnabledModels: openRouterEnabled
        ),
        configModels: modelOverrides
    )
}

/// Strip provider-native carriers from a conversation so it can be replayed to
/// a different provider.
///
/// What survives is the provider-neutral spine: system prompts, user turns and
/// assistant prose. Reasoning items, backend tool calls and custom-tool outputs
/// are opaque provider state. Function tool calls and their results go too —
/// keeping either half alone produces an unpaired call the next provider will
/// reject, and the assistant text already summarises what the tools did.
func liveProviderNeutralHistory(_ items: [ConversationItem]) -> [ConversationItem] {
    items.compactMap { item -> ConversationItem? in
        switch item {
        case .system, .user:
            return item
        case .assistant(let assistant):
            guard !assistant.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            var stripped = assistant
            stripped.toolCalls = []
            return .assistant(stripped)
        case .toolResult, .customToolOutput, .backendToolCall, .reasoning:
            return nil
        }
    }
}
