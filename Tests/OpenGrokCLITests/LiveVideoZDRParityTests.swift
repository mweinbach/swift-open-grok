// Rust reference, pin 00e176c8:
// `xai-grok-shell/src/config/mod.rs:890-950`;
// `xai-grok-shell/src/agent/mvp_agent/agent_ops.rs:2289-2318`;
// `xai-grok-tools/src/implementations/grok_build/video_gen/mod.rs:749-774`.

import Foundation
import OpenGrokConfig
import OpenGrokHTTP
import OpenGrokSamplingTypes
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokWorkspace
import Testing

@testable import OpenGrokCLI

private final class VideoZDRSamplingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [OpenGrokLiveSamplingRequest] = []

    func append(_ request: OpenGrokLiveSamplingRequest) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(request)
    }

    var requests: [OpenGrokLiveSamplingRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private struct VideoZDRFixture {
    let root: URL
    let home: URL
    let state: URL
    let workspace: URL
    let environment: [String: String]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "open-grok-video-zdr-\(UUID().uuidString)",
            isDirectory: true
        )
        home = root.appendingPathComponent("home", isDirectory: true)
        state = root.appendingPathComponent("state", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)

        for directory in [home, state, workspace] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": state.path,
            "GROK_FOLDER_TRUST": "1",
            "GROK_SANDBOX": "off",
            "GROK_VIDEO_GEN": "1",
            "XAI_API_KEY": "video-zdr-test-key",
            "XDG_STATE_HOME": state.appendingPathComponent("xdg-state").path,
        ]
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeUser(_ contents: String) throws {
        try write(contents, to: state.appendingPathComponent("config.toml"))
    }

    func writeManaged(_ contents: String) throws {
        try write(contents, to: state.appendingPathComponent("managed_config.toml"))
    }

    func writeRequirements(_ contents: String) throws {
        try write(contents, to: state.appendingPathComponent("requirements.toml"))
    }

    func writeProject(_ contents: String) throws {
        let directory = workspace.appendingPathComponent(".opengrok", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(contents, to: directory.appendingPathComponent("config.toml"))
    }

    func trustProject() throws {
        var trust = PersistentFolderTrustStore(environment: environment)
        try trust.record(workspace, trusted: true)
    }

    func security(environment override: [String: String]? = nil) -> LiveSecurityContext {
        LiveSecurityContext.resolve(
            workspaceRoot: workspace,
            environment: override ?? environment,
            isInteractive: false
        )
    }

    func availability(
        environment override: [String: String]? = nil,
        effectiveConfig: TOMLValue? = nil,
        provider: ModelProvider = .xai
    ) -> LiveVideoToolAvailability {
        LiveVideoToolComposition.resolveAvailability(
            workingDirectory: workspace,
            openGrokHome: state,
            environment: override ?? environment,
            effectiveConfig: effectiveConfig,
            samplingProvider: provider,
            samplingAPIKey: "sampling-provider-test-key",
            samplingBaseURL: provider == .xai
                ? "https://api.x.ai/v1"
                : "https://foreign-provider.invalid/v1"
        )
    }

    func runHeadless(
        transport: MockHTTPTransport,
        environment override: [String: String]? = nil
    ) async -> (code: Int32, requests: [OpenGrokLiveSamplingRequest], stderr: String) {
        let recorder = VideoZDRSamplingRecorder()
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { request, emit in
                    recorder.append(request)
                    await emit(.output("video privacy verified"))
                    return OpenGrokLiveSamplingResponse(output: "video privacy verified")
                }
            },
            makeImageTransport: { transport }
        )
        let streams = CLIStreams.buffered()
        let code = await CLIRunner.run(
            [
                "headless", "--prompt", "verify video privacy", "--cwd", workspace.path,
                "--model", "grok-4.5",
            ],
            environment: override ?? environment,
            streams: streams.0,
            application: OpenGrokApplication.live(dependencies: dependencies, control: .never)
        )
        return (code, recorder.requests, streams.2.contents)
    }

    private func write(_ contents: String, to path: URL) throws {
        try contents.write(to: path, atomically: true, encoding: .utf8)
    }
}

