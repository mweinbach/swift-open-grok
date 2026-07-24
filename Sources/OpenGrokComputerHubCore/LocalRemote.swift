// LocalRemote.swift
//
// LocalTransport, RemoteTransport, ConnectionClient, workspace_unavailable.
// Ported from `xai-computer-hub-core/src/local.rs` + `remote.rs`.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime
import OpenGrokToolTypes

/// Scope `LocalTransport.authorize` grants.
public let localInvokeScope = "tool.invoke"

/// Transport that dispatches against an in-process resolver.
public final class LocalTransport: HubTransport, @unchecked Sendable {
    public let resolver: CompoundResolver
    public let userId: UserId
    public let sessionId: SessionId

    public init(resolver: CompoundResolver, userId: UserId, sessionId: SessionId) {
        self.resolver = resolver
        self.userId = userId
        self.sessionId = sessionId
    }

    public var kind: TransportKind { .local }

    public func authorize() async throws -> Principal {
        Principal.new(userId)
            .withSession(sessionId)
            .withScope(localInvokeScope)
    }

    public func call(
        toolId: ToolId,
        args: JSONValue,
        ctx: ToolCallContext
    ) async -> ToolStream<TypedToolOutput> {
        await resolver.resolveAndDispatch(
            sessionId: sessionId,
            toolId: toolId,
            args: args,
            ctx: ctx
        )
    }
}

/// Object-safe contract for a connected remote endpoint.
public protocol ConnectionClient: Sendable {
    func request(_ request: JsonRpcRequest<JSONValue>) async throws -> JsonRpcResponse<JSONValue>
    func notify(_ notification: JsonRpcNotification<JSONValue>) async throws
}

/// Transport that forwards tool calls over a connection.
public final class RemoteTransport: HubTransport, @unchecked Sendable {
    public let connection: any ConnectionClient
    public let principal: Principal
    public let defaultSessionId: SessionId

    public init(
        connection: any ConnectionClient,
        principal: Principal,
        defaultSessionId: SessionId
    ) {
        self.connection = connection
        self.principal = principal
        self.defaultSessionId = defaultSessionId
    }

    public var kind: TransportKind { .remote }

    public func authorize() async throws -> Principal {
        principal
    }

    public func call(
        toolId: ToolId,
        args: JSONValue,
        ctx: ToolCallContext
    ) async -> ToolStream<TypedToolOutput> {
        let sessionId = principal.sessionIds.first ?? defaultSessionId
        let params: JSONValue = .object([
            "tool_call_id": .string(ctx.callId.rawValue),
            "tool_id": .string(toolId.rawValue),
            "arguments": args,
        ])
        let req = JsonRpcRequest(
            id: .string(UUID().uuidString),
            sessionId: sessionId,
            method: "tool_call_request",
            params: params
        )
        do {
            let resp = try await connection.request(req)
            switch resp.outcome {
            case .result(let value):
                let output = TypedToolOutput.fromValue(toolId: toolId, value: value)
                return terminalOnly(.success(output))
            case .error(let err):
                let toolErr = errorFromEnvelope(err)
                return terminalOnly(Result<TypedToolOutput, ToolError>.failure(toolErr))
            }
        } catch {
            return terminalOnly(
                Result<TypedToolOutput, ToolError>.failure(
                    .networkError("\(error)")
                )
            )
        }
    }
}

/// Remote tool proxy implementing `ToolHandle`.
public struct RemoteToolProxy: ToolHandle {
    public let toolId: ToolId
    public let sessionId: SessionId
    public let toolDescription: ToolDescription
    public let toolCapabilities: ToolCapabilities
    public let connection: any ConnectionClient

    public init(
        toolId: ToolId,
        sessionId: SessionId,
        description: ToolDescription,
        capabilities: ToolCapabilities,
        connection: any ConnectionClient
    ) {
        self.toolId = toolId
        self.sessionId = sessionId
        self.toolDescription = description
        self.toolCapabilities = capabilities
        self.connection = connection
    }

    public func id() -> ToolId { toolId }
    public func description(ctx: ListToolsContext) -> ToolDescription {
        _ = ctx
        return toolDescription
    }
    public func capabilities() -> ToolCapabilities { toolCapabilities }

    public func execute(
        ctx: ToolCallContext,
        args: JSONValue
    ) async -> ToolStream<TypedToolOutput> {
        let transport = RemoteTransport(
            connection: connection,
            principal: Principal.new(try! UserId("remote")).withSession(sessionId),
            defaultSessionId: sessionId
        )
        return await transport.call(toolId: toolId, args: args, ctx: ctx)
    }
}

// MARK: - workspace_unavailable

/// Whether a `ToolError` is the recognizable workspace-gone signal.
public func isWorkspaceUnavailable(_ err: ToolError) -> Bool {
    guard err.kind == .custom else { return false }
    guard case .object(let map) = err.details,
          case .string(let code) = map["code"]
    else { return false }
    return code == workspaceUnavailableSubcode
}

/// Map a JSON-RPC error envelope into a runtime `ToolError`.
public func errorFromEnvelope(_ err: JsonRpcError) -> ToolError {
    if let data = err.data,
       case .object(let map) = data,
       case .string(let sub) = map["subcode"] ?? map["code"],
       sub == workspaceUnavailableSubcode
    {
        return ToolError.custom(
            code: workspaceUnavailableSubcode,
            detail: workspaceUnavailableMessage
        )
    }
    return ToolError.custom(code: "rpc_error", detail: err.message)
}

/// Build a workspace-unavailable tool error with structured details.
public func workspaceUnavailableError(
    reason: WorkspaceGoneReason,
    phase: WorkspaceGonePhase
) -> ToolError {
    let details = WorkspaceUnavailableDetails(reason: reason, phase: phase)
    let encoded = (try? JSONValue.encode(details)) ?? .object([
        "code": .string(workspaceUnavailableSubcode),
        "reason": .string(reason.rawValue),
        "phase": .string(phase.rawValue),
        "retryable": .bool(true),
    ])
    return ToolError(
        kind: .custom,
        detail: workspaceUnavailableMessage,
        details: encoded
    )
}
