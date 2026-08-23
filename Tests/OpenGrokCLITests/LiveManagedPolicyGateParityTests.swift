import Foundation
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokFileUtils
import OpenGrokHTTP
import OpenGrokSamplingTypes
import Testing
@testable import OpenGrokCLI

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