private let protectedVideoNames: Set<String> = [
    "video_gen", "image_to_video", "reference_to_video",
]

@Suite("video generation ZDR policy parity", .serialized)
struct LiveVideoZDRParityTests {
    @Test("ordinary xAI video remains available when no protection is requested")
    func ordinaryVideoRemainsAvailable() throws {
        let fixture = try VideoZDRFixture()
        defer { fixture.dispose() }

        let availability = fixture.availability()
        #expect(availability.config.isEnabled)
        #expect(availability.imageToVideoEnabled)
        #expect(availability.referenceToVideoEnabled)
    }

    @Test("upstream's two true environment spellings close both video tools", arguments: ["1", "true"])
    func environmentEnablesProtection(_ value: String) throws {
        let fixture = try VideoZDRFixture()
        defer { fixture.dispose() }
        var environment = fixture.environment
        environment["GROK_DISABLE_ZDR_INCOMPATIBLE_TOOLS"] = value

        let availability = fixture.availability(environment: environment)
        #expect(availability.config.isEnabled == false)
        #expect(availability.imageToVideoEnabled == false)
        #expect(availability.referenceToVideoEnabled == false)
    }

    @Test("upstream's two false environment spellings override effective protection", arguments: ["0", "false"])
    func environmentCanExplicitlyDisableProtection(_ value: String) throws {
        let fixture = try VideoZDRFixture()
        defer { fixture.dispose() }
        try fixture.writeManaged("[tools]\ndisable_zdr_incompatible_tools = true\n")
        var environment = fixture.environment
        environment["GROK_DISABLE_ZDR_INCOMPATIBLE_TOOLS"] = value
        let security = fixture.security(environment: environment)

        let availability = fixture.availability(
            environment: environment,
            effectiveConfig: security.document
        )
        #expect(availability.config.isEnabled)
        #expect(availability.imageToVideoEnabled)
        #expect(availability.referenceToVideoEnabled)
    }

    @Test(
        "invalid environment spellings never clear the effective protection bit",
        arguments: ["TRUE", "True", " true ", "yes", "on", "2", ""]
    )
    func invalidEnvironmentOverridePreservesProtection(_ value: String) throws {
        let fixture = try VideoZDRFixture()
        defer { fixture.dispose() }
        try fixture.writeUser("[tools]\ndisable_zdr_incompatible_tools = true\n")
        var environment = fixture.environment
        environment["GROK_DISABLE_ZDR_INCOMPATIBLE_TOOLS"] = value

        #expect(fixture.availability(environment: environment).advertisesAnything == false)
    }

    @Test(
        "stored xAI media credentials cannot bypass protection on another model provider",
        arguments: [
            ModelProvider.xai, .codex, .kimi, .runinfra, .gemini, .openRouter,
        ]
    )
    func everySamplingProviderRespectsManagedProtection(_ provider: ModelProvider) throws {
        let fixture = try VideoZDRFixture()
        defer { fixture.dispose() }
        try fixture.writeManaged("[tools]\ndisable_zdr_incompatible_tools = true\n")

        let availability = fixture.availability(provider: provider)
        #expect(availability.config.isEnabled == false)
        #expect(availability.advertisesAnything == false)
    }

    @Test("the owner config retains its upstream precedence over managed defaults")
    func userConfigOverridesManagedDefault() throws {
        let fixture = try VideoZDRFixture()
        defer { fixture.dispose() }
        try fixture.writeManaged("[tools]\ndisable_zdr_incompatible_tools = true\n")
        try fixture.writeUser("[tools]\ndisable_zdr_incompatible_tools = false\n")

        #expect(fixture.availability().advertisesAnything)
        #expect(fixture.availability(effectiveConfig: fixture.security().document).advertisesAnything)
    }

