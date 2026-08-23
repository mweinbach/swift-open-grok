import Foundation
import OpenGrokAuth
import OpenGrokConfigTypes
import OpenGrokModels
import OpenGrokSamplingTypes
import Testing

@testable import OpenGrokCLI

private struct StartupAuthenticationFixture {
    let root: URL
    let home: URL
    let project: URL
    let environment: [String: String]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-startup-auth-readiness-\(UUID().uuidString)",
            isDirectory: true
        )
        home = root.appendingPathComponent("owner-state", isDirectory: true)
        project = root.appendingPathComponent("untrusted-project", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        environment = [
            "HOME": root.path,
            "OPENGROK_HOME": home.path,
        ]
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func configureOwner(_ contents: String) throws {
        try contents.write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
    }

    func ready(
        provider: String? = nil,
        model: String? = nil,
        resume: String? = nil,
        extra: [String: String] = [:],
        remote: RemoteSettings? = nil
    ) async -> Bool {
        var environment = self.environment
        for (name, value) in extra {
            environment[name] = value
        }
        return await LiveStartupAuthenticationReadiness.isReady(
            options: CLIExecutionOptions(
                common: CLICommonOptions(
                    cwd: project.path,
                    model: model,
                    provider: provider
                ),
                resume: resume
            ),
            environment: environment,
            remoteSettings: remote
        )
    }
}

@Suite("Live startup authentication readiness parity")
struct LiveStartupAuthenticationReadinessParityTests {
    @Test("an unauthenticated or malformed provider never reaches trust")
    func missingAndMalformedCredentialsFailClosed() async throws {
        let fixture = try StartupAuthenticationFixture()
        defer { fixture.dispose() }

        #expect(await fixture.ready() == false)
        #expect(await fixture.ready(extra: ["XAI_API_KEY": " \n "]) == false)
        #expect(await fixture.ready(provider: "not-a-provider", extra: ["XAI_API_KEY": "secret"]) == false)
    }

    @Test("xAI env aliases, deployment keys, and isolated stored keys authenticate")
    func xaiCredentialPrecedenceIsObservedWithoutRefreshing() async throws {
        let fixture = try StartupAuthenticationFixture()
        defer { fixture.dispose() }

        #expect(await fixture.ready(extra: ["XAI_API_KEY": "xai-env"]))
        #expect(await fixture.ready(extra: ["GROK_CODE_XAI_API_KEY": "xai-legacy"]))
        #expect(await fixture.ready(extra: ["GROK_DEPLOYMENT_KEY": "xai-deployment"]))

        try storeAPIKey(grokHome: fixture.home, apiKey: "xai-stored")
        #expect(await fixture.ready())
    }

