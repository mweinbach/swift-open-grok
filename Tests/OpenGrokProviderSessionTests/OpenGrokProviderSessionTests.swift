import Foundation
import Testing
import OpenGrokAuth
import OpenGrokCompaction
import OpenGrokModels
import OpenGrokProviderSession
import OpenGrokSampler
import OpenGrokSamplingTypes

private func modelEntry(
    model: String,
    provider: ModelProvider,
    backend: ApiBackend,
    toolMode: ToolMode? = nil,
    apiKey: String? = nil,
    apiBaseURL: String? = nil,
    autoCompactThresholdPercent: UInt8? = nil,
    compactionAtTokens: CompactionAtTokens? = nil
) -> ModelEntry {
    ModelEntry(
        info: ModelInfo(
            model: model,
            baseURL: "https://\(provider.asString).example/v1",
            apiBackend: backend,
            provider: provider,
            toolMode: toolMode,
            contextWindow: 128_000,
            autoCompactThresholdPercent: autoCompactThresholdPercent,
            supportsBackendSearch: provider == .xai || provider == .codex,
            compactionAtTokens: compactionAtTokens
        ),
        apiKey: apiKey,
        apiBaseURL: apiBaseURL
    )
}

private func xaiBinding() -> ProviderCredentialBinding {
    ProviderCredentialBinding(
        scope: "xai::session",
        kind: .xaiSession,
        source: StaticAuthCredentialProvider(bearer: "xai-token")
    )
}

private func codexBinding() -> ProviderCredentialBinding {
    ProviderCredentialBinding(
        scope: "codex::account",
        kind: .codexOAuth,
        source: StaticAuthCredentialProvider(bearer: "codex-token")
    )
}

private struct FixedUsageSource: ProviderUsageSource {
    let window: ProviderQuotaWindow
    let fails: Bool

    func fetchUsage() async throws -> ProviderQuotaWindow {
        if fails { throw ProviderSessionError.cancelled }
        return window
    }
}

@Suite("Provider session routing")
struct ProviderSessionRoutingTests {
    @Test("provider profile and auth headers stay isolated")
    func providerProfileAndAuthIsolation() async throws {
        let catalog = [
            "xai-model": modelEntry(model: "xai-model", provider: .xai, backend: .responses),
            "codex-model": modelEntry(
                model: "codex-model",
                provider: .codex,
                backend: .responses,
                toolMode: .codeModeOnly
            ),
        ]
        let session = try ProviderSession(configuration: ProviderSessionConfiguration(
            sessionID: "routing",
            modelCatalog: catalog,
            initialModelID: "codex-model",
            credentialBindings: [.codex: codexBinding()],
            openGrokHome: URL(fileURLWithPath: "/tmp/provider-session-tests", isDirectory: true)
        ))

        let route = await session.currentRoute()
        #expect(route.provider == .codex)
        #expect(route.profile.requestMetadata == .standardHeadersOnly)
        #expect(route.authScope == "codex::account")
        #expect(route.toolSurface.codeModeTransport == .nativeCustomGrammar)
        #expect(route.samplingConfig.bearerResolver?.currentAuth()?.extraHeaders.isEmpty == true)

        let xaiSession = try ProviderSession(configuration: ProviderSessionConfiguration(
            sessionID: "routing-xai",
            modelCatalog: catalog,
            initialModelID: "xai-model",
            credentialBindings: [.xai: xaiBinding()],
            openGrokHome: URL(fileURLWithPath: "/tmp/provider-session-tests", isDirectory: true)
        ))
        let xaiRoute = await xaiSession.currentRoute()
        #expect(xaiRoute.profile.requestMetadata == .xGrokHeaders)
        #expect(xaiRoute.samplingConfig.bearerResolver?.currentAuth()?.extraHeaders.first?.name == xaiTokenAuthHeader)
    }

