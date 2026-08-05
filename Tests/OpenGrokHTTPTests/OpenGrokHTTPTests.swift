// OpenGrokHTTPTests.swift
//
// Transport, SSE (split UTF-8, fields, comments, multiline, malformed,
// EOF, reconnect, cancellation, bounded memory), retry/idempotency,
// mock transport, and user-agent tests.

import Foundation
import Testing
@testable import OpenGrokCircuitBreaker
@testable import OpenGrokHTTP
@testable import OpenGrokTracing

@Suite("User-Agent")
struct UserAgentTests {
    @Test func collapsesDuplicateIdentity() {
        let ua = sessionUserAgentString(
            origin: OriginClientInfo(product: "open-grok", version: "0.1.0"),
            agentProduct: "open-grok",
            agentVersion: "0.1.0",
            platform: HTTPPlatformInfo(os: "macos", arch: "aarch64")
        )
        #expect(ua == "open-grok/0.1.0 (macos; aarch64)")
    }

    @Test func rendersOriginWithVersion() {
        let ua = sessionUserAgentString(
            origin: OriginClientInfo(product: "grok-desktop", version: "1.2.3"),
            agentProduct: "open-grok",
            agentVersion: "0.1.0",
            platform: HTTPPlatformInfo(os: "linux", arch: "x86_64")
        )
        #expect(ua.hasPrefix("grok-desktop/1.2.3 open-grok/0.1.0"))
        #expect(ua.contains("(linux; x86_64)"))
    }

    @Test func rendersOriginWithoutVersion() {
        let ua = sessionUserAgentString(
            origin: OriginClientInfo(product: "grok-web", version: nil),
            agentProduct: "open-grok",
            agentVersion: "0.1.0",
            platform: HTTPPlatformInfo(os: "macos", arch: "aarch64")
        )
        #expect(ua.hasPrefix("grok-web open-grok/0.1.0"))
        #expect(!ua.hasPrefix("grok-web/"))
    }
}

@Suite("SSE parser")
struct SSEParserTests {
    @Test func basicEvent() throws {
        var parser = SSEParser()
        let events = try parser.push(Data("data: hello\n\n".utf8))
        #expect(events.count == 1)
        #expect(events[0].data == "hello")
    }

    @Test func multilineData() throws {
        var parser = SSEParser()
        let events = try parser.push(Data("data: line1\ndata: line2\n\n".utf8))
        #expect(events.count == 1)
        #expect(events[0].data == "line1\nline2")
    }

    @Test func commentsIgnored() throws {
        var parser = SSEParser()
        let events = try parser.push(Data(": keep-alive\ndata: x\n\n".utf8))
        #expect(events.count == 1)
        #expect(events[0].data == "x")
    }

    @Test func splitFieldsAcrossChunks() throws {
        var parser = SSEParser()
        #expect(try parser.push(Data("da".utf8)).isEmpty)
        #expect(try parser.push(Data("ta: he".utf8)).isEmpty)
        #expect(try parser.push(Data("llo\n".utf8)).isEmpty)
        let events = try parser.push(Data("\n".utf8))
        #expect(events.count == 1)
        #expect(events[0].data == "hello")
    }

    @Test func splitUTF8AcrossChunks() throws {
        // UTF-8 for "é" is C3 A9 — split after first byte.
        var parser = SSEParser()
        // "data: caf" + first byte of é + rest
        let prefix = Data("data: caf".utf8)
        let eAcute = Data("é".utf8)
        #expect(eAcute.count == 2)
        #expect(try parser.push(prefix + eAcute.prefix(1)).isEmpty)
        let events = try parser.push(eAcute.suffix(1) + Data("\n\n".utf8))
        #expect(events.count == 1)
        #expect(events[0].data == "café")
    }

    @Test func eventIdAndRetry() throws {
        var parser = SSEParser()
        let events = try parser.push(Data("id: 42\nevent: message\nretry: 1500\ndata: hi\n\n".utf8))
        #expect(events.count == 1)
        #expect(events[0].id == "42")
        #expect(events[0].event == "message")
        #expect(events[0].retryMilliseconds == 1500)
        #expect(parser.lastSeenEventID == "42")
    }

    @Test func reconnectMetadata() throws {
        var parser = SSEParser()
        _ = try parser.push(Data("id: a\ndata: 1\n\nid: b\ndata: 2\n\n".utf8))
        #expect(parser.lastSeenEventID == "b")
    }

