// LiveWorkflowAgentTests.swift
//
// The live half of the workflow seam: what a workflow's `agent()` actually
// runs. A scripted sampler stands in for the provider and a scripted invoker
// for the tool surface, so these tests exercise the real turn loop, the real
// capability clamp, and the real budget arithmetic without a network or a
// process.

import Foundation
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokTerminalCore
import OpenGrokSessionPersistence
import OpenGrokSessionRuntime
import OpenGrokShared
import OpenGrokShell
import OpenGrokToolRegistry
import OpenGrokWorkflow
import Testing

@testable import OpenGrokCLI

// MARK: - Fakes

/// A sampler driven by a queue of canned responses, keyed by a substring of the
/// prompt so a fan-out can give each label a different answer.
private actor ScriptedSampler {
    struct Reply: Sendable {
        let match: String
        let responses: [OpenGrokLiveSamplingResponse]
    }

    private let replies: [Reply]
    private var cursors: [String: Int] = [:]
    private var requests: [OpenGrokLiveSamplingRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    private func answer(
        _ request: OpenGrokLiveSamplingRequest
    ) throws -> OpenGrokLiveSamplingResponse {
        requests.append(request)
        // Longest match wins, so a matcher of "a" cannot shadow "fail-b".
        let reply = replies
            .filter { request.prompt.contains($0.match) }
            .max { $0.match.count < $1.match.count }
        guard let reply else {
            throw CLIApplicationError.failed("no scripted reply for prompt: \(request.prompt)")
        }
        let index = cursors[reply.match] ?? 0
        cursors[reply.match] = index + 1
        return reply.responses[min(index, reply.responses.count - 1)]
    }

    nonisolated var sampler: OpenGrokLiveSampler {
        OpenGrokLiveSampler { request, _ in
            try await self.answer(request)
        }
    }

    func recordedRequests() -> [OpenGrokLiveSamplingRequest] { requests }
}

/// A tool surface that answers every call with a fixed string and records what
/// it was asked for.
private final class ScriptedInvoker: LiveWorkflowToolInvoker, @unchecked Sendable {
    let tools: [ToolSpec]
    let workingDirectory: URL
    private let recorder = CallRecorder()

    init(tools: [ToolSpec], workingDirectory: URL = URL(fileURLWithPath: "/tmp")) {
        self.tools = tools
        self.workingDirectory = workingDirectory
    }

    func invoke(
        sessionID: String,
        workingDirectory: URL,
        call: ToolCall
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        await recorder.record(call.name)
        return .success(OpenGrokShellToolCallResult(
            value: .string("ok"),
            promptText: "result of \(call.name)"
        ))
    }

    func recordedCalls() async -> [String] { await recorder.calls }
}

private actor CallRecorder {
    private(set) var calls: [String] = []
    func record(_ name: String) { calls.append(name) }
}

private func spec(_ name: String) -> ToolSpec {
    ToolSpec(name: name, description: name, parameters: .object(["type": .string("object")]))
}

private func textResponse(_ text: String) -> OpenGrokLiveSamplingResponse {
    OpenGrokLiveSamplingResponse(output: text, stopReason: "stop")
}

private func toolResponse(_ name: String, callID: String = "c1") -> OpenGrokLiveSamplingResponse {
    OpenGrokLiveSamplingResponse(
        output: "",
        stopReason: "tool_calls",
        toolCalls: [ToolCall(id: callID, name: name, arguments: "{}")]
    )
}

private func environment(
    sampler: OpenGrokLiveSampler,
    invoker: any LiveWorkflowToolInvoker,
    parent: ToolCapabilityMode = .readWrite,
    observe: (@Sendable (ToolCapabilityMode) -> Void)? = nil
) -> LiveWorkflowAgentEnvironment {
    LiveWorkflowAgentEnvironment(
        sampler: sampler,
        model: "test-model",
        workspaceRoot: URL(fileURLWithPath: "/tmp"),
        parentCapabilityMode: parent,
        makeInvoker: { mode in
            observe?(mode)
            return invoker
        }
    )
}

// MARK: - Child agent

@Suite("Workflow child agent")
struct LiveWorkflowChildAgentTests {

    @Test("a child agent runs a real turn loop, executing tools until the model stops")
    func turnLoopExecutesTools() async throws {
        let sampler = ScriptedSampler([
            .init(match: "investigate", responses: [
                toolResponse("read_file"),
                textResponse("found it"),
            ])
        ])
        let invoker = ScriptedInvoker(tools: [spec("read_file")])
        let child = LiveWorkflowChildAgent(
            runID: "run",
            environment: environment(sampler: sampler.sampler, invoker: invoker),
            cancellation: RhaiCancellationToken()
        )

        let result = try await child.run(
            agentID: "a1",
            options: RhaiAgentOptions(prompt: "investigate the bug", label: "scout")
        ) { _ in }

        #expect(result.success)
        #expect(result.output == .string("found it"))
        #expect((await invoker.recordedCalls()) == ["read_file"])
        // Two provider round trips: the tool round and the answer.
        #expect((await sampler.recordedRequests()).count == 2)
        // The tool result was fed back rather than dropped.
        let second = (await sampler.recordedRequests())[1]
        #expect(second.items.contains { item in
            if case .toolResult(let result) = item { return result.content.contains("read_file") }
            return false
        })
    }

    @Test("an output_schema is forced on the request and decoded into a real object")
    func schemaForcedOutput() async throws {
        let schema = JSONValue.object([
            "type": .string("object"),
            "properties": .object(["gaps": .object(["type": .string("string")])]),
        ])
        let sampler = ScriptedSampler([
            .init(match: "survey", responses: [textResponse("```json\n{\"gaps\":\"none\"}\n```")])
        ])
        let child = LiveWorkflowChildAgent(
            runID: "run",
            environment: environment(sampler: sampler.sampler, invoker: ScriptedInvoker(tools: [])),
            cancellation: RhaiCancellationToken()
        )

        let result = try await child.run(
            agentID: "a1",
            options: RhaiAgentOptions(prompt: "survey the code", outputSchema: schema)
        ) { _ in }

        // The schema reached the provider request…
        #expect((await sampler.recordedRequests()).first?.jsonSchema == schema)
        // …and the script gets an object it can index into, not a string.
        #expect(result.output["gaps"]?.stringValue == "none")
    }

    @Test("without a schema the output stays the model's prose")
    func proseOutputStaysAString() async throws {
        let sampler = ScriptedSampler([.init(match: "summarize", responses: [textResponse("{\"a\":1}")])])
        let child = LiveWorkflowChildAgent(
            runID: "run",
            environment: environment(sampler: sampler.sampler, invoker: ScriptedInvoker(tools: [])),
            cancellation: RhaiCancellationToken()
        )
        let result = try await child.run(
            agentID: "a1",
            options: RhaiAgentOptions(prompt: "summarize it")
        ) { _ in }
        #expect((await sampler.recordedRequests()).first?.jsonSchema == nil)
        #expect(result.output == .string("{\"a\":1}"))
    }

    @Test("a runaway tool loop becomes a soft, catchable failure")
    func toolLoopCeiling() async throws {
        let sampler = ScriptedSampler([
            .init(match: "loop", responses: [toolResponse("read_file")])
        ])
        var env = environment(
            sampler: sampler.sampler,
            invoker: ScriptedInvoker(tools: [spec("read_file")])
        )
        env = LiveWorkflowAgentEnvironment(
            sampler: env.sampler,
            model: env.model,
            workspaceRoot: env.workspaceRoot,
            parentCapabilityMode: env.parentCapabilityMode,
            maxToolRounds: 3,
            makeInvoker: env.makeInvoker
        )
        let child = LiveWorkflowChildAgent(
            runID: "run",
            environment: env,
            cancellation: RhaiCancellationToken()
        )

        await #expect(throws: RhaiHostError.self) {
            _ = try await child.run(
                agentID: "a1",
                options: RhaiAgentOptions(prompt: "loop forever", label: "spinner")
            ) { _ in }
        }
    }

    @Test("a cancelled run stops the child cooperatively")
    func cancellationStopsTheChild() async throws {
        let token = RhaiCancellationToken()
        token.cancel()
        let sampler = ScriptedSampler([.init(match: "work", responses: [textResponse("done")])])
        let child = LiveWorkflowChildAgent(
            runID: "run",
            environment: environment(sampler: sampler.sampler, invoker: ScriptedInvoker(tools: [])),
            cancellation: token
        )

        await #expect(throws: RhaiHostError.cancelled) {
            _ = try await child.run(agentID: "a1", options: RhaiAgentOptions(prompt: "work")) { _ in }
        }
        // It never reached the provider.
        #expect((await sampler.recordedRequests()).isEmpty)
    }
}