    @Test("only a trusted project can contribute its video protection policy")
    func trustedProjectPolicyUsesAuthoritativeSecurityDocument() throws {
        let fixture = try VideoZDRFixture()
        defer { fixture.dispose() }
        try fixture.writeUser("[tools]\ndisable_zdr_incompatible_tools = false\n")
        try fixture.writeProject("[tools]\ndisable_zdr_incompatible_tools = true\n")

        let untrusted = fixture.security()
        #expect(untrusted.projectTrusted == false)
        #expect(fixture.availability(effectiveConfig: untrusted.document).advertisesAnything)

        try fixture.trustProject()
        let trusted = fixture.security()
        #expect(trusted.projectTrusted)
        #expect(fixture.availability(effectiveConfig: trusted.document).advertisesAnything == false)
    }

    @Test("an untrusted project cannot erase an owner-managed protection policy")
    func untrustedProjectCannotClearManagedProtection() throws {
        let fixture = try VideoZDRFixture()
        defer { fixture.dispose() }
        try fixture.writeManaged("[tools]\ndisable_zdr_incompatible_tools = true\n")
        try fixture.writeProject("[tools]\ndisable_zdr_incompatible_tools = false\n")

        let security = fixture.security()
        #expect(security.projectTrusted == false)
        #expect(fixture.availability().advertisesAnything == false)
        #expect(fixture.availability(effectiveConfig: security.document).advertisesAnything == false)
    }

    @Test("requirements retain their final authority over owner and trusted project config")
    func requirementsOverrideTrustedProject() throws {
        let fixture = try VideoZDRFixture()
        defer { fixture.dispose() }
        try fixture.writeUser("[tools]\ndisable_zdr_incompatible_tools = false\n")
        try fixture.writeProject("[tools]\ndisable_zdr_incompatible_tools = false\n")
        try fixture.writeRequirements("[tools]\ndisable_zdr_incompatible_tools = true\n")
        try fixture.trustProject()

        let security = fixture.security()
        #expect(security.projectTrusted)
        #expect(fixture.availability(effectiveConfig: security.document).advertisesAnything == false)
    }

    @Test(
        "malformed S3 values cannot wipe a sibling protection bit",
        arguments: [
            "zdr_video_output_s3 = \"not a table\"",
            "zdr_video_output_s3 = 42",
            "[tools.zdr_video_output_s3]\nbucket = 42",
        ]
    )
    func malformedS3ConfigurationPreservesProtection(_ malformed: String) throws {
        let fixture = try VideoZDRFixture()
        defer { fixture.dispose() }
        try fixture.writeUser("""
        [tools]
        disable_zdr_incompatible_tools = true
        \(malformed)
        """)

        #expect(fixture.availability().config.isEnabled == false)
        #expect(fixture.availability(effectiveConfig: fixture.security().document).advertisesAnything == false)
    }

    @Test("a plausible S3 block cannot claim an unimplemented presigned upload path")
    func plausibleS3ConfigurationStillFailsClosed() throws {
        let fixture = try VideoZDRFixture()
        defer { fixture.dispose() }
        try fixture.writeUser("""
        [tools]
        disable_zdr_incompatible_tools = true

        [tools.zdr_video_output_s3]
        bucket = "team-owned-videos"
        region = "us-east-1"
        prefix = "generated/"

        [tools.zdr_video_output_s3.read_write]
        access_key_id = "team-access-key"
        secret_access_key = "team-secret-key"
        """)

        #expect(fixture.availability().advertisesAnything == false)
        #expect(fixture.availability(effectiveConfig: fixture.security().document).config.isEnabled == false)
    }

