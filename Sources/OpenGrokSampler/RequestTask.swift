// RequestTask.swift
//
// Per-request streaming task with retry loop and cancellation.
// Mirrors Rust `actor/request_task.rs`.

import Foundation
import OpenGrokHTTP
import OpenGrokSamplingTypes

/// Default per-chunk idle timeout (5 minutes).
let DEFAULT_IDLE_TIMEOUT_SECS: UInt64 = 300

private enum AttemptOutcome: Sendable {
    case completed(response: ConversationResponse, metrics: InferenceLatencyStats)
    case empty(context: EmptyResponseContext)
    case failed(error: SamplingError)
    case cancelled
    case initFailed(error: SamplingError)
}

func runRequestTask(
    requestId: RequestId,
    request: ConversationRequest,
    config: SamplerConfig,
    retryPolicy: RetryPolicy,
    transport: any HTTPTransport,
    eventContinuation: AsyncStream<SamplingEvent>.Continuation,
    cancelToken: CancellationToken,
    completion: CompletionBox?,
    codexTurnState: CodexTurnStateCell
) async {
    let idleTimeout = MonotonicDuration.seconds(
        Int64(config.idleTimeoutSecs ?? DEFAULT_IDLE_TIMEOUT_SECS)
    )
    let maxRetries = resolveMaxRetries(
        modelMaxRetries: config.maxRetries ?? retryPolicy.maxRetries
    )

    var client: SamplingClient
    do {
        client = try SamplingClient(
            config: config,
            transport: transport,
            codexTurnState: codexTurnState
        )
    } catch let err as SamplingError {
        emitFailed(eventContinuation, requestId: requestId, error: err)
        sendCompletion(completion, .failure(err))
        return
    } catch {
        let err = SamplingError.invalidConfiguration(String(describing: error))
        emitFailed(eventContinuation, requestId: requestId, error: err)
        sendCompletion(completion, .failure(err))
        return
    }

    var request = request
    var retryCount: UInt32 = 0
    let doomPolicy = config.doomLoopRecovery
    let doomMaxRetries = doomPolicy?.maxRetries ?? 0
    var doomRetryCount: UInt32 = 0

    while true {
        if cancelToken.isCancelled || Task.isCancelled {
            handleCancellation(eventContinuation, requestId: requestId, completion: completion)
            return
        }

        let doomCheck: DoomLoopRecoveryPolicy? =
            (doomRetryCount < doomMaxRetries) ? doomPolicy : nil

        let outcome = await runOneAttempt(
            client: client,
            request: request,
            requestId: requestId,
            idleTimeout: idleTimeout,
            eventContinuation: eventContinuation,
            cancelToken: cancelToken,
            doomCheck: doomCheck
        )

        switch outcome {
        case .completed(let response, var metrics):
            metrics.attempts = retryCount + doomRetryCount + 1
            eventContinuation.yield(.completed(
                requestId: requestId,
                response: response,
                metrics: metrics
            ))
            sendCompletion(completion, .success((response, metrics)))
            return

        case .empty(let context):
            let err = SamplingError.emptyResponse(context: context)
            if !(await applyRetryDecision(
                err,
                retryCount: &retryCount,
                maxRetries: maxRetries,
                retryPolicy: retryPolicy,
                eventContinuation: eventContinuation,
                requestId: requestId,
                request: &request,
                client: &client,
                config: config,
                codexTurnState: codexTurnState,
                transport: transport,
                completion: completion
            )) {
                return
            }

        case .failed(let error):
            if case .doomLoopDetected = error {
                let backoff = doomLoopBackoff(retryCount: doomRetryCount + 1)
                doomRetryCount += 1
                emitRetrying(
                    eventContinuation,
                    requestId: requestId,
                    attempt: doomRetryCount,
                    maxRetries: doomMaxRetries,
                    error: error
                )
                try? await backoff.sleep()
                continue
            }
            if !(await applyRetryDecision(
                error,
                retryCount: &retryCount,
                maxRetries: maxRetries,
                retryPolicy: retryPolicy,
                eventContinuation: eventContinuation,
                requestId: requestId,
                request: &request,
                client: &client,
                config: config,
                codexTurnState: codexTurnState,
                transport: transport,
                completion: completion
            )) {
                return
            }

        case .cancelled:
            handleCancellation(eventContinuation, requestId: requestId, completion: completion)
            return

        case .initFailed(let error):
            if !(await applyRetryDecision(
                error,
                retryCount: &retryCount,
                maxRetries: maxRetries,
                retryPolicy: retryPolicy,
                eventContinuation: eventContinuation,
                requestId: requestId,
                request: &request,
                client: &client,
                config: config,
                codexTurnState: codexTurnState,
                transport: transport,
                completion: completion
            )) {
                return
            }
        }
    }
}

