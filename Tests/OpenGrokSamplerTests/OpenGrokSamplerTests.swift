// OpenGrokSamplerTests.swift
//
// Rust-derived unit and hermetic streaming tests for OpenGrokSampler.
// Translated from xai-grok-sampler unit/integration suites (retry, L2
// chat completions, collect, actor, provider isolation, cancellation).

import Testing
import Foundation
@testable import OpenGrokSampler
import OpenGrokHTTP
import OpenGrokSamplingTypes
import OpenGrokShared

private final class PendingStreamSource<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Element>.Continuation?
    private var terminated = false

    func stream() -> AsyncStream<Element> {
        AsyncStream { continuation in
            lock.withLock {
                self.continuation = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.markTerminated()
            }
        }
    }

    func finish() {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.finish()
    }

    var isTerminated: Bool {
        lock.withLock { terminated }
    }

    private func markTerminated() {
        lock.withLock {
            terminated = true
        }
    }
}

private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func markCompleted() {
        lock.withLock {
            completed = true
        }
    }

    var isCompleted: Bool {
        lock.withLock { completed }
    }
}

private func collectSamplingEvents(_ stream: AsyncStream<SamplingEvent>) async -> [SamplingEvent] {
    var events: [SamplingEvent] = []
    for await event in stream {
        events.append(event)
    }
    return events
}

