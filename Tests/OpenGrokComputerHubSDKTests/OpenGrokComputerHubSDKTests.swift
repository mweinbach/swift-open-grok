// OpenGrokComputerHubSDKTests.swift
import Foundation
import Testing
@testable import OpenGrokComputerHubSDK
import OpenGrokComputerHubCore
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime
import OpenGrokToolTypes

private final class ReconnectEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ReconnectEvent] = []

    func append(_ event: ReconnectEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var snapshot: [ReconnectEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}

private final class NotificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [HubNotification] = []
    func append(_ n: HubNotification) {
        lock.lock(); items.append(n); lock.unlock()
    }
    var snapshot: [HubNotification] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}

private final class TestConnectionClient: ConnectionClient, @unchecked Sendable {
    func request(
        _ request: JsonRpcRequest<JSONValue>
    ) async throws -> JsonRpcResponse<JSONValue> {
        _ = request
        throw ClientError.notConnected
    }

    func notify(_ notification: JsonRpcNotification<JSONValue>) async throws {
        _ = notification
        throw ClientError.notConnected
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func set(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }

    func modify(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&value)
    }

    var snapshot: Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@Suite("OpenGrokComputerHubSDK")
struct ComputerHubSDKTests {
    @Test("connection pool refcount")
    func poolRefcount() throws {
        let pool = HubConnectionPool()
        let key = PrincipalKey(url: "wss://hub", userId: try UserId("u"))
        let a = pool.acquire(key: key)
        let b = pool.acquire(key: key)
        #expect(a === b)
        #expect(pool.refCount(for: key) == 2)
        #expect(!a.isConnected)
        #expect(a.connectionClient() == nil)
        pool.release(key: key)
        #expect(!a.isConnected)
        #expect(pool.refCount(for: key) == 1)
        pool.release(key: key)
        #expect(!a.isConnected)
        #expect(pool.refCount(for: key) == 0)
        #expect(pool.connectionCount == 0)
    }

    @Test("reconnect ordering disconnected→reconnecting→reconnected")
    func reconnectOrdering() throws {
        let key = PrincipalKey(url: "wss://hub", userId: try UserId("u"))
        let conn = HubConnection(
            key: key,
            client: TestConnectionClient(),
            connected: true
        )
        let recorder = ReconnectEventRecorder()
        conn.onReconnect { recorder.append($0) }
        conn.runReconnectSequence(attempts: 3, succeedOn: 2, reason: "drop")
        let events = recorder.snapshot
        #expect(events.count == 4)
        #expect(events[0] == .disconnected(reason: "drop"))
        #expect(events[1] == .reconnecting(attempt: 1))
        #expect(events[2] == .reconnecting(attempt: 2))
        #expect(events[3] == .reconnected)
        #expect(conn.isConnected)
    }

    @Test("reconnect giveUp ordering")
    func reconnectGiveUp() throws {
        let key = PrincipalKey(url: "wss://hub", userId: try UserId("u"))
        let conn = HubConnection(
            key: key,
            client: TestConnectionClient(),
            connected: true
        )
        let recorder = ReconnectEventRecorder()
        conn.onReconnect { recorder.append($0) }
        conn.runReconnectSequence(attempts: 2, succeedOn: 99, reason: "net")
        let events = recorder.snapshot
        #expect(events.first == .disconnected(reason: "net"))
        #expect(events.contains(.reconnecting(attempt: 1)))
        #expect(events.contains(.reconnecting(attempt: 2)))
        #expect(events.last == .giveUp(reason: "exhausted 2 attempts"))
        #expect(!conn.isConnected)
    }

    @Test("cancel on drop cancels shared token")
    func cancelOnDrop() {
        let token = CancellationToken()
        #expect(!token.isCancelled)
        do {
            let cod = CancelOnDrop(token: token)
            #expect(!cod.isCancelled)
            _ = cod
        }
        #expect(token.isCancelled)

        let disarmed: CancellationToken
        do {
            let cod2 = CancelOnDrop()
            #expect(!cod2.isCancelled)
            cod2.disarm()
            disarmed = cod2.cancellationToken
        }
        #expect(!disarmed.isCancelled)
    }

    @Test("cancel registry tombstone and cancel_all")
    func cancelRegistry() throws {
        let reg = CancelRegistry()
        let id = ToolCallId.newV7()
        // Cancel before register → tombstone.
        #expect(!reg.cancel(callId: id))
        #expect(reg.pendingCount == 1)
        let token = CancellationToken()
        #expect(reg.register(callId: id, token: token))
        #expect(token.isCancelled)
        #expect(reg.pendingCount == 0)

        let id2 = ToolCallId.newV7()
        let t2 = CancellationToken()
        #expect(!reg.register(callId: id2, token: t2))
        #expect(reg.cancelAll() >= 1)
        #expect(reg.isClosed)
        #expect(reg.liveCount == 0)
        let t3 = CancellationToken()
        #expect(reg.register(callId: ToolCallId.newV7(), token: t3))
        #expect(t3.isCancelled)
        #expect(reg.liveCount == 0)
    }

