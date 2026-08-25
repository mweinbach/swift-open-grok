import Foundation
import OpenGrokConfigTypes
import OpenGrokHTTP
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime
import OpenGrokWebMediaTools
import Testing
@testable import OpenGrokCLI

@Suite("Image editing resolves references without exposing local paths", .serialized)
struct LiveImageEditReferenceParityTests {
    @Test("attachment placeholders resolve only against the current session and turn")
    func currentTurnAttachmentReachesProvider() async throws {
        let fixture = try ImageReferenceFixture()
        defer { fixture.dispose() }
        let png = imageReferencePNG(width: 32, height: 32)
        fixture.resources.extras.insert(LiveImageTurnReferences(
            sessionID: "session-123",
            turnID: "turn-456",
            attachments: [PastedImage(
                displayNumber: 2,
                mimeType: "image/png",
                byteLen: png.count,
                encodedBytes: png
            )]
        ))

        let result = await fixture.invoke(reference: "[Image #2]")
        guard case .success = result else {
            Issue.record("expected image edit to succeed: \(result)")
            return
        }
        let request = try #require(fixture.transport.recordedRequests.first)
        let body = try #require(request.body)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let image = try #require(object["image"] as? [String: Any])
        #expect(image["url"] as? String == "data:image/png;base64,\(png.base64EncodedString())")
        #expect(!String(decoding: body, as: UTF8.self).contains("[Image #2]"))
        #expect(request.headers[IMAGE_GENERATION_SESSION_ID_HEADER] == "session-123")
    }

    @Test("workspace paths become provider-safe image data URLs")
    func workspacePathNeverLeavesMachine() async throws {
        let fixture = try ImageReferenceFixture()
        defer { fixture.dispose() }
        let path = fixture.workspace.appendingPathComponent("private-reference.png")
        try imageReferencePNG(width: 64, height: 64).write(to: path)

        let result = await fixture.invoke(reference: path.path)
        guard case .success = result else {
            Issue.record("expected workspace image to resolve: \(result)")
            return
        }
        let body = try #require(fixture.transport.recordedRequests.first?.body)
        let string = String(decoding: body, as: UTF8.self)
        #expect(string.contains("data:image/png;base64,"))
        #expect(!string.contains("private-reference.png"))
        #expect(!string.contains(fixture.workspace.path))
    }

    @Test("missing, stale, and foreign-session attachment tokens never reach the provider")
    func staleAttachmentsFailClosed() async throws {
        let fixture = try ImageReferenceFixture()
        defer { fixture.dispose() }
        let png = imageReferencePNG(width: 32, height: 32)
        fixture.resources.extras.insert(LiveImageTurnReferences(
            sessionID: "other-session",
            turnID: "old-turn",
            attachments: [PastedImage(displayNumber: 1, mimeType: "image/png", byteLen: png.count, encodedBytes: png)]
        ))

        let result = await fixture.invoke(reference: "[Image #1]")
        guard case .failure(let error) = result else {
            Issue.record("foreign-session attachments must be denied")
            return
        }
        #expect(error.kind == .invalidArguments)
        #expect(error.detail.contains("re-attach"))
        #expect(fixture.transport.recordedRequests.isEmpty)
    }

    @Test("filesystem escapes and symlink references never reach the provider")
    func unsafePathsFailClosed() async throws {
        let fixture = try ImageReferenceFixture()
        defer { fixture.dispose() }
        let outside = fixture.root.appendingPathComponent("outside.png")
        try imageReferencePNG(width: 32, height: 32).write(to: outside)
        let link = fixture.workspace.appendingPathComponent("linked.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        for value in [outside.path, link.path, "https://example.invalid/private.png"] {
            let result = await fixture.invoke(reference: value)
            guard case .failure = result else {
                Issue.record("unsafe reference was accepted: \(value)")
                continue
            }
        }
        #expect(fixture.transport.recordedRequests.isEmpty)
    }

    @Test("oversized image dimensions are rejected before decoding")
    func oversizedPixelHeaderFailsClosed() async throws {
        let fixture = try ImageReferenceFixture()
        defer { fixture.dispose() }
        let bomb = imageReferencePNG(width: 4_000, height: 4_000)
        let result = await fixture.invoke(
            reference: "data:image/png;base64,\(bomb.base64EncodedString())"
        )
        guard case .failure(let error) = result else {
            Issue.record("oversized reference should fail before decode")
            return
        }
        #expect(error.detail.contains("too large"))
        #expect(fixture.transport.recordedRequests.isEmpty)
    }

