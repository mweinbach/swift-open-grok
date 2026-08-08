// LiveBtwTests.swift
//
// `/btw` — the real side-question semantics (Wave 15 item 7) — through the
// LIVE seam (AGENTS.md §3): typed input into the real controller, dispatched
// to the real `LiveInteractiveControllerRenderer`, the side-call sampled on
// the real `LiveModelSwitchCoordinator`'s ACTIVE route, and the evidence
// read off the BYTES of the outbound request against the mock inference
// server — plus the two contracts a green request cannot prove alone: the
// conversation is UNCHANGED afterwards, and the record landed on the REAL
// `btw_history.jsonl`.
//
// Upstream ground truth at the pinned reference (650c1db7):
// `handle_side_question` + `side_question_prompt_and_tools`
// (acp_session_impl/recap.rs:70-219), `BtwEntry` (session/persistence.rs:
// 56-85), `btw_history.jsonl` placement (storage/jsonl/mod.rs:151-153), and
// the pager dispatch (`dispatch_send_btw`, app/dispatch/notes.rs:282-329).
//
// Fixture patterns follow `LiveRecapTests.swift` (hermetic home, endpoint
// pins, UTF-8 sink, bounded polls) and `LiveInterjectionTests.swift` (canned
// sampler over the real stack for the mid-turn probe).

import CryptoKit
import Foundation
import Testing
import OpenGrokHTTP
import OpenGrokModels
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokTerminalCore
import OpenGrokTestSupport
@testable import OpenGrokCLI

// MARK: - Helper pins (no server)

@Suite("btw helpers")
struct LiveBtwHelperTests {
    /// The instruction+question turn must be BYTE-EXACT against upstream
    /// (`side_question_prompt_and_tools`, recap.rs:192-208). The hash and
    /// byte count were computed mechanically from the pinned reference
    /// commit's source (650c1db7) — the Rust literal's line-continuation
    /// semantics processed exactly — so a transcription error in the Swift
    /// literal cannot silently pass.
    @Test("instruction is byte-exact against upstream")
    func instructionIsByteExact() {
        let text = LiveBtw.instruction(tag: "system-reminder", question: "why")
        #expect(text.utf8.count == 1099)
        let digest = SHA256.hash(data: Data(text.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        #expect(hex == "b3c49c89275a329dcd02d26b66f7a161586ff59ba4fe2931de91606f17a5d547")
    }

    @Test("instruction uses the provided tag and appends the raw question")
    func instructionTagAndQuestionPlacement() {
        let text = LiveBtw.instruction(tag: "system_reminder", question: "is it warm?")
        #expect(text.hasPrefix("<system_reminder>This is a side question from the user."))
        // The question rides RAW after the closed tag and a blank line
        // (recap.rs:207-208) — never inside the reminder wrapper.
        #expect(text.hasSuffix("</system_reminder>\n\nis it warm?"))
    }

    @Test("build appends the instruction as a final REAL user turn")
    func buildAppendsInstructionUserTurn() {
        // The system prefix is preserved verbatim for cache reuse and the
        // instruction lands last (recap.rs:86-108).
        let conv: [ConversationItem] = [
            .system("sys"),
            .user("hello"),
            .assistant("hi"),
        ]
        let items = LiveBtw.buildItems(
            conversation: conv,
            question: "why",
            tag: "system-reminder",
            stripReasoning: false
        )
        #expect(items.count == conv.count + 1)
        guard case .user(let instruction)? = items.last else {
            Issue.record("instruction must be the final user turn")
            return
        }
        #expect(instruction.syntheticReason == nil)
        #expect(instruction.content == [
            .text(text: LiveBtw.instruction(tag: "system-reminder", question: "why")),
        ])
        if case .system? = items.first {} else {
            Issue.record("system prefix must be preserved verbatim")
        }
    }

