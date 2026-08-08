// LiveRecapTests.swift
//
// `/recap` through the LIVE seam (AGENTS.md §3): typed input into the real
// controller, dispatched to the real `LiveInteractiveControllerRenderer`, the
// side-call resolved through the real `LiveModelSwitchCoordinator` and the
// real `OpenGrokLiveSampler.production` factory, and the evidence read off
// the BYTES of the outbound request against the mock inference server —
// plus the one contract a green request cannot prove alone: the conversation
// is UNCHANGED afterwards.
//
// Fixture patterns follow `LiveFastModeTests.swift`: hermetic home, every
// reachable endpoint pinned at the mock, UTF-8 sink with a compact
// customMirror, bounded polls.

import CryptoKit
import Foundation
import Testing
import OpenGrokHTTP
import OpenGrokModels
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokTerminalCore
import OpenGrokTestSupport
@testable import OpenGrokCLI

// MARK: - Helper pins (no server)

@Suite("recap helpers")
struct LiveRecapHelperTests {
    /// The instruction must be BYTE-EXACT against upstream
    /// (`recap_instruction`, session_recap.rs:37-60). The hash and byte count
    /// were computed from the pinned reference commit's source (650c1db7),
    /// so a transcription error in the Swift literal cannot silently pass.
    @Test("instruction is byte-exact against upstream")
    func instructionIsByteExact() {
        let instruction = LiveRecap.instruction(tag: "system-reminder")
        #expect(instruction.utf8.count == 1483)
        let digest = SHA256.hash(data: Data(instruction.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        #expect(hex == "444f088a31656fa196be682552887bdaae6d63b45a8fef1ddd59b9b8be736b17")
    }

    @Test("instruction uses the provided tag")
    func instructionUsesProvidedTag() {
        // Upstream's own pin (session_recap.rs:558-562).
        #expect(LiveRecap.instruction(tag: "system_reminder").contains("<system_reminder>"))
        #expect(LiveRecap.instruction(tag: "system-reminder").contains("</system-reminder>"))
    }

    @Test("instruction asks for a one-sentence body")
    func instructionAsksForOneSentenceBody() {
        // Upstream's own pin (session_recap.rs:564-577).
        let text = LiveRecap.instruction(tag: "system-reminder")
        #expect(text.contains("Output ONLY the body"))
        #expect(text.contains("You asked"))
        #expect(text.contains("We fixed"))
        #expect(text.contains("We merged"))
        #expect(text.contains("billing/retry.rs"))
        #expect(text.contains("queue_worker"))
        #expect(text.contains("We fixed the flaky"))
        #expect(text.contains("We merged the feature"))
        #expect(!text.contains("217584"))
        #expect(!text.contains("lead with \"Recap"))
    }

    // Tidy-pass pins are upstream's own test list (session_recap.rs:319-374,
    // :580-589).

    @Test("clean collapses whitespace and newlines")
    func cleanCollapsesWhitespace() {
        let raw = "Refactored   the\n\nparser\tand added   tests."
        #expect(LiveRecap.cleanText(raw) == "Refactored the parser and added tests.")
    }

    @Test("clean strips a leading label")
    func cleanStripsLeadingLabel() {
        #expect(LiveRecap.cleanText("Recap: fixed the auth bug") == "fixed the auth bug")
        #expect(LiveRecap.cleanText("Session recap: wired up the API") == "wired up the API")
    }

    @Test("clean returns the body without a Recap prefix")
    func cleanReturnsBodyWithoutRecapPrefix() {
        #expect(
            LiveRecap.cleanText("Recap: You fixed auth in foo.rs.")
                == "You fixed auth in foo.rs."
        )
        #expect(
            LiveRecap.cleanText("You fixed auth in foo.rs.")
                == "You fixed auth in foo.rs."
        )
    }

    @Test("clean strips wrapping quotes")
    func cleanStripsWrappingQuotes() {
        #expect(LiveRecap.cleanText("\"did the thing\"") == "did the thing")
        #expect(LiveRecap.cleanText("'did the thing'") == "did the thing")
    }

