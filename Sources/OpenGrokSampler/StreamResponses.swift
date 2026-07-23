// StreamResponses.swift
//
// Layer-2 stream transform for the Responses API.
// Mirrors the event-ordering and terminal-completion semantics of
// Rust `stream/responses.rs`, using tolerant JSON-typed wire events
// (async-openai is not available in Swift).

import Foundation
import OpenGrokSamplingTypes
import OpenGrokShared

// MARK: - Responses stream event (tolerant)

/// A Responses API streaming event, decoded from SSE `data:` JSON by `type`.
public enum ResponsesStreamEvent: Sendable, Equatable {
    case outputTextDelta(delta: String, itemId: String, outputIndex: UInt32)
    case outputTextDone(text: String, itemId: String, outputIndex: UInt32)
    case reasoningSummaryDelta(delta: String, itemId: String, outputIndex: UInt32, summaryIndex: UInt32)
    case reasoningSummaryDone(text: String, itemId: String, outputIndex: UInt32, summaryIndex: UInt32)
    case reasoningTextDelta(delta: String, itemId: String, outputIndex: UInt32)
    case functionCallArgumentsDelta(delta: String, itemId: String, outputIndex: UInt32)
    case functionCallArgumentsDone(arguments: String, itemId: String, outputIndex: UInt32)
    case customToolCallInputDelta(delta: String, itemId: String, outputIndex: UInt32)
    case customToolCallInputDone(input: String, itemId: String, outputIndex: UInt32)
    case outputItemAdded(outputIndex: UInt32, item: JSONValue)
    case outputItemDone(outputIndex: UInt32, item: JSONValue)
    case completed(response: JSONValue)
    case failed(response: JSONValue)
    case incomplete(response: JSONValue)
    case error(message: String, code: String?)
    case other(type: String, raw: JSONValue)

    /// Decode a single SSE data payload into a Responses stream event.
    public static func decode(data: String) throws -> ResponsesStreamEvent {
        guard let raw = try? JSONDecoder().decode(JSONValue.self, from: Data(data.utf8)) else {
            throw SamplingError.serialization("invalid responses event JSON")
        }
        let type = raw["type"]?.stringValue ?? ""
        switch type {
        case "response.output_text.delta":
            return .outputTextDelta(
                delta: raw["delta"]?.stringValue ?? "",
                itemId: raw["item_id"]?.stringValue ?? "",
                outputIndex: UInt32(raw["output_index"]?.intValue ?? 0)
            )
        case "response.output_text.done":
            return .outputTextDone(
                text: raw["text"]?.stringValue ?? "",
                itemId: raw["item_id"]?.stringValue ?? "",
                outputIndex: UInt32(raw["output_index"]?.intValue ?? 0)
            )
        case "response.reasoning_summary_text.delta":
            return .reasoningSummaryDelta(
                delta: raw["delta"]?.stringValue ?? "",
                itemId: raw["item_id"]?.stringValue ?? "",
                outputIndex: UInt32(raw["output_index"]?.intValue ?? 0),
                summaryIndex: UInt32(raw["summary_index"]?.intValue ?? 0)
            )
        case "response.reasoning_summary_text.done":
            return .reasoningSummaryDone(
                text: raw["text"]?.stringValue ?? "",
                itemId: raw["item_id"]?.stringValue ?? "",
                outputIndex: UInt32(raw["output_index"]?.intValue ?? 0),
                summaryIndex: UInt32(raw["summary_index"]?.intValue ?? 0)
            )
        case "response.reasoning_text.delta":
            return .reasoningTextDelta(
                delta: raw["delta"]?.stringValue ?? "",
                itemId: raw["item_id"]?.stringValue ?? "",
                outputIndex: UInt32(raw["output_index"]?.intValue ?? 0)
            )
        case "response.function_call_arguments.delta":
            return .functionCallArgumentsDelta(
                delta: raw["delta"]?.stringValue ?? "",
                itemId: raw["item_id"]?.stringValue ?? "",
                outputIndex: UInt32(raw["output_index"]?.intValue ?? 0)
            )
        case "response.function_call_arguments.done":
            return .functionCallArgumentsDone(
                arguments: raw["arguments"]?.stringValue ?? "",
                itemId: raw["item_id"]?.stringValue ?? "",
                outputIndex: UInt32(raw["output_index"]?.intValue ?? 0)
            )
        case "response.custom_tool_call_input.delta":
            return .customToolCallInputDelta(
                delta: raw["delta"]?.stringValue ?? "",
                itemId: raw["item_id"]?.stringValue ?? raw["call_id"]?.stringValue ?? "",
                outputIndex: UInt32(raw["output_index"]?.intValue ?? 0)
            )
        case "response.custom_tool_call_input.done":
            return .customToolCallInputDone(
                input: raw["input"]?.stringValue ?? raw["text"]?.stringValue ?? "",
                itemId: raw["item_id"]?.stringValue ?? raw["call_id"]?.stringValue ?? "",
                outputIndex: UInt32(raw["output_index"]?.intValue ?? 0)
            )
        case "response.output_item.added":
            return .outputItemAdded(
                outputIndex: UInt32(raw["output_index"]?.intValue ?? 0),
                item: raw["item"] ?? .null
            )
        case "response.output_item.done":
            return .outputItemDone(
                outputIndex: UInt32(raw["output_index"]?.intValue ?? 0),
                item: raw["item"] ?? .null
            )
        case "response.completed", "response.done":
            let resp = (raw["response"] != nil && raw["response"] != .null) ? raw["response"]! : raw
            return .completed(response: resp)
        case "response.failed":
            let resp = (raw["response"] != nil && raw["response"] != .null) ? raw["response"]! : raw
            return .failed(response: resp)
        case "response.incomplete":
            let resp = (raw["response"] != nil && raw["response"] != .null) ? raw["response"]! : raw
            return .incomplete(response: resp)
        case "error", "response.error":
            let message = raw["message"]?.stringValue
                ?? raw["error"]?["message"]?.stringValue
                ?? "unknown error"
            let code = raw["code"]?.stringValue ?? raw["error"]?["code"]?.stringValue
            return .error(message: message, code: code)
        default:
            return .other(type: type, raw: raw)
        }
    }
}

