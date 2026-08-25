import Foundation
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokHTTP
import Testing
@testable import OpenGrokCLI

private struct XAIDeviceLoginFixture {
    let root: URL
    let home: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "open-grok-xai-device-login-\(UUID().uuidString)"
        )
        home = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var environment: [String: String] {
        [
            "HOME": root.path,
            "OPENGROK_HOME": home.path,
            "GROK_MANAGED_CONFIG": "false",
        ]
    }

    var authFile: URL {
        home.appendingPathComponent(OpenGrokAuthPaths.authFileName)
    }

    func dispose() {
        LiveManagedPolicyLifecycle.stop(environment: environment)
        try? FileManager.default.removeItem(at: root)
    }

    func response(_ object: [String: Any], status: Int = 200) throws
        -> MockHTTPTransport.ScriptedResponse
    {
        MockHTTPTransport.ScriptedResponse(
            metadata: HTTPResponseMetadata(statusCode: status),
            body: try JSONSerialization.data(withJSONObject: object)
        )
    }

    func deviceResponse() throws -> MockHTTPTransport.ScriptedResponse {
        try response([
            "device_code": "private-server-device-code",
            "user_code": "ABCD-EFGH",
            "verification_uri": "https://accounts.example.test/device",
            "verification_uri_complete": "https://accounts.example.test/device?user_code=ABCD-EFGH",
            "expires_in": 600,
            "interval": 1,
        ])
    }

    func tokenResponse(principal: String? = nil) throws
        -> (response: MockHTTPTransport.ScriptedResponse, token: String)
    {
        var payload: [String: Any] = [
            "sub": "device-user",
            "exp": Int(Date().addingTimeInterval(3600).timeIntervalSince1970),
        ]
        if let principal {
            payload["principal_type"] = teamPrincipalType
            payload["principal_id"] = principal
            payload["team_id"] = principal
        }
        let token = buildTestJWT(payload: payload)
        return (
            try response([
                "access_token": token,
                "refresh_token": "private-device-refresh-token",
                "expires_in": 3600,
            ]),
            token
        )
    }

    func services(
        transport: MockHTTPTransport,
        browserLogin: LiveAuthServices.XAILoginFlow? = nil
    ) -> LiveAuthServices {
        let flow: LiveAuthServices.XAILoginFlow = browserLogin ?? { _, _, _, _ in
            throw AuthError.notLoggedIn
        }
        return LiveAuthServices(
            makeTransport: { transport },
            codexBrowserLogin: { _, _, _, _ in throw AuthError.notLoggedIn },
            codexDeviceLogin: { _, _, _, _ in throw AuthError.notLoggedIn },
            openBrowser: nil,
            readSecretLine: { nil },
            isInteractive: { false },
            xaiBrowserLogin: flow,
            managedPolicySetupServices: LiveManagedSetupServices(
                makeTransport: { MockHTTPTransport() }
            )
        )
    }

    func options(_ arguments: [String], environment: [String: String]) throws -> CLIUtilityOptions {
        let parsed = try CLICommandParser.parseOrThrow(
            ["login"] + arguments,
            environment: environment
        )
        guard case .utility(let options) = parsed else {
            throw CLIApplicationError.failed("login did not parse as an auth command")
        }
        return options
    }
}

