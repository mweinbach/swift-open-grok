#if os(Linux)
import Foundation
import FoundationNetworking
import Glibc
import Testing

@testable import OpenGrokHTTP

@Suite("Linux live enterprise HTTPS trust", .serialized)
struct LinuxEnterpriseHTTPTrustParityTests {
    @Test(
        "private CA HTTPS preserves request authority, headers, body, and configuration",
        .timeLimit(.minutes(1))
    )
    func bufferedHTTPSForwardsActualRequest() async throws {
        let responseBody = Data(#"{"trusted":true}"#.utf8)
        let fixture = try LinuxEnterpriseHTTPFixture(
            reply: .buffered(
                statusCode: 201,
                headers: ["Content-Type": "application/json", "X-Fixture": "preserved"],
                body: responseBody
            )
        )
        defer { fixture.stop() }
        try await fixture.waitUntilListening()

        let requestBody = Data(#"{"input":"body-secret"}"#.utf8)
        let configuration = HTTPTransportConfiguration(
            connectTimeout: 3,
            requestTimeout: 5,
            userAgent: "open-grok-enterprise-fixture/1.0",
            tls: HTTPTLSConfiguration(
                validateCertificates: true,
                minimumTLSVersion: "1.2",
                extraRootCertificates: [fixture.certificateDER]
            ),
            additionalHeaders: [
                "Authorization": "Bearer stale-configuration-secret",
                "X-Configuration": "configuration-value",
                "X-Override": "stale-configuration-value",
            ]
        )
        let transport = URLSessionHTTPTransport(configuration: configuration)
        let request = HTTPRequest(
            method: .post,
            url: try fixture.url(path: "/private?token=query-secret"),
            headers: [
                "authorization": "Bearer bearer-secret",
                "Content-Type": "application/json",
                "x-override": "request-value",
            ],
            body: requestBody
        )

        let response = try await transport.send(request)
        let recorded = try await fixture.recordedRequest()

        #expect(response.metadata.statusCode == 201)
        #expect(response.metadata.contentType == "application/json")
        #expect(response.body == responseBody)
        #expect(recorded.method == "POST")
        #expect(recorded.path == "/private?token=query-secret")
        #expect(recorded.body == requestBody)
        #expect(recorded.values(named: "Authorization") == ["Bearer bearer-secret"])
        #expect(recorded.values(named: "X-Override") == ["request-value"])
        #expect(recorded.values(named: "X-Configuration") == ["configuration-value"])
        #expect(recorded.values(named: "Content-Type") == ["application/json"])
        #expect(recorded.values(named: "User-Agent") == ["open-grok-enterprise-fixture/1.0"])
        #expect(recorded.values(named: "Host") == ["localhost:\(fixture.port)"])

        let snapshot = transport.appliedConfigurationSnapshot
        #expect(snapshot.tlsValidateCertificates)
        #expect(snapshot.tlsMinimumVersion == "1.2")
        #expect(snapshot.tlsExtraRootCertificateCount == 1)
        #expect(snapshot.connectTimeout == 3)
        #expect(snapshot.requestTimeout == 5)
    }

    @Test(
        "an explicitly trusted self-signed HTTPS certificate need not be a certificate authority",
        .timeLimit(.minutes(1))
    )
    func explicitlyTrustedNonCAAnchorAuthorizesHTTPS() async throws {
        let fixture = try LinuxEnterpriseHTTPFixture(reply: .ok, certificateAuthority: false)
        defer { fixture.stop() }
        try await fixture.waitUntilListening()

        let response = try await fixture.trustedTransport().send(
            HTTPRequest(method: .get, url: try fixture.url(path: "/trusted-leaf"))
        )
        let recorded = try await fixture.recordedRequest()

        #expect(response.metadata.statusCode == 200)
        #expect(response.body == Data("ok".utf8))
        #expect(recorded.method == "GET")
        #expect(recorded.path == "/trusted-leaf")
    }

    @Test(
        "private CA SSE delivers its first complete event while the HTTPS response remains open",
        .timeLimit(.minutes(1)),
        arguments: ["\n\n", "\r\n\r\n"]
    )
    func eventStreamFlushesBeforeCompletion(_ delimiter: String) async throws {
        let first = Data("data: enterprise-first\(delimiter)".utf8)
        let trailing = Data("data: enterprise-final\(delimiter)".utf8)
        let fixture = try LinuxEnterpriseHTTPFixture(reply: .eventStream(first: first, last: trailing))
        defer { fixture.stop() }
        try await fixture.waitUntilListening()

        let request = HTTPRequest(
            method: .get,
            url: try fixture.url(path: "/events"),
            headers: ["Authorization": "Bearer stream-secret", "Accept": "text/event-stream"]
        )
        var iterator = fixture.trustedTransport().stream(request).makeAsyncIterator()

        guard case .metadata(let metadata)? = try await iterator.next() else {
            throw LinuxEnterpriseHTTPFixtureError.unexpectedEvent("expected SSE response metadata")
        }
        #expect(metadata.statusCode == 200)
        #expect(metadata.isEventStream)

        guard case .body(let delivered)? = try await iterator.next() else {
            throw LinuxEnterpriseHTTPFixtureError.unexpectedEvent("expected the first SSE body")
        }
        #expect(delivered == first)
        #expect(!fixture.responseHasFinished)

        let recorded = try await fixture.recordedRequest()
        #expect(recorded.values(named: "Authorization") == ["Bearer stream-secret"])
        #expect(recorded.values(named: "Accept") == ["text/event-stream"])

        try fixture.finishEventStream()
        guard case .body(let deliveredTrailing)? = try await iterator.next() else {
            throw LinuxEnterpriseHTTPFixtureError.unexpectedEvent("expected the final SSE body")
        }
        #expect(deliveredTrailing == trailing)
        #expect(try await iterator.next() == .end)
        #expect(try await iterator.next() == nil)
        #expect(fixture.responseHasFinished)
    }

    @Test("an unrelated valid enterprise root cannot authorize a private HTTPS server", .timeLimit(.minutes(1)))
    func unrelatedRootFailsClosed() async throws {
        let fixture = try LinuxEnterpriseHTTPFixture(reply: .ok)
        defer { fixture.stop() }
        let unrelatedRoot = try fixture.makeUnrelatedCertificateDER()
        try await fixture.waitUntilListening()

        let transport = URLSessionHTTPTransport(
            configuration: fixture.configuration(extraRoots: [unrelatedRoot])
        )
        let request = HTTPRequest(
            method: .post,
            url: try fixture.url(path: "/private?token=query-secret"),
            headers: ["Authorization": "Bearer bearer-secret"],
            body: Data("body-secret".utf8)
        )

        do {
            let response = try await transport.send(request)
            Issue.record("an unrelated enterprise root unexpectedly authorized HTTP \(response.metadata.statusCode)")
        } catch {
            assertPermanentRedactedTrustFailure(error)
        }
        #expect(fixture.requestCount == 0)
    }

    @Test("a valid private root cannot disable HTTPS hostname verification", .timeLimit(.minutes(1)))
    func hostnameMismatchFailsClosed() async throws {
        let fixture = try LinuxEnterpriseHTTPFixture(reply: .ok)
        defer { fixture.stop() }
        try await fixture.waitUntilListening()

        let request = HTTPRequest(
            method: .post,
            url: try fixture.url(host: "127.0.0.1", path: "/private?token=query-secret"),
            headers: ["Authorization": "Bearer bearer-secret"],
            body: Data("body-secret".utf8)
        )

        do {
            let response = try await fixture.trustedTransport().send(request)
            Issue.record("a DNS-only localhost certificate unexpectedly authorized HTTP \(response.metadata.statusCode)")
        } catch {
            assertPermanentRedactedTrustFailure(error)
        }
        #expect(fixture.requestCount == 0)
    }

    @Test("ordinary system trust does not implicitly trust a private HTTPS root", .timeLimit(.minutes(1)))
    func absentEnterpriseRootRemainsStrict() async throws {
        let fixture = try LinuxEnterpriseHTTPFixture(reply: .ok)
        defer { fixture.stop() }
        try await fixture.waitUntilListening()

        let transport = URLSessionHTTPTransport(
            configuration: fixture.configuration(extraRoots: [])
        )

        do {
            let response = try await transport.send(
                HTTPRequest(method: .get, url: try fixture.url())
            )
            Issue.record("system trust unexpectedly accepted a private root with HTTP \(response.metadata.statusCode)")
        } catch let error as HTTPError {
            guard case .transport = error else {
                Issue.record("private-root rejection had an unexpected HTTP error: \(error)")
                return
            }
        } catch {
            Issue.record("private-root rejection had an unexpected error type")
        }
        #expect(fixture.requestCount == 0)
    }

    @Test("malformed private roots fail permanently before any HTTP credentials leave", .timeLimit(.minutes(1)))
    func malformedRootNeverSendsCredentials() async throws {
        let fixture = try LinuxEnterpriseHTTPFixture(reply: .ok)
        defer { fixture.stop() }
        try await fixture.waitUntilListening()

        let malformedRoot = Data([0x30, 0x03, 0x02, 0x01, 0x01])
        let transport = URLSessionHTTPTransport(
            configuration: fixture.configuration(extraRoots: [malformedRoot])
        )
        let request = HTTPRequest(
            method: .post,
            url: try fixture.url(path: "/private?token=query-secret"),
            headers: ["Authorization": "Bearer bearer-secret"],
            body: Data("body-secret".utf8)
        )

        do {
            let response = try await transport.send(request)
            Issue.record("a malformed enterprise root unexpectedly authorized HTTP \(response.metadata.statusCode)")
        } catch {
            assertPermanentRedactedTrustFailure(error)
        }
        #expect(fixture.requestCount == 0)
    }

    @Test("a caller-supplied URLSession retains exclusive TLS-policy authority", .timeLimit(.minutes(1)))
    func injectedSessionDoesNotAcquireEnterpriseTrust() async throws {
        let fixture = try LinuxEnterpriseHTTPFixture(reply: .ok)
        defer { fixture.stop() }
        try await fixture.waitUntilListening()

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let transport = URLSessionHTTPTransport(
            configuration: fixture.configuration(),
            session: session
        )

        do {
            let response = try await transport.send(
                HTTPRequest(method: .get, url: try fixture.url())
            )
            Issue.record("an explicit system-trust session unexpectedly used enterprise trust for HTTP \(response.metadata.statusCode)")
        } catch let error as HTTPError {
            guard case .transport = error else {
                Issue.record("caller-owned session produced an unexpected HTTP error: \(error)")
                return
            }
        } catch {
            Issue.record("caller-owned session produced an unexpected error type")
        }
        #expect(fixture.requestCount == 0)
    }

    @Test("enterprise HTTPS enforces its buffered response-byte ceiling", .timeLimit(.minutes(1)))
    func bufferedResponseLimitRemainsEnforced() async throws {
        let fixture = try LinuxEnterpriseHTTPFixture(
            reply: .buffered(statusCode: 200, headers: [:], body: Data(repeating: 0x61, count: 256))
        )
        defer { fixture.stop() }
        try await fixture.waitUntilListening()

        let transport = URLSessionHTTPTransport(
            configuration: fixture.configuration(maxResponseBytes: 32)
        )

        do {
            let response = try await transport.send(
                HTTPRequest(method: .get, url: try fixture.url(path: "/bounded"))
            )
            Issue.record("enterprise HTTPS retained \(response.body.count) bytes above its limit")
        } catch let error as HTTPError {
            #expect(error == .bufferExceeded(limit: 32))
        } catch {
            Issue.record("buffer overflow produced an unexpected error type")
        }
    }

    @Test("enterprise HTTPS enforces its pending streaming-byte ceiling", .timeLimit(.minutes(1)))
    func streamingResponseLimitRemainsEnforced() async throws {
        let fixture = try LinuxEnterpriseHTTPFixture(
            reply: .buffered(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: Data(repeating: 0x61, count: 256)
            )
        )
        defer { fixture.stop() }
        try await fixture.waitUntilListening()

        let transport = URLSessionHTTPTransport(
            configuration: fixture.configuration(maxStreamBufferBytes: 16)
        )
        let stream = transport.stream(
            HTTPRequest(method: .get, url: try fixture.url(path: "/bounded-events"))
        )
        let recorded = try await fixture.recordedRequest()
        #expect(recorded.path == "/bounded-events")
        try await Task.sleep(for: .milliseconds(50))
        var iterator = stream.makeAsyncIterator()

        do {
            var deliveredBytes = 0
            while let event = try await iterator.next() {
                if case .body(let body) = event {
                    deliveredBytes += body.count
                    #expect(deliveredBytes <= 16)
                }
            }
            Issue.record("enterprise HTTPS silently completed an oversized streaming response")
        } catch let error as HTTPError {
            #expect(error == .bufferExceeded(limit: 16))
        } catch {
            Issue.record("stream buffer overflow produced an unexpected error type")
        }
    }

    @Test("cancelling an open enterprise HTTPS event stream releases its producer", .timeLimit(.minutes(1)))
    func eventStreamCancellationStopsOpenResponse() async throws {
        let first = Data("data: first\n\n".utf8)
        let fixture = try LinuxEnterpriseHTTPFixture(
            reply: .eventStream(first: first, last: Data("data: never\n\n".utf8))
        )
        defer { fixture.stop() }
        try await fixture.waitUntilListening()

        let firstEventReceived = LinuxEnterpriseFirstEventSignal()
        let request = HTTPRequest(method: .get, url: try fixture.url(path: "/cancellable"))
        let transport = fixture.trustedTransport()
        let consumer = Task {
            var iterator = transport.stream(request).makeAsyncIterator()
            guard case .metadata? = try await iterator.next(),
                  case .body(let delivered)? = try await iterator.next(),
                  delivered == first
            else {
                throw LinuxEnterpriseHTTPFixtureError.unexpectedEvent("expected cancellable first event")
            }
            await firstEventReceived.signal()
            return try await iterator.next()
        }
        defer { consumer.cancel() }

        try await firstEventReceived.wait()
        #expect(!fixture.responseHasFinished)
        consumer.cancel()

        do {
            let unexpected = try await consumer.value
            Issue.record("cancelled enterprise stream unexpectedly produced \(String(describing: unexpected))")
        } catch let error as HTTPError {
            #expect(error == .cancelled)
        } catch is CancellationError {
        } catch {
            Issue.record("cancelled enterprise stream produced an unexpected error type")
        }
    }

    @Test("enterprise HTTPS does not follow redirects or replay private authorization", .timeLimit(.minutes(1)))
    func enterpriseHTTPSNeverFollowsRedirects() async throws {
        let fixture = try LinuxEnterpriseHTTPFixture(
            reply: .buffered(
                statusCode: 302,
                headers: ["Location": "https://127.0.0.1:9/private?token=redirect-secret"],
                body: Data()
            )
        )
        defer { fixture.stop() }
        try await fixture.waitUntilListening()

        let response = try await fixture.trustedTransport().send(
            HTTPRequest(
                method: .get,
                url: try fixture.url(path: "/redirect"),
                headers: ["Authorization": "Bearer redirect-bearer-secret"]
            )
        )
        let recorded = try await fixture.recordedRequest()

        #expect(response.metadata.statusCode == 302)
        #expect(fixture.requestCount == 1)
        #expect(recorded.values(named: "Authorization") == ["Bearer redirect-bearer-secret"])
    }

    @Test("enterprise roots remain additive and never mutate process-wide trust", .timeLimit(.minutes(1)))
    func enterpriseRootPreservesSystemTrustWithoutGlobalMutation() async throws {
        let fixture = try LinuxEnterpriseHTTPFixture(reply: .ok)
        defer { fixture.stop() }
        try await fixture.waitUntilListening()

        let environmentBefore = trustEnvironment()
        let systemBundleURL = try #require(
            FoundationTrustStoreBridge.systemBundleURL(
                environment: ProcessInfo.processInfo.environment
            )
        )
        let systemBundle = try Data(contentsOf: systemBundleURL)
        #expect(!systemBundle.isEmpty)

        let combined = try #require(
            try PortableTLSConnector.makeTrustBundle(
                systemRootPEM: systemBundle,
                extraRootCertificates: [fixture.certificateDER]
            )
        )
        #expect(combined.starts(with: systemBundle))
        #expect(combined.count > systemBundle.count)
        #expect(
            String(decoding: combined.suffix(4096), as: UTF8.self)
                .contains(fixture.certificateDER.base64EncodedString().prefix(32))
        )

