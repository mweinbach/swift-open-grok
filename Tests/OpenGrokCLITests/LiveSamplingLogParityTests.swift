import Foundation
import OpenGrokHTTP
import OpenGrokSampler
import OpenGrokSamplingTypes
import Testing

@testable import OpenGrokCLI

private struct LiveSamplingLogFixture {
    let root: URL
    let home: URL
    let workspace: URL

    init() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-sampling-log-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let resolved = temporary.standardizedFileURL.resolvingSymlinksInPath()
        #if os(macOS)
        if resolved.path.hasPrefix("/var/") {
            root = URL(fileURLWithPath: "/private\(resolved.path)", isDirectory: true)
        } else {
            root = resolved
        }
        #else
        root = resolved
        #endif
        home = root.appendingPathComponent("owner", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
    }

    var directory: URL { home.appendingPathComponent("logs", isDirectory: true) }
    var file: URL { directory.appendingPathComponent("sampling.jsonl") }

    func cleanup() {
        LiveManagedPolicyLifecycle.stop(environment: ["HOME": home.path, "OPENGROK_HOME": home.path])
        try? FileManager.default.removeItem(at: root)
    }

    func entries() throws -> [LiveSamplingLogEntry] {
        let text = try String(contentsOf: file, encoding: .utf8)
        return try text.split(whereSeparator: \.isNewline).map {
            try JSONDecoder().decode(LiveSamplingLogEntry.self, from: Data($0.utf8))
        }
    }

    func logger(environment: [String: String] = [:], cli: Bool = true) throws -> LiveSamplingLog {
        try #require(try LiveSamplingLog.makeIfEnabled(
            openGrokHome: home,
            cliEnabled: cli,
            environment: environment
        ))
    }
}

@Suite("owner-private live sampling diagnostic parity", .serialized)
struct LiveSamplingLogParityTests {
    private func response(_ text: String) -> MockHTTPTransport.ScriptedResponse {
        let chunk = #"{"id":"FULL_PROVIDER_MESSAGE_IDENTIFIER","object":"chat.completion.chunk","created":0,"model":"safe-model","choices":[{"index":0,"delta":{"role":"assistant","content":"\#(text)"},"finish_reason":"stop"}]}"#
        return .init(
            metadata: HTTPResponseMetadata(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"]
            ),
            body: Data("data: \(chunk)\n\ndata: [DONE]\n\n".utf8)
        )
    }

    private func responsesResponse(_ text: String) -> MockHTTPTransport.ScriptedResponse {
        let completed = #"{"type":"response.completed","response":{"id":"response-1","model":"grok-4.5","status":"completed","output":[{"type":"message","role":"assistant","content":"\#(text)"}],"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}}"#
        return .init(
            metadata: HTTPResponseMetadata(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"]
            ),
            body: Data("data: \(completed)\n\n".utf8)
        )
    }

