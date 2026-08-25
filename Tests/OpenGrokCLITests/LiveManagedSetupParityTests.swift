import Foundation
import OpenGrokAuth
import OpenGrokCLIChatProxyTypes
import OpenGrokConfig
import OpenGrokFileUtils
import OpenGrokHTTP
import Testing
@testable import OpenGrokCLI

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(CryptoKit)
import CryptoKit
#endif

private final class ManagedSetupRecordingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queuedResponses: [HTTPResponse]
    private var requests: [HTTPRequest] = []

    init(_ responses: [HTTPResponse] = []) {
        queuedResponses = responses
    }

    var capturedRequests: [HTTPRequest] {
        lock.withLock { requests }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try lock.withLock {
            requests.append(request)
            guard !queuedResponses.isEmpty else {
                throw ManagedSetupTransportError.unexpectedRequest
            }
            return queuedResponses.removeFirst()
        }
    }

    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<HTTPStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    private enum ManagedSetupTransportError: Error {
        case unexpectedRequest
    }
}

private actor ManagedSetupCancellationTransport: HTTPTransport {
    private let response: HTTPResponse
    private var capturedRequest: HTTPRequest?
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private var responseWaiter: CheckedContinuation<HTTPResponse, Never>?

    init(response: HTTPResponse) {
        self.response = response
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        return await withCheckedContinuation { continuation in
            capturedRequest = request
            responseWaiter = continuation
            let waiter = requestWaiter
            requestWaiter = nil
            waiter?.resume()
        }
    }

    nonisolated func stream(_ request: HTTPRequest) -> AsyncThrowingStream<HTTPStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func waitForRequest() async {
        guard capturedRequest == nil else { return }
        await withCheckedContinuation { continuation in
            requestWaiter = continuation
        }
    }

    func releaseResponseAfterCancellation() {
        let waiter = responseWaiter
        responseWaiter = nil
        waiter?.resume(returning: response)
    }

    var request: HTTPRequest? {
        capturedRequest
    }
}

private struct ManagedSetupFixture {
    let root: URL
    let home: URL
    let state: URL
    let stdout = BufferedStream()
    let stderr = BufferedStream()

    var environment: [String: String] {
        [
            "HOME": home.path,
            "OPENGROK_HOME": state.path,
            "GROK_DEPLOYMENT_CONFIG_BACKOFF_MS": "0",
        ]
    }

    var streams: CLIStreams {
        CLIStreams(out: { stdout.write($0) }, err: { stderr.write($0) })
    }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-managed-setup-\(UUID().uuidString)")
        home = root.appendingPathComponent("owner")
        state = home.appendingPathComponent(".opengrok")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeAuth(_ auth: GrokAuth) throws {
        try writeAuthJSON(
            at: state.appendingPathComponent("auth.json"),
            store: ["managed-setup-principal": auth]
        )
    }

    func inlineAuth(_ auth: GrokAuth) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(auth), as: UTF8.self)
    }

    func team(
        key: String = "team-oauth-secret",
        id: String = "team-owned",
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

    func response(status: Int = 200, json: [String: Any]) throws -> HTTPResponse {
        HTTPResponse(
            metadata: HTTPResponseMetadata(statusCode: status),
            body: try JSONSerialization.data(withJSONObject: json)
        )
    }

    #if canImport(CryptoKit)
    func signedResponse(
        key: Curve25519.Signing.PrivateKey,
        deploymentID: String? = nil,
        teamID: String? = nil,
        signedDeploymentID: String? = nil,
        signedTeamID: String? = nil,
        managedConfig: String
    ) throws -> HTTPResponse {
        let keyID = "trusted-setup-admin"
        let payload = SignedPayload(
            typ: managedPolicyTyp,
            version: signedPayloadVersion,
            deploymentId: signedDeploymentID,
            teamId: signedTeamID,
            managedConfig: managedConfig,
            expiresAt: UInt64(Date().addingTimeInterval(3_600).timeIntervalSince1970),
            keyId: keyID
        )
        let encodedPayload = try JSONEncoder().encode(payload)
        let signature = try key.signature(for: encodedPayload)
        var object: [String: Any] = [
            "managed_config": managedConfig,
            "signatures": [[
                "signed_payload": String(decoding: encodedPayload, as: UTF8.self),
                "signature": signature.base64EncodedString(),
                "key_id": keyID,
            ]],
        ]
        if let deploymentID { object["deployment_id"] = deploymentID }
        if let teamID { object["team_id"] = teamID }
        return try response(json: object)
    }
    #endif

    func services(_ transport: ManagedSetupRecordingTransport) -> LiveManagedSetupServices {
        LiveManagedSetupServices(makeTransport: { transport })
    }

    func run(
        transport: ManagedSetupRecordingTransport,
        json: Bool = false,
        environment override: [String: String]? = nil
    ) async throws -> LiveManagedSetupOutcome {
        try await LiveManagedSetupComposition.run(
            options: CLIUtilityOptions(name: "setup", json: json),
            environment: override ?? environment,
            streams: streams,
            services: services(transport)
        )
    }

    func sessionFailure(
        transport: ManagedSetupRecordingTransport,
        json: Bool = false,
        environment override: [String: String]? = nil
    ) async -> String {
        let options = CLIUtilityOptions(name: "setup", json: json)
        let context = CLIApplicationContext(
            environment: override ?? environment,
            streams: streams,
            control: .never
        )
        do {
            let session = try await LiveManagedSetupComposition.session(
                for: .utility(options),
                context: context,
                services: services(transport)
            )
            try await session.waitForExit()
            await session.shutdown()
            Issue.record("expected managed setup to refuse, but it succeeded")
            return ""
        } catch let error as CLIApplicationError {
            return error.description
        } catch {
            Issue.record("expected a typed CLI refusal, got \(error)")
            return ""
        }
    }

    func stateNames() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: state.path))
    }
}