// MARK: - Capability clamp

@Suite("Workflow child capability clamp")
struct LiveWorkflowCapabilityTests {

    @Test("a child cannot escalate beyond the parent session's mode")
    func cannotEscalate() {
        #expect(LiveWorkflowCapability.clamp(requested: "all", parent: .readOnly) == .readOnly)
        #expect(LiveWorkflowCapability.clamp(requested: "execute", parent: .readOnly) == .readOnly)
        #expect(LiveWorkflowCapability.clamp(requested: "read_write", parent: .readOnly) == .readOnly)
    }

    @Test("a child may narrow, and an unknown request falls back to the parent")
    func mayNarrow() {
        #expect(LiveWorkflowCapability.clamp(requested: "read_only", parent: .all) == .readOnly)
        #expect(LiveWorkflowCapability.clamp(requested: nil, parent: .readWrite) == .readWrite)
        #expect(LiveWorkflowCapability.clamp(requested: "nonsense", parent: .readWrite) == .readWrite)
    }

    @Test("the clamped mode is what the tool surface is built for")
    func clampReachesTheToolSurface() async throws {
        let sampler = ScriptedSampler([.init(match: "peek", responses: [textResponse("ok")])])
        let observed = ModeBox()
        let child = LiveWorkflowChildAgent(
            runID: "run",
            environment: environment(
                sampler: sampler.sampler,
                invoker: ScriptedInvoker(tools: []),
                parent: .readWrite,
                observe: { observed.set($0) }
            ),
            cancellation: RhaiCancellationToken()
        )
        _ = try await child.run(
            agentID: "a1",
            options: RhaiAgentOptions(prompt: "peek", capabilityMode: "all")
        ) { _ in }
        // `all` was requested inside a `read_write` session and did not survive.
        #expect(observed.value == .readWrite)
    }

