// LivePagerAuthCommands.swift
//
// The live backing for the in-pager `/login` and `/logout` commands: the
// provider picker's rows with real secret statuses, and the injectable side
// effects the Codex browser flow and logout revoke need. The dispatch itself
// lives on `LiveInteractiveControllerRenderer` (LiveComposition.swift); this
// file holds what tests must reach without a terminal.

import Foundation
import OpenGrokAuth
import OpenGrokHTTP
import OpenGrokModels
import OpenGrokPager
import OpenGrokPagerRender

/// Side-effecting dependencies of the pager's auth commands. The CLI routes
/// have the same seam (`LiveAuthServices`); this one is smaller because the
/// TUI has no device-code fallback — upstream's TUI flow errors when the
/// browser cannot open (`codex_auth.rs:828-843`) rather than switching modes.
struct LivePagerAuthServices: Sendable {
    /// The opener is optional for the same reason `LiveAuthServices` makes
    /// it optional: an optional closure is always escaping, and the flow
    /// holds it across its awaits.
    typealias CodexLoginFlow = @Sendable (
        _ authFile: URL,
        _ endpoints: CodexEndpoints,
        _ transport: any HTTPTransport,
        _ openBrowser: (@Sendable (URL) -> Void)?
    ) async throws -> CodexCredentials

    /// The xAI browser OAuth flow (`/login xai`). Takes the REAL store's
    /// manager so the credential lands in auth.json under its file lock; the
    /// transport and opener are the injectable legs, like the codex flow's.
    typealias XAILoginFlow = @Sendable (
        _ manager: AuthManager,
        _ environment: [String: String],
        _ transport: any HTTPTransport,
        _ openBrowser: (@Sendable (URL) -> Void)?
    ) async throws -> GrokAuth

    /// Transport for the OAuth exchange and the logout's best-effort revoke.
    var makeTransport: @Sendable () -> any HTTPTransport
    /// The browser + local-callback OAuth flow.
    var codexBrowserLogin: CodexLoginFlow
    /// The xAI browser + local-callback OAuth flow. Defaulted so existing
    /// memberwise constructions (tests with inert codex flows) keep building.
    var xaiBrowserLogin: XAILoginFlow = { manager, environment, transport, openBrowser in
        try await loginXAIBrowser(
            manager: manager,
            environment: environment,
            transport: transport,
            openBrowser: openBrowser
        )
    }
    /// Best-effort system browser launch. `nil` disables opening; the auth
    /// URL is in the transcript either way.
    var openBrowser: (@Sendable (URL) -> Void)?

    static let production = LivePagerAuthServices(
        makeTransport: { URLSessionHTTPTransport() },
        codexBrowserLogin: { authFile, endpoints, transport, openBrowser in
            try await loginCodexBrowser(
                authFile: authFile,
                endpoints: endpoints,
                transport: transport,
                announce: false,
                openBrowser: openBrowser
            )
        },
        openBrowser: { url in LiveAuthComposition.openInSystemBrowser(url) }
    )
}

/// The bare-`/login` provider chooser — upstream's ArgPicker modal over
/// `provider_items` with live secret statuses (`dispatch/auth.rs:26-51`).
enum LiveLoginProviderPicker {
    static let overlayID = "login-providers"

    /// Env override → stored key → missing, upstream's per-provider status
    /// rule (`dispatch/settings/ui.rs:37-48` and siblings).
    static func secretStatus(
        envKey: String,
        storedKey: String?,
        environment: [String: String]
    ) -> PagerSecretStatus {
        if let value = environment[envKey],
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .environmentOverride
        }
        return storedKey == nil ? .missing : .stored
    }

    /// Live statuses for the six API-key providers, keyed by the provider's
    /// canonical token (`PagerLoginProvider.insertText`). Kimi reports the
    /// Platform service, as upstream's picker does (`ui.rs:29-31`); stored
    /// keys read the same scopes the settings modal's saves write.
    static func statuses(
        openGrokHome: URL,
        environment: [String: String]
    ) -> [String: PagerSecretStatus] {
        let stored: [String: (envKey: String, provider: String)] = [
            "kimi": (KimiModels.platformAPIKeyEnv, "kimi"),
            "fireworks": (FireworksModels.apiKeyEnv, "fireworks"),
            "deepseek": (DeepSeekModels.apiKeyEnv, "deepseek"),
            "meta": (MetaModels.apiKeyEnv, "meta"),
            "opencode-go": (OpenCodeGoModels.apiKeyEnv, "opencode_go"),
            "wafer": (WaferModels.apiKeyEnv, "wafer"),
            "zai": (ZaiModels.apiKeyEnv, "zai"),
        ]
        return stored.mapValues { entry in
            secretStatus(
                envKey: entry.envKey,
                storedKey: readProviderAPIKey(
                    grokHome: openGrokHome,
                    provider: entry.provider
                ),
                environment: environment
            )
        }
    }

    /// Eight rows in upstream's order. API-key rows show
    /// "API key · <status>" (`login.rs:20-23`); the OAuth rows keep their
    /// fixed descriptions. Row ids are the provider tokens, so a selection
    /// round-trips as the exact typed form.
    ///
    /// The status text goes in `detail`, not `summary`: the list painter
    /// draws `label` + right-aligned `detail` and uses `summary` only as a
    /// filter haystack, so a `summary`-carried status is computed and never
    /// painted (the "succeeds, does nothing" trap, caught by the picker
    /// paint test).
    static func overlay(statuses: [String: PagerSecretStatus]) -> PagerOverlay {
        .list(
            id: overlayID,
            title: "Select provider",
            rows: PagerLoginProviders.all.map { provider in
                PagerListRow(
                    id: provider.insertText,
                    label: provider.display,
                    detail: provider.isAPIKeyProvider
                        ? "API key · \(statuses[provider.insertText, default: .missing].display)"
                        : provider.neutralDescription
                )
            }
        )
    }
}

/// Upstream's independent-login completion copy
/// (`dispatch/task_result.rs:3853-3869`).
func liveCodexConnectedMessage(email: String?, planType: String?) -> String {
    var details: [String] = []
    if let email, !email.trimmingCharacters(in: .whitespaces).isEmpty {
        details.append(email)
    }
    if let planType, !planType.trimmingCharacters(in: .whitespaces).isEmpty {
        details.append("\(planType) plan")
    }
    return details.isEmpty
        ? "OpenAI Codex connected."
        : "OpenAI Codex connected: \(details.joined(separator: " · "))."
}
