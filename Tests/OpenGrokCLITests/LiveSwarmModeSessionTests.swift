// LiveSwarmModeSessionTests.swift
//
// Swarm MODE through the LIVE seam (AGENTS.md §3): what the toggle actually
// CHANGES — the `<system-reminder>` items the next turn samples with — is
// asserted on the wire bodies the mock inference server receives from the
// real turn driver, never on the tracker flag alone. The exclusive-batch
// rule (tool_calls.rs:456-468) is asserted the same way: a scripted model
// batch of `agent_swarm` plus another call must produce the byte-exact
// refusal as every call's tool result and spawn nothing.

import Foundation
import Testing
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellSessionSupport
import OpenGrokTestSupport
@testable import OpenGrokCLI

private struct SwarmModeFixture {
    let home: URL
    let workspace: URL
    let server: MockInferenceServer
    let environment: [String: String]

    init(userConfig: String? = nil) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-swarm-mode-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        server = try MockInferenceServer()
        var config = """
            [endpoints]
            xai_api_base_url = "\(server.url)"
            """
        if let userConfig {
            config += "\n\n" + userConfig
        }
        try config.write(
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

    func context() -> CLIApplicationContext {
        CLIApplicationContext(
            environment: environment,
            streams: CLIStreams(out: { _ in }, err: { _ in }),
            control: .never
        )
    }

    func dependencies() -> OpenGrokLiveCompositionDependencies {
        OpenGrokLiveCompositionDependencies(
            makeSampler: OpenGrokLiveSampler.production(configuration:)
        )
    }

    func makeFoundation() async throws
        -> OpenGrokLiveApplicationLauncher.LiveSessionFoundation {
        let command = try CLICommandParser.parseOrThrow(
            ["headless", "--prompt", "hello", "--cwd", workspace.path, "--model", "grok-4.5"]
        )
        guard case .launch(let options) = command else {
            throw CLIApplicationError.failed("fixture did not parse to a launch")
        }
        return try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: options,
            context: context(),
            dependencies: dependencies()
        )
    }

    func responsesBodies() -> [String] {
        server.requests()
            .filter { $0.method == "POST" && $0.path.contains("responses") }
            .map { (try? $0.body?.encodeString()) ?? "" }
    }
}

private func occurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

/// A distinctive slice of `swarmModeReminder` that appears nowhere else
/// (prompt bodies, tool descriptions mention agent_swarm too — this exact
/// sentence is the reminder's own).
private let reminderSlice = "make one exclusive agent_swarm call with a"
private let exitReminderSlice = "Swarm mode is no longer active."

@Suite("swarm mode at the live turn seam", .serialized)
struct LiveSwarmModeSessionTests {
    private func runTurn(
        _ foundation: OpenGrokLiveApplicationLauncher.LiveSessionFoundation,
        stack: OpenGrokLiveApplicationLauncher.LiveAgentStack,
        fixture: SwarmModeFixture,
        prompt: String,
        promptID: String
    ) async throws {
        let providerSession = try ProviderSessionFactoryAdapter().makeSession(
            for: OpenGrokShellSessionRequest(
                sessionID: SessionID(foundation.sessionID),
                cwd: foundation.cwd,
                providerConfiguration: foundation.providerConfiguration
            )
        )
        _ = try await stack.turnDriver.submit(
            providerSession: providerSession,
            request: OpenGrokShellTurnRequest(
                promptID: promptID,
                text: prompt,
                turnID: promptID
            ),
            emit: { _ in }
        )
    }

