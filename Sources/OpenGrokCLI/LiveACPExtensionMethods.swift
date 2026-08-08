// LiveACPExtensionMethods.swift
//
// The ACP extension-method surface for the live composition: the
// `open-grok/*/models` credential/catalog family plus the router that
// mirrors upstream's ext-method dispatch
// (`crates/codegen/xai-grok-shell/src/agent/mvp_agent/acp_agent.rs:3794-4472`).
//
// What routes and what refuses:
//
//   * Routed with real backings — the twelve `open-grok/*` methods below,
//     `x.ai/feedback` (`LiveFeedbackACPHandler`), `x.ai/recap`
//     (`LiveRecapACPHandler`, LiveACPNotificationGateway.swift — the ack plus
//     the async SessionRecap notification, now that the notification gateway
//     gives the summary a delivery channel), the `x.ai/mcp/` prefix family
//     (`LiveMCPACPHandler`, LiveMCPACPHandlers.swift — list / call /
//     read_resource / auth_status / auth_trigger / upsert / delete over the
//     live pool, the live toolset and the real config files; setup / toggle
//     / toggle_tool refused with the terminal error, unknown names under
//     the prefix refused with upstream's OWN bare method_not_found,
//     mcp.rs:387), and the session-admin trio `x.ai/session/rename` /
//     `x.ai/session/delete` / `x.ai/session/fork`
//     (`LiveSessionAdminACPHandler`, LiveSessionAdminACPHandlers.swift —
//     the real `$OPENGROK_HOME/sessions` store). Every routed method's
//     payload mirrors the upstream payload builders byte-for-byte in copy
//     (`acp_agent.rs:32-181`) inside upstream's `ExtMethodResult` envelope
//     `{"result": <payload>}` (`session/result.rs:29-72`) — except the
//     session-admin trio, whose upstream handlers answer RAW
//     (`to_raw_response`, extensions/mod.rs:69-73), mirrored here.
//   * Everything else at the upstream pin falls through to the router's
//     terminal arm and gets upstream's unknown-method error byte-exact
//     (code -32601, message "Method not found", data
//     "unknown ACP extension method: <m>" — `acp_agent.rs:4467-4471`).
//     A refusal with the right error is honest; a registered no-op is not
//     (AGENTS.md §4). The refused remainder, with the upstream arm each
//     would need: `open-grok/toolset/perplexity-web-search/reload` (:4050 —
//     no per-session web-search reload command channel), `x.ai/getApiKey`/
//     `x.ai/setApiKey` and `x.ai/auth/*` (:4112, :4387 — the xAI auth
//     family, Wave 17), the rest of `x.ai/session*`
//     admin/state/search/usage/repair (:4115-4155 — the item 6 remainder:
//     info/close/updates/state/import/load_history/search/repair/usage need
//     live-session command plumbing, updates journals or the FTS index;
//     `x.ai/session/list`/`x.ai/sessions/list` merge the unported remote
//     registry — the typed core `session/list` this runtime serves is the
//     recorded divergence), `x.ai/memory/*` (:4156),
//     `x.ai/skills/refresh-baseline` (:4159), `x.ai/interject` (:4165),
//     `x.ai/feedback/dismiss` + `x.ai/btw` (:4166 — item 7),
//     `x.ai/cloud/*` (:4170-4370), `x.ai/billing` +
//     `x.ai/auto-topup-rule` (:4371-4374), `x.ai/share_session` (:4375),
//     `x.ai/privacy/*` (:4376), `x.ai/rollout/survey` (:4379),
//     `x.ai/prompt_history` (:4382), `x.ai/suggest`/`x.ai/suggestPrompt`
//     (:4385-4386), the prefix families `x.ai/session_summaries/`,
//     `x.ai/git/`, `x.ai/compact_conversation`, `x.ai/plugins/`,
//     `x.ai/marketplace/`, `x.ai/hooks/`, `x.ai/hunk-tracker/`, `x.ai/pr/`,
//     `x.ai/task/`, `x.ai/scheduler/`, `x.ai/subagent/`, `x.ai/terminal/`,
//     `x.ai/fs/`, `x.ai/search/`, `x.ai/bundle/`, `x.ai/code/`,
//     `x.ai/skills/`, `x.ai/workflows/list`, `x.ai/review*`, `x.ai/debug/`,
//     `x.ai/rewind*` (:4390-4466), and the leader-internal
//     `x.ai/internal/*` names (leader/protocol.rs:398-434).