    @Test("clean caps length on a char boundary")
    func cleanCapsLengthOnCharBoundary() {
        let long = String(repeating: "word ", count: LiveRecap.maxChars)
        let out = LiveRecap.cleanText(long)
        #expect(out.utf8.count <= LiveRecap.maxChars + 4)
        #expect(out.hasSuffix("\u{2026}"))
    }

    @Test("clean cap is UTF-8 safe")
    func cleanCapIsUTF8Safe() {
        // 3-byte chars straddling the byte cap must not tear a character.
        let big = String(repeating: "\u{3042} ", count: LiveRecap.maxChars)
        let out = LiveRecap.cleanText(big)
        #expect(out.hasSuffix("\u{2026}"))
    }

    @Test("clean keeps a normal recap in full")
    func cleanKeepsNormalRecapInFull() {
        let recap = "We fixed the flaky integration test by awaiting the drain "
            + "channel before exit, added a regression test for the shutdown "
            + "path, and updated the runbook with the new sequence."
        let out = LiveRecap.cleanText(recap)
        #expect(out.utf8.count < LiveRecap.maxChars)
        #expect(!out.hasSuffix("\u{2026}"))
        #expect(out.hasSuffix("with the new sequence."))
    }

    @Test("main turn count counts real users only")
    func mainTurnCountCountsRealUsersOnly() {
        // Upstream's pin (session_recap.rs:407-440): synthetic user items and
        // assistant/tool items never count as main turns.
        let conv: [ConversationItem] = [
            .system("sys"),
            .user("hi"),
            .assistant("hello"),
            .user("again"),
            .user(UserItem(
                content: [.text(text: "injected")],
                syntheticReason: .systemReminder
            )),
        ]
        #expect(LiveRecap.mainTurnCount(conv) == 2)
        #expect(LiveRecap.mainTurnCount([.system("sys")]) == 0)

        let toolLoop: [ConversationItem] = [
            .user("fix it"),
            .assistantToolCalls([ToolCall(id: "c1", name: "read_file", arguments: "{}")]),
            .toolResult(toolCallId: "c1", content: "ok"),
            .assistant("done"),
        ]
        #expect(LiveRecap.mainTurnCount(toolLoop) == 1)
    }

    @Test("build appends the instruction as a final user turn")
    func buildAppendsInstructionUserTurn() {
        // Upstream's pin (session_recap.rs:377-387): the system prefix is
        // preserved verbatim for cache reuse and the instruction lands last.
        let conv: [ConversationItem] = [
            .system("sys"),
            .user("hello"),
            .assistant("hi"),
        ]
        let items = LiveRecap.buildItems(
            conversation: conv,
            tag: "system-reminder",
            stripReasoning: true
        )
        guard case .user(let instruction)? = items.last else {
            Issue.record("instruction must be the final user turn")
            return
        }
        // A REAL user turn, never a synthetic one (ConversationItem::user,
        // session_recap.rs:89).
        #expect(instruction.syntheticReason == nil)
        if case .system? = items.first {} else {
            Issue.record("system prefix must be preserved verbatim")
        }
    }

    @Test("build truncates a trailing tool result")
    func buildTruncatesTrailingToolResult() {
        // Upstream's pin (session_recap.rs:389-405).
        let conv: [ConversationItem] = [
            .system("sys"),
            .user("hello"),
            .toolResult(toolCallId: "call-1", content: "output"),
        ]
        let items = LiveRecap.buildItems(
            conversation: conv,
            tag: "system-reminder",
            stripReasoning: false
        )
        #expect(items.count == 3)
        if case .user? = items.last {} else {
            Issue.record("instruction must be the final user turn")
        }
        #expect(!items.contains { if case .toolResult = $0 { return true } else { return false } })
    }

    @Test("pop trailing removes a tool run, keeps a clean tail")
    func popTrailingRemovesToolRunKeepsCleanTail() {
        // Upstream's pin (session_recap.rs:822-839).
        var items: [ConversationItem] = [
            .user("hi"),
            .assistantToolCalls([ToolCall(id: "c1", name: "read_file", arguments: "{}")]),
            .toolResult(toolCallId: "c1", content: "out"),
        ]
        LiveRecap.popTrailingToolRun(&items)
        #expect(items.count == 1)
        if case .user? = items.first {} else {
            Issue.record("the clean user turn must survive")
        }

        var clean: [ConversationItem] = [
            .user("hi"),
            .assistant("done"),
        ]
        LiveRecap.popTrailingToolRun(&clean)
        #expect(clean.count == 2)
    }

