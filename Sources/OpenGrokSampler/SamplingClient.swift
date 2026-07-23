// SamplingClient.swift
//
// Layer-1 HTTP streaming client. Uses injected ``HTTPTransport`` so tests
// stay hermetic and Auth/Models remain out of this module.
// Mirrors the public surface of Rust `client.rs` (conversation_stream*, etc.).

import Foundation
import OpenGrokHTTP
import OpenGrokSamplingTypes
import OpenGrokShared

/// Render a User-Agent string for the given origin client.
public func userAgentStringFor(
    _ origin: OriginClientInfo,
    agentProduct: String = "open-grok",
    agentVersion: String? = nil
) -> String {
    let version = agentVersion ?? ProcessInfo.processInfo.environment["GROK_VERSION"] ?? "0.0.0"
    return sessionUserAgentString(
        origin: origin,
        agentProduct: agentProduct,
        agentVersion: version
    )
}

/// Sampling HTTP client. Stateless with respect to conversation history;
/// credentials and defaults are snapshotted at construction.
public final class SamplingClient: @unchecked Sendable {
    private let transport: any HTTPTransport
    private var defaultHeaders: [String: String]
    private let baseURL: String
    public let defaults: SamplingClientDefaults
    private let providerAdapter: any ProviderAdapter
    private let attributionCallback: (any Auth401AttributionCallback)?
    private var bearerResolver: (any BearerResolver)?
    private let headerInjector: (any HeaderInjector)?
    private let codexTurnState: CodexTurnStateCell?
    private let forceHTTP1: Bool

    public var apiBackend: ApiBackend { defaults.apiBackend }
    public var provider: ModelProvider { defaults.provider }

    public init(
        config: SamplerConfig,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        codexTurnState: CodexTurnStateCell? = nil
    ) throws {
        let adapter = OpenGrokSampler.providerAdapter(config.provider)
        try adapter.validateBackend(config.apiBackend)

        let turnState: CodexTurnStateCell? =
            adapter.supportsTurnState(backend: config.apiBackend) ? codexTurnState : nil

        var headers: [String: String] = [
            "Content-Type": "application/json",
            "Accept": "text/event-stream, application/json",
        ]

        if let apiKey = config.apiKey {
            switch config.authScheme {
            case .xApiKey:
                headers["x-api-key"] = apiKey
            case .bearer:
                headers["Authorization"] = "Bearer \(apiKey)"
            }
        }

        for (name, value) in config.extraHeaders {
            headers[name] = value
        }

        if let resolver = config.bearerResolver {
            for name in resolver.reservedHeaders {
                headers = headers.filter { $0.key.lowercased() != name.lowercased() }
            }
        }

        adapter.applyDefaultHeaders(&headers, config: config)

        let ua: String
        if let origin = config.originClient {
            ua = userAgentStringFor(origin)
        } else {
            ua = userAgentStringFor(OriginClientInfo(product: "open-grok"))
        }
        headers["User-Agent"] = ua

        self.transport = transport
        self.defaultHeaders = headers
        self.baseURL = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.defaults = SamplingClientDefaults(from: config)
        self.providerAdapter = adapter
        self.attributionCallback = config.attributionCallback
        self.bearerResolver = config.bearerResolver
        self.headerInjector = config.headerInjector
        self.codexTurnState = turnState
        self.forceHTTP1 = config.forceHTTP1
    }

    /// Replace a live bearer resolver without rebuilding model/endpoint defaults.
    @discardableResult
    public func replaceBearerResolverIfPresent(_ resolver: any BearerResolver) -> Bool {
        guard let previous = bearerResolver else { return false }
        for name in previous.reservedHeaders + resolver.reservedHeaders {
            defaultHeaders = defaultHeaders.filter { $0.key.lowercased() != name.lowercased() }
        }
        bearerResolver = resolver
        return true
    }

    // MARK: - Conversation streaming

    public func conversationStream(
        _ request: ConversationRequest
    ) async throws -> (AsyncStream<Result<ChatCompletionChunk, SamplingError>>, ResponseModelMetadata?) {
        var req = request
        applyConversationDefaults(&req)
        var wire = projectChatCompletionRequest(req, defaults: defaults)
        providerAdapter.sanitizeChatRequest(&wire)
        wire.stream = true
        wire.streamOptions = StreamOptionsWire(includeUsage: true)
        if wire.model == nil || wire.model?.isEmpty == true {
            wire.model = defaults.model
        }
        return try await chatCompletionStream(wire)
    }

