// OpenGrokHTTP.swift
//
// Open Grok — Swift port of `xai-grok-http` transport primitives, plus the
// streaming/SSE/WebSocket foundation required by providers, MCP, managed
// config, and updates.
//
// URLSession (Apple) and FoundationNetworking (Linux) share one protocol
// surface. Mock transports support hermetic tests. SSE decoding handles split
// UTF-8, split fields, comments, multiline data, malformed frames, EOF,
// reconnect metadata, early cancellation, and bounded buffering.

import Foundation
import Dispatch
import OpenGrokCircuitBreaker
import OpenGrokExtraCA
import OpenGrokShared
import OpenGrokTracing
import OpenGrokVersion

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif


/// Portable lock over mutable state. Sync `withLock` is safe to call from async.
final class LockHolder<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State
    init(_ state: State) { self.state = state }
    @discardableResult
    func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}

/// Portable monotonic timestamp (nanoseconds since boot).
public struct MonotonicInstant: Sendable, Hashable, Comparable {
    public var nanoseconds: UInt64
    public init(nanoseconds: UInt64) { self.nanoseconds = nanoseconds }
    public static func now() -> MonotonicInstant {
        MonotonicInstant(nanoseconds: DispatchTime.now().uptimeNanoseconds)
    }
    public static func < (lhs: MonotonicInstant, rhs: MonotonicInstant) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }
    public func advanced(bySeconds seconds: TimeInterval) -> MonotonicInstant {
        if seconds >= 0 {
            return MonotonicInstant(nanoseconds: nanoseconds &+ UInt64(seconds * 1_000_000_000))
        } else {
            return MonotonicInstant(nanoseconds: nanoseconds &- UInt64((-seconds) * 1_000_000_000))
        }
    }
    public func seconds(until other: MonotonicInstant) -> TimeInterval {
        if other.nanoseconds >= nanoseconds {
            return TimeInterval(other.nanoseconds - nanoseconds) / 1_000_000_000
        }
        return -TimeInterval(nanoseconds - other.nanoseconds) / 1_000_000_000
    }
}


// MARK: - Platform / user-agent

/// Product + optional version for origin `User-Agent` composition.
public struct OriginClientInfo: Sendable, Hashable, Equatable, Codable {
    public var product: String
    public var version: String?

    public init(product: String, version: String? = nil) {
        self.product = product
        self.version = version
    }
}

/// Platform triple used in the User-Agent parenthetical.
public struct HTTPPlatformInfo: Sendable, Hashable, Equatable {
    public var os: String
    public var arch: String

    public init(os: String, arch: String) {
        self.os = os
        self.arch = arch
    }

    public static func current() -> HTTPPlatformInfo {
        let os: String
        #if os(macOS)
        os = "macos"
        #elseif os(Linux)
        os = "linux"
        #elseif os(Windows)
        os = "windows"
        #else
        os = "unknown"
        #endif

        #if arch(arm64)
        let arch = "aarch64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "unknown"
        #endif
        return HTTPPlatformInfo(os: os, arch: arch)
    }
}

/// Header telling the proxy whether this process is headless or interactive.
public let clientModeHeader = "x-grok-client-mode"

/// Build the Open Grok user-agent string for a session origin.
public func sessionUserAgentString(
    origin: OriginClientInfo,
    agentProduct: String = "open-grok",
    agentVersion: String = OpenGrokVersion.installed(),
    platform: HTTPPlatformInfo = .current()
) -> String {
    if origin.product == agentProduct,
       origin.version == agentVersion
    {
        return "\(agentProduct)/\(agentVersion) (\(platform.os); \(platform.arch))"
    }
    if let originVersion = origin.version {
        return "\(origin.product)/\(originVersion) \(agentProduct)/\(agentVersion) (\(platform.os); \(platform.arch))"
    }
    return "\(origin.product) \(agentProduct)/\(agentVersion) (\(platform.os); \(platform.arch))"
}

/// Resolve origin client info from environment (`OPENGROK_CLIENT_NAME` preferred,
/// `GROK_CLIENT_NAME` accepted as compatibility alias).
public func originClientInfoFromEnvironment(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> OriginClientInfo? {
    let product = environment["OPENGROK_CLIENT_NAME"] ?? environment["GROK_CLIENT_NAME"]
    guard let product, !product.isEmpty else { return nil }
    let version = environment["OPENGROK_CLIENT_VERSION"] ?? environment["GROK_CLIENT_VERSION"]
    return OriginClientInfo(product: product, version: version)
}

public func processUserAgentString(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    let agentVersion = OpenGrokVersion.installed(environment: environment)
    let origin = originClientInfoFromEnvironment(environment: environment)
        ?? OriginClientInfo(product: "open-grok", version: agentVersion)
    return sessionUserAgentString(origin: origin, agentVersion: agentVersion)
}

// MARK: - Request / response models

public enum HTTPMethod: String, Sendable, Hashable, Equatable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case head = "HEAD"
    case options = "OPTIONS"
}

/// Whether a request may be automatically retried.
public enum HTTPIdempotency: Sendable, Equatable {
    /// Safe to retry even after partial response (GET, HEAD, PUT, DELETE).
    case idempotent
    /// Must not be replayed once any bytes of the request body were sent or
    /// any response bytes received (typical POST streams).
    case nonIdempotent
}

public struct HTTPRequest: Sendable, Equatable {
    public var method: HTTPMethod
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval?
    public var idempotency: HTTPIdempotency

    public init(
        method: HTTPMethod,
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval? = nil,
        idempotency: HTTPIdempotency? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
        switch idempotency {
        case .some(let value):
            self.idempotency = value
        case .none:
            switch method {
            case .get, .head, .options, .put, .delete:
                self.idempotency = .idempotent
            case .post, .patch:
                self.idempotency = .nonIdempotent
            }
        }
    }
}

public struct HTTPResponseMetadata: Sendable, Equatable {
    public var statusCode: Int
    public var headers: [String: String]
    public var url: URL?

    public init(statusCode: Int, headers: [String: String] = [:], url: URL? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.url = url
    }

    /// Parse `Retry-After` using the system wall clock (delta-seconds or HTTP-date).
    public var retryAfter: TimeInterval? {
        retryAfter(now: Date())
    }

    /// Parse `Retry-After` against an injectable wall-clock instant.
    public func retryAfter(now: Date) -> TimeInterval? {
        let value = headers.first { $0.key.lowercased() == "retry-after" }?.value
        return parseRetryAfterHeader(value, now: now)
    }

    public var contentType: String? {
        headers.first { $0.key.lowercased() == "content-type" }?.value
    }

    public var isEventStream: Bool {
        contentType?.lowercased().contains("text/event-stream") == true
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var metadata: HTTPResponseMetadata
    public var body: Data

    public init(metadata: HTTPResponseMetadata, body: Data) {
        self.metadata = metadata
        self.body = body
    }
}

// MARK: - Errors / transport failure

public enum TransportFailureKind: Sendable, Equatable, Hashable {
    /// Connection could never be established.
    case unreachable
    /// Established request was cut short (timeout, reset, body drop).
    case interrupted
    /// Client-side defect; not retryable.
    case permanent
}

public struct TransportFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public var kind: TransportFailureKind
    public var detail: String