extension JSONValue {
    var intValue: Int? {
        switch self {
        case .number(let n):
            switch n {
            case .int64(let i): return Int(i)
            case .uint64(let u): return Int(exactly: u)
            case .double(let d): return Int(d)
            }
        case .string(let s): return Int(s)
        default: return nil
        }
    }
}

public func responsesEventHasMeaningfulContent(_ event: ResponsesStreamEvent) -> Bool {
    switch event {
    case .outputTextDelta(let d, _, _): return !d.isEmpty
    case .outputTextDone(let t, _, _): return !t.isEmpty
    case .reasoningSummaryDelta(let d, _, _, _): return !d.isEmpty
    case .reasoningSummaryDone(let t, _, _, _): return !t.isEmpty
    case .reasoningTextDelta(let d, _, _): return !d.isEmpty
    case .functionCallArgumentsDelta(let d, _, _): return !d.isEmpty
    case .functionCallArgumentsDone(let a, _, _): return !a.isEmpty
    case .customToolCallInputDelta(let d, _, _): return !d.isEmpty
    case .customToolCallInputDone(let input, _, _): return !input.isEmpty
    case .outputItemAdded, .outputItemDone, .completed, .failed, .incomplete, .error:
        return true
    case .other:
        return false
    }
}

private enum ReasoningUnitKey: Hashable {
    case summary(UInt32, String, UInt32)
    case text(UInt32, String)
}

/// Transform a raw Responses event stream into ``SamplingEvent``s.
public func streamResponses(
    rawStream: AsyncStream<Result<ResponsesStreamEvent, SamplingError>>,
    modelMetadata: ResponseModelMetadata?,
    requestId: RequestId,
    idleTimeout: MonotonicDuration,
    doomLoop: DoomLoopSignalCollector? = nil,
    clientCustomToolNames: [String] = []
) -> AsyncStream<SamplingEvent> {
    streamResponsesWithClientCustomTools(
        rawStream: rawStream,
        modelMetadata: modelMetadata,
        requestId: requestId,
        idleTimeout: idleTimeout,
        doomLoop: doomLoop,
        clientCustomToolNames: clientCustomToolNames
    )
}

