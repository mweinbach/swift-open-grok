import Foundation
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokFileUtils
import OpenGrokHTTP
import OpenGrokModels
import OpenGrokSamplingTypes
import Testing

@testable import OpenGrokCLI

private struct AWSWebIdentityTraceFixture {
    static let bucket = "trace-private-bucket"
    static let xaiToken = "PRIVATE_XAI_OAUTH_BEARER"
    static let jwt = "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJwcml2YXRlIn0.cHJpdmF0ZS1zaWduYXR1cmU"
    static let rotatedJWT = "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJyb3RhdGVkIn0.cm90YXRlZC1zaWduYXR1cmU"
    static let roleARN = "arn:aws:iam::123456789012:role/private/trace-writer"
    static let sessionName = "private-trace-session"
    static let accessKeyID = "ASIATEMPORARYTRACEKEY"
    static let secretAccessKey = "PRIVATE_TEMPORARY_AWS_SECRET"
    static let sessionToken = "PRIVATE_TEMPORARY_AWS_SESSION_TOKEN"

    let root: URL
    let home: URL
    let workspace: URL
    let tokenFile: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-aws-web-identity-\(UUID().uuidString)",
            isDirectory: true
        )
        home = root.appendingPathComponent("state", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        tokenFile = workspace.appendingPathComponent("private-subject.jwt")
        #if os(Windows)
        try OpenGrokConfig.createDirAllOwnerOnly(root, stateRoot: root)
        try OpenGrokConfig.createDirAllOwnerOnly(home, stateRoot: home)
        try OpenGrokConfig.createDirAllOwnerOnly(workspace, stateRoot: root)
        #else
        for directory in [root, home, workspace] {
            try OpenGrokConfig.createDirAllOwnerOnly(directory)
        }
        #endif
        try SecureFile.write(
            at: home.appendingPathComponent("config.toml"),
            contents: "[telemetry]\ntrace_upload = true\n"
        )
        try SecureFile.write(at: tokenFile, contents: Self.jwt)
    }

    func environment(
        auth: GrokAuth? = nil,
        overrides: [String: String] = [:]
    ) throws -> [String: String] {
        let account = auth ?? GrokAuth(
            key: Self.xaiToken,
            authMode: .oidc,
            userID: "aws-web-identity-user",
            codingDataRetentionOptOut: false,
            oidcIssuer: "https://auth.x.ai"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var environment = [
            "HOME": root.path,
            "OPENGROK_HOME": home.path,
            "PWD": workspace.path,
            "GROK_TRACE_UPLOAD_BUCKET": "s3://\(Self.bucket)",
            "AWS_REGION": "us-west-2",
            "AWS_WEB_IDENTITY_TOKEN_FILE": tokenFile.path,
            "AWS_ROLE_ARN": Self.roleARN,
            "AWS_ROLE_SESSION_NAME": Self.sessionName,
            "OPENGROK_AUTH": String(decoding: try encoder.encode(account), as: UTF8.self),
        ]
        environment.merge(overrides) { _, override in override }
        return environment
    }

    func profileEnvironment(
        profile: String = "default",
        configuration: String?,
        credentials: String? = nil,
        ambient: [String: String] = [:]
    ) throws -> [String: String] {
        let directory = root.appendingPathComponent(".aws", isDirectory: true)
        #if os(Windows)
        try OpenGrokConfig.createDirAllOwnerOnly(directory, stateRoot: root)
        #else
        try OpenGrokConfig.createDirAllOwnerOnly(directory)
        #endif
        if let configuration {
            try SecureFile.write(
                at: directory.appendingPathComponent("config"),
                contents: configuration
            )
        }
        if let credentials {
            try SecureFile.write(
                at: directory.appendingPathComponent("credentials"),
                contents: credentials
            )
        }

        var environment = try self.environment()
        environment.removeValue(forKey: "AWS_WEB_IDENTITY_TOKEN_FILE")
        environment.removeValue(forKey: "AWS_ROLE_ARN")
        environment.removeValue(forKey: "AWS_ROLE_SESSION_NAME")
        if profile != "default" {
            environment["AWS_PROFILE"] = profile
        }
        environment.merge(ambient) { _, override in override }
        return environment
    }

    static func profileConfiguration(
        section: String = "default",
        tokenPath: String,
        roleARN: String = AWSWebIdentityTraceFixture.roleARN,
        sessionName: String? = AWSWebIdentityTraceFixture.sessionName
    ) -> String {
        var configuration = "[\(section)]\n"
            + "role_arn = \(roleARN)\n"
            + "web_identity_token_file = \(tokenPath)\n"
        if let sessionName {
            configuration += "role_session_name = \(sessionName)\n"
        }
        return configuration
    }

    @discardableResult
    func seed(_ sessionID: String, provider: ModelProvider = .xai) async throws -> LiveConversationRecord {
        var record = LiveConversationRecord.new(sessionID: sessionID, workingDirectory: workspace)
        record.currentModelID = "grok-code-fast-1"
        record.currentProvider = provider
        record.everUsedNonXAI = provider != .xai
        record.items = [.user("PRIVATE_AWS_WEB_IDENTITY_TRANSCRIPT")]
        try await LiveConversationStore(openGrokHome: home).save(record)
        return record
    }

    func run(
        _ sessionID: String,
        environment: [String: String],
        transport: any HTTPTransport
    ) async -> (status: Int32, output: String, errors: String) {
        let services = LiveTraceUploadServices(makeTransport: { transport }, sleep: { _ in })
        let launcher = CLIApplicationLauncher { command, context in
            try LiveTraceComposition.session(for: command, context: context, services: services)
        }
        let (streams, stdout, stderr) = CLIStreams.buffered()
        let status = await CLIRunner.run(
            ["trace", sessionID, "--json"],
            environment: environment,
            streams: streams,
            application: OpenGrokApplication(launcher: launcher, control: .never)
        )
        return (status, stdout.contents, stderr.contents)
    }

    func cloudAuthorization(
        sessionID: String = "aws-web-session",
        environment: [String: String]? = nil
    ) throws -> LiveCloudTraceUpload.Authorization {
        let environment = try environment ?? self.environment()
        return try LiveCloudTraceUpload.authorize(
            sessionID: sessionID,
            bucketURL: "s3://\(Self.bucket)",
            document: LiveManagedSetupComposition.trustedConfigDocument(environment: environment),
            environment: environment
        )
    }

    static func responseXML(
        partition: String = "aws",
        accountID: String = "123456789012",
        sessionName: String = AWSWebIdentityTraceFixture.sessionName,
        accessKeyID: String = AWSWebIdentityTraceFixture.accessKeyID,
        secretAccessKey: String = AWSWebIdentityTraceFixture.secretAccessKey,
        sessionToken: String = AWSWebIdentityTraceFixture.sessionToken,
        expiration: Date = Date().addingTimeInterval(3_600)
    ) -> String {
        let expiry = ISO8601DateFormatter().string(from: expiration)
        return "<AssumeRoleWithWebIdentityResponse xmlns=\"https://sts.amazonaws.com/doc/2011-06-15/\">"
            + "<AssumeRoleWithWebIdentityResult>"
            + "<Credentials><AccessKeyId>\(accessKeyID)</AccessKeyId>"
            + "<SecretAccessKey>\(secretAccessKey)</SecretAccessKey>"
            + "<SessionToken>\(sessionToken)</SessionToken>"
            + "<Expiration>\(expiry)</Expiration></Credentials>"
            + "<AssumedRoleUser><Arn>arn:\(partition):sts::\(accountID):assumed-role/trace-writer/\(sessionName)</Arn>"
            + "<AssumedRoleId>AROAPRIVATE:\(sessionName)</AssumedRoleId></AssumedRoleUser>"
            + "</AssumeRoleWithWebIdentityResult>"
            + "<ResponseMetadata><RequestId>private-request</RequestId></ResponseMetadata>"
            + "</AssumeRoleWithWebIdentityResponse>"
    }

    static func stsResponse(
        status: Int = 200,
        body: String? = nil,
        url: URL? = nil
    ) -> MockHTTPTransport.ScriptedResponse {
        .init(
            metadata: HTTPResponseMetadata(statusCode: status, url: url),
            body: Data((body ?? responseXML()).utf8)
        )
    }

    static func initiation(sessionID: String) -> MockHTTPTransport.ScriptedResponse {
        .init(
            metadata: HTTPResponseMetadata(statusCode: 200),
            body: Data(("<InitiateMultipartUploadResult><Bucket>\(bucket)</Bucket>"
                + "<Key>\(sessionID)/trace_export.tar.gz</Key>"
                + "<UploadId>private-multipart-token</UploadId>"
                + "</InitiateMultipartUploadResult>").utf8)
        )
    }

    static func completion(sessionID: String) -> MockHTTPTransport.ScriptedResponse {
        .init(
            metadata: HTTPResponseMetadata(statusCode: 200),
            body: Data(("<CompleteMultipartUploadResult><Bucket>\(bucket)</Bucket>"
                + "<Key>\(sessionID)/trace_export.tar.gz</Key>"
                + "</CompleteMultipartUploadResult>").utf8)
        )
    }

    func clean() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor AWSWebIdentityMutationTransport: HTTPTransport {
    private let wrapped: MockHTTPTransport
    private let invocation: Int
    private let mutation: @Sendable () async throws -> Void
    private var requests = 0

    init(
        wrapped: MockHTTPTransport,
        invocation: Int,
        mutation: @escaping @Sendable () async throws -> Void
    ) {
        self.wrapped = wrapped
        self.invocation = invocation
        self.mutation = mutation
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests += 1
        let response = try await wrapped.send(request)
        if requests == invocation {
            try await mutation()
        }
        return response
    }

    nonisolated func stream(_ request: HTTPRequest) -> AsyncThrowingStream<HTTPStreamEvent, Error> {
        wrapped.stream(request)
    }
}

@Suite("live AWS web-identity STS credentials and direct S3 trace upload", .serialized)
struct LiveAWSWebIdentityCredentialParityTests {
    @Test("the real headless trace command performs one unsigned regional STS exchange and one signed S3 upload")
    func executableTraceLaunchExchangesAndSignsWithoutCrossAuthorityCredentials() async throws {
        let fixture = try AWSWebIdentityTraceFixture()
        defer { fixture.clean() }
        try await fixture.seed("web-identity-launch")
        let transport = MockHTTPTransport(responses: [
            AWSWebIdentityTraceFixture.stsResponse(),
            .init(metadata: HTTPResponseMetadata(statusCode: 200)),
        ])

        let result = await fixture.run(
            "web-identity-launch",
            environment: try fixture.environment(),
            transport: transport
        )

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(result.errors.isEmpty)
        #expect(result.output.contains(
            "s3://trace-private-bucket/web-identity-launch/trace_export.tar.gz"
        ))
        let requests = transport.recordedRequests
        #expect(requests.count == 2)
        let sts = try #require(requests.first)
        #expect(sts.method == .post)
        #expect(sts.url.absoluteString == "https://sts.us-west-2.amazonaws.com/")
        #expect(sts.headers["Content-Type"] == "application/x-www-form-urlencoded")
        #expect(sts.headers["Authorization"] == nil)
        #expect(sts.headers["X-Amz-Security-Token"] == nil)
        #expect(sts.headers[xaiTokenAuthHeader] == nil)
        let body = String(decoding: try #require(sts.body), as: UTF8.self)
        let components = try #require(URLComponents(string: "https://unused.invalid/?" + body))
        let fields = try #require(components.queryItems)
        #expect(fields.count == 5)
        #expect(fields.map(\.name) == [
            "Action", "Version", "RoleArn", "RoleSessionName", "WebIdentityToken",
        ])
        #expect(Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value ?? "") }) == [
            "Action": "AssumeRoleWithWebIdentity",
            "Version": "2011-06-15",
            "RoleArn": AWSWebIdentityTraceFixture.roleARN,
            "RoleSessionName": AWSWebIdentityTraceFixture.sessionName,
            "WebIdentityToken": AWSWebIdentityTraceFixture.jwt,
        ])

        let upload = try #require(requests.last)
        #expect(upload.method == .put)
        #expect(upload.url.host == "trace-private-bucket.s3.us-west-2.amazonaws.com")
        #expect(upload.headers["Authorization"]?.contains(
            "Credential=\(AWSWebIdentityTraceFixture.accessKeyID)/"
        ) == true)
        #expect(upload.headers["X-Amz-Security-Token"] == AWSWebIdentityTraceFixture.sessionToken)
        #expect(upload.headers[xaiTokenAuthHeader] == nil)
        #expect(upload.body?.starts(with: [0x1F, 0x8B]) == true)
        for request in requests {
            #expect(!request.headers.values.contains(AWSWebIdentityTraceFixture.xaiToken))
        }
        #expect(!result.output.contains(AWSWebIdentityTraceFixture.secretAccessKey))
        #expect(!result.errors.contains(AWSWebIdentityTraceFixture.jwt))
    }

    @Test(
        "the real trace command loads owner-private default, named, credentials-only and merged profile web identity",
        arguments: [
            "default-config", "named-config", "legacy-named-config", "credentials-only",
            "split-files", "crlf-config",
        ]
    )
    func executableProfileWebIdentityLaunchUsesThePinnedRegionalExchange(
        _ scenario: String
    ) async throws {
        let fixture = try AWSWebIdentityTraceFixture()
        defer { fixture.clean() }
        let sessionID = "profile-web-identity-\(scenario)"
        try await fixture.seed(sessionID)
        let profile = scenario == "named-config" || scenario == "legacy-named-config"
            || scenario == "split-files"
            ? "deployment"
            : "default"
        let section = profile == "default" ? "default" : "profile \(profile)"
        let configuration: String?
        let credentials: String?
        switch scenario {
        case "credentials-only":
            configuration = nil
            credentials = AWSWebIdentityTraceFixture.profileConfiguration(
                tokenPath: fixture.tokenFile.path
            )
        case "split-files":
            configuration = "[\(section)]\nrole_arn = \(AWSWebIdentityTraceFixture.roleARN)\n"
            credentials = "[\(profile)]\n"
                + "web_identity_token_file = \(fixture.tokenFile.path)\n"
                + "role_session_name = \(AWSWebIdentityTraceFixture.sessionName)\n"
        default:
            let contents = AWSWebIdentityTraceFixture.profileConfiguration(
                section: section,
                tokenPath: fixture.tokenFile.path
            )
            configuration = scenario == "crlf-config"
                ? contents.replacingOccurrences(of: "\n", with: "\r\n")
                : contents
            credentials = nil
        }
        var environment = try fixture.profileEnvironment(
            profile: profile,
            configuration: configuration,
            credentials: credentials
        )
        if scenario == "legacy-named-config" {
            environment.removeValue(forKey: "AWS_PROFILE")
            environment["AWS_DEFAULT_PROFILE"] = profile
        }
        let descriptor = try #require(fixture.cloudAuthorization(
            sessionID: sessionID,
            environment: environment
        ).webIdentity)
        if case .profile(let selected, let configurationPath, let credentialPath) = descriptor.source {
            #expect(selected == profile)
            #expect((configurationPath != nil) == (configuration != nil))
            #expect((credentialPath != nil) == (credentials != nil))
        } else {
            Issue.record("Profile credentials were silently downgraded to ambient identity")
        }

        let transport = MockHTTPTransport(responses: [
            AWSWebIdentityTraceFixture.stsResponse(),
            .init(metadata: HTTPResponseMetadata(statusCode: 200)),
        ])
        let result = await fixture.run(sessionID, environment: environment, transport: transport)

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(result.errors.isEmpty)
        #expect(transport.recordedRequests.map(\.method) == [.post, .put])
        let exchange = try #require(transport.recordedRequests.first)
        #expect(exchange.url.absoluteString == "https://sts.us-west-2.amazonaws.com/")
        #expect(exchange.headers["Authorization"] == nil)
        #expect(exchange.headers[xaiTokenAuthHeader] == nil)
        let body = String(decoding: try #require(exchange.body), as: UTF8.self)
        let fields = try #require(URLComponents(
            string: "https://unused.invalid/?" + body
        )?.queryItems)
        #expect(fields.map(\.name) == [
            "Action", "Version", "RoleArn", "RoleSessionName", "WebIdentityToken",
        ])
        #expect(fields.first { $0.name == "RoleArn" }?.value == AWSWebIdentityTraceFixture.roleARN)
        #expect(fields.first { $0.name == "WebIdentityToken" }?.value == AWSWebIdentityTraceFixture.jwt)
        let upload = try #require(transport.recordedRequests.last)
        #expect(upload.url.host == "trace-private-bucket.s3.us-west-2.amazonaws.com")
        #expect(upload.headers["Authorization"]?.contains(
            "Credential=\(AWSWebIdentityTraceFixture.accessKeyID)/"
        ) == true)
        #expect(upload.headers["X-Amz-Security-Token"] == AWSWebIdentityTraceFixture.sessionToken)
        #expect(upload.headers[xaiTokenAuthHeader] == nil)
    }

    @Test(
        "complete selected profile identity owns its role, subject and session independently of ambient identity variables",
        arguments: ["complete-hostile", "role-only", "token-only", "ambient-session"]
    )
    func selectedProfileWebIdentityNeverBorrowsAmbientAuthority(
        _ scenario: String
    ) async throws {
        let fixture = try AWSWebIdentityTraceFixture()
        defer { fixture.clean() }
        try await fixture.seed("isolated-profile-authority")
        let configuration = AWSWebIdentityTraceFixture.profileConfiguration(
            section: "profile deployment",
            tokenPath: fixture.tokenFile.path,
            sessionName: "overridden-config-session"
        )
        let credentials = "[deployment]\nrole_session_name = \(AWSWebIdentityTraceFixture.sessionName)\n"
        var ambient: [String: String] = [:]
        switch scenario {
        case "complete-hostile":
            ambient["AWS_ROLE_ARN"] = "arn:aws:iam::999999999999:role/foreign-authority"
            ambient["AWS_WEB_IDENTITY_TOKEN_FILE"] = "/PRIVATE_FOREIGN_SUBJECT"
            ambient["AWS_ROLE_SESSION_NAME"] = "PRIVATE_FOREIGN_SESSION"
        case "role-only":
            ambient["AWS_ROLE_ARN"] = "PRIVATE_MALFORMED_AMBIENT_ROLE"
        case "token-only":
            ambient["AWS_WEB_IDENTITY_TOKEN_FILE"] = "/PRIVATE_FOREIGN_SUBJECT"
        default:
            ambient["AWS_ROLE_SESSION_NAME"] = "PRIVATE/UNSAFE/AMBIENT"
        }
        let environment = try fixture.profileEnvironment(
            profile: "deployment",
            configuration: configuration,
            credentials: credentials,
            ambient: ambient
        )
        let transport = MockHTTPTransport(responses: [
            AWSWebIdentityTraceFixture.stsResponse(),
            .init(metadata: HTTPResponseMetadata(statusCode: 200)),
        ])

        let result = await fixture.run(
            "isolated-profile-authority",
            environment: environment,
            transport: transport
        )

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(transport.recordedRequests.map(\.method) == [.post, .put])
        let body = String(decoding: try #require(transport.recordedRequests.first?.body), as: UTF8.self)
        let fields = try #require(URLComponents(
            string: "https://unused.invalid/?" + body
        )?.queryItems)
        #expect(fields.first { $0.name == "RoleArn" }?.value == AWSWebIdentityTraceFixture.roleARN)
        #expect(fields.first { $0.name == "RoleSessionName" }?.value
            == AWSWebIdentityTraceFixture.sessionName)
        #expect(fields.first { $0.name == "WebIdentityToken" }?.value
            == AWSWebIdentityTraceFixture.jwt)
        #expect(!body.contains("PRIVATE_FOREIGN"))
        #expect(!result.errors.contains("PRIVATE_FOREIGN"))
    }

    @Test("profile federation uses its Rust profile-specific default role-session name")
    func profileDefaultSessionNameCannotInheritTheAmbientDefault() async throws {
        let fixture = try AWSWebIdentityTraceFixture()
        defer { fixture.clean() }
        try await fixture.seed("default-profile-role-session")
        let environment = try fixture.profileEnvironment(
            configuration: AWSWebIdentityTraceFixture.profileConfiguration(
                tokenPath: fixture.tokenFile.path,
                sessionName: nil
            ),
            ambient: ["AWS_ROLE_SESSION_NAME": "PRIVATE_AMBIENT_SESSION"]
        )
        let descriptor = try #require(fixture.cloudAuthorization(environment: environment).webIdentity)
        #expect(descriptor.sessionName.hasPrefix("web-identity-token-profile-"))
        #expect(descriptor.sessionName != "PRIVATE_AMBIENT_SESSION")
        let transport = MockHTTPTransport(responses: [
            AWSWebIdentityTraceFixture.stsResponse(
                body: AWSWebIdentityTraceFixture.responseXML(sessionName: descriptor.sessionName)
            ),
            .init(metadata: HTTPResponseMetadata(statusCode: 200)),
        ])

        let result = await fixture.run(
            "default-profile-role-session",
            environment: environment,
            transport: transport
        )

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(transport.recordedRequests.count == 2)
        let body = String(decoding: try #require(transport.recordedRequests.first?.body), as: UTF8.self)
        #expect(body.contains("RoleSessionName=\(descriptor.sessionName)"))
        #expect(!body.contains("PRIVATE_AMBIENT_SESSION"))
    }

    @Test("the explicit [profile default] configuration section supersedes legacy [default] values")
    func prefixedDefaultProfileTakesPriorityWithoutImportingIgnoredProviders() async throws {
        let fixture = try AWSWebIdentityTraceFixture()
        defer { fixture.clean() }
        try await fixture.seed("prefixed-default-profile")
        let configuration = "[default]\ncredential_process = PRIVATE_IGNORED_EXECUTION\n"
            + AWSWebIdentityTraceFixture.profileConfiguration(
                section: "profile default",
                tokenPath: fixture.tokenFile.path
            )
        let environment = try fixture.profileEnvironment(configuration: configuration)
        let transport = MockHTTPTransport(responses: [
            AWSWebIdentityTraceFixture.stsResponse(),
            .init(metadata: HTTPResponseMetadata(statusCode: 200)),
        ])

        let result = await fixture.run(
            "prefixed-default-profile",
            environment: environment,
            transport: transport
        )

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(transport.recordedRequests.map(\.method) == [.post, .put])
        #expect(!result.errors.contains("PRIVATE_IGNORED_EXECUTION"))
    }

    @Test(
        "private AWS configuration and web-identity token paths accept only absolute or safe home-relative files",
        arguments: ["absolute-config", "home-config", "home-token"]
    )
    func profileConfigurationAndTokenSupportOnlySafeResolvedPaths(
        _ scenario: String
    ) async throws {
        let fixture = try AWSWebIdentityTraceFixture()
        defer { fixture.clean() }
        try await fixture.seed("safe-profile-path")
        let subject = fixture.root.appendingPathComponent("private-home-subject.jwt")
        try SecureFile.write(at: subject, contents: AWSWebIdentityTraceFixture.jwt)
        let configuredTokenPath = scenario == "home-token" ? "~/private-home-subject.jwt" : subject.path
        let contents = AWSWebIdentityTraceFixture.profileConfiguration(tokenPath: configuredTokenPath)
        var environment = try fixture.profileEnvironment(configuration: nil)
        let configPath = fixture.root.appendingPathComponent("private-aws-profile.ini")
        try SecureFile.write(at: configPath, contents: contents)
        environment["AWS_CONFIG_FILE"] = scenario == "home-config"
            ? "~/private-aws-profile.ini"
            : configPath.path
        let transport = MockHTTPTransport(responses: [
            AWSWebIdentityTraceFixture.stsResponse(),
            .init(metadata: HTTPResponseMetadata(statusCode: 200)),
        ])

        let result = await fixture.run(
            "safe-profile-path",
            environment: environment,
            transport: transport
        )

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(transport.recordedRequests.map(\.method) == [.post, .put])
    }

    @Test(
        "relative and traversal-bearing AWS config or shared-profile paths fail before opening a credential endpoint",
        arguments: ["relative-config", "traversal-config", "relative-credentials", "traversal-credentials"]
    )
    func hostileConfiguredProfilePathsCannotReachSTS(_ scenario: String) async throws {
        let fixture = try AWSWebIdentityTraceFixture()
        defer { fixture.clean() }
        try await fixture.seed("hostile-configured-profile-path")
        var environment = try fixture.profileEnvironment(
            configuration: AWSWebIdentityTraceFixture.profileConfiguration(
                tokenPath: fixture.tokenFile.path
            )
        )
        switch scenario {
        case "relative-config":
            environment["AWS_CONFIG_FILE"] = "private-relative-config"
        case "traversal-config":
            environment["AWS_CONFIG_FILE"] = fixture.workspace.path + "/../private-config"
        case "relative-credentials":
            environment["AWS_SHARED_CREDENTIALS_FILE"] = "private-relative-credentials"
        default:
            environment["AWS_SHARED_CREDENTIALS_FILE"] =
                fixture.workspace.path + "/../private-credentials"
        }
        let transport = MockHTTPTransport()

        let result = await fixture.run(
            "hostile-configured-profile-path",
            environment: environment,
            transport: transport
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(transport.recordedRequests.isEmpty)
        #expect(!result.errors.contains(AWSWebIdentityTraceFixture.jwt))
    }

    @Test(
        "managed and environment static AWS credentials retain precedence over inaccessible or hostile profile providers",
        arguments: ["managed-inline", "managed-file", "environment"]
    )
    func earlierStaticCredentialsNeverReadOrMintProfileWebIdentity(
        _ provider: String
    ) async throws {
        let fixture = try AWSWebIdentityTraceFixture()
        defer { fixture.clean() }
        let sessionID = "profile-static-precedence-\(provider)"
        try await fixture.seed(sessionID)
        var environment = try fixture.profileEnvironment(
            configuration: AWSWebIdentityTraceFixture.profileConfiguration(
                tokenPath: "/PRIVATE_UNREADABLE_PROFILE_SUBJECT"
            )
        )
        let expectedKey: String
        switch provider {
        case "managed-inline":
            expectedKey = "PRIVATEINLINEKEY"
            environment["GROK_TRACE_UPLOAD_CREDENTIALS"] =
                "{\"aws_access_key_id\":\"\(expectedKey)\",\"aws_secret_access_key\":\"PRIVATE_MANAGED_SECRET\"}"
        case "managed-file":
            expectedKey = "PRIVATEMANAGEDFILEKEY"
            let path = fixture.workspace.appendingPathComponent("owner-private-managed.json")
            try SecureFile.write(
                at: path,
                contents: "{\"aws_access_key_id\":\"\(expectedKey)\",\"aws_secret_access_key\":\"PRIVATE_MANAGED_SECRET\"}"
            )
            environment["GROK_TRACE_UPLOAD_CREDENTIALS_FILE"] = path.path
        default:
            expectedKey = "PRIVATEENVIRONMENTKEY"
            environment["AWS_ACCESS_KEY_ID"] = expectedKey
            environment["AWS_SECRET_ACCESS_KEY"] = "PRIVATE_ENVIRONMENT_SECRET"
        }
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200)),
        ])

        let result = await fixture.run(sessionID, environment: environment, transport: transport)

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(transport.recordedRequests.count == 1)
        #expect(transport.recordedRequests.first?.method == .put)
        #expect(transport.recordedRequests.first?.headers["Authorization"]?.contains(
            "Credential=\(expectedKey)/"
        ) == true)
        #expect(!result.errors.contains("PRIVATE_UNREADABLE_PROFILE_SUBJECT"))
    }

    @Test("an owner-private configuration-only static profile precedes complete ambient web identity")
    func configurationOnlyStaticProfileBeatsLaterAmbientWebIdentity() async throws {
        let fixture = try AWSWebIdentityTraceFixture()
        defer { fixture.clean() }
        try await fixture.seed("configuration-only-static-profile")
        let configuration = "[default]\naws_access_key_id = CONFIGURATIONONLYKEY\n"
            + "aws_secret_access_key = PRIVATE_CONFIGURATION_ONLY_SECRET\n"
        let environment = try fixture.profileEnvironment(
            configuration: configuration,
            ambient: [
                "AWS_WEB_IDENTITY_TOKEN_FILE": fixture.tokenFile.path,
                "AWS_ROLE_ARN": AWSWebIdentityTraceFixture.roleARN,
            ]
        )
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200)),
        ])

        let result = await fixture.run(
            "configuration-only-static-profile",
            environment: environment,
            transport: transport
        )

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(transport.recordedRequests.count == 1)
        #expect(transport.recordedRequests.first?.method == .put)
        #expect(transport.recordedRequests.first?.headers["Authorization"]?.contains(
            "Credential=CONFIGURATIONONLYKEY/"
        ) == true)
        #expect(!result.output.contains("PRIVATE_CONFIGURATION_ONLY_SECRET"))
        #expect(!result.errors.contains("PRIVATE_CONFIGURATION_ONLY_SECRET"))
    }

    @Test("owner-private shared credentials override the same selected configuration keys before validation")
    func credentialsFileOverridesEarlierConfigurationIdentityValues() async throws {
        let fixture = try AWSWebIdentityTraceFixture()
        defer { fixture.clean() }
        try await fixture.seed("merged-profile-override")
        let configuration = "[profile deployment]\n"
            + "role_arn = PRIVATE_INVALID_EARLIER_ROLE\n"
            + "web_identity_token_file = /PRIVATE_INVALID_EARLIER_TOKEN\n"
            + "role_session_name = PRIVATE/INVALID/EARLIER/SESSION\n"
        let credentials = AWSWebIdentityTraceFixture.profileConfiguration(
            section: "deployment",
            tokenPath: fixture.tokenFile.path
        )
        let environment = try fixture.profileEnvironment(
            profile: "deployment",
            configuration: configuration,
            credentials: credentials
        )
        let transport = MockHTTPTransport(responses: [
            AWSWebIdentityTraceFixture.stsResponse(),
            .init(metadata: HTTPResponseMetadata(statusCode: 200)),
        ])

        let result = await fixture.run(
            "merged-profile-override",
            environment: environment,
            transport: transport
        )

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(transport.recordedRequests.map(\.method) == [.post, .put])
        let body = String(decoding: try #require(transport.recordedRequests.first?.body), as: UTF8.self)
        #expect(!body.contains("PRIVATE_INVALID_EARLIER"))
        #expect(!result.errors.contains("PRIVATE_INVALID_EARLIER"))
    }

    @Test(
        "partial, ambiguous, malformed, foreign and unsupported selected profile providers fail closed before networking",
        arguments: [
            "missing-role", "missing-token", "session-only", "mixed-static-config",
            "mixed-static-credentials", "credential-process", "credential-source", "source-profile",
            "sso-session", "sso-start-url", "external-id", "mfa-serial", "duration",
            "duplicate-role", "duplicate-token", "duplicate-section", "malformed-header",
            "wrong-named-section", "wrong-credentials-section", "relative-token", "token-traversal", "foreign-role",
            "invalid-account", "wrong-partition", "invalid-session", "empty-token",
            "oversized-config", "invalid-config-utf8", "oversized-credentials",
        ]
    )
    func hostileSelectedProfileProvidersNeverReachSTS(_ scenario: String) async throws {
        let fixture = try AWSWebIdentityTraceFixture()
        defer { fixture.clean() }
        try await fixture.seed("hostile-selected-profile")
        var configuration = AWSWebIdentityTraceFixture.profileConfiguration(
            tokenPath: fixture.tokenFile.path
        )
        var credentials: String?
        var profile = "default"

        switch scenario {
        case "missing-role":
            configuration = configuration.replacingOccurrences(
                of: "role_arn = \(AWSWebIdentityTraceFixture.roleARN)\n",
                with: ""
            )
        case "missing-token":
            configuration = configuration.replacingOccurrences(
                of: "web_identity_token_file = \(fixture.tokenFile.path)\n",
                with: ""
            )
        case "session-only":
            configuration = "[default]\nrole_session_name = private-incomplete-session\n"
        case "mixed-static-config":
            configuration += "aws_access_key_id = PRIVATE_STATIC_KEY\n"
                + "aws_secret_access_key = PRIVATE_STATIC_SECRET\n"
        case "mixed-static-credentials":
            credentials = "[default]\naws_access_key_id = PRIVATE_STATIC_KEY\n"
                + "aws_secret_access_key = PRIVATE_STATIC_SECRET\n"
        case "credential-process": configuration += "credential_process = PRIVATE_EXECUTE_ME\n"
        case "credential-source": configuration += "credential_source = PRIVATE_METADATA_SOURCE\n"
        case "source-profile": configuration += "source_profile = PRIVATE_CHAINED_PROFILE\n"
        case "sso-session": configuration += "sso_session = PRIVATE_SSO_SESSION\n"
        case "sso-start-url": configuration += "sso_start_url = https://PRIVATE_SSO.invalid/\n"
        case "external-id": configuration += "external_id = PRIVATE_EXTERNAL_ID\n"
        case "mfa-serial": configuration += "mfa_serial = PRIVATE_MFA_SERIAL\n"
        case "duration": configuration += "duration_seconds = 3600\n"
        case "duplicate-role": configuration += "role_arn = \(AWSWebIdentityTraceFixture.roleARN)\n"
        case "duplicate-token": configuration += "web_identity_token_file = \(fixture.tokenFile.path)\n"
        case "duplicate-section":
            configuration += "[default]\nrole_session_name = private-duplicate-session\n"
        case "malformed-header": configuration = "[default\n" + configuration
        case "wrong-named-section":
            profile = "deployment"
            configuration = AWSWebIdentityTraceFixture.profileConfiguration(
                section: "deployment",
                tokenPath: fixture.tokenFile.path
            )
        case "wrong-credentials-section":
            profile = "deployment"
            configuration = "[profile other]\nregion = us-west-2\n"
            credentials = AWSWebIdentityTraceFixture.profileConfiguration(
                section: "profile deployment",
                tokenPath: fixture.tokenFile.path
            )
        case "relative-token":
            configuration = AWSWebIdentityTraceFixture.profileConfiguration(
                tokenPath: "private-relative.jwt"
            )
        case "token-traversal":
            configuration = AWSWebIdentityTraceFixture.profileConfiguration(
                tokenPath: fixture.workspace.path + "/../private-subject.jwt"
            )
        case "foreign-role":
            configuration = AWSWebIdentityTraceFixture.profileConfiguration(
                tokenPath: fixture.tokenFile.path,
                roleARN: "arn:foreign:iam::123456789012:role/private/trace-writer"
            )
        case "invalid-account":
            configuration = AWSWebIdentityTraceFixture.profileConfiguration(
                tokenPath: fixture.tokenFile.path,
                roleARN: "arn:aws:iam::12A456789012:role/private/trace-writer"
            )
        case "wrong-partition":
            configuration = AWSWebIdentityTraceFixture.profileConfiguration(
                tokenPath: fixture.tokenFile.path,
                roleARN: "arn:aws-cn:iam::123456789012:role/private/trace-writer"
            )
        case "invalid-session":
            configuration = AWSWebIdentityTraceFixture.profileConfiguration(
                tokenPath: fixture.tokenFile.path,
                sessionName: "PRIVATE/INVALID/SESSION"
            )
        case "empty-token":
            configuration = configuration.replacingOccurrences(
                of: "web_identity_token_file = \(fixture.tokenFile.path)",
                with: "web_identity_token_file = "
            )
        case "oversized-config": configuration += String(repeating: "#", count: 65_537)
        case "oversized-credentials":
            credentials = "[other]\n#" + String(repeating: "x", count: 65_537)
        default: break
        }

        let environment = try fixture.profileEnvironment(
            profile: profile,
            configuration: configuration,
            credentials: credentials
        )
        if scenario == "invalid-config-utf8" {
            try SecureFile.write(
                at: fixture.root
                    .appendingPathComponent(".aws", isDirectory: true)
                    .appendingPathComponent("config"),
                contents: Data([0xFF, 0xFE])
            )
        }
        let transport = MockHTTPTransport()
        let result = await fixture.run(
            "hostile-selected-profile",
            environment: environment,
            transport: transport
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(transport.recordedRequests.isEmpty)
        #expect(!result.errors.contains("PRIVATE_EXECUTE_ME"))
        #expect(!result.errors.contains("PRIVATE_STATIC_SECRET"))
        #expect(!result.errors.contains(AWSWebIdentityTraceFixture.jwt))
    }

    #if !os(Windows)
    @Test(
        "profile configuration, credential and subject files must all remain owner-private regular no-follow files",
        arguments: [
            "config-symlink", "config-directory", "config-group-readable",
            "credentials-symlink", "credentials-directory", "credentials-group-readable",
            "token-symlink", "token-group-readable",
        ]
    )
    func profileCredentialFilesRejectLinksDirectoriesAndBroadPermissions(
        _ scenario: String
    ) async throws {
        let fixture = try AWSWebIdentityTraceFixture()
        defer { fixture.clean() }
        try await fixture.seed("owner-private-profile-files")
        let awsDirectory = fixture.root.appendingPathComponent(".aws", isDirectory: true)
        let configPath = awsDirectory.appendingPathComponent("config")
        let credentialPath = awsDirectory.appendingPathComponent("credentials")
        let credentials: String? = scenario.hasPrefix("credentials")
            ? "[other]\naws_access_key_id = OTHERKEY\naws_secret_access_key = PRIVATE_OTHER_SECRET\n"
            : nil
        var configuration = AWSWebIdentityTraceFixture.profileConfiguration(
            tokenPath: fixture.tokenFile.path
        )
        if scenario == "token-symlink" {
            let link = fixture.workspace.appendingPathComponent("linked-profile-subject.jwt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.tokenFile)
            configuration = AWSWebIdentityTraceFixture.profileConfiguration(tokenPath: link.path)
        }
        let environment = try fixture.profileEnvironment(
            configuration: configuration,
            credentials: credentials
        )

        switch scenario {
        case "config-symlink", "credentials-symlink":
            let path = scenario == "config-symlink" ? configPath : credentialPath
            let original = fixture.workspace.appendingPathComponent("private-link-target")
            try SecureFile.write(at: original, contents: configuration)
            try FileManager.default.removeItem(at: path)
            try FileManager.default.createSymbolicLink(at: path, withDestinationURL: original)
        case "config-directory", "credentials-directory":
            let path = scenario == "config-directory" ? configPath : credentialPath
            try FileManager.default.removeItem(at: path)
            try OpenGrokConfig.createDirAllOwnerOnly(path)
        case "config-group-readable":
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: configPath.path)
        case "credentials-group-readable":
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o640],
                ofItemAtPath: credentialPath.path
            )
        case "token-group-readable":
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o640],
                ofItemAtPath: fixture.tokenFile.path
            )
        default: break
        }
        let transport = MockHTTPTransport()

        let result = await fixture.run(
            "owner-private-profile-files",
            environment: environment,
            transport: transport
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(transport.recordedRequests.isEmpty)
        #expect(!result.errors.contains("PRIVATE_OTHER_SECRET"))
    }
    #endif

    @Test(
        "profile federation preserves provider, privacy and metadata-network gates before attempting STS",
        arguments: ["opted-out", "foreign-provider", "container", "metadata"]
    )
    func profileWebIdentityCannotBypassProviderPrivacyOrMetadataGates(
        _ scenario: String
    ) async throws {
        let fixture = try AWSWebIdentityTraceFixture()
        defer { fixture.clean() }
        try await fixture.seed(
            "closed-profile-web-boundary",
            provider: scenario == "foreign-provider" ? .codex : .xai
        )
        var environment = try fixture.profileEnvironment(
            configuration: AWSWebIdentityTraceFixture.profileConfiguration(
                tokenPath: fixture.tokenFile.path
            )
        )
        switch scenario {
        case "opted-out":
            let account = GrokAuth(
                key: AWSWebIdentityTraceFixture.xaiToken,
                authMode: .oidc,
                userID: "aws-web-identity-user",
                codingDataRetentionOptOut: true,
                oidcIssuer: "https://auth.x.ai"
            )
            environment["OPENGROK_AUTH"] = try fixture.environment(auth: account)["OPENGROK_AUTH"]
        case "container":
            environment["AWS_CONTAINER_CREDENTIALS_FULL_URI"] =
                "http://169.254.170.2/PRIVATE_CONTAINER_METADATA"
        case "metadata":
            environment["AWS_EC2_METADATA_SERVICE_ENDPOINT"] =
                "http://169.254.169.254/PRIVATE_INSTANCE_METADATA"
        default: break
        }
        let transport = MockHTTPTransport()

        let result = await fixture.run(
            "closed-profile-web-boundary",
            environment: environment,
            transport: transport
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(transport.recordedRequests.isEmpty)
        #expect(!result.errors.contains("PRIVATE_CONTAINER_METADATA"))
        #expect(!result.errors.contains("PRIVATE_INSTANCE_METADATA"))
    }

    @Test("profile federation exchanges once and signs the complete production multipart request sequence")
    func productionMultipartUploadUsesOneProfileWebIdentityExchange() async throws {
        let fixture = try AWSWebIdentityTraceFixture()
        defer { fixture.clean() }
        let sessionID = "profile-web-identity-multipart"
        try await fixture.seed(sessionID)
        let environment = try fixture.profileEnvironment(
            profile: "deployment",
            configuration: AWSWebIdentityTraceFixture.profileConfiguration(
                section: "profile deployment",
                tokenPath: fixture.tokenFile.path
            )
        )
        let document = LiveManagedSetupComposition.trustedConfigDocument(environment: environment)
        let initial = try await LiveTraceUpload.authorize(
            sessionID: sessionID,
            home: fixture.home,
            document: document,
            environment: environment,
            uploadEnabled: true
        )
        let transport = MockHTTPTransport(responses: [
            AWSWebIdentityTraceFixture.stsResponse(),
            AWSWebIdentityTraceFixture.initiation(sessionID: sessionID),
            .init(metadata: HTTPResponseMetadata(statusCode: 200, headers: ["ETag": "\"private-profile-one\""])),
            .init(metadata: HTTPResponseMetadata(statusCode: 200, headers: ["ETag": "\"private-profile-two\""])),
            AWSWebIdentityTraceFixture.completion(sessionID: sessionID),
        ])
        let services = LiveTraceUploadServices(makeTransport: { transport }, sleep: { _ in })

        let result = try await LiveTraceUpload.upload(
            sessionID: sessionID,
            archive: Data(count: LiveCloudTraceUpload.maximumArchiveBytes + 1),
            initialAuthorization: initial,
            home: fixture.home,
            document: document,
            environment: environment,
            uploadEnabled: true,
            services: services,
            retryNotice: nil
        )

        #expect(result == "s3://trace-private-bucket/\(sessionID)/trace_export.tar.gz")
        #expect(transport.recordedRequests.map(\.method) == [.post, .post, .put, .put, .post])
        #expect(transport.recordedRequests.first?.url.host == "sts.us-west-2.amazonaws.com")
        #expect(transport.recordedRequests.first?.headers["Authorization"] == nil)
        for request in transport.recordedRequests.dropFirst() {
            #expect(request.url.host == "trace-private-bucket.s3.us-west-2.amazonaws.com")
            #expect(request.headers["Authorization"]?.contains(
                "Credential=\(AWSWebIdentityTraceFixture.accessKeyID)/"
            ) == true)
            #expect(request.headers["X-Amz-Security-Token"] == AWSWebIdentityTraceFixture.sessionToken)
            #expect(request.headers[xaiTokenAuthHeader] == nil)
        }
    }

    @Test(
        "profile configuration, shared credential, subject-token and provider-source rotation after STS blocks all S3 dispatch",
        arguments: ["configuration", "credentials", "token", "ambient-downgrade"]
    )
    func profileIdentityRotationDuringSTSCannotReachStorage(
        _ scenario: String
    ) async throws {
        let fixture = try AWSWebIdentityTraceFixture()
        defer { fixture.clean() }
        try await fixture.seed("rotating-profile-provider")
        let awsDirectory = fixture.root.appendingPathComponent(".aws", isDirectory: true)
        let configPath = awsDirectory.appendingPathComponent("config")
        let credentialPath = awsDirectory.appendingPathComponent("credentials")
        let credentials: String? = scenario == "credentials"
            ? "[default]\nrole_session_name = \(AWSWebIdentityTraceFixture.sessionName)\n"
            : nil
        let ambient: [String: String]
        if scenario == "ambient-downgrade" {
            ambient = [
                "AWS_WEB_IDENTITY_TOKEN_FILE": fixture.tokenFile.path,
                "AWS_ROLE_ARN": AWSWebIdentityTraceFixture.roleARN,
                "AWS_ROLE_SESSION_NAME": AWSWebIdentityTraceFixture.sessionName,
            ]
        } else {
            ambient = [:]
        }
        let environment = try fixture.profileEnvironment(
            configuration: AWSWebIdentityTraceFixture.profileConfiguration(
                tokenPath: fixture.tokenFile.path
            ),
            credentials: credentials,
            ambient: ambient
        )
        let tokenFile = fixture.tokenFile
        let scripted = MockHTTPTransport(responses: [AWSWebIdentityTraceFixture.stsResponse()])
        let transport = AWSWebIdentityMutationTransport(wrapped: scripted, invocation: 1) {
            switch scenario {
            case "configuration":
                try SecureFile.write(
                    at: configPath,
                    contents: AWSWebIdentityTraceFixture.profileConfiguration(
                        tokenPath: tokenFile.path,
                        sessionName: "private-rotated-profile-session"
                    )
                )
            case "credentials":
                try SecureFile.write(
                    at: credentialPath,
                    contents: "[default]\nrole_session_name = private-rotated-profile-session\n"
                )
            case "token":
                try SecureFile.write(at: tokenFile, contents: AWSWebIdentityTraceFixture.rotatedJWT)
            default:
                try SecureFile.write(at: configPath, contents: "[other]\nregion = us-west-2\n")
            }
        }

        let result = await fixture.run(
            "rotating-profile-provider",
            environment: environment,
            transport: transport
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(scripted.recordedRequests.count == 1)
        #expect(scripted.recordedRequests.first?.url.host == "sts.us-west-2.amazonaws.com")
        #expect(!result.errors.contains(AWSWebIdentityTraceFixture.jwt))
        #expect(!result.errors.contains(AWSWebIdentityTraceFixture.rotatedJWT))
    }

    @Test("changing selected private profile credentials after multipart initiation suppresses parts and aborts")
    func multipartProfileRotationPreventsEverySubsequentStorageRequest() async throws {
        let fixture = try AWSWebIdentityTraceFixture()
        defer { fixture.clean() }
        let sessionID = "rotating-profile-multipart"
        try await fixture.seed(sessionID)
        let environment = try fixture.profileEnvironment(
            configuration: AWSWebIdentityTraceFixture.profileConfiguration(
                tokenPath: fixture.tokenFile.path
            )
        )
        let document = LiveManagedSetupComposition.trustedConfigDocument(environment: environment)
        let initial = try await LiveTraceUpload.authorize(
            sessionID: sessionID,
            home: fixture.home,
            document: document,
            environment: environment,
            uploadEnabled: true
        )
        let scripted = MockHTTPTransport(responses: [
            AWSWebIdentityTraceFixture.stsResponse(),
            AWSWebIdentityTraceFixture.initiation(sessionID: sessionID),
        ])
        let configurationPath = fixture.root
            .appendingPathComponent(".aws", isDirectory: true)
            .appendingPathComponent("config")
        let tokenPath = fixture.tokenFile.path
        let transport = AWSWebIdentityMutationTransport(wrapped: scripted, invocation: 2) {
            try SecureFile.write(
                at: configurationPath,
                contents: AWSWebIdentityTraceFixture.profileConfiguration(
                    tokenPath: tokenPath,
                    sessionName: "private-multipart-rotated-session"
                )
            )
        }
        let services = LiveTraceUploadServices(makeTransport: { transport }, sleep: { _ in })

        await #expect(throws: (any Error).self) {
            try await LiveTraceUpload.upload(
                sessionID: sessionID,
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
        #expect(scripted.recordedRequests.map(\.method) == [.post, .post])
        #expect(scripted.recordedRequests.first?.url.host == "sts.us-west-2.amazonaws.com")
        #expect(scripted.recordedRequests.last?.url.query == "uploads=")
    }

    @Test("an unminted web-identity authorization cannot sign or dispatch an S3 request")
    func synchronousAuthorizationContainsNoPrematureStaticCredentials() throws {
        let fixture = try AWSWebIdentityTraceFixture()
        defer { fixture.clean() }
        let authorization = try fixture.cloudAuthorization()

        #expect(authorization.webIdentity != nil)
        #expect(authorization.accessKeyID == nil)
        #expect(authorization.secretAccessKey == nil)
        #expect(authorization.sessionToken == nil)
        #expect(throws: LiveCloudTraceUpload.Failure.invalidCredentials) {
            try LiveCloudTraceUpload.request(
                authorization: authorization,
                archive: Data("PRIVATE_UNAUTHORIZED_ARCHIVE".utf8)
            )
        }
    }

    @Test("managed, environment and valid private shared-profile static credentials all precede complete web identity", arguments: ["managed-inline", "managed-file", "environment", "private-profile"])
    func earlierStaticProvidersSuppressAllWebIdentityNetworkRequests(_ provider: String) async throws {
        let fixture = try AWSWebIdentityTraceFixture()
        defer { fixture.clean() }
        let sessionID = "static-precedence-\(provider)"
        try await fixture.seed(sessionID)
        var environment = try fixture.environment()
        let expectedKey: String

        switch provider {
        case "managed-inline":
            expectedKey = "MANAGEDINLINEKEY"
            environment["GROK_TRACE_UPLOAD_CREDENTIALS"] = "{\"aws_access_key_id\":\"\(expectedKey)\",\"aws_secret_access_key\":\"PRIVATE_MANAGED_SECRET\"}"
        case "managed-file":
            expectedKey = "MANAGEDFILEKEY"
            let path = fixture.workspace.appendingPathComponent("private-managed.json")
            try SecureFile.write(at: path, contents: "{\"aws_access_key_id\":\"\(expectedKey)\",\"aws_secret_access_key\":\"PRIVATE_MANAGED_SECRET\"}")
            environment["GROK_TRACE_UPLOAD_CREDENTIALS_FILE"] = path.path
        case "environment":
            expectedKey = "ENVIRONMENTSTATICKEY"
            environment["AWS_ACCESS_KEY_ID"] = expectedKey
            environment["AWS_SECRET_ACCESS_KEY"] = "PRIVATE_ENVIRONMENT_SECRET"
        default:
            expectedKey = "PRIVATEPROFILEKEY"
            let directory = fixture.root.appendingPathComponent(".aws", isDirectory: true)
            #if os(Windows)
            try OpenGrokConfig.createDirAllOwnerOnly(directory, stateRoot: fixture.root)
            #else
            try OpenGrokConfig.createDirAllOwnerOnly(directory)
            #endif
            try SecureFile.write(
                at: directory.appendingPathComponent("credentials"),
                contents: "[default]\naws_access_key_id = \(expectedKey)\naws_secret_access_key = PRIVATE_PROFILE_SECRET\n"
            )
        }

        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200)),
        ])
        let result = await fixture.run(sessionID, environment: environment, transport: transport)

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(transport.recordedRequests.count == 1)
        let upload = try #require(transport.recordedRequests.first)
        #expect(upload.method == .put)
        #expect(upload.headers["Authorization"]?.contains("Credential=\(expectedKey)/") == true)
        #expect(upload.headers["X-Amz-Security-Token"] == nil)
    }

    @Test(
        "only an absent implicit default profile falls through from a private shared file to AWS web identity",
        arguments: [
            "implicit-missing", "explicit-named", "explicit-default", "partial-default",
            "malformed-profile",
        ]
    )
    func missingImplicitDefaultProfileCanContinueToWebIdentity(_ scenario: String) async throws {
        let fixture = try AWSWebIdentityTraceFixture()
        defer { fixture.clean() }
        let sessionID = "missing-default-\(scenario)"
        try await fixture.seed(sessionID)
        var environment = try fixture.environment()
        let directory = fixture.root.appendingPathComponent(".aws", isDirectory: true)
        #if os(Windows)
        try OpenGrokConfig.createDirAllOwnerOnly(directory, stateRoot: fixture.root)
        #else
        try OpenGrokConfig.createDirAllOwnerOnly(directory)
        #endif

        let contents: String
        switch scenario {
        case "explicit-named":
            environment["AWS_PROFILE"] = "requested"
            contents = "[other]\naws_access_key_id = OTHERKEY\naws_secret_access_key = PRIVATE_OTHER_SECRET\n"
        case "explicit-default":
            environment["AWS_DEFAULT_PROFILE"] = "default"
            contents = "[other]\naws_access_key_id = OTHERKEY\naws_secret_access_key = PRIVATE_OTHER_SECRET\n"
        case "partial-default":
            contents = "[default]\naws_access_key_id = PARTIALDEFAULTKEY\n"
        case "malformed-profile":
            contents = "[other\naws_access_key_id = OTHERKEY\n"
        default:
            contents = "[other]\naws_access_key_id = OTHERKEY\naws_secret_access_key = PRIVATE_OTHER_SECRET\n"
        }
        try SecureFile.write(at: directory.appendingPathComponent("credentials"), contents: contents)

        let transport = MockHTTPTransport(responses: [
            AWSWebIdentityTraceFixture.stsResponse(),
            .init(metadata: HTTPResponseMetadata(statusCode: 200)),
        ])
        let result = await fixture.run(sessionID, environment: environment, transport: transport)

        if scenario == "implicit-missing" {
            #expect(result.status == CLIRunner.ExitCode.success.rawValue)
            #expect(transport.recordedRequests.map(\.method) == [.post, .put])
            #expect(transport.recordedRequests.first?.url.host == "sts.us-west-2.amazonaws.com")
            #expect(transport.recordedRequests.first?.headers["Authorization"] == nil)
            #expect(transport.recordedRequests.last?.headers["Authorization"]?.contains(
                "Credential=\(AWSWebIdentityTraceFixture.accessKeyID)/"
            ) == true)
        } else {
            #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
            #expect(transport.recordedRequests.isEmpty)
        }
        #expect(!result.errors.contains("PRIVATE_OTHER_SECRET"))
    }

    @Test("the production 8 MiB multipart path exchanges once and signs every initiate, part and completion request")
    func productionMultipartUploadReusesOneWebIdentityExchange() async throws {
        let fixture = try AWSWebIdentityTraceFixture()
        defer { fixture.clean() }
        let sessionID = "web-identity-multipart"
        try await fixture.seed(sessionID)
        let environment = try fixture.environment()
        let document = LiveManagedSetupComposition.trustedConfigDocument(environment: environment)
        let initial = try await LiveTraceUpload.authorize(
            sessionID: sessionID,
            home: fixture.home,
            document: document,
            environment: environment,
            uploadEnabled: true
        )
        let transport = MockHTTPTransport(responses: [
            AWSWebIdentityTraceFixture.stsResponse(),
            AWSWebIdentityTraceFixture.initiation(sessionID: sessionID),
            .init(metadata: HTTPResponseMetadata(statusCode: 200, headers: ["ETag": "\"private-part-one\""])),
            .init(metadata: HTTPResponseMetadata(statusCode: 200, headers: ["ETag": "\"private-part-two\""])),
            AWSWebIdentityTraceFixture.completion(sessionID: sessionID),
        ])
        let services = LiveTraceUploadServices(makeTransport: { transport }, sleep: { _ in })

        let result = try await LiveTraceUpload.upload(
            sessionID: sessionID,
            archive: Data(count: LiveCloudTraceUpload.maximumArchiveBytes + 1),
            initialAuthorization: initial,
            home: fixture.home,
            document: document,
            environment: environment,
            uploadEnabled: true,
            services: services,
            retryNotice: nil
        )

        #expect(result == "s3://trace-private-bucket/\(sessionID)/trace_export.tar.gz")
        let requests = transport.recordedRequests
        #expect(requests.map(\.method) == [.post, .post, .put, .put, .post])
        #expect(requests.first?.url.host == "sts.us-west-2.amazonaws.com")
        #expect(requests[1].url.query == "uploads=")
        #expect(requests[2].url.query?.contains("partNumber=1") == true)
        #expect(requests[3].url.query?.contains("partNumber=2") == true)
        for request in requests.dropFirst() {
            #expect(request.url.host == "trace-private-bucket.s3.us-west-2.amazonaws.com")
            #expect(request.headers["Authorization"]?.contains(
                "Credential=\(AWSWebIdentityTraceFixture.accessKeyID)/"
            ) == true)
            #expect(request.headers["X-Amz-Security-Token"] == AWSWebIdentityTraceFixture.sessionToken)
            #expect(request.headers[xaiTokenAuthHeader] == nil)
        }
        #expect(requests.first?.headers["Authorization"] == nil)
    }

    @Test(
        "missing, partial, malformed or unsafe web-identity configuration fails closed before any network request",
        arguments: [
            "missing-role", "missing-token-file", "empty-role", "empty-token-file",
            "foreign-partition", "invalid-account", "non-role-resource", "role-traversal",
            "wrong-partition-region", "invalid-session", "relative-token-path", "token-traversal",
            "invalid-token", "token-newline", "token-too-large", "file-too-large", "invalid-utf8",
        ]
    )
    func hostileWebIdentityConfigurationCannotReachSTS(_ scenario: String) async throws {
        let fixture = try AWSWebIdentityTraceFixture()
        defer { fixture.clean() }
        let sessionID = "hostile-web-identity"
        try await fixture.seed(sessionID)
        var environment = try fixture.environment()

        switch scenario {
        case "missing-role": environment.removeValue(forKey: "AWS_ROLE_ARN")
        case "missing-token-file": environment.removeValue(forKey: "AWS_WEB_IDENTITY_TOKEN_FILE")
        case "empty-role": environment["AWS_ROLE_ARN"] = ""
        case "empty-token-file": environment["AWS_WEB_IDENTITY_TOKEN_FILE"] = ""
        case "foreign-partition": environment["AWS_ROLE_ARN"] = "arn:foreign:iam::123456789012:role/trace"
        case "invalid-account": environment["AWS_ROLE_ARN"] = "arn:aws:iam::12A456789012:role/trace"
        case "non-role-resource": environment["AWS_ROLE_ARN"] = "arn:aws:iam::123456789012:user/trace"
        case "role-traversal": environment["AWS_ROLE_ARN"] = "arn:aws:iam::123456789012:role/../trace"
        case "wrong-partition-region": environment["AWS_REGION"] = "cn-north-1"
        case "invalid-session": environment["AWS_ROLE_SESSION_NAME"] = "private/injected-session"
        case "relative-token-path": environment["AWS_WEB_IDENTITY_TOKEN_FILE"] = "private-subject.jwt"
        case "token-traversal": environment["AWS_WEB_IDENTITY_TOKEN_FILE"] = fixture.workspace.path + "/../private-subject.jwt"
        case "invalid-token": try SecureFile.write(at: fixture.tokenFile, contents: "PRIVATE_ONE_SEGMENT")
        case "token-newline": try SecureFile.write(at: fixture.tokenFile, contents: AWSWebIdentityTraceFixture.jwt + "\n")
        case "token-too-large": try SecureFile.write(at: fixture.tokenFile, contents: String(repeating: "a", count: 16_385) + ".b.c")
        case "file-too-large": try SecureFile.write(at: fixture.tokenFile, contents: Data(repeating: 0x61, count: 65_537))
        default: try SecureFile.write(at: fixture.tokenFile, contents: Data([0xFF, 0xFE]))
        }

        let transport = MockHTTPTransport()
        let result = await fixture.run(sessionID, environment: environment, transport: transport)

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.output.isEmpty)
        #expect(transport.recordedRequests.isEmpty)
        #expect(!result.errors.contains(AWSWebIdentityTraceFixture.jwt))
        #expect(!result.errors.contains(AWSWebIdentityTraceFixture.xaiToken))
    }

    #if !os(Windows)
    @Test("symlinked, directory-backed and nonprivate subject-token files never reach AWS STS", arguments: ["symlink", "directory", "group-readable"])
    func subjectTokenRequiresAnOwnerPrivateNoFollowRegularFile(_ scenario: String) async throws {
        let fixture = try AWSWebIdentityTraceFixture()
        defer { fixture.clean() }
        try await fixture.seed("private-token-boundary")
        var environment = try fixture.environment()

        switch scenario {
        case "symlink":
            let link = fixture.workspace.appendingPathComponent("hostile-link.jwt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.tokenFile)
            environment["AWS_WEB_IDENTITY_TOKEN_FILE"] = link.path
        case "directory":
            environment["AWS_WEB_IDENTITY_TOKEN_FILE"] = fixture.workspace.path
        default:
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o640],
                ofItemAtPath: fixture.tokenFile.path
            )
        }

        let transport = MockHTTPTransport()
        let result = await fixture.run(
            "private-token-boundary",
            environment: environment,
            transport: transport
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(transport.recordedRequests.isEmpty)
    }
    #endif

    @Test(
        "malformed, duplicated, foreign-account, expired and oversized STS XML never mints or dispatches S3 credentials",
        arguments: [
            "wrong-root", "doctype", "duplicate-access-key", "missing-session-token",
            "foreign-account", "foreign-session", "expired", "near-expiry", "excessive-lifetime",
            "invalid-key", "unsafe-secret", "oversized-response", "invalid-utf8",
        ]
    )
    func unsafeSTSResponsesStopBeforeS3(_ scenario: String) async throws {
        let fixture = try AWSWebIdentityTraceFixture()
        defer { fixture.clean() }
        let sessionID = "unsafe-sts-response"
        try await fixture.seed(sessionID)
        var response = AWSWebIdentityTraceFixture.responseXML()

        switch scenario {
        case "wrong-root":
            response = response.replacingOccurrences(
                of: "AssumeRoleWithWebIdentityResponse",
                with: "AssumeRoleResponse"
            )
        case "doctype": response = "<!DOCTYPE credentials>" + response
        case "duplicate-access-key":
            response = response.replacingOccurrences(
                of: "</AccessKeyId>",
                with: "</AccessKeyId><AccessKeyId>ASIAINJECTED</AccessKeyId>"
            )
        case "missing-session-token":
            response = response.replacingOccurrences(
                of: "<SessionToken>\(AWSWebIdentityTraceFixture.sessionToken)</SessionToken>",
                with: ""
            )
        case "foreign-account": response = AWSWebIdentityTraceFixture.responseXML(accountID: "999999999999")
        case "foreign-session": response = AWSWebIdentityTraceFixture.responseXML(sessionName: "foreign-session")
        case "expired": response = AWSWebIdentityTraceFixture.responseXML(expiration: Date().addingTimeInterval(-1))
        case "near-expiry": response = AWSWebIdentityTraceFixture.responseXML(expiration: Date().addingTimeInterval(10))
        case "excessive-lifetime": response = AWSWebIdentityTraceFixture.responseXML(expiration: Date().addingTimeInterval(48 * 60 * 60))
        case "invalid-key": response = AWSWebIdentityTraceFixture.responseXML(accessKeyID: "AKIASTATICKEY")
        case "unsafe-secret": response = AWSWebIdentityTraceFixture.responseXML(secretAccessKey: "PRIVATE<INJECTED")
        case "oversized-response": response += String(repeating: " ", count: 65_537)
        default: break
        }

        let scripted: MockHTTPTransport.ScriptedResponse
        if scenario == "invalid-utf8" {
            scripted = .init(metadata: HTTPResponseMetadata(statusCode: 200), body: Data([0xFF]))
        } else {
            scripted = AWSWebIdentityTraceFixture.stsResponse(body: response)
        }
        let transport = MockHTTPTransport(responses: [scripted])
        let result = await fixture.run(
            sessionID,
            environment: try fixture.environment(),
            transport: transport
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(transport.recordedRequests.count == 1)
        #expect(transport.recordedRequests.first?.url.host == "sts.us-west-2.amazonaws.com")
        #expect(!result.errors.contains(AWSWebIdentityTraceFixture.jwt))
        #expect(!result.errors.contains(AWSWebIdentityTraceFixture.secretAccessKey))
        #expect(!result.errors.contains(AWSWebIdentityTraceFixture.sessionToken))
    }

    @Test("STS HTTP rejection and foreign redirect metadata never dispatch temporary credentials to S3", arguments: ["rejected", "redirect", "foreign-response"])
    func rejectedAndRedirectedSTSCredentialsRemainIsolated(_ scenario: String) async throws {
        let fixture = try AWSWebIdentityTraceFixture()
        defer { fixture.clean() }
        try await fixture.seed("redirected-sts")
        let response: MockHTTPTransport.ScriptedResponse
        switch scenario {
        case "rejected":
            response = AWSWebIdentityTraceFixture.stsResponse(status: 403, body: "PRIVATE_SERVER_DETAILS")
        case "redirect":
            response = AWSWebIdentityTraceFixture.stsResponse(status: 302, body: "PRIVATE_REDIRECT")
        default:
            response = AWSWebIdentityTraceFixture.stsResponse(url: URL(string: "https://foreign.invalid/PRIVATE_REDIRECT"))
        }
        let transport = MockHTTPTransport(responses: [response])
        let result = await fixture.run(
            "redirected-sts",
            environment: try fixture.environment(),
            transport: transport
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(transport.recordedRequests.count == 1)
        #expect(!result.errors.contains("PRIVATE_SERVER_DETAILS"))
        #expect(!result.errors.contains("PRIVATE_REDIRECT"))
    }

    @Test("only an explicitly supplied exact ported literal loopback test endpoint can replace regional STS", arguments: [
        "https://foreign.invalid/", "http://localhost:24191/", "http://127.0.0.1/",
        "http://127.0.0.1:24191/token", "http://127.0.0.1:24191/?PRIVATE_QUERY",
        "http://private@127.0.0.1:24191/", "file:///private-token",
    ])
    func hostileTestEndpointOverridesFailWithoutNetwork(_ value: String) async throws {
        let fixture = try AWSWebIdentityTraceFixture()
        defer { fixture.clean() }
        let descriptor = try #require(fixture.cloudAuthorization().webIdentity)
        let endpoint = try #require(URL(string: value))
        let transport = MockHTTPTransport()

        await #expect(throws: LiveCloudTraceUpload.Failure.invalidEndpoint) {
            try await LiveAWSWebIdentityCredentials.exchange(
                descriptor: descriptor,
                region: "us-west-2",
                transport: transport,
                testEndpoint: endpoint
            )
        }
        #expect(transport.recordedRequests.isEmpty)
    }

    @Test("a dedicated exact loopback STS override never changes the separate S3 storage authority")
    func explicitLoopbackSTSSeamUsesOnlyItsOwnExactAuthority() async throws {
        let fixture = try AWSWebIdentityTraceFixture()
        defer { fixture.clean() }
        let descriptor = try #require(fixture.cloudAuthorization().webIdentity)
        let transport = MockHTTPTransport(responses: [AWSWebIdentityTraceFixture.stsResponse()])
        let endpoint = try #require(URL(string: "http://127.0.0.1:24191/"))

        let credentials = try await LiveAWSWebIdentityCredentials.exchange(
            descriptor: descriptor,
            region: "us-west-2",
            transport: transport,
            testEndpoint: endpoint
        )

        #expect(credentials.accessKeyID == AWSWebIdentityTraceFixture.accessKeyID)
        #expect(transport.recordedRequests.count == 1)
        #expect(transport.recordedRequests.first?.url == endpoint)
        #expect(transport.recordedRequests.first?.headers["Authorization"] == nil)
    }

    @Test("AWS China and GovCloud role partitions select only their exact regional STS authorities", arguments: ["china", "govcloud"])
    func partitionSpecificRegionalSTSHostsRemainPinned(_ partition: String) async throws {
        let fixture = try AWSWebIdentityTraceFixture()
        defer { fixture.clean() }
        let awsPartition = partition == "china" ? "aws-cn" : "aws-us-gov"
        let region = partition == "china" ? "cn-north-1" : "us-gov-west-1"
        let expectedHost = partition == "china"
            ? "sts.cn-north-1.amazonaws.com.cn"
            : "sts.us-gov-west-1.amazonaws.com"
        let environment = try fixture.environment(overrides: [
            "AWS_REGION": region,
            "AWS_ROLE_ARN": "arn:\(awsPartition):iam::123456789012:role/private/trace-writer",
        ])
        let descriptor = try #require(fixture.cloudAuthorization(environment: environment).webIdentity)
        let transport = MockHTTPTransport(responses: [
            AWSWebIdentityTraceFixture.stsResponse(
                body: AWSWebIdentityTraceFixture.responseXML(partition: awsPartition)
            ),
        ])

        let credentials = try await LiveAWSWebIdentityCredentials.exchange(
            descriptor: descriptor,
            region: region,
            transport: transport
        )

        #expect(credentials.accessKeyID == AWSWebIdentityTraceFixture.accessKeyID)
        #expect(transport.recordedRequests.first?.url.host == expectedHost)
    }

    @Test("rotating the owner-private JWT during STS minting blocks all later S3 dispatch")
    func subjectTokenRotationAfterSTSCannotReachStorage() async throws {
        let fixture = try AWSWebIdentityTraceFixture()
        defer { fixture.clean() }
        try await fixture.seed("rotated-web-token")
        let scripted = MockHTTPTransport(responses: [AWSWebIdentityTraceFixture.stsResponse()])
        let tokenFile = fixture.tokenFile
        let transport = AWSWebIdentityMutationTransport(wrapped: scripted, invocation: 1) {
            try SecureFile.write(at: tokenFile, contents: AWSWebIdentityTraceFixture.rotatedJWT)
        }

        let result = await fixture.run(
            "rotated-web-token",
            environment: try fixture.environment(),
            transport: transport
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(scripted.recordedRequests.count == 1)
        #expect(scripted.recordedRequests.first?.url.host == "sts.us-west-2.amazonaws.com")
        #expect(!result.errors.contains(AWSWebIdentityTraceFixture.jwt))
        #expect(!result.errors.contains(AWSWebIdentityTraceFixture.rotatedJWT))
    }

    @Test("a durable xAI provider boundary closed during STS minting blocks all later S3 dispatch")
    func providerRevocationDuringSTSCannotReachStorage() async throws {
        let fixture = try AWSWebIdentityTraceFixture()
        defer { fixture.clean() }
        let original = try await fixture.seed("revoked-web-provider")
        let scripted = MockHTTPTransport(responses: [AWSWebIdentityTraceFixture.stsResponse()])
        let home = fixture.home
        let transport = AWSWebIdentityMutationTransport(wrapped: scripted, invocation: 1) {
            var changed = original
            changed.currentProvider = .codex
            changed.everUsedNonXAI = true
            try await LiveConversationStore(openGrokHome: home).save(changed)
        }

        let result = await fixture.run(
            "revoked-web-provider",
            environment: try fixture.environment(),
            transport: transport
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(scripted.recordedRequests.count == 1)
        #expect(scripted.recordedRequests.first?.url.host == "sts.us-west-2.amazonaws.com")
    }

    @Test("token rotation after multipart initiation suppresses parts and even the best-effort abort")
    func multipartTokenRotationPreventsEverySubsequentRequest() async throws {
        let fixture = try AWSWebIdentityTraceFixture()
        defer { fixture.clean() }
        let sessionID = "rotated-multipart-token"
        try await fixture.seed(sessionID)
        let environment = try fixture.environment()
        let document = LiveManagedSetupComposition.trustedConfigDocument(environment: environment)
        let initial = try await LiveTraceUpload.authorize(
            sessionID: sessionID,
            home: fixture.home,
            document: document,
            environment: environment,
            uploadEnabled: true
        )
        let scripted = MockHTTPTransport(responses: [
            AWSWebIdentityTraceFixture.stsResponse(),
            AWSWebIdentityTraceFixture.initiation(sessionID: sessionID),
        ])
        let tokenFile = fixture.tokenFile
        let transport = AWSWebIdentityMutationTransport(wrapped: scripted, invocation: 2) {
            try SecureFile.write(at: tokenFile, contents: AWSWebIdentityTraceFixture.rotatedJWT)
        }
        let services = LiveTraceUploadServices(makeTransport: { transport }, sleep: { _ in })

        await #expect(throws: (any Error).self) {
            try await LiveTraceUpload.upload(
                sessionID: sessionID,
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
        #expect(scripted.recordedRequests.map(\.method) == [.post, .post])
        #expect(scripted.recordedRequests[0].url.host == "sts.us-west-2.amazonaws.com")
        #expect(scripted.recordedRequests[1].url.query == "uploads=")
    }

    @Test("an account opt-out, closed provider boundary or unsupported metadata provider blocks STS itself", arguments: ["opted-out", "foreign-provider", "container", "metadata", "dynamic-profile"])
    func closedSessionAndUnsupportedProvidersCannotReachSTS(_ scenario: String) async throws {
        let fixture = try AWSWebIdentityTraceFixture()
        defer { fixture.clean() }
        let provider: ModelProvider = scenario == "foreign-provider" ? .codex : .xai
        try await fixture.seed("closed-web-boundary", provider: provider)
        let account: GrokAuth?
        if scenario == "opted-out" {
            account = GrokAuth(
                key: AWSWebIdentityTraceFixture.xaiToken,
                authMode: .oidc,
                userID: "aws-web-identity-user",
                codingDataRetentionOptOut: true,
                oidcIssuer: "https://auth.x.ai"
            )
        } else {
            account = nil
        }
        var environment = try fixture.environment(auth: account)
        switch scenario {
        case "container":
            environment["AWS_CONTAINER_CREDENTIALS_FULL_URI"] = "http://169.254.170.2/PRIVATE_METADATA"
        case "metadata":
            environment["AWS_EC2_METADATA_SERVICE_ENDPOINT"] = "http://169.254.169.254/PRIVATE_METADATA"
        case "dynamic-profile":
            let path = fixture.workspace.appendingPathComponent("private-dynamic-config")
            try SecureFile.write(at: path, contents: "[default]\ncredential_process = PRIVATE_EXECUTE_ME\n")
            environment["AWS_CONFIG_FILE"] = path.path
        default: break
        }

        let transport = MockHTTPTransport()
        let result = await fixture.run(
            "closed-web-boundary",
            environment: environment,
            transport: transport
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(transport.recordedRequests.isEmpty)
        #expect(!result.errors.contains("PRIVATE_METADATA"))
        #expect(!result.errors.contains("PRIVATE_EXECUTE_ME"))
    }

    @Test("retrying an S3 failure never repeats the STS web-identity exchange")
    func temporaryCredentialsAreMintedOnceAcrossS3Retries() async throws {
        let fixture = try AWSWebIdentityTraceFixture()
        defer { fixture.clean() }
        try await fixture.seed("web-identity-retry")
        let transport = MockHTTPTransport(responses: [
            AWSWebIdentityTraceFixture.stsResponse(),
            .init(metadata: HTTPResponseMetadata(statusCode: 503)),
            .init(metadata: HTTPResponseMetadata(statusCode: 200)),
        ])

        let result = await fixture.run(
            "web-identity-retry",
            environment: try fixture.environment(),
            transport: transport
        )

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(transport.recordedRequests.map(\.method) == [.post, .put, .put])
        #expect(transport.recordedRequests.filter {
            $0.url.host == "sts.us-west-2.amazonaws.com"
        }.count == 1)
    }
}
