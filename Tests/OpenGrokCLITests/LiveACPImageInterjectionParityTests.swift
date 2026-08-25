import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokSamplingTypes
import OpenGrokShared
import Testing
@testable import OpenGrokCLI

private actor LiveACPImageProviderProbe {
    private let interjections: LiveSessionInterjections
    private let modelID: String
    private let holdFirstTurn: Bool
    private var startedPrompts: [PromptRequest] = []
    private var providerItems: [[ConversationItem]] = []
    private var continuation: CheckedContinuation<Void, Never>?

    init(
        interjections: LiveSessionInterjections,
        modelID: String,
        holdFirstTurn: Bool
    ) {
        self.interjections = interjections
        self.modelID = modelID
        self.holdFirstTurn = holdFirstTurn
    }

    func run(_ context: ACPPromptContext) async -> PromptResponse {
        await interjections.beginTurn(sessionID: context.session.sessionId.rawValue)
        startedPrompts.append(context.request)
        if holdFirstTurn, startedPrompts.count == 1 {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        let items = await interjections.drainConversationItems(modelID: modelID)
        providerItems.append(items)
        await interjections.endTurn()
        return PromptResponse(stopReason: .endTurn, userMessageId: context.request.messageId)
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func starts() -> [PromptRequest] {
        startedPrompts
    }

    func samples() -> [[ConversationItem]] {
        providerItems
    }
}

private struct LiveACPImagePromptDriver: ACPPromptDriver {
    let probe: LiveACPImageProviderProbe

    func run(
        context: ACPPromptContext,
        emit: @escaping @Sendable (SessionNotification, ACPNotificationDisposition) async -> Void
    ) async throws -> PromptResponse {
        await probe.run(context)
    }

    func cancel(sessionId: AcpSessionId) async {}
}

private struct LiveACPImageFixture {
    let runtime: ACPAgentRuntime
    let sessionID: AcpSessionId
    let gateway: ACPNotificationGateway
    let probe: LiveACPImageProviderProbe

    init(modelID: String = "grok-4.5", holdFirstTurn: Bool = false) async throws {
        let gateway = ACPNotificationGateway()
        let interjections = LiveSessionInterjections()
        let probe = LiveACPImageProviderProbe(
            interjections: interjections,
            modelID: modelID,
            holdFirstTurn: holdFirstTurn
        )
        let handler = LiveACPInterjectionHandler(
            gateway: gateway,
            interjections: interjections
        )
        let notificationRouter = ACPExtensionNotificationRouter().register(
            exact: LiveACPFollowUpSuggestionsHandler.method,
            handler: LiveACPFollowUpSuggestionsHandler(gateway: gateway)
        )
        let runtime = ACPAgentRuntime(
            promptDriver: LiveACPImagePromptDriver(probe: probe),
            extensionHandler: handler,
            extensionNotifications: notificationRouter,
            makeSessionId: { "image-interjection-session" }
        )
        await gateway.attach(runtime)
        await runtime.setReverseSender { _ in }
        _ = await runtime.handle(.request(
            id: .string("initialize-image-interjection"),
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
        ))
        let opened = await runtime.handle(.request(
            id: .string("open-image-interjection"),
            method: AgentMethodNames.sessionNew,
            params: try JSONValue.encode(NewSessionRequest(cwd: "/tmp"))
        ))
        guard case .response(_, let response?, nil)? = opened.last else {
            throw ACPRuntimeError.transport("image interjection fixture failed to open")
        }
        self.runtime = runtime
        self.sessionID = try response.decode(NewSessionResponse.self).sessionId
        self.gateway = gateway
        self.probe = probe
    }

    func call(_ fields: [String: JSONValue]) async -> (JSONValue?, AcpError?) {
        var params = fields
        if params["sessionId"] == nil {
            params["sessionId"] = .string(sessionID.rawValue)
        }
        let response = await runtime.handle(.request(
            id: .string("interject-image-\(UUID().uuidString)"),
            method: LiveACPInterjectionHandler.method,
            params: .object(params)
        ))
        guard case .response(_, let result, let error)? = response.last else {
            return (nil, AcpError.internalError("interjection returned no response"))
        }
        return (result, error)
    }

    func waitForStarts(_ count: Int) async throws {
        for _ in 0..<200 {
            if await probe.starts().count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ACPRuntimeError.transport("timed out waiting for image interjection turn")
    }

    func waitForSamples(_ count: Int) async throws -> [[ConversationItem]] {
        for _ in 0..<200 {
            let samples = await probe.samples()
            if samples.count >= count { return samples }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ACPRuntimeError.transport("timed out waiting for provider-visible interjection")
    }

    static func image(
        data: String = "aGVsbG8=",
        mimeType: String = "image/png",
        uri: String? = nil
    ) -> JSONValue {
        var fields: [String: JSONValue] = [
            "type": .string("image"),
            "data": .string(data),
            "mimeType": .string(mimeType),
        ]
        if let uri {
            fields["uri"] = .string(uri)
        }
        return .object(fields)
    }
}

private actor LiveFollowUpDeliveryProbe {
    private var notifications: [JSONValue] = []

    func record(_ params: JSONValue) {
        notifications.append(params)
    }

    func received() -> [JSONValue] {
        notifications
    }
}

@Suite("ACP image interjection and authenticated follow-up parity", .serialized)
struct LiveACPImageInterjectionParityTests {
    @Test("running interjections preserve validated structural images without leaking URI paths")
    func runningInterjectionCarriesImagesToProvider() async throws {
        let fixture = try await LiveACPImageFixture(holdFirstTurn: true)
        let request = PromptRequest(
            sessionId: fixture.sessionID,
            prompt: [.text("first turn")],
            messageId: "running-image-turn"
        )
        let params = try JSONValue.encode(request)
        let running = Task {
            await fixture.runtime.handle(.request(
                id: .string("running-image-request"),
                method: AgentMethodNames.sessionPrompt,
                params: params
            ))
        }
        try await fixture.waitForStarts(1)

        let response = await fixture.call([
            "text": .string("inspect [Image #1: /private/secret.png]"),
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string("inspect [Image #1: /private/secret.png]"),
                ]),
                LiveACPImageFixture.image(uri: "file:///private/attachment-secret.png"),
            ]),
        ])
        #expect(response.1 == nil)
        await fixture.probe.release()
        _ = await running.value

        let sample = try #require(try await fixture.waitForSamples(1).first)
        guard case .user(let user)? = sample.first else {
            Issue.record("image interjection did not reach provider-visible user content")
            return
        }
        #expect(user.syntheticReason == .interjection)
        #expect(user.content.count == 2)
        #expect(user.content[1] == .image(url: "data:image/png;base64,aGVsbG8="))
        #expect(!sample.first!.textContent().contains("/private/"))
        await fixture.runtime.close()
    }

    @Test("idle interjections inherit only their authenticated session's image context")
    func idleInterjectionStartsRealImageBearingTurn() async throws {
        let fixture = try await LiveACPImageFixture()
        let response = await fixture.call([
            "text": .string("idle image request"),
            "interjectionId": .string("real-idle-image-turn"),
            "content": .array([LiveACPImageFixture.image()]),
        ])
        #expect(response.1 == nil)
        let samples = try await fixture.waitForSamples(1)
        let request = try #require(await fixture.probe.starts().first)
        #expect(request.messageId == "real-idle-image-turn")
        guard case .user(let user)? = samples[0].first else {
            Issue.record("idle ACP image did not enter the authenticated provider turn")
            return
        }
        #expect(user.content.contains(.image(url: "data:image/png;base64,aGVsbG8=")))
        await fixture.runtime.close()
    }

    @Test("text-only models receive an explicit refusal and never receive structural images")
    func textOnlyModelRefusesImagesWithoutBypass() async throws {
        let fixture = try await LiveACPImageFixture(modelID: "glm-5")
        let response = await fixture.call([
            "text": .string("image on text model"),
            "content": .array([LiveACPImageFixture.image()]),
        ])
        #expect(response.1 == nil)
        let sample = try #require(try await fixture.waitForSamples(1).first)
        guard case .user(let user)? = sample.first else {
            Issue.record("text-only refusal was not delivered as provider-visible text")
            return
        }
        #expect(user.content.count == 1)
        #expect(sample.first!.textContent().contains(LivePromptImageCapability.textOnlyError))
        await fixture.runtime.close()
    }

    @Test("stranded image interjections survive FIFO fallback and cancellation cannot resurrect them")
    func strandedImagesRemainBoundToTheNextTurn() async throws {
        let interjections = LiveSessionInterjections()
        await interjections.beginTurn(sessionID: "provider-root")
        #expect(await interjections.interject(
            "late image",
            images: [ImageContent(data: "aGVsbG8=", mimeType: "image/png")]
        ))
        await interjections.endTurn()
        #expect(await interjections.collectStranded() == ["late image"])
        await interjections.beginTurn(sessionID: "provider-root")
        let fallback = await interjections.drainConversationItems(modelID: "grok-4.5")
        guard case .user(let user)? = fallback.first else {
            Issue.record("stranded fallback lost its image before the next turn")
            return
        }
        #expect(user.content.contains(.image(url: "data:image/png;base64,aGVsbG8=")))

        #expect(await interjections.interject(
            "cancelled image",
            images: [ImageContent(data: "aGVsbG8=", mimeType: "image/png")]
        ))
        await interjections.cancelTurn()
        #expect(await interjections.collectStranded().isEmpty)
    }

    @Test("unsupported MIME, malformed base64, oversized images, and image-count overflow fail closed")
    func invalidImageContentNeverStartsSampling() async throws {
        let fixture = try await LiveACPImageFixture()
        let oversized = Data(repeating: 0x61, count: 1_500_001).base64EncodedString()
        let invalid: [[JSONValue]] = [
            [LiveACPImageFixture.image(mimeType: "image/svg+xml")],
            [LiveACPImageFixture.image(data: "not-base64!")],
            [LiveACPImageFixture.image(data: oversized)],
            Array(repeating: LiveACPImageFixture.image(), count: maxPlaceholdersPerPrompt + 1),
        ]
        for images in invalid {
            let response = await fixture.call([
                "text": .string("reject the attachment"),
                "content": .array(images),
            ])
            #expect(response.0 == nil)
            #expect(response.1?.code == .invalidParams)
        }
        #expect(await fixture.probe.starts().isEmpty)
        await fixture.runtime.close()
    }

    @Test("sessionless follow-ups require unique ownership, bounded labels, and non-replayed delivery")
    func followUpNotificationsRemainConnectionAndSessionBound() async throws {
        let fixture = try await LiveACPImageFixture()
        let relay = LiveFollowUpSuggestionRelay.shared
        let probe = LiveFollowUpDeliveryProbe()
        let connection = LiveFollowUpSuggestionConnection(
            sessionID: fixture.sessionID.rawValue,
            generation: 1,
            connectionID: UUID()
        )
        await relay.register(connection) { _, params in
            await probe.record(params)
        }

        let longLabel = String(repeating: "x", count: 300)
        _ = await fixture.runtime.handle(.notification(
            method: "x.ai/follow_ups",
            params: .object([
                "response_id": .string("response-1"),
                "suggestions": .array(Array(repeating: .object([
                    "label": .string(longLabel),
                ]), count: 9)),
            ])
        ))
        let delivered = try #require(await probe.received().first)
        #expect(delivered["sessionId"]?.stringValue == fixture.sessionID.rawValue)
        #expect(delivered["suggestions"]?.arrayValue?.count == 6)
        let rendered = try #require(LiveFollowUpSuggestions.decode(
            delivered,
            authenticatedSessionID: fixture.sessionID.rawValue
        ))
        #expect(rendered.labels.first?.count == 256)

        _ = await fixture.runtime.handle(.notification(
            method: "x.ai/follow_ups",
            params: .object([
                "response_id": .string("response-replayed"),
                "_meta": .object(["x.ai/replayed": .bool(true)]),
            ])
        ))
        _ = await fixture.runtime.handle(.notification(
            method: "x.ai/follow_ups",
            params: .object([
                "sessionId": .string("another-session"),
                "response_id": .string("response-foreign"),
            ])
        ))
        for malformed in [
            JSONValue.object([
                "response_id": .string("malformed-suggestions"),
                "suggestions": .string("not-an-array"),
            ]),
            JSONValue.object([
                "response_id": .string("malformed-label"),
                "suggestions": .array([.object(["label": .bool(true)])]),
            ]),
            JSONValue.object([
                "response_id": .string("malformed-prompt"),
                "promptId": .number(.int64(1)),
            ]),
        ] {
            _ = await fixture.runtime.handle(.notification(
                method: "x.ai/follow_ups",
                params: malformed
            ))
        }
        #expect(await probe.received().count == 1)

        let other = LiveFollowUpSuggestionConnection(
            sessionID: "another-session",
            generation: 1,
            connectionID: UUID()
        )
        await relay.register(other) { _, _ in }
        _ = await fixture.runtime.handle(.notification(
            method: "x.ai/follow_ups",
            params: .object(["response_id": .string("ambiguous")])
        ))
        #expect(await probe.received().count == 1)
        await relay.unregister(other)
        await relay.unregister(connection)
        await fixture.runtime.close()
    }
}