    public init(kind: TransportFailureKind, detail: String) {
        self.kind = kind
        self.detail = detail
    }

    public var description: String { "\(kind): \(detail)" }

    public var isRetryable: Bool {
        switch kind {
        case .unreachable, .interrupted: return true
        case .permanent: return false
        }
    }

    public static func classifyURLError(_ error: URLError) -> TransportFailure {
        let detail = errorCauseChain(error)
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .networkConnectionLost where false,
             .notConnectedToInternet, .internationalRoamingOff,
             .callIsActive, .dataNotAllowed:
            return TransportFailure(kind: .unreachable, detail: detail)
        case .timedOut, .networkConnectionLost, .cannotParseResponse,
             .cannotDecodeContentData, .cannotDecodeRawData, .dataLengthExceedsMaximum,
             .httpTooManyRedirects:
            return TransportFailure(kind: .interrupted, detail: detail)
        case .badURL, .unsupportedURL, .userAuthenticationRequired,
             .userCancelledAuthentication, .appTransportSecurityRequiresSecureConnection,
             .secureConnectionFailed, .serverCertificateHasBadDate,
             .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired, .resourceUnavailable,
             .redirectToNonExistentLocation, .badServerResponse:
            // Certificate / policy failures are permanent for a given config.
            if error.code == .timedOut || error.code == .networkConnectionLost {
                return TransportFailure(kind: .interrupted, detail: detail)
            }
            // Prefer permanent for policy/cert defects; treat others as interrupted.
            switch error.code {
            case .badURL, .unsupportedURL, .userAuthenticationRequired,
                 .appTransportSecurityRequiresSecureConnection,
                 .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .clientCertificateRejected, .clientCertificateRequired:
                return TransportFailure(kind: .permanent, detail: detail)
            default:
                return TransportFailure(kind: .interrupted, detail: detail)
            }
        case .cancelled:
            return TransportFailure(kind: .interrupted, detail: detail)
        default:
            return TransportFailure(kind: .interrupted, detail: detail)
        }
    }
}

public enum HTTPError: Error, Sendable, Equatable, CustomStringConvertible {
    case transport(TransportFailure)
    case cancelled
    case bufferExceeded(limit: Int)
    case invalidURL(String)
    case unexpectedStatus(HTTPResponseMetadata, body: Data)
    case webSocketUnsupported(String)
    case webSocketClosed(code: Int, reason: String)

    public var description: String {
        switch self {
        case .transport(let f): return f.description
        case .cancelled: return "request cancelled"
        case .bufferExceeded(let limit): return "response buffer exceeded limit \(limit)"
        case .invalidURL(let s): return "invalid URL: \(s)"
        case .unexpectedStatus(let m, _): return "unexpected status \(m.statusCode)"
        case .webSocketUnsupported(let s): return "websocket unsupported: \(s)"
        case .webSocketClosed(let code, let reason): return "websocket closed \(code): \(reason)"
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .transport(let f): return f.isRetryable
        case .cancelled, .bufferExceeded, .invalidURL, .webSocketUnsupported:
            return false
        case .unexpectedStatus(let m, _):
            return RetryPolicy.server().shouldRetry(UInt16(clamping: m.statusCode))
        case .webSocketClosed:
            return true
        }
    }
}

/// Join an error's cause chain into one string (reqwest-style).
public func errorCauseChain(_ error: Error) -> String {
    var parts: [String] = ["\(error)"]
    var ns = error as NSError
    while let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
        parts.append("\(underlying)")
        ns = underlying
    }
    return parts.joined(separator: ": ")
}

// MARK: - Transport configuration

public struct HTTPProxyConfiguration: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var username: String?
    public var password: String?

    public init(host: String, port: Int, username: String? = nil, password: String? = nil) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }
}

public struct HTTPTLSConfiguration: Sendable, Equatable {
    /// When `false`, certificate validation is relaxed (tests only).
    public var validateCertificates: Bool
    public var minimumTLSVersion: String?
    /// Validated DER roots applied additively to the platform trust store.
    public var extraRootCertificates: [Data]

    public init(
        validateCertificates: Bool = true,
        minimumTLSVersion: String? = nil,
        extraRootCertificates: [Data] = OpenGrokExtraCA.processRootCertificates
    ) {
        self.validateCertificates = validateCertificates
        self.minimumTLSVersion = minimumTLSVersion
        self.extraRootCertificates = extraRootCertificates
    }
}

public struct HTTPTransportConfiguration: Sendable, Equatable {
    public var connectTimeout: TimeInterval
    public var requestTimeout: TimeInterval?
    public var maxResponseBytes: Int
    public var maxStreamBufferBytes: Int
    public var userAgent: String?
    public var proxy: HTTPProxyConfiguration?
    public var tls: HTTPTLSConfiguration
    public var additionalHeaders: [String: String]

    public init(
        connectTimeout: TimeInterval = TimeInterval(30),
        requestTimeout: TimeInterval? = nil,
        maxResponseBytes: Int = 64 * 1024 * 1024,
        maxStreamBufferBytes: Int = 4 * 1024 * 1024,
        userAgent: String? = nil,
        proxy: HTTPProxyConfiguration? = nil,
        tls: HTTPTLSConfiguration = HTTPTLSConfiguration(),
        additionalHeaders: [String: String] = [:]
    ) {
        self.connectTimeout = connectTimeout
        self.requestTimeout = requestTimeout
        self.maxResponseBytes = maxResponseBytes
        self.maxStreamBufferBytes = maxStreamBufferBytes
        self.userAgent = userAgent
        self.proxy = proxy
        self.tls = tls
        self.additionalHeaders = additionalHeaders
    }
}

// MARK: - Transport protocol

/// Byte chunk from an incremental HTTP response body.
public struct HTTPBodyChunk: Sendable, Equatable {
    public var data: Data
    public init(_ data: Data) { self.data = data }
}

/// Abstract HTTP transport used by production and mock clients.
public protocol HTTPTransport: Sendable {
    /// Full buffered request/response.
    func send(_ request: HTTPRequest) async throws -> HTTPResponse

    /// Incremental body stream with response metadata first.
    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<HTTPStreamEvent, Error>
}

public enum HTTPStreamEvent: Sendable, Equatable {
    case metadata(HTTPResponseMetadata)
    case body(Data)
    case end

    /// Bytes counted toward the pending stream buffer budget.
    public var pendingByteCost: Int {
        switch self {
        case .metadata, .end:
            return 0
        case .body(let data):
            return data.count
        }
    }
}

// MARK: - Bounded stream mailbox (producer/consumer backpressure)