    @Test("direct image clients refuse filesystem paths and opaque placeholders")
    func imageClientDefendsTransportBoundary() async throws {
        let fixture = try ImageReferenceFixture()
        defer { fixture.dispose() }
        for reference in ["/private/secret.png", "[Image #1]", "https://example.invalid/image.png"] {
            do {
                _ = try await fixture.client.edit(
                    prompt: "edit",
                    dataURLs: [reference],
                    aspectRatio: "auto",
                    turnID: "turn"
                )
                Issue.record("unsafe image reference crossed transport boundary")
            } catch let error as ImageGenError {
                guard case .invalidArguments = error else {
                    Issue.record("unexpected image error: \(error)")
                    continue
                }
            }
        }
        #expect(fixture.transport.recordedRequests.isEmpty)
    }

    @Test("remote image disable and per-tool denial outrank user environment")
    func remoteImagePolicyCannotBeOverridden() throws {
        let fixture = try ImageReferenceFixture()
        defer { fixture.dispose() }
        var remote = RemoteSettings()
        remote.imageGenEnabled = false
        let disabled = fixture.availability(remote: remote)
        #expect(!disabled.imageGenEnabled)
        #expect(!disabled.imageEditEnabled)

        remote.imageGenEnabled = true
        remote.imagineToolsDisabled = [IMAGE_EDIT_TOOL_NAME]
        let partial = fixture.availability(remote: remote)
        #expect(partial.imageGenEnabled)
        #expect(!partial.imageEditEnabled)
    }

    @Test("upstream attachment token spellings resolve consistently")
    func attachmentTokenGrammar() {
        #expect(LiveImageReferenceResolver.attachmentNumber("[Image #1]") == 1)
        #expect(LiveImageReferenceResolver.attachmentNumber("image #2") == 2)
        #expect(LiveImageReferenceResolver.attachmentNumber("#3") == 3)
        #expect(LiveImageReferenceResolver.attachmentNumber("#0") == nil)
        #expect(LiveImageReferenceResolver.attachmentNumber("image.png") == nil)
    }
}

private struct ImageReferenceFixture {
    let root: URL
    let workspace: URL
    let session: URL
    let transport: MockHTTPTransport
    let client: ImageGenClient
    let resources: ToolResources

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-image-reference-\(UUID().uuidString)")
        workspace = root.appendingPathComponent("workspace")
        session = root.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(statusCode: 200),
                body: Data(#"{"data":[{"b64_json":"AQID"}]}"#.utf8)
            )
        ])
        client = try ImageGenClient(
            config: .enabled(ImageGenSettings(
                provider: .grok,
                apiKey: "image-test-secret",
                baseURL: "https://api.x.ai/v1"
            )),
            transport: transport
        )
        resources = ToolResources(
            cwd: workspace.path,
            sessionFolder: session.path,
            sessionId: "session-123",
            allowedRoots: [workspace.path]
        )
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func invoke(reference: String) async -> Result<TypedToolOutput, ToolError> {
        await LiveImageToolHandler(client: client).invoke(
            clientName: IMAGE_EDIT_TOOL_NAME,
            args: .object([
                "prompt": .string("make it brighter"),
                "image": .array([.string(reference)]),
            ]),
            ctx: ToolCallContext(),
            resources: resources
        )
    }

    func availability(remote: RemoteSettings) -> LiveImageToolAvailability {
        LiveImageToolComposition.resolveAvailability(
            workingDirectory: workspace,
            openGrokHome: root,
            environment: [
                "HOME": root.path,
                "XAI_API_KEY": "test-key",
                "GROK_IMAGE_GEN": "true",
                "GROK_IMAGE_EDIT": "true",
            ],
            samplingProvider: .xai,
            samplingAPIKey: "test-key",
            samplingBaseURL: "https://api.x.ai/v1",
            remoteSettings: remote
        )
    }
}

private func imageReferencePNG(width: UInt32, height: UInt32) -> Data {
    Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        UInt8((width >> 24) & 0xFF), UInt8((width >> 16) & 0xFF),
        UInt8((width >> 8) & 0xFF), UInt8(width & 0xFF),
        UInt8((height >> 24) & 0xFF), UInt8((height >> 16) & 0xFF),
        UInt8((height >> 8) & 0xFF), UInt8(height & 0xFF),
        0x08, 0x02, 0x00, 0x00, 0x00,
    ])
}
