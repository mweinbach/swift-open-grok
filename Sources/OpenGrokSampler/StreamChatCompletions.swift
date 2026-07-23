// StreamChatCompletions.swift
//
// Layer-2 stream transform for the Chat Completions API.
// Mirrors Rust `stream/chat_completions.rs`.

import Foundation
import OpenGrokSamplingTypes

/// Transform a raw Chat Completions chunk stream into ``SamplingEvent``s.
///
/// Emits exactly one terminal event (Completed or Failed) per request.
public func streamChatCompletions(
    rawStream: AsyncStream<Result<ChatCompletionChunk, SamplingError>>,
    modelMetadata: ResponseModelMetadata?,
    requestId: RequestId,
    idleTimeout: MonotonicDuration
) -> AsyncStream<SamplingEvent> {
    AsyncStream { continuation in
        let task = Task {
            let streamStart = MonotonicInstant.now
            var chunkTimestamps: [MonotonicInstant] = []

            continuation.yield(.streamStarted(
                requestId: requestId,
                timestampMs: Int64(Date().timeIntervalSince1970 * 1000)
            ))

            if let metadata = modelMetadata {
                continuation.yield(.modelMetadata(requestId: requestId, metadata: metadata))
            }

            var firstChunkSeen = false
            var firstChoiceSeen = false
            var firstTokenEmitted = false
            var model = ""
            var modelFingerprint: String?
            var usage: TokenUsage?
            var costUsdTicks: Int64?
            var finishReason: StopReason?

            var contentAcc = ""
            var reasoningAcc = ""
            // index → (id, name, arguments)
            var toolCallAcc: [UInt32: (String, String, String)] = [:]

            var chunkIndex: UInt64 = 0
            var messageChunkCount: UInt64 = 0
            var lastContentChunkAt = MonotonicInstant.now

            let iterator = AsyncStreamIteratorRelay(rawStream)
            while true {
                let next = await iterator.next()

                guard let next else { break }

                let chunk: ChatCompletionChunk
                switch next {
                case .success(let c):
                    chunk = c
                case .failure(let err):
                    continuation.yield(.failed(requestId: requestId, error: SamplingErrorInfo(from: err)))
                    continuation.finish()
                    return
                }

                if !firstChunkSeen {
                    model = chunk.model
                    modelFingerprint = chunk.systemFingerprint.flatMap { $0.isEmpty ? nil : $0 }
                    firstChunkSeen = true
                }

                if let u = chunk.usage {
                    let chunkCost = reportedCostTicks(u.costInUsdTicks)
                    switch (costUsdTicks, chunkCost) {
                    case (_, .some(let n)): costUsdTicks = n
                    case (let prev, .none): costUsdTicks = prev
                    }
                    usage = TokenUsage(from: u)
                }

                var chunkHasContent = false

                for choice in chunk.choices {
                    firstChoiceSeen = true
                    if let fr = choice.finishReason {
                        finishReason = StopReason(from: fr)
                        chunkHasContent = true
                    }

                    let delta = choice.delta

                    if let text = delta.content, !text.isEmpty {
                        if !firstTokenEmitted {
                            firstTokenEmitted = true
                            continuation.yield(.firstToken(requestId: requestId))
                        }
                        chunkHasContent = true
                        chunkTimestamps.append(.now)
                        chunkIndex += 1
                        messageChunkCount += 1
                        contentAcc += text
                        continuation.yield(.channelToken(
                            requestId: requestId,
                            channel: .text,
                            text: text,
                            chunkIndex: chunkIndex
                        ))
                    }

                    if let thought = delta.reasoningContent, !thought.isEmpty {
                        if !firstTokenEmitted {
                            firstTokenEmitted = true
                            continuation.yield(.firstToken(requestId: requestId))
                        }
                        chunkHasContent = true
                        chunkIndex += 1
                        reasoningAcc += thought
                        continuation.yield(.channelToken(
                            requestId: requestId,
                            channel: .reasoning,
                            text: thought,
                            chunkIndex: chunkIndex
                        ))
                    }

                    for tcDelta in delta.toolCalls {
                        chunkHasContent = true
                        var entry = toolCallAcc[tcDelta.index] ?? ("", "", "")
                        var idForEvent: String?
                        var nameForEvent: String?
                        var argsForEvent: String?

                        if let id = tcDelta.id {
                            entry.0 = id
                            idForEvent = id
                        }
                        if let funcDelta = tcDelta.function {
                            if let name = funcDelta.name {
                                entry.1 = name
                                nameForEvent = name
                            }
                            if let args = funcDelta.arguments {
                                entry.2 += args
                                argsForEvent = args
                            }
                        }
                        toolCallAcc[tcDelta.index] = entry
                        continuation.yield(.toolCallDelta(
                            requestId: requestId,
                            toolIndex: tcDelta.index,
                            id: idForEvent,
                            name: nameForEvent,
                            argumentsDelta: argsForEvent
                        ))
                    }
                }

                if chunkHasContent {
                    lastContentChunkAt = .now
                } else if MonotonicInstant.now - lastContentChunkAt > idleTimeout {
                    let err = SamplingError.idleTimeout(elapsedSecs: idleTimeout.wholeSeconds)
                    continuation.yield(.failed(requestId: requestId, error: SamplingErrorInfo(from: err)))
                    continuation.finish()
                    return
                }
            }

            let toolCalls: [ToolCall] = toolCallAcc.keys.sorted().compactMap { idx in
                guard let (id, name, arguments) = toolCallAcc[idx] else { return nil }
                return ToolCall(id: id, name: name, arguments: arguments)
            }

            if !toolCalls.isEmpty {
                finishReason = .toolCalls
            }

            var items: [ConversationItem] = []
            if firstChoiceSeen {
                if !reasoningAcc.isEmpty {
                    items.append(.reasoning(synthesizedReasoningItem(reasoningAcc)))
                }
                items.append(.assistant(AssistantItem(
                    content: contentAcc,
                    toolCalls: toolCalls,
                    modelId: model.isEmpty ? nil : model,
                    modelFingerprint: modelFingerprint,
                    reasoningEffort: nil
                )))
            } else {
                items.append(.assistant(""))
            }

            let metrics = InferenceLatencyStats.fromTimestamps(
                streamStart: streamStart,
                chunkTimestamps: chunkTimestamps,
                streamEnd: .now
            )

            let response = ConversationResponse(
                items: items,
                stopReason: finishReason,
                usage: usage,
                costUsdTicks: costUsdTicks,
                messageChunksEmitted: messageChunkCount
            )
            continuation.yield(.completed(
                requestId: requestId,
                response: response,
                metrics: metrics
            ))
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

// MARK: - Timeout helper

struct TimeoutError: Error {}

private actor StreamMailbox<Element: Sendable> {
    private var values: [Element] = []
    private var waiter: CheckedContinuation<Element?, Never>?
    private var finished = false

    func offer(_ value: Element) {
        guard !finished else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: value)
        } else {
            values.append(value)
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func next() async -> Element? {
        if !values.isEmpty { return values.removeFirst() }
        if finished { return nil }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }
}

private struct StreamRelayFailure: Error, Sendable {
    let message: String
}

/// A producer task exclusively owns the source iterator; consumers receive
/// through a bounded mailbox and may race mailbox delivery against timeout.
final actor AsyncStreamIteratorRelay<Element: Sendable> {
    private let mailbox = StreamMailbox<Element>()
    private let producer: Task<Void, Never>

    init(_ stream: AsyncStream<Element>) {
        let mailbox = self.mailbox
        self.producer = Task {
            var iterator = stream.makeAsyncIterator()
            while let value = await iterator.next() { await mailbox.offer(value) }
            await mailbox.finish()
        }
    }

    func next() async -> Element? { await mailbox.next() }
}

final actor AsyncThrowingStreamIteratorRelay<Element: Sendable> {
    private let mailbox = StreamMailbox<Result<Element, StreamRelayFailure>>()
    private let producer: Task<Void, Never>

    init(_ stream: AsyncThrowingStream<Element, Error>) {
        let mailbox = self.mailbox
        self.producer = Task {
            do {
                var iterator = stream.makeAsyncIterator()
                while let value = try await iterator.next() { await mailbox.offer(.success(value)) }
            } catch {
                await mailbox.offer(.failure(StreamRelayFailure(message: String(describing: error))))
            }
            await mailbox.finish()
        }
    }

    func next() async throws -> Element? {
        guard let result = await mailbox.next() else { return nil }
        switch result {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}

func withTimeout<T: Sendable>(
    _ timeout: MonotonicDuration,
    operation: @escaping @Sendable () async -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            await operation()
        }
        group.addTask {
            try await timeout.sleep()
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

/// Convert a sequence of results into an AsyncStream for L2 transforms.
public func makeResultStream<T: Sendable>(
    _ items: [Result<T, SamplingError>]
) -> AsyncStream<Result<T, SamplingError>> {
    AsyncStream { continuation in
        for item in items {
            continuation.yield(item)
        }
        continuation.finish()
    }
}