import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokModels
import OpenGrokSamplingTypes
import OpenGrokShared

// MARK: - Router assembly

enum LiveACPExtensionRouter {
    /// The router the live ACP/serve compositions install. `modelSwitch` is
    /// the RUNNING session's coordinator; passing `nil` (compositions without
    /// a live sampler stack) keeps the catalog family working while the
    /// rebind arm reports itself as skipped in the payload warning. `recap`
    /// is the `x.ai/recap` arm (acp_agent.rs:4169 → extensions/recap.rs) —
    /// `nil` for compositions without a notification gateway, which keeps the
    /// method on the refused table rather than acking into a void.
    static func build(
        feedback: LiveFeedbackACPHandler?,
        models: LiveModelsACPHandler,
        recap: LiveRecapACPHandler? = nil,
        mcp: LiveMCPACPHandler? = nil,
        sessionAdmin: LiveSessionAdminACPHandler? = nil
    ) -> ACPExtensionMethodRouter {
        var router = ACPExtensionMethodRouter()
        if let feedback {
            router = router.register(exact: LiveFeedbackACPHandler.method, handler: feedback)
        }
        for method in LiveModelsACPHandler.methods {
            router = router.register(exact: method, handler: models)
        }
        if let recap {
            router = router.register(exact: LiveRecapACPHandler.method, handler: recap)
        }
        if let mcp {
            // The whole `x.ai/mcp/` prefix, mirroring upstream's
            // `starts_with(PREFIX)` arm (acp_agent.rs:4420-4422): the module
            // owns its own refusal shape for unknown names under the prefix
            // (bare method_not_found, mcp.rs:387), which the router's
            // terminal arm would otherwise mis-spell with data. `nil`
            // (compositions without a live MCP pool) keeps the family on
            // the refused table rather than answering from a void pool.
            router = router.register(prefix: LiveMCPACPHandler.prefix, handler: mcp)
        }
        if let sessionAdmin {
            for method in LiveSessionAdminACPHandler.methods {
                router = router.register(exact: method, handler: sessionAdmin)
            }
        }
        return router
    }
}

// MARK: - Credential/catalog family

/// The `open-grok/*/models` extension-method family — provider catalog
/// refresh/clear plus mid-session credential application.
///
/// Upstream's handler effects at the pin, per method:
///   * `apply` (fireworks :3835, deepseek :3865, meta :3890, wafer :3915,
///     opencode-go credential-apply :3989): cancel spawn-captured subagent
///     samplers for the provider, then `apply_*_credential_change` — refresh
///     the provider's catalog partition when a usable key exists, else drop
///     it (`agent/models.rs:708-715` and siblings). The resident ROOT
///     session needs no explicit rebind upstream because its provider stack
///     re-reads the stored key at use time (`stored_api_key()` reads disk
///     per call, fireworks_models.rs:113-140). This port's sampler captures
///     the key at build (the E6 measurement), so the same observable
///     contract — the running session's next request carries the applied
///     key — is delivered here by `LiveModelSwitchCoordinator
///     .rebindCredential`. Divergence in mechanism, recorded; identical in
///     effect. The provider-scoped subagent cancel is NOT ported (the port's
///     subagent host has only per-id cancel): a resident subagent child on
///     the applied provider keeps its spawn-captured credential until it
///     finishes.
///   * `refresh`/`query`/`get`: partition refetch, no credential mutation.
///   * `clear`: drop the partition, report whether anything was dropped.
///   * `kimi/endpoint/apply` (:4017): swap the service, rebuild the live
///     client, refresh — and, port-only, rebind a running Kimi session,
///     because upstream's Kimi key saves arrive through THIS method (the
///     pager persists then re-applies the endpoint, effects/mod.rs:
///     1474-1491).
struct LiveModelsACPHandler: ACPAgentExtensionHandler, Sendable {
    let catalogStore: LiveModelCatalogStore
    let modelSwitch: LiveModelSwitchCoordinator?