/// Explicitly bounded producer/consumer mailbox for stream events.
///
/// When the consumer is slow, pending body bytes accumulate. Pushing past
/// `maxPendingBytes` fails with ``HTTPError/bufferExceeded(limit:)`` so the
/// upstream producer can cancel immediately (no unbounded growth).
///
/// Synchronization uses a nonisolated `withLock` so `NSLock` is never called
/// directly from an async function context (Swift 6 unavailability).
public final class BoundedStreamMailbox: @unchecked Sendable {
    private struct State {
        var queue: [(HTTPStreamEvent, Int)] = []
        var pendingBytes: Int = 0
        var finished = false
        var finishError: Error?
        var consumer: CheckedContinuation<HTTPStreamEvent?, Error>?
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        var state = State()

        nonisolated func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
            lock.lock()
            defer { lock.unlock() }
            return try body(&state)
        }
    }

    private let box = Box()
    public let maxPendingBytes: Int

    public init(maxPendingBytes: Int) {
        self.maxPendingBytes = max(1, maxPendingBytes)
    }

    public var pendingBytes: Int {
        box.withLock { $0.pendingBytes }
    }

    /// Enqueue an event. Fails when the pending body-byte budget would be exceeded.
    public func push(_ event: HTTPStreamEvent) throws {
        let cost = event.pendingByteCost
        enum PushOutcome {
            case ignored
            case deliver(CheckedContinuation<HTTPStreamEvent?, Error>)
            case overflow
            case queued
        }
        let outcome: PushOutcome = box.withLock { state in
            if state.finished {
                return .ignored
            }
            if let waiter = state.consumer {
                state.consumer = nil
                // Deliver directly — not counted as pending.
                return .deliver(waiter)
            }
            if state.pendingBytes + cost > maxPendingBytes {
                state.finished = true
                state.finishError = HTTPError.bufferExceeded(limit: maxPendingBytes)
                return .overflow
            }
            state.queue.append((event, cost))
            state.pendingBytes += cost
            return .queued
        }
        switch outcome {
        case .ignored, .queued:
            return
        case .deliver(let waiter):
            waiter.resume(returning: event)
        case .overflow:
            throw HTTPError.bufferExceeded(limit: maxPendingBytes)
        }
    }

    public func finish(throwing error: Error? = nil) {
        let waiter: CheckedContinuation<HTTPStreamEvent?, Error>? = box.withLock { state in
            if state.finished {
                return nil
            }
            state.finished = true
            state.finishError = error
            let waiter = state.consumer
            state.consumer = nil
            return waiter
        }
        if let waiter {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume(returning: nil)
            }
        }
    }

    public func next() async throws -> HTTPStreamEvent? {
        enum Immediate {
            case event(HTTPStreamEvent)
            case done(Error?)
            case wait
        }
        let immediate: Immediate = box.withLock { state in
            if !state.queue.isEmpty {
                let (event, cost) = state.queue.removeFirst()
                state.pendingBytes = max(0, state.pendingBytes - cost)
                return .event(event)
            }
            if state.finished {
                return .done(state.finishError)
            }
            return .wait
        }
        switch immediate {
        case .event(let event):
            return event
        case .done(let error):
            if let error { throw error }
            return nil
        case .wait:
            break
        }

        return try await withCheckedThrowingContinuation { cont in
            // Re-check under the same lock before parking the waiter so a
            // concurrent finish/push cannot leave us suspended forever.
            enum Park {
                case event(HTTPStreamEvent)
                case done(Error?)
                case parked
            }
            let park: Park = box.withLock { state in
                if !state.queue.isEmpty {
                    let (event, cost) = state.queue.removeFirst()
                    state.pendingBytes = max(0, state.pendingBytes - cost)
                    return .event(event)
                }
                if state.finished {
                    return .done(state.finishError)
                }
                state.consumer = cont
                return .parked
            }
            switch park {
            case .event(let event):
                cont.resume(returning: event)
            case .done(let error):
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: nil)
                }
            case .parked:
                break
            }
        }
    }

    /// Bridge the mailbox into a pull-based `AsyncThrowingStream`.
    ///
    /// Uses the unfolding initializer so elements are only dequeued when the
    /// downstream consumer demands them — an eager intermediate drain would
    /// empty the mailbox and grow an unbounded stream buffer.
    public func makeStream(
        onCancel: (@Sendable () -> Void)? = nil
    ) -> AsyncThrowingStream<HTTPStreamEvent, Error> {
        AsyncThrowingStream { [self] in
            try await withTaskCancellationHandler {
                try await self.next()
            } onCancel: {
                onCancel?()
                self.finish(throwing: HTTPError.cancelled)
            }
        }
    }
}

// MARK: - URLSession configuration seams (proxy / TLS / headers)

/// Pure construction of `URLSessionConfiguration` fields from transport config.
///
/// Exposed for deterministic configuration-forwarding tests on macOS and Linux
/// without performing network I/O.
public enum HTTPSessionConfigurationBuilder {
    /// Build the connection proxy dictionary, including authenticated proxy
    /// username/password when supplied.
    public static func proxyDictionary(
        _ proxy: HTTPProxyConfiguration
    ) -> [AnyHashable: Any] {
        var dict: [AnyHashable: Any] = [
            "HTTPEnable": 1,
            "HTTPProxy": proxy.host,
            "HTTPPort": proxy.port,
            "HTTPSEnable": 1,
            "HTTPSProxy": proxy.host,
            "HTTPSPort": proxy.port,
        ]
        // Portable keys accepted by URLSession on Apple + FoundationNetworking.
        if let username = proxy.username {
            dict["ProxyUsername"] = username
            // Historical CFNetwork aliases (string form is portable).
            dict["kCFProxyUsername"] = username
        }
        if let password = proxy.password {
            dict["ProxyPassword"] = password
            dict["kCFProxyPassword"] = password
        }
        return dict
    }

