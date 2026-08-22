import Foundation
import Testing
@testable import OpenGrokCLI
import OpenGrokAuth
import OpenGrokHTTP

private struct ExpandedProviderCLIFixture {
    let home: URL
    let environment: [String: String]

    init(environment overrides: [String: String] = [:]) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-provider-auth-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var environment = overrides
        environment["OPENGROK_HOME"] = home.path
        environment["HOME"] = home.path
        self.environment = environment
    }

    var services: LiveAuthServices {
        LiveAuthServices(
            makeTransport: { MockHTTPTransport(responses: []) },
            codexBrowserLogin: { _, _, _, _ in throw AuthError.notLoggedIn },
            codexDeviceLogin: { _, _, _, _ in throw AuthError.notLoggedIn },
            openBrowser: nil,
            readSecretLine: { nil },
            isInteractive: { false }
        )
    }

    func options(
        _ name: String,
        values: [String] = [],
        flags: [String] = [],
        json: Bool = false
    ) -> CLIUtilityOptions {
        CLIUtilityOptions(
            name: name,
            values: values,
            options: Dictionary(uniqueKeysWithValues: flags.map { ($0, "true") }),
            json: json
        )
    }
}

@Suite("RunInfra, Gemini, and OpenRouter live authentication")
struct ExpandedProviderAuthCLIParityTests {
    @Test("positional provider aliases and flags select their own account targets")
    func cliTargetsResolveProviderAliases() throws {
        let fixture = try ExpandedProviderCLIFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        for alias in ["runinfra", "run-infra", "run_infra"] {
            #expect(try LiveAuthComposition.target(for: fixture.options("login", values: [alias])) == .runinfra)
        }
        for alias in ["gemini", "google", "google-gemini", "ai-studio", "aistudio"] {
            #expect(try LiveAuthComposition.target(for: fixture.options("login", values: [alias])) == .gemini)
        }
        for alias in ["openrouter", "open-router", "open_router"] {
            #expect(try LiveAuthComposition.target(for: fixture.options("login", values: [alias])) == .openRouter)
        }

        #expect(try LiveAuthComposition.target(for: fixture.options("login", flags: ["--runinfra"])) == .runinfra)
        #expect(try LiveAuthComposition.target(for: fixture.options("login", flags: ["--google"])) == .gemini)
        #expect(try LiveAuthComposition.target(for: fixture.options("login", flags: ["--openrouter"])) == .openRouter)
    }

    @Test("live provider login persists only the selected canonical scope without printing its secret")
    func positionalLoginsPersistIsolatedScopes() async throws {
        let fixture = try ExpandedProviderCLIFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        let providers = [
            ("run-infra", "runinfra", "RunInfra", "runinfra-secret-key"),
            ("google", "gemini", "Google Gemini", "gemini-secret-key"),
            ("open-router", "openrouter", "OpenRouter", "openrouter-secret-key"),
        ]

        for (alias, canonical, display, secret) in providers {
            let (streams, stdout, stderr) = CLIStreams.buffered()
            try await LiveAuthComposition.run(
                options: fixture.options("login", values: [alias, secret]),
                environment: fixture.environment,
                streams: streams,
                services: fixture.services
            )

            #expect(readProviderAPIKey(grokHome: fixture.home, provider: canonical) == secret)
            #expect(stdout.contents.contains("Signed in to \(display) with an API key."))
            #expect(!stdout.contents.contains(secret))
            #expect(!stderr.contents.contains(secret))
        }

        #expect(readRunInfraAPIKey(grokHome: fixture.home) == "runinfra-secret-key")
        #expect(readGeminiAPIKey(grokHome: fixture.home) == "gemini-secret-key")
        #expect(readOpenRouterAPIKey(grokHome: fixture.home) == "openrouter-secret-key")
    }

    @Test("live login honors provider environment alias precedence")
    func environmentLoginsHonorUpstreamPrecedence() async throws {
        let fixture = try ExpandedProviderCLIFixture(environment: [
            runInfraGatewayKeyEnv: "runinfra-primary-secret",
            runInfraAPIKeyEnv: "runinfra-fallback-secret",
            geminiAPIKeyEnv: "gemini-primary-secret",
            googleAPIKeyEnv: "gemini-fallback-secret",
            openRouterAPIKeyEnv: "openrouter-environment-secret",
        ])
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        for provider in ["runinfra", "gemini", "openrouter"] {
            let (streams, _, _) = CLIStreams.buffered()
            try await LiveAuthComposition.run(
                options: fixture.options("login", values: [provider]),
                environment: fixture.environment,
                streams: streams,
                services: fixture.services
            )
        }

        #expect(readRunInfraAPIKey(grokHome: fixture.home) == "runinfra-primary-secret")
        #expect(readGeminiAPIKey(grokHome: fixture.home) == "gemini-primary-secret")
        #expect(readOpenRouterAPIKey(grokHome: fixture.home) == "openrouter-environment-secret")
    }