@Suite("Live xAI OAuth and device login parity")
struct LiveXAIDeviceLoginParityTests {
    @Test("--device-auth runs RFC 8628 and persists only the resulting xAI session")
    func deviceFlagUsesRealDeviceTransportWithoutAPIKey() async throws {
        let fixture = try XAIDeviceLoginFixture()
        defer { fixture.dispose() }
        let token = try fixture.tokenResponse()
        let transport = MockHTTPTransport(responses: [try fixture.deviceResponse(), token.response])
        let environment = fixture.environment
        let (streams, output, errors) = CLIStreams.buffered()

        try await LiveAuthComposition.run(
            options: fixture.options(["--device-auth"], environment: environment),
            environment: environment,
            streams: streams,
            services: fixture.services(transport: transport)
        )

        #expect(transport.recordedRequests.count == 3)
        #expect(transport.recordedRequests[0].url.path == "/oauth2/device/code")
        #expect(transport.recordedRequests[1].url.path == "/oauth2/token")
        #expect(transport.recordedRequests[2].url.path == "/v1/user")
        #expect(transport.recordedRequests[0].headers["x-grok-client-surface"] == "headless")
        let store = try readAuthJSON(at: fixture.authFile)
        let scope = GrokComConfig.default(environment: environment).authScope
        #expect(store[scope]?.key == token.token)
        #expect(store[scope]?.authMode == .oidc)
        #expect(store[apiKeyScope] == nil)
        #expect(output.contents.contains("Signed in to xAI."))
        #expect(errors.contents.contains("ABCD-EFGH"))
        #expect(errors.contents.contains("https://accounts.example.test/device"))
        #expect(!output.contents.contains(token.token))
        #expect(!errors.contents.contains(token.token))
        #expect(!errors.contents.contains("private-server-device-code"))
        #expect(!errors.contents.contains("private-device-refresh-token"))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.home.appendingPathComponent(OpenGrokAuthPaths.codexAuthFileName).path
        ))
    }

    @Test("environment and [auth] select device transport without demanding an API key")
    func environmentAndConfigCanSelectDeviceLogin() async throws {
        for source in ["environment", "configuration"] {
            let fixture = try XAIDeviceLoginFixture()
            defer { fixture.dispose() }
            var environment = fixture.environment
            if source == "environment" {
                environment["GROK_LOGIN_DEVICE_FLOW"] = "true"
            } else {
                try "[auth]\nlogin_device_flow = true\n".write(
                    to: fixture.home.appendingPathComponent("config.toml"),
                    atomically: true,
                    encoding: .utf8
                )
            }
            let token = try fixture.tokenResponse()
            let transport = MockHTTPTransport(
                responses: [try fixture.deviceResponse(), token.response]
            )
            let (streams, _, _) = CLIStreams.buffered()

            try await LiveAuthComposition.run(
                options: fixture.options([], environment: environment),
                environment: environment,
                streams: streams,
                services: fixture.services(transport: transport)
            )

            #expect(transport.recordedRequests.count == 3)
            #expect(transport.recordedRequests[2].url.path == "/v1/user")
            #expect(FileManager.default.fileExists(atPath: fixture.authFile.path))
        }
    }

    @Test("--oauth overrides an environment-selected device flow")
    func explicitOAuthWinsOverEnvironmentDevicePreference() async throws {
        let fixture = try XAIDeviceLoginFixture()
        defer { fixture.dispose() }
        var environment = fixture.environment
        environment["GROK_LOGIN_DEVICE_FLOW"] = "true"
        let transport = MockHTTPTransport()
        let browserCalls = CallCounter()
        let services = fixture.services(transport: transport) { manager, _, _, _ in
            browserCalls.increment()
            let auth = GrokAuth(key: "private-browser-access-token", authMode: .oidc)
            try await manager.loginWithSession(auth)
            return auth
        }
        let (streams, output, errors) = CLIStreams.buffered()

        try await LiveAuthComposition.run(
            options: fixture.options(["--oauth"], environment: environment),
            environment: environment,
            streams: streams,
            services: services
        )

        #expect(browserCalls.count == 1)
        #expect(transport.recordedRequests.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.authFile.path))
        #expect(!output.contents.contains("private-browser-access-token"))
        #expect(!errors.contents.contains("private-browser-access-token"))
    }

    @Test("a 404 device endpoint falls back to xAI browser OAuth without crossing into Codex")
    func deviceEndpoint404FallsBackOnlyToXAIBrowser() async throws {
        let fixture = try XAIDeviceLoginFixture()
        defer { fixture.dispose() }
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 404)),
        ])
        let browserCalls = CallCounter()
        let services = fixture.services(transport: transport) { manager, _, _, _ in
            browserCalls.increment()
            let auth = GrokAuth(key: "private-fallback-access-token", authMode: .oidc)
            try await manager.loginWithSession(auth)
            return auth
        }
        let environment = fixture.environment
        let (streams, output, errors) = CLIStreams.buffered()

        try await LiveAuthComposition.run(
            options: fixture.options(["--device-auth"], environment: environment),
            environment: environment,
            streams: streams,
            services: services
        )

        #expect(transport.recordedRequests.count == 1)
        #expect(browserCalls.count == 1)
        #expect(errors.contents.contains("using browser sign-in"))
        #expect(!output.contents.contains("private-fallback-access-token"))
        #expect(!errors.contents.contains("private-fallback-access-token"))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.home.appendingPathComponent(OpenGrokAuthPaths.codexAuthFileName).path
        ))
    }

    @Test("other device endpoint failures never silently switch transports")
    func deviceEndpointServerFailureDoesNotFallback() async throws {
        let fixture = try XAIDeviceLoginFixture()
        defer { fixture.dispose() }
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 500)),
        ])
        let browserCalls = CallCounter()
        let services = fixture.services(transport: transport) { _, _, _, _ in
            browserCalls.increment()
            throw AuthError.notLoggedIn
        }
        let environment = fixture.environment
        let (streams, _, _) = CLIStreams.buffered()

        await #expect(throws: CLIApplicationError.self) {
            try await LiveAuthComposition.run(
                options: fixture.options(["--device-auth"], environment: environment),
                environment: environment,
                streams: streams,
                services: services
            )
        }

        #expect(browserCalls.count == 0)
        #expect(transport.recordedRequests.count == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.authFile.path))
    }

    @Test("device tokens violating a managed team pin are rejected before credential persistence")
    func devicePrincipalMustMatchManagedTeamBeforePersistence() async throws {
        let fixture = try XAIDeviceLoginFixture()
        defer { fixture.dispose() }
        try "[auth]\nforce_login_team_uuid = \"required-team\"\n".write(
            to: fixture.home.appendingPathComponent(REQUIREMENTS_FILENAME),
            atomically: true,
            encoding: .utf8
        )
        let token = try fixture.tokenResponse(principal: "wrong-team")
        let transport = MockHTTPTransport(responses: [try fixture.deviceResponse(), token.response])
        let environment = fixture.environment
        let (streams, output, errors) = CLIStreams.buffered()

        await #expect(throws: CLIApplicationError.self) {
            try await LiveAuthComposition.run(
                options: fixture.options(["--device-auth"], environment: environment),
                environment: environment,
                streams: streams,
                services: fixture.services(transport: transport)
            )
        }

        #expect(transport.recordedRequests.count == 2)
        #expect(!FileManager.default.fileExists(atPath: fixture.authFile.path))
        #expect(!output.contents.contains(token.token))
        #expect(!errors.contents.contains(token.token))
    }
}
