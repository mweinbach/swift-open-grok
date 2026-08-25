import Foundation
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokFileUtils
import OpenGrokHTTP
import OpenGrokModels
import OpenGrokSamplingTypes
import OpenGrokTestSupport
import OpenGrokVersion
import Testing

@testable import OpenGrokCLI

private struct TraceUploadFixture {
    let root: URL
    let home: URL
    let workspace: URL

    init(endpointConfiguration: String = "") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-trace-upload-\(UUID().uuidString)",
            isDirectory: true
        )
        home = root.appendingPathComponent("state", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        for directory in [root, home, workspace] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try ("[telemetry]\ntrace_upload = true\n" + endpointConfiguration).write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
    }

    var environment: [String: String] {
        [
            "HOME": root.path,
            "OPENGROK_HOME": home.path,
            "PWD": workspace.path,
        ]
    }

    var archiveDirectory: URL {
        home.appendingPathComponent("trace-exports", isDirectory: true)
    }

    func xaiAuth(
        key: String = "private-xai-oauth-bearer",
        optedOut: Bool = false,
        blockedReasons: [String] = []
    ) -> GrokAuth {
        GrokAuth(
            key: key,
            authMode: .oidc,
            userID: "trace-user",
            teamBlockedReasons: blockedReasons,
            codingDataRetentionOptOut: optedOut,
            oidcIssuer: "https://auth.x.ai"
        )
    }

    func inlineAuth(_ auth: GrokAuth) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(auth), as: UTF8.self)
    }

    func authenticatedEnvironment(
        _ auth: GrokAuth? = nil,
        overrides: [String: String] = [:]
    ) throws -> [String: String] {
        var result = environment
        result["OPENGROK_AUTH"] = try inlineAuth(auth ?? xaiAuth())
        result.merge(overrides) { _, override in override }
        return result
    }

    @discardableResult
    func seed(
        _ sessionID: String,
        provider: ModelProvider? = .xai,
        everUsedNonXAI: Bool? = false,
        prompt: String = "private trace transcript"
    ) async throws -> LiveConversationRecord {
        var record = LiveConversationRecord.new(sessionID: sessionID, workingDirectory: workspace)
        record.currentModelID = "grok-code-fast-1"
        record.currentProvider = provider
        record.everUsedNonXAI = everUsedNonXAI
        record.items = [.user(prompt)]
        try await LiveConversationStore(openGrokHome: home).save(record)
        return record
    }

    func services(
        _ transport: MockHTTPTransport,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in }
    ) -> LiveTraceUploadServices {
        LiveTraceUploadServices(makeTransport: { transport }, sleep: sleep)
    }

    func run(
        _ arguments: [String],
        environment: [String: String],
        services: LiveTraceUploadServices
    ) async -> (status: Int32, output: String, errors: String) {
        let (streams, stdout, stderr) = CLIStreams.buffered()
        let launcher = CLIApplicationLauncher { command, context in
            try LiveTraceComposition.session(for: command, context: context, services: services)
        }
        let status = await CLIRunner.run(
            arguments,
            environment: environment,
            streams: streams,
            application: OpenGrokApplication(launcher: launcher, control: .never)
        )
        return (status, stdout.contents, stderr.contents)
    }

    func uploadResponse(
        sessionID: String,
        status: Int = 200,
        bucket: String = "trace-private-bucket",
        path: String? = nil,
        body: String? = nil,
        headers: [String: String] = [:]
    ) throws -> MockHTTPTransport.ScriptedResponse {
        let data: Data
        if let body {
            data = Data(body.utf8)
        } else {
            data = try JSONSerialization.data(withJSONObject: [
                "bucket": bucket,
                "path": path ?? "\(sessionID)/trace_export.tar.gz",
            ])
        }
        return MockHTTPTransport.ScriptedResponse(
            metadata: HTTPResponseMetadata(statusCode: status, headers: headers),
            body: data
        )
    }

    func json(_ output: String) throws -> [String: Any] {
        let data = try #require(output.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func clean() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class TraceUploadRetryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []

    var delays: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func record(_ value: TimeInterval) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
}