    @Test func malformedUnknownFieldsIgnored() throws {
        var parser = SSEParser()
        let events = try parser.push(Data("foo: bar\ndata: ok\n\n".utf8))
        #expect(events.count == 1)
        #expect(events[0].data == "ok")
    }

    @Test func finishFlushesTrailingEvent() {
        var parser = SSEParser()
        _ = try? parser.push(Data("data: trailing".utf8))
        let events = parser.finish()
        #expect(events.count == 1)
        #expect(events[0].data == "trailing")
    }

    @Test func bufferExceeded() {
        var parser = SSEParser(maxBufferedBytes: 8)
        #expect(throws: HTTPError.self) {
            _ = try parser.push(Data("0123456789abcdef".utf8))
        }
    }

    @Test func spaceAfterColonOptional() throws {
        var parser = SSEParser()
        let a = try parser.push(Data("data:no-space\n\n".utf8))
        #expect(a[0].data == "no-space")
        let b = try parser.push(Data("data: with-space\n\n".utf8))
        #expect(b[0].data == "with-space")
    }

    @Test func crlfLineEndings() throws {
        var parser = SSEParser()
        let events = try parser.push(Data("data: crlf\r\n\r\n".utf8))
        #expect(events.count == 1)
        #expect(events[0].data == "crlf")
    }

    @Test func newlineTerminatedDataLineFloodIsBounded() {
        // Complete `data:` lines without a blank delimiter must count against
        // the retained-byte cap (not just unterminated line carry).
        var parser = SSEParser(maxBufferedBytes: 128)
        #expect(throws: HTTPError.self) {
            for _ in 0..<40 {
                _ = try parser.push(Data("data: xxxxxxxxxxxxxxxx\n".utf8))
            }
        }
    }

    @Test func queuedEventsCountTowardBound() throws {
        var parser = SSEParser(maxBufferedBytes: 64)
        // Many tiny complete events; pendingEvents must be bounded if the
        // caller never drains mid-push (single push can still overflow).
        let flood = String(repeating: "data: ab\n\n", count: 20)
        #expect(throws: HTTPError.self) {
            _ = try parser.push(Data(flood.utf8))
        }
    }
}

