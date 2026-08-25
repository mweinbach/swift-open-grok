import Foundation
import OpenGrokAuth
import OpenGrokModels
import Testing
@testable import OpenGrokProviderSession

private struct ManagedCredentialFixture {
    let root: URL
    let home: URL
    let environment: [String: String]

    init(extraEnvironment: [String: String] = [:]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "open-grok-managed-credential-\(UUID().uuidString)"
        )
        home = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var values = extraEnvironment
        values["HOME"] = root.path
        values["OPENGROK_HOME"] = home.path
        environment = values
    }

    var authFile: URL {
        home.appendingPathComponent(OpenGrokAuthPaths.authFileName)
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func configuration(
        apiKeysDisabled: Bool = true,
        team: ForceLoginTeam? = nil
    ) -> GrokComConfig {
        var config = GrokComConfig.default(environment: environment)
        config.disableAPIKeyAuth = apiKeysDisabled
        config.forceLoginTeamUUID = team
        return config
    }

    func resolver(config: GrokComConfig) -> LiveCredentialResolver {
        LiveCredentialResolver(
            environment: environment,
            openGrokHome: home,
            grokComConfig: config
        )
    }

    func storeSession(
        actualPrincipal: String,
        reportedTeam: String? = nil,
        config: GrokComConfig
    ) throws -> String {
        let token = buildTestJWT(payload: [
            "principal_type": teamPrincipalType,
            "principal_id": actualPrincipal,
            "team_id": actualPrincipal,
            "exp": Int(Date().addingTimeInterval(3600).timeIntervalSince1970),
        ])
        let auth = GrokAuth(
            key: token,
            authMode: .oidc,
            principalType: teamPrincipalType,
            principalID: reportedTeam ?? actualPrincipal,
            teamID: reportedTeam ?? actualPrincipal,
            expiresAt: Date().addingTimeInterval(3600)
        )
        try writeAuthJSON(at: authFile, store: [config.authScope: auth])
        return token
    }
}

