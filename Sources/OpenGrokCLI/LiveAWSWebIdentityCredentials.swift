import Foundation
import OpenGrokFileUtils
import OpenGrokHTTP
import OpenGrokShared

/// `aws-config-1.8.8/src/web_identity_token.rs:18-22,128-146,254-283`.
/// STS explicitly marks this operation unsigned; only the later S3 request
/// receives SigV4 (`aws-sdk-sts-1.88.0/src/config/auth.rs:62-73`).
enum LiveAWSWebIdentityCredentials {
    enum Source: Sendable, Equatable {
        case environment
        case profile(name: String, configurationPath: String?, credentialPath: String?)
    }

    struct Descriptor: Sendable, Equatable {
        let source: Source
        let tokenPath: String
        let token: String
        let roleARN: String
        let sessionName: String
        let partition: String
        let accountID: String
        let roleName: String
    }

    struct TemporaryCredentials: Sendable, Equatable {
        let accessKeyID: String
        let secretAccessKey: String
        let sessionToken: String
        let expiration: Date

        func isUsable(at now: Date = Date()) -> Bool {
            expiration.timeIntervalSince(now) > 30
        }
    }

    private static let maximumTokenFileBytes = 64 * 1024
    private static let maximumTokenBytes = 16 * 1024
    private static let maximumResponseBytes = 64 * 1024
    private static let maximumCredentialLifetime: TimeInterval = 12 * 60 * 60
    private static let requestTimeout: TimeInterval = 60
    private static let defaultSessionName = "web-identity-token-"
        + String(Int64(Date().timeIntervalSince1970 * 1_000))
    private static let defaultProfileSessionName = "web-identity-token-profile-"
        + String(Int64(Date().timeIntervalSince1970 * 1_000))

    static func configurationIsPresent(environment: [String: String]) throws -> Bool {
        let tokenFile = environment["AWS_WEB_IDENTITY_TOKEN_FILE"]
        let roleARN = environment["AWS_ROLE_ARN"]
        guard tokenFile != nil || roleARN != nil else { return false }
        guard let tokenFile, !tokenFile.isEmpty,
              let roleARN, !roleARN.isEmpty
        else {
            throw LiveCloudTraceUpload.Failure.unsupportedCredentialSource
        }
        return true
    }

    static func descriptor(environment: [String: String]) throws -> Descriptor {
        guard try configurationIsPresent(environment: environment),
              let configuredPath = environment["AWS_WEB_IDENTITY_TOKEN_FILE"],
              let roleARN = environment["AWS_ROLE_ARN"]
        else {
            throw LiveCloudTraceUpload.Failure.invalidCredentials
        }
        return try descriptor(
            configuredPath: configuredPath,
            roleARN: roleARN,
            sessionName: environment["AWS_ROLE_SESSION_NAME"] ?? defaultSessionName,
            source: .environment,
            environment: environment
        )
    }

    /// `aws-config-1.8.8/src/profile/credentials/exec.rs:119-139` constructs
    /// profile credentials independently; ambient role and session variables
    /// belong to the later fallback provider and must never override them.
    static func descriptor(
        profile: String,
        tokenFile: String,
        roleARN: String,
        sessionName: String?,
        configurationPath: String?,
        credentialPath: String?,
        environment: [String: String]
    ) throws -> Descriptor {
        try descriptor(
            configuredPath: tokenFile,
            roleARN: roleARN,
            sessionName: sessionName ?? defaultProfileSessionName,
            source: .profile(
                name: profile,
                configurationPath: configurationPath,
                credentialPath: credentialPath
            ),
            environment: environment
        )
    }

    private static func descriptor(
        configuredPath: String,
        roleARN: String,
        sessionName: String,
        source: Source,
        environment: [String: String]
    ) throws -> Descriptor {
        guard !configuredPath.isEmpty,
              configuredPath == configuredPath.trimmingCharacters(in: .whitespacesAndNewlines),
              roleARN == roleARN.trimmingCharacters(in: .whitespacesAndNewlines),
              let role = validatedRole(roleARN)
        else {
            throw LiveCloudTraceUpload.Failure.invalidCredentials
        }

        guard validSessionName(sessionName) else {
            throw LiveCloudTraceUpload.Failure.invalidCredentials
        }

        let tokenPath = try resolvedTokenPath(configuredPath, environment: environment)
        let tokenBytes: Data
        do {
            tokenBytes = try PathSecurity.readNoFollow(
                URL(fileURLWithPath: tokenPath),
                maximumBytes: maximumTokenFileBytes,
                requireOwnerOnly: true
            )
        } catch {
            throw LiveCloudTraceUpload.Failure.invalidCredentials
        }
        guard let token = String(data: tokenBytes, encoding: .utf8),
              validJWT(token)
        else {
            throw LiveCloudTraceUpload.Failure.invalidCredentials
        }

        return Descriptor(
            source: source,
            tokenPath: tokenPath,
            token: token,
            roleARN: roleARN,
            sessionName: sessionName,
            partition: role.partition,
            accountID: role.accountID,
            roleName: role.roleName
        )
    }