    public func conversationStreamResponses(
        _ request: ConversationRequest
    ) async throws -> (
        AsyncStream<Result<ResponsesStreamEvent, SamplingError>>,
        ResponseModelMetadata?,
        DoomLoopSignalCollector?,
        [String]
    ) {
        var req = request
        applyConversationDefaults(&req)
        let clientCustomToolNames = req.clientCustomToolNames()
        let policy = ResponsesRequestPolicy(
            multiAgentV2: defaults.codexMultiAgentV2,
            localEffort: req.reasoningEffort ?? defaults.reasoningEffort,
            reasoningSummary: defaults.reasoningSummary
        )
        var body = projectResponsesRequestBody(
            req,
            model: req.model ?? defaults.model,
            policy: policy,
            adapter: providerAdapter
        )
        if case .object(var obj) = body {
            obj["stream"] = .bool(true)
            body = .object(obj)
        }

        let doom: DoomLoopSignalCollector?
        if let policy = defaults.doomLoopRecovery, providerAdapter.sendsDoomLoopOptIn {
            doom = DoomLoopSignalCollector(policy: policy)
        } else {
            doom = nil
        }

        let (stream, meta) = try await postSSE(
            path: "/v1/responses",
            body: body,
            consumer: .responsesStream,
            requestHeaders: providerRequestHeaders(from: req),
            doomLoop: doom,
            decode: { data in try ResponsesStreamEvent.decode(data: data) }
        )
        return (stream, meta, doom, clientCustomToolNames)
    }

    public func conversationStreamMessages(
        _ request: ConversationRequest
    ) async throws -> (AsyncStream<Result<MessageStreamEvent, SamplingError>>, ResponseModelMetadata?) {
        var req = request
        applyConversationDefaults(&req)
        var wire = projectMessagesRequest(
            req,
            model: req.model ?? defaults.model,
            maxTokens: req.maxOutputTokens ?? defaults.maxCompletionTokens ?? 4096
        )
        wire.stream = true
        let body = try JSONValue.encode(wire)
        return try await postSSE(
            path: "/v1/messages",
            body: body,
            consumer: .messagesStream,
            requestHeaders: providerRequestHeaders(from: req),
            doomLoop: nil,
            decode: { data in
                try JSONDecoder().decode(MessageStreamEvent.self, from: Data(data.utf8))
            }
        )
    }

    /// Backend-aware streaming call that collects the full response.
    public func conversationCollect(
        _ request: ConversationRequest,
        requestId: RequestId = .random(),
        idleTimeout: MonotonicDuration = .seconds(300)
    ) async throws -> ConversationResponse {
        switch defaults.apiBackend {
        case .chatCompletions:
            let (raw, meta) = try await conversationStream(request)
            let events = streamChatCompletions(
                rawStream: raw,
                modelMetadata: meta,
                requestId: requestId,
                idleTimeout: idleTimeout
            )
            switch await collectResponse(events) {
            case .success(let pair): return pair.0
            case .failure(let info): throw synthesizeFromInfo(info)
            }
        case .responses:
            let (raw, meta, doom, names) = try await conversationStreamResponses(request)
            let events = streamResponsesWithClientCustomTools(
                rawStream: raw,
                modelMetadata: meta,
                requestId: requestId,
                idleTimeout: idleTimeout,
                doomLoop: doom,
                clientCustomToolNames: names
            )
            switch await collectResponse(events) {
            case .success(let pair): return pair.0
            case .failure(let info): throw synthesizeFromInfo(info)
            }
        case .messages:
            let (raw, meta) = try await conversationStreamMessages(request)
            let events = streamMessages(
                rawStream: raw,
                modelMetadata: meta,
                requestId: requestId,
                idleTimeout: idleTimeout
            )
            switch await collectResponse(events) {
            case .success(let pair): return pair.0
            case .failure(let info): throw synthesizeFromInfo(info)
            }
        }
    }

    // MARK: - Chat completion stream