        let response = try await fixture.trustedTransport().send(
            HTTPRequest(method: .get, url: try fixture.url())
        )
        #expect(response.metadata.statusCode == 200)
        #expect(trustEnvironment() == environmentBefore)
    }

    private func trustEnvironment() -> [String: String] {
        ProcessInfo.processInfo.environment.filter {
            $0.key == "CURL_CA_BUNDLE" || $0.key == "SSL_CERT_FILE"
        }
    }

    private func assertPermanentRedactedTrustFailure(_ error: any Error) {
        guard let httpError = error as? HTTPError,
              case .transport(let failure) = httpError
        else {
            Issue.record("expected a typed, permanent enterprise HTTPS trust failure")
            return
        }
        #expect(failure.kind == .permanent)
        #expect(!failure.isRetryable)
        #expect(!httpError.isRetryable)
        #expect(!failure.detail.contains("query-secret"))
        #expect(!failure.detail.contains("bearer-secret"))
        #expect(!failure.detail.contains("body-secret"))
        #expect(!failure.detail.contains("stale-configuration-secret"))
    }
}

private enum LinuxEnterpriseHTTPFixtureError: Error, CustomStringConvertible {
    case unavailable(String)
    case deadlineExceeded(String)
    case unexpectedEvent(String)

    var description: String {
        switch self {
        case .unavailable(let reason), .deadlineExceeded(let reason), .unexpectedEvent(let reason):
            return reason
        }
    }
}

