import Foundation
import OpenGrokHTTP
import OpenGrokSamplingTypes
import Testing
@testable import OpenGrokCLI

private final class LiveClientIdentityCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: OpenGrokLiveSamplingConfiguration?
    private var leaderValue: String?

    func record(_ configuration: OpenGrokLiveSamplingConfiguration) {
        lock.withLock { value = configuration }
    }

    var configuration: OpenGrokLiveSamplingConfiguration? {
        lock.withLock { value }
    }

    func recordLeader(_ identifier: String) {
        lock.withLock { leaderValue = identifier }
    }

    var leaderIdentifier: String? {
        lock.withLock { leaderValue }
    }
}

private struct LiveClientIdentityFixture {
    let root: URL
    let workspace: URL
    let home: URL
    let environment: [String: String]

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-client-identity-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        home = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        environment = [
            "HOME": root.path,
            "OPENGROK_HOME": home.path,
            "GROK_SANDBOX": "off",
            "XAI_API_KEY": "client-identity-test-key",
        ]
    }

    func cleanup() {
        LiveManagedPolicyLifecycle.stop(environment: environment)
        try? FileManager.default.removeItem(at: root)
    }

    func dependencies(capture: LiveClientIdentityCapture) -> OpenGrokLiveCompositionDependencies {
        OpenGrokLiveCompositionDependencies(
            makeSampler: { configuration in
                capture.record(configuration)
                return OpenGrokLiveSampler { _, emit in
                    await emit(.output("identified"))
                    return OpenGrokLiveSamplingResponse(output: "identified")
                }
            }
        )
    }
}

