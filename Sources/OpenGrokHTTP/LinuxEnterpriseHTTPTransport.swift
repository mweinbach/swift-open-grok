#if os(Linux)

import COpenGrokSockets
import Foundation
import OpenGrokExtraCA

/// corelibs URLSession cannot add per-session anchors, so only sessions this
/// module owns take the independently verified, request-local libcurl path.
struct LinuxEnterpriseHTTPTransport: HTTPTransport, Sendable {
    let configuration: HTTPTransportConfiguration

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let transfer = LinuxEnterpriseHTTPTransfer(
            configuration: configuration,
            request: request,
            mailbox: nil
        )

        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let worker = Thread { [transfer] in
                        do {
                            continuation.resume(returning: try transfer.perform())
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                    worker.name = "opengrok-enterprise-https"
                    worker.start()
                }
            } onCancel: {
                transfer.cancel()
            }
        } catch is CancellationError {
            throw HTTPError.cancelled
        }
    }

    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<HTTPStreamEvent, Error> {
        let mailbox = BoundedStreamMailbox(
            maxPendingBytes: configuration.maxStreamBufferBytes
        )
        let transfer = LinuxEnterpriseHTTPTransfer(
            configuration: configuration,
            request: request,
            mailbox: mailbox
        )

        let worker = Thread { [transfer, mailbox] in
            do {
                let response = try transfer.perform()
                guard response.metadata.statusCode >= 100 else {
                    throw LinuxEnterpriseHTTPTransfer.policyFailure(
                        "secure HTTPS response omitted its HTTP metadata"
                    )
                }
                try mailbox.push(.end)
                mailbox.finish()
            } catch is CancellationError {
                mailbox.finish(throwing: HTTPError.cancelled)
            } catch {
                mailbox.finish(throwing: error)
            }
        }
        worker.name = "opengrok-enterprise-https-stream"
        worker.start()

        return mailbox.makeStream {
            transfer.cancel()
        }
    }
}

private final class LinuxEnterpriseHTTPTransfer: @unchecked Sendable {
    private struct State {
        var handle: OGHTTPSHandle = 0
        var cancelled = false
        var failure: HTTPError?
        var metadata: HTTPResponseMetadata?
        var body = Data()
    }

    private static let maximumRequestBodyBytes = 64 * 1024 * 1024
    private static let maximumHeaderBytes = 64 * 1024
    private static let maximumAdditionalRootBytes = openGrokExtraCAMaxBundleBytes
    private static let maximumRootCount = 128
    private static let reservedHeaders: Set<String> = [
        "connection",
        "content-length",
        "host",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "proxy-connection",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
    ]

    private let configuration: HTTPTransportConfiguration
    private let request: HTTPRequest
    private let mailbox: BoundedStreamMailbox?
    private let stateLock = NSLock()
    private var state = State()

    init(
        configuration: HTTPTransportConfiguration,
        request: HTTPRequest,
        mailbox: BoundedStreamMailbox?
    ) {
        self.configuration = configuration
        self.request = request
        self.mailbox = mailbox
    }

    func cancel() {
        withState { state in
            state.cancelled = true
            if state.handle != 0 {
                og_https_cancel(state.handle)
            }
        }
    }

