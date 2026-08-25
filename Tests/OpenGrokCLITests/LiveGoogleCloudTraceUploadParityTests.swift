import Foundation
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokFileUtils
import OpenGrokHTTP
import OpenGrokSamplingTypes
import Testing

@testable import OpenGrokCLI

private struct GoogleCloudTraceUploadFixture {
    static let bucket = "private-google-bucket"
    static let accessToken = "PRIVATE_GOOGLE_ACCESS_TOKEN"
    static let xaiToken = "PRIVATE_XAI_OAUTH_BEARER"
    static let clientSecret = "PRIVATE_GOOGLE_CLIENT_SECRET"
    static let refreshToken = "PRIVATE_GOOGLE_REFRESH_TOKEN"
    static let serviceAccountEmail = "trace-writer@test-project.iam.gserviceaccount.com"
    static let subjectToken = "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJwcml2YXRlIn0.cHJpdmF0ZS1zaWduYXR1cmU"
    static let rotatedSubjectToken = "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJyb3RhdGVkIn0.cm90YXRlZC1zaWduYXR1cmU"
    static let workloadAudience = "//iam.googleapis.com/projects/123456789012/locations/global/"
        + "workloadIdentityPools/private-pool/providers/private-provider"
    static let testOnlyPrivateKey = """
    -----BEGIN PRIVATE KEY-----
    MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQC2J08VwFUGUAdR
    tfr1Rm+jQZ1fXH+n5oKKDl6756Q7jiUOcCNfzvEpGqoOqwcUHCDAEXPXHtk5JlNj
    0/iZSC9K8x8d5lmAFaMwLv8mqlLwRt15Z7iKA2w+MHHfi4dDcrQiDWRBsV9iSs9s
    CW4tLUEpaEWItu6lVN8v65BaOxDvme0G83v5AwSI6ociKehP+IMczE1yRvy19h2I
    G4396bi8oOhHT+tRhsVTgSfQ49rE3jb5giqRpqdC+Iv1pivg/QNrqyFC0/B+chI5
    2XoXz2jCzASyIxf7npwwujOsQwHRlOGcKZdeLZrFSglIL7vFgCOsZKboEvsRf5ft
    JQDF5nP9AgMBAAECggEAB2/d7P2sCwSv89BaBXMhgjke14KjjKOe70uMZyAbRro0
    PZ1q+FGu63Z0/IHTmWjXlnfv8pfGFyz/KRuBsiJuGeGIwvQBcfcQMVqt3LKGDdza
    1IbdVDc1D2nzcETWWjTf8Wb6EauQASecReUxrCMFns7szdroLfRj42U7ANAaDio5
    LlJnFxnp5+s2uZk4kU4PMKSQOa5BBu0hz8WIXrhocSCTH+TOOqtOuVdOEC0Gp//M
    81m35CFsCz+/6zs7q12+LWH6apwcqbQpPgV26RZ4Hvo6d79X/Z3wu/3qkn1UEi+a
    922ownKHJo5JMWpOD6kEp6oKfLVroTqvT8njllh64QKBgQDzdo5iYM/4THOXDCOn
    WzloGfr1CYg4LMi40U3EUCuiheBkUUP2wiMJP7o7ai8gjQDfN770GGLLoCCcTEia
    gJG3ACtatj7qzX7/g0vVKBrhIrFgFV4cf98oRzH9UX8u7HBDDcsV8Oy4F1EF9lfG
    LOz8MxVTg28dXF6K9HFyNggT4QKBgQC/iIqpFNamW/pO/SFip577wQqecXQZHlFq
    dreT7vc2bcNWcnpBfAk2mQAfLpvFxLmW4ykbRNRhhAIi5ZoLHMky0Kjc55DDNyAX
    ylBrXAURQfmkBEhwkX8UDaJ3/vmie4y+/IafdU93ZaAPYRqTIHLJQ+esG2LxVJBW
    9Du8p4qjnQKBgEjYa0fiQbfAYEGMn0pe0DFmvKD+piRwueoarhMUDcpGFlrNufEm
    K0eEKtvGLK2nouAnFNqCRWU51ygM5xhbab4ArfgpWW/15o7bISB5LHm6YKooGo2a
    cRHjI4DxFoXatshJYz+AY8O9LkADckXYgVwAiNwBEokNbzhSZXNP2WDhAoGAajXX
    XoeVuE7M8TxhZQm6mbSkpNQZI0yyrS0EA97B68bWSXvV27ZijYoujRwVeYfruoZh
    ZyO1+hVv8dYMpBjkYW9gFI+8sORCwa6JBd/TV4yUWKWfXfzw0Tf2XkBgQf/tPoNe
    S9KLrJQIPD8Gs4uM25ryP3g4V8ci+3UYIzdtI+kCgYBxMUMlCdKKv4AgULchRXc3
    HvFMDcR6TQgeB04AlZYdHTLmekq8s+ktpCWG4f6nPdFzJbNrUTmaSa1Jyf23TMcc
    up5ySIeMUp+bHLsYymUqM2nP12/+IP4V7qqT5ilV4sAJmLd6iICJgtR8DO3/9Fey
    Ruq2Nad+bTFNPhlOtfnxdg==
    -----END PRIVATE KEY-----
    """

