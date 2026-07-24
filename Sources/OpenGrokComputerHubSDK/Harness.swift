// Harness.swift
//
// ToolHarness — local registry + optional remote dispatch surface.
// Ported from `xai-computer-hub-sdk/src/harness.rs`.

import Foundation
import OpenGrokComputerHubCore
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime
import OpenGrokToolTypes

/// In-process tool registry used by the harness.
public final class LocalRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tools: [ToolId: any ToolHandle] = [:]
    private var registrations: [ToolId: ToolRegistration] = [:]

    public init() {}

    public func register(_ handle: any ToolHandle, registration: ToolRegistration) {
        lock.lock()
        defer { lock.unlock() }
        let id = handle.id()
        tools[id] = handle
        registrations[id] = registration
    }

    public func registerDyn(_ tool: any ToolDyn, registration: ToolRegistration) {
        register(ErasedTool(tool), registration: registration)
    }

    public func get(_ id: ToolId) -> (any ToolHandle)? {
        lock.lock(); defer { lock.unlock() }
        return tools[id]
    }

    public func registration(_ id: ToolId) -> ToolRegistration? {
        lock.lock(); defer { lock.unlock() }
        return registrations[id]
    }

    public func list() -> [ToolRegistration] {
        lock.lock(); defer { lock.unlock() }
        return Array(registrations.values)
    }
}

/// Harness entry point: local tools + optional remote connection.
///
/// Local-shadows-remote: a local registration always wins. Remote-only
/// tools are dispatched exclusively through the bound connection; a
/// missing remote never silently invents a local path. Unsupported
/// remote methods return `unsupportedRemoteOperation`.
public final class ToolHarness: @unchecked Sendable {
    public let local: LocalRegistry
    public private(set) var connection: HubConnection?
    public private(set) var sessionId: SessionId?
    public private(set) var principal: Principal?
    public var requiredScopes: [String]
    public let cancelRegistry: CancelRegistry
    private let cancelTokens = NSLock()
    private var activeCancels: [ToolCallId: CancellationToken] = [:]

    public init(
        local: LocalRegistry = LocalRegistry(),
        requiredScopes: [String] = [localInvokeScope],
        cancelRegistry: CancelRegistry = CancelRegistry()
    ) {
        self.local = local
        self.requiredScopes = requiredScopes
        self.cancelRegistry = cancelRegistry
    }

    public func bindSession(_ sessionId: SessionId) {
        self.sessionId = sessionId
        if var p = principal {
            p = p.withSession(sessionId)
            principal = p
        }
        connection?.bindSession(sessionId)
    }

    public func attach(connection: HubConnection) {
        self.connection = connection
    }

    public func setPrincipal(_ principal: Principal) {
        self.principal = principal
    }

    public func call(
        toolId: ToolId,
        args: JSONValue,
        ctx: ToolCallContext = ToolCallContext()
    ) async -> ToolStream<TypedToolOutput> {
        let token = CancellationToken()
        cancelTokens.lock()
        activeCancels[ctx.callId] = token
        cancelTokens.unlock()
        cancelRegistry.register(callId: ctx.callId, token: token)
        defer {
            cancelTokens.lock()
            activeCancels[ctx.callId] = nil
            cancelTokens.unlock()
            cancelRegistry.deregister(callId: ctx.callId)
        }

        if token.isCancelled {
            return terminalOnly(
                Result<TypedToolOutput, ToolError>.failure(
                    .cancelled(toolId: toolId, detail: "cancelled")
                )
            )
        }

        // Capability-scope + bound check against principal when present.
        let principal = self.principal
            ?? Principal.new(try! UserId("harness")).withScope(localInvokeScope)
        let caps = local.get(toolId)?.capabilities()
        if let denied = admitCall(
            principal: principal,
            requiredScopes: requiredScopes,
            capabilities: caps,
            args: args
        ) {
            return terminalOnly(Result<TypedToolOutput, ToolError>.failure(denied))
        }

        // Local first (local-shadows-remote).
        if let handle = local.get(toolId) {
            return await handle.execute(ctx: ctx, args: args)
        }

        // Remote fallback — never invent local execution when the tool is
        // only reachable remotely (or not at all).
        if let connection, connection.isConnected,
           let client = connection.connectionClient(),
           let sessionId
        {
            let transport = RemoteTransport(
                connection: client,
                principal: principal.withSession(sessionId),
                defaultSessionId: sessionId,
                requiredScopes: requiredScopes
            )
            return await transport.call(toolId: toolId, args: args, ctx: ctx)
        }

        // Remote plane intended but unavailable: fail closed, do not
        // fabricate a local path.
        if connection != nil, !connection!.isConnected {
            return terminalOnly(
                Result<TypedToolOutput, ToolError>.failure(
                    .networkError("remote hub not connected for \(toolId.rawValue)")
                )
            )
        }

        return terminalOnly(
            Result<TypedToolOutput, ToolError>.failure(
                .notFound(toolId: toolId, detail: "tool not found: \(toolId)")
            )
        )
    }

    public func cancel(callId: ToolCallId) {
        cancelRegistry.cancel(callId: callId)
        cancelTokens.lock()
        activeCancels[callId]?.cancel()
        cancelTokens.unlock()
    }
}

/// Builder for `ToolHarness`.
public struct ToolHarnessBuilder {
    private var local = LocalRegistry()
    private var connection: HubConnection?
    private var sessionId: SessionId?
    private var principal: Principal?
    private var requiredScopes: [String] = [localInvokeScope]

    public init() {}

    public func withLocal(_ tool: any ToolDyn, registration: ToolRegistration) -> ToolHarnessBuilder {
        let c = self
        c.local.registerDyn(tool, registration: registration)
        return c
    }

    public func withConnection(_ connection: HubConnection) -> ToolHarnessBuilder {
        var c = self
        c.connection = connection
        return c
    }

    public func withSession(_ sessionId: SessionId) -> ToolHarnessBuilder {
        var c = self
        c.sessionId = sessionId
        return c
    }

    public func withPrincipal(_ principal: Principal) -> ToolHarnessBuilder {
        var c = self
        c.principal = principal
        return c
    }

    public func withRequiredScopes(_ scopes: [String]) -> ToolHarnessBuilder {
        var c = self
        c.requiredScopes = scopes
        return c
    }

    public func build() -> ToolHarness {
        let h = ToolHarness(local: local, requiredScopes: requiredScopes)
        if let connection { h.attach(connection: connection) }
        if let sessionId { h.bindSession(sessionId) }
        if let principal { h.setPrincipal(principal) }
        return h
    }
}
