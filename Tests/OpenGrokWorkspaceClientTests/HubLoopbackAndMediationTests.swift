// HubLoopbackAndMediationTests.swift
//
// Two things these tests exist to catch, both of the "succeeds, does nothing,
// says nothing" family described in AGENTS.md §3:
//
//   1. A `WorkspaceClient` that reports success while never reaching a hub at
//      all. Every other test in this target registers the `workspace_rpc`
//      tool *locally*, which means the remote plane — encode, dispatch,
//      decode — is not exercised by any of them. `InProcessHubServer` below
//      is a real callee on the other side of `ConnectionClient`: it decodes
//      the `tool_call_request` this client actually sends and answers with a
//      real `tool_call_result`, so a break anywhere in that path fails here.
//
//   2. A mediation gate that is installed but not consulted. Each denial test
//      asserts on the *observable effect* — that the callee never saw the
//      call — not merely on the returned error, because a gate that denies
//      after dispatching has already done the damage.

import Foundation
import Testing
@testable import OpenGrokWorkspaceClient
import OpenGrokComputerHubCore
import OpenGrokComputerHubSDK
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime
import OpenGrokToolTypes
import OpenGrokWorkspaceTypes

// `OpenGrokWorkspaceTypes` is imported for `WORKSPACE_RPC_TOOL_ID` but also
// aliases `SessionId` onto `OpenGrokShared.SessionID`, which collides with the
// protocol identifier every hub API here takes. Pin the name to the one the
// hub actually uses.
fileprivate typealias SessionId = OpenGrokToolProtocol.SessionId

// MARK: - In-process hub server

/// A hub server living on the far side of `ConnectionClient`.
///
/// This is the SDK's server side as this port has it: `ConnectionClient` is
/// the only transport abstraction in the stack (there is no WebSocket
/// implementation yet), so a conformance that resolves and dispatches against
/// a real registry *is* an in-process hub. Calls arrive as the same
/// `tool_call_request` frames the wire would carry.
fileprivate final class InProcessHubServer: ConnectionClient, @unchecked Sendable {
    private let resolver: CompoundResolver
    private let sessionId: SessionId
    private let lock = NSLock()
    private var observed: [ToolId] = []

    init(resolver: CompoundResolver, sessionId: SessionId) {
        self.resolver = resolver
        self.sessionId = sessionId
    }

    /// Tool ids this server actually executed, in order. The denial tests
    /// assert this stays empty — a gate that denies *after* dispatch would
    /// still return an error and would still be a bypass.
    var executedToolIds: [ToolId] {
        lock.lock(); defer { lock.unlock() }
        return observed
    }

    private func record(_ toolId: ToolId) {
        lock.lock()
        observed.append(toolId)
        lock.unlock()
    }

    func request(
        _ request: JsonRpcRequest<JSONValue>
    ) async throws -> JsonRpcResponse<JSONValue> {
        guard request.method == Method.toolCallRequest.wireString else {
            return JsonRpcResponse(
                id: request.id,
                sessionId: request.sessionId,
                outcome: .error(JsonRpcError(code: -32601, message: "no such method"))
            )
        }
        let params = try request.params.decode(ToolCallParams.self)

        record(params.toolId)

        let stream = await resolver.resolveAndDispatch(
            sessionId: request.sessionId ?? sessionId,
            toolId: params.toolId,
            args: params.arguments,
            ctx: ToolCallContext(callId: params.toolCallId)
        )
        switch await consumeStreamTerminal(stream) {
        case .success(let typed):
            let result = ToolCallResult(
                toolCallId: params.toolCallId,
                output: .json(typed.value)
            )
            return JsonRpcResponse(
                id: request.id,
                sessionId: request.sessionId,
                outcome: .result(try JSONValue.encode(result))
            )
        case .failure(let error):
            return JsonRpcResponse(
                id: request.id,
                sessionId: request.sessionId,
                outcome: .error(JsonRpcError(
                    code: -32003,
                    message: error.detail
                ))
            )
        }
    }

    func notify(_ notification: JsonRpcNotification<JSONValue>) async throws {
        _ = notification
    }
}

// MARK: - Fixtures

/// Answers with `{"ok": {"served_by": <label>}}` so a test can tell *which*
/// registration ran, which is the whole question the shadowing tests ask.
private struct LabelledRpcTool: ToolDyn {
    let idValue: ToolId
    let label: String

    func id() -> ToolId { idValue }

    func description(ctx: ListToolsContext) -> ToolDescription {
        _ = ctx
        return ToolDescription(name: idValue.rawValue, description: "labelled")
    }