@Suite("live authenticated session trace uploads", .serialized)
struct LiveTraceUploadParityTests {
    @Test("the production executable reaches the real authenticated storage proxy")
    func productionExecutableUploadsThroughLiveLauncher() async throws {
        let fixture = try TraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed("production-trace")
        let server = try MockInferenceServer()
        defer { server.stop() }
        let environment = try fixture.authenticatedEnvironment(overrides: [
            "GROK_TRACE_UPLOAD_URL": server.url,
            "XAI_BASE_URL": "https://must-not-receive-traces.example/v1",
        ])
        let (streams, stdout, stderr) = CLIStreams.buffered()

        let status = await CLIRunner.run(
            ["trace", "production-trace", "--json"],
            environment: environment,
            streams: streams,
            application: .live(control: .never)
        )

        #expect(status == CLIRunner.ExitCode.success.rawValue)
        #expect(stderr.contents.isEmpty)
        let result = try fixture.json(stdout.contents)
        #expect(result["session_id"] as? String == "production-trace")
        #expect(result["status"] as? String == "uploaded")
        #expect(result["url"] as? String == "gs://mock-bucket/production-trace/trace_export.tar.gz")
        #expect(result["local_path"] == nil)
        #expect(result["error"] == nil)
        #expect(server.storageRequestCount() == 1)
        let upload = try #require(server.storageUploads().first)
        #expect(upload.path == "production-trace/trace_export.tar.gz")
        #expect(upload.authorization == "Bearer private-xai-oauth-bearer")
        #expect(upload.body.starts(with: [0x1F, 0x8B]))
        #expect(!FileManager.default.fileExists(atPath: fixture.archiveDirectory.path))
    }

    @Test("the synchronous launcher returns before its async upload begins")
    func launcherDefersUploadUntilWaitForExit() async throws {
        let fixture = try TraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed("deferred")
        let transport = MockHTTPTransport(responses: [
            try fixture.uploadResponse(sessionID: "deferred"),
        ])
        let (streams, stdout, _) = CLIStreams.buffered()
        let command = try CLICommandParser.parseOrThrow(["trace", "deferred", "--json"])
        let context = CLIApplicationContext(
            environment: try fixture.authenticatedEnvironment(),
            streams: streams,
            control: .never
        )

        let session = try LiveTraceComposition.session(
            for: command,
            context: context,
            services: fixture.services(transport)
        )
        #expect(transport.recordedRequests.isEmpty)

        try await session.waitForExit()

        #expect(transport.recordedRequests.count == 1)
        #expect(try fixture.json(stdout.contents)["status"] as? String == "uploaded")
    }

    @Test("missing or non-xAI credentials refuse before archive construction")
    func credentialGateRejectsMissingAndInferenceCredentials() async throws {
        let fixture = try TraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed("credential-gate")
        let invalidPrincipals: [[String: String]] = [
            fixture.environment,
            fixture.environment.merging(["XAI_API_KEY": "private-inference-only-key"]) { _, new in new },
            try fixture.authenticatedEnvironment(GrokAuth(
                key: "private-codex-token",
                authMode: .external,
                codingDataRetentionOptOut: false,
                oidcIssuer: "https://auth.openai.com"
            )),
        ]

        for environment in invalidPrincipals {
            let transport = MockHTTPTransport()
            let result = await fixture.run(
                ["trace", "credential-gate", "--json"],
                environment: environment,
                services: fixture.services(transport)
            )

            #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
            #expect(result.output.isEmpty)
            #expect(result.errors.contains("rerun with --local"))
            #expect(transport.recordedRequests.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: fixture.archiveDirectory.path))
        }
    }

    @Test(
        "missing boundaries, closed boundaries, and inactive xAI providers fail closed",
        arguments: ["legacy", "closed", "missing-provider", "codex"]
    )
    func providerBoundaryMustBeExplicitlyOpen(_ scenario: String) async throws {
        let fixture = try TraceUploadFixture()
        defer { fixture.clean() }
        let provider: ModelProvider?
        switch scenario {
        case "missing-provider": provider = nil
        case "codex": provider = .codex
        default: provider = .xai
        }
        let boundary: Bool? = scenario == "legacy" ? nil : scenario == "closed"
        try await fixture.seed(scenario, provider: provider, everUsedNonXAI: boundary)
        let transport = MockHTTPTransport()

        let result = await fixture.run(
            ["trace", scenario, "--json"],
            environment: try fixture.authenticatedEnvironment(),
            services: fixture.services(transport)
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.output.isEmpty)
        #expect(result.errors.contains("rerun with --local"))
        #expect(transport.recordedRequests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.archiveDirectory.path))
    }