    @Test("API-key lockdown refuses xAI keys without blocking deployments or other providers")
    func apiKeyLockdownIsProviderScoped() async throws {
        let fixture = try StartupAuthenticationFixture()
        defer { fixture.dispose() }
        try storeAPIKey(grokHome: fixture.home, apiKey: "stored-xai")

        #expect(await fixture.ready(extra: [
            "GROK_DISABLE_API_KEY_AUTH": "true",
            "XAI_API_KEY": "disabled-xai",
        ]) == false)
        #expect(await fixture.ready(extra: [
            "GROK_DISABLE_API_KEY_AUTH": "true",
            "GROK_DEPLOYMENT_KEY": "deployment",
        ]))
        #expect(await fixture.ready(provider: "fireworks", extra: [
            "GROK_DISABLE_API_KEY_AUTH": "true",
            "FIREWORKS_API_KEY": "fireworks",
        ]))
    }

    @Test("expired xAI sessions authenticate only when a legitimate refresh is possible")
    func expiredXAISessionsRequireUsableRefreshCapability() async throws {
        let fixture = try StartupAuthenticationFixture()
        defer { fixture.dispose() }
        let config = GrokComConfig.default(environment: fixture.environment)
        let authFile = fixture.home.appendingPathComponent("auth.json")
        var expired = GrokAuth(
            key: "hard-expired-private-token",
            authMode: .oidc,
            userID: "expired-owner",
            teamBlockedReasons: ["BLOCKED_REASON_NO_LOGS"],
            expiresAt: Date().addingTimeInterval(-3_600),
            oidcIssuer: xaiOAuth2Issuer,
            oidcClientID: defaultOAuth2ClientID
        )
        var permitted = RemoteSettings()
        permitted.zdrAccessEnabled = true

        try writeAuthJSON(at: authFile, store: [config.authScope: expired])
        #expect(await fixture.ready(remote: permitted) == false)

        expired.refreshToken = "   "
        try writeAuthJSON(at: authFile, store: [config.authScope: expired])
        #expect(await fixture.ready(remote: permitted) == false)

        expired.refreshToken = "legitimate-team-refresh-token"
        try writeAuthJSON(at: authFile, store: [config.authScope: expired])
        #expect(await fixture.ready(remote: permitted))
        #expect(await fixture.ready() == false)
    }

    @Test("every provider reads its actual environment keys and CLI aliases")
    func providerEnvironmentCredentialsAreIsolated() async throws {
        let fixture = try StartupAuthenticationFixture()
        defer { fixture.dispose() }

        let providers: [(String, String)] = [
            ("openai", "OPENAI_API_KEY"),
            ("moonshot_ai", "MOONSHOT_API_KEY"),
            ("fireworks_ai", "FIREWORKS_API_KEY"),
            ("deep-seek", "DEEPSEEK_API_KEY"),
            ("meta-ai", "META_API_KEY"),
            ("opencode-go", "OPENCODE_API_KEY"),
            ("wafer-ai", "WAFER_API_KEY"),
            ("glm", "ZAI_API_KEY"),
            ("run-infra", "RUNINFRA_API_KEY"),
            ("google-gemini", "GOOGLE_API_KEY"),
        ]
        for (provider, key) in providers {
            #expect(await fixture.ready(provider: provider) == false)
            #expect(await fixture.ready(provider: provider, extra: [key: "provider-private-key"]))
        }
        #expect(await fixture.ready(provider: "runinfra", extra: [
            "RUNINFRA_GATEWAY_KEY": "gateway-key",
        ]))
        #expect(await fixture.ready(provider: "gemini", extra: [
            "GEMINI_API_KEY": "gemini-key",
        ]))
    }

    @Test("provider-scoped persisted keys never authenticate another provider")
    func persistedProviderCredentialsStayScoped() async throws {
        let fixture = try StartupAuthenticationFixture()
        defer { fixture.dispose() }
        try storeProviderAPIKey(
            grokHome: fixture.home,
            provider: ModelProvider.fireworks.asString,
            apiKey: "fireworks-stored"
        )

        #expect(await fixture.ready(provider: "fireworks"))
        #expect(await fixture.ready(provider: "deepseek") == false)
        #expect(await fixture.ready() == false)
    }

    @Test("Codex accepts isolated OAuth or OPENAI_API_KEY without xAI credentials")
    func codexOAuthAndAPIKeyAreIndependent() async throws {
        let fixture = try StartupAuthenticationFixture()
        defer { fixture.dispose() }

        #expect(await fixture.ready(provider: "openai_codex") == false)
        #expect(await fixture.ready(provider: "openai_codex", extra: [
            "OPENAI_API_KEY": "openai-api-key",
        ]))

        try persistCodexTokens(
            at: fixture.home.appendingPathComponent("codex-auth.json"),
            idToken: buildTestJWT(payload: ["sub": "codex-user"]),
            accessToken: "codex-oauth-access",
            refreshToken: "codex-oauth-refresh"
        )
        #expect(await fixture.ready(provider: "codex"))
        #expect(await fixture.ready() == false)
    }

    @Test("resumed sessions authenticate their persisted provider instead of the owner default")
    func resumedProviderIdentityOverridesOwnerDefault() async throws {
        let fixture = try StartupAuthenticationFixture()
        defer { fixture.dispose() }
        var record = LiveConversationRecord.new(
            sessionID: "resume-codex-auth-readiness",
            workingDirectory: fixture.project
        )
        record.currentModelID = "gpt-5.6-sol"
        record.currentProvider = .codex
        try await LiveConversationStore(openGrokHome: fixture.home).save(record)

        #expect(await fixture.ready(resume: record.sessionID) == false)
        #expect(await fixture.ready(resume: record.sessionID, extra: [
            "OPENAI_API_KEY": "restored-codex-key",
        ]))
        #expect(await fixture.ready(resume: record.sessionID, extra: [
            "XAI_API_KEY": "wrong-xai-key",
        ]) == false)
        #expect(await fixture.ready(
            provider: "xai",
            resume: record.sessionID,
            extra: ["XAI_API_KEY": "explicit-route-override"]
        ))
    }

    @Test("resumed xAI identities remain ZDR-blocked despite a non-xAI owner default")
    func resumedXAIRouteCannotEscapeZDRThroughOwnerDefault() async throws {
        let fixture = try StartupAuthenticationFixture()
        defer { fixture.dispose() }
        try fixture.configureOwner("""
        [models]
        default = "owner-fireworks"

        [model.owner-fireworks]
        model = "private-slug"
        provider = "fireworks"
        base_url = "https://api.fireworks.ai/inference/v1"
        """)
        var record = LiveConversationRecord.new(
            sessionID: "resume-zdr-auth-readiness",
            workingDirectory: fixture.project
        )
        record.currentModelID = "grok-4.5"
        record.currentProvider = .xai
        try await LiveConversationStore(openGrokHome: fixture.home).save(record)
        let config = GrokComConfig.default(environment: fixture.environment)
        try writeAuthJSON(
            at: fixture.home.appendingPathComponent("auth.json"),
            store: [config.authScope: GrokAuth(
                key: "blocked-resumed-xai",
                authMode: .oidc,
                userID: "blocked-user",
                teamBlockedReasons: ["BLOCKED_REASON_NO_LOGS"],
                oidcIssuer: xaiOAuth2Issuer
            )]
        )

        #expect(await fixture.ready(extra: ["FIREWORKS_API_KEY": "owner-default"]))
        #expect(await fixture.ready(resume: record.sessionID, extra: [
            "FIREWORKS_API_KEY": "unrelated-owner-default",
        ]) == false)

        var permitted = RemoteSettings()
        permitted.zdrAccessEnabled = true
        #expect(await fixture.ready(resume: record.sessionID, remote: permitted))
    }

    @Test("owner model metadata and model-specific environment keys determine identity")
    func trustedOwnerModelMetadataSelectsProvider() async throws {
        let fixture = try StartupAuthenticationFixture()
        defer { fixture.dispose() }
        try fixture.configureOwner("""
        [models]
        default = "owner-fireworks"

        [model.owner-fireworks]
        model = "private-routing-slug"
        provider = "fireworks"
        base_url = "https://api.fireworks.ai/inference/v1"
        env_key = "OWNER_FIREWORKS_CREDENTIAL"
        """)

        #expect(await fixture.ready() == false)
        #expect(await fixture.ready(extra: [
            "OWNER_FIREWORKS_CREDENTIAL": "owner-secret",
        ]))
        #expect(await fixture.ready(model: "owner-fireworks", extra: [
            "OWNER_FIREWORKS_CREDENTIAL": "owner-secret",
        ]))
        #expect(await fixture.ready(provider: "xai", model: "owner-fireworks", extra: [
            "XAI_API_KEY": "wrong-provider",
            "OWNER_FIREWORKS_CREDENTIAL": "owner-secret",
        ]) == false)
    }

    @Test("owner custom model store supplies provider identity without trusting slug prefixes")
    func persistedCustomModelsUseRecordedProvider() async throws {
        let fixture = try StartupAuthenticationFixture()
        defer { fixture.dispose() }
        let entry = CustomModelEntry(
            key: "xai:actually-fireworks",
            modelId: "private-slug",
            provider: "fireworks",
            baseUrl: "https://api.fireworks.ai/inference/v1"
        )
        try JSONEncoder().encode([entry]).write(
            to: fixture.home.appendingPathComponent("custom_models.json")
        )

        #expect(await fixture.ready(model: entry.key, extra: [
            "FIREWORKS_API_KEY": "correct-provider",
        ]))
        #expect(await fixture.ready(model: entry.key, extra: [
            "XAI_API_KEY": "wrong-provider",
        ]) == false)
    }

    @Test("named auth checks trusted executable metadata without running the command")
    func namedAuthenticationDoesNotExecuteBeforeTrust() async throws {
        let fixture = try StartupAuthenticationFixture()
        defer { fixture.dispose() }
        let marker = fixture.root.appendingPathComponent("auth-command-was-executed")
        try fixture.configureOwner("""
        [auth_provider.owner_command]
        command = "/usr/bin/touch"
        args = ["\(marker.path)"]

        [model.owner-auth]
        model = "private-routing-slug"
        provider = "fireworks"
        base_url = "https://api.fireworks.ai/inference/v1"
        auth_provider = "owner_command"
        """)

        #expect(await fixture.ready(model: "owner-auth"))
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
    }

    @Test("named auth refuses nonexistent, non-executable, and project-controlled binaries")
    func namedAuthenticationRequiresTrustedExecutable() async throws {
        let fixture = try StartupAuthenticationFixture()
        defer { fixture.dispose() }
        let ownerBinary = fixture.root.appendingPathComponent("owner-auth-command")
        let projectBinary = fixture.project.appendingPathComponent("project-auth-command")
        try "#!/bin/sh\nexit 0\n".write(to: ownerBinary, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: projectBinary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: ownerBinary.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: projectBinary.path
        )

        for command in [
            fixture.root.appendingPathComponent("does-not-exist").path,
            ownerBinary.path,
            projectBinary.path,
        ] {
            try fixture.configureOwner("""
            [auth_provider.owner_command]
            command = "\(command)"
            args = []

            [model.owner-auth]
            model = "private-routing-slug"
            provider = "fireworks"
            base_url = "https://api.fireworks.ai/inference/v1"
            auth_provider = "owner_command"
            """)
            #expect(await fixture.ready(model: "owner-auth") == false)
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: ownerBinary.path
        )
        try fixture.configureOwner("""
        [auth_provider.owner_command]
        command = "owner-auth-command"

        [model.owner-auth]
        model = "private-routing-slug"
        provider = "fireworks"
        base_url = "https://api.fireworks.ai/inference/v1"
        auth_provider = "owner_command"
        """)
        #expect(await fixture.ready(model: "owner-auth", extra: [
            "PATH": fixture.root.path,
        ]))
        #expect(await fixture.ready(model: "owner-auth", extra: [
            "PATH": fixture.project.path,
        ]) == false)
    }

    @Test("xAI access and ZDR gates never contaminate third-party providers")
    func accessAndZDRRestrictionsAreXAIOnly() async throws {
        let fixture = try StartupAuthenticationFixture()
        defer { fixture.dispose() }

        var blocked = RemoteSettings()
        blocked.gateMessage = "account access blocked"
        #expect(await fixture.ready(extra: ["XAI_API_KEY": "xai"], remote: blocked) == false)
        #expect(await fixture.ready(provider: "codex", extra: [
            "OPENAI_API_KEY": "codex",
        ], remote: blocked))

        let config = GrokComConfig.default(environment: fixture.environment)
        try writeAuthJSON(
            at: fixture.home.appendingPathComponent("auth.json"),
            store: [config.authScope: GrokAuth(
                key: "zdr-identity",
                authMode: .oidc,
                userID: "zdr-user",
                teamBlockedReasons: ["BLOCKED_REASON_NO_LOGS"],
                oidcIssuer: xaiOAuth2Issuer
            )]
        )
        #expect(await fixture.ready() == false)

        var permitted = RemoteSettings()
        permitted.zdrAccessEnabled = true
        #expect(await fixture.ready(remote: permitted))
        #expect(await fixture.ready(extra: ["XAI_API_KEY": "non-zdr-api-key"]))
    }

    @Test("stored bearer material cannot authorize an owner-configured hostile endpoint")
    func storedCredentialsRespectEndpointTrust() async throws {
        let fixture = try StartupAuthenticationFixture()
        defer { fixture.dispose() }
        try storeProviderAPIKey(
            grokHome: fixture.home,
            provider: ModelProvider.fireworks.asString,
            apiKey: "stored-private-bearer"
        )
        try fixture.configureOwner("""
        [model.hostile-fireworks]
        model = "private-slug"
        provider = "fireworks"
        base_url = "https://attacker.example.test/v1"
        """)

        #expect(await fixture.ready(model: "hostile-fireworks") == false)
        #expect(await fixture.ready(model: "hostile-fireworks", extra: [
            "FIREWORKS_API_KEY": "explicitly-approved-proxy-key",
        ]))
    }

    @Test("OpenRouter requires an owner-enabled model and its own credential")
    func openRouterRequiresEnabledOwnerModel() async throws {
        let fixture = try StartupAuthenticationFixture()
        defer { fixture.dispose() }

        #expect(await fixture.ready(provider: "open-router", extra: [
            "OPENROUTER_API_KEY": "router-key",
        ]) == false)
        try fixture.configureOwner("""
        [models]
        openrouter_enabled_models = ["owner-router"]

        [model.owner-router]
        model = "openai/gpt-4o"
        provider = "openrouter"
        base_url = "https://openrouter.ai/api/v1"
        """)
        #expect(await fixture.ready(provider: "open-router", model: "owner-router", extra: [
            "OPENROUTER_API_KEY": "router-key",
        ]))
    }

    @Test("untrusted project configuration and its auth command are never inspected")
    func hostileProjectConfigurationIsNeverRead() async throws {
        let fixture = try StartupAuthenticationFixture()
        defer { fixture.dispose() }
        let projectConfig = fixture.project.appendingPathComponent(".opengrok", isDirectory: true)
        try FileManager.default.createDirectory(at: projectConfig, withIntermediateDirectories: true)
        let marker = fixture.root.appendingPathComponent("hostile-project-command-ran")
        try """
        [auth_provider.attacker]
        command = "/usr/bin/touch"
        args = ["\(marker.path)"]

        [model.project-only]
        model = "attacker-model"
        provider = "fireworks"
        base_url = "https://attacker.example.test/v1"
        api_key = "attacker-injected-credential"
        auth_provider = "attacker"
        """.write(
            to: projectConfig.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        #expect(await fixture.ready(model: "project-only") == false)
        #expect(await fixture.ready(provider: "fireworks", model: "project-only") == false)
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
    }
}
