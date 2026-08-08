// LiveInterjectionTests.swift
//
// TRUE mid-turn interjection through the LIVE seam (AGENTS.md §3): the
// composition the executable actually runs — `makeSessionFoundation` →
// `makeAgentStack` → the real `OpenGrokShell` driving the real
// `LiveShellSamplingDriver` turn loop — with the evidence read off the
// sampler REQUESTS (the items array the model is actually offered) and the
// persisted conversation record. A composition-level test would pass just
// as happily when nothing drains the buffer; these do not.
//
// Upstream ground truth at the pinned reference (650c1db7):
// `drain_pending_interjections` call sites (turn.rs:2413, tool_calls.rs:509,
// turn.rs:2956, turn.rs:2968), the `SessionCommand::Interject` running/idle
// split (run_loop.rs:1962-1989), and the Cancel arm's buffer clear
// (run_loop.rs:989-991).
//
// `/btw` no longer produces into this seam — it is a real side question
// (Wave 15 item 7); its typed live-seam coverage lives in
// `LiveBtwTests.swift`. The buffer's live producer is the subagent
// collaboration quartet (`LiveSubagentHost`), and these tests drive the
// seam directly, which is exactly the producer-side call that host makes.
//
// Fixture patterns follow `LiveHookEventsReachabilityTests.swift` (canned
// sampler over the real stack) and `LiveRecapTests.swift` (hermetic home,
// endpoint pins, bounded polls).

import Foundation
import Testing
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

/// The exact model-visible frame for a drained interjection — byte-identical
/// to upstream's `format_interjection` output (xai-interjection-core
/// format.rs:16-33).
private func expectedFrame(_ text: String) -> String {
    "The user sent a message while you were working:\n<user_query>\n\(text)\n</user_query>"
}

/// Whether `item` is the synthetic interjection user item for `text`.
private func isInterjectionItem(_ item: ConversationItem, text: String) -> Bool {
    guard case .user(let user) = item else { return false }
    return user.syntheticReason == .interjection
        && user.content == [.text(text: expectedFrame(text))]
}

// MARK: - Fixture

private struct InterjectionFixture {
    let home: URL
    let workspace: URL
    let server: MockInferenceServer
    let environment: [String: String]

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-interject-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        server = try MockInferenceServer()
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
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
            "XAI_API_KEY": "test-xai-key",
        ]
    }

    func dispose() {
        server.stop()
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    func launchOptions() throws -> CLIExecutionOptions {
        let command = try CLICommandParser.parseOrThrow(
            ["headless", "--prompt", "hello", "--cwd", workspace.path, "--model", "grok-4.5"]
        )
        guard case .launch(let options) = command else {
            throw CLIApplicationError.failed("fixture did not parse to a launch")
        }
        return options
    }

    func context() -> CLIApplicationContext {
        CLIApplicationContext(
            environment: environment,
            streams: CLIStreams(out: { _ in }, err: { _ in }),
            control: .never
        )
    }
}

// MARK: - Canned sampler

