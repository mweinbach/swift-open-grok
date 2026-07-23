// StreamMessages.swift
//
// Layer-2 stream transform for the Anthropic Messages API.
// Mirrors Rust `stream/messages.rs`.

import Foundation
import OpenGrokSamplingTypes

/// Whether a Messages API event reflects real model progress (not a ping).
public func messagesEventHasMeaningfulContent(_ event: MessageStreamEvent) -> Bool {
    switch event {
    case .ping: return false
    default: return true
    }
}

private struct MessagesBlockState {
    enum Kind { case text, toolUse, thinking }
    var kind: Kind
    var textAcc: String = ""
    var toolName: String = ""
    var toolId: String = ""
    var argsAcc: String = ""
    var thinkingAcc: String = ""
    var signature: String = ""
}

/// Transform a raw Anthropic Messages stream into ``SamplingEvent``s.
public func streamMessages(
    rawStream: AsyncStream<Result<MessageStreamEvent, SamplingError>>,
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

            var blocks: [UInt32: MessagesBlockState] = [:]
            var finalModel: String?
            var finalInputTokens: UInt32 = 0
            var finalCacheRead: UInt32 = 0
            var finalCacheCreation: UInt32 = 0
            var finalOutputTokens: UInt32 = 0
            var finalStopReason: StopReason?
            var finalStopMessage: String?

            var assistantText = ""
            var assistantToolCalls: [ToolCall] = []
            var assistantReasoning: ReasoningItem?

            var chunkIndex: UInt64 = 0
            var messageChunkCount: UInt64 = 0
            var firstTokenEmitted = false
            var lastContentChunkAt = MonotonicInstant.now
            var nextToolIndex: UInt32 = 0
            var blockToToolIndex: [UInt32: UInt32] = [:]

            var iterator = rawStream.makeAsyncIterator()
            while true {
                let next = await iterator.next()
                guard let next else { break }

                let event: MessageStreamEvent
                switch next {
                case .success(let e): event = e
                case .failure(let err):
                    continuation.yield(.failed(requestId: requestId, error: SamplingErrorInfo(from: err)))
                    continuation.finish()
                    return
                }

                let hasContent = messagesEventHasMeaningfulContent(event)

                switch event {
                case .messageStart(let message):
                    finalModel = message.model
                    finalInputTokens = message.usage.inputTokens
                    finalCacheRead = message.usage.cacheReadInputTokens
                    finalCacheCreation = message.usage.cacheCreationInputTokens

                case .contentBlockStart(let index, let contentBlock):
                    switch contentBlock {
                    case .thinking(let thinking, let signature):
                        blocks[index] = MessagesBlockState(
                            kind: .thinking,
                            thinkingAcc: thinking,
                            signature: signature
                        )
                        if !firstTokenEmitted {
                            firstTokenEmitted = true
                            continuation.yield(.firstToken(requestId: requestId))
                        }
                    case .text(let text, _):
                        blocks[index] = MessagesBlockState(kind: .text, textAcc: text)
                        if !text.isEmpty && !firstTokenEmitted {
                            firstTokenEmitted = true
                            continuation.yield(.firstToken(requestId: requestId))
                        }
                    case .toolUse(let id, let name, _):
                        let toolIndex = nextToolIndex
                        nextToolIndex += 1
                        blockToToolIndex[index] = toolIndex
                        blocks[index] = MessagesBlockState(
                            kind: .toolUse,
                            toolName: name,
                            toolId: id,
                            argsAcc: ""
                        )
                        continuation.yield(.toolCallDelta(
                            requestId: requestId,
                            toolIndex: toolIndex,
                            id: id,
                            name: name,
                            argumentsDelta: nil
                        ))
                    case .image, .toolResult:
                        break
                    }

                case .contentBlockDelta(let index, let delta):
                    guard var state = blocks[index] else { break }
                    switch delta {
                    case .textDelta(let text):
                        if !text.isEmpty {
                            if !firstTokenEmitted {
                                firstTokenEmitted = true
                                continuation.yield(.firstToken(requestId: requestId))
                            }
                            chunkTimestamps.append(.now)
                            chunkIndex += 1
                            messageChunkCount += 1
                            state.textAcc += text
                            continuation.yield(.channelToken(
                                requestId: requestId,
                                channel: .text,
                                text: text,
                                chunkIndex: chunkIndex
                            ))
                        }
                    case .thinkingDelta(let thinking):
                        if !thinking.isEmpty {
                            if !firstTokenEmitted {
                                firstTokenEmitted = true
                                continuation.yield(.firstToken(requestId: requestId))
                            }
                            chunkIndex += 1
                            state.thinkingAcc += thinking
                            continuation.yield(.channelToken(
                                requestId: requestId,
                                channel: .reasoning,
                                text: thinking,
                                chunkIndex: chunkIndex
                            ))
                        }
                    case .inputJsonDelta(let partial):
                        state.argsAcc += partial
                        if let toolIndex = blockToToolIndex[index] {
                            continuation.yield(.toolCallDelta(
                                requestId: requestId,
                                toolIndex: toolIndex,
                                id: nil,
                                name: nil,
                                argumentsDelta: partial
                            ))
                        }
                    case .signatureDelta(let signature):
                        state.signature += signature
                    }
                    blocks[index] = state

                case .contentBlockStop(let index):
                    guard let state = blocks.removeValue(forKey: index) else { break }
                    switch state.kind {
                    case .text:
                        if !state.textAcc.isEmpty {
                            if !assistantText.isEmpty {
                                assistantText += "\n"
                            }
                            assistantText += state.textAcc
                        }
                    case .thinking:
                        if !state.thinkingAcc.isEmpty || !state.signature.isEmpty {
                            let summary: [SummaryPart] = state.thinkingAcc.isEmpty
                                ? []
                                : [.summaryText(text: state.thinkingAcc)]
                            let encryptedContent: String? = state.signature.isEmpty
                                ? nil
                                : state.signature
                            assistantReasoning = ReasoningItem(
                                id: "",
                                summary: summary,
                                content: nil,
                                encryptedContent: encryptedContent,
                                status: nil
                            )
                        }
                    case .toolUse:
                        assistantToolCalls.append(ToolCall(
                            id: state.toolId,
                            name: state.toolName,
                            arguments: state.argsAcc
                        ))
                    }

                case .messageDelta(let delta, let usage):
                    finalOutputTokens = usage.outputTokens
                    if let input = usage.inputTokens { finalInputTokens = input }
                    if let cacheRead = usage.cacheReadInputTokens { finalCacheRead = cacheRead }
                    if let cacheCreate = usage.cacheCreationInputTokens { finalCacheCreation = cacheCreate }

                    if let stop = delta.stopReason {
                        switch stop {
                        case .endTurn, .stopSequence, .pauseTurn, .unknown:
                            finalStopReason = .stop
                        case .maxTokens:
                            finalStopReason = .length
                        case .toolUse:
                            finalStopReason = .toolCalls
                        case .refusal:
                            finalStopReason = .contentFilter
                            finalStopMessage = delta.stopDetails?.explanation
                        case .modelContextWindowExceeded:
                            continuation.yield(.failed(
                                requestId: requestId,
                                error: SamplingErrorInfo(from: .maxTokensTruncation)
                            ))
                            continuation.finish()
                            return
                        }
                    }

                case .messageStop:
                    break

                case .ping:
                    break

                case .error(let streamError):
                    let err = SamplingError.api(
                        status: HTTPStatus(500),
                        message: streamError.message,
                        modelMetadata: nil,
                        retryAfterSecs: nil,
                        shouldRetry: nil
                    )
                    continuation.yield(.failed(requestId: requestId, error: SamplingErrorInfo(from: err)))
                    continuation.finish()
                    return
                }

                if hasContent {
                    lastContentChunkAt = .now
                } else if MonotonicInstant.now - lastContentChunkAt > idleTimeout {
                    let err = SamplingError.idleTimeout(elapsedSecs: idleTimeout.wholeSeconds)
                    continuation.yield(.failed(requestId: requestId, error: SamplingErrorInfo(from: err)))
                    continuation.finish()
                    return
                }
            }

            if finalStopReason == .length {
                continuation.yield(.failed(
                    requestId: requestId,
                    error: SamplingErrorInfo(from: .maxTokensTruncation)
                ))
                continuation.finish()
                return
            }

            if !assistantToolCalls.isEmpty {
                finalStopReason = .toolCalls
            }

            var items: [ConversationItem] = []
            if let reasoning = assistantReasoning {
                items.append(.reasoning(reasoning))
            }
            items.append(.assistant(AssistantItem(
                content: assistantText,
                toolCalls: assistantToolCalls,
                modelId: finalModel
            )))

            let promptTokens = finalInputTokens &+ finalCacheRead &+ finalCacheCreation
            let usage = TokenUsage(
                promptTokens: promptTokens,
                completionTokens: finalOutputTokens,
                totalTokens: promptTokens &+ finalOutputTokens,
                reasoningTokens: 0,
                cachedPromptTokens: finalCacheRead
            )

            let metrics = InferenceLatencyStats.fromTimestamps(
                streamStart: streamStart,
                chunkTimestamps: chunkTimestamps,
                streamEnd: .now
            )

            let response = ConversationResponse(
                items: items,
                stopReason: finalStopReason ?? .stop,
                usage: usage,
                messageChunksEmitted: messageChunkCount,
                stopMessage: finalStopMessage
            )
            continuation.yield(.completed(requestId: requestId, response: response, metrics: metrics))
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
