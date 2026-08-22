import Foundation
import Testing
@testable import OpenGrokShellSessionSupport
import OpenGrokShared

@Suite("Shell session command ownership")
struct ShellSessionCommandOwnershipTests {
    @Test("commands are FIFO and only the owning actor can claim or complete them")
    func fifoAndOwnership() async throws {
        let mailbox = try SessionCommandMailbox(sessionID: SessionID("session-1"), ownerID: "actor-1")
        let first = try await mailbox.enqueue(.prompt(promptID: "p1", text: "first"), owner: .client, issuedAtMS: 1)
        let second = try await mailbox.enqueue(.cancel(context: nil, preserveQueuedPrompts: true), owner: .client, issuedAtMS: 2)

        do {
            _ = try await mailbox.claimNext(by: "other-actor")
            Issue.record("an unowned actor claimed a command")
        } catch ShellSessionSupportError.commandNotOwned {
        }

        #expect(try await mailbox.claimNext(by: "actor-1") == first)
        #expect(try await mailbox.claimNext(by: "actor-1") == nil)
        try await mailbox.complete(commandID: first.commandID, by: "actor-1")
        #expect(try await mailbox.claimNext(by: "actor-1") == second)
        let snapshot = await mailbox.snapshot()
        #expect(snapshot.queued.isEmpty)
        #expect(snapshot.inFlight?.commandID == second.commandID)
        #expect(snapshot.completedCommandIDs == [first.commandID])
    }

    @Test("cancelled queued commands never become in flight")
    func cancellationRemovesQueuedCommand() async throws {
        let mailbox = try SessionCommandMailbox(sessionID: SessionID("session-2"), ownerID: "actor")
        let command = try await mailbox.enqueue(.flush, owner: .system, issuedAtMS: 5)
        #expect(try await mailbox.cancel(commandID: command.commandID, by: "actor"))
        #expect(try await mailbox.claimNext(by: "actor") == nil)
        #expect(await mailbox.snapshot().cancelledCommandIDs == [command.commandID])
    }
}

@Suite("Shell session wire and transcript projection")
struct ShellSessionTranscriptTests {
    @Test("session updates preserve the ACP envelope and project deterministic transcript fields")
    func wireAndProjection() throws {
        let updates: [SessionUpdate] = [
            .acp(params(update: [
                "sessionUpdate": .string("user_message_chunk"),
                "content": .object(["type": .string("text"), "text": .string("hello ")])
            ])),
            .acp(params(update: [
                "sessionUpdate": .string("user_message_chunk"),
                "content": .object(["type": .string("text"), "text": .string("world")]),
                "_meta": .object(["promptIndex": .number(.uint64(0))])
            ])),
            .acp(params(update: [
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object(["type": .string("text"), "text": .string("answer")])
            ])),
            .acp(params(update: [
                "sessionUpdate": .string("tool_call"),
                "title": .string("Read file"),
                "locations": .array([.object(["path": .string("/tmp/example.swift")])])
            ])),
            .acp(params(update: [
                "sessionUpdate": .string("rewind_marker"),
                "target_prompt_index": .number(.uint64(0))
            ]))
        ]

        let encoded = try JSONEncoder().encode(updates[0])
        let decoded = try JSONDecoder().decode(SessionUpdate.self, from: encoded)
        #expect(decoded == updates[0])

        let projection = SessionTranscriptProjector.project(updates)
        #expect(projection.prompts.isEmpty)
        #expect(projection.assistantMessages == ["answer"])
        #expect(projection.toolMetadata == ["Read file", "/tmp/example.swift"])
        #expect(projection.malformedUpdateCount == 0)
        #expect(projection.events.contains(.toolCall(title: "Read file", paths: ["/tmp/example.swift"])))
    }

