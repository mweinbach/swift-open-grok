// PagerNewSlashCommandTests.swift
//
// Reachability for the slash commands this wave registered — `/resume`,
// `/usage`, `/btw`, `/mcps`, `/effort`, `/rename` — through the live seam
// (AGENTS.md §3): real input events into the real controller, and the only
// accepted evidence is what lands on the render adapter and the runtime.
// None of these assert registry membership; every test dispatches the
// command and observes its overlay or effect.

import Foundation
import OpenGrokPager
import OpenGrokTerminalCore
import Testing

@Suite("New slash commands at the controller seam")
struct PagerNewSlashCommandTests {
    // MARK: - /usage

    @Test("/usage opens the usage overlay and /cost is the same command")
    func usageOpensOverlay() async throws {
        let harness = try await CommandHarness.run(submitting: ["/usage", "/cost"])
        #expect(await harness.overlayRequests.filter { $0 == .usage }.count == 2)
    }

    @Test("/usage refuses arguments with upstream's non-consumer copy")
    func usageRefusesArguments() async throws {
        // usage.rs:57-61: without the billing surface, any argument —
        // including upstream's own `manage` — is refused.
        let harness = try await CommandHarness.run(submitting: ["/usage manage"])
        #expect(await harness.overlayRequests.isEmpty)
        #expect(await harness.notices.contains("Unknown argument: manage. Use /usage"))
    }

    // MARK: - /resume

    @Test("/resume opens the session picker")
    func resumeOpensPicker() async throws {
        let harness = try await CommandHarness.run(submitting: ["/resume"])
        #expect(await harness.overlayRequests.contains(.sessionPicker))
    }

    @Test("a picker selection reaches the runtime swap and repaints the resumed session")
    func resumeSelectionReachesRuntime() async throws {
        // The picker's row selection round-trips as `/resume <id>`; the
        // controller must call the runtime and announce the swap.
        let harness = try await CommandHarness.run(submitting: ["/resume stored-session"])
        #expect(await harness.runtimeResumes == ["stored-session"])
        #expect(await harness.sessionResumes == ["stored-session"])
    }

    @Test("a runtime that cannot resume yields a notice, not a dead run")
    func resumeFailureIsANotice() async throws {
        let harness = try await CommandHarness.run(
            submitting: ["/resume missing", "/help"],
            resumeOutcome: .failure
        )
        #expect(await harness.sessionResumes.isEmpty)
        #expect(await harness.notices.contains { $0.hasPrefix("Could not resume session missing:") })
        // The run survived to service the next command.
        #expect(await harness.overlayRequests.contains(.help))
    }

    // MARK: - /btw

    @Test("/btw holds the question and folds it ahead of the next prompt")
    func btwLeadsTheNextPrompt() async throws {
        let harness = try await CommandHarness.run(
            submitting: ["/btw is the cache warm", "carry on"],
            expectedTurns: 1
        )
        let prompt = await harness.turnPrompts.first { $0.contains("carry on") }
        // The interjection frame is the shell's historical format — the same
        // one enter_steers produces — and the question leads the prompt.
        #expect(prompt?.contains("is the cache warm") == true)
        #expect(prompt?.hasSuffix("carry on") == true)
        if let prompt,
           let question = prompt.range(of: "is the cache warm"),
           let followUp = prompt.range(of: "carry on") {
            #expect(question.lowerBound < followUp.lowerBound)
        }
    }

    @Test("/btw without a question is refused with its usage line")
    func btwRequiresAQuestion() async throws {
        // The trailing space lands the draft in the argument phase, where
        // Enter is a plain send; a bare "/btw" Enter now completes into that
        // phase instead of dispatching (upstream's `is_command_complete`).
        let harness = try await CommandHarness.run(submitting: ["/btw "])
        #expect(await harness.notices.contains("Usage: /btw <question>"))
    }

    // MARK: - /mcps

    @Test("/mcps opens the MCP status overlay")
    func mcpsOpensOverlay() async throws {
        let harness = try await CommandHarness.run(submitting: ["/mcps"])
        #expect(await harness.overlayRequests.contains(.mcpServers))
    }

    // MARK: - /effort

    @Test("/effort forwards the level query to the render layer, nil when bare")
    func effortForwardsQuery() async throws {
        // Trailing space on the bare form: a bare "/effort" Enter completes
        // into the argument phase now, so the dispatching press is the one
        // from the phase itself (upstream's `is_command_complete`).
        let harness = try await CommandHarness.run(submitting: ["/effort ", "/effort high"])
        #expect(await harness.overlayRequests == [
            .reasoningEffort(query: nil),
            .reasoningEffort(query: "high"),
        ])
    }

    // MARK: - /rename

    @Test("/rename forwards the title and /title is the same command")
    func renameForwardsTitle() async throws {
        let harness = try await CommandHarness.run(
            submitting: ["/rename My refactor session", "/title Two"]
        )
        #expect(await harness.overlayRequests == [
            .renameSession(title: "My refactor session"),
            .renameSession(title: "Two"),
        ])
    }

    @Test("/rename without a title is refused with upstream's usage copy")
    func renameRequiresTitle() async throws {
        // rename.rs:48-50. Trailing space: see btwRequiresAQuestion.
        let harness = try await CommandHarness.run(submitting: ["/rename "])
        #expect(await harness.overlayRequests.isEmpty)
        #expect(await harness.notices.contains("Usage: /rename <new title>"))
    }
}

