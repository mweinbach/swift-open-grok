// VideoGenerationTests.swift
//
// Derived from the Rust `video_gen` suite in
// `crates/codegen/xai-grok-tools/src/implementations/grok_build/video_gen/mod.rs`.

import Foundation
import OpenGrokHTTP
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

    @Test("resolveVideoImageReference accepts https URLs verbatim")
    func httpsPassthrough() throws {
        let url = "https://cdn.example.com/frame.png"
        #expect(try resolveVideoImageReference(url) == url)
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