private struct LinuxEnterpriseRecordedRequest: Sendable {
    let method: String
    let path: String
    let headers: [(String, String)]
    let body: Data

    func values(named name: String) -> [String] {
        headers.compactMap { header, value in
            header.caseInsensitiveCompare(name) == .orderedSame ? value : nil
        }
    }
}

private enum LinuxEnterpriseHTTPReply: Sendable {
    case buffered(statusCode: Int, headers: [String: String], body: Data)
    case eventStream(first: Data, last: Data)

    static var ok: Self {
        .buffered(statusCode: 200, headers: ["Content-Type": "text/plain"], body: Data("ok".utf8))
    }
}

private final class LinuxEnterpriseHTTPCapture: @unchecked Sendable {
    private struct State {
        var buffer = Data()
        var request: LinuxEnterpriseRecordedRequest?
        var failure: String?
        var responseFinished = false
        var stopping = false
    }

    private let lock = NSLock()
    private var state = State()
    private static let maximumRequestBytes = 1024 * 1024

    var request: LinuxEnterpriseRecordedRequest? {
        withState { $0.request }
    }

    var failure: String? {
        withState { $0.failure }
    }

    var responseFinished: Bool {
        withState { $0.responseFinished }
    }

    func markFinished() {
        withState { $0.responseFinished = true }
    }

