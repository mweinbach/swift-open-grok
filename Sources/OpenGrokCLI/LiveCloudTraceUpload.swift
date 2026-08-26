import Foundation
import OpenGrokConfig
import OpenGrokFileUtils
import OpenGrokHTTP
import OpenGrokShared

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Rust: `xai-grok-shell/src/agent/config.rs:507-550` and
/// `xai-file-utils/src/s3.rs:34-121` at `00e176c8`.
enum LiveCloudTraceUpload {
    struct Authorization: Sendable, Equatable {
        let endpoint: URL
        let bucket: String
        let region: String
        let accessKeyID: String?
        let secretAccessKey: String?
        let sessionToken: String?
        let webIdentity: LiveAWSWebIdentityCredentials.Descriptor?

        init(
            endpoint: URL,
            bucket: String,
            region: String,
            accessKeyID: String,
            secretAccessKey: String,
            sessionToken: String?
        ) {
            self.endpoint = endpoint
            self.bucket = bucket
            self.region = region
            self.accessKeyID = accessKeyID
            self.secretAccessKey = secretAccessKey
            self.sessionToken = sessionToken
            self.webIdentity = nil
        }

        init(
            endpoint: URL,
            bucket: String,
            region: String,
            webIdentity: LiveAWSWebIdentityCredentials.Descriptor
        ) {
            self.endpoint = endpoint
            self.bucket = bucket
            self.region = region
            self.accessKeyID = nil
            self.secretAccessKey = nil
            self.sessionToken = nil
            self.webIdentity = webIdentity
        }
    }

    enum Failure: Error, Sendable, Equatable {
        case unsupportedCredentialSource
        case missingCredentials
        case invalidCredentials
        case invalidBucket
        case invalidRegion
        case invalidEndpoint
        case invalidSession
        case archiveTooLarge
        case invalidMultipartRequest
        case invalidMultipartResponse
        case invalidMultipartUploadID
        case invalidMultipartETag
        case multipartRejected(Int)
        case multipartTransport
        case credentialExchangeRejected(Int)
        case credentialExchangeTransport
        case invalidCredentialResponse
        case authorizationChanged

        var message: String {
            switch self {
            case .unsupportedCredentialSource:
                return "Direct S3 trace upload only supports managed static, environment, private shared-profile, or file-backed AWS web-identity credentials."
            case .missingCredentials:
                return "Direct S3 trace upload requires scoped managed, environment, private shared-profile, or file-backed web-identity AWS credentials."
            case .invalidCredentials:
                return "Direct S3 trace upload rejected malformed AWS credentials."
            case .invalidBucket:
                return "Direct S3 trace upload requires a safe, dot-free AWS bucket name."
            case .invalidRegion:
                return "Direct S3 trace upload requires a supported AWS region."
            case .invalidEndpoint:
                return "Direct S3 trace upload requires the AWS regional endpoint or an exact loopback test endpoint."
            case .invalidSession:
                return "Direct S3 trace upload requires a safe session identifier."
            case .archiveTooLarge:
                return "Direct S3 trace upload exceeds its bounded multipart archive or part limits."
            case .invalidMultipartRequest:
                return "Direct S3 trace upload rejected an unsafe multipart request."
            case .invalidMultipartResponse:
                return "Direct S3 trace upload received an unsafe or malformed multipart response."
            case .invalidMultipartUploadID:
                return "Direct S3 trace upload received an unsafe or missing multipart upload identifier."
            case .invalidMultipartETag:
                return "Direct S3 trace upload received an unsafe or missing multipart part ETag."
            case .multipartRejected(let status):
                return "S3 storage rejected the multipart upload (HTTP \(status))."
            case .multipartTransport:
                return "Direct S3 multipart trace upload could not complete its request safely."
            case .credentialExchangeRejected(let status):
                return "AWS STS rejected the trace upload web-identity credentials (HTTP \(status))."
            case .credentialExchangeTransport:
                return "Direct S3 trace upload could not safely exchange AWS web-identity credentials."
            case .invalidCredentialResponse:
                return "AWS STS returned invalid, expired, or mismatched temporary trace upload credentials."
            case .authorizationChanged:
                return "Direct S3 trace upload authorization changed before a credential or storage request."
            }
        }
    }

    static let maximumArchiveBytes = 8 * 1024 * 1024

