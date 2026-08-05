// ImageToolCompositionTests.swift
//
// End-to-end composition tests for `image_gen` / `image_edit` in a live
// session: a scripted provider calls the tool, the call travels the real
// registry → permission → handler path, and the request lands on a mock
// endpoint instead of the network.
//
// The contracts pinned here are upstream's, not this port's inventions:
//   * `xai-grok-agent/src/builder.rs:771` — a tool is advertised only when the
//     resolved image config enables it.
//   * `MvpAgent::prepare_image_gen_config` (`agent_ops.rs:2271`) — the OpenAI
//     route is ChatGPT-OAuth-only, so a session with no isolated Codex
//     credentials resolves to `Disabled` and advertises nothing.
//   * `xai_media_api_key` (`agent_ops.rs:2213`) — a non-xAI sampling bearer is
//     never handed to an xAI media endpoint.

import Foundation
import OpenGrokAuth
import OpenGrokHTTP
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokToolRegistry
import OpenGrokWebMediaTools
import Testing
@testable import OpenGrokCLI

// MARK: - Fixtures

/// Scripted sampler: first turn calls one tool, second turn answers with the
/// tool result so the assertion can read what the model was actually told.
private final class ImageToolSamplerFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [OpenGrokLiveSamplingRequest] = []
    private let toolName: String
    private let arguments: String

    init(toolName: String, arguments: String) {
        self.toolName = toolName
        self.arguments = arguments
    }

    var recordedRequests: [OpenGrokLiveSamplingRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    /// Tool names advertised on the first sampling request.
    var advertisedTools: Set<String> {
        Set(recordedRequests.first?.tools.map(\.name) ?? [])
    }

    var lastToolResult: String? {
        recordedRequests.last?.items.compactMap { item -> ToolResultItem? in
            guard case .toolResult(let result) = item else { return nil }
            return result
        }.last?.content
    }

    func makeSampler() -> OpenGrokLiveSampler {
        let fixture = self
        return OpenGrokLiveSampler { request, emit in
            let index = fixture.record(request)
            if index == 0 {
                return OpenGrokLiveSamplingResponse(
                    output: "",
                    stopReason: "tool_calls",
                    items: [.assistant(AssistantItem(content: "", toolCalls: [
                        ToolCall(
                            id: "image-call-1",
                            name: fixture.toolName,
                            arguments: fixture.arguments
                        ),
                    ]))]
                )
            }
            let answer = "done"
            await emit(.output(answer))
            return OpenGrokLiveSamplingResponse(output: answer, stopReason: "stop")
        }
    }

    private func record(_ request: OpenGrokLiveSamplingRequest) -> Int {
        lock.lock(); defer { lock.unlock() }
        let index = requests.count
        requests.append(request)
        return index
    }
}

private let sampleImageBase64 = Data("PNG!".utf8).base64EncodedString()

