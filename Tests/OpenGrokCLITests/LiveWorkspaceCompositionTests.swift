// LiveWorkspaceCompositionTests.swift
//
// Coverage for the `open-grok workspace` route.
//
// Every test that exercises the route drives it from a parsed argv rather
// than a hand-built `CLIUtilityOptions`. That is the live seam: a route can
// be perfectly implemented and still be unreachable because the parser hands
// it a shape it does not recognise, and a test that constructs the options
// itself passes either way (AGENTS.md §3).

import Foundation
import Testing
@testable import OpenGrokCLI
import OpenGrokACPRuntime
import OpenGrokComputerHubCore
import OpenGrokConfigTypes
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokWorkspace

// MARK: - Fakes

/// A leader that answers control commands, standing in for the control plane
/// this port's `ACPLeaderIPCHost` does not implement yet.
private final class FakeLeaderChannel: WorkspaceControlChannel, @unchecked Sendable {
    let advertisedCapabilities: ACPLeaderCapabilities?

    private let lock = NSLock()
    private var received: [WorkspaceControlCommand] = []
    private var state: String
    private var cwd: String?
    private var hubURL: String?
    private var closed = false

    init(
        capabilities: ACPLeaderCapabilities? = ACPLeaderCapabilities(workspaceExposure: true),
        initialState: String = "none"
    ) {
        self.advertisedCapabilities = capabilities
        self.state = initialState
    }

    var commands: [WorkspaceControlCommand] {
        lock.lock(); defer { lock.unlock() }
        return received
    }

    var wasClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    private func apply(_ command: WorkspaceControlCommand) -> WorkspaceStatusPayload {
        lock.lock()
        defer { lock.unlock() }
        received.append(command)
        switch command {
        case .start(let url, let dir):
            state = "running"
            hubURL = url ?? "wss://hub.example/ws"
            cwd = dir
        case .pause: state = "paused"
        case .resume: state = "running"
        case .stop:
            state = "none"
            hubURL = nil
            cwd = nil
        case .status: break
        }
        return WorkspaceStatusPayload(
            state: state,
            hubURL: hubURL,
            cwd: cwd,
            uptimeMs: state == "none" ? 0 : 5_000,
            activeToolCalls: state == "running" ? 2 : 0,
            sessions: state == "none" ? [] : ["sess-a", "sess-b"],
            pid: 4242
        )
    }

    func send(_ command: WorkspaceControlCommand) async throws -> WorkspaceStatusPayload {
        apply(command)
    }

    private func markClosed() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    func close() async {
        markClosed()
    }
}

/// The env that gets past the feature gate, so a test about `start` is not
/// silently a test about the gate.
private let gateEnabled = ["GROK_WORKSPACE_COMMAND": "1"]

private func workspaceOptions(_ argv: [String]) throws -> CLIUtilityOptions {
    let command = try CLICommandParser.parseOrThrow(argv)
    guard case .utility(let options) = command, options.name == "workspace" else {
        throw WorkspaceRouteError("argv did not parse to the workspace route: \(argv)")
    }
    return options
}

@discardableResult
private func runWorkspace(
    _ argv: [String],
    environment: [String: String] = gateEnabled,
    sandboxProfile: String? = nil,
    remoteSettings: RemoteSettings? = nil,
    channel: FakeLeaderChannel = FakeLeaderChannel()
) async throws -> (out: String, err: String, channel: FakeLeaderChannel) {
    let (streams, outBuffer, errBuffer) = CLIStreams.buffered()
    try await LiveWorkspaceComposition.run(
        options: try workspaceOptions(argv),
        environment: environment,
        streams: streams,
        sandboxProfile: sandboxProfile,
        remoteSettings: remoteSettings,
        connect: { _ in channel }
    )
    return (outBuffer.contents, errBuffer.contents, channel)
}

// MARK: - Reachability

@Suite("workspace route reachability")
struct WorkspaceRouteReachabilityTests {
    @Test("every documented subcommand parses to the workspace route")
    func subcommandsParse() throws {
        for action in ["start", "restart", "pause", "resume", "stop", "status", "list"] {
            let options = try workspaceOptions(["workspace", action])
            #expect(options.values.first == action)
        }
    }

    @Test("the launcher hook claims the route")
    func handlesCommand() throws {
        #expect(LiveWorkspaceComposition.handles(try CLICommandParser.parseOrThrow(["workspace", "status"])))
        #expect(!LiveWorkspaceComposition.handles(try CLICommandParser.parseOrThrow(["mcp", "list"])))
    }
}

// MARK: - Feature gate

