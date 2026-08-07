// LiveCredentialResolver.swift
//
// Provider-identity -> outbound credential resolution for the live session.
//
// Precedence (matches the Rust shell contract):
//   1. `GROK_DEPLOYMENT_KEY` (xAI routes only) — bare Bearer, outranks all.
//   2. An explicit API key supplied by the caller (model `env_key`, provider
//      environment variable, `--api-key`). Explicit keys outrank stored OAuth.
//   3. Stored credentials for the provider:
//        * xAI    — `auth.json` session or API key via `AuthManager`.
//        * Codex  — the ISOLATED `codex-auth.json` OAuth store, refreshed on
//                   demand. Never reads `auth.json`.
//        * others — the provider-scoped API key in `auth.json`.
//
// Fail-closed: a missing or unrefreshable credential throws. A stale token is
// never used as a fallback, and the two stores never read each other.

import Foundation
import OpenGrokAuth
import OpenGrokModels
import OpenGrokSamplingTypes

/// Which rung of the precedence ladder produced a credential.
public enum LiveCredentialSource: String, Sendable, Equatable, Hashable {
    case deploymentKey
    case explicitAPIKey
    case storedAPIKey
    case storedSession
    case codexOAuth
    case namedAuthProvider
}

/// Non-secret auth facts that the live composition needs for telemetry gates.
///
/// API-key and deployment-key credentials intentionally carry the empty
/// context: a ZDR team is an OAuth/account fact, not a property inferred from
/// an arbitrary bearer string.
public struct ProviderTelemetryContext: Sendable, Equatable {
    public let zeroDataRetention: Bool
    public let userID: String?
    public let teamID: String?

    public init(
        zeroDataRetention: Bool = false,
        userID: String? = nil,
        teamID: String? = nil
    ) {
        self.zeroDataRetention = zeroDataRetention
        self.userID = userID
        self.teamID = teamID
    }

    public static let empty = ProviderTelemetryContext()
}

/// A resolved outbound credential plus the binding the provider session needs.
public struct LiveResolvedCredential: Sendable {
    public let provider: ModelProvider
    public let scope: String
    public let source: LiveCredentialSource
    public let authKind: BuiltInSessionAuthKind
    /// Wire bearer. Present for every successfully resolved credential.
    public let bearer: String
    /// Identity headers that must accompany the bearer (Codex account pinning).
    public let extraHeaders: [String: String]
    public let telemetryContext: ProviderTelemetryContext
    public let binding: ProviderCredentialBinding

    public init(
        provider: ModelProvider,
        scope: String,
        source: LiveCredentialSource,
        authKind: BuiltInSessionAuthKind,
        bearer: String,
        extraHeaders: [String: String] = [:],
        telemetryContext: ProviderTelemetryContext = .empty,
        binding: ProviderCredentialBinding
    ) {
        self.provider = provider
        self.scope = scope
        self.source = source
        self.authKind = authKind
        self.bearer = bearer
        self.extraHeaders = extraHeaders
        self.telemetryContext = telemetryContext
        self.binding = binding
    }
}

public enum LiveCredentialError: Error, Sendable, Equatable, CustomStringConvertible {
    /// No credential of any kind is available for the provider.
    case missingCredential(provider: ModelProvider, hint: String)
    /// The Codex store holds no usable OAuth tokens.
    case codexAuthRequired
    /// A Codex token refresh failed; the session must not proceed on the old token.
    case codexRefreshFailed(String)

    public var description: String {
        switch self {
        case .missingCredential(let provider, let hint):
            return "\(hint) is required for provider \(provider.asString)"
        case .codexAuthRequired:
            return codexAuthRequiredMessage
        case .codexRefreshFailed(let detail):
            return "Codex credentials could not be refreshed: \(detail)"
        }
    }
}

/// Resolves the credential a live session should present for a given provider.
public struct LiveCredentialResolver: Sendable {
    public let environment: [String: String]
    public let openGrokHome: URL
    public let codexAuthFile: URL
    public let codexRefreshService: CodexTokenRefreshService

    public init(
        environment: [String: String],
        openGrokHome: URL,
        codexAuthFile: URL? = nil,
        codexRefreshService: CodexTokenRefreshService = .storeOnly
    ) {
        self.environment = environment
        self.openGrokHome = openGrokHome
        self.codexAuthFile = codexAuthFile
            ?? OpenGrokAuthPaths.codexAuthFileURL(environment: environment)
        self.codexRefreshService = codexRefreshService
    }