    /// Exact names from the upstream dispatch (`acp_agent.rs:3794-4049`).
    static let methods: [String] = [
        "open-grok/codex/models/refresh",
        "open-grok/codex/models/clear",
        "open-grok/kimi/models/query",
        "open-grok/kimi/models/clear",
        "open-grok/fireworks/models/apply",
        "open-grok/deepseek/models/apply",
        "open-grok/meta/models/apply",
        "open-grok/wafer/models/apply",
        "open-grok/opencode-go/models/get",
        "open-grok/opencode-go/models/apply",
        "open-grok/opencode-go/models/credential-apply",
        "open-grok/kimi/endpoint/apply",
    ]

    func handle(method: String, params: JSONValue) async throws -> JSONValue {
        switch method {
        case "open-grok/codex/models/refresh":
            // `refresh_codex_models(true)` — forced online (:3796-3800).
            let outcome = await catalogStore.refreshCodexForced()
            return envelope(refreshedPayload(outcome))

        case "open-grok/codex/models/clear":
            // `{"cleared": clear_codex_models()}` (:3810-3814).
            return envelope(.object([
                "cleared": .bool(catalogStore.clearPartition(.codex)),
            ]))

        case "open-grok/kimi/models/query":
            // Pure partition query (:3815-3829); no credential mutation, so
            // no rebind — Kimi key changes arrive via `kimi/endpoint/apply`.
            let outcome = await catalogStore.refreshPartition(.kimi)
            return envelope(refreshedPayload(outcome))

        case "open-grok/kimi/models/clear":
            return envelope(.object([
                "cleared": .bool(catalogStore.clearPartition(.kimi)),
            ]))

        case "open-grok/fireworks/models/apply":
            return envelope(await applyCredentialChange(.fireworks))

        case "open-grok/deepseek/models/apply":
            return envelope(await applyCredentialChange(.deepSeek))

        case "open-grok/meta/models/apply":
            return envelope(await applyCredentialChange(.meta))

        case "open-grok/wafer/models/apply":
            return envelope(await applyCredentialChange(.wafer))

        case "open-grok/opencode-go/models/get":
            // Refresh only when the partition has never been fetched
            // (:3940-3957).
            let outcome = await refreshOpenCodeGoIfEmpty()
            return envelope(openCodeGoPayload(outcome))

        case "open-grok/opencode-go/models/apply":
            // Allowlist change (:3958-3988): not a credential mutation, so
            // the running session's sampler is untouched.
            let enabled = params["enabled_models"]?.arrayValue?
                .compactMap(\.stringValue) ?? []
            catalogStore.applyOpenCodeGoEnabledModels(enabled)
            let outcome = await refreshOpenCodeGoIfEmpty()
            return envelope(openCodeGoPayload(outcome))

        case "open-grok/opencode-go/models/credential-apply":
            let payload = await applyCredentialChange(.openCodeGo)
            guard case .object(let fields) = payload else { return envelope(payload) }
            return envelope(openCodeGoFields(merging: fields))

        case "open-grok/kimi/endpoint/apply":
            guard let raw = params["endpoint"]?.stringValue,
                  let endpoint = KimiApiEndpoint(rawValue: raw) else {
                // Upstream surfaces serde's parse failure through
                // `invalid_params().data("invalid params: …")`
                // (extensions/mod.rs:53-56). The prose after the prefix is
                // serde-generated there and hand-written here — recorded.
                throw AcpError(
                    code: .invalidParams,
                    message: AcpErrorCode.invalidParams.displayName,
                    data: .string(
                        "invalid params: unknown Kimi endpoint "
                            + "\(params["endpoint"].map(String.init(describing:)) ?? "<missing>"); "
                            + "expected \"platform\" or \"code\""
                    )
                )
            }
            let outcome = await catalogStore.applyKimiEndpoint(endpoint)
            // Kimi's settings-key save re-applies the endpoint upstream
            // (effects/mod.rs:1474-1491), so this arm carries the live
            // rebind for a running Kimi session.
            let rebindWarning = await rebindRunningSession(provider: .kimi)
            var payload: [String: JSONValue] = [
                "endpoint": .string(endpoint.rawValue),
                "effective_endpoint": .string(catalogStore.effectiveKimiEndpoint().rawValue),
                "models": sessionModelStateJSON(),
            ]
            if let failure = warning(from: outcome, rebind: rebindWarning) {
                payload["refreshed"] = .bool(false)
                payload["warning"] = .string(failure)
            } else {
                payload["refreshed"] = .bool(outcome.published)
            }
            return envelope(.object(payload))

        default:
            // Registration and dispatch are generated from the same list, so
            // this arm is unreachable through the router; refusing with the
            // upstream terminal error keeps a direct caller honest too.
            throw ACPExtensionMethodRouter.unknownExtensionMethodError(method)
        }
    }

