import Foundation
import OpenGrokHTTP
import OpenGrokHooks
import OpenGrokHooksPluginTypes
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokToolRegistry
import OpenGrokWorkflow
import Testing
@testable import OpenGrokCLI

private actor WorkflowChildAuthorityObserver {
    struct Snapshot: Sendable {
        let requests: [OpenGrokLiveSamplingRequest]
        let invokerModes: [ToolCapabilityMode]
        let emittedEvents: [String]
        let invokedTools: [String]
        let stopHooks: Int
    }

    private var requests: [OpenGrokLiveSamplingRequest] = []
    private var invokerModes: [ToolCapabilityMode] = []
    private var emittedEvents: [String] = []
    private var invokedTools: [String] = []
    private var stopHooks = 0

    func recordRequest(_ request: OpenGrokLiveSamplingRequest) {
        requests.append(request)
    }

    func recordInvoker(_ mode: ToolCapabilityMode) {
        invokerModes.append(mode)
    }

    func recordEvent(_ event: LiveWorkflowAgentEvent) {
        switch event {
        case .started: emittedEvents.append("started")
        case .status: emittedEvents.append("status")
        case .toolCall: emittedEvents.append("tool")
        case .finished: emittedEvents.append("finished")
        }
    }

    func recordTool(_ name: String) {
        invokedTools.append(name)
    }

    func recordStopHook() {
        stopHooks += 1
    }

    func snapshot() -> Snapshot {
        Snapshot(
            requests: requests,
            invokerModes: invokerModes,
            emittedEvents: emittedEvents,
            invokedTools: invokedTools,
            stopHooks: stopHooks
        )
    }
}

private struct WorkflowChildAuthorityInvoker: LiveWorkflowToolInvoker {
    let tools: [ToolSpec]
    let workingDirectory: URL
    let marker: URL
    let observer: WorkflowChildAuthorityObserver

    func invoke(
        sessionID: String,
        workingDirectory: URL,
        call: ToolCall
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        await observer.recordTool(call.name)
        do {
            try "tool mutated the parent".write(to: marker, atomically: true, encoding: .utf8)
            return .success(OpenGrokShellToolCallResult(
                value: .string("mutation"),
                promptText: "mutation"
            ))
        } catch {
            return .failure(.failed("could not write authority marker: \(error)"))
        }
    }

    func runStop(
        event: HookEvent,
        promptID: String?,
        payload: [String: HookJSONValue]
    ) async -> StopDispatchResult {
        await observer.recordStopHook()
        return StopDispatchResult()
    }
}

private struct WorkflowChildAuthorityFixture {
    let workspace: URL
    let marker: URL
    let observer: WorkflowChildAuthorityObserver
    let child: LiveWorkflowChildAgent

    init(
        parent: ToolCapabilityMode = .all,
        supportsReasoningEffort: Bool = false,
        sampler: OpenGrokLiveSampler? = nil,
        cancellation: RhaiCancellationToken = RhaiCancellationToken()
    ) throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-workflow-authority-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        marker = workspace.appendingPathComponent("parent-authority.txt")
        try "parent workspace untouched".write(to: marker, atomically: true, encoding: .utf8)

