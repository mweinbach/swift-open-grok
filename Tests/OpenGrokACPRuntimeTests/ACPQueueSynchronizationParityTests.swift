import Foundation
import OpenGrokACP
@testable import OpenGrokACPRuntime
import OpenGrokShared
import Testing

private actor ACPQueuePromptProbe {
    private var requests: [PromptRequest] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func record(_ request: PromptRequest) async {
        requests.append(request)
        guard request.messageId == "running" else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func recorded() -> [PromptRequest] {
        requests
    }
}

private struct ACPQueuePromptDriver: ACPPromptDriver {
    let probe: ACPQueuePromptProbe

    func run(
        context: ACPPromptContext,
        emit: @escaping @Sendable (SessionNotification, ACPNotificationDisposition) async -> Void
    ) async throws -> PromptResponse {
        await probe.record(context.request)
        return PromptResponse(stopReason: .endTurn, userMessageId: context.request.messageId)
    }

    func cancel(sessionId: AcpSessionId) async {}
}

private actor ACPQueueNotificationProbe {
    private var changes: [JSONValue] = []

    func record(_ message: ACPMessage) {
        guard case .notification(let method, let params) = message,
              method == "x.ai/queue/changed"
        else { return }
        changes.append(params)
    }

    func latest() -> JSONValue? {
        changes.last
    }

    func snapshots() -> [JSONValue] {
        changes
    }
}

private actor ACPQueueInterjectionProbe {
    private var payloads: [JSONValue] = []

    func record(_ params: JSONValue) {
        payloads.append(params)
    }

    func recorded() -> [JSONValue] {
        payloads
    }
}

private struct ACPQueueInterjectionHandler: ACPAgentExtensionHandler {
    let probe: ACPQueueInterjectionProbe

    func handle(method: String, params: JSONValue) async throws -> JSONValue {
        await probe.record(params)
        return .object(["result": .object(["status": .string("queued")])])
    }
}

private struct ACPQueueFixture {
    let runtime: ACPAgentRuntime
    let sessionID: AcpSessionId
    let prompts: ACPQueuePromptProbe
    let notifications: ACPQueueNotificationProbe

    init(
        interjections: ACPQueueInterjectionProbe? = nil,
        combineQueuedPrompts: Bool = false
    ) async throws {
        let prompts = ACPQueuePromptProbe()
        let notifications = ACPQueueNotificationProbe()
        let router = interjections.map {
            ACPExtensionMethodRouter().register(
                exact: "x.ai/interject",
                handler: ACPQueueInterjectionHandler(probe: $0)
            )
        }
        let runtime = ACPAgentRuntime(
            promptDriver: ACPQueuePromptDriver(probe: prompts),
            extensionRouter: router,
            makeSessionId: { "queue-session" }
        )
        await runtime.setCombineQueuedPrompts(combineQueuedPrompts)
        await runtime.setNotificationSink { message in
            await notifications.record(message)
        }
        _ = await runtime.handle(.request(
            id: .string("queue-initialize"),
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
        ))
        let opened = await runtime.handle(.request(
            id: .string("queue-open"),
            method: AgentMethodNames.sessionNew,
            params: try JSONValue.encode(NewSessionRequest(cwd: "/tmp"))
        ))
        guard case .response(_, let response?, nil)? = opened.last else {
            throw ACPRuntimeError.transport("queue parity fixture failed to open")
        }
        self.runtime = runtime
        self.sessionID = try response.decode(NewSessionResponse.self).sessionId
        self.prompts = prompts
        self.notifications = notifications
    }

    func start(
        id: String,
        text: String,
        owner: String,
        images: [ImageContent] = [],
        kind: String = "prompt",
        metadata: AcpMeta = [:],
        textMetadata: AcpMeta? = nil
    ) throws -> Task<[ACPMessage], Never> {
        let blocks = [OpenGrokACP.ContentBlock.text(TextContent(
            text: text,
            meta: textMetadata
        ))] + images.map { .image($0) }
        var promptMetadata = metadata
        promptMetadata["promptId"] = .string(id)
        promptMetadata["clientIdentifier"] = .string(owner)
        if kind != "prompt" {
            promptMetadata["kind"] = .string(kind)
        }
        let request = PromptRequest(
            sessionId: sessionID,
            prompt: blocks,
            messageId: id,
            meta: promptMetadata
        )
        let params = try JSONValue.encode(request)
        return Task {
            await ACPLeaderRequestAuthority.$clientID.withValue(owner) {
                await runtime.handle(.request(
                    id: .string("request-\(id)"),
                    method: AgentMethodNames.sessionPrompt,
                    params: params
                ))
            }
        }
    }

    func notify(_ method: String, fields: [String: JSONValue], authority: String? = nil) async {
        var params = fields
        params["sessionId"] = .string(sessionID.rawValue)
        await ACPLeaderRequestAuthority.$clientID.withValue(authority) {
            _ = await runtime.handle(.notification(method: method, params: .object(params)))
        }
    }

    func waitForRunning() async throws {
        for _ in 0..<200 {
            if !(await prompts.recorded()).isEmpty { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ACPRuntimeError.transport("timed out waiting for the running queue prompt")
    }

    func waitForQueue(_ expected: [String]) async throws -> JSONValue {
        for _ in 0..<200 {
            if let latest = await notifications.latest(),
               (latest["entries"]?.arrayValue ?? []).compactMap({ $0["id"]?.stringValue })
                    == expected {
                return latest
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ACPRuntimeError.transport("timed out waiting for authoritative queue \(expected)")
    }

    func stopReason(_ task: Task<[ACPMessage], Never>) async throws -> StopReason {
        guard case .response(_, let response?, nil)? = await task.value.last else {
            throw ACPRuntimeError.transport("queued prompt did not receive a response")
        }
        return try response.decode(PromptResponse.self).stopReason
    }
}

@Suite("ACP authoritative prompt queue Rust parity", .serialized)
struct ACPQueueSynchronizationParityTests {
    @Test("versioned edits, stable reorder, and owner-scoped clear resolve real waiting requests")
    func editsReorderAndOwnerClearReachWaitingPrompts() async throws {
        let fixture = try await ACPQueueFixture()
        let running = try fixture.start(id: "running", text: "working", owner: "alice")
        try await fixture.waitForRunning()

        let first = try fixture.start(id: "first", text: "first old", owner: "alice")
        _ = try await fixture.waitForQueue(["first"])
        let second = try fixture.start(
            id: "second",
            text: "second",
            owner: "bob",
            images: [ImageContent(data: "aGVsbG8=", mimeType: "image/png")]
        )
        _ = try await fixture.waitForQueue(["first", "second"])
        let third = try fixture.start(id: "third", text: "third", owner: "alice")
        _ = try await fixture.waitForQueue(["first", "second", "third"])

        await fixture.notify("x.ai/queue/hold_edit", fields: ["id": .string("third")])
        await fixture.notify("x.ai/queue/release_edit", fields: ["id": .string("third")])
        await fixture.notify("x.ai/queue/hold_edit", fields: ["id": .string("first")])
        await fixture.notify("x.ai/queue/edit", fields: [
            "id": .string("first"),
            "newText": .string("first replaced"),
            "owner": .string("bob"),
        ])
        let edited = try await fixture.waitForQueue(["first", "second", "third"])
        let firstEntry = try #require(edited["entries"]?.arrayValue?.first)
        #expect(firstEntry["version"]?.uint64Value == 1)
        #expect(firstEntry["owner"]?.stringValue == "alice")
        #expect(firstEntry["lastEditor"]?.stringValue == "bob")
        #expect(firstEntry["text"]?.stringValue == "first replaced")
        #expect(edited["runningPromptId"]?.stringValue == "running")

        await fixture.notify("x.ai/queue/remove", fields: [
            "id": .string("first"),
            "expectedVersion": .number(.uint64(0)),
            "owner": .string("alice"),
        ])
        _ = try await fixture.waitForQueue(["first", "second", "third"])

        await fixture.notify("x.ai/queue/reorder", fields: [
            "orderedIds": .array([.string("third"), .string("first")]),
        ])
        let reordered = try await fixture.waitForQueue(["third", "first", "second"])
        #expect(reordered["entries"]?.arrayValue?[0]["position"]?.int64Value == 0)
        #expect(reordered["entries"]?.arrayValue?[2]["position"]?.int64Value == 2)

        await fixture.notify("x.ai/queue/clear", fields: ["owner": .string("alice")])
        _ = try await fixture.waitForQueue(["second"])
        #expect(try await fixture.stopReason(first) == .cancelled)
        #expect(try await fixture.stopReason(third) == .cancelled)
        await fixture.notify("x.ai/queue/edit", fields: [
            "id": .string("second"),
            "newText": .string("second edited"),
            "owner": .string("bob"),
        ])

        await fixture.prompts.release()
        #expect(try await fixture.stopReason(running) == .endTurn)
        #expect(try await fixture.stopReason(second) == .endTurn)
        let requests = await fixture.prompts.recorded()
        #expect(requests.compactMap(\.messageId) == ["running", "second"])
        #expect(requests[1].prompt == [
            .text("second edited"),
            .image(ImageContent(data: "aGVsbG8=", mimeType: "image/png")),
        ])
        await fixture.runtime.close()
    }

    @Test("send-now forwards the queued content, including images, through the real extension router")
    func queuedInterjectionRetainsImageContent() async throws {
        let interjections = ACPQueueInterjectionProbe()
        let fixture = try await ACPQueueFixture(interjections: interjections)
        let running = try fixture.start(id: "running", text: "working", owner: "alice")
        try await fixture.waitForRunning()
        let image = ImageContent(data: "aGVsbG8=", mimeType: "image/png")
        let queued = try fixture.start(
            id: "image-prompt",
            text: "look here",
            owner: "alice",
            images: [image]
        )
        _ = try await fixture.waitForQueue(["image-prompt"])

        await fixture.notify("x.ai/queue/interject", fields: [
            "id": .string("image-prompt"),
            "expectedVersion": .number(.uint64(0)),
            "owner": .string("alice"),
            "newText": .string("look again"),
        ])
        _ = try await fixture.waitForQueue([])
        let delivered = try #require(await interjections.recorded().first)
        #expect(delivered["sessionId"]?.stringValue == fixture.sessionID.rawValue)
        #expect(delivered["interjectionId"]?.stringValue == "image-prompt")
        #expect(delivered["text"]?.stringValue == "look again")
        #expect(delivered["content"]?.arrayValue?[0]["text"]?.stringValue == "look again")
        #expect(delivered["content"]?.arrayValue?[1]["type"]?.stringValue == "image")
        #expect(delivered["content"]?.arrayValue?[1]["data"]?.stringValue == "aGVsbG8=")
        #expect(try await fixture.stopReason(queued) == .cancelled)

        await fixture.prompts.release()
        #expect(try await fixture.stopReason(running) == .endTurn)
        await fixture.runtime.close()
    }

    @Test("foreign-authority and replayed queue notifications cannot mutate another owner's prompts")
    func authorityAndReplayFailClosed() async throws {
        let fixture = try await ACPQueueFixture()
        await fixture.runtime.setSessionOwnerVerifier { _, client in client == "alice" }
        let running = try fixture.start(id: "running", text: "working", owner: "alice")
        try await fixture.waitForRunning()
        let queued = try fixture.start(id: "private", text: "owner only", owner: "alice")
        _ = try await fixture.waitForQueue(["private"])

        await fixture.notify("x.ai/queue/clear", fields: [:], authority: "mallory")
        _ = try await fixture.waitForQueue(["private"])
        await fixture.notify("x.ai/queue/remove", fields: [
            "id": .string("private"),
            "_meta": .object(["x.ai/replayed": .bool(true)]),
        ], authority: "alice")
        _ = try await fixture.waitForQueue(["private"])

        await fixture.prompts.release()
        #expect(try await fixture.stopReason(running) == .endTurn)
        #expect(try await fixture.stopReason(queued) == .endTurn)
        await fixture.runtime.close()
    }

    @Test("enabled promotion combines same-owner text, retains front images, and resolves merged rows")
    func combinePromotionPreservesImagesAndDisplayIdentity() async throws {
        let fixture = try await ACPQueueFixture(combineQueuedPrompts: true)
        let running = try fixture.start(id: "running", text: "working", owner: "alice")
        try await fixture.waitForRunning()

        let image = ImageContent(data: "aGVsbG8=", mimeType: "image/png")
        let first = try fixture.start(
            id: "first",
            text: "first prompt",
            owner: "alice",
            images: [image]
        )
        let firstQueue = try await fixture.waitForQueue(["first"])
        #expect(firstQueue["entries"]?.arrayValue?.count == 1)
        let second = try fixture.start(id: "second", text: "second prompt", owner: "alice")
        let secondQueue = try await fixture.waitForQueue(["first", "second"])
        #expect(secondQueue["entries"]?.arrayValue?.count == 2)
        let third = try fixture.start(id: "third", text: "third prompt", owner: "alice")
        let thirdQueue = try await fixture.waitForQueue(["first", "second", "third"])
        #expect(thirdQueue["entries"]?.arrayValue?.count == 3)

        await fixture.prompts.release()
        #expect(try await fixture.stopReason(running) == .endTurn)
        #expect(try await fixture.stopReason(first) == .endTurn)
        #expect(try await fixture.stopReason(second) == .cancelled)
        #expect(try await fixture.stopReason(third) == .cancelled)

        let requests = await fixture.prompts.recorded()
        #expect(requests.compactMap(\.messageId) == ["running", "first"])
        let combined = try #require(requests.last)
        #expect(combined.prompt.count == 2)
        guard case .text(let text) = combined.prompt[0] else {
            Issue.record("combined prompt lost its text block")
            return
        }
        #expect(text.text == "first prompt\n\nsecond prompt\n\nthird prompt")
        #expect(text.meta?["combinedDisplayTexts"]?.arrayValue == [
            .string("first prompt"),
            .string("second prompt"),
            .string("third prompt"),
        ])
        #expect(combined.prompt[1] == .image(image))

        let changes = await fixture.notifications.snapshots()
        let runningChange = try #require(changes.first { change in
            change["runningPromptId"]?.stringValue == "first"
                && change["runningCombinedTexts"]?.arrayValue?.count == 3
        })
        #expect(runningChange["runningText"]?.stringValue
            == "first prompt\n\nsecond prompt\n\nthird prompt")
        #expect(runningChange["entries"]?.arrayValue?.isEmpty == true)
        await fixture.runtime.close()
    }

    @Test("disabled combination keeps each queued request and response independent")
    func disabledCombinationPreservesIndividualTurns() async throws {
        let fixture = try await ACPQueueFixture(combineQueuedPrompts: false)
        let running = try fixture.start(id: "running", text: "working", owner: "alice")
        try await fixture.waitForRunning()

        let first = try fixture.start(id: "first", text: "first", owner: "alice")
        let firstQueue = try await fixture.waitForQueue(["first"])
        #expect(firstQueue["entries"]?.arrayValue?.count == 1)
        let second = try fixture.start(id: "second", text: "second", owner: "alice")
        let secondQueue = try await fixture.waitForQueue(["first", "second"])
        #expect(secondQueue["entries"]?.arrayValue?.count == 2)

        await fixture.prompts.release()
        #expect(try await fixture.stopReason(running) == .endTurn)
        #expect(try await fixture.stopReason(first) == .endTurn)
        #expect(try await fixture.stopReason(second) == .endTurn)
        let requests = await fixture.prompts.recorded()
        #expect(requests.compactMap(\.messageId) == ["running", "first", "second"])
        #expect(requests[1].prompt == [.text("first")])
        #expect(requests[2].prompt == [.text("second")])
        await fixture.runtime.close()
    }

    @Test("changing the effective queue setting before promotion changes only the next turn")
    func updatedCombinationSettingIsSampledAtPromotion() async throws {
        let fixture = try await ACPQueueFixture(combineQueuedPrompts: false)
        let running = try fixture.start(id: "running", text: "working", owner: "alice")
        try await fixture.waitForRunning()

        let first = try fixture.start(id: "first", text: "first", owner: "alice")
        let firstQueue = try await fixture.waitForQueue(["first"])
        #expect(firstQueue["entries"]?.arrayValue?.count == 1)
        let second = try fixture.start(id: "second", text: "second", owner: "alice")
        let secondQueue = try await fixture.waitForQueue(["first", "second"])
        #expect(secondQueue["entries"]?.arrayValue?.count == 2)

        await fixture.runtime.setCombineQueuedPrompts(true)
        await fixture.prompts.release()
        #expect(try await fixture.stopReason(running) == .endTurn)
        #expect(try await fixture.stopReason(first) == .endTurn)
        #expect(try await fixture.stopReason(second) == .cancelled)
        let requests = await fixture.prompts.recorded()
        #expect(requests.compactMap(\.messageId) == ["running", "first"])
        guard case .text(let combined) = requests[1].prompt[0] else {
            Issue.record("live setting update did not promote a text prompt")
            return
        }
        #expect(combined.text == "first\n\nsecond")
        await fixture.runtime.close()
    }

    @Test("cancelling one waiting request removes only that row before combining its neighbors")
    func cancellingQueuedRequestPreservesRemainingAdmission() async throws {
        let fixture = try await ACPQueueFixture(combineQueuedPrompts: true)
        let running = try fixture.start(id: "running", text: "working", owner: "alice")
        try await fixture.waitForRunning()

        let first = try fixture.start(id: "first", text: "first", owner: "alice")
        let firstQueue = try await fixture.waitForQueue(["first"])
        #expect(firstQueue["entries"]?.arrayValue?.count == 1)
        let cancelled = try fixture.start(id: "cancelled", text: "cancelled", owner: "alice")
        let cancelledQueue = try await fixture.waitForQueue(["first", "cancelled"])
        #expect(cancelledQueue["entries"]?.arrayValue?.count == 2)
        let last = try fixture.start(id: "last", text: "last", owner: "alice")
        let lastQueue = try await fixture.waitForQueue(["first", "cancelled", "last"])
        #expect(lastQueue["entries"]?.arrayValue?.count == 3)

        cancelled.cancel()
        #expect(try await fixture.stopReason(cancelled) == .cancelled)
        let remaining = try await fixture.waitForQueue(["first", "last"])
        #expect(remaining["entries"]?.arrayValue?.count == 2)

        await fixture.prompts.release()
        #expect(try await fixture.stopReason(running) == .endTurn)
        #expect(try await fixture.stopReason(first) == .endTurn)
        #expect(try await fixture.stopReason(last) == .cancelled)
        let requests = await fixture.prompts.recorded()
        #expect(requests.compactMap(\.messageId) == ["running", "first"])
        guard case .text(let combined) = requests[1].prompt[0] else {
            Issue.record("surviving queue entries did not reach the real prompt driver")
            return
        }
        #expect(combined.text == "first\n\nlast")
        await fixture.runtime.close()
    }

    @Test("an editing hold on the queue front prevents promotion until its owner releases it")
    func heldFrontIsNotPromotedUntilRelease() async throws {
        let fixture = try await ACPQueueFixture(combineQueuedPrompts: true)
        let running = try fixture.start(id: "running", text: "working", owner: "alice")
        try await fixture.waitForRunning()

        let first = try fixture.start(id: "first", text: "first", owner: "alice")
        let firstQueue = try await fixture.waitForQueue(["first"])
        #expect(firstQueue["entries"]?.arrayValue?.count == 1)
        let second = try fixture.start(id: "second", text: "second", owner: "alice")
        let secondQueue = try await fixture.waitForQueue(["first", "second"])
        #expect(secondQueue["entries"]?.arrayValue?.count == 2)
        await fixture.notify("x.ai/queue/hold_edit", fields: ["id": .string("first")])

        await fixture.prompts.release()
        #expect(try await fixture.stopReason(running) == .endTurn)
        #expect((await fixture.prompts.recorded()).compactMap(\.messageId) == ["running"])

        await fixture.notify("x.ai/queue/release_edit", fields: ["id": .string("first")])
        #expect(try await fixture.stopReason(first) == .endTurn)
        #expect(try await fixture.stopReason(second) == .cancelled)
        let requests = await fixture.prompts.recorded()
        #expect(requests.compactMap(\.messageId) == ["running", "first"])
        guard case .text(let combined) = requests[1].prompt[0] else {
            Issue.record("released queue front did not preserve its text")
            return
        }
        #expect(combined.text == "first\n\nsecond")
        await fixture.runtime.close()
    }

    @Test("an editing hold on a follower stops the merge prefix without consuming that row")
    func heldFollowerStopsCombinedPrefix() async throws {
        let fixture = try await ACPQueueFixture(combineQueuedPrompts: true)
        let running = try fixture.start(id: "running", text: "working", owner: "alice")
        try await fixture.waitForRunning()

        let first = try fixture.start(id: "first", text: "first", owner: "alice")
        let firstQueue = try await fixture.waitForQueue(["first"])
        #expect(firstQueue["entries"]?.arrayValue?.count == 1)
        let held = try fixture.start(id: "held", text: "held", owner: "alice")
        let heldQueue = try await fixture.waitForQueue(["first", "held"])
        #expect(heldQueue["entries"]?.arrayValue?.count == 2)
        let last = try fixture.start(id: "last", text: "last", owner: "alice")
        let lastQueue = try await fixture.waitForQueue(["first", "held", "last"])
        #expect(lastQueue["entries"]?.arrayValue?.count == 3)
        await fixture.notify("x.ai/queue/hold_edit", fields: ["id": .string("held")])

        await fixture.prompts.release()
        #expect(try await fixture.stopReason(running) == .endTurn)
        #expect(try await fixture.stopReason(first) == .endTurn)
        #expect((await fixture.prompts.recorded()).compactMap(\.messageId) == ["running", "first"])

        await fixture.notify("x.ai/queue/release_edit", fields: ["id": .string("held")])
        #expect(try await fixture.stopReason(held) == .endTurn)
        #expect(try await fixture.stopReason(last) == .cancelled)
        let requests = await fixture.prompts.recorded()
        #expect(requests.compactMap(\.messageId) == ["running", "first", "held"])
        guard case .text(let combined) = requests[2].prompt[0] else {
            Issue.record("held follower lost its own prompt after release")
            return
        }
        #expect(combined.text == "held\n\nlast")
        await fixture.runtime.close()
    }

    @Test("owner, image, expanded-skill, special-kind, provider, and turn boundaries never merge")
    func incompatibleQueuedPromptsRemainIsolated() async throws {
        let fixture = try await ACPQueueFixture(combineQueuedPrompts: true)
        let running = try fixture.start(id: "running", text: "working", owner: "alice")
        try await fixture.waitForRunning()

        let first = try fixture.start(id: "alice", text: "alice", owner: "alice")
        let firstQueue = try await fixture.waitForQueue(["alice"])
        #expect(firstQueue["entries"]?.arrayValue?.count == 1)
        let foreign = try fixture.start(id: "bob", text: "bob", owner: "bob")
        let foreignQueue = try await fixture.waitForQueue(["alice", "bob"])
        #expect(foreignQueue["entries"]?.arrayValue?.count == 2)
        let image = ImageContent(data: "aGVsbG8=", mimeType: "image/png")
        let imagePrompt = try fixture.start(
            id: "image",
            text: "with image",
            owner: "bob",
            images: [image]
        )
        let imageQueue = try await fixture.waitForQueue(["alice", "bob", "image"])
        #expect(imageQueue["entries"]?.arrayValue?.count == 3)
        let expanded = try fixture.start(
            id: "expanded",
            text: "expanded body",
            owner: "bob",
            textMetadata: ["displayText": .string("/skill")]
        )
        let expandedQueue = try await fixture.waitForQueue(["alice", "bob", "image", "expanded"])
        #expect(expandedQueue["entries"]?.arrayValue?.count == 4)
        let special = try fixture.start(
            id: "special",
            text: "scheduled",
            owner: "bob",
            kind: "cron"
        )
        let specialQueue = try await fixture.waitForQueue([
            "alice", "bob", "image", "expanded", "special",
        ])
        #expect(specialQueue["entries"]?.arrayValue?.count == 5)
        let firstProvider = try fixture.start(
            id: "provider-a",
            text: "provider a",
            owner: "bob",
            metadata: ["provider": .string("xai"), "turnId": .number(.int64(7))]
        )
        let providerQueue = try await fixture.waitForQueue([
            "alice", "bob", "image", "expanded", "special", "provider-a",
        ])
        #expect(providerQueue["entries"]?.arrayValue?.count == 6)
        let secondProvider = try fixture.start(
            id: "provider-b",
            text: "provider b",
            owner: "bob",
            metadata: ["provider": .string("codex"), "turnId": .number(.int64(7))]
        )
        let secondProviderQueue = try await fixture.waitForQueue([
            "alice", "bob", "image", "expanded", "special", "provider-a", "provider-b",
        ])
        #expect(secondProviderQueue["entries"]?.arrayValue?.count == 7)
        let differentTurn = try fixture.start(
            id: "turn-b",
            text: "different turn",
            owner: "bob",
            metadata: ["provider": .string("codex"), "turnId": .number(.int64(8))]
        )
        let finalQueue = try await fixture.waitForQueue([
            "alice", "bob", "image", "expanded", "special", "provider-a", "provider-b", "turn-b",
        ])
        #expect(finalQueue["entries"]?.arrayValue?.count == 8)

        await fixture.prompts.release()
        for task in [running, first, foreign, imagePrompt, expanded, special,
                     firstProvider, secondProvider, differentTurn] {
            #expect(try await fixture.stopReason(task) == .endTurn)
        }

        let requests = await fixture.prompts.recorded()
        #expect(requests.compactMap(\.messageId) == [
            "running", "alice", "bob", "image", "expanded", "special",
            "provider-a", "provider-b", "turn-b",
        ])
        #expect(requests[3].prompt[1] == .image(image))
        await fixture.runtime.close()
    }

    @Test("combination cannot exceed the existing bounded queued-prompt text budget")
    func combinedPromptRetainsMaximumTextBound() async throws {
        let fixture = try await ACPQueueFixture(combineQueuedPrompts: true)
        let running = try fixture.start(id: "running", text: "working", owner: "alice")
        try await fixture.waitForRunning()

        let first = try fixture.start(
            id: "first",
            text: String(repeating: "a", count: 80_000),
            owner: "alice"
        )
        let firstQueue = try await fixture.waitForQueue(["first"])
        #expect(firstQueue["entries"]?.arrayValue?.count == 1)
        let second = try fixture.start(
            id: "second",
            text: String(repeating: "b", count: 80_000),
            owner: "alice"
        )
        let secondQueue = try await fixture.waitForQueue(["first", "second"])
        #expect(secondQueue["entries"]?.arrayValue?.count == 2)

        await fixture.prompts.release()
        #expect(try await fixture.stopReason(running) == .endTurn)
        #expect(try await fixture.stopReason(first) == .endTurn)
        #expect(try await fixture.stopReason(second) == .endTurn)
        let requests = await fixture.prompts.recorded()
        #expect(requests.compactMap(\.messageId) == ["running", "first", "second"])
        await fixture.runtime.close()
    }
}