    func execute(ctx: ToolCallContext, args: JSONValue) async -> ToolStream<TypedToolOutput> {
        _ = (ctx, args)
        let envelope: JSONValue = .object([
            "ok": .object(["served_by": .string(label)]),
        ])
        return terminalOnly(.success(.fromValue(toolId: idValue, value: envelope)))
    }
}

/// Records every request it is asked to mediate, then answers with `verdict`.
private final class RecordingMediator: HubCallMediator, @unchecked Sendable {
    private let verdict: HubMediationVerdict
    private let lock = NSLock()
    private var seen: [HubCallRequest] = []

    init(verdict: HubMediationVerdict) {
        self.verdict = verdict
    }

    var requests: [HubCallRequest] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    private func record(_ request: HubCallRequest) {
        lock.lock()
        seen.append(request)
        lock.unlock()
    }

    func mediate(_ request: HubCallRequest) async -> HubMediationVerdict {
        record(request)
        return verdict
    }
}

private func rpcRegistration(
    toolId: ToolId,
    userId: UserId,
    transport: TransportKind
) -> ToolRegistration {
    ToolRegistration(
        toolId: toolId,
        userId: userId,
        description: ToolDescription(name: toolId.rawValue, description: "rpc"),
        transportKind: transport
    )
}

/// Build a client whose `workspace_rpc` resolves only on the far side of an
/// `InProcessHubServer` — nothing is registered locally, so a passing
/// assertion here proves the remote path ran.
private func makeRemoteBackedClient(
    mediation: HubMediation,
    remoteLabel: String = "remote",
    connection: HubConnection? = nil
) throws -> (client: WorkspaceClient, server: InProcessHubServer) {
    let toolId = try ToolId(WORKSPACE_RPC_TOOL_ID)
    let user = try UserId("u")
    let session = try SessionId("s")

    let serverRegistry = InMemoryToolRegistry()
    serverRegistry.register(
        sessionId: session,
        handle: ErasedTool(LabelledRpcTool(idValue: toolId, label: remoteLabel)),
        registration: rpcRegistration(toolId: toolId, userId: user, transport: .remote)
    )
    let server = InProcessHubServer(
        resolver: CompoundResolver(
            local: serverRegistry,
            mediation: .unmediated(
                reason: "server-side registry; the client-side gate is what is under test"
            )
        ),
        sessionId: session
    )

    let connection = connection ?? HubConnection(
        key: PrincipalKey(url: "loopback", userId: user),
        client: server,
        connected: true
    )
    let harness = ToolHarness(mediation: mediation)
    harness.attach(connection: connection)
    harness.bindSession(session)
    harness.setPrincipal(Principal.new(user).withScope(localInvokeScope).withSession(session))

    return (WorkspaceClient.withHubConnection(harness: harness, connection: connection), server)
}

// MARK: - Loopback

@Suite("Hub loopback through the client")
struct HubLoopbackTests {
    @Test("a remote-only tool round-trips through the in-process hub server")
    func remoteRoundTrip() async throws {
        let (client, server) = try makeRemoteBackedClient(
            mediation: .mediated(AllowAllHubMediator())
        )

        let raw = try await client.rpcRaw(method: "workspace.info", params: .object([:]))

        // Asserting the *body* the far side produced, not merely that the
        // call returned: a client that silently short-circuited would return
        // successfully too.
        guard case .object(let map) = raw, case .object(let ok) = map["ok"] else {
            Issue.record("expected {ok: {...}}, got \(raw)")
            return
        }
        #expect(ok["served_by"] == .string("remote"))
        #expect(server.executedToolIds.count == 1)
    }

    @Test("pool acquisition stays disconnected until the handshake activates it")
    func pooledRemoteActivation() async throws {
        let user = try UserId("u")
        let pool = HubConnectionPool()
        let connection = pool.acquire(
            key: PrincipalKey(url: "loopback", userId: user)
        )
        let (client, server) = try makeRemoteBackedClient(
            mediation: .mediated(AllowAllHubMediator()),
            connection: connection
        )
        #expect(!connection.isConnected)
        #expect(!client.isConnected)

        do {
            _ = try await client.rpcRaw(method: "workspace.info", params: .object([:]))
            Issue.record("pre-activation RPC unexpectedly succeeded")
        } catch WorkspaceClientError.notConnected {
            #expect(server.executedToolIds.isEmpty)
        } catch {
            Issue.record("expected notConnected, got \(error)")
        }

        connection.activate(client: server)
        #expect(connection.isConnected)
        #expect(client.isConnected)
        _ = try await client.rpcRaw(method: "workspace.info", params: .object([:]))
        #expect(server.executedToolIds.count == 1)
    }