        let observer = WorkflowChildAuthorityObserver()
        self.observer = observer
        let selectedSampler = sampler ?? OpenGrokLiveSampler { request, _ in
            await observer.recordRequest(request)
            return OpenGrokLiveSamplingResponse(output: "workflow child completed")
        }
        let workspace = self.workspace
        let marker = self.marker
        let environment = LiveWorkflowAgentEnvironment(
            sampler: selectedSampler,
            model: "grok-workflow-parent",
            workspaceRoot: workspace,
            parentCapabilityMode: parent,
            supportsReasoningEffort: supportsReasoningEffort,
            makeInvoker: { mode in
                await observer.recordInvoker(mode)
                let names = mode == .readOnly ? ["read_file"] : ["read_file", "edit_file"]
                return WorkflowChildAuthorityInvoker(
                    tools: names.map {
                        ToolSpec(
                            name: $0,
                            description: $0,
                            parameters: .object(["type": .string("object")])
                        )
                    },
                    workingDirectory: workspace,
                    marker: marker,
                    observer: observer
                )
            }
        )
        child = LiveWorkflowChildAgent(
            runID: "workflow-authority-run",
            environment: environment,
            cancellation: cancellation
        )
    }

    func run(_ options: RhaiAgentOptions) async throws -> RhaiAgentResult {
        try await child.run(agentID: "workflow-authority-child", options: options) { event in
            await observer.recordEvent(event)
        }
    }

    func assertRejected(_ options: RhaiAgentOptions, expected: RhaiHostError) async throws {
        do {
            let result = try await run(options)
            Issue.record("unsafe workflow child unexpectedly ran: \(result)")
        } catch let error as RhaiHostError {
            #expect(error == expected)
        }

        let observation = await observer.snapshot()
        #expect(observation.requests.isEmpty, "a provider received the rejected child")
        #expect(observation.invokerModes.isEmpty, "a rejected child initialized tools, hooks, or MCP")
        #expect(observation.emittedEvents.isEmpty, "a rejected child became visibly started")
        #expect(observation.invokedTools.isEmpty, "a rejected child invoked a parent tool")
        #expect(observation.stopHooks == 0, "a rejected child executed a hook")
        #expect(try String(contentsOf: marker, encoding: .utf8) == "parent workspace untouched")
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: workspace)
    }
}

enum WorkflowUnsupportedAuthority: String, CaseIterable, Sendable {
    case worktree
    case fork
    case resume
    case specializedAgent
    case foreignModel

    var options: RhaiAgentOptions {
        switch self {
        case .worktree:
            RhaiAgentOptions(prompt: "edit only the isolated checkout", isolationWorktree: true)
        case .fork:
            RhaiAgentOptions(prompt: "use private parent history", forkContext: true)
        case .resume:
            RhaiAgentOptions(prompt: "continue the previous child", resumeFrom: "old-child")
        case .specializedAgent:
            RhaiAgentOptions(prompt: "perform privileged edits", agentType: "security-auditor")
        case .foreignModel:
            RhaiAgentOptions(prompt: "route across providers", model: "codex:gpt-private")
        }
    }

    var error: RhaiHostError {
        switch self {
        case .worktree:
            .unsupported("workflow child worktree isolation is not available")
        case .fork:
            .unsupported("fork_context is restricted to built-in workflows")
        case .resume:
            .unsupported("workflow child session resume is not available")
        case .specializedAgent:
            .unsupported("workflow agent_type 'security-auditor' is not available")
        case .foreignModel:
            .unsupported(
                "workflow model 'codex:gpt-private' requires an isolated provider sampling route"
            )
        }
    }
}

@Suite("Live workflow child authority parity", .serialized)
struct LiveWorkflowChildAuthorityParityTests {
    @Test("malformed capability never escalates into parent permissions", arguments: [
        "nonsense",
        "READ_ONLY",
        "read only",
        "",
        " read-only ",
        "read_only;all",
        "all\n",
    ])
    func invalidCapabilitiesFailBeforeAnySideEffect(_ capability: String) async throws {
        let fixture = try WorkflowChildAuthorityFixture(parent: .all)
        defer { fixture.cleanup() }

        try await fixture.assertRejected(
            RhaiAgentOptions(prompt: "modify the parent checkout", capabilityMode: capability),
            expected: .failed(
                "invalid capability_mode '\(capability)' "
                    + "(expected read-only, read-write, execute, or all)"
            )
        )
    }

    @Test("unsupported child isolation, context, role, and provider routes fail closed",
          arguments: WorkflowUnsupportedAuthority.allCases)
    func unsupportedAuthorityNeverStarts(_ requested: WorkflowUnsupportedAuthority) async throws {
        let fixture = try WorkflowChildAuthorityFixture()
        defer { fixture.cleanup() }

        try await fixture.assertRejected(requested.options, expected: requested.error)
    }