    @Test("pop trailing removes native custom output and its owning call")
    func popTrailingRemovesCustomOutputAndOwningCall() {
        // Upstream's pin (session_recap.rs:841-864).
        var items: [ConversationItem] = [
            .user("hi"),
            .assistantToolCalls([ToolCall(id: "code-call", name: "exec", arguments: "{}")]),
            .customToolOutput(CustomToolOutputItem(
                callId: "code-call",
                itemId: "notify-1",
                name: "exec",
                content: [.text(text: "progress")]
            )),
            .customToolOutput(CustomToolOutputItem(
                callId: "code-call",
                itemId: "result-1",
                name: "exec",
                content: [.text(text: "done")]
            )),
        ]
        LiveRecap.popTrailingToolRun(&items)
        #expect(items.count == 1)
        if case .user? = items.first {} else {
            Issue.record("the clean user turn must survive")
        }
    }

    @Test("the Automatic helper table is Codex-only")
    func automaticHelperTableIsCodexOnly() {
        // The whole table upstream is ONE row (`AUTOMATIC_CODEX_AUX_MODEL`,
        // sampler_turn.rs:25-31): Codex prefers gpt-5.6-terra, everyone else
        // keeps the active session model.
        let codex = LiveRecap.desiredModel(configured: nil, activeProvider: .codex)
        #expect(codex?.modelID == "gpt-5.6-terra")
        #expect(codex?.explicit == false)
        #expect(LiveRecap.desiredModel(configured: nil, activeProvider: .xai) == nil)
        #expect(LiveRecap.desiredModel(configured: nil, activeProvider: .fireworks) == nil)
        #expect(LiveRecap.desiredModel(configured: nil, activeProvider: .kimi) == nil)
    }

    @Test("an explicit models.recap pin wins over Automatic")
    func explicitPinWins() {
        // sampler_turn.rs:1106-1113: configured beats the automatic fallback,
        // whitespace trimmed, and an empty pin means Automatic.
        let pinned = LiveRecap.desiredModel(configured: " grok-4.5 ", activeProvider: .codex)
        #expect(pinned?.modelID == "grok-4.5")
        #expect(pinned?.explicit == true)
        #expect(
            LiveRecap.desiredModel(configured: "   ", activeProvider: .xai) == nil
        )
    }

    @Test("auxiliary reasoning effort follows upstream's provider policy")
    func auxiliaryEffortPolicy() {
        // sampler_turn.rs:33-47: Codex medium, xAI low, others the model
        // default (low when it has none), and nothing on models without
        // effort support.
        #expect(LiveRecap.auxiliaryReasoningEffort(
            provider: .codex, supported: true, modelDefault: .high
        ) == .medium)
        #expect(LiveRecap.auxiliaryReasoningEffort(
            provider: .xai, supported: true, modelDefault: .high
        ) == .low)
        #expect(LiveRecap.auxiliaryReasoningEffort(
            provider: .fireworks, supported: true, modelDefault: .high
        ) == .high)
        #expect(LiveRecap.auxiliaryReasoningEffort(
            provider: .fireworks, supported: true, modelDefault: nil
        ) == .low)
        #expect(LiveRecap.auxiliaryReasoningEffort(
            provider: .codex, supported: false, modelDefault: .high
        ) == nil)
    }

    @Test("failure copy matches upstream byte for byte")
    func unavailableToastCopy() {
        // notes.rs:334-340.
        #expect(LiveRecap.unavailableToast(hasUserMessages: true) == "Couldn't generate recap")
        #expect(LiveRecap.unavailableToast(hasUserMessages: false) == "No messages yet")
    }

    @Test("the recap_model settings row persists upstream's TOML key")
    func settingsRowWritesModelsRecap() {
        // Upstream persists the `recap_model` setting into `[models] recap`
        // (`set_recap_model`, util/config/settings_writes.rs:386-394) — the
        // key `models_manager.recap_model()` reads back and the key the live
        // `/recap` resolves through. The row previously wrote
        // `models.recap_model`, which nothing reads.
        let row = PagerSettingsRegistry.default.find("recap_model")
        #expect(row?.storage == .config(path: "models.recap"))
    }
}

