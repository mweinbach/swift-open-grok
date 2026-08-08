// ACPNotificationGatewayTests.swift
//
// The ACP notification gateway (Wave 15 item 5), asserted over the REAL
// ws:// carrier: a live `ACPAgentRuntime` behind `ACPServeHost` on a loopback
// socket, driven by the shipping WebSocket client. Every inbound arm is
// asserted on the LIVE state it must reach — the pipeline's
// `PermissionHandle`, the E8 `LiveSwarmModeState` tracker — never a mirror,
// and every outbound arm is read back as the actual frame the client
// receives, pinned against upstream's payload shapes:
//
//   * `x.ai/yolo_mode_changed` / `x.ai/permissions/reset`
//     (acp_agent.rs:4486-4553, 4571-4586)
//   * `x.ai/swarm_mode_changed` in AND out (acp_agent.rs:4555-4570;
//     reminders.rs:563-577; run_loop.rs:1120-1138)
//   * `x.ai/session/prompt_complete` (acp_agent.rs:2952-2986;
//     prompt_complete_fields, sampling/error.rs:308-331)
//   * `x.ai/recap` → SessionRecap / SessionRecapUnavailable
//     (extensions/recap.rs:21-58; recap.rs:497-506)
//   * mailbox send → SubagentMessage (subagent_coordinator.rs:154-193;
//     notification.rs:749-760)
//
// The recap arm runs the PRODUCTION sampler over a recording transport (the
// documented `OpenGrokLiveSamplingConfiguration.transport` seam), so the
// model call the recap makes is the request the shipping stack forms.

import Foundation
import OpenGrokACP
import OpenGrokAgentCoordinator
import OpenGrokAuth
import OpenGrokHTTP
import OpenGrokModels
import OpenGrokProviderSession
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShellSessionSupport
import OpenGrokToolTypes
import OpenGrokWorkspace
import Testing

@testable import OpenGrokACPRuntime
@testable import OpenGrokCLI

private typealias JSONValue = OpenGrokShared.JSONValue

// MARK: - Harness

private func makeTemporaryHome() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("opengrok-acp-notify-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func pinnedEnvironment(home: URL, extra: [String: String] = [:]) -> [String: String] {
    var environment = [
        "OPENGROK_HOME": home.path,
        "HOME": home.path,
    ]
    for (key, value) in extra { environment[key] = value }
    return environment
}

private func sseResponse(text: String) -> MockHTTPTransport.ScriptedResponse {
    let chunk = #"{"id":"1","object":"chat.completion.chunk","created":0,"model":"m","choices":"#
        + #"[{"index":0,"delta":{"role":"assistant","content":"\#(text)"},"finish_reason":"stop"}]}"#
    return .init(
        metadata: HTTPResponseMetadata(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"]
        ),
        body: Data("data: \(chunk)\n\ndata: [DONE]\n\n".utf8)
    )
}

private func wsConnect(
    to endpoint: ACPServeEndpoint,
    secret: String
) async throws -> ACPWebSocketConnectionTransport {
    let channel = try await WebSocketNetworkChannel.connect(
        host: endpoint.host,
        port: endpoint.port
    )
    let connection = try await WebSocketClientUpgrade.connect(
        channel: channel,
        host: endpoint.address,
        target: endpoint.path + "?server-key=\(secret)"
    )
    return ACPWebSocketConnectionTransport(connection: connection)
}

private func wsDrain(
    _ transport: ACPWebSocketConnectionTransport,
    limit: Int = 40,
    until match: (ACPMessage) -> Bool
) async throws -> ACPMessage {
    for _ in 0..<limit {
        let message = try await transport.receive()
        if match(message) { return message }
    }
    throw ACPTransportError.closed
}