    private static let maximumCredentialFileBytes = 64 * 1024
    private static let requestTimeout: TimeInterval = 60
    private static let hexadecimalDigits = Array("0123456789ABCDEF".utf8)
    private static let unsupportedCredentialEnvironmentKeys: Set<String> = [
        "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI",
        "AWS_CONTAINER_CREDENTIALS_FULL_URI",
        "AWS_CONTAINER_AUTHORIZATION_TOKEN",
        "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE",
        "AWS_EC2_METADATA_SERVICE_ENDPOINT",
        "AWS_EC2_METADATA_SERVICE_ENDPOINT_MODE",
    ]
    private static let unsupportedCredentialProfileKeys: Set<String> = [
        "credential_process",
        "credential_source",
        "duration_seconds",
        "external_id",
        "mfa_serial",
        "role_arn",
        "role_session_name",
        "source_profile",
        "web_identity_token_file",
        "sso_session",
        "sso_start_url",
        "sso_region",
        "sso_account_id",
        "sso_role_name",
    ]

    static func authorize(
        sessionID: String,
        bucketURL: String,
        document: TOMLValue,
        environment: [String: String]
    ) throws -> Authorization {
        guard isValidSessionID(sessionID) else {
            throw Failure.invalidSession
        }

        let bucket = try bucketName(from: bucketURL)

        let credentials = try resolveCredentials(document: document, environment: environment)
        if case .staticKeys(let accessKeyID, let secretAccessKey, let sessionToken) = credentials {
            guard isValidAccessKeyID(accessKeyID),
                  isValidCredential(secretAccessKey),
                  sessionToken.map(isValidCredential) ?? true
            else {
                throw Failure.invalidCredentials
            }
        }

        let region = configured(environment["GROK_TRACE_UPLOAD_REGION"])
            ?? configured(document[path: ["endpoints", "trace_upload_region"]]?.stringValue)
            ?? configured(environment["AWS_REGION"])
            ?? configured(environment["AWS_DEFAULT_REGION"])
            ?? "us-east-1"
        guard isValidRegion(region) else {
            throw Failure.invalidRegion
        }

        let customEndpoint = configured(environment["GROK_TRACE_UPLOAD_ENDPOINT_URL"])
            ?? configured(document[path: ["endpoints", "trace_upload_endpoint_url"]]?.stringValue)

        let endpoint: URL
        if let customEndpoint {
            var components = try loopbackEndpoint(customEndpoint)
            components.percentEncodedPath = percentEncodePath(
                "/\(bucket)/\(sessionID)/trace_export.tar.gz"
            )
            guard let resolved = components.url else {
                throw Failure.invalidEndpoint
            }
            endpoint = resolved
        } else {
            var components = URLComponents()
            components.scheme = "https"
            components.host = regionalHost(bucket: bucket, region: region)
            components.percentEncodedPath = percentEncodePath(
                "/\(sessionID)/trace_export.tar.gz"
            )
            guard let resolved = components.url else {
                throw Failure.invalidEndpoint
            }
            endpoint = resolved
        }

        switch credentials {
        case .staticKeys(let accessKeyID, let secretAccessKey, let sessionToken):
            return Authorization(
                endpoint: endpoint,
                bucket: bucket,
                region: region,
                accessKeyID: accessKeyID,
                secretAccessKey: secretAccessKey,
                sessionToken: sessionToken
            )
        case .webIdentity(let descriptor):
            try LiveAWSWebIdentityCredentials.validateRegion(region, descriptor: descriptor)
            return Authorization(
                endpoint: endpoint,
                bucket: bucket,
                region: region,
                webIdentity: descriptor
            )
        }
    }

    private enum ResolvedCredentials {
        case staticKeys(accessKeyID: String, secretAccessKey: String, sessionToken: String?)
        case webIdentity(LiveAWSWebIdentityCredentials.Descriptor)

        init(_ values: (accessKeyID: String, secretAccessKey: String, sessionToken: String?)) {
            self = .staticKeys(
                accessKeyID: values.accessKeyID,
                secretAccessKey: values.secretAccessKey,
                sessionToken: values.sessionToken
            )
        }
    }

    private enum SharedProfileFileKind {
        case configuration
        case credentials
    }

    private struct SharedProfile {
        let path: String?
        let exists: Bool
        let selected: Bool
        let values: [String: String]
    }