    @Test("an unused S3-looking block does not disable ordinary unprotected video")
    func unusedS3ConfigurationDoesNotChangeOrdinaryBehavior() throws {
        let fixture = try VideoZDRFixture()
        defer { fixture.dispose() }
        try fixture.writeUser("""
        [tools]
        disable_zdr_incompatible_tools = false

        [tools.zdr_video_output_s3]
        bucket = "team-owned-videos"
        region = "us-east-1"
        """)

        #expect(fixture.availability().advertisesAnything)
    }

    @Test("protected tools cannot advertise, dispatch, expose slash commands, or send HTTP")
    func protectedLiveExecutorHasNoVideoSurface() async throws {
        let fixture = try VideoZDRFixture()
        defer { fixture.dispose() }
        try fixture.writeManaged("[tools]\ndisable_zdr_incompatible_tools = true\n")
        let security = fixture.security()
        let transport = MockHTTPTransport()
        let sessionID = "video-zdr-\(UUID().uuidString)"
        let executor = try await LiveToolExecutor(
            processBackend: LocalShellProcessBackend(inheritedEnvironment: fixture.environment),
            sessionID: sessionID,
            workingDirectory: fixture.workspace,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            fileAccessPolicy: .allowAll,
            environment: fixture.environment,
            videoToolContext: LiveVideoToolContext(
                availability: fixture.availability(effectiveConfig: security.document),
                transport: transport
            ),
            securityContext: security
        )

        let advertised = Set(executor.tools.map(\.name))
        #expect(advertised.isDisjoint(with: protectedVideoNames))
        #expect(LiveImagineVideoCommand.registrations(
            advertisedToolNames: advertised
        ).isEmpty)

        for name in ["image_to_video", "reference_to_video"] {
            let result = await executor.invoke(
                sessionID: sessionID,
                workingDirectory: fixture.workspace,
                call: ToolCall(id: "blocked-\(name)", name: name, arguments: "{}")
            )
            guard case .failure = result else {
                Issue.record("protected \(name) unexpectedly dispatched")
                continue
            }
        }

        #expect(transport.recordedRequests.isEmpty)
        await executor.shutdown()
    }

    @Test("trusted project protection is absent from the actual provider request and slash surface")
    func protectedTrustedProjectNeverReachesActualModelSchema() async throws {
        let fixture = try VideoZDRFixture()
        defer { fixture.dispose() }
        try fixture.writeProject("[tools]\ndisable_zdr_incompatible_tools = true\n")
        try fixture.trustProject()
        let transport = MockHTTPTransport()

        let result = await fixture.runHeadless(transport: transport)
        #expect(result.code == 0, "headless launch failed: \(result.stderr)")
        let request = try #require(result.requests.first)
        let advertised = Set(request.tools.map(\.name))

        #expect(advertised.isDisjoint(with: protectedVideoNames))
        #expect(LiveImagineVideoCommand.registrations(
            advertisedToolNames: advertised
        ).isEmpty)
        #expect(transport.recordedRequests.isEmpty)
    }

    @Test("ordinary trusted-project policy preserves both actual model-visible video tools")
    func unprotectedTrustedProjectKeepsActualModelSchemas() async throws {
        let fixture = try VideoZDRFixture()
        defer { fixture.dispose() }
        try fixture.writeManaged("[tools]\ndisable_zdr_incompatible_tools = true\n")
        try fixture.writeProject("[tools]\ndisable_zdr_incompatible_tools = false\n")
        try fixture.trustProject()
        let transport = MockHTTPTransport()

        let result = await fixture.runHeadless(transport: transport)
        #expect(result.code == 0, "headless launch failed: \(result.stderr)")
        let request = try #require(result.requests.first)
        let advertised = Set(request.tools.map(\.name))

        #expect(advertised.contains("image_to_video"))
        #expect(advertised.contains("reference_to_video"))
        #expect(LiveImagineVideoCommand.registrations(
            advertisedToolNames: advertised
        ).count == 1)
        #expect(transport.recordedRequests.isEmpty)
    }
}
