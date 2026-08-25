import Foundation
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokHTTP
import OpenGrokModels
import OpenGrokSampler
import OpenGrokSamplingTypes
import OpenGrokVersion

/// Injectable transport and cancellable retry clock for the live trace route.
public struct LiveTraceUploadServices: Sendable {
    public let makeTransport: @Sendable () -> any HTTPTransport
    public let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        makeTransport: @escaping @Sendable () -> any HTTPTransport,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void
    ) {
        self.makeTransport = makeTransport
        self.sleep = sleep
    }

    public static var production: LiveTraceUploadServices {
        LiveTraceUploadServices(
            makeTransport: { LiveCloudTraceUpload.makeProductionTransport() },
            sleep: { seconds in
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        )
    }
}

private struct LiveTraceUploadResponse: Decodable {
    let bucket: String
    let path: String
}

private enum LiveTraceUploadFailure: Error, Sendable {
    case rejected(status: Int)
    case malformedResponse
    case invalidStorageLocation
    case networkUnavailable
    case networkInterrupted
    case invalidTransport
    case cloud(String)

    var message: String {
        switch self {
        case .rejected(let status):
            return "Storage proxy rejected the upload (HTTP \(status))."
        case .malformedResponse:
            return "Storage proxy returned an invalid upload response."
        case .invalidStorageLocation:
            return "Storage proxy returned an unsafe or unexpected storage location."
        case .networkUnavailable:
            return "Storage proxy could not be reached."
        case .networkInterrupted:
            return "Storage proxy request was interrupted or timed out."
        case .invalidTransport:
            return "Storage proxy request could not be completed safely."
        case .cloud(let message):
            return message
        }
    }
}

/// Rust: `pager/src/trace_cmd.rs:426-534,623-680`,
/// `xai-file-utils/src/storage_client.rs:383-400,1152-1210`, and
/// `shell/src/agent/config.rs:395-405,570-593` at `00e176c8`.
enum LiveTraceUpload {
    struct Authorization: Sendable {
        let endpoint: URL
        let credentials: GrokAuthCredentials
        let cloud: LiveCloudTraceUpload.Authorization?

        init(
            endpoint: URL,
            credentials: GrokAuthCredentials,
            cloud: LiveCloudTraceUpload.Authorization? = nil
        ) {
            self.endpoint = endpoint
            self.credentials = credentials
            self.cloud = cloud
        }
    }