    /// Normalize a textual minimum TLS version for configuration snapshots.
    ///
    /// Returns one of `"1.0"`, `"1.1"`, `"1.2"`, `"1.3"`, or `nil` when the
    /// input is missing/unrecognized. Applied through platform-specific
    /// URLSession seams in ``apply(_:to:)``.
    public static func normalizedTLSMinimumVersion(_ raw: String?) -> String? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1.0", "tls1.0", "tlsv1", "tlsv1.0":
            return "1.0"
        case "1.1", "tls1.1", "tlsv1.1":
            return "1.1"
        case "1.2", "tls1.2", "tlsv1.2":
            return "1.2"
        case "1.3", "tls1.3", "tlsv1.3":
            return "1.3"
        default:
            return nil
        }
    }

    /// Apply timeouts, headers, proxy, and TLS minimum-version policy.
    @discardableResult
    public static func apply(
        _ transport: HTTPTransportConfiguration,
        to config: URLSessionConfiguration
    ) -> URLSessionConfiguration {
        let requestTimeout = transport.requestTimeout ?? TimeInterval(60)
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = transport.connectTimeout + requestTimeout

        var headers: [AnyHashable: Any] = [:]
        let ua = transport.userAgent ?? processUserAgentString()
        headers["User-Agent"] = ua
        for (k, v) in transport.additionalHeaders {
            headers[k] = v
        }
        config.httpAdditionalHeaders = headers

        if let proxy = transport.proxy {
            config.connectionProxyDictionary = proxyDictionary(proxy)
        }

        // TLS minimum protocol is an Apple URLSession seam. Linux
        // FoundationNetworking does not expose the same API; the normalized
        // value is still recorded on the configuration snapshot for tests.
        #if !os(Linux)
        if let min = normalizedTLSMinimumVersion(transport.tls.minimumTLSVersion) {
            switch min {
            case "1.0":
                config.tlsMinimumSupportedProtocolVersion = .TLSv10
            case "1.1":
                config.tlsMinimumSupportedProtocolVersion = .TLSv11
            case "1.2":
                config.tlsMinimumSupportedProtocolVersion = .TLSv12
            case "1.3":
                config.tlsMinimumSupportedProtocolVersion = .TLSv13
            default:
                break
            }
        }
        #endif
        return config
    }

    /// Create an ephemeral configuration with all transport fields applied.
    public static func makeEphemeral(
        _ transport: HTTPTransportConfiguration
    ) -> URLSessionConfiguration {
        apply(transport, to: .ephemeral)
    }

    /// Snapshot of configuration fields for hermetic assertions.
    public struct Snapshot: Sendable, Equatable {
        public var userAgent: String?
        public var additionalHeaders: [String: String]
        public var proxyHost: String?
        public var proxyPort: Int?
        public var proxyUsername: String?
        public var proxyPassword: String?
        public var tlsValidateCertificates: Bool
        public var tlsMinimumVersion: String?
        public var tlsExtraRootCertificateCount: Int
        public var connectTimeout: TimeInterval
        public var requestTimeout: TimeInterval?
        public var maxStreamBufferBytes: Int
    }

    public static func snapshot(
        _ transport: HTTPTransportConfiguration
    ) -> Snapshot {
        Snapshot(
            userAgent: transport.userAgent,
            additionalHeaders: transport.additionalHeaders,
            proxyHost: transport.proxy?.host,
            proxyPort: transport.proxy?.port,
            proxyUsername: transport.proxy?.username,
            proxyPassword: transport.proxy?.password,
            tlsValidateCertificates: transport.tls.validateCertificates,
            tlsMinimumVersion: transport.tls.minimumTLSVersion,
            tlsExtraRootCertificateCount: transport.tls.extraRootCertificates.count,
            connectTimeout: transport.connectTimeout,
            requestTimeout: transport.requestTimeout,
            maxStreamBufferBytes: transport.maxStreamBufferBytes
        )
    }
}

/// URLSession delegate that applies certificate-validation policy.
///
/// When `validateCertificates` is `false` (tests only), server-trust challenges
/// are accepted without chain evaluation. Default is strict system validation.
public final class HTTPTransportSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    public let validateCertificates: Bool
    public let extraRootCertificates: [Data]

    /// Whether this platform can install additive trust anchors in a server
    /// trust challenge. FoundationNetworking currently exposes no equivalent
    /// `serverTrust` challenge API on Linux.
    public static var supportsAdditionalTrustRoots: Bool {
        #if canImport(Darwin) && canImport(Security)
        return true
        #else
        return false
        #endif
    }

    /// `true` when configured roots cannot be applied by this platform's
    /// URLSession implementation. The transport remains strict rather than
    /// weakening validation or replacing system roots.
    public var additionalTrustRootsUnavailable: Bool {
        !extraRootCertificates.isEmpty && !Self.supportsAdditionalTrustRoots
    }

    /// Whether this platform can honor `validateCertificates == false`.
    ///
    /// swift-corelibs-foundation ships neither `NSURLAuthenticationMethodServerTrust`
    /// nor `URLProtectionSpace.serverTrust` — both are explicitly `@available(*,
    /// unavailable)` there — so the relaxation cannot be applied off Darwin.
    /// Challenges then always take strict system handling, which is the
    /// fail-closed direction.
    public static var supportsRelaxedCertificateValidation: Bool {
        #if canImport(Darwin)
        return true
        #else
        return false
        #endif
    }

    /// `true` when relaxed validation was asked for but this platform cannot
    /// deliver it, so the request will still be validated strictly. Exposed so
    /// a caller pointing at a self-signed endpoint learns that from the
    /// transport rather than from an unexplained TLS failure.
    public var relaxedValidationUnavailable: Bool {
        !validateCertificates && !Self.supportsRelaxedCertificateValidation
    }

    public init(
        validateCertificates: Bool = true,
        extraRootCertificates: [Data] = OpenGrokExtraCA.processRootCertificates
    ) {
        self.validateCertificates = validateCertificates
        self.extraRootCertificates = extraRootCertificates
        super.init()
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        #if canImport(Darwin)
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodServerTrust {
            if !validateCertificates,
               let trust = challenge.protectionSpace.serverTrust
            {
                completionHandler(.useCredential, URLCredential(trust: trust))
                return
            }
            if !extraRootCertificates.isEmpty,
               let trust = challenge.protectionSpace.serverTrust
            {
                let anchors = extraRootCertificates.compactMap {
                    SecCertificateCreateWithData(nil, $0 as CFData)
                }
                if !anchors.isEmpty,
                   SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess,
                   SecTrustSetAnchorCertificatesOnly(trust, false) == errSecSuccess,
                   SecTrustEvaluateWithError(trust, nil)
                {
                    completionHandler(.useCredential, URLCredential(trust: trust))
                    return
                }
            }
            completionHandler(.performDefaultHandling, nil)
            return
        }
        #endif
        // Proxy basic-auth is supplied via connectionProxyDictionary credentials.
        completionHandler(.performDefaultHandling, nil)
    }
}

// MARK: - URLSession transport

/// Production transport backed by `URLSession`.
public final class URLSessionHTTPTransport: NSObject, HTTPTransport, @unchecked Sendable {
    public let configuration: HTTPTransportConfiguration
    private let session: URLSession
    /// Retained so the session delegate outlives the transport.
    private let sessionDelegate: HTTPTransportSessionDelegate?

    public init(
        configuration: HTTPTransportConfiguration = HTTPTransportConfiguration(),
        session: URLSession? = nil
    ) {
        // A caller-supplied session owns its TLS policy; only default-created
        // sessions attach the resolved extra-root delegate below.
        self.configuration = configuration
        if let session {
            self.session = session
            self.sessionDelegate = nil
        } else {
            let delegate = HTTPTransportSessionDelegate(
                validateCertificates: configuration.tls.validateCertificates,
                extraRootCertificates: configuration.tls.extraRootCertificates
            )
            let config = HTTPSessionConfigurationBuilder.makeEphemeral(configuration)
            self.sessionDelegate = delegate
            self.session = URLSession(
                configuration: config,
                delegate: delegate,
                delegateQueue: nil
            )
        }
        super.init()
    }