    /// Resolve the credential for `provider`.
    ///
    /// `explicitAPIKey` is whatever the caller already extracted from the model
    /// profile or the provider's environment variable; when non-empty it wins
    /// over any stored OAuth session. Explicit and environment keys are the
    /// user's per-invocation choice and are deliberately *not* host-gated —
    /// upstream sends them to whatever `base_url` the user configured
    /// (`select_api_key`, `meta_models.rs:78-88`).
    ///
    /// `baseURL` is the endpoint the resolved credential will travel to. For
    /// the API-key providers, a *stored* first-party key resolves only when
    /// that endpoint is the provider's trusted host — a config-overridden
    /// `base_url` must not receive the stored key
    /// (`trusted_built_in_session_endpoint` applied inside
    /// `resolve_credentials`, xai-grok-shell `agent/config.rs:5430-5437`,
    /// `:5486-5503`). Passing `nil` fails closed for that rung: an endpoint we
    /// cannot vouch for is treated as untrusted, so the route ends in
    /// `missingCredential` rather than in a stored key on an unknown host.
    public func resolve(
        provider: ModelProvider,
        explicitAPIKey: String? = nil,
        baseURL: String? = nil,
        scope: String
    ) async throws -> LiveResolvedCredential {
        let explicit = Self.trimmed(explicitAPIKey)

        if provider == .xai {
            return try await resolveXAI(explicitAPIKey: explicit, scope: scope)
        }

        if let explicit {
            return Self.apiKeyCredential(
                provider: provider,
                scope: scope,
                source: .explicitAPIKey,
                key: explicit
            )
        }

        if provider == .codex {
            return try await resolveCodex(scope: scope)
        }

        let storedKeyEndpointTrusted = baseURL.map {
            trustedBuiltInSessionEndpoint(provider: provider, baseURL: $0)
        } ?? false
        if storedKeyEndpointTrusted,
           let stored = Self.trimmed(
               readProviderAPIKey(grokHome: openGrokHome, provider: provider.asString)
           ) {
            return Self.apiKeyCredential(
                provider: provider,
                scope: scope,
                source: .storedAPIKey,
                key: stored
            )
        }

        throw LiveCredentialError.missingCredential(
            provider: provider,
            hint: Self.credentialHint(provider)
        )
    }

    /// Convenience for call sites that only need the provider-session binding.
    public func binding(
        provider: ModelProvider,
        explicitAPIKey: String? = nil,
        baseURL: String? = nil,
        scope: String
    ) async throws -> ProviderCredentialBinding {
        try await resolve(
            provider: provider,
            explicitAPIKey: explicitAPIKey,
            baseURL: baseURL,
            scope: scope
        ).binding
    }

    /// Whether the provider can authenticate right now without prompting.
    /// Read-only: performs no refresh and no network I/O.
    public func hasStoredCredential(for provider: ModelProvider) -> Bool {
        if deploymentKeyFromEnvironment(environment) != nil, provider == .xai {
            return true
        }
        switch provider {
        case .xai:
            if xaiAPIKeyFromEnvironment(environment) != nil { return true }
            let path = OpenGrokAuthPaths.authFileURL(environment: environment)
            guard let store = try? readAuthJSONOrEmpty(at: path) else { return false }
            let config = GrokComConfig.default(environment: environment)
            return lookupAuth(store, scope: config.authScope) != nil
                || store[apiKeyScope] != nil
        case .codex:
            return isCodexLoggedIn(at: codexAuthFile)
        case .kimi, .fireworks, .deepseek, .meta, .openCodeGo, .wafer:
            // Meta joins the other API-key providers: the provider-scoped
            // stored key (`meta::api_key`, upstream `stored_api_key` at
            // meta_models.rs:74-76). This is only the "can authenticate at
            // all" hint; whether the key may travel to a given endpoint is
            // decided per-resolve by the trusted-host gate above.
            return readProviderAPIKey(grokHome: openGrokHome, provider: provider.asString) != nil
        }
    }

    // MARK: - Providers