// MARK: - Live seam fixture

private final class RecapCapturingSink: PagerTerminalSink, CustomReflectable,
    @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes newBytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        bytes.append(contentsOf: newBytes)
    }

    func flush() throws {}

    /// A failed `#expect` mirrors captured values; without this, Swift
    /// Testing dumps the whole byte buffer as decimal text.
    var customMirror: Mirror {
        lock.lock(); defer { lock.unlock() }
        return Mirror(self, children: ["byteCount": bytes.count])
    }

    var strippedText: String {
        lock.lock(); defer { lock.unlock() }
        var plain: [UInt8] = []
        plain.reserveCapacity(bytes.count / 4)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x1B else {
                plain.append(bytes[index])
                index += 1
                continue
            }
            index += 1
            guard index < bytes.count else { break }
            switch bytes[index] {
            case UInt8(ascii: "["):
                index += 1
                while index < bytes.count, !(0x40...0x7E).contains(bytes[index]) {
                    index += 1
                }
                index += 1
            case UInt8(ascii: "]"):
                index += 1
                while index < bytes.count {
                    if bytes[index] == 0x07 { index += 1; break }
                    if bytes[index] == 0x1B, index + 1 < bytes.count,
                       bytes[index + 1] == UInt8(ascii: "\\") {
                        index += 2
                        break
                    }
                    index += 1
                }
            default:
                index += 1
            }
        }
        return String(decoding: plain, as: UTF8.self)
    }
}

/// Hermetic home + mock inference server; every endpoint the recap side-call
/// or a session turn could reach is pinned at the mock.
private struct RecapFixture {
    let home: URL
    let server: MockInferenceServer
    let environment: [String: String]

    /// `configLines` land in the home `config.toml` after the pinned
    /// `[endpoints]` block — the `[models] recap` pin rides here.
    init(configLines: String = "") throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-recap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        server = try MockInferenceServer()
        try """
            [endpoints]
            xai_api_base_url = "\(server.url)"

            \(configLines)
            """
            .write(
                to: home.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
            "XAI_API_KEY": "test-xai-key",
            "FIREWORKS_API_KEY": "test-fireworks-key",
            "OPENGROK_FIREWORKS_API_BASE_URL": server.url,
            "GROK_CODEX_INFERENCE_BASE_URL": server.url,
            "GROK_CODEX_AUTH_BASE_URL": server.url,
        ]
    }

    func dispose() {
        server.stop()
        try? FileManager.default.removeItem(at: home)
    }

    func resolver(sessionID: String) -> LiveModelCatalogResolver {
        LiveModelCatalogResolver(
            environment: environment,
            openGrokHome: home,
            sessionID: sessionID,
            workingDirectory: home,
            // Model the post-refresh Fireworks partition production runs on
            // (the LiveFastModeTests lesson): the embedded defaults carry no
            // service tiers, and the curated entries' base URL is pinned at
            // the mock so no request can escape.
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
    }

    func inferenceBodies() -> [LogEntry] {
        server.requests().filter {
            $0.path.contains("responses") || $0.path.contains("chat/completions")
        }
    }
}

/// The live renderer over a REAL coordinator and a REAL conversation history,
/// driven by typed input through the real controller.
private struct RecapRendererFixture {
    let sink: RecapCapturingSink
    let renderer: LiveInteractiveControllerRenderer
    let coordinator: LiveModelSwitchCoordinator
    let history: LiveConversationHistory

