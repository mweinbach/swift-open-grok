import Foundation
import OpenGrokHTTP
import OpenGrokModels
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokSessionPersistence
import OpenGrokTerminalCore
import OpenGrokTestSupport
import Testing
@testable import OpenGrokCLI

private final class AutoRecapDiscardingSink: PagerTerminalSink, @unchecked Sendable {
    var capabilities: PagerTerminalCapabilities { .standard }
    func write(bytes: [UInt8]) throws {}
    func flush() throws {}
}

private struct AutoRecapFixture {
    let home: URL
    let sessionID: String
    let server: MockInferenceServer
    let history: LiveConversationHistory
    let renderer: LiveInteractiveControllerRenderer
    let initialItems: [ConversationItem]

    init(
        realMainTurns: Int = 3,
        idleSeconds: TimeInterval = 240,
        awayThresholdSeconds: UInt64 = 0,
        notificationsEnabled: Bool = true,
        featureEnabled: Bool = true
    ) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-auto-recap-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let server = try MockInferenceServer()
        let featureConfiguration = featureEnabled ? "" : """

        [features]
        session_recap = false
        """
        try """
        [endpoints]
        xai_api_base_url = "\(server.url)"

        [ui.notifications]
        method = "none"
        condition = "never"
        progress_bar = false
        sleep_prevention = false
        session_recap = \(notificationsEnabled)
        session_recap_threshold_secs = \(awayThresholdSeconds)
        \(featureConfiguration)
        """.write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let sessionID = "auto-recap-\(UUID().uuidString.lowercased())"
        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
            "TERM": "xterm-256color",
            "GROK_NO_MOTION": "1",
            "XAI_API_KEY": "test-xai-key",
            "FIREWORKS_API_KEY": "test-fireworks-key",
            "OPENGROK_FIREWORKS_API_BASE_URL": server.url,
            "GROK_CODEX_INFERENCE_BASE_URL": server.url,
            "GROK_CODEX_AUTH_BASE_URL": server.url,
        ]
        let resolver = LiveModelCatalogResolver(
            environment: environment,
            openGrokHome: home,
            sessionID: sessionID,
            workingDirectory: home,
            catalogSource: { [server] in
                resolveModelCatalog(
                    input: .default,
                    fireworksCatalog: FireworksModelsCatalog(
                        entries: FireworksModels.curatedCatalog(baseURL: server.url),
                        credentialFingerprint: "test-fireworks-key"
                    )
                )
            }
        )
        let initial = try await resolver.resolve(modelID: "glm-5.2")
        var initialItems: [ConversationItem] = [.system("sys")]
        for turn in 0..<realMainTurns {
            initialItems.append(.user("question \(turn)"))
            initialItems.append(.assistant("answer \(turn)"))
        }
        initialItems.append(.user(UserItem(
            content: [.text(text: "synthetic reminder")],
            syntheticReason: .systemReminder
        )))

        let store = LiveConversationStore(openGrokHome: home)
        let record = LiveConversationRecord(
            sessionID: sessionID,
            workingDirectory: home.path,
            parentSessionID: nil,
            createdAt: Date().addingTimeInterval(-600),
            updatedAt: Date().addingTimeInterval(-idleSeconds),
            items: initialItems
        )
        try await store.save(record)
        let history = LiveConversationHistory(record: record, store: store)
        let coordinator = LiveModelSwitchCoordinator(
            sampling: initial.sampling,
            sampler: try OpenGrokLiveSampler.production(configuration: initial.sampling),
            resolver: resolver,
            makeSampler: OpenGrokLiveSampler.production(configuration:),
            history: history
        )
        let renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { true },
                size: { OpenGrokLiveTerminalSize(width: 120, height: 40) },
                write: { _ in }
            ),
            sink: AutoRecapDiscardingSink(),
            workingDirectory: home.path,
            modelName: initial.sampling.model,
            modelCatalog: resolver.catalogEntries(),
            modelSwitch: coordinator,
            sessionID: sessionID,
            conversationHistory: history,
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: environment
        )

        self.home = home
        self.sessionID = sessionID
        self.server = server
        self.history = history
        self.renderer = renderer
        self.initialItems = initialItems
    }

    var watermarkURL: URL {
        get throws {
            try SessionDocumentStore(grokHome: home)
                .sessionDirectory(sessionID: sessionID, cwd: home.path)
                .appendingPathComponent("last_recap_main_turn")
        }
    }

    var inferenceRequests: [LogEntry] {
        server.requests().filter {
            $0.path.contains("responses") || $0.path.contains("chat/completions")
        }
    }

    func focusRoundTrip() async throws {
        let lost = try await renderer.handleInput(.focusLost)
        #expect(lost == .consumed)
        let gained = try await renderer.handleInput(.focusGained)
        #expect(gained == .consumed)
    }

    func awaitRecap(summary: String, auto: Bool, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let matches = await renderer.testingConversationItems().contains { item in
                guard case .block(.sessionEvent(let block)) = item,
                      case .recap(let value, let isAutomatic) = block.event
                else { return false }
                return value == summary && isAutomatic == auto && block.isExpanded
            }
            if matches { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func awaitInferenceRequests(_ count: Int, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if inferenceRequests.count >= count { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func finishPendingRecap() async {
        if let task = await renderer.recapTask {
            await task.value
        }
    }

    func dispose() {
        server.stop()
        try? FileManager.default.removeItem(at: home)
    }
}

private func withAutoRecapFixture(
    realMainTurns: Int = 3,
    idleSeconds: TimeInterval = 240,
    awayThresholdSeconds: UInt64 = 0,
    notificationsEnabled: Bool = true,
    featureEnabled: Bool = true,
    _ body: (AutoRecapFixture) async throws -> Void
) async throws {
    let fixture = try await AutoRecapFixture(
        realMainTurns: realMainTurns,
        idleSeconds: idleSeconds,
        awayThresholdSeconds: awayThresholdSeconds,
        notificationsEnabled: notificationsEnabled,
        featureEnabled: featureEnabled
    )
    do {
        try await fixture.renderer.begin()
        try await body(fixture)
        await fixture.finishPendingRecap()
        try await fixture.renderer.restoreTerminal()
        fixture.dispose()
    } catch {
        await fixture.finishPendingRecap()
        try? await fixture.renderer.restoreTerminal()
        fixture.dispose()
        throw error
    }
}

@Suite("Rust return-from-away recap live parity", .serialized)
struct LiveAutoRecapParityTests {
    @Test("an eligible recap is generated and cached before terminal focus returns")
    func pregeneratesRecapWhileTerminalIsUnfocused() async throws {
        try await withAutoRecapFixture { fixture in
            fixture.server.setResponse("Recap: The cached away summary is already ready.")

            let lost = try await fixture.renderer.handleInput(.focusLost)
            #expect(lost == .consumed)
            #expect(await fixture.awaitInferenceRequests(1))
            #expect(await fixture.renderer.terminalNotifications.focused == false)
            #expect(await fixture.awaitRecap(
                summary: "The cached away summary is already ready.",
                auto: true
            ))
            #expect(await fixture.renderer.terminalNotifications.focused == false)
            #expect(fixture.inferenceRequests.count == 1)
            #expect(fixture.inferenceRequests[0].body?["tools"].isNull == true)
            let watermark = try String(contentsOf: fixture.watermarkURL, encoding: .utf8)
            #expect(watermark == "3")
            #expect(await fixture.history.items == fixture.initialItems)
            #expect(await fixture.renderer.awayRecapPollTask == nil)

            let gained = try await fixture.renderer.handleInput(.focusGained)
            #expect(gained == .consumed)
            #expect(await fixture.awaitRecap(
                summary: "The cached away summary is already ready.",
                auto: true
            ))
            #expect(fixture.inferenceRequests.count == 1)
            #expect(await fixture.history.items == fixture.initialItems)
        }
    }

    @Test("an in-flight away recap survives focus return without a duplicate side call")
    func focusReturnReusesInflightAwayPregeneration() async throws {
        try await withAutoRecapFixture { fixture in
            fixture.server.setChunkDelay(0.05)
            fixture.server.setResponse("Recap: One background request survives refocus.")

            let lost = try await fixture.renderer.handleInput(.focusLost)
            #expect(lost == .consumed)
            #expect(await fixture.awaitInferenceRequests(1))
            #expect(await fixture.renderer.terminalNotifications.focused == false)
            let gained = try await fixture.renderer.handleInput(.focusGained)
            #expect(gained == .consumed)

            #expect(await fixture.awaitRecap(
                summary: "One background request survives refocus.",
                auto: true
            ))
            #expect(fixture.inferenceRequests.count == 1)
            #expect(await fixture.renderer.awayRecapPollTask == nil)
            #expect(await fixture.history.items == fixture.initialItems)
        }
    }

    @Test("focus regain before the configured threshold cancels unfocused generation")
    func earlyFocusRegainCancelsThresholdTimer() async throws {
        try await withAutoRecapFixture(awayThresholdSeconds: 60) { fixture in
            let lost = try await fixture.renderer.handleInput(.focusLost)
            #expect(lost == .consumed)
            #expect(await fixture.renderer.awayRecapPollTask != nil)
            #expect(fixture.inferenceRequests.isEmpty)

            let gained = try await fixture.renderer.handleInput(.focusGained)
            #expect(gained == .consumed)
            #expect(await fixture.renderer.awayRecapPollTask == nil)
            #expect(await fixture.renderer.recapTask == nil)
            #expect(fixture.inferenceRequests.isEmpty)
            let watermarkPath = try fixture.watermarkURL.path
            #expect(!FileManager.default.fileExists(atPath: watermarkPath))
        }
    }

    @Test("terminal shutdown cancels the pending away recap before it can sample")
    func shutdownCancelsAwayPregeneration() async throws {
        try await withAutoRecapFixture(awayThresholdSeconds: 60) { fixture in
            let lost = try await fixture.renderer.handleInput(.focusLost)
            #expect(lost == .consumed)
            #expect(await fixture.renderer.awayRecapPollTask != nil)

            try await fixture.renderer.restoreTerminal()

            #expect(await fixture.renderer.awayRecapPollTask == nil)
            #expect(await fixture.renderer.recapTask == nil)
            #expect(fixture.inferenceRequests.isEmpty)
            #expect(await fixture.history.items == fixture.initialItems)
        }
    }

    @Test("a new turn invalidates an already-sampling unfocused recap")
    func newTurnDiscardsStaleAwayPregeneration() async throws {
        try await withAutoRecapFixture { fixture in
            fixture.server.setChunkDelay(0.1)
            fixture.server.setResponse("Recap: This stale summary must never be painted.")

            let lost = try await fixture.renderer.handleInput(.focusLost)
            #expect(lost == .consumed)
            #expect(await fixture.awaitInferenceRequests(1))
            try await fixture.renderer.render(.turnStarted(OpenGrokPagerRequest(
                prompt: "a newer real turn invalidates this summary",
                mode: .fullScreen
            )))
            await fixture.finishPendingRecap()

            let displayed = await fixture.renderer.testingConversationItems()
            #expect(!displayed.contains { item in
                guard case .block(.sessionEvent(let block)) = item,
                      case .recap = block.event
                else { return false }
                return true
            })
            #expect(fixture.inferenceRequests.count == 1)
            let watermarkPath = try fixture.watermarkURL.path
            #expect(!FileManager.default.fileExists(atPath: watermarkPath))
        }
    }

    @Test("real focus return emits exactly one auto recap and persists its session watermark")
    func focusReturnSamplesOnceAndPreservesManualRecap() async throws {
        try await withAutoRecapFixture { fixture in
            fixture.server.setChunkDelay(0.02)
            fixture.server.setResponse("Recap: We restored the focus-return recap.")
            try "99".write(to: fixture.watermarkURL, atomically: true, encoding: .utf8)

            try await fixture.focusRoundTrip()
            try await fixture.focusRoundTrip()
            #expect(await fixture.awaitRecap(
                summary: "We restored the focus-return recap.",
                auto: true
            ))
            #expect(fixture.inferenceRequests.count == 1)
            #expect(try String(contentsOf: fixture.watermarkURL, encoding: .utf8) == "3")
            #expect(await fixture.history.items == fixture.initialItems)

            try await fixture.focusRoundTrip()
            #expect(fixture.inferenceRequests.count == 1)

            fixture.server.setResponse("Recap: We kept the manual command available.")
            await fixture.renderer.startRecap()
            #expect(await fixture.awaitRecap(
                summary: "We kept the manual command available.",
                auto: false
            ))
            #expect(fixture.inferenceRequests.count == 2)
            #expect(await fixture.history.items == fixture.initialItems)
        }
    }

    @Test(
        "auto recap refuses disabled features, short absences, too few real turns, and recent activity",
        arguments: ["notifications", "feature", "away", "turns", "idle"]
    )
    func authoritativeAutomaticGates(scenario: String) async throws {
        try await withAutoRecapFixture(
            realMainTurns: scenario == "turns" ? 2 : 3,
            idleSeconds: scenario == "idle" ? 179 : 240,
            awayThresholdSeconds: scenario == "away" ? 30 : 0,
            notificationsEnabled: scenario != "notifications",
            featureEnabled: scenario != "feature"
        ) { fixture in
            let before = await fixture.renderer.testingConversationItems()
            try await fixture.focusRoundTrip()
            #expect(fixture.inferenceRequests.isEmpty)
            #expect(await fixture.renderer.recapTask == nil)
            #expect(await fixture.renderer.testingConversationItems() == before)
            #expect(!FileManager.default.fileExists(atPath: try fixture.watermarkURL.path))
        }
    }

    @Test("queued prompts, running background work, permission overlays, and active turns suppress auto recap")
    func liveBusyModalAndBackgroundGates() async throws {
        try await withAutoRecapFixture { fixture in
            let backgroundStart = try #require(
                LiveActiveBackgroundWorkEvent.upsert(kind: .shell, id: "running")
            )
            await fixture.renderer.applyActiveBackgroundWork(backgroundStart)
            try await fixture.focusRoundTrip()
            #expect(fixture.inferenceRequests.isEmpty)

            let backgroundEnd = try #require(
                LiveActiveBackgroundWorkEvent.remove(kind: .shell, id: "running")
            )
            await fixture.renderer.applyActiveBackgroundWork(backgroundEnd)
            try await fixture.renderer.render(.queueChanged(queuedPromptCount: 1))
            try await fixture.focusRoundTrip()
            #expect(fixture.inferenceRequests.isEmpty)

            try await fixture.renderer.render(.queueChanged(queuedPromptCount: 0))
            await fixture.renderer.showPermission(PagerPermissionRequest(
                id: "approval",
                toolName: "bash"
            ))
            try await fixture.focusRoundTrip()
            #expect(fixture.inferenceRequests.isEmpty)

            await fixture.renderer.showPermission(nil)
            try await fixture.renderer.render(.turnStarted(OpenGrokPagerRequest(
                prompt: "still working",
                mode: .fullScreen
            )))
            try await fixture.focusRoundTrip()
            #expect(fixture.inferenceRequests.isEmpty)
            #expect(await fixture.renderer.recapTask == nil)
        }
    }

    @Test("failed automatic recaps stay silent and do not advance the durable watermark")
    func failedAutomaticRecapRetriesNextAwayPeriod() async throws {
        try await withAutoRecapFixture { fixture in
            try fixture.server.enqueueResponse(
                path: "/v1/chat/completions",
                response: .json(status: 400, .object(["error": .string("bad recap")]))
            )
            let before = await fixture.renderer.testingConversationItems()
            try await fixture.focusRoundTrip()
            await fixture.finishPendingRecap()
            #expect(fixture.inferenceRequests.count == 1)
            #expect(await fixture.renderer.testingConversationItems() == before)
            #expect(!FileManager.default.fileExists(atPath: try fixture.watermarkURL.path))

            fixture.server.setResponse("We recovered on the next focus return.")
            try await fixture.focusRoundTrip()
            #expect(await fixture.awaitRecap(
                summary: "We recovered on the next focus return.",
                auto: true
            ))
            #expect(fixture.inferenceRequests.count == 2)
            #expect(try String(contentsOf: fixture.watermarkURL, encoding: .utf8) == "3")
        }
    }

    @Test("long automatic model output is suppressed but commits the Rust watermark")
    func oversizedAutomaticRecapIsSilentlySuppressed() async throws {
        try await withAutoRecapFixture { fixture in
            fixture.server.setResponse(String(repeating: "x", count: 501))
            let before = await fixture.renderer.testingConversationItems()
            try await fixture.focusRoundTrip()
            await fixture.finishPendingRecap()

            #expect(fixture.inferenceRequests.count == 1)
            #expect(await fixture.renderer.testingConversationItems() == before)
            #expect(try String(contentsOf: fixture.watermarkURL, encoding: .utf8) == "3")
            #expect(await fixture.history.items == fixture.initialItems)
        }
    }
}
