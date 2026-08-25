import Foundation
import OpenGrokAuth
@testable import OpenGrokCLI
import OpenGrokHTTP
import OpenGrokProviderSession
import OpenGrokSampler
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokWebMediaTools
import Testing

private actor LiveSamplingRuntimeEventRecorder {
    private var recorded: [OpenGrokLiveSamplingEvent] = []

    func append(_ event: OpenGrokLiveSamplingEvent) {
        recorded.append(event)
    }

    func snapshot() -> [OpenGrokLiveSamplingEvent] {
        recorded
    }
}

private final class LiveSamplingAttributionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Auth401AttributionRecord] = []

    func append(_ value: Auth401AttributionRecord) {
        lock.withLock { recorded.append(value) }
    }

    var values: [Auth401AttributionRecord] {
        lock.withLock { recorded }
    }
}

private final class LiveSamplingRotatingResolver: BearerResolver, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private let rejected: String
    private let current: String

    init(rejected: String, current: String) {
        self.rejected = rejected
        self.current = current
    }

    func currentBearer() -> String? {
        lock.withLock {
            defer { reads += 1 }
            return reads == 0 ? rejected : current
        }
    }
}

private final class LiveSamplingRefreshingCredential: AuthCredentialProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var token = "stale-runtime-token"
    private var refreshes = 0

    func apply(to headers: inout [String: String], baseURL: String) {
        _ = baseURL
        headers["Authorization"] = "Bearer \(snapshot().token ?? "")"
    }

    func snapshot() -> CredentialSnapshot {
        lock.withLock { CredentialSnapshot(token: token) }
    }

    func refreshAfterUnauthorized() async -> Bool {
        lock.withLock {
            guard refreshes == 0 else { return false }
            token = "fresh-runtime-token"
            refreshes += 1
            return true
        }
    }

    func needsTokenAuthHeader() -> Bool { false }

    var refreshCount: Int {
        lock.withLock { refreshes }
    }
}

@Suite("Live provider sampling runtime parity")
struct LiveSamplingRuntimeParityTests {
    private func chunk(_ text: String, final: Bool = true) -> String {
        let finish = final ? #""stop""# : "null"
        return #"{"id":"chunk-1","object":"chat.completion.chunk","created":0,"model":"test-model","choices":[{"index":0,"delta":{"role":"assistant","content":"\#(text)"},"finish_reason":\#(finish)}]}"#
    }

    private func chatResponse(
        _ text: String,
        delayPerChunk: TimeInterval = 0
    ) -> MockHTTPTransport.ScriptedResponse {
        .init(
            metadata: HTTPResponseMetadata(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"]
            ),
            body: Data("data: \(chunk(text))\n\ndata: [DONE]\n\n".utf8),
            delayPerChunk: delayPerChunk
        )
    }

