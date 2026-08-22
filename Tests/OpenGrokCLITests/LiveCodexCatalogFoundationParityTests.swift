// LiveCodexCatalogFoundationParityTests.swift
//
// End-to-end production catalog wiring, not a substitute credential broker:
// isolated auth stores -> LiveModelCatalogStore -> OAuth/catalog transport ->
// account-scoped disk cache and the actual selectable model catalog.

import Foundation
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokHTTP
import OpenGrokModels
import OpenGrokSamplingTypes
import Testing

@testable import OpenGrokCLI

private final class CodexCatalogFoundationFixture: @unchecked Sendable {
    let home: URL
    let environment: [String: String]

    init(extraEnvironment: [String: String] = [:]) throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-codex-catalog-foundation-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var values = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "GROK_CODEX_INFERENCE_BASE_URL": "https://catalog.example.test/backend/codex",
            "GROK_CODEX_AUTH_BASE_URL": "https://issuer.example.test",
            "OPENGROK_CODEX_CLIENT_VERSION": "1.2.3-foundation",
        ]
        for (key, value) in extraEnvironment {
            values[key] = value
        }
        environment = values
    }

    var codexAuthFile: URL {
        home.appendingPathComponent(OpenGrokAuthPaths.codexAuthFileName)
    }

    var codexCacheFile: URL {
        home.appendingPathComponent(CodexModels.cacheFileName)
    }

    func dispose() {
        try? FileManager.default.removeItem(at: home)
    }

    @discardableResult
    func installCodex(
        accountID: String? = "account-foundation",
        userID: String? = "user-foundation",
        email: String? = "foundation@example.test",
        workspace: Bool = false,
        accessTokenLifetime: TimeInterval = 7_200,
        tokenLabel: String = UUID().uuidString
    ) throws -> (idToken: String, accessToken: String) {
        var auth: [String: Any] = [
            "chatgpt_plan_type": workspace ? "team" : "plus",
        ]
        if let accountID { auth["chatgpt_account_id"] = accountID }
        if let userID { auth["chatgpt_user_id"] = userID }

        var claims: [String: Any] = [
            "https://api.openai.com/auth": auth,
            "exp": Int(Date().addingTimeInterval(7_200).timeIntervalSince1970),
        ]
        if let email { claims["email"] = email }
        let idToken = buildTestJWT(payload: claims)
        let accessToken = buildTestJWT(payload: [
            "exp": Int(Date().addingTimeInterval(accessTokenLifetime).timeIntervalSince1970),
            "jti": tokenLabel,
        ])
        try persistCodexTokens(
            at: codexAuthFile,
            idToken: idToken,
            accessToken: accessToken,
            refreshToken: "refresh-\(tokenLabel)",
            accountID: accountID
        )
        return (idToken, accessToken)
    }

    func cacheDocument() throws -> [String: Any] {
        let data = try Data(contentsOf: codexCacheFile)
        let document = try JSONSerialization.jsonObject(with: data)
        return try #require(document as? [String: Any])
    }
}

private func codexCatalogFoundationBody(
    slug: String = "codex-foundation-live",
    name: String = "Foundation Live"
) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "models": [[
            "slug": slug,
            "display_name": name,
            "visibility": "list",
            "priority": 1,
            "context_window": 400_000,
            "supported_in_api": false,
        ]],
    ])
}

private func catalogFoundationResponse(
    status: Int = 200,
    body: Data = Data()
) -> MockHTTPTransport.ScriptedResponse {
    MockHTTPTransport.ScriptedResponse(
        metadata: HTTPResponseMetadata(statusCode: status),
        body: body
    )
}

private func upstreamCodexPrincipalFingerprint(
    accountID: String?,
    userID: String?,
    email: String?,
    workspace: Bool
) -> String {
    var message = Data("open-grok-codex-model-cache-account-v1\0".utf8)
    for component in [accountID, userID, email] {
        let encoded = Data((component ?? "").utf8)
        var length = UInt64(encoded.count).littleEndian
        withUnsafeBytes(of: &length) { message.append(contentsOf: $0) }
        message.append(encoded)
    }
    message.append(workspace ? 1 : 0)
    return Blake3.hexDigest(Array(message))
}

private func foundationAPIKeyFingerprint(_ key: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in key.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return String(hash, radix: 16)
}

private final class PrincipalSwitchCatalogTransport: HTTPTransport, @unchecked Sendable {
    private let response: Data
    private let switchPrincipal: @Sendable () throws -> Void

