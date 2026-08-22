import Foundation
import OpenGrokAuth
import OpenGrokCompaction
import OpenGrokHTTP
import OpenGrokSampler
import OpenGrokSamplingTypes
import Testing
@testable import OpenGrokCLI

private let expiredCompactionBearer = "codex-revoked-bearer-secret"
private let replacementCompactionBearer = "codex-replacement-bearer-secret"

private struct CompactionCredentialFixture {
    let home: URL
    let transport: MockHTTPTransport
    let coordinator: LiveModelSwitchCoordinator

    init(provider: ModelProvider = .codex) throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-compaction-credential-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        transport = MockHTTPTransport()
        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "GROK_CODEX_INFERENCE_BASE_URL": "https://compaction.example.test",
        ]
        let configuration = OpenGrokLiveSamplingConfiguration(
            model: "gpt-5.6-sol",
            baseURL: "https://compaction.example.test",
            apiKey: expiredCompactionBearer,
            provider: provider,
            apiBackend: .responses,
            extraHeaders: ["ChatGPT-Account-ID": "compaction-account"],
            environment: environment,
            transport: transport
        )
        let sampler = OpenGrokLiveSampler { _, _ in
            OpenGrokLiveSamplingResponse(output: "not a compaction request")
        }
        coordinator = LiveModelSwitchCoordinator(
            sampling: configuration,
            sampler: sampler,
            resolver: LiveModelCatalogResolver(
                environment: environment,
                openGrokHome: home,
                sessionID: "compaction-credential-session",
                workingDirectory: home
            ),
            makeSampler: { _ in sampler },
            history: nil
        )
    }

    func dispose() {
        try? FileManager.default.removeItem(at: home)
    }

    func remoteResponse() -> MockHTTPTransport.ScriptedResponse {
        let body = """
        data: {"type":"response.output_item.done","item":{"type":"compaction","encrypted_content":"opaque-summary"}}

        data: {"type":"response.completed","response":{"id":"compaction-response"}}


        """
        return MockHTTPTransport.ScriptedResponse(
            metadata: HTTPResponseMetadata(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"]
            ),
            body: Data(body.utf8)
        )
    }

    func compactTransport(
        snapshot: LiveModelSwitchCoordinator.Snapshot,
        underlying: (any HTTPTransport)? = nil
    ) -> HTTPCodexCompactionTransport {
        let configuration = liveCredentialGuardedCompactionConfiguration(snapshot: snapshot)
        let guarded = underlying ?? configuration.transport!
        return HTTPCodexCompactionTransport(
            transport: guarded,
            baseURL: configuration.baseURL,
            model: configuration.model,
            headers: ["Authorization": "Bearer \(configuration.apiKey)"],
            requestPolicy: ResponsesRequestPolicy(
                sessionID: "compaction-credential-session",
                turnID: "compaction-turn"
            )
        )
    }

    func persistReplacementCredential() throws {
        let store = CodexAuthStore(
            authMode: "chatgpt",
            tokens: CodexTokenData(
                idToken: "opaque-id-token",
                accessToken: replacementCompactionBearer,
                refreshToken: "replacement-refresh-token",
                accountID: "compaction-account"
            ),
            lastRefresh: Date()
        )
        try saveCodexStore(
            store,
            at: home.appendingPathComponent("codex-auth.json")
        )
    }
}

private final class RevokingCompactionCredentialProvider: AuthCredentialProvider,
    @unchecked Sendable
{
    let coordinator: LiveModelSwitchCoordinator

    init(coordinator: LiveModelSwitchCoordinator) {
        self.coordinator = coordinator
    }

    func apply(to headers: inout [String: String], baseURL: String) {
        headers["Authorization"] = "Bearer \(expiredCompactionBearer)"
    }

    func snapshot() -> CredentialSnapshot {
        CredentialSnapshot(token: replacementCompactionBearer)
    }

    func refreshAfterUnauthorized() async -> Bool {
        await coordinator.invalidateCredential(provider: .codex)
    }
}

