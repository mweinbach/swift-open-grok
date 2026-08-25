import Foundation
import Testing
@testable import OpenGrokAuth

private func teamPinTestHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("open-grok-auth-team-pin-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

private func teamPinTestConfig(_ policy: ForceLoginTeam = .single("team-required")) -> GrokComConfig {
    var config = GrokComConfig.default(environment: [:])
    config.forceLoginTeamUUID = policy
    return config
}

private func teamPinTestSession(
    principal: String?,
    metadataTeam: String? = nil,
    camelCasePrincipal: Bool = false,
    expired: Bool = false
) -> GrokAuth {
    var payload: [String: Any] = [
        "sub": "team-pin-user",
        "exp": 9_999_999_999,
        "jti": UUID().uuidString,
    ]
    if let principal {
        payload[camelCasePrincipal ? "principalId" : "principal_id"] = principal
    }
    let metadata = metadataTeam ?? principal
    return GrokAuth(
        key: buildTestJWT(payload: payload),
        authMode: .oidc,
        userID: "team-pin-user",
        principalType: "Team",
        principalID: metadata,
        teamID: metadata,
        refreshToken: "refresh-token-\(principal ?? "missing")",
        expiresAt: Date().addingTimeInterval(expired ? -600 : 3_600),
        oidcIssuer: xaiOAuth2Issuer,
        oidcClientID: defaultOAuth2ClientID
    )
}

private func expectTeamPinMismatch(_ operation: () async throws -> Void) async {
    do {
        try await operation()
        Issue.record("expected administrator team-pin mismatch")
    } catch let error as AuthError {
        guard case .pinnedTeamMismatch = error else {
            Issue.record("unexpected authentication error: \(error)")
            return
        }
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

private actor BlockingTeamPinRefresher: TokenRefresher {
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var outcomeWaiter: CheckedContinuation<RefreshOutcome, Never>?

    func refresh(reason: RefreshReason, current: GrokAuth?) async -> RefreshOutcome {
        await withCheckedContinuation { continuation in
            outcomeWaiter = continuation
            let waiter = startWaiter
            startWaiter = nil
            waiter?.resume()
        }
    }

    func waitUntilStarted() async {
        guard outcomeWaiter == nil else { return }
        await withCheckedContinuation { continuation in
            startWaiter = continuation
        }
    }

    func finish(_ outcome: RefreshOutcome) {
        let waiter = outcomeWaiter
        outcomeWaiter = nil
        waiter?.resume(returning: outcome)
    }
}

@Suite("xAI OAuth administrator team-pin and refresh-rotation parity")
struct AuthManagerTeamPinParityTests {
    @Test("startup clears only the owned wrong-team scope and never trusts forged team metadata")
    func startupRejectsWrongJWTPrincipalWithoutRemovingOtherProviders() async throws {
        let home = try teamPinTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = teamPinTestConfig()
        let authPath = home.appendingPathComponent("auth.json")
        let wrong = teamPinTestSession(principal: "team-attacker", metadataTeam: "team-required")
        let otherProvider = GrokAuth.testDefault(key: "gemini-api-key", authMode: .apiKey)
        try writeAuthJSON(
            at: authPath,
            store: [config.authScope: wrong, "gemini::api_key": otherProvider]
        )

        let manager = AuthManager(grokHome: home, config: config, environment: [:])
        let provider = LiveAuthCredentialProvider(manager: manager)

        #expect(await manager.current() == nil)
        #expect(await manager.currentOrExpired() == nil)
        #expect(!provider.hasUsableCredential())
        #expect(provider.snapshot().token == nil)
        let remaining = try readAuthJSON(at: authPath)
        #expect(remaining[config.authScope] == nil)
        #expect(remaining["gemini::api_key"]?.key == otherProvider.key)
        await expectTeamPinMismatch {
            let auth = try await manager.auth()
            Issue.record("wrong-team credential unexpectedly authenticated: \(auth.authMode)")
        }
    }

    @Test("startup removes auth.json when its only stored OAuth session violates the pin")
    func startupRemovesSoleWrongTeamSession() throws {
        let home = try teamPinTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = teamPinTestConfig()
        let authPath = home.appendingPathComponent("auth.json")
        try writeAuthJSON(
            at: authPath,
            store: [config.authScope: teamPinTestSession(principal: "team-other")]
        )

        let manager = AuthManager(grokHome: home, config: config, environment: [:])

        #expect(manager.snapshotBox.read().token == nil)
        #expect(!FileManager.default.fileExists(atPath: authPath.path))
    }

    @Test("a matching JWT principal remains valid even when mutable auth.json team metadata disagrees")
    func matchingJWTPrincipalOverridesContradictoryStoredMetadata() async throws {
        let home = try teamPinTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = teamPinTestConfig()
        let auth = teamPinTestSession(principal: "team-required", metadataTeam: "forged-metadata")
        let authPath = home.appendingPathComponent("auth.json")
        try writeAuthJSON(at: authPath, store: [config.authScope: auth])

        let manager = AuthManager(grokHome: home, config: config, environment: [:])

        #expect(await manager.current()?.key == auth.key)
        #expect(try await manager.auth().key == auth.key)
        #expect(manager.snapshotBox.read().token == auth.key)
        #expect(try readAuthJSON(at: authPath)[config.authScope]?.key == auth.key)
    }

    @Test("principalId aliases do not require a principal_type claim")
    func principalIDAliasIsAcceptedWithoutPrincipalType() async throws {
        let home = try teamPinTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = AuthManager(grokHome: home, config: teamPinTestConfig(), environment: [:])
        let auth = teamPinTestSession(principal: "team-required", camelCasePrincipal: true)

        try await manager.loginWithSession(auth)

        #expect(try await manager.auth().key == auth.key)
    }

    @Test("inline environment credentials are rejected before snapshot publication without touching disk")
    func inlineWrongTeamDoesNotPublishOrDestroyOwnedDiskState() async throws {
        let home = try teamPinTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = teamPinTestConfig()
        let authPath = home.appendingPathComponent("auth.json")
        let matchingDisk = teamPinTestSession(principal: "team-required")
        try writeAuthJSON(at: authPath, store: [config.authScope: matchingDisk])
        let original = try Data(contentsOf: authPath)
        let forgedInline = teamPinTestSession(principal: "team-other", metadataTeam: "team-required")
        let inlineJSON = String(decoding: try AuthJSON.encoder.encode(forgedInline), as: UTF8.self)

        let manager = AuthManager(
            grokHome: home,
            config: config,
            environment: ["OPENGROK_AUTH": inlineJSON]
        )

        #expect(manager.snapshotBox.read().token == nil)
        #expect(await manager.currentOrExpired() == nil)
        #expect(try Data(contentsOf: authPath) == original)
        await expectTeamPinMismatch {
            let auth = try await manager.auth()
            Issue.record("inline credential unexpectedly authenticated: \(auth.authMode)")
        }
    }

    @Test("matching inline OAuth credentials are accepted without persisting environment-owned secrets")
    func matchingInlineCredentialIsUsableWithoutDiskWrite() async throws {
        let home = try teamPinTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let matching = teamPinTestSession(principal: "team-required")
        let inlineJSON = String(decoding: try AuthJSON.encoder.encode(matching), as: UTF8.self)
        let manager = AuthManager(
            grokHome: home,
            config: teamPinTestConfig(),
            environment: ["OPENGROK_AUTH": inlineJSON]
        )

        #expect(try await manager.auth().key == matching.key)
        #expect(manager.snapshotBox.read().token == matching.key)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path))
    }

    @Test("an empty administrator team allowlist rejects every JWT principal")
    func emptyAllowedTeamsFailClosedBeforePersistence() async throws {
        let home = try teamPinTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = AuthManager(
            grokHome: home,
            config: teamPinTestConfig(.anyOf([])),
            environment: [:]
        )
        let auth = teamPinTestSession(principal: "team-required")

        await expectTeamPinMismatch {
            try await manager.loginWithSession(auth)
        }

        #expect(manager.snapshotBox.read().token == nil)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path))
    }

    @Test("legacy bearer tokens without a principal claim cannot satisfy a newly deployed team pin")
    func missingJWTPrincipalFailsClosedDespiteForgedTeamMetadata() async throws {
        let home = try teamPinTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = AuthManager(grokHome: home, config: teamPinTestConfig(), environment: [:])
        let auth = teamPinTestSession(principal: nil, metadataTeam: "team-required")

        await expectTeamPinMismatch {
            try await manager.update(auth)
        }

        #expect(await manager.currentOrExpired() == nil)
        #expect(manager.snapshotBox.read().token == nil)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path))
    }

    @Test("hot swaps reject wrong-team tokens before cached or synchronous readers can observe them")
    func wrongTeamHotSwapNeverPublishesBearer() async throws {
        let home = try teamPinTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = AuthManager(grokHome: home, config: teamPinTestConfig(), environment: [:])
        let matching = teamPinTestSession(principal: "team-required")
        await manager.hotSwap(matching)
        #expect(manager.snapshotBox.read().token == matching.key)

        await manager.hotSwap(
            teamPinTestSession(principal: "team-other", metadataTeam: "team-required")
        )

        #expect(await manager.current() == nil)
        #expect(await manager.currentOrExpired() == nil)
        #expect(manager.snapshotBox.read().token == nil)
        await expectTeamPinMismatch {
            let auth = try await manager.auth()
            Issue.record("hot-swapped credential unexpectedly authenticated: \(auth.authMode)")
        }
    }

    @Test("update rejects a wrong-team token before modifying existing persisted or published credentials")
    func rejectedUpdatePreservesExistingMatchingSession() async throws {
        let home = try teamPinTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = AuthManager(grokHome: home, config: teamPinTestConfig(), environment: [:])
        let matching = teamPinTestSession(principal: "team-required")
        try await manager.update(matching)
        let authPath = home.appendingPathComponent("auth.json")
        let original = try Data(contentsOf: authPath)
        let forged = teamPinTestSession(principal: "team-other", metadataTeam: "team-required")

        await expectTeamPinMismatch {
            try await manager.update(forged)
        }

        #expect(try Data(contentsOf: authPath) == original)
        #expect(await manager.currentOrExpired()?.key == matching.key)
        #expect(manager.snapshotBox.read().token == matching.key)
    }

    @Test("the explicit login policy checks the access JWT even when auth.json metadata claims compliance")
    func explicitLoginPolicyRejectsForgedMetadataBeforeManagerWrite() async throws {
        let home = try teamPinTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = AuthManager(grokHome: home, environment: [:])
        let forged = teamPinTestSession(principal: "team-other", metadataTeam: "team-required")

        await expectTeamPinMismatch {
            try await loginXAIWithSession(
                manager: manager,
                auth: forged,
                policy: .single("team-required")
            )
        }

        #expect(manager.snapshotBox.read().token == nil)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path))
    }

    @Test("sibling-written wrong-team sessions are removed before adoption or token exchange")
    func wrongTeamSiblingTokenCannotBeAdoptedOrRefreshed() async throws {
        let home = try teamPinTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = teamPinTestConfig()
        let manager = AuthManager(grokHome: home, config: config, environment: [:])
        let expired = teamPinTestSession(principal: "team-required", expired: true)
        await manager.hotSwap(expired)
        let authPath = home.appendingPathComponent("auth.json")
        try writeAuthJSON(
            at: authPath,
            store: [config.authScope: teamPinTestSession(
                principal: "team-other",
                metadataTeam: "team-required"
            )]
        )
        let exchangeCount = CallCounter()
        await manager.configureRefresher(MockTokenRefresher(
            outcome: .success(teamPinTestSession(principal: "team-required")),
            callCount: exchangeCount
        ))

        await expectTeamPinMismatch {
            let auth = try await manager.auth()
            Issue.record("sibling credential unexpectedly authenticated: \(auth.authMode)")
        }

        #expect(exchangeCount.count == 0)
        #expect(manager.snapshotBox.read().token == nil)
        #expect(!FileManager.default.fileExists(atPath: authPath.path))
    }

    @Test("refresh-token rotation into another team never persists or publishes the rejected successor")
    func refreshRejectsWrongTeamSuccessorBeforeDiskWrite() async throws {
        let home = try teamPinTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = teamPinTestConfig()
        let manager = AuthManager(grokHome: home, config: config, environment: [:])
        let expired = teamPinTestSession(principal: "team-required", expired: true)
        try await manager.update(expired)
        let authPath = home.appendingPathComponent("auth.json")
        let original = try Data(contentsOf: authPath)
        let rejected = teamPinTestSession(principal: "team-other", metadataTeam: "team-required")
        let exchangeCount = CallCounter()
        await manager.configureRefresher(MockTokenRefresher(
            outcome: .success(rejected),
            callCount: exchangeCount
        ))

        await expectTeamPinMismatch {
            let auth = try await manager.auth()
            Issue.record("rotated credential unexpectedly authenticated: \(auth.authMode)")
        }

        #expect(exchangeCount.count == 1)
        #expect(try Data(contentsOf: authPath) == original)
        #expect(manager.snapshotBox.read().token == nil)
        #expect(await manager.currentOrExpired() == nil)
    }

    @Test("team-pinned API keys never appear outbound, while deployment-key credentials remain unaffected")
    func outboundSnapshotsExcludeWrongTeamWithoutBreakingDeploymentKeys() async throws {
        let home = try teamPinTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = AuthManager(
            grokHome: home,
            config: teamPinTestConfig(),
            environment: ["XAI_API_KEY": "blocked-api-key"]
        )
        let oauthProvider = LiveAuthCredentialProvider(manager: manager)
        var oauthHeaders: [String: String] = [:]
        oauthProvider.apply(to: &oauthHeaders, baseURL: "https://api.x.ai/v1")

        #expect(!oauthProvider.hasUsableCredential())
        #expect(oauthHeaders["Authorization"] == nil)
        #expect(!(await manager.isLoggedIn()))

        let deploymentProvider = LiveAuthCredentialProvider(
            manager: manager,
            deploymentKey: "deployment-credential"
        )
        var deploymentHeaders: [String: String] = [:]
        deploymentProvider.apply(to: &deploymentHeaders, baseURL: "https://api.x.ai/v1")

        #expect(deploymentProvider.snapshot().token == "deployment-credential")
        #expect(deploymentProvider.snapshot().deploymentID != nil)
        #expect(deploymentHeaders["Authorization"] == "Bearer deployment-credential")
    }

    @Test("only the file-lock owner spends a refresh token and contenders adopt its durable successor")
    func concurrentManagersDoNotDoubleSpendRefreshTokens() async throws {
        let home = try teamPinTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = teamPinTestConfig()
        let expired = teamPinTestSession(principal: "team-required", expired: true)
        try writeAuthJSON(
            at: home.appendingPathComponent("auth.json"),
            store: [config.authScope: expired]
        )
        let owner = AuthManager(grokHome: home, config: config, environment: [:])
        let contender = AuthManager(grokHome: home, config: config, environment: [:])
        let blockingRefresher = BlockingTeamPinRefresher()
        await owner.configureRefresher(blockingRefresher)
        let contenderExchangeCount = CallCounter()
        await contender.configureRefresher(MockTokenRefresher(
            outcome: .success(teamPinTestSession(principal: "team-required")),
            callCount: contenderExchangeCount
        ))
        let ownerRequest = Task {
            try await owner.auth()
        }
        await blockingRefresher.waitUntilStarted()

        do {
            let auth = try await contender.auth()
            Issue.record("lock contender unexpectedly authenticated: \(auth.authMode)")
        } catch let error as AuthError {
            #expect(error == .tokenExpiredNoRefresh)
        }
        #expect(contenderExchangeCount.count == 0)

        var rotated = teamPinTestSession(principal: "team-required")
        rotated.refreshToken = "rotated-successor"
        await blockingRefresher.finish(.success(rotated))
        let ownerCredential = try await ownerRequest.value
        #expect(ownerCredential.key == rotated.key)

        let adopted = try await contender.auth()
        #expect(adopted.key == rotated.key)
        #expect(contenderExchangeCount.count == 0)
        #expect(try readAuthJSON(at: home.appendingPathComponent("auth.json"))[
            config.authScope
        ]?.refreshToken == "rotated-successor")
    }

    @Test("cancellation after refresh-token exchange still durably saves the rotated successor")
    func cancelledInflightRefreshPersistsRotatedSuccessor() async throws {
        let home = try teamPinTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = teamPinTestConfig()
        let manager = AuthManager(grokHome: home, config: config, environment: [:])
        let expired = teamPinTestSession(principal: "team-required", expired: true)
        try await manager.update(expired)
        let refresher = BlockingTeamPinRefresher()
        await manager.configureRefresher(refresher)
        var rotated = teamPinTestSession(principal: "team-required")
        rotated.refreshToken = "durably-rotated-refresh-token"
        let request = Task {
            try await manager.auth()
        }
        await refresher.waitUntilStarted()

        request.cancel()
        await refresher.finish(.success(rotated))

        do {
            let auth = try await request.value
            Issue.record("cancelled caller unexpectedly received \(auth.authMode)")
        } catch is CancellationError {
            // The caller is cancelled only after the exchanged successor is durable.
        }

        let stored = try readAuthJSON(at: home.appendingPathComponent("auth.json"))[
            config.authScope
        ]
        #expect(stored?.key == rotated.key)
        #expect(stored?.refreshToken == "durably-rotated-refresh-token")
        #expect(manager.snapshotBox.read().token == rotated.key)
    }

    @Test("a refresh whose successor cannot be persisted never reports in-memory-only success")
    func persistenceFailureDoesNotPublishRotatedCredential() async throws {
        let home = try teamPinTestHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let authPath = home.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: authPath, withIntermediateDirectories: false)
        let manager = AuthManager(grokHome: home, config: teamPinTestConfig(), environment: [:])
        let expired = teamPinTestSession(principal: "team-required", expired: true)
        await manager.hotSwap(expired)
        var rotated = teamPinTestSession(principal: "team-required")
        rotated.refreshToken = "must-not-be-published-without-disk"
        await manager.configureRefresher(MockTokenRefresher(outcome: .success(rotated)))

        do {
            let auth = try await manager.auth()
            Issue.record("non-durable refresh unexpectedly succeeded: \(auth.authMode)")
        } catch let error as AuthError {
            guard case .storage = error else {
                Issue.record("unexpected persistence failure: \(error)")
                return
            }
        }

        #expect(await manager.currentOrExpired()?.refreshToken == expired.refreshToken)
        #expect(manager.snapshotBox.read().token == expired.key)
        #expect(FileManager.default.fileExists(atPath: authPath.path))
    }
}
