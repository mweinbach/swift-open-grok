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
        #expect(p.hasAllScopes([localInvokeScope]))
        #expect(!p.hasAllScopes([localInvokeScope, "admin"]))
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

    @Test("capability scope deny without invoke")
    func capabilityScopeDeny() async throws {
        let user = try UserId("u")
        let session = try SessionId("s")
        let toolId = try ToolId("demo:echo")
        let reg = InMemoryToolRegistry()
        reg.register(
            sessionId: session,
            handle: ErasedTool(EchoTool(id: toolId, payload: "x")),
            registration: ToolRegistration(
                toolId: toolId,
                userId: user,
                description: ToolDescription(name: "echo", description: "e"),
                transportKind: .local
            )
        )
        let transport = LocalTransport(
            resolver: CompoundResolver(local: reg),
            userId: user,
            sessionId: session,
            requiredScopes: [localInvokeScope, "admin"]
        )
        // authorize() always grants requiredScopes for LocalTransport, so
        // exercise admitCall directly with a principal missing the scope.
        let p = Principal.new(user).withSession(session).withScope(localInvokeScope)
        let denied = admitCall(
            principal: p,
            requiredScopes: [localInvokeScope, "admin"],
            capabilities: nil,
            args: .null
        )
        #expect(denied?.kind == .permissionDenied)
        _ = transport
    }

    @Test("payload bound rejects oversized args")
    func payloadBound() {
        let p = Principal.new(try! UserId("u")).withScope(localInvokeScope)
        let caps = ToolCapabilities(maxFrameBytes: 16)
        let big = JSONValue.string(String(repeating: "x", count: 64))
        let denied = admitCall(
            principal: p,
            requiredScopes: [localInvokeScope],
            capabilities: caps,
            args: big
        )
        #expect(denied != nil)
        if case .custom = denied?.kind {
            #expect(denied?.details.map { isPayloadTooLarge($0) } == true
                || denied?.detail.contains("exceeds") == true)
        }
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

    @Test("workspace_unavailable every reason/phase via wire")
    func workspaceUnavailableAllSubcodes() {
        let reasons: [WorkspaceGoneReason] = [
            .idleTimeout, .disconnect, .shutdown, .notBound, .instanceGone,
        ]
        let phases: [WorkspaceGonePhase] = [.inFlightCancelled, .routeMissing]
        for reason in reasons {
            for phase in phases {
                let wire = workspaceUnavailableWire(reason: reason, phase: phase)
                let err = toolErrorFromWire(wire)
                #expect(isWorkspaceUnavailable(err), "reason=\(reason) phase=\(phase)")
                if case .object(let map) = err.details {
                    #expect(map["code"] == .string(workspaceUnavailableSubcode))
                    #expect(map["retryable"] == .bool(true))
                } else {
                    Issue.record("missing details")
                }
            }
        }
    }

    @Test("errorFromEnvelope maps workspace unavailable wire")
    func errorFromEnvelopeMaps() throws {
        let wire = workspaceUnavailableWire(reason: .disconnect, phase: .routeMissing)
        let data = try JSONValue.encode(wire)
        let err = JsonRpcError(
            code: workspaceUnavailableJsonrpcCode,
            message: workspaceUnavailableMessage,
            data: data
        )
        let toolErr = errorFromEnvelope(err)
        #expect(isWorkspaceUnavailable(toolErr))
    }

    @Test("numeric only tool_server_gone is not recognized")
    func numericOnlyNotRecognized() {
        let err = errorFromEnvelope(JsonRpcError(
            code: workspaceUnavailableJsonrpcCode,
            message: "tool server gone",
            data: nil
        ))
        #expect(!isWorkspaceUnavailable(err))
    }

    @Test("outputToValue text/json/mcp image+binary blocks")
    func structuredOutputs() throws {
        #expect(outputToValue(.text("hello")) == .string("hello"))
        #expect(outputToValue(.json(.object(["a": .number(.int64(1))]))) == .object(["a": .number(.int64(1))]))

        let mcp = ToolOutputWire.mcp(blocks: [
            .text(text: "hi"),
            .image(mimeType: "image/png", data: "base64=="),
            .resource(uri: "file:///x.bin", mimeType: "application/octet-stream", text: nil),
        ])
        let value = outputToValue(mcp)
        guard case .object(let map) = value,
              case .array(let blocks) = map["blocks"]
        else {
            Issue.record("expected blocks array")
            return
        }
        #expect(blocks.count == 3)
        // Round-trip ContentBlock decode for image/binary resource.
        let decoded = try value.decode(BlocksEnvelope.self)
        #expect(decoded.blocks.count == 3)
        if case .image(let mime, _, _, _, _, _) = decoded.blocks[1] {
            #expect(mime == "image/png")
        } else {
            Issue.record("expected image block")
        }
        if case .resource(let uri, let mime, _) = decoded.blocks[2] {
            #expect(uri == "file:///x.bin")
            #expect(mime == "application/octet-stream")
        } else {
            Issue.record("expected resource block")
        }
    }

    @Test("decodeCallResult strict tool_call_result body")
    func decodeCallResultStrict() throws {
        let toolId = try ToolId("demo:t")
        let callId = ToolCallId.newV7()
        let result = ToolCallResult(
            toolCallId: callId,
            output: .text("done")
        )
        let value = try JSONValue.encode(result)
        let decoded = decodeCallResult(toolId: toolId, value: value)
        switch decoded {
        case .success(let out):
            #expect(out.value == .string("done"))
        case .failure(let err):
            Issue.record("\(err)")
        }
    }

    @Test("decodeCallResult bare body passthrough")
    func decodeBare() throws {
        let toolId = try ToolId("demo:t")
        let bare: JSONValue = .object(["ok": .bool(true)])
        let decoded = decodeCallResult(toolId: toolId, value: bare)
        switch decoded {
        case .success(let out):
            #expect(out.value == bare)
        case .failure(let err):
            Issue.record("\(err)")
        }
    }

    @Test("remote transport shares protocol and never invents local")
    func remoteTransportProtocol() async throws {
        let session = try SessionId("s")
        let user = try UserId("u")
        let toolId = try ToolId("remote:only")
        let callId = ToolCallId.newV7()
        let mock = MockConnectionClient()
        let body = try JSONValue.encode(ToolCallResult(
            toolCallId: callId,
            output: .json(.object(["src": .string("remote")]))
        ))
        mock.enqueueOk(body)

        let principal = Principal.new(user).withSession(session).withScope(localInvokeScope)
        let transport = RemoteTransport(
            connection: mock,
            principal: principal,
            defaultSessionId: session
        )
        #expect(transport.kind == .remote)
        let stream = await transport.call(
            toolId: toolId,
            args: .object([:]),
            ctx: ToolCallContext(callId: callId)
        )
        let result = await firstTerminal(stream)
        switch result {
        case .success(let out):
            #expect(out.value == .object(["src": .string("remote")]))
        case .failure(let err):
            Issue.record("\(err)")
        }
        #expect(mock.capturedRequests.count == 1)
        #expect(mock.capturedRequests[0].method == Method.toolCallRequest.wireString)
    }

    @Test("remote unsupported maps envelope error without local fallback")
    func remoteUnsupported() async throws {
        let session = try SessionId("s")
        let user = try UserId("u")
        let toolId = try ToolId("remote:nope")
        let mock = MockConnectionClient()
        mock.enqueueErr(JsonRpcError(
            code: -32601,
            message: "method not found",
            data: .object([
                "code": .string("custom"),
                "subcode": .string("unsupported_remote_operation"),
                "message": .string("nope"),
            ])
        ))
        // Even if data isn't full ToolErrorWire, envelope still surfaces error.
        let transport = RemoteTransport(
            connection: mock,
            principal: Principal.new(user).withSession(session).withScope(localInvokeScope),
            defaultSessionId: session
        )
        let stream = await transport.call(
            toolId: toolId,
            args: .null,
            ctx: ToolCallContext()
        )
        let result = await firstTerminal(stream)
        switch result {
        case .failure:
            break
        case .success:
            Issue.record("expected remote failure")
        }
    }

    @Test("inner dispatch fails after detach")
    func innerDispatchDropped() async throws {
        let session = try SessionId("s")
        let resolver = CompoundResolver(local: InMemoryToolRegistry())
        let inner = InnerDispatchForResolver(resolver: resolver, sessionId: session)
        inner.detach()
        let stream = await inner.call(
            toolId: try ToolId("x:y"),
            args: .null,
            ctx: ToolCallContext()
        )
        let result = await firstTerminal(stream)
        switch result {
        case .failure(let err):
            #expect(err.kind == .custom)
            if case .object(let map) = err.details {
                #expect(map["code"] == .string("computer_hub_dropped"))
            }
        case .success:
            Issue.record("expected drop")
        }
    }

    @Test("unsupportedRemoteOperation helper")
    func unsupportedHelper() {
        let err = unsupportedRemoteOperation(method: "workspace.exotic")
        #expect(err.kind == .custom)
        if case .object(let map) = err.details {
            #expect(map["code"] == .string("unsupported_remote_operation"))
        }
    }
}

