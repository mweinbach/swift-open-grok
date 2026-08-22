import Foundation
@testable import OpenGrokCLI
import OpenGrokCodeModeProtocol
import OpenGrokHTTP
import OpenGrokPager
import OpenGrokPagerMinimal
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import Testing

private final class CodeModePrivacySink: PagerTerminalSink, @unchecked Sendable {
    var capabilities: PagerTerminalCapabilities { .standard }
    func write(bytes: [UInt8]) throws {}
    func flush() throws {}
}

@Suite("Code Mode streamed transport privacy parity")
struct LiveCodeModeStreamingPrivacyParityTests {
    @Test("Outer exec arguments become bounded sanitized nested previews")
    func execArgumentsNeverEnterCardsOrTranscript() {
        var conversation = LivePagerConversationState(codeModeActive: true)
        conversation.startTurn(prompt: "hello")
        let secret = "sk-never-paint-this-secret"

        let activity = conversation.applyToolCallDelta(
            toolIndex: 0,
            id: "outer-exec",
            name: "exec",
            argumentsDelta: #"{"source":"await tools.read_file({token:'sk-never-paint-this-secret'})"}"#
        )

        #expect(activity == "read_file")
        #expect(conversation.testingToolCard(callID: "outer-exec") == nil)
        #expect(conversation.transcript.contains("read_file"))
        #expect(!conversation.transcript.contains("Tool exec"))
        #expect(!conversation.transcript.contains(secret))
        #expect(!conversation.transcript.contains("await tools"))
    }

    @Test("Nameless continuation fragments retain stream identity without exposing source")
    func namelessContinuationRemainsTransport() {
        var conversation = LivePagerConversationState(codeModeActive: true)
        let first = conversation.applyToolCallDelta(
            toolIndex: 4,
            id: "outer-exec",
            name: "exec",
            argumentsDelta: "tools.search"
        )
        let next = conversation.applyToolCallDelta(
            toolIndex: 4,
            id: nil,
            name: nil,
            argumentsDelta: "_files({token:'secret-value'})"
        )

        #expect(first == nil)
        #expect(next == "search_files")
        #expect(!conversation.transcript.contains("secret-value"))
        #expect(!conversation.transcript.contains("exec"))
    }

    @Test("Outer wait never creates a visible tool card")
    func waitPayloadRemainsInvisible() {
        var conversation = LivePagerConversationState(codeModeActive: true)
        let activity = conversation.applyToolCallDelta(
            toolIndex: 0,
            id: "outer-wait",
            name: "wait",
            argumentsDelta: #"{"cell_id":"private-cell-secret"}"#
        )

        #expect(activity == nil)
        #expect(conversation.items.isEmpty)
        #expect(!conversation.transcript.contains("private-cell-secret"))
    }

    @Test("Genuine plugin tools named exec and wait stay visible outside Code Mode")
    func directPluginNamesRemainVisible() {
        var conversation = LivePagerConversationState(codeModeActive: false)
        let exec = conversation.applyToolCallDelta(
            toolIndex: 0,
            id: "plugin-exec",
            name: "exec",
            argumentsDelta: #"{"command":"plugin-visible"}"#
        )
        let wait = conversation.applyToolCallDelta(
            toolIndex: 1,
            id: "plugin-wait",
            name: "wait",
            argumentsDelta: #"{"job":"plugin-job"}"#
        )

        #expect(exec == "exec")
        #expect(wait == "wait")
        #expect(conversation.testingToolCard(callID: "plugin-exec")?.name == "exec")
        #expect(conversation.testingToolCard(callID: "plugin-wait")?.name == "wait")
    }

    @Test("Canonical nested dispatch retires ephemeral sanitized previews")
    func canonicalToolReplacesPreview() {
        var conversation = LivePagerConversationState(codeModeActive: true)
        let activity = conversation.applyToolCallDelta(
            toolIndex: 0,
            id: "outer-exec",
            name: "exec",
            argumentsDelta: "tools.read_file({})"
        )
        #expect(activity == "read_file")

        conversation.apply(OpenGrokPagerToolUpdate(
            callID: "nested-call",
            name: "read_file",
            input: #"{"path":"safe.swift"}"#,
            state: .running
        ))

        let tools = conversation.items.compactMap { item -> String? in
            guard case .tool(let card) = item else { return nil }
            return card.name
        }
        #expect(tools == ["read_file"])
        #expect(conversation.testingToolCard(callID: "nested-call") != nil)
    }