@Suite("workspace feature gate")
struct WorkspaceGateTests {
    @Test("env override wins over remote settings, in both directions")
    func envOverrideWins() {
        var settings = RemoteSettings()
        settings.workspaceCommandEnabled = false
        #expect(workspaceCommandGate(environmentOverride: true, remoteSettings: settings) == .enabled)

        settings.workspaceCommandEnabled = true
        #expect(workspaceCommandGate(environmentOverride: false, remoteSettings: settings) == .disabled)
    }

    @Test("absent settings are unknown, not disabled — main.rs:280")
    func absentSettingsAreUnknown() {
        #expect(workspaceCommandGate(environmentOverride: nil, remoteSettings: nil) == .unknown)
    }

    @Test("loaded-but-unset is disabled, not unknown — main.rs:279")
    func loadedButUnsetIsDisabled() {
        #expect(
            workspaceCommandGate(environmentOverride: nil, remoteSettings: RemoteSettings())
                == .disabled
        )
    }

    @Test("falsy spellings disable; everything else enables — main.rs:285-290")
    func envFlagSpellings() {
        for falsy in ["", "0", "false", "off", "no", "  OFF  ", "False"] {
            #expect(!workspaceEnvFlagEnabled(falsy), "expected '\(falsy)' to be falsy")
        }
        for truthy in ["1", "true", "yes", "on", "anything"] {
            #expect(workspaceEnvFlagEnabled(truthy), "expected '\(truthy)' to be truthy")
        }
    }

    @Test("an unknown gate refuses and never dials the leader")
    func unknownGateRefusesBeforeDialing() async throws {
        let channel = FakeLeaderChannel()
        await #expect(throws: WorkspaceRouteError.self) {
            try await runWorkspace(["workspace", "status"], environment: [:], channel: channel)
        }
        // The decisive assertion: refusal happened before any connection.
        #expect(channel.commands.isEmpty)
    }

    @Test("a disabled gate refuses with the account wording, not the network wording")
    func disabledGateWording() async throws {
        do {
            _ = try await runWorkspace(
                ["workspace", "status"],
                environment: ["GROK_WORKSPACE_COMMAND": "0"]
            )
            Issue.record("expected a refusal")
        } catch let error as WorkspaceRouteError {
            #expect(error.message.contains("not enabled for this account"))
        }
    }
}

// MARK: - Sandbox refusal

@Suite("workspace sandbox refusal")
struct WorkspaceSandboxTests {
    @Test("start/restart/resume are refused under a confinement profile")
    func activatingActionsRefused() async throws {
        for action in ["start", "restart", "resume"] {
            let channel = FakeLeaderChannel()
            do {
                _ = try await runWorkspace(
                    ["workspace", action],
                    sandboxProfile: "readonly",
                    channel: channel
                )
                Issue.record("expected '\(action)' to be refused under a sandbox profile")
            } catch let error as WorkspaceRouteError {
                #expect(error.message.contains("sandbox profile 'readonly'"))
            }
            #expect(channel.commands.isEmpty)
        }
    }

    @Test("status/pause/stop still work under a confinement profile — main.rs:296-301")
    func nonActivatingActionsAllowed() async throws {
        for action in ["status", "pause", "stop"] {
            let result = try await runWorkspace(["workspace", action], sandboxProfile: "readonly")
            #expect(!result.channel.commands.isEmpty, "'\(action)' should have reached the leader")
        }
    }

    @Test("the sandbox refusal precedes the feature gate")
    func sandboxRefusalPrecedesGate() async throws {
        // No gate env at all: if the gate ran first this would be the
        // "could not load your settings" message instead.
        do {
            _ = try await runWorkspace(
                ["workspace", "start"],
                environment: [:],
                sandboxProfile: "strict"
            )
            Issue.record("expected a refusal")
        } catch let error as WorkspaceRouteError {
            #expect(error.message.contains("sandbox profile 'strict'"))
        }
    }
}

// MARK: - Capability check

@Suite("workspace leader capability check")
struct WorkspaceCapabilityTests {
    @Test("a leader without workspace_exposure is refused — main.rs:353-362")
    func leaderWithoutExposureRefused() async throws {
        let channel = FakeLeaderChannel(capabilities: ACPLeaderCapabilities())
        do {
            _ = try await runWorkspace(["workspace", "status"], channel: channel)
            Issue.record("expected the capability check to refuse")
        } catch let error as WorkspaceRouteError {
            #expect(error.message.contains("does not support workspace exposure"))
        }
        #expect(channel.commands.isEmpty)
    }

