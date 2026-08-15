import Foundation
@testable import OpenGrokCLI
import OpenGrokPagerMinimal
import OpenGrokPagerRender
import OpenGrokSampler
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import Testing

/// Wave A live-seam honesty: seed outcomes, apply fold/finishedAt merge, and
/// stream event mapping without spinning the full TUI.
@Suite("Wave A live stream and restore")
struct WaveALiveStreamAndRestoreTests {
    @Test("seed does not invent success for failed, cancelled, or unpaired tools")
    func seedHonestToolOutcomes() {
        var outcomes = ToolCallOutcomeMap()
        outcomes.upsert(callID: "ok", outcome: .succeeded)
        outcomes.upsert(callID: "boom", outcome: .failed, detail: "exit code 7")
        outcomes.upsert(callID: "stop", outcome: .cancelled)

        let items: [ConversationItem] = [
            .user("run tools"),
            .assistant(AssistantItem(
                content: "working",
                toolCalls: [
                    ToolCall(id: "ok", name: "read", arguments: #"{"path":"a.swift"}"#),
                    ToolCall(id: "boom", name: "bash", arguments: #"{"command":"exit 7"}"#),
                    ToolCall(id: "stop", name: "bash", arguments: #"{"command":"sleep 9"}"#),
                    ToolCall(id: "orphan", name: "read", arguments: #"{"path":"missing.swift"}"#),
                ]
            )),
            .toolResult(ToolResultItem(toolCallId: "ok", content: "file body")),
            .toolResult(ToolResultItem(toolCallId: "boom", content: "exit code 7")),
            .toolResult(ToolResultItem(toolCallId: "stop", content: "Cancelled")),
            // orphan intentionally unpaired
            .reasoning(ReasoningItem(
                id: "r1",
                summary: [.summaryText(text: "plan the edits")]
            )),
        ]

        var conversation = LivePagerConversationState()
        conversation.seed(from: items, toolOutcomes: outcomes)

        let tools = conversation.items.compactMap { item -> PagerToolCard? in
            if case .tool(let card) = item { return card }
            return nil
        }
        #expect(tools.count == 4)

        let byNameInput = Dictionary(uniqueKeysWithValues: tools.map { ($0.input, $0) })
        // displayInput extracts path/command from JSON
        #expect(byNameInput["a.swift"]?.state == .succeeded)
        #expect(byNameInput["exit 7"]?.state == .failed)
        #expect(byNameInput["exit 7"]?.detail == "exit code 7")
        #expect(byNameInput["sleep 9"]?.state == .cancelled)
        #expect(byNameInput["missing.swift"]?.state == .pending)
        #expect(byNameInput["missing.swift"]?.output == nil)

        let hasReasoning = conversation.items.contains { item in
            if case .message(let message) = item {
                return message.role == .reasoning && message.text.contains("plan the edits")
            }
            return false
        }
        #expect(hasReasoning)
    }

    @Test("apply running then terminal preserves isExpanded and first finishedAt")
    func applyPreservesFoldAndFinishedAt() {
        var conversation = LivePagerConversationState()
        conversation.startTurn(prompt: "hi")

        conversation.apply(
            OpenGrokPagerToolUpdate(
                callID: "c1",
                name: "bash",
                input: #"{"command":"echo one"}"#,
                state: .running
            ),
            atSeconds: 10
        )
        // Expand while running.
        let expanded = conversation.withItems { items in
            guard case .tool(var card) = items[items.count - 1] else {
                Issue.record("expected tool card")
                return false
            }
            card.isExpanded = true
            items[items.count - 1] = .tool(card)
            return true
        }
        #expect(expanded)

        // Incremental output while still running (A5 replace-or-keep).
        conversation.apply(
            OpenGrokPagerToolUpdate(
                callID: "c1",
                name: "bash",
                input: "",
                output: "one\n",
                state: .running
            ),
            atSeconds: 11
        )
        #expect(conversation.testingToolCard(callID: "c1")?.isExpanded == true)
        #expect(conversation.testingToolCard(callID: "c1")?.output == "one\n")
        // Sparse leader-style update must not wipe name/input.
        #expect(conversation.testingToolCard(callID: "c1")?.name == "bash")
        #expect(conversation.testingToolCard(callID: "c1")?.input == "echo one")

        conversation.apply(
            OpenGrokPagerToolUpdate(
                callID: "c1",
                name: "tool",
                input: "{}",
                output: "one\ntwo\n",
                state: .succeeded
            ),
            atSeconds: 12
        )
        let final = conversation.testingToolCard(callID: "c1")
        #expect(final?.isExpanded == true)
        #expect(final?.state == .succeeded)
        #expect(final?.output == "one\ntwo\n")
        #expect(final?.name == "bash")
        #expect(final?.input == "echo one")
        #expect(final?.finishedAt == 12)

        // Re-delivered terminal must not restart the flash.
        conversation.apply(
            OpenGrokPagerToolUpdate(
                callID: "c1",
                name: "bash",
                input: "echo one",
                output: "one\ntwo\n",
                state: .succeeded
            ),
            atSeconds: 99
        )
        #expect(conversation.testingFinishedAt(callID: "c1") == 12)
        #expect(conversation.testingToolCard(callID: "c1")?.isExpanded == true)
    }

    @Test("LiveSamplingStreamMapper forwards non-text sampler events")
    func streamMapperForwardsEvents() {
        let reasoning = LiveSamplingStreamMapper.map(
            .channelToken(requestId: .random(), channel: .reasoning, text: "think", chunkIndex: 0)
        )
        #expect(reasoning == .emit(.reasoning("think")))

        let delta = LiveSamplingStreamMapper.map(
            .toolCallDelta(
                requestId: .random(),
                toolIndex: 1,
                id: "tc-1",
                name: "bash",
                argumentsDelta: #"{"com"#
            )
        )
        guard case .emit(.toolCallDelta(1, "tc-1", "bash", #"{"com"#)) = delta else {
            Issue.record("expected toolCallDelta emit, got \(String(describing: delta))")
            return
        }

        let retry = LiveSamplingStreamMapper.map(
            .retrying(
                requestId: .random(),
                attempt: 2,
                maxRetries: 5,
                kind: .rateLimited,
                reason: "slow down",
                doomLoopTriggers: nil,
                doomLoopAbortedAtChunk: nil
            )
        )
        guard case .emit(.retrying(2, 5, .rateLimited, "slow down")) = retry else {
            Issue.record("expected retrying emit, got \(String(describing: retry))")
            return
        }

        let error = SamplingErrorInfo(
            kind: .auth,
            message: "bad key",
            isRetryable: false
        )
        let failed = LiveSamplingStreamMapper.map(
            .failed(requestId: .random(), error: error)
        )
        #expect(failed == .failed(error))

        let backendStart = LiveSamplingStreamMapper.map(
            .backendToolCallStarted(requestId: .random(), callId: "b1", name: "web_search")
        )
        #expect(backendStart == .emit(.backendToolCallStarted(callId: "b1", name: "web_search")))

        let backendDone = LiveSamplingStreamMapper.map(
            .backendToolCallCompleted(
                requestId: .random(),
                callId: "b1",
                name: "web_search",
                result: .string("hits")
            )
        )
        #expect(
            backendDone == .emit(.backendToolCallCompleted(
                callId: "b1",
                name: "web_search",
                result: .string("hits")
            ))
        )

        // Empty text tokens are ignored; streamStarted does not surface.
        #expect(LiveSamplingStreamMapper.map(
            .channelToken(requestId: .random(), channel: .text, text: "", chunkIndex: 0)
        ) == nil)
        #expect(LiveSamplingStreamMapper.map(
            .streamStarted(requestId: .random(), timestampMs: 0)
        ) == nil)
    }

    @Test("displayState marks nonzero exit as failed without dropping promptText")
    func displayStateFromTerminalMetadata() {
        let failed = OpenGrokShellToolCallResult(
            value: .object([
                "exit_code": .number(.int64(7)),
                "timed_out": .bool(false),
                "combined_output": .string("boom"),
            ]),
            promptText: "exit code 7\nboom"
        )
        #expect(LiveToolResultText.displayState(for: failed) == .failed)

        let ok = OpenGrokShellToolCallResult(
            value: .object([
                "exit_code": .number(.int64(0)),
                "timed_out": .bool(false),
            ]),
            promptText: "ok"
        )
        #expect(LiveToolResultText.displayState(for: ok) == .succeeded)

        let timedOut = OpenGrokShellToolCallResult(
            value: .object([
                "exit_code": .null,
                "timed_out": .bool(true),
            ]),
            promptText: "timed out"
        )
        #expect(LiveToolResultText.displayState(for: timedOut) == .failed)
    }
}