public func streamResponsesWithClientCustomTools(
    rawStream: AsyncStream<Result<ResponsesStreamEvent, SamplingError>>,
    modelMetadata: ResponseModelMetadata?,
    requestId: RequestId,
    idleTimeout: MonotonicDuration,
    doomLoop: DoomLoopSignalCollector?,
    clientCustomToolNames: [String]
) -> AsyncStream<SamplingEvent> {
    let customNameSet = Set(clientCustomToolNames)
    return AsyncStream { continuation in
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

            var finalResponse: JSONValue?
            var chunkIndex: UInt64 = 0
            var messageChunkCount: UInt64 = 0
            var firstTokenEmitted = false
            var reasoningTextAcc = ""
            var reasoningSummaryParts: [ReasoningUnitKey: String] = [:]
            var lastReasoningUnit: ReasoningUnitKey?
            var completedOutputItems: [UInt32: JSONValue] = [:]
            var lastContentChunkAt = MonotonicInstant.now
            var outputToToolIndex: [UInt32: UInt32] = [:]
            var funcArgsStarted: Set<UInt32> = []
            var customInputStarted: Set<UInt32> = []
            var nextToolIndex: UInt32 = 0
            var citationFilter = DisplayCitationFilter()
            var streamedText = ""

            let iterator = AsyncStreamIteratorRelay(rawStream)
            while true {
                if let triggers = doomLoop?.abortTriggers() {
                    let err = SamplingError.doomLoopDetected(
                        triggers: triggers,
                        abortedAtChunk: chunkIndex
                    )
                    continuation.yield(.failed(requestId: requestId, error: SamplingErrorInfo(from: err)))
                    continuation.finish()
                    return
                }

                let next = await iterator.next()
                guard let next else { break }

                let event: ResponsesStreamEvent
                switch next {
                case .success(let e): event = e
                case .failure(let err):
                    continuation.yield(.failed(requestId: requestId, error: SamplingErrorInfo(from: err)))
                    continuation.finish()
                    return
                }

                let hasContent = responsesEventHasMeaningfulContent(event)
                var shouldBreak = false

                switch event {
                case .outputTextDelta(let delta, _, _):
                    if !delta.isEmpty {
                        let visible = citationFilter.push(delta)
                        if !visible.isEmpty {
                            if !firstTokenEmitted {
                                firstTokenEmitted = true
                                continuation.yield(.firstToken(requestId: requestId))
                            }
                            chunkTimestamps.append(.now)
                            chunkIndex += 1
                            messageChunkCount += 1
                            streamedText += visible
                            continuation.yield(.channelToken(
                                requestId: requestId,
                                channel: .text,
                                text: visible,
                                chunkIndex: chunkIndex
                            ))
                        }
                    }

                case .outputTextDone:
                    break

                case .reasoningSummaryDelta(let delta, let itemId, let outputIndex, let summaryIndex):
                    if !delta.isEmpty {
                        if !firstTokenEmitted {
                            firstTokenEmitted = true
                            continuation.yield(.firstToken(requestId: requestId))
                        }
                        chunkIndex += 1
                        let unit = ReasoningUnitKey.summary(outputIndex, itemId, summaryIndex)
                        let needsBreak = lastReasoningUnit.map { $0 != unit } ?? false
                        lastReasoningUnit = unit
                        reasoningSummaryParts[unit, default: ""] += delta
                        let text = needsBreak ? "\n\n\(delta)" : delta
                        continuation.yield(.channelToken(
                            requestId: requestId,
                            channel: .reasoning,
                            text: text,
                            chunkIndex: chunkIndex
                        ))
                    }

                case .reasoningSummaryDone(let text, let itemId, let outputIndex, let summaryIndex):
                    let unit = ReasoningUnitKey.summary(outputIndex, itemId, summaryIndex)
                    let existing = reasoningSummaryParts[unit] ?? ""
                    if existing.isEmpty && !text.isEmpty {
                        if !firstTokenEmitted {
                            firstTokenEmitted = true
                            continuation.yield(.firstToken(requestId: requestId))
                        }
                        chunkIndex += 1
                        reasoningSummaryParts[unit] = text
                        let needsBreak = lastReasoningUnit.map { $0 != unit } ?? false
                        lastReasoningUnit = unit
                        continuation.yield(.channelToken(
                            requestId: requestId,
                            channel: .reasoning,
                            text: needsBreak ? "\n\n\(text)" : text,
                            chunkIndex: chunkIndex
                        ))
                    }

                case .reasoningTextDelta(let delta, let itemId, let outputIndex):
                    if !delta.isEmpty {
                        if !firstTokenEmitted {
                            firstTokenEmitted = true
                            continuation.yield(.firstToken(requestId: requestId))
                        }
                        chunkIndex += 1
                        let unit = ReasoningUnitKey.text(outputIndex, itemId)
                        let needsBreak = lastReasoningUnit.map { $0 != unit } ?? false
                        lastReasoningUnit = unit
                        reasoningTextAcc += delta
                        continuation.yield(.channelToken(
                            requestId: requestId,
                            channel: .reasoning,
                            text: needsBreak ? "\n\n\(delta)" : delta,
                            chunkIndex: chunkIndex
                        ))
                    }

                case .functionCallArgumentsDelta(let delta, _, let outputIndex):
                    if !delta.isEmpty {
                        let toolIndex = outputToToolIndex[outputIndex] ?? {
                            let idx = nextToolIndex
                            nextToolIndex += 1
                            outputToToolIndex[outputIndex] = idx
                            return idx
                        }()
                        funcArgsStarted.insert(outputIndex)
                        continuation.yield(.toolCallDelta(
                            requestId: requestId,
                            toolIndex: toolIndex,
                            id: nil,
                            name: nil,
                            argumentsDelta: delta
                        ))
                    }

                case .functionCallArgumentsDone(let arguments, _, let outputIndex):
                    let toolIndex = outputToToolIndex[outputIndex] ?? {
                        let idx = nextToolIndex
                        nextToolIndex += 1
                        outputToToolIndex[outputIndex] = idx
                        return idx
                    }()
                    if !funcArgsStarted.contains(outputIndex) && !arguments.isEmpty {
                        continuation.yield(.toolCallDelta(
                            requestId: requestId,
                            toolIndex: toolIndex,
                            id: nil,
                            name: nil,
                            argumentsDelta: arguments
                        ))
                    }

                case .customToolCallInputDelta(let delta, _, let outputIndex):
                    if !delta.isEmpty {
                        let toolIndex = outputToToolIndex[outputIndex] ?? {
                            let idx = nextToolIndex
                            nextToolIndex += 1
                            outputToToolIndex[outputIndex] = idx
                            return idx
                        }()
                        customInputStarted.insert(outputIndex)
                        continuation.yield(.toolCallDelta(
                            requestId: requestId,
                            toolIndex: toolIndex,
                            id: nil,
                            name: nil,
                            argumentsDelta: delta
                        ))
                    }

                case .customToolCallInputDone(let input, let itemId, let outputIndex):
                    if let toolIndex = outputToToolIndex[outputIndex] {
                        if !customInputStarted.contains(outputIndex) && !input.isEmpty {
                            continuation.yield(.toolCallDelta(
                                requestId: requestId,
                                toolIndex: toolIndex,
                                id: nil,
                                name: nil,
                                argumentsDelta: input
                            ))
                        }
                    } else if !itemId.isEmpty {
                        continuation.yield(.backendToolCallStarted(
                            requestId: requestId,
                            callId: itemId,
                            name: "x_search"
                        ))
                    }

                case .outputItemAdded(let outputIndex, let item):
                    let itemType = item["type"]?.stringValue
                    if itemType == "function_call" || itemType == "custom_tool_call" {
                        let toolIndex = nextToolIndex
                        nextToolIndex += 1
                        outputToToolIndex[outputIndex] = toolIndex
                        let id = item["call_id"]?.stringValue ?? item["id"]?.stringValue
                        let name = item["name"]?.stringValue
                        let args = item["arguments"]?.stringValue ?? item["input"]?.stringValue
                        if let args, !args.isEmpty {
                            funcArgsStarted.insert(outputIndex)
                            customInputStarted.insert(outputIndex)
                        }
                        continuation.yield(.toolCallDelta(
                            requestId: requestId,
                            toolIndex: toolIndex,
                            id: id,
                            name: name,
                            argumentsDelta: args
                        ))
                    } else if itemType == "web_search_call" || itemType == "x_search_call"
                                || itemType == "code_interpreter_call"
                    {
                        let callId = item["id"]?.stringValue ?? "backend-\(outputIndex)"
                        let name = itemType ?? "backend_tool"
                        continuation.yield(.backendToolCallStarted(
                            requestId: requestId,
                            callId: callId,
                            name: name
                        ))
                    }

                case .outputItemDone(let outputIndex, let item):
                    completedOutputItems[outputIndex] = item
                    let itemType = item["type"]?.stringValue
                    if itemType == "web_search_call" || itemType == "x_search_call"
                        || itemType == "code_interpreter_call"
                    {
                        let callId = item["id"]?.stringValue ?? "backend-\(outputIndex)"
                        let name = itemType ?? "backend_tool"
                        continuation.yield(.backendToolCallCompleted(
                            requestId: requestId,
                            callId: callId,
                            name: name,
                            result: item
                        ))
                    }

                case .completed(let response):
                    finalResponse = response
                    shouldBreak = true

                case .incomplete(let response):
                    finalResponse = response
                    shouldBreak = true

                case .failed(let response):
                    let message = response["error"]?["message"]?.stringValue
                        ?? response["error"]?.stringValue
                        ?? "response failed"
                    let err = SamplingError.api(
                        status: HTTPStatus(500),
                        message: message,
                        modelMetadata: nil,
                        retryAfterSecs: nil,
                        shouldRetry: nil
                    )
                    continuation.yield(.failed(requestId: requestId, error: SamplingErrorInfo(from: err)))
                    continuation.finish()
                    return

                case .error(let message, let code):
                    let err = SamplingError.streamError(
                        errorType: code ?? "server_error",
                        message: message
                    )
                    continuation.yield(.failed(requestId: requestId, error: SamplingErrorInfo(from: err)))
                    continuation.finish()
                    return

                case .other:
                    break
                }

                if hasContent {
                    lastContentChunkAt = .now
                } else if MonotonicInstant.now - lastContentChunkAt > idleTimeout {
                    let err = SamplingError.idleTimeout(elapsedSecs: idleTimeout.wholeSeconds)
                    continuation.yield(.failed(requestId: requestId, error: SamplingErrorInfo(from: err)))
                    continuation.finish()
                    return
                }

                if shouldBreak { break }
            }

            citationFilter.finish()

            guard var responseJSON = finalResponse else {
                let err = SamplingError.api(
                    status: HTTPStatus(500),
                    message: "stream ended without response.completed",
                    modelMetadata: nil,
                    retryAfterSecs: nil,
                    shouldRetry: nil
                )
                continuation.yield(.failed(requestId: requestId, error: SamplingErrorInfo(from: err)))
                continuation.finish()
                return
            }

            // Codex: terminal completed may have empty output; retain item.done items.
            if case .object(var obj) = responseJSON {
                let output = obj["output"]?.arrayValue ?? []
                if output.isEmpty && !completedOutputItems.isEmpty {
                    let merged = completedOutputItems.keys.sorted().compactMap { completedOutputItems[$0] }
                    obj["output"] = .array(merged)
                    responseJSON = .object(obj)
                }
            }

            var items = responsesJSONToConversationItems(
                responseJSON,
                clientCustomToolNames: customNameSet,
                streamedTextFallback: streamedText
            )
            stripDisplayCitationsInItems(&items)

            if reasoningSummaryParts.isEmpty {
                injectStreamingReasoningFallback(items: &items, text: reasoningTextAcc)
            } else {
                // Merge summary parts into a single reasoning sibling when none exist.
                let joined = reasoningSummaryParts
                    .sorted { a, b in
                        switch (a.key, b.key) {
                        case (.summary(let ao, _, let as_), .summary(let bo, _, let bs_)):
                            return (ao, as_) < (bo, bs_)
                        default:
                            return false
                        }
                    }
                    .map(\.value)
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")
                injectStreamingReasoningFallback(items: &items, text: joined)
            }

            let hasToolCalls = items.contains { item in
                if case .assistant(let a) = item { return !a.toolCalls.isEmpty }
                return false
            }
            let status = responseJSON["status"]?.stringValue
            let stopReason: StopReason?
            if hasToolCalls {
                stopReason = .toolCalls
            } else if status == "completed" {
                stopReason = .stop
            } else if status == "incomplete" {
                stopReason = .length
            } else {
                stopReason = nil
            }

            let usage = parseResponsesUsage(responseJSON["usage"])
            let costUsdTicks = responseJSON["metadata"]?["xai.cost_usd_ticks"]?.stringValue
                .flatMap { Int64($0) }
                .flatMap { reportedCostTicks($0) }

            let metrics = InferenceLatencyStats.fromTimestamps(
                streamStart: streamStart,
                chunkTimestamps: chunkTimestamps,
                streamEnd: .now
            )

            let doomSignals = doomLoop?.take() ?? []
            let conversationResponse = ConversationResponse(
                items: items,
                stopReason: stopReason,
                usage: usage,
                costUsdTicks: costUsdTicks,
                messageChunksEmitted: messageChunkCount,
                doomLoopSignals: doomSignals
            )
            continuation.yield(.completed(
                requestId: requestId,
                response: conversationResponse,
                metrics: metrics
            ))
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

// MARK: - Responses → ConversationItem

func responsesJSONToConversationItems(
    _ response: JSONValue,
    clientCustomToolNames: Set<String>,
    streamedTextFallback: String
) -> [ConversationItem] {
    let output = response["output"]?.arrayValue ?? []
    var items: [ConversationItem] = []
    var assistantText = ""
    var toolCalls: [ToolCall] = []
    let model = response["model"]?.stringValue

    for item in output {
        let type = item["type"]?.stringValue ?? ""
        switch type {
        case "message":
            let role = item["role"]?.stringValue ?? "assistant"
            if role == "assistant" {
                if let content = item["content"] {
                    if case .string(let s) = content {
                        assistantText += s
                    } else if case .array(let parts) = content {
                        for part in parts {
                            let ptype = part["type"]?.stringValue
                            if ptype == "output_text" || ptype == "text" {
                                assistantText += part["text"]?.stringValue ?? ""
                            }
                        }
                    }
                }
            }
        case "function_call":
            let callId = item["call_id"]?.stringValue ?? item["id"]?.stringValue ?? ""
            let name = item["name"]?.stringValue ?? ""
            let args = item["arguments"]?.stringValue ?? "{}"
            toolCalls.append(ToolCall(id: callId, name: name, arguments: args))
        case "custom_tool_call":
            let callId = item["call_id"]?.stringValue ?? ""
            let itemId = item["id"]?.stringValue ?? callId
            let name = item["name"]?.stringValue ?? ""
            let input = item["input"]?.stringValue ?? ""
            if clientCustomToolNames.contains(name) {
                toolCalls.append(.custom(callId: callId, itemId: itemId, name: name, input: input))
            } else {
                // Backend custom tool (e.g. x_search) — store as backend call.
                items.append(.backendToolCall(BackendToolCallItem(kind: .xSearch(
                    CustomToolCall(id: itemId, callId: callId, name: name, input: input)
                ))))
            }
        case "reasoning":
            if let reasoning = try? item.decode(ReasoningItem.self) {
                items.append(.reasoning(reasoning))
            } else {
                let id = item["id"]?.stringValue ?? ""
                let enc = item["encrypted_content"]?.stringValue
                items.append(.reasoning(ReasoningItem(
                    id: id,
                    summary: [],
                    encryptedContent: enc
                )))
            }
        case "web_search_call":
            let id = item["id"]?.stringValue ?? ""
            let query = item["action"]?["query"]?.stringValue ?? ""
            items.append(.backendToolCall(BackendToolCallItem(kind: .webSearch(
                WebSearchToolCall(id: id, action: .search(query: query))
            ))))
        default:
            break
        }
    }

    if assistantText.isEmpty && !streamedTextFallback.isEmpty {
        assistantText = streamedTextFallback
    }

    items.append(.assistant(AssistantItem(
        content: assistantText,
        toolCalls: toolCalls,
        modelId: model
    )))
    return items
}

private func parseResponsesUsage(_ usage: JSONValue?) -> TokenUsage? {
    guard let usage else { return nil }
    let input = UInt32(usage["input_tokens"]?.intValue ?? 0)
    let output = UInt32(usage["output_tokens"]?.intValue ?? 0)
    let total = UInt32(usage["total_tokens"]?.intValue ?? Int(input &+ output))
    let reasoning = UInt32(usage["output_tokens_details"]?["reasoning_tokens"]?.intValue ?? 0)
    let cached = UInt32(usage["input_tokens_details"]?["cached_tokens"]?.intValue ?? 0)
    return TokenUsage(
        promptTokens: input,
        completionTokens: output,
        totalTokens: total,
        reasoningTokens: reasoning,
        cachedPromptTokens: cached
    )
}