/// Poll an async predicate until it holds or ~2s elapse. Inbound
/// notifications are fire-and-forget — the serve loop dispatches each frame
/// on its own child task, so there is no response to await; the LIVE state
/// is the only observable.
private func pollUntil(
    _ predicate: @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<100 {
        if await predicate() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await predicate()
}

/// One serve host over one runtime, torn down by the caller.
private struct ServedRuntime {
    let host: ACPServeHost
    let endpoint: ACPServeEndpoint
    let served: Task<Void, Never>
    let client: ACPWebSocketConnectionTransport

    static func start(
        secret: String,
        makeRuntime: @escaping @Sendable () async throws -> ACPAgentRuntime
    ) async throws -> ServedRuntime {
        let host = ACPServeHost(
            configuration: ACPServeConfiguration(
                host: "127.0.0.1",
                port: 0,
                secret: secret,
                keepAliveInterval: nil
            ),
            makeRuntime: makeRuntime
        )
        let endpoint = try await host.start()
        let served = Task { await host.run() }
        let client = try await wsConnect(to: endpoint, secret: secret)
        return ServedRuntime(host: host, endpoint: endpoint, served: served, client: client)
    }

    func initialize() async throws {
        try await client.send(.request(
            id: .number(1),
            method: AgentMethodNames.initialize,
            params: .object([
                "protocolVersion": .number(.int64(1)),
                "clientCapabilities": .object([:]),
            ])
        ))
        _ = try await wsDrain(client) { $0.id == .number(1) }
    }

    func newSession(cwd: String) async throws -> String {
        try await client.send(.request(
            id: .number(2),
            method: AgentMethodNames.sessionNew,
            params: .object(["cwd": .string(cwd), "mcpServers": .array([])])
        ))
        let created = try await wsDrain(client) { $0.id == .number(2) }
        guard case .response(_, .object(let object)?, _) = created,
              case .string(let sessionId)? = object["sessionId"] else {
            throw ACPTransportError.invalidMessage("no sessionId in \(created)")
        }
        return sessionId
    }

    func stop() async {
        await client.close()
        served.cancel()
        await host.stop()
    }
}

// MARK: - Inbound: yolo / auto / permissions reset

@Suite("ACP inbound permission notifications over ws://", .serialized)
struct ACPInboundPermissionNotificationTests {
    private struct Fixture {
        let handle: PermissionHandle
        let mode: LiveSessionPermissionMode
        let served: ServedRuntime

        static func start(resolved: ResolvedPermissions = ResolvedPermissions()) async throws -> Fixture {
            let home = try makeTemporaryHome()
            let handle = PermissionHandle(
                yoloPinReason: resolved.yoloPinReason,
                shellCwd: home.path
            )
            let pipeline = PermissionPipeline(
                permissions: handle,
                yoloPinReason: resolved.yoloPinReason
            )
            let mode = LiveSessionPermissionMode(pipeline: pipeline, resolved: resolved)
            let gateway = ACPNotificationGateway()
            let router = LiveACPInboundNotifications.build(
                permissionMode: mode,
                permissions: handle,
                swarmMode: LiveSwarmModeState(),
                gateway: gateway
            )
            let served = try await ServedRuntime.start(secret: "perm-secret") {
                let runtime = ACPAgentRuntime(extensionNotifications: router)
                await gateway.attach(runtime)
                return runtime
            }
            try await served.initialize()
            return Fixture(handle: handle, mode: mode, served: served)
        }
    }

    @Test("yolo_mode_changed lands on the pipeline's PermissionHandle, both directions")
    func yoloReachesLiveHandle() async throws {
        let fixture = try await Fixture.start()
        defer { Task { await fixture.served.stop() } }

        #expect(await fixture.handle.yoloMode == false)
        try await fixture.served.client.send(.notification(
            method: "x.ai/yolo_mode_changed",
            params: .object(["yolo_mode": .bool(true), "permission_mode": .string("always-approve")])
        ))
        #expect(await pollUntil { await fixture.handle.yoloMode })
        // The display handle moved WITH the pipeline — no drift between the
        // composer flag and the gate the next tool call consults.
        #expect(await fixture.mode.permissionModeLabel() == "always-approve")

        try await fixture.served.client.send(.notification(
            method: "x.ai/yolo_mode_changed",
            params: .object(["yolo_mode": .bool(false), "permission_mode": .string("ask")])
        ))
        #expect(await pollUntil { await !fixture.handle.yoloMode })
        #expect(await fixture.mode.permissionModeLabel() == "ask")
    }

    @Test("a pinned enable is refused: the pin's veto survives the inbound arm")
    func yoloEnableRefusedUnderPin() async throws {
        let fixture = try await Fixture.start(
            resolved: ResolvedPermissions(yoloPinReason: "always-approve is disabled by managed policy")
        )
        defer { Task { await fixture.served.stop() } }

        try await fixture.served.client.send(.notification(
            method: "x.ai/yolo_mode_changed",
            params: .object(["yolo_mode": .bool(true)])
        ))
        // No acknowledgement exists to await; give the arm time to (wrongly)
        // apply before asserting it did not.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(await fixture.handle.yoloMode == false)
        #expect(await fixture.mode.permissionModeLabel() == "ask")
    }

    @Test("permission_mode auto sets the live auto flag and clears it on explicit false")
    func autoModeReachesLiveHandle() async throws {
        let fixture = try await Fixture.start()
        defer { Task { await fixture.served.stop() } }

        try await fixture.served.client.send(.notification(
            method: "x.ai/yolo_mode_changed",
            params: .object(["permission_mode": .string("auto")])
        ))
        #expect(await pollUntil { await fixture.handle.autoMode })
        #expect(await fixture.handle.yoloMode == false)

        try await fixture.served.client.send(.notification(
            method: "x.ai/yolo_mode_changed",
            params: .object(["auto_mode": .bool(false)])
        ))
        #expect(await pollUntil { await !fixture.handle.autoMode })
    }

    @Test("permissions/reset clears session grants, bash prefixes, and the session edit allow")
    func permissionsResetClearsLiveState() async throws {
        let fixture = try await Fixture.start()
        defer { Task { await fixture.served.stop() } }

        await fixture.handle.grant(SessionGrant(
            access: .bash("git status"),
            scope: .session,
            pattern: "git *"
        ))
        await fixture.handle.grant(SessionGrant(access: .edit("/tmp/a.txt"), scope: .session))
        #expect(await fixture.handle.sessionGrants.count == 2)
        #expect(await fixture.handle.allowEditsForSession)
        #expect(await fixture.handle.bashPrefixGrants == ["git *"])

        try await fixture.served.client.send(.notification(
            method: "x.ai/permissions/reset",
            params: .object([:])
        ))
        #expect(await pollUntil { await fixture.handle.sessionGrants.isEmpty })
        #expect(await fixture.handle.bashPrefixGrants.isEmpty)
        #expect(await fixture.handle.allowEditsForSession == false)
    }
}

// MARK: - Inbound + outbound: swarm mode

@Suite("ACP swarm-mode notifications over ws://", .serialized)
struct ACPSwarmModeNotificationTests {
    @Test("swarm_mode_changed reaches the E8 tracker and broadcasts SwarmModeChanged both ways")
    func swarmModeRoundTrip() async throws {
        let swarm = LiveSwarmModeState()
        let gateway = ACPNotificationGateway()
        let router = LiveACPInboundNotifications.build(
            permissionMode: nil,
            permissions: nil,
            swarmMode: swarm,
            gateway: gateway
        )
        let store = InMemoryACPSessionStore()
        let served = try await ServedRuntime.start(secret: "swarm-secret") {
            let runtime = ACPAgentRuntime(store: store, extensionNotifications: router)
            await gateway.attach(runtime)
            return runtime
        }
        defer { Task { await served.stop() } }
        try await served.initialize()
        let sessionId = try await served.newSession(cwd: FileManager.default.temporaryDirectory.path)

        func notifySwarm(sessionId: String, enabled: Bool, trigger: String) async throws {
            try await served.client.send(.notification(
                method: "x.ai/swarm_mode_changed",
                params: .object([
                    "sessionId": .string(sessionId),
                    "enabled": .bool(enabled),
                    "trigger": .string(trigger),
                ])
            ))
        }

        func nextSessionNotification() async throws -> (sessionId: String, update: JSONValue, meta: JSONValue?) {
            let frame = try await wsDrain(served.client) {
                $0.method == "x.ai/session_notification"
            }
            guard case .notification(_, let params) = frame,
                  let sid = params["sessionId"]?.stringValue,
                  let update = params["update"] else {
                throw ACPTransportError.invalidMessage("malformed session notification: \(frame)")
            }
            return (sid, update, params["_meta"])
        }

        // An unknown session is dropped whole — upstream only applies to a
        // session the agent holds (acp_agent.rs:4564-4568).
        try await notifySwarm(sessionId: "nope", enabled: true, trigger: "manual")
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(await swarm.enabled == false)

        // Enable manual: the tracker turns on and the broadcast carries the
        // EFFECTIVE trigger (reminders.rs:563-577).
        try await notifySwarm(sessionId: sessionId, enabled: true, trigger: "manual")
        let enabled = try await nextSessionNotification()
        #expect(enabled.sessionId == sessionId)
        #expect(enabled.update["sessionUpdate"]?.stringValue == "swarm_mode_changed")
        #expect(enabled.update["enabled"]?.boolValue == true)
        #expect(enabled.update["trigger"]?.stringValue == "manual")
        #expect(enabled.meta?["eventId"]?.stringValue?.hasPrefix("\(sessionId)-") == true)
        #expect(await swarm.enabled)
        #expect(await swarm.currentTrigger == .manual)

        // A task disable must NOT kill a manual entry (run_loop.rs:1124-1127)
        // and must not broadcast; the manual disable that follows exits and
        // broadcasts enabled:false with an explicit null trigger — receiving
        // it as the NEXT frame proves the task arm stayed silent.
        try await notifySwarm(sessionId: sessionId, enabled: false, trigger: "task")
        try await notifySwarm(sessionId: sessionId, enabled: false, trigger: "manual")
        let disabled = try await nextSessionNotification()
        #expect(disabled.update["enabled"]?.boolValue == false)
        #expect(disabled.update["trigger"] == JSONValue.null)
        #expect(await swarm.enabled == false)

        // Disabling an already-off mode broadcasts nothing
        // (run_loop.rs:1132-1136): the next frame is the task ENABLE.
        try await notifySwarm(sessionId: sessionId, enabled: false, trigger: "manual")
        try await notifySwarm(sessionId: sessionId, enabled: true, trigger: "task")
        let reEnabled = try await nextSessionNotification()
        #expect(reEnabled.update["enabled"]?.boolValue == true)
        #expect(reEnabled.update["trigger"]?.stringValue == "task")
        #expect(await swarm.currentTrigger == .task)
    }
}

// MARK: - Outbound: prompt_complete

/// Switches the turn outcome on the prompt text so one served runtime can
/// exercise all three `prompt_complete_fields` arms.
private struct OutcomeSwitchingPromptDriver: ACPPromptDriver {
    func run(
        context: ACPPromptContext,
        emit: @escaping @Sendable (SessionNotification, ACPNotificationDisposition) async -> Void
    ) async throws -> PromptResponse {
        let text = context.request.prompt.compactMap { block -> String? in
            guard case .text(let value) = block else { return nil }
            return value.text
        }.joined()
        switch text {
        case "fail":
            throw AcpError(
                code: .internalError,
                message: "Internal error",
                data: .object(["message": .string("model exploded")])
            )
        case "limit":
            // Upstream's RATE_LIMITED_ERROR_CODE (sampling/error.rs:19).
            throw AcpError(code: .other(-32003), message: "Rate limited")
        default:
            return PromptResponse(stopReason: .endTurn)
        }
    }

    func cancel(sessionId: AcpSessionId) async {}
}

@Suite("x.ai/session/prompt_complete over ws://", .serialized)
struct ACPPromptCompleteTests {
    @Test("prompt_complete fires at turn end with upstream's payload, all three arms")
    func promptCompletePayloads() async throws {
        let served = try await ServedRuntime.start(secret: "pc-secret") {
            ACPAgentRuntime(promptDriver: OutcomeSwitchingPromptDriver())
        }
        defer { Task { await served.stop() } }
        try await served.initialize()
        let sessionId = try await served.newSession(cwd: FileManager.default.temporaryDirectory.path)

        func prompt(id: Int64, text: String, meta: JSONValue? = nil) async throws {
            var params: [String: JSONValue] = [
                "sessionId": .string(sessionId),
                "prompt": .array([.object(["type": .string("text"), "text": .string(text)])]),
            ]
            if let meta { params["_meta"] = meta }
            try await served.client.send(.request(
                id: .number(id),
                method: AgentMethodNames.sessionPrompt,
                params: .object(params)
            ))
        }

        func nextPromptComplete() async throws -> JSONValue {
            let frame = try await wsDrain(served.client) {
                $0.method == "x.ai/session/prompt_complete"
            }
            guard case .notification(_, let params) = frame else {
                throw ACPTransportError.invalidMessage("malformed prompt_complete: \(frame)")
            }
            return params
        }

        // Ok arm: the client's promptId/turnId ride through
        // (acp_agent.rs:2671-2677, 2960-2974) and the pair is
        // ("end_turn", null) — prompt_complete_fields' Ok arm.
        try await prompt(
            id: 3,
            text: "ok",
            meta: .object(["promptId": .string("p-1"), "turnId": .number(.int64(7))])
        )
        let ok = try await nextPromptComplete()
        #expect(ok["sessionId"]?.stringValue == sessionId)
        #expect(ok["promptId"]?.stringValue == "p-1")
        #expect(ok["stopReason"]?.stringValue == "end_turn")
        #expect(ok["agentResult"] == JSONValue.null)
        #expect(ok["turnId"]?.int64Value == 7)
        _ = try await wsDrain(served.client) { $0.id == .number(3) }

        // Error arm: ("error", data.message) — error_message_from_data
        // prefers the data's message field (sampling/error.rs:236-238).
        // No meta: promptId is generated, turnId absent.
        try await prompt(id: 4, text: "fail")
        let failed = try await nextPromptComplete()
        #expect(failed["stopReason"]?.stringValue == "error")
        #expect(failed["agentResult"]?.stringValue == "model exploded")
        #expect(failed["promptId"]?.stringValue?.isEmpty == false)
        #expect(failed["turnId"] == nil)
        let failedResponse = try await wsDrain(served.client) { $0.id == .number(4) }
        guard case .response(_, .object(let responseObject)?, nil) = failedResponse else {
            Issue.record("prompt 4 must still answer (flattened refusal): \(failedResponse)")
            return
        }
        // The response keeps this runtime's pre-existing flattening; the
        // broadcast is where the error detail must be told.
        #expect(responseObject["stopReason"]?.stringValue == "refusal")

        // Rate-limit arm: ("rate_limit", null) so the client shows its own
        // upgrade copy (sampling/error.rs:316-320).
        try await prompt(id: 5, text: "limit")
        let limited = try await nextPromptComplete()
        #expect(limited["stopReason"]?.stringValue == "rate_limit")
        #expect(limited["agentResult"] == JSONValue.null)
        _ = try await wsDrain(served.client) { $0.id == .number(5) }
    }
}

// MARK: - x.ai/recap

@Suite("x.ai/recap over ws://", .serialized)
struct ACPRecapNotificationTests {
    /// A production coordinator over a recording inference transport — the
    /// same construction the credential-family ws test uses, so the recap's
    /// model call is the request the shipping sampler forms.
    private struct RecapStack {
        let store: LiveModelCatalogStore
        let coordinator: LiveModelSwitchCoordinator
        let inferenceTransport: MockHTTPTransport
        let home: URL
        let environment: [String: String]

        init(
            home: URL,
            environment: [String: String],
            responses: [MockHTTPTransport.ScriptedResponse]
        ) async throws {
            self.home = home
            self.environment = environment
            try storeProviderAPIKey(
                grokHome: home,
                provider: ModelProvider.fireworks.asString,
                apiKey: "fw-recap"
            )
            let store = LiveModelCatalogStore(
                input: .default,
                environment: environment,
                openGrokHome: home,
                transport: MockHTTPTransport(responses: [])
            )
            let resolver = LiveModelCatalogResolver(
                environment: environment,
                openGrokHome: home,
                sessionID: "acp-recap-e2e",
                workingDirectory: home,
                catalogSource: { store.snapshot() },
                makeCredentialResolver: { environment, openGrokHome in
                    LiveCredentialResolver(environment: environment, openGrokHome: openGrokHome)
                }
            )
            let inferenceTransport = MockHTTPTransport(responses: responses)
            let makeSampler: @Sendable (OpenGrokLiveSamplingConfiguration) throws -> OpenGrokLiveSampler = { configuration in
                try OpenGrokLiveSampler.production(configuration: OpenGrokLiveSamplingConfiguration(
                    model: configuration.model,
                    baseURL: configuration.baseURL,
                    apiKey: configuration.apiKey,
                    provider: configuration.provider,
                    apiBackend: configuration.apiBackend,
                    extraHeaders: configuration.extraHeaders,
                    queryParams: configuration.queryParams,
                    tuning: configuration.tuning,
                    bearerResolver: configuration.bearerResolver,
                    credentialProvider: configuration.credentialProvider,
                    transport: inferenceTransport
                ))
            }
            let initial = try await resolver.resolve(modelID: "glm-5.2")
            self.store = store
            self.inferenceTransport = inferenceTransport
            self.coordinator = LiveModelSwitchCoordinator(
                sampling: initial.sampling,
                sampler: try makeSampler(initial.sampling),
                resolver: resolver,
                makeSampler: makeSampler,
                history: nil
            )
        }
    }

    private func handler(
        stack: RecapStack,
        gateway: ACPNotificationGateway,
        conversation: [ConversationItem],
        environment: [String: String]? = nil
    ) -> LiveRecapACPHandler {
        let coordinator = stack.coordinator
        return LiveRecapACPHandler(
            gateway: gateway,
            conversation: { conversation },
            recapRoute: { explicit in
                await coordinator.auxiliaryRecapRoute(explicitModelID: explicit)
            },
            workingDirectory: stack.home,
            openGrokHome: stack.home,
            environment: environment ?? stack.environment
        )
    }

    @Test("recap acks {ok:true} then delivers SessionRecap with the cleaned summary")
    func recapAcksThenDelivers() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = pinnedEnvironment(home: home)
        let stack = try await RecapStack(
            home: home,
            environment: environment,
            responses: [sseResponse(text: "We wired the ACP notification gateway end to end.")]
        )
        let gateway = ACPNotificationGateway()
        let recap = handler(
            stack: stack,
            gateway: gateway,
            conversation: [.user("hello"), .assistant("hi there")]
        )
        let router = LiveACPExtensionRouter.build(
            feedback: nil,
            models: LiveModelsACPHandler(catalogStore: stack.store, modelSwitch: stack.coordinator),
            recap: recap
        )
        let served = try await ServedRuntime.start(secret: "recap-secret") {
            let runtime = ACPAgentRuntime(extensionRouter: router)
            await gateway.attach(runtime)
            return runtime
        }
        defer { Task { await served.stop() } }
        try await served.initialize()
        let sessionId = try await served.newSession(cwd: home.path)

        // Unknown session first: upstream's invalid-params refusal
        // (recap.rs:45-49), and no model call may leave the process.
        try await served.client.send(.request(
            id: .number(9),
            method: "x.ai/recap",
            params: .object(["sessionId": .string("nope")])
        ))
        let refused = try await wsDrain(served.client) { $0.id == .number(9) }
        guard case .response(_, nil, let error?) = refused else {
            Issue.record("unknown session must refuse: \(refused)")
            return
        }
        #expect(error.code == .invalidParams)
        #expect(error.message == "Invalid params")
        #expect(error.data == .string("session not found: nope"))
        #expect(stack.inferenceTransport.recordedRequests.isEmpty)

        // The real request: ack, then the async SessionRecap notification
        // (recap.rs:51-57 → recap.rs:497-506). The generation Task races the
        // ack write, so the two frames are collected order-insensitively.
        try await served.client.send(.request(
            id: .number(10),
            method: "x.ai/recap",
            params: .object(["sessionId": .string(sessionId)])
        ))
        var ackObject: [String: JSONValue]?
        var recapParams: JSONValue?
        for _ in 0..<40 {
            let message = try await served.client.receive()
            if case .response(let id, .object(let object)?, nil) = message, id == .number(10) {
                ackObject = object
            }
            if case .notification("x.ai/session_notification", let notificationParams) = message {
                recapParams = notificationParams
            }
            if ackObject != nil, recapParams != nil { break }
        }
        let ack = try #require(ackObject, "recap must ack")
        #expect(ack["result"]?["ok"]?.boolValue == true)
        #expect(ack["result"]?["disabled"] == nil)

        let params = try #require(recapParams, "recap must deliver the SessionRecap notification")
        #expect(params["sessionId"]?.stringValue == sessionId)
        let update = params["update"]
        #expect(update?["sessionUpdate"]?.stringValue == "session_recap")
        #expect(update?["summary"]?.stringValue == "We wired the ACP notification gateway end to end.")
        #expect(update?["auto"]?.boolValue == false)
        #expect(params["_meta"]?["eventId"]?.stringValue?.hasPrefix("\(sessionId)-") == true)
        // Exactly one model call, carrying the stored key the production
        // resolver released.
        #expect(stack.inferenceTransport.recordedRequests.count == 1)
        let request = try #require(stack.inferenceTransport.recordedRequests.first)
        #expect(request.headers["Authorization"] == "Bearer fw-recap")
    }

    @Test("the feature gate acks {ok:true, disabled:true} and samples nothing")
    func recapDisabled() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = pinnedEnvironment(home: home, extra: ["GROK_SESSION_RECAP": "0"])
        let stack = try await RecapStack(home: home, environment: environment, responses: [])
        let gateway = ACPNotificationGateway()
        let recap = handler(stack: stack, gateway: gateway, conversation: [.user("hello")])
        let runtime = ACPAgentRuntime(
            extensionRouter: LiveACPExtensionRouter.build(
                feedback: nil,
                models: LiveModelsACPHandler(catalogStore: stack.store, modelSwitch: nil),
                recap: recap
            )
        )
        await gateway.attach(runtime)
        _ = await runtime.handle(.request(
            id: .string("init"),
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
        ))
        let output = await runtime.handle(.request(
            id: .string("r1"),
            method: "x.ai/recap",
            params: .object(["sessionId": .string("any")])
        ))
        guard case .response(_, .object(let object)?, nil) = output[0] else {
            Issue.record("disabled recap must still ack: \(output)")
            return
        }
        // The gate answers BEFORE the session lookup (recap.rs:36-39), so an
        // unknown session id still acks here.
        #expect(object["result"]?["ok"]?.boolValue == true)
        #expect(object["result"]?["disabled"]?.boolValue == true)
        #expect(stack.inferenceTransport.recordedRequests.isEmpty)
    }

    @Test("a manual recap over an empty conversation delivers SessionRecapUnavailable")
    func recapEmptyConversationUnavailable() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = pinnedEnvironment(home: home)
        let stack = try await RecapStack(home: home, environment: environment, responses: [])
        let gateway = ACPNotificationGateway()
        let recap = handler(stack: stack, gateway: gateway, conversation: [])
        let runtime = ACPAgentRuntime(
            store: InMemoryACPSessionStore(),
            extensionRouter: LiveACPExtensionRouter.build(
                feedback: nil,
                models: LiveModelsACPHandler(catalogStore: stack.store, modelSwitch: nil),
                recap: recap
            ),
            makeSessionId: { "recap-empty" }
        )
        await gateway.attach(runtime)
        _ = await runtime.handle(.request(
            id: .string("init"),
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
        ))
        _ = await runtime.handle(.request(
            id: .string("new"),
            method: AgentMethodNames.sessionNew,
            params: try JSONValue.encode(NewSessionRequest(cwd: home.path))
        ))
        let output = await runtime.handle(.request(
            id: .string("r1"),
            method: "x.ai/recap",
            params: .object(["sessionId": .string("recap-empty")])
        ))
        guard case .response(_, .object(let object)?, nil) = output[0] else {
            Issue.record("recap must ack: \(output)")
            return
        }
        #expect(object["result"]?["ok"]?.boolValue == true)

        // The unavailable signal rides the runtime's own notification queue —
        // the same channel a carrier's sink drains (recap_gate's manual arm,
        // session_recap.rs:232-241 → emit_recap_unavailable).
        var unavailable: JSONValue?
        for _ in 0..<100 {
            let queued = await runtime.pollNotifications()
            if let match = queued.first(where: { $0.method == "x.ai/session_notification" }) {
                unavailable = match.params
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let params = try #require(unavailable)
        #expect(params["update"]?["sessionUpdate"]?.stringValue == "session_recap_unavailable")
        #expect(stack.inferenceTransport.recordedRequests.isEmpty)
    }
}