    @Test(
        "ZDR and retention opt-out deny even with a deployment credential",
        arguments: ["zdr", "opted-out"]
    )
    func privacyGateOverridesDeploymentCredentials(_ scenario: String) async throws {
        let fixture = try TraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed(scenario)
        let auth = fixture.xaiAuth(
            optedOut: scenario == "opted-out",
            blockedReasons: scenario == "zdr" ? ["BLOCKED_REASON_NO_LOGS"] : []
        )
        let transport = MockHTTPTransport()

        let result = await fixture.run(
            ["trace", scenario, "--json"],
            environment: try fixture.authenticatedEnvironment(auth, overrides: [
                "GROK_DEPLOYMENT_KEY": "private-deployment-credential",
            ]),
            services: fixture.services(transport)
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.output.isEmpty)
        #expect(result.errors.contains("zero data retention or has opted out"))
        #expect(transport.recordedRequests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.archiveDirectory.path))
    }

    @Test(
        "expired ZDR and retention accounts still veto deployment-key uploads before I/O",
        arguments: ["expired-zdr", "expired-opted-out"]
    )
    func expiredAccountPrivacyStillOverridesDeploymentCredentials(_ scenario: String) async throws {
        let fixture = try TraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed(scenario)
        let expiredBearer = "PRIVATE_EXPIRED_ACCOUNT_BEARER_MUST_NOT_LEAK"
        let deployment = "PRIVATE_DEPLOYMENT_KEY_MUST_NOT_LEAK"
        var auth = fixture.xaiAuth(
            key: expiredBearer,
            optedOut: scenario == "expired-opted-out",
            blockedReasons: scenario == "expired-zdr" ? ["BLOCKED_REASON_NO_LOGS"] : []
        )
        auth.expiresAt = Date().addingTimeInterval(-3_600)
        let transport = MockHTTPTransport()

        let result = await fixture.run(
            ["trace", scenario, "--json"],
            environment: try fixture.authenticatedEnvironment(auth, overrides: [
                "GROK_DEPLOYMENT_KEY": deployment,
            ]),
            services: fixture.services(transport)
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.output.isEmpty)
        #expect(result.errors.contains("zero data retention or has opted out"))
        #expect(transport.recordedRequests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.archiveDirectory.path))
        for secret in [expiredBearer, deployment] {
            #expect(!result.output.contains(secret))
            #expect(!result.errors.contains(secret))
        }
    }

    @Test("deployment credentials win over OAuth without cross-provider token headers")
    func deploymentCredentialHasExclusiveWireAuthority() async throws {
        let fixture = try TraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed("deployment-priority")
        let transport = MockHTTPTransport(responses: [
            try fixture.uploadResponse(sessionID: "deployment-priority"),
        ])

        let result = await fixture.run(
            ["trace", "deployment-priority", "--json"],
            environment: try fixture.authenticatedEnvironment(overrides: [
                "GROK_DEPLOYMENT_KEY": "private-enterprise-deployment-key",
                "GROK_TRACE_UPLOAD_URL": "https://trace.example/v1/",
            ]),
            services: fixture.services(transport)
        )

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        let request = try #require(transport.recordedRequests.first)
        #expect(request.method == .post)
        #expect(request.url.absoluteString == "https://trace.example/v1/storage")
        #expect(request.headers["Authorization"] == "Bearer private-enterprise-deployment-key")
        #expect(request.headers[xaiTokenAuthHeader] == nil)
        #expect(request.headers["Content-Type"] == "application/gzip")
        #expect(request.headers["X-Storage-Path"] == "deployment-priority/trace_export.tar.gz")
        #expect(request.headers["x-grok-client-version"] == OpenGrokVersion.compiledVersion)
        #expect(request.headers["x-grok-client-identifier"] == "grok-shell")
        #expect(request.timeout == 60)
        #expect(request.body?.starts(with: [0x1F, 0x8B]) == true)
    }

    @Test("a deployment credential can upload without any OAuth account")
    func deploymentOnlyAuthenticationIsSupported() async throws {
        let fixture = try TraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed("deployment-only")
        let transport = MockHTTPTransport(responses: [
            try fixture.uploadResponse(sessionID: "deployment-only"),
        ])
        var environment = fixture.environment
        environment["GROK_DEPLOYMENT_KEY"] = "private-deployment-only-key"

        let result = await fixture.run(
            ["trace", "deployment-only", "--json"],
            environment: environment,
            services: fixture.services(transport)
        )

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        let request = try #require(transport.recordedRequests.first)
        #expect(request.headers["Authorization"] == "Bearer private-deployment-only-key")
        #expect(request.headers[xaiTokenAuthHeader] == nil)
    }

