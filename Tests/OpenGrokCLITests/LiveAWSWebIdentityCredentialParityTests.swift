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