private func applyRetryDecision(
    _ err: SamplingError,
    retryCount: inout UInt32,
    maxRetries: UInt32,
    retryPolicy: RetryPolicy,
    eventContinuation: AsyncStream<SamplingEvent>.Continuation,
    requestId: RequestId,
    request: inout ConversationRequest,
    client: inout SamplingClient,
    config: SamplerConfig,
    codexTurnState: CodexTurnStateCell,
    transport: any HTTPTransport,
    completion: CompletionBox?
) async -> Bool {
    let rateLimitThreshold = retryPolicy.rateLimitRetryThreshold == 0
        ? RATE_LIMIT_RETRY_THRESHOLD
        : retryPolicy.rateLimitRetryThreshold
    let decision = classifyError(
        err,
        retryCount: retryCount,
        maxRetries: maxRetries,
        rateLimitThreshold: rateLimitThreshold
    )

    if err.isLikelyBodyRejected {
        _ = request.stripImages()
    }

    switch decision {
    case .retry(let backoff):
        retryCount += 1
        emitRetrying(eventContinuation, requestId: requestId, attempt: retryCount, maxRetries: maxRetries, error: err)
        try? await backoff.sleep()
        return true

    case .retryWithBackoff(let backoff, _):
        retryCount += 1
        emitRetrying(eventContinuation, requestId: requestId, attempt: retryCount, maxRetries: maxRetries, error: err)
        try? await backoff.sleep()
        return true

    case .retryWithImageStrip:
        let stripped = request.stripImages()
        if stripped == 0 {
            emitFailed(eventContinuation, requestId: requestId, error: err)
            sendCompletion(completion, .failure(err))
            return false
        }
        retryCount += 1
        emitRetrying(eventContinuation, requestId: requestId, attempt: retryCount, maxRetries: maxRetries, error: err)
        return true

    case .retryWithClientRebuild(let backoff):
        retryCount += 1
        emitRetrying(eventContinuation, requestId: requestId, attempt: retryCount, maxRetries: maxRetries, error: err)
        try? await backoff.sleep()
        var http1Config = config
        http1Config.forceHTTP1 = true
        if let fresh = try? SamplingClient(
            config: http1Config,
            transport: transport,
            codexTurnState: codexTurnState
        ) {
            client = fresh
        }
        return true

    case .emitToSession(let emitted):
        emitFailed(eventContinuation, requestId: requestId, error: emitted)
        sendCompletion(completion, .failure(emitted))
        return false

    case .fatal(let fatalErr):
        emitFailed(eventContinuation, requestId: requestId, error: fatalErr)
        sendCompletion(completion, .failure(fatalErr))
        return false
    }
}