    @Test("OAuth uploads carry only the scoped xAI token marker")
    func firstPartyOAuthHeadersMatchStorageContract() async throws {
        let fixture = try TraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed("oauth")
        let transport = MockHTTPTransport(responses: [
            try fixture.uploadResponse(sessionID: "oauth"),
        ])

        let result = await fixture.run(
            ["trace", "oauth", "--json"],
            environment: try fixture.authenticatedEnvironment(),
            services: fixture.services(transport)
        )

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        let request = try #require(transport.recordedRequests.first)
        #expect(request.headers["Authorization"] == "Bearer private-xai-oauth-bearer")
        #expect(request.headers[xaiTokenAuthHeader] == xaiTokenAuthValue)
        #expect(request.url.absoluteString == CLI_CHAT_PROXY_BASE_URL_DEFAULT + "/storage")
    }

    @Test("trace override, configuration, proxy, and genuine default never use inference URLs")
    func storageEndpointRespectsIndependentProxyPrecedence() async throws {
        let fixture = try TraceUploadFixture(endpointConfiguration: """

        [endpoints]
        trace_upload_url = "https://configured-trace.example/v2"
        xai_api_base_url = "https://configured-inference.example/v1"
        """)
        defer { fixture.clean() }
        try await fixture.seed("endpoint-precedence")
        let document = LiveManagedSetupComposition.trustedConfigDocument(environment: fixture.environment)

        let explicit = try await LiveTraceUpload.authorize(
            sessionID: "endpoint-precedence",
            home: fixture.home,
            document: document,
            environment: try fixture.authenticatedEnvironment(overrides: [
                "GROK_TRACE_UPLOAD_URL": "https://environment-trace.example/v3",
                "GROK_CLI_CHAT_PROXY_BASE_URL": "https://environment-proxy.example/v1",
                "XAI_BASE_URL": "https://inference-must-not-receive-traces.example/v1",
            ]),
            uploadEnabled: true
        )
        #expect(explicit.endpoint.absoluteString == "https://environment-trace.example/v3/storage")

        let configured = try await LiveTraceUpload.authorize(
            sessionID: "endpoint-precedence",
            home: fixture.home,
            document: document,
            environment: try fixture.authenticatedEnvironment(overrides: [
                "GROK_CLI_CHAT_PROXY_BASE_URL": "https://environment-proxy.example/v1",
                "XAI_BASE_URL": "https://inference-must-not-receive-traces.example/v1",
            ]),
            uploadEnabled: true
        )
        #expect(configured.endpoint.absoluteString == "https://configured-trace.example/v2/storage")

        let cleanFixture = try TraceUploadFixture()
        defer { cleanFixture.clean() }
        try await cleanFixture.seed("proxy-precedence")
        let cleanDocument = LiveManagedSetupComposition.trustedConfigDocument(
            environment: cleanFixture.environment
        )
        let proxy = try await LiveTraceUpload.authorize(
            sessionID: "proxy-precedence",
            home: cleanFixture.home,
            document: cleanDocument,
            environment: try cleanFixture.authenticatedEnvironment(overrides: [
                "GROK_CLI_CHAT_PROXY_BASE_URL": "https://environment-proxy.example/v1",
                "XAI_BASE_URL": "https://inference-must-not-receive-traces.example/v1",
            ]),
            uploadEnabled: true
        )
        #expect(proxy.endpoint.absoluteString == "https://environment-proxy.example/v1/storage")

        let defaultProxy = try await LiveTraceUpload.authorize(
            sessionID: "proxy-precedence",
            home: cleanFixture.home,
            document: cleanDocument,
            environment: try cleanFixture.authenticatedEnvironment(overrides: [
                "XAI_BASE_URL": "https://inference-must-not-receive-traces.example/v1",
            ]),
            uploadEnabled: true
        )
        #expect(defaultProxy.endpoint.absoluteString == CLI_CHAT_PROXY_BASE_URL_DEFAULT + "/storage")
    }