    /// Manual mode's payload: the reminder rides the NEXT turn's request as
    /// a `<system-reminder>` user item, exactly once, and persists in the
    /// transcript without re-injection — then survives the turn (manual
    /// never auto-exits).
    @Test("manual swarm mode injects the reminder once and survives turns")
    func manualModeInjectsReminder() async throws {
        let fixture = try SwarmModeFixture()
        defer { fixture.dispose() }
        for text in ["turn one answer", "turn two answer"] {
            try fixture.server.enqueueResponse(
                path: "/v1/responses",
                response: .sse(SseEvents.responsesApiEventsExact(text: text, model: "grok-4.5"))
            )
        }
        let foundation = try await fixture.makeFoundation()
        let stack = await OpenGrokLiveApplicationLauncher.makeAgentStack(
            foundation: foundation,
            context: fixture.context(),
            dependencies: fixture.dependencies()
        )
        defer { Task { await foundation.toolExecutor.shutdown() } }

        // The same entry `/swarm on` and the settings row perform.
        await foundation.toolExecutor.swarmMode.enter(.manual)
        try await runTurn(foundation, stack: stack, fixture: fixture, prompt: "first prompt", promptID: "p1")

        let firstBody = fixture.responsesBodies()[0]
        #expect(occurrences(of: reminderSlice, in: firstBody) == 1)
        #expect(firstBody.contains("<system-reminder>"))

        // Manual survives the turn boundary; the reminder is take-once, so
        // turn two carries the persisted copy and no second injection.
        #expect(await foundation.toolExecutor.swarmMode.enabled)
        try await runTurn(foundation, stack: stack, fixture: fixture, prompt: "second prompt", promptID: "p2")
        let secondBody = fixture.responsesBodies()[1]
        #expect(occurrences(of: reminderSlice, in: secondBody) == 1,
                "the reminder persists in the transcript but is never re-injected")
    }

    /// The one-shot task trigger — `/swarm <task>`'s session half: the task
    /// turn samples with the reminder, the mode auto-exits at the turn
    /// boundary, and the NEXT turn carries the exit notice.
    @Test("a one-shot task turn gets the reminder, auto-exits, and the next turn gets the exit notice")
    func oneShotTaskAutoExits() async throws {
        let fixture = try SwarmModeFixture()
        defer { fixture.dispose() }
        for text in ["task turn answer", "followup answer"] {
            try fixture.server.enqueueResponse(
                path: "/v1/responses",
                response: .sse(SseEvents.responsesApiEventsExact(text: text, model: "grok-4.5"))
            )
        }
        let foundation = try await fixture.makeFoundation()
        let stack = await OpenGrokLiveApplicationLauncher.makeAgentStack(
            foundation: foundation,
            context: fixture.context(),
            dependencies: fixture.dependencies()
        )
        defer { Task { await foundation.toolExecutor.shutdown() } }

        // The mode-then-prompt ordering's session half: `.swarmTaskMode`
        // enters BEFORE the task prompt's turn starts.
        await foundation.toolExecutor.swarmMode.enter(.task)
        try await runTurn(foundation, stack: stack, fixture: fixture, prompt: "the swarm task", promptID: "p1")

        #expect(occurrences(of: reminderSlice, in: fixture.responsesBodies()[0]) == 1)
        // auto_exit_turn (run_loop.rs:419): the one-shot trigger does not
        // survive the turn.
        #expect(await !foundation.toolExecutor.swarmMode.enabled)

        try await runTurn(foundation, stack: stack, fixture: fixture, prompt: "unrelated followup", promptID: "p2")
        let secondBody = fixture.responsesBodies()[1]
        #expect(secondBody.contains(exitReminderSlice),
                "the exit notice must steer the model back out of swarm discipline")
    }

    /// `ui.swarm_mode = true` — the config key that parsed with no reader —
    /// now seeds the session's manual mode. Asserted at its payload: the
    /// tracker is armed and the first turn samples with the reminder.
    /// (The interactive composition seeds from the same effective-config
    /// read; this pins the seed the way that path performs it.)
    @Test("the persisted ui.swarm_mode preference arms manual mode with its reminder")
    func persistedPreferenceSeedsManualMode() async throws {
        let fixture = try SwarmModeFixture(userConfig: """
            [ui]
            swarm_mode = true
            """)
        defer { fixture.dispose() }
        try fixture.server.enqueueResponse(
            path: "/v1/responses",
            response: .sse(SseEvents.responsesApiEventsExact(text: "seeded answer", model: "grok-4.5"))
        )
        let foundation = try await fixture.makeFoundation()
        let stack = await OpenGrokLiveApplicationLauncher.makeAgentStack(
            foundation: foundation,
            context: fixture.context(),
            dependencies: fixture.dependencies()
        )
        defer { Task { await foundation.toolExecutor.shutdown() } }

        // The seed the interactive composition applies from the resolved
        // `[ui]` table (spawn.rs:773-775's session_swarm_mode flag).
        let resolved = LiveInteractiveControllerRenderer.resolveUIConfig(
            workingDirectory: fixture.workspace,
            environment: fixture.environment
        )
        #expect(resolved.config.swarmMode == true, "the fixture's [ui] table must resolve")
        if resolved.config.swarmMode == true {
            await foundation.toolExecutor.swarmMode.enter(.manual)
        }

        try await runTurn(foundation, stack: stack, fixture: fixture, prompt: "hello", promptID: "p1")
        #expect(occurrences(of: reminderSlice, in: fixture.responsesBodies()[0]) == 1)
        #expect(await foundation.toolExecutor.swarmMode.enabled)
    }

    /// The exclusive-batch rule (tool_calls.rs:456-468) at the live driver:
    /// a model batch of `agent_swarm` plus any other call executes NOTHING —
    /// every call's tool result is the byte-exact refusal, and no child
    /// ever reaches the coordinator.
    @Test("agent_swarm mixed into a batch refuses every call and spawns nothing")
    func exclusiveBatchRefusal() async throws {
        let fixture = try SwarmModeFixture()
        defer { fixture.dispose() }
        let swarmArguments = #"{\"description\":\"d\",\"prompt_template\":\"{{item}}\",\"items\":[\"a\",\"b\"]}"#
        let readArguments = #"{\"path\":\"README.md\"}"#
        // Hand-rolled two-call batch, modeled on
        // `responsesApiReasoningThenToolCallEvents`' event grammar.
        let events: [SseEvent] = [
            .data(#"{"type":"response.created","sequence_number":0,"response":{"id":"resp_test","object":"response","created_at":1234567890,"model":"grok-4.5","status":"in_progress","output":[]}}"#),
            .data(#"{"type":"response.function_call_arguments.delta","sequence_number":1,"item_id":"call-batch-1","output_index":0,"delta":"\#(swarmArguments)"}"#),
            .data(#"{"type":"response.function_call_arguments.delta","sequence_number":2,"item_id":"call-batch-2","output_index":1,"delta":"\#(readArguments)"}"#),
            .data(#"{"type":"response.completed","sequence_number":3,"response":{"id":"resp_test","object":"response","created_at":1234567890,"model":"grok-4.5","status":"completed","output":[{"type":"function_call","call_id":"call-batch-1","name":"agent_swarm","arguments":"\#(swarmArguments)"},{"type":"function_call","call_id":"call-batch-2","name":"read_file","arguments":"\#(readArguments)"}],"usage":{"input_tokens":10,"output_tokens":20,"total_tokens":30,"input_tokens_details":{"cached_tokens":0},"output_tokens_details":{"reasoning_tokens":0}}}}"#),
            .data("[DONE]"),
        ]
        try fixture.server.enqueueResponse(path: "/v1/responses", response: .sse(events))
        try fixture.server.enqueueResponse(
            path: "/v1/responses",
            response: .sse(SseEvents.responsesApiEventsExact(text: "settled", model: "grok-4.5"))
        )

        let foundation = try await fixture.makeFoundation()
        let stack = await OpenGrokLiveApplicationLauncher.makeAgentStack(
            foundation: foundation,
            context: fixture.context(),
            dependencies: fixture.dependencies()
        )
        defer { Task { await foundation.toolExecutor.shutdown() } }

        try await runTurn(foundation, stack: stack, fixture: fixture, prompt: "go", promptID: "p1")

        let bodies = fixture.responsesBodies()
        #expect(bodies.count == 2, "the refusal round-trips as tool results, then the turn ends")
        guard bodies.count == 2 else { return }
        // JSON-encoded on the wire: backticks survive, so distinctive
        // unescaped slices of the byte-pinned refusal (the full copy is
        // pinned at `LiveShellSamplingDriver.swarmExclusiveBatchError`)
        // are asserted plus both call ids.
        #expect(occurrences(of: "must be the only tool call in its batch", in: bodies[1]) == 2,
                "every call in the violating batch carries the refusal")
        #expect(bodies[1].contains("Inspect briefly, then make one exclusive agent_swarm call"))
        #expect(bodies[1].contains("call-batch-1"))
        #expect(bodies[1].contains("call-batch-2"))

        // Nothing executed: no child reached the coordinator.
        #expect(await foundation.subagentHost?.knownSubagentIDs().isEmpty == true)
    }
}