@Suite("Managed xAI credential policy parity")
struct LiveCredentialManagedPolicyParityTests {
    @Test("managed policy blocks both environment aliases and model-explicit xAI API keys")
    func managedPolicyBlocksEnvironmentAndExplicitAPIKeys() async throws {
        for environmentKey in ["XAI_API_KEY", "GROK_CODE_XAI_API_KEY"] {
            let fixture = try ManagedCredentialFixture(extraEnvironment: [
                environmentKey: "private-disallowed-environment-key",
                "GROK_DISABLE_API_KEY_AUTH": "false",
            ])
            defer { fixture.dispose() }
            let resolver = fixture.resolver(config: fixture.configuration())

            await #expect(throws: LiveCredentialError.self) {
                let credential = try await resolver.resolve(
                    provider: .xai,
                    explicitAPIKey: "private-disallowed-explicit-key",
                    baseURL: "https://api.x.ai/v1",
                    scope: "managed-policy:test"
                )
                Issue.record("administrator policy exported \(credential.source.rawValue)")
            }

            #expect(!resolver.hasStoredCredential(for: .xai))
            #expect(!FileManager.default.fileExists(atPath: fixture.authFile.path))
        }
    }

    @Test("managed policy blocks an existing stored xAI API key without deleting its file")
    func managedPolicyBlocksStoredAPIKey() async throws {
        let fixture = try ManagedCredentialFixture()
        defer { fixture.dispose() }
        try storeAPIKey(grokHome: fixture.home, apiKey: "private-disallowed-stored-key")
        let resolver = fixture.resolver(config: fixture.configuration())

        await #expect(throws: LiveCredentialError.self) {
            let credential = try await resolver.resolve(
                provider: .xai,
                baseURL: "https://api.x.ai/v1",
                scope: "managed-policy:test"
            )
            Issue.record("administrator policy exported \(credential.source.rawValue)")
        }

        #expect(!resolver.hasStoredCredential(for: .xai))
        #expect(FileManager.default.fileExists(atPath: fixture.authFile.path))
    }

    @Test("a compliant signed team session replaces forbidden explicit and environment keys")
    func matchingSignedTeamSessionWinsOverForbiddenKeys() async throws {
        let fixture = try ManagedCredentialFixture(extraEnvironment: [
            "XAI_API_KEY": "private-disallowed-environment-key",
            "GROK_DISABLE_API_KEY_AUTH": "false",
        ])
        defer { fixture.dispose() }
        let config = fixture.configuration(team: .single("approved-team"))
        let token = try fixture.storeSession(actualPrincipal: "approved-team", config: config)
        let resolver = fixture.resolver(config: config)

        let credential = try await resolver.resolve(
            provider: .xai,
            explicitAPIKey: "private-disallowed-explicit-key",
            baseURL: "https://api.x.ai/v1",
            scope: "managed-policy:test"
        )

        #expect(credential.source == .storedSession)
        #expect(credential.bearer == token)
        #expect(resolver.hasStoredCredential(for: .xai))
    }

    @Test("forged auth.json team metadata cannot override the signed access-token principal")
    func tokenPrincipalWinsOverForgedTeamMetadata() async throws {
        let fixture = try ManagedCredentialFixture()
        defer { fixture.dispose() }
        let config = fixture.configuration(team: .single("approved-team"))
        let wrongToken = try fixture.storeSession(
            actualPrincipal: "attacker-team",
            reportedTeam: "approved-team",
            config: config
        )
        #expect(try readAuthJSON(at: fixture.authFile)[config.authScope]?.key == wrongToken)
        let resolver = fixture.resolver(config: config)

        await #expect(throws: LiveCredentialError.self) {
            let credential = try await resolver.resolve(
                provider: .xai,
                baseURL: "https://api.x.ai/v1",
                scope: "managed-policy:test"
            )
            Issue.record("administrator policy exported the forged principal \(credential.source.rawValue)")
        }

        #expect(!resolver.hasStoredCredential(for: .xai))
    }

    @Test("an empty administrator team list fails closed for existing sessions")
    func emptyManagedTeamListRejectsEverySession() async throws {
        let fixture = try ManagedCredentialFixture()
        defer { fixture.dispose() }
        let config = fixture.configuration(team: .anyOf([]))
        let token = try fixture.storeSession(actualPrincipal: "otherwise-valid-team", config: config)
        #expect(try readAuthJSON(at: fixture.authFile)[config.authScope]?.key == token)
        let resolver = fixture.resolver(config: config)

        await #expect(throws: LiveCredentialError.self) {
            let credential = try await resolver.resolve(
                provider: .xai,
                baseURL: "https://api.x.ai/v1",
                scope: "managed-policy:test"
            )
            Issue.record("empty team policy exported \(credential.source.rawValue)")
        }

        #expect(!resolver.hasStoredCredential(for: .xai))
    }

    @Test("deployment credentials remain independent of the xAI account API-key policy")
    func deploymentCredentialRemainsAvailable() async throws {
        let fixture = try ManagedCredentialFixture(extraEnvironment: [
            "GROK_DEPLOYMENT_KEY": "private-deployment-key",
            "XAI_API_KEY": "private-disallowed-account-key",
        ])
        defer { fixture.dispose() }
        let config = fixture.configuration(team: .anyOf([]))
        let resolver = fixture.resolver(config: config)

        let credential = try await resolver.resolve(
            provider: .xai,
            explicitAPIKey: "private-disallowed-explicit-key",
            baseURL: "https://api.x.ai/v1",
            scope: "managed-policy:test"
        )

        #expect(credential.source == .deploymentKey)
        #expect(credential.bearer == "private-deployment-key")
        #expect(resolver.hasStoredCredential(for: .xai))
    }

    @Test("independent providers and explicit custom-host BYOK remain unaffected")
    func managedXAIPolicyPreservesOtherProvidersAndCustomBYOK() async throws {
        let fixture = try ManagedCredentialFixture()
        defer { fixture.dispose() }
        let resolver = fixture.resolver(
            config: fixture.configuration(team: .single("approved-team"))
        )

        let kimi = try await resolver.resolve(
            provider: .kimi,
            explicitAPIKey: "private-independent-kimi-key",
            baseURL: "https://api.moonshot.ai/v1",
            scope: "managed-policy:kimi"
        )
        let custom = try await resolver.resolve(
            provider: .xai,
            explicitAPIKey: "private-custom-endpoint-key",
            baseURL: "https://independent.example.test/v1",
            scope: "managed-policy:custom"
        )

        #expect(kimi.source == .explicitAPIKey)
        #expect(kimi.bearer == "private-independent-kimi-key")
        #expect(custom.source == .explicitAPIKey)
        #expect(custom.bearer == "private-custom-endpoint-key")
    }
}