    private func resolveXAI(
        explicitAPIKey: String?,
        scope: String
    ) async throws -> LiveResolvedCredential {
        let config = GrokComConfig.default(environment: environment)
        let manager = AuthManager(
            grokHome: openGrokHome,
            config: config,
            environment: environment
        )
        let resolvedExplicitAPIKey = config.apiKeyAuthDisabled(environment: environment)
            ? nil
            : explicitAPIKey
        let precedence = await resolveCredentialPrecedence(
            manager: manager,
            environment: environment,
            explicitAPIKey: resolvedExplicitAPIKey
        )
        let credentials = precedence.resolved

        if let deploymentKey = credentials.deploymentKey {
            return LiveResolvedCredential(
                provider: .xai,
                scope: scope,
                source: .deploymentKey,
                authKind: .apiKeyOnly,
                bearer: deploymentKey,
                binding: .deploymentKey(scope: scope, key: deploymentKey)
            )
        }

        guard let bearer = credentials.userToken else {
            throw LiveCredentialError.missingCredential(
                provider: .xai,
                hint: Self.credentialHint(.xai)
            )
        }

        if let resolvedExplicitAPIKey, bearer == resolvedExplicitAPIKey {
            return Self.apiKeyCredential(
                provider: .xai,
                scope: scope,
                source: .explicitAPIKey,
                key: bearer
            )
        }

        let session = precedence.session
        if session == nil || session?.authMode == .apiKey {
            return Self.apiKeyCredential(
                provider: .xai,
                scope: scope,
                source: .storedAPIKey,
                key: bearer
            )
        }

        // OIDC / OAuth session: bind the live manager so a 401 can refresh once.
        return LiveResolvedCredential(
            provider: .xai,
            scope: scope,
            source: .storedSession,
            authKind: .xaiSession,
            bearer: bearer,
            telemetryContext: ProviderTelemetryContext(
                zeroDataRetention: session?.isZDRTeam == true,
                userID: session?.userID.isEmpty == false ? session?.userID : nil,
                teamID: session?.teamID
            ),
            binding: ProviderCredentialBinding(
                scope: scope,
                kind: .xaiSession,
                source: LiveAuthCredentialProvider(manager: manager)
            )
        )
    }

    private func resolveCodex(scope: String) async throws -> LiveResolvedCredential {
        guard isCodexLoggedIn(at: codexAuthFile) else {
            throw LiveCredentialError.codexAuthRequired
        }
        let provider = CodexAuthCredentialProvider(
            authFile: codexAuthFile,
            refreshService: codexRefreshService
        )
        let credentials: CodexCredentials
        do {
            credentials = try await provider.ensureFreshCredentials()
        } catch let error as LiveCredentialError {
            throw error
        } catch {
            throw LiveCredentialError.codexRefreshFailed(Self.describe(error))
        }
        guard let resolved = resolveCodexBearer(
            credentials: credentials,
            expectedIdentity: provider.expectedIdentity
        ) else {
            throw LiveCredentialError.codexAuthRequired
        }
        return LiveResolvedCredential(
            provider: .codex,
            scope: scope,
            source: .codexOAuth,
            authKind: .codexOAuth,
            bearer: resolved.bearer,
            extraHeaders: resolved.extraHeaders,
            binding: ProviderCredentialBinding(
                scope: scope,
                kind: .codexOAuth,
                source: provider
            )
        )
    }

    // MARK: - Helpers

    private static func apiKeyCredential(
        provider: ModelProvider,
        scope: String,
        source: LiveCredentialSource,
        key: String
    ) -> LiveResolvedCredential {
        LiveResolvedCredential(
            provider: provider,
            scope: scope,
            source: source,
            authKind: .apiKeyOnly,
            bearer: key,
            binding: .apiKey(scope: scope, key: key)
        )
    }

    /// Human-facing name of the credential a provider expects. Never a secret.
    public static func credentialHint(_ provider: ModelProvider) -> String {
        switch provider {
        case .xai:
            return "XAI_API_KEY or `open-grok login`"
        case .codex:
            return "Codex OAuth credentials (`open-grok login --codex`)"
        case .kimi:
            return "MOONSHOT_API_KEY or KIMI_CODE_API_KEY"
        case .fireworks:
            return "FIREWORKS_API_KEY"
        case .deepseek:
            return "DEEPSEEK_API_KEY or `open-grok login --deepseek`"
        case .meta:
            // Upstream's Meta credential env key (meta_models.rs:16).
            return "META_API_KEY"
        case .openCodeGo:
            return "OPENCODE_API_KEY"
        case .wafer:
            return "WAFER_API_KEY"
        }
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    private static func describe(_ error: Error) -> String {
        // `String(describing:)` already prefers `CustomStringConvertible`, so
        // the previous explicit cast (an always-succeeding `as?` warning) was
        // pure noise with identical behavior.
        String(describing: error)
    }
}