    let root: URL
    let home: URL
    let workspace: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-google-trace-\(UUID().uuidString)",
            isDirectory: true
        )
        home = root.appendingPathComponent("state", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
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
    }

    static func credentials(
        clientID: String = "google-cloud-client",
        tokenURI: String = "https://oauth2.googleapis.com/token",
        type: String = "authorized_user"
    ) throws -> String {
        let payload: [String: String] = [
            "type": type,
            "client_id": clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "token_uri": tokenURI,
        ]
        return String(
            decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            as: UTF8.self
        )
    }

    static func serviceAccountCredentials() throws -> String {
        let payload: [String: String] = [
            "type": "service_account",
            "client_email": serviceAccountEmail,
            "private_key_id": "deterministic-test-key",
            "private_key": testOnlyPrivateKey,
            "token_uri": "https://oauth2.googleapis.com/token",
        ]
        return String(
            decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            as: UTF8.self
        )
    }

    static func externalAccountCredentials(
        subjectTokenPath: String,
        tokenURL: String = "https://sts.googleapis.com/v1/token",
        audience: String = workloadAudience,
        subjectTokenType: String = "urn:ietf:params:oauth:token-type:jwt",
        format: String? = nil,
        subjectTokenField: String? = nil,
        documentOverrides: [String: Any] = [:],
        sourceOverrides: [String: Any] = [:]
    ) throws -> String {
        var source: [String: Any] = ["file": subjectTokenPath]
        if let format {
            var configuration: [String: Any] = ["type": format]
            if let subjectTokenField {
                configuration["subject_token_field_name"] = subjectTokenField
            }
            source["format"] = configuration
        }
        source.merge(sourceOverrides) { _, override in override }

        var payload: [String: Any] = [
            "type": "external_account",
            "audience": audience,
            "subject_token_type": subjectTokenType,
            "token_url": tokenURL,
            "credential_source": source,
        ]
        payload.merge(documentOverrides) { _, override in override }
        return String(
            decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            as: UTF8.self
        )
    }

    static func document(inline: String? = nil, credentialFile: String? = nil) -> TOMLValue {
        var endpoints = TOMLTable()
        if let inline {
            endpoints["trace_upload_credentials"] = .string(inline)
        }
        if let credentialFile {
            endpoints["trace_upload_credentials_file"] = .string(credentialFile)
        }
        return .table(["endpoints": .table(endpoints)])
    }

    static func tokenResponse(
        status: Int = 200,
        body: String = "{\"access_token\":\"\(accessToken)\",\"token_type\":\"Bearer\",\"expires_in\":3600}",
        url: URL? = nil
    ) -> MockHTTPTransport.ScriptedResponse {
        MockHTTPTransport.ScriptedResponse(
            metadata: HTTPResponseMetadata(statusCode: status, url: url),
            body: Data(body.utf8)
        )
    }

    static func uploadResponse(
        sessionID: String,
        status: Int = 200,
        body: String? = nil,
        url: URL? = nil
    ) -> MockHTTPTransport.ScriptedResponse {
        let response = body
            ?? "{\"bucket\":\"\(bucket)\",\"name\":\"\(sessionID)/trace_export.tar.gz\"}"
        return MockHTTPTransport.ScriptedResponse(
            metadata: HTTPResponseMetadata(statusCode: status, url: url),
            body: Data(response.utf8)
        )
    }

    static func authorize(
        sessionID: String = "google-session",
        bucketURL: String = "gs://private-google-bucket",
        document: TOMLValue = .table(TOMLTable()),
        environment: [String: String]? = nil
    ) throws -> LiveGoogleCloudTraceUpload.Authorization {
        try LiveGoogleCloudTraceUpload.authorize(
            sessionID: sessionID,
            bucketURL: bucketURL,
            document: document,
            environment: environment
                ?? ["GOOGLE_APPLICATION_CREDENTIALS_JSON": try credentials()]
        )
    }

    static func upload(
        sessionID: String = "google-session",
        archive: Data = Data("PRIVATE_GOOGLE_TRACE_ARCHIVE".utf8),
        authorization: LiveGoogleCloudTraceUpload.Authorization,
        transport: MockHTTPTransport,
        authorizeRequest: (@Sendable () async throws -> LiveGoogleCloudTraceUpload.Authorization)? = nil
    ) async throws -> String {
        try await LiveGoogleCloudTraceUpload.upload(
            sessionID: sessionID,
            archive: archive,
            authorization: authorization,
            transport: transport,
            authorizeRequest: authorizeRequest ?? { authorization }
        )
    }

    static func tokenFields(in request: HTTPRequest) throws -> [String: String] {
        let body = try #require(request.body)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
    }

    static func decodeBase64URL(_ segment: Substring) -> Data? {
        var encoded = segment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        return Data(base64Encoded: encoded)
    }

    func privateCredentialFile(_ contents: String, named name: String = "credentials.json") throws -> URL {
        let location = workspace.appendingPathComponent(name)
        try SecureFile.write(at: location, contents: contents)
        return location
    }

    func environment(
        credentials: String? = nil,
        auth: GrokAuth? = nil,
        overrides: [String: String] = [:]
    ) throws -> [String: String] {
        let account = auth ?? GrokAuth(
            key: Self.xaiToken,
            authMode: .oidc,
            userID: "google-trace-user",
            codingDataRetentionOptOut: false,
            oidcIssuer: "https://auth.x.ai"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let selectedCredentials: String
        if let credentials {
            selectedCredentials = credentials
        } else {
            selectedCredentials = try Self.credentials()
        }
        var environment = [
            "HOME": root.path,
            "OPENGROK_HOME": home.path,
            "PWD": workspace.path,
            "GROK_TRACE_UPLOAD_BUCKET": "gs://\(Self.bucket)",
            "GOOGLE_APPLICATION_CREDENTIALS_JSON": selectedCredentials,
            "OPENGROK_AUTH": String(decoding: try encoder.encode(account), as: UTF8.self),
        ]
        environment.merge(overrides) { _, override in override }
        return environment
    }

    func seed(_ sessionID: String) async throws {
        var record = LiveConversationRecord.new(sessionID: sessionID, workingDirectory: workspace)
        record.currentModelID = "grok-code-fast-1"
        record.currentProvider = .xai
        record.everUsedNonXAI = false
        record.items = [.user("PRIVATE_GOOGLE_TRACE_TRANSCRIPT")]
        try await LiveConversationStore(openGrokHome: home).save(record)
    }

    func run(
        _ sessionID: String,
        environment: [String: String],
        transport: MockHTTPTransport
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

    func clean() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor GoogleCloudAuthorizationBoundary {
    private(set) var invocationCount = 0
    private let revokedInvocation: Int?

    init(revokedInvocation: Int? = nil) {
        self.revokedInvocation = revokedInvocation
    }

    func authorize(
        _ authorization: LiveGoogleCloudTraceUpload.Authorization
    ) throws -> LiveGoogleCloudTraceUpload.Authorization {
        invocationCount += 1
        if invocationCount == revokedInvocation {
            throw LiveGoogleCloudTraceUpload.Failure.authorizationChanged
        }
        return authorization
    }
}

private actor GoogleCloudSubjectTokenRotationBoundary {
    private let path: URL
    private let environment: [String: String]
    private let rotateInvocation: Int
    private(set) var invocationCount = 0

    init(path: URL, environment: [String: String], rotateInvocation: Int) {
        self.path = path
        self.environment = environment
        self.rotateInvocation = rotateInvocation
    }

    func authorize() throws -> LiveGoogleCloudTraceUpload.Authorization {
        invocationCount += 1
        if invocationCount == rotateInvocation {
            try SecureFile.write(
                at: path,
                contents: GoogleCloudTraceUploadFixture.rotatedSubjectToken
            )
        }
        return try GoogleCloudTraceUploadFixture.authorize(environment: environment)
    }
}

@Suite("live direct Google Cloud Storage trace upload security and parity", .serialized)
struct LiveGoogleCloudTraceUploadParityTests {
    @Test("Google storage scopes match the pinned Rust gcloud-storage client exactly")
    func storageScopesMatchPinnedRustClient() {
        #expect(LiveGoogleCloudTraceUpload.storageScopes
            == "https://www.googleapis.com/auth/cloud-platform "
                + "https://www.googleapis.com/auth/devstorage.full_control")
    }

    @Test("direct gs destinations resolve to Google's pinned media-upload origin")
    func googleStorageDestinationIsPinnedAndObjectPathIsEncoded() throws {
        let authorization = try GoogleCloudTraceUploadFixture.authorize(sessionID: "session-42")

        #expect(authorization.bucket == GoogleCloudTraceUploadFixture.bucket)
        #expect(authorization.endpoint.absoluteString
            == "https://storage.googleapis.com/upload/storage/v1/b/private-google-bucket/o"
                + "?uploadType=media&name=session-42%2Ftrace_export.tar.gz")
    }

    @Test("native service-account signing creates an RS256 JWT with exact Rust storage scopes")
    func serviceAccountUsesNativeRS256SigningAndPinnedClaims() async throws {
        let authorization = try GoogleCloudTraceUploadFixture.authorize(environment: [
            "GOOGLE_APPLICATION_CREDENTIALS_JSON": try GoogleCloudTraceUploadFixture.serviceAccountCredentials(),
        ])
        let assertion = try LiveGoogleCloudTraceUpload.serviceAccountAssertion(
            authorization: authorization,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let segments = assertion.split(separator: ".")
        try #require(segments.count == 3)
        let headerData = try #require(
            GoogleCloudTraceUploadFixture.decodeBase64URL(segments[0])
        )
        let claimsData = try #require(
            GoogleCloudTraceUploadFixture.decodeBase64URL(segments[1])
        )
        let header = try #require(JSONSerialization.jsonObject(
            with: headerData
        ) as? [String: Any])
        let claims = try #require(JSONSerialization.jsonObject(
            with: claimsData
        ) as? [String: Any])
        let signature = try #require(GoogleCloudTraceUploadFixture.decodeBase64URL(segments[2]))
        #expect(header["alg"] as? String == "RS256")
        #expect(header["typ"] as? String == "JWT")
        #expect(header["kid"] as? String == "deterministic-test-key")
        #expect(claims["iss"] as? String == GoogleCloudTraceUploadFixture.serviceAccountEmail)
        #expect(claims["scope"] as? String == LiveGoogleCloudTraceUpload.storageScopes)
        #expect(claims["aud"] as? String == "https://oauth2.googleapis.com/token")
        #expect((claims["iat"] as? NSNumber)?.int64Value == 1_700_000_000)
        #expect((claims["exp"] as? NSNumber)?.int64Value == 1_700_003_600)
        #expect(signature.count == 256)

        let transport = MockHTTPTransport(responses: [
            GoogleCloudTraceUploadFixture.tokenResponse(),
            GoogleCloudTraceUploadFixture.uploadResponse(sessionID: "google-session"),
        ])
        let result = try await GoogleCloudTraceUploadFixture.upload(
            authorization: authorization,
            transport: transport
        )

        #expect(result == "gs://private-google-bucket/google-session/trace_export.tar.gz")
        let tokenRequest = try #require(transport.recordedRequests.first)
        #expect(tokenRequest.headers["Content-Type"] == "application/x-www-form-urlencoded")
        let tokenBody = String(decoding: try #require(tokenRequest.body), as: UTF8.self)
        let components = try #require(URLComponents(string: "https://unused.invalid/?" + tokenBody))
        let fields = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
        #expect(fields["grant_type"] == "urn:ietf:params:oauth:grant-type:jwt-bearer")
        #expect(fields["assertion"]?.split(separator: ".").count == 3)
        #expect(fields["scope"] == nil)
        #expect(!tokenBody.contains("PRIVATE KEY"))
    }

    @Test("raw and base64 Google ADC JSON perform one isolated refresh and one media upload", arguments: [false, true])
    func authorizedUserRefreshAndMediaUploadAreIsolated(_ base64Encoded: Bool) async throws {
        let credentials = try GoogleCloudTraceUploadFixture.credentials()
        let encodedCredentials = base64Encoded
            ? Data(credentials.utf8).base64EncodedString()
            : credentials
        let authorization = try GoogleCloudTraceUploadFixture.authorize(environment: [
            "GOOGLE_APPLICATION_CREDENTIALS_JSON": encodedCredentials,
            "XAI_API_KEY": "PRIVATE_FOREIGN_XAI_KEY",
            "GROK_DEPLOYMENT_KEY": "PRIVATE_FOREIGN_DEPLOYMENT_KEY",
        ])
        let transport = MockHTTPTransport(responses: [
            GoogleCloudTraceUploadFixture.tokenResponse(),
            GoogleCloudTraceUploadFixture.uploadResponse(sessionID: "google-session"),
        ])
        let boundary = GoogleCloudAuthorizationBoundary()
        let archive = Data("PRIVATE_GOOGLE_TRACE_ARCHIVE".utf8)

        let result = try await GoogleCloudTraceUploadFixture.upload(
            archive: archive,
            authorization: authorization,
            transport: transport,
            authorizeRequest: { try await boundary.authorize(authorization) }
        )

        #expect(result == "gs://private-google-bucket/google-session/trace_export.tar.gz")
        #expect(await boundary.invocationCount == 2)
        #expect(transport.recordedRequests.count == 2)
        let token = try #require(transport.recordedRequests.first)
        #expect(token.method == .post)
        #expect(token.url.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(token.headers["Content-Type"] == "application/json")
        #expect(token.headers["Authorization"] == nil)
        let fields = try GoogleCloudTraceUploadFixture.tokenFields(in: token)
        #expect(fields["grant_type"] == "refresh_token")
        #expect(fields["client_id"] == "google-cloud-client")
        #expect(fields["client_secret"] == GoogleCloudTraceUploadFixture.clientSecret)
        #expect(fields["refresh_token"] == GoogleCloudTraceUploadFixture.refreshToken)
        #expect(fields["scope"] == nil)
        #expect(fields.count == 4)

        let upload = try #require(transport.recordedRequests.last)
        #expect(upload.method == .post)
        #expect(upload.url == authorization.endpoint)
        #expect(upload.headers["Authorization"]
            == "Bearer \(GoogleCloudTraceUploadFixture.accessToken)")
        #expect(upload.headers["Content-Type"] == "application/gzip")
        #expect(upload.body == archive)
        for request in transport.recordedRequests {
            #expect(request.headers[xaiTokenAuthHeader] == nil)
            #expect(request.headers["x-grok-client-version"] == nil)
            #expect(request.headers["x-grok-client-identifier"] == nil)
            #expect(!request.headers.values.contains("PRIVATE_FOREIGN_XAI_KEY"))
            #expect(!request.headers.values.contains("PRIVATE_FOREIGN_DEPLOYMENT_KEY"))
        }
        #expect(upload.headers.values.allSatisfy {
            !$0.contains(GoogleCloudTraceUploadFixture.refreshToken)
                && !$0.contains(GoogleCloudTraceUploadFixture.clientSecret)
        })
    }

    @Test(
        "owner-private text and JSON workload JWT files use the pinned Rust six-field STS exchange",
        arguments: ["implicit-text", "text", "json"]
    )
    func privateWorkloadIdentityFilesExchangeOnlyScopedJWTs(_ format: String) async throws {
        let fixture = try GoogleCloudTraceUploadFixture()
        defer { fixture.clean() }
        let contents = format == "json"
            ? "{\"assertion\":\"\(GoogleCloudTraceUploadFixture.subjectToken)\",\"other\":true}"
            : GoogleCloudTraceUploadFixture.subjectToken
        let subjectFile = try fixture.privateCredentialFile(contents, named: "private-subject-token")
        let credentials = try GoogleCloudTraceUploadFixture.externalAccountCredentials(
            subjectTokenPath: subjectFile.path,
            format: format == "implicit-text" ? nil : format,
            subjectTokenField: format == "json" ? "assertion" : nil
        )
        let authorization = try GoogleCloudTraceUploadFixture.authorize(environment: [
            "GOOGLE_APPLICATION_CREDENTIALS_JSON": credentials,
            "XAI_API_KEY": "PRIVATE_FOREIGN_XAI_KEY",
            "GROK_DEPLOYMENT_KEY": "PRIVATE_FOREIGN_DEPLOYMENT_KEY",
        ])
        let transport = MockHTTPTransport(responses: [
            GoogleCloudTraceUploadFixture.tokenResponse(),
            GoogleCloudTraceUploadFixture.uploadResponse(sessionID: "google-session"),
        ])
        let boundary = GoogleCloudAuthorizationBoundary()

        let result = try await GoogleCloudTraceUploadFixture.upload(
            authorization: authorization,
            transport: transport,
            authorizeRequest: { try await boundary.authorize(authorization) }
        )

        #expect(result == "gs://private-google-bucket/google-session/trace_export.tar.gz")
        #expect(await boundary.invocationCount == 2)
        #expect(transport.recordedRequests.count == 2)

        let exchange = try #require(transport.recordedRequests.first)
        #expect(exchange.method == .post)
        #expect(exchange.url.absoluteString == "https://sts.googleapis.com/v1/token")
        #expect(exchange.headers["Content-Type"] == "application/x-www-form-urlencoded")
        #expect(exchange.headers["Authorization"] == nil)
        let body = String(decoding: try #require(exchange.body), as: UTF8.self)
        let components = try #require(URLComponents(string: "https://unused.invalid/?" + body))
        let fields = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
        #expect(fields.count == 6)
        #expect(fields["grant_type"] == "urn:ietf:params:oauth:grant-type:token-exchange")
        #expect(fields["audience"] == GoogleCloudTraceUploadFixture.workloadAudience)
        #expect(fields["scope"] == LiveGoogleCloudTraceUpload.storageScopes)
        #expect(fields["subject_token_type"] == "urn:ietf:params:oauth:token-type:jwt")
        #expect(fields["subject_token"] == GoogleCloudTraceUploadFixture.subjectToken)
        #expect(fields["requested_token_type"] == "urn:ietf:params:oauth:token-type:access_token")

        let upload = try #require(transport.recordedRequests.last)
        #expect(upload.url.host == "storage.googleapis.com")
        #expect(upload.headers["Authorization"] == "Bearer \(GoogleCloudTraceUploadFixture.accessToken)")
        #expect(!upload.headers.values.contains(GoogleCloudTraceUploadFixture.subjectToken))
        for request in transport.recordedRequests {
            #expect(request.headers[xaiTokenAuthHeader] == nil)
            #expect(!request.headers.values.contains("PRIVATE_FOREIGN_XAI_KEY"))
            #expect(!request.headers.values.contains("PRIVATE_FOREIGN_DEPLOYMENT_KEY"))
        }
    }

    @Test("the launched trace command exchanges a private workload JWT before uploading its real archive")
    func productionTraceCommandReachesGoogleWorkloadIdentityFederation() async throws {
        let fixture = try GoogleCloudTraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed("federated-google")
        let subjectFile = try fixture.privateCredentialFile(
            GoogleCloudTraceUploadFixture.subjectToken,
            named: "launched-subject-token"
        )
        let credentials = try GoogleCloudTraceUploadFixture.externalAccountCredentials(
            subjectTokenPath: subjectFile.path
        )
        let transport = MockHTTPTransport(responses: [
            GoogleCloudTraceUploadFixture.tokenResponse(),
            GoogleCloudTraceUploadFixture.uploadResponse(sessionID: "federated-google"),
        ])

        let result = await fixture.run(
            "federated-google",
            environment: try fixture.environment(credentials: credentials),
            transport: transport
        )

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(result.errors.isEmpty)
        let output = try #require(JSONSerialization.jsonObject(
            with: Data(result.output.utf8)
        ) as? [String: Any])
        #expect(output["url"] as? String
            == "gs://private-google-bucket/federated-google/trace_export.tar.gz")
        #expect(transport.recordedRequests.count == 2)
        #expect(transport.recordedRequests[0].url.absoluteString == "https://sts.googleapis.com/v1/token")
        #expect(transport.recordedRequests[1].url.host == "storage.googleapis.com")
        #expect(transport.recordedRequests[1].body?.starts(with: [0x1F, 0x8B]) == true)
        for secret in [
            GoogleCloudTraceUploadFixture.subjectToken,
            GoogleCloudTraceUploadFixture.accessToken,
            GoogleCloudTraceUploadFixture.xaiToken,
        ] {
            #expect(!result.output.contains(secret))
            #expect(!result.errors.contains(secret))
        }
    }

    @Test("an explicit loopback override keeps Google STS and storage on the same exact authority")
    func workloadIdentityLoopbackExchangeSharesStorageAuthority() async throws {
        let fixture = try GoogleCloudTraceUploadFixture()
        defer { fixture.clean() }
        let subjectFile = try fixture.privateCredentialFile(
            GoogleCloudTraceUploadFixture.subjectToken,
            named: "loopback-subject-token"
        )
        let origin = "http://127.0.0.1:24191"
        let credentials = try GoogleCloudTraceUploadFixture.externalAccountCredentials(
            subjectTokenPath: subjectFile.path,
            tokenURL: origin + "/v1/token"
        )
        let authorization = try GoogleCloudTraceUploadFixture.authorize(environment: [
            "GOOGLE_APPLICATION_CREDENTIALS_JSON": credentials,
            "GROK_TRACE_UPLOAD_ENDPOINT_URL": origin,
        ])
        let transport = MockHTTPTransport(responses: [
            GoogleCloudTraceUploadFixture.tokenResponse(),
            GoogleCloudTraceUploadFixture.uploadResponse(sessionID: "google-session"),
        ])

        let result = try await GoogleCloudTraceUploadFixture.upload(
            authorization: authorization,
            transport: transport
        )

        #expect(result == "gs://private-google-bucket/google-session/trace_export.tar.gz")
        #expect(transport.recordedRequests.count == 2)
        #expect(transport.recordedRequests[0].url.absoluteString == origin + "/v1/token")
        #expect(transport.recordedRequests[1].url.host == "127.0.0.1")
        #expect(transport.recordedRequests[1].url.port == 24191)
    }

    @Test("a loopback Google workload exchange cannot silently switch away from its storage authority")
    func workloadIdentityLoopbackCannotCrossAuthorities() throws {
        let fixture = try GoogleCloudTraceUploadFixture()
        defer { fixture.clean() }
        let subjectFile = try fixture.privateCredentialFile(
            GoogleCloudTraceUploadFixture.subjectToken,
            named: "cross-authority-subject-token"
        )
        let credentials = try GoogleCloudTraceUploadFixture.externalAccountCredentials(
            subjectTokenPath: subjectFile.path,
            tokenURL: "http://127.0.0.1:24192/v1/token"
        )
        let transport = MockHTTPTransport()

        #expect(throws: LiveGoogleCloudTraceUpload.Failure.self) {
            try GoogleCloudTraceUploadFixture.authorize(environment: [
                "GOOGLE_APPLICATION_CREDENTIALS_JSON": credentials,
                "GROK_TRACE_UPLOAD_ENDPOINT_URL": "http://127.0.0.1:24191",
            ])
        }
        #expect(transport.recordedRequests.isEmpty)
    }

    @Test("the launched trace command exchanges scoped Google credentials and never emits account secrets")
    func productionTraceCommandReachesGoogleStorageTransport() async throws {
        let fixture = try GoogleCloudTraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed("production-google")
        let transport = MockHTTPTransport(responses: [
            GoogleCloudTraceUploadFixture.tokenResponse(),
            GoogleCloudTraceUploadFixture.uploadResponse(sessionID: "production-google"),
        ])

        let result = await fixture.run(
            "production-google",
            environment: try fixture.environment(),
            transport: transport
        )

        #expect(result.status == CLIRunner.ExitCode.success.rawValue)
        #expect(result.errors.isEmpty)
        let output = try #require(JSONSerialization.jsonObject(
            with: Data(result.output.utf8)
        ) as? [String: Any])
        #expect(output["url"] as? String
            == "gs://private-google-bucket/production-google/trace_export.tar.gz")
        #expect(transport.recordedRequests.count == 2)
        #expect(transport.recordedRequests[0].url.host == "oauth2.googleapis.com")
        #expect(transport.recordedRequests[1].url.host == "storage.googleapis.com")
        #expect(transport.recordedRequests[1].body?.starts(with: [0x1F, 0x8B]) == true)
        for secret in [
            GoogleCloudTraceUploadFixture.accessToken,
            GoogleCloudTraceUploadFixture.xaiToken,
            GoogleCloudTraceUploadFixture.clientSecret,
            GoogleCloudTraceUploadFixture.refreshToken,
        ] {
            #expect(!result.output.contains(secret))
            #expect(!result.errors.contains(secret))
        }
    }

    @Test("managed inline Google credentials override both private files and ambient ADC")
    func managedInlineCredentialsTakePrecedenceOverFilesAndAmbientAuthority() async throws {
        let fixture = try GoogleCloudTraceUploadFixture()
        defer { fixture.clean() }
        let ignoredFile = try fixture.privateCredentialFile(
            GoogleCloudTraceUploadFixture.credentials(clientID: "must-not-use-managed-file")
        )
        let authorization = try GoogleCloudTraceUploadFixture.authorize(
            document: GoogleCloudTraceUploadFixture.document(
                inline: GoogleCloudTraceUploadFixture.credentials(clientID: "managed-inline-client"),
                credentialFile: ignoredFile.path
            ),
            environment: [
                "GOOGLE_APPLICATION_CREDENTIALS_JSON": try GoogleCloudTraceUploadFixture.credentials(
                    clientID: "must-not-use-ambient-client"
                ),
                "GOOGLE_APPLICATION_CREDENTIALS": "../../must-not-open-ambient-file",
            ]
        )
        let transport = MockHTTPTransport(responses: [
            GoogleCloudTraceUploadFixture.tokenResponse(),
            GoogleCloudTraceUploadFixture.uploadResponse(sessionID: "google-session"),
        ])

        let result = try await GoogleCloudTraceUploadFixture.upload(
            authorization: authorization,
            transport: transport
        )

        #expect(result == "gs://private-google-bucket/google-session/trace_export.tar.gz")
        let fields = try GoogleCloudTraceUploadFixture.tokenFields(
            in: #require(transport.recordedRequests.first)
        )
        #expect(fields["client_id"] == "managed-inline-client")
    }

    @Test("private managed credential files precede injected ambient Google ADC")
    func managedPrivateFilePrecedesAmbientADC() async throws {
        let fixture = try GoogleCloudTraceUploadFixture()
        defer { fixture.clean() }
        let credentialFile = try fixture.privateCredentialFile(
            GoogleCloudTraceUploadFixture.credentials(clientID: "private-managed-file-client")
        )
        let authorization = try GoogleCloudTraceUploadFixture.authorize(
            document: GoogleCloudTraceUploadFixture.document(credentialFile: credentialFile.path),
            environment: [
                "GOOGLE_APPLICATION_CREDENTIALS_JSON": try GoogleCloudTraceUploadFixture.credentials(
                    clientID: "must-not-use-ambient-client"
                ),
            ]
        )
        let transport = MockHTTPTransport(responses: [
            GoogleCloudTraceUploadFixture.tokenResponse(),
            GoogleCloudTraceUploadFixture.uploadResponse(sessionID: "google-session"),
        ])

        let result = try await GoogleCloudTraceUploadFixture.upload(
            authorization: authorization,
            transport: transport
        )

        #expect(result == "gs://private-google-bucket/google-session/trace_export.tar.gz")
        let fields = try GoogleCloudTraceUploadFixture.tokenFields(
            in: #require(transport.recordedRequests.first)
        )
        #expect(fields["client_id"] == "private-managed-file-client")
    }

    @Test("explicit trace-upload inline environment credentials precede ambient Google ADC")
    func explicitInlineEnvironmentPrecedesAmbientADC() async throws {
        let authorization = try GoogleCloudTraceUploadFixture.authorize(environment: [
            "GROK_TRACE_UPLOAD_CREDENTIALS": try GoogleCloudTraceUploadFixture.credentials(
                clientID: "explicit-trace-inline-client"
            ),
            "GOOGLE_APPLICATION_CREDENTIALS_JSON": try GoogleCloudTraceUploadFixture.credentials(
                clientID: "must-not-use-ambient-client"
            ),
        ])
        let transport = MockHTTPTransport(responses: [
            GoogleCloudTraceUploadFixture.tokenResponse(),
            GoogleCloudTraceUploadFixture.uploadResponse(sessionID: "google-session"),
        ])

        let result = try await GoogleCloudTraceUploadFixture.upload(
            authorization: authorization,
            transport: transport
        )

        #expect(result == "gs://private-google-bucket/google-session/trace_export.tar.gz")
        let fields = try GoogleCloudTraceUploadFixture.tokenFields(
            in: #require(transport.recordedRequests.first)
        )
        #expect(fields["client_id"] == "explicit-trace-inline-client")
    }

    @Test("injected ambient Google ADC JSON precedes the owner-private ADC file")
    func injectedADCJSONPrecedesPrivateADCFile() async throws {
        let fixture = try GoogleCloudTraceUploadFixture()
        defer { fixture.clean() }
        let credentialFile = try fixture.privateCredentialFile(
            GoogleCloudTraceUploadFixture.credentials(clientID: "must-not-use-ambient-file")
        )
        let authorization = try GoogleCloudTraceUploadFixture.authorize(environment: [
            "GOOGLE_APPLICATION_CREDENTIALS_JSON": try GoogleCloudTraceUploadFixture.credentials(
                clientID: "injected-ambient-client"
            ),
            "GOOGLE_APPLICATION_CREDENTIALS": credentialFile.path,
        ])
        let transport = MockHTTPTransport(responses: [
            GoogleCloudTraceUploadFixture.tokenResponse(),
            GoogleCloudTraceUploadFixture.uploadResponse(sessionID: "google-session"),
        ])

        let result = try await GoogleCloudTraceUploadFixture.upload(
            authorization: authorization,
            transport: transport
        )

        #expect(result == "gs://private-google-bucket/google-session/trace_export.tar.gz")
        let fields = try GoogleCloudTraceUploadFixture.tokenFields(
            in: #require(transport.recordedRequests.first)
        )
        #expect(fields["client_id"] == "injected-ambient-client")
    }

    @Test("an owner-private GOOGLE_APPLICATION_CREDENTIALS file is accepted")
    func privateExplicitADCFileIsAccepted() throws {
        let fixture = try GoogleCloudTraceUploadFixture()
        defer { fixture.clean() }
        let credentialFile = try fixture.privateCredentialFile(
            GoogleCloudTraceUploadFixture.credentials()
        )

        let authorization = try GoogleCloudTraceUploadFixture.authorize(environment: [
            "GOOGLE_APPLICATION_CREDENTIALS": credentialFile.path,
        ])

        #expect(authorization.bucket == GoogleCloudTraceUploadFixture.bucket)
        #expect(authorization.endpoint.host == "storage.googleapis.com")
    }

    #if !os(Windows)
    @Test("an owner-private gcloud application-default credential file supplies ambient Google ADC")
    func privateDefaultGCloudCredentialFileSuppliesAmbientADC() throws {
        let fixture = try GoogleCloudTraceUploadFixture()
        defer { fixture.clean() }
        let directory = fixture.root
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("gcloud", isDirectory: true)
        try OpenGrokConfig.createDirAllOwnerOnly(directory)
        try SecureFile.write(
            at: directory.appendingPathComponent("application_default_credentials.json"),
            contents: GoogleCloudTraceUploadFixture.credentials()
        )

        let authorization = try GoogleCloudTraceUploadFixture.authorize(environment: [
            "HOME": fixture.root.path,
        ])

        #expect(authorization.bucket == GoogleCloudTraceUploadFixture.bucket)
        #expect(authorization.endpoint.host == "storage.googleapis.com")
    }
    #endif

    @Test(
        "forged workload-identity STS authorities cannot receive private JWT subject tokens",
        arguments: [
            "https://sts.googleapis.com.attacker.invalid/v1/token",
            "https://attacker.invalid/v1/token",
            "http://sts.googleapis.com/v1/token",
            "https://sts.googleapis.com/v1/token/",
            "https://sts.googleapis.com/v1/token?redirect=attacker.invalid",
            "https://sts.googleapis.com/v1/token#private",
            "https://private@sts.googleapis.com/v1/token",
            "https://oauth2.googleapis.com/token",
            "http://127.0.0.1:24191/v1/token",
        ]
    )
    func hostileWorkloadIdentityTokenEndpointsFailBeforeNetwork(_ tokenURL: String) throws {
        let fixture = try GoogleCloudTraceUploadFixture()
        defer { fixture.clean() }
        let subjectFile = try fixture.privateCredentialFile(
            GoogleCloudTraceUploadFixture.subjectToken,
            named: "hostile-endpoint-subject-token"
        )
        let credentials = try GoogleCloudTraceUploadFixture.externalAccountCredentials(
            subjectTokenPath: subjectFile.path,
            tokenURL: tokenURL
        )
        let transport = MockHTTPTransport()

        #expect(throws: LiveGoogleCloudTraceUpload.Failure.self) {
            try GoogleCloudTraceUploadFixture.authorize(environment: [
                "GOOGLE_APPLICATION_CREDENTIALS_JSON": credentials,
            ])
        }
        #expect(transport.recordedRequests.isEmpty)
    }

    @Test(
        "workload federation rejects forged Google IAM pool audiences and non-JWT token types",
        arguments: [
            "//iam.googleapis.com.attacker.invalid/projects/123/locations/global/workloadIdentityPools/pool/providers/provider",
            "https://iam.googleapis.com/projects/123/locations/global/workloadIdentityPools/pool/providers/provider",
            "//iam.googleapis.com/projects/private/locations/global/workloadIdentityPools/pool/providers/provider",
            "//iam.googleapis.com/projects/123/locations/us-east1/workloadIdentityPools/pool/providers/provider",
            "//iam.googleapis.com/projects/123/locations/global/workforcePools/pool/providers/provider",
            "//iam.googleapis.com/projects/123/locations/global/workloadIdentityPools/../providers/provider",
            "//iam.googleapis.com/projects/123/locations/global/workloadIdentityPools/pool/providers/provider?private",
            "//iam.googleapis.com/projects/123/locations/global/workloadIdentityPools/pool/providers/provider/other",
        ]
    )
    func hostileWorkloadIdentityAudiencesAreRefused(_ audience: String) throws {
        let fixture = try GoogleCloudTraceUploadFixture()
        defer { fixture.clean() }
        let subjectFile = try fixture.privateCredentialFile(
            GoogleCloudTraceUploadFixture.subjectToken,
            named: "hostile-audience-subject-token"
        )
        let credentials = try GoogleCloudTraceUploadFixture.externalAccountCredentials(
            subjectTokenPath: subjectFile.path,
            audience: audience
        )

        #expect(throws: LiveGoogleCloudTraceUpload.Failure.self) {
            try GoogleCloudTraceUploadFixture.authorize(environment: [
                "GOOGLE_APPLICATION_CREDENTIALS_JSON": credentials,
            ])
        }
    }

    @Test(
        "workload federation accepts only the exact RFC8693 JWT subject-token type",
        arguments: [
            "urn:ietf:params:oauth:token-type:access_token",
            "urn:ietf:params:oauth:token-type:id_token",
            "urn:ietf:params:aws:token-type:aws4_request",
            "urn:ietf:params:oauth:token-type:jwt\r\nAuthorization: private",
            "",
        ]
    )
    func unsafeWorkloadIdentityTokenTypesAreRefused(_ tokenType: String) throws {
        let fixture = try GoogleCloudTraceUploadFixture()
        defer { fixture.clean() }
        let subjectFile = try fixture.privateCredentialFile(
            GoogleCloudTraceUploadFixture.subjectToken,
            named: "unsafe-type-subject-token"
        )
        let credentials = try GoogleCloudTraceUploadFixture.externalAccountCredentials(
            subjectTokenPath: subjectFile.path,
            subjectTokenType: tokenType
        )

        #expect(throws: LiveGoogleCloudTraceUpload.Failure.self) {
            try GoogleCloudTraceUploadFixture.authorize(environment: [
                "GOOGLE_APPLICATION_CREDENTIALS_JSON": credentials,
            ])
        }
    }

    @Test(
        "URL, executable, custom-header and AWS-metadata subject-token providers never activate",
        arguments: [
            "url", "headers", "executable", "environment_id", "region_url",
            "regional_cred_verification_url", "cred_verification_url", "imdsv2_session_token_url",
        ]
    )
    func dynamicWorkloadIdentitySubjectSourcesStayFailClosed(_ source: String) throws {
        let fixture = try GoogleCloudTraceUploadFixture()
        defer { fixture.clean() }
        let subjectFile = try fixture.privateCredentialFile(
            GoogleCloudTraceUploadFixture.subjectToken,
            named: "dynamic-source-subject-token"
        )
        let forbidden: Any
        switch source {
        case "headers":
            forbidden = ["Authorization": "PRIVATE_METADATA_AUTHORIZATION"]
        case "executable":
            forbidden = ["command": "/must/never/execute", "output_file": "/must/never/read"]
        case "environment_id":
            forbidden = "aws1"
        default:
            forbidden = "http://169.254.169.254/latest/private-credentials"
        }
        let credentials = try GoogleCloudTraceUploadFixture.externalAccountCredentials(
            subjectTokenPath: subjectFile.path,
            sourceOverrides: [source: forbidden]
        )
        let transport = MockHTTPTransport()

        #expect(throws: LiveGoogleCloudTraceUpload.Failure.self) {
            try GoogleCloudTraceUploadFixture.authorize(environment: [
                "GOOGLE_APPLICATION_CREDENTIALS_JSON": credentials,
            ])
        }
        #expect(transport.recordedRequests.isEmpty)
    }

    @Test(
        "workload federation rejects mixed credentials, impersonation, delegated authority and alternate universes",
        arguments: [
            "client_email", "private_key_id", "private_key", "client_id", "client_secret",
            "refresh_token", "token_uri", "token_info_url", "service_account_impersonation_url",
            "service_account_impersonation", "delegates", "quota_project_id",
            "workforce_pool_user_project", "universe_domain",
        ]
    )
    func delegatedWorkloadIdentityAuthorityCannotBeSmuggled(_ field: String) throws {
        let fixture = try GoogleCloudTraceUploadFixture()
        defer { fixture.clean() }
        let subjectFile = try fixture.privateCredentialFile(
            GoogleCloudTraceUploadFixture.subjectToken,
            named: "delegated-subject-token"
        )
        let forbidden: Any
        switch field {
        case "service_account_impersonation":
            forbidden = ["token_lifetime_seconds": 3600]
        case "delegates":
            forbidden = ["projects/-/serviceAccounts/private@attacker.invalid"]
        case "universe_domain":
            forbidden = "attacker.invalid"
        default:
            forbidden = "PRIVATE_DELEGATED_AUTHORITY"
        }
        let credentials = try GoogleCloudTraceUploadFixture.externalAccountCredentials(
            subjectTokenPath: subjectFile.path,
            documentOverrides: [field: forbidden]
        )
        let transport = MockHTTPTransport()

        #expect(throws: LiveGoogleCloudTraceUpload.Failure.self) {
            try GoogleCloudTraceUploadFixture.authorize(environment: [
                "GOOGLE_APPLICATION_CREDENTIALS_JSON": credentials,
            ])
        }
        #expect(transport.recordedRequests.isEmpty)
    }

    @Test(
        "relative, traversing, missing, oversized and invalid UTF-8 workload JWT files remain private",
        arguments: ["relative", "traversal", "missing", "oversized", "invalid-utf8"]
    )
    func unsafeWorkloadIdentitySubjectFilesFailBeforeExchange(_ scenario: String) throws {
        let fixture = try GoogleCloudTraceUploadFixture()
        defer { fixture.clean() }
        let location = fixture.workspace.appendingPathComponent("unsafe-subject-token")
        let path: String
        switch scenario {
        case "relative":
            path = "relative-subject-token"
        case "traversal":
            path = fixture.workspace.path + "/../outside-subject-token"
        case "missing":
            path = location.path
        case "oversized":
            try SecureFile.write(at: location, contents: Data(repeating: 0x61, count: 65_537))
            path = location.path
        default:
            try SecureFile.write(at: location, contents: Data([0xFF, 0xFE]))
            path = location.path
        }
        let credentials = try GoogleCloudTraceUploadFixture.externalAccountCredentials(
            subjectTokenPath: path
        )
        let transport = MockHTTPTransport()

        #expect(throws: LiveGoogleCloudTraceUpload.Failure.self) {
            try GoogleCloudTraceUploadFixture.authorize(environment: [
                "GOOGLE_APPLICATION_CREDENTIALS_JSON": credentials,
            ])
        }
        #expect(transport.recordedRequests.isEmpty)
    }

    #if !os(Windows)
    @Test(
        "symlinked and group-readable workload JWT files are rejected by their pinned descriptors",
        arguments: ["symlink", "group-readable"]
    )
    func nonPrivateWorkloadIdentitySubjectFilesAreRejected(_ scenario: String) throws {
        let fixture = try GoogleCloudTraceUploadFixture()
        defer { fixture.clean() }
        let target = try fixture.privateCredentialFile(
            GoogleCloudTraceUploadFixture.subjectToken,
            named: "private-subject-target"
        )
        let path: String
        if scenario == "symlink" {
            let link = fixture.workspace.appendingPathComponent("linked-subject-token")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            path = link.path
        } else {
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)
            path = target.path
        }
        let credentials = try GoogleCloudTraceUploadFixture.externalAccountCredentials(
            subjectTokenPath: path
        )

        #expect(throws: LiveGoogleCloudTraceUpload.Failure.self) {
            try GoogleCloudTraceUploadFixture.authorize(environment: [
                "GOOGLE_APPLICATION_CREDENTIALS_JSON": credentials,
            ])
        }
    }
    #endif

    @Test(
        "malformed or oversized JWT subject-token text cannot enter a Google STS exchange",
        arguments: ["empty", "newline", "control", "unicode", "segments", "missing-segment", "oversized"]
    )
    func malformedWorkloadIdentitySubjectTokensAreRefused(_ scenario: String) throws {
        let fixture = try GoogleCloudTraceUploadFixture()
        defer { fixture.clean() }
        let token: String
        switch scenario {
        case "empty": token = ""
        case "newline": token = GoogleCloudTraceUploadFixture.subjectToken + "\n"
        case "control": token = "private.\r\nInjected:token.signature"
        case "unicode": token = "private.令牌.signature"
        case "segments": token = "private.token.signature.other"
        case "missing-segment": token = "private..signature"
        default: token = String(repeating: "a", count: 16_384) + ".private.signature"
        }
        let subjectFile = try fixture.privateCredentialFile(token, named: "malformed-subject-token")
        let credentials = try GoogleCloudTraceUploadFixture.externalAccountCredentials(
            subjectTokenPath: subjectFile.path
        )

        #expect(throws: LiveGoogleCloudTraceUpload.Failure.self) {
            try GoogleCloudTraceUploadFixture.authorize(environment: [
                "GOOGLE_APPLICATION_CREDENTIALS_JSON": credentials,
            ])
        }
    }

    @Test(
        "JSON workload subject files require one safe named JWT field and a supported format",
        arguments: ["missing-field", "wrong-field", "unsafe-field", "non-string", "malformed-json", "text-field", "unknown-format"]
    )
    func malformedWorkloadIdentitySubjectFormatsAreRefused(_ scenario: String) throws {
        let fixture = try GoogleCloudTraceUploadFixture()
        defer { fixture.clean() }
        let contents: String
        switch scenario {
        case "wrong-field": contents = "{\"other\":\"\(GoogleCloudTraceUploadFixture.subjectToken)\"}"
        case "non-string": contents = "{\"assertion\":42}"
        case "malformed-json": contents = "{not-json"
        case "text-field", "unknown-format": contents = GoogleCloudTraceUploadFixture.subjectToken
        default: contents = "{\"assertion\":\"\(GoogleCloudTraceUploadFixture.subjectToken)\"}"
        }
        let subjectFile = try fixture.privateCredentialFile(contents, named: "formatted-subject-token")
        let format = scenario == "text-field" ? "text" : scenario == "unknown-format" ? "yaml" : "json"
        let field: String? = scenario == "missing-field"
            ? nil
            : scenario == "unsafe-field" ? "../assertion" : "assertion"
        let credentials = try GoogleCloudTraceUploadFixture.externalAccountCredentials(
            subjectTokenPath: subjectFile.path,
            format: format,
            subjectTokenField: field
        )

        #expect(throws: LiveGoogleCloudTraceUpload.Failure.self) {
            try GoogleCloudTraceUploadFixture.authorize(environment: [
                "GOOGLE_APPLICATION_CREDENTIALS_JSON": credentials,
            ])
        }
    }

    @Test(
        "rotating a private workload JWT before either request revokes its original authorization",
        arguments: [1, 2]
    )
    func workloadIdentityTokenRotationFailsClosedAtEveryBoundary(_ rotateInvocation: Int) async throws {
        let fixture = try GoogleCloudTraceUploadFixture()
        defer { fixture.clean() }
        let subjectFile = try fixture.privateCredentialFile(
            GoogleCloudTraceUploadFixture.subjectToken,
            named: "rotating-subject-token"
        )
        let credentials = try GoogleCloudTraceUploadFixture.externalAccountCredentials(
            subjectTokenPath: subjectFile.path
        )
        let environment = ["GOOGLE_APPLICATION_CREDENTIALS_JSON": credentials]
        let authorization = try GoogleCloudTraceUploadFixture.authorize(environment: environment)
        let transport = MockHTTPTransport(responses: [
            GoogleCloudTraceUploadFixture.tokenResponse(),
            GoogleCloudTraceUploadFixture.uploadResponse(sessionID: "google-session"),
        ])
        let boundary = GoogleCloudSubjectTokenRotationBoundary(
            path: subjectFile,
            environment: environment,
            rotateInvocation: rotateInvocation
        )

        await #expect(throws: LiveGoogleCloudTraceUpload.Failure.self) {
            try await GoogleCloudTraceUploadFixture.upload(
                authorization: authorization,
                transport: transport,
                authorizeRequest: { try await boundary.authorize() }
            )
        }

        #expect(await boundary.invocationCount == rotateInvocation)
        #expect(transport.recordedRequests.count == rotateInvocation - 1)
        #expect(transport.recordedRequests.allSatisfy { $0.url.host == "sts.googleapis.com" })
    }

    @Test(
        "privacy revocation blocks workload JWT transmission and its later Google archive upload",
        arguments: [1, 2]
    )
    func workloadIdentityPrivacyRevocationRemainsFailClosed(_ revokedInvocation: Int) async throws {
        let fixture = try GoogleCloudTraceUploadFixture()
        defer { fixture.clean() }
        let subjectFile = try fixture.privateCredentialFile(
            GoogleCloudTraceUploadFixture.subjectToken,
            named: "privacy-subject-token"
        )
        let credentials = try GoogleCloudTraceUploadFixture.externalAccountCredentials(
            subjectTokenPath: subjectFile.path
        )
        let authorization = try GoogleCloudTraceUploadFixture.authorize(environment: [
            "GOOGLE_APPLICATION_CREDENTIALS_JSON": credentials,
        ])
        let transport = MockHTTPTransport(responses: [
            GoogleCloudTraceUploadFixture.tokenResponse(),
            GoogleCloudTraceUploadFixture.uploadResponse(sessionID: "google-session"),
        ])
        let boundary = GoogleCloudAuthorizationBoundary(revokedInvocation: revokedInvocation)

        await #expect(throws: LiveGoogleCloudTraceUpload.Failure.self) {
            try await GoogleCloudTraceUploadFixture.upload(
                authorization: authorization,
                transport: transport,
                authorizeRequest: { try await boundary.authorize(authorization) }
            )
        }

        #expect(await boundary.invocationCount == revokedInvocation)
        #expect(transport.recordedRequests.count == revokedInvocation - 1)
        #expect(transport.recordedRequests.allSatisfy { $0.url.host == "sts.googleapis.com" })
    }

    @Test("a redirected Google STS response never forwards the exchanged bearer or the archive")
    func redirectedWorkloadIdentityExchangeFailsBeforeUpload() async throws {
        let fixture = try GoogleCloudTraceUploadFixture()
        defer { fixture.clean() }
        let subjectFile = try fixture.privateCredentialFile(
            GoogleCloudTraceUploadFixture.subjectToken,
            named: "redirected-subject-token"
        )
        let credentials = try GoogleCloudTraceUploadFixture.externalAccountCredentials(
            subjectTokenPath: subjectFile.path
        )
        let authorization = try GoogleCloudTraceUploadFixture.authorize(environment: [
            "GOOGLE_APPLICATION_CREDENTIALS_JSON": credentials,
        ])
        let foreign = try #require(URL(string: "https://attacker.invalid/private-token"))
        let transport = MockHTTPTransport(responses: [
            GoogleCloudTraceUploadFixture.tokenResponse(url: foreign),
            GoogleCloudTraceUploadFixture.uploadResponse(sessionID: "google-session"),
        ])

        await #expect(throws: LiveGoogleCloudTraceUpload.Failure.self) {
            try await GoogleCloudTraceUploadFixture.upload(
                authorization: authorization,
                transport: transport
            )
        }

        #expect(transport.recordedRequests.count == 1)
        #expect(transport.recordedRequests.first?.url.host == "sts.googleapis.com")
    }

    @Test(
        "missing, malformed, partial and externally delegated ADC never open a network endpoint",
        arguments: ["missing", "malformed", "partial", "external-account", "unknown-type"]
    )
    func unsafeCredentialProvidersFailClosed(_ scenario: String) throws {
        let environment: [String: String]
        switch scenario {
        case "missing":
            environment = [:]
        case "malformed":
            environment = ["GOOGLE_APPLICATION_CREDENTIALS_JSON": "{not-valid-json"]
        case "partial":
            environment = ["GOOGLE_APPLICATION_CREDENTIALS_JSON": "{\"type\":\"authorized_user\",\"client_id\":\"partial\"}"]
        case "external-account":
            environment = ["GOOGLE_APPLICATION_CREDENTIALS_JSON": try GoogleCloudTraceUploadFixture.credentials(type: "external_account")]
        default:
            environment = ["GOOGLE_APPLICATION_CREDENTIALS_JSON": try GoogleCloudTraceUploadFixture.credentials(type: "unreviewed_account")]
        }
        let transport = MockHTTPTransport()

        #expect(throws: LiveGoogleCloudTraceUpload.Failure.self) {
            try GoogleCloudTraceUploadFixture.authorize(environment: environment)
        }
        #expect(transport.recordedRequests.isEmpty)
    }

    @Test("malformed service-account signing keys never exchange Google OAuth credentials")
    func malformedServiceAccountSigningKeyNeverReachesNetwork() async throws {
        let credentials = """
        {
          "type": "service_account",
          "client_email": "trace-writer@project.iam.gserviceaccount.com",
          "private_key": "-----BEGIN PRIVATE KEY-----\\nnot-a-private-key\\n-----END PRIVATE KEY-----\\n",
          "token_uri": "https://oauth2.googleapis.com/token"
        }
        """
        let transport = MockHTTPTransport(responses: [
            GoogleCloudTraceUploadFixture.tokenResponse(),
            GoogleCloudTraceUploadFixture.uploadResponse(sessionID: "google-session"),
        ])

        do {
            let authorization = try GoogleCloudTraceUploadFixture.authorize(environment: [
                "GOOGLE_APPLICATION_CREDENTIALS_JSON": credentials,
            ])
            await #expect(throws: LiveGoogleCloudTraceUpload.Failure.self) {
                try await GoogleCloudTraceUploadFixture.upload(
                    authorization: authorization,
                    transport: transport
                )
            }
        } catch is LiveGoogleCloudTraceUpload.Failure {
            #expect(transport.recordedRequests.isEmpty)
        }

        #expect(transport.recordedRequests.isEmpty)
    }

    @Test(
        "forged Google token destinations cannot exfiltrate OAuth client and refresh credentials",
        arguments: [
            "https://oauth2.googleapis.com.attacker.invalid/token",
            "https://attacker.invalid/token",
            "http://oauth2.googleapis.com/token",
            "https://oauth2.googleapis.com/other",
            "https://oauth2.googleapis.com/token?redirect=attacker.invalid",
            "https://oauth2.googleapis.com/token#private",
            "https://private@oauth2.googleapis.com/token",
        ]
    )
    func hostileTokenEndpointsNeverReceiveCredentials(_ tokenURI: String) throws {
        let transport = MockHTTPTransport()

        #expect(throws: LiveGoogleCloudTraceUpload.Failure.self) {
            try GoogleCloudTraceUploadFixture.authorize(environment: [
                "GOOGLE_APPLICATION_CREDENTIALS_JSON": try GoogleCloudTraceUploadFixture.credentials(
                    tokenURI: tokenURI
                ),
            ])
        }
        #expect(transport.recordedRequests.isEmpty)
    }

    @Test(
        "invalid Google buckets fail before credential exchange",
        arguments: [
            "",
            "s3://private-google-bucket",
            "gs://",
            "gs://private-google-bucket/other",
            "gs://private-google-bucket?redirect=attacker.invalid",
            "gs://../private-google-bucket",
            "gs://PRIVATE_GOOGLE_BUCKET",
            "gs://-private-google-bucket",
        ]
    )
    func hostileBucketsFailBeforeNetworkIO(_ bucketURL: String) throws {
        #expect(throws: LiveGoogleCloudTraceUpload.Failure.self) {
            try GoogleCloudTraceUploadFixture.authorize(bucketURL: bucketURL)
        }
    }

    @Test(
        "traversing, encoded and ambiguous session identifiers cannot escape the Google object key",
        arguments: ["", "..", "../private", "private/other", "private\\other", "private%2Fother", "private\r\nother"]
    )
    func hostileSessionIdentifiersFailBeforeNetworkIO(_ sessionID: String) throws {
        #expect(throws: LiveGoogleCloudTraceUpload.Failure.self) {
            try GoogleCloudTraceUploadFixture.authorize(sessionID: sessionID)
        }
    }

    @Test(
        "relative, traversing, oversized and invalid UTF-8 ADC files fail without opening the network",
        arguments: ["relative", "traversal", "oversized", "invalid-utf8"]
    )
    func unsafeCredentialFilesFailClosed(_ scenario: String) throws {
        let fixture = try GoogleCloudTraceUploadFixture()
        defer { fixture.clean() }
        let location = fixture.workspace.appendingPathComponent("unsafe-google-credentials")
        let path: String
        switch scenario {
        case "relative":
            path = "relative-google-credentials.json"
        case "traversal":
            path = fixture.workspace.path + "/../outside-google-credentials.json"
        case "oversized":
            try SecureFile.write(at: location, contents: Data(repeating: 0x61, count: 65_537))
            path = location.path
        default:
            try SecureFile.write(at: location, contents: Data([0xFF, 0xFE]))
            path = location.path
        }

        #expect(throws: LiveGoogleCloudTraceUpload.Failure.self) {
            try GoogleCloudTraceUploadFixture.authorize(environment: [
                "GOOGLE_APPLICATION_CREDENTIALS": path,
            ])
        }
    }

    #if !os(Windows)
    @Test(
        "symlinked or group-readable Google credential files are rejected against their pinned descriptors",
        arguments: ["symlink", "group-readable"]
    )
    func symbolicLinksAndBroadCredentialPermissionsAreRejected(_ scenario: String) throws {
        let fixture = try GoogleCloudTraceUploadFixture()
        defer { fixture.clean() }
        let target = try fixture.privateCredentialFile(GoogleCloudTraceUploadFixture.credentials())
        let path: String
        if scenario == "symlink" {
            let link = fixture.workspace.appendingPathComponent("linked-google-credentials")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            path = link.path
        } else {
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)
            path = target.path
        }

        #expect(throws: LiveGoogleCloudTraceUpload.Failure.self) {
            try GoogleCloudTraceUploadFixture.authorize(environment: [
                "GOOGLE_APPLICATION_CREDENTIALS": path,
            ])
        }
    }
    #endif

    @Test("privacy revocation before Google token exchange sends no request")
    func privacyRevocationBeforeTokenExchangeSendsNothing() async throws {
        let authorization = try GoogleCloudTraceUploadFixture.authorize()
        let transport = MockHTTPTransport(responses: [
            GoogleCloudTraceUploadFixture.tokenResponse(),
            GoogleCloudTraceUploadFixture.uploadResponse(sessionID: "google-session"),
        ])
        let boundary = GoogleCloudAuthorizationBoundary(revokedInvocation: 1)

        await #expect(throws: LiveGoogleCloudTraceUpload.Failure.self) {
            try await GoogleCloudTraceUploadFixture.upload(
                authorization: authorization,
                transport: transport,
                authorizeRequest: { try await boundary.authorize(authorization) }
            )
        }

        #expect(await boundary.invocationCount == 1)
        #expect(transport.recordedRequests.isEmpty)
    }

    @Test("privacy revocation after token exchange prevents archive and Google bearer transmission")
    func privacyRevocationBeforeArchiveUploadSendsNoArchive() async throws {
        let authorization = try GoogleCloudTraceUploadFixture.authorize()
        let transport = MockHTTPTransport(responses: [
            GoogleCloudTraceUploadFixture.tokenResponse(),
            GoogleCloudTraceUploadFixture.uploadResponse(sessionID: "google-session"),
        ])
        let boundary = GoogleCloudAuthorizationBoundary(revokedInvocation: 2)

        await #expect(throws: LiveGoogleCloudTraceUpload.Failure.self) {
            try await GoogleCloudTraceUploadFixture.upload(
                authorization: authorization,
                transport: transport,
                authorizeRequest: { try await boundary.authorize(authorization) }
            )
        }

        #expect(await boundary.invocationCount == 2)
        #expect(transport.recordedRequests.count == 1)
        #expect(transport.recordedRequests.first?.url.host == "oauth2.googleapis.com")
        #expect(transport.recordedRequests.first?.headers["Authorization"] == nil)
    }

    @Test("changed Google destination authority fails closed before exchanging OAuth credentials")
    func changedGoogleAuthorizationFailsBeforeTokenExchange() async throws {
        let original = try GoogleCloudTraceUploadFixture.authorize(sessionID: "original-session")
        let replacement = try GoogleCloudTraceUploadFixture.authorize(sessionID: "replacement-session")
        let transport = MockHTTPTransport(responses: [GoogleCloudTraceUploadFixture.tokenResponse()])

        await #expect(throws: LiveGoogleCloudTraceUpload.Failure.self) {
            try await GoogleCloudTraceUploadFixture.upload(
                sessionID: "original-session",
                authorization: original,
                transport: transport,
                authorizeRequest: { replacement }
            )
        }

        #expect(transport.recordedRequests.isEmpty)
    }

    @Test(
        "rejected or unsafe OAuth token responses never transmit the archive",
        arguments: ["status", "missing", "malformed", "unsafe-token", "foreign-response"]
    )
    func unsafeTokenResponsesNeverTransmitTheArchive(_ scenario: String) async throws {
        let response: MockHTTPTransport.ScriptedResponse
        switch scenario {
        case "status":
            response = GoogleCloudTraceUploadFixture.tokenResponse(status: 401)
        case "missing":
            response = GoogleCloudTraceUploadFixture.tokenResponse(body: "{\"token_type\":\"Bearer\"}")
        case "malformed":
            response = GoogleCloudTraceUploadFixture.tokenResponse(body: "{malformed-token")
        case "unsafe-token":
            response = GoogleCloudTraceUploadFixture.tokenResponse(
                body: "{\"access_token\":\"unsafe\\r\\nInjected: secret\",\"token_type\":\"Bearer\"}"
            )
        default:
            response = GoogleCloudTraceUploadFixture.tokenResponse(
                url: try #require(URL(string: "https://attacker.invalid/private-token"))
            )
        }
        let authorization = try GoogleCloudTraceUploadFixture.authorize()
        let transport = MockHTTPTransport(responses: [
            response,
            GoogleCloudTraceUploadFixture.uploadResponse(sessionID: "google-session"),
        ])

        await #expect(throws: LiveGoogleCloudTraceUpload.Failure.self) {
            try await GoogleCloudTraceUploadFixture.upload(
                authorization: authorization,
                transport: transport
            )
        }

        #expect(transport.recordedRequests.count == 1)
        #expect(transport.recordedRequests.first?.url.host == "oauth2.googleapis.com")
    }

    @Test(
        "rejected, forged, malformed or redirected Google object receipts are never accepted",
        arguments: ["status", "foreign-bucket", "foreign-object", "malformed", "redirected"]
    )
    func unsafeUploadResponsesCannotForgeSuccessfulStorage(_ scenario: String) async throws {
        let response: MockHTTPTransport.ScriptedResponse
        switch scenario {
        case "status":
            response = GoogleCloudTraceUploadFixture.uploadResponse(sessionID: "google-session", status: 403)
        case "foreign-bucket":
            response = GoogleCloudTraceUploadFixture.uploadResponse(
                sessionID: "google-session",
                body: "{\"bucket\":\"attacker-bucket\",\"name\":\"google-session/trace_export.tar.gz\"}"
            )
        case "foreign-object":
            response = GoogleCloudTraceUploadFixture.uploadResponse(
                sessionID: "google-session",
                body: "{\"bucket\":\"private-google-bucket\",\"name\":\"attacker/trace_export.tar.gz\"}"
            )
        case "malformed":
            response = GoogleCloudTraceUploadFixture.uploadResponse(
                sessionID: "google-session",
                body: "{malformed-object"
            )
        default:
            response = GoogleCloudTraceUploadFixture.uploadResponse(
                sessionID: "google-session",
                url: try #require(URL(string: "https://attacker.invalid/private-archive"))
            )
        }
        let authorization = try GoogleCloudTraceUploadFixture.authorize()
        let transport = MockHTTPTransport(responses: [
            GoogleCloudTraceUploadFixture.tokenResponse(),
            response,
        ])

        await #expect(throws: LiveGoogleCloudTraceUpload.Failure.self) {
            try await GoogleCloudTraceUploadFixture.upload(
                authorization: authorization,
                transport: transport
            )
        }

        #expect(transport.recordedRequests.count == 2)
        #expect(transport.recordedRequests.last?.url.host == "storage.googleapis.com")
    }

    @Test("an opted-out first-party account cannot expose a workload JWT through the launched command")
    func optedOutAccountNeverReachesWorkloadIdentityExchange() async throws {
        let fixture = try GoogleCloudTraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed("opted-out-federation")
        let subjectFile = try fixture.privateCredentialFile(
            GoogleCloudTraceUploadFixture.subjectToken,
            named: "opted-out-subject-token"
        )
        let credentials = try GoogleCloudTraceUploadFixture.externalAccountCredentials(
            subjectTokenPath: subjectFile.path
        )
        let account = GrokAuth(
            key: GoogleCloudTraceUploadFixture.xaiToken,
            authMode: .oidc,
            userID: "google-trace-user",
            codingDataRetentionOptOut: true,
            oidcIssuer: "https://auth.x.ai"
        )
        let transport = MockHTTPTransport(responses: [
            GoogleCloudTraceUploadFixture.tokenResponse(),
            GoogleCloudTraceUploadFixture.uploadResponse(sessionID: "opted-out-federation"),
        ])

        let result = await fixture.run(
            "opted-out-federation",
            environment: try fixture.environment(credentials: credentials, auth: account),
            transport: transport
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(transport.recordedRequests.isEmpty)
        #expect(!result.output.contains(GoogleCloudTraceUploadFixture.subjectToken))
        #expect(!result.errors.contains(GoogleCloudTraceUploadFixture.subjectToken))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.home.appendingPathComponent("trace-exports").path
        ))
    }

    @Test("an opted-out first-party account cannot exchange Google credentials through the live command")
    func optedOutAccountNeverReachesGoogleTokenExchange() async throws {
        let fixture = try GoogleCloudTraceUploadFixture()
        defer { fixture.clean() }
        try await fixture.seed("opted-out-google")
        let account = GrokAuth(
            key: GoogleCloudTraceUploadFixture.xaiToken,
            authMode: .oidc,
            userID: "google-trace-user",
            codingDataRetentionOptOut: true,
            oidcIssuer: "https://auth.x.ai"
        )
        let transport = MockHTTPTransport(responses: [
            GoogleCloudTraceUploadFixture.tokenResponse(),
            GoogleCloudTraceUploadFixture.uploadResponse(sessionID: "opted-out-google"),
        ])

        let result = await fixture.run(
            "opted-out-google",
            environment: try fixture.environment(auth: account),
            transport: transport
        )

        #expect(result.status == CLIRunner.ExitCode.failure.rawValue)
        #expect(transport.recordedRequests.isEmpty)
        #expect(!result.output.contains(GoogleCloudTraceUploadFixture.refreshToken))
        #expect(!result.errors.contains(GoogleCloudTraceUploadFixture.refreshToken))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.home.appendingPathComponent("trace-exports").path
        ))
    }
}
