// ImageGenerationTests.swift
//
// Derived from the Rust `image_gen` suite in
// `crates/codegen/xai-grok-tools/src/implementations/grok_build/image_gen/mod.rs`
// (`openai_size_maps_supported_orientations`,
// `openai_generation_matches_codex_images_contract`) and the OAuth-isolation
// contract fixed by upstream ebb4dc65.

import Foundation
import OpenGrokHTTP
import Testing
@testable import OpenGrokWebMediaTools

private struct StubBearer: ImageBearerProvider {
    let value: String?
    func currentBearer() async -> String? { value }
}

private func jsonBody(_ request: HTTPRequest) -> [String: Any] {
    guard let body = request.body,
          let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    else { return [:] }
    return obj
}

private func imageResponse(b64: String) -> MockHTTPTransport.ScriptedResponse {
    MockHTTPTransport.ScriptedResponse(
        metadata: HTTPResponseMetadata(statusCode: 200),
        body: Data(#"{"data":[{"b64_json":"\#(b64)"}]}"#.utf8)
    )
}

/// Base64 of the 4 bytes `PNG!`, so a decode failure is distinguishable from
/// an empty-image failure.
private let samplePNGBase64 = Data("PNG!".utf8).base64EncodedString()

@Suite("Image generation provider routing")
struct ImageGenerationProviderTests {
    @Test("canonical strings round-trip and match the config-side mirror")
    func canonicalStrings() {
        #expect(ImageGenerationProvider.default == .grok)
        #expect(ImageGenerationProvider.grok.canonical == "grok")
        #expect(ImageGenerationProvider.openAI.canonical == "openai")
        #expect(ImageGenerationProvider.fromCanonical(" OpenAI ") == .openAI)
        #expect(ImageGenerationProvider.fromCanonical("GROK") == .grok)
        #expect(ImageGenerationProvider.fromCanonical("imagine") == nil)
    }

    @Test("snake_case wire names")
    func wireNames() throws {
        let data = try JSONEncoder().encode(ImageGenerationProvider.openAI)
        #expect(String(decoding: data, as: UTF8.self) == "\"openai\"")
        let back = try JSONDecoder().decode(ImageGenerationProvider.self, from: data)
        #expect(back == .openAI)
    }

    @Test("aspect ratios map to the OpenAI size vocabulary")
    func sizeMapping() {
        #expect(openAIImageSize("1:1") == "1024x1024")
        #expect(openAIImageSize("16:9") == "1536x1024")
        #expect(openAIImageSize("9:16") == "1024x1536")
        #expect(openAIImageSize("auto") == "auto")
        #expect(openAIImageSize("unexpected") == "auto")
    }
}

@Suite("Image generation OAuth isolation")
struct ImageGenerationIsolationTests {
    /// The core boundary ebb4dc65 fixes: an OpenAI-routed client must never
    /// bake a static bearer, no matter what the config carries.
    @Test("OpenAI route never bakes a static Authorization header")
    func openAINeverBakesStaticBearer() throws {
        let client = try ImageGenClient(
            config: .enabled(
                ImageGenSettings(
                    provider: .openAI,
                    apiKey: "static-xai-key-that-must-not-leak",
                    baseURL: "https://chatgpt.com/backend-api/codex",
                    extraHeaders: [("originator", "codex_cli_rs")],
                    bearerProvider: StubBearer(value: "codex-token")
                )
            ),
            transport: MockHTTPTransport()
        )

        #expect(client.defaultHeaders["Authorization"] == nil)
        #expect(!client.defaultHeaders.values.contains { $0.contains("static-xai-key") })
        #expect(client.defaultHeaders["originator"] == "codex_cli_rs")
        #expect(client.requireLiveBearer)
    }

    /// The legacy session-wide provider carries the xAI bearer, so it may back
    /// only Grok. If it could reach the OpenAI client, a Grok bearer would be
    /// sent to an OpenAI endpoint.
    @Test("legacy session bearer provider never backs the OpenAI route")
    func legacyProviderNeverBacksOpenAI() async throws {
        let openAI = try ImageGenClient(
            config: .enabled(
                ImageGenSettings(
                    provider: .openAI,
                    baseURL: "https://chatgpt.com/backend-api/codex",
                    bearerProvider: nil
                )
            ),
            legacyBearerProvider: StubBearer(value: "xai-session-bearer"),
            transport: MockHTTPTransport()
        )
        #expect(await openAI.currentBearer() == nil)

        let grok = try ImageGenClient(
            config: .enabled(
                ImageGenSettings(provider: .grok, baseURL: "https://api.x.ai/v1")
            ),
            legacyBearerProvider: StubBearer(value: "xai-session-bearer"),
            transport: MockHTTPTransport()
        )
        #expect(await grok.currentBearer() == "xai-session-bearer")
    }

    @Test("config-level resolver wins over the legacy provider on Grok")
    func configResolverWinsOnGrok() async throws {
        let grok = try ImageGenClient(
            config: .enabled(
                ImageGenSettings(
                    provider: .grok,
                    baseURL: "https://api.x.ai/v1",
                    bearerProvider: StubBearer(value: "config-resolver")
                )
            ),
            legacyBearerProvider: StubBearer(value: "legacy"),
            transport: MockHTTPTransport()
        )
        #expect(await grok.currentBearer() == "config-resolver")
    }

    /// Fail closed: without a live OAuth bearer nothing is sent at all.
    @Test("OpenAI request fails closed when no live bearer resolves")
    func openAIFailsClosedWithoutBearer() async throws {
        let transport = MockHTTPTransport(responses: [imageResponse(b64: samplePNGBase64)])
        let client = try ImageGenClient(
            config: .enabled(
                ImageGenSettings(
                    provider: .openAI,
                    apiKey: "static-key",
                    baseURL: "https://chatgpt.com/backend-api/codex",
                    bearerProvider: StubBearer(value: nil)
                )
            ),
            transport: transport
        )

        await #expect(throws: ImageGenError.authRequired) {
            _ = try await client.generate(prompt: "a red fox", aspectRatio: "1:1", turnID: "t")
        }
        #expect(transport.recordedRequests.isEmpty, "no request may leave without a bearer")
    }

    /// Grok has no live-bearer requirement: the static key is its fallback.
    @Test("Grok route still sends with only its static key")
    func grokSendsWithStaticKey() async throws {
        let transport = MockHTTPTransport(responses: [imageResponse(b64: samplePNGBase64)])
        let client = try ImageGenClient(
            config: .enabled(
                ImageGenSettings(
                    provider: .grok,
                    apiKey: "xai-static",
                    baseURL: "https://api.x.ai/v1"
                )
            ),
            transport: transport
        )
        #expect(!client.requireLiveBearer)

        let bytes = try await client.generate(
            prompt: "a red fox",
            aspectRatio: "1:1",
            turnID: "turn-123"
        )
        #expect(bytes == Data("PNG!".utf8))

        let request = try #require(transport.recordedRequests.first)
        #expect(request.headers["Authorization"] == "Bearer xai-static")
        // The Codex turn-id header belongs to the OpenAI route only.
        #expect(request.headers[CODEX_IMAGE_TURN_ID_HEADER] == nil)
    }
}