    @Test("refcounted set edges")
    func refCountedSet() {
        let set = RefCountedSet<String>()
        #expect(set.increment("a") == (0, 1))
        #expect(set.increment("a") == (1, 2))
        #expect(set.decrement("a") == 1)
        #expect(set.decrement("a") == 0)
        #expect(set.isEmpty)
        #expect(set.decrement("missing") == nil)
    }

    @Test("notification demux response/progress/session/broadcast")
    func demuxRouting() throws {
        let demux = Demux(sessionCapacity: 4, progressCapacity: 4)
        let session = try SessionId("sess-1")
        demux.registerSessionInbox(session)

        let response = LockedValue<Result<JsonRpcResponse<JSONValue>, ClientError>?>(nil)
        demux.registerResponseWaiter(requestId: "req-1", sessionId: session) { response.set($0) }

        let callId = ToolCallId.newV7()
        demux.registerProgressWaiter(toolCallId: callId)

        let notifs = LockedValue<[JSONValue]>([])
        demux.onNotification { notification in
            notifs.modify { $0.append(notification) }
        }

        // Response route.
        let respFrame: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .string("req-1"),
            "result": .object(["ok": .bool(true)]),
        ])
        #expect(demux.route(respFrame) == .response)
        #expect(response.snapshot != nil)