    @Test("valid read-only child receives only the narrowed production tool surface")
    func validReadOnlyCapabilityReachesLiveRequest() async throws {
        let fixture = try WorkflowChildAuthorityFixture(parent: .all)
        defer { fixture.cleanup() }

        let result = try await fixture.run(RhaiAgentOptions(
            prompt: "inspect without changing the parent",
            capabilityMode: "read-only"
        ))
        #expect(result.success)
        let observation = await fixture.observer.snapshot()
        #expect(observation.invokerModes == [.readOnly])
        #expect(observation.requests.count == 1)
        #expect(observation.requests.first?.tools.map(\.name) == ["read_file"])
        #expect(observation.emittedEvents == ["started", "status", "finished"])
    }

    @Test("broader valid capability remains clamped to the parent's ceiling")
    func validEscalationStillClampsToParent() async throws {
        let fixture = try WorkflowChildAuthorityFixture(parent: .readOnly)
        defer { fixture.cleanup() }

        let result = try await fixture.run(RhaiAgentOptions(
            prompt: "request broad access",
            capabilityMode: "all"
        ))
        #expect(result.success)
        let observation = await fixture.observer.snapshot()
        #expect(observation.invokerModes == [.readOnly])
        #expect(observation.requests.first?.tools.map(\.name) == ["read_file"])
    }

    @Test("Rust's exact legacy capability aliases remain accepted", arguments: [
        "read-only", "readonly", "readOnly", "read_only", "ReadOnly",
    ])
    func upstreamReadOnlyAliasesStayCompatible(_ alias: String) throws {
        #expect(try LiveWorkflowCapability.clamp(requested: alias, parent: .all) == .readOnly)
    }

    @Test("normalized workflow effort reaches the actual child sampling request", arguments: [
        "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra", " HIGH ",
    ])
    func validatedEffortReachesChildRequest(_ requested: String) async throws {
        let fixture = try WorkflowChildAuthorityFixture(supportsReasoningEffort: true)
        defer { fixture.cleanup() }

        let result = try await fixture.run(RhaiAgentOptions(
            prompt: "apply the requested effort",
            reasoningEffort: requested
        ))
        #expect(result.success)
        let normalized = requested.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let observation = await fixture.observer.snapshot()
        #expect(observation.requests.first?.reasoningEffort == ReasoningEffort(rawValue: normalized))
    }

    @Test("workflow effort sentinels are omissions rather than unsupported overrides", arguments: [
        "", "   ", "null", " NULL ", "undefined", "UNDEFINED",
    ])
    func effortSentinelsDoNotRequireModelSupport(_ requested: String) async throws {
        let fixture = try WorkflowChildAuthorityFixture(supportsReasoningEffort: false)
        defer { fixture.cleanup() }

        let result = try await fixture.run(RhaiAgentOptions(
            prompt: "use the parent default",
            reasoningEffort: requested
        ))
        #expect(result.success)
        let observation = await fixture.observer.snapshot()
        #expect(observation.requests.first?.reasoningEffort == nil)
    }

    @Test("invalid reasoning effort is rejected before provider, tools, hooks, or events")
    func invalidEffortFailsBeforeSideEffects() async throws {
        let fixture = try WorkflowChildAuthorityFixture(supportsReasoningEffort: true)
        defer { fixture.cleanup() }

        try await fixture.assertRejected(
            RhaiAgentOptions(prompt: "attempt excessive reasoning", reasoningEffort: "extreme"),
            expected: .failed(
                "invalid reasoning_effort \"extreme\" (expected one of: "
                    + "none, minimal, low, medium, high, xhigh, max, ultra)"
            )
        )
    }

