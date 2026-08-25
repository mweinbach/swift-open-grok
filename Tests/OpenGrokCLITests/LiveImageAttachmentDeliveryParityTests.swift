import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokTerminalCore
import OpenGrokTestSupport
import Testing
@testable import OpenGrokCLI

@Suite("Pasted images reach the genuine live model request", .serialized)
struct LiveImageAttachmentDeliveryParityTests {
    @Test("real controller and live shell deliver image bytes to the sampler and session record")
    func pastedImageReachesSamplerAndPersistence() async throws {
        let fixture = try LiveImageAttachmentFixture(modelID: "grok-4.5")
        defer { fixture.dispose() }
        let capture = LiveImageAttachmentSamplerCapture()
        let stack = try await fixture.makeStack(capture: capture)
        let image = liveImageAttachmentPNG(width: 32, height: 32)
        let renderer = LiveImageAttachmentRenderer()
        let controller = fixture.makeController(
            stack: stack,
            renderer: renderer,
            events: [
                .paste("Describe "),
                .paste(encodeWrapImagePayload(data: image, mimeType: "image/png")),
                .key(KeyEvent(key: .enter)),
            ],
            finishAfterTurn: true
        )

        let result = try await controller.run(.init(prompt: "", mode: .inline))
        let request = try #require(await capture.requests.first)
        let user = try #require(request.items.last.flatMap { item -> UserItem? in
            guard case .user(let user) = item else { return nil }
            return user
        })
        let expectedImage = "data:image/png;base64,\(image.base64EncodedString())"

        #expect(result.completedTurnCount == 1)
        #expect(user.syntheticReason == nil)
        #expect(user.content == [
            .text(text: "Describe [Image #1]"),
            .image(url: expectedImage),
        ])
        #expect(!request.prompt.contains(image.base64EncodedString()))

        let persisted = try await LiveConversationStore(openGrokHome: fixture.home)
            .loadIfPresent(sessionID: stack.foundation.sessionID)
        let persistedUser = try #require(persisted?.items.first(where: { item in
            guard case .user(let candidate) = item else { return false }
            return candidate.content.contains(.image(url: expectedImage))
        }))
        guard case .user(let persistedContent) = persistedUser else {
            Issue.record("persisted image must remain on the genuine user turn")
            return
        }
        #expect(persistedContent.syntheticReason == nil)
        #expect(persistedContent.content == user.content)
        #expect(await controller.state().prompt.pastedImages.isEmpty)
        await stack.foundation.toolExecutor.shutdown()
    }

    @Test("a real text-only GLM route retains the image draft and never samples")
    func textOnlyModelRejectsBeforeQueueing() async throws {
        let fixture = try LiveImageAttachmentFixture(modelID: "glm-5.2")
        defer { fixture.dispose() }
        let capture = LiveImageAttachmentSamplerCapture()
        let stack = try await fixture.makeStack(capture: capture)
        let image = liveImageAttachmentPNG(width: 32, height: 32)
        let renderer = LiveImageAttachmentRenderer()
        let controller = fixture.makeController(
            stack: stack,
            renderer: renderer,
            events: [
                .paste("Keep "),
                .paste(encodeWrapImagePayload(data: image, mimeType: "image/png")),
                .key(KeyEvent(key: .enter)),
            ]
        )

        let result = try await controller.run(.init(prompt: "", mode: .inline))
        let draft = await controller.state().prompt

        #expect(result.submittedPrompts.isEmpty)
        #expect(await capture.requests.isEmpty)
        #expect(draft.text == "Keep [Image #1]")
        #expect(draft.pastedImages.first?.encodedBytes == image)
        #expect(await renderer.notices.contains(LivePromptImageCapability.textOnlyError))
        #expect(await stack.agent.conversationHistory.items.isEmpty)
        await stack.foundation.toolExecutor.shutdown()
    }

    @Test("invalid decoded dimensions never become a provider request")
    func invalidDimensionsRemainInComposer() async throws {
        let fixture = try LiveImageAttachmentFixture(modelID: "grok-4.5")
        defer { fixture.dispose() }
        let capture = LiveImageAttachmentSamplerCapture()
        let stack = try await fixture.makeStack(capture: capture)
        let image = liveImageAttachmentPNG(width: 16, height: 16)
        let renderer = LiveImageAttachmentRenderer()
        let controller = fixture.makeController(
            stack: stack,
            renderer: renderer,
            events: [
                .paste(encodeWrapImagePayload(data: image, mimeType: "image/png")),
                .key(KeyEvent(key: .enter)),
            ]
        )

        let result = try await controller.run(.init(prompt: "", mode: .inline))

        #expect(result.submittedPrompts.isEmpty)
        #expect(await capture.requests.isEmpty)
        #expect(await controller.state().prompt.pastedImages.first?.encodedBytes == image)
        #expect(await renderer.notices.contains(
            OpenGrokPagerImageAttachmentError.imageDimensionsTooSmall.description
        ))
        await stack.foundation.toolExecutor.shutdown()
    }

    @Test(arguments: [
        "glm-5",
        "GLM-5",
        "glm-5-turbo",
        "glm-5.1",
        "glm-5.1-preview",
        "glm-5.2",
        "glm-5.2-fast",
        "glm-5.3",
        "zai:glm-5.2",
        "accounts/fireworks/models/glm-5p2",
        "accounts/fireworks/routers/glm-5p2-fast",
    ])
    func glmTextOnlyFamilyMatchesUpstream(_ model: String) {
        #expect(!LivePromptImageCapability.supports(modelID: model))
    }

    @Test(arguments: [
        "glm-5v",
        "glm-5.2v",
        "glm-5-vision",
        "grok-4",
        "grok-4.5",
        "gpt-5",
        "unknown-provider-model",
    ])
    func visionAndUnknownModelsRemainSupported(_ model: String) {
        #expect(LivePromptImageCapability.supports(modelID: model))
    }
}