    init(response: Data, switchPrincipal: @escaping @Sendable () throws -> Void) {
        self.response = response
        self.switchPrincipal = switchPrincipal
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try switchPrincipal()
        return HTTPResponse(
            metadata: HTTPResponseMetadata(statusCode: 200),
            body: response
        )
    }

    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<HTTPStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

@Suite("Live Codex catalog foundation parity", .serialized)
struct LiveCodexCatalogFoundationParityTests {
    @Test("a real Codex auth store fetches, publishes, and writes a principal-only cache")
    func codexCatalogReachesLiveStoreAndPrincipalScopedCache() async throws {
        let fixture = try CodexCatalogFoundationFixture()
        defer { fixture.dispose() }
        let credentials = try fixture.installCodex(workspace: true)
        let transport = MockHTTPTransport(responses: [
            catalogFoundationResponse(body: try codexCatalogFoundationBody()),
        ])
        let store = LiveModelCatalogStore(
            input: .default,
            environment: fixture.environment,
            openGrokHome: fixture.home,
            transport: transport
        )

        let outcome = await store.refreshCodexForced()

        #expect(outcome.partition == .codex)
        #expect(outcome.published)
        #expect(outcome.failure == nil)
        #expect(store.snapshot()["codex-foundation-live"]?.info.name == "Foundation Live")

        let request = try #require(transport.recordedRequests.first)
        #expect(transport.recordedRequests.count == 1)
        #expect(request.url.absoluteString ==
            "https://catalog.example.test/backend/codex/models?client_version=1.2.3")
        #expect(request.headers["Authorization"] == "Bearer \(credentials.accessToken)")
        #expect(request.headers["ChatGPT-Account-ID"] == "account-foundation")
        #expect(request.headers["originator"] == "codex_cli_rs")