    // MARK: Credential application

    /// `apply_*_credential_change` (agent/models.rs:708-715 and siblings):
    /// re-read the credential snapshot, refresh the partition when a usable
    /// key exists, else clear it — then rebind the RUNNING session's sampler
    /// so the next request carries the applied key (the Wave 12 deferral
    /// this family closes).
    private func applyCredentialChange(
        _ partition: ModelCatalogPartition
    ) async -> JSONValue {
        // The port of the pager's post-store snapshot re-read
        // (effects/mod.rs:832-861): without it the manager's fingerprint
        // gate rejects catalogs fetched under the just-applied key.
        catalogStore.refreshCredentialSnapshot()
        let outcome: LiveCatalogRefreshOutcome
        if await catalogStore.hasUsableCredential(for: partition) {
            outcome = await catalogStore.refreshPartition(partition)
        } else {
            // No usable key: drop the credential-derived entries back to the
            // embedded fallback and report `refreshed: false` with no
            // warning, upstream's else-arm.
            catalogStore.clearPartition(partition)
            outcome = LiveCatalogRefreshOutcome(partition: partition, published: false)
        }
        let rebindWarning = await rebindRunningSession(provider: partition.provider)
        return refreshedPayload(outcome, rebind: rebindWarning)
    }

    /// Rebind the running session's sampler to the freshly stored credential
    /// when the session is on the applied provider. Returns a warning string
    /// for the payload when the rebind failed — the silent case must
    /// announce itself (AGENTS.md §3); upstream has no such string because
    /// it has no such step.
    private func rebindRunningSession(provider: ModelProvider) async -> String? {
        guard let modelSwitch else { return nil }
        switch await modelSwitch.rebindCredential(provider: provider) {
        case .notActive, .rebound:
            return nil
        case .failed(let message):
            return "live credential rebind failed: \(message)"
        }
    }

    private func refreshOpenCodeGoIfEmpty() async -> LiveCatalogRefreshOutcome {
        if catalogStore.openCodeGoDescriptors().isEmpty {
            return await catalogStore.refreshPartition(.openCodeGo)
        }
        return LiveCatalogRefreshOutcome(partition: .openCodeGo, published: false)
    }

    // MARK: Payload builders (acp_agent.rs:32-181)

    /// `{"result": payload}` — upstream's `ExtMethodResult::success`
    /// envelope (`session/result.rs:38-44`); every family arm responds
    /// through `to_ext_response(Ok(...))`, failures riding inside the
    /// payload as `warning`, never as the envelope's `error`.
    private func envelope(_ payload: JSONValue) -> JSONValue {
        .object(["result": payload])
    }