    @Test("a leader advertising no capabilities at all is refused")
    func leaderWithoutCapabilitiesRefused() {
        #expect(throws: WorkspaceRouteError.self) {
            try ensureWorkspaceCapabilities(nil)
        }
    }

    @Test("this port's default leader capabilities do not permit exposure")
    func portDefaultLeaderIsRefused() {
        // Guards the honesty claim in the route's header comment: if someone
        // flips `ACPLeaderCapabilities.supported` without implementing the
        // control plane, this fails and they have to look at why.
        #expect(!ACPLeaderCapabilities.supported.workspaceExposure)
    }
}

// MARK: - Lifecycle

@Suite("workspace lifecycle")
struct WorkspaceLifecycleTests {
    @Test("status on an idle leader renders the not-running line — main.rs:501-504")
    func statusWhenNotRunning() async throws {
        let result = try await runWorkspace(["workspace", "status"])
        #expect(result.out == "Workspace exposure: not running (leader PID 4242)\n")
        #expect(result.channel.commands == [.status])
    }

    @Test("list is an alias for status, not a distinct command — cli.rs:206")
    func listIsStatusAlias() async throws {
        let result = try await runWorkspace(["workspace", "list"])
        #expect(result.channel.commands == [.status])
    }

    @Test("start then status then stop moves the leader through the states")
    func startStatusStop() async throws {
        let channel = FakeLeaderChannel()

        let started = try await runWorkspace(
            ["workspace", "start", "--hub-url", "wss://hub.test/ws", "--cwd", "/tmp"],
            channel: channel
        )
        #expect(started.out.contains("Workspace exposure: running"))
        #expect(started.out.contains("hub:      wss://hub.test/ws"))
        #expect(started.out.contains("active:   2 tool call(s)"))
        #expect(started.out.contains("sessions: 2 (sess-a, sess-b)"))

        let status = try await runWorkspace(["workspace", "status"], channel: channel)
        #expect(status.out.contains("Workspace exposure: running"))

        let stopped = try await runWorkspace(["workspace", "stop"], channel: channel)
        #expect(stopped.out == "Workspace exposure: not running (leader PID 4242)\n")

        #expect(channel.commands.count == 3)
        #expect(channel.commands.last == .stop)
    }

    @Test("pause then resume round-trips")
    func pauseResume() async throws {
        let channel = FakeLeaderChannel(initialState: "running")

        let paused = try await runWorkspace(["workspace", "pause"], channel: channel)
        #expect(paused.out.contains("Workspace exposure: paused"))

        let resumed = try await runWorkspace(["workspace", "resume"], channel: channel)
        #expect(resumed.out.contains("Workspace exposure: running"))

        #expect(channel.commands == [.pause, .resume])
    }

    @Test("restart is stop-then-start — main.rs:451")
    func restartIsStopThenStart() async throws {
        let result = try await runWorkspace(["workspace", "restart", "--cwd", "/tmp"])
        #expect(result.channel.commands.count == 2)
        #expect(result.channel.commands.first == .stop)
        guard case .start = result.channel.commands.last else {
            Issue.record("expected restart to end in a start, got \(result.channel.commands)")
            return
        }
    }

    @Test("start refuses under --no-leader without dialling — main.rs:422-431")
    func startRequiresLeaderMode() async throws {
        let channel = FakeLeaderChannel()
        do {
            _ = try await runWorkspace(["workspace", "start", "--no-leader"], channel: channel)
            Issue.record("expected --no-leader to refuse")
        } catch let error as WorkspaceRouteError {
            #expect(error.message.contains("requires leader mode"))
        }
        #expect(channel.commands.isEmpty)
    }

    @Test("a bare `workspace` is a usage error, not a silent status")
    func bareWorkspaceIsUsageError() async throws {
        // The parser refuses first, so this never reaches the route — which
        // is the right layer for it. The route keeps its own guard for
        // programmatic callers that build `CLIUtilityOptions` directly; the
        // next test covers that one so neither guard can rot unnoticed.
        #expect(throws: CLIParseError.self) {
            _ = try CLICommandParser.parseOrThrow(["workspace"])
        }
    }

    @Test("the route refuses an empty action even when the parser is bypassed")
    func routeRefusesEmptyActionDirectly() async throws {
        let channel = FakeLeaderChannel()
        let (streams, _, _) = CLIStreams.buffered()
        await #expect(throws: WorkspaceRouteError.self) {
            try await LiveWorkspaceComposition.run(
                options: CLIUtilityOptions(name: "workspace"),
                environment: gateEnabled,
                streams: streams,
                sandboxProfile: nil,
                remoteSettings: nil,
                connect: { _ in channel }
            )
        }
        #expect(channel.commands.isEmpty)
    }

    @Test("the channel is closed even when the control command succeeds")
    func channelIsClosed() async throws {
        let result = try await runWorkspace(["workspace", "status"])
        // The close is scheduled on a detached task by the route's `defer`;
        // yield until it lands rather than racing it.
        for _ in 0..<100 where !result.channel.wasClosed {
            await Task.yield()
        }
        #expect(result.channel.wasClosed)
    }
}

