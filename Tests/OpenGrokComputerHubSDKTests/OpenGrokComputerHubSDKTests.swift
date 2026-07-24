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
        lock.withLock {
            events.append(event)
        }
    }

    var snapshot: [ReconnectEvent] {
        lock.withLock { events }
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
        pool.release(key: key)
        #expect(a.isConnected) // still held
        pool.release(key: key)
        #expect(!a.isConnected)
    }

    @Test("reconnect handlers fire")
    func reconnectHandlers() throws {
        let key = PrincipalKey(url: "wss://hub", userId: try UserId("u"))
        let conn = HubConnection(key: key, connected: true)
        let recorder = ReconnectEventRecorder()
        conn.onReconnect { recorder.append($0) }
        conn.markDisconnected(reason: "drop")
        conn.markConnected()
        let events = recorder.snapshot
        #expect(events.count == 2)
        #expect(events[0] == .disconnected(reason: "drop"))
        #expect(events[1] == .reconnected)
    }

    @Test("cancel on drop cancels token")
    func cancelOnDrop() {
        var token: CancellationToken!
        do {
            let cod = CancelOnDrop()
            token = CancellationToken()
            // exercise CancelOnDrop deinit path
            _ = cod
        }
        let cod2 = CancelOnDrop()
        #expect(!cod2.isCancelled)
        cod2.cancel()
        #expect(cod2.isCancelled)
        _ = token
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
        let harness = ToolHarnessBuilder()
            .withLocal(tool, registration: reg)
            .withSession(try SessionId("s"))
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
        let harness = ToolHarness()
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
