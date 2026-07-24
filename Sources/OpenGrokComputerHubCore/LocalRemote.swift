// LocalRemote.swift
//
// LocalTransport, RemoteTransport, ConnectionClient, progress-aware
// remote dispatch. Ported from `xai-computer-hub-core/src/local.rs` +
// `remote.rs`.

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
    /// Required principal scopes for every call through this transport.
    public var requiredScopes: [String]

    public init(
        resolver: CompoundResolver,
        userId: UserId,
        sessionId: SessionId,
        requiredScopes: [String] = [localInvokeScope]
    ) {
        self.resolver = resolver
        self.userId = userId
        self.sessionId = sessionId
        self.requiredScopes = requiredScopes
    }

    public var kind: TransportKind { .local }

    public func authorize() async throws -> Principal {
        var p = Principal.new(userId).withSession(sessionId)
        for scope in requiredScopes {
            p = p.withScope(scope)
        }
        return p
    }

    public func call(
        toolId: ToolId,
        args: JSONValue,
        ctx: ToolCallContext
    ) async -> ToolStream<TypedToolOutput> {
        // Capability-scope gate before any local dispatch.
        let principal: Principal
        do {
            principal = try await authorize()
        } catch {
            return terminalOnly(
                Result<TypedToolOutput, ToolError>.failure(
                    .permissionDenied("\(error)")
                )
            )
        }
        let caps = resolver.resolve(sessionId: sessionId, toolId: toolId)?
            .handle.capabilities()
        if let denied = admitCall(
            principal: principal,
            requiredScopes: requiredScopes,
            capabilities: caps,
            args: args
        ) {
            return terminalOnly(Result<TypedToolOutput, ToolError>.failure(denied))
        }
        return await resolver.resolveAndDispatch(
            sessionId: sessionId,
            toolId: toolId,
            args: args,
            ctx: ctx
        )
    }
}

// MARK: - ConnectionClient

/// Object-safe contract for a connected remote endpoint.
///
/// Concrete implementations supply the wire transport; tests use
/// channel-backed mocks. Progress subscribers MUST be registered before
/// the corresponding request is sent.
public protocol ConnectionClient: Sendable {
    func request(_ request: JsonRpcRequest<JSONValue>) async throws -> JsonRpcResponse<JSONValue>
    func notify(_ notification: JsonRpcNotification<JSONValue>) async throws
    /// Subscribe to progress frames for `toolCallId`. Stream closes when
    /// the call terminates, the connection drops, or the subscriber is
    /// cancelled.
    func subscribeProgress(toolCallId: ToolCallId) async -> AsyncStream<ToolCallProgressFrame>
}

extension ConnectionClient {
    /// Default: empty progress stream (no progress frames).
    public func subscribeProgress(
        toolCallId: ToolCallId
    ) async -> AsyncStream<ToolCallProgressFrame> {
        _ = toolCallId
        return AsyncStream { $0.finish() }
    }
}

/// Transport that forwards tool calls over a connection.
///
/// Local and remote share one protocol: `tool_call_request` +
/// progress notifications + terminal `tool_call_result`. Unsupported
/// remote operations surface as typed errors and never silently fall
/// back to in-process execution.
public final class RemoteTransport: HubTransport, @unchecked Sendable {
    public let connection: any ConnectionClient
    public let principal: Principal
    public let defaultSessionId: SessionId
    public var requiredScopes: [String]

    public init(
        connection: any ConnectionClient,
        principal: Principal,
        defaultSessionId: SessionId,
        requiredScopes: [String] = [localInvokeScope]
    ) {
        self.connection = connection
        self.principal = principal
        self.defaultSessionId = defaultSessionId
        self.requiredScopes = requiredScopes
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
        if let denied = admitCall(
            principal: principal,
            requiredScopes: requiredScopes,
            capabilities: nil,
            args: args
        ) {
            return terminalOnly(Result<TypedToolOutput, ToolError>.failure(denied))
        }
        return await dispatchViaConnection(
            connection: connection,
            toolId: toolId,
            sessionId: principal.sessionIds.first ?? defaultSessionId,
            arguments: args,
            ctx: ctx
        )
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
        // Bound by declared maxFrameBytes when present.
        if let denied = admitCall(
            principal: Principal.new(try! UserId("remote")).withSession(sessionId),
            requiredScopes: [],
            capabilities: toolCapabilities,
            args: args
        ) {
            return terminalOnly(Result<TypedToolOutput, ToolError>.failure(denied))
        }
        return await dispatchViaConnection(
            connection: connection,
            toolId: toolId,
            sessionId: sessionId,
            arguments: args,
            ctx: ctx
        )
    }
}

// MARK: - Shared remote dispatch

/// Subscribe to progress BEFORE sending the request, then interleave
/// progress frames with the terminal response. Shared by
/// `RemoteTransport` and `RemoteToolProxy` so both paths honour the
/// subscribe-before-send contract.
public func dispatchViaConnection(
    connection: any ConnectionClient,
    toolId: ToolId,
    sessionId: SessionId,
    arguments: JSONValue,
    ctx: ToolCallContext
) async -> ToolStream<TypedToolOutput> {
    let callId = ctx.callId
    let progressStream = await connection.subscribeProgress(toolCallId: callId)

    let params = ToolCallParams(
        toolCallId: callId,
        toolId: toolId,
        arguments: arguments
    )
    let paramsValue: JSONValue
    do {
        paramsValue = try JSONValue.encode(params)
    } catch {
        return terminalOnly(
            Result<TypedToolOutput, ToolError>.failure(
                .custom(code: "request_encoding", detail: "\(error)")
            )
        )
    }

    let req = JsonRpcRequest(
        id: .newUUID(),
        sessionId: sessionId,
        method: Method.toolCallRequest.wireString,
        params: paramsValue
    )

    return AsyncStream { continuation in
        let task = Task {
            // Fan progress into the returned stream while the request is
            // in flight; terminal short-circuits remaining progress.
            let progressTask = Task {
                for await frame in progressStream {
                    if Task.isCancelled { break }
                    continuation.yield(.progress(progressFromFrame(frame)))
                }
            }

            let terminal: Result<TypedToolOutput, ToolError>
            do {
                let resp = try await connection.request(req)
                switch resp.outcome {
                case .result(let value):
                    terminal = decodeCallResult(toolId: toolId, value: value)
                case .error(let err):
                    terminal = .failure(errorFromEnvelope(err))
                }
            } catch let err as ToolError {
                terminal = .failure(err)
            } catch {
                terminal = .failure(.networkError("\(error)"))
            }

            progressTask.cancel()
            continuation.yield(.terminal(terminal))
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

// MARK: - Unsupported remote op

/// Explicit failure for operations the remote endpoint does not support.
/// Callers must never silently execute such ops in-process when the
/// intended plane is remote.
public func unsupportedRemoteOperation(
    method: String,
    detail: String? = nil
) -> ToolError {
    .custom(
        code: "unsupported_remote_operation",
        detail: detail ?? "remote endpoint does not support \(method)"
    )
}
