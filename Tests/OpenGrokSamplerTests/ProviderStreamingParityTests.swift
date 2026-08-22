import Foundation
import OpenGrokSamplingTypes
import OpenGrokShared
import Testing
@testable import OpenGrokSampler

@Suite("Foundational provider streaming parity")
struct ProviderStreamingParityTests {
    private func chatChunk(
        delta: ChatChunkDelta,
        finishReason: FinishReason? = nil,
        usage: Usage? = nil
    ) -> ChatCompletionChunk {
        ChatCompletionChunk(
            id: "chat_1",
            object: "chat.completion.chunk",
            created: 1,
            model: "openrouter/test",
            choices: [ChatChunkChoice(index: 0, delta: delta, finishReason: finishReason)],
            usage: usage
        )
    }

    private func collect(_ stream: AsyncStream<SamplingEvent>) async -> [SamplingEvent] {
        var result: [SamplingEvent] = []
        for await event in stream {
            result.append(event)
        }
        return result
    }

    private func chatEvents(_ chunks: [ChatCompletionChunk]) async -> [SamplingEvent] {
        await collect(streamChatCompletions(
            rawStream: makeResultStream(chunks.map { .success($0) }),
            modelMetadata: nil,
            requestId: RequestId("provider-parity"),
            idleTimeout: .seconds(60)
        ))
    }

    private func responseEvents(
        _ events: [ResponsesStreamEvent],
        clientCustomToolNames: [String] = []
    ) async -> [SamplingEvent] {
        await collect(streamResponses(
            rawStream: makeResultStream(events.map { .success($0) }),
            modelMetadata: nil,
            requestId: RequestId("provider-parity"),
            idleTimeout: .seconds(60),
            clientCustomToolNames: clientCustomToolNames
        ))
    }

    private func completedResponse(output: [JSONValue] = [], usage: JSONValue? = nil) -> JSONValue {
        var response: [String: JSONValue] = [
            "id": .string("response_1"),
            "status": .string("completed"),
            "model": .string("test"),
            "output": .array(output),
        ]
        if let usage {
            response["usage"] = usage
        }
        return .object(response)
    }

    private func functionItem(id: String, name: String, arguments: String = "") -> JSONValue {
        .object([
            "type": .string("function_call"),
            "id": .string("item_\(id)"),
            "call_id": .string(id),
            "name": .string(name),
            "arguments": .string(arguments),
        ])
    }

    private func customItem(id: String, name: String, input: String = "") -> JSONValue {
        .object([
            "type": .string("custom_tool_call"),
            "id": .string("item_\(id)"),
            "call_id": .string(id),
            "name": .string(name),
            "input": .string(input),
        ])
    }

    private func completions(_ events: [SamplingEvent]) -> [(index: UInt32, id: String?, name: String?)] {
        events.compactMap { event in
            guard case .toolCallArgumentsComplete(_, let index, let id, let name) = event else {
                return nil
            }
            return (index: index, id: id, name: name)
        }
    }

    private func argumentDeltas(_ events: [SamplingEvent], index: UInt32) -> [String] {
        events.compactMap { event in
            guard case .toolCallDelta(_, let toolIndex, _, _, let arguments) = event,
                  toolIndex == index
            else { return nil }
            return arguments
        }
    }

    @Test("OpenRouter reasoning deltas preserve leading spaces and populate missing token counts")
    func openRouterReasoningAndTokenFallback() async {
        let events = await chatEvents([
            chatChunk(delta: ChatChunkDelta(reasoning: "I think")),
            chatChunk(delta: ChatChunkDelta(reasoning: " therefore")),
            chatChunk(
                delta: ChatChunkDelta(content: "answer"),
                finishReason: .stop,
                usage: Usage(promptTokens: 20, completionTokens: 9, totalTokens: 29)
            ),
        ])

        let reasoning = events.compactMap { event -> String? in
            guard case .channelToken(_, .reasoning, let text, _) = event else { return nil }
            return text
        }

        #expect(reasoning == ["I think", " therefore"])
        guard case .completed(_, let response, _) = events.last else {
            Issue.record("expected terminal completed response")
            return
        }
        #expect(response.reasoningItems().first?.summary.first?.text == "I think therefore")
        #expect(response.usage?.reasoningTokens == 5)
    }

