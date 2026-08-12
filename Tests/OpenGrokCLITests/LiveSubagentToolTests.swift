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
//   * resume cwd: source inheritance, ignored caller cwd, missing-dir
//     parent fallback, and recorded-but-missing worktree → Shared/parent
//     over a still-existing childCWD (same-process bookkeeping only);
//   * spawn-time validation copy (unknown / disabled types).

import Foundation
import Testing
import OpenGrokFileUtils
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

/// `pwd`-equivalent absolute path. Foundation's `resolvingSymlinksInPath` leaves
/// the macOS firmlink `/var` → `/private/var` alone; shell `pwd` and
/// `PathSecurity.canonicalize` (`realpath`) physicalize it.
private func physicalPath(_ url: URL) throws -> String {
    try PathSecurity.canonicalize(url).path
}

/// Await `toolExecutor.shutdown` after `operation` succeeds or throws.
/// Scoped to the resumed-CWD tests — historical suites keep their fire-and-forget
/// `defer { Task { … } }` so this change stays local.
private func withAwaitedToolExecutorShutdown(
    _ foundation: OpenGrokLiveApplicationLauncher.LiveSessionFoundation,
    operation: () async throws -> Void
) async rethrows {
    do {
        try await operation()
    } catch {
        await foundation.toolExecutor.shutdown()
        throw error
    }
    await foundation.toolExecutor.shutdown()
}

/// Decoded string leaves from a logged Responses body.
///
/// `SubagentFixture.bodyText` re-encodes via `JSONSerialization`, which escapes
/// `/` as `\/`. Searching that raw text for absolute paths therefore fails even
/// when production emitted the correct physical path; path-identity checks must
/// run against these decoded values instead.
private func decodedBodyStrings(_ entry: LogEntry) -> [String] {
    // Encode through Data + JSONSerialization rather than naming the
    // OpenGrokTestSupport JSONValue type: that qualifier is ambiguous
    // (module enum `OpenGrokTestSupport` vs module-qualified type) once
    // OpenGrokShared's JSONValue is also in scope.
    guard let body = entry.body,
          let data = try? body.encode(),
          let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    else { return [] }
    var out: [String] = []
    appendDecodedStrings(from: root, into: &out)
    return out
}

private func appendDecodedStrings(from value: Any, into out: inout [String]) {
    if let string = value as? String {
        out.append(string)
        return
    }
    if let items = value as? [Any] {
        for item in items {
            appendDecodedStrings(from: item, into: &out)
        }
        return
    }
    if let object = value as? [String: Any] {
        for child in object.values {
            appendDecodedStrings(from: child, into: &out)
        }
    }
}

/// `Workspace Path:` value from a decoded system-prompt / message string leaf.
private func workspacePath(listedIn entry: LogEntry) -> String? {
    prefixedPath(listedIn: entry, prefix: "Workspace Path: ")
}

/// `RESUME_CWD=` value from a decoded `function_call_output` / content string.
/// Only absolute shell output lines (`RESUME_CWD=/…`) count — the tool-call
/// arguments leaf also contains `RESUME_CWD=$(pwd)` and must be ignored.
private func resumeCWD(listedIn entry: LogEntry) -> String? {
    let prefix = "RESUME_CWD="
    for text in decodedBodyStrings(entry) {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("RESUME_CWD=/") else { continue }
            return String(trimmed.dropFirst(prefix.count))
        }
    }
    return nil
}

private func prefixedPath(listedIn entry: LogEntry, prefix: String) -> String? {
    for text in decodedBodyStrings(entry) {
        guard let range = text.range(of: prefix) else { continue }
        let rest = text[range.upperBound...]
        let end = rest.firstIndex(where: \.isNewline) ?? rest.endIndex
        let value = String(rest[..<end])
        if !value.isEmpty { return value }
    }
    return nil
}