    @Test("a session with no agent profile still gets a narrowing policy")
    func unrestrictedPolicyNarrows() throws {
        // No profile plus the session default is expressed as "no policy".
        #expect(LiveWorkflowLaunch.clampedPolicy(nil, to: .readWrite) == nil)
        // A narrowed mode has to bite even without a profile.
        let narrowed = try? #require(LiveWorkflowLaunch.clampedPolicy(nil, to: .readOnly))
        #expect(narrowed?.capabilityMode == .readOnly)
        // The wildcard keeps every tool name a candidate; the capability mode
        // is the only thing filtering.
        #expect(narrowed?.allows(liveToolName: "read_file") == true)
        #expect(narrowed?.allows(liveToolName: "run_terminal_cmd") == false)
    }
}

private final class ModeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ToolCapabilityMode?
    func set(_ mode: ToolCapabilityMode) {
        lock.lock(); stored = mode; lock.unlock()
    }
    var value: ToolCapabilityMode? {
        lock.lock(); defer { lock.unlock() }; return stored
    }
}

// MARK: - Host

@Suite("Live workflow host")
struct LiveWorkflowHostTests {

    private func makeHost(
        sampler: OpenGrokLiveSampler,
        invoker: any LiveWorkflowToolInvoker,
        budget: UInt64 = 8,
        concurrency: Int = 2,
        cancellation: RhaiCancellationToken = RhaiCancellationToken(),
        scratch: URL
    ) -> LiveWorkflowHost {
        LiveWorkflowHost(
            context: RhaiWorkflowRunContext(
                runID: "run1",
                workflowName: "wf",
                arguments: .object([:]),
                agentBudget: budget,
                journalURL: nil,
                cancellation: cancellation
            ),
            environment: environment(sampler: sampler, invoker: invoker),
            scratchRoot: scratch,
            maxConcurrentAgents: concurrency,
            gitDiff: { _, _ in "" }
        )
    }