    @Test(
        "nonloopback HTTP and endpoint userinfo, query, or fragments are refused",
        arguments: [
            "http://example.com/v1",
            "http://127.evil.example/v1",
            "https://user:secret@example.com/v1",
            "https://example.com/v1?private=secret",
            "https://example.com/v1#private-secret",
            "file:///tmp/private-traces",
        ]
    )
    func endpointSecurityRejectsUnsafeDestinations(_ endpoint: String) async throws {
        let fixture = try TraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed("endpoint-gate")
        let transport = MockHTTPTransport()

        let result = await fixture.run(
            ["trace", "endpoint-gate", "--json"],
            environment: try fixture.authenticatedEnvironment(overrides: [
                "GROK_TRACE_UPLOAD_URL": endpoint,
            ]),
            services: fixture.services(transport)
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.output.isEmpty)
        #expect(result.errors.contains("invalid or does not use HTTPS"))
        #expect(transport.recordedRequests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.archiveDirectory.path))
    }

    @Test(
        "unavailable direct cloud credentials never silently downgrade to proxy upload",
        arguments: ["gs://private-google-bucket", "s3://private-amazon-bucket"]
    )
    func unavailableDirectBucketsFailClosed(_ bucket: String) async throws {
        let fixture = try TraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed("direct-bucket")
        let transport = MockHTTPTransport()

        let result = await fixture.run(
            ["trace", "direct-bucket", "--json"],
            environment: try fixture.authenticatedEnvironment(overrides: [
                "GROK_TRACE_UPLOAD_BUCKET": bucket,
                "GROK_DEPLOYMENT_KEY": "private-deployment-key",
            ]),
            services: fixture.services(transport)
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.output.isEmpty)
        if bucket.hasPrefix("gs://") {
            #expect(result.errors.contains("direct cloud-storage upload method is not available"))
        } else {
            #expect(result.errors.contains("AWS"))
        }
        #expect(!result.errors.contains(bucket))
        #expect(transport.recordedRequests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.archiveDirectory.path))
    }

    @Test("transient proxy failures retry with bounded cancellable exponential delays")
    func transientFailuresRetryBeforeSuccessfulUpload() async throws {
        let fixture = try TraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed("retry-success")
        let transport = MockHTTPTransport(responses: [
            try fixture.uploadResponse(sessionID: "retry-success", status: 503),
            try fixture.uploadResponse(
                sessionID: "retry-success",
                status: 429,
                headers: ["Retry-After": "7"]
            ),
            try fixture.uploadResponse(sessionID: "retry-success"),
        ])
        let clock = TraceUploadRetryClock()

        let result = await fixture.run(
            ["trace", "retry-success", "--json"],
            environment: try fixture.authenticatedEnvironment(),
            services: fixture.services(transport, sleep: { seconds in clock.record(seconds) })
        )

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(transport.recordedRequests.count == 3)
        #expect(clock.delays == [2, 7])
        #expect(try fixture.json(result.output)["status"] as? String == "uploaded")
    }

