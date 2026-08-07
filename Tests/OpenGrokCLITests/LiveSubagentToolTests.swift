// LiveSubagentToolTests.swift
//
// The subagent stack through the LIVE seam (AGENTS.md §3): the composition
// the executable actually runs — `makeSessionFoundation` / `makeAgentStack`,
// the real `OpenGrokLiveSampler.production` factory against the mock
// inference server, and the real `LiveToolExecutor` dispatch — so the
// assertions below fail if the wiring regresses, not merely if a library
// does.
//
// Covered, in order:
//   * advertisement: `spawn_subagent` reaches the model exactly when the
//     upstream gate (subagents enabled + non-empty roster, builder.rs:848-896)
//     says so — and `--no-subagents` / an all-toggled-off roster remove it;
//   * end-to-end: a scripted model turn calling `spawn_subagent` spawns a
//     child whose own turn runs against the mock server, the child cannot
//     see the spawn surface (the strip rule), and the result round-trips
//     through `get_task_output`;
//   * cancel: `kill_task` on a subagent id kills the child;
//   * spawn-time validation copy (unknown / disabled types).

import Foundation
import Testing
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokTestSupport
@testable import OpenGrokCLI

// MARK: - Fixture

private struct SubagentFixture {
    let home: URL
    let workspace: URL
    let server: MockInferenceServer
    let environment: [String: String]