    private func scratchDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-scratch-\(UUID().uuidString)", isDirectory: true)
        return url
    }

    @Test("reservations are refused past the budget, before any agent runs")
    func reservationRefusal() async throws {
        let sampler = ScriptedSampler([.init(match: "x", responses: [textResponse("ok")])])
        let host = makeHost(
            sampler: sampler.sampler,
            invoker: ScriptedInvoker(tools: []),
            budget: 2,
            scratch: scratchDirectory()
        )
        try await host.reserveAgentCalls(2)
        await #expect(throws: RhaiHostError.self) {
            try await host.reserveAgentCalls(1)
        }
        let state = await host.budgetState()
        #expect(state.total == 2)
        #expect(state.reserved == 2)
        #expect(state.remaining == 0)
    }

    @Test("a released reservation is available again")
    func releaseReturnsSlots() async throws {
        let sampler = ScriptedSampler([.init(match: "x", responses: [textResponse("ok")])])
        let host = makeHost(
            sampler: sampler.sampler,
            invoker: ScriptedInvoker(tools: []),
            budget: 2,
            scratch: scratchDirectory()
        )
        try await host.reserveAgentCalls(2)
        await host.releaseAgentCalls(2)
        try await host.reserveAgentCalls(2)
        #expect(await host.budgetState().reserved == 2)
    }

    @Test("a batch comes back in input order and honours the concurrency cap")
    func batchOrderAndConcurrency() async throws {
        let sampler = ScriptedSampler([
            .init(match: "alpha", responses: [textResponse("A")]),
            .init(match: "bravo", responses: [textResponse("B")]),
            .init(match: "charlie", responses: [textResponse("C")]),
            .init(match: "delta", responses: [textResponse("D")]),
        ])
        let host = makeHost(
            sampler: sampler.sampler,
            invoker: ScriptedInvoker(tools: []),
            concurrency: 2,
            scratch: scratchDirectory()
        )
        try await host.reserveAgentCalls(4)

        let batch = ["alpha", "bravo", "charlie", "delta"].map {
            RhaiAgentOptions(prompt: $0, label: $0)
        }
        let results = await host.spawnAgents(batch)
        #expect(results.count == 4)
        let outputs = results.map { try? $0.get().output.stringValue }
        #expect(outputs == ["A", "B", "C", "D"])
        #expect(await host.budgetState().spent == 4)
    }

    @Test("a failed child is charged and reported as a soft failure")
    func failedChildIsCharged() async throws {
        // No scripted reply means the sampler throws, which is a soft `.failed`.
        let sampler = ScriptedSampler([])
        let host = makeHost(
            sampler: sampler.sampler,
            invoker: ScriptedInvoker(tools: []),
            scratch: scratchDirectory()
        )
        try await host.reserveAgentCalls(1)
        await #expect(throws: RhaiHostError.self) {
            _ = try await host.spawnAgent(RhaiAgentOptions(prompt: "nothing matches", label: "x"))
        }
        // The provider call happened, so the slot is spent rather than returned.
        let state = await host.budgetState()
        #expect(state.spent == 1)
        #expect(state.reserved == 0)
    }

    @Test("a cancelled run refuses the whole batch without spawning")
    func cancelledBatch() async throws {
        let token = RhaiCancellationToken()
        token.cancel()
        let sampler = ScriptedSampler([.init(match: "a", responses: [textResponse("A")])])
        let host = makeHost(
            sampler: sampler.sampler,
            invoker: ScriptedInvoker(tools: []),
            cancellation: token,
            scratch: scratchDirectory()
        )
        let results = await host.spawnAgents([RhaiAgentOptions(prompt: "a", label: "a")])
        #expect(results.count == 1)
        if case .failure(let error) = results[0] {
            #expect(error == .cancelled)
        } else {
            Issue.record("a cancelled run must not produce a result")
        }
        #expect((await sampler.recordedRequests()).isEmpty)
    }

    @Test("scratch files stay inside the run's own directory")
    func scratchFilesAreConfined() async throws {
        let scratch = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let sampler = ScriptedSampler([])
        let host = makeHost(
            sampler: sampler.sampler,
            invoker: ScriptedInvoker(tools: []),
            scratch: scratch
        )

        let written = try await host.writeScratchFile(name: "report.md", content: "hello")
        #expect(written.hasPrefix(scratch.path))
        #expect(try await host.readScratchFile(name: "report.md") == "hello")

        // A traversing name is reduced to its last component rather than
        // escaping into the workspace.
        let escaped = try await host.writeScratchFile(name: "../../evil.md", content: "no")
        #expect(escaped == scratch.appendingPathComponent("evil.md").path)
        #expect(!escaped.contains(".."))
    }

    @Test("render_template reports unsupported so a script can fall back")
    func renderTemplateIsCatchable() async throws {
        let host = makeHost(
            sampler: ScriptedSampler([]).sampler,
            invoker: ScriptedInvoker(tools: []),
            scratch: scratchDirectory()
        )
        await #expect(throws: RhaiHostError.self) {
            _ = try await host.renderTemplate(name: "x", variables: .object([:]))
        }
    }
}