    @Test("no connection and no local tool is notFound, never a fabricated success")
    func unreachableToolFails() async throws {
        let client = WorkspaceClient(
            harness: ToolHarness(
                mediation: .mediated(AllowAllHubMediator())
            )
        )
        do {
            _ = try await client.rpcRaw(method: "workspace.info", params: .object([:]))
            Issue.record("expected a failure for an unregistered tool")
        } catch let error as WorkspaceClientError {
            guard case .transport(let detail) = error else {
                Issue.record("expected .transport, got \(error)")
                return
            }
            #expect(detail.contains("not found"))
        }
    }
}

// MARK: - Local shadows remote

@Suite("Local shadows remote")
struct LocalShadowsRemoteTests {
    @Test("the harness runs the local registration when both planes offer the id")
    func harnessPrefersLocal() async throws {
        let toolId = try ToolId(WORKSPACE_RPC_TOOL_ID)
        let user = try UserId("u")
        let session = try SessionId("s")

        // Same id on both planes — the case the rule exists for.
        let serverRegistry = InMemoryToolRegistry()
        serverRegistry.register(
            sessionId: session,
            handle: ErasedTool(LabelledRpcTool(idValue: toolId, label: "remote")),
            registration: rpcRegistration(toolId: toolId, userId: user, transport: .remote)
        )
        let server = InProcessHubServer(
            resolver: CompoundResolver(
                local: serverRegistry,
                mediation: .unmediated(reason: "server-side registry; not the gate under test")
            ),
            sessionId: session
        )
        let connection = HubConnection(
            key: PrincipalKey(url: "loopback", userId: user),
            client: server,
            connected: true
        )

        let harness = ToolHarnessBuilder(mediation: .mediated(AllowAllHubMediator()))
            .withLocal(
                LabelledRpcTool(idValue: toolId, label: "local"),
                registration: rpcRegistration(toolId: toolId, userId: user, transport: .local)
            )
            .withConnection(connection)
            .withSession(session)
            .withPrincipal(Principal.new(user).withScope(localInvokeScope))
            .build()

        let raw = try await WorkspaceClient(harness: harness)
            .rpcRaw(method: "workspace.info", params: .object([:]))

        guard case .object(let map) = raw, case .object(let ok) = map["ok"] else {
            Issue.record("expected {ok: {...}}, got \(raw)")
            return
        }
        #expect(ok["served_by"] == .string("local"))
        // The decisive half: the remote plane was reachable and was still not
        // used. Without this the test would pass against a harness that had
        // simply lost its connection.
        #expect(server.executedToolIds.isEmpty)
    }

    @Test("the resolver reports local, and falls through to remote only on a miss")
    func resolverPrefersLocalAndFallsThrough() throws {
        let session = try SessionId("s")
        let user = try UserId("u")
        let shared = try ToolId("shared_tool")
        let remoteOnly = try ToolId("remote_only_tool")

        let local = InMemoryToolRegistry()
        local.register(
            sessionId: session,
            handle: ErasedTool(LabelledRpcTool(idValue: shared, label: "local")),
            registration: rpcRegistration(toolId: shared, userId: user, transport: .local)
        )
        let remote = InMemoryToolRegistry()
        for id in [shared, remoteOnly] {
            remote.register(
                sessionId: session,
                handle: ErasedTool(LabelledRpcTool(idValue: id, label: "remote")),
                registration: rpcRegistration(toolId: id, userId: user, transport: .remote)
            )
        }

        let resolver = CompoundResolver(
            local: local,
            mediation: .unmediated(reason: "resolution-only test; nothing is dispatched"),
            remote: remote
        )

        #expect(resolver.resolve(sessionId: session, toolId: shared)?.isLocal == true)
        #expect(resolver.resolve(sessionId: session, toolId: remoteOnly)?.isRemote == true)
        #expect(resolver.resolve(sessionId: session, toolId: try ToolId("absent")) == nil)
    }

    @Test("shadowing is per-session: another session still gets the remote tool")
    func shadowingIsPerSession() throws {
        let user = try UserId("u")
        let shared = try ToolId("shared_tool")
        let sessionA = try SessionId("a")
        let sessionB = try SessionId("b")

        let local = InMemoryToolRegistry()
        local.register(
            sessionId: sessionA,
            handle: ErasedTool(LabelledRpcTool(idValue: shared, label: "local")),
            registration: rpcRegistration(toolId: shared, userId: user, transport: .local)
        )
        let remote = InMemoryToolRegistry()
        for session in [sessionA, sessionB] {
            remote.register(
                sessionId: session,
                handle: ErasedTool(LabelledRpcTool(idValue: shared, label: "remote")),
                registration: rpcRegistration(toolId: shared, userId: user, transport: .remote)
            )
        }

        let resolver = CompoundResolver(
            local: local,
            mediation: .unmediated(reason: "resolution-only test; nothing is dispatched"),
            remote: remote
        )

        #expect(resolver.resolve(sessionId: sessionA, toolId: shared)?.isLocal == true)
        #expect(resolver.resolve(sessionId: sessionB, toolId: shared)?.isRemote == true)
    }
}