    init(extraEnvironment: [String: String] = [:], userConfig: String? = nil) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-subagent-\(UUID().uuidString)", isDirectory: true)
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
        var env = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": home.appendingPathComponent("state").path,
            "XAI_API_KEY": "test-xai-key",
        ]
        for (key, value) in extraEnvironment { env[key] = value }
        environment = env
    }

    func dispose() {
        server.stop()
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    func launchOptions(_ arguments: [String]) throws -> CLIExecutionOptions {
        let command = try CLICommandParser.parseOrThrow(
            ["headless", "--prompt", "hello", "--cwd", workspace.path] + arguments
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

    /// The REAL production sampler factory — the child must reach the wire
    /// through the code path the executable runs, not a stub.
    func productionDependencies() -> OpenGrokLiveCompositionDependencies {
        OpenGrokLiveCompositionDependencies(
            makeSampler: OpenGrokLiveSampler.production(configuration:)
        )
    }

    func makeFoundation(_ arguments: [String] = ["--model", "grok-4.5"]) async throws
        -> OpenGrokLiveApplicationLauncher.LiveSessionFoundation {
        try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
            options: launchOptions(arguments),
            context: context(),
            dependencies: productionDependencies()
        )
    }

    /// Inference POST bodies to the Responses endpoint, in arrival order.
    func responsesRequests() -> [LogEntry] {
        server.requests().filter { $0.method == "POST" && $0.path.contains("responses") }
    }

    /// Poll until `predicate` matches a logged request or the deadline passes.
    func waitForRequest(
        containing marker: String,
        timeoutSeconds: UInt64 = 15
    ) async -> LogEntry? {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            if let match = server.requests().first(where: {
                Self.bodyText($0).contains(marker)
            }) {
                return match
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    /// Encoded request body for content assertions; a body that fails to
    /// encode reads as empty (it then simply never matches a marker).
    static func bodyText(_ entry: LogEntry) -> String {
        (try? entry.body?.encodeString()) ?? ""
    }
}

private func toolNames(in entry: LogEntry) -> [String] {
    entry.body?["tools"].arrayValue?.compactMap { $0["name"].stringValue } ?? []
}

// MARK: - Advertisement gates

@Suite("subagent tool advertisement", .serialized)
struct LiveSubagentAdvertisementTests {
    @Test("a default session advertises spawn_subagent with the discovered roster")
    func advertisesSpawnTool() async throws {
        let fixture = try SubagentFixture()
        defer { fixture.dispose() }
        let foundation = try await fixture.makeFoundation()
        defer { Task { await foundation.toolExecutor.shutdown() } }

        let advertised = Set(foundation.toolExecutor.tools.map(\.name))
        #expect(advertised.contains("spawn_subagent"))
        #expect(foundation.subagentHost != nil)

        let spec = foundation.toolExecutor.tools.first { $0.name == "spawn_subagent" }
        #expect(spec?.description?.contains("**general-purpose**") == true)
        #expect(spec?.description?.contains("**explore**") == true)
        // The description must point at the retrieval tool this session
        // actually advertises, never a renamed one it does not.
        #expect(spec?.description?.contains("get_command_or_subagent_output") == true)
    }

    @Test("--no-subagents launches and strips the spawn surface")
    func noSubagentsStripsTool() async throws {
        let fixture = try SubagentFixture()
        defer { fixture.dispose() }
        // Before the stack landed this flag was refused as unhonorable; the
        // launch now succeeds and the flag is the kill switch.
        let foundation = try await fixture.makeFoundation(["--model", "grok-4.5", "--no-subagents"])
        defer { Task { await foundation.toolExecutor.shutdown() } }

        #expect(foundation.subagentHost == nil)
        #expect(!foundation.toolExecutor.tools.map(\.name).contains("spawn_subagent"))
    }

    @Test("an all-toggled-off roster strips the spawn surface")
    func emptyRosterStripsTool() async throws {
        let fixture = try SubagentFixture(userConfig: """
            [subagents.toggle]
            general-purpose = false
            explore = false
            plan = false
            """)
        defer { fixture.dispose() }
        let foundation = try await fixture.makeFoundation()
        defer { Task { await foundation.toolExecutor.shutdown() } }

        #expect(foundation.subagentHost == nil)
        #expect(!foundation.toolExecutor.tools.map(\.name).contains("spawn_subagent"))
    }

    @Test("the advertised list reaches the wire on a real launch")
    func advertisedListReachesTheWire() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-subagent-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var toolNames: [[String]] = []
            func append(_ tools: [ToolSpec]) {
                lock.lock()
                defer { lock.unlock() }
                toolNames.append(tools.map(\.name))
            }
        }
        let recorder = Recorder()
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { request, emit in
                    recorder.append(request.tools)
                    await emit(.output("done"))
                    return OpenGrokLiveSamplingResponse(output: "done", stopReason: "stop")
                }
            }
        )
        let application = OpenGrokApplication.live(dependencies: dependencies, control: .never)
        let (streams, _, _) = CLIStreams.buffered()
        let code = await CLIRunner.run(
            ["headless", "--prompt", "hi", "--cwd", root.path],
            environment: [
                "HOME": root.path,
                "OPENGROK_HOME": root.appendingPathComponent("state").path,
                "XDG_STATE_HOME": root.appendingPathComponent("state").path,
                "XAI_API_KEY": "test-key",
            ],
            streams: streams,
            application: application
        )
        #expect(code == CLIRunner.ExitCode.success.rawValue)
        #expect(recorder.toolNames.first?.contains("spawn_subagent") == true)
    }

    @Test("--no-subagents reaches the wire as an absent tool")
    func noSubagentsReachesTheWire() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-subagent-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var toolNames: [[String]] = []
            func append(_ tools: [ToolSpec]) {
                lock.lock()
                defer { lock.unlock() }
                toolNames.append(tools.map(\.name))
            }
        }
        let recorder = Recorder()
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                OpenGrokLiveSampler { request, emit in
                    recorder.append(request.tools)
                    await emit(.output("done"))
                    return OpenGrokLiveSamplingResponse(output: "done", stopReason: "stop")
                }
            }
        )
        let application = OpenGrokApplication.live(dependencies: dependencies, control: .never)
        let (streams, _, _) = CLIStreams.buffered()
        let code = await CLIRunner.run(
            ["headless", "--prompt", "hi", "--cwd", root.path, "--no-subagents"],
            environment: [
                "HOME": root.path,
                "OPENGROK_HOME": root.appendingPathComponent("state").path,
                "XDG_STATE_HOME": root.appendingPathComponent("state").path,
                "XAI_API_KEY": "test-key",
            ],
            streams: streams,
            application: application
        )
        // The flag used to be refused as unhonorable; it now launches and
        // simply strips the surface.
        #expect(code == CLIRunner.ExitCode.success.rawValue)
        #expect(recorder.toolNames.first?.contains("spawn_subagent") == false)
    }
}

// MARK: - End-to-end spawn

