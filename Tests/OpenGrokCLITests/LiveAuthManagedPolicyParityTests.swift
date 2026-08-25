import Foundation
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokHTTP
import Testing
@testable import OpenGrokCLI

private struct ManagedAuthPolicyFixture {
    let root: URL
    let home: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "open-grok-managed-auth-policy-\(UUID().uuidString)"
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

    func write(_ contents: String, to filename: String) throws {
        try contents.write(
            to: home.appendingPathComponent(filename),
            atomically: true,
            encoding: .utf8
        )
    }

    func dispose() {
        LiveManagedPolicyLifecycle.stop(environment: environment)
        try? FileManager.default.removeItem(at: root)
    }

    func services(transport: MockHTTPTransport = MockHTTPTransport()) -> LiveAuthServices {
        LiveAuthServices(
            makeTransport: { transport },
            codexBrowserLogin: { _, _, _, _ in throw AuthError.notLoggedIn },
            codexDeviceLogin: { _, _, _, _ in throw AuthError.notLoggedIn },
            openBrowser: nil,
            readSecretLine: { nil },
            isInteractive: { false },
            managedPolicySetupServices: LiveManagedSetupServices(
                makeTransport: { MockHTTPTransport() }
            )
        )
    }

    func loginOptions(_ arguments: [String], environment: [String: String]) throws -> CLIUtilityOptions {
        let command = try CLICommandParser.parseOrThrow(
            ["login"] + arguments,
            environment: environment
        )
        guard case .utility(let options) = command else {
            throw CLIApplicationError.failed("login did not reach the CLI auth route")
        }
        return options
    }
}