    @Test("transient failures stop after four attempts and emit owner-private fallback files")
    func retryExhaustionWritesRedactedPrivateFallback() async throws {
        let fixture = try TraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed(
            "retry-exhausted",
            prompt: "PRIVATE_TRANSCRIPT_MUST_NEVER_ENTER_LOG"
        )
        let responses = try (0..<4).map { _ in
            try fixture.uploadResponse(
                sessionID: "retry-exhausted",
                status: 503,
                body: "PRIVATE_SERVER_RESPONSE_MUST_NEVER_ENTER_LOG"
            )
        }
        let transport = MockHTTPTransport(responses: responses)
        let clock = TraceUploadRetryClock()
        let oauth = "PRIVATE_OAUTH_BEARER_MUST_NEVER_ENTER_LOG"
        let deployment = "PRIVATE_DEPLOYMENT_KEY_MUST_NEVER_ENTER_LOG"

        let result = await fixture.run(
            ["trace", "retry-exhausted", "--json"],
            environment: try fixture.authenticatedEnvironment(
                fixture.xaiAuth(key: oauth),
                overrides: [
                    "GROK_DEPLOYMENT_KEY": deployment,
                    "GROK_TRACE_UPLOAD_URL": "https://PRIVATE-ENDPOINT.example/v1",
                ]
            ),
            services: fixture.services(transport, sleep: { seconds in clock.record(seconds) })
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(transport.recordedRequests.count == 4)
        #expect(clock.delays == [2, 4, 8])
        let output = try fixture.json(result.output)
        #expect(output["status"] as? String == "failed")
        #expect(output["error"] as? String == "Storage proxy rejected the upload (HTTP 503).")
        #expect(output["url"] == nil)
        let archive = URL(fileURLWithPath: try #require(output["local_path"] as? String))
        let log = fixture.archiveDirectory.appendingPathComponent("retry-exhausted.upload.log")
        #expect(try SecureFile.isOwnerOnly(at: archive))
        #expect(try SecureFile.isOwnerOnly(at: log))
        let contents = try String(contentsOf: log, encoding: .utf8)
        #expect(contents.contains("retry-exhausted/trace_export.tar.gz"))
        for secret in [
            oauth,
            deployment,
            "PRIVATE-ENDPOINT.example",
            "PRIVATE_TRANSCRIPT_MUST_NEVER_ENTER_LOG",
            "PRIVATE_SERVER_RESPONSE_MUST_NEVER_ENTER_LOG",
        ] {
            #expect(!contents.contains(secret))
            #expect(!result.output.contains(secret))
            #expect(!result.errors.contains(secret))
        }
    }

    @Test("permanent 403 responses never retry and preserve a private local archive")
    func permanentAuthorizationFailureNeverRetries() async throws {
        let fixture = try TraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed("forbidden")
        let transport = MockHTTPTransport(responses: [
            try fixture.uploadResponse(sessionID: "forbidden", status: 403),
        ])

        let result = await fixture.run(
            ["trace", "forbidden", "--json"],
            environment: try fixture.authenticatedEnvironment(),
            services: fixture.services(transport)
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(transport.recordedRequests.count == 1)
        let output = try fixture.json(result.output)
        #expect(output["status"] as? String == "failed")
        #expect(output["error"] as? String == "Storage proxy rejected the upload (HTTP 403).")
        let archive = URL(fileURLWithPath: try #require(output["local_path"] as? String))
        #expect(try SecureFile.isOwnerOnly(at: archive))
    }

    @Test(
        "malformed proxy locations cannot forge a successful external storage URL",
        arguments: ["wrong-session/trace_export.tar.gz", "../private.tar.gz"]
    )
    func returnedStoragePathMustMatchTheAuthorizedObject(_ returnedPath: String) async throws {
        let fixture = try TraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed("response-path")
        let transport = MockHTTPTransport(responses: [
            try fixture.uploadResponse(sessionID: "response-path", path: returnedPath),
        ])

        let result = await fixture.run(
            ["trace", "response-path", "--json"],
            environment: try fixture.authenticatedEnvironment(),
            services: fixture.services(transport)
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(transport.recordedRequests.count == 1)
        let output = try fixture.json(result.output)
        #expect(output["status"] as? String == "failed")
        #expect((output["error"] as? String)?.contains("unsafe or unexpected") == true)
        #expect(output["url"] == nil)
    }

    @Test("the provider boundary is rechecked before every retry's HTTP request")
    func boundaryClosureDuringRetryPreventsAnotherWireRequest() async throws {
        let fixture = try TraceUploadFixture()
        defer { fixture.clean() }
        let original = try await fixture.seed("boundary-recheck")
        let transport = MockHTTPTransport(responses: [
            try fixture.uploadResponse(sessionID: "boundary-recheck", status: 503),
            try fixture.uploadResponse(sessionID: "boundary-recheck"),
        ])
        let home = fixture.home

        let result = await fixture.run(
            ["trace", "boundary-recheck", "--json"],
            environment: try fixture.authenticatedEnvironment(),
            services: fixture.services(transport, sleep: { _ in
                var switched = original
                switched.currentProvider = .codex
                switched.everUsedNonXAI = true
                try await LiveConversationStore(openGrokHome: home).save(switched)
            })
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(transport.recordedRequests.count == 1)
        let output = try fixture.json(result.output)
        #expect(output["status"] as? String == "failed")
        #expect((output["error"] as? String)?.contains("provider-export boundary") == true)
    }

    @Test("cancelling retry backoff never uploads again or creates a fallback archive")
    func cancellationInterruptsRetryBackoff() async throws {
        let fixture = try TraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed("cancelled")
        let transport = MockHTTPTransport(responses: [
            try fixture.uploadResponse(sessionID: "cancelled", status: 503),
        ])
        let (streams, _, _) = CLIStreams.buffered()
        let options = CLIUtilityOptions(name: "trace", values: ["cancelled"], json: true)

        await #expect(throws: CancellationError.self) {
            try await LiveTraceComposition.run(
                options: options,
                environment: try fixture.authenticatedEnvironment(),
                streams: streams,
                services: fixture.services(transport, sleep: { _ in throw CancellationError() })
            )
        }

        #expect(transport.recordedRequests.count == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.archiveDirectory.path))
    }
}
