// LiveVideoCompositionTests.swift
//
// Availability, registration, and handler contracts for `image_to_video`
// and `reference_to_video`.
//
// Upstream references (pin 650c1db7):
//   * `video_gen/mod.rs:1030-1075` — image_to_video handler
//   * `video_gen/mod.rs:1136-1189` — reference_to_video validation + payload
//   * `builder.rs:781-788` — both tools under one VideoGenConfig gate
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

private func dataImageURL() -> String {
    "data:image/png;base64,\(minimalPNGData().base64EncodedString())"
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
    #expect(!resolved.referenceToVideoEnabled)
    #expect(resolved.config.isEnabled == false)
}

@Test func missingBackendAdvertisesNothing() {
    let resolved = availability(provider: .xai, apiKey: "")
    #expect(!resolved.imageToVideoEnabled)
    #expect(!resolved.referenceToVideoEnabled)
    #expect(resolved.config.isEnabled == false)
}

@Test func xaiSessionWithBearerGetsBothVideoTools() {
    let resolved = availability(provider: .xai, apiKey: "xai-key")
    #expect(resolved.imageToVideoEnabled)
    #expect(resolved.referenceToVideoEnabled)
    #expect(resolved.config.isEnabled)
}

@Test func nonXaiSessionMayUseStoredXaiKey() {
    var environment = hermeticEnvironment
    environment["XAI_API_KEY"] = "stored-xai-key"
    let resolved = availability(provider: .kimi, apiKey: "kimi-key", environment: environment)
    #expect(resolved.imageToVideoEnabled)
    #expect(resolved.referenceToVideoEnabled)
}

// MARK: - Registration gate

@Test func registerVideoToolsSkipsWhenClientCannotBeBuilt() {
    var builder = ToolRegistryBuilder()
    var toolConfig = ToolServerConfig(tools: [])
    let context = LiveVideoToolContext(
        availability: .unavailable,
        transport: MockHTTPTransport()
    )
    LiveVideoToolComposition.registerVideoTools(
        context: context,
        builder: &builder,
        toolConfig: &toolConfig
    )
    #expect(toolConfig.tools.isEmpty)
}

@Test func registerVideoToolsAppendsBothWhenClientConstructible() throws {
    var builder = ToolRegistryBuilder()
    var toolConfig = ToolServerConfig(tools: [])
    let context = LiveVideoToolContext(
        availability: LiveVideoToolAvailability(
            config: .enabled(VideoGenSettings(apiKey: "k", baseURL: "https://api.x.ai/v1")),
            imageToVideoEnabled: true,
            referenceToVideoEnabled: true
        ),
        transport: MockHTTPTransport()
    )
    LiveVideoToolComposition.registerVideoTools(
        context: context,
        builder: &builder,
        toolConfig: &toolConfig
    )
    #expect(toolConfig.tools.count == 2)
    let ids = Set(toolConfig.tools.map(\.id))
    #expect(ids.contains(BuiltinToolCatalog.imageToVideoQualifiedId))
    #expect(ids.contains(BuiltinToolCatalog.referenceToVideoQualifiedId))
    #expect(builder.hasToolId(BuiltinToolCatalog.imageToVideoQualifiedId))
    #expect(builder.hasToolId(BuiltinToolCatalog.referenceToVideoQualifiedId))
}

@Test func registerImageToVideoAliasRegistersBoth() throws {
    var builder = ToolRegistryBuilder()
    var toolConfig = ToolServerConfig(tools: [])
    let context = LiveVideoToolContext(
        availability: LiveVideoToolAvailability(
            config: .enabled(VideoGenSettings(apiKey: "k", baseURL: "https://api.x.ai/v1")),
            imageToVideoEnabled: true,
            referenceToVideoEnabled: true
        ),
        transport: MockHTTPTransport()
    )
    LiveVideoToolComposition.registerImageToVideo(
        context: context,
        builder: &builder,
        toolConfig: &toolConfig
    )
    #expect(toolConfig.tools.count == 2)
}

// MARK: - image_to_video handler