private func runOneAttempt(
    client: SamplingClient,
    request: ConversationRequest,
    requestId: RequestId,
    idleTimeout: MonotonicDuration,
    eventContinuation: AsyncStream<SamplingEvent>.Continuation,
    cancelToken: CancellationToken,
    doomCheck: DoomLoopRecoveryPolicy?
) async -> AttemptOutcome {
    switch client.apiBackend {
    case .chatCompletions:
        let pair: (AsyncStream<Result<ChatCompletionChunk, SamplingError>>, ResponseModelMetadata?)
        do {
            pair = try await client.conversationStream(request)
        } catch let err as SamplingError {
            return .initFailed(error: err)
        } catch {
            return .initFailed(error: .http(String(describing: error)))
        }
        let (teed, captured) = teeErrors(pair.0)
        let l2 = streamChatCompletions(
            rawStream: teed,
            modelMetadata: pair.1,
            requestId: requestId,
            idleTimeout: idleTimeout
        )
        return await driveL2(
            l2,
            requestId: requestId,
            eventContinuation: eventContinuation,
            cancelToken: cancelToken,
            captured: captured,
            doomCheck: nil
        )

    case .responses:
        let parts: (
            AsyncStream<Result<ResponsesStreamEvent, SamplingError>>,
            ResponseModelMetadata?,
            DoomLoopSignalCollector?,
            [String]
        )
        do {
            parts = try await client.conversationStreamResponses(request)
        } catch let err as SamplingError {
            return .initFailed(error: err)
        } catch {
            return .initFailed(error: .http(String(describing: error)))
        }
        if doomCheck == nil {
            parts.2?.disarmAbort()
        }
        let (teed, captured) = teeErrors(parts.0)
        let l2 = streamResponsesWithClientCustomTools(
            rawStream: teed,
            modelMetadata: parts.1,
            requestId: requestId,
            idleTimeout: idleTimeout,
            doomLoop: parts.2,
            clientCustomToolNames: parts.3
        )
        return await driveL2(
            l2,
            requestId: requestId,
            eventContinuation: eventContinuation,
            cancelToken: cancelToken,
            captured: captured,
            doomCheck: doomCheck
        )

    case .messages:
        let pair: (AsyncStream<Result<MessageStreamEvent, SamplingError>>, ResponseModelMetadata?)
        do {
            pair = try await client.conversationStreamMessages(request)
        } catch let err as SamplingError {
            return .initFailed(error: err)
        } catch {
            return .initFailed(error: .http(String(describing: error)))
        }
        let (teed, captured) = teeErrors(pair.0)
        let l2 = streamMessages(
            rawStream: teed,
            modelMetadata: pair.1,
            requestId: requestId,
            idleTimeout: idleTimeout
        )
        return await driveL2(
            l2,
            requestId: requestId,
            eventContinuation: eventContinuation,
            cancelToken: cancelToken,
            captured: captured,
            doomCheck: nil
        )
    }
}

// MARK: - Error tee

private final class ErrorCell: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SamplingError?

    func storeIfEmpty(_ error: SamplingError) {
        lock.lock()
        defer { lock.unlock() }
        if value == nil { value = error }
    }

    func take() -> SamplingError? {
        lock.lock()
        defer { lock.unlock() }
        let v = value
        value = nil
        return v
    }
}

