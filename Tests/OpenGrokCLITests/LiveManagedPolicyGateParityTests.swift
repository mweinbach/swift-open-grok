import Foundation
import OpenGrokAuth
import OpenGrokCLIChatProxyTypes
import OpenGrokConfig
import OpenGrokFileUtils
import OpenGrokHTTP
import OpenGrokSamplingTypes
import Testing
@testable import OpenGrokCLI

#if canImport(CryptoKit)
import CryptoKit
#endif

private final class ManagedPolicyGateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func record(_ value: String) {
        lock.withLock { values.append(value) }
    }

    var recorded: [String] {
        lock.withLock { values }
    }
}

private final class ManagedPolicyGateTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [HTTPResponse]
    private var requests: [HTTPRequest] = []

    init(responses: [HTTPResponse]) {
        self.responses = responses
    }

    var capturedRequests: [HTTPRequest] {
        lock.withLock { requests }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try lock.withLock {
            requests.append(request)
            guard !responses.isEmpty else {
                throw CLIApplicationError.failed("unexpected policy request")
            }
            return responses.removeFirst()
        }
    }

    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<HTTPStreamEvent, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }
}

private struct ManagedPolicyGateFixture {
    let root: URL
    let home: URL
    let workspace: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "open-grok-managed-policy-gate-\(UUID().uuidString)"
        )
        home = root.appendingPathComponent("state")
        workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    var environment: [String: String] {
        [
            "HOME": root.path,
            "OPENGROK_HOME": home.path,
            "GROK_SANDBOX": "off",
            "GROK_DEPLOYMENT_CONFIG_BACKOFF_MS": "0",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func team(
        id: String = "team-owned",
        key: String = "private-team-session-token",
        expiresAt: Date? = Date().addingTimeInterval(3_600)
    ) -> GrokAuth {
        GrokAuth(
            key: key,
            authMode: .oidc,
            createTime: Date(),
            principalType: teamPrincipalType,
            teamID: id,
            expiresAt: expiresAt
        )
    }

    func writeAuth(_ auth: GrokAuth) throws {
        try writeAuthJSON(
            at: home.appendingPathComponent("auth.json"),
            store: ["live-managed-policy-principal": auth]
        )
    }

    func inlineAuth(_ auth: GrokAuth) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(auth), as: UTF8.self)
    }

    #if canImport(CryptoKit)
    func signedPolicyResponse(
        signingKey: Curve25519.Signing.PrivateKey,
        teamID: String = "team-owned",
        managed: String = "[permission]\nmode = \"default\"\n"
    ) throws -> HTTPResponse {
        let keyID = "managed-gate-refresh-signing-key"
        let payload = SignedPayload(
            typ: managedPolicyTyp,
            version: signedPayloadVersion,
            deploymentId: nil,
            teamId: teamID,
            managedConfig: managed,
            requirements: "fail_closed = true\n",
            failClosed: true,
            expiresAt: UInt64(Date().addingTimeInterval(3_600).timeIntervalSince1970),
            keyId: keyID
        )
        let encoded = try JSONEncoder().encode(payload)
        let signature = try signingKey.signature(for: encoded)
        return HTTPResponse(
            metadata: HTTPResponseMetadata(statusCode: 200),
            body: try JSONSerialization.data(withJSONObject: [
                "team_id": teamID,
                "managed_config": managed,
                "requirements": "fail_closed = true\n",
                "signatures": [[
                    "signed_payload": String(decoding: encoded, as: UTF8.self),
                    "signature": signature.base64EncodedString(),
                    "key_id": keyID,
                ]],
            ])
        )
    }
    #endif

    func writeMarker(
        principal: String? = "team-owned",
        fingerprint: String? = nil,
        managed: Bool = true,
        requirements: Bool = false,
        failClosed: Bool = true
    ) throws {
        let cache = ManagedConfigCache(
            syncedAt: UInt64(Date().timeIntervalSince1970),
            principal: principal,
            hadManagedConfig: managed,
            hadRequirements: requirements,
            keyFingerprint: fingerprint,
            failClosed: failClosed,
            rollbackFloor: UInt64(Date().timeIntervalSince1970)
        )
        try JSONEncoder().encode(cache).write(to: home.appendingPathComponent(MANAGED_CONFIG_CACHE_FILE))
    }

    func write(_ contents: String, filename: String) throws {
        try contents.write(
            to: home.appendingPathComponent(filename),
            atomically: true,
            encoding: .utf8
        )
    }

    func noHealing(recorder: ManagedPolicyGateRecorder? = nil) -> LiveManagedPolicyGateServices {
        LiveManagedPolicyGateServices(timeoutNanoseconds: 1_000_000_000) { _ in
            recorder?.record("heal")
            return false
        }
    }

    func requireRefusal(
        environment: [String: String]? = nil,
        services: LiveManagedPolicyGateServices? = nil
    ) async {
        do {
            try await LiveManagedPolicyGate.enforce(
                environment: environment ?? self.environment,
                services: services ?? noHealing()
            )
            Issue.record("compromised managed policy unexpectedly admitted session startup")
        } catch let error as CLIApplicationError {
            #expect(error == .failed(LiveManagedPolicyGate.missingPolicyMessage))
        } catch {
            Issue.record("expected a typed managed-policy refusal, got \(error)")
        }
    }

    func requireLauncherRefusal(
        environment: [String: String],
        recorder: ManagedPolicyGateRecorder = ManagedPolicyGateRecorder()
    ) async throws {
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                recorder.record("sampler")
                return OpenGrokLiveSampler { _, _ in
                    OpenGrokLiveSamplingResponse(output: "must not run")
                }
            }
        )
        let command = try CLICommandParser.parseOrThrow([
            "headless", "--prompt", "blocked", "--cwd", workspace.path,
            "--model", "grok-4.5",
        ])
        let context = CLIApplicationContext(
            environment: environment,
            streams: CLIStreams(out: { _ in }, err: { _ in }),
            control: .never
        )
        do {
            let session = try await OpenGrokLiveApplicationLauncher(dependencies: dependencies)
                .launcher.start(command, context)
            await session.shutdown()
            Issue.record("the actual launcher admitted compromised administrator policy")
        } catch let error as CLIApplicationError {
            #expect(error == .failed(LiveManagedPolicyGate.missingPolicyMessage))
        }
        #expect(recorder.recorded.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("sessions").path))
    }
}