// MARK: - Harness

private actor CommandHarness {
    private let renderer: CommandRecordingRenderer
    private let runtime: CommandTestRuntime

    private init(renderer: CommandRecordingRenderer, runtime: CommandTestRuntime) {
        self.renderer = renderer
        self.runtime = runtime
    }

    var overlayRequests: [OpenGrokPagerOverlayRequest] {
        get async { await renderer.overlayRequests }
    }
    var notices: [String] { get async { await renderer.notices } }
    var sessionResumes: [String] { get async { await renderer.sessionResumes } }
    var runtimeResumes: [String] { get async { await runtime.resumedSessionIDs } }
    var turnPrompts: [String] { get async { await runtime.requests.map(\.prompt) } }

    enum ResumeOutcome {
        case success
        case failure
    }

    /// Type each line and press Enter, then let input exhaustion end the run
    /// (or, when a turn is expected, shut down once it has landed).
    static func run(
        submitting lines: [String],
        resumeOutcome: ResumeOutcome = .success,
        expectedTurns: Int? = nil
    ) async throws -> CommandHarness {
        var events: [InputEvent] = []
        for line in lines {
            events.append(.paste(line))
            events.append(.key(KeyEvent(key: .enter)))
        }
        let renderer = CommandRecordingRenderer()
        let runtime = CommandTestRuntime(resumeFails: resumeOutcome == .failure)
        let controller = OpenGrokPagerInteractiveController(
            input: makeStream(events, stayOpen: expectedTurns != nil),
            runtime: runtime,
            renderer: renderer,
            output: SilentCommandOutput()
        )
        let stopper: Task<Void, Never>? = expectedTurns.map { turns in
            Task {
                await runtime.waitForRequestCount(atLeast: turns)
                await controller.shutdown()
            }
        }
        _ = try await controller.run(.init(prompt: "", mode: .inline))
        stopper?.cancel()
        return CommandHarness(renderer: renderer, runtime: runtime)
    }
}

private actor CommandRecordingRenderer: OpenGrokPagerInteractiveRenderAdapter {
    private var events: [OpenGrokPagerInteractiveEvent] = []

    func begin() {}
    func restoreTerminal() {}

    func render(_ event: OpenGrokPagerInteractiveEvent) {
        events.append(event)
    }

    var overlayRequests: [OpenGrokPagerOverlayRequest] {
        events.compactMap { if case .overlay(let request) = $0 { return request } else { return nil } }
    }

    var notices: [String] {
        events.compactMap { if case .notice(let message) = $0 { return message } else { return nil } }
    }

    var sessionResumes: [String] {
        events.compactMap {
            if case .sessionResumed(let sessionID) = $0 { return sessionID }
            return nil
        }
    }
}

private struct SilentCommandOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}

private actor CommandTestRuntime: OpenGrokPagerRuntimeAdapter {
    private(set) var requests: [OpenGrokPagerRequest] = []
    private(set) var resumedSessionIDs: [String] = []
    private let resumeFails: Bool
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(resumeFails: Bool) {
        self.resumeFails = resumeFails
    }

    func waitForRequestCount(atLeast count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }

    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        requests.append(request)
        let ready = requestWaiters.filter { $0.0 <= requests.count }
        requestWaiters.removeAll { $0.0 <= requests.count }
        for waiter in ready { waiter.1.resume() }
        let session = ImmediateSession(sessionID: request.sessionID ?? "auto")
        session.finish()
        return session
    }

    func replaceSession(from request: OpenGrokPagerRequest) async throws -> String {
        _ = request
        return "replacement"
    }

    func resumeSession(sessionID: String) async throws -> String {
        guard !resumeFails else {
            throw OpenGrokPagerError.sessionResumeUnsupported
        }
        resumedSessionIDs.append(sessionID)
        return sessionID
    }
}

private final class ImmediateSession: OpenGrokPagerSessionAdapter, @unchecked Sendable {
    let sessionID: String?
    let events: AsyncThrowingStream<OpenGrokPagerEvent, Error>
    private let continuation: AsyncThrowingStream<OpenGrokPagerEvent, Error>.Continuation

    init(sessionID: String) {
        self.sessionID = sessionID
        var captured: AsyncThrowingStream<OpenGrokPagerEvent, Error>.Continuation!
        events = AsyncThrowingStream { captured = $0 }
        continuation = captured
    }

    func finish() {
        continuation.yield(.completed(.init(sessionID: sessionID)))
        continuation.finish()
    }

    func cancel() async {
        continuation.yield(.cancelled)
        continuation.finish()
    }

    func close() async {
        continuation.finish()
    }
}

private func makeStream(_ events: [InputEvent], stayOpen: Bool) -> AsyncStream<InputEvent> {
    AsyncStream { continuation in
        for event in events { continuation.yield(event) }
        if !stayOpen { continuation.finish() }
    }
}