    private static let requestTimeout: TimeInterval = 60
    private static let maximumAttempts = 4
    private static let retryableStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]

    static func authorize(
        sessionID: String,
        home: URL,
        document: TOMLValue,
        environment: [String: String],
        uploadEnabled: Bool
    ) async throws -> Authorization {
        guard uploadEnabled else {
            throw refusal("trace uploads have not been explicitly enabled")
        }

        let directBucket = configuredDirectBucket(document: document, environment: environment)
        if directBucket?.hasPrefix("gs://") == true {
            throw refusal(
                "the configured direct cloud-storage upload method is not available in this build"
            )
        }

        let managedAuthentication = liveManagedAuthenticationConfiguration(
            environment: environment
        )
        let manager = AuthManager(
            grokHome: home,
            config: managedAuthentication,
            environment: environment
        )
        let knownAuth = await manager.currentOrExpired()
        if managedAuthentication.forceLoginTeamUUID != nil, knownAuth == nil {
            throw refusal("the active account does not satisfy managed authentication policy")
        }
        if let knownAuth, knownAuth.isDataCollectionDisabled {
            throw refusal("the account uses zero data retention or has opted out of data collection")
        }

        // Expiration invalidates an OAuth bearer, never its durable privacy
        // choices: a deployment key must not reopen an opted-out account.
        let currentAuth = await manager.current()
        let sessionAuth: GrokAuth?
        if let currentAuth,
           currentAuth.isSessionAuth,
           currentAuth.isXAIAuth,
           nonempty(currentAuth.key) != nil
        {
            sessionAuth = currentAuth
        } else {
            sessionAuth = nil
        }

        let deploymentKey = nonempty(deploymentKeyFromEnvironment(environment))
            ?? nonempty(document[path: ["endpoints", "deployment_key"]]?.stringValue)
        guard sessionAuth != nil || deploymentKey != nil else {
            throw refusal(
                "no first-party xAI session credential or deployment credential is available"
            )
        }

        let store = LiveConversationStore(openGrokHome: home)
        guard let record = try await store.loadIfPresent(sessionID: sessionID) else {
            throw refusal("the session does not exist or cannot be authorized for export")
        }
        guard let everUsedNonXAI = record.everUsedNonXAI, !everUsedNonXAI else {
            throw refusal("the session's persisted xAI provider-export boundary is missing or closed")
        }
        guard record.currentProvider == .xai else {
            throw refusal("the session does not have an active first-party xAI provider")
        }

        let credentials = GrokAuthCredentials(
            userToken: sessionAuth?.key,
            deploymentKey: deploymentKey
        )
        if let bucket = directBucket, bucket.hasPrefix("s3://") {
            let cloud: LiveCloudTraceUpload.Authorization
            do {
                cloud = try LiveCloudTraceUpload.authorize(
                    sessionID: sessionID,
                    bucketURL: bucket,
                    document: document,
                    environment: environment
                )
            } catch let error as LiveCloudTraceUpload.Failure {
                throw refusal(error.message)
            }
            return Authorization(endpoint: cloud.endpoint, credentials: credentials, cloud: cloud)
        }

        return Authorization(
            endpoint: try storageEndpoint(document: document, environment: environment),
            credentials: credentials
        )
    }

    static func upload(
        sessionID: String,
        archive: Data,
        initialAuthorization: Authorization,
        home: URL,
        document: TOMLValue,
        environment: [String: String],
        uploadEnabled: Bool,
        services: LiveTraceUploadServices,
        retryNotice: (@Sendable (TimeInterval) -> Void)?
    ) async throws -> String {
        let transport = services.makeTransport()
        let objectPath = "\(sessionID)/trace_export.tar.gz"

        for attempt in 0..<maximumAttempts {
            try Task.checkCancellation()

            // The durable provider boundary can close between archive creation,
            // retries, or cancellation; no previously authorized bearer is a
            // license to send after the session's current policy has changed.
            let authorization = try await authorize(
                sessionID: sessionID,
                home: home,
                document: document,
                environment: environment,
                uploadEnabled: uploadEnabled
            )
            guard authorization.endpoint == initialAuthorization.endpoint,
                  authorization.cloud == initialAuthorization.cloud
            else {
                throw refusal("the authorized trace storage endpoint changed before upload")
            }

            let request: HTTPRequest
            if let cloud = authorization.cloud {
                do {
                    request = try LiveCloudTraceUpload.request(
                        authorization: cloud,
                        archive: archive
                    )
                } catch let error as LiveCloudTraceUpload.Failure {
                    throw LiveTraceUploadFailure.cloud(error.message)
                }
            } else {
                var headers = [
                    "Accept": "application/json",
                    "Content-Type": "application/gzip",
                    "X-Storage-Path": objectPath,
                    "x-grok-client-version": OpenGrokVersion.compiledVersion,
                    "x-grok-client-identifier": DEFAULT_CLIENT_IDENTIFIER,
                ]
                authorization.credentials.apply(
                    to: &headers,
                    baseURL: authorization.endpoint.absoluteString
                )
                request = HTTPRequest(
                    method: .post,
                    url: authorization.endpoint,
                    headers: headers,
                    body: archive,
                    timeout: requestTimeout
                )
            }

            let response: HTTPResponse
            do {
                response = try await transport.send(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as HTTPError {
                if case .cancelled = error { throw CancellationError() }
                let failure = transportFailure(error)
                guard error.isRetryable, attempt + 1 < maximumAttempts else {
                    throw failure
                }
                try await pause(
                    after: attempt,
                    retryAfter: nil,
                    services: services,
                    retryNotice: retryNotice
                )
                continue
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                let classified = TransportFailure.classifyURLError(error)
                let failure = classified.kind == .unreachable
                    ? LiveTraceUploadFailure.networkUnavailable
                    : LiveTraceUploadFailure.networkInterrupted
                guard classified.isRetryable, attempt + 1 < maximumAttempts else {
                    throw failure
                }
                try await pause(
                    after: attempt,
                    retryAfter: nil,
                    services: services,
                    retryNotice: retryNotice
                )
                continue
            } catch {
                throw LiveTraceUploadFailure.invalidTransport
            }

            let status = response.metadata.statusCode
            guard (200..<300).contains(status) else {
                guard retryableStatusCodes.contains(status), attempt + 1 < maximumAttempts else {
                    if authorization.cloud != nil {
                        throw LiveTraceUploadFailure.cloud(
                            "S3 storage rejected the upload (HTTP \(status))."
                        )
                    }
                    throw LiveTraceUploadFailure.rejected(status: status)
                }
                try await pause(
                    after: attempt,
                    retryAfter: response.metadata.retryAfter,
                    services: services,
                    retryNotice: retryNotice
                )
                continue
            }

            if let cloud = authorization.cloud {
                guard response.body.isEmpty,
                      response.metadata.url == nil || response.metadata.url == authorization.endpoint
                else {
                    throw LiveTraceUploadFailure.cloud(
                        "S3 storage returned an unsafe or unexpected upload response."
                    )
                }
                return LiveCloudTraceUpload.resultURL(
                    authorization: cloud,
                    sessionID: sessionID
                )
            }

            let decoded: LiveTraceUploadResponse
            do {
                decoded = try JSONDecoder().decode(LiveTraceUploadResponse.self, from: response.body)
            } catch {
                throw LiveTraceUploadFailure.malformedResponse
            }
            guard validBucket(decoded.bucket), decoded.path == objectPath else {
                throw LiveTraceUploadFailure.invalidStorageLocation
            }
            return "gs://\(decoded.bucket)/\(decoded.path)"
        }

        throw LiveTraceUploadFailure.invalidTransport
    }

    static func failureMessage(_ error: any Error) -> String {
        if let failure = error as? LiveTraceUploadFailure {
            return failure.message
        }
        if let applicationError = error as? CLIApplicationError,
           case .failed(let message) = applicationError
        {
            return message
        }
        return "Storage proxy request could not be completed safely."
    }

    private static func configuredDirectBucket(
        document: TOMLValue,
        environment: [String: String]
    ) -> String? {
        nonempty(environment["GROK_TRACE_UPLOAD_BUCKET"])
            ?? nonempty(document[path: ["endpoints", "trace_upload_bucket"]]?.stringValue)
    }

    private static func storageEndpoint(
        document: TOMLValue,
        environment: [String: String]
    ) throws -> URL {
        let base = nonempty(environment["GROK_TRACE_UPLOAD_URL"])
            ?? nonempty(document[path: ["endpoints", "trace_upload_url"]]?.stringValue)
            ?? nonempty(environment["GROK_CLI_CHAT_PROXY_BASE_URL"])
            ?? nonempty(document[path: ["endpoints", "cli_chat_proxy_base_url"]]?.stringValue)
            ?? CLI_CHAT_PROXY_BASE_URL_DEFAULT

        guard var components = URLComponents(string: base),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && isLoopback(host))
        else {
            throw refusal("the trace upload endpoint is invalid or does not use HTTPS")
        }

        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        components.path += "/storage"
        guard let endpoint = components.url else {
            throw refusal("the trace upload endpoint cannot be resolved safely")
        }
        return endpoint
    }

    private static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host == "[::1]" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets[0] == "127" else { return false }
        return octets.allSatisfy { UInt8($0) != nil }
    }

    private static func validBucket(_ bucket: String) -> Bool {
        guard !bucket.isEmpty, bucket.utf8.count <= 255 else { return false }
        return bucket.utf8.allSatisfy { byte in
            (48...57).contains(byte)
                || (65...90).contains(byte)
                || (97...122).contains(byte)
                || byte == 45
                || byte == 46
                || byte == 95
        }
    }

    private static func pause(
        after attempt: Int,
        retryAfter: TimeInterval?,
        services: LiveTraceUploadServices,
        retryNotice: (@Sendable (TimeInterval) -> Void)?
    ) async throws {
        let base = min(pow(2, Double(attempt + 1)), 8)
        let delay = min(max(base, retryAfter ?? 0), 8)
        retryNotice?(delay)
        try await services.sleep(delay)
        try Task.checkCancellation()
    }

    private static func transportFailure(_ error: HTTPError) -> LiveTraceUploadFailure {
        guard case .transport(let failure) = error else {
            return error.isRetryable ? .networkInterrupted : .invalidTransport
        }
        switch failure.kind {
        case .unreachable: return .networkUnavailable
        case .interrupted: return .networkInterrupted
        case .permanent: return .invalidTransport
        }
    }

    private static func refusal(_ reason: String) -> CLIApplicationError {
        CLIApplicationError.failed(
            "Trace upload refused: \(reason); "
                + "rerun with --local to export without sending session data."
        )
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }
}