// MARK: - Helpers

private struct BlocksEnvelope: Codable {
    var blocks: [ContentBlock]
}

private func isPayloadTooLarge(_ details: JSONValue) -> Bool {
    if case .object(let map) = details, case .string(let c) = map["code"] {
        return c == "payload_too_large"
    }
    return false
}

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

private final class MockConnectionClient: ConnectionClient, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Result<JsonRpcResponse<JSONValue>, ToolError>] = []
    private(set) var capturedRequests: [JsonRpcRequest<JSONValue>] = []
    private var progress: [ToolCallId: [ToolCallProgressFrame]] = [:]

    func enqueueOk(_ body: JSONValue) {
        lock.lock()
        responses.append(.success(JsonRpcResponse(
            id: .string("pending"),
            outcome: .result(body)
        )))
        lock.unlock()
    }

    func enqueueErr(_ err: JsonRpcError) {
        lock.lock()
        responses.append(.success(JsonRpcResponse(
            id: .string("pending"),
            outcome: .error(err)
        )))
        lock.unlock()
    }

    func request(_ request: JsonRpcRequest<JSONValue>) async throws -> JsonRpcResponse<JSONValue> {
        let next = try dequeueResponse(for: request)
        switch next {
        case .success(var response):
            response.id = request.id
            response.sessionId = request.sessionId
            return response
        case .failure(let error):
            throw error
        }
    }

    private func dequeueResponse(
        for request: JsonRpcRequest<JSONValue>
    ) throws -> Result<JsonRpcResponse<JSONValue>, ToolError> {
        lock.lock()
        defer { lock.unlock() }
        capturedRequests.append(request)
        guard !responses.isEmpty else {
            throw ToolError.custom(code: "mock_response_missing", detail: "no response staged")
        }
        return responses.removeFirst()
    }

    func notify(_ notification: JsonRpcNotification<JSONValue>) async throws {
        _ = notification
    }

    func subscribeProgress(toolCallId: ToolCallId) async -> AsyncStream<ToolCallProgressFrame> {
        let frames = progressFrames(for: toolCallId)
        return AsyncStream { continuation in
            for frame in frames { continuation.yield(frame) }
            continuation.finish()
        }
    }

    private func progressFrames(for toolCallId: ToolCallId) -> [ToolCallProgressFrame] {
        lock.lock()
        defer { lock.unlock() }
        return progress[toolCallId] ?? []
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
