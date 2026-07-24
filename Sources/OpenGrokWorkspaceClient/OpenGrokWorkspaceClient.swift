// OpenGrokWorkspaceClient.swift
//
// Typed client for hub-proxied `workspace.*` RPC methods (Swift port of
// `xai-grok-workspace-client`). Wire types live in OpenGrokWorkspaceTypes;
// this target adds the connected-state latch, generic RPC core, and
// transport-fatal disconnect mapping.

import Foundation
import OpenGrokComputerHubCore
import OpenGrokComputerHubSDK
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime
import OpenGrokWorkspaceTypes

// MARK: - Errors

public enum WorkspaceClientError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A previous call observed a fatal transport error and no reconnect
    /// has been signalled since.
    case notConnected
    case transport(String)
    case timeout(method: String, afterMs: UInt64)
    case decode(method: String, detail: String)
    case rpc(RpcError)

    public var description: String {
        switch self {
        case .notConnected:
            return "hub connection lost (previously disconnected)"
        case .transport(let d):
            return "rpc failed: \(d)"
        case .timeout(let method, let after):
            return "\(method) timed out after \(after)ms"
        case .decode(let method, let detail):
            return "\(method): response decode: \(detail)"
        case .rpc(let e):
            return "workspace rpc error: \(e)"
        }
    }
}

// MARK: - Stream helpers

/// Consume a tool stream to its terminal item, discarding progress frames.
public func consumeStreamTerminal(
    _ stream: ToolStream<TypedToolOutput>
) async -> Result<TypedToolOutput, ToolError> {
    for await item in stream {
        switch item {
        case .progress:
            continue
        case .terminal(let result):
            return result
        }
    }
    return .failure(.networkError("stream ended without terminal item"))
}

/// Whether a `ToolError` indicates a fatal transport failure.
public func isTransportFatal(_ err: ToolError) -> Bool {
    switch err.kind {
    case .networkError:
        return true
    case .custom:
        if case .object(let map) = err.details,
           case .string(let code) = map["code"],
           code == "protocol_error"
        {
            return true
        }
        return false
    default:
        return false
    }
}

// MARK: - Client

/// Typed client over a bound `ToolHarness` for `workspace.*` RPCs.
///
/// Clones share the harness and the connected latch via reference types.
public final class WorkspaceClient: @unchecked Sendable {
    public let harness: ToolHarness
    private let connected: ConnectedFlag
    public var deadlineMs: UInt64?

    public init(harness: ToolHarness, connected: ConnectedFlag = ConnectedFlag(true)) {
        self.harness = harness
        self.connected = connected
        self.deadlineMs = nil
    }

    public func withDeadline(ms: UInt64) -> WorkspaceClient {
        let c = WorkspaceClient(harness: harness, connected: connected)
        c.deadlineMs = ms
        return c
    }

    public var isConnected: Bool { connected.value }

    public func markDisconnected() { connected.set(false) }
    public func markConnected() { connected.set(true) }

    /// Untyped RPC: `{"method": .., "params": ..}` through `workspace_rpc`.
    public func rpcRaw(method: String, params: JSONValue) async throws -> JSONValue {
        guard isConnected else { throw WorkspaceClientError.notConnected }

        let toolId: ToolId
        do {
            toolId = try ToolId(WORKSPACE_RPC_TOOL_ID)
        } catch {
            throw WorkspaceClientError.transport("invalid workspace_rpc tool id")
        }

        let args: JSONValue = .object([
            "method": .string(method),
            "params": params,
        ])

        let work: @Sendable () async -> Result<TypedToolOutput, ToolError> = {
            let stream = await self.harness.call(
                toolId: toolId,
                args: args,
                ctx: ToolCallContext()
            )
            return await consumeStreamTerminal(stream)
        }

        let result: Result<TypedToolOutput, ToolError>
        if let deadlineMs {
            result = await withTimeout(ms: deadlineMs, method: method, work)
        } else {
            result = await work()
        }

        switch result {
        case .success(let typed):
            return typed.value
        case .failure(let err):
            if isTransportFatal(err) {
                markDisconnected()
            }
            if err.kind == .timeout {
                throw WorkspaceClientError.timeout(method: method, afterMs: deadlineMs ?? 0)
            }
            throw WorkspaceClientError.transport(err.detail)
        }
    }

    /// Typed RPC: method and response type from `WorkspaceRpc`.
    public func rpc<R: WorkspaceRpc>(_ req: R) async throws -> R.Response
    where R.Response: Hashable & Equatable {
        let params: JSONValue
        do {
            params = try JSONValue.encode(req)
        } catch {
            throw WorkspaceClientError.decode(method: R.method, detail: "\(error)")
        }
        let raw = try await rpcRaw(method: R.method, params: params)
        let envelope: RpcEnvelope<R.Response>
        do {
            envelope = try raw.decode(RpcEnvelope<R.Response>.self)
        } catch {
            throw WorkspaceClientError.decode(method: R.method, detail: "\(error)")
        }
        switch envelope.intoResult() {
        case .success(let value):
            return value
        case .failure(let rpcErr):
            throw WorkspaceClientError.rpc(rpcErr)
        }
    }
}

// MARK: - Connected flag

public final class ConnectedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool

    public init(_ value: Bool = true) {
        self._value = value
    }

    public var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return _value
    }

    public func set(_ value: Bool) {
        lock.lock()
        _value = value
        lock.unlock()
    }
}

// MARK: - Timeout

private func withTimeout(
    ms: UInt64,
    method: String,
    _ work: @escaping @Sendable () async -> Result<TypedToolOutput, ToolError>
) async -> Result<TypedToolOutput, ToolError> {
    await withTaskGroup(of: Result<TypedToolOutput, ToolError>?.self) { group in
        group.addTask {
            await work()
        }
        group.addTask {
            let ns = UInt64(ms) * 1_000_000
            try? await Task.sleep(nanoseconds: ns)
            return nil
        }
        var first: Result<TypedToolOutput, ToolError>?
        for await item in group {
            if let item {
                first = item
                group.cancelAll()
                break
            } else if first == nil {
                // timeout won
                first = .failure(.timeout(
                    toolId: try! ToolId(WORKSPACE_RPC_TOOL_ID),
                    detail: "\(method) timed out after \(ms)ms"
                ))
                group.cancelAll()
                break
            }
        }
        return first ?? .failure(.networkError("timeout race failed"))
    }
}