    /// Exposed for configuration-forwarding tests.
    public var appliedConfigurationSnapshot: HTTPSessionConfigurationBuilder.Snapshot {
        HTTPSessionConfigurationBuilder.snapshot(configuration)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try Task.checkCancellation()
        let urlRequest = try makeURLRequest(request)
        do {
            let (data, response) = try await session.data(for: urlRequest)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw HTTPError.transport(
                    TransportFailure(kind: .permanent, detail: "non-HTTP response")
                )
            }
            if data.count > configuration.maxResponseBytes {
                throw HTTPError.bufferExceeded(limit: configuration.maxResponseBytes)
            }
            return HTTPResponse(
                metadata: Self.metadata(from: http),
                body: data
            )
        } catch is CancellationError {
            throw HTTPError.cancelled
        } catch let error as HTTPError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled { throw HTTPError.cancelled }
            throw HTTPError.transport(TransportFailure.classifyURLError(error))
        } catch {
            throw HTTPError.transport(
                TransportFailure(kind: .interrupted, detail: errorCauseChain(error))
            )
        }
    }

    public func stream(_ request: HTTPRequest) -> AsyncThrowingStream<HTTPStreamEvent, Error> {
        let mailbox = BoundedStreamMailbox(
            maxPendingBytes: configuration.maxStreamBufferBytes
        )
        #if !canImport(Darwin)
        return streamViaDataDelegate(request, mailbox: mailbox)
        #else
        let producer = Task {
            do {
                try Task.checkCancellation()
                let urlRequest = try makeURLRequest(request)
                let (bytes, response) = try await session.bytes(for: urlRequest)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else {
                    throw HTTPError.transport(
                        TransportFailure(kind: .permanent, detail: "non-HTTP response")
                    )
                }
                try mailbox.push(.metadata(Self.metadata(from: http)))

                var chunk = Data()
                chunk.reserveCapacity(16 * 1024)
                for try await byte in bytes {
                    try Task.checkCancellation()
                    chunk.append(byte)
                    if chunk.count >= 16 * 1024 {
                        try mailbox.push(.body(chunk))
                        chunk = Data()
                        chunk.reserveCapacity(16 * 1024)
                    }
                }
                if !chunk.isEmpty {
                    try mailbox.push(.body(chunk))
                }
                try mailbox.push(.end)
                mailbox.finish()
            } catch is CancellationError {
                mailbox.finish(throwing: HTTPError.cancelled)
            } catch let error as HTTPError {
                mailbox.finish(throwing: error)
            } catch let error as URLError {
                if error.code == .cancelled {
                    mailbox.finish(throwing: HTTPError.cancelled)
                } else {
                    mailbox.finish(
                        throwing: HTTPError.transport(TransportFailure.classifyURLError(error))
                    )
                }
            } catch {
                mailbox.finish(
                    throwing: HTTPError.transport(
                        TransportFailure(kind: .interrupted, detail: errorCauseChain(error))
                    )
                )
            }
        }
        return mailbox.makeStream {
            producer.cancel()
        }
        #endif
    }

    #if !canImport(Darwin)
    /// Streaming for swift-corelibs-foundation, which has no `URLSession.bytes(for:)`.
    ///
    /// A `URLSessionDataDelegate` delivers body chunks as they arrive, which is
    /// what SSE needs; the alternative corelibs API (`data(for:)`) only yields
    /// the whole body at completion and would turn every stream into a stall.
    /// The session is per-stream because the delegate is per-stream, and it is
    /// invalidated on termination so the task and its connection are released.
    private func streamViaDataDelegate(
        _ request: HTTPRequest,
        mailbox: BoundedStreamMailbox
    ) -> AsyncThrowingStream<HTTPStreamEvent, Error> {
        let urlRequest: URLRequest
        do {
            urlRequest = try makeURLRequest(request)
        } catch {
            mailbox.finish(throwing: error)
            return mailbox.makeStream {}
        }
        let delegate = StreamingDataDelegate(
            mailbox: mailbox,
            extraRootCertificates: configuration.tls.extraRootCertificates
        )
        let streamSession = URLSession(
            configuration: HTTPSessionConfigurationBuilder.makeEphemeral(configuration),
            delegate: delegate,
            delegateQueue: nil
        )
        let task = streamSession.dataTask(with: urlRequest)
        task.resume()
        return mailbox.makeStream {
            task.cancel()
            streamSession.finishTasksAndInvalidate()
        }
    }
    #endif

    private func makeURLRequest(_ request: HTTPRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        for (k, v) in request.headers {
            urlRequest.setValue(v, forHTTPHeaderField: k)
        }
        urlRequest.httpBody = request.body
        if let timeout = request.timeout {
            urlRequest.timeoutInterval = timeout
        }
        return urlRequest
    }

    fileprivate static func metadata(from response: HTTPURLResponse) -> HTTPResponseMetadata {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let k = key as? String, let v = value as? String {
                headers[k] = v
            }
        }
        return HTTPResponseMetadata(
            statusCode: response.statusCode,
            headers: headers,
            url: response.url
        )
    }
}

#if !canImport(Darwin)
/// Pumps a corelibs `URLSessionDataTask` into a `BoundedStreamMailbox`.
///
/// The delegate owns the mailbox's terminal state: exactly one of `finish()`
/// or `finish(throwing:)` runs, from `didCompleteWithError`. A `push` that
/// throws (the mailbox's bounded-buffer limit) cancels the task, so a consumer
/// that stops reading stops the transfer instead of growing the buffer.
private final class StreamingDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let mailbox: BoundedStreamMailbox
    /// Retained for capability reporting; corelibs Foundation has no trust
    /// challenge hook to install these roots for streaming sessions.
    private let extraRootCertificates: [Data]
    private let lock = NSLock()
    private var failure: Error?

    init(mailbox: BoundedStreamMailbox, extraRootCertificates: [Data]) {
        self.mailbox = mailbox
        self.extraRootCertificates = extraRootCertificates
        super.init()
    }

    /// Record the first failure and stop the transfer. Terminal delivery still
    /// happens in `didCompleteWithError` so there is one finish path.
    private func fail(_ error: Error, cancelling task: URLSessionTask?) {
        lock.lock()
        if failure == nil { failure = error }
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            fail(
                HTTPError.transport(
                    TransportFailure(kind: .permanent, detail: "non-HTTP response")
                ),
                cancelling: dataTask
            )
            completionHandler(.cancel)
            return
        }
        do {
            try mailbox.push(.metadata(URLSessionHTTPTransport.metadata(from: http)))
            completionHandler(.allow)
        } catch {
            fail(error, cancelling: dataTask)
            completionHandler(.cancel)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard !data.isEmpty else { return }
        do {
            try mailbox.push(.body(data))
        } catch {
            fail(error, cancelling: dataTask)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        lock.lock()
        let recorded = failure
        lock.unlock()

        if let recorded {
            mailbox.finish(throwing: recorded)
        } else if let error {
            if let urlError = error as? URLError {
                if urlError.code == .cancelled {
                    mailbox.finish(throwing: HTTPError.cancelled)
                } else {
                    mailbox.finish(
                        throwing: HTTPError.transport(
                            TransportFailure.classifyURLError(urlError)
                        )
                    )
                }
            } else {
                mailbox.finish(
                    throwing: HTTPError.transport(
                        TransportFailure(kind: .interrupted, detail: errorCauseChain(error))
                    )
                )
            }
        } else {
            // `.end` may still exceed the buffer bound; report that rather than
            // closing the stream as if the body had been delivered in full.
            do {
                try mailbox.push(.end)
                mailbox.finish()
            } catch {
                mailbox.finish(throwing: error)
            }
        }
        session.finishTasksAndInvalidate()
    }
}
#endif