    @Test("unsupported routes fall back without crossing provider credentials")
    func unsupportedRouteFallsBack() async throws {
        let catalog = [
            "codex-wrong": modelEntry(model: "codex-wrong", provider: .codex, backend: .chatCompletions),
            "xai-model": modelEntry(model: "xai-model", provider: .xai, backend: .responses),
        ]
        let session = try ProviderSession(configuration: ProviderSessionConfiguration(
            sessionID: "fallback",
            modelCatalog: catalog,
            initialModelID: "codex-wrong",
            credentialBindings: [.xai: xaiBinding()],
            fallbackModelIDs: ["xai-model"],
            openGrokHome: URL(fileURLWithPath: "/tmp/provider-session-tests", isDirectory: true)
        ))

        let snapshot = await session.snapshot()
        #expect(snapshot.route.modelID == "xai-model")
        #expect(snapshot.route.provider == .xai)

        do {
            _ = try await ProviderSession(configuration: ProviderSessionConfiguration(
                sessionID: "no-route",
                modelCatalog: ["codex-wrong": catalog["codex-wrong"]!],
                initialModelID: "codex-wrong",
                credentialBindings: [.xai: xaiBinding()],
                openGrokHome: URL(fileURLWithPath: "/tmp/provider-session-tests", isDirectory: true)
            ))
            Issue.record("expected no route")
        } catch let error as ProviderSessionError {
            if case .noRoute(let candidates, let reasons) = error {
                #expect(candidates == ["codex-wrong"])
                #expect(reasons.contains { $0.contains("unsupported") })
            } else {
                Issue.record("unexpected provider session error: \(error)")
            }
        }
    }

    @Test("auxiliary and compaction routes use their own provider contract")
    func auxiliaryAndCompactionRouting() async throws {
        let catalog = [
            "xai": modelEntry(model: "xai", provider: .xai, backend: .responses),
            "kimi-compaction": modelEntry(
                model: "kimi-compaction",
                provider: .kimi,
                backend: .chatCompletions,
                apiKey: "kimi-key",
                compactionAtTokens: .fixed(40_000)
            ),
        ]
        let session = try ProviderSession(configuration: ProviderSessionConfiguration(
            sessionID: "auxiliary",
            modelCatalog: catalog,
            initialModelID: "xai",
            credentialBindings: [.xai: xaiBinding()],
            auxiliaryModelIDs: [.compaction: "kimi-compaction"],
            openGrokHome: URL(fileURLWithPath: "/tmp/provider-session-tests", isDirectory: true)
        ))

        let auxiliary = try await session.auxiliaryRoute(for: .compaction)
        #expect(auxiliary.provider == .kimi)
        #expect(auxiliary.authKind == .apiKeyOnly)
        #expect(auxiliary.compactionBudget.triggerTokenLimit == 40_000)
        #expect(auxiliary.samplingConfig.provider == .kimi)
    }
}

@Suite("Provider session tool policy")
struct ProviderSessionToolPolicyTests {
    @Test("unsupported hosted tools are hidden rather than leaked")
    func incompatibleToolsAreHidden() async throws {
        let entry = modelEntry(
            model: "kimi-model",
            provider: .kimi,
            backend: .chatCompletions,
            apiKey: "kimi-key",
            apiBaseURL: "https://api.kimi.example/v1"
        )
        let session = try ProviderSession(configuration: ProviderSessionConfiguration(
            sessionID: "kimi-tools",
            modelCatalog: ["kimi": entry],
            initialModelID: "kimi",
            toolRequest: ProviderToolRequest(capabilities: [.hostedWebSearch, .imageInput]),
            openGrokHome: URL(fileURLWithPath: "/tmp/provider-session-tests", isDirectory: true)
        ))

        let surface = await session.snapshot().route.toolSurface
        #expect(surface.mode == .direct)
        #expect(surface.enabledCapabilities.contains(.hostedWebSearch) == false)
        #expect(surface.enabledCapabilities.contains(.imageInput) == false)
        #expect(surface.hiddenCapabilities.contains(.hostedWebSearch))
        #expect(surface.hiddenCapabilities.contains(.imageInput))
    }

    @Test("Code Mode transport follows the selected provider")
    func codeModeTransportIsProviderSpecific() async throws {
        let catalog = [
            "xai-code": modelEntry(model: "xai-code", provider: .xai, backend: .responses, toolMode: .codeMode),
            "codex-code": modelEntry(model: "codex-code", provider: .codex, backend: .responses, toolMode: .codeModeOnly),
        ]
        let session = try ProviderSession(configuration: ProviderSessionConfiguration(
            sessionID: "code-mode",
            modelCatalog: catalog,
            initialModelID: "xai-code",
            credentialBindings: [.xai: xaiBinding()],
            openGrokHome: URL(fileURLWithPath: "/tmp/provider-session-tests", isDirectory: true)
        ))
        #expect((await session.currentRoute()).toolSurface.codeModeTransport == .functionEnvelope)

        do {
            _ = try await session.switchModel(to: "codex-code")
            Issue.record("expected missing Codex credential")
        } catch let error as ProviderSessionError {
            #expect(error.description.contains("no provider route") || error.description.contains("missing credential"))
        }
    }
}