    @Test("durable Rust turn_completed terminals replay without being classified as malformed")
    func durableTurnCompletedProjection() {
        let updates: [SessionUpdate] = [
            .acp(params(update: [
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object(["type": .string("text"), "text": .string("answer")])
            ])),
            .xai(params(update: [
                "sessionUpdate": .string("turn_completed"),
                "prompt_id": .string("prompt-completed"),
                "stop_reason": .string("end_turn"),
                "agent_result": .string("answer")
            ])),
            .xai(params(update: [
                "sessionUpdate": .string("turn_completed"),
                "prompt_id": .string("prompt-cancelled"),
                "stop_reason": .string("cancelled")
            ])),
            .xai(params(update: [
                "sessionUpdate": .string("turn_completed"),
                "prompt_id": .string("prompt-limited"),
                "stop_reason": .string("max_turns_reached"),
                "limit": .number(.uint64(3))
            ]))
        ]

        let projection = SessionTranscriptProjector.project(updates)
        #expect(projection.assistantMessages == ["answer"])
        #expect(projection.malformedUpdateCount == 0)
        #expect(projection.events.contains(.turnCompleted(kind: .completed)))
        #expect(projection.events.contains(.turnCompleted(
            kind: .cancelled(category: nil, context: nil)
        )))
        #expect(projection.events.contains(.turnCompleted(kind: .maxTurnsReached(limit: 3))))
    }

    @Test("durable turn terminals reject malformed or ACP-routed terminal payloads")
    func malformedDurableTurnCompletedProjection() {
        let projection = SessionTranscriptProjector.project([
            .xai(params(update: [
                "sessionUpdate": .string("turn_completed"),
                "stop_reason": .string("cancelled")
            ])),
            .acp(params(update: [
                "sessionUpdate": .string("turn_completed"),
                "prompt_id": .string("wrong-rail"),
                "stop_reason": .string("end_turn")
            ])),
            .acp(params(update: ["sessionUpdate": .string("turn_complete")]))
        ])

        #expect(projection.malformedUpdateCount == 2)
        #expect(projection.events.isEmpty)
    }

    @Test("host turns, bash prompts, malformed payloads, and unmarked updates terminate prompt runs")
    func conservativePromptProjection() {
        let events: [PromptExtractEvent] = [
            .userTextChunk(text: "kept", promptIndex: 0),
            .userTextChunk(text: "hidden bash", promptIndex: 1),
            .notUserMessage,
            .userTextChunk(text: "tail", promptIndex: 2),
            .rewind(toPromptIndex: 1)
        ]
        #expect(SessionTranscriptProjector.collectPrompts(from: events) == ["kept"])

        let projection = SessionTranscriptProjector.project([
            .acp(params(update: [
                "sessionUpdate": .string("user_message_chunk"),
                "content": .object([
                    "type": .string("text"),
                    "text": .string("not persisted"),
                    "_meta": .object(["bash_command": .string("echo no")])
                ])
            ])),
            .acp(params(update: ["sessionUpdate": .string("invalid_without_content")])),
            .acp(.string("not an object"))
        ])
        #expect(projection.prompts.isEmpty)
        #expect(projection.malformedUpdateCount == 2)
    }

    private func params(update: [String: JSONValue]) -> JSONValue {
        .object(["update": .object(update)])
    }
}

@Suite("Shell session interruption and persistence")
struct ShellSessionRecoveryTests {
    @Test("dead process recovery replays queued commands in sequence order")
    func deadProcessRecoveryReplaysQueuedCommands() async throws {
        let mailbox = try SessionCommandMailbox(sessionID: SessionID("recoverable"), ownerID: "actor")
        let first = try await mailbox.enqueue(.flush, owner: .client, issuedAtMS: 1)
        let second = try await mailbox.enqueue(.shutdown, owner: .system, issuedAtMS: 2)
        let recovery = SessionRecoveryState(
            status: .interrupted,
            interruption: SessionInterruption(trigger: .processExit, interruptedAtMS: 9),
            recoveryGeneration: 3,
            lastCompletedSequence: 0
        )
        let plan = SessionRecoveryPlanner.plan(recovery: recovery, mailbox: await mailbox.snapshot(), processWasAlive: false)
        #expect(plan.decision == .resume)
        #expect(plan.commandsToReplay.map(\.commandID) == [first.commandID, second.commandID])
        #expect(plan.state.status == .recoverable)
        #expect(plan.state.recoveryGeneration == 4)
    }

