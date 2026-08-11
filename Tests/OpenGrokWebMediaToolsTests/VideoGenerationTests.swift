// VideoGenerationTests.swift
//
// Derived from the Rust `video_gen` suite in
// `crates/codegen/xai-grok-tools/src/implementations/grok_build/video_gen/mod.rs`.

import Foundation
import OpenGrokHTTP
import OpenGrokShared
import Testing
@testable import OpenGrokWebMediaTools

private let sampleVideoBytes = Data("MP4!".utf8)

private func videoFlowResponses() -> [MockHTTPTransport.ScriptedResponse] {
    [
        MockHTTPTransport.ScriptedResponse(
            metadata: HTTPResponseMetadata(statusCode: 200),
            body: Data(#"{"request_id":"req-1"}"#.utf8)
        ),
        MockHTTPTransport.ScriptedResponse(
            metadata: HTTPResponseMetadata(statusCode: 200),
            body: Data(#"{"status":"done","video":{"url":"https://video.mock.invalid/clip.mp4"}}"#.utf8)
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

@Suite("Video generation validation")
struct VideoGenerationValidationTests {
    @Test("duration validation allows only toolbox values")
    func durationValidation() throws {
        try validateImagineVideoDuration(nil)
        try validateImagineVideoDuration(6)
        try validateImagineVideoDuration(10)
        #expect(throws: VideoGenError.self) {
            try validateImagineVideoDuration(8)
        }
    }

    @Test("resolution validation accepts 480p and 720p only")
    func resolutionValidation() throws {
        try validateVideoResolution("480p")
        try validateVideoResolution("720p")
        #expect(throws: VideoGenError.self) {
            try validateVideoResolution("1080p")
        }
    }

    @Test("aspect ratio validation accepts Imagine toolbox values only")
    func aspectRatioValidation() throws {
        for ratio in VALID_IMAGINE_VIDEO_ASPECT_RATIOS {
            try validateImagineVideoAspectRatio(ratio)
        }
        #expect(throws: VideoGenError.self) {
            try validateImagineVideoAspectRatio("4:3")
        }
    }

    @Test("image_to_video input defaults match upstream")
    func inputDefaults() throws {
        let input = try JSONDecoder().decode(
            ImageToVideoInput.self,
            from: Data(#"{"image":"/tmp/source.jpg"}"#.utf8)
        )
        #expect(input.prompt == nil)
        #expect(input.duration == nil)
        #expect(input.resolutionName == DEFAULT_VIDEO_RESOLUTION)
    }

    @Test("reference_to_video input deserializes with defaults")
    func referenceToVideoInputDefaults() throws {
        let input = try JSONDecoder().decode(
            ReferenceToVideoInput.self,
            from: Data(#"""
            {
              "prompt": "blend these",
              "images": ["/tmp/a.jpg", "/tmp/b.jpg"],
              "aspect_ratio": "16:9",
              "duration": 10
            }
            """#.utf8)
        )
        #expect(input.prompt == "blend these")
        #expect(input.images.count == 2)
        #expect(input.aspectRatio == "16:9")
        #expect(input.duration == 10)
        #expect(input.resolutionName == DEFAULT_VIDEO_RESOLUTION)
    }

    @Test("resolveVideoImageReference accepts https URLs verbatim")
    func httpsPassthrough() throws {
        let url = "https://cdn.example.com/frame.png"
        #expect(try resolveVideoImageReference(url) == url)
    }

    @Test("constants match Rust pin 650c1db7")
    func constantsMatchPin() {
        #expect(XAI_VIDEO_BASE_MODEL == "grok-imagine-video")
        #expect(XAI_VIDEO_QUALITY_MODEL == "grok-imagine-video-1.5-preview")
        #expect(MAX_R2V_REFERENCE_IMAGES == 7)
        #expect(REFERENCE_TO_VIDEO_TOOL_NAME == "reference_to_video")
        #expect(REFERENCE_TO_VIDEO_DESCRIPTION.contains("2 to 7 image references"))
    }
}

@Suite("Video generation client")
struct VideoGenerationClientTests {
    @Test("disabled config fails closed at construction")
    func disabledConfig() {
        #expect(throws: VideoGenError.self) {
            _ = try VideoGenClient(config: .disabled, transport: MockHTTPTransport())
        }
    }

    @Test("generateWithImages polls and downloads via mock transport")
    func generateWithImages() async throws {
        let transport = MockHTTPTransport(responses: videoFlowResponses())
        let client = try VideoGenClient(
            config: .enabled(VideoGenSettings(
                apiKey: "k",
                baseURL: "https://api.x.ai/v1"
            )),
            transport: transport
        )
        let image = "data:image/png;base64,\(minimalPNGData().base64EncodedString())"
        let bytes = try await client.generateWithImages(
            prompt: "camera push-in",
            duration: 6,
            resolution: "480p",
            image: image
        )
        #expect(bytes == sampleVideoBytes)
        #expect(transport.recordedRequests.count == 3)

        let startBody = try #require(transport.recordedRequests.first?.body)
        let root = try JSONSerialization.jsonObject(with: startBody) as? [String: Any]
        #expect(root?["model"] as? String == XAI_VIDEO_QUALITY_MODEL)
        #expect(root?["image"] != nil)
        #expect(root?["reference_images"] == nil)
        #expect(root?["aspect_ratio"] == nil)
    }

    @Test("reference_to_video payload uses base model and omits image")
    func referenceToVideoPayload() async throws {
        let transport = MockHTTPTransport(responses: videoFlowResponses())
        let client = try VideoGenClient(
            config: .enabled(VideoGenSettings(
                apiKey: "k",
                baseURL: "https://api.x.ai/v1"
            )),
            transport: transport
        )
        let a = "data:image/png;base64,\(minimalPNGData().base64EncodedString())"
        let b = a
        let bytes = try await client.generateWithImages(
            model: XAI_VIDEO_BASE_MODEL,
            prompt: "blend",
            duration: 6,
            aspectRatio: "16:9",
            resolution: "480p",
            image: nil,
            referenceImages: [a, b]
        )
        #expect(bytes == sampleVideoBytes)
        #expect(transport.recordedRequests.count == 3)

        let startBody = try #require(transport.recordedRequests.first?.body)
        let root = try #require(try JSONSerialization.jsonObject(with: startBody) as? [String: Any])
        #expect(root["model"] as? String == XAI_VIDEO_BASE_MODEL)
        #expect(root["aspect_ratio"] as? String == "16:9")
        #expect(root["image"] == nil)
        let refs = try #require(root["reference_images"] as? [[String: Any]])
        #expect(refs.count == 2)
        #expect(refs[0]["url"] as? String == a)
    }

    @Test("tier restriction is surfaced on the client")
    func tierRestriction() throws {
        let client = try VideoGenClient(
            config: .enabled(VideoGenSettings(
                apiKey: "k",
                baseURL: "https://api.x.ai/v1",
                tierRestricted: true
            )),
            transport: MockHTTPTransport()
        )
        #expect(client.isTierRestricted)
    }
}