    init(
        fixture: RecapFixture,
        modelID: String,
        sessionID: String,
        serviceTier: String? = nil,
        items: [ConversationItem]
    ) async throws {
        let resolver = fixture.resolver(sessionID: sessionID)
        let initial = try await resolver.resolve(modelID: modelID, serviceTier: serviceTier)
        let store = LiveConversationStore(openGrokHome: fixture.home)
        let record = LiveConversationRecord(
            sessionID: sessionID,
            workingDirectory: fixture.home.path,
            parentSessionID: nil,
            createdAt: Date(),
            updatedAt: Date(),
            items: items
        )
        try await store.save(record)
        history = LiveConversationHistory(record: record, store: store)
        coordinator = LiveModelSwitchCoordinator(
            sampling: initial.sampling,
            sampler: try OpenGrokLiveSampler.production(configuration: initial.sampling),
            resolver: resolver,
            makeSampler: OpenGrokLiveSampler.production(configuration:),
            history: history
        )
        sink = RecapCapturingSink()
        renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 120, height: 40) },
                write: { _ in }
            ),
            sink: sink,
            workingDirectory: fixture.home.path,
            modelName: initial.sampling.model,
            modelCatalog: resolver.catalogEntries(),
            modelSwitch: coordinator,
            sessionID: sessionID,
            conversationHistory: history,
            openGrokHome: fixture.home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: fixture.environment
        )
    }

    func paintedCompact() -> String {
        sink.strippedText.filter { !$0.isWhitespace }
    }

    func waitForPaint(of marker: String, timeout: TimeInterval = 10) async -> Bool {
        let needle = marker.filter { !$0.isWhitespace }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !paintedCompact().contains(needle) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return paintedCompact().contains(needle)
    }

    /// Run the REAL controller over this renderer with typed input: each
    /// line is typed, the dropdown closed with Esc, and submitted.
    func runController(submitting lines: [String]) async throws {
        var events: [InputEvent] = []
        for line in lines {
            events.append(.paste(line))
            events.append(.key(KeyEvent(key: .escape)))
            events.append(.key(KeyEvent(key: .enter)))
        }
        let controller = OpenGrokPagerInteractiveController(
            input: AsyncStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            },
            runtime: RecapUnusedRuntime(),
            renderer: renderer,
            output: RecapDiscardingOutput()
        )
        _ = try await controller.run(.init(prompt: "", mode: .inline))
    }

    /// One real turn through the coordinator's CURRENT sampler over the
    /// session's own item spine — the same stack the turn loop samples with.
    func runOneTurn(sessionID: String, prompt: String) async throws {
        let snapshot = await coordinator.snapshot()
        let items = await history.itemsForTurn(sessionID: sessionID, prompt: prompt)
        _ = try await snapshot.sampler.sample(
            OpenGrokLiveSamplingRequest(
                sessionID: sessionID,
                turnID: "turn-\(UUID().uuidString)",
                model: snapshot.modelID,
                prompt: prompt,
                items: items
            ),
            emit: { _ in }
        )
    }
}

private struct RecapUnusedRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        _ = request
        throw CancellationError()
    }
}

private struct RecapDiscardingOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}

private let recapSeedItems: [ConversationItem] = [
    .system("sys"),
    .user("hello"),
    .assistant("hi"),
]

// MARK: - The side-call on the wire

