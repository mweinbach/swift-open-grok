// OpenGrokComputerHubCoreTests.swift
import Foundation
import Testing
@testable import OpenGrokComputerHubCore
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime
import OpenGrokToolTypes

@Suite("OpenGrokComputerHubCore")
struct ComputerHubCoreTests {
    @Test("principal builders")
    func principalBuilders() throws {
        let user = try UserId("user-1")
        let session = try SessionId("sess-1")
        let p = Principal.new(user).withSession(session).withScope(localInvokeScope)
        #expect(p.hasScope(localInvokeScope))
        #expect(p.authorizesSession(session))
        #expect(!p.authorizesSession(try SessionId("other")))
    }

    @Test("local shadows remote")
    func localShadowsRemote() async throws {
        let user = try UserId("u")
        let session = try SessionId("s")
        let toolId = try ToolId("demo:echo")

        let localReg = InMemoryToolRegistry()
        let remoteReg = InMemoryToolRegistry()

        let localHandle = ErasedTool(EchoTool(id: toolId, payload: "local"))
        let remoteHandle = ErasedTool(EchoTool(id: toolId, payload: "remote"))

        let desc = ToolDescription(name: "echo", description: "echo")
        let registration = ToolRegistration(
            toolId: toolId,
            userId: user,
            description: desc,
            transportKind: .local
        )
        localReg.register(sessionId: session, handle: localHandle, registration: registration)
        remoteReg.register(
            sessionId: session,
            handle: remoteHandle,
            registration: ToolRegistration(
                toolId: toolId,
                userId: user,
                description: desc,
                transportKind: .remote
            )
        )

        let resolver = CompoundResolver(local: localReg, remote: remoteReg)
        let resolved = resolver.resolve(sessionId: session, toolId: toolId)
        #expect(resolved?.isLocal == true)

        let stream = await resolver.resolveAndDispatch(
            sessionId: session,
            toolId: toolId,
            args: .null,
            ctx: ToolCallContext()
        )
        let result = await firstTerminal(stream)
        switch result {
        case .success(let out):
            #expect(out.value == .string("local"))
        case .failure(let err):
            Issue.record("unexpected failure: \(err)")
        }
    }

    @Test("local transport authorize grants invoke scope")
    func localAuthorize() async throws {
        let user = try UserId("u")
        let session = try SessionId("s")
        let transport = LocalTransport(
            resolver: CompoundResolver(local: InMemoryToolRegistry()),
            userId: user,
            sessionId: session
        )
        #expect(transport.kind == .local)
        let principal = try await transport.authorize()
        #expect(principal.hasScope(localInvokeScope))
        #expect(principal.authorizesSession(session))
    }

    @Test("not found yields terminal notFound")
    func notFound() async throws {
        let session = try SessionId("s")
        let toolId = try ToolId("missing:tool")
        let resolver = CompoundResolver(local: InMemoryToolRegistry())
        let stream = await resolver.resolveAndDispatch(
            sessionId: session,
            toolId: toolId,
            args: .null,
            ctx: ToolCallContext()
        )
        let result = await firstTerminal(stream)
        switch result {
        case .failure(let err):
            #expect(err.kind == .notFound)
        case .success:
            Issue.record("expected notFound")
        }
    }

    @Test("isWorkspaceUnavailable detects custom subcode")
    func workspaceUnavailableDetect() {
        let err = workspaceUnavailableError(reason: .disconnect, phase: .routeMissing)
        #expect(isWorkspaceUnavailable(err))
        #expect(!isWorkspaceUnavailable(.networkError("x")))
        #expect(!isWorkspaceUnavailable(.custom(code: "other", detail: "x")))
    }

    @Test("errorFromEnvelope maps workspace unavailable")
    func errorFromEnvelopeMaps() {
        let err = JsonRpcError(
            code: workspaceUnavailableJsonrpcCode,
            message: workspaceUnavailableMessage,
            data: .object([
                "subcode": .string(workspaceUnavailableSubcode),
            ])
        )
        let toolErr = errorFromEnvelope(err)
        #expect(isWorkspaceUnavailable(toolErr))
    }
}

// MARK: - Helpers

private struct EchoTool: ToolDyn {
    let idValue: ToolId
    let payload: String

    init(id: ToolId, payload: String) {
        self.idValue = id
        self.payload = payload
    }

    func id() -> ToolId { idValue }
    func description(ctx: ListToolsContext) -> ToolDescription {
        _ = ctx
        return ToolDescription(name: idValue.rawValue, description: "echo")
    }
    func execute(ctx: ToolCallContext, args: JSONValue) async -> ToolStream<TypedToolOutput> {
        _ = (ctx, args)
        return terminalOnly(.success(.fromValue(toolId: idValue, value: .string(payload))))
    }
}

private func firstTerminal(
    _ stream: ToolStream<TypedToolOutput>
) async -> Result<TypedToolOutput, ToolError> {
    for await item in stream {
        if case .terminal(let r) = item { return r }
    }
    return .failure(.networkError("no terminal"))
}