    func stop() {
        withState { $0.stopping = true }
    }

    func fail(_ description: String) {
        withState { state in
            if state.failure == nil { state.failure = description }
        }
    }

    func receive(_ data: Data) -> Bool {
        withState { state in
            guard !state.stopping, state.request == nil, state.failure == nil else { return false }
            guard state.buffer.count <= Self.maximumRequestBytes - data.count else {
                state.failure = "fixture request exceeded its private capture limit"
                return false
            }
            state.buffer.append(data)
            guard let boundary = state.buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else {
                return false
            }
            guard let head = String(
                data: state.buffer.prefix(upTo: boundary.lowerBound),
                encoding: .utf8
            ) else {
                state.failure = "fixture request headers were not valid UTF-8"
                return false
            }
            let lines = head.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else {
                state.failure = "fixture request did not contain an HTTP request line"
                return false
            }
            let components = requestLine.split(separator: " ", omittingEmptySubsequences: true)
            guard components.count >= 2 else {
                state.failure = "fixture request contained a malformed HTTP request line"
                return false
            }

            let headers: [(String, String)] = lines.dropFirst().compactMap { line in
                guard let separator = line.firstIndex(of: ":") else { return nil }
                let name = String(line[..<separator])
                let value = String(line[line.index(after: separator)...])
                    .trimmingCharacters(in: .whitespaces)
                return (name, value)
            }
            let lengthValue = headers.first {
                $0.0.caseInsensitiveCompare("Content-Length") == .orderedSame
            }?.1 ?? "0"
            guard let bodyLength = Int(lengthValue),
                  bodyLength >= 0,
                  bodyLength <= Self.maximumRequestBytes
            else {
                state.failure = "fixture request contained an invalid Content-Length"
                return false
            }
            let available = state.buffer.count - boundary.upperBound
            guard available >= bodyLength else { return false }
            let body = state.buffer[boundary.upperBound..<(boundary.upperBound + bodyLength)]

            state.request = LinuxEnterpriseRecordedRequest(
                method: String(components[0]),
                path: String(components[1]),
                headers: headers,
                body: Data(body)
            )
            return true
        }
    }