private func waitUntil(
    timeout: MonotonicDuration = .milliseconds(500),
    condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let startedAt = MonotonicInstant.now
    while MonotonicInstant.now - startedAt < timeout {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return condition()
}

private func expectPromptCancellation<Element: Sendable>(
    stream: AsyncStream<SamplingEvent>,
    source: PendingStreamSource<Element>
) async {
    let completion = CompletionFlag()
    let consumer = Task {
        for await _ in stream {}
        completion.markCompleted()
    }
    try? await Task.sleep(nanoseconds: 20_000_000)
    consumer.cancel()
    let consumerStopped = await waitUntil { completion.isCompleted }
    let sourceStopped = await waitUntil { source.isTerminated }
    source.finish()
    _ = await consumer.result
    #expect(consumerStopped)
    #expect(sourceStopped)
}

// MARK: - RequestId

@Suite("RequestId")
struct RequestIdTests {
    @Test("from string round-trips")
    func fromString() {
        let id = RequestId("abc-123")
        #expect(id.asString == "abc-123")
        #expect(id.description == "abc-123")
    }

    @Test("random produces unique values")
    func randomUnique() {
        let a = RequestId.random()
        let b = RequestId.random()
        #expect(a != b)
        #expect(a.asString.count == 36)
    }
}

// MARK: - Metrics

@Suite("Metrics")
struct MetricsTests {
    @Test("percentiles from sorted slice")
    func percentiles() {
        let sorted: [UInt64] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        let p = computePercentiles(sorted)
        #expect(p.p50 == 6) // len/2 = 5 → index 5 is 6
        #expect(p.max == 10)
        #expect(p.mean == 5)
        #expect(p.sum == 55)
    }

    @Test("fromDates empty chunks only sets TTLB")
    func emptyChunks() {
        let start = Date(timeIntervalSince1970: 0)
        let end = Date(timeIntervalSince1970: 1.5)
        let stats = InferenceLatencyStats.fromDates(
            streamStart: start,
            chunkTimestamps: [],
            streamEnd: end
        )
        #expect(stats.timeToFirstTokenMs == nil)
        #expect(stats.chunkCount == 0)
        #expect(stats.timeToLastByteMs == 1500)
    }

    @Test("fromDates computes TTFB and ITL")
    func withChunks() {
        let start = Date(timeIntervalSince1970: 0)
        let c1 = Date(timeIntervalSince1970: 0.1)
        let c2 = Date(timeIntervalSince1970: 0.3)
        let end = Date(timeIntervalSince1970: 0.5)
        let stats = InferenceLatencyStats.fromDates(
            streamStart: start,
            chunkTimestamps: [c1, c2],
            streamEnd: end
        )
        #expect(stats.timeToFirstTokenMs == 100)
        #expect(stats.chunkCount == 2)
        #expect(stats.itlIntervalsMs == [200])
        #expect(stats.itlP50Ms == 200)
    }
}

// MARK: - Retry

@Suite("Retry classification")
struct RetryTests {
    @Test("auth is emit-to-session")
    func auth() {
        let d = classifyError(.auth("bad"), retryCount: 0, maxRetries: 15, rateLimitThreshold: 2)
        if case .emitToSession(let e) = d {
            #expect(e.isAuthError)
        } else {
            Issue.record("expected emitToSession")
        }
    }

    @Test("429 retries then fatal at threshold")
    func rateLimit() {
        let err = SamplingError.api(
            status: HTTPStatus(429),
            message: "slow",
            modelMetadata: nil,
            retryAfterSecs: 15,
            shouldRetry: nil
        )
        let d0 = classifyError(err, retryCount: 0, maxRetries: 15, rateLimitThreshold: 2)
        if case .retryWithBackoff(let backoff, let isRL) = d0 {
            #expect(isRL)
            #expect(backoff == .seconds(15))
        } else {
            Issue.record("expected retryWithBackoff, got \(d0)")
        }
        let d1 = classifyError(err, retryCount: 1, maxRetries: 15, rateLimitThreshold: 2)
        if case .fatal = d1 {
            // nextAttempt=2 >= min(15,2)=2
        } else {
            Issue.record("expected fatal at threshold")
        }
    }

    @Test("5xx first retry rebuilds client")
    func serverErrorRebuild() {
        let err = SamplingError.api(
            status: HTTPStatus(500),
            message: "boom",
            modelMetadata: nil,
            retryAfterSecs: nil,
            shouldRetry: nil
        )
        let d = classifyError(err, retryCount: 0, maxRetries: 15, rateLimitThreshold: 2)
        if case .retryWithClientRebuild = d {
            // ok
        } else {
            Issue.record("expected retryWithClientRebuild")
        }
        let d2 = classifyError(err, retryCount: 1, maxRetries: 15, rateLimitThreshold: 2)
        if case .retry = d2 {
            // ok
        } else {
            Issue.record("expected retry")
        }
    }

    @Test("x-should-retry false is fatal")
    func shouldRetryFalse() {
        let err = SamplingError.api(
            status: HTTPStatus(500),
            message: "nope",
            modelMetadata: nil,
            retryAfterSecs: nil,
            shouldRetry: false
        )
        let d = classifyError(err, retryCount: 0, maxRetries: 15, rateLimitThreshold: 2)
        if case .fatal = d {
            // ok
        } else {
            Issue.record("expected fatal")
        }
    }

    @Test("413 is image strip")
    func payloadTooLarge() {
        let err = SamplingError.api(
            status: HTTPStatus(413),
            message: "too large",
            modelMetadata: nil,
            retryAfterSecs: nil,
            shouldRetry: nil
        )
        let d = classifyError(err, retryCount: 0, maxRetries: 15, rateLimitThreshold: 2)
        if case .retryWithImageStrip = d {
            // ok
        } else {
            Issue.record("expected retryWithImageStrip")
        }
    }

    @Test("context length is fatal")
    func contextLength() {
        let err = SamplingError.api(
            status: HTTPStatus(400),
            message: "maximum context length exceeded",
            modelMetadata: nil,
            retryAfterSecs: nil,
            shouldRetry: nil
        )
        let d = classifyError(err, retryCount: 0, maxRetries: 15, rateLimitThreshold: 2)
        if case .fatal = d {
            // ok
        } else {
            Issue.record("expected fatal")
        }
    }

    @Test("resolve max retries env override")
    func resolveRetries() {
        #expect(resolveMaxRetriesWithEnv(envOverride: "7", modelMaxRetries: 3) == 7)
        #expect(resolveMaxRetriesWithEnv(envOverride: nil, modelMaxRetries: 3) == 3)
        #expect(resolveMaxRetriesWithEnv(envOverride: nil, modelMaxRetries: nil) == DEFAULT_MAX_RETRIES)
    }

    @Test("format sampling error includes retry prefix")
    func formatError() {
        let s = formatSamplingError(.auth("x"), retryCount: 2)
        #expect(s.contains("after 2 retries"))
        #expect(s.contains("Authentication failed"))
    }
}

// MARK: - SamplingErrorInfo

@Suite("SamplingErrorInfo")
struct ErrorInfoTests {
    @Test("api 429 classified as rate limited")
    func rateLimited() {
        let err = SamplingError.api(
            status: HTTPStatus(429),
            message: "slow",
            modelMetadata: nil,
            retryAfterSecs: 15,
            shouldRetry: nil
        )
        let info = SamplingErrorInfo(from: err)
        #expect(info.kind == .rateLimited)
        #expect(info.statusCode == 429)
        #expect(info.retryAfterSecs == 15)
        #expect(info.isRetryable)
    }

    @Test("idle timeout not retryable")
    func idle() {
        let info = SamplingErrorInfo(from: .idleTimeout(elapsedSecs: 300))
        #expect(info.kind == .idleTimeout)
        #expect(!info.isRetryable)
        #expect(info.message.contains("300s"))
    }

    @Test("error kind asString stable")
    func asString() {
        #expect(SamplingErrorKind.doomLoopDetected.asString == "doom_loop_detected")
        #expect(SamplingErrorKind.rateLimited.asString == "rate_limited")
    }
}

// MARK: - Provider adapters

@Suite("Provider adapters")
struct ProviderTests {
    @Test("registry covers all providers")
    func registry() {
        let expected: [(provider: ModelProvider, profile: ProviderProfile)] = [
            (.xai, .xai),
            (.codex, .codex),
            (.kimi, .kimi),
            (.fireworks, .fireworks),
            (.deepseek, .deepseek),
            (.meta, .meta),
            (.openCodeGo, .openCodeGo),
            (.wafer, .wafer),
            (.zai, .zai),
            (.runinfra, .runinfra),
            (.gemini, .gemini),
            (.openRouter, .openRouter),
        ]

        #expect(PROVIDER_REGISTRY.count == 12)
        #expect(PROVIDER_REGISTRY.map { $0.provider } == expected.map { $0.provider })
        for item in expected {
            let matching = PROVIDER_REGISTRY.filter { $0.provider == item.provider }
            #expect(matching.count == 1)
            let adapter = providerAdapter(item.provider)
            #expect(adapter.provider == item.provider)
            #expect(adapter.profile == item.profile)
        }
    }

    @Test("kimi strips temperature and top_p")
    func kimiSanitize() {
        var req = ChatCompletionWireRequest(
            model: "kimi",
            messages: [.user("hi")],
            temperature: 0.7,
            topP: 0.9
        )
        KimiProvider().sanitizeChatRequest(&req)
        #expect(req.temperature == nil)
        #expect(req.topP == nil)
    }

    @Test("fireworks strips model_id on messages")
    func fireworksSanitize() {
        var req = ChatCompletionWireRequest(
            messages: [
                ChatRequestWireMessage(role: .assistant, content: .text("hi"), modelId: "grok")
            ]
        )
        FireworksProvider().sanitizeChatRequest(&req)
        #expect(req.messages[0].modelId == nil)
    }

    @Test("codex validates responses only")
    func codexBackend() throws {
        try CodexProvider().validateBackend(.responses)
        do {
            try CodexProvider().validateBackend(.chatCompletions)
            Issue.record("should throw")
        } catch {
            // expected
        }
    }

    @Test("xai applies identity headers; codex sanitizes them")
    func headers() {
        var headers: [String: String] = ["x-grok-foo": "bar", "Accept": "json"]
        CodexProvider().sanitizeHeaders(&headers)
        #expect(headers["x-grok-foo"] == nil)
        #expect(headers["Accept"] == "json")

        var xaiHeaders: [String: String] = [:]
        let cfg = SamplerConfig(clientIdentifier: "test-id", clientVersion: "1.0")
        XaiProvider().applyDefaultHeaders(&xaiHeaders, config: cfg)
        #expect(xaiHeaders["x-grok-client-identifier"] == "test-id")
        #expect(xaiHeaders["x-grok-client-version"] == "1.0")
    }

    @Test("codex instruction roles extraction into instructions property")
    func codexInstructionRoles() {
        var body: JSONValue = .object([
            "input": .array([
                .object(["type": .string("message"), "role": .string("system"), "content": .string("Leading System Instruction 1")]),
                .object(["type": .string("message"), "role": .string("system"), "content": .string("Leading System Instruction 2")]),
                .object(["type": .string("message"), "role": .string("user"), "content": .string("User Prompt")]),
                .object(["type": .string("message"), "role": .string("system"), "content": .string("Subsequent System Message")]),
            ])
        ])
        let policy = ResponsesRequestPolicy(multiAgentV2: false, localEffort: nil, reasoningSummary: nil)
        patchCodexResponsesRequest(&body, policy: policy)

        #expect(body["instructions"]?.stringValue == "Leading System Instruction 1\n\nLeading System Instruction 2")
        guard case .array(let input) = body["input"] else {
            Issue.record("input should be an array")
            return
        }
        #expect(input.count == 2)
        #expect(input[0]["role"]?.stringValue == "user")
        #expect(input[1]["role"]?.stringValue == "developer")
        #expect(input[1]["content"]?.stringValue == "Subsequent System Message")
    }

    @Test("codex multi-agent v2 mode tag insertion")
    func codexMultiAgentV2() {
        var body: JSONValue = .object([
            "input": .array([
                .object(["type": .string("message"), "role": .string("user"), "content": .string("Hello")]),
            ])
        ])
        let policyUltra = ResponsesRequestPolicy(multiAgentV2: true, localEffort: .ultra, reasoningSummary: nil)
        patchCodexResponsesRequest(&body, policy: policyUltra)

        #expect(body["reasoning"]?["effort"]?.stringValue == "max")

        guard case .array(let input) = body["input"] else {
            Issue.record("input should be array")
            return
        }
        #expect(input.count == 2)
        #expect(input[0]["role"]?.stringValue == "developer")
        #expect(input[0]["content"]?.arrayValue?.first?["text"]?.stringValue?.contains(PROACTIVE_MULTI_AGENT_MODE_TEXT) == true)
        #expect(input[1]["role"]?.stringValue == "user")
    }

    @Test("codex prompt cache key matches session id")
    func codexPromptCacheKey() {
        let key = CodexProvider().promptCacheKey(sessionId: "session-123")
        #expect(key == "session-123")
        let nilKey = XaiProvider().promptCacheKey(sessionId: "session-123")
        #expect(nilKey == nil)
    }

    @Test("codex turn state first-write-wins")
    func turnState() {
        let cell = CodexTurnStateCell()
        #expect(cell.setIfEmpty("a"))
        #expect(!cell.setIfEmpty("b"))
        #expect(cell.get() == "a")

        let state = CodexTurnState()
        let s1 = state.snapshot()
        state.beginTurn()
        let s2 = state.snapshot()
        s1.setIfEmpty("turn-a")
        #expect(s2.get() == nil)
    }
}

// MARK: - Display citations

@Suite("Display citations")
struct CitationTests {
    @Test("strips complete widget across chunks")
    func splitWidget() {
        let marker = "\(CITATION_START)cite\(CITATION_DELIMITER)turn1search0\(CITATION_STOP)"
        let mid = marker.index(marker.startIndex, offsetBy: marker.count / 2)
        var filter = DisplayCitationFilter()
        let a = filter.push("hello " + String(marker[..<mid]))
        let b = filter.push(String(marker[mid...]) + " world")
        #expect(a == "hello ")
        #expect(b == " world")
        #expect(!stripDisplayCitations("x\(marker)y").contains("cite"))
    }
}

// MARK: - L2 Chat Completions

@Suite("Stream chat completions")
struct StreamChatCompletionsTests {
    private func rid() -> RequestId { RequestId("test-req") }

    private func textChunk(_ text: String) -> ChatCompletionChunk {
        ChatCompletionChunk(
            id: "c1",
            object: "chat.completion.chunk",
            created: 0,
            model: "test-model",
            choices: [
                ChatChunkChoice(
                    index: 0,
                    delta: ChatChunkDelta(role: .assistant, content: text),
                    finishReason: nil
                ),
            ]
        )
    }

    private func finalChunk(_ reason: FinishReason = .stop) -> ChatCompletionChunk {
        ChatCompletionChunk(
            id: "c1",
            object: "chat.completion.chunk",
            created: 0,
            model: "test-model",
            choices: [
                ChatChunkChoice(
                    index: 0,
                    delta: ChatChunkDelta(),
                    finishReason: reason
                ),
            ]
        )
    }

    private func collect(_ stream: AsyncStream<SamplingEvent>) async -> [SamplingEvent] {
        var out: [SamplingEvent] = []
        for await e in stream { out.append(e) }
        return out
    }

    @Test("empty stream yields started then completed")
    func emptyStream() async {
        let raw = makeResultStream([Result<ChatCompletionChunk, SamplingError>]())
        let events = await collect(streamChatCompletions(
            rawStream: raw,
            modelMetadata: nil,
            requestId: rid(),
            idleTimeout: .seconds(60)
        ))
        #expect(events.count == 2)
        if case .streamStarted = events[0] {} else { Issue.record("expected StreamStarted") }
        if case .completed(_, let response, _) = events[1] {
            #expect(response.isEmpty)
        } else {
            Issue.record("expected Completed")
        }
    }

    @Test("text stream emits first token then channel tokens")
    func textStream() async {
        let chunks: [Result<ChatCompletionChunk, SamplingError>] = [
            .success(textChunk("Hello, ")),
            .success(textChunk("world!")),
            .success(finalChunk()),
        ]
        let events = await collect(streamChatCompletions(
            rawStream: makeResultStream(chunks),
            modelMetadata: nil,
            requestId: rid(),
            idleTimeout: .seconds(60)
        ))
        if case .streamStarted = events[0] {} else { Issue.record("started") }
        if case .firstToken = events[1] {} else { Issue.record("first token") }
        let texts = events.compactMap { e -> String? in
            if case .channelToken(_, .text, let t, _) = e { return t }
            return nil
        }
        #expect(texts == ["Hello, ", "world!"])
        if case .completed(_, let response, _) = events.last {
            #expect(response.assistantText() == "Hello, world!")
            #expect(response.stopReason == .stop)
            #expect(response.messageChunksEmitted == 2)
        } else {
            Issue.record("expected completed")
        }
    }

    @Test("tool call stream assembles final call")
    func toolCalls() async {
        let chunk1 = ChatCompletionChunk(
            id: "c", object: "chat.completion.chunk", created: 0, model: "m",
            choices: [ChatChunkChoice(
                index: 0,
                delta: ChatChunkDelta(toolCalls: [
                    ToolCallDelta(
                        index: 0,
                        id: "call_abc",
                        kind: "function",
                        function: ToolCallFunctionDelta(name: "do_thing", arguments: #"{"x":"#)
                    ),
                ]),
                finishReason: nil
            )]
        )
        let chunk2 = ChatCompletionChunk(
            id: "c", object: "chat.completion.chunk", created: 0, model: "m",
            choices: [ChatChunkChoice(
                index: 0,
                delta: ChatChunkDelta(toolCalls: [
                    ToolCallDelta(
                        index: 0,
                        function: ToolCallFunctionDelta(arguments: "1}")
                    ),
                ]),
                finishReason: nil
            )]
        )
        let events = await collect(streamChatCompletions(
            rawStream: makeResultStream([.success(chunk1), .success(chunk2)]),
            modelMetadata: nil,
            requestId: rid(),
            idleTimeout: .seconds(60)
        ))
        if case .completed(_, let response, _) = events.last {
            let calls = response.toolCalls()
            #expect(calls.count == 1)
            #expect(calls[0].id == "call_abc")
            #expect(calls[0].name == "do_thing")
            #expect(calls[0].arguments == #"{"x":1}"#)
            #expect(response.stopReason == .toolCalls)
        } else {
            Issue.record("expected completed")
        }
    }

    @Test("mid-stream error yields failed without completed")
    func midStreamError() async {
        let chunks: [Result<ChatCompletionChunk, SamplingError>] = [
            .success(textChunk("hi")),
            .failure(.eventStreamError("conn reset")),
        ]
        let events = await collect(streamChatCompletions(
            rawStream: makeResultStream(chunks),
            modelMetadata: nil,
            requestId: rid(),
            idleTimeout: .seconds(60)
        ))
        #expect(events.contains { if case .failed = $0 { return true }; return false })
        #expect(!events.contains { if case .completed = $0 { return true }; return false })
    }

    @Test("reasoning channel emits once first token")
    func reasoning() async {
        let reasoning = ChatCompletionChunk(
            id: "c", object: "chat.completion.chunk", created: 0, model: "m",
            choices: [ChatChunkChoice(
                index: 0,
                delta: ChatChunkDelta(reasoningContent: "thinking..."),
                finishReason: nil
            )]
        )
        let events = await collect(streamChatCompletions(
            rawStream: makeResultStream([
                .success(reasoning),
                .success(textChunk("done")),
                .success(finalChunk()),
            ]),
            modelMetadata: nil,
            requestId: rid(),
            idleTimeout: .seconds(60)
        ))
        let firstCount = events.filter { if case .firstToken = $0 { return true }; return false }.count
        #expect(firstCount == 1)
        if case .completed(_, let response, _) = events.last {
            #expect(!response.reasoningItems().isEmpty)
        } else {
            Issue.record("completed")
        }
    }
}

// MARK: - Collect

@Suite("Collect response")
struct CollectTests {
    @Test("happy path")
    func happy() async {
        let chunks: [Result<ChatCompletionChunk, SamplingError>] = [
            .success(ChatCompletionChunk(
                id: "c", object: "chat.completion.chunk", created: 0, model: "m",
                choices: [ChatChunkChoice(
                    index: 0,
                    delta: ChatChunkDelta(role: .assistant, content: "hello"),
                    finishReason: nil
                )]
            )),
            .success(ChatCompletionChunk(
                id: "c", object: "chat.completion.chunk", created: 0, model: "m",
                choices: [ChatChunkChoice(
                    index: 0,
                    delta: ChatChunkDelta(),
                    finishReason: .stop
                )]
            )),
        ]
        let events = streamChatCompletions(
            rawStream: makeResultStream(chunks),
            modelMetadata: nil,
            requestId: RequestId("collect"),
            idleTimeout: .seconds(60)
        )
        switch await collectResponse(events) {
        case .success(let (response, _)):
            #expect(response.assistantText() == "hello")
        case .failure:
            Issue.record("expected success")
        }
    }

    @Test("truncated stream returns error")
    func truncated() async {
        let stream = AsyncStream<SamplingEvent> { cont in
            cont.yield(.streamStarted(requestId: RequestId("t"), timestampMs: 0))
            cont.finish()
        }
        switch await collectResponse(stream) {
        case .failure(let info):
            #expect(info.kind == .api)
            #expect(info.message.contains("stream ended without"))
        case .success:
            Issue.record("expected failure")
        }
    }
}

// MARK: - Conversation projection

@Suite("Request projection")
struct ProjectionTests {
    @Test("chat projection folds reasoning into assistant")
    func foldReasoning() {
        let items: [ConversationItem] = [
            .system("sys"),
            .user("hi"),
            .reasoning(synthesizedReasoningItem("think")),
            .assistant("hello"),
        ]
        let msgs = conversationToChatMessages(items)
        #expect(msgs.count == 3)
        #expect(msgs[0].role == .system)
        #expect(msgs[2].reasoningContent == "think")
        #expect(msgs[2].content == .text("hello"))
    }

    @Test("strip images replaces image parts")
    func stripImages() {
        var req = ConversationRequest(items: [
            .userWithParts([
                .text(text: "see"),
                .image(url: "data:image/png;base64,abc"),
            ]),
        ])
        let n = req.stripImages()
        #expect(n == 1)
        if case .user(let u) = req.items[0] {
            #expect(u.content.count == 2)
            if case .text(let t) = u.content[1] {
                #expect(t.contains("image removed"))
            } else {
                Issue.record("expected text placeholder")
            }
        }
    }

    @Test("bearer prefix scrub")
    func scrub() {
        let full = "sk-abcdefghijklmnopqrstuvwxyz"
        #expect(scrubbedBearerPrefix(full).count == SENT_BEARER_PREFIX_LEN)
        #expect(scrubbedBearerPrefix("short") == "short")
    }
}

// MARK: - Doom loop collector

@Suite("Doom loop collector")
struct DoomLoopCollectorTests {
    @Test("absorb swallows check event and records signals")
    func absorb() {
        let collector = DoomLoopSignalCollector()
        #expect(collector.absorb(eventName: DOOM_LOOP_CHECK_EVENT_TYPE, data: SAMPLE_CHECK_EVENT_DATA))
        let signals = collector.take()
        #expect(signals.count == 1)
        if case .tailRepetition(let t) = signals[0].kind {
            #expect(t == 4)
        } else {
            Issue.record("expected tailRepetition")
        }
    }

    @Test("disarm suppresses abort triggers")
    func disarm() {
        let policy = DoomLoopRecoveryPolicy(maxThreshold: 8, maxRetries: 2)
        let collector = DoomLoopSignalCollector(policy: policy)
        _ = collector.absorb(
            eventName: DOOM_LOOP_CHECK_EVENT_TYPE,
            data: #"{"type":"response.doom_loop_check","doom_loop_check":{"triggers":["tail_repetition:4@thinking"]}}"#
        )
        #expect(collector.abortTriggers() != nil)
        collector.disarmAbort()
        #expect(collector.abortTriggers() == nil)
    }

    @Test("absorb malformed check event logs diagnostic once and swallows")
    func malformedLogging() {
        let collector = DoomLoopSignalCollector()
        #expect(collector.absorb(eventName: DOOM_LOOP_CHECK_EVENT_TYPE, data: "not valid json"))
        #expect(collector.take().isEmpty)
    }
}

// MARK: - Messages L2

@Suite("Stream messages")
struct StreamMessagesTests {
    @Test("text block assembles into completed response")
    func textBlock() async {
        let events: [Result<MessageStreamEvent, SamplingError>] = [
            .success(.messageStart(message: MessagesResponse(
                id: "m1", type: "message", role: "assistant",
                content: [], model: "claude", usage: MessagesUsage(inputTokens: 10, outputTokens: 0)
            ))),
            .success(.contentBlockStart(index: 0, contentBlock: .text(text: "", cacheControl: nil))),
            .success(.contentBlockDelta(index: 0, delta: .textDelta(text: "Hi"))),
            .success(.contentBlockStop(index: 0)),
            .success(.messageDelta(
                delta: MessageDeltaBody(stopReason: .endTurn),
                usage: MessageDeltaUsage(outputTokens: 1, inputTokens: 10)
            )),
            .success(.messageStop),
        ]
        var out: [SamplingEvent] = []
        for await e in streamMessages(
            rawStream: makeResultStream(events),
            modelMetadata: nil,
            requestId: RequestId("msg"),
            idleTimeout: .seconds(60)
        ) {
            out.append(e)
        }
        if case .completed(_, let response, _) = out.last {
            #expect(response.assistantText() == "Hi")
            #expect(response.stopReason == .stop)
            #expect(response.usage?.promptTokens == 10)
        } else {
            Issue.record("expected completed")
        }
    }

    @Test("server error yields failed 500")
    func serverError() async {
        let events: [Result<MessageStreamEvent, SamplingError>] = [
            .success(.error(error: StreamError(type: "api_error", message: "boom"))),
        ]
        var out: [SamplingEvent] = []
        for await e in streamMessages(
            rawStream: makeResultStream(events),
            modelMetadata: nil,
            requestId: RequestId("msg"),
            idleTimeout: .seconds(60)
        ) {
            out.append(e)
        }
        if case .failed(_, let info) = out.last {
            #expect(info.statusCode == 500)
            #expect(info.message.contains("boom"))
        } else {
            Issue.record("expected failed")
        }
    }

    @Test("thinking block preserves encrypted reasoning signature")
    func thinkingSignature() async {
        let events: [Result<MessageStreamEvent, SamplingError>] = [
            .success(.messageStart(message: MessagesResponse(
                id: "m1", type: "message", role: "assistant",
                content: [], model: "claude", usage: MessagesUsage(inputTokens: 10, outputTokens: 0)
            ))),
            .success(.contentBlockStart(index: 0, contentBlock: .thinking(thinking: "deliberating", signature: "sig_enc_123"))),
            .success(.contentBlockStop(index: 0)),
            .success(.messageDelta(
                delta: MessageDeltaBody(stopReason: .endTurn),
                usage: MessageDeltaUsage(outputTokens: 5, inputTokens: 10)
            )),
            .success(.messageStop),
        ]
        var out: [SamplingEvent] = []
        for await e in streamMessages(
            rawStream: makeResultStream(events),
            modelMetadata: nil,
            requestId: RequestId("msg"),
            idleTimeout: .seconds(60)
        ) {
            out.append(e)
        }
        if case .completed(_, let response, _) = out.last {
            guard let reasoningItem = response.reasoningItems().first else {
                Issue.record("expected reasoning item")
                return
            }
            #expect(reasoningItem.encryptedContent == "sig_enc_123")
            #expect(reasoningItem.summary.first?.text == "deliberating")
        } else {
            Issue.record("expected completed")
        }
    }

    @Test("start-populated text block emits first token immediately")
    func textBlockStartFirstToken() async {
        let events: [Result<MessageStreamEvent, SamplingError>] = [
            .success(.messageStart(message: MessagesResponse(
                id: "m1", type: "message", role: "assistant",
                content: [], model: "claude", usage: MessagesUsage(inputTokens: 10, outputTokens: 0)
            ))),
            .success(.contentBlockStart(index: 0, contentBlock: .text(text: "Inline text", cacheControl: nil))),
            .success(.contentBlockStop(index: 0)),
            .success(.messageDelta(
                delta: MessageDeltaBody(stopReason: .endTurn),
                usage: MessageDeltaUsage(outputTokens: 2, inputTokens: 10)
            )),
            .success(.messageStop),
        ]
        var out: [SamplingEvent] = []
        for await e in streamMessages(
            rawStream: makeResultStream(events),
            modelMetadata: nil,
            requestId: RequestId("msg"),
            idleTimeout: .seconds(60)
        ) {
            out.append(e)
        }
        let firstTokenEvents = out.filter { if case .firstToken = $0 { return true }; return false }
        #expect(firstTokenEvents.count == 1)
        if case .completed(_, let response, _) = out.last {
            #expect(response.assistantText() == "Inline text")
        } else {
            Issue.record("expected completed")
        }
    }

    @Test("multiple text blocks insert newline separator")
    func multiTextBlockNewline() async {
        let events: [Result<MessageStreamEvent, SamplingError>] = [
            .success(.messageStart(message: MessagesResponse(
                id: "m1", type: "message", role: "assistant",
                content: [], model: "claude", usage: MessagesUsage(inputTokens: 10, outputTokens: 0)
            ))),
            .success(.contentBlockStart(index: 0, contentBlock: .text(text: "First block", cacheControl: nil))),
            .success(.contentBlockStop(index: 0)),
            .success(.contentBlockStart(index: 1, contentBlock: .text(text: "Second block", cacheControl: nil))),
            .success(.contentBlockStop(index: 1)),
            .success(.messageDelta(
                delta: MessageDeltaBody(stopReason: .endTurn),
                usage: MessageDeltaUsage(outputTokens: 4, inputTokens: 10)
            )),
            .success(.messageStop),
        ]
        var out: [SamplingEvent] = []
        for await e in streamMessages(
            rawStream: makeResultStream(events),
            modelMetadata: nil,
            requestId: RequestId("msg"),
            idleTimeout: .seconds(60)
        ) {
            out.append(e)
        }
        if case .completed(_, let response, _) = out.last {
            #expect(response.assistantText() == "First block\nSecond block")
        } else {
            Issue.record("expected completed")
        }
    }
}

// MARK: - Responses L2

@Suite("Stream responses")
struct StreamResponsesTests {
    @Test("text delta then completed")
    func textThenCompleted() async {
        let completedJSON: JSONValue = .object([
            "id": .string("resp_1"),
            "status": .string("completed"),
            "model": .string("test"),
            "output": .array([
                .object([
                    "type": .string("message"),
                    "role": .string("assistant"),
                    "content": .array([
                        .object([
                            "type": .string("output_text"),
                            "text": .string("hello"),
                        ]),
                    ]),
                ]),
            ]),
        ])
        let raw: [Result<ResponsesStreamEvent, SamplingError>] = [
            .success(.outputTextDelta(delta: "hello", itemId: "i1", outputIndex: 0)),
            .success(.completed(response: completedJSON)),
        ]
        var out: [SamplingEvent] = []
        for await e in streamResponses(
            rawStream: makeResultStream(raw),
            modelMetadata: nil,
            requestId: RequestId("r"),
            idleTimeout: .seconds(60)
        ) {
            out.append(e)
        }
        let texts = out.compactMap { e -> String? in
            if case .channelToken(_, .text, let t, _) = e { return t }
            return nil
        }
        #expect(texts == ["hello"])
        if case .completed(_, let response, _) = out.last {
            #expect(response.stopReason == .stop)
            #expect(response.assistantText() == "hello")
        } else {
            Issue.record("expected completed")
        }
    }

    @Test("missing completed yields failed")
    func missingCompleted() async {
        let raw: [Result<ResponsesStreamEvent, SamplingError>] = []
        var out: [SamplingEvent] = []
        for await e in streamResponses(
            rawStream: makeResultStream(raw),
            modelMetadata: nil,
            requestId: RequestId("r"),
            idleTimeout: .seconds(60)
        ) {
            out.append(e)
        }
        if case .failed(_, let info) = out.last {
            #expect(info.statusCode == 500)
        } else {
            Issue.record("expected failed")
        }
    }

    @Test("decode output_item.done tool call")
    func outputItemDone() async {
        let item: JSONValue = .object([
            "type": .string("function_call"),
            "call_id": .string("call_1"),
            "name": .string("read"),
            "arguments": .string(#"{"path":"a"}"#),
        ])
        let completed: JSONValue = .object([
            "id": .string("resp"),
            "status": .string("completed"),
            "model": .string("m"),
            "output": .array([item]),
        ])
        let raw: [Result<ResponsesStreamEvent, SamplingError>] = [
            .success(.outputItemDone(outputIndex: 0, item: item)),
            .success(.completed(response: completed)),
        ]
        var out: [SamplingEvent] = []
        for await e in streamResponses(
            rawStream: makeResultStream(raw),
            modelMetadata: nil,
            requestId: RequestId("r"),
            idleTimeout: .seconds(60)
        ) {
            out.append(e)
        }
        if case .completed(_, let response, _) = out.last {
            #expect(response.toolCalls().count == 1)
            #expect(response.stopReason == .toolCalls)
        } else {
            Issue.record("expected completed")
        }
    }

    @Test("response.done decodes as terminal completed response")
    func responseDoneDecoding() throws {
        let doneJSON = """
        {"type":"response.done","response":{"id":"resp_done","status":"completed","model":"test-codex","output":[{"type":"message","role":"assistant","content":"Done!"}]}}
        """
        let event = try ResponsesStreamEvent.decode(data: doneJSON)
        if case .completed(let resp) = event {
            #expect(resp["id"]?.stringValue == "resp_done" || resp["response"]?["id"]?.stringValue == "resp_done")
        } else {
            Issue.record("expected completed event for response.done")
        }
    }

    @Test("custom tool call argument streaming and done handling")
    func customToolCallInputStreaming() throws {
        let deltaJSON = """
        {"type":"response.custom_tool_call_input.delta","call_id":"custom_call_1","delta":"ls -la","output_index":0}
        """
        let eventDelta = try ResponsesStreamEvent.decode(data: deltaJSON)
        if case .customToolCallInputDelta(let delta, let itemId, let index) = eventDelta {
            #expect(delta == "ls -la")
            #expect(itemId == "custom_call_1")
            #expect(index == 0)
        } else {
            Issue.record("expected customToolCallInputDelta")
        }

        let doneJSON = """
        {"type":"response.custom_tool_call_input.done","call_id":"custom_call_1","input":"ls -la","output_index":0}
        """
        let eventDone = try ResponsesStreamEvent.decode(data: doneJSON)
        if case .customToolCallInputDone(let input, let itemId, let index) = eventDone {
            #expect(input == "ls -la")
            #expect(itemId == "custom_call_1")
            #expect(index == 0)
        } else {
            Issue.record("expected customToolCallInputDone")
        }
    }
}

@Suite("Stream timeout and cancellation")
struct StreamTimeoutAndCancellationTests {
    @Test("chat completions times out while awaiting the next chunk")
    func chatTimeout() async {
        let source = PendingStreamSource<Result<ChatCompletionChunk, SamplingError>>()
        let events = await collectSamplingEvents(streamChatCompletions(
            rawStream: source.stream(),
            modelMetadata: nil,
            requestId: RequestId("chat-timeout"),
            idleTimeout: .milliseconds(30)
        ))
        let sourceStopped = await waitUntil { source.isTerminated }
        if case .failed(_, let info) = events.last {
            #expect(info.kind == .idleTimeout)
        } else {
            Issue.record("expected idle timeout")
        }
        #expect(sourceStopped)
    }

    @Test("messages times out while awaiting the next event")
    func messagesTimeout() async {
        let source = PendingStreamSource<Result<MessageStreamEvent, SamplingError>>()
        let events = await collectSamplingEvents(streamMessages(
            rawStream: source.stream(),
            modelMetadata: nil,
            requestId: RequestId("messages-timeout"),
            idleTimeout: .milliseconds(30)
        ))
        let sourceStopped = await waitUntil { source.isTerminated }
        if case .failed(_, let info) = events.last {
            #expect(info.kind == .idleTimeout)
        } else {
            Issue.record("expected idle timeout")
        }
        #expect(sourceStopped)
    }

    @Test("responses times out while awaiting the next event")
    func responsesTimeout() async {
        let source = PendingStreamSource<Result<ResponsesStreamEvent, SamplingError>>()
        let events = await collectSamplingEvents(streamResponses(
            rawStream: source.stream(),
            modelMetadata: nil,
            requestId: RequestId("responses-timeout"),
            idleTimeout: .milliseconds(30)
        ))
        let sourceStopped = await waitUntil { source.isTerminated }
        if case .failed(_, let info) = events.last {
            #expect(info.kind == .idleTimeout)
        } else {
            Issue.record("expected idle timeout")
        }
        #expect(sourceStopped)
    }

    @Test("chat completions cancellation reaches the source")
    func chatCancellation() async {
        let source = PendingStreamSource<Result<ChatCompletionChunk, SamplingError>>()
        await expectPromptCancellation(
            stream: streamChatCompletions(
                rawStream: source.stream(),
                modelMetadata: nil,
                requestId: RequestId("chat-cancel"),
                idleTimeout: .seconds(60)
            ),
            source: source
        )
    }

    @Test("messages cancellation reaches the source")
    func messagesCancellation() async {
        let source = PendingStreamSource<Result<MessageStreamEvent, SamplingError>>()
        await expectPromptCancellation(
            stream: streamMessages(
                rawStream: source.stream(),
                modelMetadata: nil,
                requestId: RequestId("messages-cancel"),
                idleTimeout: .seconds(60)
            ),
            source: source
        )
    }

    @Test("responses cancellation reaches the source")
    func responsesCancellation() async {
        let source = PendingStreamSource<Result<ResponsesStreamEvent, SamplingError>>()
        await expectPromptCancellation(
            stream: streamResponses(
                rawStream: source.stream(),
                modelMetadata: nil,
                requestId: RequestId("responses-cancel"),
                idleTimeout: .seconds(60)
            ),
            source: source
        )
    }
}

// MARK: - Hermetic HTTP client + actor

@Suite("SamplingClient hermetic")
struct ClientHermeticTests {
    private func sseBody(_ events: [String]) -> Data {
        var s = ""
        for e in events {
            s += "data: \(e)\n\n"
        }
        s += "data: [DONE]\n\n"
        return Data(s.utf8)
    }

    @Test("chat completions stream end-to-end via mock transport")
    func chatStream() async throws {
        let chunk1 = #"{"id":"1","object":"chat.completion.chunk","created":0,"model":"m","choices":[{"index":0,"delta":{"role":"assistant","content":"Hi"},"finish_reason":null}]}"#
        let chunk2 = #"{"id":"1","object":"chat.completion.chunk","created":0,"model":"m","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream"]
                ),
                body: sseBody([chunk1, chunk2])
            ),
        ])
        let config = SamplerConfig(
            apiKey: "test-key",
            baseURL: "https://api.example.test",
            model: "test-model",
            apiBackend: .chatCompletions,
            provider: .xai
        )
        let client = try SamplingClient(config: config, transport: transport)
        let response = try await client.conversationCollect(
            ConversationRequest(items: [.user("hello")]),
            idleTimeout: .seconds(30)
        )
        #expect(response.assistantText() == "Hi")
        #expect(transport.recordedRequests.count == 1)
        #expect(transport.recordedRequests[0].url.absoluteString == "https://api.example.test/v1/chat/completions")
        #expect(transport.recordedRequests[0].headers["Authorization"] == "Bearer test-key")
    }

    @Test("API prefix base URL does not duplicate v1")
    func apiPrefixURL() async throws {
        let chunk = #"{"id":"1","object":"chat.completion.chunk","created":0,"model":"m","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}]}"#
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream"]
                ),
                body: sseBody([chunk])
            ),
        ])
        let client = try SamplingClient(
            config: SamplerConfig(
                apiKey: "test-key",
                baseURL: "https://api.fireworks.ai/inference/v1",
                model: "accounts/fireworks/models/test",
                apiBackend: .chatCompletions,
                provider: .fireworks
            ),
            transport: transport
        )

        let response = try await client.conversationCollect(
            ConversationRequest(items: [.user("hello")]),
            idleTimeout: .seconds(30)
        )

        #expect(response.assistantText() == "ok")
        #expect(transport.recordedRequests.count == 1)
        #expect(
            transport.recordedRequests[0].url.absoluteString
                == "https://api.fireworks.ai/inference/v1/chat/completions"
        )
    }

    @Test("401 emits auth error and scrubs bearer")
    func auth401() async throws {
        final class Attr: Auth401AttributionCallback, @unchecked Sendable {
            var seen: String?
            func record401(consumer: SamplingConsumer, sentBearerPrefix: String?) {
                seen = sentBearerPrefix
            }
        }
        let attr = Attr()
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(statusCode: 401, headers: [:]),
                body: Data(#"{"error":{"message":"unauthorized","type":"auth"}}"#.utf8)
            ),
        ])
        let config = SamplerConfig(
            apiKey: "super-secret-token-value",
            baseURL: "https://api.example.test",
            model: "m",
            attributionCallback: attr
        )
        let client = try SamplingClient(config: config, transport: transport)
        do {
            _ = try await client.conversationCollect(
                ConversationRequest(items: [.user("x")]),
                idleTimeout: .seconds(10)
            )
            Issue.record("expected throw")
        } catch let err as SamplingError {
            #expect(err.isAuthError)
            if case .auth(_, let credential) = err {
                #expect(credential == .sent)
            } else {
                Issue.record("expected credentialed auth error")
            }
            #expect(attr.seen == scrubbedBearerPrefix("super-secret-token-value"))
            #expect(attr.seen?.count == SENT_BEARER_PREFIX_LEN)
        }
    }

    @Test("kimi provider isolation strips sampling fields in body")
    func kimiBody() async throws {
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream"]
                ),
                body: sseBody([
                    #"{"id":"1","object":"chat.completion.chunk","created":0,"model":"k","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}]}"#,
                ])
            ),
        ])
        let config = SamplerConfig(
            apiKey: "k",
            baseURL: "https://api.moonshot.test/v1",
            model: "kimi",
            temperature: 0.9,
            topP: 0.5,
            apiBackend: .chatCompletions,
            provider: .kimi
        )
        let client = try SamplingClient(config: config, transport: transport)
        // Fire stream; ignore response — we care about recorded body.
        let req = ConversationRequest(items: [.user("hi")], temperature: 0.9, topP: 0.5)
        _ = try? await client.conversationCollect(req, idleTimeout: .seconds(5))
        #expect(transport.recordedRequests.count == 1)
        #expect(transport.recordedRequests[0].url.absoluteString == "https://api.moonshot.test/v1/chat/completions")
        if let body = transport.recordedRequests[0].body,
           let json = try? JSONDecoder().decode(JSONValue.self, from: body)
        {
            #expect(json["temperature"] == nil)
            #expect(json["top_p"] == nil)
        } else {
            Issue.record("missing body")
        }
    }
}