@Suite("Provider session lifecycle")
struct ProviderSessionLifecycleTests {
    @Test("OPENGROK_HOME is the isolated session root")
    func openGrokHomeIsolation() throws {
        let home = ProviderSession.defaultOpenGrokHome(environment: ["OPENGROK_HOME": "/tmp/open-grok-home"])
        #expect(home.path == "/tmp/open-grok-home")
        #expect(!home.path.hasSuffix("/.grok"))

        do {
            _ = try ProviderSession(configuration: ProviderSessionConfiguration(
                sessionID: "../escape",
                modelCatalog: ["xai": modelEntry(model: "xai", provider: .xai, backend: .responses)],
                initialModelID: "xai",
                credentialBindings: [.xai: xaiBinding()],
                openGrokHome: home
            ))
            Issue.record("expected path traversal session id to be rejected")
        } catch let error as ProviderSessionError {
            #expect(error == .invalidSessionID("../escape"))
        }
    }

    @Test("turn ownership and cancellation are isolated per session")
    func perSessionCancellation() async throws {
        let catalog = [
            "xai": modelEntry(model: "xai", provider: .xai, backend: .responses),
        ]
        let home = URL(fileURLWithPath: "/tmp/provider-session-tests", isDirectory: true)
        let first = try ProviderSession(configuration: ProviderSessionConfiguration(
            sessionID: "first",
            modelCatalog: catalog,
            initialModelID: "xai",
            credentialBindings: [.xai: xaiBinding()],
            openGrokHome: home
        ))
        let second = try ProviderSession(configuration: ProviderSessionConfiguration(
            sessionID: "second",
            modelCatalog: catalog,
            initialModelID: "xai",
            credentialBindings: [.xai: xaiBinding()],
            openGrokHome: home
        ))

        let firstTurn = try await first.beginTurn(turnID: "first-turn")
        _ = try await second.beginTurn(turnID: "second-turn")
        #expect(firstTurn.cancellation.isCancelled == false)

        do {
            _ = try await first.beginTurn(turnID: "second-first-turn")
            Issue.record("expected active-turn rejection")
        } catch let error as ProviderSessionError {
            #expect(error == .turnAlreadyActive("first-turn"))
        }

        #expect(await first.cancelActiveTurn())
        #expect(firstTurn.cancellation.isCancelled)
        #expect((await first.snapshot()).state == .cancelled(turnID: "first-turn", modelID: "xai"))
        #expect((await second.snapshot()).state == .sampling(turnID: "second-turn", modelID: "xai", attempt: 0))

        let retry = try await second.beginRetry(turnID: "second-turn")
        #expect(retry.attempt == 1)
        #expect((await second.snapshot()).state == .sampling(turnID: "second-turn", modelID: "xai", attempt: 1))
        try await second.finishTurn(turnID: "second-turn")
        #expect((await second.snapshot()).completedTurns == 1)
    }

    @Test("model switches preserve session identity and reject active turns")
    func deterministicModelSwitch() async throws {
        let catalog = [
            "xai": modelEntry(model: "xai", provider: .xai, backend: .responses),
            "kimi": modelEntry(model: "kimi", provider: .kimi, backend: .chatCompletions, apiKey: "kimi-key"),
        ]
        let session = try ProviderSession(configuration: ProviderSessionConfiguration(
            sessionID: "switching",
            modelCatalog: catalog,
            initialModelID: "xai",
            credentialBindings: [.xai: xaiBinding()],
            openGrokHome: URL(fileURLWithPath: "/tmp/provider-session-tests", isDirectory: true)
        ))
        _ = try await session.beginTurn(turnID: "active")
        do {
            _ = try await session.switchModel(to: "kimi")
            Issue.record("expected active-turn model-switch rejection")
        } catch let error as ProviderSessionError {
            #expect(error == .turnAlreadyActive("active"))
        }
        #expect(await session.cancelActiveTurn())
        _ = try await session.switchModel(to: "kimi")
        let snapshot = await session.snapshot()
        #expect(snapshot.sessionID == "switching")
        #expect(snapshot.route.provider == .kimi)
        #expect(snapshot.historyRevision == 1)
        #expect(snapshot.everUsedNonXAI)
        #expect(snapshot.route.canExportToXAI == false)
    }

