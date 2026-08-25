import Foundation
import OpenGrokPager
import OpenGrokPagerConversationUI
import OpenGrokPagerRender
import OpenGrokShared
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

@Suite("Live ACP follow-up suggestion reachability", .serialized)
struct LiveFollowUpSuggestionsParityTests {
    @Test("raw ACP objects enforce the authenticated session, exact wire types and replay rejection")
    func decodesAuthenticatedACPNotification() throws {
        let accepted = try #require(LiveFollowUpSuggestions.decode(
            notification(
                responseID: "response-1",
                promptID: "prompt-1",
                labels: [" \u{001B}Summarize\u{202E} "]
            ),
            authenticatedSessionID: "session-1"
        ))

        #expect(accepted.sessionID == "session-1")
        #expect(accepted.promptID == "prompt-1")
        #expect(accepted.labels == ["Summarize"])
        #expect(LiveFollowUpSuggestions.decode(
            notification(responseID: "response-1", labels: ["wrong"], sessionID: "session-2"),
            authenticatedSessionID: "session-1"
        ) == nil)
        #expect(LiveFollowUpSuggestions.decode(
            notification(responseID: "response-1", labels: ["stale"], replayed: true),
            authenticatedSessionID: "session-1"
        ) == nil)
        #expect(LiveFollowUpSuggestions.decode(
            .object(["response_id": .string("r"), "suggestions": .string("bad")]),
            authenticatedSessionID: "session-1"
        ) == nil)
        #expect(LiveFollowUpSuggestions.decode(
            .object([
                "response_id": .string("r"),
                "suggestions": .array([.object(["label": .bool(true)])]),
            ]),
            authenticatedSessionID: "session-1"
        ) == nil)
    }

    @Test("relay routes to the exact registered session and rejects stale unregister tokens")
    func relayIsSessionAndConnectionScoped() async throws {
        let relay = LiveFollowUpSuggestionRelay()
        let capture = FollowUpDeliveryCapture()
        var firstState = LiveFollowUpSuggestions()
        let initialConnection = firstState.connect(sessionID: "session-1")
        let first = try #require(initialConnection)
        await relay.register(first) { connection, params in
            await capture.record(connection: connection, params: params)
        }

        #expect(await relay.uniquelyRegisteredSessionID() == "session-1")
        await relay.publish(
            sessionID: "session-2",
            params: notification(responseID: "foreign", labels: ["wrong"])
        )
        #expect(await capture.responseIDs == [])

        await relay.publish(
            sessionID: "session-1",
            params: notification(responseID: "accepted", labels: ["right"])
        )
        #expect(await capture.responseIDs == ["accepted"])

        let replacementConnection = firstState.connect(sessionID: "session-1")
        let replacement = try #require(replacementConnection)
        await relay.register(replacement) { connection, params in
            await capture.record(connection: connection, params: params)
        }
        await relay.unregister(first)
        await relay.publish(
            sessionID: "session-1",
            params: notification(responseID: "replacement", labels: ["new"])
        )

        #expect(await capture.responseIDs == ["accepted", "replacement"])
        #expect(await capture.connectionIDs.last == replacement.connectionID)

        await relay.unregister(replacement)
        #expect(await relay.uniquelyRegisteredSessionID() == nil)
    }

    @Test("a second live session disables unsafe sessionless fallback")
    func sessionlessFallbackRequiresExactlyOneRegistration() async throws {
        let relay = LiveFollowUpSuggestionRelay()
        var firstState = LiveFollowUpSuggestions()
        var secondState = LiveFollowUpSuggestions()
        let firstConnection = firstState.connect(sessionID: "session-1")
        let secondConnection = secondState.connect(sessionID: "session-2")
        let first = try #require(firstConnection)
        let second = try #require(secondConnection)

        await relay.register(first) { _, _ in }
        #expect(await relay.uniquelyRegisteredSessionID() == "session-1")
        await relay.register(second) { _, _ in }
        #expect(await relay.uniquelyRegisteredSessionID() == nil)

        await relay.unregister(second)
        #expect(await relay.uniquelyRegisteredSessionID() == "session-1")
    }

    @Test("stale connection UUIDs, generations and painted chips cannot submit")
    func rejectsStaleConnectionAndChipGenerations() throws {
        var state = LiveFollowUpSuggestions()
        let initialConnection = state.connect(sessionID: "session-1")
        let first = try #require(initialConnection)
        let params = notification(responseID: "response-1", labels: ["submit"])

        let receivedInitial = state.receive(
            sessionID: "session-1",
            connectionID: first.connectionID,
            generation: first.generation,
            params: params
        )
        #expect(receivedInitial)
        let firstChip = try chip(from: state)

        let replacementConnection = state.connect(sessionID: "session-1")
        let second = try #require(replacementConnection)
        #expect(state.renderModel == nil)
        let receivedStaleConnection = state.receive(
            sessionID: "session-1",
            connectionID: first.connectionID,
            generation: first.generation,
            params: params
        )
        #expect(!receivedStaleConnection)
        let receivedStaleGeneration = state.receive(
            sessionID: "session-1",
            connectionID: second.connectionID,
            generation: first.generation,
            params: params
        )
        #expect(!receivedStaleGeneration)
        let receivedReplacement = state.receive(
            sessionID: "session-1",
            connectionID: second.connectionID,
            generation: second.generation,
            params: params
        )
        #expect(receivedReplacement)
        let staleChipPrompt = state.takePrompt(for: firstChip, activeSessionID: "session-1")
        #expect(staleChipPrompt == nil)

        let currentChip = try chip(from: state)
        let foreignSessionPrompt = state.takePrompt(for: currentChip, activeSessionID: "session-2")
        #expect(foreignSessionPrompt == nil)
        let acceptedPrompt = state.takePrompt(for: currentChip, activeSessionID: "session-1")
        #expect(acceptedPrompt == "submit")
        let repeatedPrompt = state.takePrompt(for: currentChip, activeSessionID: "session-1")
        #expect(repeatedPrompt == nil)
    }

    @Test("real ACP delivery paints Unicode chips and a real mouse click submits the chosen text")
    func liveDeliveryRendersAndMouseDispatchesPrompt() async throws {
        let fixture = try LiveFollowUpFixture()
        defer { fixture.dispose() }

        try await fixture.renderer.begin()
        try await fixture.renderer.testingDismissWelcomeOverlay()
        try await fixture.renderer.render(.turnStarted(OpenGrokPagerRequest(
            prompt: "original request",
            mode: .fullScreen,
            sessionID: fixture.sessionID,
            metadata: [OpenGrokPagerInteractiveController.promptIDMetadataKey: "prompt-1"]
        )))
        try await fixture.renderer.render(.session(.output("assistant answer")))

        await LiveFollowUpSuggestionRelay.shared.publish(
            sessionID: fixture.sessionID,
            params: notification(
                responseID: "response-1",
                promptID: "prompt-1",
                labels: ["漢字 summary", "More details"]
            )
        )

        let chips = try #require(await fixture.waitForPaintedChips())
        #expect(chips.map(\.label) == ["漢字 summary", "More details"])
        #expect(chips[0].frame.width == UnicodeDisplayWidth.width(of: "[ 漢字 summary ]"))

        let route = try await fixture.renderer.handleInput(.mouse(MouseEvent(
            kind: .down,
            x: chips[1].frame.x + 2,
            y: chips[1].frame.y,
            button: .left
        )))

        #expect(route == .dispatchPrompt(sessionID: fixture.sessionID, prompt: "More details"))
        #expect(await fixture.renderer.liveFollowUpSuggestions.renderModel == nil)
        await fixture.renderer.uninstallFollowUpSuggestionRelay()
    }

    private func notification(
        responseID: String,
        promptID: String? = nil,
        labels: [String],
        sessionID: String? = nil,
        replayed: Bool = false
    ) -> JSONValue {
        var fields: [String: JSONValue] = [
            "response_id": .string(responseID),
            "suggestions": .array(labels.map { .object(["label": .string($0)]) }),
        ]
        if let promptID { fields["promptId"] = .string(promptID) }
        if let sessionID { fields["sessionId"] = .string(sessionID) }
        if replayed { fields["_meta"] = .object(["x.ai/replayed": .bool(true)]) }
        return .object(fields)
    }

    private func chip(from state: LiveFollowUpSuggestions) throws -> PagerFollowUpSuggestionChip {
        let model = try #require(state.renderModel)
        return PagerFollowUpSuggestionChip(
            sessionID: model.sessionID,
            responseID: model.responseID,
            generation: model.generation,
            connectionID: model.connectionID,
            connectionGeneration: model.connectionGeneration,
            index: 0,
            label: model.labels[0],
            frame: TerminalRect(x: 0, y: 0, width: 10, height: 1)
        )
    }
}