@Suite("subagent spawn end-to-end", .serialized)
struct LiveSubagentSpawnTests {
    /// One foreground spawn through a scripted root turn: the parent calls
    /// `spawn_subagent`, the child runs its own turn against the mock server,
    /// and the parent reads the completion. Foreground keeps the mock's FIFO
    /// script deterministic — the child samples only while the parent is
    /// blocked in the tool call.
    @Test("a scripted turn spawns a child whose turn runs against the mock server")
    func foregroundSpawnRunsChildEndToEnd() async throws {
        let fixture = try SubagentFixture()
        defer { fixture.dispose() }

        let taskPrompt = "Find the meaning of the keystone slice \(UUID().uuidString)"
        try fixture.server.enqueueResponse(
            path: "/v1/responses",
            response: .sse(SseEvents.responsesApiReasoningThenToolCallEvents(
                reasoning: "Delegating.",
                callId: "call-spawn-1",
                name: "spawn_subagent",
                arguments: #"{"prompt":"\#(taskPrompt)","description":"keystone probe","subagent_type":"general-purpose","background":false}"#,
                model: "grok-4.5"
            ))
        )
        try fixture.server.enqueueResponse(
            path: "/v1/responses",
            response: .sse(SseEvents.responsesApiEventsExact(
                text: "the child answered from its own turn",
                model: "grok-4.5"
            ))
        )
        try fixture.server.enqueueResponse(
            path: "/v1/responses",
            response: .sse(SseEvents.responsesApiEventsExact(
                text: "root final answer",
                model: "grok-4.5"
            ))
        )

        let foundation = try await fixture.makeFoundation()
        let stack = await OpenGrokLiveApplicationLauncher.makeAgentStack(
            foundation: foundation,
            context: fixture.context(),
            dependencies: fixture.productionDependencies()
        )
        defer { Task { await foundation.toolExecutor.shutdown() } }
        let providerSession = try ProviderSessionFactoryAdapter().makeSession(
            for: OpenGrokShellSessionRequest(
                sessionID: SessionID(foundation.sessionID),
                cwd: foundation.cwd,
                providerConfiguration: foundation.providerConfiguration
            )
        )

        let result = try await stack.turnDriver.submit(
            providerSession: providerSession,
            request: OpenGrokShellTurnRequest(promptID: "prompt-1", text: "hello", turnID: "turn-1"),
            emit: { _ in }
        )

        #expect(result.cancelled == false)
        #expect(result.output == "root final answer")

        let requests = fixture.responsesRequests()
        #expect(requests.count == 3)

        // The parent's first sample advertises the spawn surface.
        #expect(toolNames(in: requests[0]).contains("spawn_subagent"))

        // The child's sample: its own conversation (the task prompt, the
        // general-purpose prompt body) and — the strip rule — no spawn
        // surface of its own.
        let childRequest = requests[1]
        #expect(SubagentFixture.bodyText(childRequest).contains(taskPrompt))
        #expect(SubagentFixture.bodyText(childRequest).contains("Complete the assigned task directly"))
        let childTools = toolNames(in: childRequest)
        #expect(!childTools.isEmpty)
        #expect(!childTools.contains("spawn_subagent"))
        #expect(!childTools.contains("task"))
        #expect(!childTools.contains("agent_swarm"))
        #expect(!childTools.contains("workflow"))

        // The parent's second sample carries the tool result with the
        // child's completion block.
        let secondParentBody = SubagentFixture.bodyText(requests[2])
        #expect(secondParentBody.contains("the child answered from its own turn"))
        #expect(secondParentBody.contains("<subagent_meta>"))

        // The result round-trips through the background-task output tool.
        let host = foundation.subagentHost
        #expect(host != nil)
        let ids = await host?.knownSubagentIDs() ?? []
        #expect(ids.count == 1)
        let output = await foundation.toolExecutor.invoke(
            sessionID: foundation.sessionID,
            workingDirectory: foundation.cwd,
            call: ToolCall(
                id: "call-output-1",
                name: "get_command_or_subagent_output",
                arguments: #"{"task_ids":["\#(ids[0])"]}"#
            )
        )
        guard case .success(let outputResult) = output else {
            Issue.record("get_task_output failed: \(output)")
            return
        }
        #expect(outputResult.promptText.contains("the child answered from its own turn"))
        #expect(outputResult.promptText.contains("<subagent_meta>"))
        #expect(outputResult.value["status"]?.stringValue == "completed")

        // `wait_tasks` accepts the same subagent id (the unified family).
        let wait = await foundation.toolExecutor.invoke(
            sessionID: foundation.sessionID,
            workingDirectory: foundation.cwd,
            call: ToolCall(
                id: "call-wait-1",
                name: "wait_commands_or_subagents",
                arguments: #"{"task_ids":["\#(ids[0])"],"mode":"wait_all","timeout_ms":1000}"#
            )
        )
        guard case .success(let waitResult) = wait else {
            Issue.record("wait_tasks failed: \(wait)")
            return
        }
        #expect(waitResult.value["results"]?[0]?["status"]?.stringValue == "completed")
    }