    /// Rust `agent/config.rs:507-550` supplies managed inline credentials before
    /// managed files; `xai-file-utils/src/s3.rs:39-90,121-147` selects those
    /// static JSON/INI credentials before the ambient AWS provider chain.
    /// `aws-config-1.8.8/src/default_provider/credentials.rs:183-193` then
    /// orders environment, merged profile and environment web-identity providers.
    private static func resolveCredentials(
        document: TOMLValue,
        environment: [String: String]
    ) throws -> ResolvedCredentials {
        if let inline = configured(environment["GROK_TRACE_UPLOAD_CREDENTIALS"])
            ?? configured(document[path: ["endpoints", "trace_upload_credentials"]]?.stringValue)
        {
            guard !inline.isEmpty, inline.utf8.count <= maximumCredentialFileBytes else {
                throw Failure.invalidCredentials
            }
            return try ResolvedCredentials(parseManagedCredentials(Data(inline.utf8)))
        }

        if let path = configured(environment["GROK_TRACE_UPLOAD_CREDENTIALS_FILE"])
            ?? configured(document[path: ["endpoints", "trace_upload_credentials_file"]]?.stringValue)
        {
            return try ResolvedCredentials(parseManagedCredentials(
                managedCredentialData(at: path, environment: environment)
            ))
        }

        let environmentKey = environment["AWS_ACCESS_KEY_ID"]
        let primaryEnvironmentSecret = environment["AWS_SECRET_ACCESS_KEY"]
        let fallbackEnvironmentSecret = environment["SECRET_ACCESS_KEY"]
        let environmentSecret: String?
        if let primaryEnvironmentSecret,
           !primaryEnvironmentSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            environmentSecret = primaryEnvironmentSecret
        } else {
            environmentSecret = fallbackEnvironmentSecret
        }
        if environmentKey != nil || primaryEnvironmentSecret != nil
            || fallbackEnvironmentSecret != nil || environment["AWS_SESSION_TOKEN"] != nil {
            guard let environmentKey, !environmentKey.isEmpty,
                  let environmentSecret, !environmentSecret.isEmpty
            else {
                throw Failure.missingCredentials
            }
            return .staticKeys(
                accessKeyID: environmentKey,
                secretAccessKey: environmentSecret,
                sessionToken: environment["AWS_SESSION_TOKEN"]
            )
        }

        if unsupportedCredentialEnvironmentKeys.contains(where: {
            configured(environment[$0]) != nil
        }) {
            throw Failure.unsupportedCredentialSource
        }

        let explicitlySelectedProfile = configured(environment["AWS_PROFILE"])
            ?? configured(environment["AWS_DEFAULT_PROFILE"])
        let profile = explicitlySelectedProfile ?? "default"
        guard isValidProfile(profile) else {
            throw Failure.invalidCredentials
        }

        let configuration = try sharedProfile(
            kind: .configuration,
            profile: profile,
            environment: environment
        )
        let credentials = try sharedProfile(
            kind: .credentials,
            profile: profile,
            environment: environment
        )
        var values = configuration.values
        values.merge(credentials.values) { _, credentialValue in credentialValue }

        let webIdentityKeys: Set<String> = [
            "role_arn",
            "role_session_name",
            "web_identity_token_file",
        ]
        if values.keys.contains(where: {
            unsupportedCredentialProfileKeys.contains($0) && !webIdentityKeys.contains($0)
        }) {
            throw Failure.unsupportedCredentialSource
        }

        let staticKeys: Set<String> = [
            "aws_access_key_id",
            "aws_secret_access_key",
            "aws_session_token",
        ]
        let hasStaticKeys = values.keys.contains(where: staticKeys.contains)
        let hasWebIdentityKeys = values.keys.contains(where: webIdentityKeys.contains)

        if hasWebIdentityKeys {
            guard !hasStaticKeys,
                  let roleARN = values["role_arn"],
                  let tokenFile = values["web_identity_token_file"]
            else {
                throw Failure.unsupportedCredentialSource
            }
            return .webIdentity(try LiveAWSWebIdentityCredentials.descriptor(
                profile: profile,
                tokenFile: tokenFile,
                roleARN: roleARN,
                sessionName: values["role_session_name"],
                configurationPath: configuration.exists ? configuration.path : nil,
                credentialPath: credentials.exists ? credentials.path : nil,
                environment: environment
            ))
        }

        // Keep the pre-existing strict rejection of partial ambient identity
        // settings for static profiles; complete profile providers above own
        // their authority and never consult ambient role or session values.
        let webIdentityConfigured = try LiveAWSWebIdentityCredentials.configurationIsPresent(
            environment: environment
        )
        if hasStaticKeys {
            guard let accessKeyID = values["aws_access_key_id"],
                  let secretAccessKey = values["aws_secret_access_key"]
            else {
                throw Failure.missingCredentials
            }
            return .staticKeys(
                accessKeyID: accessKeyID,
                secretAccessKey: secretAccessKey,
                sessionToken: values["aws_session_token"]
            )
        }

