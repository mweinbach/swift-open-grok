// MultiProviderAuthCLITests.swift
//
// Tests for multi-provider CLI authentication (login, logout, status, target parsing)
// in OpenGrokCLI against isolated temporary homes.

import Foundation
import Testing
@testable import OpenGrokCLI
import OpenGrokAuth
import OpenGrokHTTP

private struct MultiAuthCommandFixture {
    let home: URL
    let environment: [String: String]

    var authFile: URL { home.appendingPathComponent(OpenGrokAuthPaths.authFileName) }
    var codexFile: URL { home.appendingPathComponent(OpenGrokAuthPaths.codexAuthFileName) }

    init(extraEnvironment: [String: String] = [:]) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-multiauth-test-\(UUID().uuidString)", isDirectory: true)
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
}

private func makeAuthOptions(
    _ name: String,
    values: [String] = [],
    flags: [String] = [],
    json: Bool = false
) -> CLIUtilityOptions {
    var options: [String: String] = [:]
    for flag in flags {
        options[flag] = "true"
    }
    return CLIUtilityOptions(name: name, values: values, options: options, json: json)
}

private func makeInteractiveServices(secret: String?) -> LiveAuthServices {
    LiveAuthServices(
        makeTransport: { MockHTTPTransport(responses: []) },
        codexBrowserLogin: { _, _, _, _ in throw AuthError.notLoggedIn },
        codexDeviceLogin: { _, _, _, _ in throw AuthError.notLoggedIn },
        openBrowser: nil,
        readSecretLine: { secret },
        isInteractive: { true }
    )
}

private func makeNonInteractiveServices() -> LiveAuthServices {
    LiveAuthServices(
        makeTransport: { MockHTTPTransport(responses: []) },
        codexBrowserLogin: { _, _, _, _ in throw AuthError.notLoggedIn },
        codexDeviceLogin: { _, _, _, _ in throw AuthError.notLoggedIn },
        openBrowser: nil,
        readSecretLine: { nil },
        isInteractive: { false }
    )
}

@Suite("Multi-Provider Auth CLI")
struct MultiProviderAuthCLITests {

    // MARK: - Target Parsing Tests