    private func failure(_ message: String) -> MockHTTPTransport.ScriptedResponse {
        .init(
            metadata: HTTPResponseMetadata(statusCode: 500, headers: ["Retry-After": "0"]),
            body: Data(#"{"error":{"message":"\#(message)"}}"#.utf8)
        )
    }

    private func configuration(
        logger: LiveSamplingLog?,
        transport: MockHTTPTransport,
        provider: ModelProvider = .xai,
        apiKey: String = "PRIVATE_PROVIDER_CREDENTIAL_ABCDEFGHIJKL"
    ) -> OpenGrokLiveSamplingConfiguration {
        OpenGrokLiveSamplingConfiguration(
            model: "safe-model",
            baseURL: "https://provider.example.invalid/private?api_key=URL_QUERY_SECRET",
            apiKey: apiKey,
            provider: provider,
            extraHeaders: ["X-Custom-Secret": "CUSTOM_HEADER_SECRET"],
            queryParams: ["secret_parameter": "QUERY_PARAMETER_SECRET"],
            samplingLog: logger,
            tuning: OpenGrokLiveSamplingTuning(maxRetries: 2),
            transport: transport
        )
    }

    @Test("default stays dark and only exact session-scoped upstream environment values enable")
    func optInIsExplicit() throws {
        let fixture = try LiveSamplingLogFixture()
        defer { fixture.cleanup() }

        #expect(try LiveSamplingLog.makeIfEnabled(
            openGrokHome: fixture.home,
            cliEnabled: false,
            environment: [:]
        ) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))

        for rejected in ["TRUE", " true", "yes", "0"] {
            #expect(try LiveSamplingLog.makeIfEnabled(
                openGrokHome: fixture.home,
                cliEnabled: false,
                environment: ["GROK_LOG_SAMPLING": rejected]
            ) == nil)
        }

        for enabled in ["1", "true", "on"] {
            let logger = try fixture.logger(
                environment: ["GROK_LOG_SAMPLING": enabled, "OPENGROK_TELEMETRY_ENABLED": "false"],
                cli: false
            )
            #expect(type(of: logger).maximumBytes == 5 * 1_024 * 1_024)
        }
    }

    @Test("ZDR and explicit managed privacy denial fail closed without creating a log")
    func privacyPolicyDeniesLogging() throws {
        let fixture = try LiveSamplingLogFixture()
        defer { fixture.cleanup() }

        #expect(throws: (any Error).self) {
            try LiveSamplingLog.makeIfEnabled(
                openGrokHome: fixture.home,
                cliEnabled: true,
                environment: [:],
                zeroDataRetention: true
            )
        }
        #expect(throws: (any Error).self) {
            try LiveSamplingLog.makeIfEnabled(
                openGrokHome: fixture.home,
                cliEnabled: true,
                environment: [:],
                managedPrivacyBlocked: true
            )
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    @Test("actual production sampling records retry metrics privately without content or credentials")
    func productionSamplingRecordsOnlySafeMetadata() async throws {
        let fixture = try LiveSamplingLogFixture()
        defer { fixture.cleanup() }
        let logger = try fixture.logger()
        let transport = MockHTTPTransport(responses: [
            failure("PROVIDER_ERROR_BODY_SECRET"),
            response("ASSISTANT_OUTPUT_SECRET"),
        ])
        let sampler = try OpenGrokLiveSampler.production(
            configuration: configuration(logger: logger, transport: transport)
        )

        let result = try await sampler.sample(
            OpenGrokLiveSamplingRequest(
                sessionID: "FULL_SESSION_IDENTIFIER_SECRET",
                turnID: "FULL_TURN_IDENTIFIER_SECRET",
                model: "safe-model",
                prompt: "USER_PROMPT_AND_TOOL_ARGUMENT_SECRET"
            ),
            emit: { _ in }
        )

        #expect(result.output == "ASSISTANT_OUTPUT_SECRET")
        #expect(result.latencyStats?.attempts == 2)

        let entries = try fixture.entries()
        #expect(entries.contains { $0.event == .requestStarted && $0.authSuffix == "ABCDEFGHIJKL" })
        #expect(entries.contains { $0.event == .retry && $0.attempt == 1 && $0.errorKind == "api" })
        #expect(entries.contains { $0.event == .completed && $0.attempt == 2 })
        #expect(entries.allSatisfy { $0.provider == "xai" && $0.requestSuffix.count == 8 })

        let contents = try String(contentsOf: fixture.file, encoding: .utf8)
        for secret in [
            "PRIVATE_PROVIDER_CREDENTIAL_ABCDEFGHIJKL",
            "PROVIDER_ERROR_BODY_SECRET",
            "ASSISTANT_OUTPUT_SECRET",
            "FULL_SESSION_IDENTIFIER_SECRET",
            "FULL_TURN_IDENTIFIER_SECRET",
            "FULL_PROVIDER_MESSAGE_IDENTIFIER",
            "USER_PROMPT_AND_TOOL_ARGUMENT_SECRET",
            "CUSTOM_HEADER_SECRET",
            "URL_QUERY_SECRET",
            "QUERY_PARAMETER_SECRET",
            "provider.example.invalid",
            "Authorization",
        ] {
            #expect(!contents.contains(secret), "sampling log leaked \(secret)")
        }

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: fixture.directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: fixture.file.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("provider records remain isolated and short credentials are never logged in full")
    func providerIsolationAndShortCredentials() async throws {
        let fixture = try LiveSamplingLogFixture()
        defer { fixture.cleanup() }
        let logger = try fixture.logger()

        for (provider, key) in [
            (ModelProvider.xai, "XAI_PRIVATE_CREDENTIAL_123456789ABC"),
            (.kimi, "short-secret"),
        ] {
            let transport = MockHTTPTransport(responses: [response("private-output")])
            let sampler = try OpenGrokLiveSampler.production(configuration: configuration(
                logger: logger,
                transport: transport,
                provider: provider,
                apiKey: key
            ))
            let result = try await sampler.sample(
                OpenGrokLiveSamplingRequest(
                    sessionID: "session-\(provider.asString)",
                    turnID: "turn-\(provider.asString)",
                    model: "safe-model",
                    prompt: "provider-specific-private-prompt"
                ),
                emit: { _ in }
            )
            #expect(result.output == "private-output")
        }

        let entries = try fixture.entries()
        #expect(entries.contains { $0.provider == "xai" && $0.authSuffix == "123456789ABC" })
        #expect(entries.contains { $0.provider == "kimi" && $0.event == .requestStarted })
        #expect(entries.filter { $0.provider == "kimi" }.allSatisfy { $0.authSuffix == nil })
        let contents = try String(contentsOf: fixture.file, encoding: .utf8)
        #expect(!contents.contains("XAI_PRIVATE_CREDENTIAL_123456789ABC"))
        #expect(!contents.contains("short-secret"))
    }

    @Test("existing symlink and multiply-linked files are rejected without modifying their victim")
    func symbolicLinksAndHardLinksAreRejected() throws {
        let fixture = try LiveSamplingLogFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let victim = fixture.root.appendingPathComponent("private-victim")
        try Data("VICTIM_CONTENT_MUST_SURVIVE".utf8).write(to: victim)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: victim.path)
        try FileManager.default.createSymbolicLink(at: fixture.file, withDestinationURL: victim)

        #expect(throws: (any Error).self) { try fixture.logger() }
        #expect(try String(contentsOf: victim, encoding: .utf8) == "VICTIM_CONTENT_MUST_SURVIVE")

        try FileManager.default.removeItem(at: fixture.file)
        try FileManager.default.linkItem(at: victim, to: fixture.file)
        #expect(throws: (any Error).self) { try fixture.logger() }
        #expect(try String(contentsOf: victim, encoding: .utf8) == "VICTIM_CONTENT_MUST_SURVIVE")
    }

    @Test("repeated diagnostic writes stay strictly bounded and retain complete JSONL records")
    func diagnosticFileIsBounded() throws {
        let fixture = try LiveSamplingLogFixture()
        defer { fixture.cleanup() }
        let logger = try LiveSamplingLog.make(openGrokHome: fixture.home, byteLimit: 1_024)
        let scope = try logger.begin(
            config: SamplerConfig(
                apiKey: "PRIVATE_CREDENTIAL_123456789ABC",
                baseURL: "https://example.invalid",
                model: "safe-model"
            ),
            request: ConversationRequest(items: [.user("CONTENT_NEVER_LOGGED")]),
            requestID: RequestId("FULL_REQUEST_IDENTIFIER_12345678")
        )

        for attempt in UInt32(1)...UInt32(80) {
            try scope.record(.retry, attempt: attempt, maxRetries: 80, errorKind: "api")
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.file.path)
        #expect((attributes[.size] as? NSNumber)?.intValue ?? 0 <= 1_024)
        #expect(LiveSamplingLog.maximumBytes == 5 * 1_024 * 1_024)
        let records = try fixture.entries()
        #expect(!records.isEmpty)
        #expect(records.last?.attempt == 80)
        #expect(records.allSatisfy { $0.requestSuffix == "12345678" })
    }

    @Test("actual headless --log-sampling route creates and populates the session-owned diagnostic")
    func actualCLILaunchEnablesSamplingLog() async throws {
        let fixture = try LiveSamplingLogFixture()
        defer { fixture.cleanup() }
        let transport = MockHTTPTransport(responses: [responsesResponse("CLI_PRIVATE_OUTPUT")])
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { resolved in
                try OpenGrokLiveSampler.production(configuration: OpenGrokLiveSamplingConfiguration(
                    model: resolved.model,
                    baseURL: resolved.baseURL,
                    apiKey: resolved.apiKey,
                    provider: resolved.provider,
                    apiBackend: resolved.apiBackend,
                    extraHeaders: resolved.extraHeaders,
                    queryParams: resolved.queryParams,
                    envHTTPHeaders: resolved.envHTTPHeaders,
                    environment: resolved.environment,
                    clientIdentifier: resolved.clientIdentifier,
                    samplingLog: resolved.samplingLog,
                    tuning: resolved.tuning,
                    doomLoopRecovery: resolved.doomLoopRecovery,
                    codexPermissions: resolved.codexPermissions,
                    bearerResolver: resolved.bearerResolver,
                    credentialProvider: resolved.credentialProvider,
                    attributionCallback: resolved.attributionCallback,
                    transport: transport
                ))
            }
        )
        let (streams, _, errors) = CLIStreams.buffered()
        let environment = [
            "HOME": fixture.home.path,
            "OPENGROK_HOME": fixture.home.path,
            "GROK_SANDBOX": "off",
            "XDG_STATE_HOME": fixture.home.appendingPathComponent("state").path,
            "XAI_API_KEY": "CLI_PRIVATE_CREDENTIAL_ABCDEFGHIJKL",
        ]

        let code = await CLIRunner.run(
            [
                "headless", "--prompt", "CLI_PRIVATE_PROMPT", "--cwd", fixture.workspace.path,
                "--model", "grok-4.5", "--log-sampling",
            ],
            environment: environment,
            streams: streams,
            application: OpenGrokApplication.live(dependencies: dependencies, control: .never)
        )

        #expect(code == CLIRunner.ExitCode.success.rawValue, "\(errors.contents)")
        let entries = try fixture.entries()
        #expect(entries.contains { $0.event == .requestStarted })
        #expect(entries.contains { $0.event == .completed })
        let contents = try String(contentsOf: fixture.file, encoding: .utf8)
        #expect(!contents.contains("CLI_PRIVATE_PROMPT"))
        #expect(!contents.contains("CLI_PRIVATE_OUTPUT"))
        #expect(!contents.contains("CLI_PRIVATE_CREDENTIAL_ABCDEFGHIJKL"))
    }
}