@Suite("Managed policy session-start enforcement parity", .serialized)
struct LiveManagedPolicyGateParityTests {
    @Test("an unauthenticated personal installation never fetches or blocks")
    func personalInstallationStaysOffline() async throws {
        let fixture = try ManagedPolicyGateFixture()
        defer { fixture.dispose() }
        let recorder = ManagedPolicyGateRecorder()
        try fixture.writeMarker(principal: "former-team")

        try await LiveManagedPolicyGate.enforce(
            environment: fixture.environment,
            services: fixture.noHealing(recorder: recorder)
        )

        #expect(recorder.recorded.isEmpty)
        #expect(LiveManagedPolicyGate.servingIdentity(environment: fixture.environment) == .none)
    }

    @Test("plain xAI API keys do not become enterprise policy principals")
    func APIKeyOnlyUserNeverFetchesPolicy() async throws {
        let fixture = try ManagedPolicyGateFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(GrokAuth(key: "personal-xai-key", authMode: .apiKey))
        try fixture.writeMarker(principal: "former-team")
        let recorder = ManagedPolicyGateRecorder()

        try await LiveManagedPolicyGate.enforce(
            environment: fixture.environment,
            services: fixture.noHealing(recorder: recorder)
        )

        #expect(recorder.recorded.isEmpty)
    }

    @Test("expired team tokens remain managed principals and cannot disarm policy")
    func expiredTeamIdentityRemainsEnforced() async throws {
        let fixture = try ManagedPolicyGateFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(fixture.team(expiresAt: Date().addingTimeInterval(-3_600)))
        try fixture.writeMarker()

        #expect(LiveManagedPolicyGate.servingIdentity(environment: fixture.environment) == .team("team-owned"))
        await fixture.requireRefusal()
    }

    @Test("personal OAuth identities remain outside enterprise enforcement")
    func personalOAuthDoesNotBecomeTeamPrincipal() async throws {
        let fixture = try ManagedPolicyGateFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(GrokAuth(key: "personal-session", authMode: .oidc, userID: "personal"))
        try fixture.writeMarker(principal: "former-team")

        try await LiveManagedPolicyGate.enforce(
            environment: fixture.environment,
            services: fixture.noHealing()
        )
        #expect(LiveManagedPolicyGate.servingIdentity(environment: fixture.environment) == .none)
    }

