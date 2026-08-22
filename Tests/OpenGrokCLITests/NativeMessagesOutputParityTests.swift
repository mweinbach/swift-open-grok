import Foundation
import OpenGrokPagerMinimal
import OpenGrokSamplingTypes
import OpenGrokTestSupport
import Testing
@testable import OpenGrokCLI

private struct NativeMessagesOutputFixture {
    let output: LivePagerOutput
    let stdout: BufferedStream
    let stderr: BufferedStream

    init(includePartialMessages: Bool = false) {
        let captured = CLIStreams.buffered()
        output = LivePagerOutput(
            streams: captured.streams,
            format: .streamingMessagesJSON,
            includePartialMessages: includePartialMessages,
            sessionID: "native-session",
            model: "claude-native",
            workingDirectory: "/tmp/native-workspace",
            tools: ["read_file", "write_file"],
            slashCommands: ["help", "compact"],
            skills: ["review"],
            permissionMode: "acceptEdits",
            apiKeySource: "oauth"
        )
        stdout = captured.out
        stderr = captured.err
    }

    func lines() throws -> [[String: Any]] {
        try stdout.contents.split(whereSeparator: \.isNewline).map { line in
            try #require(
                JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            )
        }
    }

    func responseStarted(
        messageID: String = "msg_provider_123",
        model: String = "claude-native",
        inputTokens: UInt64 = 120,
        cacheReadInputTokens: UInt64 = 40,
        cacheCreationInputTokens: UInt64 = 12
    ) async throws {
        try await output.forward(.responseStarted(
            messageID: messageID,
            model: model,
            inputTokens: inputTokens,
            cacheReadInputTokens: cacheReadInputTokens,
            cacheCreationInputTokens: cacheCreationInputTokens
        ))
    }

    func responseCompleted(
        messageID: String = "msg_provider_123",
        stopReason: String = "end_turn",
        stopSequence: String? = nil,
        inputTokens: UInt64 = 120,
        outputTokens: UInt64 = 17,
        cacheReadInputTokens: UInt64 = 40,
        cacheCreationInputTokens: UInt64 = 12
    ) async throws {
        try await output.forward(.responseCompleted(
            messageID: messageID,
            stopReason: stopReason,
            stopSequence: stopSequence,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadInputTokens: cacheReadInputTokens,
            cacheCreationInputTokens: cacheCreationInputTokens
        ))
    }

    func finish(summary: String = "end_turn") async throws {
        try await output.forward(.completed(OpenGrokPagerMinimalCompletion(
            sessionID: "native-session",
            summary: summary
        )))
    }
}

@Suite("Native streaming Messages output parity", .serialized)
struct NativeMessagesOutputParityTests {
    @Test("non-partial output emits typed system, assembled assistant, and result envelopes")
    func canonicalEnvelopesWithoutPartialMessages() async throws {
        let fixture = NativeMessagesOutputFixture()
        try await fixture.responseStarted()
        try await fixture.output.forward(.output("hello "))
        try await fixture.output.forward(.output("world"))
        try await fixture.responseCompleted(stopSequence: "<done>")
        try await fixture.finish()

        let lines = try fixture.lines()
        #expect(lines.compactMap { $0["type"] as? String } == ["system", "assistant", "result"])
        let initial = try #require(lines.first)
        #expect(initial["subtype"] as? String == "init")
        #expect(initial["session_id"] as? String == "native-session")
        #expect(initial["apiKeySource"] as? String == "oauth")
        #expect(initial["permissionMode"] as? String == "acceptEdits")
        #expect(initial["cwd"] as? String == "/tmp/native-workspace")
        #expect(initial["tools"] as? [String] == ["read_file", "write_file"])
        #expect(initial["slash_commands"] as? [String] == ["help", "compact"])
        #expect(initial["skills"] as? [String] == ["review"])

        let assistant = try #require(lines[1]["message"] as? [String: Any])
        #expect(assistant["id"] as? String == "msg_provider_123")
        #expect(assistant["role"] as? String == "assistant")
        #expect(assistant["model"] as? String == "claude-native")
        #expect(assistant["stop_reason"] as? String == "end_turn")
        #expect(assistant["stop_sequence"] as? String == "<done>")
        let content = try #require(assistant["content"] as? [[String: Any]])
        #expect(content.count == 1)
        #expect(content[0]["text"] as? String == "hello world")
        let assistantUsage = try #require(assistant["usage"] as? [String: Any])
        #expect(assistantUsage["input_tokens"] as? UInt64 == 120)
        #expect(assistantUsage["output_tokens"] as? UInt64 == 17)
        #expect(assistantUsage["cache_read_input_tokens"] as? UInt64 == 40)
        #expect(assistantUsage["cache_creation_input_tokens"] as? UInt64 == 12)

        let result = try #require(lines.last)
        #expect(result["subtype"] as? String == "success")
        #expect(result["is_error"] as? Bool == false)
        #expect(result["result"] as? String == "hello world")
        #expect(result["num_turns"] as? Int == 1)
        let resultUsage = try #require(result["usage"] as? [String: Any])
        #expect(resultUsage["cache_creation_input_tokens"] as? UInt64 == 12)
        let modelUsage = try #require(result["modelUsage"] as? [String: Any])
        let model = try #require(modelUsage["claude-native"] as? [String: Any])
        #expect(model["cacheCreationInputTokens"] as? UInt64 == 12)
        #expect(fixture.stderr.contents.isEmpty)
    }