    @Test("build truncates a trailing incomplete tool run")
    func buildTruncatesTrailingToolRun() {
        // `/btw` fires mid-turn, so the snapshot may end on a dangling tool
        // call; the same pop `/recap` uses (recap.rs:97-104).
        let conv: [ConversationItem] = [
            .system("sys"),
            .user("hello"),
            .assistantToolCalls([ToolCall(id: "c1", name: "read_file", arguments: "{}")]),
            .toolResult(toolCallId: "c1", content: "output"),
        ]
        let items = LiveBtw.buildItems(
            conversation: conv,
            question: "why",
            tag: "system-reminder",
            stripReasoning: false
        )
        #expect(items.count == 3)
        #expect(!items.contains { if case .toolResult = $0 { return true } else { return false } })
        if case .user? = items.last {} else {
            Issue.record("instruction must be the final user turn")
        }
    }

    @Test("build strips reasoning only when asked")
    func buildStripsReasoningOnlyWhenAsked() {
        let conv: [ConversationItem] = [
            .user("hello"),
            .reasoning(ReasoningItem(id: "r1")),
            .assistant("hi"),
        ]
        let stripped = LiveBtw.buildItems(
            conversation: conv, question: "q", tag: "system-reminder", stripReasoning: true
        )
        #expect(!stripped.contains { if case .reasoning = $0 { return true } else { return false } })
        let kept = LiveBtw.buildItems(
            conversation: conv, question: "q", tag: "system-reminder", stripReasoning: false
        )
        #expect(kept.contains { if case .reasoning = $0 { return true } else { return false } })
    }

    @Test("failure copy carries upstream's prefix")
    func failureCopyPrefix() {
        // effects/mod.rs:5641-5649; commands.rs:34-35.
        #expect(LiveBtw.failureCopy("boom") == "side question failed: boom")
        #expect(LiveBtw.emptyResponseCopy == "No response from model")
    }

    // MARK: btw_history.jsonl record schema

