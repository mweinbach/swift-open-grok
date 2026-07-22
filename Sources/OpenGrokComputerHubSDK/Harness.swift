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
public final class ToolHarness: @unchecked Sendable {
    public let local: LocalRegistry
    public private(set) var connection: HubConnection?
    public private(set) var sessionId: SessionId?
    private let cancelTokens = NSLock()
    private var activeCancels: [ToolCallId: CancellationToken] = [:]

    public init(local: LocalRegistry = LocalRegistry()) {
        self.local = local
    }

    public func bindSession(_ sessionId: SessionId) {
        self.sessionId = sessionId
    }

    public func attach(connection: HubConnection) {
        self.connection = connection
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
        defer {
            cancelTokens.lock()
            activeCancels.removeValue(forKey: ctx.callId)
            cancelTokens.unlock()
        }

        if token.isCancelled {
            return terminalOnly(
                Result<TypedToolOutput, ToolError>.failure(
                    .cancelled(toolId: toolId, detail: "cancelled")
                )
            )
        }

        // Local first (local-shadows-remote).
        if let handle = local.get(toolId) {
            return await handle.execute(ctx: ctx, args: args)
        }

        // Remote fallback.
        if let connection, connection.isConnected,
           let client = connection.connectionClient(),
           let sessionId
        {
            let transport = RemoteTransport(
                connection: client,
                principal: Principal.new(try! UserId("harness")).withSession(sessionId),
                defaultSessionId: sessionId
            )
            return await transport.call(toolId: toolId, args: args, ctx: ctx)
        }

        return terminalOnly(
            Result<TypedToolOutput, ToolError>.failure(
                .notFound(toolId: toolId, detail: "tool not found: \(toolId)")
            )
        )
    }

    public func cancel(callId: ToolCallId) {
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

    public init() {}

    public func withLocal(_ tool: any ToolDyn, registration: ToolRegistration) -> ToolHarnessBuilder {
        var c = self
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

    public func build() -> ToolHarness {
        let h = ToolHarness(local: local)
        if let connection { h.attach(connection: connection) }
        if let sessionId { h.bindSession(sessionId) }
        return h
    }
}