private func scriptedImageResponse() -> MockHTTPTransport.ScriptedResponse {
    MockHTTPTransport.ScriptedResponse(
        metadata: HTTPResponseMetadata(statusCode: 200),
        body: Data(#"{"data":[{"b64_json":"\#(sampleImageBase64)"}]}"#.utf8)
    )
}

private struct ImageSessionOutcome {
    var exitCode: Int32
    var advertisedTools: Set<String>
    var toolResult: String?
    var requests: [HTTPRequest]
    var savedImages: [String]
    var root: URL
}

/// Runs a real headless session whose single turn calls an image tool.
private func runImageToolSession(
    toolName: String = "image_gen",
    arguments: String = #"{"prompt":"a red bicycle","aspect_ratio":"16:9"}"#,
    extraEnvironment: [String: String] = [:],
    responses: [MockHTTPTransport.ScriptedResponse] = [scriptedImageResponse()]
) async -> ImageSessionOutcome {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let sampler = ImageToolSamplerFixture(toolName: toolName, arguments: arguments)
    let transport = MockHTTPTransport(responses: responses)
    let dependencies = OpenGrokLiveCompositionDependencies(
        makeSampler: { _ in sampler.makeSampler() },
        makeImageTransport: { transport }
    )
    let application = OpenGrokApplication.live(dependencies: dependencies, control: .never)
    let (streams, _, _) = CLIStreams.buffered()

    var environment = [
        "HOME": root.path,
        "OPENGROK_HOME": root.appendingPathComponent("state").path,
        "XAI_API_KEY": "test-xai-key",
        "GROK_XAI_API_BASE_URL": "https://images.mock.invalid/v1",
    ]
    for (key, value) in extraEnvironment {
        environment[key] = value
    }

    let code = await CLIRunner.run(
        ["headless", "--prompt", "make me a picture", "--cwd", root.path],
        environment: environment,
        streams: streams,
        application: application
    )

    let imagesDirectory = root.appendingPathComponent("images")
    let saved = ((try? FileManager.default.contentsOfDirectory(atPath: imagesDirectory.path)) ?? [])
        .sorted()

    return ImageSessionOutcome(
        exitCode: code,
        advertisedTools: sampler.advertisedTools,
        toolResult: sampler.lastToolResult,
        requests: transport.recordedRequests,
        savedImages: saved,
        root: root
    )
}

private func requestBody(_ request: HTTPRequest) -> [String: Any] {
    guard let body = request.body,
          let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    else { return [:] }
    return object
}

private func header(_ request: HTTPRequest, _ name: String) -> String? {
    request.headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
}

// MARK: - Tests

@Suite("Image tool live composition")
struct ImageToolCompositionTests {

    @Test("a Grok-credentialed session advertises and executes image_gen end to end")
    func imageGenEndToEnd() async {
        let outcome = await runImageToolSession()
        defer { try? FileManager.default.removeItem(at: outcome.root) }

        #expect(outcome.exitCode == CLIRunner.ExitCode.success.rawValue)
        #expect(outcome.advertisedTools.contains("image_gen"))
        #expect(outcome.advertisedTools.contains("image_edit"))

        #expect(outcome.requests.count == 1)
        guard let request = outcome.requests.first else {
            Issue.record("image_gen issued no request")
            return
        }
        #expect(request.url.absoluteString == "https://images.mock.invalid/v1/images/generations")
        // The xAI-provenanced session bearer, and nothing else.
        #expect(header(request, "Authorization") == "Bearer test-xai-key")
        // `x-codex-image-turn-id` is an OpenAI-route header only.
        #expect(header(request, CODEX_IMAGE_TURN_ID_HEADER) == nil)

        let body = requestBody(request)
        #expect(body["model"] as? String == XAI_IMAGINE_MODEL)
        #expect(body["prompt"] as? String == "a red bicycle")
        #expect(body["aspect_ratio"] as? String == "16:9")

        // The bytes reached disk under the session folder, numbered from 1.
        #expect(outcome.savedImages == ["1.jpg"])
        let saved = try? Data(
            contentsOf: outcome.root.appendingPathComponent("images/1.jpg")
        )
        #expect(saved == Data("PNG!".utf8))

        // History / tool-card recording: the model is told the path and size.
        #expect(outcome.toolResult?.contains("images/1.jpg") == true)
        #expect(outcome.toolResult?.contains("4 bytes") == true)
    }

    @Test("image_edit sends its references and honors the edit model override")
    func imageEditModelOverride() async {
        let outcome = await runImageToolSession(
            toolName: "image_edit",
            arguments: #"{"prompt":"make it blue","image":["data:image/png;base64,AAAA"]}"#,
            extraEnvironment: ["GROK_IMAGE_EDIT_MODEL_OVERRIDE": "grok-imagine-image-edit-next"]
        )
        defer { try? FileManager.default.removeItem(at: outcome.root) }

        #expect(outcome.requests.count == 1)
        guard let request = outcome.requests.first else {
            Issue.record("image_edit issued no request")
            return
        }
        #expect(request.url.absoluteString == "https://images.mock.invalid/v1/images/edits")
        let body = requestBody(request)
        #expect(body["model"] as? String == "grok-imagine-image-edit-next")
        // A single reference travels as `image`, not `images` — upstream only
        // switches to the array form (and sends an aspect ratio) for multi-image
        // edits.
        #expect((body["image"] as? [String: Any])?["url"] as? String
            == "data:image/png;base64,AAAA")
        #expect(body["images"] == nil)
        #expect(outcome.savedImages == ["1.jpg"])
    }

    /// `image_gen_model_override` applies to `image_gen` only; `image_edit`
    /// keeps its own model (`agent/config.rs:2744`).
    @Test("the gen model override does not leak into image_edit")
    func genOverrideDoesNotAffectEdit() async {
        let outcome = await runImageToolSession(
            toolName: "image_edit",
            arguments: #"{"prompt":"make it blue","image":["data:image/png;base64,AAAA"]}"#,
            extraEnvironment: ["GROK_IMAGE_GEN_MODEL_OVERRIDE": "grok-imagine-custom"]
        )
        defer { try? FileManager.default.removeItem(at: outcome.root) }
        guard let request = outcome.requests.first else {
            Issue.record("image_edit issued no request")
            return
        }
        #expect(requestBody(request)["model"] as? String == XAI_IMAGINE_EDIT_MODEL)
    }

    /// The credential-isolation boundary as an *availability* rule: an
    /// OpenAI-provider session with no isolated Codex credentials must not
    /// advertise the tools, and must send nothing.
    @Test("the OpenAI route refuses without isolated Codex credentials")
    func openAIWithoutCodexCredentialsRefuses() async {
        let outcome = await runImageToolSession(
            extraEnvironment: ["GROK_IMAGE_GENERATION_PROVIDER": "openai"]
        )
        defer { try? FileManager.default.removeItem(at: outcome.root) }

        #expect(!outcome.advertisedTools.contains("image_gen"))
        #expect(!outcome.advertisedTools.contains("image_edit"))
        // Nothing was sent: the wrong-credential case fails closed before any
        // request is built, so the xAI key can never reach an OpenAI endpoint.
        #expect(outcome.requests.isEmpty)
        #expect(outcome.savedImages.isEmpty)
        // The model asked for a tool that is not on its list.
        #expect(outcome.toolResult?.contains("unknown tool") == true)
    }

    @Test("GROK_IMAGE_GEN=0 drops image_gen and keeps image_edit")
    func imageGenDisabled() async {
        let outcome = await runImageToolSession(
            extraEnvironment: ["GROK_IMAGE_GEN": "0"]
        )
        defer { try? FileManager.default.removeItem(at: outcome.root) }
        #expect(!outcome.advertisedTools.contains("image_gen"))
        #expect(outcome.advertisedTools.contains("image_edit"))
        #expect(outcome.requests.isEmpty)
    }

    @Test("GROK_IMAGE_EDIT=0 drops image_edit and keeps image_gen")
    func imageEditDisabled() async {
        let outcome = await runImageToolSession(
            extraEnvironment: ["GROK_IMAGE_EDIT": "0"]
        )
        defer { try? FileManager.default.removeItem(at: outcome.root) }
        #expect(outcome.advertisedTools.contains("image_gen"))
        #expect(!outcome.advertisedTools.contains("image_edit"))
        #expect(outcome.requests.count == 1)
    }
}