    /// The wire schema pin for one `btw_history.jsonl` line — camelCase keys
    /// matching upstream's `#[serde(rename_all = "camelCase")]` `BtwEntry`
    /// (persistence.rs:56-85), `error` omitted when nil.
    @Test("entry serializes with upstream's camelCase schema, error omitted when nil")
    func entrySchemaPin() throws {
        let entry = LiveBtwEntry(
            btwSessionId: "btw-abc",
            parentSessionId: "parent-1",
            askedAt: Date(timeIntervalSince1970: 1_754_000_000),
            question: "why",
            answer: "because",
            model: "grok-4.5",
            success: true,
            error: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let object = try JSONDecoder().decode(
            JSONValue.self,
            from: encoder.encode(entry)
        )
        #expect(object["btwSessionId"]?.stringValue == "btw-abc")
        #expect(object["parentSessionId"]?.stringValue == "parent-1")
        #expect(object["askedAt"]?.stringValue == "2025-07-31T22:13:20Z")
        #expect(object["question"]?.stringValue == "why")
        #expect(object["answer"]?.stringValue == "because")
        #expect(object["model"]?.stringValue == "grok-4.5")
        #expect(object["success"]?.boolValue == true)
        #expect(object["attempts"]?.doubleValue == 1)
        // `skip_serializing_if = "Option::is_none"` (persistence.rs:74-76).
        guard case .object(let fields) = object else {
            Issue.record("entry must encode as an object")
            return
        }
        #expect(fields["error"] == nil)
        #expect(fields.count == 8)
    }

    @Test("a failed entry carries its error, and legacy lines default attempts to 1")
    func entryFailureAndLegacyDecode() throws {
        let failed = LiveBtwEntry(
            btwSessionId: "btw-x",
            parentSessionId: "p",
            askedAt: Date(),
            question: "q",
            answer: "",
            model: "m",
            success: false,
            error: "No response from model",
            attempts: 1
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(failed))
        #expect(object["error"]?.stringValue == "No response from model")

        // Entries written before `attempts` existed deserialize as 1
        // (persistence.rs:77-85).
        let legacy = """
        {"btwSessionId":"btw-old","parentSessionId":"p","askedAt":"2025-01-01T00:00:00Z",\
        "question":"q","answer":"a","model":"m","success":true}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LiveBtwEntry.self, from: Data(legacy.utf8))
        #expect(decoded.attempts == 1)
        #expect(decoded.error == nil)
    }

    // MARK: btw_history.jsonl store

    @Test("append lands one JSONL line per entry on the real session file")
    func storeAppendsToRealFile() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-btw-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = LiveBtwHistoryStore(openGrokHome: home)
        func entry(_ id: String, question: String) -> LiveBtwEntry {
            LiveBtwEntry(
                btwSessionId: id,
                parentSessionId: "sess-1",
                askedAt: Date(),
                question: question,
                answer: "a",
                model: "m",
                success: true,
                error: nil
            )
        }
        try await store.append(entry("btw-1", question: "first"))
        try await store.append(entry("btw-2", question: "second"))

        let file = LiveBtwHistoryStore.historyFileURL(openGrokHome: home, sessionID: "sess-1")
        // The upstream placement: {session_dir}/btw_history.jsonl
        // (storage/jsonl/mod.rs:151-153) over this port's per-session
        // directory convention.
        #expect(file.path.hasSuffix("sessions/sess-1/btw_history.jsonl"))
        let text = try String(contentsOf: file, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline)
        #expect(lines.count == 2)
        #expect(text.hasSuffix("\n"), "every record must be newline-terminated")

        let loaded = await store.load(sessionID: "sess-1")
        #expect(loaded.map(\.question) == ["first", "second"])
    }

    @Test("append heals a torn tail instead of merging records")
    func storeHealsTornTail() async throws {
        // Upstream's torn-tail discipline (jsonl/mod.rs:259-316): a crashed
        // previous append (no trailing newline) is terminated as its own
        // corrupt line, bounding the damage to exactly one record.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-btw-torn-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = LiveBtwHistoryStore.historyFileURL(openGrokHome: home, sessionID: "sess-torn")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"btwSessionId":"btw-torn","parentSes"#.utf8).write(to: file)

        let store = LiveBtwHistoryStore(openGrokHome: home)
        try await store.append(LiveBtwEntry(
            btwSessionId: "btw-after",
            parentSessionId: "sess-torn",
            askedAt: Date(),
            question: "still works?",
            answer: "yes",
            model: "m",
            success: true,
            error: nil
        ))
        let loaded = await store.load(sessionID: "sess-torn")
        #expect(loaded.map(\.btwSessionId) == ["btw-after"])
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.split(whereSeparator: \.isNewline).count == 2)
    }

    @Test("id builders carry upstream's prefixes")
    func idBuilderPrefixes() {
        // recap.rs:77 and :34/:139.
        #expect(LiveBtw.makeBtwSessionID().hasPrefix("btw-"))
        #expect(LiveBtw.makeRequestID().hasPrefix("xai-btw-"))
    }
}

// MARK: - Live seam fixture

private final class BtwCapturingSink: PagerTerminalSink, CustomReflectable,
    @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes newBytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        bytes.append(contentsOf: newBytes)
    }

    func flush() throws {}

    var customMirror: Mirror {
        lock.lock(); defer { lock.unlock() }
        return Mirror(self, children: ["byteCount": bytes.count])
    }

    /// The painted text with CSI/OSC escape sequences stripped (the
    /// `LiveRecapTests` scrubber).
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

/// Hermetic home + mock inference server; every endpoint the side-call or a
/// session turn could reach is pinned at the mock.
private struct BtwFixture {
    let home: URL
    let server: MockInferenceServer
    let environment: [String: String]

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-btw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        server = try MockInferenceServer()
        try """
            [endpoints]
            xai_api_base_url = "\(server.url)"
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
private struct BtwRendererFixture {
    let sink: BtwCapturingSink
    let renderer: LiveInteractiveControllerRenderer
    let coordinator: LiveModelSwitchCoordinator
    let history: LiveConversationHistory

    init(
        fixture: BtwFixture,
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
        sink = BtwCapturingSink()
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
            runtime: BtwUnusedRuntime(),
            renderer: renderer,
            output: BtwDiscardingOutput()
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

private struct BtwUnusedRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        _ = request
        throw CancellationError()
    }
}

private struct BtwDiscardingOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}

private let btwSeedItems: [ConversationItem] = [
    .system("sys"),
    .user("hello"),
    .assistant("hi"),
]

/// Bounded poll for the history record — the append runs on the side-call
/// task after the paint.
private func waitForHistory(
    store: LiveBtwHistoryStore,
    sessionID: String,
    count: Int,
    timeout: TimeInterval = 10
) async -> [LiveBtwEntry] {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let entries = await store.load(sessionID: sessionID)
        if entries.count >= count { return entries }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await store.load(sessionID: sessionID)
}

// MARK: - The side-call on the wire (idle)

@Suite("/btw live seam", .serialized)
struct LiveBtwLiveSeamTests {
    /// The full idle journey: typed `/btw` sends ONE tool-free request on
    /// the ACTIVE session route — the session's model AND its Fast tier ride
    /// (upstream uses `prepare_chat_completion(false)` + the session
    /// `sampling_config`, recap.rs:81-84, :110-112; contrast the recap test,
    /// where only a RESOLVED aux route drops the tier). The body is the
    /// conversation prefix VERBATIM plus the instruction+question turn. The
    /// answer paints as the BtwBlock-shaped note, the conversation is
    /// UNCHANGED, and the record lands on the real `btw_history.jsonl`.
    @Test("/btw sends one tool-free request on the active route and never mutates the conversation")
    func btwWireShapeNoMutationAndHistory() async throws {
        let fixture = try BtwFixture()
        defer { fixture.dispose() }
        fixture.server.setResponse("The cache is warm.")
        let harness = try await BtwRendererFixture(
            fixture: fixture,
            modelID: "glm-5.2",
            sessionID: "btw-wire",
            serviceTier: "priority",
            items: btwSeedItems
        )
        let before = fixture.inferenceBodies().count

        try await harness.runController(submitting: ["/btw is the cache warm"])
        #expect(await harness.waitForPaint(of: "/btw is the cache warm"))
        #expect(await harness.waitForPaint(of: "The cache is warm."))

        // Exactly ONE side-call left the machine.
        #expect(fixture.inferenceBodies().count == before + 1)
        let body = fixture.inferenceBodies().last?.body
        #expect(body?["model"].stringValue == "accounts/fireworks/models/glm-5p2")
        // The ACTIVE route carries the session's tier — a side question
        // rides the session's own client, never the aux resolution that
        // pins tier to nil.
        #expect(body?["service_tier"].stringValue == "priority")
        // Tool-free: no tools field at all, not an empty list.
        #expect(body?["tools"].isNull == true)
        // The conversation prefix rides verbatim, then ONE instruction turn
        // wrapped in the reminder tag with the question after it.
        let messages = body?["messages"].arrayValue ?? []
        #expect(messages.count == btwSeedItems.count + 1)
        #expect(messages.first?["role"].stringValue == "system")
        #expect(messages.first?["content"].stringValue == "sys")
        let instruction = messages.last
        #expect(instruction?["role"].stringValue == "user")
        let instructionText = instruction?["content"].stringValue ?? ""
        #expect(instructionText.hasPrefix(
            "<system-reminder>This is a side question from the user."
        ))
        #expect(instructionText.hasSuffix("</system-reminder>\n\nis the cache warm"))

        // NEVER MUTATES: the live conversation is byte-identical afterwards…
        #expect(await harness.history.items == btwSeedItems)
        // …and the next REAL turn's request body is clean of the question
        // AND the answer.
        try await harness.runOneTurn(sessionID: "btw-wire", prompt: "next real prompt")
        let nextTurn = fixture.inferenceBodies().last?.body
        let nextMessages = nextTurn?["messages"].arrayValue ?? []
        #expect(nextMessages.count == btwSeedItems.count + 1)
        #expect(!nextMessages.contains { message in
            let content = message["content"].stringValue ?? ""
            return content.contains("This is a side question")
                || content.contains("is the cache warm")
                || content.contains("The cache is warm.")
        })
        // The session's Fast tier survived the side-call untouched.
        #expect(nextTurn?["service_tier"].stringValue == "priority")

        // The durable record: question+answer pair on the real file
        // (persistence.rs:56-85; recap.rs:114-128, :162-172).
        let store = LiveBtwHistoryStore(openGrokHome: fixture.home)
        let entries = await waitForHistory(store: store, sessionID: "btw-wire", count: 1)
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.btwSessionId.hasPrefix("btw-"))
        #expect(entry.parentSessionId == "btw-wire")
        #expect(entry.question == "is the cache warm")
        #expect(entry.answer == "The cache is warm.")
        #expect(entry.model == "accounts/fireworks/models/glm-5p2")
        #expect(entry.success == true)
        #expect(entry.error == nil)
        #expect(entry.attempts == 1)
    }

    /// A failed side-call paints the failure copy, appends a FAILED record
    /// (upstream persists failures too, recap.rs:174-178), and the session
    /// keeps working with an untouched conversation.
    @Test("a failed /btw paints the failure copy, records the failure, and the session survives")
    func failedBtwRecordsFailureAndSessionSurvives() async throws {
        let fixture = try BtwFixture()
        defer { fixture.dispose() }
        // A scripted 400 fails the ONE request deterministically (4xx never
        // retries — and this port's side-call is one-shot by design).
        try fixture.server.enqueueResponse(
            path: "/v1/chat/completions",
            response: .json(status: 400, .object(["error": .string("bad btw request")]))
        )
        let harness = try await BtwRendererFixture(
            fixture: fixture,
            modelID: "glm-5.2",
            sessionID: "btw-failure",
            items: btwSeedItems
        )

        try await harness.runController(submitting: ["/btw does it work"])
        #expect(await harness.waitForPaint(of: "side question failed:"))
        // The conversation is untouched and the session still samples.
        #expect(await harness.history.items == btwSeedItems)
        try await harness.runOneTurn(sessionID: "btw-failure", prompt: "still alive?")
        let body = fixture.inferenceBodies().last?.body
        #expect(body?["messages"].arrayValue?.count == btwSeedItems.count + 1)

        let store = LiveBtwHistoryStore(openGrokHome: fixture.home)
        let entries = await waitForHistory(store: store, sessionID: "btw-failure", count: 1)
        let entry = try #require(entries.first)
        #expect(entry.success == false)
        #expect(entry.answer.isEmpty)
        #expect(entry.error?.hasPrefix("side question model call failed:") == true)
        #expect(entry.attempts == 1)
    }

    /// With no live sampling stack behind the renderer, `/btw` answers with
    /// the honest no-session copy (dispatch_send_btw, notes.rs:293-304).
    @Test("/btw with no live session paints \"No active session\"")
    func btwWithoutSessionRefuses() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-btw-nosession-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let sink = BtwCapturingSink()
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
            sessionID: "btw-nosession",
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: ["HOME": home.path, "OPENGROK_HOME": home.path]
        )
        try await renderer.begin()
        try await renderer.render(.overlay(.sideQuestion(question: "anyone home")))

        let deadline = Date().addingTimeInterval(5)
        var painted = sink.strippedText.filter { !$0.isWhitespace }
        while Date() < deadline, !painted.contains("Noactivesession") {
            try? await Task.sleep(nanoseconds: 10_000_000)
            painted = sink.strippedText.filter { !$0.isWhitespace }
        }
        #expect(painted.contains("Noactivesession"))
        try await renderer.restoreTerminal()
    }
}