private func teeErrors<T: Sendable>(
    _ raw: AsyncStream<Result<T, SamplingError>>
) -> (AsyncStream<Result<T, SamplingError>>, ErrorCell) {
    let cell = ErrorCell()
    let teed = AsyncStream<Result<T, SamplingError>> { continuation in
        let task = Task {
            for await item in raw {
                if case .failure(let e) = item {
                    cell.storeIfEmpty(e)
                }
                continuation.yield(item)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
    return (teed, cell)
}

private func driveL2(
    _ l2: AsyncStream<SamplingEvent>,
    requestId: RequestId,
    eventContinuation: AsyncStream<SamplingEvent>.Continuation,
    cancelToken: CancellationToken,
    captured: ErrorCell,
    doomCheck: DoomLoopRecoveryPolicy?
) async -> AttemptOutcome {
    var iterator = l2.makeAsyncIterator()
    while true {
        if cancelToken.isCancelled || Task.isCancelled {
            return .cancelled
        }

        let next: SamplingEvent? = await withTaskGroup(of: SamplingEvent?.self) { group in
            group.addTask { await iterator.next() }
            group.addTask {
                await cancelToken.cancelled()
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }

        // Distinguish cancel vs stream end: if cancel token fired, prefer cancelled.
        if cancelToken.isCancelled || Task.isCancelled {
            return .cancelled
        }

        guard let event = next else {
            return .failed(error: .eventStreamError("stream dropped without terminal event"))
        }

        switch event {
        case .completed(_, let response, let metrics):
            if let policy = doomCheck {
                let triggers = policy.confidentTriggers(response.doomLoopSignals)
                if !triggers.isEmpty {
                    return .failed(error: .doomLoopDetected(triggers: triggers, abortedAtChunk: nil))
                }
            }
            if response.stopReason == .length {
                return .failed(error: .maxTokensTruncation)
            }
            let contentFiltered = response.stopReason == .contentFilter
            if !contentFiltered, let reason = response.emptyReason() {
                return .empty(context: buildEmptyContext(reason: reason, response: response))
            }
            return .completed(response: response, metrics: metrics)

        case .failed(_, let info):
            let raw = captured.take()
            let error = raw ?? synthesizeFromInfo(info)
            return .failed(error: error)

        default:
            eventContinuation.yield(event)
        }
    }
}

private func buildEmptyContext(
    reason: EmptyReason,
    response: ConversationResponse
) -> EmptyResponseContext {
    let hadReasoning = response.reasoningItems().contains { r in
        !r.summary.isEmpty || r.content != nil || r.encryptedContent != nil
    }
    let contentLen: Int
    let toolCallCount: Int
    let model: String
    let firstChoiceSeen: Bool
    if let a = response.assistant() {
        contentLen = a.content.count
        toolCallCount = a.toolCalls.count
        model = a.modelId ?? ""
        firstChoiceSeen = a.modelId != nil
    } else {
        contentLen = 0
        toolCallCount = 0
        model = ""
        firstChoiceSeen = false
    }
    return EmptyResponseContext(
        reason: reason,
        hadReasoning: hadReasoning,
        contentLen: contentLen,
        toolCallCount: toolCallCount,
        finishReason: response.stopReason?.asString,
        completionTokens: response.usage?.completionTokens,
        reasoningTokens: response.usage?.reasoningTokens,
        promptTokens: response.usage?.promptTokens,
        model: model,
        firstChoiceSeen: firstChoiceSeen
    )
}

// MARK: - Emit helpers

private func emitFailed(
    _ cont: AsyncStream<SamplingEvent>.Continuation,
    requestId: RequestId,
    error: SamplingError
) {
    cont.yield(.failed(requestId: requestId, error: SamplingErrorInfo(from: error)))
}

private func emitRetrying(
    _ cont: AsyncStream<SamplingEvent>.Continuation,
    requestId: RequestId,
    attempt: UInt32,
    maxRetries: UInt32,
    error: SamplingError
) {
    let info = SamplingErrorInfo(from: error)
    cont.yield(.retrying(
        requestId: requestId,
        attempt: attempt,
        maxRetries: maxRetries,
        kind: info.kind,
        reason: formatSamplingError(error, retryCount: nil),
        doomLoopTriggers: info.doomLoopTriggers,
        doomLoopAbortedAtChunk: info.doomLoopAbortedAtChunk
    ))
}

private func handleCancellation(
    _ cont: AsyncStream<SamplingEvent>.Continuation,
    requestId: RequestId,
    completion: CompletionBox?
) {
    // Cancellation is silent on the event channel (session owns cancel UX).
    // Completions get an auth-style "dropped" error matching Rust submit_and_collect.
    sendCompletion(completion, .failure(.auth("sampler request cancelled")))
    _ = cont
    _ = requestId
}

private func sendCompletion(
    _ completion: CompletionBox?,
    _ result: Result<(ConversationResponse, InferenceLatencyStats), SamplingError>
) {
    completion?.complete(result)
}