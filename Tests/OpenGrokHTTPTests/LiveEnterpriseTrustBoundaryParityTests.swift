import Foundation
import Testing
@testable import OpenGrokHTTP

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Darwin)

@Suite("Live enterprise TLS trust boundary", .serialized)
struct LiveEnterpriseTrustBoundaryParityTests {
    @Test("buffered requests reject unsupported enterprise roots before URLProtocol")
    func bufferedRequestNeverLeavesUnsupportedTrustBoundary() async throws {
        let fixture = EnterpriseTrustFixture()
        defer { fixture.session.invalidateAndCancel() }

        do {
            _ = try await fixture.transport.send(fixture.request)
            Issue.record("buffered request unexpectedly bypassed the enterprise trust boundary")
        } catch {
            assertPermanentTrustFailure(error)
        }

        #expect(EnterpriseTrustRecordingURLProtocol.requestCount == 0)
        #expect(await sessionTaskCount(fixture.session) == 0)
    }

    @Test("enterprise trust failure is terminal and never enters retry backoff")
    func unsupportedTrustCannotRetryOrExposeCredentials() async throws {
        let fixture = EnterpriseTrustFixture()
        defer { fixture.session.invalidateAndCancel() }
        let retrySleeps = EnterpriseTrustCounter()

        do {
            _ = try await sendWithRetry(
                transport: fixture.transport,
                request: fixture.request,
                policy: HTTPRetryPolicy(maxAttempts: 4),
                sleeper: { _ in retrySleeps.increment() }
            )
            Issue.record("retry orchestration unexpectedly bypassed the enterprise trust boundary")
        } catch {
            assertPermanentTrustFailure(error)
        }

        #expect(retrySleeps.value == 0)
        #expect(EnterpriseTrustRecordingURLProtocol.requestCount == 0)
        #expect(await sessionTaskCount(fixture.session) == 0)
    }

    @Test("event streams reject unsupported roots without creating producers or session tasks")
    func eventStreamNeverStartsUnsupportedTrustRequest() async throws {
        let fixture = EnterpriseTrustFixture()
        defer { fixture.session.invalidateAndCancel() }

        let stream = fixture.transport.stream(fixture.request)
        #expect(EnterpriseTrustRecordingURLProtocol.requestCount == 0)
        #expect(await sessionTaskCount(fixture.session) == 0)

        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            Issue.record("event stream unexpectedly bypassed the enterprise trust boundary")
        } catch {
            assertPermanentTrustFailure(error)
        }

        #expect(EnterpriseTrustRecordingURLProtocol.requestCount == 0)
        #expect(await sessionTaskCount(fixture.session) == 0)
    }

    @Test("WebSocket connections reject unsupported roots before task creation")
    func webSocketNeverCreatesUnsupportedTrustTask() async throws {
        let fixture = EnterpriseTrustFixture()
        defer { fixture.session.invalidateAndCancel() }

        var request = URLRequest(
            url: URL(string: "wss://enterprise-trust-boundary.test/socket?token=query-secret")!
        )
        request.setValue("Bearer bearer-secret", forHTTPHeaderField: "Authorization")

        do {
            _ = try URLSessionWebSocketClient.connect(
                preparedSession: fixture.session,
                request: request,
                delegate: fixture.delegate,
                snapshot: HTTPSessionConfigurationBuilder.snapshot(fixture.configuration)
            )
            Issue.record("WebSocket unexpectedly bypassed the enterprise trust boundary")
        } catch {
            assertPermanentTrustFailure(error)
        }

        #expect(EnterpriseTrustRecordingURLProtocol.requestCount == 0)
        #expect(await sessionTaskCount(fixture.session) == 0)
    }

    @Test("ordinary system-trust requests remain usable with no enterprise roots")
    func emptyAdditionalRootsDoNotBlockOrdinaryRequests() async throws {
        let fixture = EnterpriseTrustFixture(extraRootCertificates: [])
        defer { fixture.session.invalidateAndCancel() }

        let response = try await fixture.transport.send(fixture.request)

        #expect(response.metadata.statusCode == 200)
        #expect(response.body == Data("trusted fixture response".utf8))
        #expect(EnterpriseTrustRecordingURLProtocol.requestCount == 1)
    }

    @Test("Darwin session-local enterprise roots remain usable")
    func darwinSupportedTrustStillSendsRequests() async throws {
        let fixture = EnterpriseTrustFixture(additionalTrustRootsApplied: true)
        defer { fixture.session.invalidateAndCancel() }

        let response = try await fixture.transport.send(fixture.request)

        #expect(response.metadata.statusCode == 200)
        #expect(EnterpriseTrustRecordingURLProtocol.requestCount == 1)
    }

    @Test("caller-supplied sessions retain explicit ownership of their TLS policy")
    func explicitSessionPolicyRemainsUntouched() async throws {
        let fixture = EnterpriseTrustFixture()
        defer { fixture.session.invalidateAndCancel() }
        let transport = URLSessionHTTPTransport(
            configuration: fixture.configuration,
            session: fixture.session
        )

        let response = try await transport.send(fixture.request)

        #expect(response.metadata.statusCode == 200)
        #expect(EnterpriseTrustRecordingURLProtocol.requestCount == 1)
    }

    private func assertPermanentTrustFailure(_ error: any Error) {
        guard let httpError = error as? HTTPError,
              case .transport(let failure) = httpError
        else {
            Issue.record("expected a typed permanent HTTP transport failure")
            return
        }

        #expect(failure.kind == .permanent)
        #expect(!failure.isRetryable)
        #expect(!httpError.isRetryable)
        #expect(
            failure.detail == "configured additional TLS trust roots are unavailable on this platform"
        )
        #expect(!failure.detail.contains("enterprise-trust-boundary.test"))
        #expect(!failure.detail.contains("bearer-secret"))
        #expect(!failure.detail.contains("api-key-secret"))
        #expect(!failure.detail.contains("query-secret"))
        #expect(!failure.detail.contains("body-secret"))
    }

    private func sessionTaskCount(_ session: URLSession) async -> Int {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: tasks.count)
            }
        }
    }
}