@Suite("Image generation wire contract")
struct ImageGenerationWireTests {
    /// Golden request. Provenance: Rust
    /// `openai_generation_matches_codex_images_contract` (image_gen/mod.rs).
    @Test("OpenAI generation matches the pinned Codex images contract")
    func openAIGenerationContract() async throws {
        let transport = MockHTTPTransport(responses: [imageResponse(b64: samplePNGBase64)])
        let client = try ImageGenClient(
            config: .enabled(
                ImageGenSettings(
                    provider: .openAI,
                    baseURL: "https://chatgpt.com/backend-api/codex",
                    extraHeaders: [("originator", "codex_cli_rs")],
                    bearerProvider: StubBearer(value: "codex-token")
                )
            ),
            transport: transport
        )

        _ = try await client.generate(
            prompt: "a red fox",
            aspectRatio: "1:1",
            turnID: "turn-123"
        )

        let request = try #require(transport.recordedRequests.first)
        #expect(request.url.absoluteString == "https://chatgpt.com/backend-api/codex/images/generations")
        #expect(request.headers["Authorization"] == "Bearer codex-token")
        #expect(request.headers["originator"] == "codex_cli_rs")
        #expect(request.headers[CODEX_IMAGE_TURN_ID_HEADER] == "turn-123")

        let body = jsonBody(request)
        #expect(body["model"] as? String == OPENAI_IMAGE_MODEL)
        #expect(body["prompt"] as? String == "a red fox")
        #expect(body["background"] as? String == "auto")
        #expect(body["quality"] as? String == "auto")
        #expect(body["size"] as? String == "1024x1024")
        // Grok-only fields must not appear on the OpenAI payload.
        #expect(body["response_format"] == nil)
        #expect(body["aspect_ratio"] == nil)
        #expect(body["n"] == nil)
    }