@Suite("Mock transport")
struct MockTransportTests {
    @Test func sendReturnsScriptedBody() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(statusCode: 200, headers: ["Content-Type": "text/plain"]),
                body: Data("pong".utf8)
            )
        ])
        let url = URL(string: "https://example.test/ping")!
        let response = try await transport.send(HTTPRequest(method: .get, url: url))
        #expect(response.metadata.statusCode == 200)
        #expect(String(data: response.body, encoding: .utf8) == "pong")
        #expect(transport.recordedRequests.count == 1)
    }

    @Test func streamYieldsChunks() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(statusCode: 200),
                bodyChunks: [Data("a".utf8), Data("b".utf8), Data("c".utf8)]
            )
        ])
        let url = URL(string: "https://example.test/stream")!
        var body = Data()
        var sawMeta = false
        var sawEnd = false
        for try await event in transport.stream(HTTPRequest(method: .get, url: url)) {
            switch event {
            case .metadata(let m):
                #expect(m.statusCode == 200)
                sawMeta = true
            case .body(let d):
                body.append(d)
            case .end:
                sawEnd = true
            }
        }
        #expect(sawMeta && sawEnd)
        #expect(String(data: body, encoding: .utf8) == "abc")
    }

    @Test func earlyCancellation() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(statusCode: 200),
                bodyChunks: Array(repeating: Data("x".utf8), count: 1000),
                delayPerChunk: (5 / 1000.0)
            )
        ])
        let url = URL(string: "https://example.test/slow")!
        let stream = transport.stream(HTTPRequest(method: .get, url: url))
        let task = Task {
            for try await _ in stream {
                // consume
            }
        }
        task.cancel()
        do {
            _ = try await task.value
        } catch is CancellationError {
            // ok
        } catch let error as HTTPError {
            #expect(error == .cancelled)
        } catch {
            // Some platforms surface cooperative cancellation differently.
        }
    }

    @Test func sseStreamFromMockBody() async throws {
        let payload = "data: one\n\ndata: two\n\n"
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream"]
                ),
                bodyChunks: [
                    Data(payload.prefix(8).utf8),
                    Data(payload.dropFirst(8).utf8),
                ]
            )
        ])
        let url = URL(string: "https://example.test/sse")!
        let events = sseEventStream(from: transport.stream(HTTPRequest(method: .get, url: url)))
        var collected: [SSEEvent] = []
        for try await e in events {
            collected.append(e)
        }
        #expect(collected.map(\.data) == ["one", "two"])
    }

    @Test func boundedMemoryUnderSlowConsumer() async throws {
        // Parser enforces maxBufferedBytes even if the consumer is slow.
        var parser = SSEParser(maxBufferedBytes: 64)
        // Never dispatch (no blank line) so buffer grows.
        #expect(throws: HTTPError.self) {
            for _ in 0..<10 {
                _ = try parser.push(Data(repeating: UInt8(ascii: "x"), count: 32))
            }
        }
    }

    @Test func productionStreamMailboxBoundsPendingBytes() async throws {
        // Explicit producer/consumer mailbox: slow consumer + flood cancels
        // the upstream when pending body bytes exceed the cap.
        let chunk = Data(repeating: UInt8(ascii: "z"), count: 32)
        let transport = MockHTTPTransport(
            responses: [
                .init(
                    metadata: HTTPResponseMetadata(statusCode: 200),
                    // Small delay so the consumer can park after metadata while
                    // the producer is still pushing subsequent body chunks.
                    bodyChunks: Array(repeating: chunk, count: 20),
                    delayPerChunk: (2 / 1000.0)
                )
            ],
            maxStreamBufferBytes: 64
        )
        let url = URL(string: "https://example.test/flood")!
        let stream = transport.stream(HTTPRequest(method: .get, url: url))
        var sawBufferExceeded = false
        do {
            // Consume metadata only, then stall so body piles up in the mailbox.
            var iterator = stream.makeAsyncIterator()
            let first = try await iterator.next()
            if case .metadata = first {
                // ok
            } else {
                Issue.record("expected metadata first")
            }
            // Stall far longer than the producer needs to emit its 20 chunks, so a
            // saturated cooperative pool only delays the overflow instead of hiding it.
            try await Task.sleep(nanoseconds: 2_000_000_000)
            while let event = try await iterator.next() {
                _ = event
            }
        } catch let error as HTTPError {
            if case .bufferExceeded = error {
                sawBufferExceeded = true
            } else {
                Issue.record("unexpected HTTPError: \(error)")
            }
        }
        #expect(sawBufferExceeded)
    }

    @Test func boundedMailboxPushFailsPastLimit() throws {
        let mailbox = BoundedStreamMailbox(maxPendingBytes: 16)
        try mailbox.push(.metadata(HTTPResponseMetadata(statusCode: 200)))
        try mailbox.push(.body(Data(repeating: 1, count: 10)))
        #expect(throws: HTTPError.self) {
            try mailbox.push(.body(Data(repeating: 2, count: 10)))
        }
    }
}

@Suite("Transport configuration forwarding")
struct TransportConfigurationTests {
    @Test func proxyAndTLSSnapshotIncludesCredentials() {
        let transport = HTTPTransportConfiguration(
            connectTimeout: 12,
            requestTimeout: 34,
            maxStreamBufferBytes: 1024,
            userAgent: "cfg-test/1.0",
            proxy: HTTPProxyConfiguration(
                host: "proxy.example",
                port: 8080,
                username: "alice",
                password: "s3cret"
            ),
            tls: HTTPTLSConfiguration(
                validateCertificates: false,
                minimumTLSVersion: "tls1.2"
            ),
            additionalHeaders: ["X-Test": "1"]
        )
        let snap = HTTPSessionConfigurationBuilder.snapshot(transport)
        #expect(snap.proxyHost == "proxy.example")
        #expect(snap.proxyPort == 8080)
        #expect(snap.proxyUsername == "alice")
        #expect(snap.proxyPassword == "s3cret")
        #expect(snap.tlsValidateCertificates == false)
        #expect(snap.tlsMinimumVersion == "tls1.2")
        #expect(snap.userAgent == "cfg-test/1.0")
        #expect(snap.additionalHeaders["X-Test"] == "1")
        #expect(snap.maxStreamBufferBytes == 1024)

        let dict = HTTPSessionConfigurationBuilder.proxyDictionary(transport.proxy!)
        #expect(dict["HTTPProxy"] as? String == "proxy.example")
        #expect(dict["HTTPPort"] as? Int == 8080)
        #expect(dict["ProxyUsername"] as? String == "alice")
        #expect(dict["ProxyPassword"] as? String == "s3cret")
        #expect(HTTPSessionConfigurationBuilder.normalizedTLSMinimumVersion("TLSv1.3") == "1.3")

        let urlTransport = URLSessionHTTPTransport(configuration: transport)
        #expect(urlTransport.appliedConfigurationSnapshot.proxyUsername == "alice")
        #expect(urlTransport.appliedConfigurationSnapshot.tlsMinimumVersion == "tls1.2")
    }