// MARK: - Overlay

@Suite("Workflows overlay")
struct LiveWorkflowOverlayTests {

    private func view(status: PersistedWorkflowStatus = .active) -> RhaiWorkflowRunView {
        RhaiWorkflowRunView(
            record: WorkflowRunRecord(
                runID: "wf_1",
                workflowName: "deep-research",
                scriptHash: "h",
                argumentsHash: "h",
                status: status,
                agentBudget: 8
            ),
            entries: [
                RhaiJournalEntry(
                    seq: 0,
                    kind: "spawn_agent",
                    reqHash: "r",
                    result: .object([
                        "agent_id": .string("scout-1"),
                        "success": .bool(true),
                        "cancelled": .bool(false),
                        "tokens_used": .number(.uint64(42)),
                    ]),
                    atMS: 0
                )
            ],
            progress: RhaiWorkflowProgress(
                phases: ["survey", "synthesize"],
                agents: [RhaiWorkflowAgentProgress(
                    agentID: "scout-1",
                    label: "scout",
                    state: .succeeded,
                    tokensUsed: 42
                )],
                tokensUsed: 42
            )
        )
    }

    @Test("a run view becomes a dashboard row with phase, roster, and progress")
    func rowCarriesDashboardColumns() {
        let row = LiveWorkflowOverlayBuilder.row(from: view())
        #expect(row.runID == "wf_1")
        #expect(row.name == "deep-research")
        #expect(row.status == "active")
        #expect(row.phase == "synthesize")
        #expect(row.agentsFinished == 1)
        #expect(row.agentBudget == 8)
        #expect(row.tokensUsed == 42)
        #expect(row.agents == [PagerWorkflowAgent(name: "scout", state: "ok", tokensUsed: 42)])
    }

    @Test("the dashboard lists the newest run first")
    func newestFirst() {
        var older = view()
        older = RhaiWorkflowRunView(
            record: {
                var record = older.record
                record.runID = "wf_0"
                return record
            }(),
            entries: older.entries,
            progress: older.progress
        )
        let rows = LiveWorkflowOverlayBuilder.rows(from: [older, view()])
        #expect(rows.map(\.runID) == ["wf_1", "wf_0"])
    }

    @Test("enter opens a run's detail and escape unwinds it before the overlay")
    func detailViewUnwindsFirst() {
        var stack = PagerOverlayStack()
        stack.push(.workflows(rows: [LiveWorkflowOverlayBuilder.row(from: view())]))

        #expect(stack.handle(KeyEvent(key: .enter)) == .redraw)
        guard case .workflows(let opened) = stack.topmost?.content else {
            Issue.record("expected a workflows overlay")
            return
        }
        #expect(opened.isDetailOpen)
        #expect(opened.detailLines.contains { $0.contains("deep-research") })
        #expect(opened.detailLines.contains { $0.contains("scout") })

        // First escape closes the detail, second dismisses the overlay.
        #expect(stack.handle(KeyEvent(key: .escape)) == .redraw)
        #expect(stack.isEmpty == false)
        #expect(stack.handle(KeyEvent(key: .escape)) == .dismissed(id: "workflows"))
        #expect(stack.isEmpty)
    }