// MARK: - Actor integration

@Suite("Sampler actor")
struct ActorTests {
    private func sseBody(_ events: [String]) -> Data {
        var s = ""
        for e in events {
            s += "data: \(e)\n\n"
        }
        s += "data: [DONE]\n\n"
        return Data(s.utf8)
    }

    @Test("submit emits exactly one terminal completed")
    func submitCompleted() async throws {
        let chunk = #"{"id":"1","object":"chat.completion.chunk","created":0,"model":"m","choices":[{"index":0,"delta":{"content":"yo"},"finish_reason":"stop"}]}"#
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream"]
                ),
                body: sseBody([chunk])
            ),
        ])
        let config = SamplerConfig(
            apiKey: "k",
            baseURL: "https://api.example.test",
            model: "m",
            maxRetries: 0
        )
        let spawn = SamplerActor.spawn(
            config: config,
            retryPolicy: RetryPolicy(maxRetries: 0),
            transport: transport
        )
        let id = RequestId("actor-1")
        spawn.handle.submit(requestId: id, request: ConversationRequest(items: [.user("hi")]))

        var terminals = 0
        var sawCompleted = false
        for await event in spawn.events {
            switch event {
            case .completed(let rid, let response, _):
                #expect(rid == id)
                #expect(response.assistantText() == "yo")
                sawCompleted = true
                terminals += 1
                break
            case .failed:
                terminals += 1
                break
            default:
                continue
            }
            if terminals > 0 { break }
        }
        #expect(sawCompleted)
        #expect(terminals == 1)
    }

    @Test("submitAndCollect returns result")
    func submitAndCollect() async throws {
        let chunk = #"{"id":"1","object":"chat.completion.chunk","created":0,"model":"m","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}]}"#
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream"]
                ),
                body: sseBody([chunk])
            ),
        ])
        let config = SamplerConfig(
            apiKey: "k",
            baseURL: "https://api.example.test",
            model: "m",
            maxRetries: 0
        )
        let spawn = SamplerActor.spawn(config: config, retryPolicy: RetryPolicy(maxRetries: 0), transport: transport)
        let result = await spawn.handle.submitAndCollect(
            requestId: RequestId("collect-1"),
            request: ConversationRequest(items: [.user("x")])
        )
        switch result {
        case .success(let (response, metrics)):
            #expect(response.assistantText() == "ok")
            #expect(metrics.attempts == 1)
        case .failure(let err):
            Issue.record("unexpected failure: \(err)")
        }
    }

    @Test("retry once on 500 then succeed")
    func retry500() async throws {
        let okChunk = #"{"id":"1","object":"chat.completion.chunk","created":0,"model":"m","choices":[{"index":0,"delta":{"content":"recovered"},"finish_reason":"stop"}]}"#
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(statusCode: 500, headers: [:]),
                body: Data(#"{"error":{"message":"transient","type":"server_error"}}"#.utf8)
            ),
            .init(
                metadata: HTTPResponseMetadata(
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream"]
                ),
                body: sseBody([okChunk])
            ),
        ])
        let config = SamplerConfig(
            apiKey: "k",
            baseURL: "https://api.example.test",
            model: "m",
            maxRetries: 3
        )
        let spawn = SamplerActor.spawn(
            config: config,
            retryPolicy: RetryPolicy(maxRetries: 3),
            transport: transport
        )
        let result = await spawn.handle.submitAndCollect(
            requestId: RequestId("retry-1"),
            request: ConversationRequest(items: [.user("x")])
        )
        switch result {
        case .success(let (response, metrics)):
            #expect(response.assistantText() == "recovered")
            #expect(metrics.attempts >= 2)
        case .failure(let err):
            Issue.record("unexpected failure: \(err)")
        }
        #expect(transport.recordedRequests.count == 2)
    }

    @Test("noop handle does not crash")
    func noop() {
        let h = SamplerHandle.noop()
        h.submit(requestId: RequestId("n"), request: ConversationRequest())
        h.cancel(requestId: RequestId("n"))
    }
}

// MARK: - Config serde

@Suite("SamplerConfig serde")
struct ConfigSerdeTests {
    @Test("missing doom_loop_recovery deserializes to nil")
    func doomLoopOptional() throws {
        var value = try JSONValue.encode(SamplerConfig())
        if case .object(var obj) = value {
            obj.removeValue(forKey: "doom_loop_recovery")
            value = .object(obj)
        }
        let data = try WireJSONEncoder.make().encode(value)
        let config = try JSONDecoder().decode(SamplerConfig.self, from: data)
        #expect(config.doomLoopRecovery == nil)
    }

    @Test("retry policy defaults")
    func retryDefaults() {
        let p = RetryPolicy.default
        #expect(p.maxRetries == DEFAULT_MAX_RETRIES)
        #expect(p.rateLimitRetryThreshold == RATE_LIMIT_RETRY_THRESHOLD)
    }
}