    private func withState<Result>(_ body: (inout State) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}

private final class LinuxEnterpriseFixtureResponseWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var closed = false

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else {
            throw LinuxEnterpriseHTTPFixtureError.unavailable(
                "private HTTPS fixture response channel has closed"
            )
        }
        try handle.write(contentsOf: data)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        try? handle.close()
    }
}

private final class LinuxEnterpriseHTTPFixture: @unchecked Sendable {
    private static let openssl = "/usr/bin/openssl"

    let certificateDER: Data
    let port: UInt16

    private let directory: URL
    private let process: Process
    private let processFinished: DispatchSemaphore
    private let input: Pipe
    private let output: Pipe
    private let capture: LinuxEnterpriseHTTPCapture
    private let responseWriter: LinuxEnterpriseFixtureResponseWriter
    private let reply: LinuxEnterpriseHTTPReply
    private let stopLock = NSLock()
    private var stopped = false

    var requestCount: Int {
        capture.request == nil ? 0 : 1
    }

    var responseHasFinished: Bool {
        capture.responseFinished
    }

    init(reply: LinuxEnterpriseHTTPReply, certificateAuthority: Bool = true) throws {
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: Self.openssl) else {
            throw LinuxEnterpriseHTTPFixtureError.unavailable(
                "enterprise HTTPS regression requires /usr/bin/openssl"
            )
        }