private struct EnterpriseTrustFixture {
    let configuration: HTTPTransportConfiguration
    let session: URLSession
    let delegate: HTTPTransportSessionDelegate
    let transport: URLSessionHTTPTransport
    let request: HTTPRequest

    init(
        extraRootCertificates: [Data] = [Data([0x30, 0x03, 0x02, 0x01, 0x01])],
        additionalTrustRootsApplied: Bool = false
    ) {
        EnterpriseTrustRecordingURLProtocol.reset()

        self.configuration = HTTPTransportConfiguration(
            tls: HTTPTLSConfiguration(
                validateCertificates: true,
                extraRootCertificates: extraRootCertificates
            )
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [EnterpriseTrustRecordingURLProtocol.self]
        self.session = URLSession(configuration: sessionConfiguration)
        self.delegate = HTTPTransportSessionDelegate(
            validateCertificates: true,
            extraRootCertificates: extraRootCertificates,
            additionalTrustRootsApplied: additionalTrustRootsApplied
        )
        self.transport = URLSessionHTTPTransport(
            configuration: configuration,
            session: session,
            sessionDelegate: delegate
        )
        self.request = HTTPRequest(
            method: .post,
            url: URL(
                string: "https://enterprise-trust-boundary.test/private?token=query-secret"
            )!,
            headers: [
                "Authorization": "Bearer bearer-secret",
                "X-Api-Key": "api-key-secret",
            ],
            body: Data("body-secret".utf8)
        )
    }
}

private final class EnterpriseTrustCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        count = 0
    }
}

private final class EnterpriseTrustRecordingURLProtocol: URLProtocol, @unchecked Sendable {
    private static let counter = EnterpriseTrustCounter()

    static var requestCount: Int {
        counter.value
    }

    static func reset() {
        counter.reset()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "enterprise-trust-boundary.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.counter.increment()
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "text/plain"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("trusted fixture response".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

#elseif os(Linux)

@Suite("Live Linux enterprise TLS trust boundary")
struct LiveLinuxEnterpriseTrustBoundaryParityTests {
    private var configuration: HTTPTransportConfiguration {
        HTTPTransportConfiguration(
            tls: HTTPTLSConfiguration(
                validateCertificates: true,
                extraRootCertificates: [Data([0x30, 0x03, 0x02, 0x01, 0x01])]
            )
        )
    }

    private var request: HTTPRequest {
        HTTPRequest(
            method: .post,
            url: URL(string: "https://127.0.0.1:9/private?token=query-secret")!,
            headers: ["Authorization": "Bearer bearer-secret"],
            body: Data("body-secret".utf8)
        )
    }

    @Test("the actual Linux buffered transport refuses configured unsupported roots")
    func bufferedTransportFailsClosedBeforeNetwork() async {
        do {
            _ = try await URLSessionHTTPTransport(configuration: configuration).send(request)
            Issue.record("Linux buffered transport ignored configured enterprise roots")
        } catch {
            assertPermanentTrustFailure(error)
        }
    }

    @Test("the actual Linux streaming transport refuses before a data task starts")
    func streamingTransportFailsClosedBeforeNetwork() async {
        var iterator = URLSessionHTTPTransport(configuration: configuration)
            .stream(request)
            .makeAsyncIterator()
        do {
            _ = try await iterator.next()
            Issue.record("Linux streaming transport ignored configured enterprise roots")
        } catch {
            assertPermanentTrustFailure(error)
        }
    }

    @Test("the actual Linux WebSocket transport refuses before its socket task starts")
    func webSocketTransportFailsClosedBeforeNetwork() {
        do {
            _ = try URLSessionWebSocketClient.connect(
                url: URL(string: "wss://127.0.0.1:9/socket?token=query-secret")!,
                configuration: configuration,
                headers: ["Authorization": "Bearer bearer-secret"]
            )
            Issue.record("Linux WebSocket transport ignored configured enterprise roots")
        } catch {
            assertPermanentTrustFailure(error)
        }
    }

    private func assertPermanentTrustFailure(_ error: any Error) {
        guard let httpError = error as? HTTPError,
              case .transport(let failure) = httpError
        else {
            Issue.record("expected a typed Linux enterprise trust refusal, got \(error)")
            return
        }
        #expect(failure.kind == .permanent)
        #expect(!failure.isRetryable)
        #expect(!httpError.isRetryable)
        #expect(!failure.detail.contains("query-secret"))
        #expect(!failure.detail.contains("bearer-secret"))
        #expect(!failure.detail.contains("body-secret"))
    }
}

#endif