private actor FollowUpDeliveryCapture {
    private(set) var responseIDs: [String] = []
    private(set) var connectionIDs: [UUID] = []

    func record(connection: LiveFollowUpSuggestionConnection, params: JSONValue) {
        if let responseID = params["response_id"]?.stringValue {
            responseIDs.append(responseID)
            connectionIDs.append(connection.connectionID)
        }
    }
}

private struct LiveFollowUpFixture {
    let directory: URL
    let sessionID: String
    let renderer: LiveInteractiveControllerRenderer

    init() throws {
        sessionID = "follow-up-\(UUID().uuidString)"
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-\(sessionID)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let environment = ["HOME": directory.path, "OPENGROK_HOME": directory.path]
        renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
                write: { _ in }
            ),
            sink: LiveFollowUpRecordingSink(),
            workingDirectory: directory.path,
            modelName: "test-model",
            sessionID: sessionID,
            openGrokHome: directory,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: environment
        )
    }

    func waitForPaintedChips() async -> [PagerFollowUpSuggestionChip]? {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let chips = await renderer.followUpSuggestionChipsForTesting()
            if !chips.isEmpty { return chips }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let chips = await renderer.followUpSuggestionChipsForTesting()
        return chips.isEmpty ? nil : chips
    }

    func dispose() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class LiveFollowUpRecordingSink: PagerTerminalSink, @unchecked Sendable {
    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes: [UInt8]) throws {}
    func flush() throws {}
}