    @Test("state store uses the injected Open Grok home and round trips DTOs")
    func stateStoreUsesInjectedHomeAndRoundTripsDTOs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = SessionID("persisted")
        let summary = SessionSummary(sessionID: sessionID, cwd: "/work/project", currentModelID: "grok-test")
        let state = PersistedSessionState(
            summary: summary,
            chatHistory: [.string("hello")],
            updates: [try SessionUpdateEnvelope(method: "session/update", params: .object(["ok": .bool(true)]))],
            transcript: SessionTranscript().appending(event: .phaseChanged(.idle), timestampMS: 10),
            recovery: SessionRecoveryState(status: .clean)
        )
        let store = SessionStateStore(root: root)
        try await store.save(state)
        #expect(try await store.load(sessionID: sessionID) == state)
        #expect(try await store.load(sessionID: SessionID("missing")) == nil)
    }

    @Test("corrupt active-session data is treated as recoverable empty state")
    func corruptActiveSessionDataIsRecoverable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: root.appendingPathComponent(ActiveSessionRegistry.dataFileName))
        let registry = ActiveSessionRegistry(root: root)
        try await registry.load()
        #expect(try await registry.list().isEmpty)
        try await registry.register(ActiveSessionRecord(sessionID: SessionID("live"), pid: 10, cwd: "/tmp"))
        try await registry.register(ActiveSessionRecord(sessionID: SessionID("live"), pid: 10, cwd: "/tmp"))
        #expect(try await registry.list().count == 1)
        #expect(try await registry.collectCrashed(alivePIDs: []).map(\.sessionID.rawValue) == ["live"])
    }
}

@Suite("Managed MCP session support")
struct ManagedMcpSessionTests {
    @Test("managed naming, URL matching, and header replacement follow the Rust policy")
    func managedPolicy() {
        #expect(ManagedMcpState.toManagedName("My Server") == "grok_com_my_server")
        #expect(ManagedMcpState.normalizeURL("https://proxy.example/") == "https://proxy.example")
        let config = ManagedMcpConfig(
            name: "Slack",
            endpoint: "https://proxy.example/",
            headers: ["Authorization": "Bearer fresh", "X-Token": "token"]
        )
        #expect(ManagedMcpState.shouldInjectManagedAuth(serverName: "grok_com_slack", serverURL: "https://proxy.example", managed: [config]))
        let headers = ManagedMcpState.injectedHeaders(
            serverName: "grok_com_slack",
            serverURL: "https://proxy.example/",
            existing: ["authorization": "Bearer stale", "X-Connector-Scope": "workspace", "Accept": "application/json"],
            managed: [config]
        )
        #expect(headers["Authorization"] == "Bearer fresh")
        #expect(headers["Accept"] == "application/json")
        #expect(headers["X-Connector-Scope"] == nil)
    }

    @Test("gateway epochs reject stale fetches and reauth cooldowns become terminal")
    func gatewayEpochsAndReauthCooldowns() async throws {
        let state = ManagedMcpState()
        let epoch = await state.enableGatewayTools()
        #expect(await state.startGatewayToolFetch() == epoch)
        await state.disableGatewayTools()
        #expect(await state.completeGatewayToolFetch(epoch: epoch, catalog: GatewayToolCatalog()) == false)
        #expect(await state.snapshot().gatewayToolsActive == false)

        let now = Date(timeIntervalSince1970: 0)
        #expect(await state.reauthAllowed(server: "slack", now: now))
        await state.recordReauthFailure(server: "slack", now: now)
        await state.recordReauthFailure(server: "slack", now: now)
        await state.recordReauthFailure(server: "slack", now: now)
        #expect(await state.reauthIsTerminal(server: "slack"))
        #expect(await state.reauthAllowed(server: "slack", now: now) == false)
        await state.recordReauthSuccess(server: "slack")
        #expect(await state.reauthAllowed(server: "slack", now: now))
    }
}

@Suite("Shell session continuation and tool history")
struct ShellSessionContinuationAndHistoryTests {
    @Test("continuations complete exactly once and require the owning actor")
    func continuationOwnershipAndExactlyOnceCompletion() async throws {
        let registry = try SessionContinuationRegistry(sessionID: SessionID("continuations"), ownerID: "actor")
        let continuation = try await registry.register(
            continuationID: "continuation-1",
            commandID: "command-1",
            issuedAtMS: 4
        )
        #expect(continuation.sessionID == SessionID("continuations"))

        do {
            try await registry.complete(continuationID: continuation.continuationID, by: "other")
            Issue.record("an unowned actor completed a continuation")
        } catch ShellSessionSupportError.commandNotOwned {
        }

        try await registry.complete(continuationID: continuation.continuationID, by: "actor")
        do {
            try await registry.complete(continuationID: continuation.continuationID, by: "actor")
            Issue.record("a continuation completed twice")
        } catch ShellSessionSupportError.commandAlreadyCompleted {
        }
        #expect(await registry.snapshot().completedContinuationIDs == ["continuation-1"])
    }