    private func chatCompletionStream(
        _ wire: ChatCompletionWireRequest
    ) async throws -> (AsyncStream<Result<ChatCompletionChunk, SamplingError>>, ResponseModelMetadata?) {
        let body = try JSONValue.encode(wire)
        return try await postSSE(
            path: "/v1/chat/completions",
            body: body,
            consumer: .chatCompletionsStream,
            requestHeaders: providerRequestHeaders(
                convId: wire.xGrokConvId,
                reqId: wire.xGrokReqId,
                modelId: wire.model ?? defaults.model,
                sessionId: wire.xGrokSessionId,
                turnIdx: wire.xGrokTurnIdx,
                agentId: wire.xGrokAgentId,
                deploymentId: wire.xGrokDeploymentId,
                userId: wire.xGrokUserId
            ),
            doomLoop: nil,
            decode: { data in
                if data.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
                    throw SSEDoneMarker()
                }
                if let streamErr = tryParseStreamError(data) {
                    throw streamErr
                }
                return try JSONDecoder().decode(ChatCompletionChunk.self, from: Data(data.utf8))
            }
        )
    }

    // MARK: - SSE POST (incremental)

    private struct SSEDoneMarker: Error {}

    private func postSSE<T: Sendable>(
        path: String,
        body: JSONValue,
        consumer: SamplingConsumer,
        requestHeaders: ProviderRequestHeaders?,
        doomLoop: DoomLoopSignalCollector?,
        decode: @escaping @Sendable (String) throws -> T
    ) async throws -> (AsyncStream<Result<T, SamplingError>>, ResponseModelMetadata?) {
        let url = try makeURL(path: path)
        var headers = buildHeaders(requestHeaders: requestHeaders)
        if doomLoop != nil, providerAdapter.sendsDoomLoopOptIn {
            headers[DOOM_LOOP_CHECK_HEADER] = "1"
        }

        let bodyData = try WireJSONEncoder.make().encode(body)
        let request = HTTPRequest(
            method: .post,
            url: url,
            headers: headers,
            body: bodyData,
            idempotency: .nonIdempotent
        )

        let httpStream = transport.stream(request)
        let iterator = AsyncThrowingStreamIteratorRelay(httpStream)

        // Wait for metadata first so non-2xx fails before any decoded event.
        var metadata: ResponseModelMetadata?
        var statusCode = 0
        var responseHeaders: [String: String] = [:]
        var earlyBody = Data()
        var sawMetadata = false

        while let event = try await iterator.next() {
            switch event {
            case .metadata(let meta):
                sawMetadata = true
                statusCode = meta.statusCode
                responseHeaders = meta.headers
                metadata = extractModelMetadata(from: meta.headers)
                providerAdapter.captureTurnState(from: meta.headers, into: codexTurnState)
                break
            case .body(let data):
                earlyBody.append(data)
            case .end:
                break
            }
            if sawMetadata { break }
        }

        guard sawMetadata else {
            throw SamplingError.http("missing response headers from sampling endpoint")
        }

        if !(200..<300).contains(statusCode) {
            var errBody = earlyBody
            while let event = try await iterator.next() {
                if case .body(let d) = event { errBody.append(d) }
            }
            throw mapHTTPError(
                status: statusCode,
                body: errBody,
                headers: responseHeaders,
                consumer: consumer
            )
        }

        let adapter = providerAdapter
        let turnState = codexTurnState
        let initialBody = earlyBody

        let resultStream = AsyncStream<Result<T, SamplingError>> { continuation in
            let task = Task {
                var parser = SSEParser()
                // Process any body bytes that arrived before/with metadata.
                if !initialBody.isEmpty {
                    do {
                        let events = try parser.push(initialBody)
                        if !(await Self.emitSSEEvents(
                            events,
                            adapter: adapter,
                            turnState: turnState,
                            doomLoop: doomLoop,
                            decode: decode,
                            continuation: continuation
                        )) {
                            return
                        }
                    } catch {
                        continuation.yield(.failure(.eventStreamError(String(describing: error))))
                        continuation.finish()
                        return
                    }
                }

                do {
                    while let event = try await iterator.next() {
                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }
                        switch event {
                        case .metadata:
                            continue
                        case .body(let data):
                            let events = try parser.push(data)
                            if !(await Self.emitSSEEvents(
                                events,
                                adapter: adapter,
                                turnState: turnState,
                                doomLoop: doomLoop,
                                decode: decode,
                                continuation: continuation
                            )) {
                                return
                            }
                        case .end:
                            break
                        }
                    }
                    let remaining = parser.finish()
                    _ = await Self.emitSSEEvents(
                        remaining,
                        adapter: adapter,
                        turnState: turnState,
                        doomLoop: doomLoop,
                        decode: decode,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let err as SamplingError {
                    continuation.yield(.failure(err))
                    continuation.finish()
                } catch {
                    continuation.yield(.failure(.eventStreamError(String(describing: error))))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        return (resultStream, metadata)
    }

    /// Returns `false` when the stream should stop (terminal error or [DONE]).
    private static func emitSSEEvents<T: Sendable>(
        _ events: [SSEEvent],
        adapter: any ProviderAdapter,
        turnState: CodexTurnStateCell?,
        doomLoop: DoomLoopSignalCollector?,
        decode: @escaping @Sendable (String) throws -> T,
        continuation: AsyncStream<Result<T, SamplingError>>.Continuation
    ) async -> Bool {
        for sse in events {
            if Task.isCancelled { return false }
            if adapter.absorbResponseMetadata(
                eventName: sse.event ?? "",
                data: sse.data,
                turnState: turnState
            ) {
                continue
            }
            if doomLoop?.absorb(eventName: sse.event ?? "", data: sse.data) == true {
                continue
            }
            let data = sse.data
            let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed == "[DONE]" {
                continuation.finish()
                return false
            }
            if let streamErr = tryParseStreamError(data) {
                continuation.yield(.failure(streamErr))
                continuation.finish()
                return false
            }
            do {
                let decoded = try decode(data)
                continuation.yield(.success(decoded))
            } catch is SSEDoneMarker {
                continuation.finish()
                return false
            } catch let err as SamplingError {
                if adapter.ignoresUnknownResponseEvent(error: err, data: data) {
                    continue
                }
                continuation.yield(.failure(err))
                continuation.finish()
                return false
            } catch {
                let err = SamplingError.serialization(String(describing: error))
                if adapter.ignoresUnknownResponseEvent(error: err, data: data) {
                    continue
                }
                continuation.yield(.failure(err))
                continuation.finish()
                return false
            }
        }
        return true
    }

    // MARK: - Headers / URL

    private func buildHeaders(requestHeaders: ProviderRequestHeaders?) -> [String: String] {
        var headers = defaultHeaders
        if let resolver = bearerResolver {
            for name in resolver.reservedHeaders {
                headers = headers.filter { $0.key.lowercased() != name.lowercased() }
            }
            let resolved = resolver.currentAuth()
            if resolved != nil || resolver.failClosedOnMissing {
                headers = headers.filter {
                    let k = $0.key.lowercased()
                    return k != "authorization" && k != "x-api-key"
                }
            }
            if let resolved {
                switch defaults.authScheme {
                case .xApiKey:
                    headers["x-api-key"] = resolved.bearer
                case .bearer:
                    headers["Authorization"] = "Bearer \(resolved.bearer)"
                }
                for (name, value) in resolved.extraHeaders {
                    headers[name] = value
                }
            }
        }
        if let injector = headerInjector {
            injector.inject(into: &headers)
        }
        providerAdapter.sanitizeHeaders(&headers)
        providerAdapter.applyTurnStateHeader(&headers, turnState: codexTurnState)
        if let requestHeaders {
            providerAdapter.applyRequestHeaders(&headers, request: requestHeaders)
        }
        return headers
    }

    private func makeURL(path: String) throws -> URL {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let p = path.hasPrefix("/") ? path : "/" + path
        guard let url = URL(string: base + p) else {
            throw SamplingError.invalidConfiguration("invalid base URL: \(baseURL)")
        }
        return url
    }

    private func providerRequestHeaders(from req: ConversationRequest) -> ProviderRequestHeaders? {
        providerRequestHeaders(
            convId: req.xGrokConvId,
            reqId: req.xGrokReqId,
            modelId: req.model ?? defaults.model,
            sessionId: req.xGrokSessionId,
            turnIdx: req.xGrokTurnIdx,
            agentId: req.xGrokAgentId,
            deploymentId: req.xGrokDeploymentId,
            userId: req.xGrokUserId
        )
    }

    private func providerRequestHeaders(
        convId: String?,
        reqId: String?,
        modelId: String,
        sessionId: String?,
        turnIdx: String?,
        agentId: String?,
        deploymentId: String?,
        userId: String?
    ) -> ProviderRequestHeaders? {
        guard providerAdapter.profile.requestMetadata == .xGrokHeaders else { return nil }
        return ProviderRequestHeaders(
            convId: convId ?? "",
            reqId: reqId ?? "",
            modelId: modelId,
            sessionId: sessionId ?? "",
            turnIdx: turnIdx,
            agentId: agentId ?? "",
            deploymentId: deploymentId,
            userId: userId
        )
    }

    private func applyConversationDefaults(_ request: inout ConversationRequest) {
        if request.model == nil || request.model?.isEmpty == true {
            request.model = defaults.model
        }
        if request.temperature == nil {
            request.temperature = defaults.temperature
        }
        if request.topP == nil {
            request.topP = defaults.topP
        }
        if request.maxOutputTokens == nil {
            request.maxOutputTokens = defaults.maxCompletionTokens
        }
        if request.reasoningEffort == nil {
            request.reasoningEffort = defaults.reasoningEffort
        }
    }

    private func extractModelMetadata(from headers: [String: String]) -> ResponseModelMetadata? {
        func header(_ name: String) -> String? {
            headers.first { $0.key.lowercased() == name.lowercased() }?.value
        }
        let contextWindow = header("x-grok-context-window").flatMap { UInt64($0) }
        let maxCompletion = header("x-grok-max-completion-tokens").flatMap { UInt32($0) }
        let etag = header("x-models-etag")
        if contextWindow == nil && maxCompletion == nil && etag == nil {
            return nil
        }
        return ResponseModelMetadata(
            contextWindow: contextWindow,
            maxCompletionTokens: maxCompletion,
            modelsEtag: etag
        )
    }

    private func mapHTTPError(
        status: Int,
        body: Data,
        headers: [String: String],
        consumer: SamplingConsumer
    ) -> SamplingError {
        let message = userFacingAPIMessage(status: HTTPStatus(status), bytes: body)
        let retryAfter = parseRetryAfterSecs(headers)
        let shouldRetry = parseShouldRetry(headers)
        let meta = extractModelMetadata(from: headers)

        if status == 401 {
            let prefix = currentSentBearerPrefix()
            attributionCallback?.record401(consumer: consumer, sentBearerPrefix: prefix)
            return .auth(message)
        }

        return .api(
            status: HTTPStatus(status),
            message: message,
            modelMetadata: meta,
            retryAfterSecs: retryAfter,
            shouldRetry: shouldRetry
        )
    }

    private func currentSentBearerPrefix() -> String? {
        let bearer: String?
        if let resolver = bearerResolver {
            if let live = resolver.currentBearer() {
                bearer = live
            } else if resolver.failClosedOnMissing {
                bearer = nil
            } else {
                bearer = extractStaticBearer()
            }
        } else {
            bearer = extractStaticBearer()
        }
        return bearer.map { scrubbedBearerPrefix($0) }
    }

    private func extractStaticBearer() -> String? {
        if let auth = defaultHeaders.first(where: { $0.key.lowercased() == "authorization" })?.value {
            if auth.lowercased().hasPrefix("bearer ") {
                return String(auth.dropFirst(7))
            }
            return auth
        }
        return defaultHeaders.first { $0.key.lowercased() == "x-api-key" }?.value
    }

    private func parseRetryAfterSecs(_ headers: [String: String]) -> UInt64? {
        guard let value = headers.first(where: { $0.key.lowercased() == "retry-after" })?.value
        else { return nil }
        if let secs = UInt64(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return secs
        }
        if let interval = HTTPResponseMetadata(statusCode: 429, headers: headers).retryAfter,
           interval > 0
        {
            return UInt64(interval.rounded(.up))
        }
        return nil
    }

    private func parseShouldRetry(_ headers: [String: String]) -> Bool? {
        guard let value = headers.first(where: { $0.key.lowercased() == "x-should-retry" })?.value
        else { return nil }
        switch value.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }
}

// MARK: - Reconstruct SamplingError from info (shared with request task)

func synthesizeFromInfo(_ info: SamplingErrorInfo) -> SamplingError {
    switch info.kind {
    case .idleTimeout:
        let secs = info.message
            .split(separator: " ")
            .compactMap { tok -> UInt64? in
                if tok.hasSuffix("s"), let n = UInt64(tok.dropLast()) { return n }
                return nil
            }
            .first ?? 0
        return .idleTimeout(elapsedSecs: secs)
    case .auth:
        return .auth(info.message)
    case .serialization:
        return .serializationFromRendered(info.message)
    case .http:
        return .eventStreamError(info.message)
    case .api, .rateLimited:
        let code = Int(info.statusCode ?? 500)
        return .api(
            status: HTTPStatus(code),
            message: info.message,
            modelMetadata: info.modelMetadata,
            retryAfterSecs: info.retryAfterSecs,
            shouldRetry: nil
        )
    case .emptyResponse:
        if let ctx = info.emptyResponseContext {
            return .emptyResponse(context: ctx)
        }
        return .eventStreamError(info.message)
    case .maxTokensTruncation:
        return .maxTokensTruncation
    case .doomLoopDetected:
        return .doomLoopDetected(
            triggers: info.doomLoopTriggers ?? [],
            abortedAtChunk: info.doomLoopAbortedAtChunk
        )
    }
}
