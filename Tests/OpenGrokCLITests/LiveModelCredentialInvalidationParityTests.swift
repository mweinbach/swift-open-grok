import Foundation
import OpenGrokAuth
import OpenGrokHTTP
import OpenGrokSampler
import OpenGrokSamplingTypes
import Testing

@testable import OpenGrokCLI

private let originalCredentialInvalidationSecret = "fireworks-revoked-private-secret"
private let replacementCredentialInvalidationSecret = "fireworks-replacement-private-secret"

private struct LiveModelCredentialInvalidationFixture {
    let home: URL
    let environment: [String: String]
    let transport: MockHTTPTransport
    let resolver: LiveModelCatalogResolver
    let coordinator: LiveModelSwitchCoordinator

    init() async throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-model-credential-invalidation-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XAI_API_KEY": "unrelated-xai-private-secret",
        ]
        try storeProviderAPIKey(
            grokHome: home,
            provider: ModelProvider.fireworks.asString,
            apiKey: originalCredentialInvalidationSecret
        )

        transport = MockHTTPTransport(responses: (0..<8).map { index in
            let event = #"{"id":"1","object":"chat.completion.chunk","created":0,"model":"m","choices":[{"index":0,"delta":{"role":"assistant","content":"response-\#(index)"},"finish_reason":"stop"}]}"#
            return MockHTTPTransport.ScriptedResponse(
                metadata: HTTPResponseMetadata(
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream"]
                ),
                body: Data("data: \(event)\n\ndata: [DONE]\n\n".utf8)
            )
        })
        let transport = self.transport
        let makeSampler: @Sendable (
            OpenGrokLiveSamplingConfiguration
        ) throws -> OpenGrokLiveSampler = { configuration in
            try OpenGrokLiveSampler.production(configuration: OpenGrokLiveSamplingConfiguration(
                model: configuration.model,
                baseURL: configuration.baseURL,
                apiKey: configuration.apiKey,
                provider: configuration.provider,
                apiBackend: configuration.apiBackend,
                extraHeaders: configuration.extraHeaders,
                queryParams: configuration.queryParams,
                environment: configuration.environment,
                tuning: configuration.tuning,
                doomLoopRecovery: configuration.doomLoopRecovery,
                codexPermissions: configuration.codexPermissions,
                bearerResolver: configuration.bearerResolver,
                credentialProvider: configuration.credentialProvider,
                transport: transport
            ))
        }
        let catalog = LiveModelCatalogStore(
            input: .default,
            environment: environment,
            openGrokHome: home
        )
        resolver = LiveModelCatalogResolver(
            environment: environment,
            openGrokHome: home,
            sessionID: "credential-invalidation-session",
            workingDirectory: home,
            catalogSource: { catalog.snapshot() },
            makeCredentialResolver: { environment, home in
                LiveCredentialResolver(environment: environment, openGrokHome: home)
            }
        )
        let initial = try await resolver.resolve(modelID: "glm-5.2")
        coordinator = LiveModelSwitchCoordinator(
            sampling: initial.sampling,
            sampler: try makeSampler(initial.sampling),
            resolver: resolver,
            makeSampler: makeSampler,
            history: nil
        )
    }

    func dispose() {
        try? FileManager.default.removeItem(at: home)
    }

    func sample(
        sampler: OpenGrokLiveSampler,
        modelID: String,
        turnID: String
    ) async throws -> OpenGrokLiveSamplingResponse {
        try await sampler.sample(
            OpenGrokLiveSamplingRequest(
                sessionID: "credential-invalidation-session",
                turnID: turnID,
                model: modelID,
                prompt: "credential invalidation probe"
            ),
            emit: { _ in }
        )
    }

    func expectBlocked(
        sampler: OpenGrokLiveSampler,
        modelID: String,
        turnID: String,
        expectedRequestCount: Int = 0
    ) async {
        do {
            let response = try await sample(sampler: sampler, modelID: modelID, turnID: turnID)
            Issue.record("revoked credential unexpectedly sampled: \(response.output)")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("fireworks"))
            #expect(message.contains("credential"))
            #expect(!message.contains(originalCredentialInvalidationSecret))
            #expect(!message.contains(replacementCredentialInvalidationSecret))
        }
        #expect(transport.recordedRequests.count == expectedRequestCount)
    }
}

