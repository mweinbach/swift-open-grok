import Foundation
@testable import OpenGrokCLI
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokHTTP
import OpenGrokModels
import OpenGrokSamplingTypes
import Testing

private final class LiveDoomLoopFixture: @unchecked Sendable {
    let home: URL
    let workspace: URL
    let environment: [String: String]

    init(
        userConfiguration: String? = nil,
        projectConfiguration: String? = nil,
        environmentOverrides: [String: String] = [:]
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-doom-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        home = root.appendingPathComponent("home", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        if let userConfiguration {
            try userConfiguration.write(
                to: home.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
        }
        if let projectConfiguration {
            let project = workspace.appendingPathComponent(".opengrok", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try projectConfiguration.write(
                to: project.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
        }

        var values = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XAI_API_KEY": "private-doom-loop-test-credential",
        ]
        for (key, value) in environmentOverrides {
            values[key] = value
        }
        environment = values
    }

    func dispose() {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    func foundation(remoteSettings: RemoteSettings? = nil) async throws
        -> OpenGrokLiveApplicationLauncher.LiveSessionFoundation {
        let command = try CLICommandParser.parseOrThrow([
            "--cwd", workspace.path, "--model", "grok-4.5", "-p", "hello",
        ])
        guard case let .launch(options) = command else {
            throw CLIApplicationError.failed("doom-loop fixture did not parse a launch")
        }
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { _, _ in
                    OpenGrokLiveSamplingResponse(output: "ok")
                }
            },
            remoteSettingsSnapshot: remoteSettings
        )
        return try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: options,
            context: CLIApplicationContext(
                environment: environment,
                streams: CLIStreams(out: { _ in }, err: { _ in }),
                control: .never
            ),
            dependencies: dependencies
        )
    }
}

private actor LiveDoomLoopEventRecorder {
    private var events: [OpenGrokLiveSamplingEvent] = []

    func append(_ event: OpenGrokLiveSamplingEvent) {
        events.append(event)
    }

    func snapshot() -> [OpenGrokLiveSamplingEvent] {
        events
    }
}

@Suite("Live xAI doom-loop recovery parity", .serialized)
struct LiveDoomLoopRecoveryParityTests {
    private func responsesStream(
        output: String,
        doomed: Bool = false
    ) -> MockHTTPTransport.ScriptedResponse {
        let detector = #"{"type":"response.doom_loop_check","doom_loop_check":{"triggers":["tail_repetition:32@thinking"]}}"#
        let completed = #"{"type":"response.completed","response":{"id":"response-1","model":"test-model","status":"completed","output":[{"type":"message","role":"assistant","content":"\#(output)"}],"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}}"#
        var stream = ""
        if doomed {
            stream += "data: \(detector)\n\n"
        }
        stream += "data: \(completed)\n\n"
        return .init(
            metadata: HTTPResponseMetadata(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"]
            ),
            body: Data(stream.utf8)
        )
    }

    @Test("Actual launch enables the exact upstream recovery defaults")
    func actualLaunchCarriesDefaultRecoveryPolicy() async throws {
        let fixture = try LiveDoomLoopFixture()
        defer { fixture.dispose() }
        let foundation = try await fixture.foundation()

        #expect(foundation.samplingConfiguration.doomLoopRecovery == DoomLoopRecoveryPolicy())
        #expect(foundation.samplingConfiguration.doomLoopRecovery?.maxThreshold == 32)
        #expect(foundation.samplingConfiguration.doomLoopRecovery?.maxRetries == 2)
        #expect(foundation.samplingConfiguration.doomLoopRecovery?.windowTokens == 1024)
        await foundation.toolExecutor.shutdown()
    }

    @Test("Environment wins over local and reviewed remote enabled flags")
    func enabledPrecedence() throws {
        var remote = RemoteSettings()
        remote.doomLoopRecovery = DoomLoopRecoverySettings(enabled: true)
        let localOff = try parseTOML("[doom_loop_recovery]\nenabled = false\n")

        let forcedOn = OpenGrokLiveApplicationLauncher.resolveDoomLoopRecovery(
            environment: ["GROK_DOOM_LOOP_RECOVERY": "true"],
            document: localOff,
            remoteSettings: remote
        )
        let forcedOff = OpenGrokLiveApplicationLauncher.resolveDoomLoopRecovery(
            environment: ["GROK_DOOM_LOOP_RECOVERY": "false"],
            document: .table(TOMLTable()),
            remoteSettings: remote
        )
        let localWins = OpenGrokLiveApplicationLauncher.resolveDoomLoopRecovery(
            environment: [:],
            document: localOff,
            remoteSettings: remote
        )

        #expect(forcedOn == DoomLoopRecoveryPolicy())
        #expect(forcedOff == nil)
        #expect(localWins == nil)
    }

    @Test("Trusted local fields override remote independently and clamp exactly")
    func trustedLocalFieldPrecedenceAndClamp() throws {
        var remote = RemoteSettings()
        remote.doomLoopRecovery = DoomLoopRecoverySettings(
            enabled: true,
            maxThreshold: 27,
            maxRetries: 3,
            windowTokens: 2048
        )
        let partial = try parseTOML("""
            [doom_loop_recovery]
            max_threshold = 1
            window_tokens = 511
            """)
        let policy = try #require(OpenGrokLiveApplicationLauncher.resolveDoomLoopRecovery(
            environment: [:],
            document: partial,
            remoteSettings: remote
        ))