    @Test("Target parsing maps flags to correct targets")
    func testTargetParsingFlags() throws {
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("logout", flags: ["--all"])) == .all)
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("login", flags: ["--codex"])) == .codex)
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("login", flags: ["--kimi"])) == .kimi)
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("login", flags: ["--fireworks"])) == .fireworks)
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("login", flags: ["--deepseek"])) == .deepseek)
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("login", flags: ["--meta"])) == .meta)
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("login", flags: ["--opencode-go"])) == .openCodeGo)
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("login", flags: ["--wafer"])) == .wafer)
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("login", flags: ["--zai"])) == .zai)
    }

    @Test("Target parsing maps positional values and aliases")
    func testTargetParsingPositionalValues() throws {
        // Default with no values
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("login")) == .xai)

        // all
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("logout", values: ["all"])) == .all)

        // codex / openai / chatgpt
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("login", values: ["codex"])) == .codex)
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("login", values: ["openai"])) == .codex)
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("login", values: ["chatgpt"])) == .codex)

        // xai / grok
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("login", values: ["xai"])) == .xai)
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("login", values: ["grok"])) == .xai)

        // kimi / moonshot
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("login", values: ["kimi"])) == .kimi)
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("login", values: ["moonshot"])) == .kimi)

        // fireworks
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("login", values: ["fireworks"])) == .fireworks)

        // deepseek / deep-seek
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("login", values: ["deepseek"])) == .deepseek)
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("login", values: ["deep-seek"])) == .deepseek)

        // meta / meta-ai / meta-api
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("login", values: ["meta"])) == .meta)
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("login", values: ["meta-ai"])) == .meta)
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("login", values: ["meta-api"])) == .meta)

        // opencode-go / opencode_go / opencode / go
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("login", values: ["opencode-go"])) == .openCodeGo)
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("login", values: ["opencode_go"])) == .openCodeGo)
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("login", values: ["opencode"])) == .openCodeGo)
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("login", values: ["go"])) == .openCodeGo)

        // wafer / wafer-ai / wafer_ai
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("login", values: ["wafer"])) == .wafer)
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("login", values: ["wafer-ai"])) == .wafer)
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("login", values: ["wafer_ai"])) == .wafer)

        // zai / z-ai / z_ai
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("login", values: ["zai"])) == .zai)
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("login", values: ["z-ai"])) == .zai)
        #expect(try LiveAuthComposition.target(for: makeAuthOptions("login", values: ["z_ai"])) == .zai)
    }

    @Test("Conflicting --all and --codex options throw error")
    func testConflictingOptions() {
        #expect(throws: CLIApplicationError.self) {
            _ = try LiveAuthComposition.target(for: makeAuthOptions("logout", flags: ["--all", "--codex"]))
        }
        #expect(throws: CLIApplicationError.self) {
            _ = try LiveAuthComposition.target(for: makeAuthOptions("logout", values: ["all", "codex"]))
        }
    }

    // MARK: - Login Tests

    @Test("login --all throws unsupported error")
    func testLoginAllThrows() async throws {
        let fixture = try MultiAuthCommandFixture()
        defer { fixture.dispose() }
        let (streams, _, _) = CLIStreams.buffered()

        await #expect(throws: CLIApplicationError.self) {
            try await LiveAuthComposition.run(
                options: makeAuthOptions("login", flags: ["--all"]),
                environment: fixture.environment,
                streams: streams,
                services: makeNonInteractiveServices()
            )
        }
    }

    @Test("login with positional provider key saves to auth.json for all scoped providers")
    func testLoginScopedProvidersPositional() async throws {
        let fixture = try MultiAuthCommandFixture()
        defer { fixture.dispose() }

        let providers: [(target: String, token: String, key: String, display: String)] = [
            ("kimi", "kimi", "kimi-test-key-123", "Kimi"),
            ("fireworks", "fireworks", "fw-test-key-456", "Fireworks AI"),
            ("deepseek", "deepseek", "ds-test-key-789", "DeepSeek"),
            ("meta", "meta", "meta-test-key-321", "Meta API"),
            ("opencode-go", "opencode_go", "ocg-test-key-654", "OpenCode Go"),
            ("wafer", "wafer", "waf-test-key-987", "Wafer AI"),
            ("zai", "zai", "zai-test-key-111", "Z AI"),
        ]

        for item in providers {
            let (streams, out, _) = CLIStreams.buffered()
            try await LiveAuthComposition.run(
                options: makeAuthOptions("login", values: [item.target, item.key]),
                environment: fixture.environment,
                streams: streams,
                services: makeNonInteractiveServices()
            )

            #expect(out.contents.contains("Signed in to \(item.display) with an API key."))
            #expect(readProviderAPIKey(grokHome: fixture.home, provider: item.token) == item.key)
        }
    }

    @Test("login with interactive prompt saves key")
    func testLoginInteractivePrompt() async throws {
        let fixture = try MultiAuthCommandFixture()
        defer { fixture.dispose() }
        let (streams, out, _) = CLIStreams.buffered()

        try await LiveAuthComposition.run(
            options: makeAuthOptions("login", values: ["deepseek"]),
            environment: fixture.environment,
            streams: streams,
            services: makeInteractiveServices(secret: "interactive-deepseek-key")
        )

        #expect(out.contents.contains("Paste your DeepSeek API key"))
        #expect(out.contents.contains("Signed in to DeepSeek with an API key."))
        #expect(readProviderAPIKey(grokHome: fixture.home, provider: "deepseek") == "interactive-deepseek-key")
    }

    @Test("login non-interactive without key fails")
    func testLoginNonInteractiveWithoutKeyFails() async throws {
        let fixture = try MultiAuthCommandFixture()
        defer { fixture.dispose() }
        let (streams, _, _) = CLIStreams.buffered()

        await #expect(throws: CLIApplicationError.self) {
            try await LiveAuthComposition.run(
                options: makeAuthOptions("login", values: ["fireworks"]),
                environment: fixture.environment,
                streams: streams,
                services: makeNonInteractiveServices()
            )
        }
    }

    // MARK: - Logout Tests

    @Test("logout removes scoped provider key from auth.json")
    func testLogoutScopedProviders() async throws {
        let fixture = try MultiAuthCommandFixture()
        defer { fixture.dispose() }

        let providers: [(target: String, token: String, display: String)] = [
            ("kimi", "kimi", "Kimi"),
            ("fireworks", "fireworks", "Fireworks AI"),
            ("deepseek", "deepseek", "DeepSeek"),
            ("meta", "meta", "Meta API"),
            ("opencode-go", "opencode_go", "OpenCode Go"),
            ("wafer", "wafer", "Wafer AI"),
            ("zai", "zai", "Z AI"),
        ]

        // Store keys first
        for item in providers {
            try storeProviderAPIKey(grokHome: fixture.home, provider: item.token, apiKey: "sample-key-\(item.token)")
            #expect(readProviderAPIKey(grokHome: fixture.home, provider: item.token) == "sample-key-\(item.token)")
        }

        // Logout each provider
        for item in providers {
            let (streams, out, _) = CLIStreams.buffered()
            try await LiveAuthComposition.run(
                options: makeAuthOptions("logout", values: [item.target]),
                environment: fixture.environment,
                streams: streams,
                services: makeNonInteractiveServices()
            )

            #expect(out.contents.contains("Signed out of \(item.display); key removed from auth.json."))
            #expect(readProviderAPIKey(grokHome: fixture.home, provider: item.token) == nil)
        }
    }

    // MARK: - Status Lines Tests

    @Test("statusLines reports not authenticated when empty")
    func testStatusLinesUnauthenticated() throws {
        let fixture = try MultiAuthCommandFixture()
        defer { fixture.dispose() }

        let lines = LiveAuthComposition.statusLines(environment: fixture.environment)
        #expect(lines.count == 12)

        #expect(lines.contains { $0.contains("xAI: not authenticated (run `open-grok login`)") })
        #expect(lines.contains { $0.contains("Codex: not authenticated (run `open-grok login --codex`)") })
        #expect(lines.contains { $0.contains("Kimi: not authenticated (run `open-grok login kimi`)") })
        #expect(lines.contains { $0.contains("Fireworks AI: not authenticated (run `open-grok login fireworks`)") })
        #expect(lines.contains { $0.contains("DeepSeek: not authenticated (run `open-grok login deepseek`)") })
        #expect(lines.contains { $0.contains("Meta API: not authenticated (run `open-grok login meta`)") })
        #expect(lines.contains { $0.contains("OpenCode Go: not authenticated (run `open-grok login opencode-go`)") })
        #expect(lines.contains { $0.contains("Wafer AI: not authenticated (run `open-grok login wafer`)") })
        #expect(lines.contains { $0.contains("Z AI: not authenticated (run `open-grok login zai`)") })
        #expect(lines.contains { $0.contains("RunInfra: not authenticated (run `open-grok login runinfra`)") })
        #expect(lines.contains { $0.contains("Google Gemini: not authenticated (run `open-grok login gemini`)") })
        #expect(lines.contains { $0.contains("OpenRouter: not authenticated (run `open-grok login openrouter`)") })
    }

    @Test("statusLines reports authenticated when keys are present in env or store")
    func testStatusLinesAuthenticated() throws {
        let fixture = try MultiAuthCommandFixture(extraEnvironment: [
            "FIREWORKS_API_KEY": "env-fw-key",
            "DEEPSEEK_API_KEY": "env-ds-key",
            "MOONSHOT_API_KEY": "env-moonshot-key",
        ])
        defer { fixture.dispose() }

        try storeProviderAPIKey(grokHome: fixture.home, provider: "meta", apiKey: "store-meta-key")
        try storeProviderAPIKey(grokHome: fixture.home, provider: "opencode_go", apiKey: "store-ocg-key")
        try storeProviderAPIKey(grokHome: fixture.home, provider: "wafer", apiKey: "store-waf-key")
        try storeProviderAPIKey(grokHome: fixture.home, provider: "zai", apiKey: "store-zai-key")

        let lines = LiveAuthComposition.statusLines(environment: fixture.environment)
        #expect(lines.count == 12)

        #expect(lines.contains { $0.contains("Kimi: authenticated (environment)") })
        #expect(lines.contains { $0.contains("Fireworks AI: authenticated (environment)") })
        #expect(lines.contains { $0.contains("DeepSeek: authenticated (environment)") })
        #expect(lines.contains { $0.contains("Meta API: authenticated (api_key)") })
        #expect(lines.contains { $0.contains("OpenCode Go: authenticated (api_key)") })
        #expect(lines.contains { $0.contains("Wafer AI: authenticated (api_key)") })
        #expect(lines.contains { $0.contains("Z AI: authenticated (api_key)") })
        #expect(lines.contains { $0.contains("RunInfra: not authenticated") })
        #expect(lines.contains { $0.contains("Google Gemini: not authenticated") })
        #expect(lines.contains { $0.contains("OpenRouter: not authenticated") })
    }
}
