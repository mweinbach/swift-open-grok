import Foundation
import OpenGrokConfig
import OpenGrokHTTP
import OpenGrokModels
import OpenGrokShellSessionSupport
import OpenGrokTestSupport
import Testing
@testable import OpenGrokCLI

private struct EndpointLaunchOverrideFixture {
    let root: URL
    let home: URL
    let workspace: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "open-grok-endpoint-overrides-\(UUID().uuidString)",
            isDirectory: true
        )
        home = root.appendingPathComponent("state", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    var environment: [String: String] {
        [
            "HOME": root.path,
            "OPENGROK_HOME": home.path,
            "GROK_MANAGED_CONFIG": "false",
            "GROK_SANDBOX": "off",
            "XDG_STATE_HOME": root.appendingPathComponent("xdg-state").path,
            "XAI_API_KEY": "private-xai-api-key",
        ]
    }

    func dispose() {
        LiveManagedPolicyLifecycle.stop(environment: environment)
        try? FileManager.default.removeItem(at: root)
    }

    func write(_ value: String, named filename: String) throws {
        try value.write(
            to: home.appendingPathComponent(filename),
            atomically: true,
            encoding: .utf8
        )
    }

    func options(
        api: String? = nil,
        proxy: String? = nil,
        provider: String? = nil
    ) -> CLIExecutionOptions {
        CLIExecutionOptions(
            mode: .headless,
            common: CLICommonOptions(cwd: workspace.path, provider: provider),
            prompt: "endpoint parity",
            advanced: CLIAdvancedOptions(
                cliChatProxyBaseURL: proxy,
                xaiAPIBaseURL: api
            )
        )
    }

    func context(
        environment: [String: String]? = nil,
        streams: CLIStreams? = nil,
        control: CLIExecutionControl = .never
    ) -> CLIApplicationContext {
        CLIApplicationContext(
            environment: environment ?? self.environment,
            streams: streams ?? CLIStreams(out: { _ in }, err: { _ in }),
            control: control
        )
    }
}