    func perform() throws -> HTTPResponse {
        try validateConfiguration()
        let handle = og_https_create()
        guard handle != 0 else {
            throw Self.captureNativeFailure()
        }

        let cancelledBeforeStart = withState { state in
            if state.cancelled { return true }
            state.handle = handle
            return false
        }
        if cancelledBeforeStart {
            og_https_destroy(handle)
            throw HTTPError.cancelled
        }
        defer {
            withState { state in
                guard state.handle != 0 else { return }
                let released = state.handle
                state.handle = 0
                og_https_destroy(released)
            }
        }

        try configure(handle)
        guard !withState({ $0.cancelled }) else {
            throw HTTPError.cancelled
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = og_https_perform(
            handle,
            context,
            linuxEnterpriseHTTPSMetadataCallback,
            linuxEnterpriseHTTPSBodyCallback
        )
        let nativeFailure = result == 0 ? nil : Self.captureNativeFailure()
        let outcome = withState { state in
            (state.failure, state.cancelled, state.metadata, state.body)
        }

        if let failure = outcome.0 { throw failure }
        if outcome.1 { throw HTTPError.cancelled }
        if let nativeFailure { throw nativeFailure }
        guard let metadata = outcome.2 else {
            throw Self.policyFailure("secure HTTPS response omitted its HTTP metadata")
        }
        return HTTPResponse(metadata: metadata, body: outcome.3)
    }

    private func configure(_ handle: OGHTTPSHandle) throws {
        let roots = configuration.tls.extraRootCertificates
        for certificate in roots {
            let result = certificate.withUnsafeBytes { bytes in
                og_https_add_root_der(handle, bytes.baseAddress, bytes.count)
            }
            if result != 0 {
                throw Self.policyFailure("configured additional TLS trust root is malformed")
            }
        }

        let trustBundle: Data
        do {
            guard let resolved = try PortableTLSConnector.resolvedTrustBundle(
                extraRootCertificates: roots
            ) else {
                throw Self.policyFailure(
                    "configured additional TLS trust roots require an available system trust bundle"
                )
            }
            trustBundle = resolved
        } catch let error as HTTPError {
            throw error
        } catch {
            throw Self.policyFailure(
                "configured additional TLS trust roots require a readable, bounded system trust bundle"
            )
        }

        try check(trustBundle.withUnsafeBytes { bytes in
            og_https_set_trust_bundle(handle, bytes.baseAddress, bytes.count)
        })
        try check(request.url.absoluteString.withCString { og_https_set_url(handle, $0) })
        try check(request.method.rawValue.withCString { og_https_set_method(handle, $0) })

        let requestSeconds = request.timeout
            ?? configuration.requestTimeout
            ?? (mailbox == nil ? 60 : 0)
        try check(og_https_set_timeouts(handle, configuration.connectTimeout, requestSeconds))
        try check(og_https_set_minimum_tls(handle, try minimumTLSVersion()))

        let headers = try resolvedHeaders()
        if let agent = headers.first(where: { $0.name.caseInsensitiveCompare("User-Agent") == .orderedSame }) {
            try check(agent.value.withCString { og_https_set_user_agent(handle, $0) })
        }
        for header in headers where header.name.caseInsensitiveCompare("User-Agent") != .orderedSame {
            try check(header.name.withCString { name in
                header.value.withCString { value in
                    og_https_add_header(handle, name, value)
                }
            })
        }

        if let body = request.body {
            try check(body.withUnsafeBytes { bytes in
                og_https_set_body(handle, bytes.baseAddress, bytes.count)
            })
        }
        if let proxy = configuration.proxy {
            try configureProxy(proxy, handle: handle)
        }
    }

    private func validateConfiguration() throws {
        guard configuration.tls.validateCertificates else {
            throw Self.policyFailure(
                "additional TLS trust roots require strict certificate validation"
            )
        }
        guard !configuration.tls.extraRootCertificates.isEmpty,
              configuration.tls.extraRootCertificates.count <= Self.maximumRootCount
        else {
            throw Self.policyFailure("configured additional TLS trust roots are invalid")
        }
        var rootBytes = 0
        for root in configuration.tls.extraRootCertificates {
            guard !root.isEmpty,
                  root.count <= Self.maximumAdditionalRootBytes - rootBytes
            else {
                throw Self.policyFailure("configured additional TLS trust roots exceed their size limit")
            }
            rootBytes += root.count
        }

        guard let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              !request.url.absoluteString.utf8.contains(0)
        else {
            throw Self.policyFailure("enterprise trust requires a safe HTTPS request URL")
        }
        guard configuration.connectTimeout.isFinite,
              configuration.connectTimeout > 0,
              configuration.connectTimeout <= 86_400
        else {
            throw Self.policyFailure("secure HTTPS connect timeout is invalid")
        }
        if let timeout = request.timeout ?? configuration.requestTimeout {
            guard timeout.isFinite, timeout > 0, timeout <= 86_400 else {
                throw Self.policyFailure("secure HTTPS request timeout is invalid")
            }
        }
        guard configuration.maxResponseBytes > 0,
              configuration.maxStreamBufferBytes > 0
        else {
            throw Self.policyFailure("secure HTTPS response buffer configuration is invalid")
        }
        if let body = request.body, body.count > Self.maximumRequestBodyBytes {
            throw HTTPError.bufferExceeded(limit: Self.maximumRequestBodyBytes)
        }
    }

    private func minimumTLSVersion() throws -> Int32 {
        guard let configured = configuration.tls.minimumTLSVersion else { return 12 }
        guard let normalized = HTTPSessionConfigurationBuilder.normalizedTLSMinimumVersion(configured) else {
            throw Self.policyFailure("secure HTTPS minimum TLS version is invalid")
        }
        switch normalized {
        case "1.0", "1.1", "1.2":
            return 12
        case "1.3":
            return 13
        default:
            throw Self.policyFailure("secure HTTPS minimum TLS version is unavailable")
        }
    }

    private struct Header {
        let name: String
        let value: String
    }

    private func resolvedHeaders() throws -> [Header] {
        var result: [String: Header] = [:]
        let baseAgent = configuration.userAgent ?? processUserAgentString()
        try validateHeader(name: "User-Agent", value: baseAgent)
        result["user-agent"] = Header(name: "User-Agent", value: baseAgent)

        for (name, value) in configuration.additionalHeaders {
            try validateHeader(name: name, value: value)
            result[name.lowercased()] = Header(name: name, value: value)
        }
        for (name, value) in request.headers {
            try validateHeader(name: name, value: value)
            result[name.lowercased()] = Header(name: name, value: value)
        }

        guard result.values.reduce(0, { $0 + $1.name.utf8.count + $1.value.utf8.count + 4 })
            <= Self.maximumHeaderBytes
        else {
            throw Self.policyFailure("secure HTTPS request headers exceed their size limit")
        }
        return result.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private func validateHeader(name: String, value: String) throws {
        guard !name.isEmpty,
              name.utf8.allSatisfy(Self.isHeaderToken),
              value.utf8.allSatisfy({ $0 == 0x09 || (0x20...0x7E).contains($0) }),
              !Self.reservedHeaders.contains(name.lowercased())
        else {
            throw Self.policyFailure("secure HTTPS request contains an unsafe header")
        }
    }

    private static func isHeaderToken(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A,
             0x21, 0x23...0x27, 0x2A, 0x2B, 0x2D, 0x2E, 0x5E...0x60, 0x7C, 0x7E:
            true
        default:
            false
        }
    }

    private func configureProxy(_ proxy: HTTPProxyConfiguration, handle: OGHTTPSHandle) throws {
        guard !proxy.host.isEmpty,
              !proxy.host.utf8.contains(where: { $0 <= 0x20 || $0 == 0x7F }),
              !proxy.host.contains(where: { "/\\?#@".contains($0) }),
              let port = UInt16(exactly: proxy.port),
              port > 0,
              proxy.username?.utf8.contains(0) != true,
              proxy.password?.utf8.contains(0) != true
        else {
            throw Self.policyFailure("secure HTTPS proxy configuration is invalid")
        }

        let result = proxy.host.withCString { host in
            withOptionalCString(proxy.username) { username in
                withOptionalCString(proxy.password) { password in
                    og_https_set_proxy(handle, host, port, username, password)
                }
            }
        }
        try check(result)
    }

    private func withOptionalCString<Result>(
        _ value: String?,
        _ body: (UnsafePointer<CChar>?) -> Result
    ) -> Result {
        guard let value else { return body(nil) }
        return value.withCString(body)
    }

    fileprivate func receiveMetadata(
        status: Int,
        effectiveURL: UnsafePointer<CChar>?,
        headers: UnsafePointer<UInt8>?,
        length: Int
    ) -> Int32 {
        do {
            guard (100...999).contains(status),
                  length >= 0,
                  length <= Self.maximumHeaderBytes,
                  let effectiveURL
            else {
                throw Self.policyFailure("secure HTTPS response metadata is invalid")
            }

            let destination = String(cString: effectiveURL)
            guard let responseURL = URL(string: destination),
                  sameOrigin(responseURL, request.url)
            else {
                throw Self.policyFailure("secure HTTPS response changed its authorized destination")
            }

            let bytes: [UInt8]
            if length == 0 {
                bytes = []
            } else {
                guard let headers else {
                    throw Self.policyFailure("secure HTTPS response headers are unavailable")
                }
                bytes = Array(UnsafeBufferPointer(start: headers, count: length))
            }
            guard let text = String(bytes: bytes, encoding: .utf8) else {
                throw Self.policyFailure("secure HTTPS response headers are malformed")
            }

            var parsed: [String: String] = [:]
            for line in text.components(separatedBy: "\r\n") where !line.isEmpty {
                if line.hasPrefix("HTTP/") { continue }
                guard let separator = line.firstIndex(of: ":") else {
                    throw Self.policyFailure("secure HTTPS response headers are malformed")
                }
                let name = String(line[..<separator])
                let value = line[line.index(after: separator)...]
                    .trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, name.utf8.allSatisfy(Self.isHeaderToken) else {
                    throw Self.policyFailure("secure HTTPS response headers are malformed")
                }
                if let key = parsed.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                    parsed[key] = (parsed[key] ?? "") + ", " + value
                } else {
                    parsed[name] = value
                }
            }

            let metadata = HTTPResponseMetadata(
                statusCode: status,
                headers: parsed,
                url: responseURL
            )
            let accepted = withState { state in
                if state.cancelled { return (accepted: false, cancelled: true) }
                guard state.metadata == nil else { return (accepted: false, cancelled: false) }
                state.metadata = metadata
                return (accepted: true, cancelled: false)
            }
            if accepted.cancelled { return 1 }
            guard accepted.accepted else {
                throw Self.policyFailure("secure HTTPS response repeated its final metadata")
            }
            if let mailbox {
                try mailbox.push(.metadata(metadata))
            }
            return 0
        } catch let error as HTTPError {
            recordFailure(error)
            return 1
        } catch {
            recordFailure(Self.policyFailure("secure HTTPS response metadata is invalid"))
            return 1
        }
    }

