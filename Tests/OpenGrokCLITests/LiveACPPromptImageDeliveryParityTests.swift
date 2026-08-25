import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokSamplingTypes
import OpenGrokShared
import Testing
@testable import OpenGrokCLI

private actor LiveACPPromptImageSampler {
    private let holdFirstTurn: Bool
    private var requests: [OpenGrokLiveSamplingRequest] = []
    private var continuation: CheckedContinuation<Void, any Error>?

    init(holdFirstTurn: Bool) {
        self.holdFirstTurn = holdFirstTurn
    }

    func sample(_ request: OpenGrokLiveSamplingRequest) async throws -> OpenGrokLiveSamplingResponse {
        requests.append(request)
        if holdFirstTurn, requests.count == 1 {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, any Error>) in
                    self.continuation = continuation
                }
            } onCancel: {
                Task { await self.cancelPending() }
            }
        }
        return OpenGrokLiveSamplingResponse(output: "ACP image accepted")
    }

    func cancelPending() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    func recorded() -> [OpenGrokLiveSamplingRequest] {
        requests
    }
}

private struct LiveACPPromptImageFixture {
    let root: URL
    let home: URL
    let rootSessionID: String
    let runtime: ACPAgentRuntime
    let wireSessionID: AcpSessionId
    let sampler: LiveACPPromptImageSampler
    let components: LiveACPLaunchComponents

    init(
        modelID: String = "grok-4.5",
        holdFirstTurn: Bool = false,
        installSkill: Bool = false
    ) async throws {
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
        #if os(macOS)
        root = URL(fileURLWithPath: "/private/tmp/ogapi-\(suffix)", isDirectory: true)
        #else
        root = URL(fileURLWithPath: "/tmp/ogapi-\(suffix)", isDirectory: true)
        #endif
        home = root.appendingPathComponent("home", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        if installSkill {
            let directory = workspace
                .appendingPathComponent(".opengrok/skills/inspect-image", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try """
            ---
            name: inspect-image
            description: Inspect the attached image
            ---
            Inspect image carefully: $ARGUMENTS
            """.write(
                to: directory.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
        }

        rootSessionID = "root-image-\(suffix)"
        let sampler = LiveACPPromptImageSampler(holdFirstTurn: holdFirstTurn)
        self.sampler = sampler
        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "GROK_SANDBOX": "off",
            "XAI_API_KEY": "acp-image-test-key",
            "FIREWORKS_API_KEY": "acp-image-fireworks-key",
        ]
        let command = try CLICommandParser.parseOrThrow([
            "acp", "--cwd", workspace.path,
            "--session-id", rootSessionID,
            "--model", modelID,
        ])
        guard case .launch(let options) = command else {
            throw CLIApplicationError.failed("ACP prompt-image fixture did not parse")
        }
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { request, _ in
                    try await sampler.sample(request)
                }
            }
        )
        let launch = LiveACPLaunch(
            workingDirectory: workspace,
            openGrokHome: home,
            environment: environment,
            streams: CLIStreams(out: { _ in }, err: { _ in }),
            options: options
        )
        let components = try await OpenGrokLiveApplicationLauncher
            .liveACPServices(dependencies: dependencies)
            .makeComponents(launch)
        self.components = components
        guard let gateway = components.notificationGateway else {
            throw CLIApplicationError.failed("ACP prompt-image fixture has no gateway")
        }
        let runtime = ACPAgentRuntime(
            promptDriver: components.promptDriver,
            extensionHandler: components.extensionHandler,
            extensionNotifications: components.extensionNotifications,
            onSessionOpened: components.onSessionOpened,
            onSessionClosed: components.onSessionClosed,
            makeSessionId: { "wire-image-\(suffix)" }
        )
        self.runtime = runtime
        await gateway.attach(runtime)
        await runtime.setReverseSender { _ in }
        _ = await runtime.handle(.request(
            id: .string("initialize-prompt-images"),
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
        ))
        let opened = await runtime.handle(.request(
            id: .string("open-prompt-images"),
            method: AgentMethodNames.sessionNew,
            params: try JSONValue.encode(NewSessionRequest(cwd: workspace.path))
        ))
        guard case .response(_, let response?, nil)? = opened.last else {
            throw CLIApplicationError.failed("ACP prompt-image fixture did not open its session")
        }
        wireSessionID = try response.decode(NewSessionResponse.self).sessionId
    }

