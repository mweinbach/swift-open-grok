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
import OpenGrokModels
import OpenGrokProviderSession
import OpenGrokSamplingTypes

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
    let workingDirectory: URL
    /// Injection seam for tests; production passes the real resolver.
    let makeCredentialResolver: @Sendable (
        [String: String],
        URL
    ) -> LiveCredentialResolver

    init(
        environment: [String: String],
        openGrokHome: URL,
        sessionID: String,
        workingDirectory: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ),
        makeCredentialResolver: @escaping @Sendable (
            [String: String],
            URL
        ) -> LiveCredentialResolver = { environment, openGrokHome in
            LiveCredentialResolver(environment: environment, openGrokHome: openGrokHome)
        }
    ) {
        self.environment = environment
        self.openGrokHome = openGrokHome
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.makeCredentialResolver = makeCredentialResolver
    }

    /// Every model the `/model` picker should offer. Hidden entries stay hidden.
    ///
    /// Ordering is left to `LiveModelPicker.rows`, which sorts by provider then
    /// name — sorting by raw id here would interleave providers.
    static func catalog() -> [LiveModelPickerEntry] {
        embeddedDefaultModels().models
            .filter { !$0.hidden }
            .map { model in
                LiveModelPickerEntry(
                    id: model.id ?? model.model,
                    providerID: model.provider.asString,
                    name: model.name ?? model.id ?? model.model,
                    description: model.description,
                    contextWindow: model.contextWindow,
                    supportsReasoningEffort: model.supportsReasoningEffort
                )
            }
    }

    func resolve(modelID: String) async throws -> LiveModelResolution {
        guard let profile = embeddedDefaultModels().models.first(where: {
            ($0.id ?? $0.model) == modelID || $0.model == modelID
        }) else {
            throw LiveModelSwitchError.unknownModel(modelID)
        }
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
        let baseURL = OpenGrokLiveApplicationLauncher.resolveProviderBaseURL(
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
        if provider == .kimi,
           let modelBaseURL = profile.baseURL,
           let modelEndpoint = KimiModels.endpoint(forBaseURL: modelBaseURL),
           let resolvedEndpoint = KimiModels.endpoint(forBaseURL: baseURL),
           modelEndpoint != resolvedEndpoint {
            throw LiveModelSwitchError.unsupportedBaseURL(provider: provider, baseURL: baseURL)
        }
        let explicitAPIKey = try OpenGrokLiveApplicationLauncher.resolveProviderAPIKey(
            provider: provider,
            model: profile,
            baseURL: baseURL,
            environment: environment
        )
        let credential: LiveResolvedCredential
        do {
            credential = try await makeCredentialResolver(environment, openGrokHome).resolve(
                provider: provider,
                explicitAPIKey: explicitAPIKey,
                scope: "cli:\(sessionID)"
            )
        } catch let error as LiveCredentialError {
            throw LiveModelSwitchError.credentialsUnavailable(
                provider: provider,
                detail: error.description
            )
        }
        return LiveModelResolution(
            sampling: OpenGrokLiveSamplingConfiguration(
                model: profile.model,
                baseURL: baseURL,
                apiKey: credential.bearer,
                provider: provider,
                apiBackend: backend,
                extraHeaders: credential.extraHeaders
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

    var changedProvider: Bool { provider != previousProvider }

    /// The system message the transcript records for this switch.
    var transcriptMessage: String {
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
        Snapshot(sampler: sampler, modelID: sampling.model, provider: sampling.provider)
    }

    var activeModelID: String { sampling.model }
    var activeProvider: ModelProvider { sampling.provider }

    /// Rebuild the sampling stack for `modelID`.
    ///
    /// Resolution, credential lookup and sampler construction all happen before
    /// any state changes, so a failure leaves the session exactly as it was.
    func apply(modelID: String) async -> LiveModelSwitchOutcome {
        let previous = sampling
        if modelID == previous.model || modelID == activeCatalogID(for: previous) {
            return .unchanged(modelID: modelID)
        }
        let resolution: LiveModelResolution
        do {
            resolution = try await resolver.resolve(modelID: modelID)
        } catch let error as LiveModelSwitchError {
            return .failed(modelID: modelID, message: error.description)
        } catch {
            return .failed(modelID: modelID, message: String(describing: error))
        }
        guard resolution.sampling.model != previous.model else {
            return .unchanged(modelID: modelID)
        }
        let rebuilt: OpenGrokLiveSampler
        do {
            rebuilt = try makeSampler(resolution.sampling)
        } catch {
            return .failed(modelID: modelID, message: String(describing: error))
        }

        var dropped = 0
        if resolution.sampling.provider != previous.provider, let history {
            dropped = (try? await history.isolateForProviderSwitch()) ?? 0
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
            droppedOpaqueItems: dropped
        ))
    }

    /// The catalog id (`glm-5.2`) for a wire model name
    /// (`accounts/fireworks/models/glm-5p2`), so re-picking the active row is
    /// recognised as a no-op whichever name the picker used.
    private func activeCatalogID(for configuration: OpenGrokLiveSamplingConfiguration) -> String? {
        embeddedDefaultModels().models
            .first { $0.model == configuration.model }
            .map { $0.id ?? $0.model }
    }
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
