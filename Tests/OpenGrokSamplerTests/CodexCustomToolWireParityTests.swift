import Foundation
@testable import OpenGrokSampler
import OpenGrokSamplingTypes
import OpenGrokShared
import Testing

@Suite("Codex native custom Code Mode Responses wire parity")
struct CodexCustomToolWireParityTests {
    private func project(_ request: ConversationRequest, provider: ModelProvider) -> JSONValue {
        projectResponsesRequestBody(
            request,
            model: "test-model",
            policy: ResponsesRequestPolicy(),
            adapter: providerAdapter(provider)
        )
    }

    @Test("Codex advertises native custom exec with its exact Lark source grammar")
    func codexNativeGrammarAndOrdinaryFunctionsCoexist() throws {
        let request = ConversationRequest(
            tools: [ToolSpec(
                name: "read_file",
                description: "Read a file",
                parameters: .object(["type": .string("object")])
            )],
            hostedTools: [.clientCustom(CustomToolSpec(
                name: "exec",
                description: "Accepts raw JavaScript source text, not JSON.",
                format: .grammar
            ))],
            toolChoice: .custom("exec")
        )

        let wire = project(request, provider: .codex)
        let tools = try #require(wire["tools"]?.arrayValue)
        #expect(tools.count == 2)
        #expect(tools[0]["type"] == .string("function"))
        #expect(tools[0]["name"] == .string("read_file"))
        #expect(tools[1]["type"] == .string("custom"))
        #expect(tools[1]["name"] == .string("exec"))
        #expect(tools[1]["parameters"] == nil)
        #expect(tools[1]["format"]?["type"] == .string("grammar"))
        #expect(tools[1]["format"]?["syntax"] == .string("lark"))
        #expect(tools[1]["format"]?["definition"] == .string(CODEX_CODE_MODE_FREEFORM_GRAMMAR))
        #expect(CODEX_CODE_MODE_FREEFORM_GRAMMAR.contains(#"PRAGMA_LINE: /[ \t]*\/\/ @exec:[^\r\n]*/"#))
        #expect(CODEX_CODE_MODE_FREEFORM_GRAMMAR.contains(#"SOURCE: /[\s\S]+/"#))
        #expect(wire["tool_choice"]?["type"] == .string("custom"))
    }

    @Test("non-grammar native custom tools retain the Responses text format")
    func textCustomToolRetainsNativeTextFormat() throws {
        let request = ConversationRequest(hostedTools: [.clientCustom(CustomToolSpec(
            name: "code",
            description: "Custom input",
            format: .string
        ))])
        let tool = try #require(project(request, provider: .codex)["tools"]?.arrayValue?.first)

        #expect(tool["type"] == .string("custom"))
        #expect(tool["format"] == .object(["type": .string("text")]))
    }

    @Test("Codex replays raw calls and ordered native output without losing identity or images")
    func codexReplaysNativeCallAndRichOutput() throws {
        let source = "const answer = 40 + 2;\ntext(answer);"
        let call = ToolCall.custom(callId: "call-exec", itemId: "ctc-exec", name: "exec", input: source)
        let output = CustomToolOutputItem(
            callId: "call-exec",
            itemId: "out-exec",
            name: "exec",
            content: [
                .text(text: "before"),
                .image(url: "data:image/png;base64,SAFE", detail: .original),
                .text(text: "after"),
            ]
        )
        let request = ConversationRequest(items: [
            .assistant(AssistantItem(content: "", toolCalls: [call])),
            .customToolOutput(output),
        ])

        let input = try #require(project(request, provider: .codex)["input"]?.arrayValue)
        let nativeCall = try #require(input.first { $0["type"] == .string("custom_tool_call") })
        let nativeOutput = try #require(input.first { $0["type"] == .string("custom_tool_call_output") })

        #expect(nativeCall["call_id"] == .string("call-exec"))
        #expect(nativeCall["id"] == .string("ctc-exec"))
        #expect(nativeCall["input"] == .string(source))
        #expect(nativeOutput["call_id"] == .string("call-exec"))
        #expect(nativeOutput["id"] == .string("out-exec"))
        #expect(nativeOutput["name"] == .string("exec"))
        #expect(nativeOutput["output"]?[0]?["text"] == .string("before"))
        #expect(nativeOutput["output"]?[1]?["image_url"] == .string("data:image/png;base64,SAFE"))
        #expect(nativeOutput["output"]?[1]?["detail"] == .string("original"))
        #expect(nativeOutput["output"]?[2]?["text"] == .string("after"))
    }

    @Test("xAI converts Codex-native declarations, calls, and repeated outputs to function transport")
    func xaiNeverReceivesCodexNativeWireShapes() throws {
        let source = "const answer = 40 + 2;\ntext(answer);"
        let call = ToolCall.custom(callId: "call-exec", itemId: "ctc-private", name: "exec", input: source)
        let request = ConversationRequest(
            items: [
                .assistant(AssistantItem(content: "", toolCalls: [call])),
                .customToolOutput(CustomToolOutputItem(
                    callId: "call-exec",
                    name: "exec",
                    content: [.text(text: "progress")]
                )),
                .customToolOutput(CustomToolOutputItem(
                    callId: "call-exec",
                    name: "exec",
                    content: [.text(text: "42")]
                )),
            ],
            hostedTools: [.clientCustom(CustomToolSpec(
                name: "exec",
                description: "- Accepts raw JavaScript source text, not JSON, quoted strings, or markdown code fences.",
                format: .grammar
            ))],
            toolChoice: .custom("exec")
        )

        let wire = project(request, provider: .xai)
        let tools = try #require(wire["tools"]?.arrayValue)
        let exec = try #require(tools.first { $0["name"] == .string("exec") })
        #expect(exec["type"] == .string("function"))
        #expect(exec["parameters"]?["required"] == .array([.string("source")]))
        #expect(exec["description"]?.stringValue?.contains("Accepts raw JavaScript source text") == false)
        #expect(wire["tool_choice"]?["type"] == .string("function"))

        let input = try #require(wire["input"]?.arrayValue)
        #expect(!input.contains { item in
            item["type"] == .string("custom_tool_call")
                || item["type"] == .string("custom_tool_call_output")
        })
        let functionCall = try #require(input.first { $0["type"] == .string("function_call") })
        #expect(functionCall["call_id"] == .string("call-exec"))
        #expect(functionCall["id"] == nil)
        let arguments = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(try #require(functionCall["arguments"]?.stringValue).utf8)
        )
        #expect(arguments["source"] == .string(source))

        let outputs = input.filter { $0["type"] == .string("function_call_output") }
        #expect(outputs.count == 1)
        #expect(outputs[0]["output"]?[0]?["text"] == .string("progress"))
        #expect(outputs[0]["output"]?[1]?["text"] == .string("42"))
    }
}