    @Test("an inline managed team cannot bypass the actual fail-closed session launcher")
    func inlineTeamOverrideIsEnforcedByActualLauncher() async throws {
        let fixture = try ManagedPolicyGateFixture()
        defer { fixture.dispose() }
        try fixture.writeMarker()
        try fixture.write("[features]\nremote_fetch = false\n", filename: "config.toml")
        var environment = fixture.environment
        environment["OPENGROK_AUTH"] = try fixture.inlineAuth(fixture.team())

        #expect(LiveManagedPolicyGate.servingIdentity(environment: environment) == .team("team-owned"))
        try await fixture.requireLauncherRefusal(environment: environment)
    }

    @Test("an explicit managed auth path cannot bypass the actual fail-closed session launcher")
    func overriddenTeamAuthPathIsEnforcedByActualLauncher() async throws {
        let fixture = try ManagedPolicyGateFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(GrokAuth(key: "home-personal-key", authMode: .apiKey))
        try fixture.writeMarker()
        try fixture.write("[features]\nremote_fetch = false\n", filename: "config.toml")
        let override = fixture.root.appendingPathComponent("managed-override.json")
        try writeAuthJSON(at: override, store: ["override-team": fixture.team()])
        var environment = fixture.environment
        environment["OPENGROK_AUTH_PATH"] = override.path

        #expect(LiveManagedPolicyGate.servingIdentity(environment: environment) == .team("team-owned"))
        try await fixture.requireLauncherRefusal(environment: environment)
    }

    @Test("a valid personal inline identity outranks managed disk and path credentials")
    func personalInlineOverrideDoesNotInheritDiskTeam() async throws {
        let fixture = try ManagedPolicyGateFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(fixture.team())
        try fixture.writeMarker()
        let override = fixture.root.appendingPathComponent("override-team.json")
        try writeAuthJSON(at: override, store: ["path-team": fixture.team()])
        var environment = fixture.environment
        environment["OPENGROK_AUTH_PATH"] = override.path
        environment["OPENGROK_AUTH"] = try fixture.inlineAuth(
            GrokAuth(key: "inline-personal-key", authMode: .apiKey)
        )
        let recorder = ManagedPolicyGateRecorder()

        try await LiveManagedPolicyGate.enforce(
            environment: environment,
            services: fixture.noHealing(recorder: recorder)
        )

        #expect(LiveManagedPolicyGate.servingIdentity(environment: environment) == .none)
        #expect(recorder.recorded.isEmpty)
    }

    @Test("malformed inline and missing path overrides cannot downgrade enforced policy")
    func malformedAuthOverridesFailClosed() async throws {
        let fixture = try ManagedPolicyGateFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(GrokAuth(key: "disk-personal-key", authMode: .apiKey))
        try fixture.writeMarker()
        var inline = fixture.environment
        inline["OPENGROK_AUTH"] = "{broken-enterprise-override"
        await fixture.requireRefusal(environment: inline)

        var missingPath = fixture.environment
        missingPath["OPENGROK_AUTH_PATH"] = fixture.root
            .appendingPathComponent("missing-enterprise-auth.json").path
        await fixture.requireRefusal(environment: missingPath)

        try fixture.writeAuth(fixture.team())
        #expect(LiveManagedPolicyGate.servingIdentity(environment: inline) == .team("team-owned"))
        #expect(LiveManagedPolicyGate.servingIdentity(environment: missingPath) == .team("team-owned"))
        await fixture.requireRefusal(environment: inline)
        await fixture.requireRefusal(environment: missingPath)
    }