        #expect(policy.maxThreshold == 2)
        #expect(policy.maxRetries == 3)
        #expect(policy.windowTokens == 4096)
    }

    @Test("An untrusted repository cannot disable the user's recovery policy")
    func untrustedProjectPolicyIsInert() async throws {
        let fixture = try LiveDoomLoopFixture(
            userConfiguration: """
                [doom_loop_recovery]
                enabled = true
                max_threshold = 21
                window_tokens = 1536
                """,
            projectConfiguration: """
                [doom_loop_recovery]
                enabled = false
                max_threshold = 64
                """
        )
        defer { fixture.dispose() }
        let foundation = try await fixture.foundation()

        #expect(foundation.securityContext.projectTrusted == false)
        #expect(foundation.samplingConfiguration.doomLoopRecovery?.maxThreshold == 21)
        #expect(foundation.samplingConfiguration.doomLoopRecovery?.windowTokens == 1536)
        await foundation.toolExecutor.shutdown()
    }

    @Test("Authoritative injected remote settings reach the actual launch without fetching")
    func remoteSnapshotReachesActualLaunch() async throws {
        let fixture = try LiveDoomLoopFixture()
        defer { fixture.dispose() }
        var remote = RemoteSettings()
        remote.doomLoopRecovery = DoomLoopRecoverySettings(
            enabled: true,
            maxThreshold: 24,
            maxRetries: 1,
            windowTokens: 3072
        )
        let foundation = try await fixture.foundation(remoteSettings: remote)

        #expect(foundation.samplingConfiguration.doomLoopRecovery == DoomLoopRecoveryPolicy(
            maxThreshold: 24,
            maxRetries: 1,
            windowTokens: 3072
        ))
        await foundation.toolExecutor.shutdown()
    }

    @Test("Model switches retain the frozen policy instead of rereading process authority")
    func modelSwitchRetainsSessionPolicy() async throws {
        let fixture = try LiveDoomLoopFixture()
        defer { fixture.dispose() }
        let policy = DoomLoopRecoveryPolicy(
            maxThreshold: 18,
            maxRetries: 1,
            windowTokens: 2560
        )
        let resolver = LiveModelCatalogResolver(
            environment: fixture.environment,
            openGrokHome: fixture.home,
            sessionID: "doom-loop-switch-session",
            workingDirectory: fixture.workspace,
            doomLoopRecovery: policy
        )

        let resolution = try await resolver.resolve(modelID: "grok-4.5")
        #expect(resolution.sampling.doomLoopRecovery == policy)
    }

    @Test("Actual production sampling resamples a confident loop and emits a typed retry")
    func productionSamplerResamplesDoomedResponse() async throws {
        let transport = MockHTTPTransport(responses: [
            responsesStream(output: "discarded", doomed: true),
            responsesStream(output: "recovered"),
        ])
        let recorder = LiveDoomLoopEventRecorder()
        let policy = DoomLoopRecoveryPolicy(
            maxThreshold: 32,
            maxRetries: 2,
            windowTokens: 1536
        )
        let sampler = try OpenGrokLiveSampler.production(configuration: .init(
            model: "test-model",
            baseURL: "https://provider.example.test",
            apiKey: "private-doom-loop-test-credential",
            provider: .xai,
            apiBackend: .responses,
            doomLoopRecovery: policy,
            transport: transport
        ))

        let response = try await sampler.sample(
            OpenGrokLiveSamplingRequest(
                sessionID: "doom-session",
                turnID: "doom-turn",
                model: "test-model",
                prompt: "hello"
            ),
            emit: { event in await recorder.append(event) }
        )

        #expect(response.output == "recovered")
        #expect(transport.recordedRequests.count == 2)
        #expect(transport.recordedRequests.allSatisfy {
            $0.headers[DOOM_LOOP_CHECK_HEADER] == "1536"
        })
        let events = await recorder.snapshot()
        #expect(events.contains { event in
            if case let .retrying(attempt, maxRetries, kind, reason) = event {
                return attempt == 1 && maxRetries == 2 && kind == .doomLoopDetected
                    && !reason.contains("private-doom-loop-test-credential")
            }
            return false
        })
        #expect(!events.contains { event in
            if case .failed = event { return true }
            return false
        })
    }

    @Test("The exhausted final attempt keeps the detector header but accepts its response")
    func exhaustedRetryBudgetAcceptsFinalResponse() async throws {
        let transport = MockHTTPTransport(responses: [
            responsesStream(output: "retry-me", doomed: true),
            responsesStream(output: "accepted-final", doomed: true),
        ])
        let sampler = try OpenGrokLiveSampler.production(configuration: .init(
            model: "test-model",
            baseURL: "https://provider.example.test",
            apiKey: "private-doom-loop-test-credential",
            provider: .xai,
            apiBackend: .responses,
            doomLoopRecovery: DoomLoopRecoveryPolicy(
                maxThreshold: 32,
                maxRetries: 1,
                windowTokens: 1024
            ),
            transport: transport
        ))

        let response = try await sampler.sample(
            OpenGrokLiveSamplingRequest(
                sessionID: "doom-budget-session",
                turnID: "doom-budget-turn",
                model: "test-model",
                prompt: "hello"
            ),
            emit: { _ in }
        )

        #expect(response.output == "accepted-final")
        #expect(transport.recordedRequests.count == 2)
        #expect(transport.recordedRequests.allSatisfy {
            $0.headers[DOOM_LOOP_CHECK_HEADER] == "1024"
        })
    }
}
