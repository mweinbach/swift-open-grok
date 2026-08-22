import Foundation
import OpenGrokAuth
import OpenGrokModels
import Testing
@testable import OpenGrokCLI

private struct LiveModelsCommandFixture {
    let home: URL
    let environment: [String: String]

    init(overrides: [String: String] = [:]) throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-models-command-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var values = overrides
        values["HOME"] = home.path
        values["OPENGROK_HOME"] = home.path
        values["PWD"] = home.path
        environment = values
    }

    func configure(_ document: String) throws {
        try Data(document.utf8).write(
            to: home.appendingPathComponent("config.toml"),
            options: .atomic
        )
    }

    func syncModels(environment overrides: [String: String]? = nil) throws -> LiveModelsCommandOutput {
        let (streams, output, errors) = CLIStreams.buffered()
        let code = CLIRunner.main(
            ["models", "--json"],
            environment: overrides ?? environment,
            streams: streams
        )
        #expect(code == CLIRunner.ExitCode.success.rawValue)
        #expect(errors.contents.isEmpty)
        return try JSONDecoder().decode(
            LiveModelsCommandOutput.self,
            from: Data(output.contents.utf8)
        )
    }

    func asyncModels(environment overrides: [String: String]? = nil) async throws -> LiveModelsCommandOutput {
        let (streams, output, errors) = CLIStreams.buffered()
        let code = await CLIRunner.run(
            ["models", "list", "--json"],
            environment: overrides ?? environment,
            streams: streams
        )
        #expect(code == CLIRunner.ExitCode.success.rawValue)
        #expect(errors.contents.isEmpty)
        return try JSONDecoder().decode(
            LiveModelsCommandOutput.self,
            from: Data(output.contents.utf8)
        )
    }

    func login(_ provider: String, key: String) async {
        let (streams, output, errors) = CLIStreams.buffered()
        let code = await CLIRunner.run(
            ["login", provider, key],
            environment: environment,
            streams: streams,
            application: .live()
        )
        #expect(code == CLIRunner.ExitCode.success.rawValue)
        #expect(!output.contents.contains(key))
        #expect(!errors.contents.contains(key))
    }
}

private struct LiveModelsCommandOutput: Decodable {
    let defaultModel: String
    let models: [String]

    enum CodingKeys: String, CodingKey {
        case defaultModel = "default"
        case models
    }
}

@Suite("Real models command authenticated provider parity", .serialized)
struct LiveModelsCommandProviderParityTests {
    @Test("unauthenticated models preserve the exact embedded order and default")
    func noCredentialsPreserveEmbeddedCatalog() throws {
        let fixture = try LiveModelsCommandFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let embedded = embeddedDefaultModels()
        let expected = embedded.models
            .filter { !$0.hidden && $0.supportedInApi }
            .map(\.model)

        let output = try fixture.syncModels()

        #expect(output.defaultModel == embedded.default)
        #expect(output.models == expected)
        #expect(!output.models.contains { $0.hasPrefix("gemini:") })
        #expect(!output.models.contains { $0.hasPrefix("runinfra:") })
        #expect(!output.models.contains { $0.hasPrefix("openrouter:") })
    }

    @Test("real provider login immediately publishes reviewed catalogs in both runners")
    func providerLoginsReachActualModelsEntryPoints() async throws {
        let fixture = try LiveModelsCommandFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let original = try fixture.syncModels()

        await fixture.login("gemini", key: "gemini-stored-secret")
        let afterGemini = try fixture.syncModels()
        for model in GeminiModels.curated {
            #expect(afterGemini.models.contains(GeminiModels.catalogKey(modelID: model.id)))
        }
        #expect(!afterGemini.models.contains { $0.hasPrefix("runinfra:") })
        #expect(afterGemini.defaultModel == original.defaultModel)

        await fixture.login("runinfra", key: "runinfra-stored-secret")
        let afterRunInfra = try await fixture.asyncModels()
        for model in RunInfraModels.fallbackModelIDs {
            #expect(afterRunInfra.models.contains(RunInfraModels.catalogKey(modelID: model)))
        }
        for model in GeminiModels.curated {
            #expect(afterRunInfra.models.contains(GeminiModels.catalogKey(modelID: model.id)))
        }
        #expect(Array(afterRunInfra.models.prefix(original.models.count)) == original.models)
        #expect(afterRunInfra.defaultModel == original.defaultModel)
    }

    @Test("provider environment aliases unlock only their own reviewed catalogs")
    func environmentAliasesRemainProviderIsolated() async throws {
        let fixture = try LiveModelsCommandFixture(overrides: [
            runInfraAPIKeyEnv: "runinfra-environment-secret",
            googleAPIKeyEnv: "google-environment-secret",
        ])
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        let output = try await fixture.asyncModels()

        #expect(output.models.contains("runinfra:deepseek-v4-flash"))
        #expect(output.models.contains("gemini:gemini-3.7-flash"))
        #expect(!output.models.contains { $0.hasPrefix("openrouter:") })
    }

