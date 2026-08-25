import Foundation
import OpenGrokConfig
import OpenGrokFileUtils
import OpenGrokHTTP
import OpenGrokShared

/// Rust: `xai-file-utils/src/gcs.rs:101-135,488-510,549-575` and its pinned
/// `gcloud-auth-1.3.0` credential/token sources at Rust commit `00e176c8`.
enum LiveGoogleCloudTraceUpload {
    struct Authorization: Sendable, Equatable {
        let endpoint: URL
        let bucket: String
        let objectPath: String
        let tokenEndpoint: URL
        fileprivate let credentials: Credentials
    }

    enum Failure: Error, Sendable, Equatable {
        case unsupportedCredentialSource
        case missingCredentials
        case invalidCredentials
        case invalidBucket
        case invalidEndpoint
        case invalidSession
        case archiveTooLarge
        case authorizationChanged
        case signingFailed
        case tokenRejected(Int)
        case malformedToken
        case uploadRejected(Int)
        case malformedUploadResponse
        case transport

        var message: String {
            switch self {
            case .unsupportedCredentialSource:
                return "Direct Google Cloud trace upload only supports private service-account or authorized-user credentials."
            case .missingCredentials:
                return "Direct Google Cloud trace upload requires scoped private Google Application Default Credentials."
            case .invalidCredentials:
                return "Direct Google Cloud trace upload rejected malformed or non-private Google credentials."
            case .invalidBucket:
                return "Direct Google Cloud trace upload requires a safe Google Cloud Storage bucket name."
            case .invalidEndpoint:
                return "Direct Google Cloud trace upload requires pinned Google endpoints or one exact loopback test origin."
            case .invalidSession:
                return "Direct Google Cloud trace upload requires a safe session identifier."
            case .archiveTooLarge:
                return "Direct Google Cloud trace upload exceeds its bounded archive size."
            case .authorizationChanged:
                return "Direct Google Cloud trace upload authorization changed before a credential or upload request."
            case .signingFailed:
                return "Direct Google Cloud trace upload could not securely sign its service-account assertion."
            case .tokenRejected(let status):
                return "Google OAuth rejected the trace upload credentials (HTTP \(status))."
            case .malformedToken:
                return "Google OAuth returned an invalid or unsafe access token."
            case .uploadRejected(let status):
                return "Google Cloud Storage rejected the trace upload (HTTP \(status))."
            case .malformedUploadResponse:
                return "Google Cloud Storage returned an unsafe or unexpected upload response."
            case .transport:
                return "Direct Google Cloud trace upload could not complete its request safely."
            }
        }
    }

    fileprivate enum Credentials: Sendable, Equatable {
        case serviceAccount(email: String, keyID: String?, privateKey: String)
        case authorizedUser(clientID: String, clientSecret: String, refreshToken: String)
    }

    private struct CredentialDocument: Decodable {
        let type: String
        let client_email: String?
        let private_key_id: String?
        let private_key: String?
        let client_id: String?
        let client_secret: String?
        let refresh_token: String?
        let token_uri: String?
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let token_type: String
        let expires_in: Int?
    }

    private struct UploadResponse: Decodable {
        let bucket: String
        let name: String
    }

    private struct ServiceAccountHeader: Encodable {
        let alg = "RS256"
        let typ = "JWT"
        let kid: String?
    }

    private struct ServiceAccountClaims: Encodable {
        let iss: String
        let scope: String
        let aud: String
        let exp: Int64
        let iat: Int64
    }

    private struct AuthorizedUserTokenRequest: Encodable {
        let client_id: String
        let client_secret: String
        let grant_type = "refresh_token"
        let refresh_token: String
    }

    static let storageScopes = "https://www.googleapis.com/auth/cloud-platform "
        + "https://www.googleapis.com/auth/devstorage.full_control"