    @Test("logging out one provider preserves all sibling account credentials")
    func liveProviderLogoutPreservesSiblings() async throws {
        let fixture = try ExpandedProviderCLIFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        try storeRunInfraAPIKey(grokHome: fixture.home, apiKey: "runinfra-private")
        try storeGeminiAPIKey(grokHome: fixture.home, apiKey: "gemini-private")
        try storeOpenRouterAPIKey(grokHome: fixture.home, apiKey: "openrouter-private")

        let (streams, stdout, _) = CLIStreams.buffered()
        try await LiveAuthComposition.run(
            options: fixture.options("logout", values: ["google"]),
            environment: fixture.environment,
            streams: streams,
            services: fixture.services
        )

        #expect(stdout.contents.contains("Signed out of Google Gemini; key removed from auth.json."))
        #expect(readGeminiAPIKey(grokHome: fixture.home) == nil)
        #expect(readRunInfraAPIKey(grokHome: fixture.home) == "runinfra-private")
        #expect(readOpenRouterAPIKey(grokHome: fixture.home) == "openrouter-private")
    }

    @Test("status JSON reports canonical provider identities and never serializes API keys")
    func statusJSONNeverExposesSecrets() throws {
        let fixture = try ExpandedProviderCLIFixture(environment: [
            runInfraAPIKeyEnv: "runinfra-secret-value",
            googleAPIKeyEnv: "gemini-secret-value",
        ])
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        try storeOpenRouterAPIKey(grokHome: fixture.home, apiKey: "openrouter-secret-value")

        let status = LiveAuthComposition.status(environment: fixture.environment)
        #expect(status.runinfra == LiveAuthProviderStatus(authenticated: true, source: "environment"))
        #expect(status.gemini == LiveAuthProviderStatus(authenticated: true, source: "environment"))
        #expect(status.openRouter == LiveAuthProviderStatus(authenticated: true, source: "api_key"))

        let data = try JSONEncoder().encode(status)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for provider in ["runinfra", "gemini", "openrouter"] {
            let entry = try #require(json[provider] as? [String: Any])
            #expect(entry["authenticated"] as? Bool == true)
        }
        let encoded = String(decoding: data, as: UTF8.self)
        #expect(!encoded.contains("runinfra-secret-value"))
        #expect(!encoded.contains("gemini-secret-value"))
        #expect(!encoded.contains("openrouter-secret-value"))
    }

    @Test("provider picker observes environment aliases and provider-isolated persisted keys")
    func providerPickerRecognizesProviderAliases() throws {
        let fixture = try ExpandedProviderCLIFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        try storeOpenRouterAPIKey(grokHome: fixture.home, apiKey: "openrouter-private")

        let statuses = LiveLoginProviderPicker.statuses(
            openGrokHome: fixture.home,
            environment: [
                runInfraAPIKeyEnv: "runinfra-fallback",
                googleAPIKeyEnv: "google-fallback",
            ]
        )

        #expect(statuses["runinfra"] == .environmentOverride)
        #expect(statuses["gemini"] == .environmentOverride)
        #expect(statuses["openrouter"] == .stored)
    }

    @Test("provider login fails closed instead of borrowing another provider's environment key")
    func providerLoginDoesNotBorrowSiblingEnvironment() async throws {
        let fixture = try ExpandedProviderCLIFixture(environment: [
            runInfraGatewayKeyEnv: "runinfra-private",
            googleAPIKeyEnv: "google-private",
        ])
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let (streams, _, _) = CLIStreams.buffered()

        await #expect(throws: CLIApplicationError.self) {
            try await LiveAuthComposition.run(
                options: fixture.options("login", values: ["openrouter"]),
                environment: fixture.environment,
                streams: streams,
                services: fixture.services
            )
        }
        #expect(readOpenRouterAPIKey(grokHome: fixture.home) == nil)
    }
}