    @Test("valid effort on an unsupported model fails closed rather than vanishing")
    func unsupportedModelEffortFailsBeforeSideEffects() async throws {
        let fixture = try WorkflowChildAuthorityFixture(supportsReasoningEffort: false)
        defer { fixture.cleanup() }

        try await fixture.assertRejected(
            RhaiAgentOptions(prompt: "request unsupported reasoning", reasoningEffort: "high"),
            expected: .unsupported(
                "reasoning_effort is not supported by the active workflow model"
            )
        )
    }

    @Test("oversized UTF-8 prompts cannot reach child admission")
    func oversizedPromptFailsBeforeSideEffects() async throws {
        let fixture = try WorkflowChildAuthorityFixture()
        defer { fixture.cleanup() }

        try await fixture.assertRejected(
            RhaiAgentOptions(prompt: String(repeating: "é", count: 524_289)),
            expected: .failed("agent prompt exceeds 1048576 bytes")
        )
    }

    @Test("label and phase byte ceilings are enforced before child startup", arguments: [
        "label", "phase",
    ])
    func metadataByteLimitsFailBeforeSideEffects(_ field: String) async throws {
        let fixture = try WorkflowChildAuthorityFixture()
        defer { fixture.cleanup() }
        let oversized = String(repeating: "é", count: 129)
        let options = field == "label"
            ? RhaiAgentOptions(prompt: "check label", label: oversized)
            : RhaiAgentOptions(prompt: "check phase", phase: oversized)

        try await fixture.assertRejected(
            options,
            expected: .failed("agent label and phase must each be at most 256 bytes")
        )
    }

    @Test("explicit default agent type and exact parent model remain legitimate")
    func explicitDefaultsRemainExecutable() async throws {
        let fixture = try WorkflowChildAuthorityFixture()
        defer { fixture.cleanup() }

        let result = try await fixture.run(RhaiAgentOptions(
            prompt: "use the existing parent route",
            model: "grok-workflow-parent",
            maxOutputTokens: 50,
            agentType: "general-purpose"
        ))
        #expect(result.success)
        let observation = await fixture.observer.snapshot()
        #expect(observation.requests.count == 1)
        #expect(observation.requests.first?.model == "grok-workflow-parent")
    }

    @Test("cancelled workflow never emits started or initializes child tools")
    func cancelledWorkflowRejectsBeforeAdmission() async throws {
        let cancellation = RhaiCancellationToken()
        cancellation.cancel()
        let fixture = try WorkflowChildAuthorityFixture(cancellation: cancellation)
        defer { fixture.cleanup() }

        try await fixture.assertRejected(
            RhaiAgentOptions(prompt: "do not start"),
            expected: .cancelled
        )
    }

    @Test("workflow effort override reaches the production provider HTTP body")
    func effortReachesRealProviderWire() async throws {
        let completed = #"{"type":"response.completed","response":{"id":"response-workflow","model":"grok-workflow-parent","status":"completed","output":[{"type":"message","role":"assistant","content":"done"}],"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}}"#
        let transport = MockHTTPTransport(responses: [
            .init(
                metadata: HTTPResponseMetadata(
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream"]
                ),
                body: Data("data: \(completed)\n\n".utf8)
            ),
        ])
        let sampler = try OpenGrokLiveSampler.production(
            configuration: OpenGrokLiveSamplingConfiguration(
                model: "grok-workflow-parent",
                baseURL: "https://api.x.ai/v1",
                apiKey: "workflow-private-key",
                provider: .xai,
                apiBackend: .responses,
                tuning: OpenGrokLiveSamplingTuning(reasoningEffort: .low),
                transport: transport
            )
        )
        let fixture = try WorkflowChildAuthorityFixture(
            supportsReasoningEffort: true,
            sampler: sampler
        )
        defer { fixture.cleanup() }

        let result = try await fixture.run(RhaiAgentOptions(
            prompt: "override parent reasoning",
            reasoningEffort: " HIGH "
        ))
        #expect(result.success)
        let request = try #require(transport.recordedRequests.first)
        #expect(request.headers["Authorization"] == "Bearer workflow-private-key")
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
        #expect(body["reasoning"]?["effort"]?.stringValue == "high")
    }
}