    @Test("deployment identity uses a full BLAKE3 fingerprint and outranks team OAuth")
    func deploymentIdentityOutranksTeam() throws {
        let fixture = try ManagedPolicyGateFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(fixture.team())
        var environment = fixture.environment
        environment["GROK_DEPLOYMENT_KEY"] = "deployment-private-secret"

        #expect(
            LiveManagedPolicyGate.servingIdentity(environment: environment)
                == .deploymentKey(fingerprint: Blake3.hexDigest(Array("deployment-private-secret".utf8)))
        )
    }

    @Test("owner configuration can provide an enterprise deployment principal")
    func ownerConfigDeploymentIdentity() throws {
        let fixture = try ManagedPolicyGateFixture()
        defer { fixture.dispose() }
        try fixture.write(
            "[endpoints]\ndeployment_key = \"owner-config-key\"\n",
            filename: "config.toml"
        )

        #expect(
            LiveManagedPolicyGate.servingIdentity(environment: fixture.environment)
                == .deploymentKey(fingerprint: Blake3.hexDigest(Array("owner-config-key".utf8)))
        )
    }

    @Test("malformed owner config cannot erase a managed deployment or bypass actual launch")
    func malformedOwnerConfigCannotEraseManagedDeploymentAuthority() async throws {
        let fixture = try ManagedPolicyGateFixture()
        defer { fixture.dispose() }
        let deploymentKey = "administrator-only-deployment-key"
        try fixture.write("[malformed owner config", filename: "config.toml")
        try fixture.write(
            "[endpoints]\ndeployment_key = \"\(deploymentKey)\"\n"
                + "[features]\nremote_fetch = false\n",
            filename: MANAGED_CONFIG_FILENAME
        )
        try fixture.writeMarker(
            principal: "administrator-deployment",
            fingerprint: Blake3.hexDigest(Array(deploymentKey.utf8)),
            requirements: true
        )

        #expect(
            LiveManagedPolicyGate.servingIdentity(environment: fixture.environment)
                == .deploymentKey(fingerprint: Blake3.hexDigest(Array(deploymentKey.utf8)))
        )
        try await fixture.requireLauncherRefusal(environment: fixture.environment)
    }

    @Test("a deployment-authenticated real launch survives missing or malformed team auth")
    func actualDeploymentLauncherIgnoresBrokenOptionalTeamSources() async throws {
        for source in ["missing-path", "malformed-home"] {
            let fixture = try ManagedPolicyGateFixture()
            defer { fixture.dispose() }
            let deploymentKey = "live-administrator-deployment-key"
            try fixture.write("[features]\nremote_fetch = false\n", filename: MANAGED_CONFIG_FILENAME)
            try fixture.writeMarker(
                principal: "administrator-deployment",
                fingerprint: Blake3.hexDigest(Array(deploymentKey.utf8))
            )
            var environment = fixture.environment
            environment["GROK_DEPLOYMENT_KEY"] = deploymentKey
            if source == "missing-path" {
                environment["OPENGROK_AUTH_PATH"] = fixture.root
                    .appendingPathComponent("absent-team.json").path
            } else {
                try fixture.write("{malformed-team-store", filename: "auth.json")
            }
            let recorder = ManagedPolicyGateRecorder()
            let dependencies = OpenGrokLiveCompositionDependencies(
                makeSampler: { configuration in
                    recorder.record(configuration.apiKey)
                    return OpenGrokLiveSampler { _, _ in
                        OpenGrokLiveSamplingResponse(output: "deployment launch admitted")
                    }
                }
            )
            let command = try CLICommandParser.parseOrThrow([
                "headless", "--prompt", "allowed", "--cwd", fixture.workspace.path,
                "--model", "grok-4.5",
            ])
            let context = CLIApplicationContext(
                environment: environment,
                streams: CLIStreams(out: { _ in }, err: { _ in }),
                control: .never
            )

            let session = try await OpenGrokLiveApplicationLauncher(dependencies: dependencies)
                .launcher.start(command, context)

            #expect(recorder.recorded == [deploymentKey])
            await session.shutdown()
        }
    }

    @Test("an unreadable auth store never bypasses a fail-closed missing artifact")
    func unreadableAuthStoreFailsSafe() async throws {
        let fixture = try ManagedPolicyGateFixture()
        defer { fixture.dispose() }
        try fixture.write("{not-valid-json", filename: "auth.json")
        try fixture.writeMarker()
        let recorder = ManagedPolicyGateRecorder()

        await fixture.requireRefusal(services: fixture.noHealing(recorder: recorder))
        #expect(recorder.recorded.isEmpty)
    }

    @Test("an intact same-team fail-closed cache stays usable offline without healing")
    func intactPolicyDoesNotDelayOfflineStartup() async throws {
        let fixture = try ManagedPolicyGateFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(fixture.team())
        try fixture.write("[features]\nmanaged = true\n", filename: MANAGED_CONFIG_FILENAME)
        try fixture.writeMarker()
        let recorder = ManagedPolicyGateRecorder()

        try await LiveManagedPolicyGate.enforce(
            environment: fixture.environment,
            services: fixture.noHealing(recorder: recorder)
        )

        #expect(recorder.recorded.isEmpty)
    }

    @Test("a missing artifact under an unenforced marker does not block offline access")
    func nonFailClosedMarkerDoesNotRefuse() async throws {
        let fixture = try ManagedPolicyGateFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(fixture.team())
        try fixture.writeMarker(failClosed: false)

        try await LiveManagedPolicyGate.enforce(
            environment: fixture.environment,
            services: fixture.noHealing()
        )
    }

    @Test("a rotated deployment key cannot reuse another deployment's enforced policy")
    func rotatedDeploymentKeyFailsClosed() async throws {
        let fixture = try ManagedPolicyGateFixture()
        defer { fixture.dispose() }
        try fixture.write("[features]\nmanaged = true\n", filename: MANAGED_CONFIG_FILENAME)
        try fixture.writeMarker(
            principal: "deployment-one",
            fingerprint: Blake3.hexDigest(Array("deployment-old-key".utf8))
        )
        var environment = fixture.environment
        environment["GROK_DEPLOYMENT_KEY"] = "deployment-new-key"

        await fixture.requireRefusal(environment: environment)
    }

    @Test("confirmed tenant switches purge only old tenant artifacts and preserve owner config")
    func confirmedTeamSwitchPurgesPriorPolicy() async throws {
        let fixture = try ManagedPolicyGateFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(fixture.team(id: "team-new"))
        try fixture.write("[features]\nremote_fetch = false\n", filename: "config.toml")
        try fixture.write("[old]\nenforced = true\n", filename: MANAGED_CONFIG_FILENAME)
        try fixture.write("fail_closed = true\n", filename: REQUIREMENTS_FILENAME)
        try fixture.write("old-signature", filename: SIGNATURE_SIDECAR_FILE)
        try fixture.write("old-identity", filename: MANAGED_IDENTITY_SIDECAR_FILE)
        try fixture.write("keep this", filename: "unrelated.txt")
        try fixture.writeMarker(principal: "team-old", requirements: true)

        try await LiveManagedPolicyGate.enforce(
            environment: fixture.environment,
            services: fixture.noHealing()
        )

        for name in [
            MANAGED_CONFIG_FILENAME,
            REQUIREMENTS_FILENAME,
            SIGNATURE_SIDECAR_FILE,
            MANAGED_IDENTITY_SIDECAR_FILE,
            MANAGED_CONFIG_CACHE_FILE,
        ] {
            #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(name).path))
        }
        #expect(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("config.toml").path))
        #expect(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("unrelated.txt").path))
    }

    @Test("a deployment-bound marker is never mistaken for another team's policy")
    func deploymentBoundMarkerIsNotTeamSwitch() async throws {
        let fixture = try ManagedPolicyGateFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(fixture.team(id: "team-other"))
        try fixture.write("[features]\nmanaged = true\n", filename: MANAGED_CONFIG_FILENAME)
        try fixture.writeMarker(
            principal: "deployment-owner",
            fingerprint: Blake3.hexDigest(Array("deployment-owner-key".utf8)),
            failClosed: false
        )
        var environment = fixture.environment
        environment["GROK_MANAGED_CONFIG"] = "false"

        try await LiveManagedPolicyGate.enforce(
            environment: environment,
            services: fixture.noHealing()
        )

        #expect(FileManager.default.fileExists(
            atPath: fixture.home.appendingPathComponent(MANAGED_CONFIG_FILENAME).path
        ))
        #expect(FileManager.default.fileExists(
            atPath: fixture.home.appendingPathComponent(MANAGED_CONFIG_CACHE_FILE).path
        ))
    }

    @Test("managed-config disable suppresses healing without disarming fail-closed enforcement")
    func managedFetchDisableStillEnforcesPolicy() async throws {
        let fixture = try ManagedPolicyGateFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(fixture.team())
        try fixture.writeMarker()
        let recorder = ManagedPolicyGateRecorder()
        var environment = fixture.environment
        environment["GROK_MANAGED_CONFIG"] = "false"

        await fixture.requireRefusal(environment: environment, services: fixture.noHealing(recorder: recorder))
        #expect(recorder.recorded.isEmpty)
    }

    @Test("a managed remote-fetch deny suppresses healing without disarming fail-closed enforcement")
    func remoteFetchDisableStillEnforcesPolicy() async throws {
        let fixture = try ManagedPolicyGateFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(fixture.team())
        try fixture.write("[features]\nremote_fetch = true\n", filename: "config.toml")
        try fixture.write("[features]\nremote_fetch = false\n", filename: MANAGED_CONFIG_FILENAME)
        try fixture.writeMarker(managed: true, requirements: true)
        let recorder = ManagedPolicyGateRecorder()

        await fixture.requireRefusal(services: fixture.noHealing(recorder: recorder))
        #expect(recorder.recorded.isEmpty)
    }

    @Test("a hard-stale team cache is healed through the real authenticated setup/install path")
    func boundedHealUsesActualManagedSetup() async throws {
        let fixture = try ManagedPolicyGateFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(fixture.team())
        try fixture.writeMarker()
        let response = HTTPResponse(
            metadata: HTTPResponseMetadata(statusCode: 200),
            body: try JSONSerialization.data(withJSONObject: [
                "team_id": "team-owned",
                "managed_config": "[permission]\nmode = \"default\"\n",
                "requirements": "fail_closed = true\n",
            ])
        )
        let transport = ManagedPolicyGateTransport(responses: [response])
        let services = LiveManagedPolicyGateServices.using(
            setupServices: LiveManagedSetupServices(makeTransport: { transport })
        )

        try await LiveManagedPolicyGate.enforce(environment: fixture.environment, services: services)

        let request = try #require(transport.capturedRequests.first)
        #expect(transport.capturedRequests.count == 1)
        #expect(request.url.absoluteString == "https://cli-chat-proxy.grok.com/v1/deployment/config")
        #expect(request.headers["Authorization"] == "Bearer private-team-session-token")
        #expect(FileManager.default.fileExists(
            atPath: fixture.home.appendingPathComponent(MANAGED_CONFIG_FILENAME).path
        ))
        #expect(FileManager.default.fileExists(
            atPath: fixture.home.appendingPathComponent(REQUIREMENTS_FILENAME).path
        ))
    }

    @Test("an expired team token is really refreshed before signed policy install and live launch")
    func expiredTeamRefreshInstallsSignedPolicyAndLaunches() async throws {
        #if canImport(CryptoKit)
        let fixture = try ManagedPolicyGateFixture()
        defer { fixture.dispose() }
        var expired = fixture.team(expiresAt: Date().addingTimeInterval(-600))
        expired.key = "expired-team-bearer"
        expired.refreshToken = "private-team-refresh-token"
        expired.oidcIssuer = xaiOAuth2Issuer
        expired.oidcClientID = defaultOAuth2ClientID
        try fixture.writeAuth(expired)
        try fixture.writeMarker()
        let signingKey = Curve25519.Signing.PrivateKey()
        setEmbeddedKeys([(
            "managed-gate-refresh-signing-key",
            Array(signingKey.publicKey.rawRepresentation),
        )])
        defer { clearEmbeddedKeysOverride() }
        let refreshedBearer = "fresh-team-bearer"
        let refreshResponse = HTTPResponse(
            metadata: HTTPResponseMetadata(statusCode: 200),
            body: try JSONSerialization.data(withJSONObject: [
                "access_token": refreshedBearer,
                "refresh_token": "rotated-private-team-refresh-token",
                "expires_in": 3_600,
            ])
        )
        let transport = ManagedPolicyGateTransport(responses: [
            refreshResponse,
            try fixture.signedPolicyResponse(signingKey: signingKey),
        ])
        let services = LiveManagedPolicyGateServices.using(
            setupServices: LiveManagedSetupServices(makeTransport: { transport })
        )

        try await LiveManagedPolicyGate.enforce(environment: fixture.environment, services: services)

        let requests = transport.capturedRequests
        #expect(requests.count == 2)
        let refresh = try #require(requests.first)
        let policy = try #require(requests.last)
        #expect(refresh.url.absoluteString == "https://auth.x.ai/oauth2/token")
        #expect(refresh.method == .post)
        #expect(policy.url.absoluteString == "https://cli-chat-proxy.grok.com/v1/deployment/config")
        #expect(policy.headers["Authorization"] == "Bearer \(refreshedBearer)")
        #expect(policy.headers["Authorization"] != "Bearer expired-team-bearer")
        #expect(FileManager.default.fileExists(
            atPath: fixture.home.appendingPathComponent(SIGNATURE_SIDECAR_FILE).path
        ))
        let persisted = try readAuthJSON(at: fixture.home.appendingPathComponent("auth.json"))
        #expect(persisted.values.contains { $0.key == refreshedBearer && $0.teamID == "team-owned" })

        let command = try CLICommandParser.parseOrThrow([
            "headless", "--prompt", "allowed", "--cwd", fixture.workspace.path,
            "--model", "grok-4.5",
        ])
        guard case let .launch(options) = command else {
            Issue.record("fixture command did not parse as a launch")
            return
        }
        let recorder = ManagedPolicyGateRecorder()
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { configuration in
                recorder.record(configuration.apiKey)
                return OpenGrokLiveSampler { _, _ in
                    OpenGrokLiveSamplingResponse(output: "signed policy admitted launch")
                }
            }
        )
        let foundation = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: options,
            context: CLIApplicationContext(
                environment: fixture.environment,
                streams: CLIStreams(out: { _ in }, err: { _ in }),
                control: .never
            ),
            dependencies: dependencies
        )

        #expect(recorder.recorded == [refreshedBearer])
        #expect(foundation.samplingConfiguration.apiKey == refreshedBearer)
        await foundation.toolExecutor.shutdown()
        #endif
    }

    @Test("an expired inline team refresh uses the fresh bearer without changing its tenant")
    func expiredInlineTeamRefreshesWithinSameStartupBudget() async throws {
        let fixture = try ManagedPolicyGateFixture()
        defer { fixture.dispose() }
        var expired = fixture.team(expiresAt: Date().addingTimeInterval(-600))
        expired.refreshToken = "inline-team-refresh"
        expired.oidcIssuer = xaiOAuth2Issuer
        expired.oidcClientID = defaultOAuth2ClientID
        try fixture.writeMarker()
        var environment = fixture.environment
        environment["OPENGROK_AUTH"] = try fixture.inlineAuth(expired)
        let refreshResponse = HTTPResponse(
            metadata: HTTPResponseMetadata(statusCode: 200),
            body: try JSONSerialization.data(withJSONObject: [
                "access_token": "fresh-inline-team-bearer",
                "expires_in": 3_600,
            ])
        )
        let policyResponse = HTTPResponse(
            metadata: HTTPResponseMetadata(statusCode: 200),
            body: try JSONSerialization.data(withJSONObject: [
                "team_id": "team-owned",
                "managed_config": "[features]\nmanaged = true\n",
                "requirements": "fail_closed = true\n",
            ])
        )
        let transport = ManagedPolicyGateTransport(responses: [refreshResponse, policyResponse])
        let services = LiveManagedPolicyGateServices.using(
            setupServices: LiveManagedSetupServices(makeTransport: { transport })
        )

        try await LiveManagedPolicyGate.enforce(environment: environment, services: services)

        #expect(transport.capturedRequests.count == 2)
        #expect(transport.capturedRequests.last?.headers["Authorization"]
            == "Bearer fresh-inline-team-bearer")
        #expect(LiveManagedPolicyGate.servingIdentity(environment: environment) == .team("team-owned"))
    }

    @Test("a rejected managed-team refresh never fetches policy or opens a compromised session")
    func failedTeamRefreshRemainsFailClosed() async throws {
        let fixture = try ManagedPolicyGateFixture()
        defer { fixture.dispose() }
        var expired = fixture.team(expiresAt: Date().addingTimeInterval(-600))
        expired.refreshToken = "rejected-private-refresh-token"
        expired.oidcIssuer = xaiOAuth2Issuer
        expired.oidcClientID = defaultOAuth2ClientID
        try fixture.writeAuth(expired)
        try fixture.writeMarker()
        let rejected = HTTPResponse(
            metadata: HTTPResponseMetadata(statusCode: 400),
            body: try JSONSerialization.data(withJSONObject: ["error": "invalid_grant"])
        )
        let transport = ManagedPolicyGateTransport(responses: [rejected])
        let services = LiveManagedPolicyGateServices.using(
            setupServices: LiveManagedSetupServices(makeTransport: { transport })
        )

        await fixture.requireRefusal(services: services)

        #expect(transport.capturedRequests.count == 1)
        #expect(transport.capturedRequests.first?.url.absoluteString == "https://auth.x.ai/oauth2/token")
        #expect(!FileManager.default.fileExists(
            atPath: fixture.home.appendingPathComponent(MANAGED_CONFIG_FILENAME).path
        ))
    }

    @Test("failed automatic healing never downgrades a compromised policy")
    func failedHealStillRefuses() async throws {
        let fixture = try ManagedPolicyGateFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(fixture.team())
        try fixture.writeMarker()
        let recorder = ManagedPolicyGateRecorder()

        await fixture.requireRefusal(services: fixture.noHealing(recorder: recorder))

        #expect(recorder.recorded == ["heal"])
    }

    @Test("a wedged managed-policy heal is bounded and still fails closed")
    func healDeadlineCannotHangLaunch() async throws {
        let fixture = try ManagedPolicyGateFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(fixture.team())
        try fixture.writeMarker()
        let services = LiveManagedPolicyGateServices(timeoutNanoseconds: 20_000_000) { _ in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return true
        }
        let started = Date()

        await fixture.requireRefusal(services: services)

        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test("the actual launcher rejects compromised team policy before sampler, tools, or session creation")
    func actualLauncherFailsClosedBeforeProviderStartup() async throws {
        let fixture = try ManagedPolicyGateFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(fixture.team(expiresAt: Date().addingTimeInterval(-600)))
        try fixture.writeMarker()
        try fixture.write("[features]\nremote_fetch = false\n", filename: "config.toml")
        let recorder = ManagedPolicyGateRecorder()
        var environment = fixture.environment
        environment["XAI_API_KEY"] = "launch-bearer-must-not-leak"
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                recorder.record("sampler")
                return OpenGrokLiveSampler { _, _ in
                    OpenGrokLiveSamplingResponse(output: "should never run")
                }
            }
        )
        let command = try CLICommandParser.parseOrThrow([
            "headless", "--prompt", "blocked", "--cwd", fixture.workspace.path,
            "--model", "grok-4.5",
        ])
        let context = CLIApplicationContext(
            environment: environment,
            streams: CLIStreams(out: { _ in }, err: { _ in }),
            control: .never
        )

        do {
            let session = try await OpenGrokLiveApplicationLauncher(dependencies: dependencies)
                .launcher.start(command, context)
            await session.shutdown()
            Issue.record("the actual launcher admitted a compromised fail-closed team")
        } catch let error as CLIApplicationError {
            #expect(error == .failed(LiveManagedPolicyGate.missingPolicyMessage))
            #expect(!error.description.contains("launch-bearer-must-not-leak"))
            #expect(!error.description.contains("private-team-session-token"))
        }

        #expect(recorder.recorded.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("sessions").path))
    }

    @Test("leader-backed session launches cannot bypass enterprise policy before attaching")
    func actualLeaderLauncherFailsClosedBeforeLeaderAcquisition() async throws {
        let fixture = try ManagedPolicyGateFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(fixture.team())
        try fixture.writeMarker()
        try fixture.write("[features]\nremote_fetch = false\n", filename: "config.toml")
        let recorder = ManagedPolicyGateRecorder()
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                recorder.record("sampler")
                return OpenGrokLiveSampler { _, _ in
                    OpenGrokLiveSamplingResponse(output: "should never run")
                }
            },
            makeLeaderClient: { _ in
                recorder.record("leader")
                throw CLIApplicationError.failed("a leader was acquired before policy enforcement")
            }
        )
        let command = try CLICommandParser.parseOrThrow([
            "headless", "--prompt", "blocked", "--cwd", fixture.workspace.path, "--leader",
        ])
        let context = CLIApplicationContext(
            environment: fixture.environment,
            streams: CLIStreams(out: { _ in }, err: { _ in }),
            control: .never
        )

        do {
            let session = try await OpenGrokLiveApplicationLauncher(dependencies: dependencies)
                .launcher.start(command, context)
            await session.shutdown()
            Issue.record("the leader launch bypassed compromised managed policy")
        } catch let error as CLIApplicationError {
            #expect(error == .failed(LiveManagedPolicyGate.missingPolicyMessage))
        }

        #expect(recorder.recorded.isEmpty)
    }

    @Test("the actual session foundation admits intact team policy without issuing any heal")
    func actualSessionFoundationAdmitsIntactPolicyOffline() async throws {
        let fixture = try ManagedPolicyGateFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(fixture.team())
        try fixture.write("[permission]\nmode = \"default\"\n", filename: MANAGED_CONFIG_FILENAME)
        try fixture.writeMarker()
        var environment = fixture.environment
        environment["XAI_API_KEY"] = "offline-team-model-key"
        let command = try CLICommandParser.parseOrThrow([
            "--cwd", fixture.workspace.path, "--model", "grok-4.5", "-p", "allowed",
        ])
        guard case let .launch(options) = command else {
            Issue.record("fixture command did not parse as a launch")
            return
        }
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { _, _ in OpenGrokLiveSamplingResponse(output: "ok") }
            }
        )

        let foundation = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: options,
            context: CLIApplicationContext(
                environment: environment,
                streams: CLIStreams(out: { _ in }, err: { _ in }),
                control: .never
            ),
            dependencies: dependencies
        )

        #expect(foundation.cwd.standardizedFileURL == fixture.workspace.standardizedFileURL)
        await foundation.toolExecutor.shutdown()
    }
}
