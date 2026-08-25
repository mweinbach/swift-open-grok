import Foundation
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokFileUtils
import OpenGrokHTTP
import OpenGrokModels
import OpenGrokSamplingTypes
import OpenGrokTestSupport
import Testing

@testable import OpenGrokCLI

private struct CloudTraceUploadFixture {
    let root: URL
    let home: URL
    let workspace: URL

    init(configuration: String = "") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-cloud-trace-\(UUID().uuidString)",
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
        try ("[telemetry]\ntrace_upload = true\n" + configuration).write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
    }

    var baseEnvironment: [String: String] {
        ["HOME": root.path, "OPENGROK_HOME": home.path, "PWD": workspace.path]
    }

    var archiveDirectory: URL {
        home.appendingPathComponent("trace-exports", isDirectory: true)
    }

    func auth(
        key: String = "PRIVATE_XAI_OAUTH_BEARER",
        optedOut: Bool = false,
        blockedReasons: [String] = []
    ) -> GrokAuth {
        GrokAuth(
            key: key,
            authMode: .oidc,
            userID: "cloud-trace-user",
            teamBlockedReasons: blockedReasons,
            codingDataRetentionOptOut: optedOut,
            oidcIssuer: "https://auth.x.ai"
        )
    }

    func environment(
        auth: GrokAuth? = nil,
        overrides: [String: String] = [:]
    ) throws -> [String: String] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var environment = baseEnvironment
        environment["OPENGROK_AUTH"] = String(
            decoding: try encoder.encode(auth ?? self.auth()),
            as: UTF8.self
        )
        environment["GROK_TRACE_UPLOAD_BUCKET"] = "s3://trace-private-bucket"
        environment["AWS_ACCESS_KEY_ID"] = "AKIDEXAMPLE"
        environment["AWS_SECRET_ACCESS_KEY"] = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
        environment["AWS_REGION"] = "us-west-2"
        environment.merge(overrides) { _, override in override }
        return environment
    }

    func sharedCredentialEnvironment(
        overrides: [String: String] = [:]
    ) throws -> [String: String] {
        var environment = try self.environment()
        environment.removeValue(forKey: "AWS_ACCESS_KEY_ID")
        environment.removeValue(forKey: "AWS_SECRET_ACCESS_KEY")
        environment.removeValue(forKey: "AWS_SESSION_TOKEN")
        environment.merge(overrides) { _, override in override }
        return environment
    }

    @discardableResult
    func writeSharedCredentials(_ content: String, at path: URL? = nil) throws -> URL {
        let location = path ?? root
            .appendingPathComponent(".aws", isDirectory: true)
            .appendingPathComponent("credentials", isDirectory: false)
        try FileManager.default.createDirectory(
            at: location.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try SecureFile.write(at: location, contents: content)
        return location
    }

    @discardableResult
    func seed(
        _ sessionID: String,
        provider: ModelProvider? = .xai,
        everUsedNonXAI: Bool? = false
    ) async throws -> LiveConversationRecord {
        var record = LiveConversationRecord.new(sessionID: sessionID, workingDirectory: workspace)
        record.currentModelID = "grok-code-fast-1"
        record.currentProvider = provider
        record.everUsedNonXAI = everUsedNonXAI
        record.items = [.user("PRIVATE_CLOUD_TRACE_TRANSCRIPT")]
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
        _ sessionID: String,
        environment: [String: String],
        services: LiveTraceUploadServices? = nil
    ) async -> (status: Int32, output: String, errors: String) {
        let (streams, stdout, stderr) = CLIStreams.buffered()
        let application: OpenGrokApplication
        if let services {
            let launcher = CLIApplicationLauncher { command, context in
                try LiveTraceComposition.session(for: command, context: context, services: services)
            }
            application = OpenGrokApplication(launcher: launcher, control: .never)
        } else {
            application = .live(control: .never)
        }
        let status = await CLIRunner.run(
            ["trace", sessionID, "--json"],
            environment: environment,
            streams: streams,
            application: application
        )
        return (status, stdout.contents, stderr.contents)
    }

    func json(_ output: String) throws -> [String: Any] {
        let bytes = try #require(output.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    func clean() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class CloudTraceRequestHandler: HttpRequestHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var received: [HttpRequest] = []
    private let response: @Sendable (HttpRequest) -> HttpResponse

    init(response: @escaping @Sendable (HttpRequest) -> HttpResponse = { _ in
        HttpResponse(status: 200, body: .bytes(Data()))
    }) {
        self.response = response
    }

    func handle(_ request: HttpRequest) -> HttpResponse {
        lock.lock()
        received.append(request)
        lock.unlock()
        return response(request)
    }

    var requests: [HttpRequest] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }
}

private enum S3MultipartTraceFixture {
    static let bucket = "trace-private-bucket"

    static func initiation(sessionID: String, uploadID: String = "multipart+token/=") -> Data {
        Data(("<InitiateMultipartUploadResult><Bucket>\(bucket)</Bucket>"
            + "<Key>\(sessionID)/trace_export.tar.gz</Key>"
            + "<UploadId>\(uploadID)</UploadId></InitiateMultipartUploadResult>").utf8)
    }

    static func completion(sessionID: String) -> Data {
        Data(("<CompleteMultipartUploadResult><Bucket>\(bucket)</Bucket>"
            + "<Key>\(sessionID)/trace_export.tar.gz</Key>"
            + "<ETag>completed</ETag></CompleteMultipartUploadResult>").utf8)
    }
}

private actor MultipartBoundaryRevokingTransport: HTTPTransport {
    private let wrapped: MockHTTPTransport
    private let revoke: @Sendable () async throws -> Void
    private var requests = 0

    init(wrapped: MockHTTPTransport, revoke: @escaping @Sendable () async throws -> Void) {
        self.wrapped = wrapped
        self.revoke = revoke
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests += 1
        let response = try await wrapped.send(request)
        if requests == 1 {
            try await revoke()
        }
        return response
    }

    nonisolated func stream(_ request: HTTPRequest) -> AsyncThrowingStream<HTTPStreamEvent, Error> {
        wrapped.stream(request)
    }
}

@Suite("live direct S3 trace upload security and parity", .serialized)
struct LiveCloudTraceUploadParityTests {
    @Test("HMAC-SHA256 matches RFC 4231 test case one")
    func hmacMatchesPublishedVector() {
        let digest = LiveCloudTraceUpload.hmacSHA256(
            key: Data(repeating: 0x0B, count: 20),
            data: Data("Hi There".utf8)
        )

        #expect(digest.map { String(format: "%02x", $0) }.joined()
            == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
    }