// MARK: - Mediation

@Suite("Hub calls pass the mediation gate")
struct HubMediationTests {
    @Test("a denied remote call never reaches the hub server")
    func deniedRemoteCallIsNotDispatched() async throws {
        let mediator = RecordingMediator(verdict: .deny(reason: "policy: mcp tool blocked"))
        let (client, server) = try makeRemoteBackedClient(mediation: .mediated(mediator))

        do {
            _ = try await client.rpcRaw(method: "workspace.info", params: .object([:]))
            Issue.record("expected the gate to deny")
        } catch let error as WorkspaceClientError {
            guard case .transport(let detail) = error else {
                Issue.record("expected .transport carrying the denial, got \(error)")
                return
            }
            #expect(detail.contains("policy: mcp tool blocked"))
        }

        // The point of the test: denial happened *before* dispatch.
        #expect(server.executedToolIds.isEmpty)
        #expect(mediator.requests.count == 1)
        #expect(mediator.requests.first?.origin == .remote)
        #expect(mediator.requests.first?.toolId.rawValue == WORKSPACE_RPC_TOOL_ID)
    }

    @Test("a denied local call never reaches the local tool")
    func deniedLocalCallIsNotDispatched() async throws {
        let toolId = try ToolId(WORKSPACE_RPC_TOOL_ID)
        let user = try UserId("u")
        let mediator = RecordingMediator(verdict: .deny(reason: "plan mode is active"))

        let harness = ToolHarnessBuilder(mediation: .mediated(mediator))
            .withLocal(
                LabelledRpcTool(idValue: toolId, label: "local"),
                registration: rpcRegistration(toolId: toolId, userId: user, transport: .local)
            )
            .withSession(try SessionId("s"))
            .withPrincipal(Principal.new(user).withScope(localInvokeScope))
            .build()

        let stream = await harness.call(toolId: toolId, args: .object([:]))
        let terminal = await consumeStreamTerminal(stream)

        guard case .failure(let error) = terminal else {
            Issue.record("expected a denial, got success")
            return
        }
        // `permissionDenied`, not `custom`: a model must not be able to tell a
        // hub-mediated denial from a local one and retry around it.
        #expect(error.kind == .permissionDenied)
        #expect(error.detail.contains("plan mode is active"))
        #expect(mediator.requests.first?.origin == .local)
    }

    @Test("the resolver's inner-dispatch path is gated too")
    func innerDispatchIsMediated() async throws {
        let session = try SessionId("s")
        let user = try UserId("u")
        let toolId = try ToolId("inner_tool")
        let mediator = RecordingMediator(verdict: .deny(reason: "no laundering through inner calls"))

        let registry = InMemoryToolRegistry()
        registry.register(
            sessionId: session,
            handle: ErasedTool(LabelledRpcTool(idValue: toolId, label: "inner")),
            registration: rpcRegistration(toolId: toolId, userId: user, transport: .local)
        )
        let resolver = CompoundResolver(local: registry, mediation: .mediated(mediator))
        let inner = InnerDispatchForResolver(resolver: resolver, sessionId: session)

        let terminal = await consumeStreamTerminal(
            await inner.call(toolId: toolId, args: .object([:]), ctx: ToolCallContext())
        )

        guard case .failure(let error) = terminal else {
            Issue.record("expected the inner call to be denied")
            return
        }
        #expect(error.kind == .permissionDenied)
        #expect(mediator.requests.count == 1)
    }

    @Test("an allowing gate is consulted, not bypassed")
    func allowingGateStillRuns() async throws {
        let mediator = RecordingMediator(verdict: .allow)
        let (client, server) = try makeRemoteBackedClient(mediation: .mediated(mediator))

        _ = try await client.rpcRaw(method: "workspace.info", params: .object([:]))

        // A gate that is installed but never called would leave this at 0
        // while every other assertion in the suite still passed.
        #expect(mediator.requests.count == 1)
        #expect(server.executedToolIds.count == 1)
    }

    @Test("DenyAllHubMediator refuses everything")
    func denyAllRefuses() async throws {
        let (client, server) = try makeRemoteBackedClient(
            mediation: .mediated(DenyAllHubMediator())
        )
        do {
            _ = try await client.rpcRaw(method: "workspace.info", params: .object([:]))
            Issue.record("expected DenyAllHubMediator to refuse")
        } catch {
            // expected
        }
        #expect(server.executedToolIds.isEmpty)
    }
}