// MARK: - Mock transport

/// Deterministic mock for hermetic tests.
public final class MockHTTPTransport: HTTPTransport, @unchecked Sendable {
    public struct ScriptedResponse: Sendable {
        public var metadata: HTTPResponseMetadata
        public var bodyChunks: [Data]
        public var delayPerChunk: TimeInterval
        public var error: HTTPError?

        public init(
            metadata: HTTPResponseMetadata,
            body: Data = Data(),
            bodyChunks: [Data]? = nil,
            delayPerChunk: TimeInterval = 0,
            error: HTTPError? = nil
        ) {
            self.metadata = metadata
            if let bodyChunks {
                self.bodyChunks = bodyChunks
            } else if body.isEmpty {
                self.bodyChunks = []
            } else {
                self.bodyChunks = [body]
            }
            self.delayPerChunk = delayPerChunk
            self.error = error
        }
    }

    private struct State {
        var queue: [ScriptedResponse]
        var recorded: [HTTPRequest]
    }

    private let state: LockHolder<State>
    /// Pending body-byte budget for streamed responses (mirrors production).
    public let maxStreamBufferBytes: Int

    public init(
        responses: [ScriptedResponse] = [],
        maxStreamBufferBytes: Int = 4 * 1024 * 1024
    ) {
        self.state = LockHolder(State(queue: responses, recorded: []))
        self.maxStreamBufferBytes = max(1, maxStreamBufferBytes)
    }

    public var recordedRequests: [HTTPRequest] {
        state.withLock { $0.recorded }
    }

    public func enqueue(_ response: ScriptedResponse) {
        state.withLock { $0.queue.append(response) }
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try Task.checkCancellation()
        let next: ScriptedResponse = try state.withLock { s in
            s.recorded.append(request)
            guard !s.queue.isEmpty else {
                throw HTTPError.transport(
                    TransportFailure(kind: .permanent, detail: "mock transport exhausted")
                )
            }
            return s.queue.removeFirst()
        }

        if let error = next.error {
            throw error
        }
        var body = Data()
        for chunk in next.bodyChunks {
            body.append(chunk)
        }
        return HTTPResponse(metadata: next.metadata, body: body)
    }

    public func stream(_ request: HTTPRequest) -> AsyncThrowingStream<HTTPStreamEvent, Error> {
        let mailbox = BoundedStreamMailbox(maxPendingBytes: maxStreamBufferBytes)
        let producer = Task {
            do {
                try Task.checkCancellation()
                let next: ScriptedResponse = try state.withLock { s in
                    s.recorded.append(request)
                    guard !s.queue.isEmpty else {
                        throw HTTPError.transport(
                            TransportFailure(kind: .permanent, detail: "mock transport exhausted")
                        )
                    }
                    return s.queue.removeFirst()
                }

                if let error = next.error {
                    throw error
                }
                try mailbox.push(.metadata(next.metadata))
                for chunk in next.bodyChunks {
                    try Task.checkCancellation()
                    if next.delayPerChunk > 0 {
                        try await Task.sleep(
                            nanoseconds: UInt64(max(0, next.delayPerChunk) * 1_000_000_000)
                        )
                    }
                    try mailbox.push(.body(chunk))
                }
                try mailbox.push(.end)
                mailbox.finish()
            } catch is CancellationError {
                mailbox.finish(throwing: HTTPError.cancelled)
            } catch let error as HTTPError {
                mailbox.finish(throwing: error)
            } catch {
                mailbox.finish(throwing: error)
            }
        }
        return mailbox.makeStream {
            producer.cancel()
        }
    }
}

// MARK: - SSE

/// One Server-Sent Event after field assembly.
public struct SSEEvent: Sendable, Equatable, Hashable {
    public var id: String?
    public var event: String?
    public var data: String
    public var retryMilliseconds: Int?

    public init(
        id: String? = nil,
        event: String? = nil,
        data: String = "",
        retryMilliseconds: Int? = nil
    ) {
        self.id = id
        self.event = event
        self.data = data
        self.retryMilliseconds = retryMilliseconds
    }

    /// Last-Event-ID reconnect metadata when present.
    public var reconnectID: String? { id }
}

/// Incremental SSE parser tolerant of split UTF-8 and split fields.
public struct SSEParser: Sendable {
    private var byteBuffer = Data()
    private var lineCarry = ""
    private var eventID: String?
    private var eventName: String?
    private var dataLines: [String] = []
    private var retryMilliseconds: Int?
    private var lastEventID: String?
    private var pendingEvents: [SSEEvent] = []
    /// Hard cap on *all* retained parser state (incomplete bytes, line carry,
    /// assembled `data:` lines, and queued events) so slow consumers and
    /// newline-terminated floods cannot grow memory without limit.
    public var maxBufferedBytes: Int

    public init(maxBufferedBytes: Int = 4 * 1024 * 1024) {
        self.maxBufferedBytes = max(1, maxBufferedBytes)
    }

    public var lastSeenEventID: String? { lastEventID }

    /// Bytes retained across incomplete UTF-8, unfinished lines, assembled
    /// data fields, and events not yet returned to the caller.
    public var retainedBytes: Int {
        var total = byteBuffer.count + lineCarry.utf8.count
        for line in dataLines {
            // +1 accounts for the separator that would be emitted on join.
            total += line.utf8.count + 1
        }
        if let eventID { total += eventID.utf8.count }
        if let eventName { total += eventName.utf8.count }
        for event in pendingEvents {
            total += event.data.utf8.count
            if let id = event.id { total += id.utf8.count }
            if let name = event.event { total += name.utf8.count }
        }
        return total
    }