    /// The `{refreshed, models}` / `{refreshed: false, warning, models}`
    /// pair every refresh-shaped arm returns (`codex_models_refresh_payload`
    /// and siblings, acp_agent.rs:32-108).
    private func refreshedPayload(
        _ outcome: LiveCatalogRefreshOutcome,
        rebind rebindWarning: String? = nil
    ) -> JSONValue {
        var payload: [String: JSONValue] = ["models": sessionModelStateJSON()]
        if let failure = warning(from: outcome, rebind: rebindWarning) {
            payload["refreshed"] = .bool(false)
            payload["warning"] = .string(failure)
        } else {
            payload["refreshed"] = .bool(outcome.published)
        }
        return .object(payload)
    }

    private func warning(
        from outcome: LiveCatalogRefreshOutcome,
        rebind rebindWarning: String?
    ) -> String? {
        switch (outcome.failure, rebindWarning) {
        case (nil, nil): return nil
        case (let failure?, nil): return failure
        case (nil, let rebind?): return rebind
        case (let failure?, let rebind?): return "\(failure); \(rebind)"
        }
    }

    /// `opencode_go_models_payload` (acp_agent.rs:110-134): the refreshed
    /// pair plus the unfiltered catalog descriptors and the allowlist.
    private func openCodeGoPayload(_ outcome: LiveCatalogRefreshOutcome) -> JSONValue {
        guard case .object(let fields) = refreshedPayload(outcome) else { return .null }
        return openCodeGoFields(merging: fields)
    }

    private func openCodeGoFields(merging fields: [String: JSONValue]) -> JSONValue {
        var payload = fields
        payload["catalog"] = .array(
            catalogStore.openCodeGoDescriptors().map(Self.descriptorJSON)
        )
        payload["enabled_models"] = .array(
            catalogStore.openCodeGoEnabledModels().map(JSONValue.string)
        )
        return .object(payload)
    }

    /// `acp::SessionModelState::new(current_model_id, available)` — the
    /// `models` field of every family payload. The entries are the port's
    /// picker-visible set (`!hidden && userSelectable`); upstream
    /// additionally drops providers whose credentials cannot resolve right
    /// now and attaches a `_meta` capability block
    /// (`available_models_with_provider_auth` → `to_acp_model_info`,
    /// agent/models/resolution.rs:212-223, agent/config.rs:6339+). Recorded
    /// divergence: a peer reading `_meta.provider` or relying on auth-gated
    /// hiding sees a flatter list here until the ACP session-surface slice
    /// ports the full conversion.
    private func sessionModelStateJSON() -> JSONValue {
        let state = SessionModelState(
            currentModelId: ModelId(catalogStore.currentModelID()),
            availableModels: catalogStore.pickerEntries().map {
                OpenGrokACP.ModelInfo(
                    modelId: ModelId($0.id),
                    name: $0.name,
                    description: $0.description
                )
            }
        )
        return (try? JSONValue.encode(state)) ?? .null
    }

    /// One `OpenCodeGoModelDescriptor` in upstream's serde spelling —
    /// snake_case keys, snake_case `ApiBackend` values
    /// (opencode_go_models.rs:25-31; sampling-types types.rs:1066-1073). The
    /// Swift type's own Codable spelling is camelCase, so the wire shape is
    /// built by hand here.
    private static func descriptorJSON(_ descriptor: OpenCodeGoModelDescriptor) -> JSONValue {
        .object([
            "key": .string(descriptor.key),
            "id": .string(descriptor.id),
            "name": .string(descriptor.name),
            "api_backend": .string(wireAPIBackend(descriptor.apiBackend)),
        ])
    }

    private static func wireAPIBackend(_ backend: ApiBackend) -> String {
        switch backend {
        case .chatCompletions: return "chat_completions"
        case .responses: return "responses"
        case .messages: return "messages"
        }
    }
}