@Suite("Session-scoped xAI endpoint CLI override parity", .serialized)
struct LiveEndpointLaunchOverrideParityTests {
    @Test("CLI API and proxy endpoints override only their own inherited environment values")
    func apiAndProxyRemainIndependentAndSessionScoped() throws {
        let fixture = try EndpointLaunchOverrideFixture()
        defer { fixture.dispose() }
        var original = fixture.environment
        original["GROK_XAI_API_BASE_URL"] = "https://inherited-api.example/v1"
        original["GROK_CLI_CHAT_PROXY_BASE_URL"] = "https://inherited-proxy.example/v1"
        let (streams, output, _) = CLIStreams.buffered()
        let control = CLIExecutionControl(
            isCancelled: { true },
            waitForCancellation: {}
        )
        let context = fixture.context(environment: original, streams: streams, control: control)

        let derived = try LiveEndpointLaunchOverrides.applying(
            options: fixture.options(
                api: "HTTPS://CLI-API.EXAMPLE/v1/",
                proxy: "https://cli-proxy.example/v2/"
            ),
            to: context
        )

        #expect(derived.environment["GROK_XAI_API_BASE_URL"] == "https://cli-api.example/v1")
        #expect(derived.environment["GROK_CLI_CHAT_PROXY_BASE_URL"]
            == "https://cli-proxy.example/v2")
        #expect(derived.environment[LiveEndpointLaunchOverrides.xaiCommandLineMarker]
            == "https://cli-api.example/v1")
        #expect(context.environment["GROK_XAI_API_BASE_URL"]
            == "https://inherited-api.example/v1")
        #expect(context.environment["GROK_CLI_CHAT_PROXY_BASE_URL"]
            == "https://inherited-proxy.example/v1")
        #expect(context.environment[LiveEndpointLaunchOverrides.xaiCommandLineMarker] == nil)
        #expect(derived.control.isCancelled())
        derived.streams.out("same-stream")
        #expect(output.contents == "same-stream")
    }

    @Test("an API-only override never changes the proxy or auxiliary-service authority")
    func apiOverrideDoesNotRedirectProxyServices() throws {
        let fixture = try EndpointLaunchOverrideFixture()
        defer { fixture.dispose() }
        var environment = fixture.environment
        environment["GROK_CLI_CHAT_PROXY_BASE_URL"] = "https://owned-proxy.example/v1"

        let derived = try LiveEndpointLaunchOverrides.applying(
            options: fixture.options(api: "https://inference-only.example/v3"),
            to: fixture.context(environment: environment)
        )

        #expect(derived.environment["GROK_XAI_API_BASE_URL"]
            == "https://inference-only.example/v3")
        #expect(derived.environment["GROK_CLI_CHAT_PROXY_BASE_URL"]
            == "https://owned-proxy.example/v1")
        #expect(EndpointsConfig(
            cliChatProxyBaseURL: derived.environment["GROK_CLI_CHAT_PROXY_BASE_URL"],
            xaiApiBaseURL: derived.environment["GROK_XAI_API_BASE_URL"] ?? ""
        ).proxyURL() == "https://owned-proxy.example/v1")
    }

    @Test("the production feedback client sends its bearer only to the distinct CLI proxy")
    func realAuxiliaryClientUsesProxyInsteadOfInferenceEndpoint() async throws {
        let fixture = try EndpointLaunchOverrideFixture()
        defer { fixture.dispose() }
        var environment = fixture.environment
        environment["GROK_FEEDBACK_ENABLED"] = "true"
        let context = try LiveEndpointLaunchOverrides.applying(
            options: fixture.options(
                api: "https://inference-only.example/v1",
                proxy: "https://auxiliary-only.example/v1"
            ),
            to: fixture.context(environment: environment)
        )
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200))
        ])
        let feedback = try await LiveFeedbackComposition.production(
            sessionID: "endpoint-proxy-isolation",
            openGrokHome: fixture.home,
            environment: context.environment,
            boundary: ExportBoundary(),
            transport: transport
        )

        let outcome = try await feedback.submitText("the explicit proxy owns auxiliary traffic")

        #expect(outcome == .persistedAndUploaded)
        let request = try #require(transport.recordedRequests.first)
        #expect(request.url.absoluteString == "https://auxiliary-only.example/v1/feedback")
        #expect(request.headers["Authorization"] == "Bearer private-xai-api-key")
        #expect(request.url.host != "inference-only.example")
    }

    @Test("a proxy-only override cannot manufacture xAI inference command-line authority")
    func proxyOverrideDoesNotRedirectInference() throws {
        let fixture = try EndpointLaunchOverrideFixture()
        defer { fixture.dispose() }
        var environment = fixture.environment
        environment["GROK_XAI_API_BASE_URL"] = "https://owned-inference.example/v1"
        environment[LiveEndpointLaunchOverrides.xaiCommandLineMarker] =
            "https://forged-inference.example/v1"

        let derived = try LiveEndpointLaunchOverrides.applying(
            options: fixture.options(proxy: "https://explicit-proxy.example/v4"),
            to: fixture.context(environment: environment)
        )

        #expect(derived.environment["GROK_CLI_CHAT_PROXY_BASE_URL"]
            == "https://explicit-proxy.example/v4")
        #expect(derived.environment["GROK_XAI_API_BASE_URL"]
            == "https://owned-inference.example/v1")
        #expect(derived.environment[LiveEndpointLaunchOverrides.xaiCommandLineMarker] == nil)
    }

    @Test("forged command-line provenance is stripped even when no endpoint flag is present")
    func callerCannotForgeCommandLineEndpointAuthority() throws {
        let fixture = try EndpointLaunchOverrideFixture()
        defer { fixture.dispose() }
        var environment = fixture.environment
        environment[LiveEndpointLaunchOverrides.xaiCommandLineMarker] =
            "https://attacker.example/private"

        let derived = try LiveEndpointLaunchOverrides.applying(
            options: fixture.options(),
            to: fixture.context(environment: environment)
        )

        #expect(derived.environment[LiveEndpointLaunchOverrides.xaiCommandLineMarker] == nil)
        #expect(environment[LiveEndpointLaunchOverrides.xaiCommandLineMarker]
            == "https://attacker.example/private")
    }

    @Test("ordinary launches do not inspect administrator files or mutate their context")
    func noOverridePerformsNoConfigIO() throws {
        let fixture = try EndpointLaunchOverrideFixture()
        defer { fixture.dispose() }
        try fixture.write("[malformed\nsecret = private\n", named: MANAGED_CONFIG_FILENAME)
        let original = fixture.context()

        let derived = try LiveEndpointLaunchOverrides.applying(
            options: fixture.options(),
            to: original
        )

        #expect(derived.environment == original.environment)
        #expect(derived.environment[LiveEndpointLaunchOverrides.xaiCommandLineMarker] == nil)
    }

    @Test(
        "administrator-managed and requirements endpoint pins cannot be replaced",
        arguments: [MANAGED_CONFIG_FILENAME, REQUIREMENTS_FILENAME]
    )
    func administrativeEndpointPinsWin(_ filename: String) throws {
        let fixture = try EndpointLaunchOverrideFixture()
        defer { fixture.dispose() }
        try fixture.write("""
        [endpoints]
        xai_api_base_url = "https://managed-api.example/v1"
        cli_chat_proxy_base_url = "https://managed-proxy.example/v1"
        """, named: filename)

        for options in [
            fixture.options(api: "https://owner-api.example/v1"),
            fixture.options(proxy: "https://owner-proxy.example/v1"),
        ] {
            do {
                _ = try LiveEndpointLaunchOverrides.applying(
                    options: options,
                    to: fixture.context()
                )
                Issue.record("expected an administrator-managed endpoint to win")
            } catch let error as CLIApplicationError {
                #expect(error.description.contains("administrator-managed endpoint"))
            }
        }
    }

    @Test("a CLI endpoint matching its normalized managed pin remains usable")
    func matchingAdministratorEndpointIsAccepted() throws {
        let fixture = try EndpointLaunchOverrideFixture()
        defer { fixture.dispose() }
        try fixture.write("""
        [endpoints]
        xai_api_base_url = "HTTPS://MANAGED-API.EXAMPLE/v1/"
        """, named: REQUIREMENTS_FILENAME)

        let derived = try LiveEndpointLaunchOverrides.applying(
            options: fixture.options(api: "https://managed-api.example/v1"),
            to: fixture.context()
        )

        #expect(derived.environment["GROK_XAI_API_BASE_URL"]
            == "https://managed-api.example/v1")
    }

    @Test("malformed administrator requirements fail closed without applying overrides")
    func malformedRequirementsCannotEraseAnEndpointPin() throws {
        let fixture = try EndpointLaunchOverrideFixture()
        defer { fixture.dispose() }
        try fixture.write("[endpoints\nxai_api_base_url = secret\n", named: REQUIREMENTS_FILENAME)

        #expect(throws: (any Error).self) {
            try LiveEndpointLaunchOverrides.applying(
                options: fixture.options(api: "https://owner.example/v1"),
                to: fixture.context()
            )
        }
    }

    @Test(
        "unsafe endpoint URLs fail closed without disclosing embedded credential material",
        arguments: [
            "",
            "relative/path",
            "ftp://proxy.example/v1",
            "http://public.example/v1",
            "https://user:private-bearer@proxy.example/v1",
            "https://proxy.example/v1?token=private-bearer",
            "https://proxy.example/v1#private-bearer",
            "https://proxy.example/v1/../private-bearer",
            "https://proxy.example/v1\nprivate-bearer",
            "https://proxy.example/v1 private-bearer",
        ]
    )
    func unsafeEndpointNeverLeaksSecrets(_ unsafe: String) throws {
        let fixture = try EndpointLaunchOverrideFixture()
        defer { fixture.dispose() }

        do {
            _ = try LiveEndpointLaunchOverrides.applying(
                options: fixture.options(api: unsafe),
                to: fixture.context()
            )
            Issue.record("expected an unsafe command-line endpoint to fail closed")
        } catch let error as CLIApplicationError {
            #expect(error.description.contains("--xai-api-base-url"))
            #expect(!error.description.contains("private-bearer"))
            #expect(!error.description.contains("user:"))
        }
    }

    @Test(
        "explicit localhost and IPv4 loopback may use HTTP for hermetic development",
        arguments: ["http://127.0.0.1:9452/v1/", "http://localhost:9452/v1/"]
    )
    func explicitLoopbackHTTPIsSupported(_ endpoint: String) throws {
        let fixture = try EndpointLaunchOverrideFixture()
        defer { fixture.dispose() }

        let derived = try LiveEndpointLaunchOverrides.applying(
            options: fixture.options(api: endpoint),
            to: fixture.context()
        )

        #expect(derived.environment["GROK_XAI_API_BASE_URL"]
            == String(endpoint.dropLast()))
    }

    @Test("an explicit xAI CLI endpoint outranks owner config only for the xAI provider")
    func commandLinePrecedenceCannotCrossProviderBoundaries() throws {
        let fixture = try EndpointLaunchOverrideFixture()
        defer { fixture.dispose() }
        var environment = fixture.environment
        environment["GROK_CODEX_INFERENCE_BASE_URL"] = "https://codex-owner.example/v1"

        let derived = try LiveEndpointLaunchOverrides.applying(
            options: fixture.options(api: "https://cli-xai.example/v1", provider: "codex"),
            to: fixture.context(environment: environment)
        )

        #expect(OpenGrokLiveApplicationLauncher.resolveProviderBaseURL(
            provider: .xai,
            model: nil,
            environment: derived.environment,
            configuredXaiBaseURL: "https://owner-xai.example/v1"
        ) == "https://cli-xai.example/v1")
        #expect(OpenGrokLiveApplicationLauncher.resolveProviderBaseURL(
            provider: .codex,
            model: nil,
            environment: derived.environment,
            configuredXaiBaseURL: nil
        ) == "https://codex-owner.example/v1")
    }

    @Test("the actual live CLI sends xAI inference to the explicit loopback endpoint")
    func liveCLIHonorsInferenceEndpointOverOwnerConfiguration() async throws {
        let fixture = try EndpointLaunchOverrideFixture()
        defer { fixture.dispose() }
        let server = try MockInferenceServer()
        defer { server.stop() }
        try fixture.write("""
        [endpoints]
        xai_api_base_url = "http://127.0.0.1:9/v1"
        """, named: "config.toml")

        let (streams, output, errors) = CLIStreams.buffered()
        let code = await CLIRunner.run(
            [
                "headless", "--prompt", "endpoint parity", "--cwd", fixture.workspace.path,
                "--xai-api-base-url", server.url,
            ],
            environment: fixture.environment,
            streams: streams,
            application: .live(
                dependencies: OpenGrokLiveCompositionDependencies(
                    makeSampler: OpenGrokLiveSampler.production(configuration:)
                ),
                control: .never
            )
        )

        #expect(code == CLIRunner.ExitCode.success.rawValue)
        let inference = try #require(server.requests().first { request in
            request.method == "POST"
                && (request.path.contains("/chat/completions")
                    || request.path.contains("/responses"))
        })
        #expect(inference.authorization == "Bearer private-xai-api-key")
        #expect(errors.contents.contains("nothing in this composition honors yet") == false)
        #expect(!output.contents.contains("private-xai-api-key"))
        #expect(!errors.contents.contains("private-xai-api-key"))
    }
}