private func decodedBodyContains(_ entry: LogEntry, _ needle: String) -> Bool {
    decodedBodyStrings(entry).contains { $0.contains(needle) }
}

/// Test-only bookkeeping mutators/readers. Subscript assignment on
/// `host.bookkeeping[…]` is illegal from a nonisolated test context under
/// Swift 6 actor checking; these run on the host actor itself.
extension LiveSubagentHost {
    /// Stamp a recorded worktree path onto an existing entry without creating
    /// a worktree — the edge under test is resume selection, not isolation.
    /// Returns `false` when `id` is unknown.
    @discardableResult
    func stampBookkeepingWorktreePath(id: String, _ path: URL) -> Bool {
        guard var entry = bookkeeping[id] else { return false }
        entry.worktreePath = path
        bookkeeping[id] = entry
        return true
    }

    func bookkeepingChildCWD(id: String) -> URL? {
        bookkeeping[id]?.childCWD
    }

    func bookkeepingWorktreePath(id: String) -> URL? {
        bookkeeping[id]?.worktreePath
    }
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

    /// Resume inherits the source child's effective cwd (same-process
    /// bookkeeping), and a caller-supplied `cwd` on the resume call is
    /// ignored — matching the schema text and `select_override_cwd`
    /// (subagent/mod.rs:1623-1632). Proves execution cwd via a real
    /// `run_terminal_cmd`/`pwd` on the resumed child, not the inherited
    /// system-prompt string (which would still mention the source path
    /// even if tools ran under the parent).
    @Test("resume_from inherits the source child's cwd and ignores caller cwd")
    func resumeFromInheritsSourceCWDAndIgnoresCallerCWD() async throws {
        let fixture = try SubagentFixture()
        defer { fixture.dispose() }

        let sourceDir = fixture.home.deletingLastPathComponent()
            .appendingPathComponent("source-cwd-\(UUID().uuidString)", isDirectory: true)
        let decoyDir = fixture.home.deletingLastPathComponent()
            .appendingPathComponent("decoy-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: decoyDir, withIntermediateDirectories: true)

        let firstPrompt = "first cwd probe \(UUID().uuidString)"
        let resumePrompt = "resume cwd probe \(UUID().uuidString)"
        try fixture.server.enqueueResponse(
            path: "/v1/responses",
            response: .sse(SseEvents.responsesApiEventsExact(text: "first child answer", model: "grok-4.5"))
        )
        // Marker prefix keeps the execution cwd distinct from the inherited
        // `Workspace Path:` system-prompt line (which also names the source).
        try fixture.server.enqueueResponse(
            path: "/v1/responses",
            response: .sse(SseEvents.responsesApiReasoningThenToolCallEvents(
                reasoning: "Checking cwd.",
                callId: "call-pwd-1",
                name: "run_terminal_cmd",
                arguments: #"{"command":"echo RESUME_CWD=$(pwd)","timeout_ms":5000}"#,
                model: "grok-4.5"
            ))
        )
        try fixture.server.enqueueResponse(
            path: "/v1/responses",
            response: .sse(SseEvents.responsesApiEventsExact(text: "resumed child answer", model: "grok-4.5"))
        )

        // `--yolo` so the resumed child's shell tool clears the permission gate.
        let foundation = try await fixture.makeFoundation(["--model", "grok-4.5", "--yolo"])
        try await withAwaitedToolExecutorShutdown(foundation) {
            let first = await foundation.toolExecutor.invoke(
                sessionID: foundation.sessionID,
                workingDirectory: foundation.cwd,
                call: ToolCall(
                    id: "call-spawn-1",
                    name: "spawn_subagent",
                    arguments: #"{"prompt":"\#(firstPrompt)","description":"cwd source","subagent_type":"general-purpose","background":false,"cwd":"\#(sourceDir.path)"}"#
                )
            )
            guard case .success(let firstResult) = first else {
                Issue.record("first spawn failed: \(first)")
                return
            }
            guard let firstID = firstResult.value["subagent_id"]?.stringValue else {
                Issue.record("first spawn carried no subagent_id: \(firstResult.value)")
                return
            }
            // Fresh spawn with an explicit cwd: the child's system prompt names it.
            // Decode string leaves first — raw `bodyText` escapes `/` as `\/`.
            // Compare physical paths — prompt spelling may be `/var/...` while
            // `realpath`/`pwd` use `/private/var/...`.
            let listedWorkspace = try #require(workspacePath(listedIn: fixture.responsesRequests()[0]))
            #expect(try physicalPath(URL(fileURLWithPath: listedWorkspace)) == physicalPath(sourceDir))

            let resumed = await foundation.toolExecutor.invoke(
                sessionID: foundation.sessionID,
                workingDirectory: foundation.cwd,
                call: ToolCall(
                    id: "call-spawn-2",
                    name: "spawn_subagent",
                    arguments: #"{"prompt":"\#(resumePrompt)","description":"cwd resume","subagent_type":"general-purpose","background":false,"resume_from":"\#(firstID)","cwd":"\#(decoyDir.path)"}"#
                )
            )
            guard case .success(let resumedResult) = resumed else {
                Issue.record("resume spawn failed: \(resumed)")
                return
            }
            #expect(resumedResult.promptText.contains("resumed child answer"))

            // The resumed child's follow-up sample carries the marker from the
            // shell tool — source directory, never the decoy caller cwd.
            // Physicalize: macOS `pwd` prints `/private/var/...` while
            // `FileManager` temp URLs often stay at `/var/...`.
            let requests = fixture.responsesRequests()
            #expect(requests.count == 3)
            let resumePath = try #require(resumeCWD(listedIn: requests[2]))
            let sourcePath = try physicalPath(sourceDir)
            let decoyPath = try physicalPath(decoyDir)
            let parentPath = try physicalPath(foundation.cwd)
            #expect(resumePath == sourcePath)
            #expect(resumePath != decoyPath)
            #expect(resumePath != parentPath)
            #expect(!decodedBodyContains(requests[2], "RESUME_CWD=\(decoyPath)"))
            #expect(!decodedBodyContains(requests[2], "RESUME_CWD=\(parentPath)"))
            #expect(decodedBodyContains(requests[2], resumePrompt))
        }
    }

    /// When the source child's recorded cwd no longer exists, resume falls
    /// back to the parent workspace — the existence check in
    /// `resume_inherited_cwd` (subagent/mod.rs:1612-1619). Same-process only;
    /// durable meta.json reconstruction is not claimed here.
    @Test("resume_from falls back to parent cwd when the source directory is gone")
    func resumeFromFallsBackWhenSourceCWDMissing() async throws {
        let fixture = try SubagentFixture()
        defer { fixture.dispose() }

        let sourceDir = fixture.home.deletingLastPathComponent()
            .appendingPathComponent("ephemeral-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        let firstPrompt = "ephemeral cwd probe \(UUID().uuidString)"
        let resumePrompt = "fallback cwd probe \(UUID().uuidString)"
        try fixture.server.enqueueResponse(
            path: "/v1/responses",
            response: .sse(SseEvents.responsesApiEventsExact(text: "first child answer", model: "grok-4.5"))
        )
        try fixture.server.enqueueResponse(
            path: "/v1/responses",
            response: .sse(SseEvents.responsesApiReasoningThenToolCallEvents(
                reasoning: "Checking cwd.",
                callId: "call-pwd-2",
                name: "run_terminal_cmd",
                arguments: #"{"command":"echo RESUME_CWD=$(pwd)","timeout_ms":5000}"#,
                model: "grok-4.5"
            ))
        )
        try fixture.server.enqueueResponse(
            path: "/v1/responses",
            response: .sse(SseEvents.responsesApiEventsExact(text: "fallback child answer", model: "grok-4.5"))
        )

        let foundation = try await fixture.makeFoundation(["--model", "grok-4.5", "--yolo"])
        try await withAwaitedToolExecutorShutdown(foundation) {
            let first = await foundation.toolExecutor.invoke(
                sessionID: foundation.sessionID,
                workingDirectory: foundation.cwd,
                call: ToolCall(
                    id: "call-spawn-1",
                    name: "spawn_subagent",
                    arguments: #"{"prompt":"\#(firstPrompt)","description":"ephemeral source","subagent_type":"general-purpose","background":false,"cwd":"\#(sourceDir.path)"}"#
                )
            )
            guard case .success(let firstResult) = first else {
                Issue.record("first spawn failed: \(first)")
                return
            }
            guard let firstID = firstResult.value["subagent_id"]?.stringValue else {
                Issue.record("first spawn carried no subagent_id: \(firstResult.value)")
                return
            }

            // Capture the physical spelling before unlink — `realpath` needs the
            // leaf to exist, and `resolvingSymlinksInPath` will not rewrite `/var`.
            let sourcePath = try physicalPath(sourceDir)
            let parentPath = try physicalPath(foundation.cwd)
            try FileManager.default.removeItem(at: sourceDir)
            #expect(!FileManager.default.fileExists(atPath: sourceDir.path))

            let resumed = await foundation.toolExecutor.invoke(
                sessionID: foundation.sessionID,
                workingDirectory: foundation.cwd,
                call: ToolCall(
                    id: "call-spawn-2",
                    name: "spawn_subagent",
                    arguments: #"{"prompt":"\#(resumePrompt)","description":"cwd fallback","subagent_type":"general-purpose","background":false,"resume_from":"\#(firstID)"}"#
                )
            )
            guard case .success(let resumedResult) = resumed else {
                Issue.record("resume spawn failed: \(resumed)")
                return
            }
            #expect(resumedResult.promptText.contains("fallback child answer"))

            let requests = fixture.responsesRequests()
            #expect(requests.count == 3)
            // Marker pins execution cwd to the parent; the inherited system prompt
            // may still mention the deleted source path, so absence of that path
            // is not a valid claim. Decode leaves first — raw `bodyText` escapes `/`.
            let resumePath = try #require(resumeCWD(listedIn: requests[2]))
            #expect(resumePath == parentPath)
            #expect(resumePath != sourcePath)
            #expect(!decodedBodyContains(requests[2], "RESUME_CWD=\(sourcePath)"))
        }
    }

    /// A source marked worktree-backed whose worktree dir is gone must resume
    /// under the parent workspace — not the still-existing `childCWD`.
    /// Upstream checks `worktree_path.is_some()` before inheriting cwd
    /// (`resume_inherited_cwd`, subagent/mod.rs:1621) and maps a missing
    /// worktree to `ResumeWorktreeAction::Shared` (handle_request.rs:462-468).
    /// Worktree *creation* is absent; this only stamps bookkeeping the way a
    /// prior worktree-backed child would have.
    @Test("resume_from selects parent when recorded worktree is missing but childCWD remains")
    func resumeFromMissingRecordedWorktreeSelectsParentOverChildCWD() async throws {
        let fixture = try SubagentFixture()
        defer { fixture.dispose() }

        let sourceDir = fixture.home.deletingLastPathComponent()
            .appendingPathComponent("wt-child-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let missingWorktree = fixture.home.deletingLastPathComponent()
            .appendingPathComponent("missing-worktree-\(UUID().uuidString)", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: missingWorktree.path))

        let firstPrompt = "worktree-backed source \(UUID().uuidString)"
        let resumePrompt = "missing worktree resume \(UUID().uuidString)"
        try fixture.server.enqueueResponse(
            path: "/v1/responses",
            response: .sse(SseEvents.responsesApiEventsExact(text: "first child answer", model: "grok-4.5"))
        )
        try fixture.server.enqueueResponse(
            path: "/v1/responses",
            response: .sse(SseEvents.responsesApiReasoningThenToolCallEvents(
                reasoning: "Checking cwd.",
                callId: "call-pwd-wt",
                name: "run_terminal_cmd",
                arguments: #"{"command":"echo RESUME_CWD=$(pwd)","timeout_ms":5000}"#,
                model: "grok-4.5"
            ))
        )
        try fixture.server.enqueueResponse(
            path: "/v1/responses",
            response: .sse(SseEvents.responsesApiEventsExact(text: "shared workspace answer", model: "grok-4.5"))
        )

        let foundation = try await fixture.makeFoundation(["--model", "grok-4.5", "--yolo"])
        try await withAwaitedToolExecutorShutdown(foundation) {
            let first = await foundation.toolExecutor.invoke(
                sessionID: foundation.sessionID,
                workingDirectory: foundation.cwd,
                call: ToolCall(
                    id: "call-spawn-1",
                    name: "spawn_subagent",
                    arguments: #"{"prompt":"\#(firstPrompt)","description":"wt source","subagent_type":"general-purpose","background":false,"cwd":"\#(sourceDir.path)"}"#
                )
            )
            guard case .success(let firstResult) = first else {
                Issue.record("first spawn failed: \(first)")
                return
            }
            guard let firstID = firstResult.value["subagent_id"]?.stringValue else {
                Issue.record("first spawn carried no subagent_id: \(firstResult.value)")
                return
            }

            let host = try #require(foundation.subagentHost)
            // Stamp recorded worktree presence without creating a worktree —
            // the edge under test is resume selection, not isolation setup.
            // Mutation must run on the host actor (see test-only extension).
            #expect(await host.bookkeepingChildCWD(id: firstID) != nil)
            guard await host.stampBookkeepingWorktreePath(id: firstID, missingWorktree) else {
                Issue.record("source bookkeeping missing after spawn")
                return
            }
            #expect(await host.bookkeepingWorktreePath(id: firstID) != nil)
            #expect(FileManager.default.fileExists(atPath: sourceDir.path))
            #expect(!FileManager.default.fileExists(atPath: missingWorktree.path))

            // Pure pin of the same selection the spawn path must apply
            // (reusable URL vs recorded presence — subagent/mod.rs:1619-1632).
            let reusable = LiveSubagentHost.resumeWorktreePath(missingWorktree)
            #expect(reusable == nil)
            let override = LiveSubagentHost.resumeInheritedCWD(
                sourceCWD: sourceDir,
                recordedWorktreePath: missingWorktree
            )
            #expect(override == nil)
            let selected = LiveSubagentHost.resolveChildCWD(
                worktreePath: reusable,
                overrideCWD: override,
                parentCWD: foundation.cwd
            )
            #expect(selected.standardizedFileURL == foundation.cwd.standardizedFileURL)

            let sourcePath = try physicalPath(sourceDir)
            let parentPath = try physicalPath(foundation.cwd)

            let resumed = await foundation.toolExecutor.invoke(
                sessionID: foundation.sessionID,
                workingDirectory: foundation.cwd,
                call: ToolCall(
                    id: "call-spawn-2",
                    name: "spawn_subagent",
                    arguments: #"{"prompt":"\#(resumePrompt)","description":"wt missing","subagent_type":"general-purpose","background":false,"resume_from":"\#(firstID)"}"#
                )
            )
            guard case .success(let resumedResult) = resumed else {
                Issue.record("resume spawn failed: \(resumed)")
                return
            }
            #expect(resumedResult.promptText.contains("shared workspace answer"))

            let requests = fixture.responsesRequests()
            #expect(requests.count == 3)
            let resumePath = try #require(resumeCWD(listedIn: requests[2]))
            #expect(resumePath == parentPath)
            #expect(resumePath != sourcePath)
            #expect(!decodedBodyContains(requests[2], "RESUME_CWD=\(sourcePath)"))
        }
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