/// A canned sampler that records every agent-turn request (the items array
/// is the wire evidence) and can gate its first agent response — either
/// until the live interjection buffer is non-empty (so the drain point
/// deterministically sees the entry) or until cancellation lands.
private actor InterjectionSamplerStore {
    private(set) var agentRequests: [OpenGrokLiveSamplingRequest] = []
    private var queue: [OpenGrokLiveSamplingResponse] = []
    /// Bounded-poll probe evaluated before the FIRST agent response returns;
    /// `nil` gates nothing.
    private var firstResponseGate: (@Sendable () async -> Bool)?
    /// Hold the first agent response until task cancellation (cancel test).
    private var holdFirstResponse = false

    func enqueue(_ responses: [OpenGrokLiveSamplingResponse]) {
        queue.append(contentsOf: responses)
    }

    func gateFirstResponse(until probe: @escaping @Sendable () async -> Bool) {
        firstResponseGate = probe
    }

    func holdFirstResponseUntilCancelled() {
        holdFirstResponse = true
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
        if request.tools.isEmpty || request.turnID.hasPrefix("compaction-") {
            return OpenGrokLiveSamplingResponse(output: "compacted summary")
        }
        agentRequests.append(request)
        if agentRequests.count == 1 {
            if holdFirstResponse {
                // Task.sleep observes cancellation, which is how the hold
                // resolves: the cancelled turn throws out of the sampler.
                while true {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
            }
            if let firstResponseGate {
                let deadline = Date().addingTimeInterval(15)
                while Date() < deadline, !(await firstResponseGate()) {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
            }
        }
        if queue.isEmpty {
            return OpenGrokLiveSamplingResponse(output: "done")
        }
        return queue.removeFirst()
    }
}

private func makeCannedSampler(_ store: InterjectionSamplerStore) -> OpenGrokLiveSampler {
    OpenGrokLiveSampler { request, _ in
        try await store.next(request)
    }
}

private func toolCallResponse() -> OpenGrokLiveSamplingResponse {
    OpenGrokLiveSamplingResponse(
        output: "",
        toolCalls: [ToolCall(
            id: "call-1",
            name: "todo_write",
            arguments: #"{"todos":[{"id":"1","content":"do it","status":"pending"}]}"#
        )]
    )
}

/// Build the real foundation + agent stack over the canned sampler.
private func makeStack(
    fixture: InterjectionFixture,
    store: InterjectionSamplerStore
) async throws -> (
    foundation: OpenGrokLiveApplicationLauncher.LiveSessionFoundation,
    stack: OpenGrokLiveApplicationLauncher.LiveAgentStack
) {
    let dependencies = OpenGrokLiveCompositionDependencies(
        makeSampler: { _ in makeCannedSampler(store) }
    )
    let foundation = try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
        options: fixture.launchOptions(),
        context: fixture.context(),
        dependencies: dependencies
    )
    let stack = await OpenGrokLiveApplicationLauncher.makeAgentStack(
        foundation: foundation,
        context: fixture.context(),
        dependencies: dependencies
    )
    return (foundation, stack)
}

// MARK: - Session-actor seam

@Suite("Mid-turn interjection: session actor", .serialized)
struct LiveInterjectionSessionActorTests {
    /// A multi-round turn (tool call, then final text) with an interjection
    /// buffered during round one: the SECOND sampler request's body must
    /// carry the synthetic user item AFTER the tool result, as the last
    /// item, wrapped byte-exactly — and the completed turn's session record
    /// must persist it (the opposite of `/recap`'s no-mutation contract:
    /// an interjection MUST mutate the conversation).
    @Test("an interjection drains into the running turn's next sampler round and persists")
    func interjectionDrainsIntoRunningTurn() async throws {
        let fixture = try InterjectionFixture()
        defer { fixture.dispose() }
        let store = InterjectionSamplerStore()
        await store.enqueue([toolCallResponse()])
        let (foundation, stack) = try await makeStack(fixture: fixture, store: store)
        // Round 1 does not return until the interjection is in the buffer,
        // so the round-2 drain point deterministically sees it.
        let interjections = stack.interjections
        await store.gateFirstResponse { await !interjections.isEmpty }

        let shell = stack.shell
        _ = try await shell.start()
        let sessionID = SessionID(foundation.sessionID)
        _ = try await shell.createSession(OpenGrokShellSessionRequest(
            sessionID: sessionID,
            cwd: foundation.cwd,
            providerConfiguration: foundation.providerConfiguration
        ))
        let handle = try await shell.submitTurn(
            sessionID: sessionID,
            request: OpenGrokShellTurnRequest(promptID: "p1", text: "do a todo", turnID: "t1")
        )
        // The turn task flips the seam active shortly after submit; a false
        // return means it has not begun yet, so retry — a false push buffers
        // nothing, which is what makes the retry safe.
        var delivered = false
        let deliverDeadline = Date().addingTimeInterval(15)
        while !delivered, Date() < deliverDeadline {
            delivered = await stack.interjections.interject("hurry up")
            if !delivered { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        #expect(delivered, "the running turn must accept the interjection")

        _ = try await shell.waitForTurn(handle, timeout: ShellDuration(timeInterval: 30))

        // Wire evidence: the SECOND agent request carries the synthetic user
        // item after the tool result, at the end of the items array.
        let requests = await store.agentRequests
        try #require(requests.count >= 2)
        let secondItems = requests[1].items
        #expect(
            isInterjectionItem(try #require(secondItems.last), text: "hurry up"),
            "the interjection must be the last item of round two, got \(secondItems)"
        )
        let toolResultIndex = secondItems.lastIndex {
            if case .toolResult = $0 { return true } else { return false }
        }
        let interjectionIndex = secondItems.lastIndex { isInterjectionItem($0, text: "hurry up") }
        #expect(
            toolResultIndex != nil && interjectionIndex != nil
                && toolResultIndex! < interjectionIndex!,
            "the interjection must land after the tool results"
        )
        // The first request must NOT have carried it (it did not exist yet).
        #expect(!requests[0].items.contains { isInterjectionItem($0, text: "hurry up") })

        // Persistence: the interjection is a REAL user item in the committed
        // conversation, in memory and on disk.
        let liveItems = await stack.conversationHistory.items
        #expect(liveItems.contains { isInterjectionItem($0, text: "hurry up") })
        let reloaded = try await LiveConversationStore(openGrokHome: fixture.home)
            .loadIfPresent(sessionID: foundation.sessionID)
        #expect(
            reloaded?.items.contains { isInterjectionItem($0, text: "hurry up") } == true,
            "the interjection must persist to the session record"
        )
        // Nothing stranded, nothing left over.
        #expect(await stack.interjections.isEmpty)
    }

    /// The `SessionCommand::Interject` idle split (run_loop.rs:1980-1989):
    /// with no running turn the seam refuses, which is the caller's cue to
    /// queue the text as its own fallback prompt turn.
    @Test("an interjection with no running turn is refused for the fallback path")
    func idleInterjectionIsRefused() async throws {
        let fixture = try InterjectionFixture()
        defer { fixture.dispose() }
        let store = InterjectionSamplerStore()
        let (_, stack) = try await makeStack(fixture: fixture, store: store)
        #expect(await stack.interjections.interject("too early") == false)
        #expect(await stack.interjections.isEmpty, "a refused interjection must not buffer")
    }

    /// Cancellation clears the buffer — upstream's Cancel arm: "the turn is
    /// being cancelled, so they have no active turn to inject into"
    /// (run_loop.rs:989-991). The next turn's request must not carry it.
    @Test("cancelling the turn drops its pending interjections")
    func cancellationClearsPendingInterjections() async throws {
        let fixture = try InterjectionFixture()
        defer { fixture.dispose() }
        let store = InterjectionSamplerStore()
        await store.holdFirstResponseUntilCancelled()
        let (foundation, stack) = try await makeStack(fixture: fixture, store: store)

        let shell = stack.shell
        _ = try await shell.start()
        let sessionID = SessionID(foundation.sessionID)
        _ = try await shell.createSession(OpenGrokShellSessionRequest(
            sessionID: sessionID,
            cwd: foundation.cwd,
            providerConfiguration: foundation.providerConfiguration
        ))
        let handle = try await shell.submitTurn(
            sessionID: sessionID,
            request: OpenGrokShellTurnRequest(promptID: "p1", text: "long turn", turnID: "t1")
        )
        var delivered = false
        let deliverDeadline = Date().addingTimeInterval(15)
        while !delivered, Date() < deliverDeadline {
            delivered = await stack.interjections.interject("never mind")
            if !delivered { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        #expect(delivered)

        try await shell.cancelTurn(handle)
        do {
            _ = try await shell.waitForTurn(handle, timeout: ShellDuration(timeInterval: 30))
            Issue.record("the cancelled turn should not report success")
        } catch {
            // Expected: the turn ended cancelled.
        }
        // Bounded poll: the driver's catch runs on the turn task after the
        // shell reports cancellation.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !(await stack.interjections.isEmpty) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(
            await stack.interjections.isEmpty,
            "cancel must clear pending interjections (run_loop.rs:989-991)"
        )

        // The dropped text must not leak into the next turn's request.
        let handle2 = try await shell.submitTurn(
            sessionID: sessionID,
            request: OpenGrokShellTurnRequest(promptID: "p2", text: "fresh start", turnID: "t2")
        )
        _ = try await shell.waitForTurn(handle2, timeout: ShellDuration(timeInterval: 30))
        let requests = await store.agentRequests
        let lastItems = try #require(requests.last).items
        #expect(!lastItems.contains { isInterjectionItem($0, text: "never mind") })
    }
}