    @Test("stored provider credentials cannot publish through attacker-controlled endpoints")
    func storedCredentialsCannotEscapeTrustedEndpoints() async throws {
        let fixture = try LiveModelsCommandFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        try storeRunInfraAPIKey(grokHome: fixture.home, apiKey: "stored-runinfra-secret")
        try storeGeminiAPIKey(grokHome: fixture.home, apiKey: "stored-gemini-secret")
        try storeOpenRouterAPIKey(grokHome: fixture.home, apiKey: "stored-router-secret")
        try fixture.configure("""
        [models]
        openrouter_enabled_models = ["openai/gpt-4o"]

        [model.openrouter_selected]
        model = "openai/gpt-4o"
        provider = "openrouter"
        """)
        var hostile = fixture.environment
        hostile[RunInfraModels.apiBaseURLEnv] = "https://attacker.example.test/runinfra"
        hostile[GeminiModels.apiBaseURLEnv] = "https://attacker.example.test/gemini"
        hostile[OpenRouterModels.apiBaseURLEnv] = "https://attacker.example.test/openrouter"

        let denied = try fixture.syncModels(environment: hostile)
        #expect(!denied.models.contains { $0.hasPrefix("runinfra:") })
        #expect(!denied.models.contains { $0.hasPrefix("gemini:") })
        #expect(!denied.models.contains("openrouter_selected"))

        hostile[RunInfraModels.gatewayKeyEnv] = "explicit-runinfra-proxy-key"
        hostile[GeminiModels.apiKeyEnv] = "explicit-gemini-proxy-key"
        hostile[OpenRouterModels.apiKeyEnv] = "explicit-openrouter-proxy-key"
        let explicitlyAuthorized = try await fixture.asyncModels(environment: hostile)
        #expect(explicitlyAuthorized.models.contains("runinfra:deepseek-v4-flash"))
        #expect(explicitlyAuthorized.models.contains("gemini:gemini-3.7-flash"))
        #expect(explicitlyAuthorized.models.contains("openrouter_selected"))
    }

    @Test("OpenRouter requires both a usable key and an explicitly enabled known model")
    func openRouterRequiresOptInAuthenticationAndRecognizedModel() throws {
        let fixture = try LiveModelsCommandFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        try fixture.configure("""
        [models]
        openrouter_enabled_models = ["openai/gpt-4o", "anthropic/not-discovered"]

        [model.openrouter_selected]
        model = "openai/gpt-4o"
        provider = "openrouter"
        """)

        #expect(!(try fixture.syncModels().models.contains("openrouter_selected")))
        try storeOpenRouterAPIKey(grokHome: fixture.home, apiKey: "openrouter-stored-secret")
        let enabled = try fixture.syncModels()
        #expect(enabled.models.contains("openrouter_selected"))
        #expect(!enabled.models.contains("anthropic/not-discovered"))
        #expect(!enabled.models.contains("openrouter:anthropic/not-discovered"))

        try fixture.configure("""
        [models]
        openrouter_enabled_models = []

        [model.openrouter_selected]
        model = "openai/gpt-4o"
        provider = "openrouter"
        """)
        #expect(!(try fixture.syncModels().models.contains("openrouter_selected")))
    }

    @Test("models default honors trusted config and environment without changing plain output")
    func configuredDefaultPrecedenceRemainsVisible() throws {
        let fixture = try LiveModelsCommandFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let embedded = embeddedDefaultModels()
        let choices = embedded.models.filter { !$0.hidden && $0.supportedInApi }.map(\.model)
        guard let configuredDefault = choices.first(where: { $0 != embedded.default }) else {
            Issue.record("the embedded fixture must provide an alternate visible model")
            return
        }
        try fixture.configure("""
        [models]
        default = "\(configuredDefault)"
        """)
        #expect(try fixture.syncModels().defaultModel == configuredDefault)

        var overridden = fixture.environment
        overridden[GROK_DEFAULT_MODEL_ENV] = embedded.default
        #expect(try fixture.syncModels(environment: overridden).defaultModel == embedded.default)

        let (streams, output, errors) = CLIStreams.buffered()
        let code = CLIRunner.main(
            ["models", "default"],
            environment: fixture.environment,
            streams: streams
        )
        #expect(code == CLIRunner.ExitCode.success.rawValue)
        #expect(output.contents == configuredDefault + "\n")
        #expect(errors.contents.isEmpty)
    }
}