@Test func tierRestrictedReturnsUpsellWithoutHTTP() async throws {
    let transport = MockHTTPTransport(responses: videoFlowResponses())
    let client = try VideoGenClient(
        config: .enabled(VideoGenSettings(
            apiKey: "k",
            baseURL: "https://api.x.ai/v1",
            tierRestricted: true
        )),
        transport: transport
    )
    let handler = LiveImageToVideoToolHandler(client: client)
    let sessionFolder = temporaryDirectory().path
    let result = await handler.invoke(
        clientName: IMAGE_TO_VIDEO_TOOL_NAME,
        args: .object([
            "image": .string(dataImageURL()),
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
    #expect(transport.recordedRequests.isEmpty)
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

// MARK: - reference_to_video handler

@Test func referenceToVideoRejectsEmptyPrompt() async throws {
    let transport = MockHTTPTransport()
    let client = try VideoGenClient(
        config: .enabled(VideoGenSettings(apiKey: "k", baseURL: "https://api.x.ai/v1")),
        transport: transport
    )
    let handler = LiveReferenceToVideoToolHandler(client: client)
    let sessionFolder = temporaryDirectory().path
    let result = await handler.invoke(
        clientName: REFERENCE_TO_VIDEO_TOOL_NAME,
        args: .object([
            "prompt": .string("   "),
            "images": .array([.string(dataImageURL()), .string(dataImageURL())]),
            "aspect_ratio": .string("16:9"),
        ]),
        ctx: ToolCallContext(),
        resources: ToolResources(cwd: sessionFolder, sessionFolder: sessionFolder)
    )
    guard case .failure(let error) = result else {
        Issue.record("expected empty prompt failure")
        return
    }
    #expect(error.description.contains("`prompt` must not be empty."))
    #expect(transport.recordedRequests.isEmpty)
}

@Test func referenceToVideoRejectsTooFewImages() async throws {
    let transport = MockHTTPTransport()
    let client = try VideoGenClient(
        config: .enabled(VideoGenSettings(apiKey: "k", baseURL: "https://api.x.ai/v1")),
        transport: transport
    )
    let handler = LiveReferenceToVideoToolHandler(client: client)
    let sessionFolder = temporaryDirectory().path
    let result = await handler.invoke(
        clientName: REFERENCE_TO_VIDEO_TOOL_NAME,
        args: .object([
            "prompt": .string("blend"),
            "images": .array([.string(dataImageURL())]),
            "aspect_ratio": .string("16:9"),
        ]),
        ctx: ToolCallContext(),
        resources: ToolResources(cwd: sessionFolder, sessionFolder: sessionFolder)
    )
    guard case .failure(let error) = result else {
        Issue.record("expected too-few-images failure")
        return
    }
    #expect(error.description.contains("at least two image references"))
    #expect(transport.recordedRequests.isEmpty)
}

@Test func referenceToVideoRejectsTooManyImages() async throws {
    let transport = MockHTTPTransport()
    let client = try VideoGenClient(
        config: .enabled(VideoGenSettings(apiKey: "k", baseURL: "https://api.x.ai/v1")),
        transport: transport
    )
    let handler = LiveReferenceToVideoToolHandler(client: client)
    let sessionFolder = temporaryDirectory().path
    let images = (0..<8).map { _ in JSONValue.string(dataImageURL()) }
    let result = await handler.invoke(
        clientName: REFERENCE_TO_VIDEO_TOOL_NAME,
        args: .object([
            "prompt": .string("blend"),
            "images": .array(images),
            "aspect_ratio": .string("16:9"),
        ]),
        ctx: ToolCallContext(),
        resources: ToolResources(cwd: sessionFolder, sessionFolder: sessionFolder)
    )
    guard case .failure(let error) = result else {
        Issue.record("expected too-many-images failure")
        return
    }
    #expect(error.description.contains("at most 7 image references"))
    #expect(transport.recordedRequests.isEmpty)
}

@Test func referenceToVideoRejectsInvalidAspectRatio() async throws {
    let transport = MockHTTPTransport()
    let client = try VideoGenClient(
        config: .enabled(VideoGenSettings(apiKey: "k", baseURL: "https://api.x.ai/v1")),
        transport: transport
    )
    let handler = LiveReferenceToVideoToolHandler(client: client)
    let sessionFolder = temporaryDirectory().path
    let result = await handler.invoke(
        clientName: REFERENCE_TO_VIDEO_TOOL_NAME,
        args: .object([
            "prompt": .string("blend"),
            "images": .array([.string(dataImageURL()), .string(dataImageURL())]),
            "aspect_ratio": .string("4:3"),
        ]),
        ctx: ToolCallContext(),
        resources: ToolResources(cwd: sessionFolder, sessionFolder: sessionFolder)
    )
    guard case .failure(let error) = result else {
        Issue.record("expected invalid aspect ratio failure")
        return
    }
    #expect(error.description.contains("`aspect_ratio` must be one of:"))
    #expect(error.description.contains("Got 4:3."))
    #expect(transport.recordedRequests.isEmpty)
}

@Test func referenceToVideoRejectsInvalidDuration() async throws {
    let transport = MockHTTPTransport()
    let client = try VideoGenClient(
        config: .enabled(VideoGenSettings(apiKey: "k", baseURL: "https://api.x.ai/v1")),
        transport: transport
    )
    let handler = LiveReferenceToVideoToolHandler(client: client)
    let sessionFolder = temporaryDirectory().path
    let result = await handler.invoke(
        clientName: REFERENCE_TO_VIDEO_TOOL_NAME,
        args: .object([
            "prompt": .string("blend"),
            "images": .array([.string(dataImageURL()), .string(dataImageURL())]),
            "aspect_ratio": .string("16:9"),
            "duration": .number(.int64(8)),
        ]),
        ctx: ToolCallContext(),
        resources: ToolResources(cwd: sessionFolder, sessionFolder: sessionFolder)
    )
    guard case .failure(let error) = result else {
        Issue.record("expected invalid duration failure")
        return
    }
    #expect(error.description.contains("`duration` must be either 6 or 10 seconds. Got 8."))
    #expect(transport.recordedRequests.isEmpty)
}

@Test func referenceToVideoRejectsInvalidResolution() async throws {
    let transport = MockHTTPTransport()
    let client = try VideoGenClient(
        config: .enabled(VideoGenSettings(apiKey: "k", baseURL: "https://api.x.ai/v1")),
        transport: transport
    )
    let handler = LiveReferenceToVideoToolHandler(client: client)
    let sessionFolder = temporaryDirectory().path
    let result = await handler.invoke(
        clientName: REFERENCE_TO_VIDEO_TOOL_NAME,
        args: .object([
            "prompt": .string("blend"),
            "images": .array([.string(dataImageURL()), .string(dataImageURL())]),
            "aspect_ratio": .string("16:9"),
            "resolution_name": .string("1080p"),
        ]),
        ctx: ToolCallContext(),
        resources: ToolResources(cwd: sessionFolder, sessionFolder: sessionFolder)
    )
    guard case .failure(let error) = result else {
        Issue.record("expected invalid resolution failure")
        return
    }
    #expect(error.description.contains("`resolution_name` must be one of:"))
    #expect(error.description.contains("Got 1080p."))
    #expect(transport.recordedRequests.isEmpty)
}

@Test func referenceToVideoTierRestrictedReturnsUpsellWithoutHTTP() async throws {
    let transport = MockHTTPTransport(responses: videoFlowResponses())
    let client = try VideoGenClient(
        config: .enabled(VideoGenSettings(
            apiKey: "k",
            baseURL: "https://api.x.ai/v1",
            tierRestricted: true
        )),
        transport: transport
    )
    let handler = LiveReferenceToVideoToolHandler(client: client)
    let sessionFolder = temporaryDirectory().path
    let result = await handler.invoke(
        clientName: REFERENCE_TO_VIDEO_TOOL_NAME,
        args: .object([
            "prompt": .string("blend these into a cinematic shot"),
            "images": .array([.string(dataImageURL()), .string(dataImageURL())]),
            "aspect_ratio": .string("16:9"),
            "duration": .number(.int64(6)),
            "resolution_name": .string("480p"),
        ]),
        ctx: ToolCallContext(),
        resources: ToolResources(cwd: sessionFolder, sessionFolder: sessionFolder)
    )
    guard case .success(let output) = result else {
        Issue.record("expected tier upsell success, got \(String(describing: result))")
        return
    }
    guard case .object(let obj) = output.value,
          case .string(let text)? = obj["content"]
    else {
        Issue.record("expected text output")
        return
    }
    #expect(text == VIDEO_TIER_RESTRICTED_UPSELL)
    #expect(transport.recordedRequests.isEmpty)
}

@Test func referenceToVideoHappyPathUsesBaseModelAndReferenceImages() async throws {
    let transport = MockHTTPTransport(responses: videoFlowResponses())
    let client = try VideoGenClient(
        config: .enabled(VideoGenSettings(
            apiKey: "k",
            baseURL: "https://api.x.ai/v1"
        )),
        transport: transport
    )
    let sessionFolder = temporaryDirectory()
    let refA = sessionFolder.appendingPathComponent("ref-a.png")
    let refB = sessionFolder.appendingPathComponent("ref-b.png")
    try minimalPNGData().write(to: refA)
    try minimalPNGData().write(to: refB)

    let handler = LiveReferenceToVideoToolHandler(client: client)
    let result = await handler.invoke(
        clientName: REFERENCE_TO_VIDEO_TOOL_NAME,
        args: .object([
            "prompt": .string("blend these into a cinematic fashion shot"),
            "images": .array([.string(refA.path), .string(refB.path)]),
            "aspect_ratio": .string("16:9"),
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
        Issue.record("expected successful reference_to_video, got \(String(describing: result))")
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
    #expect(transport.recordedRequests.count == 3)

    let startBody = try #require(transport.recordedRequests.first?.body)
    let root = try #require(try JSONSerialization.jsonObject(with: startBody) as? [String: Any])
    #expect(root["model"] as? String == XAI_VIDEO_BASE_MODEL)
    #expect(root["aspect_ratio"] as? String == "16:9")
    #expect(root["image"] == nil)
    let refs = try #require(root["reference_images"] as? [[String: Any]])
    #expect(refs.count == 2)
    #expect((refs[0]["url"] as? String)?.hasPrefix("data:image/") == true)
}

// MARK: - duration argument (crash + silent-default regressions)

/// `UInt32(someInt64)` traps above `UInt32.max`, so this input used to kill the
/// agent process instead of returning a tool error.
@Test func referenceToVideoRejectsOutOfRangeDuration() async throws {
    let transport = MockHTTPTransport()
    let client = try VideoGenClient(
        config: .enabled(VideoGenSettings(apiKey: "k", baseURL: "https://api.x.ai/v1")),
        transport: transport
    )
    let handler = LiveReferenceToVideoToolHandler(client: client)
    let sessionFolder = temporaryDirectory().path
    let result = await handler.invoke(
        clientName: REFERENCE_TO_VIDEO_TOOL_NAME,
        args: .object([
            "prompt": .string("blend"),
            "images": .array([.string(dataImageURL()), .string(dataImageURL())]),
            "aspect_ratio": .string("16:9"),
            "duration": .number(.int64(4_294_967_296)),
        ]),
        ctx: ToolCallContext(),
        resources: ToolResources(cwd: sessionFolder, sessionFolder: sessionFolder)
    )
    guard case .failure(let error) = result else {
        Issue.record("expected out-of-range duration failure")
        return
    }
    #expect(error.description.contains("`duration`"))
    #expect(transport.recordedRequests.isEmpty)
}

/// A malformed duration used to collapse into "absent" and silently generate at
/// the six-second default — a billable request the caller never asked for.
@Test func referenceToVideoRejectsMalformedDuration() async throws {
    let transport = MockHTTPTransport()
    let client = try VideoGenClient(
        config: .enabled(VideoGenSettings(apiKey: "k", baseURL: "https://api.x.ai/v1")),
        transport: transport
    )
    let handler = LiveReferenceToVideoToolHandler(client: client)
    let sessionFolder = temporaryDirectory().path
    for malformed in [JSONValue.string("soon"), .number(.int64(-1))] {
        let result = await handler.invoke(
            clientName: REFERENCE_TO_VIDEO_TOOL_NAME,
            args: .object([
                "prompt": .string("blend"),
                "images": .array([.string(dataImageURL()), .string(dataImageURL())]),
                "aspect_ratio": .string("16:9"),
                "duration": malformed,
            ]),
            ctx: ToolCallContext(),
            resources: ToolResources(cwd: sessionFolder, sessionFolder: sessionFolder)
        )
        guard case .failure(let error) = result else {
            Issue.record("expected malformed duration failure for \(malformed)")
            return
        }
        #expect(error.description.contains("`duration`"))
    }
    #expect(transport.recordedRequests.isEmpty)
}

@Test func imageToVideoRejectsOutOfRangeDuration() async throws {
    let transport = MockHTTPTransport()
    let client = try VideoGenClient(
        config: .enabled(VideoGenSettings(apiKey: "k", baseURL: "https://api.x.ai/v1")),
        transport: transport
    )
    let handler = LiveImageToVideoToolHandler(client: client)
    let sessionFolder = temporaryDirectory().path
    let result = await handler.invoke(
        clientName: IMAGE_TO_VIDEO_TOOL_NAME,
        args: .object([
            "image": .string(dataImageURL()),
            "duration": .number(.int64(4_294_967_296)),
        ]),
        ctx: ToolCallContext(),
        resources: ToolResources(cwd: sessionFolder, sessionFolder: sessionFolder)
    )
    guard case .failure(let error) = result else {
        Issue.record("expected out-of-range duration failure")
        return
    }
    #expect(error.description.contains("`duration`"))
    #expect(transport.recordedRequests.isEmpty)
}
