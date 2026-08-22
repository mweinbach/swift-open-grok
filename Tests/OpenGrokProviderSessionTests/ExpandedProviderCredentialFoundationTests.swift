import Foundation
import Testing
@testable import OpenGrokProviderSession
import OpenGrokAuth
import OpenGrokSamplingTypes

private struct ExpandedProviderResolverFixture {
    let home: URL
    let environment: [String: String]

    init(environment overrides: [String: String] = [:]) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-provider-credential-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var environment = overrides
        environment["OPENGROK_HOME"] = home.path
        environment["HOME"] = home.path
        self.environment = environment
    }

    var resolver: LiveCredentialResolver {
        LiveCredentialResolver(environment: environment, openGrokHome: home)
    }
}

@Suite("Expanded provider credential isolation and trusted endpoints")
struct ExpandedProviderCredentialFoundationTests {
    @Test("provider-scoped stored keys resolve only for their matching official hosts")
    func storedProviderKeysResolveOnOfficialHosts() async throws {
        let fixture = try ExpandedProviderResolverFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        try storeRunInfraAPIKey(grokHome: fixture.home, apiKey: "runinfra-private")
        try storeGeminiAPIKey(grokHome: fixture.home, apiKey: "gemini-private")
        try storeOpenRouterAPIKey(grokHome: fixture.home, apiKey: "openrouter-private")

        let providers: [(ModelProvider, String, String)] = [
            (.runinfra, "https://api.runinfra.ai/v1", "runinfra-private"),
            (.gemini, "https://generativelanguage.googleapis.com/v1beta/openai", "gemini-private"),
            (.openRouter, "https://openrouter.ai/api/v1", "openrouter-private"),
        ]

        for (provider, endpoint, expectedKey) in providers {
            let resolved = try await fixture.resolver.resolve(
                provider: provider,
                baseURL: endpoint,
                scope: "session:\(provider.asString)"
            )
            #expect(resolved.provider == provider)
            #expect(resolved.source == .storedAPIKey)
            #expect(resolved.authKind == .apiKeyOnly)
            #expect(resolved.bearer == expectedKey)
            #expect(resolved.extraHeaders.isEmpty)
            #expect(resolved.telemetryContext == .empty)
        }
    }