    /// Golden request. Provenance: the Grok Imagine branch of
    /// `ImageGenClient::generate` (image_gen/mod.rs).
    @Test("Grok generation sends the Imagine payload")
    func grokGenerationContract() async throws {
        let transport = MockHTTPTransport(responses: [imageResponse(b64: samplePNGBase64)])
        let client = try ImageGenClient(
            config: .enabled(
                ImageGenSettings(
                    provider: .grok,
                    apiKey: "xai-static",
                    baseURL: "https://api.x.ai/v1/"
                )
            ),
            transport: transport
        )

        _ = try await client.generate(prompt: "a red fox", aspectRatio: "16:9", turnID: "t")

        let request = try #require(transport.recordedRequests.first)
        // The trailing slash on the configured base URL must not double up.
        #expect(request.url.absoluteString == "https://api.x.ai/v1/images/generations")
        let body = jsonBody(request)
        #expect(body["model"] as? String == XAI_IMAGINE_MODEL)
        #expect(body["aspect_ratio"] as? String == "16:9")
        #expect(body["resolution"] as? String == "1k")
        #expect(body["response_format"] as? String == "b64_json")
        #expect((body["n"] as? NSNumber)?.intValue == 1)
    }

    @Test("Grok single-image edit uses `image`, multi-image uses `images`")
    func grokEditShape() async throws {
        let transport = MockHTTPTransport(responses: [
            imageResponse(b64: samplePNGBase64),
            imageResponse(b64: samplePNGBase64),
        ])
        let client = try ImageGenClient(
            config: .enabled(
                ImageGenSettings(provider: .grok, apiKey: "k", baseURL: "https://api.x.ai/v1")
            ),
            transport: transport
        )

        _ = try await client.edit(
            prompt: "brighten",
            dataURLs: ["data:image/png;base64,AA"],
            aspectRatio: "1:1",
            turnID: "t"
        )
        let single = jsonBody(try #require(transport.recordedRequests.first))
        #expect(single["image"] != nil)
        #expect(single["images"] == nil)
        #expect(single["aspect_ratio"] == nil)

        _ = try await client.edit(
            prompt: "brighten",
            dataURLs: ["data:image/png;base64,AA", "data:image/png;base64,BB"],
            aspectRatio: "1:1",
            turnID: "t"
        )
        let multi = jsonBody(try #require(transport.recordedRequests.last))
        #expect(multi["image"] == nil)
        #expect((multi["images"] as? [Any])?.count == 2)
        #expect(multi["aspect_ratio"] as? String == "1:1")
    }

    @Test("OpenAI edit rejects more than five reference images")
    func openAIEditReferenceLimit() async throws {
        let transport = MockHTTPTransport()
        let client = try ImageGenClient(
            config: .enabled(
                ImageGenSettings(
                    provider: .openAI,
                    baseURL: "https://chatgpt.com/backend-api/codex",
                    bearerProvider: StubBearer(value: "codex-token")
                )
            ),
            transport: transport
        )

        let urls = (0..<6).map { "data:image/png;base64,\($0)" }
        await #expect(throws: ImageGenError.self) {
            _ = try await client.edit(
                prompt: "merge",
                dataURLs: urls,
                aspectRatio: "1:1",
                turnID: "t"
            )
        }
        #expect(transport.recordedRequests.isEmpty)
    }

    @Test("an empty data array is reported as missing image data, not a parse failure")
    func emptyDataArray() async throws {
        let transport = MockHTTPTransport(responses: [
            MockHTTPTransport.ScriptedResponse(
                metadata: HTTPResponseMetadata(statusCode: 200),
                body: Data(#"{"data":[]}"#.utf8)
            ),
        ])
        let client = try ImageGenClient(
            config: .enabled(
                ImageGenSettings(provider: .grok, apiKey: "k", baseURL: "https://api.x.ai/v1")
            ),
            transport: transport
        )

        await #expect(throws: ImageGenError.noImageData(operation: "generation")) {
            _ = try await client.generate(prompt: "x", aspectRatio: "1:1", turnID: "t")
        }
    }

    @Test("a disabled config cannot produce a client")
    func disabledConfig() {
        #expect(throws: ImageGenError.disabledConfig) {
            _ = try ImageGenClient(config: .disabled, transport: MockHTTPTransport())
        }
    }