    fileprivate func receiveBody(_ bytes: UnsafePointer<UInt8>?, length: Int) -> Int32 {
        guard length >= 0 else {
            recordFailure(Self.policyFailure("secure HTTPS response body is invalid"))
            return 1
        }
        guard length > 0 else { return 0 }
        guard let bytes else {
            recordFailure(Self.policyFailure("secure HTTPS response body is unavailable"))
            return 1
        }
        let readiness = withState { (metadata: $0.metadata != nil, cancelled: $0.cancelled) }
        if readiness.cancelled { return 1 }
        guard readiness.metadata else {
            recordFailure(Self.policyFailure("secure HTTPS response body preceded its metadata"))
            return 1
        }

        if let mailbox {
            var offset = 0
            do {
                while offset < length {
                    let count = min(length - offset, mailbox.maxPendingBytes)
                    let chunk = Data(bytes: bytes.advanced(by: offset), count: count)
                    try mailbox.push(.body(chunk))
                    offset += count
                }
                return 0
            } catch let error as HTTPError {
                recordFailure(error)
                return 1
            } catch {
                recordFailure(Self.policyFailure("secure HTTPS response body could not be delivered"))
                return 1
            }
        }

        let accepted = withState { state in
            guard length <= configuration.maxResponseBytes - state.body.count else {
                state.failure = .bufferExceeded(limit: configuration.maxResponseBytes)
                return false
            }
            state.body.append(bytes, count: length)
            return true
        }
        return accepted ? 0 : 1
    }

