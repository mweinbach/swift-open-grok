// OpenGrokWorkspaceClientTests.swift
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

@Suite("OpenGrokWorkspaceClient")
struct WorkspaceClientTests {
    @Test("not connected fast-fails")
    func notConnected() async throws {
        let client = WorkspaceClient(harness: ToolHarness(mediation: .unmediated(reason: "wire/dispatch unit test; no agent reaches this harness")), connected: ConnectedFlag(false))
        do {
            _ = try await client.rpcRaw(method: "workspace.info", params: .object([:]))
            Issue.record("expected notConnected")
        } catch WorkspaceClientError.notConnected {
            // ok
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }

    @Test("fatal transport marks disconnected and stays notConnected until reconnect")
    func fatalMarksDisconnected() async throws {
        let flag = ConnectedFlag(true)
        let toolId = try ToolId(WORKSPACE_RPC_TOOL_ID)
        let user = try UserId("u")
        let tool = FatalTransportTool(id: toolId)
        let reg = ToolRegistration(
            toolId: toolId,
            userId: user,
            description: ToolDescription(name: "workspace_rpc", description: "rpc"),
            transportKind: .local
        )
        let harness = ToolHarnessBuilder(mediation: .unmediated(reason: "wire/dispatch unit test; no agent reaches this harness"))
            .withLocal(tool, registration: reg)
            .withSession(try SessionId("s"))
            .withPrincipal(Principal.new(user).withScope(localInvokeScope))
            .build()
        let client = WorkspaceClient(harness: harness, connected: flag)
        #expect(client.isConnected)

        do {
            _ = try await client.rpcRaw(method: "workspace.info", params: .object([:]))
            Issue.record("expected transport failure")
        } catch WorkspaceClientError.transport {
            #expect(!client.isConnected)
        }

        // Subsequent calls preserve notConnected until reconnect.
        do {
            _ = try await client.rpcRaw(method: "workspace.info", params: .object([:]))
            Issue.record("expected notConnected")
        } catch WorkspaceClientError.notConnected {
            // ok
        }

        client.markConnected()
        #expect(client.isConnected)
    }

    @Test("non-fatal notFound does not clear latch")
    func nonFatalKeepsConnected() async throws {
        let flag = ConnectedFlag(true)
        let harness = ToolHarness(mediation: .unmediated(reason: "wire/dispatch unit test; no agent reaches this harness")) // no tools → notFound, not fatal
        let client = WorkspaceClient(harness: harness, connected: flag)
        do {
            _ = try await client.rpcRaw(method: "workspace.info", params: .object([:]))
        } catch WorkspaceClientError.transport {
            #expect(client.isConnected)
        }
    }

    @Test("isTransportFatal classification")
    func transportFatal() {
        #expect(isTransportFatal(.networkError("drop")))
        #expect(isTransportFatal(.custom(code: "protocol_error", detail: "bad frame")))
        #expect(!isTransportFatal(.notFound(toolId: try! ToolId("x"), detail: "nope")))
        #expect(!isTransportFatal(.custom(code: "other", detail: "x")))
    }

    @Test("rpc raw success path via local workspace_rpc tool")
    func rpcRawSuccess() async throws {
        let toolId = try ToolId(WORKSPACE_RPC_TOOL_ID)
        let user = try UserId("u")
        let tool = WorkspaceRpcEchoTool(id: toolId)
        let reg = ToolRegistration(
            toolId: toolId,
            userId: user,
            description: ToolDescription(name: "workspace_rpc", description: "rpc"),
            transportKind: .local
        )
        let harness = ToolHarnessBuilder(mediation: .unmediated(reason: "wire/dispatch unit test; no agent reaches this harness"))
            .withLocal(tool, registration: reg)
            .withSession(try SessionId("s"))
            .withPrincipal(Principal.new(user).withScope(localInvokeScope))
            .build()
        let client = WorkspaceClient(harness: harness)
        let value = try await client.rpcRaw(
            method: "workspace.info",
            params: .object([:])
        )
        if case .object(let map) = value, case .object = map["ok"] {
            // ok
        } else {
            Issue.record("unexpected envelope: \(value)")
        }
        #expect(client.isConnected)
    }

    @Test("typed rpc decode success and decode failure")
    func typedRpcDecode() async throws {
        let toolId = try ToolId(WORKSPACE_RPC_TOOL_ID)
        let user = try UserId("u")
        let info = WorkspaceInfo(os: "macOS", shell: "/bin/zsh", cwd: "/tmp")
        let tool = WorkspaceRpcTypedTool(id: toolId, info: info)
        let reg = ToolRegistration(
            toolId: toolId,
            userId: user,
            description: ToolDescription(name: "workspace_rpc", description: "rpc"),
            transportKind: .local
        )
        let harness = ToolHarnessBuilder(mediation: .unmediated(reason: "wire/dispatch unit test; no agent reaches this harness"))
            .withLocal(tool, registration: reg)
            .withSession(try SessionId("s"))
            .withPrincipal(Principal.new(user).withScope(localInvokeScope))
            .build()
        let client = WorkspaceClient(harness: harness)

        let got = try await client.info()
        #expect(got.os == "macOS")
        #expect(got.shell == "/bin/zsh")
        #expect(got.cwd == "/tmp")

        // Force decode failure by asking for a typed method whose envelope is garbage.
        let badTool = WorkspaceRpcGarbageTool(id: toolId)
        let badHarness = ToolHarnessBuilder(mediation: .unmediated(reason: "wire/dispatch unit test; no agent reaches this harness"))
            .withLocal(badTool, registration: reg)
            .withSession(try SessionId("s"))
            .withPrincipal(Principal.new(user).withScope(localInvokeScope))
            .build()
        let badClient = WorkspaceClient(harness: badHarness)
        do {
            _ = try await badClient.info()
            Issue.record("expected decode error")
        } catch WorkspaceClientError.decode {
            // ok
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }

    @Test("consumeStreamTerminal drains progress")
    func consumeProgress() async {
        let toolId = try! ToolId("t")
        let stream = AsyncStream<ToolStreamItem<TypedToolOutput>> { cont in
            cont.yield(.progress(.text(text: "working")))
            cont.yield(.terminal(.success(.fromValue(toolId: toolId, value: .string("done")))))
            cont.finish()
        }
        let result = await consumeStreamTerminal(stream)
        switch result {
        case .success(let out):
            #expect(out.value == .string("done"))
        case .failure(let err):
            Issue.record("\(err)")
        }
    }

    @Test("stream terminal drain ends without terminal → networkError")
    func emptyStream() async {
        let stream = AsyncStream<ToolStreamItem<TypedToolOutput>> { cont in
            cont.finish()
        }
        let result = await consumeStreamTerminal(stream)
        switch result {
        case .failure(let err):
            #expect(err.kind == .networkError)
        case .success:
            Issue.record("expected failure")
        }
    }

    @Test("mark connected resets latch")
    func markConnected() {
        let client = WorkspaceClient(harness: ToolHarness(mediation: .unmediated(reason: "wire/dispatch unit test; no agent reaches this harness")), connected: ConnectedFlag(false))
        #expect(!client.isConnected)
        client.markConnected()
        #expect(client.isConnected)
        client.markDisconnected()
        #expect(!client.isConnected)
    }

    @Test("attachReconnect restores latch after hub reconnect sequence")
    func attachReconnect() throws {
        let flag = ConnectedFlag(true)
        let client = WorkspaceClient(harness: ToolHarness(mediation: .unmediated(reason: "wire/dispatch unit test; no agent reaches this harness")), connected: flag)
        let key = PrincipalKey(url: "wss://hub", userId: try UserId("u"))
        let conn = HubConnection(key: key, connected: true)
        client.attachReconnect(to: conn)

        conn.markDisconnected(reason: "drop")
        #expect(!client.isConnected)
        // Still not connected until reconnected event.
        do {
            // can't call rpc without tools; just check latch
            #expect(!client.isConnected)
        }
        conn.markReconnecting(attempt: 1)
        #expect(!client.isConnected)
        conn.markConnected()
        #expect(client.isConnected)
    }

    @Test("workspace unavailable surfaces typed error")
    func workspaceUnavailable() async throws {
        let toolId = try ToolId(WORKSPACE_RPC_TOOL_ID)
        let user = try UserId("u")
        let tool = WorkspaceUnavailableTool(id: toolId)
        let reg = ToolRegistration(
            toolId: toolId,
            userId: user,
            description: ToolDescription(name: "workspace_rpc", description: "rpc"),
            transportKind: .local
        )
        let harness = ToolHarnessBuilder(mediation: .unmediated(reason: "wire/dispatch unit test; no agent reaches this harness"))
            .withLocal(tool, registration: reg)
            .withSession(try SessionId("s"))
            .withPrincipal(Principal.new(user).withScope(localInvokeScope))
            .build()
        let client = WorkspaceClient(harness: harness)
        do {
            _ = try await client.rpcRaw(method: "workspace.info", params: .object([:]))
            Issue.record("expected workspaceUnavailable")
        } catch WorkspaceClientError.workspaceUnavailable(let err) {
            let unavailable = OpenGrokComputerHubCore.isWorkspaceUnavailable(err)
            #expect(unavailable)
            // workspace_unavailable is not transport-fatal
            #expect(client.isConnected)
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }
}

// MARK: - Test tools

/// Minimal `workspace_rpc` tool that returns `{ok: {method: ...}}`.
private struct WorkspaceRpcEchoTool: ToolDyn {
    let idValue: ToolId
    init(id: ToolId) { self.idValue = id }
    func id() -> ToolId { idValue }
    func description(ctx: ListToolsContext) -> ToolDescription {
        _ = ctx
        return ToolDescription(name: "workspace_rpc", description: "rpc")
    }
    func execute(ctx: ToolCallContext, args: JSONValue) async -> ToolStream<TypedToolOutput> {
        _ = ctx
        let method: String
        if case .object(let map) = args, case .string(let m) = map["method"] {
            method = m
        } else {
            method = "unknown"
        }
        let envelope: JSONValue = .object([
            "ok": .object(["method": .string(method)]),
        ])
        return terminalOnly(.success(.fromValue(toolId: idValue, value: envelope)))
    }
}

private struct WorkspaceRpcTypedTool: ToolDyn {
    let idValue: ToolId
    let info: WorkspaceInfo
    init(id: ToolId, info: WorkspaceInfo) {
        self.idValue = id
        self.info = info
    }
    func id() -> ToolId { idValue }
    func description(ctx: ListToolsContext) -> ToolDescription {
        _ = ctx
        return ToolDescription(name: "workspace_rpc", description: "rpc")
    }
    func execute(ctx: ToolCallContext, args: JSONValue) async -> ToolStream<TypedToolOutput> {
        _ = (ctx, args)
        let payload = (try? JSONValue.encode(info)) ?? .null
        let envelope: JSONValue = .object(["ok": payload])
        return terminalOnly(.success(.fromValue(toolId: idValue, value: envelope)))
    }
}

private struct WorkspaceRpcGarbageTool: ToolDyn {
    let idValue: ToolId
    init(id: ToolId) { self.idValue = id }
    func id() -> ToolId { idValue }
    func description(ctx: ListToolsContext) -> ToolDescription {
        _ = ctx
        return ToolDescription(name: "workspace_rpc", description: "rpc")
    }
    func execute(ctx: ToolCallContext, args: JSONValue) async -> ToolStream<TypedToolOutput> {
        _ = (ctx, args)
        // Valid envelope shape but wrong inner type for WorkspaceInfo.
        let envelope: JSONValue = .object(["ok": .string("not-an-object")])
        return terminalOnly(.success(.fromValue(toolId: idValue, value: envelope)))
    }
}

private struct FatalTransportTool: ToolDyn {
    let idValue: ToolId
    init(id: ToolId) { self.idValue = id }
    func id() -> ToolId { idValue }
    func description(ctx: ListToolsContext) -> ToolDescription {
        _ = ctx
        return ToolDescription(name: "workspace_rpc", description: "rpc")
    }
    func execute(ctx: ToolCallContext, args: JSONValue) async -> ToolStream<TypedToolOutput> {
        _ = (ctx, args)
        return terminalOnly(
            Result<TypedToolOutput, ToolError>.failure(.networkError("socket closed"))
        )
    }
}

private struct WorkspaceUnavailableTool: ToolDyn {
    let idValue: ToolId
    init(id: ToolId) { self.idValue = id }
    func id() -> ToolId { idValue }
    func description(ctx: ListToolsContext) -> ToolDescription {
        _ = ctx
        return ToolDescription(name: "workspace_rpc", description: "rpc")
    }
    func execute(ctx: ToolCallContext, args: JSONValue) async -> ToolStream<TypedToolOutput> {
        _ = (ctx, args)
        return terminalOnly(
            Result<TypedToolOutput, ToolError>.failure(
                workspaceUnavailableError(reason: .disconnect, phase: .routeMissing)
            )
        )
    }
}