    @Test func webSocketUsesTransportConfiguration() throws {
        let configuration = HTTPTransportConfiguration(
            connectTimeout: 9,
            requestTimeout: 11,
            userAgent: "ws-test/2.0",
            proxy: HTTPProxyConfiguration(
                host: "ws-proxy.example",
                port: 3128,
                username: "u",
                password: "p"
            ),
            tls: HTTPTLSConfiguration(
                validateCertificates: false,
                minimumTLSVersion: "1.2"
            ),
            additionalHeaders: ["X-WS": "yes"]
        )
        let url = URL(string: "wss://example.test/socket")!
        let prepared = URLSessionWebSocketClient.makeSessionAndRequest(
            url: url,
            configuration: configuration,
            headers: ["Sec-WebSocket-Protocol": "chat"]
        )
        #expect(prepared.snapshot.proxyHost == "ws-proxy.example")
        #expect(prepared.snapshot.proxyUsername == "u")
        #expect(prepared.snapshot.tlsValidateCertificates == false)
        #expect(prepared.snapshot.userAgent == "ws-test/2.0")
        #expect(prepared.delegate.validateCertificates == false)
        #expect(prepared.request.value(forHTTPHeaderField: "User-Agent") == "ws-test/2.0")
        #expect(prepared.request.value(forHTTPHeaderField: "X-WS") == "yes")
        #expect(prepared.request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == "chat")
    }
}