    @Test("partial framing preserves provider identity, block order, signature, and raw stop sequence")
    func orderedPartialFramesAndSignature() async throws {
        let fixture = NativeMessagesOutputFixture(includePartialMessages: true)
        try await fixture.responseStarted()
        try await fixture.output.forward(.reasoning("consider"))
        try await fixture.output.forward(.reasoning(" carefully"))
        try await fixture.output.forward(.reasoningCompleted(signature: "sig_real_provider"))
        try await fixture.output.forward(.output("answer"))
        try await fixture.responseCompleted(stopSequence: "\nHuman:")
        try await fixture.finish()

        let lines = try fixture.lines()
        let partials = lines.filter { $0["type"] as? String == "stream_event" }
        let events = try partials.map {
            try #require($0["event"] as? [String: Any])
        }
        #expect(events.compactMap { $0["type"] as? String } == [
            "message_start",
            "content_block_start",
            "content_block_delta",
            "content_block_delta",
            "content_block_delta",
            "content_block_stop",
            "content_block_start",
            "content_block_delta",
            "content_block_stop",
            "message_delta",
            "message_stop",
        ])
        let start = try #require(events[0]["message"] as? [String: Any])
        #expect(start["id"] as? String == "msg_provider_123")
        #expect(start["model"] as? String == "claude-native")
        let startingUsage = try #require(start["usage"] as? [String: Any])
        #expect(startingUsage["input_tokens"] as? UInt64 == 120)
        #expect(startingUsage["output_tokens"] as? UInt64 == 0)
        #expect(startingUsage["cache_read_input_tokens"] as? UInt64 == 40)
        #expect(startingUsage["cache_creation_input_tokens"] as? UInt64 == 12)

        let signature = try #require(events[4]["delta"] as? [String: Any])
        #expect(signature["type"] as? String == "signature_delta")
        #expect(signature["signature"] as? String == "sig_real_provider")
        #expect(events[5]["index"] as? Int == 0)
        #expect(events[6]["index"] as? Int == 1)
        let finalDelta = try #require(events[9]["delta"] as? [String: Any])
        #expect(finalDelta["stop_reason"] as? String == "end_turn")
        #expect(finalDelta["stop_sequence"] as? String == "\nHuman:")
        let finalUsage = try #require(events[9]["usage"] as? [String: Any])
        #expect(finalUsage["output_tokens"] as? UInt64 == 17)

        let assistant = try #require(lines.first { $0["type"] as? String == "assistant" })
        let message = try #require(assistant["message"] as? [String: Any])
        let blocks = try #require(message["content"] as? [[String: Any]])
        #expect(blocks.map { $0["type"] as? String } == ["thinking", "text"])
        #expect(blocks[0]["thinking"] as? String == "consider carefully")
        #expect(blocks[0]["signature"] as? String == "sig_real_provider")
        #expect(blocks[1]["text"] as? String == "answer")
        #expect(partials.allSatisfy { $0["session_id"] as? String == "native-session" })
    }

    @Test("tool argument deltas and repeated progress never duplicate tool-use blocks")
    func toolProgressDoesNotDuplicateCalls() async throws {
        let fixture = NativeMessagesOutputFixture(includePartialMessages: true)
        try await fixture.responseStarted()
        try await fixture.output.forward(.toolCallDelta(
            toolIndex: 0,
            id: "call_a",
            name: "read_file",
            argumentsDelta: #"{"path":"#
        ))
        let running = OpenGrokPagerToolUpdate(
            callID: "call_a",
            name: "read_file",
            input: #"{"path":"notes.md"}"#,
            state: .running
        )
        try await fixture.output.forward(.tool(running))
        try await fixture.output.forward(.tool(running))
        try await fixture.output.forward(.tool(OpenGrokPagerToolUpdate(
            callID: "call_a",
            name: "read_file",
            input: running.input,
            output: "file body",
            state: .succeeded
        )))
        try await fixture.output.forward(.tool(OpenGrokPagerToolUpdate(
            callID: "call_a",
            name: "read_file",
            input: running.input,
            output: "duplicate completion",
            state: .succeeded
        )))
        try await fixture.finish()

        let lines = try fixture.lines()
        let assistants = lines.filter { $0["type"] as? String == "assistant" }
        #expect(assistants.count == 1)
        let message = try #require(assistants[0]["message"] as? [String: Any])
        let blocks = try #require(message["content"] as? [[String: Any]])
        #expect(blocks.count == 1)
        #expect(blocks[0]["type"] as? String == "tool_use")
        let input = try #require(blocks[0]["input"] as? [String: Any])
        #expect(input["path"] as? String == "notes.md")

        let users = lines.filter { $0["type"] as? String == "user" }
        #expect(users.count == 1)
        let user = try #require(users[0]["message"] as? [String: Any])
        let results = try #require(user["content"] as? [[String: Any]])
        #expect(results.count == 1)
        #expect(results[0]["tool_use_id"] as? String == "call_a")
        #expect(results[0]["content"] as? String == "file body")
        #expect(results[0]["is_error"] as? Bool == false)
    }

    @Test("multiple client results are grouped in original tool-use order")
    func toolResultsGroupAndKeepInvocationOrder() async throws {
        let fixture = NativeMessagesOutputFixture()
        for identifier in ["call_first", "call_second"] {
            try await fixture.output.forward(.tool(OpenGrokPagerToolUpdate(
                callID: identifier,
                name: "read_file",
                input: #"{"path":"file"}"#,
                state: .running
            )))
        }
        for identifier in ["call_second", "call_first"] {
            try await fixture.output.forward(.tool(OpenGrokPagerToolUpdate(
                callID: identifier,
                name: "read_file",
                input: "{}",
                output: identifier,
                state: .succeeded
            )))
        }
        try await fixture.finish()

        let user = try #require(try fixture.lines().first { $0["type"] as? String == "user" })
        let message = try #require(user["message"] as? [String: Any])
        let content = try #require(message["content"] as? [[String: Any]])
        #expect(content.compactMap { $0["tool_use_id"] as? String } == [
            "call_first", "call_second",
        ])
    }

    @Test("backend web searches remain adjacent server blocks inside the assistant frame")
    func webSearchFoldsIntoAssistantFrame() async throws {
        let fixture = NativeMessagesOutputFixture(includePartialMessages: true)
        try await fixture.output.forward(.output("before "))
        try await fixture.output.forward(.tool(OpenGrokPagerToolUpdate(
            callID: "search_1",
            name: "web_search",
            input: "{}",
            state: .running
        )))
        try await fixture.output.forward(.tool(OpenGrokPagerToolUpdate(
            callID: "search_1",
            name: "web_search",
            input: "{}",
            output: #"{"action":{"query":"swift","sources":[{"url":"https://swift.org","title":"Swift"}]}}"#,
            state: .succeeded
        )))
        try await fixture.output.forward(.output("after"))
        try await fixture.finish()

        let lines = try fixture.lines()
        let assistant = try #require(lines.first { $0["type"] as? String == "assistant" })
        let message = try #require(assistant["message"] as? [String: Any])
        let content = try #require(message["content"] as? [[String: Any]])
        #expect(content.compactMap { $0["type"] as? String } == [
            "text", "server_tool_use", "web_search_tool_result", "text",
        ])
        #expect(content[1]["name"] as? String == "web_search")
        let searchInput = try #require(content[1]["input"] as? [String: Any])
        #expect(searchInput["query"] as? String == "swift")
        let hits = try #require(content[2]["content"] as? [[String: Any]])
        #expect(hits[0]["url"] as? String == "https://swift.org")
        let result = try #require(lines.last)
        let usage = try #require(result["usage"] as? [String: Any])
        let serverToolUsage = try #require(usage["server_tool_use"] as? [String: Any])
        #expect(serverToolUsage["web_search_requests"] as? UInt64 == 1)
        #expect(lines.allSatisfy { $0["type"] as? String != "user" })
    }

    @Test("sampling failures emit exactly one typed error result and nullable assistant stop")
    func failureHasNativeTerminalEnvelope() async throws {
        let fixture = NativeMessagesOutputFixture(includePartialMessages: true)
        try await fixture.responseStarted()
        try await fixture.output.forward(.output("partial answer"))
        try await fixture.output.forward(.samplingFailed(
            kind: "auth",
            message: "expired credential",
            isRetryable: false,
            statusCode: 401
        ))
        try await fixture.output.forward(.cancelled)

        let lines = try fixture.lines()
        let assistant = try #require(lines.first { $0["type"] as? String == "assistant" })
        let message = try #require(assistant["message"] as? [String: Any])
        #expect(message["stop_reason"] is NSNull)
        let results = lines.filter { $0["type"] as? String == "result" }
        #expect(results.count == 1)
        #expect(results[0]["subtype"] as? String == "error_during_execution")
        #expect(results[0]["is_error"] as? Bool == true)
        #expect(results[0]["errors"] as? [String] == ["expired credential"])
        #expect(results[0]["result"] == nil)
        #expect(results[0]["stop_reason"] is NSNull)
    }

    @Test("missing usage leaves modelUsage empty instead of fabricating a billed call")
    func absentUsageDoesNotInventModelBilling() async throws {
        let fixture = NativeMessagesOutputFixture()
        try await fixture.output.forward(.output("unmetered"))
        try await fixture.finish()

        let result = try #require(try fixture.lines().last)
        let modelUsage = try #require(result["modelUsage"] as? [String: Any])
        #expect(modelUsage.isEmpty)
        let usage = try #require(result["usage"] as? [String: Any])
        #expect(usage["input_tokens"] as? UInt64 == 0)
        #expect(usage["cache_creation_input_tokens"] as? UInt64 == 0)
    }

    @Test("partial stream events never appear unless explicitly enabled")
    func partialFlagStrictlyGatesStreamEvents() async throws {
        let fixture = NativeMessagesOutputFixture()
        try await fixture.responseStarted()
        try await fixture.output.forward(.reasoning("private thought"))
        try await fixture.output.forward(.reasoningCompleted(signature: "sig"))
        try await fixture.output.forward(.output("visible"))
        try await fixture.responseCompleted()
        try await fixture.finish()

        let lines = try fixture.lines()
        #expect(lines.allSatisfy { $0["type"] as? String != "stream_event" })
        let assistant = try #require(lines.first { $0["type"] as? String == "assistant" })
        let message = try #require(assistant["message"] as? [String: Any])
        let blocks = try #require(message["content"] as? [[String: Any]])
        #expect(blocks.map { $0["type"] as? String } == ["thinking", "text"])
    }

    @Test("plain and generic streaming-json retain their preexisting output contracts")
    func existingFormatsRemainUnchanged() async throws {
        let plain = CLIStreams.buffered()
        let plainOutput = LivePagerOutput(streams: plain.streams, format: .plain)
        try await plainOutput.forward(.output("unchanged"))
        try await plainOutput.forward(.completed(OpenGrokPagerMinimalCompletion()))
        #expect(plain.out.contents == "unchanged\n")

        let streaming = CLIStreams.buffered()
        let streamingOutput = LivePagerOutput(streams: streaming.streams, format: .streamingJSON)
        try await streamingOutput.forward(.output("chunk"))
        let line = try #require(
            JSONSerialization.jsonObject(with: Data(streaming.out.contents.utf8))
                as? [String: Any]
        )
        #expect(line["type"] as? String == "output")
        #expect(line["content"] as? String == "chunk")
    }

    @Test("actual headless CLI routes provider lifecycle and cache metadata to native partial frames")
    func liveHeadlessSessionUsesNativeWire() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-native-messages-\(UUID().uuidString)",
            isDirectory: true
        )
        let home = root.appendingPathComponent("home", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let server = try MockInferenceServer()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: root)
        }
        try """
        [endpoints]
        xai_api_base_url = "\(server.url)"
        """.write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
            "XAI_API_KEY": "native-test-key",
        ]
        let captured = CLIStreams.buffered()
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { _, emit in
                    await emit(.responseStarted(
                        messageID: "msg_actual_provider",
                        model: "grok-4.5",
                        inputTokens: 210,
                        cacheReadInputTokens: 70,
                        cacheCreationInputTokens: 25
                    ))
                    await emit(.reasoning("inspect"))
                    await emit(.reasoningCompleted(signature: "signature-live"))
                    await emit(.output("live answer"))
                    return OpenGrokLiveSamplingResponse(
                        output: "live answer",
                        stopReason: "end_turn",
                        usage: TokenUsage(
                            promptTokens: 210,
                            completionTokens: 19,
                            totalTokens: 229,
                            cachedPromptTokens: 70,
                            cacheCreationPromptTokens: 25
                        ),
                        messageID: "msg_actual_provider",
                        rawStopReason: "end_turn",
                        stopSequence: "<provider-stop>"
                    )
                }
            }
        )
        let command = try CLICommandParser.parseOrThrow([
            "headless",
            "--prompt", "prove native output",
            "--cwd", workspace.path,
            "--model", "grok-4.5",
            "--output-format", "streaming-messages-json",
            "--include-partial-messages",
        ])
        let context = CLIApplicationContext(
            environment: environment,
            streams: captured.streams,
            control: .never
        )
        let session = try await OpenGrokLiveApplicationLauncher(dependencies: dependencies)
            .launcher.start(command, context)
        try await session.waitForExit()
        await session.shutdown()

        let lines = try captured.out.contents.split(whereSeparator: \.isNewline).map { line in
            try #require(
                JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            )
        }
        #expect(lines.first?["type"] as? String == "system")
        #expect(lines.last?["type"] as? String == "result")
        let start = try #require(lines.first { line in
            (line["event"] as? [String: Any])?["type"] as? String == "message_start"
        })
        let startEvent = try #require(start["event"] as? [String: Any])
        let providerMessage = try #require(startEvent["message"] as? [String: Any])
        #expect(providerMessage["id"] as? String == "msg_actual_provider")
        #expect(providerMessage["model"] as? String == "grok-4.5")
        let initialUsage = try #require(providerMessage["usage"] as? [String: Any])
        #expect(initialUsage["cache_creation_input_tokens"] as? UInt64 == 25)

        let signatureEvent = try #require(lines.first { line in
            let event = line["event"] as? [String: Any]
            return (event?["delta"] as? [String: Any])?["type"] as? String
                == "signature_delta"
        })
        let event = try #require(signatureEvent["event"] as? [String: Any])
        let delta = try #require(event["delta"] as? [String: Any])
        #expect(delta["signature"] as? String == "signature-live")

        let assistant = try #require(lines.first { $0["type"] as? String == "assistant" })
        let message = try #require(assistant["message"] as? [String: Any])
        #expect(message["id"] as? String == "msg_actual_provider")
        #expect(message["stop_sequence"] as? String == "<provider-stop>")
        let usage = try #require(message["usage"] as? [String: Any])
        #expect(usage["output_tokens"] as? UInt64 == 19)
        #expect(usage["cache_read_input_tokens"] as? UInt64 == 70)
        #expect(usage["cache_creation_input_tokens"] as? UInt64 == 25)
    }
}
