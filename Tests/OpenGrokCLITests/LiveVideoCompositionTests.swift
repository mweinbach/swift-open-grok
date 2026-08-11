// LiveVideoCompositionTests.swift
//
// Availability, registration, and handler contracts for `image_to_video`.
//
// Upstream references:
//   * `video_gen/mod.rs:1030-1075` — handler validation, tier upsell, save path
//   * `agent_ops.rs:2272-2314` — xAI-only config from `xai_media_api_key`

import Foundation
import OpenGrokHTTP
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokToolRegistry
import OpenGrokToolRuntime
import OpenGrokWebMediaTools
import Testing
@testable import OpenGrokCLI

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("video-tools-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let hermeticEnvironment: [String: String] = ["HOME": "/nonexistent"]

private func availability(
    provider: ModelProvider = .xai,
    apiKey: String = "",
    environment: [String: String] = hermeticEnvironment,
    tierRestricted: Bool = false
) -> LiveVideoToolAvailability {
    let directory = temporaryDirectory()
    return LiveVideoToolComposition.resolveAvailability(
        workingDirectory: directory,
        openGrokHome: directory,
        environment: environment,
        samplingProvider: provider,
        samplingAPIKey: apiKey,
        samplingBaseURL: "https://api.x.ai/v1",
        tierRestricted: tierRestricted
    )
}

private let sampleVideoBytes = Data("MP4!".utf8)

private func videoFlowResponses(downloadURL: String = "https://video.mock.invalid/clip.mp4") -> [MockHTTPTransport.ScriptedResponse] {
    [
        MockHTTPTransport.ScriptedResponse(
            metadata: HTTPResponseMetadata(statusCode: 200),
            body: Data(#"{"request_id":"req-1"}"#.utf8)
        ),
        MockHTTPTransport.ScriptedResponse(
            metadata: HTTPResponseMetadata(statusCode: 200),
            body: Data(#"{"status":"done","video":{"url":"\#(downloadURL)"}}"#.utf8)
        ),
        MockHTTPTransport.ScriptedResponse(
            metadata: HTTPResponseMetadata(statusCode: 200),
            body: sampleVideoBytes
        ),
    ]
}

private func minimalPNGData() -> Data {
    Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
        0x54, 0x08, 0xD7, 0x63, 0x60, 0x00, 0x00, 0x00,
        0x02, 0x00, 0x01, 0xE2, 0x21, 0xBC, 0x33, 0x00,
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
        0x42, 0x60, 0x82,
    ])
}

// MARK: - Availability

@Test func videoGenDisabledByFeatureFlag() {
    let directory = temporaryDirectory()
    var environment = hermeticEnvironment
    environment["GROK_VIDEO_GEN"] = "0"
    environment["XAI_API_KEY"] = "stored-xai-key"
    let resolved = LiveVideoToolComposition.resolveAvailability(
        workingDirectory: directory,
        openGrokHome: directory,
        environment: environment,
        samplingProvider: .xai,
        samplingAPIKey: "xai-key",
        samplingBaseURL: "https://api.x.ai/v1"
    )
    #expect(!resolved.imageToVideoEnabled)
    #expect(resolved.config.isEnabled == false)
}

@Test func missingBackendAdvertisesNothing() {
    let resolved = availability(provider: .xai, apiKey: "")
    #expect(!resolved.imageToVideoEnabled)
    #expect(resolved.config.isEnabled == false)
}

@Test func xaiSessionWithBearerGetsVideoTool() {
    let resolved = availability(provider: .xai, apiKey: "xai-key")
    #expect(resolved.imageToVideoEnabled)
    #expect(resolved.config.isEnabled)
}

@Test func nonXaiSessionMayUseStoredXaiKey() {
    var environment = hermeticEnvironment
    environment["XAI_API_KEY"] = "stored-xai-key"
    let resolved = availability(provider: .kimi, apiKey: "kimi-key", environment: environment)
    #expect(resolved.imageToVideoEnabled)
}

// MARK: - Registration gate

@Test func registerImageToVideoSkipsWhenClientCannotBeBuilt() {
    var builder = ToolRegistryBuilder()
    var toolConfig = ToolServerConfig(tools: [])
    let context = LiveVideoToolContext(
        availability: .unavailable,
        transport: MockHTTPTransport()
    )
    LiveVideoToolComposition.registerImageToVideo(
        context: context,
        builder: &builder,
        toolConfig: &toolConfig
    )
    #expect(toolConfig.tools.isEmpty)
}

@Test func registerImageToVideoAppendsWhenClientConstructible() throws {
    var builder = ToolRegistryBuilder()
    var toolConfig = ToolServerConfig(tools: [])
    let client = try VideoGenClient(
        config: .enabled(VideoGenSettings(
            apiKey: "k",
            baseURL: "https://api.x.ai/v1"
        )),
        transport: MockHTTPTransport()
    )
    let context = LiveVideoToolContext(
        availability: LiveVideoToolAvailability(
            config: .enabled(VideoGenSettings(apiKey: "k", baseURL: "https://api.x.ai/v1")),
            imageToVideoEnabled: true
        ),
        transport: MockHTTPTransport()
    )
    _ = client
    LiveVideoToolComposition.registerImageToVideo(
        context: context,
        builder: &builder,
        toolConfig: &toolConfig
    )
    #expect(toolConfig.tools.count == 1)
    #expect(toolConfig.tools[0].id == BuiltinToolCatalog.imageToVideoQualifiedId)
}

// MARK: - Handler

@Test func tierRestrictedReturnsUpsellWithoutHTTP() async throws {
    let client = try VideoGenClient(
        config: .enabled(VideoGenSettings(
            apiKey: "k",
            baseURL: "https://api.x.ai/v1",
            tierRestricted: true
        )),
        transport: MockHTTPTransport(responses: videoFlowResponses())
    )
    let handler = LiveImageToVideoToolHandler(client: client)
    let transport = MockHTTPTransport(responses: videoFlowResponses())
    _ = transport
    let sessionFolder = temporaryDirectory().path
    let result = await handler.invoke(
        clientName: IMAGE_TO_VIDEO_TOOL_NAME,
        args: .object([
            "image": .string("data:image/png;base64,\(minimalPNGData().base64EncodedString())"),
            "prompt": .string("gentle motion"),
        ]),
        ctx: ToolCallContext(),
        resources: ToolResources(cwd: sessionFolder, sessionFolder: sessionFolder)
    )
    guard case .success(let output) = result else {
        Issue.record("expected tier upsell success")
        return
    }
    guard case .object(let obj) = output.value,
          case .string(let text)? = obj["content"]
    else {
        Issue.record("expected text output")
        return
    }
    #expect(text == VIDEO_TIER_RESTRICTED_UPSELL)
}

@Test func mockHTTPGeneratesAndSavesVideo() async throws {
    let transport = MockHTTPTransport(responses: videoFlowResponses())
    let client = try VideoGenClient(
        config: .enabled(VideoGenSettings(
            apiKey: "k",
            baseURL: "https://api.x.ai/v1"
        )),
        transport: transport
    )
    let sessionFolder = temporaryDirectory()
    let imagePath = sessionFolder.appendingPathComponent("source.png")
    try minimalPNGData().write(to: imagePath)

    let handler = LiveImageToVideoToolHandler(client: client)
    let result = await handler.invoke(
        clientName: IMAGE_TO_VIDEO_TOOL_NAME,
        args: .object([
            "image": .string(imagePath.path),
            "prompt": .string("camera push-in"),
            "duration": .number(.int64(6)),
            "resolution_name": .string("480p"),
        ]),
        ctx: ToolCallContext(),
        resources: ToolResources(
            cwd: sessionFolder.path,
            sessionFolder: sessionFolder.path
        )
    )
    guard case .success(let output) = result else {
        Issue.record("expected successful video generation, got \(String(describing: result))")
        return
    }
    guard case .object(let obj) = output.value,
          case .string(let text)? = obj["content"]
    else {
        Issue.record("expected structured output")
        return
    }
    #expect(text.contains("Saved video to"))
    let videosDirectory = sessionFolder.appendingPathComponent("videos")
    let saved = try FileManager.default.contentsOfDirectory(atPath: videosDirectory.path)
    #expect(saved.contains("1.mp4"))
    let savedBytes = try Data(contentsOf: videosDirectory.appendingPathComponent("1.mp4"))
    #expect(savedBytes == sampleVideoBytes)
    #expect(transport.recordedRequests.count == 3)
}

@Test func invalidDurationIsRejected() async throws {
    let client = try VideoGenClient(
        config: .enabled(VideoGenSettings(apiKey: "k", baseURL: "https://api.x.ai/v1")),
        transport: MockHTTPTransport()
    )
    let handler = LiveImageToVideoToolHandler(client: client)
    let sessionFolder = temporaryDirectory().path
    let result = await handler.invoke(
        clientName: IMAGE_TO_VIDEO_TOOL_NAME,
        args: .object([
            "image": .string("/tmp/source.png"),
            "duration": .number(.int64(8)),
        ]),
        ctx: ToolCallContext(),
        resources: ToolResources(cwd: sessionFolder, sessionFolder: sessionFolder)
    )
    guard case .failure(let error) = result else {
        Issue.record("expected invalid duration failure")
        return
    }
    #expect(error.description.contains("either 6 or 10"))
}

@Test func invalidResolutionIsRejected() async throws {
    let client = try VideoGenClient(
        config: .enabled(VideoGenSettings(apiKey: "k", baseURL: "https://api.x.ai/v1")),
        transport: MockHTTPTransport()
    )
    let handler = LiveImageToVideoToolHandler(client: client)
    let sessionFolder = temporaryDirectory().path
    let result = await handler.invoke(
        clientName: IMAGE_TO_VIDEO_TOOL_NAME,
        args: .object([
            "image": .string("/tmp/source.png"),
            "resolution_name": .string("1080p"),
        ]),
        ctx: ToolCallContext(),
        resources: ToolResources(cwd: sessionFolder, sessionFolder: sessionFolder)
    )
    guard case .failure(let error) = result else {
        Issue.record("expected invalid resolution failure")
        return
    }
    #expect(error.description.contains("resolution_name"))
}