        let document = try fixture.cacheDocument()
        let expectedFingerprint = upstreamCodexPrincipalFingerprint(
            accountID: "account-foundation",
            userID: "user-foundation",
            email: "foundation@example.test",
            workspace: true
        )
        #expect(document["account_fingerprint"] as? String == expectedFingerprint)
        #expect((document["account_fingerprint"] as? String)?.count == 64)
        let cacheText = try String(contentsOf: fixture.codexCacheFile, encoding: .utf8)
        #expect(!cacheText.contains(credentials.accessToken))
        #expect(!cacheText.contains("refresh-"))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.home.appendingPathComponent("models_cache.json").path
        ))
    }

    @Test("an unauthorized catalog request performs exactly one real OAuth refresh and retry")
    func unauthorizedCatalogForcesOneOAuthRefresh() async throws {
        let fixture = try CodexCatalogFoundationFixture()
        defer { fixture.dispose() }
        let initial = try fixture.installCodex(tokenLabel: "initial")
        let refreshedAccess = buildTestJWT(payload: [
            "exp": Int(Date().addingTimeInterval(7_200).timeIntervalSince1970),
            "jti": "refreshed",
        ])
        let refreshBody = try JSONSerialization.data(withJSONObject: [
            "access_token": refreshedAccess,
            "refresh_token": "refresh-rotated",
            "id_token": initial.idToken,
        ])
        let transport = MockHTTPTransport(responses: [
            catalogFoundationResponse(status: 401),
            catalogFoundationResponse(body: refreshBody),
            catalogFoundationResponse(body: try codexCatalogFoundationBody()),
        ])
        let store = LiveModelCatalogStore(
            input: .default,
            environment: fixture.environment,
            openGrokHome: fixture.home,
            transport: transport
        )

        let outcome = await store.refreshCodexForced()

        #expect(outcome.published)
        #expect(outcome.failure == nil)
        let requests = transport.recordedRequests
        #expect(requests.map(\.url.path) == [
            "/backend/codex/models",
            "/oauth/token",
            "/backend/codex/models",
        ])
        let firstRequest = try #require(requests.first)
        let retriedRequest = try #require(requests.dropFirst(2).first)
        #expect(firstRequest.headers["Authorization"] == "Bearer \(initial.accessToken)")
        #expect(retriedRequest.headers["Authorization"] == "Bearer \(refreshedAccess)")
        #expect(retriedRequest.headers["ChatGPT-Account-ID"] == "account-foundation")
        #expect((try loadCodexCredentials(at: fixture.codexAuthFile))?.accessToken == refreshedAccess)
    }

    @Test("normal startup refresh automatically discovers the authenticated Codex catalog")
    func normalBackgroundRefreshIncludesCodex() async throws {
        let fixture = try CodexCatalogFoundationFixture()
        defer { fixture.dispose() }
        try fixture.installCodex()
        let transport = MockHTTPTransport(responses: [
            catalogFoundationResponse(body: try codexCatalogFoundationBody(
                slug: "startup-codex-model",
                name: "Startup Codex"
            )),
        ])
        let store = LiveModelCatalogStore(
            input: .default,
            environment: fixture.environment,
            openGrokHome: fixture.home,
            transport: transport
        )

        store.spawnBackgroundRefresh()
        let refresh = try #require(store.backgroundRefreshTask)
        await refresh.value

        #expect(store.snapshot()["startup-codex-model"]?.info.name == "Startup Codex")
        #expect(transport.recordedRequests.count == 1)
        #expect(transport.recordedRequests.first?.url.path == "/backend/codex/models")
    }

    @Test("an expired bearer is refreshed before any catalog request")
    func expiredBearerRefreshesBeforeCatalogFetch() async throws {
        let fixture = try CodexCatalogFoundationFixture()
        defer { fixture.dispose() }
        let expired = try fixture.installCodex(
            accessTokenLifetime: -60,
            tokenLabel: "expired"
        )
        let fresh = buildTestJWT(payload: [
            "exp": Int(Date().addingTimeInterval(7_200).timeIntervalSince1970),
            "jti": "proactive",
        ])
        let refreshBody = try JSONSerialization.data(withJSONObject: [
            "access_token": fresh,
            "refresh_token": "refresh-proactive",
            "id_token": expired.idToken,
        ])
        let transport = MockHTTPTransport(responses: [
            catalogFoundationResponse(body: refreshBody),
            catalogFoundationResponse(body: try codexCatalogFoundationBody()),
        ])
        let store = LiveModelCatalogStore(
            input: .default,
            environment: fixture.environment,
            openGrokHome: fixture.home,
            transport: transport
        )

        let outcome = await store.refreshCodexForced()

        #expect(outcome.published)
        let requests = transport.recordedRequests
        #expect(requests.map(\.url.path) == ["/oauth/token", "/backend/codex/models"])
        let catalogRequest = try #require(requests.dropFirst().first)
        #expect(catalogRequest.headers["Authorization"] == "Bearer \(fresh)")
        #expect(!requests.contains { $0.headers["Authorization"] == "Bearer \(expired.accessToken)" })
    }

    @Test("credentials without any stable principal never fetch or persist a catalog")
    func absentStableIdentityFailsClosed() async throws {
        let fixture = try CodexCatalogFoundationFixture()
        defer { fixture.dispose() }
        try fixture.installCodex(accountID: nil, userID: nil, email: nil)
        let transport = MockHTTPTransport()
        let store = LiveModelCatalogStore(
            input: .default,
            environment: fixture.environment,
            openGrokHome: fixture.home,
            transport: transport
        )

        let outcome = await store.refreshCodexForced()

        #expect(!outcome.published)
        #expect(transport.recordedRequests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.codexCacheFile.path))
    }

    @Test("bearer rotation preserves account identity while an account switch changes it")
    func principalFingerprintSurvivesBearerRotationOnly() async throws {
        let fixture = try CodexCatalogFoundationFixture()
        defer { fixture.dispose() }
        try fixture.installCodex(tokenLabel: "first")
        let transport = MockHTTPTransport(responses: [
            catalogFoundationResponse(body: try codexCatalogFoundationBody()),
            catalogFoundationResponse(body: try codexCatalogFoundationBody()),
            catalogFoundationResponse(body: try codexCatalogFoundationBody()),
        ])
        let store = LiveModelCatalogStore(
            input: .default,
            environment: fixture.environment,
            openGrokHome: fixture.home,
            transport: transport
        )

        let first = await store.refreshCodexForced()
        #expect(first.published)
        let firstCacheDocument = try fixture.cacheDocument()
        let firstFingerprint = try #require(firstCacheDocument["account_fingerprint"] as? String)

        let rotated = try fixture.installCodex(tokenLabel: "rotated")
        store.refreshCredentialSnapshot()
        let second = await store.refreshCodexForced()
        #expect(second.published)
        let rotatedCacheDocument = try fixture.cacheDocument()
        let rotatedFingerprint = try #require(rotatedCacheDocument["account_fingerprint"] as? String)
        #expect(rotatedFingerprint == firstFingerprint)
        let rotatedRequest = try #require(transport.recordedRequests.dropFirst().first)
        #expect(rotatedRequest.headers["Authorization"] ==
            "Bearer \(rotated.accessToken)")

        try fixture.installCodex(accountID: "account-other", tokenLabel: "other")
        store.refreshCredentialSnapshot()
        let third = await store.refreshCodexForced()
        #expect(third.published)
        let switchedCacheDocument = try fixture.cacheDocument()
        let switchedFingerprint = try #require(switchedCacheDocument["account_fingerprint"] as? String)
        #expect(switchedFingerprint != firstFingerprint)
        let accountRequest = try #require(transport.recordedRequests.dropFirst(2).first)
        #expect(accountRequest.headers["ChatGPT-Account-ID"] == "account-other")
    }

    @Test("an account switch during fetch cannot publish or overwrite the new principal's cache")
    func principalSwitchDuringFetchIsDiscarded() async throws {
        let fixture = try CodexCatalogFoundationFixture()
        defer { fixture.dispose() }
        try fixture.installCodex(accountID: "account-before")
        let transport = PrincipalSwitchCatalogTransport(
            response: try codexCatalogFoundationBody(slug: "stale-account-model")
        ) {
            try fixture.installCodex(accountID: "account-after")
        }
        let store = LiveModelCatalogStore(
            input: .default,
            environment: fixture.environment,
            openGrokHome: fixture.home,
            transport: transport
        )

        let outcome = await store.refreshCodexForced()

        #expect(!outcome.published)
        #expect(store.snapshot()["stale-account-model"] == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.codexCacheFile.path))
    }

    @Test("Codex OAuth visibility and xAI session visibility remain independent")
    func providerSessionVisibilityComesFromTheCorrectStore() throws {
        let fixture = try CodexCatalogFoundationFixture()
        defer { fixture.dispose() }
        let codexInput = CatalogResolutionInput(
            models: ModelsSectionConfig(default: "gpt-5.6-sol")
        )
        let unauthenticated = LiveModelCatalogStore(
            input: codexInput,
            environment: fixture.environment,
            openGrokHome: fixture.home
        )
        #expect(unauthenticated.currentModelID() != "gpt-5.6-sol")

        let scope = GrokComConfig.default(environment: fixture.environment).authScope
        try writeAuthJSON(
            at: fixture.home.appendingPathComponent(OpenGrokAuthPaths.authFileName),
            store: [scope: GrokAuth(key: "xai-session", authMode: .oidc, userID: "xai-user")]
        )
        let xaiOnly = LiveModelCatalogStore(
            input: codexInput,
            environment: fixture.environment,
            openGrokHome: fixture.home
        )
        #expect(xaiOnly.currentModelID() != "gpt-5.6-sol")

        try fixture.installCodex()
        let bothProviders = LiveModelCatalogStore(
            input: codexInput,
            environment: fixture.environment,
            openGrokHome: fixture.home
        )
        #expect(bothProviders.currentModelID() == "gpt-5.6-sol")

        let xaiSessionOnlyInput = CatalogResolutionInput(
            models: ModelsSectionConfig(default: "foundation-xai-session-only"),
            configModels: [(
                "foundation-xai-session-only",
                ConfigModelOverride(
                    model: "foundation-xai-session-only",
                    provider: .xai,
                    supportedInApi: false
                )
            )]
        )
        let xaiSession = LiveModelCatalogStore(
            input: xaiSessionOnlyInput,
            environment: fixture.environment,
            openGrokHome: fixture.home
        )
        #expect(xaiSession.currentModelID() == "foundation-xai-session-only")
    }

    @Test("stored provider keys stay on trusted hosts while explicit keys retain precedence")
    func providerSnapshotMatchesBrokerTrustAndPrecedence() async throws {
        let fixture = try CodexCatalogFoundationFixture(extraEnvironment: [
            FireworksModels.apiBaseURLEnv: "https://untrusted.example.test/v1",
        ])
        defer { fixture.dispose() }
        try storeProviderAPIKey(
            grokHome: fixture.home,
            provider: ModelProvider.fireworks.asString,
            apiKey: "stored-fireworks-secret"
        )
        let blockedTransport = MockHTTPTransport()
        let blocked = LiveModelCatalogStore(
            input: .default,
            environment: fixture.environment,
            openGrokHome: fixture.home,
            transport: blockedTransport
        )
        let blockedOutcome = await blocked.refreshPartition(.fireworks)
        #expect(!blockedOutcome.published)
        #expect(blockedTransport.recordedRequests.isEmpty)

        var explicitEnvironment = fixture.environment
        explicitEnvironment[FireworksModels.apiKeyEnv] = "explicit-fireworks-key"
        let allowedTransport = MockHTTPTransport(responses: [
            catalogFoundationResponse(body: Data(#"{"data":[]}"#.utf8)),
        ])
        let allowed = LiveModelCatalogStore(
            input: .default,
            environment: explicitEnvironment,
            openGrokHome: fixture.home,
            transport: allowedTransport
        )
        let allowedOutcome = await allowed.refreshPartition(.fireworks)
        #expect(allowedOutcome.published)
        let request = try #require(allowedTransport.recordedRequests.first)
        #expect(request.url.host == "untrusted.example.test")
        #expect(request.headers["Authorization"] == "Bearer explicit-fireworks-key")
        #expect(request.headers["Authorization"] != "Bearer stored-fireworks-secret")
    }

    @Test("provider publish fences reject forged fingerprints and accept the selected key")
    func providerPublishFenceRejectsMismatchedCredentials() throws {
        let fixture = try CodexCatalogFoundationFixture(extraEnvironment: [
            FireworksModels.apiKeyEnv: "provider-foundation-key",
        ])
        defer { fixture.dispose() }
        let store = LiveModelCatalogStore(
            input: .default,
            environment: fixture.environment,
            openGrokHome: fixture.home
        )
        let modelID = "fireworks-foundation-only"
        var info = ModelInfo.fallback(slug: modelID)
        info.provider = .fireworks
        info.model = "accounts/fireworks/models/foundation-only"
        info.name = "Provider Foundation"
        let entries = OrderedModelMap([(modelID, ModelEntry(
            info: info,
            envKey: .single(FireworksModels.apiKeyEnv)
        ))])

        store.applyFireworksCatalog(FireworksModelsCatalog(
            entries: entries,
            credentialFingerprint: "forged-fingerprint"
        ))
        #expect(store.snapshot()[modelID] == nil)

        store.applyFireworksCatalog(FireworksModelsCatalog(
            entries: entries,
            credentialFingerprint: foundationAPIKeyFingerprint("provider-foundation-key")
        ))
        #expect(store.snapshot()[modelID]?.info.name == "Provider Foundation")
    }

    @Test("a custom model saved through settings becomes selectable after the actual live reload")
    func savedCustomModelReachesLiveCatalogAndResolver() async throws {
        let fixture = try CodexCatalogFoundationFixture(extraEnvironment: [
            ZaiModels.apiKeyEnv: "foundation-zai-key",
        ])
        defer { fixture.dispose() }
        let key = "zai:foundation-custom"
        let initialInput = liveCatalogResolutionInput(
            workingDirectory: fixture.home,
            environment: fixture.environment
        )
        let catalog = LiveModelCatalogStore(
            input: initialInput,
            environment: fixture.environment,
            openGrokHome: fixture.home
        )
        #expect(catalog.snapshot()[key] == nil)

        let settingsStore = CustomModelStore(grokHome: fixture.home)
        try await settingsStore.upsertCustomModel(CustomModelEntry(
            key: key,
            modelId: "glm-foundation-custom",
            provider: ModelProvider.zai.asString,
            baseUrl: "https://api.z.ai/v1",
            contextWindow: 128_000
        ))
        catalog.updateInput(liveCatalogResolutionInput(
            workingDirectory: fixture.home,
            environment: fixture.environment
        ))

        #expect(catalog.snapshot()[key]?.info.model == "glm-foundation-custom")
        #expect(catalog.snapshot()[key]?.info.provider == .zai)
        #expect(catalog.pickerEntries().contains { $0.id == key })

        let resolver = LiveModelCatalogResolver(
            environment: fixture.environment,
            openGrokHome: fixture.home,
            sessionID: "foundation-custom-session",
            workingDirectory: fixture.home,
            catalogSource: { catalog.snapshot() }
        )
        let resolved = try await resolver.resolve(modelID: key)
        #expect(resolved.sampling.provider == .zai)
        #expect(resolved.sampling.model == "glm-foundation-custom")
        #expect(resolved.credential.bearer == "foundation-zai-key")
    }
}