    @Test("p/r/x report a control intent rather than acting in the render layer")
    func controlKeysReportIntent() {
        var stack = PagerOverlayStack()
        stack.push(.workflows(rows: [LiveWorkflowOverlayBuilder.row(from: view())]))

        #expect(stack.handle(KeyEvent(key: .char("x"))) == .selected(id: "workflows", rowID: "x:wf_1"))
        #expect(LiveWorkflowOverlayBuilder.command(forRowID: "x:wf_1") == .stop(runID: "wf_1"))
        #expect(LiveWorkflowOverlayBuilder.command(forRowID: "p:wf_1") == .pause(runID: "wf_1"))
        #expect(LiveWorkflowOverlayBuilder.command(forRowID: "r:wf_1") == .resume(runID: "wf_1"))
        // A plain row id is a selection, not a command.
        #expect(LiveWorkflowOverlayBuilder.command(forRowID: "wf_1") == nil)
    }

    @Test("stopping a run through the dashboard reaches the registry")
    func stopReachesTheRegistry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-overlay-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkflowSessionStore(directory: directory)
        try await store.insert(WorkflowRunRecord(
            runID: "wf_stop",
            workflowName: "wf",
            scriptHash: "h",
            argumentsHash: "h",
            status: .paused,
            agentBudget: 4
        ))
        let registry = RhaiWorkflowRunRegistry(store: store)

        let stopped = await LiveWorkflowOverlayBuilder.apply(.stop(runID: "wf_stop"), registry: registry)
        #expect(stopped.contains("stopped"))
        // A bare resume cannot raise a budget cap, so it says what to do
        // instead of silently doing half of it.
        let resumed = await LiveWorkflowOverlayBuilder.apply(.resume(runID: "wf_stop"), registry: registry)
        #expect(resumed.contains("agent_budget"))
    }
}

// MARK: - CLI route

@Suite("workflow CLI route")
struct LiveWorkflowRouteTests {

    @Test("`workflow list` reads the manifest under OPENGROK_HOME")
    func listReadsTheManifest() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = WorkflowSessionStore(directory: home)
        try await store.insert(WorkflowRunRecord(
            runID: "wf_listed",
            workflowName: "triage",
            scriptHash: "h",
            argumentsHash: "h",
            status: .completed,
            agentBudget: 4
        ))

        let buffer = BufferedStream()
        try await LiveWorkflowComposition.run(
            options: CLIResourceOptions(action: "list"),
            environment: ["OPENGROK_HOME": home.path],
            streams: CLIStreams(out: { buffer.write($0) }, err: { _ in })
        )
        let output = buffer.contents
        #expect(output.contains("wf_listed"))
        #expect(output.contains("triage"))
        #expect(output.contains("completed"))
    }

    @Test("`workflow show` reports the roster and result")
    func showReportsDetail() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = WorkflowSessionStore(directory: home)
        try await store.insert(WorkflowRunRecord(
            runID: "wf_shown",
            workflowName: "triage",
            scriptHash: "h",
            argumentsHash: "h",
            status: .completed,
            result: .object(["ok": .bool(true)]),
            agentBudget: 4,
            agentsUsed: 2
        ))

        let buffer = BufferedStream()
        try await LiveWorkflowComposition.run(
            options: CLIResourceOptions(action: "show", target: "wf_shown"),
            environment: ["OPENGROK_HOME": home.path],
            streams: CLIStreams(out: { buffer.write($0) }, err: { _ in })
        )
        let output = buffer.contents
        #expect(output.contains("wf_shown"))
        #expect(output.contains("2 used of 4"))
        #expect(output.contains("{\"ok\":true}"))
    }

    @Test("the route claims the workflow command and rejects an unknown action")
    func routing() async throws {
        #expect(LiveWorkflowComposition.handles(.workflow(CLIResourceOptions(action: "list"))))
        #expect(!LiveWorkflowComposition.handles(.doctor(CLIDoctorOptions())))
        await #expect(throws: CLIApplicationError.self) {
            try await LiveWorkflowComposition.run(
                options: CLIResourceOptions(action: "frobnicate"),
                environment: [:],
                streams: CLIStreams(out: { _ in }, err: { _ in })
            )
        }
    }
}