    func close() async {
        await sampler.cancelPending()
        await runtime.close()
        await components.promptDriver.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    func prompt(
        id: String,
        text: String,
        images: [OpenGrokACP.ImageContent] = [],
        sessionID: AcpSessionId? = nil
    ) async throws -> (PromptResponse?, AcpError?) {
        let blocks = [OpenGrokACP.ContentBlock.text(text)] + images.map { .image($0) }
        let request = PromptRequest(
            sessionId: sessionID ?? wireSessionID,
            prompt: blocks,
            messageId: id
        )
        let response = await runtime.handle(.request(
            id: .string("request-\(UUID().uuidString)"),
            method: AgentMethodNames.sessionPrompt,
            params: try JSONValue.encode(request)
        ))
        guard case .response(_, let value, let error)? = response.last else {
            throw CLIApplicationError.failed("ACP prompt-image response was absent")
        }
        return (try value?.decode(PromptResponse.self), error)
    }

    func waitForSamples(_ count: Int) async throws -> [OpenGrokLiveSamplingRequest] {
        for _ in 0..<200 {
            let requests = await sampler.recorded()
            if requests.count >= count { return requests }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CLIApplicationError.failed("ACP prompt image did not reach the actual sampler")
    }
}

private func liveACPPromptImagePNG(width: UInt32 = 32, height: UInt32 = 32) -> Data {
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

private func withLiveACPPromptImageFixture(
    modelID: String = "grok-4.5",
    holdFirstTurn: Bool = false,
    installSkill: Bool = false,
    body: (LiveACPPromptImageFixture) async throws -> Void
) async throws {
    let fixture = try await LiveACPPromptImageFixture(
        modelID: modelID,
        holdFirstTurn: holdFirstTurn,
        installSkill: installSkill
    )
    do {
        try await body(fixture)
        await fixture.close()
    } catch {
        await fixture.close()
        throw error
    }
}

@Suite("ACP session/prompt genuine provider image delivery", .serialized)
struct LiveACPPromptImageDeliveryParityTests {
    @Test("authenticated wire-session image reaches the genuine root-provider user item and persistence")
    func imageReachesRealSamplerAndDurableUserMessage() async throws {
        try await withLiveACPPromptImageFixture { fixture in
            let image = liveACPPromptImagePNG()
            let response = try await fixture.prompt(
                id: "genuine-acp-image-turn",
                text: "Describe this image",
                images: [ImageContent(data: image.base64EncodedString(), mimeType: "image/png")]
            )
            #expect(response.1 == nil)
            #expect(response.0?.stopReason == .endTurn)
            #expect(fixture.wireSessionID.rawValue != fixture.rootSessionID)

            let request = try #require(try await fixture.waitForSamples(1).first)
            let item = try #require(request.items.last)
            guard case .user(let user) = item else {
                Issue.record("ACP image was not attached to the real provider user item")
                return
            }
            let expected = "data:image/png;base64,\(image.base64EncodedString())"
            #expect(user.syntheticReason == nil)
            #expect(user.content == [.text(text: "Describe this image"), .image(url: expected)])
            #expect(!request.prompt.contains(image.base64EncodedString()))

            let saved = try await LiveConversationStore(openGrokHome: fixture.home)
                .load(sessionID: fixture.rootSessionID)
            let persisted = try #require(saved.items.first { item in
                guard case .user(let candidate) = item else { return false }
                return candidate.content.contains(.image(url: expected))
            })
            guard case .user(let durable) = persisted else { return }
            #expect(durable.syntheticReason == nil)
        }
    }

    @Test("expanded ACP skill prompts retain the original image on the genuine provider turn")
    func expandedSkillDoesNotDiscardImageBlocks() async throws {
        try await withLiveACPPromptImageFixture(installSkill: true) { fixture in
            let image = liveACPPromptImagePNG()
            let response = try await fixture.prompt(
                id: "skill-acp-image-turn",
                text: "/inspect-image details",
                images: [ImageContent(data: image.base64EncodedString(), mimeType: "image/png")]
            )
            #expect(response.1 == nil)
            #expect(response.0?.stopReason == .endTurn)
            let request = try #require(try await fixture.waitForSamples(1).first)
            let item = try #require(request.items.last)
            guard case .user(let user) = item else {
                Issue.record("expanded ACP skill did not retain its genuine user turn")
                return
            }
            #expect(item.textContent().contains("<skill_information>"))
            #expect(user.content.contains(.image(
                url: "data:image/png;base64,\(image.base64EncodedString())"
            )))
        }
    }

    @Test("text-only model refuses image prompts before sampler admission")
    func textOnlyModelCannotReceiveACPImage() async throws {
        try await withLiveACPPromptImageFixture(modelID: "glm-5.2") { fixture in
            let image = liveACPPromptImagePNG()
            let response = try await fixture.prompt(
                id: "text-only-acp-image-turn",
                text: "This model must refuse",
                images: [ImageContent(data: image.base64EncodedString(), mimeType: "image/png")]
            )
            #expect(response.1 == nil)
            #expect(response.0?.stopReason == .refusal)
            #expect(await fixture.sampler.recorded().isEmpty)
            let notifications = await fixture.runtime.pollNotifications()
            let complete = try #require(notifications.first {
                $0.method == "x.ai/session/prompt_complete"
            })
            #expect(complete.params?["agentResult"]?.stringValue?
                .contains(LivePromptImageCapability.textOnlyError) == true)
        }
    }

    @Test("foreign sessions, URI images, invalid bytes, and mismatched MIME never sample")
    func unauthorizedAndInvalidImagesFailClosed() async throws {
        try await withLiveACPPromptImageFixture { fixture in
            let valid = liveACPPromptImagePNG()
            let foreign = try await fixture.prompt(
                id: "foreign-image-turn",
                text: "do not cross sessions",
                images: [ImageContent(data: valid.base64EncodedString(), mimeType: "image/png")],
                sessionID: AcpSessionId("another-wire-session")
            )
            #expect(foreign.0 == nil)
            #expect(foreign.1 != nil)

            let invalid = [
                ImageContent(
                    data: valid.base64EncodedString(),
                    mimeType: "image/png",
                    uri: "file:///private/secret.png"
                ),
                ImageContent(data: "invalid-base64!", mimeType: "image/png"),
                ImageContent(data: valid.base64EncodedString(), mimeType: "image/jpeg"),
                ImageContent(
                    data: liveACPPromptImagePNG(width: 8, height: 8).base64EncodedString(),
                    mimeType: "image/png"
                ),
            ]
            for (index, image) in invalid.enumerated() {
                let result = try await fixture.prompt(
                    id: "invalid-image-\(index)",
                    text: "reject invalid image",
                    images: [image]
                )
                #expect(result.0?.stopReason == .refusal)
            }
            #expect(await fixture.sampler.recorded().isEmpty)
        }
    }

    @Test("cancelling an image turn never leaks its staged bytes into a later genuine user turn")
    func cancellationClearsImageStagingBeforePromptReuse() async throws {
        try await withLiveACPPromptImageFixture(holdFirstTurn: true) { fixture in
            let image = liveACPPromptImagePNG()
            let running = Task {
                try await fixture.prompt(
                    id: "reused-acp-prompt",
                    text: "cancel this image",
                    images: [ImageContent(data: image.base64EncodedString(), mimeType: "image/png")]
                )
            }
            _ = try await fixture.waitForSamples(1)
            _ = await fixture.runtime.handle(.request(
                id: .string("cancel-image-prompt"),
                method: AgentMethodNames.sessionCancel,
                params: try JSONValue.encode(CancelNotification(sessionId: fixture.wireSessionID))
            ))
            let cancelled = try await running.value
            #expect(cancelled.0?.stopReason == .cancelled)

            let retry = try await fixture.prompt(
                id: "reused-acp-prompt",
                text: "fresh text without an image"
            )
            #expect(retry.0?.stopReason == .endTurn)
            let samples = try await fixture.waitForSamples(2)
            let retryItem = try #require(samples[1].items.last)
            guard case .user(let user) = retryItem else { return }
            #expect(user.content == [.text(text: "fresh text without an image")])
        }
    }
}