    private func failedResponse(
        status: Int,
        message: String = "transient failure"
    ) -> MockHTTPTransport.ScriptedResponse {
        .init(
            metadata: HTTPResponseMetadata(
                statusCode: status,
                headers: ["Retry-After": "0"]
            ),
            body: Data(#"{"error":{"message":"\#(message)"}}"#.utf8)
        )
    }

    private func liveRequest(
        items: [ConversationItem]? = nil,
        retryOnlyBeforeOutput: Bool = false
    ) -> OpenGrokLiveSamplingRequest {
        OpenGrokLiveSamplingRequest(
            sessionID: "runtime-session",
            turnID: "runtime-turn",
            model: "test-model",
            prompt: "hello",
            items: items,
            retryOnlyBeforeOutput: retryOnlyBeforeOutput
        )
    }

    private func makeSampler(
        transport: MockHTTPTransport,
        maxRetries: UInt32 = 2,
        idleTimeout: UInt64? = nil,
        resolver: (any BearerResolver)? = nil,
        attribution: (any Auth401AttributionCallback)? = nil
    ) throws -> OpenGrokLiveSampler {
        try OpenGrokLiveSampler.production(configuration: OpenGrokLiveSamplingConfiguration(
            model: "test-model",
            baseURL: "https://provider.example.test",
            apiKey: "static-provider-secret-never-record",
            tuning: OpenGrokLiveSamplingTuning(
                maxRetries: maxRetries,
                inferenceIdleTimeoutSecs: idleTimeout
            ),
            bearerResolver: resolver,
            attributionCallback: attribution,
            transport: transport
        ))
    }

    private func containsString(_ value: JSONValue, fragment: String) -> Bool {
        switch value {
        case .string(let text):
            return text.contains(fragment)
        case .array(let items):
            return items.contains { containsString($0, fragment: fragment) }
        case .object(let values):
            return values.values.contains { containsString($0, fragment: fragment) }
        case .null, .bool, .number:
            return false
        }
    }

    @Test("actual production sampling retries a transient 500 and retains attempt metrics")
    func productionRetriesTransientFailure() async throws {
        let transport = MockHTTPTransport(responses: [
            failedResponse(status: 500),
            chatResponse("recovered"),
        ])
        let recorder = LiveSamplingRuntimeEventRecorder()
        let sampler = try makeSampler(transport: transport)

        let response = try await sampler.sample(liveRequest()) { event in
            await recorder.append(event)
        }

        #expect(response.output == "recovered")
        #expect(response.latencyStats?.attempts == 2)
        #expect(transport.recordedRequests.count == 2)
        let events = await recorder.snapshot()
        #expect(events.contains { event in
            if case .retrying(let attempt, let maximum, let kind, _) = event {
                return attempt == 1 && maximum == 2 && kind == .api
            }
            return false
        })
        #expect(events.contains(.output("recovered")))
        #expect(!events.contains { event in
            if case .failed = event { return true }
            return false
        })
    }

    @Test("side-question collection returns an empty answer without turn-actor retries")
    func sideQuestionCollectsEmptyResponseExactlyOnce() async throws {
        let transport = MockHTTPTransport(responses: [chatResponse("")])
        let sampler = try makeSampler(transport: transport, maxRetries: 15)

        let response = try await sampler.sample(
            OpenGrokLiveSamplingRequest(
                sessionID: "side-session",
                turnID: "xai-btw-empty",
                model: "test-model",
                prompt: "anything?",
                isSideQuestion: true
            ),
            emit: { _ in }
        )

        #expect(response.output.isEmpty)
        #expect(response.latencyStats?.attempts == 1)
        #expect(transport.recordedRequests.count == 1)
    }

    @Test("side questions retry transient failures under their separate bounded policy")
    func sideQuestionRetriesTransientFailureWithoutTurnActor() async throws {
        let transport = MockHTTPTransport(responses: [
            failedResponse(status: 500),
            chatResponse("side question recovered"),
        ])
        let sampler = try makeSampler(transport: transport, maxRetries: 15)

        let result = try await LiveBtw.sampleSideQuestion(
            sampler: sampler,
            sessionID: "side-session",
            model: "test-model",
            question: "did it recover?",
            items: [.user("did it recover?")]
        )

        #expect(result.response.output == "side question recovered")
        #expect(result.attempts == 2)
        #expect(transport.recordedRequests.count == 2)
    }

    @Test("side-question overload retries stop after exactly three attempts")
    func sideQuestionRetriesAreBoundedToThreeAttempts() async throws {
        let transport = MockHTTPTransport(responses: [
            failedResponse(status: 500),
            failedResponse(status: 502),
            failedResponse(status: 503),
        ])
        let sampler = try makeSampler(transport: transport, maxRetries: 15)

        do {
            let response = try await LiveBtw.sampleSideQuestion(
                sampler: sampler,
                sessionID: "side-session",
                model: "test-model",
                question: "still overloaded?",
                items: [.user("still overloaded?")]
            )
            Issue.record("exhausted side question unexpectedly returned \(response.response.output)")
        } catch let failure as LiveBtw.SamplingFailure {
            #expect(failure.attempts == 3)
        }

        #expect(transport.recordedRequests.count == 3)
    }

    @Test("rate-limited side questions never enter the main actor retry budget")
    func sideQuestionNeverRetriesRateLimits() async throws {
        let transport = MockHTTPTransport(responses: [
            failedResponse(status: 429, message: "rate limited"),
        ])
        let sampler = try makeSampler(transport: transport, maxRetries: 15)

        do {
            let response = try await LiveBtw.sampleSideQuestion(
                sampler: sampler,
                sessionID: "side-session",
                model: "test-model",
                question: "rate limited?",
                items: [.user("rate limited?")]
            )
            Issue.record("rate-limited side question unexpectedly returned \(response.response.output)")
        } catch let failure as LiveBtw.SamplingFailure {
            #expect(failure.attempts == 1)
            if let samplingError = failure.underlying as? SamplingError,
               case .api(let status, _, _, _, _, _) = samplingError {
                #expect(status.code == 429)
            } else {
                Issue.record("rate-limit error lost its typed sampling failure")
            }
        }

        #expect(transport.recordedRequests.count == 1)
    }

    @Test("provider retry veto is honored by the independent side-question policy")
    func sideQuestionHonorsProviderRetryVeto() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(
                    statusCode: 500,
                    headers: ["x-should-retry": "false"]
                ),
                body: Data(#"{"error":{"message":"do not retry"}}"#.utf8)
            ),
        ])
        let sampler = try makeSampler(transport: transport, maxRetries: 15)

        do {
            let response = try await LiveBtw.sampleSideQuestion(
                sampler: sampler,
                sessionID: "side-session",
                model: "test-model",
                question: "retry veto?",
                items: [.user("retry veto?")]
            )
            Issue.record("vetoed side question unexpectedly returned \(response.response.output)")
        } catch let failure as LiveBtw.SamplingFailure {
            #expect(failure.attempts == 1)
        }

        #expect(transport.recordedRequests.count == 1)
    }

    @Test("rate-limit retries use the authoritative actor and emit one typed retry")
    func productionRetriesRateLimitBeforeOutput() async throws {
        let transport = MockHTTPTransport(responses: [
            failedResponse(status: 429, message: "rate limited"),
            chatResponse("allowed"),
        ])
        let recorder = LiveSamplingRuntimeEventRecorder()
        let sampler = try makeSampler(transport: transport, maxRetries: 3)

        let response = try await sampler.sample(liveRequest()) { event in
            await recorder.append(event)
        }

        #expect(response.output == "allowed")
        #expect(response.latencyStats?.attempts == 2)
        let events = await recorder.snapshot()
        let retries = events.filter { event in
            if case .retrying = event { return true }
            return false
        }
        #expect(retries.count == 1)
        #expect(transport.recordedRequests.count == 2)
    }

    @Test("existing auth middleware refreshes exactly once without a second actor retry")
    func authRefreshDoesNotDoubleRetry() async throws {
        let credentials = LiveSamplingRefreshingCredential()
        let transport = MockHTTPTransport(responses: [
            failedResponse(status: 401, message: "expired"),
            chatResponse("authenticated"),
        ])
        let recorder = LiveSamplingRuntimeEventRecorder()
        let sampler = try OpenGrokLiveSampler.production(configuration: .init(
            model: "test-model",
            baseURL: "https://provider.example.test",
            apiKey: "stale-runtime-token",
            tuning: OpenGrokLiveSamplingTuning(maxRetries: 4),
            credentialProvider: credentials,
            transport: transport
        ))

        let response = try await sampler.sample(liveRequest()) { event in
            await recorder.append(event)
        }

        #expect(response.output == "authenticated")
        #expect(response.latencyStats?.attempts == 1)
        #expect(credentials.refreshCount == 1)
        #expect(transport.recordedRequests.count == 2)
        #expect(transport.recordedRequests[0].headers["Authorization"] == "Bearer stale-runtime-token")
        #expect(transport.recordedRequests[1].headers["Authorization"] == "Bearer fresh-runtime-token")
        let events = await recorder.snapshot()
        #expect(!events.contains { event in
            if case .retrying = event { return true }
            return false
        })
    }

    @Test("payload rejection strips images before the real provider replay")
    func productionStripsRejectedImages() async throws {
        let transport = MockHTTPTransport(responses: [
            failedResponse(status: 413, message: "payload too large"),
            chatResponse("image removed safely"),
        ])
        let sampler = try makeSampler(transport: transport)
        let request = liveRequest(items: [
            .userWithParts([
                .text(text: "describe this"),
                .image(url: "data:image/png;base64,QUJD"),
            ]),
        ])

        let response = try await sampler.sample(request, emit: { _ in })

        #expect(response.output == "image removed safely")
        #expect(response.latencyStats?.attempts == 2)
        let sent = transport.recordedRequests
        #expect(sent.count == 2)
        let firstBody = try JSONDecoder().decode(JSONValue.self, from: try #require(sent.first?.body))
        let retriedBody = try JSONDecoder().decode(JSONValue.self, from: try #require(sent.last?.body))
        #expect(containsString(firstBody, fragment: "data:image/png;base64,QUJD"))
        #expect(!containsString(retriedBody, fragment: "data:image/png;base64,QUJD"))
        #expect(containsString(retriedBody, fragment: "image removed"))
    }

    @Test("budgeted production requests never retry after a visible output token")
    func productionNeverRetriesBudgetedPartialOutput() async throws {
        let first = "data: \(chunk("already visible", final: false))\n\n"
            + #"data: {"error":{"type":"server_error","message":"provider interrupted"}}"#
            + "\n\n"
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream"]
                ),
                body: Data(first.utf8)
            ),
            chatResponse("must not replay"),
        ])
        let recorder = LiveSamplingRuntimeEventRecorder()
        let sampler = try makeSampler(transport: transport)

        do {
            let response = try await sampler.sample(
                liveRequest(retryOnlyBeforeOutput: true)
            ) { event in
                await recorder.append(event)
            }
            Issue.record("partially visible request unexpectedly completed: \(response.output)")
        } catch {
            #expect(transport.recordedRequests.count == 1)
        }

        let events = await recorder.snapshot()
        #expect(events.contains(.output("already visible")))
        #expect(events.contains { event in
            if case .failed = event { return true }
            return false
        })
        #expect(!events.contains { event in
            if case .retrying = event { return true }
            return false
        })
    }

    @Test("configured model idle timeout governs the live provider stream")
    func configuredIdleTimeoutIsApplied() async throws {
        let transport = MockHTTPTransport(responses: [
            chatResponse("arrives too late", delayPerChunk: 1.2),
        ])
        let recorder = LiveSamplingRuntimeEventRecorder()
        let sampler = try makeSampler(transport: transport, maxRetries: 0, idleTimeout: 1)

        do {
            let response = try await sampler.sample(liveRequest()) { event in
                await recorder.append(event)
            }
            Issue.record("timed-out provider unexpectedly completed: \(response.output)")
        } catch {
            let events = await recorder.snapshot()
            #expect(events.contains { event in
                if case .failed(let failure) = event {
                    return failure.kind == .idleTimeout
                }
                return false
            })
        }
        #expect(transport.recordedRequests.count == 1)
    }

    @Test("cancelling production sampling tears down its actor-owned HTTP stream")
    func cancellationStopsActorAndTransport() async throws {
        let transport = MockHTTPTransport(responses: [
            chatResponse("must not complete", delayPerChunk: 30),
        ])
        let sampler = try makeSampler(transport: transport)
        let request = liveRequest()
        let task = Task {
            try await sampler.sample(request, emit: { _ in })
        }

        for _ in 0..<1_000 where transport.recordedRequests.isEmpty {
            await Task.yield()
        }
        #expect(transport.recordedRequests.count == 1)
        task.cancel()

        do {
            let response = try await task.value
            Issue.record("cancelled provider unexpectedly completed: \(response.output)")
        } catch is CancellationError {
            #expect(transport.recordedRequests.count == 1)
        }
    }

    @Test("production 401 attribution compares only transmitted and live token tails")
    func productionAttributionIsNonblockingAndScrubbed() async throws {
        let rejected = "very-secret-rejected-token-oldtail1"
        let current = "very-secret-current-token-newtail99"
        let resolver = LiveSamplingRotatingResolver(rejected: rejected, current: current)
        let attribution = LiveSamplingAttributionRecorder()
        let callback = LiveSamplingAuth401Attribution(
            resolver: resolver,
            staticBearer: nil
        ) { value in
            attribution.append(value)
        }
        let transport = MockHTTPTransport(responses: [
            failedResponse(status: 401, message: "expired"),
        ])
        let sampler = try makeSampler(
            transport: transport,
            maxRetries: 0,
            resolver: resolver,
            attribution: callback
        )

        do {
            let response = try await sampler.sample(liveRequest(), emit: { _ in })
            Issue.record("unauthorized provider unexpectedly returned \(response.output)")
        } catch {
            #expect(transport.recordedRequests.count == 1)
        }

        for _ in 0..<1_000 where attribution.values.isEmpty {
            await Task.yield()
        }
        let event = try #require(attribution.values.first)
        #expect(event.consumer == .chatCompletionsStream)
        #expect(event.sentBearerSuffix == scrubbedBearerSuffix(rejected))
        #expect(event.currentBearerSuffix == scrubbedBearerSuffix(current))
        #expect(event.isStaleSnapshot)
        #expect(event.sentBearerSuffix != rejected)
        #expect(event.currentBearerSuffix != current)
        #expect(!String(describing: event).contains(rejected))
        #expect(!String(describing: event).contains(current))
        #expect(transport.recordedRequests.first?.headers["Authorization"] == "Bearer \(rejected)")
    }

    @Test("direct callback invocation re-scrubs malicious full bearer inputs")
    func attributionCallbackRescrubsAtBoundary() async throws {
        let sent = "malicious-full-provider-credential-tail-123"
        let current = "different-full-provider-credential-tail-456"
        let captured = LiveSamplingAttributionRecorder()
        let callback = LiveSamplingAuth401Attribution(
            resolver: nil,
            staticBearer: current
        ) { value in
            captured.append(value)
        }

        callback.record401(consumer: .standaloneWebSearch, sentBearerPrefix: sent)
        for _ in 0..<1_000 where captured.values.isEmpty {
            await Task.yield()
        }

        let record = try #require(captured.values.first)
        #expect(record.consumer == .standaloneWebSearch)
        #expect(record.sentBearerSuffix == scrubbedBearerSuffix(sent))
        #expect(record.currentBearerSuffix == scrubbedBearerSuffix(current))
        #expect(record.isStaleSnapshot)
        #expect(record.sentBearerSuffix?.count == BEARER_SUFFIX_LEN)
        #expect(record.currentBearerSuffix?.count == BEARER_SUFFIX_LEN)
    }

    @Test("actual standalone Codex backend inherits the configured 401 callback")
    func standaloneCompositionForwardsAttributionCallback() async throws {
        let bearer = "codex-oauth-rejected-secret-tail"
        let provider = StaticAuthCredentialProvider(bearer: bearer)
        let binding = ProviderCredentialBinding(
            scope: "codex:standalone-session",
            kind: .codexOAuth,
            source: provider
        )
        let credential = LiveResolvedCredential(
            provider: .codex,
            scope: "codex:standalone-session",
            source: .codexOAuth,
            authKind: .codexOAuth,
            bearer: bearer,
            binding: binding
        )
        let captured = LiveSamplingAttributionRecorder()
        let callback = LiveSamplingAuth401Attribution(
            resolver: nil,
            staticBearer: bearer
        ) { value in
            captured.append(value)
        }
        let transport = MockHTTPTransport(responses: [
            failedResponse(status: 401, message: "expired"),
        ])
        let configuration = OpenGrokLiveSamplingConfiguration(
            model: "gpt-test",
            baseURL: "https://codex.example.test/v1",
            apiKey: bearer,
            provider: .codex,
            apiBackend: .responses,
            tuning: OpenGrokLiveSamplingTuning(supportsStandaloneWebSearch: true),
            credentialProvider: provider,
            attributionCallback: callback,
            transport: transport
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "standalone-attribution-\(UUID().uuidString)",
            isDirectory: true
        )
        var conversation = LiveConversationRecord.new(
            sessionID: "standalone-session",
            workingDirectory: root
        )
        conversation.items = [.user("find documentation")]
        conversation.currentProvider = .codex
        conversation.currentModelID = "gpt-test"
        let history = LiveConversationHistory(
            record: conversation,
            store: LiveConversationStore(openGrokHome: root)
        )
        let availability = LiveWebToolAvailability(
            searchConfig: .disabled,
            webSearchEnabled: true,
            webFetchEnabled: false,
            xSearchEnabled: false
        )
        let configuredBackend = try LiveStandaloneWebSearchComposition.makeBackend(
            configuration: configuration,
            credential: credential,
            conversationHistory: history,
            sessionID: "standalone-session",
            availability: availability,
            disableWebSearch: false,
            supportsStandaloneWebSearch: true
        )
        let backend = try #require(configuredBackend)

        do {
            let output = try await backend.search(commands: .object([
                "search_query": .array([.object(["q": .string("Open Grok")])]),
            ]))
            Issue.record("unauthorized standalone search unexpectedly returned \(output)")
        } catch {
            #expect(transport.recordedRequests.count == 1)
        }

        for _ in 0..<1_000 where captured.values.isEmpty {
            await Task.yield()
        }
        let event = try #require(captured.values.first)
        #expect(event.consumer == .standaloneWebSearch)
        #expect(event.sentBearerSuffix == scrubbedBearerSuffix(bearer))
        #expect(!event.isStaleSnapshot)
        #expect(!String(describing: event).contains(bearer))
    }

    @Test("invalid provider/backend configurations still fail synchronously")
    func invalidConfigurationFailsAtConstruction() {
        #expect(throws: SamplingError.self) {
            try LiveSamplingRuntime(
                config: SamplerConfig(
                    apiKey: "secret",
                    baseURL: "https://codex.example.test",
                    model: "gpt-test",
                    apiBackend: .chatCompletions,
                    provider: .codex
                ),
                transport: MockHTTPTransport()
            )
        }
    }
}
