import Foundation
import Testing
@testable import OpenGrokHTTP

#if canImport(Darwin)

@Suite("Darwin HTTP event-stream flushing")
struct HTTPEventStreamFlushParityTests {
    @Test("LF-delimited events arrive before an open response finishes")
    func lfEventFlushesBeforeEOF() async throws {
        let first = Data("data: first\n\n".utf8)
        let second = Data("data: second\n\n".utf8)

        try await withEventStreamFixture(
            contentType: "text/event-stream",
            initialChunks: [first],
            remainingChunks: [second]
        ) { transport, fixture in
            var iterator = transport.stream(fixture.request).makeAsyncIterator()
            guard case .metadata(let metadata)? = try await iterator.next() else {
                throw HTTPEventStreamFixtureError.unexpectedEvent
            }
            #expect(metadata.isEventStream)

            guard case .body(let delivered)? = try await iterator.next() else {
                throw HTTPEventStreamFixtureError.unexpectedEvent
            }
            #expect(delivered == first)
            #expect(await fixture.responseHasFinished() == false)

            await fixture.finish()
            guard case .body(let trailing)? = try await iterator.next() else {
                throw HTTPEventStreamFixtureError.unexpectedEvent
            }
            #expect(trailing == second)
            #expect(try await iterator.next() == .end)
            #expect(try await iterator.next() == nil)
        }
    }

    @Test("split CRLF delimiters and UTF-8 retain exact event bytes")
    func splitCRLFEventFlushesBeforeEOF() async throws {
        let accented = Data("é".utf8)
        let fragments = [
            Data("event: progress\r\ndata: caf".utf8),
            Data(accented.prefix(1)),
            Data(accented.suffix(1)),
            Data("\r".utf8),
            Data("\n\r".utf8),
            Data("\n".utf8),
        ]
        let expected = fragments.reduce(into: Data()) { $0.append($1) }
        let trailing = Data("data: complete\r\n\r\n".utf8)

        try await withEventStreamFixture(
            contentType: "TEXT/EVENT-STREAM; charset=utf-8",
            initialChunks: fragments,
            remainingChunks: [trailing]
        ) { transport, fixture in
            var iterator = transport.stream(fixture.request).makeAsyncIterator()
            guard case .metadata(let metadata)? = try await iterator.next() else {
                throw HTTPEventStreamFixtureError.unexpectedEvent
            }
            #expect(metadata.isEventStream)

            guard case .body(let delivered)? = try await iterator.next() else {
                throw HTTPEventStreamFixtureError.unexpectedEvent
            }
            #expect(delivered == expected)
            #expect(await fixture.responseHasFinished() == false)

            await fixture.finish()
            guard case .body(let deliveredTrailing)? = try await iterator.next() else {
                throw HTTPEventStreamFixtureError.unexpectedEvent
            }
            #expect(deliveredTrailing == trailing)
            #expect(try await iterator.next() == .end)
        }
    }

    @Test("unterminated events flush at the configured bounded chunk size")
    func oversizedPartialEventFlushesBeforeEOF() async throws {
        let partial = Data(repeating: 0x61, count: 32)
        let delimiter = Data("\n\n".utf8)

        try await withEventStreamFixture(
            contentType: "text/event-stream",
            initialChunks: [partial],
            remainingChunks: [delimiter],
            maxPendingBytes: partial.count
        ) { transport, fixture in
            var iterator = transport.stream(fixture.request).makeAsyncIterator()
            guard case .metadata? = try await iterator.next() else {
                throw HTTPEventStreamFixtureError.unexpectedEvent
            }
            guard case .body(let delivered)? = try await iterator.next() else {
                throw HTTPEventStreamFixtureError.unexpectedEvent
            }
            #expect(delivered == partial)
            #expect(await fixture.responseHasFinished() == false)

            await fixture.finish()
            guard case .body(let deliveredDelimiter)? = try await iterator.next() else {
                throw HTTPEventStreamFixtureError.unexpectedEvent
            }
            #expect(deliveredDelimiter == delimiter)
            #expect(try await iterator.next() == .end)
        }
    }