@Suite("live managed setup security and Rust CLI parity", .serialized)
struct LiveManagedSetupParityTests {
    @Test("production setup redirects are rejected before credentials can leave the trusted host")
    func productionRedirectDelegateFailsClosedAcrossFoundationImplementations() async throws {
        let trustedURL = try #require(URL(string: "https://cli-chat-proxy.grok.com/v1/deployment/config"))
        let redirectedURL = try #require(URL(string: "https://attacker.example/collect"))
        let response = try #require(HTTPURLResponse(
            url: trustedURL,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": redirectedURL.absoluteString]
        ))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: trustedURL)
        let delegate = ManagedSetupNoRedirectDelegate()

        let rejected = await withCheckedContinuation { continuation in
            delegate.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: redirectedURL)
            ) { request in
                continuation.resume(returning: request == nil)
            }
        }

        #expect(rejected)
    }

    @Test("hostile deployment backoff overrides are capped without arithmetic overflow")
    func hostileRetryBackoffCannotOverflowOrHang() {
        let delay = LiveManagedSetupComposition.boundedRetryBackoffNanoseconds(
            attempt: Int.max,
            environment: ["GROK_DEPLOYMENT_CONFIG_BACKOFF_MS": String(UInt64.max)]
        )
        let disabled = LiveManagedSetupComposition.boundedRetryBackoffNanoseconds(
            attempt: 3,
            environment: ["GROK_DEPLOYMENT_CONFIG_BACKOFF_MS": "0"]
        )

        #expect(delay == 15_000_000_000)
        #expect(disabled == 0)
    }

    @Test("the real CLI routes setup and returns upstream no-principal guidance")
    func executableRouteRejectsMissingPrincipalWithoutNetwork() async throws {
        let fixture = try ManagedSetupFixture()
        defer { fixture.dispose() }

        let status = await CLIRunner.run(
            ["setup"],
            environment: fixture.environment,
            streams: fixture.streams,
            application: .live()
        )

        #expect(status == CLIRunner.ExitCode.failure.rawValue)
        #expect(fixture.stderr.contents.contains("No deployment key or team sign-in found"))
        #expect(fixture.stdout.contents.isEmpty)
        #expect(try fixture.stateNames().isEmpty)
    }

    @Test("personal and expired OAuth identities cannot fetch enterprise policy")
    func personalAndExpiredCredentialsAreIneligible() async throws {
        let personal = try ManagedSetupFixture()
        defer { personal.dispose() }
        try personal.writeAuth(GrokAuth(
            key: "personal-secret",
            authMode: .oidc,
            createTime: Date(),
            principalType: "User"
        ))
        let personalTransport = ManagedSetupRecordingTransport()
        let personalError = await personal.sessionFailure(transport: personalTransport)
        #expect(personalError.contains("No deployment key"))
        #expect(personalTransport.capturedRequests.isEmpty)

        let expired = try ManagedSetupFixture()
        defer { expired.dispose() }
        try expired.writeAuth(expired.team(expiresAt: Date().addingTimeInterval(-60)))
        let expiredTransport = ManagedSetupRecordingTransport()
        let expiredError = await expired.sessionFailure(transport: expiredTransport)
        #expect(expiredError.contains("No deployment key"))
        #expect(expiredTransport.capturedRequests.isEmpty)
    }

    @Test("inline team credentials outrank an explicit path and the home auth store")
    func inlineManagedTeamIsAuthoritativeForSetup() async throws {
        let fixture = try ManagedSetupFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(fixture.team(key: "must-not-send-home-token", id: "home-team"))
        let path = fixture.root.appendingPathComponent("different-team-auth.json")
        try writeAuthJSON(at: path, store: [
            "path-team": fixture.team(key: "must-not-send-path-token", id: "path-team"),
        ])
        var environment = fixture.environment
        environment["OPENGROK_AUTH_PATH"] = path.path
        environment["OPENGROK_AUTH"] = try fixture.inlineAuth(
            fixture.team(key: "inline-team-token", id: "inline-team")
        )
        let transport = ManagedSetupRecordingTransport([
            try fixture.response(json: ["team_id": "inline-team"]),
        ])

        let outcome = try await fixture.run(transport: transport, environment: environment)

        #expect(outcome == .installed)
        #expect(transport.capturedRequests.count == 1)
        #expect(transport.capturedRequests.first?.headers["Authorization"] == "Bearer inline-team-token")
        #expect(LiveManagedSetupComposition.signedInTeamIDForPolicyBinding(
            home: fixture.state,
            environment: environment
        ) == "inline-team")
    }

    @Test("an explicit team auth path outranks a different home credential")
    func explicitManagedAuthPathIsAuthoritativeForSetup() async throws {
        let fixture = try ManagedSetupFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(fixture.team(key: "must-not-send-home-token", id: "home-team"))
        let path = fixture.root.appendingPathComponent("active-team-auth.json")
        try writeAuthJSON(at: path, store: [
            "active-team": fixture.team(key: "path-team-token", id: "path-team"),
        ])
        var environment = fixture.environment
        environment["OPENGROK_AUTH_PATH"] = path.path
        let transport = ManagedSetupRecordingTransport([
            try fixture.response(json: ["team_id": "path-team"]),
        ])

        let outcome = try await fixture.run(transport: transport, environment: environment)

        #expect(outcome == .installed)
        #expect(transport.capturedRequests.first?.headers["Authorization"] == "Bearer path-team-token")
        #expect(LiveManagedSetupComposition.signedInTeamIDForPolicyBinding(
            home: fixture.state,
            environment: environment
        ) == "path-team")
    }

    @Test("personal inline credentials never borrow a managed account from disk")
    func personalInlineOverrideNeverBorrowsDiskTeam() async throws {
        let fixture = try ManagedSetupFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(fixture.team())
        var environment = fixture.environment
        environment["OPENGROK_AUTH"] = try fixture.inlineAuth(
            GrokAuth(key: "personal-inline-key", authMode: .apiKey)
        )
        let transport = ManagedSetupRecordingTransport()

        let message = await fixture.sessionFailure(transport: transport, environment: environment)

        #expect(message.contains("No deployment key"))
        #expect(transport.capturedRequests.isEmpty)
    }

    @Test("malformed inline and unreadable explicit auth overrides fail without fallback")
    func malformedAuthOverridesCannotBorrowAnotherPrincipal() async throws {
        let fixture = try ManagedSetupFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(fixture.team())
        var inline = fixture.environment
        inline["OPENGROK_AUTH"] = "{invalid-managed-identity"
        let inlineTransport = ManagedSetupRecordingTransport()

        let inlineMessage = await fixture.sessionFailure(
            transport: inlineTransport,
            environment: inline
        )

        #expect(inlineMessage.contains("credentials could not be read safely"))
        #expect(inlineTransport.capturedRequests.isEmpty)

        var path = fixture.environment
        path["OPENGROK_AUTH_PATH"] = fixture.root.appendingPathComponent("absent-auth.json").path
        let pathTransport = ManagedSetupRecordingTransport()
        let pathMessage = await fixture.sessionFailure(transport: pathTransport, environment: path)

        #expect(pathMessage.contains("credentials could not be read safely"))
        #expect(pathTransport.capturedRequests.isEmpty)
    }

    @Test("an administrator deployment key remains independent of broken team auth sources")
    func deploymentKeySurvivesBrokenOptionalTeamCredentials() async throws {
        for source in ["missing-path", "malformed-home", "malformed-inline"] {
            let fixture = try ManagedSetupFixture()
            defer { fixture.dispose() }
            var environment = fixture.environment
            environment["GROK_DEPLOYMENT_KEY"] = "independent-administrator-key"
            switch source {
            case "missing-path":
                environment["OPENGROK_AUTH_PATH"] = fixture.root
                    .appendingPathComponent("missing-team.json").path
            case "malformed-home":
                try "{broken-auth-store".write(
                    to: fixture.state.appendingPathComponent("auth.json"),
                    atomically: true,
                    encoding: .utf8
                )
            case "malformed-inline":
                environment["OPENGROK_AUTH"] = "{broken-inline-team"
            default:
                Issue.record("unknown auth-source fixture")
                continue
            }
            let transport = ManagedSetupRecordingTransport([
                try fixture.response(json: ["deployment_id": "administrator-deployment"]),
            ])

            let outcome = try await fixture.run(transport: transport, environment: environment)

            #expect(outcome == .installed)
            #expect(transport.capturedRequests.count == 1)
            #expect(transport.capturedRequests.first?.headers["Authorization"]
                == "Bearer independent-administrator-key")
        }
    }

    @Test("signed policy tenant binding survives an expired team access token")
    func expiredTeamIdentityRemainsAuthoritativeForPolicyBinding() throws {
        let fixture = try ManagedSetupFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(fixture.team(
            id: "  team-owned  ",
            expiresAt: Date().addingTimeInterval(-60)
        ))

        #expect(LiveManagedSetupComposition.signedInTeamIDForPolicyBinding(home: fixture.state)
            == "team-owned")
    }

    @Test("administrator remote_fetch denial beats a user attempt to re-enable network")
    func managedNetworkPolicyCannotBeBypassed() async throws {
        let fixture = try ManagedSetupFixture()
        defer { fixture.dispose() }
        try "[features]\nremote_fetch = false\n".write(
            to: fixture.state.appendingPathComponent("managed_config.toml"),
            atomically: true,
            encoding: .utf8
        )
        try "[features]\nremote_fetch = true\n".write(
            to: fixture.state.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        var environment = fixture.environment
        environment["GROK_DEPLOYMENT_KEY"] = "deployment-secret"
        let transport = ManagedSetupRecordingTransport()

        let message = await fixture.sessionFailure(transport: transport, environment: environment)

        #expect(message.contains("disabled by deployment policy"))
        #expect(transport.capturedRequests.isEmpty)
    }

    @Test("hostile managed endpoint overrides never receive a deployment bearer")
    func untrustedEndpointCannotExfiltrateBearer() async throws {
        let fixture = try ManagedSetupFixture()
        defer { fixture.dispose() }
        var environment = fixture.environment
        environment["GROK_DEPLOYMENT_KEY"] = "never-send-this-secret"
        environment["GROK_MANAGED_CONFIG_URL"] = "https://attacker.example/v1/deployment/config"
        let transport = ManagedSetupRecordingTransport()

        let message = await fixture.sessionFailure(transport: transport, environment: environment)

        #expect(message.contains("trusted official xAI"))
        #expect(!message.contains("never-send-this-secret"))
        #expect(transport.capturedRequests.isEmpty)
    }

    @Test("official-looking URL userinfo, non-TLS, ports and alternate paths are refused")
    func malformedOfficialEndpointVariantsAreDenied() async throws {
        for endpoint in [
            "http://cli-chat-proxy.grok.com/v1/deployment/config",
            "https://cli-chat-proxy.grok.com@attacker.example/v1/deployment/config",
            "https://cli-chat-proxy.grok.com:444/v1/deployment/config",
            "https://cli-chat-proxy.grok.com/v1/not-managed",
            "https://cli-chat-proxy.grok.com/v1/deployment/config?token=bad",
        ] {
            let fixture = try ManagedSetupFixture()
            defer { fixture.dispose() }
            var environment = fixture.environment
            environment["GROK_DEPLOYMENT_KEY"] = "deployment-secret"
            environment["GROK_MANAGED_CONFIG_URL"] = endpoint
            let transport = ManagedSetupRecordingTransport()

            let message = await fixture.sessionFailure(transport: transport, environment: environment)

            #expect(message.contains("trusted official xAI"))
            #expect(transport.capturedRequests.isEmpty)
        }
    }

    @Test("an official endpoint redirect is rejected instead of forwarding its bearer")
    func managedEndpointRedirectNeverReplaysCredentials() async throws {
        let fixture = try ManagedSetupFixture()
        defer { fixture.dispose() }
        var environment = fixture.environment
        environment["GROK_DEPLOYMENT_KEY"] = "do-not-forward-this-secret"
        let redirect = HTTPResponse(
            metadata: HTTPResponseMetadata(
                statusCode: 302,
                headers: ["Location": "https://attacker.example/collect-bearer"]
            ),
            body: Data()
        )
        let transport = ManagedSetupRecordingTransport([redirect])

        let message = await fixture.sessionFailure(transport: transport, environment: environment)

        #expect(message.contains("HTTP 302"))
        #expect(!message.contains("do-not-forward-this-secret"))
        #expect(transport.capturedRequests.count == 1)
        #expect(transport.capturedRequests.first?.url.host == "cli-chat-proxy.grok.com")
    }

    @Test("deployment setup installs owner-private policy and an identity-bound cache marker")
    func deploymentPrincipalInstallsDurableOwnerPrivatePolicy() async throws {
        let fixture = try ManagedSetupFixture()
        defer { fixture.dispose() }
        var environment = fixture.environment
        environment["GROK_DEPLOYMENT_KEY"] = "deployment-secret"
        let managed = "[features]\ntelemetry = false\n"
        let requirements = "fail_closed = true\n"
        let transport = ManagedSetupRecordingTransport([
            try fixture.response(json: [
                "deployment_id": "deployment-owned",
                "managed_config": managed,
                "requirements": requirements,
            ]),
        ])

        let outcome = try await fixture.run(transport: transport, environment: environment)

        #expect(outcome == .installed)
        #expect(fixture.stdout.contents.isEmpty)
        #expect(fixture.stderr.contents.contains("Applied managed configuration."))
        let request = try #require(transport.capturedRequests.first)
        #expect(request.url.absoluteString == "https://cli-chat-proxy.grok.com/v1/deployment/config")
        #expect(request.headers["Authorization"] == "Bearer deployment-secret")
        let managedPath = fixture.state.appendingPathComponent("managed_config.toml")
        let requirementsPath = fixture.state.appendingPathComponent("requirements.toml")
        #expect(try String(contentsOf: managedPath, encoding: .utf8) == managed)
        #expect(try String(contentsOf: requirementsPath, encoding: .utf8) == requirements)
        let marker = try JSONDecoder().decode(
            ManagedConfigCache.self,
            from: Data(contentsOf: fixture.state.appendingPathComponent(MANAGED_CONFIG_CACHE_FILE))
        )
        #expect(marker.principal == "deployment-owned")
        #expect(marker.keyFingerprint == Blake3.hexDigest(Array("deployment-secret".utf8)))
        #expect(marker.failClosed)
        #expect(marker.hadManagedConfig)
        #expect(marker.hadRequirements)
        #expect(!fixture.stdout.contents.contains("deployment-secret"))
        #expect(!fixture.stderr.contents.contains("deployment-secret"))
        #if !os(Windows)
        for file in [managedPath, requirementsPath, fixture.state.appendingPathComponent(MANAGED_CONFIG_CACHE_FILE)] {
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
                as? NSNumber
            #expect(mode?.intValue == 0o600)
        }
        #endif
    }

    @Test("a deployment key in owner config is accepted without reading repository config")
    func ownerConfigurationCanProvideDeploymentPrincipal() async throws {
        let fixture = try ManagedSetupFixture()
        defer { fixture.dispose() }
        try "[endpoints]\ndeployment_key = \"owner-config-secret\"\n".write(
            to: fixture.state.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        let transport = ManagedSetupRecordingTransport([
            try fixture.response(json: ["deployment_id": "owner-deployment"]),
        ])

        let outcome = try await fixture.run(transport: transport)

        #expect(outcome == .installed)
        #expect(transport.capturedRequests.first?.headers["Authorization"] == "Bearer owner-config-secret")
    }

    @Test("malformed owner config cannot hide a trusted managed-tier deployment key")
    func corruptOwnerConfigPreservesManagedDeploymentAuthority() async throws {
        let fixture = try ManagedSetupFixture()
        defer { fixture.dispose() }
        let managed = "[endpoints]\ndeployment_key = \"trusted-managed-deployment\"\n"
        try managed.write(
            to: fixture.state.appendingPathComponent(MANAGED_CONFIG_FILENAME),
            atomically: true,
            encoding: .utf8
        )
        try "[intentionally malformed user config".write(
            to: fixture.state.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        let transport = ManagedSetupRecordingTransport([
            try fixture.response(json: [
                "deployment_id": "trusted-deployment",
                "managed_config": managed,
                "requirements": "fail_closed = true\n",
            ]),
        ])

        let outcome = try await fixture.run(transport: transport)

        #expect(outcome == .installed)
        #expect(transport.capturedRequests.first?.headers["Authorization"]
            == "Bearer trusted-managed-deployment")
        let markerData = try Data(contentsOf: fixture.state.appendingPathComponent(MANAGED_CONFIG_CACHE_FILE))
        let marker = try JSONDecoder().decode(ManagedConfigCache.self, from: markerData)
        #expect(marker.principal == "trusted-deployment")
        #expect(marker.failClosed)
    }

    @Test("eligible team OAuth fetches its own policy without accepting a personal API key")
    func authenticatedTeamPrincipalInstallsPolicy() async throws {
        let fixture = try ManagedSetupFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(fixture.team())
        let transport = ManagedSetupRecordingTransport([
            try fixture.response(json: [
                "team_id": "team-owned",
                "managed_config": "[features]\ntelemetry = false\n",
            ]),
        ])

        let outcome = try await fixture.run(transport: transport)

        #expect(outcome == .installed)
        #expect(transport.capturedRequests.first?.headers["Authorization"] == "Bearer team-oauth-secret")
        let marker = try JSONDecoder().decode(
            ManagedConfigCache.self,
            from: Data(contentsOf: fixture.state.appendingPathComponent(MANAGED_CONFIG_CACHE_FILE))
        )
        #expect(marker.principal == "team-owned")
        #expect(marker.keyFingerprint == nil)
    }

    @Test("a rejected deployment key falls back to a valid team principal exactly once")
    func rejectedDeploymentFallsBackToTeamOAuth() async throws {
        let fixture = try ManagedSetupFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(fixture.team())
        var environment = fixture.environment
        environment["GROK_DEPLOYMENT_KEY"] = "rejected-deployment-secret"
        let transport = ManagedSetupRecordingTransport([
            try fixture.response(status: 401, json: [:]),
            try fixture.response(json: ["team_id": "team-owned"]),
        ])

        let outcome = try await fixture.run(transport: transport, environment: environment)

        #expect(outcome == .installed)
        #expect(transport.capturedRequests.compactMap { $0.headers["Authorization"] } == [
            "Bearer rejected-deployment-secret",
            "Bearer team-oauth-secret",
        ])
    }

    @Test("an expired team refreshes before a rejected deployment falls back to that team")
    func rejectedDeploymentFallsBackToRefreshedTeam() async throws {
        let fixture = try ManagedSetupFixture()
        defer { fixture.dispose() }
        var expired = fixture.team(
            key: "expired-team-secret",
            expiresAt: Date().addingTimeInterval(-600)
        )
        expired.refreshToken = "team-refresh-secret"
        expired.oidcIssuer = xaiOAuth2Issuer
        expired.oidcClientID = defaultOAuth2ClientID
        try fixture.writeAuth(expired)
        var environment = fixture.environment
        environment["GROK_DEPLOYMENT_KEY"] = "rejected-deployment-secret"
        let transport = ManagedSetupRecordingTransport([
            try fixture.response(json: [
                "access_token": "refreshed-team-secret",
                "expires_in": 3_600,
            ]),
            try fixture.response(status: 401, json: [:]),
            try fixture.response(json: ["team_id": "team-owned"]),
        ])

        let outcome = try await fixture.run(transport: transport, environment: environment)

        #expect(outcome == .installed)
        let requests = transport.capturedRequests
        #expect(requests.count == 3)
        #expect(requests.first?.url.absoluteString == "https://auth.x.ai/oauth2/token")
        #expect(requests.dropFirst().compactMap { $0.headers["Authorization"] } == [
            "Bearer rejected-deployment-secret",
            "Bearer refreshed-team-secret",
        ])
        let markerData = try Data(contentsOf: fixture.state.appendingPathComponent(MANAGED_CONFIG_CACHE_FILE))
        let marker = try JSONDecoder().decode(ManagedConfigCache.self, from: markerData)
        #expect(marker.principal == "team-owned")
        #expect(marker.keyFingerprint == nil)
    }

    @Test("a failed optional team refresh cannot disable a valid deployment key")
    func failedTeamRefreshStillUsesIndependentDeploymentKey() async throws {
        let fixture = try ManagedSetupFixture()
        defer { fixture.dispose() }
        var expired = fixture.team(expiresAt: Date().addingTimeInterval(-600))
        expired.refreshToken = "rejected-team-refresh"
        expired.oidcIssuer = xaiOAuth2Issuer
        expired.oidcClientID = defaultOAuth2ClientID
        try fixture.writeAuth(expired)
        var environment = fixture.environment
        environment["GROK_DEPLOYMENT_KEY"] = "valid-deployment-secret"
        let transport = ManagedSetupRecordingTransport([
            try fixture.response(status: 400, json: ["error": "invalid_grant"]),
            try fixture.response(json: ["deployment_id": "valid-deployment"]),
        ])

        let outcome = try await fixture.run(transport: transport, environment: environment)

        #expect(outcome == .installed)
        #expect(transport.capturedRequests.count == 2)
        #expect(transport.capturedRequests.last?.headers["Authorization"]
            == "Bearer valid-deployment-secret")
    }

    @Test("a deployment principal with no served row falls back to configured team policy")
    func unconfiguredDeploymentFallsBackToTeamOAuth() async throws {
        let fixture = try ManagedSetupFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(fixture.team())
        var environment = fixture.environment
        environment["GROK_DEPLOYMENT_KEY"] = "empty-deployment-secret"
        let transport = ManagedSetupRecordingTransport([
            try fixture.response(json: [:]),
            try fixture.response(json: ["team_id": "team-owned"]),
        ])

        let outcome = try await fixture.run(transport: transport, environment: environment)

        #expect(outcome == .installed)
        #expect(transport.capturedRequests.count == 2)
    }

    @Test("setup --json is read-only and emits the exact upstream camelCase report")
    func JSONReportNeverPersistsPolicyLockOrMarker() async throws {
        let fixture = try ManagedSetupFixture()
        defer { fixture.dispose() }
        var environment = fixture.environment
        environment["GROK_DEPLOYMENT_KEY"] = "json-bearer-secret"
        let before = try fixture.stateNames()
        let transport = ManagedSetupRecordingTransport([
            try fixture.response(json: [
                "deployment_id": "deployment-owned",
                "managed_config": "[ui]\ntheme = \"dark\"\n",
                "requirements": "fail_closed = true\n",
            ]),
        ])

        let outcome = try await fixture.run(transport: transport, json: true, environment: environment)

        #expect(outcome == .reported)
        #expect(try fixture.stateNames() == before)
        #expect(fixture.stderr.contents.isEmpty)
        #expect(!fixture.stdout.contents.contains("json-bearer-secret"))
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(fixture.stdout.contents.utf8)) as? [String: Any]
        )
        #expect(object["source"] as? String == "deploymentKey")
        #expect(object["configured"] as? Bool == true)
        #expect(object["deploymentId"] as? String == "deployment-owned")
        #expect(object["teamId"] is NSNull)
        #expect(object["managedConfig"] as? String == "[ui]\ntheme = \"dark\"\n")
        #expect(object["failClosed"] as? Bool == true)
        #expect(object["deployment_id"] == nil)
    }

    @Test("a no-row response removes withdrawn owner policy without touching user config")
    func withdrawnPolicyConvergesToTheServedArtifactSet() async throws {
        let fixture = try ManagedSetupFixture()
        defer { fixture.dispose() }
        var environment = fixture.environment
        environment["GROK_DEPLOYMENT_KEY"] = "deployment-secret"
        let configPath = fixture.state.appendingPathComponent("config.toml")
        try "[ui]\ntheme = \"mine\"\n".write(to: configPath, atomically: true, encoding: .utf8)
        for name in [MANAGED_CONFIG_FILENAME, REQUIREMENTS_FILENAME] {
            try "[features]\ntelemetry = false\n".write(
                to: fixture.state.appendingPathComponent(name),
                atomically: true,
                encoding: .utf8
            )
        }
        let transport = ManagedSetupRecordingTransport([try fixture.response(json: [:])])

        let outcome = try await fixture.run(transport: transport, environment: environment)

        #expect(outcome == .nothingConfigured)
        #expect(fixture.stderr.contents.contains("doesn't have a managed configuration"))
        #expect(!FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent(MANAGED_CONFIG_FILENAME).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent(REQUIREMENTS_FILENAME).path))
        #expect(try String(contentsOf: configPath, encoding: .utf8) == "[ui]\ntheme = \"mine\"\n")
    }

    @Test("malformed served policy never replaces existing administrator policy")
    func malformedPolicyFailsClosedBeforeDiskMutation() async throws {
        let fixture = try ManagedSetupFixture()
        defer { fixture.dispose() }
        var environment = fixture.environment
        environment["GROK_DEPLOYMENT_KEY"] = "deployment-secret"
        let existingPath = fixture.state.appendingPathComponent(MANAGED_CONFIG_FILENAME)
        try "[features]\ntelemetry = false\n".write(
            to: existingPath,
            atomically: true,
            encoding: .utf8
        )
        let transport = ManagedSetupRecordingTransport([
            try fixture.response(json: [
                "deployment_id": "deployment-owned",
                "managed_config": "[this is invalid",
            ]),
        ])

        let message = await fixture.sessionFailure(transport: transport, environment: environment)

        #expect(message.contains("malformed managed configuration"))
        #expect(try String(contentsOf: existingPath, encoding: .utf8) == "[features]\ntelemetry = false\n")
    }

    @Test("a team response bound to another tenant is refused without writing")
    func foreignTeamPolicyCannotCrossTenantBoundary() async throws {
        let fixture = try ManagedSetupFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(fixture.team())
        let transport = ManagedSetupRecordingTransport([
            try fixture.response(json: [
                "team_id": "someone-elses-team",
                "managed_config": "[features]\ntelemetry = true\n",
            ]),
        ])

        let message = await fixture.sessionFailure(transport: transport)

        #expect(message.contains("different team"))
        #expect(!FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent(MANAGED_CONFIG_FILENAME).path))
    }

    @Test("an active signature-verification policy rejects unsigned responses before mutation")
    func requiredManagedSignatureCannotBeBypassed() async throws {
        let fixture = try ManagedSetupFixture()
        defer { fixture.dispose() }
        setEmbeddedKeys([("required-admin-key", Array(repeating: 0x01, count: 32))])
        defer { clearEmbeddedKeysOverride() }
        var environment = fixture.environment
        environment["GROK_DEPLOYMENT_KEY"] = "deployment-secret"
        let transport = ManagedSetupRecordingTransport([
            try fixture.response(json: [
                "deployment_id": "deployment-owned",
                "managed_config": "[features]\ntelemetry = false\n",
            ]),
        ])

        let message = await fixture.sessionFailure(transport: transport, environment: environment)

        #expect(message.contains("signature could not be verified"))
        #expect(!FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent(MANAGED_CONFIG_FILENAME).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent(MANAGED_CONFIG_CACHE_FILE).path))
    }

    @Test("a deployment key cannot erase the signed-in team's expired-token tenant binding")
    func deploymentKeyCannotBypassExpiredTeamEnvelopeBinding() async throws {
        #if canImport(CryptoKit)
        let fixture = try ManagedSetupFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(fixture.team(
            id: "team-owned",
            expiresAt: Date().addingTimeInterval(-60)
        ))
        let signingKey = Curve25519.Signing.PrivateKey()
        setEmbeddedKeys([("trusted-setup-admin", Array(signingKey.publicKey.rawRepresentation))])
        defer { clearEmbeddedKeysOverride() }
        var environment = fixture.environment
        environment["GROK_DEPLOYMENT_KEY"] = "deployment-secret"
        let transport = ManagedSetupRecordingTransport([
            try fixture.signedResponse(
                key: signingKey,
                deploymentID: "deployment-owned",
                signedTeamID: "attacker-team",
                managedConfig: "[features]\ntelemetry = true\n"
            ),
        ])

        let message = await fixture.sessionFailure(transport: transport, environment: environment)

        #expect(message.contains("signature could not be verified"))
        #expect(transport.capturedRequests.count == 1)
        #expect(transport.capturedRequests.first?.headers["Authorization"] == "Bearer deployment-secret")
        #expect(!FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent(MANAGED_CONFIG_FILENAME).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent(MANAGED_CONFIG_CACHE_FILE).path))
        #endif
    }

    @Test("deployment-signed policy binds to the inline team instead of a different disk tenant")
    func deploymentEnvelopeUsesInlineTenantAuthority() async throws {
        #if canImport(CryptoKit)
        let fixture = try ManagedSetupFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(fixture.team(id: "disk-team"))
        let signingKey = Curve25519.Signing.PrivateKey()
        setEmbeddedKeys([("trusted-setup-admin", Array(signingKey.publicKey.rawRepresentation))])
        defer { clearEmbeddedKeysOverride() }
        var environment = fixture.environment
        environment["GROK_DEPLOYMENT_KEY"] = "deployment-secret"
        environment["OPENGROK_AUTH"] = try fixture.inlineAuth(
            fixture.team(key: "inline-team-secret", id: "inline-team")
        )
        let transport = ManagedSetupRecordingTransport([
            try fixture.signedResponse(
                key: signingKey,
                deploymentID: "deployment-owned",
                signedTeamID: "disk-team",
                managedConfig: "[features]\ntelemetry = true\n"
            ),
        ])

        let message = await fixture.sessionFailure(transport: transport, environment: environment)

        #expect(message.contains("signature could not be verified"))
        #expect(transport.capturedRequests.count == 1)
        #expect(transport.capturedRequests.first?.headers["Authorization"] == "Bearer deployment-secret")
        #expect(!FileManager.default.fileExists(
            atPath: fixture.state.appendingPathComponent(MANAGED_CONFIG_FILENAME).path
        ))
        #endif
    }

    @Test("broken optional auth overrides cannot erase a deployment's signed disk-team binding")
    func brokenOptionalAuthSourcesCannotEraseSignedDiskTenant() async throws {
        #if canImport(CryptoKit)
        let signingKey = Curve25519.Signing.PrivateKey()
        setEmbeddedKeys([("trusted-setup-admin", Array(signingKey.publicKey.rawRepresentation))])
        defer { clearEmbeddedKeysOverride() }

        for source in ["malformed-inline", "unreadable-path", "malformed-inline-unreadable-path"] {
            let fixture = try ManagedSetupFixture()
            defer { fixture.dispose() }
            try fixture.writeAuth(fixture.team(id: "genuine-disk-team"))
            var environment = fixture.environment
            environment["GROK_DEPLOYMENT_KEY"] = "deployment-secret"
            if source.contains("malformed-inline") {
                environment["OPENGROK_AUTH"] = "{broken-selected-credential"
            }
            if source.contains("unreadable-path") {
                environment["OPENGROK_AUTH_PATH"] = fixture.root
                    .appendingPathComponent("missing-selected-team.json").path
            }
            let transport = ManagedSetupRecordingTransport([
                try fixture.signedResponse(
                    key: signingKey,
                    deploymentID: "deployment-owned",
                    signedTeamID: "attacker-team",
                    managedConfig: "[features]\ntelemetry = true\n"
                ),
            ])

            let message = await fixture.sessionFailure(transport: transport, environment: environment)

            #expect(LiveManagedSetupComposition.signedInTeamIDForPolicyBinding(
                home: fixture.state,
                environment: environment
            ) == "genuine-disk-team")
            #expect(message.contains("signature could not be verified"))
            #expect(transport.capturedRequests.count == 1)
            #expect(transport.capturedRequests.first?.headers["Authorization"] == "Bearer deployment-secret")
            #expect(!FileManager.default.fileExists(
                atPath: fixture.state.appendingPathComponent(MANAGED_CONFIG_FILENAME).path
            ))
        }
        #endif
    }

    @Test("deployment cache markers prefer the cryptographically signed deployment identity")
    func deploymentMarkerIgnoresConflictingUnsignedResponseIdentity() async throws {
        #if canImport(CryptoKit)
        let fixture = try ManagedSetupFixture()
        defer { fixture.dispose() }
        let signingKey = Curve25519.Signing.PrivateKey()
        setEmbeddedKeys([("trusted-setup-admin", Array(signingKey.publicKey.rawRepresentation))])
        defer { clearEmbeddedKeysOverride() }
        var environment = fixture.environment
        environment["GROK_DEPLOYMENT_KEY"] = "deployment-secret"
        let transport = ManagedSetupRecordingTransport([
            try fixture.signedResponse(
                key: signingKey,
                deploymentID: "untrusted-outer-deployment",
                signedDeploymentID: "signed-deployment-owner",
                managedConfig: "[features]\ntelemetry = false\n"
            ),
        ])

        let outcome = try await fixture.run(transport: transport, environment: environment)

        #expect(outcome == .installed)
        let marker = try JSONDecoder().decode(
            ManagedConfigCache.self,
            from: Data(contentsOf: fixture.state.appendingPathComponent(MANAGED_CONFIG_CACHE_FILE))
        )
        #expect(marker.principal == "signed-deployment-owner")
        #expect(marker.principal != "untrusted-outer-deployment")
        #endif
    }

    @Test("a deployment-signed envelope cannot rebind a team-authenticated cache marker")
    func teamMarkerRemainsBoundToTheServingTeam() async throws {
        #if canImport(CryptoKit)
        let fixture = try ManagedSetupFixture()
        defer { fixture.dispose() }
        try fixture.writeAuth(fixture.team())
        let signingKey = Curve25519.Signing.PrivateKey()
        setEmbeddedKeys([("trusted-setup-admin", Array(signingKey.publicKey.rawRepresentation))])
        defer { clearEmbeddedKeysOverride() }
        let transport = ManagedSetupRecordingTransport([
            try fixture.signedResponse(
                key: signingKey,
                deploymentID: "unsigned-outer-deployment",
                teamID: "team-owned",
                signedDeploymentID: "signed-deployment-owner",
                managedConfig: "[features]\ntelemetry = false\n"
            ),
        ])

        let outcome = try await fixture.run(transport: transport)

        #expect(outcome == .installed)
        let marker = try JSONDecoder().decode(
            ManagedConfigCache.self,
            from: Data(contentsOf: fixture.state.appendingPathComponent(MANAGED_CONFIG_CACHE_FILE))
        )
        #expect(marker.principal == "team-owned")
        #expect(marker.keyFingerprint == nil)
        #endif
    }

    @Test("a cancelled managed fetch returning late never installs policy, requirements, or a marker")
    func cancelledFetchCannotInstallLateAdministratorPolicy() async throws {
        let fixture = try ManagedSetupFixture()
        defer { fixture.dispose() }
        var environment = fixture.environment
        environment["GROK_DEPLOYMENT_KEY"] = "cancelled-deployment-secret"
        let taskEnvironment = environment
        let transport = ManagedSetupCancellationTransport(response: try fixture.response(json: [
            "deployment_id": "cancelled-deployment",
            "managed_config": "[features]\ntelemetry = false\n",
            "requirements": "fail_closed = true\n",
        ]))
        let services = LiveManagedSetupServices(makeTransport: { transport })
        let streams = fixture.streams
        let task = Task {
            try await LiveManagedSetupComposition.run(
                options: CLIUtilityOptions(name: "setup"),
                environment: taskEnvironment,
                streams: streams,
                services: services
            )
        }

        await transport.waitForRequest()
        task.cancel()
        await transport.releaseResponseAfterCancellation()

        do {
            let outcome = try await task.value
            Issue.record("cancelled setup unexpectedly installed policy: \(outcome)")
        } catch is CancellationError {
            // Cancellation, not a successful install or a retry, owns the task.
        } catch {
            Issue.record("cancelled setup returned an unexpected error: \(error)")
        }

        let request = await transport.request
        let remainingFiles = try fixture.stateNames()
        #expect(request?.url.host == "cli-chat-proxy.grok.com")
        #expect(remainingFiles.isEmpty)
        #expect(fixture.stdout.contents.isEmpty)
        #expect(fixture.stderr.contents.isEmpty)
    }

    @Test("a late response from a cancelled tenant refresh cannot erase or replace old policy")
    func cancelledTenantSwitchCannotOverwriteExistingAdministratorPolicy() async throws {
        let fixture = try ManagedSetupFixture()
        defer { fixture.dispose() }
        let oldManaged = "[features]\ntelemetry = false\n"
        let oldRequirements = "fail_closed = true\n"
        let managedPath = fixture.state.appendingPathComponent(MANAGED_CONFIG_FILENAME)
        let requirementsPath = fixture.state.appendingPathComponent(REQUIREMENTS_FILENAME)
        let markerPath = fixture.state.appendingPathComponent(MANAGED_CONFIG_CACHE_FILE)
        try oldManaged.write(to: managedPath, atomically: true, encoding: .utf8)
        try oldRequirements.write(to: requirementsPath, atomically: true, encoding: .utf8)
        let priorMarker = ManagedConfigCache(
            syncedAt: UInt64(Date().timeIntervalSince1970),
            principal: "previous-tenant",
            hadManagedConfig: true,
            hadRequirements: true,
            keyFingerprint: Blake3.hexDigest(Array("prior-deployment-key".utf8)),
            failClosed: true,
            rollbackFloor: UInt64(Date().timeIntervalSince1970)
        )
        try JSONEncoder().encode(priorMarker).write(to: markerPath)
        let originalManaged = try Data(contentsOf: managedPath)
        let originalRequirements = try Data(contentsOf: requirementsPath)
        let originalMarker = try Data(contentsOf: markerPath)
        var environment = fixture.environment
        environment["GROK_DEPLOYMENT_KEY"] = "replacement-deployment-key"
        let taskEnvironment = environment
        let transport = ManagedSetupCancellationTransport(response: try fixture.response(json: [
            "deployment_id": "replacement-tenant",
            "managed_config": "[features]\ntelemetry = true\n",
            "requirements": "fail_closed = false\n",
        ]))
        let services = LiveManagedSetupServices(makeTransport: { transport })
        let streams = fixture.streams
        let task = Task {
            try await LiveManagedSetupComposition.run(
                options: CLIUtilityOptions(name: "setup"),
                environment: taskEnvironment,
                streams: streams,
                services: services
            )
        }

        await transport.waitForRequest()
        task.cancel()
        await transport.releaseResponseAfterCancellation()

        do {
            let outcome = try await task.value
            Issue.record("cancelled tenant refresh unexpectedly returned: \(outcome)")
        } catch is CancellationError {
            // The original tenant retains its complete fail-closed artifact set.
        } catch {
            Issue.record("cancelled tenant refresh returned an unexpected error: \(error)")
        }

        let currentManaged = try Data(contentsOf: managedPath)
        let currentRequirements = try Data(contentsOf: requirementsPath)
        let currentMarker = try Data(contentsOf: markerPath)
        #expect(currentManaged == originalManaged)
        #expect(currentRequirements == originalRequirements)
        #expect(currentMarker == originalMarker)
        #expect(fixture.stdout.contents.isEmpty)
        #expect(fixture.stderr.contents.isEmpty)
    }

    @Test("cancellation after tenant eviction still commits one complete managed-policy bundle")
    func cancellationDuringTenantCommitCannotLeaveMixedAdministratorPolicy() async throws {
        let fixture = try ManagedSetupFixture()
        defer { fixture.dispose() }
        let managedPath = fixture.state.appendingPathComponent(MANAGED_CONFIG_FILENAME)
        let requirementsPath = fixture.state.appendingPathComponent(REQUIREMENTS_FILENAME)
        let markerPath = fixture.state.appendingPathComponent(MANAGED_CONFIG_CACHE_FILE)
        try "[features]\ntelemetry = false\n".write(
            to: managedPath,
            atomically: true,
            encoding: .utf8
        )
        try "fail_closed = false\n".write(
            to: requirementsPath,
            atomically: true,
            encoding: .utf8
        )
        let priorMarker = ManagedConfigCache(
            syncedAt: UInt64(Date().timeIntervalSince1970),
            principal: "previous-tenant",
            hadManagedConfig: true,
            hadRequirements: true,
            keyFingerprint: Blake3.hexDigest(Array("prior-deployment-key".utf8)),
            failClosed: false,
            rollbackFloor: UInt64(Date().timeIntervalSince1970)
        )
        try JSONEncoder().encode(priorMarker).write(to: markerPath)
        var environment = fixture.environment
        environment["GROK_DEPLOYMENT_KEY"] = "replacement-deployment-key"
        let taskEnvironment = environment
        let replacementManaged = "[features]\ntelemetry = true\n"
        let replacementRequirements = "fail_closed = true\n"
        let transport = ManagedSetupRecordingTransport([
            try fixture.response(json: [
                "deployment_id": "replacement-tenant",
                "managed_config": replacementManaged,
                "requirements": replacementRequirements,
            ]),
        ])
        var services = LiveManagedSetupServices(makeTransport: { transport })
        services.afterFirstManagedArtifactCommit = {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
        }
        let taskServices = services
        let streams = fixture.streams
        let task = Task {
            try await LiveManagedSetupComposition.run(
                options: CLIUtilityOptions(name: "setup"),
                environment: taskEnvironment,
                streams: streams,
                services: taskServices
            )
        }

        do {
            let outcome = try await task.value
            Issue.record("cancelled managed commit unexpectedly returned: \(outcome)")
        } catch is CancellationError {
            // Cancellation is observed only after the locked bundle is coherent.
        } catch {
            Issue.record("cancelled managed commit returned an unexpected error: \(error)")
        }

        let currentManaged = try String(contentsOf: managedPath, encoding: .utf8)
        let currentRequirements = try String(contentsOf: requirementsPath, encoding: .utf8)
        let marker = try JSONDecoder().decode(
            ManagedConfigCache.self,
            from: Data(contentsOf: markerPath)
        )
        #expect(currentManaged == replacementManaged)
        #expect(currentRequirements == replacementRequirements)
        #expect(marker.principal == "replacement-tenant")
        #expect(marker.keyFingerprint == Blake3.hexDigest(Array("replacement-deployment-key".utf8)))
        #expect(marker.hadManagedConfig)
        #expect(marker.hadRequirements)
        #expect(marker.failClosed)
        #expect(fixture.stdout.contents.isEmpty)
        #expect(fixture.stderr.contents.isEmpty)
    }

    @Test("cancellation preserves rotated OAuth credentials without applying managed policy")
    func cancelledOAuthRefreshPreservesRotatedCredentialsWithoutApplyingPolicy() async throws {
        let fixture = try ManagedSetupFixture()
        defer { fixture.dispose() }
        var expired = fixture.team(expiresAt: Date().addingTimeInterval(-600))
        expired.refreshToken = "private-cancelled-refresh-token"
        expired.oidcIssuer = xaiOAuth2Issuer
        expired.oidcClientID = defaultOAuth2ClientID
        try fixture.writeAuth(expired)
        let authPath = fixture.state.appendingPathComponent("auth.json")
        let originalCredentials = try Data(contentsOf: authPath)
        let transport = ManagedSetupCancellationTransport(response: try fixture.response(json: [
            "access_token": "late-refreshed-team-bearer",
            "refresh_token": "late-refreshed-team-refresh-token",
            "expires_in": 3_600,
        ]))
        let services = LiveManagedSetupServices(makeTransport: { transport })
        let environment = fixture.environment
        let streams = fixture.streams
        let task = Task {
            try await LiveManagedSetupComposition.run(
                options: CLIUtilityOptions(name: "setup"),
                environment: environment,
                streams: streams,
                services: services
            )
        }

        await transport.waitForRequest()
        task.cancel()
        await transport.releaseResponseAfterCancellation()

        do {
            let outcome = try await task.value
            Issue.record("cancelled OAuth refresh unexpectedly returned: \(outcome)")
        } catch is CancellationError {
            // A completed token rotation remains durable even when this waiter
            // is cancelled; cancellation still prevents managed-policy writes.
        } catch {
            Issue.record("cancelled OAuth refresh returned an unexpected error: \(error)")
        }

        let request = await transport.request
        #expect(request?.url.absoluteString == "https://auth.x.ai/oauth2/token")
        let currentCredentials = try Data(contentsOf: authPath)
        #expect(currentCredentials != originalCredentials)
        let store = try readAuthJSON(at: authPath)
        let scope = GrokComConfig.default(environment: environment).authScope
        let refreshed = try #require(lookupAuth(store, scope: scope))
        #expect(refreshed.key == "late-refreshed-team-bearer")
        #expect(refreshed.refreshToken == "late-refreshed-team-refresh-token")
        #expect(refreshed.teamID == expired.teamID)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.state.appendingPathComponent(MANAGED_CONFIG_FILENAME).path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.state.appendingPathComponent(MANAGED_CONFIG_CACHE_FILE).path
        ))
    }

    @Test("an existing apply lock returns skipped without overwriting policy")
    func concurrentManagedConfigurationApplyIsSkipped() async throws {
        let fixture = try ManagedSetupFixture()
        defer { fixture.dispose() }
        var environment = fixture.environment
        environment["GROK_DEPLOYMENT_KEY"] = "deployment-secret"
        let lock = try AdvisoryFileLock.acquire(
            at: fixture.state.appendingPathComponent("managed_config.lock"),
            options: AdvisoryLockOptions(nonBlocking: true, create: true, mode: 0o600)
        )
        defer { lock.release() }
        let transport = ManagedSetupRecordingTransport([
            try fixture.response(json: [
                "deployment_id": "deployment-owned",
                "managed_config": "[features]\ntelemetry = false\n",
            ]),
        ])

        let outcome = try await fixture.run(transport: transport, environment: environment)

        #expect(outcome == .skipped)
        #expect(fixture.stderr.contents.contains("was not applied this run"))
        #expect(!FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent(MANAGED_CONFIG_FILENAME).path))
    }

    @Test("a symlink at a managed artifact path cannot redirect an owner credential write")
    func managedArtifactSymlinkFailsClosed() async throws {
        #if !os(Windows)
        let fixture = try ManagedSetupFixture()
        defer { fixture.dispose() }
        var environment = fixture.environment
        environment["GROK_DEPLOYMENT_KEY"] = "deployment-secret"
        let external = fixture.root.appendingPathComponent("outside-policy.toml")
        try "[features]\noriginal = true\n".write(to: external, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: fixture.state.appendingPathComponent(MANAGED_CONFIG_FILENAME),
            withDestinationURL: external
        )
        let transport = ManagedSetupRecordingTransport([
            try fixture.response(json: [
                "deployment_id": "deployment-owned",
                "managed_config": "[features]\noriginal = false\n",
            ]),
        ])

        let message = await fixture.sessionFailure(transport: transport, environment: environment)

        #expect(message.contains("could not be saved safely"))
        #expect(try String(contentsOf: external, encoding: .utf8) == "[features]\noriginal = true\n")
        #endif
    }
}