    static func validateRegion(_ region: String, descriptor: Descriptor) throws {
        let expectedPartition: String
        if region.hasPrefix("cn-") {
            expectedPartition = "aws-cn"
        } else if region.hasPrefix("us-gov-") {
            expectedPartition = "aws-us-gov"
        } else {
            expectedPartition = "aws"
        }
        guard descriptor.partition == expectedPartition else {
            throw LiveCloudTraceUpload.Failure.invalidCredentials
        }
    }

    static func exchange(
        descriptor: Descriptor,
        region: String,
        transport: any HTTPTransport,
        now: Date = Date(),
        testEndpoint: URL? = nil
    ) async throws -> TemporaryCredentials {
        try validateRegion(region, descriptor: descriptor)
        let endpoint = try endpoint(region: region, override: testEndpoint)
        let fields = [
            ("Action", "AssumeRoleWithWebIdentity"),
            ("Version", "2011-06-15"),
            ("RoleArn", descriptor.roleARN),
            ("RoleSessionName", descriptor.sessionName),
            ("WebIdentityToken", descriptor.token),
        ]
        let body = fields.map { FormURLEncoding.encode([$0.0: $0.1]) }
            .joined(separator: "&")
        let request = HTTPRequest(
            method: .post,
            url: endpoint,
            headers: [
                "Accept": "application/xml",
                "Content-Type": "application/x-www-form-urlencoded",
            ],
            body: Data(body.utf8),
            timeout: requestTimeout
        )

        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HTTPError {
            if case .cancelled = error { throw CancellationError() }
            throw LiveCloudTraceUpload.Failure.credentialExchangeTransport
        } catch {
            throw LiveCloudTraceUpload.Failure.credentialExchangeTransport
        }

        guard response.metadata.url == nil || response.metadata.url == endpoint else {
            throw LiveCloudTraceUpload.Failure.invalidEndpoint
        }
        guard (200..<300).contains(response.metadata.statusCode) else {
            throw LiveCloudTraceUpload.Failure.credentialExchangeRejected(
                response.metadata.statusCode
            )
        }
        return try temporaryCredentials(from: response.body, descriptor: descriptor, now: now)
    }

    private static func endpoint(region: String, override: URL?) throws -> URL {
        if let override {
            guard let components = URLComponents(url: override, resolvingAgainstBaseURL: false),
                  components.scheme == "http" || components.scheme == "https",
                  components.host == "127.0.0.1" || components.host == "::1"
                    || components.host == "[::1]",
                  components.port.map({ (1...65_535).contains($0) }) == true,
                  components.user == nil,
                  components.password == nil,
                  components.query == nil,
                  components.fragment == nil,
                  components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/"
            else {
                throw LiveCloudTraceUpload.Failure.invalidEndpoint
            }
            return override
        }

        let suffix = region.hasPrefix("cn-") ? "amazonaws.com.cn" : "amazonaws.com"
        var components = URLComponents()
        components.scheme = "https"
        components.host = "sts.\(region).\(suffix)"
        components.path = "/"
        guard let endpoint = components.url else {
            throw LiveCloudTraceUpload.Failure.invalidEndpoint
        }
        return endpoint
    }