    private func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = URLComponents(url: lhs, resolvingAgainstBaseURL: false),
              let right = URLComponents(url: rhs, resolvingAgainstBaseURL: false),
              left.scheme?.lowercased() == "https",
              right.scheme?.lowercased() == "https",
              left.host?.caseInsensitiveCompare(right.host ?? "") == .orderedSame,
              (left.port ?? 443) == (right.port ?? 443),
              left.user == nil,
              left.password == nil
        else {
            return false
        }
        return true
    }

    private func recordFailure(_ failure: HTTPError) {
        withState { state in
            if state.failure == nil { state.failure = failure }
        }
    }

    private func check(_ status: Int32) throws {
        guard status == 0 else { throw Self.captureNativeFailure() }
    }

    private static func captureNativeFailure() -> HTTPError {
        let kind = og_https_last_error_kind()
        let pointer = og_https_last_error_message()
        let message = pointer.map { String(cString: $0) } ?? "secure HTTPS operation failed"
        let detail: String
        if !message.isEmpty,
           message.utf8.count <= 256,
           message.utf8.allSatisfy({ (0x20...0x7E).contains($0) }),
           !message.contains("://") {
            detail = message
        } else {
            detail = "secure HTTPS operation failed"
        }

        switch kind {
        case Int32(OG_HTTPS_FAILURE_UNREACHABLE):
            return .transport(TransportFailure(kind: .unreachable, detail: detail))
        case Int32(OG_HTTPS_FAILURE_CANCELLED):
            return .cancelled
        case Int32(OG_HTTPS_FAILURE_PERMANENT):
            return .transport(TransportFailure(kind: .permanent, detail: detail))
        default:
            return .transport(TransportFailure(kind: .interrupted, detail: detail))
        }
    }

    fileprivate static func policyFailure(_ detail: String) -> HTTPError {
        .transport(TransportFailure(kind: .permanent, detail: detail))
    }

    @discardableResult
    private func withState<Result>(_ body: (inout State) -> Result) -> Result {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body(&state)
    }
}

private func linuxEnterpriseHTTPSMetadataCallback(
    _ context: UnsafeMutableRawPointer?,
    _ status: Int,
    _ effectiveURL: UnsafePointer<CChar>?,
    _ headers: UnsafePointer<UInt8>?,
    _ length: Int
) -> Int32 {
    guard let context else { return 1 }
    let transfer = Unmanaged<LinuxEnterpriseHTTPTransfer>
        .fromOpaque(context)
        .takeUnretainedValue()
    return transfer.receiveMetadata(
        status: status,
        effectiveURL: effectiveURL,
        headers: headers,
        length: length
    )
}

private func linuxEnterpriseHTTPSBodyCallback(
    _ context: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<UInt8>?,
    _ length: Int
) -> Int32 {
    guard let context else { return 1 }
    return Unmanaged<LinuxEnterpriseHTTPTransfer>
        .fromOpaque(context)
        .takeUnretainedValue()
        .receiveBody(bytes, length: length)
}

#endif