@Suite("Image tool credential isolation")
struct ImageToolCredentialIsolationTests {

    /// The rule that keeps a Codex sampling token out of an Imagine request:
    /// only a provider whose session auth *is* xAI may lend its bearer.
    @Test("a non-xAI sampling bearer is never used for the Grok image route")
    func nonXaiBearerIsRefused() {
        #expect(LiveImageToolComposition.xaiMediaAPIKey(
            samplingProvider: .codex,
            samplingAPIKey: "codex-oauth-token",
            environment: [:]
        ) == nil)
        // With an xAI key of its own on the environment, the session gets that
        // key — never the Codex one.
        #expect(LiveImageToolComposition.xaiMediaAPIKey(
            samplingProvider: .codex,
            samplingAPIKey: "codex-oauth-token",
            environment: ["XAI_API_KEY": "xai-key"]
        ) == "xai-key")
        #expect(LiveImageToolComposition.xaiMediaAPIKey(
            samplingProvider: .xai,
            samplingAPIKey: "xai-session-bearer",
            environment: [:]
        ) == "xai-session-bearer")
    }

    /// `CodexCredentials::supports_image_generation` — every plan but Free.
    @Test("ChatGPT Free is refused image generation")
    func freePlanIsRefused() {
        func credentials(plan: String?) -> CodexCredentials {
            CodexCredentials(accessToken: "token", planType: plan)
        }
        #expect(!LiveImageToolComposition.supportsImageGeneration(credentials(plan: "free")))
        #expect(!LiveImageToolComposition.supportsImageGeneration(credentials(plan: "FREE")))
        #expect(LiveImageToolComposition.supportsImageGeneration(credentials(plan: "plus")))
        #expect(LiveImageToolComposition.supportsImageGeneration(credentials(plan: nil)))
    }

    /// The registry cannot import the tools target, so the two copies of the
    /// model-facing description are pinned together here instead.
    @Test("the registry descriptions match the tool implementation's")
    func descriptionParity() {
        #expect(BuiltinToolCatalog.imageGenDescription == IMAGE_GEN_DESCRIPTION)
        #expect(BuiltinToolCatalog.imageEditDescription == IMAGE_EDIT_DESCRIPTION)
        #expect(BuiltinToolCatalog.mediaTools.map(\.id)
            == [IMAGE_GEN_TOOL_NAME, IMAGE_EDIT_TOOL_NAME])
    }
}