        // Progress route.
        let progressFrame: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "method": .string(Method.toolCallProgress.wireString),
            "params": .object([
                "tool_call_id": .string(callId.rawValue),
                "kind": .string("delta"),
                "body": .object(["n": .number(.int64(1))]),
            ]),
        ])
        #expect(demux.route(progressFrame) == .progress)
        let drained = demux.drainProgress(toolCallId: callId)
        #expect(drained.count == 1)
        #expect(drained[0].kind == "delta")

        // Session request.
        let sessionReq: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .string("s1"),
            "session_id": .string(session.rawValue),
            "method": .string("tool_call_request"),
            "params": .object([:]),
        ])
        #expect(demux.route(sessionReq) == .session)
        let inbox = demux.drainSessionInbox(session)
        #expect(inbox.count == 1)
        if case .request = inbox[0] {
            // ok
        } else {
            Issue.record("expected request")
        }

        // Connection-level notification.
        let connNotif: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "method": .string("session.bind"),
            "params": .object(["x": .number(.int64(1))]),
        ])
        #expect(demux.route(connNotif) == .notification)
        #expect(notifs.snapshot.count == 1)

        // Unknown progress after unregister.
        demux.unregisterProgressWaiter(toolCallId: callId)
        #expect(demux.route(progressFrame) == .unknownProgress)
    }

    @Test("demux failCallsForSession drains waiters")
    func demuxFailSession() throws {
        let demux = Demux()
        let session = try SessionId("s")
        let got = LockedValue<ClientError?>(nil)
        demux.registerResponseWaiter(requestId: "c1", sessionId: session) { result in
            if case .failure(let error) = result { got.set(error) }
        }
        let n = demux.failCallsForSession(session, error: .networkError("gone"))
        #expect(n == 1)
        #expect(got.snapshot == .networkError("gone"))
    }

    @Test("hub connection notification demux fanout")
    func hubNotificationFanout() throws {
        let key = PrincipalKey(url: "wss://hub", userId: try UserId("u"))
        let conn = HubConnection(key: key, connected: true)
        let recorder = NotificationRecorder()
        conn.onNotification { recorder.append($0) }
        let frame: JSONValue = .object([
            "method": .string("workspace.event"),
            "params": .object(["k": .string("v")]),
        ])
        #expect(conn.demux.route(frame) == .notification)
        let items = recorder.snapshot
        #expect(items.contains(where: {
            if case .custom(let m, _) = $0 { return m == "workspace.event" }
            return false
        }))
    }

    @Test("session bind refcount")
    func sessionBindRefcount() throws {
        let key = PrincipalKey(url: "wss://hub", userId: try UserId("u"))
        let conn = HubConnection(key: key, connected: true)
        let sid = try SessionId("s1")
        #expect(conn.bindSession(sid)) // 0→1 edge
        #expect(!conn.bindSession(sid)) // 1→2
        #expect(conn.boundSessionCount() == 1)
        #expect(!conn.unbindSession(sid)) // 2→1, not last
        #expect(conn.unbindSession(sid)) // 1→0 last
        #expect(conn.boundSessionCount() == 0)
    }

    @Test("auth credential redaction never leaks secrets")
    func authRedaction() {
        let c = AuthCredential.bearer(token: "super-secret-token")
        #expect(!c.redactedDescription.contains("super-secret"))
        #expect(c.redactedDescription.contains("***"))
    }

    @Test("harness local call")
    func harnessLocalCall() async throws {
        let toolId = try ToolId("demo:ping")
        let user = try UserId("u")
        let tool = PingTool(id: toolId)
        let reg = ToolRegistration(
            toolId: toolId,
            userId: user,
            description: ToolDescription(name: "ping", description: "ping"),
            transportKind: .local
        )
        let harness = ToolHarnessBuilder(mediation: .unmediated(reason: "wire/dispatch unit test; no agent reaches this harness"))
            .withLocal(tool, registration: reg)
            .withSession(try SessionId("s"))
            .withPrincipal(Principal.new(user).withScope(localInvokeScope))
            .build()

        let stream = await harness.call(toolId: toolId, args: .null)
        for await item in stream {
            if case .terminal(.success(let out)) = item {
                #expect(out.value == .string("pong"))
                return
            }
            if case .terminal(.failure(let err)) = item {
                Issue.record("failed: \(err)")
                return
            }
        }
        Issue.record("no terminal")
    }

    @Test("harness missing tool")
    func harnessMissing() async throws {
        let harness = ToolHarness(mediation: .unmediated(reason: "wire/dispatch unit test; no agent reaches this harness"))
        let toolId = try ToolId("nope:tool")
        let stream = await harness.call(toolId: toolId, args: .null)
        for await item in stream {
            if case .terminal(.failure(let err)) = item {
                #expect(err.kind == .notFound)
                return
            }
        }
        Issue.record("expected notFound")
    }

    @Test("harness remote disconnected fails closed without local invent")
    func harnessRemoteDisconnected() async throws {
        let key = PrincipalKey(url: "wss://hub", userId: try UserId("u"))
        let conn = HubConnection(key: key, connected: false)
        let harness = ToolHarnessBuilder(mediation: .unmediated(reason: "wire/dispatch unit test; no agent reaches this harness"))
            .withConnection(conn)
            .withSession(try SessionId("s"))
            .withPrincipal(Principal.new(try UserId("u")).withScope(localInvokeScope))
            .build()
        let stream = await harness.call(toolId: try ToolId("remote:x"), args: .null)
        for await item in stream {
            if case .terminal(.failure(let err)) = item {
                #expect(err.kind == .networkError)
                return
            }
        }
        Issue.record("expected networkError")
    }

    @Test("harness connected without a client fails closed")
    func harnessConnectedWithoutClient() async throws {
        let key = PrincipalKey(url: "wss://hub", userId: try UserId("u"))
        let conn = HubConnection(key: key, connected: true)
        let harness = ToolHarnessBuilder(mediation: .unmediated(reason: "wire/dispatch unit test; no agent reaches this harness"))
            .withConnection(conn)
            .withSession(try SessionId("s"))
            .withPrincipal(Principal.new(try UserId("u")).withScope(localInvokeScope))
            .build()
        let stream = await harness.call(toolId: try ToolId("remote:x"), args: .null)
        for await item in stream {
            if case .terminal(.failure(let err)) = item {
                #expect(err.kind == .networkError)
                return
            }
        }
        Issue.record("expected networkError")
    }

    @Test("harness capability scope deny")
    func harnessScopeDeny() async throws {
        let toolId = try ToolId("demo:ping")
        let user = try UserId("u")
        let reg = ToolRegistration(
            toolId: toolId,
            userId: user,
            description: ToolDescription(name: "ping", description: "ping"),
            transportKind: .local
        )
        let harness = ToolHarnessBuilder(mediation: .unmediated(reason: "wire/dispatch unit test; no agent reaches this harness"))
            .withLocal(PingTool(id: toolId), registration: reg)
            .withPrincipal(Principal.new(user)) // no scopes
            .withRequiredScopes([localInvokeScope])
            .build()
        let stream = await harness.call(toolId: toolId, args: .null)
        for await item in stream {
            if case .terminal(.failure(let err)) = item {
                #expect(err.kind == .permissionDenied)
                return
            }
        }
        Issue.record("expected permissionDenied")
    }

    @Test("isWorkspaceUnavailable re-export")
    func unavailableReexport() {
        let err = ToolError.custom(code: workspaceUnavailableSubcode, detail: "gone")
        let unavailable = OpenGrokComputerHubSDK.isWorkspaceUnavailable(err)
        #expect(unavailable)
    }
}

private struct PingTool: ToolDyn {
    let idValue: ToolId
    init(id: ToolId) { self.idValue = id }
    func id() -> ToolId { idValue }
    func description(ctx: ListToolsContext) -> ToolDescription {
        _ = ctx
        return ToolDescription(name: "ping", description: "ping")
    }
    func execute(ctx: ToolCallContext, args: JSONValue) async -> ToolStream<TypedToolOutput> {
        _ = (ctx, args)
        return terminalOnly(.success(.fromValue(toolId: idValue, value: .string("pong"))))
    }
}
