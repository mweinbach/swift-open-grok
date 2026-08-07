// LiveCredentialResolverTests.swift
//
// Credential precedence and store isolation for the live session resolver.
// Every case runs against an isolated OPENGROK_HOME under the system temp
// directory and an explicit environment dictionary, so the developer's real
// ~/.opengrok is never read or written and no network is reachable.

import Foundation
import Testing
@testable import OpenGrokProviderSession
import OpenGrokAuth
import OpenGrokModels
import OpenGrokSamplingTypes

private struct ResolverFixture {
    let home: URL
    let environment: [String: String]

    var authFile: URL { home.appendingPathComponent(OpenGrokAuthPaths.authFileName) }
    var codexFile: URL { home.appendingPathComponent(OpenGrokAuthPaths.codexAuthFileName) }

    init(extraEnvironment: [String: String] = [:]) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        home = root
        var env = extraEnvironment
        env["OPENGROK_HOME"] = root.path
        env["HOME"] = root.path
        environment = env
    }

    func dispose() {
        try? FileManager.default.removeItem(at: home)
    }

    func resolver(
        codexRefreshService: CodexTokenRefreshService = .storeOnly
    ) -> LiveCredentialResolver {
        LiveCredentialResolver(
            environment: environment,
            openGrokHome: home,
            codexRefreshService: codexRefreshService
        )
    }

    func writeCodexCredentials(account: String = "acct-1") throws {
        let idToken = buildTestJWT(payload: [
            "email": "person@openai.com",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": account,
                "chatgpt_plan_type": "plus",
                "chatgpt_user_id": "user-1",
            ],
            "exp": Int(Date().addingTimeInterval(3600).timeIntervalSince1970),
        ])
        let access = buildTestJWT(payload: [
            "exp": Int(Date().addingTimeInterval(3600).timeIntervalSince1970),
        ])
        try persistCodexTokens(
            at: codexFile,
            idToken: idToken,
            accessToken: access,
            refreshToken: "codex-refresh",
            accountID: account
        )
    }
}

@Suite("Live credential resolver")
struct LiveCredentialResolverTests {
    @Test("stored xAI API key resolves without touching the codex store")
    func resolvesStoredXAIKey() async throws {
        let fixture = try ResolverFixture()
        defer { fixture.dispose() }
        try storeAPIKey(grokHome: fixture.home, apiKey: "xai-stored-key")

        let resolved = try await fixture.resolver().resolve(provider: .xai, scope: "cli:test")
        #expect(resolved.bearer == "xai-stored-key")
        #expect(resolved.authKind == .apiKeyOnly)
        #expect(resolved.source == .storedAPIKey)
        #expect(!FileManager.default.fileExists(atPath: fixture.codexFile.path))
    }

    @Test("GROK_DEPLOYMENT_KEY outranks every stored xAI credential")
    func deploymentKeyWins() async throws {
        let fixture = try ResolverFixture(extraEnvironment: ["GROK_DEPLOYMENT_KEY": "deploy-key"])
        defer { fixture.dispose() }
        try storeAPIKey(grokHome: fixture.home, apiKey: "xai-stored-key")

        let resolved = try await fixture.resolver().resolve(provider: .xai, scope: "cli:test")
        #expect(resolved.bearer == "deploy-key")
        #expect(resolved.source == .deploymentKey)
    }

    @Test("an explicit model API key outranks stored Codex OAuth")
    func explicitKeyBeatsOAuth() async throws {
        let fixture = try ResolverFixture()
        defer { fixture.dispose() }
        try fixture.writeCodexCredentials()

        let resolved = try await fixture.resolver().resolve(
            provider: .codex,
            explicitAPIKey: "sk-explicit",
            scope: "cli:test"
        )
        #expect(resolved.bearer == "sk-explicit")
        #expect(resolved.source == .explicitAPIKey)
        #expect(resolved.authKind == .apiKeyOnly)
        #expect(resolved.extraHeaders.isEmpty)
    }

    @Test("Codex resolves from its own store with no xAI credentials present")
    func codexOnlyNeedsNoXAI() async throws {
        let fixture = try ResolverFixture()
        defer { fixture.dispose() }
        try fixture.writeCodexCredentials()

        let resolver = fixture.resolver()
        #expect(!FileManager.default.fileExists(atPath: fixture.authFile.path))

        let resolved = try await resolver.resolve(provider: .codex, scope: "cli:test")
        #expect(resolved.source == .codexOAuth)
        #expect(resolved.authKind == .codexOAuth)
        #expect(resolved.extraHeaders["ChatGPT-Account-ID"] == "acct-1")
        #expect(resolver.hasStoredCredential(for: .codex))
        // Signing in to Codex never creates or populates auth.json.
        #expect(!FileManager.default.fileExists(atPath: fixture.authFile.path))
    }