// MARK: - Mid-turn: the side question and the running turn never touch

/// A canned sampler over the real stack (the `LiveInterjectionTests`
/// fixture pattern): agent-turn requests are recorded and the FIRST agent
/// response is gated until the side question has been asked AND answered —
/// pinning that `/btw` samples CONCURRENTLY with the running turn instead
/// of cancelling, queueing behind, or merging into it.
private actor BtwMidTurnSamplerStore {
    private(set) var agentRequests: [OpenGrokLiveSamplingRequest] = []
    private(set) var btwRequests: [OpenGrokLiveSamplingRequest] = []
    private var queue: [OpenGrokLiveSamplingResponse] = []

    func enqueue(_ responses: [OpenGrokLiveSamplingResponse]) {
        queue.append(contentsOf: responses)
    }

    func waitForAgentRequests(atLeast count: Int, timeout: TimeInterval = 15) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if agentRequests.count >= count { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return agentRequests.count >= count
    }

    func next(_ request: OpenGrokLiveSamplingRequest) async throws -> OpenGrokLiveSamplingResponse {
        // The side question is keyed by upstream's own request-id prefix
        // (`xai-btw-{uuid}`, recap.rs:34) — never by tool absence, which
        // compaction shares.
        if request.turnID.hasPrefix("xai-btw-") {
            btwRequests.append(request)
            return OpenGrokLiveSamplingResponse(output: "warm, per round one")
        }
        if request.tools.isEmpty || request.turnID.hasPrefix("compaction-") {
            return OpenGrokLiveSamplingResponse(output: "compacted summary")
        }
        agentRequests.append(request)
        if agentRequests.count == 1 {
            // Round 1 does not return until the /btw side-call has fully
            // completed, so the side question deterministically ran DURING
            // the turn.
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline, btwRequests.isEmpty {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        if queue.isEmpty {
            return OpenGrokLiveSamplingResponse(output: "done")
        }
        return queue.removeFirst()
    }
}

@Suite("/btw mid-turn live seam", .serialized)
struct LiveBtwMidTurnTests {
    /// Typed `/btw` during a RUNNING turn: the side sample fires and
    /// completes while round one is still in flight, the running turn's
    /// round two carries NEITHER the question NOR the answer, the turn
    /// completes normally (never cancelled), nothing reaches the
    /// interjection buffer, and the record lands on `btw_history.jsonl`.
    @Test("typed /btw mid-turn samples concurrently and never touches the running turn")
    func typedBtwMidTurnIsASideQuestion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-btw-midturn-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try MockInferenceServer()
        defer { server.stop() }
        try """
        [endpoints]
        xai_api_base_url = "\(server.url)"
        """.write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
            "XAI_API_KEY": "test-xai-key",
        ]

        let store = BtwMidTurnSamplerStore()
        await store.enqueue([OpenGrokLiveSamplingResponse(
            output: "",
            toolCalls: [ToolCall(
                id: "call-1",
                name: "todo_write",
                arguments: #"{"todos":[{"id":"1","content":"do it","status":"pending"}]}"#
            )]
        )])
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { request, _ in
                    try await store.next(request)
                }
            }
        )
        let command = try CLICommandParser.parseOrThrow(
            ["headless", "--prompt", "hello", "--cwd", workspace.path, "--model", "grok-4.5"]
        )
        guard case .launch(let options) = command else {
            throw CLIApplicationError.failed("fixture did not parse to a launch")
        }
        let context = CLIApplicationContext(
            environment: environment,
            streams: CLIStreams(out: { _ in }, err: { _ in }),
            control: .never
        )
        let foundation = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: options,
            context: context,
            dependencies: dependencies
        )
        let stack = await OpenGrokLiveApplicationLauncher.makeAgentStack(
            foundation: foundation,
            context: context,
            dependencies: dependencies
        )

        var inputContinuation: AsyncStream<InputEvent>.Continuation!
        let input = AsyncStream<InputEvent> { inputContinuation = $0 }
        let sink = BtwCapturingSink()
        let renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 120, height: 40) },
                write: { _ in }
            ),
            sink: sink,
            workingDirectory: workspace.path,
            modelName: "grok-4.5",
            modelSwitch: stack.modelSwitch,
            sessionID: foundation.sessionID,
            conversationHistory: stack.conversationHistory,
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: environment
        )
        let runtime = LivePagerRuntimeAdapter(
            shell: stack.shell,
            cwd: foundation.cwd,
            providerConfiguration: foundation.providerConfiguration,
            conversationHistory: stack.conversationHistory,
            conversationStore: LiveConversationStore(openGrokHome: home)
        )
        let controller = OpenGrokPagerInteractiveController(
            input: input,
            runtime: runtime,
            renderer: renderer,
            output: BtwDiscardingOutput()
        )
        // The live seam stays installed exactly as the composition installs
        // it — the mid-turn contract is that /btw does NOT use it.
        let interjections = stack.interjections
        await controller.setInterjectionSeam(OpenGrokPagerInterjectionSeam(
            deliver: { text in await interjections.interject(text) },
            collectStranded: { await interjections.collectStranded() }
        ))

        let script = Task {
            inputContinuation.yield(.paste("fix the bug"))
            inputContinuation.yield(.key(KeyEvent(key: .enter)))
            // Round one is in flight once the first agent request lands, and
            // it cannot return until the side question completes — so the
            // typed /btw deterministically runs MID-turn.
            _ = await store.waitForAgentRequests(atLeast: 1)
            inputContinuation.yield(.paste("/btw hurry up"))
            inputContinuation.yield(.key(KeyEvent(key: .enter)))
            _ = await store.waitForAgentRequests(atLeast: 2)
            // Let the turn's final round land in the record.
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                let items = await stack.conversationHistory.items
                if items.contains(where: { item in
                    if case .assistant(let assistant) = item {
                        return assistant.content == "done"
                    }
                    return false
                }) {
                    break
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            await controller.shutdown()
            inputContinuation.finish()
        }
        _ = try? await controller.run(.init(prompt: "", mode: .inline))
        _ = await script.value

        // The side question fired exactly once, tool-free, with the
        // instruction+question as its final user turn.
        let btwRequests = await store.btwRequests
        try #require(btwRequests.count == 1)
        let btwRequest = try #require(btwRequests.first)
        #expect(btwRequest.tools.isEmpty)
        guard case .user(let instruction)? = btwRequest.items.last else {
            Issue.record("the side request must end with the instruction turn")
            return
        }
        #expect(instruction.content == [.text(text: LiveBtw.instruction(
            tag: "system-reminder",
            question: "hurry up"
        ))])

        // The RUNNING turn was never cancelled and never mutated: round two
        // ran, and no request round carried the question or the answer.
        let agentRequests = await store.agentRequests
        try #require(agentRequests.count >= 2)
        for request in agentRequests {
            #expect(!request.items.contains { item in
                guard case .user(let user) = item else { return false }
                return user.content.contains { part in
                    if case .text(let text) = part {
                        return text.contains("hurry up")
                    }
                    return false
                }
            }, "the running turn must never see the side question")
            #expect(!request.items.contains { item in
                guard case .assistant(let assistant) = item else { return false }
                return assistant.content.contains("warm, per round one")
            }, "the running turn must never see the side answer")
        }

        // The committed conversation — memory and disk — is clean of both.
        let liveItems = await stack.conversationHistory.items
        #expect(!liveItems.contains { item in
            let encoded = String(describing: item)
            return encoded.contains("hurry up") || encoded.contains("warm, per round one")
        })
        let reloaded = try await LiveConversationStore(openGrokHome: home)
            .loadIfPresent(sessionID: foundation.sessionID)
        let reloadedDescription = String(describing: reloaded?.items ?? [])
        #expect(!reloadedDescription.contains("hurry up"))
        #expect(!reloadedDescription.contains("warm, per round one"))

        // Nothing reached the interjection seam.
        #expect(await stack.interjections.isEmpty)

        // The answer painted as the BtwBlock-shaped note, and the record
        // landed on the real history file.
        #expect(sink.strippedText.filter { !$0.isWhitespace }.contains("/btwhurryup"))
        #expect(sink.strippedText.filter { !$0.isWhitespace }.contains("warm,perroundone"))
        let historyStore = LiveBtwHistoryStore(openGrokHome: home)
        let entries = await waitForHistory(
            store: historyStore,
            sessionID: foundation.sessionID,
            count: 1
        )
        let entry = try #require(entries.first)
        #expect(entry.question == "hurry up")
        #expect(entry.answer == "warm, per round one")
        #expect(entry.success == true)
    }
}
