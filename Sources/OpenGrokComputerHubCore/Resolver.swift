// Resolver.swift
//
// CompoundResolver with local-shadows-remote rule. Ported from
// `xai-computer-hub-core/src/resolver.rs`.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime
import OpenGrokToolTypes

/// Object-safe projection of a registered tool.
public protocol ToolHandle: Sendable {
    func id() -> ToolId
    func description(ctx: ListToolsContext) -> ToolDescription
    func capabilities() -> ToolCapabilities
    func shouldList(ctx: ListToolsContext) -> Bool
    func execute(ctx: ToolCallContext, args: JSONValue) async -> ToolStream<TypedToolOutput>
}

extension ToolHandle {
    public func shouldList(ctx: ListToolsContext) -> Bool {
        _ = ctx
        return true
    }
}

/// Active resolution returned by `CompoundResolver.resolve`.
public enum ResolvedTool: Sendable {
    case local(tool: any ToolHandle, registration: ToolRegistration)
    case remote(proxy: any ToolHandle, registration: ToolRegistration)

    public var registration: ToolRegistration {
        switch self {
        case .local(_, let reg), .remote(_, let reg): return reg
        }
    }

    public var handle: any ToolHandle {
        switch self {
        case .local(let tool, _): return tool
        case .remote(let proxy, _): return proxy
        }
    }

    public var isLocal: Bool {
        if case .local = self { return true }
        return false
    }
}

/// Type-erasing wrapper for `ToolDyn`.
public struct ErasedTool: ToolHandle {
    private let inner: any ToolDyn

    public init(_ inner: any ToolDyn) {
        self.inner = inner
    }

    public func id() -> ToolId { inner.id() }
    public func description(ctx: ListToolsContext) -> ToolDescription {
        inner.description(ctx: ctx)
    }
    public func capabilities() -> ToolCapabilities { inner.capabilities() }
    public func shouldList(ctx: ListToolsContext) -> Bool { inner.shouldList(ctx: ctx) }
    public func execute(ctx: ToolCallContext, args: JSONValue) async -> ToolStream<TypedToolOutput> {
        await inner.execute(ctx: ctx, args: args)
    }
}

/// In-memory tool registry for one session plane.
public protocol ToolRegistry: Sendable {
    func get(sessionId: SessionId, toolId: ToolId) -> (handle: any ToolHandle, registration: ToolRegistration)?
    func list(sessionId: SessionId) -> [ToolRegistration]
}

/// Simple dictionary registry.
public final class InMemoryToolRegistry: ToolRegistry, @unchecked Sendable {
    private let lock = NSLock()
    private var bySession: [SessionId: [ToolId: (any ToolHandle, ToolRegistration)]] = [:]

    public init() {}

    public func register(
        sessionId: SessionId,
        handle: any ToolHandle,
        registration: ToolRegistration
    ) {
        lock.lock()
        defer { lock.unlock() }
        var map = bySession[sessionId] ?? [:]
        map[handle.id()] = (handle, registration)
        bySession[sessionId] = map
    }

    public func get(
        sessionId: SessionId,
        toolId: ToolId
    ) -> (handle: any ToolHandle, registration: ToolRegistration)? {
        lock.lock()
        defer { lock.unlock() }
        return bySession[sessionId]?[toolId]
    }

    public func list(sessionId: SessionId) -> [ToolRegistration] {
        lock.lock()
        defer { lock.unlock() }
        return bySession[sessionId]?.values.map(\.1) ?? []
    }
}

/// Local shadows remote when both planes register the same tool id.
public final class CompoundResolver: @unchecked Sendable {
    public let local: any ToolRegistry
    public let remote: (any ToolRegistry)?

    public init(local: any ToolRegistry, remote: (any ToolRegistry)? = nil) {
        self.local = local
        self.remote = remote
    }

    public func resolve(sessionId: SessionId, toolId: ToolId) -> ResolvedTool? {
        if let hit = local.get(sessionId: sessionId, toolId: toolId) {
            return .local(tool: hit.handle, registration: hit.registration)
        }
        if let remote, let hit = remote.get(sessionId: sessionId, toolId: toolId) {
            return .remote(proxy: hit.handle, registration: hit.registration)
        }
        return nil
    }

    public func resolveAndDispatch(
        sessionId: SessionId,
        toolId: ToolId,
        args: JSONValue,
        ctx: ToolCallContext
    ) async -> ToolStream<TypedToolOutput> {
        guard let resolved = resolve(sessionId: sessionId, toolId: toolId) else {
            return terminalOnly(
                Result<TypedToolOutput, ToolError>.failure(
                    .notFound(toolId: toolId, detail: "tool not found: \(toolId)")
                )
            )
        }
        return await resolved.handle.execute(ctx: ctx, args: args)
    }
}
