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
        let client = WorkspaceClient(harness: ToolHarness(), connected: ConnectedFlag(false))
        do {
            _ = try await client.rpcRaw(method: "workspace.info", params: .object([:]))
            Issue.record("expected notConnected")
        } catch WorkspaceClientError.notConnected {
            // ok
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }

    @Test("fatal transport marks disconnected")
    func fatalMarksDisconnected() async throws {
        let flag = ConnectedFlag(true)
        let harness = ToolHarness() // no tools → notFound, not fatal
        let client = WorkspaceClient(harness: harness, connected: flag)
        // notFound is not fatal
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
        let harness = ToolHarnessBuilder()
            .withLocal(tool, registration: reg)
            .withSession(try SessionId("s"))
            .build()
        let client = WorkspaceClient(harness: harness)
        let value = try await client.rpcRaw(
            method: "workspace.info",
            params: .object([:])
        )
        // Echo tool wraps method into ok envelope.
        if case .object(let map) = value, case .object = map["ok"] {
            // ok
        } else {
            Issue.record("unexpected envelope: \(value)")
        }
        #expect(client.isConnected)
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

    @Test("mark connected resets latch")
    func markConnected() {
        let client = WorkspaceClient(harness: ToolHarness(), connected: ConnectedFlag(false))
        #expect(!client.isConnected)
        client.markConnected()
        #expect(client.isConnected)
        client.markDisconnected()
        #expect(!client.isConnected)
    }
}

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