    @Test("non-SSE responses retain existing batched body delivery")
    func ordinaryResponseRemainsBatched() async throws {
        let first = Data(#"{"first":true,"#.utf8)
        let second = Data(#""second":true}"#.utf8)

        try await withEventStreamFixture(
            contentType: "application/json",
            initialChunks: [first],
            remainingChunks: [second]
        ) { transport, fixture in
            var iterator = transport.stream(fixture.request).makeAsyncIterator()
            guard case .metadata(let metadata)? = try await iterator.next() else {
                throw HTTPEventStreamFixtureError.unexpectedEvent
            }
            #expect(metadata.isEventStream == false)

            await fixture.waitForInitialDelivery()
            #expect(await fixture.responseHasFinished() == false)
            await fixture.finish()

            guard case .body(let delivered)? = try await iterator.next() else {
                throw HTTPEventStreamFixtureError.unexpectedEvent
            }
            #expect(delivered == first + second)
            #expect(try await iterator.next() == .end)
        }
    }
}

private enum HTTPEventStreamFixtureError: Error {
    case deadlineExceeded
    case unexpectedEvent
}

private actor HTTPEventStreamFixtureRegistry {
    static let shared = HTTPEventStreamFixtureRegistry()

    private var fixtures: [URL: HTTPEventStreamFixture] = [:]

    func install(_ fixture: HTTPEventStreamFixture) {
        fixtures[fixture.url] = fixture
    }

    func fixture(for url: URL) -> HTTPEventStreamFixture? {
        fixtures[url]
    }

    func remove(_ url: URL) {
        fixtures.removeValue(forKey: url)
    }
}

private actor HTTPEventStreamFixture {
    nonisolated let url: URL

    private let contentType: String
    private let initialChunks: [Data]
    private let remainingChunks: [Data]
    private var initialDeliveryFinished = false
    private var responseFinished = false
    private var finishRequested = false
    private var cancelled = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var initialDeliveryContinuation: CheckedContinuation<Void, Never>?

    nonisolated var request: HTTPRequest {
        HTTPRequest(method: .get, url: url)
    }

    init(contentType: String, initialChunks: [Data], remainingChunks: [Data]) {
        self.url = URL(
            string: "https://opengrok-event-stream.test/\(UUID().uuidString)"
        )!
        self.contentType = contentType
        self.initialChunks = initialChunks
        self.remainingChunks = remainingChunks
    }

    func start(using reference: HTTPEventStreamProtocolReference) async {
        guard let protocolInstance = reference.value else { return }
        guard !cancelled else { return }

        protocolInstance.sendResponse(url: url, contentType: contentType)
        for chunk in initialChunks {
            protocolInstance.send(chunk)
        }
        initialDeliveryFinished = true
        initialDeliveryContinuation?.resume()
        initialDeliveryContinuation = nil

        if !finishRequested && !cancelled {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }

        guard !cancelled else { return }
        for chunk in remainingChunks {
            protocolInstance.send(chunk)
        }
        responseFinished = true
        protocolInstance.finishLoading()
    }

    func waitForInitialDelivery() async {
        guard !initialDeliveryFinished && !cancelled else { return }
        await withCheckedContinuation { continuation in
            initialDeliveryContinuation = continuation
        }
    }

    func responseHasFinished() -> Bool {
        responseFinished
    }

    func finish() {
        finishRequested = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func cancel() {
        cancelled = true
        initialDeliveryContinuation?.resume()
        initialDeliveryContinuation = nil
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class HTTPEventStreamProtocolReference: @unchecked Sendable {
    weak var value: HTTPEventStreamURLProtocol?

    init(_ value: HTTPEventStreamURLProtocol) {
        self.value = value
    }
}

private final class HTTPEventStreamURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "opengrok-event-stream.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else { return }
        let reference = HTTPEventStreamProtocolReference(self)
        Task { [reference] in
            guard let fixture = await HTTPEventStreamFixtureRegistry.shared.fixture(for: url) else {
                if let protocolInstance = reference.value {
                    protocolInstance.client?.urlProtocol(
                        protocolInstance,
                        didFailWithError: URLError(.resourceUnavailable)
                    )
                }
                return
            }
            await fixture.start(using: reference)
        }
    }

    override func stopLoading() {
        guard let url = request.url else { return }
        Task {
            guard let fixture = await HTTPEventStreamFixtureRegistry.shared.fixture(for: url) else {
                return
            }
            await fixture.cancel()
        }
    }

    func sendResponse(url: URL, contentType: String) {
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    func send(_ data: Data) {
        client?.urlProtocol(self, didLoad: data)
    }

    func finishLoading() {
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func withEventStreamFixture(
    contentType: String,
    initialChunks: [Data],
    remainingChunks: [Data],
    maxPendingBytes: Int = 4 * 1024 * 1024,
    operation: @escaping @Sendable (
        URLSessionHTTPTransport,
        HTTPEventStreamFixture
    ) async throws -> Void
) async throws {
    let fixture = HTTPEventStreamFixture(
        contentType: contentType,
        initialChunks: initialChunks,
        remainingChunks: remainingChunks
    )
    await HTTPEventStreamFixtureRegistry.shared.install(fixture)

    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [HTTPEventStreamURLProtocol.self]
    let session = URLSession(configuration: sessionConfiguration)
    defer { session.invalidateAndCancel() }

    let transport = URLSessionHTTPTransport(
        configuration: HTTPTransportConfiguration(maxStreamBufferBytes: maxPendingBytes),
        session: session
    )

    do {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await operation(transport, fixture)
                return true
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                await fixture.finish()
                throw HTTPEventStreamFixtureError.deadlineExceeded
            }

            guard try await group.next() == true else {
                throw HTTPEventStreamFixtureError.deadlineExceeded
            }
            group.cancelAll()
        }
    } catch {
        await fixture.cancel()
        await HTTPEventStreamFixtureRegistry.shared.remove(fixture.url)
        throw error
    }

    await fixture.finish()
    await HTTPEventStreamFixtureRegistry.shared.remove(fixture.url)
}

#endif