    @Test("structured OpenRouter details reach the reasoning channel without encrypted payloads")
    func structuredReasoning() async {
        let events = await chatEvents([
            chatChunk(delta: ChatChunkDelta(reasoningDetails: [
                OpenRouterReasoningDetail(type: "reasoning.encrypted", extra: ["data": .string("secret")]),
                OpenRouterReasoningDetail(type: "reasoning.text", text: "first"),
                OpenRouterReasoningDetail(type: "reasoning.summary", summary: " second"),
            ])),
            chatChunk(delta: ChatChunkDelta(content: "answer"), finishReason: .stop),
        ])

        let reasoning = events.compactMap { event -> String? in
            guard case .channelToken(_, .reasoning, let text, _) = event else { return nil }
            return text
        }

        #expect(reasoning == ["first second"])
    }

    @Test("provider-reported reasoning token counts are never replaced")
    func reportedReasoningTokensWin() async {
        let events = await chatEvents([
            chatChunk(delta: ChatChunkDelta(reasoning: "123456789")),
            chatChunk(
                delta: ChatChunkDelta(content: "answer"),
                finishReason: .stop,
                usage: Usage(
                    promptTokens: 20,
                    completionTokens: 9,
                    totalTokens: 29,
                    completionTokensDetails: CompletionTokensDetails(reasoningTokens: 77)
                )
            ),
        ])

        guard case .completed(_, let response, _) = events.last else {
            Issue.record("expected completed response")
            return
        }
        #expect(response.usage?.reasoningTokens == 77)
    }