@Suite("live client identifier follows provider, leader, and approval boundaries")
struct LiveClientIdentityParityTests {
    private func transport() -> MockHTTPTransport {
        let chunk = #"{"id":"client-identity","object":"chat.completion.chunk","created":0,"model":"test-model","choices":[{"index":0,"delta":{"role":"assistant","content":"identified"},"finish_reason":"stop"}]}"#
        return MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream"]
                ),
                body: Data("data: \(chunk)\n\ndata: [DONE]\n\n".utf8)
            ),
        ])
    }

    @Test("the actual xAI production request carries the session client identifier")
    func productionXAIRequestCarriesIdentifier() async throws {
        let transport = transport()
        let sampler = try OpenGrokLiveSampler.production(
            configuration: OpenGrokLiveSamplingConfiguration(
                model: "test-model",
                baseURL: "https://provider.example.test",
                apiKey: "client-identity-test-key",
                clientIdentifier: "grok-desktop",
                transport: transport
            )
        )

        let result = try await sampler.sample(
            OpenGrokLiveSamplingRequest(
                sessionID: "identity-session",
                turnID: "identity-turn",
                model: "test-model",
                prompt: "identify this request"
            ),
            emit: { _ in }
        )

        #expect(result.output == "identified")
        let request = try #require(transport.recordedRequests.first)
        #expect(request.headers["x-grok-client-identifier"] == "grok-desktop")
    }

    @Test("non-xAI providers never receive the xAI client-identity header")
    func foreignProviderNeverReceivesClientIdentifier() async throws {
        let transport = transport()
        let sampler = try OpenGrokLiveSampler.production(
            configuration: OpenGrokLiveSamplingConfiguration(
                model: "test-model",
                baseURL: "https://provider.example.test",
                apiKey: "foreign-provider-test-key",
                provider: .fireworks,
                clientIdentifier: "private-xai-client",
                transport: transport
            )
        )

        _ = try await sampler.sample(
            OpenGrokLiveSamplingRequest(
                sessionID: "foreign-session",
                turnID: "foreign-turn",
                model: "test-model",
                prompt: "preserve provider isolation"
            ),
            emit: { _ in }
        )

        let request = try #require(transport.recordedRequests.first)
        #expect(request.headers["x-grok-client-identifier"] == nil)
    }

    @Test("the genuine headless CLI honors its client-identifier flag")
    func actualHeadlessLaunchCarriesClientIdentity() async throws {
        let fixture = try LiveClientIdentityFixture()
        defer { fixture.cleanup() }
        let capture = LiveClientIdentityCapture()
        let streams = CLIStreams.buffered()

        let status = await CLIRunner.run(
            [
                "headless", "--prompt", "identify me", "--cwd", fixture.workspace.path,
                "--model", "grok-4.5", "--client-identifier", "grok-desktop",
            ],
            environment: fixture.environment,
            streams: streams.0,
            application: .live(dependencies: fixture.dependencies(capture: capture), control: .never)
        )

        #expect(status == CLIRunner.ExitCode.success.rawValue, "launch failed: \(streams.2.contents)")
        #expect(capture.configuration?.clientIdentifier == "grok-desktop")
        #expect(streams.1.contents.contains("identified"))
    }

    @Test("persisted project approvals are isolated and safely named per client")
    func projectApprovalsRemainClientScoped() async throws {
        let fixture = try LiveClientIdentityFixture()
        defer { fixture.cleanup() }
        let command = try CLICommandParser.parseOrThrow([
            "headless", "--prompt", "scope approvals", "--cwd", fixture.workspace.path,
            "--model", "grok-4.5", "--client-identifier", "desktop/client.alpha",
        ])
        guard case .launch(let options) = command else {
            Issue.record("client identity fixture did not produce launch options")
            return
        }
        let capture = LiveClientIdentityCapture()
        let foundation = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: options,
            context: CLIApplicationContext(
                environment: fixture.environment,
                streams: CLIStreams(out: { _ in }, err: { _ in }),
                control: .never
            ),
            dependencies: fixture.dependencies(capture: capture)
        )
        let handle = try #require(await foundation.toolExecutor.permissionHandle())
        let file = try #require(await handle.projectApprovalStateURL)

        #expect(file.lastPathComponent == "permission_desktop_client_alpha.toml")
        #expect(file.path.hasPrefix(fixture.home.path + "/"))
        #expect(foundation.samplingConfiguration.clientIdentifier == "desktop/client.alpha")
        await foundation.toolExecutor.shutdown()
    }

    @Test("leader initialization preserves the authenticated session client identity")
    func leaderConnectionReceivesClientIdentity() async throws {
        let fixture = try LiveClientIdentityFixture()
        defer { fixture.cleanup() }
        let capture = LiveClientIdentityCapture()
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                throw CLIApplicationError.failed("leader launch unexpectedly built a sampler")
            },
            makeLeaderClient: { configuration in
                capture.recordLeader(configuration.clientType)
                throw CLIApplicationError.failed("leader identity observed")
            }
        )
        let command = try CLICommandParser.parseOrThrow([
            "headless", "--prompt", "leader identity", "--cwd", fixture.workspace.path,
            "--leader", "--sandbox", "off", "--client-identifier", "grok-desktop",
        ])
        let context = CLIApplicationContext(
            environment: fixture.environment,
            streams: CLIStreams(out: { _ in }, err: { _ in }),
            control: .never
        )

        do {
            _ = try await OpenGrokLiveApplicationLauncher(dependencies: dependencies)
                .launcher.start(command, context)
            Issue.record("leader fixture unexpectedly returned a connected session")
        } catch let error as CLIApplicationError {
            #expect(error == .failed("leader identity observed"))
        }
        #expect(capture.leaderIdentifier == "grok-desktop")
    }

    @Test("provider switching retains the original root-session client identity")
    func catalogResolutionRetainsRootClientIdentity() async throws {
        let fixture = try LiveClientIdentityFixture()
        defer { fixture.cleanup() }
        let resolver = LiveModelCatalogResolver(
            environment: fixture.environment,
            openGrokHome: fixture.home,
            sessionID: "identity-catalog-session",
            workingDirectory: fixture.workspace,
            clientIdentifier: "grok-desktop"
        )

        let resolved = try await resolver.resolve(modelID: "grok-4.5")
        #expect(resolved.sampling.clientIdentifier == "grok-desktop")
        #expect(resolved.sampling.withCodexPermissions(nil).clientIdentifier == "grok-desktop")
    }

    @Test("control characters in client identifiers fail before provider construction")
    func controlCharactersCannotBecomeProviderHeaders() async throws {
        let fixture = try LiveClientIdentityFixture()
        defer { fixture.cleanup() }
        let capture = LiveClientIdentityCapture()
        let streams = CLIStreams.buffered()

        let status = await CLIRunner.run(
            [
                "headless", "--prompt", "reject injection", "--cwd", fixture.workspace.path,
                "--model", "grok-4.5", "--client-identifier", "desktop\r\nAuthorization: stolen",
            ],
            environment: fixture.environment,
            streams: streams.0,
            application: .live(dependencies: fixture.dependencies(capture: capture), control: .never)
        )

        #expect(status == CLIRunner.ExitCode.failure.rawValue)
        #expect(streams.2.contents.contains("--client-identifier"))
        #expect(capture.configuration == nil)
    }
}