@Suite("Managed xAI login policy parity")
struct LiveAuthManagedPolicyParityTests {
    @Test("requirements deny the real parsed login before environment keys or network are used")
    func requirementsBlockEnvironmentAPIKeyBeforeAnySideEffect() async throws {
        let fixture = try ManagedAuthPolicyFixture()
        defer { fixture.dispose() }
        try fixture.write(
            "[grok_com_config]\ndisable_api_key_auth = true\n",
            to: REQUIREMENTS_FILENAME
        )
        try fixture.write("[auth]\ndisable_api_key_auth = false\n", to: "config.toml")
        var environment = fixture.environment
        environment["XAI_API_KEY"] = "private-managed-denied-key"
        environment["GROK_DISABLE_API_KEY_AUTH"] = "false"
        let options = try fixture.loginOptions([], environment: environment)
        let transport = MockHTTPTransport()
        let (streams, output, errors) = CLIStreams.buffered()

        await #expect(throws: CLIApplicationError.self) {
            try await LiveAuthComposition.run(
                options: options,
                environment: environment,
                streams: streams,
                services: fixture.services(transport: transport)
            )
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.authFile.path))
        #expect(transport.recordedRequests.isEmpty)
        #expect(!output.contents.contains("private-managed-denied-key"))
        #expect(!errors.contents.contains("private-managed-denied-key"))
    }

    @Test("malformed personal configuration cannot erase an administrator's managed denial")
    func malformedUserConfigurationCannotBypassManagedPolicy() async throws {
        let fixture = try ManagedAuthPolicyFixture()
        defer { fixture.dispose() }
        try fixture.write(
            "[auth]\ndisable_api_key_auth = true\n",
            to: MANAGED_CONFIG_FILENAME
        )
        try fixture.write("[broken\nsecret = \"private-personal-secret\"\n", to: "config.toml")
        var environment = fixture.environment
        environment["GROK_DISABLE_API_KEY_AUTH"] = "false"
        let options = try fixture.loginOptions(
            ["xai", "private-positional-secret"],
            environment: environment
        )
        let transport = MockHTTPTransport()
        let (streams, output, errors) = CLIStreams.buffered()

        await #expect(throws: CLIApplicationError.self) {
            try await LiveAuthComposition.run(
                options: options,
                environment: environment,
                streams: streams,
                services: fixture.services(transport: transport)
            )
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.authFile.path))
        #expect(transport.recordedRequests.isEmpty)
        #expect(!output.contents.contains("private-positional-secret"))
        #expect(!errors.contents.contains("private-positional-secret"))
    }

    @Test("team requirements implicitly forbid API keys, including empty fail-closed lists")
    func teamRequirementDisallowsPositionalAPIKeys() async throws {
        for teamValue in ["\"managed-team\"", "[]"] {
            let fixture = try ManagedAuthPolicyFixture()
            defer { fixture.dispose() }
            try fixture.write(
                "[auth]\nforce_login_team_uuid = \(teamValue)\n",
                to: REQUIREMENTS_FILENAME
            )
            let environment = fixture.environment
            let options = try fixture.loginOptions(
                ["xai", "private-team-denied-key"],
                environment: environment
            )
            let (streams, output, errors) = CLIStreams.buffered()

            await #expect(throws: CLIApplicationError.self) {
                try await LiveAuthComposition.run(
                    options: options,
                    environment: environment,
                    streams: streams,
                    services: fixture.services()
                )
            }

            #expect(!FileManager.default.fileExists(atPath: fixture.authFile.path))
            #expect(!output.contents.contains("private-team-denied-key"))
            #expect(!errors.contents.contains("private-team-denied-key"))
        }
    }

    @Test("trusted team restrictions intersect rather than being widened by the effective document")
    func effectiveDocumentCannotWidenAdministratorTeamPolicy() throws {
        let fixture = try ManagedAuthPolicyFixture()
        defer { fixture.dispose() }
        try fixture.write(
            "[grok_com_config]\nforce_login_team_uuid = [\"team-a\", \"team-b\"]\n",
            to: MANAGED_CONFIG_FILENAME
        )
        try fixture.write(
            "[auth]\nforce_login_team_uuid = [\"team-b\", \"team-c\"]\n",
            to: REQUIREMENTS_FILENAME
        )
        let untrustedOverride = try parseTOML(
            "[grok_com_config]\nforce_login_team_uuid = [\"team-b\", \"team-c\"]\n"
        )

        let config = try LiveAuthComposition.effectiveGrokComConfig(
            environment: fixture.environment,
            document: untrustedOverride
        )

        #expect(config.forceLoginTeamUUID == .single("team-b"))
        #expect(config.apiKeyAuthDisabled(environment: fixture.environment))
    }

    @Test("malformed administrator policy fails closed without creating credential state")
    func malformedAdministratorPolicyFailsClosed() async throws {
        let fixture = try ManagedAuthPolicyFixture()
        defer { fixture.dispose() }
        try fixture.write(
            "[grok_com_config]\ndisable_api_key_auth = \"false\"\n",
            to: MANAGED_CONFIG_FILENAME
        )
        let environment = fixture.environment
        let options = try fixture.loginOptions(
            ["private-malformed-policy-secret"],
            environment: environment
        )
        let transport = MockHTTPTransport()
        let (streams, output, errors) = CLIStreams.buffered()

        await #expect(throws: CLIApplicationError.self) {
            try await LiveAuthComposition.run(
                options: options,
                environment: environment,
                streams: streams,
                services: fixture.services(transport: transport)
            )
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.authFile.path))
        #expect(transport.recordedRequests.isEmpty)
        #expect(!output.contents.contains("private-malformed-policy-secret"))
        #expect(!errors.contents.contains("private-malformed-policy-secret"))
    }

    @Test("an xAI administrator restriction does not block independent provider credentials")
    func managedXAIPolicyDoesNotBlockIndependentProvider() async throws {
        let fixture = try ManagedAuthPolicyFixture()
        defer { fixture.dispose() }
        try fixture.write(
            "[auth]\ndisable_api_key_auth = true\nforce_login_team_uuid = \"team-only\"\n",
            to: REQUIREMENTS_FILENAME
        )
        let environment = fixture.environment
        let options = try fixture.loginOptions(
            ["kimi", "private-independent-kimi-key"],
            environment: environment
        )
        let (streams, output, errors) = CLIStreams.buffered()

        try await LiveAuthComposition.run(
            options: options,
            environment: environment,
            streams: streams,
            services: fixture.services()
        )

        #expect(readProviderAPIKey(grokHome: fixture.home, provider: "kimi")
            == "private-independent-kimi-key")
        #expect(!output.contents.contains("private-independent-kimi-key"))
        #expect(!errors.contents.contains("private-independent-kimi-key"))
    }
}