private struct LiveImageAttachmentStack {
    let foundation: OpenGrokLiveApplicationLauncher.LiveSessionFoundation
    let agent: OpenGrokLiveApplicationLauncher.LiveAgentStack
}

private struct LiveImageAttachmentFixture {
    let home: URL
    let workspace: URL
    let server: MockInferenceServer
    let modelID: String
    let environment: [String: String]

    init(modelID: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-live-images-\(UUID().uuidString)",
            isDirectory: true
        )
        home = root.appendingPathComponent("home", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        server = try MockInferenceServer()
        self.modelID = modelID
        try """
        [endpoints]
        xai_api_base_url = "\(server.url)"
        """.write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "GROK_SANDBOX": "off",
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
            "XAI_API_KEY": "test-xai-key",
            "FIREWORKS_API_KEY": "test-fireworks-key",
        ]
    }

    func dispose() {
        server.stop()
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    func makeStack(capture: LiveImageAttachmentSamplerCapture) async throws
        -> LiveImageAttachmentStack {
        let command = try CLICommandParser.parseOrThrow([
            "headless", "--prompt", "hello", "--cwd", workspace.path, "--model", modelID,
        ])
        guard case .launch(let options) = command else {
            throw CLIApplicationError.failed("image fixture did not parse to a launch")
        }
        let context = CLIApplicationContext(
            environment: environment,
            streams: CLIStreams(out: { _ in }, err: { _ in }),
            control: .never
        )
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { request, _ in
                    await capture.sample(request)
                }
            }
        )
        let foundation = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: options,
            context: context,
            dependencies: dependencies
        )
        let agent = await OpenGrokLiveApplicationLauncher.makeAgentStack(
            foundation: foundation,
            context: context,
            dependencies: dependencies
        )
        return LiveImageAttachmentStack(foundation: foundation, agent: agent)
    }

    func makeController(
        stack: LiveImageAttachmentStack,
        renderer: LiveImageAttachmentRenderer,
        events: [InputEvent],
        finishAfterTurn: Bool = false
    ) -> OpenGrokPagerInteractiveController {
        let runtime = LivePagerRuntimeAdapter(
            shell: stack.agent.shell,
            cwd: stack.foundation.cwd,
            providerConfiguration: stack.foundation.providerConfiguration,
            conversationHistory: stack.agent.conversationHistory,
            conversationStore: stack.foundation.conversationStore,
            toolExecutor: stack.foundation.toolExecutor,
            compaction: stack.agent.compaction,
            modelSwitch: stack.agent.modelSwitch
        )
        let input = AsyncStream<InputEvent> { continuation in
            for event in events {
                continuation.yield(event)
            }
            guard finishAfterTurn else {
                continuation.finish()
                return
            }
            let completion = Task {
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline, !(await renderer.hasFinishedTurn) {
                    do {
                        try await Task.sleep(nanoseconds: 1_000_000)
                    } catch {
                        return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                completion.cancel()
            }
        }
        return OpenGrokPagerInteractiveController(
            input: input,
            runtime: runtime,
            renderer: renderer,
            output: LiveImageAttachmentSilentOutput()
        )
    }
}

private actor LiveImageAttachmentSamplerCapture {
    private(set) var requests: [OpenGrokLiveSamplingRequest] = []

    func sample(_ request: OpenGrokLiveSamplingRequest) -> OpenGrokLiveSamplingResponse {
        if request.turnID.hasPrefix("compaction-") {
            return OpenGrokLiveSamplingResponse(output: "compacted")
        }
        requests.append(request)
        return OpenGrokLiveSamplingResponse(output: "image received")
    }
}

private actor LiveImageAttachmentRenderer: OpenGrokPagerInteractiveRenderAdapter {
    private var events: [OpenGrokPagerInteractiveEvent] = []

    var notices: [String] {
        events.compactMap { event in
            guard case .notice(let notice) = event else { return nil }
            return notice
        }
    }

    var hasFinishedTurn: Bool {
        events.contains { event in
            guard case .turnFinished = event else { return false }
            return true
        }
    }

    func begin() {}
    func restoreTerminal() {}

    func render(_ event: OpenGrokPagerInteractiveEvent) {
        events.append(event)
    }
}

private struct LiveImageAttachmentSilentOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws {}
}

private func liveImageAttachmentPNG(width: UInt32, height: UInt32) -> Data {
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