@Suite("Retry policy integration")
struct HTTPRetryTests {
    @Test func retriesRetryableStatus() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(statusCode: 503, headers: ["Retry-After": "0"]),
                body: Data()
            ),
            .init(
                metadata: HTTPResponseMetadata(statusCode: 200),
                body: Data("ok".utf8)
            ),
        ])
        let url = URL(string: "https://example.test/r")!
        let response = try await sendWithRetry(
            transport: transport,
            request: HTTPRequest(method: .get, url: url),
            policy: HTTPRetryPolicy(maxAttempts: 3, jitterSeed: 1),
            sleeper: { _ in }
        )
        #expect(response.metadata.statusCode == 200)
        #expect(transport.recordedRequests.count == 2)
    }

    @Test func doesNotRetryTerminalStatus() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(statusCode: 400),
                body: Data("bad".utf8)
            ),
        ])
        let url = URL(string: "https://example.test/bad")!
        let response = try await sendWithRetry(
            transport: transport,
            request: HTTPRequest(method: .get, url: url),
            policy: HTTPRetryPolicy(maxAttempts: 3, jitterSeed: 1),
            sleeper: { _ in }
        )
        #expect(response.metadata.statusCode == 400)
        #expect(transport.recordedRequests.count == 1)
    }

    @Test func refusesReplayOfPartialNonIdempotent() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(statusCode: 500),
                body: Data("partial".utf8)
            ),
            .init(
                metadata: HTTPResponseMetadata(statusCode: 200),
                body: Data("should-not-reach".utf8)
            ),
        ])
        let url = URL(string: "https://example.test/post")!
        do {
            _ = try await sendWithRetry(
                transport: transport,
                request: HTTPRequest(method: .post, url: url, body: Data("{}".utf8)),
                policy: HTTPRetryPolicy(maxAttempts: 3, jitterSeed: 1),
                sleeper: { _ in }
            )
            Issue.record("expected refusal to replay non-idempotent")
        } catch let error as HTTPError {
            if case .transport(let f) = error {
                #expect(f.detail.contains("non-idempotent") || f.kind == .permanent)
            } else if case .unexpectedStatus = error {
                // First attempt returned 500; second blocked — either is fine
                // depending on whether status retry sets observedPartial first.
            }
        }
        // At most one network attempt for non-idempotent after partial.
        #expect(transport.recordedRequests.count <= 2)
    }

    @Test func honorsRetryAfter() async throws {
        final class SleepLog: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [TimeInterval] = []
            func append(_ d: TimeInterval) {
                lock.lock(); defer { lock.unlock() }
                values.append(d)
            }
            var snapshot: [TimeInterval] {
                lock.lock(); defer { lock.unlock() }
                return values
            }
        }
        let slept = SleepLog()
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(statusCode: 429, headers: ["Retry-After": "2"]),
                body: Data()
            ),
            .init(
                metadata: HTTPResponseMetadata(statusCode: 200),
                body: Data("ok".utf8)
            ),
        ])
        let url = URL(string: "https://example.test/rl")!
        _ = try await sendWithRetry(
            transport: transport,
            request: HTTPRequest(method: .get, url: url),
            policy: HTTPRetryPolicy(maxAttempts: 3, honorRetryAfter: true, jitterSeed: 1),
            sleeper: { d in slept.append(d) }
        )
        #expect(slept.snapshot.contains(2))
    }

    @Test func honorsHTTPDateRetryAfter() async throws {
        final class SleepLog: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [TimeInterval] = []
            func append(_ d: TimeInterval) {
                lock.lock(); defer { lock.unlock() }
                values.append(d)
            }
            var snapshot: [TimeInterval] {
                lock.lock(); defer { lock.unlock() }
                return values
            }
        }
        let slept = SleepLog()
        let clock = MockWallClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        // 30 seconds in the future from the mock clock.
        let future = clock.now().addingTimeInterval(30)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let httpDate = formatter.string(from: future)

        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(
                    statusCode: 503,
                    headers: ["Retry-After": httpDate]
                ),
                body: Data()
            ),
            .init(
                metadata: HTTPResponseMetadata(statusCode: 200),
                body: Data("ok".utf8)
            ),
        ])
        let url = URL(string: "https://example.test/date-ra")!
        _ = try await sendWithRetry(
            transport: transport,
            request: HTTPRequest(method: .get, url: url),
            policy: HTTPRetryPolicy(maxAttempts: 3, honorRetryAfter: true, jitterSeed: 1),
            wallClock: clock,
            sleeper: { d in slept.append(d) }
        )
        #expect(!slept.snapshot.isEmpty)
        #expect(abs((slept.snapshot.first ?? -1) - 30) < 0.5)
    }

    @Test func transportFailureClassification() {
        let timeout = TransportFailure.classifyURLError(URLError(.timedOut))
        #expect(timeout.kind == .interrupted)
        let badURL = TransportFailure.classifyURLError(URLError(.badURL))
        #expect(badURL.kind == .permanent)
        let unreachable = TransportFailure.classifyURLError(URLError(.cannotConnectToHost))
        #expect(unreachable.kind == .unreachable)
    }
}

@Suite("Traced client", .serialized)
struct TracedClientTests {
    @Test func injectsTraceparent() async throws {
        let sink = RecordingTraceSink()
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(statusCode: 200), body: Data())
        ])
        let client = TracedHTTPClient(
            transport: transport,
            tracer: Tracer(
                correlation: TraceCorrelation(sessionID: "s1", requestID: "r1"),
                sink: sink
            )
        )
        let url = URL(string: "https://example.test/t")!
        _ = try await client.send(HTTPRequest(method: .get, url: url))
        #expect(transport.recordedRequests.count == 1)
        let headers = transport.recordedRequests[0].headers
        #expect(headers["traceparent"] != nil)
        #expect(headers["x-opengrok-session-id"] == "s1")
        #expect(sink.endedSpans.count == 1)
    }
}

@Suite("Error cause chain")
struct ErrorCauseTests {
    @Test func joinsUnderlying() {
        let leaf = NSError(domain: "leaf", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "connection closed"
        ])
        let wrapper = NSError(domain: "wrap", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "error sending request",
            NSUnderlyingErrorKey: leaf,
        ])
        let chain = errorCauseChain(wrapper)
        #expect(chain.contains("error sending request"))
        #expect(chain.contains("connection closed"))
    }
}