    @Test("tier restriction applies to Grok only")
    func tierRestriction() throws {
        let grok = try ImageGenClient(
            config: .enabled(
                ImageGenSettings(
                    provider: .grok,
                    apiKey: "k",
                    baseURL: "https://api.x.ai/v1",
                    tierRestricted: true
                )
            ),
            transport: MockHTTPTransport()
        )
        #expect(grok.isTierRestricted)

        let openAI = try ImageGenClient(
            config: .enabled(
                ImageGenSettings(
                    provider: .openAI,
                    baseURL: "https://chatgpt.com/backend-api/codex",
                    bearerProvider: StubBearer(value: "t"),
                    tierRestricted: true
                )
            ),
            transport: MockHTTPTransport()
        )
        #expect(!openAI.isTierRestricted)
    }

    @Test("the pinned Codex model ignores an override; Grok honors one")
    func modelOverrides() throws {
        let openAI = try ImageGenClient(
            config: .enabled(
                ImageGenSettings(
                    provider: .openAI,
                    baseURL: "https://chatgpt.com/backend-api/codex",
                    bearerProvider: StubBearer(value: "t"),
                    modelOverride: "some-other-model"
                )
            ),
            transport: MockHTTPTransport()
        )
        #expect(openAI.model == OPENAI_IMAGE_MODEL)

        let grok = try ImageGenClient(
            config: .enabled(
                ImageGenSettings(
                    provider: .grok,
                    apiKey: "k",
                    baseURL: "https://api.x.ai/v1",
                    modelOverride: "grok-imagine-image",
                    editModelOverride: "   "
                )
            ),
            transport: MockHTTPTransport()
        )
        #expect(grok.model == "grok-imagine-image")
        // A blank override falls back rather than sending an empty model.
        #expect(grok.editModel == XAI_IMAGINE_EDIT_MODEL)
    }

    @Test("image_gen input defaults its aspect ratio to auto")
    func inputDefaults() throws {
        let input = try JSONDecoder().decode(
            ImageGenInput.self,
            from: Data(#"{"prompt":"a fox"}"#.utf8)
        )
        #expect(input.prompt == "a fox")
        #expect(input.aspectRatio == "auto")
    }
}
