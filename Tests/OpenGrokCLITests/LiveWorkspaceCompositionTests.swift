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
import OpenGrokHTTP
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokWorkspace

// MARK: - Fakes

/// A leader that answers control commands, standing in for the hub backend:
/// `ACPLeaderIPCHost` implements the control plane, but these tests exercise
/// the route without a real leader process, so the channel stays fake. The
/// live-seam proof against the real host is `portDefaultLeaderBacksExposureAdvert`.
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

@Suite("workspace remote settings loader")
struct WorkspaceRemoteSettingsLoaderTests {
    @Test("fetches authenticated settings from the configured proxy")
    func fetchesConfiguredSettings() async throws {
        var settings = RemoteSettings()
        settings.workspaceCommandEnabled = true
        let transport = MockHTTPTransport(responses: [
            MockHTTPTransport.ScriptedResponse(
                metadata: HTTPResponseMetadata(statusCode: 200),
                body: try JSONEncoder().encode(settings)
            )
        ])

        let loaded = await loadWorkspaceRemoteSettings(
            environment: [
                "XAI_API_KEY": "test-token",
                "GROK_CLI_CHAT_PROXY_BASE_URL": "https://proxy.example/v1",
            ],
            transport: transport
        )

        #expect(loaded?.workspaceCommandEnabled == true)
        let request = try #require(transport.recordedRequests.first)
        #expect(request.method == .get)
        #expect(request.url.absoluteString == "https://proxy.example/v1/settings")
        #expect(request.headers["Accept"] == "application/json")
        #expect(request.headers["Authorization"] == "Bearer test-token")
    }

    @Test("maps malformed endpoint, non-2xx, and malformed body to unavailable settings")
    func loaderFailsClosed() async throws {
        let environment = ["XAI_API_KEY": "test-token"]
        let malformedEndpoint = await loadWorkspaceRemoteSettings(
            environment: environment.merging(["GROK_CLI_CHAT_PROXY_BASE_URL": "%%%"], uniquingKeysWith: { _, new in new }),
            transport: MockHTTPTransport()
        )
        #expect(malformedEndpoint == nil)

        let nonSuccessTransport = MockHTTPTransport(responses: [
            MockHTTPTransport.ScriptedResponse(
                metadata: HTTPResponseMetadata(statusCode: 503),
                body: Data("{}".utf8)
            )
        ])
        let nonSuccess = await loadWorkspaceRemoteSettings(
            environment: environment,
            transport: nonSuccessTransport
        )
        #expect(nonSuccess == nil)

        let malformedBodyTransport = MockHTTPTransport(responses: [
            MockHTTPTransport.ScriptedResponse(
                metadata: HTTPResponseMetadata(statusCode: 200),
                body: Data("not-json".utf8)
            )
        ])
        let malformedBody = await loadWorkspaceRemoteSettings(
            environment: environment,
            transport: malformedBodyTransport
        )
        #expect(malformedBody == nil)
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

    @Test("this port's leader backs its workspace_exposure advert with a live control plane")
    func portDefaultLeaderBacksExposureAdvert() async throws {
        // The inverted tripwire. While the control plane did not exist, this
        // test asserted `workspaceExposure == false` so the bit could not be
        // flipped without the implementation. `ACPLeaderControlPlane` now
        // exists, so the assertion inverts: the bit must stay set AND the real
        // ACPLeaderIPCHost — driven below over the same frame codec the
        // production Unix socket serves — must answer workspace control round
        // trips. Dropping the control plane while keeping the bit fails here,
        // which is the lie the original guard prevented in the other
        // direction.
        #expect(ACPLeaderCapabilities.supported.workspaceExposure)
        #expect(ACPLeaderCapabilities.supported.controlV1)

        // Half 1: the production-default host (no hub backend wired) still
        // answers `workspace_status` truthfully — state none, real pid.
        let production = ACPLeaderIPCHost(runtime: ACPAgentRuntime())
        let productionReplies = try await driveWorkspaceControl(
            over: production,
            commands: [(id: "ws-1", command: ["type": "workspace_status"])]
        )
        guard case .controlResult("ws-1", .workspaceStatus(let none)) = productionReplies["ws-1"] else {
            Issue.record("expected a workspace_status result, got \(productionReplies)")
            return
        }
        #expect(none.state == "none")
        #expect(none.pid == UInt32(clamping: ProcessInfo.processInfo.processIdentifier))

        // Half 2: with an exposure backend injected, the same seam reports
        // the exposure itself — reachable, not merely representable.
        let plane = ACPLeaderControlPlane(
            connector: { _, _ in TripwireExposureConnection() }
        )
        let backed = ACPLeaderIPCHost(
            runtime: ACPAgentRuntime(),
            configuration: ACPLeaderIPCConfiguration(controlPlane: plane)
        )
        let backedReplies = try await driveWorkspaceControl(
            over: backed,
            commands: [
                (id: "ws-1", command: ["type": "workspace_start", "hub_url": "wss://hub.test/ws", "cwd": "/tmp/proj"]),
                (id: "ws-2", command: ["type": "workspace_status"]),
            ]
        )
        guard case .controlResult("ws-1", .workspaceStatus(let started)) = backedReplies["ws-1"] else {
            Issue.record("expected workspace_start to succeed, got \(backedReplies)")
            return
        }
        #expect(started.state == "running")
        #expect(started.hubURL == "wss://hub.test/ws")
        #expect(started.cwd == "/tmp/proj")
        guard case .controlResult("ws-2", .workspaceStatus(let polled)) = backedReplies["ws-2"] else {
            Issue.record("expected workspace_status to succeed, got \(backedReplies)")
            return
        }
        #expect(polled.state == "running")
        #expect(polled.activeToolCalls == 1)
        #expect(polled.sessions == ["sess-1"])
    }

    @Test("production leader configuration constructs a live workspace connector")
    func productionLeaderConfigurationWiresExposureConnector() async throws {
        let configuration = LiveLeaderComposition.productionIPCConfiguration(
            paths: (
                socket: URL(fileURLWithPath: "/tmp/open-grok-leader.sock"),
                lock: URL(fileURLWithPath: "/tmp/open-grok-leader.lock")
            ),
            relayURL: "wss://relay.example/ws",
            environment: [:],
            productionExposureConnector: { _, _ in TripwireExposureConnection() }
        )
        guard configuration.controlPlane != nil else {
            Issue.record("production leader configuration dropped its exposure connector")
            return
        }
        let host = ACPLeaderIPCHost(
            runtime: ACPAgentRuntime(),
            configuration: configuration
        )
        let replies = try await driveWorkspaceControl(
            over: host,
            commands: [
                (id: "ws-connector", command: [
                    "type": "workspace_start",
                    "hub_url": "wss://hub.test/ws",
                    "cwd": "/tmp/proj"
                ])
            ]
        )
        guard case .controlResult("ws-connector", .workspaceStatus(let status)) = replies["ws-connector"] else {
            Issue.record("production workspace connector did not start the exposure: \(replies)")
            return
        }
        #expect(status.state == "running")
        #expect(status.hubURL == "wss://hub.test/ws")
        #expect(status.cwd == "/tmp/proj")
    }

    @Test("the production workspace channel consumes a control result", .timeLimit(.minutes(1)))
    func productionChannelConsumesControlResult() async throws {
        let host = ACPLeaderIPCHost(runtime: ACPAgentRuntime())
        let pair = InMemoryWebSocketChannel.makePair()
        let served = Task { await host.serve(channel: pair.a) }
        defer { served.cancel() }

        let deadline = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            await pair.b.close()
        }
        defer { deadline.cancel() }

        let channel = try await LeaderWorkspaceControlChannel.register(channel: pair.b)
        let payload = try await channel.send(.status)
        #expect(payload.state == "none")
        #expect(payload.pid == ProcessInfo.processInfo.processIdentifier)
        await channel.close()
    }
}