@Suite("Live model credential invalidation parity", .serialized)
struct LiveModelCredentialInvalidationParityTests {
    @Test("revocation blocks already-issued and new production samplers before any provider request")
    func revokedSnapshotsNeverReachOldTransport() async throws {
        let fixture = try await LiveModelCredentialInvalidationFixture()
        defer { fixture.dispose() }

        let issuedBeforeRevocation = await fixture.coordinator.snapshot()
        try issuedBeforeRevocation.requireValidCredential()
        #expect(issuedBeforeRevocation.configuration.apiKey == originalCredentialInvalidationSecret)
        let invalidated = await fixture.coordinator.invalidateCredential(provider: .fireworks)
        #expect(invalidated)
        try clearProviderAPIKey(grokHome: fixture.home, provider: ModelProvider.fireworks.asString)

        let outcome = await fixture.coordinator.rebindCredential(provider: .fireworks)
        guard case .failed(let failure) = outcome else {
            Issue.record("missing provider credential unexpectedly rebound: \(outcome)")
            return
        }
        #expect(!failure.contains(originalCredentialInvalidationSecret))

        let blocked = await fixture.coordinator.snapshot()
        #expect(blocked.provider == .fireworks)
        #expect(blocked.modelID == issuedBeforeRevocation.modelID)
        #expect(blocked.configuration.apiKey.isEmpty)
        #expect(blocked.configuration.bearerResolver == nil)
        #expect(blocked.configuration.credentialProvider == nil)
        #expect(throws: LiveModelSwitchError.credentialsUnavailable(
            provider: .fireworks,
            detail: "credential was removed or rotated; update it or switch providers"
        )) {
            try issuedBeforeRevocation.requireValidCredential()
        }

        await fixture.expectBlocked(
            sampler: issuedBeforeRevocation.sampler,
            modelID: issuedBeforeRevocation.modelID,
            turnID: "captured-before-removal"
        )
        await fixture.expectBlocked(
            sampler: blocked.sampler,
            modelID: blocked.modelID,
            turnID: "captured-after-removal"
        )
    }

    @Test("a replacement key restores new requests without resurrecting pre-revocation snapshots")
    func replacementRebindRestoresOnlyNewGeneration() async throws {
        let fixture = try await LiveModelCredentialInvalidationFixture()
        defer { fixture.dispose() }

        let revoked = await fixture.coordinator.snapshot()
        let invalidated = await fixture.coordinator.invalidateCredential(provider: .fireworks)
        #expect(invalidated)
        try clearProviderAPIKey(grokHome: fixture.home, provider: ModelProvider.fireworks.asString)
        guard case .failed = await fixture.coordinator.rebindCredential(provider: .fireworks) else {
            Issue.record("removed credential unexpectedly rebound")
            return
        }

        try storeProviderAPIKey(
            grokHome: fixture.home,
            provider: ModelProvider.fireworks.asString,
            apiKey: replacementCredentialInvalidationSecret
        )
        let rebound = await fixture.coordinator.rebindCredential(provider: .fireworks)
        #expect(rebound == .rebound(provider: .fireworks))

        let restored = await fixture.coordinator.snapshot()
        let response = try await fixture.sample(
            sampler: restored.sampler,
            modelID: restored.modelID,
            turnID: "replacement-turn"
        )
        #expect(response.output == "response-0")
        #expect(fixture.transport.recordedRequests.count == 1)
        #expect(fixture.transport.recordedRequests.first?.headers["Authorization"]
            == "Bearer \(replacementCredentialInvalidationSecret)")

        await fixture.expectBlocked(
            sampler: revoked.sampler,
            modelID: revoked.modelID,
            turnID: "stale-generation-after-recovery",
            expectedRequestCount: 1
        )
    }

    @Test("an unrelated provider invalidation cannot interrupt the active sampler")
    func unrelatedProviderLeavesActiveCredentialUntouched() async throws {
        let fixture = try await LiveModelCredentialInvalidationFixture()
        defer { fixture.dispose() }

        let existing = await fixture.coordinator.snapshot()
        let invalidated = await fixture.coordinator.invalidateCredential(provider: .deepseek)
        #expect(!invalidated)
        #expect(await fixture.coordinator.activeProvider == .fireworks)

        let response = try await fixture.sample(
            sampler: existing.sampler,
            modelID: existing.modelID,
            turnID: "unrelated-provider-removal"
        )
        #expect(response.output == "response-0")
        #expect(fixture.transport.recordedRequests.count == 1)
        #expect(fixture.transport.recordedRequests.first?.headers["Authorization"]
            == "Bearer \(originalCredentialInvalidationSecret)")
    }

    @Test("reselecting an unchanged model recovers an invalidated credential route")
    func sameModelSelectionRestoresRevokedRoute() async throws {
        let fixture = try await LiveModelCredentialInvalidationFixture()
        defer { fixture.dispose() }

        let invalidated = await fixture.coordinator.invalidateCredential(provider: .fireworks)
        #expect(invalidated)
        try storeProviderAPIKey(
            grokHome: fixture.home,
            provider: ModelProvider.fireworks.asString,
            apiKey: replacementCredentialInvalidationSecret
        )

        let outcome = await fixture.coordinator.apply(modelID: "glm-5.2")
        guard case .switched(let summary) = outcome else {
            Issue.record("unchanged model selection did not restore revoked route: \(outcome)")
            return
        }
        #expect(summary.provider == .fireworks)

        let restored = await fixture.coordinator.snapshot()
        let response = try await fixture.sample(
            sampler: restored.sampler,
            modelID: restored.modelID,
            turnID: "same-model-recovery"
        )
        #expect(response.output == "response-0")
        #expect(fixture.transport.recordedRequests.first?.headers["Authorization"]
            == "Bearer \(replacementCredentialInvalidationSecret)")
    }

    @Test("an auxiliary provider route captured before revocation also fails closed")
    func capturedAuxiliaryRouteCannotReuseRevokedBearer() async throws {
        let fixture = try await LiveModelCredentialInvalidationFixture()
        defer { fixture.dispose() }

        let auxiliary = await fixture.coordinator.auxiliaryRecapRoute(explicitModelID: nil)
        #expect(auxiliary.configuration.provider == .fireworks)
        let invalidated = await fixture.coordinator.invalidateCredential(provider: .fireworks)
        #expect(invalidated)

        await fixture.expectBlocked(
            sampler: auxiliary.sampler,
            modelID: auxiliary.configuration.model,
            turnID: "captured-auxiliary-route"
        )
    }

    @Test("Codex snapshots preserve turn-state registry while credential generations remain revocable")
    func codexTurnStateSurvivesSamplingGate() async throws {
        let fixture = try await LiveModelCredentialInvalidationFixture()
        defer { fixture.dispose() }

        let codexTransport = MockHTTPTransport()
        let configuration = OpenGrokLiveSamplingConfiguration(
            model: "gpt-test",
            baseURL: "https://provider.example.test",
            apiKey: "codex-revoked-private-secret",
            provider: .codex,
            apiBackend: .responses,
            extraHeaders: ["Authorization": "Bearer codex-revoked-private-secret"],
            queryParams: ["api_key": "codex-revoked-private-secret", "safe": "retained"],
            transport: codexTransport
        )
        let originalSampler = try OpenGrokLiveSampler.production(configuration: configuration)
        let coordinator = LiveModelSwitchCoordinator(
            sampling: configuration,
            sampler: originalSampler,
            resolver: fixture.resolver,
            makeSampler: OpenGrokLiveSampler.production(configuration:),
            history: nil
        )
        let issued = await coordinator.snapshot()
        let originalState = try #require(originalSampler.codexTurnState(
            sessionID: "codex-session",
            turnID: "codex-turn"
        ))
        let snapshotState = try #require(issued.sampler.codexTurnState(
            sessionID: "codex-session",
            turnID: "codex-turn"
        ))
        #expect(originalState === snapshotState)

        let invalidated = await coordinator.invalidateCredential(provider: .codex)
        #expect(invalidated)
        let blocked = await coordinator.snapshot()
        #expect(blocked.configuration.apiKey.isEmpty)
        #expect(blocked.configuration.extraHeaders["Authorization"] == nil)
        #expect(blocked.configuration.queryParams["api_key"] == nil)
        #expect(blocked.configuration.queryParams["safe"] == "retained")

        do {
            let response = try await issued.sampler.sample(
                OpenGrokLiveSamplingRequest(
                    sessionID: "codex-session",
                    turnID: "codex-turn",
                    model: "gpt-test",
                    prompt: "blocked Codex turn"
                ),
                emit: { _ in }
            )
            Issue.record("revoked Codex snapshot unexpectedly sampled: \(response.output)")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("codex"))
            #expect(!message.contains("codex-revoked-private-secret"))
        }
        #expect(codexTransport.recordedRequests.isEmpty)
    }
}
