import Foundation
import OpenGrokModels
import OpenGrokSampler
import OpenGrokSamplingTypes
import Testing
@testable import OpenGrokCLI

@Suite("Current Rust gap executable composition")
struct GapClosureLiveCompositionTests {
    @Test("first-class provider selectors reach launch options")
    func providerSelectorsReachLaunchOptions() throws {
        for (selector, expected) in [
            ("--runinfra", "runinfra"),
            ("--gemini", "gemini"),
            ("--google", "gemini"),
            ("--openrouter", "openrouter"),
        ] {
            let command = try CLICommandParser.parseOrThrow([selector, "-p", "hello"])
            guard case let .launch(options) = command else {
                Issue.record("\(selector) did not resolve to a live launch")
                continue
            }
            #expect(options.common.provider == expected)
            #expect(options.mode == .headless)
        }
    }

    @Test("provider endpoints and environment credentials stay isolated")
    func expandedProviderEndpointAndCredentialIsolation() throws {
        let runInfraEnvironment = [
            RunInfraModels.apiBaseURLEnv: "https://runinfra.example.test/v1",
            RunInfraModels.gatewayKeyEnv: "gateway-key",
            RunInfraModels.apiKeyEnv: "fallback-key",
        ]
        #expect(OpenGrokLiveApplicationLauncher.resolveProviderBaseURL(
            provider: .runinfra,
            model: nil,
            environment: runInfraEnvironment
        ) == "https://runinfra.example.test/v1")
        #expect(try OpenGrokLiveApplicationLauncher.resolveProviderAPIKey(
            provider: .runinfra,
            model: nil,
            baseURL: RunInfraModels.apiBaseURLDefault,
            environment: runInfraEnvironment
        ) == "gateway-key")

        let geminiEnvironment = [
            GeminiModels.apiBaseURLEnv: "https://gemini.example.test/v1",
            GeminiModels.apiKeyEnv: "gemini-key",
            GeminiModels.googleAPIKeyEnv: "google-key",
        ]
        #expect(OpenGrokLiveApplicationLauncher.resolveProviderBaseURL(
            provider: .gemini,
            model: nil,
            environment: geminiEnvironment
        ) == "https://gemini.example.test/v1")
        #expect(try OpenGrokLiveApplicationLauncher.resolveProviderAPIKey(
            provider: .gemini,
            model: nil,
            baseURL: GeminiModels.apiBaseURLDefault,
            environment: geminiEnvironment
        ) == "gemini-key")

        #expect(OpenGrokLiveApplicationLauncher.resolveProviderBaseURL(
            provider: .openRouter,
            model: nil,
            environment: [:]
        ) == OpenRouterModels.apiBaseURLDefault)
        #expect(try OpenGrokLiveApplicationLauncher.resolveProviderAPIKey(
            provider: .openRouter,
            model: nil,
            baseURL: OpenRouterModels.apiBaseURLDefault,
            environment: [OpenRouterModels.apiKeyEnv: "router-key"]
        ) == "router-key")
    }

    @Test("RunInfra and Gemini cold launches select reviewed provider defaults")
    func reviewedProvidersReachActualLaunchFoundation() async throws {
        for (flag, provider, credentialName, expectedModel) in [
            ("--runinfra", ModelProvider.runinfra, RunInfraModels.gatewayKeyEnv, "deepseek-v4-flash"),
            ("--gemini", ModelProvider.gemini, GeminiModels.apiKeyEnv, "gemini-3.7-flash"),
        ] {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent(
                "og-gap-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }
            let environment = [
                "HOME": home.path,
                "OPENGROK_HOME": home.path,
                credentialName: "provider-test-key",
            ]
            let command = try CLICommandParser.parseOrThrow([
                flag, "--cwd", home.path, "-p", "hello",
            ])
            guard case let .launch(options) = command else {
                Issue.record("\(flag) did not produce a launch")
                continue
            }
            let (streams, _, _) = CLIStreams.buffered()
            let context = CLIApplicationContext(
                environment: environment,
                streams: streams,
                control: .never
            )
            let dependencies = OpenGrokLiveCompositionDependencies(
                makeSampler: { _ in
                    OpenGrokLiveSampler { _, _ in
                        OpenGrokLiveSamplingResponse(output: "ok")
                    }
                }
            )

            let foundation = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
                options: options,
                context: context,
                dependencies: dependencies
            )
            #expect(foundation.samplingConfiguration.provider == provider)
            #expect(foundation.samplingConfiguration.model == expectedModel)
            #expect(foundation.samplingConfiguration.apiKey == "provider-test-key")
            #expect(foundation.toolExecutor.tools.contains { $0.name == "list_sessions" })
            #expect(foundation.toolExecutor.tools.contains { $0.name == "read_session" })
            #expect(foundation.toolExecutor.tools.contains { $0.name == "message_session" })
            await foundation.toolExecutor.shutdown()
        }
    }

    @Test("OpenRouter cannot cold-launch a model outside its explicit opt-in")
    func openRouterRequiresExactConfiguredOptIn() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "og-router-gap-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            OpenRouterModels.apiKeyEnv: "router-test-key",
        ]
        let (streams, _, _) = CLIStreams.buffered()
        let context = CLIApplicationContext(
            environment: environment,
            streams: streams,
            control: .never
        )
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { _, _ in OpenGrokLiveSamplingResponse(output: "ok") }
            }
        )
        let command = try CLICommandParser.parseOrThrow([
            "--openrouter", "--cwd", home.path,
            "--model", "openai/gpt-4o", "-p", "hello",
        ])
        guard case let .launch(options) = command else {
            Issue.record("OpenRouter command did not produce a launch")
            return
        }

        do {
            _ = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
                options: options,
                context: context,
                dependencies: dependencies
            )
            Issue.record("a non-opted-in OpenRouter model was accepted")
        } catch {
            #expect(String(describing: error).contains("not enabled"))
        }

        try Data("""
        [models]
        openrouter_enabled_models = ["openai/gpt-4o"]

        """.utf8).write(to: home.appendingPathComponent("config.toml"))
        let foundation = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: options,
            context: context,
            dependencies: dependencies
        )
        #expect(foundation.samplingConfiguration.provider == .openRouter)
        #expect(foundation.samplingConfiguration.model == "openai/gpt-4o")
        #expect(foundation.samplingConfiguration.apiKey == "router-test-key")
        await foundation.toolExecutor.shutdown()
    }

    @Test("native Messages response metadata reaches the live event seam")
    func messagesLifecycleEventsRemainOrderedAndComplete() {
        let started = LiveSamplingStreamMapper.map(.responseStarted(
            requestId: .random(),
            messageID: "msg_live_1",
            model: "claude-sonnet",
            inputTokens: 11,
            cacheReadInputTokens: 7,
            cacheCreationInputTokens: 3
        ))
        #expect(started == .emit(.responseStarted(
            messageID: "msg_live_1",
            model: "claude-sonnet",
            inputTokens: 11,
            cacheReadInputTokens: 7,
            cacheCreationInputTokens: 3
        )))

        let signature = LiveSamplingStreamMapper.map(.reasoningCompleted(
            requestId: .random(),
            signature: "signed-thinking"
        ))
        #expect(signature == .emit(.reasoningCompleted(signature: "signed-thinking")))

        let response = OpenGrokLiveSamplingResponse(
            output: "done",
            stopReason: "stop",
            messageID: "msg_live_1",
            rawStopReason: "stop_sequence",
            stopSequence: "END"
        )
        #expect(response.messageID == "msg_live_1")
        #expect(response.rawStopReason == "stop_sequence")
        #expect(response.stopSequence == "END")
    }

    @Test("OpenRouter attribution is added without weakening credential authority")
    func openRouterAttributionRemainsProviderScoped() {
        let headers = OpenGrokLiveApplicationLauncher.mergeCredentialHeaders(
            provider: .openRouter,
            credentialHeaders: ["Authorization": "Bearer trusted"],
            configuredHeaders: [("Authorization", "Bearer attacker")]
        )

        #expect(headers["Authorization"] == "Bearer trusted")
        #expect(headers["HTTP-Referer"] == "https://github.com/mweinbach/open-grok")
        #expect(headers["X-Title"] == "Open Grok")
        #expect(OpenGrokLiveApplicationLauncher.mergeCredentialHeaders(
            provider: .gemini,
            credentialHeaders: [:],
            configuredHeaders: []
        )["HTTP-Referer"] == nil)
    }
}