@Suite("/recap live seam", .serialized)
struct LiveRecapLiveSeamTests {
    /// The full journey with an explicit `[models] recap` pin: typed `/recap`
    /// sends ONE tool-free request whose body is the session's conversation
    /// prefix VERBATIM plus the instruction turn — and, because the pinned
    /// route resolves through the aux config (`sampling_config_for_model`
    /// pins `service_tier: None`, agent/config.rs:6097), the body carries NO
    /// service_tier even while the session has Fast on. The mocked text
    /// paints as the "Recap —" line, and the conversation is UNCHANGED:
    /// the next real turn's body contains no recap items.
    @Test("/recap sends one tool-free request and never mutates the conversation")
    func recapWireShapeAndNoMutation() async throws {
        let fixture = try RecapFixture(configLines: """
            [models]
            recap = "glm-5.2"
            """)
        defer { fixture.dispose() }
        fixture.server.setResponse("Recap: We wired the recap side-call.")
        let harness = try await RecapRendererFixture(
            fixture: fixture,
            modelID: "glm-5.2",
            sessionID: "recap-wire",
            serviceTier: "priority",
            items: recapSeedItems
        )

        // Prove Fast really is on: a session turn carries the tier.
        try await harness.runOneTurn(sessionID: "recap-wire", prompt: "warmup")
        #expect(fixture.inferenceBodies().last?.body?["service_tier"].stringValue == "priority")
        let before = fixture.inferenceBodies().count

        try await harness.runController(submitting: ["/recap"])
        #expect(await harness.waitForPaint(of: "Recap \u{2014} We wired the recap side-call."))

        // Exactly ONE side-call left the machine.
        #expect(fixture.inferenceBodies().count == before + 1)
        let body = fixture.inferenceBodies().last?.body
        #expect(body?["model"].stringValue == "accounts/fireworks/models/glm-5p2")
        // Tier ABSENT on the aux route even though the session has Fast on.
        #expect(body?["service_tier"].stringValue == nil)
        // Tool-free: no tools field at all, not an empty list.
        #expect(body?["tools"].isNull == true)
        // The conversation prefix rides verbatim, then ONE instruction turn
        // wrapped in the reminder tag.
        let messages = body?["messages"].arrayValue ?? []
        #expect(messages.count == recapSeedItems.count + 1)
        #expect(messages.first?["role"].stringValue == "system")
        #expect(messages.first?["content"].stringValue == "sys")
        let instruction = messages.last
        #expect(instruction?["role"].stringValue == "user")
        let instructionText = instruction?["content"].stringValue ?? ""
        #expect(instructionText.hasPrefix("<system-reminder>Write ONE sentence recap body"))
        #expect(instructionText.hasSuffix("</system-reminder>"))

        // NEVER MUTATES: the live conversation is byte-identical afterwards…
        #expect(await harness.history.items == recapSeedItems)
        // …and the next REAL turn's request body carries no recap items.
        try await harness.runOneTurn(sessionID: "recap-wire", prompt: "next real prompt")
        let nextTurn = fixture.inferenceBodies().last?.body
        let nextMessages = nextTurn?["messages"].arrayValue ?? []
        #expect(nextMessages.count == recapSeedItems.count + 1)
        #expect(!nextMessages.contains { message in
            let content = message["content"].stringValue ?? ""
            return content.contains("Write ONE sentence recap body")
                || content.contains("Recap \u{2014}")
        })
        // The session's Fast tier survived the side-call untouched.
        #expect(nextTurn?["service_tier"].stringValue == "priority")
    }

    /// With NO `[models] recap` pin on a non-Codex session, Automatic keeps
    /// the ACTIVE session route (`automatic_auxiliary_model` is Codex-only,
    /// sampler_turn.rs:27-31; `config = active`, sampler_turn.rs:1162) — and
    /// the active config CARRIES the session's tier
    /// (`reconstruct_full_config`, sampler_turn.rs:850). The brief predicted
    /// tier-None here; the pinned reference says otherwise, so this test pins
    /// the verified behavior: only the RESOLVED aux route drops the tier.
    @Test("Automatic on a non-Codex session keeps the active route, tier included")
    func automaticFallbackKeepsActiveRouteAndTier() async throws {
        let fixture = try RecapFixture()
        defer { fixture.dispose() }
        fixture.server.setResponse("We kept the active route.")
        let harness = try await RecapRendererFixture(
            fixture: fixture,
            modelID: "glm-5.2",
            sessionID: "recap-fallback",
            serviceTier: "priority",
            items: recapSeedItems
        )
        let before = fixture.inferenceBodies().count

        try await harness.runController(submitting: ["/recap"])
        #expect(await harness.waitForPaint(of: "Recap \u{2014} We kept the active route."))

        #expect(fixture.inferenceBodies().count == before + 1)
        let body = fixture.inferenceBodies().last?.body
        #expect(body?["model"].stringValue == "accounts/fireworks/models/glm-5p2")
        #expect(body?["service_tier"].stringValue == "priority")
        #expect(body?["tools"].isNull == true)
        #expect(await harness.history.items == recapSeedItems)
    }

    /// A failed side-call paints upstream's failure copy and the session
    /// keeps working (recap.rs:378-401; notes.rs:331-340).
    @Test("a failed recap paints the failure copy and the session survives")
    func failedRecapPaintsCopyAndSessionSurvives() async throws {
        let fixture = try RecapFixture()
        defer { fixture.dispose() }
        // A scripted 400 fails the ONE recap request deterministically (4xx
        // never retries); the queue then drains back to echo mode.
        try fixture.server.enqueueResponse(
            path: "/v1/chat/completions",
            response: .json(status: 400, .object(["error": .string("bad recap request")]))
        )
        let harness = try await RecapRendererFixture(
            fixture: fixture,
            modelID: "glm-5.2",
            sessionID: "recap-failure",
            items: recapSeedItems
        )

        try await harness.runController(submitting: ["/recap"])
        #expect(await harness.waitForPaint(of: "Couldn't generate recap"))
        // The conversation is untouched and the session still samples.
        #expect(await harness.history.items == recapSeedItems)
        try await harness.runOneTurn(sessionID: "recap-failure", prompt: "still alive?")
        let body = fixture.inferenceBodies().last?.body
        #expect(body?["messages"].arrayValue?.count == recapSeedItems.count + 1)
    }

    /// Nothing to summarize yet: the empty-state copy, and no request leaves
    /// the machine (recap_gate manual arm, session_recap.rs:232-241;
    /// notes.rs:334-340).
    @Test("/recap on an empty session paints \"No messages yet\" and sends nothing")
    func recapOnEmptySessionSendsNothing() async throws {
        let fixture = try RecapFixture()
        defer { fixture.dispose() }
        let harness = try await RecapRendererFixture(
            fixture: fixture,
            modelID: "glm-5.2",
            sessionID: "recap-empty",
            items: [.system("sys")]
        )
        let before = fixture.inferenceBodies().count

        try await harness.runController(submitting: ["/recap"])
        #expect(await harness.waitForPaint(of: "No messages yet"))
        #expect(fixture.inferenceBodies().count == before)
    }

    /// With no live sampling stack behind the renderer, `/recap` answers with
    /// the honest no-session copy (notes.rs:379-384).
    @Test("/recap with no live session paints \"No active session\"")
    func recapWithoutSessionRefuses() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-recap-nosession-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let sink = RecapCapturingSink()
        let renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 120, height: 40) },
                write: { _ in }
            ),
            sink: sink,
            workingDirectory: home.path,
            modelName: "test-model",
            sessionID: "recap-nosession",
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: ["HOME": home.path, "OPENGROK_HOME": home.path]
        )
        try await renderer.begin()
        try await renderer.render(.overlay(.recap))

        let deadline = Date().addingTimeInterval(5)
        var painted = sink.strippedText.filter { !$0.isWhitespace }
        while Date() < deadline, !painted.contains("Noactivesession") {
            try? await Task.sleep(nanoseconds: 10_000_000)
            painted = sink.strippedText.filter { !$0.isWhitespace }
        }
        #expect(painted.contains("Noactivesession"))
        try await renderer.restoreTerminal()
    }

    /// The `GROK_SESSION_RECAP` kill switch answers with upstream's disabled
    /// copy and never reads the conversation (notes.rs:372-377;
    /// resolve_session_recap, agent/config.rs:2657-2667).
    @Test("GROK_SESSION_RECAP=0 disables the command with upstream's copy")
    func killSwitchDisablesRecap() async throws {
        let fixture = try RecapFixture()
        defer { fixture.dispose() }
        var environment = fixture.environment
        environment["GROK_SESSION_RECAP"] = "0"
        let resolver = fixture.resolver(sessionID: "recap-disabled")
        let initial = try await resolver.resolve(modelID: "glm-5.2")
        let sink = RecapCapturingSink()
        let renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 120, height: 40) },
                write: { _ in }
            ),
            sink: sink,
            workingDirectory: fixture.home.path,
            modelName: initial.sampling.model,
            modelSwitch: LiveModelSwitchCoordinator(
                sampling: initial.sampling,
                sampler: try OpenGrokLiveSampler.production(configuration: initial.sampling),
                resolver: resolver,
                makeSampler: OpenGrokLiveSampler.production(configuration:),
                history: nil
            ),
            sessionID: "recap-disabled",
            openGrokHome: fixture.home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: environment
        )
        try await renderer.begin()
        try await renderer.render(.overlay(.recap))

        let deadline = Date().addingTimeInterval(5)
        var painted = sink.strippedText.filter { !$0.isWhitespace }
        while Date() < deadline, !painted.contains("Sessionrecapisnotenabled") {
            try? await Task.sleep(nanoseconds: 10_000_000)
            painted = sink.strippedText.filter { !$0.isWhitespace }
        }
        #expect(painted.contains("Sessionrecapisnotenabled"))
        #expect(fixture.inferenceBodies().isEmpty)
        try await renderer.restoreTerminal()
    }
}
