import Foundation
import OpenGrokConfig
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
        let accessKeyID: String
        let secretAccessKey: String
        let sessionToken: String?
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

        var message: String {
            switch self {
            case .unsupportedCredentialSource:
                return "Direct S3 trace upload cannot safely use configured inline or file AWS credentials."
            case .missingCredentials:
                return "Direct S3 trace upload requires scoped AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY credentials."
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
                return "Direct S3 trace upload cannot safely upload an archive requiring AWS multipart support."
            }
        }
    }

    static let maximumArchiveBytes = 8 * 1024 * 1024

    private static let requestTimeout: TimeInterval = 60
    private static let hexadecimalDigits = Array("0123456789ABCDEF".utf8)

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

        if configured(environment["GROK_TRACE_UPLOAD_CREDENTIALS"]) != nil
            || configured(environment["GROK_TRACE_UPLOAD_CREDENTIALS_FILE"]) != nil
            || configured(document[path: ["endpoints", "trace_upload_credentials"]]?.stringValue) != nil
            || configured(document[path: ["endpoints", "trace_upload_credentials_file"]]?.stringValue) != nil
        {
            throw Failure.unsupportedCredentialSource
        }

        guard let accessKeyID = environment["AWS_ACCESS_KEY_ID"], !accessKeyID.isEmpty,
              let secretAccessKey = environment["AWS_SECRET_ACCESS_KEY"], !secretAccessKey.isEmpty
        else {
            throw Failure.missingCredentials
        }

        let sessionToken = environment["AWS_SESSION_TOKEN"]
        guard isValidAccessKeyID(accessKeyID),
              isValidCredential(secretAccessKey),
              sessionToken.map(isValidCredential) ?? true
        else {
            throw Failure.invalidCredentials
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

        return Authorization(
            endpoint: endpoint,
            bucket: bucket,
            region: region,
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey,
            sessionToken: sessionToken
        )
    }

    static func request(
        authorization: Authorization,
        archive: Data,
        now: Date = Date()
    ) throws -> HTTPRequest {
        guard archive.count < maximumArchiveBytes else {
            throw Failure.archiveTooLarge
        }

        guard isValidBucket(authorization.bucket),
              isValidRegion(authorization.region),
              isValidAccessKeyID(authorization.accessKeyID),
              isValidCredential(authorization.secretAccessKey),
              authorization.sessionToken.map(isValidCredential) ?? true
        else {
            throw Failure.invalidCredentials
        }

        let components = try validatedEndpoint(authorization)
        let payloadHash = SHA256.hexDigest(archive)
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
            "Content-Type": "application/gzip",
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
            HTTPMethod.put.rawValue,
            components.percentEncodedPath,
            "",
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
            key: Array("AWS4\(authorization.secretAccessKey)".utf8),
            message: Array(date.utf8)
        )
        let regionKey = hmacSHA256(key: dateKey, message: Array(authorization.region.utf8))
        let serviceKey = hmacSHA256(key: regionKey, message: Array("s3".utf8))
        let signingKey = hmacSHA256(key: serviceKey, message: Array("aws4_request".utf8))
        let signature = hmacSHA256(key: signingKey, message: Array(stringToSign.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        headers["Authorization"] = "AWS4-HMAC-SHA256 "
            + "Credential=\(authorization.accessKeyID)/\(credentialScope), "
            + "SignedHeaders=\(signedHeaders), "
            + "Signature=\(signature)"

        return HTTPRequest(
            method: .put,
            url: authorization.endpoint,
            headers: headers,
            body: archive,
            timeout: requestTimeout
        )
    }

    static func resultURL(authorization: Authorization, sessionID: String) -> String {
        "s3://\(authorization.bucket)/\(sessionID)/trace_export.tar.gz"
    }

    static func makeProductionTransport() -> any HTTPTransport {
        let configuration = HTTPTransportConfiguration()
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