    /// Push raw bytes; returns any completed events.
    public mutating func push(_ data: Data) throws -> [SSEEvent] {
        if retainedBytes + data.count > maxBufferedBytes {
            throw HTTPError.bufferExceeded(limit: maxBufferedBytes)
        }
        byteBuffer.append(data)
        try drainCompleteLines()
        // Re-check after line assembly: complete `data:` lines without a blank
        // delimiter accumulate in `dataLines` and must count against the cap.
        if retainedBytes > maxBufferedBytes {
            throw HTTPError.bufferExceeded(limit: maxBufferedBytes)
        }
        let out = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)
        return out
    }

    /// Signal end-of-stream; flushes a trailing event if fields are pending.
    public mutating func finish() -> [SSEEvent] {
        // Flush any remaining bytes as a final incomplete UTF-8 attempt.
        if !byteBuffer.isEmpty {
            if let s = String(data: byteBuffer, encoding: .utf8) {
                lineCarry += s
            }
            byteBuffer.removeAll(keepingCapacity: false)
        }
        if !lineCarry.isEmpty {
            // Finish is best-effort; bound was already enforced on push.
            try? handleLine(lineCarry)
            lineCarry = ""
        }
        try? dispatchEventIfNeeded()
        let out = pendingEvents
        pendingEvents.removeAll(keepingCapacity: false)
        return out
    }

    private mutating func drainCompleteLines() throws {
        // Decode as much valid UTF-8 as possible; keep a short incomplete tail.
        while true {
            guard !byteBuffer.isEmpty else { return }
            if let full = String(data: byteBuffer, encoding: .utf8) {
                byteBuffer.removeAll(keepingCapacity: true)
                try processText(full)
                return
            }
            // Trim from the end until the prefix is valid UTF-8.
            var end = byteBuffer.count
            var decoded: String?
            while end > 0 {
                let slice = byteBuffer.prefix(end)
                if let s = String(data: slice, encoding: .utf8) {
                    decoded = s
                    break
                }
                end -= 1
            }
            if let decoded, end > 0 {
                try processText(decoded)
                byteBuffer.removeFirst(end)
                // Incomplete multi-byte sequence remains in buffer.
                if byteBuffer.count > 4 {
                    // Pathological invalid sequence — drop one byte and continue.
                    byteBuffer.removeFirst()
                }
                continue
            }
            // Nothing decodable yet; wait for more bytes.
            return
        }
    }

    private mutating func processText(_ text: String) throws {
        var combined = lineCarry + text
        lineCarry = ""
        // Normalize CRLF so split-on-LF never leaves a lone CR field line.
        combined = combined.replacingOccurrences(of: "\r\n", with: "\n")
        combined = combined.replacingOccurrences(of: "\r", with: "\n")
        while let range = combined.range(of: "\n") {
            let line = String(combined[..<range.lowerBound])
            combined = String(combined[range.upperBound...])
            try handleLine(line)
        }
        lineCarry = combined
    }

    private mutating func handleLine(_ line: String) throws {
        // Empty line dispatches the event.
        if line.isEmpty {
            try dispatchEventIfNeeded()
            return
        }
        // Comments
        if line.hasPrefix(":") {
            return
        }
        let field: String
        let value: String
        if let idx = line.firstIndex(of: ":") {
            field = String(line[..<idx])
            var v = String(line[line.index(after: idx)...])
            if v.hasPrefix(" ") {
                v.removeFirst()
            }
            value = v
        } else {
            field = line
            value = ""
        }
        switch field {
        case "event":
            eventName = value
        case "data":
            dataLines.append(value)
            // Bound assembled data-lines even without a dispatch delimiter.
            if retainedBytes > maxBufferedBytes {
                throw HTTPError.bufferExceeded(limit: maxBufferedBytes)
            }
        case "id":
            // Per SSE spec, id must not contain null; ignore if it does.
            if !value.contains("\0") {
                eventID = value
            }
        case "retry":
            if let ms = Int(value), ms >= 0 {
                retryMilliseconds = ms
            }
        default:
            // Unknown fields ignored (forward-compatible).
            break
        }
    }

    private mutating func dispatchEventIfNeeded() throws {
        // Spec: if data is empty after join, don't dispatch (except we still
        // accept events with only id/retry for reconnect metadata).
        guard !dataLines.isEmpty || eventID != nil || retryMilliseconds != nil || eventName != nil else {
            resetFields()
            return
        }
        // Classic SSE: empty data-only blocks with no fields produce nothing.
        if dataLines.isEmpty && eventName == nil && eventID == nil && retryMilliseconds == nil {
            resetFields()
            return
        }
        let data = dataLines.joined(separator: "\n")
        // Dispatch only when there is data or meaningful control fields.
        if dataLines.isEmpty && eventName == nil && eventID == nil {
            // retry-only line block is valid reconnect metadata.
            if retryMilliseconds != nil {
                let event = SSEEvent(
                    id: nil,
                    event: nil,
                    data: "",
                    retryMilliseconds: retryMilliseconds
                )
                pendingEvents.append(event)
            }
            resetFields()
            if retainedBytes > maxBufferedBytes {
                throw HTTPError.bufferExceeded(limit: maxBufferedBytes)
            }
            return
        }
        if dataLines.isEmpty && eventName == nil && retryMilliseconds == nil && eventID != nil {
            // id without data still updates last-event-id.
            lastEventID = eventID
            resetFields()
            return
        }
        let event = SSEEvent(
            id: eventID,
            event: eventName,
            data: data,
            retryMilliseconds: retryMilliseconds
        )
        if let id = eventID {
            lastEventID = id
        }
        pendingEvents.append(event)
        resetFields()
        if retainedBytes > maxBufferedBytes {
            throw HTTPError.bufferExceeded(limit: maxBufferedBytes)
        }
    }

    private mutating func resetFields() {
        eventID = nil
        eventName = nil
        dataLines.removeAll(keepingCapacity: true)
        retryMilliseconds = nil
    }
}

/// Stream SSE events from an HTTP body stream.
public func sseEventStream(
    from body: AsyncThrowingStream<HTTPStreamEvent, Error>,
    maxBufferedBytes: Int = 4 * 1024 * 1024
) -> AsyncThrowingStream<SSEEvent, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            var parser = SSEParser(maxBufferedBytes: maxBufferedBytes)
            do {
                for try await event in body {
                    try Task.checkCancellation()
                    switch event {
                    case .metadata:
                        continue
                    case .body(let data):
                        let events = try parser.push(data)
                        for e in events {
                            continuation.yield(e)
                        }
                    case .end:
                        for e in parser.finish() {
                            continuation.yield(e)
                        }
                        continuation.finish()
                        return
                    }
                }
                for e in parser.finish() {
                    continuation.yield(e)
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: HTTPError.cancelled)
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

// MARK: - WebSocket

public enum WebSocketMessage: Sendable, Equatable {
    case text(String)
    case data(Data)
}

/// Cross-platform WebSocket client protocol.
public protocol WebSocketClient: Sendable {
    func send(_ message: WebSocketMessage) async throws
    func receive() async throws -> WebSocketMessage
    func close(code: Int, reason: String) async
}

/// URLSession-backed WebSocket (available on Apple platforms and recent Foundation).
public final class URLSessionWebSocketClient: WebSocketClient, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    /// Retained so the session (and its TLS/proxy delegate) outlives the task.
    private let session: URLSession
    private let sessionDelegate: HTTPTransportSessionDelegate?
    /// Configuration snapshot for deterministic forwarding tests.
    public let appliedConfigurationSnapshot: HTTPSessionConfigurationBuilder.Snapshot

    public init(
        task: URLSessionWebSocketTask,
        session: URLSession,
        sessionDelegate: HTTPTransportSessionDelegate? = nil,
        appliedConfigurationSnapshot: HTTPSessionConfigurationBuilder.Snapshot
    ) {
        self.task = task
        self.session = session
        self.sessionDelegate = sessionDelegate
        self.appliedConfigurationSnapshot = appliedConfigurationSnapshot
        task.resume()
    }

    /// Build a configured session + request without connecting (test seam).
    public static func makeSessionAndRequest(
        url: URL,
        configuration: HTTPTransportConfiguration = HTTPTransportConfiguration(),
        headers: [String: String] = [:]
    ) -> (
        session: URLSession,
        request: URLRequest,
        delegate: HTTPTransportSessionDelegate,
        snapshot: HTTPSessionConfigurationBuilder.Snapshot
    ) {
        var request = URLRequest(url: url)
        if let timeout = configuration.requestTimeout {
            request.timeoutInterval = timeout
        } else {
            request.timeoutInterval = configuration.connectTimeout
        }
        let ua = configuration.userAgent ?? processUserAgentString()
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        for (k, v) in configuration.additionalHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let delegate = HTTPTransportSessionDelegate(
            validateCertificates: configuration.tls.validateCertificates,
            extraRootCertificates: configuration.tls.extraRootCertificates
        )
        let config = HTTPSessionConfigurationBuilder.makeEphemeral(configuration)
        let session = URLSession(
            configuration: config,
            delegate: delegate,
            delegateQueue: nil
        )
        return (
            session,
            request,
            delegate,
            HTTPSessionConfigurationBuilder.snapshot(configuration)
        )
    }

    public static func connect(
        url: URL,
        configuration: HTTPTransportConfiguration = HTTPTransportConfiguration(),
        headers: [String: String] = [:]
    ) throws -> URLSessionWebSocketClient {
        let prepared = makeSessionAndRequest(
            url: url,
            configuration: configuration,
            headers: headers
        )
        let task = prepared.session.webSocketTask(with: prepared.request)
        return URLSessionWebSocketClient(
            task: task,
            session: prepared.session,
            sessionDelegate: prepared.delegate,
            appliedConfigurationSnapshot: prepared.snapshot
        )
    }

    public func send(_ message: WebSocketMessage) async throws {
        switch message {
        case .text(let s):
            try await task.send(.string(s))
        case .data(let d):
            try await task.send(.data(d))
        }
    }

    public func receive() async throws -> WebSocketMessage {
        let message = try await task.receive()
        switch message {
        case .string(let s):
            return .text(s)
        case .data(let d):
            return .data(d)
        @unknown default:
            throw HTTPError.webSocketUnsupported("unknown message kind")
        }
    }

    public func close(code: Int, reason: String) async {
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
        task.cancel(with: closeCode, reason: reason.data(using: .utf8))
    }
}