    private static let googleTokenURL = "https://oauth2.googleapis.com/token"
    private static let googleStorageHost = "storage.googleapis.com"
    private static let maximumCredentialBytes = 64 * 1024
    private static let maximumArchiveBytes = 64 * 1024 * 1024
    private static let maximumResponseBytes = 64 * 1024
    private static let maximumTokenBytes = 16 * 1024
    private static let maximumAttempts = 4
    private static let requestTimeout: TimeInterval = 60
    private static let retryableStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]

    static func authorize(
        sessionID: String,
        bucketURL: String,
        document: TOMLValue,
        environment: [String: String]
    ) throws -> Authorization {
        guard validSession(sessionID) else { throw Failure.invalidSession }
        let bucket = try bucketName(from: bucketURL)
        let credentialsData = try credentialBytes(document: document, environment: environment)
        let credential: CredentialDocument
        do {
            credential = try JSONDecoder().decode(CredentialDocument.self, from: credentialsData)
        } catch {
            throw Failure.invalidCredentials
        }

        let credentials = try validatedCredentials(credential)
        let testOrigin = try loopbackOrigin(document: document, environment: environment)
        let tokenEndpoint = try tokenEndpoint(for: credential.token_uri, testOrigin: testOrigin)
        let objectPath = "\(sessionID)/trace_export.tar.gz"
        let endpoint = try storageEndpoint(
            bucket: bucket,
            objectPath: objectPath,
            testOrigin: testOrigin
        )

        return Authorization(
            endpoint: endpoint,
            bucket: bucket,
            objectPath: objectPath,
            tokenEndpoint: tokenEndpoint,
            credentials: credentials
        )
    }

    static func upload(
        sessionID: String,
        archive: Data,
        authorization: Authorization,
        transport: any HTTPTransport,
        authorizeRequest: @escaping @Sendable () async throws -> Authorization,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) async throws -> String {
        guard validSession(sessionID),
              authorization.objectPath == "\(sessionID)/trace_export.tar.gz"
        else {
            throw Failure.invalidSession
        }
        guard !archive.isEmpty, archive.count <= maximumArchiveBytes else {
            throw Failure.archiveTooLarge
        }

        for attempt in 0..<maximumAttempts {
            try Task.checkCancellation()
            guard try await authorizeRequest() == authorization else {
                throw Failure.authorizationChanged
            }

            let accessToken: String
            do {
                accessToken = try await token(for: authorization, transport: transport)
            } catch let failure as Failure {
                if case .tokenRejected(let status) = failure,
                   retryableStatusCodes.contains(status),
                   attempt + 1 < maximumAttempts {
                    try await sleep(pow(2, Double(attempt)))
                    continue
                }
                throw failure
            }

            try Task.checkCancellation()
            guard try await authorizeRequest() == authorization else {
                throw Failure.authorizationChanged
            }

            let request = HTTPRequest(
                method: .post,
                url: authorization.endpoint,
                headers: [
                    "Accept": "application/json",
                    "Authorization": "Bearer \(accessToken)",
                    "Content-Type": "application/gzip",
                ],
                body: archive,
                timeout: requestTimeout
            )

            let response = try await send(request, using: transport)
            guard response.metadata.url == nil || response.metadata.url == authorization.endpoint else {
                throw Failure.invalidEndpoint
            }
            let status = response.metadata.statusCode
            guard (200..<300).contains(status) else {
                if retryableStatusCodes.contains(status), attempt + 1 < maximumAttempts {
                    try await sleep(pow(2, Double(attempt)))
                    continue
                }
                throw Failure.uploadRejected(status)
            }

            guard response.body.count <= maximumResponseBytes,
                  let object = try? JSONDecoder().decode(UploadResponse.self, from: response.body),
                  object.bucket == authorization.bucket,
                  object.name == authorization.objectPath
            else {
                throw Failure.malformedUploadResponse
            }
            return "gs://\(authorization.bucket)/\(authorization.objectPath)"
        }

        throw Failure.transport
    }

    static func serviceAccountAssertion(
        authorization: Authorization,
        now: Date = Date()
    ) throws -> String {
        guard case .serviceAccount(let email, let keyID, let privateKey) = authorization.credentials else {
            throw Failure.invalidCredentials
        }

        let issuedAt = Int64(now.timeIntervalSince1970)
        let header = ServiceAccountHeader(kid: keyID)
        let claims = ServiceAccountClaims(
            iss: email,
            scope: storageScopes,
            aud: authorization.tokenEndpoint.absoluteString,
            exp: issuedAt + 3600,
            iat: issuedAt
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encodedHeader = try encoder.encode(header)
        let encodedClaims = try encoder.encode(claims)
        let signingInput = Base64URL.encode(encodedHeader) + "." + Base64URL.encode(encodedClaims)

        let signature: Data
        do {
            signature = try LiveGoogleCloudServiceAccountSigner.sign(
                Data(signingInput.utf8),
                privateKeyPEM: privateKey
            )
        } catch {
            throw Failure.signingFailed
        }
        return signingInput + "." + Base64URL.encode(signature)
    }

    private static func token(
        for authorization: Authorization,
        transport: any HTTPTransport
    ) async throws -> String {
        let requestBody: Data
        let contentType: String
        switch authorization.credentials {
        case .serviceAccount:
            let assertion = try serviceAccountAssertion(authorization: authorization)
            requestBody = FormURLEncoding.encodeData([
                "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
                "assertion": assertion,
            ])
            contentType = "application/x-www-form-urlencoded"
        case .authorizedUser(let clientID, let clientSecret, let refreshToken):
            requestBody = try JSONEncoder().encode(
                AuthorizedUserTokenRequest(
                    client_id: clientID,
                    client_secret: clientSecret,
                    refresh_token: refreshToken
                )
            )
            contentType = "application/json"
        }

        let request = HTTPRequest(
            method: .post,
            url: authorization.tokenEndpoint,
            headers: ["Accept": "application/json", "Content-Type": contentType],
            body: requestBody,
            timeout: requestTimeout
        )
        let response = try await send(request, using: transport)
        guard response.metadata.url == nil || response.metadata.url == authorization.tokenEndpoint else {
            throw Failure.invalidEndpoint
        }
        guard (200..<300).contains(response.metadata.statusCode) else {
            throw Failure.tokenRejected(response.metadata.statusCode)
        }
        guard response.body.count <= maximumResponseBytes,
              let token = try? JSONDecoder().decode(TokenResponse.self, from: response.body),
              token.token_type.caseInsensitiveCompare("Bearer") == .orderedSame,
              token.expires_in.map({ $0 > 0 && $0 <= 86_400 }) ?? true,
              validAccessToken(token.access_token)
        else {
            throw Failure.malformedToken
        }
        return token.access_token
    }

    private static func send(
        _ request: HTTPRequest,
        using transport: any HTTPTransport
    ) async throws -> HTTPResponse {
        do {
            return try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HTTPError {
            if case .cancelled = error { throw CancellationError() }
            throw Failure.transport
        } catch {
            throw Failure.transport
        }
    }

    private static func credentialBytes(
        document: TOMLValue,
        environment: [String: String]
    ) throws -> Data {
        if let inline = configured(environment["GROK_TRACE_UPLOAD_CREDENTIALS"])
            ?? configured(document[path: ["endpoints", "trace_upload_credentials"]]?.stringValue)
            ?? configured(document[path: ["endpoints", "gcs_service_account_key"]]?.stringValue) {
            return try inlineCredentialData(inline, allowBase64: false)
        }

        if let configuredFile = configured(environment["GROK_TRACE_UPLOAD_CREDENTIALS_FILE"])
            ?? configured(document[path: ["endpoints", "trace_upload_credentials_file"]]?.stringValue) {
            return try privateCredentialData(at: configuredFile, environment: environment)
        }

        if let inlineADC = configured(environment["GOOGLE_APPLICATION_CREDENTIALS_JSON"]) {
            return try inlineCredentialData(inlineADC, allowBase64: true)
        }

        if let configuredADC = configured(environment["GOOGLE_APPLICATION_CREDENTIALS"]) {
            return try privateCredentialData(at: configuredADC, environment: environment)
        }

        #if os(Windows)
        guard let home = configured(environment["APPDATA"]) else {
            throw Failure.missingCredentials
        }
        try validateCredentialHome(home)
        let location = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("gcloud", isDirectory: true)
            .appendingPathComponent("application_default_credentials.json", isDirectory: false)
        #else
        guard let home = configured(environment["HOME"]) else {
            throw Failure.missingCredentials
        }
        try validateCredentialHome(home)
        let location = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("gcloud", isDirectory: true)
            .appendingPathComponent("application_default_credentials.json", isDirectory: false)
        #endif

        return try privateCredentialData(at: location.path, environment: environment)
    }

    private static func inlineCredentialData(_ value: String, allowBase64: Bool) throws -> Data {
        guard value.utf8.count <= maximumCredentialBytes * 2 else {
            throw Failure.invalidCredentials
        }
        let data: Data
        if allowBase64, !value.hasPrefix("{"), let decoded = Data(base64Encoded: value) {
            data = decoded
        } else {
            data = Data(value.utf8)
        }
        guard !data.isEmpty, data.count <= maximumCredentialBytes else {
            throw Failure.invalidCredentials
        }
        return data
    }

    private static func privateCredentialData(
        at configuredPath: String,
        environment: [String: String]
    ) throws -> Data {
        var path = configuredPath
        if path.hasPrefix("~/") || path.hasPrefix("~\\") {
            guard let home = configured(environment["HOME"])
                ?? configured(environment["USERPROFILE"])
            else {
                throw Failure.invalidCredentials
            }
            let suffix = String(path.dropFirst(2))
            try validateCredentialHome(home)
            do {
                try PathSecurity.rejectHostileLexical(suffix)
            } catch {
                throw Failure.invalidCredentials
            }
            path = URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(suffix, isDirectory: false)
                .path
        }

        guard (path as NSString).isAbsolutePath else {
            throw Failure.invalidCredentials
        }
        do {
            try PathSecurity.rejectHostileLexical(path)
            return try PathSecurity.readNoFollow(
                URL(fileURLWithPath: path),
                maximumBytes: maximumCredentialBytes,
                requireOwnerOnly: true
            )
        } catch let error as FileUtilsError {
            if case .notFound = error { throw Failure.missingCredentials }
            throw Failure.invalidCredentials
        } catch {
            throw Failure.invalidCredentials
        }
    }

    private static func validateCredentialHome(_ path: String) throws {
        guard (path as NSString).isAbsolutePath else {
            throw Failure.invalidCredentials
        }
        do {
            try PathSecurity.rejectHostileLexical(path)
        } catch {
            throw Failure.invalidCredentials
        }
    }

    private static func validatedCredentials(_ document: CredentialDocument) throws -> Credentials {
        switch document.type {
        case "service_account":
            guard let email = configured(document.client_email),
                  email.utf8.count <= 320,
                  email.split(separator: "@").count == 2,
                  validVisibleCredential(email),
                  let privateKey = document.private_key,
                  privateKey.utf8.count <= maximumCredentialBytes,
                  privateKey.contains("-----BEGIN PRIVATE KEY-----"),
                  privateKey.contains("-----END PRIVATE KEY-----")
            else {
                throw Failure.invalidCredentials
            }
            if let keyID = document.private_key_id,
               keyID.utf8.count > 256 || !validVisibleCredential(keyID) {
                throw Failure.invalidCredentials
            }
            return .serviceAccount(
                email: email,
                keyID: document.private_key_id,
                privateKey: privateKey
            )
        case "authorized_user":
            guard let clientID = configured(document.client_id),
                  let clientSecret = configured(document.client_secret),
                  let refreshToken = configured(document.refresh_token),
                  [clientID, clientSecret, refreshToken].allSatisfy(validVisibleCredential)
            else {
                throw Failure.invalidCredentials
            }
            return .authorizedUser(
                clientID: clientID,
                clientSecret: clientSecret,
                refreshToken: refreshToken
            )
        default:
            throw Failure.unsupportedCredentialSource
        }
    }

    private static func tokenEndpoint(for configuredURL: String?, testOrigin: URL?) throws -> URL {
        guard let production = URL(string: googleTokenURL) else {
            throw Failure.invalidEndpoint
        }

        if let testOrigin {
            let local = testOrigin.appendingPathComponent("token", isDirectory: false)
            if let value = configured(configuredURL),
               value != googleTokenURL,
               value != local.absoluteString {
                throw Failure.invalidEndpoint
            }
            return local
        }

        if let value = configured(configuredURL), value != googleTokenURL {
            throw Failure.invalidEndpoint
        }
        return production
    }

    private static func storageEndpoint(
        bucket: String,
        objectPath: String,
        testOrigin: URL?
    ) throws -> URL {
        var components: URLComponents
        if let testOrigin, let local = URLComponents(url: testOrigin, resolvingAgainstBaseURL: false) {
            components = local
        } else {
            components = URLComponents()
            components.scheme = "https"
            components.host = googleStorageHost
        }
        components.percentEncodedPath = "/upload/storage/v1/b/\(bucket)/o"
        components.percentEncodedQuery = "uploadType=media&name=\(percentEncode(objectPath))"
        guard let endpoint = components.url else { throw Failure.invalidEndpoint }
        return endpoint
    }

    private static func loopbackOrigin(
        document: TOMLValue,
        environment: [String: String]
    ) throws -> URL? {
        guard let raw = configured(environment["GROK_TRACE_UPLOAD_ENDPOINT_URL"])
            ?? configured(document[path: ["endpoints", "trace_upload_endpoint_url"]]?.stringValue)
        else {
            return nil
        }

        guard let components = URLComponents(string: raw),
              components.scheme == "http" || components.scheme == "https",
              components.host == "127.0.0.1" || components.host == "::1"
                || components.host == "[::1]",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let port = components.port,
              (1...65_535).contains(port),
              let url = components.url
        else {
            throw Failure.invalidEndpoint
        }
        return url
    }

    private static func bucketName(from value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix("gs://") else { throw Failure.invalidBucket }
        var bucket = String(normalized.dropFirst(5))
        while bucket.hasSuffix("/") { bucket.removeLast() }
        let bytes = Array(bucket.utf8)
        guard (3...222).contains(bytes.count),
              let first = bytes.first,
              let last = bytes.last,
              lowercaseOrDigit(first),
              lowercaseOrDigit(last),
              !bucket.contains(".."),
              bytes.allSatisfy({ lowercaseOrDigit($0) || $0 == 0x2D || $0 == 0x2E || $0 == 0x5F }),
              bucket.split(separator: ".").allSatisfy({ (1...63).contains($0.utf8.count) })
        else {
            throw Failure.invalidBucket
        }
        return bucket
    }

    private static func validSession(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 128, value != ".", value != ".." else {
            return false
        }
        return bytes.allSatisfy {
            ($0 >= 0x41 && $0 <= 0x5A)
                || lowercaseOrDigit($0)
                || $0 == 0x2D
                || $0 == 0x2E
                || $0 == 0x5F
        }
    }

    private static func validVisibleCredential(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumCredentialBytes
            && value.utf8.allSatisfy { (0x21...0x7E).contains($0) }
    }

    private static func validAccessToken(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumTokenBytes else { return false }
        return bytes.allSatisfy {
            ($0 >= 0x41 && $0 <= 0x5A)
                || lowercaseOrDigit($0)
                || [0x2D, 0x2E, 0x5F, 0x7E, 0x2B, 0x2F, 0x3D].contains($0)
        }
    }

    private static func percentEncode(_ value: String) -> String {
        let alphabet = Array("0123456789ABCDEF".utf8)
        var result: [UInt8] = []
        result.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            if (byte >= 0x41 && byte <= 0x5A)
                || lowercaseOrDigit(byte)
                || byte == 0x2D
                || byte == 0x2E
                || byte == 0x5F
                || byte == 0x7E {
                result.append(byte)
            } else {
                result.append(0x25)
                result.append(alphabet[Int(byte >> 4)])
                result.append(alphabet[Int(byte & 0x0F)])
            }
        }
        return String(decoding: result, as: UTF8.self)
    }

    private static func lowercaseOrDigit(_ byte: UInt8) -> Bool {
        (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
    }

    private static func configured(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