    @Test("parallel Chat call fragments can interleave until the terminal finish reason")
    func chatKeepsInterleavedArgumentsOpenUntilFinish() async {
        let events = await chatEvents([
            chatChunk(delta: ChatChunkDelta(toolCalls: [
                ToolCallDelta(index: 0, id: "call_a", function: ToolCallFunctionDelta(name: "first", arguments: #"{"path":"#)),
            ])),
            chatChunk(delta: ChatChunkDelta(toolCalls: [
                ToolCallDelta(index: 1, id: "call_b", function: ToolCallFunctionDelta(name: "second", arguments: "{}")),
            ])),
            chatChunk(delta: ChatChunkDelta(toolCalls: [
                ToolCallDelta(index: 0, function: ToolCallFunctionDelta(arguments: #""a.swift"}"#)),
            ])),
            chatChunk(delta: ChatChunkDelta(), finishReason: .toolCalls),
        ])

        #expect(completions(events).map { $0.index } == [0, 1])
        let firstCompletion = events.firstIndex {
            guard case .toolCallArgumentsComplete(_, let index, _, _) = $0 else { return false }
            return index == 0
        }
        let secondDelta = events.firstIndex {
            guard case .toolCallDelta(_, let index, _, _, _) = $0 else { return false }
            return index == 1
        }
        #expect(firstCompletion != nil)
        #expect(secondDelta != nil)
        #expect(firstCompletion! > secondDelta!)
        guard case .completed(_, let response, _) = events.last else {
            Issue.record("expected completed response")
            return
        }
        #expect(response.toolCalls().count == 2)
        #expect(response.toolCalls().first?.arguments == #"{"path":"a.swift"}"#)
    }

    @Test("Chat stream ending without finish reason finalizes each started call once")
    func chatCompletesAtEnd() async {
        let events = await chatEvents([
            chatChunk(delta: ChatChunkDelta(toolCalls: [
                ToolCallDelta(index: 0, id: "call_a", function: ToolCallFunctionDelta(name: "run", arguments: #"{"x":"#)),
            ])),
            chatChunk(delta: ChatChunkDelta(toolCalls: [
                ToolCallDelta(index: 0, function: ToolCallFunctionDelta(arguments: "1}")),
            ])),
        ])

        #expect(completions(events).count == 1)
        #expect(completions(events).first?.id == "call_a")
        #expect(argumentDeltas(events, index: 0) == [#"{"x":"#, "1}"])
        guard case .completed(_, let response, _) = events.last else {
            Issue.record("expected completed response")
            return
        }
        #expect(response.toolCalls().first?.arguments == #"{"x":1}"#)
    }

    @Test("Interrupted Chat streams never finalize incomplete parallel calls")
    func interruptedChatNeverCompletesTools() async {
        let first = chatChunk(delta: ChatChunkDelta(toolCalls: [
            ToolCallDelta(index: 0, id: "call_a", function: ToolCallFunctionDelta(
                name: "first", arguments: #"{"path":"#
            )),
        ]))
        let events = await collect(streamChatCompletions(
            rawStream: makeResultStream([
                .success(first),
                .failure(.streamError(errorType: "transport", message: "interrupted")),
            ]),
            modelMetadata: nil,
            requestId: RequestId("interrupted-chat"),
            idleTimeout: .seconds(60)
        ))

        #expect(completions(events).isEmpty)
        if case .failed = events.last {
            #expect(Bool(true))
        } else {
            Issue.record("interrupted stream must fail instead of completing")
        }
    }

    @Test("Messages tool block stop emits one completion before the canonical response")
    func messagesCompleteAtBlockStop() async {
        let events: [MessageStreamEvent] = [
            .messageStart(message: MessagesResponse(
                id: "message_1",
                type: "message",
                role: "assistant",
                content: [],
                model: "claude",
                usage: MessagesUsage(inputTokens: 10, outputTokens: 0)
            )),
            .contentBlockStart(index: 1, contentBlock: .toolUse(id: "tool_1", name: "read_file", input: .object([:]))),
            .contentBlockDelta(index: 1, delta: .inputJsonDelta(partialJson: #"{"path":"a"}"#)),
            .contentBlockStop(index: 1),
            .contentBlockStop(index: 1),
            .messageDelta(delta: MessageDeltaBody(stopReason: .toolUse), usage: MessageDeltaUsage(outputTokens: 3)),
            .messageStop,
        ]
        let output = await collect(streamMessages(
            rawStream: makeResultStream(events.map { .success($0) }),
            modelMetadata: nil,
            requestId: RequestId("messages-parity"),
            idleTimeout: .seconds(60)
        ))

        #expect(completions(output).count == 1)
        #expect(completions(output).first?.id == "tool_1")
        #expect(completions(output).first?.name == "read_file")
        guard case .completed(_, let response, _) = output.last else {
            Issue.record("expected completed response")
            return
        }
        #expect(response.toolCalls().first?.arguments == #"{"path":"a"}"#)
    }

    @Test("Messages preserves nonempty tool input provided in the initial block")
    func messagesPreservesInitialToolInput() async {
        let events = await collect(streamMessages(
            rawStream: makeResultStream([
                .success(.contentBlockStart(index: 2, contentBlock: .toolUse(
                    id: "tool_1",
                    name: "read_file",
                    input: .object(["value": .number(.int64(7))])
                ))),
                .success(.contentBlockStop(index: 2)),
                .success(.messageStop),
            ]),
            modelMetadata: nil,
            requestId: RequestId("messages-initial-input"),
            idleTimeout: .seconds(60)
        ))

        #expect(argumentDeltas(events, index: 0) == [#"{"value":7}"#])
        guard case .completed(_, let response, _) = events.last else {
            Issue.record("expected completed response")
            return
        }
        #expect(response.toolCalls().first?.arguments == #"{"value":7}"#)
    }

    @Test("Messages normalizes an untouched empty tool input before completion")
    func messagesNormalizesEmptyToolInput() async {
        let events = await collect(streamMessages(
            rawStream: makeResultStream([
                .success(.contentBlockStart(index: 0, contentBlock: .toolUse(
                    id: "tool_1", name: "read_file", input: .object([:])
                ))),
                .success(.contentBlockStop(index: 0)),
            ]),
            modelMetadata: nil,
            requestId: RequestId("messages-empty-input"),
            idleTimeout: .seconds(60)
        ))

        #expect(argumentDeltas(events, index: 0) == ["{}"])
        #expect(completions(events).count == 1)
        guard case .completed(_, let response, _) = events.last else {
            Issue.record("expected completed response")
            return
        }
        #expect(response.toolCalls().first?.arguments == "{}")
    }

    @Test("Messages retains tool start order when block stops arrive in reverse")
    func messagesPreservesParallelStartOrder() async {
        let events = await collect(streamMessages(
            rawStream: makeResultStream([
                .success(.contentBlockStart(index: 2, contentBlock: .toolUse(
                    id: "first", name: "first", input: .object([:])
                ))),
                .success(.contentBlockStart(index: 5, contentBlock: .toolUse(
                    id: "second", name: "second", input: .object([:])
                ))),
                .success(.contentBlockStop(index: 5)),
                .success(.contentBlockStop(index: 2)),
            ]),
            modelMetadata: nil,
            requestId: RequestId("messages-parallel"),
            idleTimeout: .seconds(60)
        ))

        guard case .completed(_, let response, _) = events.last else {
            Issue.record("expected completed response")
            return
        }
        #expect(response.toolCalls().map(\.name) == ["first", "second"])
    }

    @Test("Responses function done finalizes exactly once despite duplicate and item-done frames")
    func responsesFunctionCompletionExactlyOnce() async {
        let item = functionItem(id: "call_1", name: "read", arguments: #"{"path":"a"}"#)
        let events = await responseEvents([
            .outputItemAdded(outputIndex: 2, item: functionItem(id: "call_1", name: "read")),
            .functionCallArgumentsDelta(delta: #"{"path":"#, itemId: "item_1", outputIndex: 2),
            .functionCallArgumentsDelta(delta: #""a"}"#, itemId: "item_1", outputIndex: 2),
            .functionCallArgumentsDone(arguments: #"{"path":"a"}"#, itemId: "item_1", outputIndex: 2),
            .functionCallArgumentsDone(arguments: #"{"path":"a"}"#, itemId: "item_1", outputIndex: 2),
            .outputItemDone(outputIndex: 2, item: item),
            .completed(response: completedResponse()),
        ])

        #expect(completions(events).count == 1)
        #expect(completions(events).first?.index == 0)
        #expect(completions(events).first?.name == "read")
        #expect(argumentDeltas(events, index: 0) == [#"{"path":"#, #""a"}"#])
        guard case .completed(_, let response, _) = events.last else {
            Issue.record("expected completed response")
            return
        }
        #expect(response.toolCalls().first?.arguments == #"{"path":"a"}"#)
    }

    @Test("Responses arguments-done sends complete catch-up before its readiness hint")
    func responsesFunctionDoneCatchUp() async {
        let events = await responseEvents([
            .outputItemAdded(outputIndex: 0, item: functionItem(id: "call_1", name: "run")),
            .functionCallArgumentsDone(arguments: #"{"command":"pwd"}"#, itemId: "item_1", outputIndex: 0),
            .completed(response: completedResponse()),
        ])

        #expect(argumentDeltas(events, index: 0) == [#"{"command":"pwd"}"#])
        #expect(completions(events).count == 1)
        let deltaPosition = events.lastIndex {
            guard case .toolCallDelta(_, _, _, _, let arguments) = $0 else { return false }
            return arguments != nil
        }
        let completionPosition = events.firstIndex {
            if case .toolCallArgumentsComplete = $0 { return true }
            return false
        }
        #expect(deltaPosition! < completionPosition!)
    }

    @Test("Responses function done emits only the missing authoritative suffix")
    func responsesFunctionDoneCompletesPartialSuffix() async {
        let full = #"{"source":"return 1"}"#
        let events = await responseEvents([
            .outputItemAdded(outputIndex: 0, item: functionItem(id: "call_1", name: "exec")),
            .functionCallArgumentsDelta(delta: #"{"source":"#, itemId: "item_1", outputIndex: 0),
            .functionCallArgumentsDone(arguments: full, itemId: "item_1", outputIndex: 0),
            .completed(response: completedResponse(output: [
                functionItem(id: "call_1", name: "exec", arguments: full),
            ])),
        ])

        #expect(argumentDeltas(events, index: 0) == [#"{"source":"#, #""return 1"}"#])
        #expect(completions(events).count == 1)
    }

    @Test("Responses initial function arguments precede subsequent fragments exactly once")
    func responsesInitialFunctionInputIsPreserved() async {
        let full = #"{"source":"return 1"}"#
        let events = await responseEvents([
            .outputItemAdded(outputIndex: 0, item: functionItem(
                id: "call_1", name: "exec", arguments: #"{"source":"#
            )),
            .functionCallArgumentsDelta(delta: #""return 1"}"#, itemId: "item_1", outputIndex: 0),
            .functionCallArgumentsDone(arguments: full, itemId: "item_1", outputIndex: 0),
            .completed(response: completedResponse()),
        ])

        #expect(argumentDeltas(events, index: 0) == [#"{"source":"#, #""return 1"}"#])
        #expect(completions(events).count == 1)
    }

    @Test("Responses custom completion adds its missing suffix and rejects late deltas")
    func responsesCustomSuffixAndLateDeltaIsolation() async {
        let events = await responseEvents([
            .outputItemAdded(outputIndex: 0, item: customItem(id: "call_exec", name: "exec")),
            .customToolCallInputDelta(delta: "return ", itemId: "item_exec", outputIndex: 0),
            .customToolCallInputDone(input: "return 1", itemId: "item_exec", outputIndex: 0),
            .customToolCallInputDone(input: "return 1", itemId: "item_exec", outputIndex: 0),
            .customToolCallInputDelta(delta: ";secret()", itemId: "item_exec", outputIndex: 0),
            .completed(response: completedResponse(output: [
                customItem(id: "call_exec", name: "exec", input: "return 1"),
            ])),
        ], clientCustomToolNames: ["exec"])

        #expect(argumentDeltas(events, index: 0) == ["return ", "1"])
        #expect(completions(events).count == 1)
    }

    @Test("Responses terminal snapshot completes missing function bytes and identity")
    func responsesTerminalSnapshotFinalizesMissingSuffix() async {
        let full = #"{"path":"a.swift"}"#
        let events = await responseEvents([
            .outputItemAdded(outputIndex: 0, item: functionItem(id: "call_1", name: "read_file")),
            .functionCallArgumentsDelta(delta: #"{"path":"#, itemId: "item_1", outputIndex: 0),
            .completed(response: completedResponse(output: [
                functionItem(id: "call_1", name: "read_file", arguments: full),
            ])),
        ])

        #expect(argumentDeltas(events, index: 0) == [#"{"path":"#, #""a.swift"}"#])
        #expect(completions(events).count == 1)
        #expect(completions(events).first?.id == "call_1")
        #expect(completions(events).first?.name == "read_file")
    }

    @Test("Responses item-done backstop catches up unstreamed function arguments")
    func responsesFunctionItemDoneBackstop() async {
        let fullItem = functionItem(id: "call_1", name: "run", arguments: #"{"command":"pwd"}"#)
        let events = await responseEvents([
            .outputItemAdded(outputIndex: 0, item: functionItem(id: "call_1", name: "run")),
            .outputItemDone(outputIndex: 0, item: fullItem),
            .completed(response: completedResponse()),
        ])

        #expect(argumentDeltas(events, index: 0) == [#"{"command":"pwd"}"#])
        #expect(completions(events).count == 1)
        #expect(completions(events).first?.name == "run")
    }

    @Test("Responses client custom input-done and item-done share one completion")
    func responsesClientCustomCompletionExactlyOnce() async {
        let finalItem = customItem(id: "call_exec", name: "exec", input: "console.log(1)")
        let events = await responseEvents([
            .outputItemAdded(outputIndex: 4, item: customItem(id: "call_exec", name: "exec")),
            .customToolCallInputDelta(delta: "console.", itemId: "item_exec", outputIndex: 4),
            .customToolCallInputDelta(delta: "log(1)", itemId: "item_exec", outputIndex: 4),
            .customToolCallInputDone(input: "console.log(1)", itemId: "item_exec", outputIndex: 4),
            .outputItemDone(outputIndex: 4, item: finalItem),
            .completed(response: completedResponse()),
        ], clientCustomToolNames: ["exec"])

        #expect(argumentDeltas(events, index: 0) == ["console.", "log(1)"])
        #expect(completions(events).count == 1)
        guard case .completed(_, let response, _) = events.last else {
            Issue.record("expected completed response")
            return
        }
        #expect(response.toolCalls().first?.name == "exec")
    }

    @Test("Responses client custom item-done catches up input and retains call identity")
    func responsesCustomItemDoneBackstop() async {
        let finalItem = customItem(id: "call_exec", name: "exec", input: "return 1")
        let events = await responseEvents([
            .outputItemAdded(outputIndex: 0, item: customItem(id: "call_exec", name: "exec")),
            .outputItemDone(outputIndex: 0, item: finalItem),
            .completed(response: completedResponse()),
        ], clientCustomToolNames: ["exec"])

        #expect(argumentDeltas(events, index: 0) == ["return 1"])
        #expect(completions(events).count == 1)
        #expect(completions(events).first?.id == "call_exec")
        #expect(completions(events).first?.name == "exec")
    }

    @Test("backend custom tools never masquerade as executable client calls")
    func backendCustomToolsStayServerSide() async {
        let item = customItem(id: "search_1", name: "x_keyword_search", input: "swift")
        let events = await responseEvents([
            .outputItemAdded(outputIndex: 1, item: item),
            .customToolCallInputDone(input: "swift", itemId: "item_search_1", outputIndex: 1),
            .outputItemDone(outputIndex: 1, item: item),
            .completed(response: completedResponse()),
        ], clientCustomToolNames: ["exec"])

        #expect(completions(events).isEmpty)
        #expect(argumentDeltas(events, index: 0).isEmpty)
        let started = events.filter {
            if case .backendToolCallStarted = $0 { return true }
            return false
        }
        let finished = events.filter {
            if case .backendToolCallCompleted = $0 { return true }
            return false
        }
        #expect(started.count == 1)
        #expect(finished.count == 1)
        guard case .completed(_, let response, _) = events.last else {
            Issue.record("expected completed response")
            return
        }
        #expect(response.toolCalls().isEmpty)
        #expect(response.backendToolItems().count == 1)
    }

    @Test("Responses context totals replace inflated cumulative totals without changing billing")
    func responsesContextTotalsAndCost() async {
        let usage: JSONValue = .object([
            "input_tokens": .number(.int64(18_000)),
            "output_tokens": .number(.int64(3_000)),
            "total_tokens": .number(.int64(21_000)),
            "cost_in_usd_ticks": .number(.int64(725)),
            "context_details": .object([
                "input_tokens": .number(.int64(4_000)),
                "output_tokens": .number(.int64(500)),
            ]),
            "input_tokens_details": .object(["cached_tokens": .number(.int64(1_200))]),
            "output_tokens_details": .object(["reasoning_tokens": .number(.int64(300))]),
        ])
        let events = await responseEvents([
            .completed(response: completedResponse(usage: usage)),
        ])

        guard case .completed(_, let response, _) = events.last else {
            Issue.record("expected completed response")
            return
        }
        #expect(response.usage?.promptTokens == 18_000)
        #expect(response.usage?.completionTokens == 3_000)
        #expect(response.usage?.totalTokens == 4_500)
        #expect(response.usage?.cachedPromptTokens == 1_200)
        #expect(response.usage?.reasoningTokens == 300)
        #expect(response.costUsdTicks == 725)
    }

    @Test("partial Responses context details retain the cumulative wire total")
    func partialContextDetailsRemainUnchanged() async {
        let usage: JSONValue = .object([
            "input_tokens": .number(.int64(18_000)),
            "output_tokens": .number(.int64(3_000)),
            "total_tokens": .number(.int64(21_000)),
            "context_details": .object(["input_tokens": .number(.int64(4_000))]),
        ])
        let events = await responseEvents([
            .completed(response: completedResponse(usage: usage)),
        ])

        guard case .completed(_, let response, _) = events.last else {
            Issue.record("expected completed response")
            return
        }
        #expect(response.usage?.totalTokens == 21_000)
    }
}