// MARK: - Retry orchestration

public struct HTTPRetryPolicy: Sendable {
    public var maxAttempts: UInt32
    public var statusPolicy: RetryPolicy
    public var honorRetryAfter: Bool
    /// When true, never replay non-idempotent requests after any response metadata.
    public var respectIdempotency: Bool
    public var jitterSeed: UInt64?

    public init(
        maxAttempts: UInt32 = 3,
        statusPolicy: RetryPolicy = .server(),
        honorRetryAfter: Bool = true,
        respectIdempotency: Bool = true,
        jitterSeed: UInt64? = nil
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.statusPolicy = statusPolicy
        self.honorRetryAfter = honorRetryAfter
        self.respectIdempotency = respectIdempotency
        self.jitterSeed = jitterSeed
    }
}

/// Send with retries. Never replays a non-idempotent request after partial
/// stream progress (any metadata or body observed).
///
/// - Parameter wallClock: Injectable wall clock used when converting IMF-fixdate
///   `Retry-After` values into remaining delays.
public func sendWithRetry(
    transport: any HTTPTransport,
    request: HTTPRequest,
    policy: HTTPRetryPolicy = HTTPRetryPolicy(),
    wallClock: any WallClock = SystemWallClock(),
    sleeper: @escaping @Sendable (TimeInterval) async -> Void = { duration in
        try? await Task.sleep(nanoseconds: UInt64(max(0, duration) * 1_000_000_000))
    }
) async throws -> HTTPResponse {
    var lastError: HTTPError?
    var observedPartial = false

    for attempt in 0..<policy.maxAttempts {
        if attempt > 0 {
            if policy.respectIdempotency,
               request.idempotency == .nonIdempotent,
               observedPartial
            {
                // Never replay a non-idempotent request after any response was
                // observed — partial stream progress is not safe to retry.
                throw HTTPError.transport(
                    TransportFailure(
                        kind: .permanent,
                        detail: "refusing to replay partial non-idempotent stream"
                    )
                )
            }
            let backoff: TimeInterval
            if policy.honorRetryAfter,
               case .unexpectedStatus(let meta, _)? = lastError,
               let retryAfter = meta.retryAfter(now: wallClock.now())
            {
                backoff = retryAfter
            } else {
                let seed = policy.jitterSeed.map { $0 &+ UInt64(attempt) }
                backoff = retryBackoffWithJitter(retryCount: attempt, seed: seed)
            }
            try Task.checkCancellation()
            await sleeper(backoff)
            try Task.checkCancellation()
        }

        do {
            try Task.checkCancellation()
            let response = try await transport.send(request)
            observedPartial = true
            if let disposition = policy.statusPolicy.classify(UInt16(clamping: response.metadata.statusCode)),
               disposition == .retryable,
               attempt + 1 < policy.maxAttempts
            {
                lastError = .unexpectedStatus(response.metadata, body: response.body)
                continue
            }
            return response
        } catch is CancellationError {
            throw HTTPError.cancelled
        } catch let error as HTTPError {
            observedPartial = true
            lastError = error
            if !error.isRetryable {
                throw error
            }
        } catch {
            observedPartial = true
            let wrapped = HTTPError.transport(
                TransportFailure(kind: .interrupted, detail: errorCauseChain(error))
            )
            lastError = wrapped
            if !wrapped.isRetryable {
                throw wrapped
            }
        }
    }
    throw lastError ?? HTTPError.transport(
        TransportFailure(kind: .permanent, detail: "retry attempts exhausted")
    )
}

// MARK: - Traced client

/// HTTP client that attaches trace headers and records client spans.
public struct TracedHTTPClient: Sendable {
    public var transport: any HTTPTransport
    public var tracer: Tracer

    public init(transport: any HTTPTransport, tracer: Tracer = Tracer()) {
        self.transport = transport
        self.tracer = tracer
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await tracer.withSpan(
            "http_request",
            kind: .client,
            attributes: [
                "http.request.method": .string(request.method.rawValue),
                "url.full": .string(TraceRedaction.urlOrigin(request.url.absoluteString)),
            ]
        ) { span in
            var req = request
            attachTraceToHTTPHeaders(&req.headers, span: span)
            // Never attach raw authorization values to the span.
            let response = try await transport.send(req)
            span.setAttribute(
                "http.response.status_code",
                .int(Int64(response.metadata.statusCode))
            )
            return response
        }
    }
}

// MARK: - Shared client handle

/// Process-level shared transport configuration (mirrors Rust OnceLock clients).
public enum SharedHTTP {
    private static let state = LockHolder<(any HTTPTransport)?>(nil)

    public static func sharedTransport(
        configuration: HTTPTransportConfiguration = HTTPTransportConfiguration()
    ) -> any HTTPTransport {
        state.withLock { current in
            if let existing = current {
                return existing
            }
            let created = URLSessionHTTPTransport(configuration: configuration)
            current = created
            return created
        }
    }

    /// Replace the shared transport (tests).
    public static func setSharedTransportForTests(_ transport: (any HTTPTransport)?) {
        state.withLock { $0 = transport }
    }
}