    @Test("a fixed UTC request matches an independently computed SigV4 golden")
    func signedRequestMatchesOpenSSLGolden() throws {
        let authorization = LiveCloudTraceUpload.Authorization(
            endpoint: try #require(URL(string:
                "https://trace-bucket.s3.us-west-2.amazonaws.com/sigv4-session/trace_export.tar.gz"
            )),
            bucket: "trace-bucket",
            region: "us-west-2",
            accessKeyID: "AKIDEXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            sessionToken: nil
        )
        let request = try LiveCloudTraceUpload.request(
            authorization: authorization,
            archive: Data("trace archive bytes".utf8),
            now: Date(timeIntervalSince1970: 1_440_938_160)
        )

        #expect(request.method == .put)
        #expect(request.url == authorization.endpoint)
        #expect(request.headers["Host"] == "trace-bucket.s3.us-west-2.amazonaws.com")
        #expect(request.headers["Content-Type"] == "application/gzip")
        #expect(request.headers["X-Amz-Date"] == "20150830T123600Z")
        #expect(request.headers["X-Amz-Content-Sha256"]
            == "f2874433109b3e8008182f49b81166b561ebb952c85be2fa4ddc117dce0a3854")
        #expect(request.headers["Authorization"]
            == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-west-2/s3/aws4_request, "
                + "SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date, "
                + "Signature=1477b87cd8f7552e374d4e02676a1af8c3c4b56f87e820d00ca853d3da146ae9")
        #expect(request.timeout == 60)
        #expect(request.body == Data("trace archive bytes".utf8))
    }

    @Test("temporary AWS session tokens are transmitted and cryptographically signed")
    func temporarySessionTokenIsSigned() throws {
        let authorization = LiveCloudTraceUpload.Authorization(
            endpoint: try #require(URL(string:
                "https://trace-bucket.s3.us-west-2.amazonaws.com/token/trace_export.tar.gz"
            )),
            bucket: "trace-bucket",
            region: "us-west-2",
            accessKeyID: "AKIDEXAMPLE",
            secretAccessKey: "PRIVATE_AWS_SECRET",
            sessionToken: "PRIVATE_AWS_SESSION_TOKEN"
        )
        let request = try LiveCloudTraceUpload.request(
            authorization: authorization,
            archive: Data("token archive".utf8),
            now: Date(timeIntervalSince1970: 1_440_938_160)
        )

        #expect(request.headers["X-Amz-Security-Token"] == "PRIVATE_AWS_SESSION_TOKEN")
        let signed = try #require(request.headers["Authorization"])
        #expect(signed.contains("SignedHeaders=content-type;host;x-amz-content-sha256;"
            + "x-amz-date;x-amz-security-token"))
        #expect(!signed.contains("PRIVATE_AWS_SECRET"))
        #expect(!signed.contains("PRIVATE_AWS_SESSION_TOKEN"))
        #expect(request.headers[xaiTokenAuthHeader] == nil)
    }

    @Test("a private default AWS profile drives a real signed upload with its temporary token")
    func privateDefaultProfileReachesTheLiveSignedTransport() async throws {
        let fixture = try CloudTraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed("shared-profile-live")
        try fixture.writeSharedCredentials("""
        [default]
        aws_access_key_id = PROFILEACCESS123
        aws_secret_access_key = PRIVATE_PROFILE_SECRET
        aws_session_token = PRIVATE_PROFILE_SESSION_TOKEN
        """)
        let handler = CloudTraceRequestHandler()
        let server = HttpServer(handler: handler, basePath: "")
        try server.start()
        defer { server.stop() }

        let result = await fixture.run(
            "shared-profile-live",
            environment: try fixture.sharedCredentialEnvironment(overrides: [
                "GROK_TRACE_UPLOAD_ENDPOINT_URL": server.baseURL,
            ])
        )

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(result.errors.isEmpty)
        #expect(try fixture.json(result.output)["url"] as? String
            == "s3://trace-private-bucket/shared-profile-live/trace_export.tar.gz")
        let request = try #require(handler.requests.first)
        #expect(handler.requests.count == 1)
        #expect(request.authorization?.contains("Credential=PROFILEACCESS123/") == true)
        #expect(request.header("x-amz-security-token") == "PRIVATE_PROFILE_SESSION_TOKEN")
        #expect(request.header(xaiTokenAuthHeader) == nil)
        for secret in ["PRIVATE_PROFILE_SECRET", "PRIVATE_PROFILE_SESSION_TOKEN"] {
            #expect(!result.output.contains(secret))
            #expect(!result.errors.contains(secret))
        }
    }

    @Test(
        "AWS_PROFILE overrides AWS_DEFAULT_PROFILE and both isolate named shared profiles",
        arguments: ["explicit", "fallback", "explicit-wins"]
    )
    func sharedCredentialProfileSelectionHonorsPrecedence(_ scenario: String) throws {
        let fixture = try CloudTraceUploadFixture()
        defer { fixture.clean() }
        try fixture.writeSharedCredentials("""
        [default]
        aws_access_key_id = DEFAULTKEY
        aws_secret_access_key = PRIVATE_DEFAULT_SECRET

        [engineering]
        aws_access_key_id = ENGINEERINGKEY # safe inline comment
        aws_secret_access_key = PRIVATE_ENGINEERING_SECRET
        aws_session_token = PRIVATE_ENGINEERING_TOKEN

        [deployment]
        aws_access_key_id = DEPLOYMENTKEY
        aws_secret_access_key = PRIVATE_DEPLOYMENT_SECRET

        [unrelated]
        credential_process = /must/never/run
        """)

        let overrides: [String: String]
        let expectedKey: String
        switch scenario {
        case "explicit":
            overrides = ["AWS_PROFILE": "engineering"]
            expectedKey = "ENGINEERINGKEY"
        case "fallback":
            overrides = ["AWS_DEFAULT_PROFILE": "deployment"]
            expectedKey = "DEPLOYMENTKEY"
        default:
            overrides = ["AWS_PROFILE": "engineering", "AWS_DEFAULT_PROFILE": "deployment"]
            expectedKey = "ENGINEERINGKEY"
        }

        let environment = try fixture.sharedCredentialEnvironment(overrides: overrides)
        let authorization = try LiveCloudTraceUpload.authorize(
            sessionID: "profile-selection",
            bucketURL: "s3://trace-private-bucket",
            document: LiveManagedSetupComposition.trustedConfigDocument(environment: environment),
            environment: environment
        )

        #expect(authorization.accessKeyID == expectedKey)
        #expect(authorization.sessionToken
            == (expectedKey == "ENGINEERINGKEY" ? "PRIVATE_ENGINEERING_TOKEN" : nil))
    }

    @Test("complete environment AWS credentials take precedence over hostile shared-provider configuration")
    func environmentCredentialsPrecedeEverySharedProvider() throws {
        let fixture = try CloudTraceUploadFixture()
        defer { fixture.clean() }
        let environment = try fixture.environment(overrides: [
            "AWS_SHARED_CREDENTIALS_FILE": "../../must-not-be-opened",
            "AWS_PROFILE": "../must-not-be-selected",
            "AWS_CONTAINER_CREDENTIALS_FULL_URI": "http://169.254.169.254/private",
        ])

        let authorization = try LiveCloudTraceUpload.authorize(
            sessionID: "environment-precedence",
            bucketURL: "s3://trace-private-bucket",
            document: LiveManagedSetupComposition.trustedConfigDocument(environment: environment),
            environment: environment
        )

        #expect(authorization.accessKeyID == "AKIDEXAMPLE")
        #expect(authorization.secretAccessKey == "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
    }

    @Test(
        "AWS_SHARED_CREDENTIALS_FILE resolves absolute and tilde paths against the injected home",
        arguments: ["absolute", "tilde"]
    )
    func explicitlySelectedPrivateCredentialFileIsSupported(_ scenario: String) throws {
        let fixture = try CloudTraceUploadFixture()
        defer { fixture.clean() }
        let location = scenario == "absolute"
            ? fixture.workspace.appendingPathComponent("private-cloud-credentials")
            : fixture.root
                .appendingPathComponent(".aws", isDirectory: true)
                .appendingPathComponent("credentials", isDirectory: false)
        try fixture.writeSharedCredentials("""
        [custom]
        aws_access_key_id = CUSTOMPROFILEKEY
        aws_secret_access_key = PRIVATE_CUSTOM_SECRET
        """, at: location)
        try SecureFile.write(
            at: fixture.root
                .appendingPathComponent(".aws", isDirectory: true)
                .appendingPathComponent("config", isDirectory: false),
            contents: "[profile custom]\nregion = us-west-2\n"
        )
        let environment = try fixture.sharedCredentialEnvironment(overrides: [
            "AWS_PROFILE": "custom",
            "AWS_SHARED_CREDENTIALS_FILE": scenario == "absolute" ? location.path : "~/.aws/credentials",
        ])

        let authorization = try LiveCloudTraceUpload.authorize(
            sessionID: "custom-profile-location",
            bucketURL: "s3://trace-private-bucket",
            document: LiveManagedSetupComposition.trustedConfigDocument(environment: environment),
            environment: environment
        )

        #expect(authorization.accessKeyID == "CUSTOMPROFILEKEY")
        #expect(authorization.secretAccessKey == "PRIVATE_CUSTOM_SECRET")
    }

    @Test("shared AWS profile parsing handles CRLF without crossing section boundaries")
    func sharedCredentialProfilesHonorCRLFLines() throws {
        let fixture = try CloudTraceUploadFixture()
        defer { fixture.clean() }
        try fixture.writeSharedCredentials(
            "[foreign]\r\naws_access_key_id = FOREIGNKEY\r\n"
                + "aws_secret_access_key = PRIVATE_FOREIGN_SECRET\r\n"
                + "[default]\r\naws_access_key_id = CRLFPROFILEKEY\r\n"
                + "aws_secret_access_key = PRIVATE_CRLF_SECRET\r\n"
        )
        let environment = try fixture.sharedCredentialEnvironment()

        let authorization = try LiveCloudTraceUpload.authorize(
            sessionID: "crlf-profile",
            bucketURL: "s3://trace-private-bucket",
            document: LiveManagedSetupComposition.trustedConfigDocument(environment: environment),
            environment: environment
        )

        #expect(authorization.accessKeyID == "CRLFPROFILEKEY")
        #expect(authorization.secretAccessKey == "PRIVATE_CRLF_SECRET")
    }

    @Test(
        "partial environment AWS credentials never mix with or downgrade to a shared profile",
        arguments: ["access-only", "secret-only", "token-only"]
    )
    func partialEnvironmentCredentialsNeverFallThrough(_ scenario: String) throws {
        let fixture = try CloudTraceUploadFixture()
        defer { fixture.clean() }
        try fixture.writeSharedCredentials("""
        [default]
        aws_access_key_id = VALIDPROFILEKEY
        aws_secret_access_key = PRIVATE_VALID_SECRET
        """)
        var environment = try fixture.sharedCredentialEnvironment()
        switch scenario {
        case "access-only": environment["AWS_ACCESS_KEY_ID"] = "PARTIALKEY"
        case "secret-only": environment["AWS_SECRET_ACCESS_KEY"] = "PRIVATE_PARTIAL_SECRET"
        default: environment["AWS_SESSION_TOKEN"] = "PRIVATE_PARTIAL_TOKEN"
        }

        #expect(throws: LiveCloudTraceUpload.Failure.missingCredentials) {
            try LiveCloudTraceUpload.authorize(
                sessionID: "partial-profile",
                bucketURL: "s3://trace-private-bucket",
                document: LiveManagedSetupComposition.trustedConfigDocument(environment: environment),
                environment: environment
            )
        }
    }

    @Test(
        "relative, traversing, oversized and invalid UTF-8 shared AWS files fail before network I/O",
        arguments: ["relative", "traversal", "oversized", "invalid-utf8"]
    )
    func unsafeSharedCredentialFilesNeverReachTransport(_ scenario: String) async throws {
        let fixture = try CloudTraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed("unsafe-shared-file")
        let location = fixture.workspace.appendingPathComponent("unsafe-credentials")
        let configuredPath: String
        switch scenario {
        case "relative":
            configuredPath = "relative-credentials"
        case "traversal":
            configuredPath = fixture.root.path + "/../private-outside-credentials"
        case "oversized":
            try SecureFile.write(at: location, contents: Data(repeating: UInt8(ascii: "a"), count: 65_537))
            configuredPath = location.path
        default:
            try SecureFile.write(at: location, contents: Data([0xFF, 0xFE]))
            configuredPath = location.path
        }
        let transport = MockHTTPTransport()

        let result = await fixture.run(
            "unsafe-shared-file",
            environment: try fixture.sharedCredentialEnvironment(overrides: [
                "AWS_SHARED_CREDENTIALS_FILE": configuredPath,
            ]),
            services: fixture.services(transport)
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.output.isEmpty)
        #expect(result.errors.contains("AWS"))
        #expect(transport.recordedRequests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.archiveDirectory.path))
    }

    #if !os(Windows)
    @Test(
        "symlinked and group-readable shared AWS files are rejected against their pinned descriptors",
        arguments: ["symlink", "group-readable"]
    )
    func sharedCredentialSymlinksAndBroadPermissionsFailClosed(_ scenario: String) async throws {
        let fixture = try CloudTraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed("unsafe-profile-mode")
        let target = fixture.workspace.appendingPathComponent("private-profile-target")
        try fixture.writeSharedCredentials("""
        [default]
        aws_access_key_id = UNSAFEPROFILEKEY
        aws_secret_access_key = PRIVATE_UNSAFE_SECRET
        """, at: target)
        let configuredPath: String
        if scenario == "symlink" {
            let link = fixture.workspace.appendingPathComponent("profile-link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            configuredPath = link.path
        } else {
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)
            configuredPath = target.path
        }
        let transport = MockHTTPTransport()

        let result = await fixture.run(
            "unsafe-profile-mode",
            environment: try fixture.sharedCredentialEnvironment(overrides: [
                "AWS_SHARED_CREDENTIALS_FILE": configuredPath,
            ]),
            services: fixture.services(transport)
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.output.isEmpty)
        #expect(!result.errors.contains("PRIVATE_UNSAFE_SECRET"))
        #expect(transport.recordedRequests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.archiveDirectory.path))
    }
    #endif

    @Test(
        "AWS web identity, container and metadata providers are refused without opening their endpoints",
        arguments: [
            "AWS_WEB_IDENTITY_TOKEN_FILE",
            "AWS_ROLE_ARN",
            "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI",
            "AWS_CONTAINER_CREDENTIALS_FULL_URI",
            "AWS_EC2_METADATA_SERVICE_ENDPOINT",
        ]
    )
    func dynamicCredentialProvidersNeverReachTheNetwork(_ provider: String) async throws {
        let fixture = try CloudTraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed("dynamic-provider")
        try fixture.writeSharedCredentials("""
        [default]
        aws_access_key_id = STATICPROFILEKEY
        aws_secret_access_key = PRIVATE_STATIC_SECRET
        """)
        let transport = MockHTTPTransport()

        let result = await fixture.run(
            "dynamic-provider",
            environment: try fixture.sharedCredentialEnvironment(overrides: [
                provider: "http://169.254.169.254/PRIVATE_METADATA_TOKEN",
            ]),
            services: fixture.services(transport)
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.output.isEmpty)
        #expect(!result.errors.contains("PRIVATE_METADATA_TOKEN"))
        #expect(transport.recordedRequests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.archiveDirectory.path))
    }

    @Test(
        "selected AWS profiles cannot execute commands, assume roles or start SSO",
        arguments: ["credential_process", "credential_source", "role_arn", "source_profile", "web_identity_token_file", "sso_session", "sso_start_url"]
    )
    func dynamicSelectedProfileProvidersFailClosed(_ provider: String) async throws {
        let fixture = try CloudTraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed("dynamic-profile")
        try fixture.writeSharedCredentials("""
        [default]
        aws_access_key_id = STATICPROFILEKEY
        aws_secret_access_key = PRIVATE_STATIC_SECRET
        \(provider) = /must/never/run/PRIVATE_PROFILE_COMMAND
        """)
        let transport = MockHTTPTransport()

        let result = await fixture.run(
            "dynamic-profile",
            environment: try fixture.sharedCredentialEnvironment(),
            services: fixture.services(transport)
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.output.isEmpty)
        #expect(!result.errors.contains("PRIVATE_PROFILE_COMMAND"))
        #expect(transport.recordedRequests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.archiveDirectory.path))
    }

    @Test(
        "merged default and explicitly selected AWS config files cannot introduce hidden role providers",
        arguments: ["default-config", "custom-config"]
    )
    func mergedAWSConfigCannotChangeStaticCredentialAuthority(_ scenario: String) async throws {
        let fixture = try CloudTraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed("merged-dynamic-profile")
        try fixture.writeSharedCredentials("""
        [engineering]
        aws_access_key_id = ENGINEERINGKEY
        aws_secret_access_key = PRIVATE_ENGINEERING_SECRET
        """)
        let configuration = scenario == "default-config"
            ? fixture.root
                .appendingPathComponent(".aws", isDirectory: true)
                .appendingPathComponent("config", isDirectory: false)
            : fixture.workspace.appendingPathComponent("private-aws-config")
        try SecureFile.write(at: configuration, contents: """
        [profile unrelated]
        role_arn = arn:aws:iam::111111111111:role/unrelated

        [profile engineering]
        credential_process = /must/never/run/PRIVATE_MERGED_COMMAND
        """)
        var overrides = ["AWS_PROFILE": "engineering"]
        if scenario == "custom-config" {
            overrides["AWS_CONFIG_FILE"] = configuration.path
        }
        let transport = MockHTTPTransport()

        let result = await fixture.run(
            "merged-dynamic-profile",
            environment: try fixture.sharedCredentialEnvironment(overrides: overrides),
            services: fixture.services(transport)
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.output.isEmpty)
        #expect(!result.errors.contains("PRIVATE_MERGED_COMMAND"))
        #expect(transport.recordedRequests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.archiveDirectory.path))
    }

    @Test("the real executable sends one signed path-style PUT to a real loopback listener")
    func productionExecutableUploadsSignedArchiveToLoopback() async throws {
        let fixture = try CloudTraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed("production-cloud")
        let handler = CloudTraceRequestHandler()
        let server = HttpServer(handler: handler, basePath: "")
        try server.start()
        defer { server.stop() }

        let result = await fixture.run(
            "production-cloud",
            environment: try fixture.environment(overrides: [
                "GROK_TRACE_UPLOAD_ENDPOINT_URL": server.baseURL,
                "AWS_SESSION_TOKEN": "PRIVATE_SESSION_TOKEN",
                "GROK_DEPLOYMENT_KEY": "PRIVATE_DEPLOYMENT_KEY",
            ])
        )

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(result.errors.isEmpty)
        #expect(try fixture.json(result.output)["url"] as? String
            == "s3://trace-private-bucket/production-cloud/trace_export.tar.gz")
        #expect(handler.requests.count == 1)
        let request = try #require(handler.requests.first)
        #expect(request.method == "PUT")
        #expect(request.pathOnly == "/trace-private-bucket/production-cloud/trace_export.tar.gz")
        #expect(request.authorization?.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/") == true)
        #expect(request.header("x-amz-security-token") == "PRIVATE_SESSION_TOKEN")
        #expect(request.body.starts(with: [0x1F, 0x8B]))
        for forbidden in [xaiTokenAuthHeader, "x-grok-client-version", "x-grok-client-identifier"] {
            #expect(request.header(forbidden) == nil)
        }
        for secret in ["PRIVATE_SESSION_TOKEN", "PRIVATE_DEPLOYMENT_KEY", "PRIVATE_XAI_OAUTH_BEARER"] {
            #expect(request.authorization?.contains(secret) == false)
            #expect(!result.output.contains(secret))
            #expect(!result.errors.contains(secret))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.archiveDirectory.path))
    }

    @Test("redirects cannot forward a signed archive or cloud credentials to another listener")
    func productionTransportNeverFollowsCloudRedirects() async throws {
        let fixture = try CloudTraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed("redirect-cloud")
        let destinationHandler = CloudTraceRequestHandler()
        let destination = HttpServer(handler: destinationHandler, basePath: "")
        try destination.start()
        defer { destination.stop() }
        let redirectURL = destination.baseURL + "/private-redirect-target"
        let sourceHandler = CloudTraceRequestHandler { _ in
            HttpResponse(status: 307, headers: [("Location", redirectURL)], body: .bytes(Data()))
        }
        let source = HttpServer(handler: sourceHandler, basePath: "")
        try source.start()
        defer { source.stop() }

        let result = await fixture.run(
            "redirect-cloud",
            environment: try fixture.environment(overrides: [
                "GROK_TRACE_UPLOAD_ENDPOINT_URL": source.baseURL,
                "AWS_SESSION_TOKEN": "PRIVATE_REDIRECT_SESSION_TOKEN",
            ])
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(sourceHandler.requests.count == 1)
        #expect(destinationHandler.requests.isEmpty)
        #expect(try fixture.json(result.output)["status"] as? String == "failed")
        #expect(!result.output.contains("PRIVATE_REDIRECT_SESSION_TOKEN"))
        #expect(!result.errors.contains("PRIVATE_REDIRECT_SESSION_TOKEN"))
    }

    @Test("default S3 destinations use region-scoped virtual hosting and China partitions")
    func awsVirtualHostingRespectsRegionalPartitions() throws {
        let fixture = try CloudTraceUploadFixture()
        defer { fixture.clean() }
        for (region, suffix) in [
            ("us-west-2", "amazonaws.com"),
            ("us-gov-west-1", "amazonaws.com"),
            ("cn-north-1", "amazonaws.com.cn"),
        ] {
            let environment = try fixture.environment(overrides: ["GROK_TRACE_UPLOAD_REGION": region])
            let authorization = try LiveCloudTraceUpload.authorize(
                sessionID: "regional-session",
                bucketURL: "s3://trace-private-bucket",
                document: LiveManagedSetupComposition.trustedConfigDocument(environment: environment),
                environment: environment
            )
            #expect(authorization.region == region)
            #expect(authorization.endpoint.absoluteString
                == "https://trace-private-bucket.s3.\(region).\(suffix)/regional-session/trace_export.tar.gz")
        }
    }

    @Test("explicit region precedes managed endpoint config, then AWS ambient fallback")
    func regionConfigurationUsesSecurityReviewedPrecedence() throws {
        let fixture = try CloudTraceUploadFixture(configuration: """

        [endpoints]
        trace_upload_region = "eu-central-1"
        """)
        defer { fixture.clean() }
        let environment = try fixture.environment()
        let document = LiveManagedSetupComposition.trustedConfigDocument(environment: environment)
        let configured = try LiveCloudTraceUpload.authorize(
            sessionID: "region-order",
            bucketURL: "s3://trace-private-bucket",
            document: document,
            environment: environment
        )
        let explicit = try LiveCloudTraceUpload.authorize(
            sessionID: "region-order",
            bucketURL: "s3://trace-private-bucket",
            document: document,
            environment: environment.merging(["GROK_TRACE_UPLOAD_REGION": "ap-southeast-2"]) {
                _, override in override
            }
        )

        #expect(configured.region == "eu-central-1")
        #expect(explicit.region == "ap-southeast-2")

        let fallback = try CloudTraceUploadFixture()
        defer { fallback.clean() }
        var fallbackEnvironment = try fallback.environment()
        fallbackEnvironment.removeValue(forKey: "AWS_REGION")
        fallbackEnvironment["AWS_DEFAULT_REGION"] = "sa-east-1"
        let fallbackDocument = LiveManagedSetupComposition.trustedConfigDocument(
            environment: fallbackEnvironment
        )
        let defaultRegion = try LiveCloudTraceUpload.authorize(
            sessionID: "region-order",
            bucketURL: "s3://trace-private-bucket",
            document: fallbackDocument,
            environment: fallbackEnvironment
        )
        #expect(defaultRegion.region == "sa-east-1")
        fallbackEnvironment.removeValue(forKey: "AWS_DEFAULT_REGION")
        let implicitRegion = try LiveCloudTraceUpload.authorize(
            sessionID: "region-order",
            bucketURL: "s3://trace-private-bucket",
            document: fallbackDocument,
            environment: fallbackEnvironment
        )
        #expect(implicitRegion.region == "us-east-1")
    }

    @Test(
        "malformed or missing scoped AWS credentials fail before archive creation or network I/O",
        arguments: ["missing-id", "missing-secret", "blank-id", "blank-secret", "injected-id", "injected-secret", "blank-token", "injected-token"]
    )
    func invalidCloudCredentialsNeverReachTheWire(_ scenario: String) async throws {
        let fixture = try CloudTraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed("invalid-credentials")
        var environment = try fixture.environment()
        switch scenario {
        case "missing-id": environment.removeValue(forKey: "AWS_ACCESS_KEY_ID")
        case "missing-secret": environment.removeValue(forKey: "AWS_SECRET_ACCESS_KEY")
        case "blank-id": environment["AWS_ACCESS_KEY_ID"] = "  "
        case "blank-secret": environment["AWS_SECRET_ACCESS_KEY"] = "  "
        case "injected-id": environment["AWS_ACCESS_KEY_ID"] = "AKID\nInjected: true"
        case "injected-secret": environment["AWS_SECRET_ACCESS_KEY"] = "PRIVATE\r\nInjected: true"
        case "blank-token": environment["AWS_SESSION_TOKEN"] = " "
        default: environment["AWS_SESSION_TOKEN"] = "PRIVATE\nInjected: true"
        }
        let transport = MockHTTPTransport()

        let result = await fixture.run(
            "invalid-credentials",
            environment: environment,
            services: fixture.services(transport)
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.output.isEmpty)
        #expect(result.errors.contains("AWS"))
        #expect(!result.errors.contains("PRIVATE"))
        #expect(!result.errors.contains("Injected"))
        #expect(transport.recordedRequests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.archiveDirectory.path))
    }

    @Test(
        "malicious bucket names are rejected before archive creation or network I/O",
        arguments: ["s3://ab", "s3://UPPERCASE", "s3://bucket.with.dots", "s3://bucket/nested", "s3://-bucket", "s3://bucket-", "s3://127.0.0.1", "s3://bucket@evil.example"]
    )
    func unsafeBucketsFailClosed(_ bucket: String) async throws {
        let fixture = try CloudTraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed("invalid-bucket")
        let transport = MockHTTPTransport()

        let result = await fixture.run(
            "invalid-bucket",
            environment: try fixture.environment(overrides: ["GROK_TRACE_UPLOAD_BUCKET": bucket]),
            services: fixture.services(transport)
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.output.isEmpty)
        #expect(transport.recordedRequests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.archiveDirectory.path))
    }

    @Test(
        "metadata, private, public, spoofed loopback and credential-bearing custom endpoints are refused",
        arguments: [
            "http://169.254.169.254/latest/meta-data/iam/security-credentials",
            "http://10.0.0.2:9000",
            "http://172.16.0.2:9000",
            "http://192.168.0.2:9000",
            "https://public-storage.example",
            "http://localhost:9000",
            "http://127.0.0.2:9000",
            "http://user:PRIVATE_PASSWORD@127.0.0.1:9000",
            "http://127.0.0.1:9000?token=PRIVATE_QUERY",
            "http://127.0.0.1:9000#PRIVATE_FRAGMENT",
            "file:///tmp/private-cloud-archive",
        ]
    )
    func unsafeCustomEndpointsNeverReceiveRequests(_ endpoint: String) async throws {
        let fixture = try CloudTraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed("invalid-endpoint")
        let transport = MockHTTPTransport()

        let result = await fixture.run(
            "invalid-endpoint",
            environment: try fixture.environment(overrides: [
                "GROK_TRACE_UPLOAD_ENDPOINT_URL": endpoint,
            ]),
            services: fixture.services(transport)
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.output.isEmpty)
        #expect(!result.errors.contains("PRIVATE_PASSWORD"))
        #expect(!result.errors.contains("PRIVATE_QUERY"))
        #expect(!result.errors.contains("PRIVATE_FRAGMENT"))
        #expect(transport.recordedRequests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.archiveDirectory.path))
    }

    @Test(
        "invalid regions cannot change S3 authority or inject signed request headers",
        arguments: ["US-west-2", "us-east-0", "us-east-1.amazonaws.com", "cn-gov-north-1", "us-west-2/evil", "us-west-2\nHost: attacker"]
    )
    func unsafeRegionsFailClosed(_ region: String) async throws {
        let fixture = try CloudTraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed("invalid-region")
        let transport = MockHTTPTransport()

        let result = await fixture.run(
            "invalid-region",
            environment: try fixture.environment(overrides: ["GROK_TRACE_UPLOAD_REGION": region]),
            services: fixture.services(transport)
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.output.isEmpty)
        #expect(transport.recordedRequests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.archiveDirectory.path))
    }

    @Test("AWS credentials never substitute for first-party xAI or deployment authorization")
    func cloudCredentialsCannotBypassFirstPartyIdentity() async throws {
        let fixture = try CloudTraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed("identity-boundary")
        var environment = try fixture.environment()
        environment.removeValue(forKey: "OPENGROK_AUTH")
        let transport = MockHTTPTransport()

        let result = await fixture.run(
            "identity-boundary",
            environment: environment,
            services: fixture.services(transport)
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.output.isEmpty)
        #expect(result.errors.contains("first-party xAI session credential or deployment credential"))
        #expect(transport.recordedRequests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.archiveDirectory.path))
    }

    @Test(
        "privacy opt-out, ZDR, missing provider boundaries and foreign providers veto direct S3",
        arguments: ["zdr", "opted-out", "legacy-boundary", "closed-boundary", "foreign-provider"]
    )
    func privacyAndProviderBoundariesOverrideCloudCredentials(_ scenario: String) async throws {
        let fixture = try CloudTraceUploadFixture()
        defer { fixture.clean() }
        let provider: ModelProvider? = scenario == "foreign-provider" ? .codex : .xai
        let boundary: Bool? = scenario == "legacy-boundary" ? nil : scenario == "closed-boundary"
        try await fixture.seed("privacy-boundary", provider: provider, everUsedNonXAI: boundary)
        let auth = fixture.auth(
            optedOut: scenario == "opted-out",
            blockedReasons: scenario == "zdr" ? ["BLOCKED_REASON_NO_LOGS"] : []
        )
        let transport = MockHTTPTransport()

        let result = await fixture.run(
            "privacy-boundary",
            environment: try fixture.environment(auth: auth, overrides: [
                "GROK_DEPLOYMENT_KEY": "PRIVATE_DEPLOYMENT_KEY",
            ]),
            services: fixture.services(transport)
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.output.isEmpty)
        #expect(transport.recordedRequests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.archiveDirectory.path))
    }

    @Test("multipart SigV4 canonical queries are sorted, escaped and independently signed")
    func multipartCanonicalQueryMatchesIndependentSignature() throws {
        let authorization = LiveCloudTraceUpload.Authorization(
            endpoint: try #require(URL(string:
                "https://trace-bucket.s3.us-west-2.amazonaws.com/canonical-session/trace_export.tar.gz"
            )),
            bucket: "trace-bucket",
            region: "us-west-2",
            accessKeyID: "AKIDEXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            sessionToken: nil
        )
        let request = try LiveCloudTraceUpload.signedRequest(
            authorization: authorization,
            method: .put,
            query: [("uploadId", "token+part/="), ("partNumber", "2")],
            body: Data("multipart bytes".utf8),
            contentType: "application/gzip",
            now: Date(timeIntervalSince1970: 1_440_938_160)
        )

        #expect(request.url.absoluteString
            == authorization.endpoint.absoluteString + "?partNumber=2&uploadId=token%2Bpart%2F%3D")
        #expect(request.headers["X-Amz-Content-Sha256"]
            == "478a20786fcad12b4f40a8c0a5e1d3df1de2c616c0de2ed033197103ef28c560")
        #expect(request.headers["Authorization"]
            == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-west-2/s3/aws4_request, "
                + "SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date, "
                + "Signature=0c62dc3df14046ee5d35962dbd29ca33de16f003c1849ceda309543f25ab5f5a")
    }

    @Test("the upstream 8 MiB threshold creates, uploads and completes a signed S3 part")
    func upstreamMultipartThresholdUsesTheProductionUploadPath() async throws {
        let fixture = try CloudTraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed("threshold-cloud")
        let environment = try fixture.environment()
        let document = LiveManagedSetupComposition.trustedConfigDocument(environment: environment)
        let authorization = try await LiveTraceUpload.authorize(
            sessionID: "threshold-cloud",
            home: fixture.home,
            document: document,
            environment: environment,
            uploadEnabled: true
        )
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(statusCode: 200),
                body: S3MultipartTraceFixture.initiation(sessionID: "threshold-cloud")
            ),
            .init(metadata: HTTPResponseMetadata(statusCode: 200, headers: ["ETag": "\"part-one\""])),
            .init(
                metadata: HTTPResponseMetadata(statusCode: 200),
                body: S3MultipartTraceFixture.completion(sessionID: "threshold-cloud")
            ),
        ])

        let result = try await LiveTraceUpload.upload(
            sessionID: "threshold-cloud",
            archive: Data(count: LiveCloudTraceUpload.maximumArchiveBytes),
            initialAuthorization: authorization,
            home: fixture.home,
            document: document,
            environment: environment,
            uploadEnabled: true,
            services: fixture.services(transport),
            retryNotice: nil
        )

        #expect(result == "s3://trace-private-bucket/threshold-cloud/trace_export.tar.gz")
        let requests = transport.recordedRequests
        #expect(requests.map(\.method) == [.post, .put, .post])
        #expect(requests[0].url.query == "uploads=")
        #expect(requests[1].url.absoluteString.contains(
            "?partNumber=1&uploadId=multipart%2Btoken%2F%3D"
        ))
        #expect(requests[1].body?.count == LiveCloudTraceUpload.maximumArchiveBytes)
        #expect(requests[2].headers["Content-Type"] == "application/xml")
        for request in requests {
            #expect(request.headers["Authorization"]?.hasPrefix("AWS4-HMAC-SHA256 ") == true)
            #expect(request.headers[xaiTokenAuthHeader] == nil)
        }
    }

    @Test("real loopback S3 multipart requests preserve signing, ordering and XML-safe ETags")
    func realLoopbackMultipartTransportCompletesEverySignedPart() async throws {
        let fixture = try CloudTraceUploadFixture()
        defer { fixture.clean() }
        let sessionID = "loopback-multipart"
        let handler = CloudTraceRequestHandler { request in
            if request.method == "POST", request.query == "uploads=" {
                return HttpResponse(
                    status: 200,
                    body: .bytes(S3MultipartTraceFixture.initiation(sessionID: sessionID))
                )
            }
            if request.method == "PUT" {
                return HttpResponse(
                    status: 200,
                    headers: [("ETag", "\"part<&>\"")],
                    body: .bytes(Data())
                )
            }
            if request.method == "POST", request.query.hasPrefix("uploadId=") {
                return HttpResponse(
                    status: 200,
                    body: .bytes(S3MultipartTraceFixture.completion(sessionID: sessionID))
                )
            }
            return HttpResponse.text(status: 500, "unexpected multipart operation")
        }
        let server = HttpServer(handler: handler, basePath: "")
        try server.start()
        defer { server.stop() }
        let environment = try fixture.environment(overrides: [
            "GROK_TRACE_UPLOAD_ENDPOINT_URL": server.baseURL,
            "AWS_SESSION_TOKEN": "PRIVATE_MULTIPART_TOKEN",
        ])
        let cloud = try LiveCloudTraceUpload.authorize(
            sessionID: sessionID,
            bucketURL: "s3://trace-private-bucket",
            document: LiveManagedSetupComposition.trustedConfigDocument(environment: environment),
            environment: environment
        )

        let result = try await LiveS3MultipartUpload.upload(
            sessionID: sessionID,
            archive: Data(repeating: 0xAB, count: 17),
            authorization: cloud,
            transport: LiveCloudTraceUpload.makeProductionTransport(),
            limits: .init(partSize: 8, maximumPartCount: 10),
            authorizeRequest: { cloud }
        )

        #expect(result == "s3://trace-private-bucket/loopback-multipart/trace_export.tar.gz")
        let requests = handler.requests
        #expect(requests.map(\.method) == ["POST", "PUT", "PUT", "PUT", "POST"])
        #expect(requests[1].body.count == 8)
        #expect(requests[2].body.count == 8)
        #expect(requests[3].body.count == 1)
        #expect(requests[1].query == "partNumber=1&uploadId=multipart%2Btoken%2F%3D")
        #expect(requests[4].query == "uploadId=multipart%2Btoken%2F%3D")
        let completion = String(decoding: requests[4].body, as: UTF8.self)
        #expect(completion.contains("<PartNumber>1</PartNumber>"))
        #expect(completion.contains("<PartNumber>2</PartNumber>"))
        #expect(completion.contains("<PartNumber>3</PartNumber>"))
        #expect(completion.contains("<ETag>&quot;part&lt;&amp;&gt;&quot;</ETag>"))
        for request in requests {
            #expect(request.authorization?.hasPrefix("AWS4-HMAC-SHA256 ") == true)
            #expect(request.header("x-amz-security-token") == "PRIVATE_MULTIPART_TOKEN")
            #expect(request.header(xaiTokenAuthHeader) == nil)
        }
    }

    @Test("multipart archive and AWS part-count limits reject overflow before network I/O")
    func multipartArchiveLimitsAreExplicitAndBounded() throws {
        #expect(try LiveS3MultipartUpload.validatedPartCount(
            archiveBytes: LiveCloudTraceUpload.maximumArchiveBytes
        ) == 1)
        #expect(try LiveS3MultipartUpload.validatedPartCount(
            archiveBytes: LiveCloudTraceUpload.maximumArchiveBytes + 1
        ) == 2)
        #expect(throws: LiveCloudTraceUpload.Failure.archiveTooLarge) {
            try LiveS3MultipartUpload.validatedPartCount(
                archiveBytes: LiveCloudTraceUpload.maximumArchiveBytes * 10_000 + 1
            )
        }
        #expect(throws: LiveCloudTraceUpload.Failure.archiveTooLarge) {
            try LiveS3MultipartUpload.validatedPartCount(
                archiveBytes: 8,
                limits: .init(partSize: 8, maximumPartCount: 10_001)
            )
        }
    }

    @Test(
        "missing, hostile and oversized S3 upload identifiers never reach an upload or abort request",
        arguments: ["missing", "query-injection", "whitespace", "oversized", "doctype"]
    )
    func invalidMultipartIdentifiersStopBeforePartDispatch(_ scenario: String) async throws {
        let fixture = try CloudTraceUploadFixture()
        defer { fixture.clean() }
        let environment = try fixture.environment()
        let cloud = try LiveCloudTraceUpload.authorize(
            sessionID: "invalid-upload-id",
            bucketURL: "s3://trace-private-bucket",
            document: LiveManagedSetupComposition.trustedConfigDocument(environment: environment),
            environment: environment
        )
        let body: Data
        switch scenario {
        case "missing":
            body = Data("<InitiateMultipartUploadResult></InitiateMultipartUploadResult>".utf8)
        case "query-injection":
            body = S3MultipartTraceFixture.initiation(sessionID: "invalid-upload-id", uploadID: "bad&partNumber=9")
        case "whitespace":
            body = S3MultipartTraceFixture.initiation(sessionID: "invalid-upload-id", uploadID: "bad token")
        case "oversized":
            body = S3MultipartTraceFixture.initiation(
                sessionID: "invalid-upload-id",
                uploadID: String(repeating: "x", count: 2_049)
            )
        default:
            body = Data("<!DOCTYPE x><InitiateMultipartUploadResult><UploadId>ok</UploadId></InitiateMultipartUploadResult>".utf8)
        }
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: body),
        ])

        await #expect(throws: (any Error).self) {
            try await LiveS3MultipartUpload.upload(
                sessionID: "invalid-upload-id",
                archive: Data(count: 8),
                authorization: cloud,
                transport: transport,
                limits: .init(partSize: 8),
                authorizeRequest: { cloud }
            )
        }
        #expect(transport.recordedRequests.count == 1)
        #expect(transport.recordedRequests[0].method == .post)
    }

    @Test(
        "missing and malformed multipart ETags abort the initiated upload without completing it",
        arguments: ["missing", "unquoted", "injected-newline", "embedded-quote"]
    )
    func invalidMultipartETagsTriggerBoundedAbort(_ scenario: String) async throws {
        let fixture = try CloudTraceUploadFixture()
        defer { fixture.clean() }
        let environment = try fixture.environment()
        let cloud = try LiveCloudTraceUpload.authorize(
            sessionID: "invalid-part-etag",
            bucketURL: "s3://trace-private-bucket",
            document: LiveManagedSetupComposition.trustedConfigDocument(environment: environment),
            environment: environment
        )
        let headers: [String: String]
        switch scenario {
        case "missing": headers = [:]
        case "unquoted": headers = ["ETag": "unquoted-tag"]
        case "injected-newline": headers = ["ETag": "\"tag\nInjected: true\""]
        default: headers = ["ETag": "\"tag\"injected\""]
        }
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(statusCode: 200),
                body: S3MultipartTraceFixture.initiation(sessionID: "invalid-part-etag")
            ),
            .init(metadata: HTTPResponseMetadata(statusCode: 200, headers: headers)),
            .init(metadata: HTTPResponseMetadata(statusCode: 204)),
        ])

        await #expect(throws: LiveCloudTraceUpload.Failure.invalidMultipartETag) {
            try await LiveS3MultipartUpload.upload(
                sessionID: "invalid-part-etag",
                archive: Data(count: 8),
                authorization: cloud,
                transport: transport,
                limits: .init(partSize: 8),
                authorizeRequest: { cloud }
            )
        }
        let requests = transport.recordedRequests
        #expect(requests.map(\.method) == [.post, .put, .delete])
        #expect(requests[2].url.absoluteString.hasSuffix("?uploadId=multipart%2Btoken%2F%3D"))
        #expect(requests[2].timeout == 10)
        #expect(requests[2].headers["Authorization"]?.hasPrefix("AWS4-HMAC-SHA256 ") == true)
    }

    @Test("a failing multipart part issues exactly one signed best-effort abort")
    func rejectedMultipartPartAbortsExactlyOnce() async throws {
        let fixture = try CloudTraceUploadFixture()
        defer { fixture.clean() }
        let environment = try fixture.environment()
        let cloud = try LiveCloudTraceUpload.authorize(
            sessionID: "rejected-part",
            bucketURL: "s3://trace-private-bucket",
            document: LiveManagedSetupComposition.trustedConfigDocument(environment: environment),
            environment: environment
        )
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(statusCode: 200),
                body: S3MultipartTraceFixture.initiation(sessionID: "rejected-part")
            ),
            .init(metadata: HTTPResponseMetadata(statusCode: 503)),
            .init(metadata: HTTPResponseMetadata(statusCode: 204)),
        ])

        await #expect(throws: LiveCloudTraceUpload.Failure.multipartRejected(503)) {
            try await LiveS3MultipartUpload.upload(
                sessionID: "rejected-part",
                archive: Data(count: 8),
                authorization: cloud,
                transport: transport,
                limits: .init(partSize: 8),
                authorizeRequest: { cloud }
            )
        }
        #expect(transport.recordedRequests.map(\.method) == [.post, .put, .delete])
    }

    @Test("a provider boundary closed after multipart creation suppresses both parts and abort")
    func providerBoundaryClosurePreventsEveryFurtherMultipartRequest() async throws {
        let fixture = try CloudTraceUploadFixture()
        defer { fixture.clean() }
        let original = try await fixture.seed("revoked-multipart")
        let environment = try fixture.environment()
        let document = LiveManagedSetupComposition.trustedConfigDocument(environment: environment)
        let initial = try await LiveTraceUpload.authorize(
            sessionID: "revoked-multipart",
            home: fixture.home,
            document: document,
            environment: environment,
            uploadEnabled: true
        )
        let scripted = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(statusCode: 200),
                body: S3MultipartTraceFixture.initiation(sessionID: "revoked-multipart")
            ),
        ])
        let home = fixture.home
        let revoked = MultipartBoundaryRevokingTransport(wrapped: scripted) {
            var changed = original
            changed.currentProvider = .codex
            changed.everUsedNonXAI = true
            try await LiveConversationStore(openGrokHome: home).save(changed)
        }
        let services = LiveTraceUploadServices(makeTransport: { revoked }, sleep: { _ in })

        await #expect(throws: (any Error).self) {
            try await LiveTraceUpload.upload(
                sessionID: "revoked-multipart",
                archive: Data(count: LiveCloudTraceUpload.maximumArchiveBytes),
                initialAuthorization: initial,
                home: fixture.home,
                document: document,
                environment: environment,
                uploadEnabled: true,
                services: services,
                retryNotice: nil
            )
        }
        #expect(scripted.recordedRequests.count == 1)
        #expect(scripted.recordedRequests.first?.method == .post)
    }

    @Test("a provider boundary closed during S3 retry prevents every subsequent wire request")
    func providerBoundaryRecheckedBeforeCloudRetry() async throws {
        let fixture = try CloudTraceUploadFixture()
        defer { fixture.clean() }
        let original = try await fixture.seed("cloud-retry-boundary")
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 503)),
            .init(metadata: HTTPResponseMetadata(statusCode: 200)),
        ])
        let home = fixture.home

        let result = await fixture.run(
            "cloud-retry-boundary",
            environment: try fixture.environment(),
            services: fixture.services(transport, sleep: { _ in
                var changed = original
                changed.currentProvider = .codex
                changed.everUsedNonXAI = true
                try await LiveConversationStore(openGrokHome: home).save(changed)
            })
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(transport.recordedRequests.count == 1)
        #expect(try fixture.json(result.output)["status"] as? String == "failed")
    }

    @Test("cloud failures preserve private fallback permissions and redact every credential")
    func failureDiagnosticsAndArchiveNeverContainCredentials() async throws {
        let fixture = try CloudTraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed("cloud-redaction")
        let accessID = "PRIVATEAWSACCESSID"
        let secret = "PRIVATEAWSSECRETKEY"
        let sessionToken = "PRIVATEAWSSESSIONTOKEN"
        let deployment = "PRIVATEDEPLOYMENTKEY"
        let oauth = "PRIVATEXAIOAUTHBEARER"
        let serverBody = "PRIVATES3SERVERRESPONSE"
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 403), body: Data(serverBody.utf8)),
        ])

        let result = await fixture.run(
            "cloud-redaction",
            environment: try fixture.environment(auth: fixture.auth(key: oauth), overrides: [
                "AWS_ACCESS_KEY_ID": accessID,
                "AWS_SECRET_ACCESS_KEY": secret,
                "AWS_SESSION_TOKEN": sessionToken,
                "GROK_DEPLOYMENT_KEY": deployment,
            ]),
            services: fixture.services(transport)
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(transport.recordedRequests.count == 1)
        let output = try fixture.json(result.output)
        #expect(output["status"] as? String == "failed")
        let archive = URL(fileURLWithPath: try #require(output["local_path"] as? String))
        let log = fixture.archiveDirectory.appendingPathComponent("cloud-redaction.upload.log")
        #expect(try SecureFile.isOwnerOnly(at: archive))
        #expect(try SecureFile.isOwnerOnly(at: log))
        let diagnostics = try String(contentsOf: log, encoding: .utf8)
        let tar = try BundleArchiveExtractor.decompressGzip(Data(contentsOf: archive))
        let archiveContents = String(decoding: tar, as: UTF8.self)
        for credential in [accessID, secret, sessionToken, deployment, oauth, serverBody] {
            #expect(!result.output.contains(credential))
            #expect(!result.errors.contains(credential))
            #expect(!diagnostics.contains(credential))
            #expect(!archiveContents.contains(credential))
        }
    }

    @Test("Google Cloud buckets remain fail-closed even when valid AWS credentials exist")
    func googleCloudRemainsExplicitlyUnavailable() async throws {
        let fixture = try CloudTraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed("google-cloud-refusal")
        let transport = MockHTTPTransport()

        let result = await fixture.run(
            "google-cloud-refusal",
            environment: try fixture.environment(overrides: [
                "GROK_TRACE_UPLOAD_BUCKET": "gs://private-google-bucket",
            ]),
            services: fixture.services(transport)
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.output.isEmpty)
        #expect(result.errors.contains("direct cloud-storage upload method is not available"))
        #expect(transport.recordedRequests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.archiveDirectory.path))
    }
}