    @Test("tool history projects isolated views and redacts export data")
    func toolHistoryViewsAndRedaction() async throws {
        let sink = SessionToolHistorySink()
        let modelEntry = try await sink.record(
            entryID: "entry-1",
            timestampMS: 1,
            toolCallID: "call-1",
            title: "Read file",
            paths: ["/tmp/example.swift"],
            input: .object(["path": .string("/tmp/example.swift")]),
            views: [.modelVisible, .durableReplay, .liveUI]
        )
        _ = try await sink.record(
            entryID: "entry-2",
            timestampMS: 2,
            toolCallID: "call-2",
            parentToolCallID: "call-1",
            title: "Nested lookup",
            input: .string("secret"),
            views: [.nestedTool, .redactedExport]
        )

        let projection = await sink.projection()
        #expect(projection.modelVisible == [modelEntry])
        #expect(projection.durableReplay == [modelEntry])
        #expect(projection.liveUI == [modelEntry])
        #expect(projection.nestedTools.map(\.toolCallID) == ["call-2"])
        #expect(projection.redactedExport.count == 1)
        #expect(projection.redactedExport[0].isRedacted)
        #expect(projection.redactedExport[0].input == .null)
        #expect(projection.redactedExport[0].paths.isEmpty)
    }
}

@Suite("Shell session safety and managed MCP wire compatibility")
struct ShellSessionSafetyAndManagedMcpTests {
    @Test("session identifiers cannot escape the persisted Open Grok home")
    func rejectsUnsafeSessionIdentifiers() throws {
        let unsafeIDs = ["../escape", "nested/session", "C:\\escape", ".", "..", "has space"]
        for rawValue in unsafeIDs {
            do {
                _ = try SessionCommand(
                    commandID: "command",
                    sessionID: SessionID(rawValue),
                    owner: .client,
                    sequence: 0,
                    issuedAtMS: 0,
                    kind: .flush
                )
                Issue.record("unsafe session identifier was accepted: \(rawValue)")
            } catch ShellSessionSupportError.invalidSession {
            }
        }
    }

    @Test("managed MCP DTO defaults and fetch epochs are deterministic")
    func managedMcpDefaultsAndEpochs() async throws {
        let decoder = JSONDecoder()
        let config = try decoder.decode(ManagedMcpConfig.self, from: Data(#"{"endpoint":"https://proxy.example"}"#.utf8))
        #expect(config.name == "")
        #expect(config.headers.isEmpty)
        #expect(config.scope == nil)

        let catalog = try decoder.decode(
            GatewayToolCatalog.self,
            from: Data(#"{"tools":[],"connectors_needing_reauth":[]}"#.utf8)
        )
        #expect(catalog.totalTools == 0)
        #expect(catalog.tools.isEmpty)
        #expect(GatewayToolCallRequest(callID: "call", arguments: .null).arguments == .object([:]))

        let state = ManagedMcpState()
        let firstEpoch = await state.enableGatewayTools()
        #expect(await state.startGatewayToolFetch() == firstEpoch)
        #expect(await state.startGatewayToolFetch() == firstEpoch)
        #expect(await state.completeGatewayToolFetch(epoch: firstEpoch, catalog: GatewayToolCatalog()))
        #expect(await state.snapshot().gatewayToolCache == .ready(GatewayToolCatalog()))
    }

    @Test("OpenGrok home resolution honors the isolated environment override")
    func opengrokHomeResolution() {
        let home = OpenGrokHome.resolve(
            environment: ["OPENGROK_HOME": "/tmp/isolated-opengrok"],
            homeDirectory: URL(fileURLWithPath: "/tmp/ignored-home", isDirectory: true)
        )
        #expect(home.path == "/tmp/isolated-opengrok")
    }
}