    private static func temporaryCredentials(
        from data: Data,
        descriptor: Descriptor,
        now: Date
    ) throws -> TemporaryCredentials {
        guard !data.isEmpty,
              data.count <= maximumResponseBytes,
              let original = String(data: data, encoding: .utf8),
              !original.contains("<!"),
              !original.utf8.contains(where: {
                  $0 < 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D
              })
        else {
            throw LiveCloudTraceUpload.Failure.invalidCredentialResponse
        }

        var document = original.trimmingCharacters(in: .whitespacesAndNewlines)
        if document.hasPrefix("<?xml") {
            guard let declaration = document.range(of: "?>") else {
                throw LiveCloudTraceUpload.Failure.invalidCredentialResponse
            }
            document = String(document[declaration.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let rootName = "AssumeRoleWithWebIdentityResponse"
        let opening = "<\(rootName)"
        let closing = "</\(rootName)>"
        guard document.hasPrefix(opening),
              document.hasSuffix(closing),
              document.range(of: closing)?.upperBound == document.endIndex,
              let start = document.firstIndex(of: ">")
        else {
            throw LiveCloudTraceUpload.Failure.invalidCredentialResponse
        }
        let nameBoundary = document.index(document.startIndex, offsetBy: opening.count)
        guard nameBoundary < document.endIndex,
              document[nameBoundary] == ">" || document[nameBoundary].isWhitespace
        else {
            throw LiveCloudTraceUpload.Failure.invalidCredentialResponse
        }
        let bodyEnd = document.index(document.endIndex, offsetBy: -closing.count)
        let root = String(document[document.index(after: start)..<bodyEnd])
        let result = try requiredElement("AssumeRoleWithWebIdentityResult", in: root)
        let credentials = try requiredElement("Credentials", in: result)
        let assumedRole = try requiredElement("AssumedRoleUser", in: result)
        let assumedARN = try requiredElement("Arn", in: assumedRole)
        guard validAssumedRole(assumedARN, descriptor: descriptor) else {
            throw LiveCloudTraceUpload.Failure.invalidCredentialResponse
        }

        let accessKeyID = try requiredElement("AccessKeyId", in: credentials)
        let secretAccessKey = try requiredElement("SecretAccessKey", in: credentials)
        let sessionToken = try requiredElement("SessionToken", in: credentials)
        let expirationValue = try requiredElement("Expiration", in: credentials)
        guard (4...128).contains(accessKeyID.utf8.count),
              accessKeyID.hasPrefix("ASIA"),
              accessKeyID.utf8.allSatisfy(isASCIIAlphanumeric),
              validCredential(secretAccessKey, maximumBytes: 1_024),
              validCredential(sessionToken, maximumBytes: maximumTokenBytes),
              let expiration = parseExpiration(expirationValue),
              expiration.timeIntervalSince(now) > 30,
              expiration.timeIntervalSince(now) <= maximumCredentialLifetime + 60
        else {
            throw LiveCloudTraceUpload.Failure.invalidCredentialResponse
        }

        return TemporaryCredentials(
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey,
            sessionToken: sessionToken,
            expiration: expiration
        )
    }

    private static func requiredElement(_ name: String, in document: String) throws -> String {
        let opening = "<\(name)>"
        let closing = "</\(name)>"
        guard let start = document.range(of: opening),
              let end = document.range(of: closing, range: start.upperBound..<document.endIndex),
              document.range(of: opening, range: end.upperBound..<document.endIndex) == nil
        else {
            throw LiveCloudTraceUpload.Failure.invalidCredentialResponse
        }
        return String(document[start.upperBound..<end.lowerBound])
    }

    private static func parseExpiration(_ value: String) -> Date? {
        guard value.utf8.count <= 64 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func resolvedTokenPath(
        _ configured: String,
        environment: [String: String]
    ) throws -> String {
        var path = configured
        if path.hasPrefix("~/") || path.hasPrefix("~\\") {
            guard let home = environment["HOME"] ?? environment["USERPROFILE"],
                  (home as NSString).isAbsolutePath
            else {
                throw LiveCloudTraceUpload.Failure.invalidCredentials
            }
            let relative = String(path.dropFirst(2))
            do {
                try PathSecurity.rejectHostileLexical(home)
                try PathSecurity.rejectHostileLexical(relative)
            } catch {
                throw LiveCloudTraceUpload.Failure.invalidCredentials
            }
            path = URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(relative, isDirectory: false)
                .path
        }
        guard (path as NSString).isAbsolutePath else {
            throw LiveCloudTraceUpload.Failure.invalidCredentials
        }
        do {
            try PathSecurity.rejectHostileLexical(path)
        } catch {
            throw LiveCloudTraceUpload.Failure.invalidCredentials
        }
        return path
    }

    private static func validatedRole(
        _ value: String
    ) -> (partition: String, accountID: String, roleName: String)? {
        guard value.utf8.count <= 512 else { return nil }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6,
              parts[0] == "arn",
              ["aws", "aws-cn", "aws-us-gov"].contains(String(parts[1])),
              parts[2] == "iam",
              parts[3].isEmpty,
              parts[4].utf8.count == 12,
              parts[4].utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              parts[5].hasPrefix("role/")
        else {
            return nil
        }
        let resource = parts[5].dropFirst("role/".count)
        let segments = resource.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.isEmpty,
              segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".."
                  && $0.utf8.allSatisfy(isRoleCharacter) }),
              let roleName = segments.last
        else {
            return nil
        }
        return (String(parts[1]), String(parts[4]), String(roleName))
    }

    private static func validAssumedRole(_ value: String, descriptor: Descriptor) -> Bool {
        let expected = "arn:\(descriptor.partition):sts::\(descriptor.accountID):assumed-role/"
            + "\(descriptor.roleName)/\(descriptor.sessionName)"
        return value == expected
    }

    private static func validSessionName(_ value: String) -> Bool {
        (2...64).contains(value.utf8.count)
            && value.utf8.allSatisfy(isRoleCharacter)
    }

    private static func validJWT(_ value: String) -> Bool {
        guard value.utf8.count <= maximumTokenBytes else { return false }
        let segments = value.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, segments.allSatisfy({ !$0.isEmpty }) else { return false }
        return segments.allSatisfy { segment in
            segment.utf8.allSatisfy {
                isASCIIAlphanumeric($0) || $0 == 0x2D || $0 == 0x5F
            }
        }
    }

    private static func validCredential(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes
            && value.utf8.allSatisfy { (0x21...0x7E).contains($0)
                && $0 != 0x3C && $0 != 0x3E && $0 != 0x26 }
    }

    private static func isRoleCharacter(_ value: UInt8) -> Bool {
        isASCIIAlphanumeric(value) || [0x2B, 0x3D, 0x2C, 0x2E, 0x40, 0x2D, 0x5F].contains(value)
    }

    private static func isASCIIAlphanumeric(_ value: UInt8) -> Bool {
        (0x41...0x5A).contains(value)
            || (0x61...0x7A).contains(value)
            || (0x30...0x39).contains(value)
    }
}