    @Test("Durable exact transport IDs hide replay and linked output without hiding plugins")
    func replayFiltersExactTransportIdentifiers() {
        let items: [ConversationItem] = [
            .assistant(AssistantItem(content: "", toolCalls: [
                ToolCall(id: "transport", name: "exec", arguments: "super-secret-source"),
                ToolCall(id: "plugin", name: "exec", arguments: "visible-plugin"),
            ])),
            .customToolOutput(.text(callId: "transport", "super-secret-output")),
            .customToolOutput(.text(callId: "plugin", "visible-plugin-output")),
        ]
        var conversation = LivePagerConversationState(codeModeActive: false)
        conversation.seed(from: items, hiddenTransportCallIDs: ["transport"])

        #expect(conversation.testingToolCard(callID: "transport") == nil)
        #expect(conversation.testingToolCard(callID: "plugin")?.name == "exec")
        #expect(!conversation.transcript.contains("super-secret"))
        #expect(conversation.transcript.contains("visible-plugin-output"))
    }

    @Test("Production controller activity uses sanitized nested names, never outer exec")
    func controllerActivityHidesTransportName() async {
        let renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 80, height: 24) },
                write: { _ in }
            ),
            sink: CodeModePrivacySink(),
            workingDirectory: "/tmp",
            environment: [:],
            codeModeActive: true
        )
        await renderer.apply(.toolCallDelta(
            toolIndex: 0,
            id: "outer-exec",
            name: "exec",
            argumentsDelta: "tools.search_files({token:'never-visible'})"
        ))

        let activity = await renderer.turnActivity
        let transcript = await renderer.transcript
        #expect(activity?.contains("search_files") == true)
        #expect(activity?.contains("exec") == false)
        #expect(!transcript.contains("never-visible"))
    }

    @Test("Typed nested progress stays visible without duplicating bash chunks")
    func nestedTypedProgressProjection() {
        let readChunk = NestedToolProgress.withPayload("", .object([
            "subkind": .string("read_file_chunk"),
            "payload": .object(["delta": .string("visible file bytes")]),
        ]))
        let content = NestedToolProgress.withPayload("", .object([
            "blocks": .array([
                .object(["type": .string("text"), "text": .string("first")]),
                .object(["type": .string("text"), "text": .string(" second")]),
            ]),
        ]))
        let bashChunk = NestedToolProgress.withPayload("", .object([
            "subkind": .string("bash_output_chunk"),
            "payload": .object(["delta": .string("already delivered")]),
        ]))

        #expect(LiveCodeModeNestedExecutor.visibleNestedProgressOutput(.text("plain")) == "plain")
        #expect(LiveCodeModeNestedExecutor.visibleNestedProgressOutput(readChunk) == "visible file bytes")
        #expect(LiveCodeModeNestedExecutor.visibleNestedProgressOutput(content) == "first second")
        #expect(LiveCodeModeNestedExecutor.visibleNestedProgressOutput(bashChunk) == nil)
        #expect(readChunk.text.isEmpty)
        #expect(readChunk.payload?["payload"]?["delta"]?.stringValue == "visible file bytes")
    }

    @Test("Production sampler resolves defaults and overrides without leaking xAI fields")
    func productionSamplerProviderLocalStreamingPolicy() async throws {
        let scenarios: [(ModelProvider, [String: String], Bool?, Bool)] = [
            (.xai, [:], nil, true),
            (.xai, ["GROK_STREAM_TOOL_CALLS": "false"], nil, false),
            (.xai, ["GROK_STREAM_TOOL_CALLS": "false"], true, true),
            (.codex, [:], true, false),
        ]
        let event = #"{"type":"response.completed","response":{"id":"response-1","model":"test-model","status":"completed","output":[{"type":"message","role":"assistant","content":"ok"}],"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}}"#

        for (provider, environment, override, expected) in scenarios {
            let transport = MockHTTPTransport(responses: [
                .init(
                    metadata: HTTPResponseMetadata(
                        statusCode: 200,
                        headers: ["Content-Type": "text/event-stream"]
                    ),
                    body: Data("data: \(event)\n\n".utf8)
                ),
            ])
            let sampler = try OpenGrokLiveSampler.production(
                configuration: OpenGrokLiveSamplingConfiguration(
                    model: "test-model",
                    baseURL: "https://provider.example.test",
                    apiKey: "test-key",
                    provider: provider,
                    apiBackend: .responses,
                    environment: environment,
                    tuning: OpenGrokLiveSamplingTuning(streamToolCalls: override),
                    transport: transport
                )
            )
            let response = try await sampler.sample(
                OpenGrokLiveSamplingRequest(
                    sessionID: "stream-policy-session",
                    turnID: "stream-policy-turn",
                    model: "test-model",
                    prompt: "hello"
                ),
                emit: { _ in }
            )
            #expect(response.output == "ok")
            let request = try #require(transport.recordedRequests.first)
            let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
            #expect(body["stream_tool_calls"] == (expected ? .bool(true) : nil))
        }
    }
}