    /// The canonical registry spelling dispatches to the same surface — a
    /// model primed on `task` (or a profile written against it) must not
    /// fall on the floor.
    @Test("the canonical 'task' spelling dispatches")
    func canonicalTaskSpellingDispatches() async throws {
        let fixture = try SubagentFixture()
        defer { fixture.dispose() }
        let foundation = try await fixture.makeFoundation()
        defer { Task { await foundation.toolExecutor.shutdown() } }

        let result = await foundation.toolExecutor.invoke(
            sessionID: foundation.sessionID,
            workingDirectory: foundation.cwd,
            call: ToolCall(
                id: "call-spawn-1",
                name: "task",
                arguments: #"{"prompt":"p","description":"d","subagent_type":"nosuchagent"}"#
            )
        )
        guard case .failure(let error) = result else {
            Issue.record("expected the unknown type to be rejected, got \(result)")
            return
        }
        // Reaching validation (rather than "unknown tool") proves dispatch.
        #expect(error.description.contains("Unknown subagent type: nosuchagent"))
    }

    /// `kill_task` on a subagent id: the child is parked inside a real
    /// `sleep` (its own tool call, through its own clamped surface) when the
    /// kill lands, so the coordinator cancels a genuinely running child.
    @Test("kill_task cancels a running child")
    func killTaskCancelsChild() async throws {
        let fixture = try SubagentFixture()
        defer { fixture.dispose() }

        let taskPrompt = "Park inside a sleep \(UUID().uuidString)"
        try fixture.server.enqueueResponse(
            path: "/v1/responses",
            response: .sse(SseEvents.responsesApiReasoningThenToolCallEvents(
                reasoning: "Working.",
                callId: "call-sleep-1",
                name: "run_terminal_cmd",
                arguments: #"{"command":"sleep 30","timeout_ms":30000}"#,
                model: "grok-4.5"
            ))
        )

        // `--yolo` so the child's own `run_terminal_cmd` and the test's
        // `kill_task` pass the permission pipeline without a prompter.
        let foundation = try await fixture.makeFoundation(["--model", "grok-4.5", "--yolo"])
        defer { Task { await foundation.toolExecutor.shutdown() } }

        let spawn = await foundation.toolExecutor.invoke(
            sessionID: foundation.sessionID,
            workingDirectory: foundation.cwd,
            call: ToolCall(
                id: "call-spawn-1",
                name: "spawn_subagent",
                arguments: #"{"prompt":"\#(taskPrompt)","description":"parking probe","subagent_type":"general-purpose","background":true}"#
            )
        )
        guard case .success(let spawnResult) = spawn else {
            Issue.record("spawn failed: \(spawn)")
            return
        }
        guard let childID = spawnResult.value["subagent_id"]?.stringValue else {
            Issue.record("spawn result carried no subagent_id: \(spawnResult.value)")
            return
        }

        // Wait until the child's first sample is actually on the wire, so the
        // kill lands on a running child rather than a not-yet-registered one.
        let childRequest = await fixture.waitForRequest(containing: taskPrompt)
        #expect(childRequest != nil, "the child never sampled against the mock server")

        let kill = await foundation.toolExecutor.invoke(
            sessionID: foundation.sessionID,
            workingDirectory: foundation.cwd,
            call: ToolCall(
                id: "call-kill-1",
                name: "kill_command_or_subagent",
                arguments: #"{"task_id":"\#(childID)"}"#
            )
        )
        guard case .success(let killResult) = kill else {
            Issue.record("kill_task failed: \(kill)")
            return
        }
        #expect(killResult.value["outcome"]?.stringValue == "killed")

        // The output tool waits for the cancelled terminal state.
        let output = await foundation.toolExecutor.invoke(
            sessionID: foundation.sessionID,
            workingDirectory: foundation.cwd,
            call: ToolCall(
                id: "call-output-1",
                name: "get_command_or_subagent_output",
                arguments: #"{"task_ids":["\#(childID)"],"timeout_ms":10000}"#
            )
        )
        guard case .success(let outputResult) = output else {
            Issue.record("get_task_output failed: \(output)")
            return
        }
        #expect(outputResult.value["status"]?.stringValue == "cancelled")
    }