private final class RevokingRemoteCompactionTransport: CodexCompactionTransport,
    @unchecked Sendable
{
    let coordinator: LiveModelSwitchCoordinator
    let transport: HTTPCodexCompactionTransport

    init(
        coordinator: LiveModelSwitchCoordinator,
        transport: HTTPCodexCompactionTransport
    ) {
        self.coordinator = coordinator
        self.transport = transport
    }

    func send(
        _ request: CodexCompactionRequest,
        onEvent: @Sendable (CodexCompactionStreamEvent) async throws -> Void
    ) async throws {
        _ = await coordinator.invalidateCredential(provider: .codex)
        try await transport.send(request, onEvent: onEvent)
    }
}

@Suite("Live Codex compaction credential revocation")
struct LiveCompactionCredentialRevocationParityTests {
    @Test("a valid production snapshot sends Codex remote compaction normally")
    func validSnapshotReachesRemoteCompaction() async throws {
        let fixture = try CompactionCredentialFixture()
        defer { fixture.dispose() }
        fixture.transport.enqueue(fixture.remoteResponse())
        let snapshot = await fixture.coordinator.snapshot()

        let result = try await runCodexRemoteCompaction(
            transport: fixture.compactTransport(snapshot: snapshot),
            request: CodexCompactionRequest(protocolVersion: .remoteV2, input: [.user("hello")])
        )

        #expect(result.item.encryptedContent == "opaque-summary")
        #expect(fixture.transport.recordedRequests.count == 1)
        #expect(fixture.transport.recordedRequests[0].headers["Authorization"]
            == "Bearer \(expiredCompactionBearer)")
    }

    @Test("a revoked preconstructed remote compaction transport never sends its old bearer")
    func revokedStreamingSnapshotNeverReachesWire() async throws {
        let fixture = try CompactionCredentialFixture()
        defer { fixture.dispose() }
        fixture.transport.enqueue(fixture.remoteResponse())
        let transport = fixture.compactTransport(snapshot: await fixture.coordinator.snapshot())
        #expect(await fixture.coordinator.invalidateCredential(provider: .codex))

        do {
            _ = try await runCodexRemoteCompaction(
                transport: transport,
                request: CodexCompactionRequest(
                    protocolVersion: .remoteV2,
                    input: [.user("hello")]
                )
            )
            Issue.record("a revoked Codex compaction unexpectedly reached the provider")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("credential"))
            #expect(!message.contains(expiredCompactionBearer))
        }
        #expect(fixture.transport.recordedRequests.isEmpty)
    }

    @Test("a revoked legacy unary compaction is blocked at the actual HTTP send")
    func revokedLegacySnapshotNeverReachesWire() async throws {
        let fixture = try CompactionCredentialFixture()
        defer { fixture.dispose() }
        let transport = fixture.compactTransport(snapshot: await fixture.coordinator.snapshot())
        #expect(await fixture.coordinator.invalidateCredential(provider: .codex))

        do {
            _ = try await transport.compactLegacy(CodexCompactionRequest(
                protocolVersion: .legacyUnary,
                input: [.user("hello")]
            ))
            Issue.record("a revoked unary compaction unexpectedly reached the provider")
        } catch {
            #expect(!String(describing: error).contains(expiredCompactionBearer))
        }
        #expect(fixture.transport.recordedRequests.isEmpty)
    }

    @Test("credential revocation during auth refresh blocks the second actual send")
    func unauthorizedRetryCannotBypassSnapshotGate() async throws {
        let fixture = try CompactionCredentialFixture()
        defer { fixture.dispose() }
        fixture.transport.enqueue(MockHTTPTransport.ScriptedResponse(
            metadata: HTTPResponseMetadata(statusCode: 401)
        ))
        fixture.transport.enqueue(MockHTTPTransport.ScriptedResponse(
            metadata: HTTPResponseMetadata(statusCode: 200)
        ))
        let snapshot = await fixture.coordinator.snapshot()
        let guarded = try #require(
            liveCredentialGuardedCompactionConfiguration(snapshot: snapshot).transport
        )
        let retry = AuthRetryTransport(
            transport: guarded,
            credentials: RevokingCompactionCredentialProvider(coordinator: fixture.coordinator),
            maxRetries: 1
        )
        let request = HTTPRequest(
            method: .get,
            url: try #require(URL(string: "https://compaction.example.test/v1/responses"))
        )

        do {
            _ = try await retry.send(request)
            Issue.record("the invalidated refresh retry unexpectedly reached the provider")
        } catch {
            #expect(!String(describing: error).contains(expiredCompactionBearer))
        }
        #expect(fixture.transport.recordedRequests.count == 1)
        #expect(fixture.transport.recordedRequests[0].headers["Authorization"]
            == "Bearer \(expiredCompactionBearer)")
    }

    @Test("replacement credentials restore new compaction snapshots without reviving the old one")
    func replacementCredentialRestoresFreshSnapshotOnly() async throws {
        let fixture = try CompactionCredentialFixture()
        defer { fixture.dispose() }
        let stale = await fixture.coordinator.snapshot()
        #expect(await fixture.coordinator.invalidateCredential(provider: .codex))
        try fixture.persistReplacementCredential()
        #expect(await fixture.coordinator.rebindCredential(provider: .codex)
            == .rebound(provider: .codex))

        let replacement = await fixture.coordinator.snapshot()
        #expect(replacement.configuration.apiKey == replacementCompactionBearer)
        let guarded = LiveCodexCompactionCredentialTransport(
            transport: fixture.transport,
            snapshot: replacement
        )
        fixture.transport.enqueue(fixture.remoteResponse())
        let result = try await runCodexRemoteCompaction(
            transport: fixture.compactTransport(snapshot: replacement, underlying: guarded),
            request: CodexCompactionRequest(protocolVersion: .remoteV2, input: [.user("hello")])
        )
        #expect(result.item.encryptedContent == "opaque-summary")
        #expect(fixture.transport.recordedRequests[0].headers["Authorization"]
            == "Bearer \(replacementCompactionBearer)")

        do {
            try stale.requireValidCredential()
            Issue.record("the old credential generation was unexpectedly revived")
        } catch {
            #expect(!String(describing: error).contains(expiredCompactionBearer))
        }
    }

    @Test("the live compaction coordinator guards the transport supplied to existing factories")
    func coordinatorFactoryReceivesGuardedProductionTransport() async throws {
        let fixture = try CompactionCredentialFixture()
        defer { fixture.dispose() }
        fixture.transport.enqueue(fixture.remoteResponse())
        let sessionID = "compaction-credential-session"
        let record = LiveConversationRecord(
            sessionID: sessionID,
            workingDirectory: fixture.home.path,
            parentSessionID: nil,
            createdAt: Date(),
            updatedAt: Date(),
            items: [.system("be concise"), .user("compact this real turn")],
            currentModelID: "gpt-5.6-sol",
            currentProvider: .codex
        )
        let history = LiveConversationHistory(
            record: record,
            store: LiveConversationStore(openGrokHome: fixture.home)
        )
        let coordinator = fixture.coordinator
        let compaction = LiveCompactionCoordinator(
            history: history,
            modelSwitch: coordinator,
            sessionID: sessionID,
            openGrokHome: fixture.home,
            makeCodexTransport: { configuration, policy, affinity, turnState in
                guard let guarded = configuration.transport else { return nil }
                let remote = HTTPCodexCompactionTransport(
                    transport: guarded,
                    baseURL: configuration.baseURL,
                    model: configuration.model,
                    headers: ["Authorization": "Bearer \(configuration.apiKey)"],
                    cacheAffinityID: affinity,
                    codexTurnState: turnState,
                    requestPolicy: policy
                )
                return RevokingRemoteCompactionTransport(
                    coordinator: coordinator,
                    transport: remote
                )
            }
        )

        let result = await compaction.compactNow()
        if case .unableToCompact(let reason) = result {
            #expect(!reason.contains(expiredCompactionBearer))
        }
        #expect(fixture.transport.recordedRequests.isEmpty)
    }

    @Test("non-Codex configurations retain their original transport unchanged")
    func nonCodexConfigurationRemainsUnmodified() async throws {
        let fixture = try CompactionCredentialFixture(provider: .xai)
        defer { fixture.dispose() }
        let snapshot = await fixture.coordinator.snapshot()
        let configuration = liveCredentialGuardedCompactionConfiguration(snapshot: snapshot)
        #expect(configuration == snapshot.configuration)
        #expect(configuration.transport is MockHTTPTransport)
    }
}