    @Test("stored provider keys never authenticate foreign, HTTP, or sibling-provider endpoints")
    func storedProviderKeysFailClosedOnUntrustedEndpoints() async throws {
        let fixture = try ExpandedProviderResolverFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        try storeRunInfraAPIKey(grokHome: fixture.home, apiKey: "runinfra-private")
        try storeGeminiAPIKey(grokHome: fixture.home, apiKey: "gemini-private")
        try storeOpenRouterAPIKey(grokHome: fixture.home, apiKey: "openrouter-private")

        let denied: [(ModelProvider, String?)] = [
            (.runinfra, "https://attacker.example/v1"),
            (.runinfra, "http://api.runinfra.ai/v1"),
            (.runinfra, "https://openrouter.ai/api/v1"),
            (.gemini, "https://generativelanguage.googleapis.com.attacker.example/v1"),
            (.gemini, "https://api.runinfra.ai/v1"),
            (.openRouter, "http://openrouter.ai/api/v1"),
            (.openRouter, "https://generativelanguage.googleapis.com/v1beta/openai"),
            (.openRouter, nil),
        ]

        for (provider, endpoint) in denied {
            await #expect(throws: LiveCredentialError.missingCredential(
                provider: provider,
                hint: LiveCredentialResolver.credentialHint(provider)
            )) {
                _ = try await fixture.resolver.resolve(
                    provider: provider,
                    baseURL: endpoint,
                    scope: "session:\(provider.asString)"
                )
            }
        }
    }

    @Test("RunInfra explicit keys beat gateway keys, aliases, and stored credentials")
    func runInfraEnvironmentPrecedence() async throws {
        let fixture = try ExpandedProviderResolverFixture(environment: [
            runInfraGatewayKeyEnv: " preferred-gateway ",
            runInfraAPIKeyEnv: "fallback-gateway",
        ])
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        try storeRunInfraAPIKey(grokHome: fixture.home, apiKey: "stored-gateway")

        let environmentKey = try await fixture.resolver.resolve(
            provider: .runinfra,
            baseURL: "https://configured-proxy.example/v1",
            scope: "session:runinfra"
        )
        #expect(environmentKey.source == .explicitAPIKey)
        #expect(environmentKey.bearer == "preferred-gateway")

        let explicit = try await fixture.resolver.resolve(
            provider: .runinfra,
            explicitAPIKey: " explicit-model-key ",
            baseURL: "https://configured-proxy.example/v1",
            scope: "session:runinfra"
        )
        #expect(explicit.bearer == "explicit-model-key")
    }

    @Test("Gemini API key beats Google alias and falls back when the primary is blank")
    func geminiEnvironmentPrecedence() async throws {
        let primary = try ExpandedProviderResolverFixture(environment: [
            geminiAPIKeyEnv: "dedicated-gemini",
            googleAPIKeyEnv: "generic-google",
        ])
        defer { try? FileManager.default.removeItem(at: primary.home) }

        let primaryResolved = try await primary.resolver.resolve(
            provider: .gemini,
            baseURL: "https://configured-proxy.example/v1",
            scope: "session:gemini"
        )
        #expect(primaryResolved.bearer == "dedicated-gemini")

        let fallback = try ExpandedProviderResolverFixture(environment: [
            geminiAPIKeyEnv: " \n ",
            googleAPIKeyEnv: "generic-google",
        ])
        defer { try? FileManager.default.removeItem(at: fallback.home) }

        let fallbackResolved = try await fallback.resolver.resolve(
            provider: .gemini,
            baseURL: "https://configured-proxy.example/v1",
            scope: "session:gemini"
        )
        #expect(fallbackResolved.bearer == "generic-google")
    }

    @Test("OpenRouter environment credentials may use an explicitly configured custom endpoint")
    func openRouterEnvironmentCredentialsHonorCustomEndpoints() async throws {
        let fixture = try ExpandedProviderResolverFixture(environment: [
            openRouterAPIKeyEnv: " selected-openrouter-key ",
        ])
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        try storeOpenRouterAPIKey(grokHome: fixture.home, apiKey: "stored-openrouter-key")

        let resolved = try await fixture.resolver.resolve(
            provider: .openRouter,
            baseURL: "http://127.0.0.1:18432/v1",
            scope: "session:openrouter"
        )
        #expect(resolved.bearer == "selected-openrouter-key")
        #expect(resolved.authKind == .apiKeyOnly)
        #expect(resolved.extraHeaders.isEmpty)
    }

    @Test("sibling environment and stored credentials never satisfy another provider")
    func siblingProviderCredentialsNeverLeak() async throws {
        let fixture = try ExpandedProviderResolverFixture(environment: [
            runInfraGatewayKeyEnv: "runinfra-environment-secret",
            googleAPIKeyEnv: "google-environment-secret",
        ])
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        try storeAPIKey(grokHome: fixture.home, apiKey: "xai-private")
        try storeRunInfraAPIKey(grokHome: fixture.home, apiKey: "runinfra-stored-secret")

        await #expect(throws: LiveCredentialError.missingCredential(
            provider: .openRouter,
            hint: "OPENROUTER_API_KEY"
        )) {
            _ = try await fixture.resolver.resolve(
                provider: .openRouter,
                baseURL: "https://openrouter.ai/api/v1",
                scope: "session:openrouter"
            )
        }
        #expect(!fixture.resolver.hasStoredCredential(for: .openRouter))
        #expect(fixture.resolver.hasStoredCredential(for: .runinfra))
        #expect(fixture.resolver.hasStoredCredential(for: .gemini))
    }

    @Test("missing credential hints identify the correct provider without exposing secrets")
    func providerHintsAreNonSecretAndSpecific() {
        #expect(LiveCredentialResolver.credentialHint(.runinfra)
            == "RUNINFRA_GATEWAY_KEY or RUNINFRA_API_KEY")
        #expect(LiveCredentialResolver.credentialHint(.gemini)
            == "GEMINI_API_KEY or GOOGLE_API_KEY")
        #expect(LiveCredentialResolver.credentialHint(.openRouter) == "OPENROUTER_API_KEY")
    }
}