    @Test("a rehydrated non-xAI marker keeps xAI export closed")
    func rehydratedBoundaryRemainsClosed() async throws {
        let session = try ProviderSession(configuration: ProviderSessionConfiguration(
            sessionID: "rehydrated-boundary",
            modelCatalog: ["xai": modelEntry(model: "xai", provider: .xai, backend: .responses)],
            initialModelID: "xai",
            credentialBindings: [.xai: xaiBinding()],
            openGrokHome: URL(fileURLWithPath: "/tmp/provider-session-tests", isDirectory: true),
            everUsedNonXAI: true
        ))
        let snapshot = await session.snapshot()
        #expect(snapshot.everUsedNonXAI)
        #expect(snapshot.route.canExportToXAI == false)
    }

    @Test("usage remains attributed to the provider and model used by the turn")
    func usageAttribution() async throws {
        let session = try ProviderSession(configuration: ProviderSessionConfiguration(
            sessionID: "usage",
            modelCatalog: ["xai": modelEntry(model: "xai", provider: .xai, backend: .responses)],
            initialModelID: "xai",
            credentialBindings: [.xai: xaiBinding()],
            openGrokHome: URL(fileURLWithPath: "/tmp/provider-session-tests", isDirectory: true)
        ))
        _ = try await session.beginTurn(turnID: "usage-turn")
        try await session.recordUsage(
            turnID: "usage-turn",
            usage: TokenUsage(promptTokens: 12, completionTokens: 5, totalTokens: 17, reasoningTokens: 2, cachedPromptTokens: 3),
            apiDurationMS: 25,
            costUSDTicks: 100
        )
        try await session.finishTurn(turnID: "usage-turn")

        let records = await session.usageSnapshot()
        #expect(records.count == 1)
        #expect(records[0].provider == .xai)
        #expect(records[0].totals.inputTokens == 12)
        #expect(records[0].totals.cachedReadTokens == 3)
        #expect(records[0].totals.reasoningTokens == 2)
        #expect(records[0].totals.modelCalls == 1)
    }
}

@Suite("Provider session retry policy")
struct ProviderSessionRetryTests {
    @Test("authentication remains session-owned while transient failures retry")
    func retryOwnership() async throws {
        let session = try ProviderSession(configuration: ProviderSessionConfiguration(
            sessionID: "retry",
            modelCatalog: ["xai": modelEntry(model: "xai", provider: .xai, backend: .responses)],
            initialModelID: "xai",
            credentialBindings: [.xai: xaiBinding()],
            openGrokHome: URL(fileURLWithPath: "/tmp/provider-session-tests", isDirectory: true)
        ))
        let auth = await session.requestDisposition(for: .auth("expired"), retryCount: 0)
        if case .recoverAuthentication = auth {
        } else {
            Issue.record("authentication should be recovered by the session")
        }

        let server = SamplingError.api(
            status: HTTPStatus(503),
            message: "temporary",
            modelMetadata: nil,
            retryAfterSecs: nil,
            shouldRetry: nil
        )
        let transient = await session.requestDisposition(for: server, retryCount: 0)
        if case .retry(let decision) = transient {
            if case .retryWithClientRebuild = decision {
            } else {
                Issue.record("first transient retry should rebuild the client")
            }
        } else {
            Issue.record("server failure should be retryable")
        }
    }

    @Test("combined provider usage preserves successful windows when one fails")
    func independentUsageWindows() async {
        let result = await fetchCombinedProviderUsage(sources: [
            .xai: FixedUsageSource(window: ProviderQuotaWindow(provider: .xai, used: 12, durationSeconds: 86_400), fails: true),
            .codex: FixedUsageSource(window: ProviderQuotaWindow(provider: .codex, used: 7, durationSeconds: 3_600), fails: false),
        ])
        #expect(result.windows.count == 1)
        #expect(result.windows[0].provider == .codex)
        #expect(result.windows[0].durationSeconds == 3_600)
        #expect(result.failures == [ProviderUsageFailure(provider: .xai, message: "usage request failed")])
    }
}