    /// The advertised `resume_from` path: a completed child's persisted
    /// transcript seeds the resumed child's next turn, and a type mismatch is
    /// rejected with the resolution module's own error.
    @Test("resume_from continues a completed child's persisted transcript")
    func resumeFromContinuesTheChild() async throws {
        let fixture = try SubagentFixture()
        defer { fixture.dispose() }

        let firstPrompt = "first keystone task \(UUID().uuidString)"
        let secondPrompt = "follow-up keystone task \(UUID().uuidString)"
        try fixture.server.enqueueResponse(
            path: "/v1/responses",
            response: .sse(SseEvents.responsesApiEventsExact(text: "first child answer", model: "grok-4.5"))
        )
        try fixture.server.enqueueResponse(
            path: "/v1/responses",
            response: .sse(SseEvents.responsesApiEventsExact(text: "resumed child answer", model: "grok-4.5"))
        )

        let foundation = try await fixture.makeFoundation()
        defer { Task { await foundation.toolExecutor.shutdown() } }

        let first = await foundation.toolExecutor.invoke(
            sessionID: foundation.sessionID,
            workingDirectory: foundation.cwd,
            call: ToolCall(
                id: "call-spawn-1",
                name: "spawn_subagent",
                arguments: #"{"prompt":"\#(firstPrompt)","description":"first probe","subagent_type":"general-purpose","background":false}"#
            )
        )
        guard case .success(let firstResult) = first else {
            Issue.record("first spawn failed: \(first)")
            return
        }
        #expect(firstResult.promptText.contains("first child answer"))
        guard let firstID = firstResult.value["subagent_id"]?.stringValue else {
            Issue.record("first spawn carried no subagent_id: \(firstResult.value)")
            return
        }

        // A mismatched type is rejected before anything spawns.
        let mismatch = await foundation.toolExecutor.invoke(
            sessionID: foundation.sessionID,
            workingDirectory: foundation.cwd,
            call: ToolCall(
                id: "call-spawn-2",
                name: "spawn_subagent",
                arguments: #"{"prompt":"\#(secondPrompt)","description":"mismatch probe","subagent_type":"explore","background":false,"resume_from":"\#(firstID)"}"#
            )
        )
        guard case .failure(let mismatchError) = mismatch else {
            Issue.record("a type-mismatched resume unexpectedly spawned")
            return
        }
        #expect(mismatchError.description.contains("Resumed sessions must use the same subagent type as the source"))

        let resumed = await foundation.toolExecutor.invoke(
            sessionID: foundation.sessionID,
            workingDirectory: foundation.cwd,
            call: ToolCall(
                id: "call-spawn-3",
                name: "spawn_subagent",
                arguments: #"{"prompt":"\#(secondPrompt)","description":"resume probe","subagent_type":"general-purpose","background":false,"resume_from":"\#(firstID)"}"#
            )
        )
        guard case .success(let resumedResult) = resumed else {
            Issue.record("resume spawn failed: \(resumed)")
            return
        }
        #expect(resumedResult.promptText.contains("resumed child answer"))

        // The resumed child's sample carries the source transcript (the first
        // task prompt) plus the new one — the continuation upstream promises.
        let requests = fixture.responsesRequests()
        #expect(requests.count == 2)
        let resumedBody = SubagentFixture.bodyText(requests[1])
        #expect(resumedBody.contains(firstPrompt))
        #expect(resumedBody.contains("first child answer"))
        #expect(resumedBody.contains(secondPrompt))
    }

    // MARK: Validation copy

    @Test("an unknown subagent type fails with the available roster")
    func unknownTypeIsRejected() async throws {
        let fixture = try SubagentFixture()
        defer { fixture.dispose() }
        let foundation = try await fixture.makeFoundation()
        defer { Task { await foundation.toolExecutor.shutdown() } }

        let result = await foundation.toolExecutor.invoke(
            sessionID: foundation.sessionID,
            workingDirectory: foundation.cwd,
            call: ToolCall(
                id: "call-spawn-1",
                name: "spawn_subagent",
                arguments: #"{"prompt":"p","description":"d","subagent_type":"nosuchagent"}"#
            )
        )
        guard case .failure(let error) = result else {
            Issue.record("an unknown type unexpectedly spawned")
            return
        }
        #expect(error.description.contains("Unknown subagent type: nosuchagent"))
        #expect(error.description.contains("general-purpose"))
    }

    @Test("a toggled-off subagent type fails with the config message")
    func disabledTypeIsRejected() async throws {
        let fixture = try SubagentFixture(userConfig: """
            [subagents.toggle]
            explore = false
            """)
        defer { fixture.dispose() }
        let foundation = try await fixture.makeFoundation()
        defer { Task { await foundation.toolExecutor.shutdown() } }

        // The roster still has the other built-ins, so the surface stays up…
        #expect(foundation.toolExecutor.tools.map(\.name).contains("spawn_subagent"))

        let result = await foundation.toolExecutor.invoke(
            sessionID: foundation.sessionID,
            workingDirectory: foundation.cwd,
            call: ToolCall(
                id: "call-spawn-1",
                name: "spawn_subagent",
                arguments: #"{"prompt":"p","description":"d","subagent_type":"explore"}"#
            )
        )
        guard case .failure(let error) = result else {
            Issue.record("a disabled type unexpectedly spawned")
            return
        }
        #expect(error.description.contains(
            "Subagent 'explore' is disabled via [subagents.toggle] in config.toml"
        ))
    }
}