// MARK: - Control plane tripwire driver

/// An exposure backend for the tripwire: proves the control plane reports an
/// exposure it is given, not only the empty state.
private final class TripwireExposureConnection: ACPWorkspaceExposureConnection, @unchecked Sendable {
    func snapshot() -> ACPWorkspaceActivitySnapshot {
        ACPWorkspaceActivitySnapshot(activeToolCalls: 1, sessionIDs: ["sess-1"])
    }

    func disconnect() async {}
    func reconnect() async throws {}
}

/// Drive the real leader IPC host over an in-memory channel and collect one
/// control reply per command. This is the same frame codec and host the
/// production Unix socket serves (`ACPLeaderSocketListener`).
private func driveWorkspaceControl(
    over host: ACPLeaderIPCHost,
    commands: [(id: String, command: [String: String])]
) async throws -> [String: ACPLeaderServerMessage] {
    let pair = InMemoryWebSocketChannel.makePair()
    let served = Task { await host.serve(channel: pair.a) }
    defer { served.cancel() }

    let reader = ACPLeaderChannelReader(
        channel: pair.b,
        maximumMessageSize: ACPLeaderProtocolLimits.maximumMessageSize
    )
    // Bounded reads: a leader that stops answering would park the suite
    // forever (`ByteMailbox.take()` ignores cancellation), so a deadline
    // closes the channel and fails the test instead.
    let deadline = Task {
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        guard !Task.isCancelled else { return }
        await pair.b.close()
    }
    defer { deadline.cancel() }

    try await pair.b.write(
        try ACPLeaderCodec.encode(
            ACPLeaderClientMessage.register(
                clientType: "grok-workspace-cli",
                mode: .stdio,
                capabilities: ACPLeaderClientCapabilities()
            )
        )
    )

    // Await the registration before any control traffic, and require the
    // advert this whole test exists to police.
    var capabilities: ACPLeaderCapabilities?
    while capabilities == nil {
        guard let message = try await reader.next(ACPLeaderServerMessage.self) else { break }
        if case .registered(_, _, _, _, let advertised) = message {
            capabilities = advertised
        }
    }
    #expect(capabilities?.workspaceExposure == true)
    #expect(capabilities?.controlV1 == true)

    var replies: [String: ACPLeaderServerMessage] = [:]
    for (id, command) in commands {
        try await pair.b.write(
            try ACPLeaderCodec.encode(ACPLeaderClientMessage.control(requestID: id, command: command))
        )
        // Control commands are answered on detached tasks
        // (`server.rs:1763-1817`), so each reply is awaited before the next
        // command is sent — a pipelined status could legitimately read the
        // pre-start state and make the test flaky.
        while replies[id] == nil {
            guard let message = try await reader.next(ACPLeaderServerMessage.self) else { break }
            switch message {
            case .controlResult(let replyID, _) where replyID == id:
                replies[id] = message
            case .controlError(let replyID, _, _) where replyID == id:
                replies[id] = message
            default:
                continue
            }
        }
    }
    return replies
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