    @Test("the two stores cannot cross-read")
    func storesAreIsolated() async throws {
        let fixture = try ResolverFixture()
        defer { fixture.dispose() }
        try storeAPIKey(grokHome: fixture.home, apiKey: "xai-stored-key")
        let resolver = fixture.resolver()

        // xAI credentials never satisfy a Codex route.
        #expect(!resolver.hasStoredCredential(for: .codex))
        await #expect(throws: LiveCredentialError.codexAuthRequired) {
            _ = try await resolver.resolve(provider: .codex, scope: "cli:test")
        }

        // Codex credentials never satisfy an xAI route.
        let codexOnly = try ResolverFixture()
        defer { codexOnly.dispose() }
        try codexOnly.writeCodexCredentials()
        let codexResolver = codexOnly.resolver()
        #expect(!codexResolver.hasStoredCredential(for: .xai))
        await #expect(throws: LiveCredentialError.self) {
            _ = try await codexResolver.resolve(provider: .xai, scope: "cli:test")
        }
    }

    @Test("an expired Codex token is refreshed before the session starts")
    func refreshesExpiredCodexToken() async throws {
        let fixture = try ResolverFixture()
        defer { fixture.dispose() }
        let idToken = buildTestJWT(payload: [
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct-1"],
            "exp": Int(Date().addingTimeInterval(3600).timeIntervalSince1970),
        ])
        try persistCodexTokens(
            at: fixture.codexFile,
            idToken: idToken,
            accessToken: buildTestJWT(payload: [
                "exp": Int(Date().addingTimeInterval(-120).timeIntervalSince1970),
            ]),
            refreshToken: "codex-refresh",
            accountID: "acct-1"
        )

        let refreshes = RefreshCounter()
        let service = CodexTokenRefreshService { authFile, _ in
            await refreshes.increment()
            try persistCodexTokens(
                at: authFile,
                idToken: idToken,
                accessToken: "refreshed-access",
                refreshToken: "codex-refresh-2",
                accountID: "acct-1"
            )
            return try loadCodexCredentials(at: authFile)
        }

        let resolved = try await fixture
            .resolver(codexRefreshService: service)
            .resolve(provider: .codex, scope: "cli:test")
        #expect(resolved.bearer == "refreshed-access")
        let refreshCount = await refreshes.value
        #expect(refreshCount == 1)
    }

    @Test("a failed Codex refresh fails the route instead of using the old token")
    func failsClosedOnRefreshFailure() async throws {
        let fixture = try ResolverFixture()
        defer { fixture.dispose() }
        try fixture.writeCodexCredentials()

        let service = CodexTokenRefreshService { _, _ in
            throw AuthError.protocolError("Codex OAuth refresh returned 401")
        }
        await #expect(throws: LiveCredentialError.self) {
            _ = try await fixture
                .resolver(codexRefreshService: service)
                .resolve(provider: .codex, scope: "cli:test")
        }
    }

    @Test("providers without a credential report a non-secret hint")
    func missingCredentialHint() async throws {
        let fixture = try ResolverFixture()
        defer { fixture.dispose() }
        let resolver = fixture.resolver()

        await #expect(
            throws: LiveCredentialError.missingCredential(
                provider: .fireworks,
                hint: LiveCredentialResolver.credentialHint(.fireworks)
            )
        ) {
            _ = try await resolver.resolve(provider: .fireworks, scope: "cli:test")
        }
    }

    @Test("a stored Meta key resolves and hints once the provider store holds one")
    func metaStoredCredentialAndHint() async throws {
        let fixture = try ResolverFixture()
        defer { fixture.dispose() }
        let resolver = fixture.resolver()

        #expect(!resolver.hasStoredCredential(for: .meta))
        try storeProviderAPIKey(
            grokHome: fixture.home,
            provider: ModelProvider.meta.asString,
            apiKey: "meta-stored-secret"
        )
        #expect(resolver.hasStoredCredential(for: .meta))
        #expect(LiveCredentialResolver.credentialHint(.meta) == "META_API_KEY")

        let resolved = try await resolver.resolve(
            provider: .meta,
            baseURL: MetaModels.apiBaseURLDefault,
            scope: "cli:test"
        )
        #expect(resolved.bearer == "meta-stored-secret")
        #expect(resolved.source == .storedAPIKey)
        #expect(resolved.authKind == .apiKeyOnly)
    }
}