        let directory = manager.temporaryDirectory.appendingPathComponent(
            "opengrok-enterprise-https-\(UUID().uuidString)",
            isDirectory: true
        )
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        do {
            let certificate = directory.appendingPathComponent("localhost.pem")
            let key = directory.appendingPathComponent("localhost.key")
            let certificateDER = try Self.generateCertificate(
                commonName: "localhost",
                certificate: certificate,
                key: key,
                certificateAuthority: certificateAuthority
            )

            let reservation = try PortableSocketListener.tcp(host: "127.0.0.1", port: 0)
            guard let port = reservation.port else {
                reservation.close()
                throw LinuxEnterpriseHTTPFixtureError.unavailable(
                    "could not reserve a private HTTPS fixture port"
                )
            }
            reservation.close()

            let input = Pipe()
            let output = Pipe()
            let capture = LinuxEnterpriseHTTPCapture()
            let responseWriter = LinuxEnterpriseFixtureResponseWriter(input.fileHandleForWriting)
            let initialResponse = Self.initialResponse(for: reply)
            output.fileHandleForReading.readabilityHandler = {
                [capture, responseWriter, initialResponse, reply] handle in
                let bytes = handle.availableData
                if bytes.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                guard capture.receive(bytes) else { return }
                do {
                    try responseWriter.write(initialResponse)
                    if case .buffered = reply {
                        capture.markFinished()
                    }
                } catch {
                    capture.fail("private HTTPS fixture could not send its response")
                }
            }

            let finished = DispatchSemaphore(value: 0)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.openssl)
            process.arguments = [
                "s_server",
                "-accept", "127.0.0.1:\(port)",
                "-cert", certificate.path,
                "-key", key.path,
                "-quiet",
            ]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in finished.signal() }

            do {
                try process.run()
            } catch {
                output.fileHandleForReading.readabilityHandler = nil
                throw error
            }

            self.directory = directory
            self.certificateDER = certificateDER
            self.port = port
            self.process = process
            self.processFinished = finished
            self.input = input
            self.output = output
            self.capture = capture
            self.responseWriter = responseWriter
            self.reply = reply
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    func url(host: String = "localhost", path: String = "/") throws -> URL {
        guard let url = URL(string: "https://\(host):\(port)\(path)") else {
            throw LinuxEnterpriseHTTPFixtureError.unavailable("invalid private HTTPS fixture URL")
        }
        return url
    }

    func configuration(
        extraRoots: [Data]? = nil,
        maxResponseBytes: Int = 64 * 1024,
        maxStreamBufferBytes: Int = 64 * 1024
    ) -> HTTPTransportConfiguration {
        HTTPTransportConfiguration(
            connectTimeout: 3,
            requestTimeout: 5,
            maxResponseBytes: maxResponseBytes,
            maxStreamBufferBytes: maxStreamBufferBytes,
            tls: HTTPTLSConfiguration(
                validateCertificates: true,
                extraRootCertificates: extraRoots ?? [certificateDER]
            )
        )
    }

    func trustedTransport() -> URLSessionHTTPTransport {
        URLSessionHTTPTransport(configuration: configuration())
    }

    func waitUntilListening() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        let address = "0100007F:\(String(format: "%04X", port))"

        while clock.now < deadline {
            guard process.isRunning else {
                throw LinuxEnterpriseHTTPFixtureError.unavailable(
                    "private HTTPS fixture exited before becoming ready"
                )
            }
            let sockets = try String(contentsOfFile: "/proc/net/tcp", encoding: .utf8)
            let ready = sockets.split(whereSeparator: \.isNewline).contains { line in
                let columns = line.split(whereSeparator: \.isWhitespace)
                return columns.count > 3 && columns[1] == address && columns[3] == "0A"
            }
            if ready { return }
            try await Task.sleep(for: .milliseconds(25))
        }

        throw LinuxEnterpriseHTTPFixtureError.deadlineExceeded(
            "private HTTPS fixture did not begin listening within five seconds"
        )
    }

    func recordedRequest() async throws -> LinuxEnterpriseRecordedRequest {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))

        while clock.now < deadline {
            if let request = capture.request { return request }
            if let failure = capture.failure {
                throw LinuxEnterpriseHTTPFixtureError.unavailable(failure)
            }
            try await Task.sleep(for: .milliseconds(15))
        }

        throw LinuxEnterpriseHTTPFixtureError.deadlineExceeded(
            "private HTTPS fixture did not observe its plaintext request"
        )
    }

    func makeUnrelatedCertificateDER() throws -> Data {
        try Self.generateCertificate(
            commonName: "unrelated-private-root",
            certificate: directory.appendingPathComponent("unrelated.pem"),
            key: directory.appendingPathComponent("unrelated.key")
        )
    }

    func finishEventStream() throws {
        guard case .eventStream(_, let last) = reply else {
            throw LinuxEnterpriseHTTPFixtureError.unavailable(
                "cannot finish an event stream for a buffered fixture"
            )
        }
        guard !capture.responseFinished else { return }
        try responseWriter.write(last)
        capture.markFinished()
    }

    func stop() {
        stopLock.lock()
        guard !stopped else {
            stopLock.unlock()
            return
        }
        stopped = true
        stopLock.unlock()

        capture.stop()
        output.fileHandleForReading.readabilityHandler = nil
        responseWriter.close()

        if process.isRunning {
            process.terminate()
            if processFinished.wait(timeout: .now() + 2) == .timedOut {
                let killed = Glibc.kill(process.processIdentifier, SIGKILL)
                if killed != 0 && errno != ESRCH {
                    Issue.record("could not terminate the private HTTPS fixture")
                }
                if processFinished.wait(timeout: .now() + 2) == .timedOut {
                    Issue.record("private HTTPS fixture did not stop within its bounded deadline")
                }
            }
        }

        try? output.fileHandleForReading.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private static func initialResponse(for reply: LinuxEnterpriseHTTPReply) -> Data {
        let statusCode: Int
        var headers: [String: String]
        let firstBody: Data
        let totalLength: Int

        switch reply {
        case .buffered(let status, let configuredHeaders, let body):
            statusCode = status
            headers = configuredHeaders
            firstBody = body
            totalLength = body.count
        case .eventStream(let first, let last):
            statusCode = 200
            headers = ["Content-Type": "text/event-stream", "Cache-Control": "no-cache"]
            firstBody = first
            totalLength = first.count + last.count
        }

        headers["Content-Length"] = String(totalLength)
        headers["Connection"] = "close"
        let statusText: String
        switch statusCode {
        case 200: statusText = "OK"
        case 201: statusText = "Created"
        case 302: statusText = "Found"
        default: statusText = "Fixture"
        }

        var head = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        for key in headers.keys.sorted() {
            guard let value = headers[key] else { continue }
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"
        var bytes = Data(head.utf8)
        bytes.append(firstBody)
        return bytes
    }

    private static func generateCertificate(
        commonName: String,
        certificate: URL,
        key: URL,
        certificateAuthority: Bool = true
    ) throws -> Data {
        let basicConstraints = certificateAuthority
            ? "basicConstraints=critical,CA:TRUE"
            : "basicConstraints=critical,CA:FALSE"

        try runOpenSSL([
            "req",
            "-x509",
            "-newkey", "rsa:2048",
            "-noenc",
            "-days", "1",
            "-subj", "/CN=\(commonName)",
            "-addext", "subjectAltName=DNS:\(commonName)",
            "-addext", basicConstraints,
            "-keyout", key.path,
            "-out", certificate.path,
        ])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: key.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: certificate.path
        )

        let pem = String(decoding: try Data(contentsOf: certificate), as: UTF8.self)
        let encoded = pem.split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let der = Data(base64Encoded: encoded), !der.isEmpty else {
            throw LinuxEnterpriseHTTPFixtureError.unavailable(
                "could not decode the private HTTPS fixture certificate"
            )
        }
        return der
    }

    private static func runOpenSSL(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: openssl)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()

        guard finished.wait(timeout: .now() + 15) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                let killed = Glibc.kill(process.processIdentifier, SIGKILL)
                if killed != 0 && errno != ESRCH {
                    throw LinuxEnterpriseHTTPFixtureError.unavailable(
                        "could not terminate the private certificate generator"
                    )
                }
                guard finished.wait(timeout: .now() + 2) == .success else {
                    throw LinuxEnterpriseHTTPFixtureError.deadlineExceeded(
                        "private certificate generator did not stop"
                    )
                }
            }
            throw LinuxEnterpriseHTTPFixtureError.deadlineExceeded(
                "private certificate generation exceeded its bounded deadline"
            )
        }

        guard process.terminationStatus == 0 else {
            throw LinuxEnterpriseHTTPFixtureError.unavailable(
                "private certificate generator exited with status \(process.terminationStatus)"
            )
        }
    }
}

private actor LinuxEnterpriseFirstEventSignal {
    private var signalled = false

    func signal() {
        signalled = true
    }

    func wait() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !signalled {
            guard clock.now < deadline else {
                throw LinuxEnterpriseHTTPFixtureError.deadlineExceeded(
                    "enterprise event-stream cancellation probe did not receive its first event"
                )
            }
            try await Task.sleep(for: .milliseconds(15))
        }
    }
}
#endif