// MARK: - SubagentMessage

@Suite("SubagentMessage over ws://", .serialized)
struct ACPSubagentMessageNotificationTests {
    @Test("an accepted mailbox send emits SubagentMessage with upstream's payload")
    func mailboxSendEmitsSubagentMessage() async throws {
        let coordinator = OpenGrokAgentCoordinator()
        let gateway = ACPNotificationGateway()
        // The identical observer wiring `liveACPServices` installs (through
        // `LiveSubagentHost.installAgentMessageObserver`), pointed at the
        // same gateway type — the payload and the channel are the live ones.
        await coordinator.installAgentMessageObserver { message, status in
            let update = LiveXaiSessionUpdates.subagentMessage(message, status: status)
            let rootSessionID = message.teamScopeID
            Task {
                await gateway.sendXaiSessionUpdate(sessionID: rootSessionID, update: update)
            }
        }
        let served = try await ServedRuntime.start(secret: "mailbox-secret") {
            let runtime = ACPAgentRuntime()
            await gateway.attach(runtime)
            return runtime
        }
        defer { Task { await served.stop() } }
        try await served.initialize()

        // A child-to-root message with no parked waiter queues — status
        // "queued", the observer fires on the accepted send
        // (sendAgentMessage → onAgentMessage; upstream coordinator.rs:637-700).
        let identity = AgentMailboxIdentity(teamScopeID: "root-1", agentID: "child-a")
        let output = try await coordinator.sendAgentMessage(
            identity: identity,
            target: "root",
            message: AgentMailboxMessage(
                messageID: "msg-1",
                teamScopeID: "root-1",
                fromAgentID: "child-a",
                toAgentID: "",
                kind: .message,
                body: "Please verify the parser edge case.",
                createdAtMS: 42
            )
        )
        #expect(output.status == .queued)

        let frame = try await wsDrain(served.client) { $0.method == "x.ai/session_notification" }
        guard case .notification(_, let params) = frame else {
            Issue.record("expected session notification, got \(frame)")
            return
        }
        // Emitted on the ROOT session's channel (team_scope_id), the payload
        // field-for-field from SessionUpdate::SubagentMessage
        // (notification.rs:749-760).
        #expect(params["sessionId"]?.stringValue == "root-1")
        let update = params["update"]
        #expect(update?["sessionUpdate"]?.stringValue == "subagent_message")
        #expect(update?["message_id"]?.stringValue == "msg-1")
        #expect(update?["team_scope_id"]?.stringValue == "root-1")
        #expect(update?["from_agent_id"]?.stringValue == "child-a")
        #expect(update?["to_agent_id"]?.stringValue == "root-1")
        #expect(update?["kind"]?.stringValue == "message")
        #expect(update?["body"]?.stringValue == "Please verify the parser edge case.")
        #expect(update?["status"]?.stringValue == "queued")
        #expect(update?["created_at_ms"]?.int64Value == 42)
    }
}