/// Resolver half of upstream's regression test
/// `stored_meta_and_wafer_keys_resolve_only_on_trusted_hosts`
/// (xai-grok-shell agent/config.rs:7418-7458 at HEAD 70002584): a stored
/// first-party provider key resolves only when the model's endpoint is that
/// provider's trusted host; environment keys are the user's explicit choice
/// and are not host-gated (`select_api_key`, meta_models.rs:78-88).
@Suite("Stored provider keys are host-gated")
struct StoredKeyTrustedHostTests {
    @Test("stored Meta and Wafer keys resolve only on trusted hosts")
    func storedMetaAndWaferKeysResolveOnlyOnTrustedHosts() async throws {
        let fixture = try ResolverFixture()
        defer { fixture.dispose() }
        try storeProviderAPIKey(
            grokHome: fixture.home,
            provider: ModelProvider.meta.asString,
            apiKey: "meta-stored-secret"
        )
        try storeProviderAPIKey(
            grokHome: fixture.home,
            provider: ModelProvider.wafer.asString,
            apiKey: "wafer-stored-secret"
        )
        let resolver = fixture.resolver()

        let meta = try await resolver.resolve(
            provider: .meta,
            baseURL: MetaModels.apiBaseURLDefault,
            scope: "cli:test"
        )
        #expect(meta.bearer == "meta-stored-secret")
        #expect(meta.source == .storedAPIKey)

        await #expect(throws: LiveCredentialError.missingCredential(
            provider: .meta,
            hint: LiveCredentialResolver.credentialHint(.meta)
        )) {
            _ = try await resolver.resolve(
                provider: .meta,
                baseURL: "https://proxy.example/v1",
                scope: "cli:test"
            )
        }

        let wafer = try await resolver.resolve(
            provider: .wafer,
            baseURL: WaferModels.apiBaseURLDefault,
            scope: "cli:test"
        )
        #expect(wafer.bearer == "wafer-stored-secret")
        #expect(wafer.source == .storedAPIKey)

        await #expect(throws: LiveCredentialError.missingCredential(
            provider: .wafer,
            hint: LiveCredentialResolver.credentialHint(.wafer)
        )) {
            _ = try await resolver.resolve(
                provider: .wafer,
                baseURL: "https://proxy.example/v1",
                scope: "cli:test"
            )
        }
    }

    @Test("an environment key is not host-gated and outranks the stored key")
    func environmentKeyResolvesOnUntrustedHost() async throws {
        let fixture = try ResolverFixture()
        defer { fixture.dispose() }
        try storeProviderAPIKey(
            grokHome: fixture.home,
            provider: ModelProvider.meta.asString,
            apiKey: "meta-stored-secret"
        )
        let resolver = fixture.resolver()

        // Upstream sends the env key to whatever base_url the user
        // configured — it is their explicit per-invocation choice
        // (`select_api_key`, meta_models.rs:78-88).
        let resolved = try await resolver.resolve(
            provider: .meta,
            explicitAPIKey: "meta-env-key",
            baseURL: "https://proxy.example/v1",
            scope: "cli:test"
        )
        #expect(resolved.bearer == "meta-env-key")
        #expect(resolved.source == .explicitAPIKey)
    }

    @Test("no base URL fails closed for the stored-key rung")
    func nilBaseURLWithholdsStoredKey() async throws {
        let fixture = try ResolverFixture()
        defer { fixture.dispose() }
        try storeProviderAPIKey(
            grokHome: fixture.home,
            provider: ModelProvider.meta.asString,
            apiKey: "meta-stored-secret"
        )
        let resolver = fixture.resolver()

        // An endpoint the caller cannot name is an endpoint we cannot vouch
        // for: the stored key stays home rather than following an unknown
        // host (AGENTS.md §5 — fail-closed means fail-closed).
        await #expect(throws: LiveCredentialError.missingCredential(
            provider: .meta,
            hint: LiveCredentialResolver.credentialHint(.meta)
        )) {
            _ = try await resolver.resolve(provider: .meta, scope: "cli:test")
        }
    }
}

private actor RefreshCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