        if credentials.selected
            || (explicitlySelectedProfile != nil
                && (configuration.exists || credentials.exists)
                && !configuration.selected
                && !credentials.selected)
        {
            throw Failure.missingCredentials
        }
        if webIdentityConfigured {
            return .webIdentity(try LiveAWSWebIdentityCredentials.descriptor(
                environment: environment
            ))
        }
        throw Failure.missingCredentials
    }

    private static func managedCredentialData(
        at configuredPath: String,
        environment: [String: String]
    ) throws -> Data {
        var path = configuredPath
        if path.hasPrefix("~/") || path.hasPrefix("~\\") {
            let suffix = String(path.dropFirst(2))
            do {
                try PathSecurity.rejectHostileLexical(suffix)
            } catch {
                throw Failure.invalidCredentials
            }
            path = URL(fileURLWithPath: try sharedCredentialHome(environment: environment), isDirectory: true)
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
                maximumBytes: maximumCredentialFileBytes,
                requireOwnerOnly: true
            )
        } catch let error as FileUtilsError {
            if case .notFound = error { throw Failure.missingCredentials }
            throw Failure.invalidCredentials
        } catch {
            throw Failure.invalidCredentials
        }
    }

    private static func parseManagedCredentials(
        _ data: Data
    ) throws -> (accessKeyID: String, secretAccessKey: String, sessionToken: String?) {
        guard !data.isEmpty,
              data.count <= maximumCredentialFileBytes,
              let content = String(data: data, encoding: .utf8)
        else {
            throw Failure.invalidCredentials
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.invalidCredentials }

        let values: [String: String]
        if trimmed.hasPrefix("{") {
            values = try parseManagedJSONCredentials(Array(trimmed.utf8))
        } else {
            values = try parseManagedINICredentials(trimmed)
        }

        guard let accessKeyID = values["aws_access_key_id"],
              let secretAccessKey = values["aws_secret_access_key"]
        else {
            throw Failure.missingCredentials
        }
        return (accessKeyID, secretAccessKey, values["aws_session_token"])
    }

    private static func parseManagedJSONCredentials(_ bytes: [UInt8]) throws -> [String: String] {
        var offset = 0
        skipJSONWhitespace(bytes, offset: &offset)
        guard offset < bytes.count, bytes[offset] == 0x7B else {
            throw Failure.invalidCredentials
        }
        offset += 1

        var values: [String: String] = [:]
        skipJSONWhitespace(bytes, offset: &offset)
        if offset < bytes.count, bytes[offset] == 0x7D {
            offset += 1
        } else {
            while true {
                let key = try managedJSONString(bytes, offset: &offset)
                skipJSONWhitespace(bytes, offset: &offset)
                guard offset < bytes.count, bytes[offset] == 0x3A else {
                    throw Failure.invalidCredentials
                }
                offset += 1
                skipJSONWhitespace(bytes, offset: &offset)
                let value = try managedJSONString(bytes, offset: &offset)
                try insertManagedCredential(key, value: value, into: &values)
                skipJSONWhitespace(bytes, offset: &offset)
                guard offset < bytes.count else { throw Failure.invalidCredentials }
                if bytes[offset] == 0x7D {
                    offset += 1
                    break
                }
                guard bytes[offset] == 0x2C else { throw Failure.invalidCredentials }
                offset += 1
                skipJSONWhitespace(bytes, offset: &offset)
            }
        }

        skipJSONWhitespace(bytes, offset: &offset)
        guard offset == bytes.count else { throw Failure.invalidCredentials }
        return values
    }

    private static func managedJSONString(_ bytes: [UInt8], offset: inout Int) throws -> String {
        guard offset < bytes.count, bytes[offset] == 0x22 else {
            throw Failure.invalidCredentials
        }
        let start = offset
        offset += 1
        var escaped = false
        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1
            if escaped {
                escaped = false
            } else if byte == 0x5C {
                escaped = true
            } else if byte == 0x22 {
                do {
                    return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset]))
                } catch {
                    throw Failure.invalidCredentials
                }
            }
        }
        throw Failure.invalidCredentials
    }

    private static func skipJSONWhitespace(_ bytes: [UInt8], offset: inout Int) {
        while offset < bytes.count {
            switch bytes[offset] {
            case 0x09, 0x0A, 0x0D, 0x20:
                offset += 1
            default:
                return
            }
        }
    }

    private static func parseManagedINICredentials(_ content: String) throws -> [String: String] {
        var values: [String: String] = [:]
        var foundSection = false

        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else {
                continue
            }

            if line.hasPrefix("[") {
                guard line.hasSuffix("]"), !foundSection, values.isEmpty else {
                    throw Failure.invalidCredentials
                }
                let section = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard isValidProfile(section) else { throw Failure.invalidCredentials }
                foundSection = true
                continue
            }

            guard let separator = line.firstIndex(of: "=") else {
                throw Failure.invalidCredentials
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = line[line.index(after: separator)...]
            let value = rawValue.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try insertManagedCredential(key, value: value, into: &values)
        }

        return values
    }

    private static func insertManagedCredential(
        _ key: String,
        value: String,
        into values: inout [String: String]
    ) throws {
        guard !unsupportedCredentialProfileKeys.contains(key) else {
            throw Failure.unsupportedCredentialSource
        }
        guard key == "aws_access_key_id"
            || key == "aws_secret_access_key"
            || key == "aws_session_token"
        else {
            throw Failure.invalidCredentials
        }
        guard !value.isEmpty, values.updateValue(value, forKey: key) == nil else {
            throw Failure.invalidCredentials
        }
    }

    private static func sharedCredentialHome(environment: [String: String]) throws -> String {
        guard let home = configured(environment["HOME"])
            ?? configured(environment["USERPROFILE"]),
            (home as NSString).isAbsolutePath
        else {
            throw Failure.invalidCredentials
        }
        do {
            try PathSecurity.rejectHostileLexical(home)
        } catch {
            throw Failure.invalidCredentials
        }
        return home
    }

    private static func sharedProfile(
        kind: SharedProfileFileKind,
        profile: String,
        environment: [String: String]
    ) throws -> SharedProfile {
        let environmentKey: String
        let filename: String
        switch kind {
        case .configuration:
            environmentKey = "AWS_CONFIG_FILE"
            filename = "config"
        case .credentials:
            environmentKey = "AWS_SHARED_CREDENTIALS_FILE"
            filename = "credentials"
        }

        let path: String
        if let configuredPath = configured(environment[environmentKey]) {
            if configuredPath.hasPrefix("~/") || configuredPath.hasPrefix("~\\") {
                let relativePath = String(configuredPath.dropFirst(2))
                do {
                    try PathSecurity.rejectHostileLexical(relativePath)
                } catch {
                    throw Failure.invalidCredentials
                }
                path = URL(fileURLWithPath: try sharedCredentialHome(environment: environment), isDirectory: true)
                    .appendingPathComponent(relativePath, isDirectory: false)
                    .path
            } else {
                path = configuredPath
            }
        } else if configured(environment["HOME"]) != nil
            || configured(environment["USERPROFILE"]) != nil
        {
            path = URL(fileURLWithPath: try sharedCredentialHome(environment: environment), isDirectory: true)
                .appendingPathComponent(".aws", isDirectory: true)
                .appendingPathComponent(filename, isDirectory: false)
                .path
        } else {
            return SharedProfile(path: nil, exists: false, selected: false, values: [:])
        }

        guard (path as NSString).isAbsolutePath else {
            throw Failure.invalidCredentials
        }
        let bytes: Data
        do {
            try PathSecurity.rejectHostileLexical(path)
            bytes = try PathSecurity.readNoFollow(
                URL(fileURLWithPath: path),
                maximumBytes: maximumCredentialFileBytes,
                requireOwnerOnly: true
            )
        } catch let error as FileUtilsError {
            if case .notFound = error {
                return SharedProfile(path: path, exists: false, selected: false, values: [:])
            }
            throw Failure.invalidCredentials
        } catch {
            throw Failure.invalidCredentials
        }
        guard let content = String(data: bytes, encoding: .utf8) else {
            throw Failure.invalidCredentials
        }
        return try parseSharedProfile(content, kind: kind, profile: profile, path: path)
    }

    private static func parseSharedProfile(
        _ content: String,
        kind: SharedProfileFileKind,
        profile: String,
        path: String
    ) throws -> SharedProfile {
        var selectedRank: Int?
        var selectedSections: Set<Int> = []
        var valuesByRank: [Int: [String: String]] = [:]
        let credentialKeys: Set<String> = [
            "aws_access_key_id",
            "aws_secret_access_key",
            "aws_session_token",
        ]

        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else {
                continue
            }

            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else {
                    throw Failure.invalidCredentials
                }
                let section = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                switch kind {
                case .credentials:
                    selectedRank = section == profile ? 0 : nil
                case .configuration:
                    if section == "profile \(profile)" {
                        selectedRank = 1
                    } else if profile == "default", section == "default" {
                        selectedRank = 0
                    } else {
                        selectedRank = nil
                    }
                }
                if let selectedRank,
                   !selectedSections.insert(selectedRank).inserted
                {
                    throw Failure.invalidCredentials
                }
                continue
            }

            guard let selectedRank else { continue }
            guard let separator = line.firstIndex(of: "=") else {
                throw Failure.invalidCredentials
            }

            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            guard unsupportedCredentialProfileKeys.contains(key)
                || credentialKeys.contains(key)
            else {
                continue
            }

            let rawValue = line[line.index(after: separator)...]
            let value = rawValue.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var values = valuesByRank[selectedRank] ?? [:]
            guard !value.isEmpty, values.updateValue(value, forKey: key) == nil else {
                throw Failure.invalidCredentials
            }
            valuesByRank[selectedRank] = values
        }

        let highestRank = selectedSections.max()
        return SharedProfile(
            path: path,
            exists: true,
            selected: highestRank != nil,
            values: highestRank.flatMap { valuesByRank[$0] } ?? [:]
        )
    }

    private static func isValidProfile(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 128 else { return false }
        return bytes.allSatisfy {
            isASCIIAlphanumeric($0)
                || $0 == 0x2d
                || $0 == 0x2e
                || $0 == 0x5f
                || $0 == 0x40
                || $0 == 0x2b
                || $0 == 0x3d
                || $0 == 0x2c
        }
    }

    static func request(
        authorization: Authorization,
        archive: Data,
        now: Date = Date()
    ) throws -> HTTPRequest {
        guard archive.count < maximumArchiveBytes else {
            throw Failure.archiveTooLarge
        }
        return try signedRequest(
            authorization: authorization,
            method: .put,
            query: [],
            body: archive,
            contentType: "application/gzip",
            now: now
        )
    }

    static func signedRequest(
        authorization: Authorization,
        method: HTTPMethod,
        query: [(name: String, value: String)],
        body: Data,
        contentType: String,
        now: Date = Date(),
        timeout: TimeInterval? = nil
    ) throws -> HTTPRequest {
        guard isValidBucket(authorization.bucket),
              isValidRegion(authorization.region),
              authorization.webIdentity == nil,
              let accessKeyID = authorization.accessKeyID,
              let secretAccessKey = authorization.secretAccessKey,
              isValidAccessKeyID(accessKeyID),
              isValidCredential(secretAccessKey),
              authorization.sessionToken.map(isValidCredential) ?? true
        else {
            throw Failure.invalidCredentials
        }
        guard contentType == "application/gzip" || contentType == "application/xml" else {
            throw Failure.invalidMultipartRequest
        }

        var components = try validatedEndpoint(authorization)
        let canonicalQuery = try canonicalQueryString(method: method, query: query)
        if !canonicalQuery.isEmpty {
            components.percentEncodedQuery = canonicalQuery
        }
        guard let requestURL = components.url,
              URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.percentEncodedQuery
                == (canonicalQuery.isEmpty ? nil : canonicalQuery)
        else {
            throw Failure.invalidMultipartRequest
        }

        let payloadHash = SHA256.hexDigest(body)
        let timestampFormatter = DateFormatter()
        timestampFormatter.locale = Locale(identifier: "en_US_POSIX")
        timestampFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        timestampFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = timestampFormatter.string(from: now)
        let date = String(timestamp.prefix(8))

        guard let host = components.host else {
            throw Failure.invalidEndpoint
        }
        let enclosedHost = host.contains(":") && !host.hasPrefix("[")
            ? "[\(host)]"
            : host
        let hostHeader = components.port.map { "\(enclosedHost):\($0)" } ?? enclosedHost

        var headers = [
            "Content-Type": contentType,
            "Host": hostHeader,
            "X-Amz-Content-Sha256": payloadHash,
            "X-Amz-Date": timestamp,
        ]
        if let sessionToken = authorization.sessionToken {
            headers["X-Amz-Security-Token"] = sessionToken
        }

        let orderedHeaders = headers
            .map { ($0.key.lowercased(), $0.value) }
            .sorted { $0.0 < $1.0 }
        let canonicalHeaders = orderedHeaders
            .map { "\($0.0):\($0.1)\n" }
            .joined()
        let signedHeaders = orderedHeaders
            .map(\.0)
            .joined(separator: ";")
        let canonicalRequest = [
            method.rawValue,
            components.percentEncodedPath,
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let credentialScope = "\(date)/\(authorization.region)/s3/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            timestamp,
            credentialScope,
            SHA256.hexDigest(canonicalRequest),
        ].joined(separator: "\n")

        let dateKey = hmacSHA256(
            key: Array("AWS4\(secretAccessKey)".utf8),
            message: Array(date.utf8)
        )
        let regionKey = hmacSHA256(key: dateKey, message: Array(authorization.region.utf8))
        let serviceKey = hmacSHA256(key: regionKey, message: Array("s3".utf8))
        let signingKey = hmacSHA256(key: serviceKey, message: Array("aws4_request".utf8))
        let signature = hmacSHA256(key: signingKey, message: Array(stringToSign.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        headers["Authorization"] = "AWS4-HMAC-SHA256 "
            + "Credential=\(accessKeyID)/\(credentialScope), "
            + "SignedHeaders=\(signedHeaders), "
            + "Signature=\(signature)"

        return HTTPRequest(
            method: method,
            url: requestURL,
            headers: headers,
            body: body,
            timeout: timeout ?? requestTimeout
        )
    }

    private static func canonicalQueryString(
        method: HTTPMethod,
        query: [(name: String, value: String)]
    ) throws -> String {
        if query.isEmpty {
            guard method == .put else { throw Failure.invalidMultipartRequest }
            return ""
        }

        let names = Set(query.map(\.name))
        guard names.count == query.count else { throw Failure.invalidMultipartRequest }

        switch method {
        case .post:
            guard names == ["uploads"] || names == ["uploadId"] else {
                throw Failure.invalidMultipartRequest
            }
        case .put:
            guard names == ["partNumber", "uploadId"] else {
                throw Failure.invalidMultipartRequest
            }
        case .delete:
            guard names == ["uploadId"] else { throw Failure.invalidMultipartRequest }
        default:
            throw Failure.invalidMultipartRequest
        }

        for item in query {
            switch item.name {
            case "uploads":
                guard item.value.isEmpty else { throw Failure.invalidMultipartRequest }
            case "partNumber":
                guard let number = Int(item.value), (1...10_000).contains(number),
                      String(number) == item.value
                else {
                    throw Failure.invalidMultipartRequest
                }
            case "uploadId":
                guard validMultipartUploadID(item.value) else {
                    throw Failure.invalidMultipartUploadID
                }
            default:
                throw Failure.invalidMultipartRequest
            }
        }

        let encoded: [(name: String, value: String)] = query.map { item in
            (
                name: percentEncodeQueryComponent(item.name),
                value: percentEncodeQueryComponent(item.value)
            )
        }
        let sorted = encoded.sorted { lhs, rhs in
            if lhs.name == rhs.name {
                return lhs.value < rhs.value
            }
            return lhs.name < rhs.name
        }
        let parameters = sorted.map { item in
            "\(item.name)=\(item.value)"
        }
        return parameters.joined(separator: "&")
    }

    static func validMultipartUploadID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 2_048 else { return false }
        return bytes.allSatisfy {
            isASCIIAlphanumeric($0)
                || $0 == 0x2d
                || $0 == 0x2e
                || $0 == 0x5f
                || $0 == 0x7e
                || $0 == 0x2b
                || $0 == 0x2f
                || $0 == 0x3d
        }
    }

    private static func percentEncodeQueryComponent(_ value: String) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            if isASCIIAlphanumeric(byte)
                || byte == 0x2d
                || byte == 0x2e
                || byte == 0x5f
                || byte == 0x7e
            {
                bytes.append(byte)
            } else {
                bytes.append(0x25)
                bytes.append(hexadecimalDigits[Int(byte >> 4)])
                bytes.append(hexadecimalDigits[Int(byte & 0x0f)])
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func resultURL(authorization: Authorization, sessionID: String) -> String {
        "s3://\(authorization.bucket)/\(sessionID)/trace_export.tar.gz"
    }

    static func makeProductionTransport(
        configuration: HTTPTransportConfiguration = HTTPTransportConfiguration()
    ) -> any HTTPTransport {
        #if os(Linux) || os(Windows)
        if !configuration.tls.extraRootCertificates.isEmpty {
            return URLSessionHTTPTransport(configuration: configuration)
        }
        #endif
        let session = URLSession(
            configuration: HTTPSessionConfigurationBuilder.makeEphemeral(configuration),
            delegate: LiveCloudTraceUploadSessionDelegate(configuration: configuration),
            delegateQueue: nil
        )
        return URLSessionHTTPTransport(configuration: configuration, session: session)
    }

    static func hmacSHA256(key: Data, data: Data) -> Data {
        Data(hmacSHA256(key: Array(key), message: Array(data)))
    }

    static func hmacSHA256(key: [UInt8], message: [UInt8]) -> [UInt8] {
        let blockLength = 64
        var paddedKey = key.count > blockLength ? SHA256.hash(key) : key
        paddedKey.append(contentsOf: repeatElement(0, count: blockLength - paddedKey.count))

        let innerKey = paddedKey.map { $0 ^ 0x36 }
        let outerKey = paddedKey.map { $0 ^ 0x5c }
        let innerDigest = SHA256.hash(innerKey + message)
        return SHA256.hash(outerKey + innerDigest)
    }

    static func percentEncodePath(_ path: String) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(path.utf8.count)

        for byte in path.utf8 {
            if isASCIIAlphanumeric(byte)
                || byte == 0x2d
                || byte == 0x2e
                || byte == 0x2f
                || byte == 0x5f
                || byte == 0x7e
            {
                bytes.append(byte)
            } else {
                bytes.append(0x25)
                bytes.append(hexadecimalDigits[Int(byte >> 4)])
                bytes.append(hexadecimalDigits[Int(byte & 0x0f)])
            }
        }

        return String(decoding: bytes, as: UTF8.self)
    }

    private static func configured(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func bucketName(from bucketURL: String) throws -> String {
        let normalized = bucketURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix("s3://") else {
            throw Failure.invalidBucket
        }

        var bucket = String(normalized.dropFirst(5))
        while bucket.hasSuffix("/") {
            bucket.removeLast()
        }
        guard isValidBucket(bucket) else {
            throw Failure.invalidBucket
        }
        return bucket
    }

    private static func isValidBucket(_ bucket: String) -> Bool {
        let bytes = Array(bucket.utf8)
        guard (3...63).contains(bytes.count),
              let first = bytes.first,
              let last = bytes.last,
              isASCIILowercaseOrDigit(first),
              isASCIILowercaseOrDigit(last)
        else {
            return false
        }

        return bytes.allSatisfy { isASCIILowercaseOrDigit($0) || $0 == 0x2d }
    }

    private static func isValidRegion(_ region: String) -> Bool {
        let components = region.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 3 || components.count == 4,
              components.first?.utf8.count == 2,
              components.first?.utf8.allSatisfy(isASCIILowercase) == true,
              let number = components.last,
              (1...3).contains(number.utf8.count),
              number.utf8.first != 0x30,
              number.utf8.allSatisfy(isASCIIDigit)
        else {
            return false
        }

        if components.count == 4,
           !(components[0] == "us" && components[1] == "gov")
        {
            return false
        }

        let geography = components[components.count - 2]
        return !geography.isEmpty && geography.utf8.allSatisfy(isASCIILowercase)
    }

    private static func isValidSessionID(_ sessionID: String) -> Bool {
        let bytes = Array(sessionID.utf8)
        guard !bytes.isEmpty,
              bytes.count <= 128,
              sessionID != ".",
              sessionID != ".."
        else {
            return false
        }

        return bytes.allSatisfy {
            isASCIIAlphanumeric($0) || $0 == 0x2d || $0 == 0x2e || $0 == 0x5f
        }
    }

    private static func isValidAccessKeyID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy(isASCIIAlphanumeric)
    }

    private static func isValidCredential(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (0x21...0x7e).contains($0) }
    }

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        isASCIIDigit(byte) || isASCIILowercase(byte) || (0x41...0x5a).contains(byte)
    }

    private static func isASCIILowercaseOrDigit(_ byte: UInt8) -> Bool {
        isASCIILowercase(byte) || isASCIIDigit(byte)
    }

    private static func isASCIILowercase(_ byte: UInt8) -> Bool {
        (0x61...0x7a).contains(byte)
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
    }

    private static func regionalHost(bucket: String, region: String) -> String {
        let suffix = region.hasPrefix("cn-") ? "amazonaws.com.cn" : "amazonaws.com"
        return "\(bucket).s3.\(region).\(suffix)"
    }

    private static func loopbackEndpoint(_ value: String) throws -> URLComponents {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              host == "127.0.0.1" || host == "::1" || host == "[::1]",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
              components.port.map({ (1...65535).contains($0) }) ?? true,
              let schemeSeparator = value.range(of: "://")
        else {
            throw Failure.invalidEndpoint
        }

        let remainder = value[schemeSeparator.upperBound...]
        let authority = remainder.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        let literalHost = host == "127.0.0.1" ? host : "[::1]"
        let expectedAuthority = components.port.map { "\(literalHost):\($0)" } ?? literalHost
        guard authority == expectedAuthority else {
            throw Failure.invalidEndpoint
        }

        return components
    }

    private static func validatedEndpoint(_ authorization: Authorization) throws -> URLComponents {
        guard let components = URLComponents(
            url: authorization.endpoint,
            resolvingAgainstBaseURL: false
        ),
            let scheme = components.scheme?.lowercased(),
            let host = components.host,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.port.map({ (1...65535).contains($0) }) ?? true
        else {
            throw Failure.invalidEndpoint
        }

        let path = components.percentEncodedPath
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let sessionID: String
        if host == regionalHost(bucket: authorization.bucket, region: authorization.region) {
            guard scheme == "https", components.port == nil,
                  parts.count == 3, parts[0].isEmpty,
                  parts[2] == "trace_export.tar.gz"
            else {
                throw Failure.invalidEndpoint
            }
            sessionID = String(parts[1])
        } else {
            guard scheme == "http" || scheme == "https",
                  host == "127.0.0.1" || host == "::1" || host == "[::1]",
                  parts.count == 4, parts[0].isEmpty,
                  parts[1] == authorization.bucket,
                  parts[3] == "trace_export.tar.gz"
            else {
                throw Failure.invalidEndpoint
            }
            sessionID = String(parts[2])
        }

        guard isValidSessionID(sessionID) else {
            throw Failure.invalidSession
        }
        return components
    }
}

private final class LiveCloudTraceUploadSessionDelegate:
    NSObject, URLSessionTaskDelegate, @unchecked Sendable
{
    private let trustDelegate: HTTPTransportSessionDelegate

    init(configuration: HTTPTransportConfiguration) {
        trustDelegate = HTTPTransportSessionDelegate(
            validateCertificates: configuration.tls.validateCertificates,
            extraRootCertificates: configuration.tls.extraRootCertificates
        )
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        trustDelegate.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
