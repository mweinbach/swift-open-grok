import Foundation
import OpenGrokAuth
import OpenGrokModels
import OpenGrokProviderSession
import OpenGrokSamplingTypes
import Testing

@Suite("Live streamed tool-call preference precedence")
struct StreamToolCallsPreferenceParityTests {
    private func home(configuration: String? = nil) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stream-tool-preference-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let configuration {
            try configuration.write(
                to: directory.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
        }
        return directory
    }

    private func routePreference(
        home: URL,
        provider: ModelProvider = .xai,
        backend: ApiBackend = .responses,
        override: Bool? = nil,
        additionalEnvironment: [String: String] = [:]
    ) async throws -> Bool {
        let model = "preference-model"
        let entry = ModelEntry(info: ModelInfo(
            model: model,
            baseURL: "https://provider.example.test/v1",
            apiBackend: backend,
            provider: provider,
            streamToolCalls: override
        ))
        let kind: BuiltInSessionAuthKind = provider == .codex ? .codexOAuth : .xaiSession
        let binding = ProviderCredentialBinding(
            scope: "preference-test",
            kind: kind,
            source: StaticAuthCredentialProvider(bearer: "test-token")
        )
        var environment = ["HOME": home.path, "OPENGROK_HOME": home.path]
        environment.merge(additionalEnvironment, uniquingKeysWith: { _, updated in updated })
        let session = try ProviderSession(configuration: ProviderSessionConfiguration(
            sessionID: "stream-preference-\(UUID().uuidString)",
            modelCatalog: [model: entry],
            initialModelID: model,
            credentialBindings: [provider: binding],
            openGrokHome: home,
            environment: environment
        ))
        return await session.currentRoute().samplingConfig.streamToolCalls
    }

    @Test("The default is enabled and an empty injected environment never reads developer state")
    func defaultEnabled() async throws {
        #expect(resolveStreamToolCallsPreference(environment: [:]))
        #expect(try await routePreference(home: home()))
    }

    @Test("UI preference outranks legacy models preference")
    func uiBeatsModels() async throws {
        let directory = try home(configuration: """
        [models]
        stream_tool_calls = true

        [ui]
        stream_tool_calls = false
        """)
        #expect(try await !routePreference(home: directory))
    }

    @Test("Models preference remains a fallback without freezing a model override")
    func modelsFallback() async throws {
        let directory = try home(configuration: """
        [models]
        stream_tool_calls = false
        """)
        #expect(try await !routePreference(home: directory))
    }

    @Test("Environment overrides UI and malformed environment values fall through")
    func environmentPrecedence() async throws {
        let directory = try home(configuration: """
        [ui]
        stream_tool_calls = false
        """)
        #expect(try await routePreference(
            home: directory,
            additionalEnvironment: ["GROK_STREAM_TOOL_CALLS": "yes"]
        ))
        #expect(try await !routePreference(
            home: directory,
            additionalEnvironment: ["GROK_STREAM_TOOL_CALLS": "invalid"]
        ))
    }

    @Test("Explicit per-model overrides beat the live preference")
    func modelOverrideWins() async throws {
        let disabled = try home(configuration: "[ui]\nstream_tool_calls = false\n")
        let enabled = try home(configuration: "[ui]\nstream_tool_calls = true\n")

        #expect(try await routePreference(home: disabled, override: true))
        #expect(try await !routePreference(home: enabled, override: false))
    }

    @Test("Foreign providers and non-Responses xAI routes remain disabled")
    func providerAndBackendIsolation() async throws {
        let directory = try home()
        #expect(try await !routePreference(home: directory, provider: .codex, override: true))
        #expect(try await !routePreference(home: directory, backend: .chatCompletions, override: true))
        #expect(try await !routePreference(home: directory, backend: .messages, override: true))
    }
}
