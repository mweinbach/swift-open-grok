import Foundation
import OpenGrokHTTP
@testable import OpenGrokSampler
import OpenGrokSamplingTypes
import OpenGrokShared
import Testing

@Suite("Codex provider-local image preparation parity")
struct CodexImagePreparationParityTests {
    private let validImage = "data:image/png;base64,"
        + "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/"
        + "iZk9HQAAAABJRU5ErkJggg=="

    private func requestBody(
        _ request: ConversationRequest,
        provider: ModelProvider = .codex
    ) async throws -> JSONValue {
        let transport = MockHTTPTransport(responses: [
            .init(metadata: HTTPResponseMetadata(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"]
            )),
        ])
        let client = try SamplingClient(
            config: SamplerConfig(
                baseURL: "https://provider.example.test",
                model: "test-model",
                apiBackend: .responses,
                provider: provider
            ),
            transport: transport
        )

        let (_, _, _, _) = try await client.conversationStreamResponses(request)
        #expect(transport.recordedRequests.count == 1)
        let recorded = try #require(transport.recordedRequests.first)
        return try JSONDecoder().decode(JSONValue.self, from: try #require(recorded.body))
    }

    private func input(_ body: JSONValue, type: String, callID: String? = nil) throws -> JSONValue {
        let input = try #require(body["input"]?.arrayValue)
        return try #require(input.first { item in
            item["type"]?.stringValue == type
                && (callID == nil || item["call_id"]?.stringValue == callID)
        })
    }

    @Test("Codex replaces malformed, unpadded, non-image, and remote user images on the actual wire")
    func unsendableUserImagesBecomeExactPlaceholders() async throws {
        let request = ConversationRequest(items: [
            .userWithParts([
                .text(text: "before"),
                .image(url: "data:image/png;base64,%%%"),
                .image(url: "data:image/png;base64,AAA"),
                .image(url: "data:text/plain;base64,SGVsbG8="),
                .image(url: "data:image/png,SGVsbG8="),
                .image(url: "HTTPS://example.test/remote.png"),
                .image(url: "data:image/png;base64,QU JD"),
                .text(text: "after"),
            ]),
        ])

        let body = try await requestBody(request)
        let message = try input(body, type: "message")
        let content = try #require(message["content"]?.arrayValue)
        #expect(content.map { $0["text"]?.stringValue } == [
            "before",
            CODEX_IMAGE_PROCESSING_ERROR_PLACEHOLDER,
            CODEX_IMAGE_PROCESSING_ERROR_PLACEHOLDER,
            CODEX_IMAGE_PROCESSING_ERROR_PLACEHOLDER,
            CODEX_IMAGE_PROCESSING_ERROR_PLACEHOLDER,
            CODEX_REMOTE_IMAGE_URL_PLACEHOLDER,
            CODEX_IMAGE_PROCESSING_ERROR_PLACEHOLDER,
            "after",
        ])
        #expect(content.allSatisfy { $0["type"] == .string("input_text") })
        guard case .user(let original) = request.items[0],
              case .image = original.content[1]
        else {
            Issue.record("preparation must not mutate the caller's conversation")
            return
        }
    }

    @Test("Codex retains valid padded images and supported detail without changing order")
    func validImagesRemainOnTheActualWire() async throws {
        let request = ConversationRequest(items: [
            .userWithParts([
                .text(text: "user image"),
                .image(url: validImage),
                .image(url: "DATA:IMAGE/PNG;BASE64,AA=="),
                .image(url: "data:image/png;charset=UTF-8;BaSe64,AA=="),
            ]),
            .toolResult(ToolResultItem(
                toolCallId: "function-call",
                content: "",
                orderedContent: [
                    .image(url: validImage, detail: .high),
                    .image(url: validImage, detail: .auto),
                ]
            )),
            .customToolOutput(CustomToolOutputItem(
                callId: "custom-call",
                content: [
                    .text(text: "before"),
                    .image(url: validImage, detail: .original),
                    .text(text: "after"),
                ]
            )),
        ])

        let body = try await requestBody(request)
        let userContent = try #require(input(body, type: "message")["content"]?.arrayValue)
        #expect(userContent[1]["image_url"] == .string(validImage))
        #expect(userContent[2]["image_url"] == .string("DATA:IMAGE/PNG;BASE64,AA=="))
        #expect(userContent[3]["image_url"] == .string("data:image/png;charset=UTF-8;BaSe64,AA=="))

        let functionOutput = try #require(
            input(body, type: "function_call_output", callID: "function-call")["output"]?.arrayValue
        )
        #expect(functionOutput.map { $0["detail"]?.stringValue } == ["high", "auto"])
        #expect(functionOutput.allSatisfy { $0["image_url"] == .string(validImage) })

        let customOutput = try #require(
            input(body, type: "custom_tool_call_output", callID: "custom-call")["output"]?.arrayValue
        )
        #expect(customOutput[0]["text"] == .string("before"))
        #expect(customOutput[1]["image_url"] == .string(validImage))
        #expect(customOutput[1]["detail"] == .string("original"))
        #expect(customOutput[2]["text"] == .string("after"))
    }

    @Test("ordered function and native custom outputs retain their exact replacement positions")
    func orderedToolOutputImagesRemainOrdered() async throws {
        let request = ConversationRequest(items: [
            .toolResult(ToolResultItem(
                toolCallId: "function-call",
                content: "ignored when ordered content exists",
                orderedContent: [
                    .text(text: "before"),
                    .image(url: "data:image/png;base64,%%%", detail: .high),
                    .image(url: "data:image/png;base64,AAA", detail: .original),
                    .image(url: validImage, detail: .low),
                    .image(url: "https://example.test/image.png", detail: .low),
                    .image(url: validImage, detail: .high),
                    .text(text: "after"),
                ]
            )),
            .customToolOutput(CustomToolOutputItem(
                callId: "custom-call",
                content: [
                    .text(text: "first"),
                    .image(url: "http://example.test/image.png", detail: .original),
                    .image(url: validImage, detail: .low),
                    .image(url: "data:text/plain;base64,SGVsbG8=", detail: .high),
                    .text(text: "last"),
                ]
            )),
        ])

        let body = try await requestBody(request)
        let functionOutput = try #require(
            input(body, type: "function_call_output", callID: "function-call")["output"]?.arrayValue
        )
        #expect(functionOutput[0]["text"] == .string("before"))
        #expect(functionOutput[1]["text"] == .string(CODEX_IMAGE_PROCESSING_ERROR_PLACEHOLDER))
        #expect(functionOutput[2]["text"] == .string(CODEX_IMAGE_PROCESSING_ERROR_PLACEHOLDER))
        #expect(functionOutput[3]["text"] == .string(CODEX_UNSUPPORTED_LOW_DETAIL_PLACEHOLDER))
        #expect(functionOutput[4]["text"] == .string(CODEX_REMOTE_IMAGE_URL_PLACEHOLDER))
        #expect(functionOutput[5]["image_url"] == .string(validImage))
        #expect(functionOutput[6]["text"] == .string("after"))

        let customOutput = try #require(
            input(body, type: "custom_tool_call_output", callID: "custom-call")["output"]?.arrayValue
        )
        #expect(customOutput.map { $0["text"]?.stringValue } == [
            "first",
            CODEX_REMOTE_IMAGE_URL_PLACEHOLDER,
            CODEX_UNSUPPORTED_LOW_DETAIL_PLACEHOLDER,
            CODEX_IMAGE_PROCESSING_ERROR_PLACEHOLDER,
            "last",
        ])
    }

    @Test("parallel tool images leave one exact breadcrumb and preserve valid images")
    func parallelToolImagesLeaveBreadcrumb() async throws {
        let request = ConversationRequest(items: [
            .toolResult(ToolResultItem(
                toolCallId: "mixed",
                content: "original output",
                images: [
                    .image(url: "https://example.test/rejected.png"),
                    .image(url: validImage),
                ]
            )),
            .toolResult(ToolResultItem(
                toolCallId: "empty",
                content: "",
                images: [.image(url: "data:image/png;base64,AAA")]
            )),
            .toolResult(ToolResultItem(
                toolCallId: "existing",
                content: "image content omitted previously",
                images: [.image(url: "data:image/png;base64,%%")]
            )),
        ])

        let body = try await requestBody(request)
        let mixedOutput = try #require(
            input(body, type: "function_call_output", callID: "mixed")["output"]?.arrayValue
        )
        #expect(mixedOutput[0]["text"] == .string(
            "original output\n[\(CODEX_IMAGE_PROCESSING_ERROR_PLACEHOLDER)]"
        ))
        #expect(mixedOutput[1]["image_url"] == .string(validImage))
        #expect(try input(body, type: "function_call_output", callID: "empty")["output"]
            == .string(CODEX_IMAGE_PROCESSING_ERROR_PLACEHOLDER))
        #expect(try input(body, type: "function_call_output", callID: "existing")["output"]
            == .string("image content omitted previously"))
    }

    @Test("the preparation count matches all replaced images without duplicating repeated breadcrumbs")
    func preparationReportsExactReplacementCount() {
        var request = ConversationRequest(items: [
            .userWithParts([
                .image(url: "https://example.test/user.png"),
                .image(url: validImage),
            ]),
            .toolResult(ToolResultItem(
                toolCallId: "tool",
                content: "tool output",
                images: [.image(url: "data:image/png;base64,AAA")],
                orderedContent: [.image(url: validImage, detail: .low)]
            )),
            .customToolOutput(CustomToolOutputItem(
                callId: "custom",
                content: [.image(url: "data:text/plain;base64,SGVsbG8=", detail: .high)]
            )),
        ])

        #expect(request.prepareImagesForCodex() == 4)
        #expect(request.prepareImagesForCodex() == 0)
        guard case .toolResult(let result) = request.items[1] else {
            Issue.record("expected the function tool output to remain in place")
            return
        }
        #expect(result.content == "tool output\n[\(CODEX_IMAGE_PROCESSING_ERROR_PLACEHOLDER)]")
    }

    @Test("non-data non-remote URLs retain upstream passthrough behavior")
    func unrelatedURLSchemesAreNotRewritten() async throws {
        let body = try await requestBody(ConversationRequest(items: [
            .userWithParts([
                .text(text: "reference"),
                .image(url: "blob:provider-local-image"),
                .image(url: "file:///tmp/image.png"),
                .image(url: "http"),
                .image(url: "https"),
            ]),
        ]))
        let content = try #require(input(body, type: "message")["content"]?.arrayValue)

        #expect(content[1]["image_url"] == .string("blob:provider-local-image"))
        #expect(content[2]["image_url"] == .string("file:///tmp/image.png"))
        #expect(content[3]["image_url"] == .string("http"))
        #expect(content[4]["image_url"] == .string("https"))
    }

    @Test("Codex-only preparation never changes xAI, DeepSeek, or Meta Responses requests")
    func imagePreparationCannotCrossProviderBoundary() async throws {
        let request = ConversationRequest(items: [
            .userWithParts([
                .image(url: "https://example.test/remote.png"),
                .image(url: "data:image/png;base64,AAA"),
            ]),
            .toolResult(ToolResultItem(
                toolCallId: "tool",
                content: "",
                orderedContent: [.image(url: validImage, detail: .low)]
            )),
        ])

        for provider: ModelProvider in [.xai, .deepseek, .meta] {
            let body = try await requestBody(request, provider: provider)
            let userContent = try #require(input(body, type: "message")["content"]?.arrayValue)
            #expect(userContent[0]["image_url"] == .string("https://example.test/remote.png"))
            #expect(userContent[1]["image_url"] == .string("data:image/png;base64,AAA"))

            let toolOutput = try #require(
                input(body, type: "function_call_output", callID: "tool")["output"]?.arrayValue
            )
            #expect(toolOutput[0]["image_url"] == .string(validImage))
            #expect(toolOutput[0]["detail"] == .string("low"))
        }
    }
}
