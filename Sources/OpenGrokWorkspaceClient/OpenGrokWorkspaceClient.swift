// OpenGrokWorkspaceClient.swift
//
// Typed client for hub-proxied `workspace.*` RPC methods (Swift port of
// `xai-grok-workspace-client`). Wire types live in OpenGrokWorkspaceTypes;
// this target adds the connected-state latch, generic RPC core, transport-
// fatal disconnect mapping, and typed helpers.

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
    case workspaceUnavailable(ToolError)

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
        case .workspaceUnavailable(let e):
            return "workspace unavailable: \(e.detail)"
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
///
/// Returns `true` for:
/// - `networkError` — direct transport failure
/// - `custom` with `details.code == "protocol_error"` — half-closed WS
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
/// After a fatal transport error the latch stays `false` until
/// `markConnected()` (e.g. from an SDK `onReconnect` callback sharing the
/// same `ConnectedFlag`).
public final class WorkspaceClient: @unchecked Sendable {
    public let harness: ToolHarness
    private let connected: ConnectedFlag
    public var deadlineMs: UInt64?

    public init(harness: ToolHarness, connected: ConnectedFlag = ConnectedFlag(true)) {
        self.harness = harness
        self.connected = connected
        self.deadlineMs = nil
    }

    public init(harness: ToolHarness, connection: HubConnection) {
        self.harness = harness
        self.connected = ConnectedFlag(connection.isConnected)
        self.deadlineMs = nil
        attachReconnect(to: connection)
    }

    /// Share a pre-created connected flag so an SDK reconnect callback
    /// holding the same flag can reset it.
    public static func withConnectedFlag(
        harness: ToolHarness,
        connected: ConnectedFlag
    ) -> WorkspaceClient {
        WorkspaceClient(harness: harness, connected: connected)
    }

    public static func withHubConnection(
        harness: ToolHarness,
        connection: HubConnection
    ) -> WorkspaceClient {
        WorkspaceClient(harness: harness, connection: connection)
    }

    public func withDeadline(ms: UInt64) -> WorkspaceClient {
        let c = WorkspaceClient(harness: harness, connected: connected)
        c.deadlineMs = ms
        return c
    }

    public var isConnected: Bool { connected.value }

    public func markDisconnected() { connected.set(false) }
    public func markConnected() { connected.set(true) }

    /// Wire this client to a hub connection so reconnect restores the latch
    /// and transport-fatal disconnects clear it.
    public func attachReconnect(to connection: HubConnection) {
        connection.onReconnect { [weak self] event in
            guard let self else { return }
            switch event {
            case .disconnected:
                self.markDisconnected()
            case .reconnected:
                self.markConnected()
            case .reconnecting, .giveUp:
                break
            }
        }
    }

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
            if OpenGrokComputerHubCore.isWorkspaceUnavailable(err) {
                throw WorkspaceClientError.workspaceUnavailable(err)
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

    // MARK: Typed helpers (Rust WorkspaceClient surface)

    /// `workspace.info` decoded into the typed shape.
    public func info() async throws -> WorkspaceInfo {
        let raw = try await rpc(WorkspaceInfoReq())
        do {
            return try raw.decode(WorkspaceInfo.self)
        } catch {
            throw WorkspaceClientError.decode(
                method: WorkspaceInfoReq.method,
                detail: "\(error)"
            )
        }
    }

    public func gitStatus() async throws -> JSONValue {
        try await rpc(GitStatusReq())
    }

    public func fsList(_ req: FsListReq) async throws -> FsListData {
        try await rpc(req)
    }

    public func fsExists(_ req: FsExistsReq) async throws -> FsExistsData {
        try await rpc(req)
    }

    public func fsReadFile(_ req: FsReadFileReq) async throws -> FsReadFileData {
        try await rpc(req)
    }

    public func fsWriteFile(_ req: FsWriteFileReq) async throws {
        let _: WorkspaceRpcUnit = try await rpc(req)
    }

    public func fsDeleteFile(_ req: FsDeleteFileReq) async throws {
        let _: WorkspaceRpcUnit = try await rpc(req)
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