// MARK: - Rendering

@Suite("workspace status rendering")
struct WorkspaceRenderTests {
    @Test("--json emits the upstream key spellings — main.rs:481-491")
    func jsonKeys() async throws {
        let result = try await runWorkspace(["workspace", "status", "--json"])
        let data = Data(result.out.utf8)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let keys = Set((object ?? [:]).keys)
        // `hubUrl`/`cwd` are absent when nil, matching serde's skip behaviour
        // for the not-running payload.
        #expect(keys.isSuperset(of: ["state", "uptimeMs", "activeToolCalls", "sessions", "pid"]))
        #expect(object?["state"] as? String == "none")
        #expect(object?["pid"] as? Int == 4242)
    }

    @Test("uptime renders in whole seconds and empty sessions render as a dash")
    func humanRendering() {
        let (streams, out, _) = CLIStreams.buffered()
        LiveWorkspaceComposition.renderStatus(
            WorkspaceStatusPayload(
                state: "running",
                cwd: "/work",
                uptimeMs: 65_400,
                activeToolCalls: 0,
                sessions: [],
                pid: 7
            ),
            json: false,
            streams: streams
        )
        #expect(out.contents.contains("uptime:   65s"))
        #expect(out.contents.contains("sessions: 0 (-)"))
        #expect(out.contents.contains("leader:   PID 7"))
        // No hub line when the leader reported no URL.
        #expect(!out.contents.contains("hub:"))
    }
}

// MARK: - Permission mediation

@Suite("hub calls are mediated by the real permission pipeline")
struct LiveHubMediationTests {
    private func request(tool: String = "remote_shell") throws -> HubCallRequest {
        HubCallRequest(
            toolId: try ToolId(tool),
            toolCallId: ToolCallId.newV7(),
            sessionId: try SessionId("s"),
            origin: .mcpBridge(server: "vendor-server"),
            arguments: .object(["cmd": .string("rm -rf /")])
        )
    }

    @Test("a policy deny from the real pipeline denies the hub call")
    func policyDenyDeniesHubCall() async throws {
        // `remotePolicyDenied` is the pipeline's own first gate
        // (PermissionPipeline.swift:170), so this asserts the hub call is
        // subject to the same gate order as the agent's own tools.
        let mediator = LivePermissionHubMediator(
            pipeline: PermissionPipeline(
                permissions: PermissionHandle(),
                remotePolicyDenied: true,
                remotePolicyAvailable: true
            )
        )
        let verdict = await mediator.mediate(try request())
        guard case .deny(let reason) = verdict else {
            Issue.record("expected a denial, got \(verdict)")
            return
        }
        #expect(reason.contains(PermissionDecisionSource.remotePolicy.rawValue))
    }

    @Test("a required-but-unprovable sandbox denies the hub call")
    func sandboxRequirementDeniesHubCall() async throws {
        let mediator = LivePermissionHubMediator(
            pipeline: PermissionPipeline(
                permissions: PermissionHandle(),
                remotePolicyAvailable: false,
                requireSandbox: true,
                isolation: .sandbox
            )
        )
        let verdict = await mediator.mediate(try request())
        guard case .deny(let reason) = verdict else {
            Issue.record("expected a denial, got \(verdict)")
            return
        }
        #expect(reason.contains(PermissionDecisionSource.sandboxRequired.rawValue))
    }

    @Test("an allow-all pipeline allows, so the denials above are not vacuous")
    func allowingPipelineAllows() async throws {
        let mediator = LivePermissionHubMediator(
            pipeline: PermissionPipeline(permissions: PermissionHandle(allowAll: true))
        )
        #expect(await mediator.mediate(try request()) == .allow)
    }

    @Test("an unanswered ask is a denial, never a pass")
    func askIsDenied() async throws {
        // The default headless prompter cannot answer, and a hub call has no
        // prompt attached — treating "needs asking" as "yes" is the fail-open
        // this seam exists to prevent.
        let mediator = LivePermissionHubMediator(
            pipeline: PermissionPipeline(permissions: PermissionHandle())
        )
        let verdict = await mediator.mediate(try request())
        #expect(verdict != .allow)
    }

    @Test("hub calls are classified as mcp tools so user rules can match them")
    func classifiedAsMcpTool() throws {
        let kind = LivePermissionHubMediator.accessKind(for: try request(tool: "vendor_tool"))
        guard case .mcpTool(let name, _) = kind else {
            Issue.record("expected .mcpTool, got \(kind)")
            return
        }
        #expect(name == "vendor_tool")
    }
}
