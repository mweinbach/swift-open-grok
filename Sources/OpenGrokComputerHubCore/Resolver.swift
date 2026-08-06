// Resolver.swift
//
// CompoundResolver with local-shadows-remote rule + inner-dispatch.
// Ported from `xai-computer-hub-core/src/resolver.rs` + `inner.rs`.

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

    public var isRemote: Bool {
        if case .remote = self { return true }
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

    public func unregister(sessionId: SessionId, toolId: ToolId) {
        lock.lock()
        defer { lock.unlock() }
        bySession[sessionId]?[toolId] = nil
        if bySession[sessionId]?.isEmpty == true {
            bySession[sessionId] = nil
        }
    }

    public func dropSession(_ sessionId: SessionId) {
        lock.lock()
        defer { lock.unlock() }
        bySession[sessionId] = nil
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

/// Placeholder principal for the resolver's payload-bound check.
///
/// Grants nothing: the only call site passes an empty `requiredScopes`,
/// so this value never participates in a scope decision. Hoisted out of
/// the dispatch path so that path carries no `try!`.
let resolverPrincipal: Principal = {
    // `UserId` rejects only the empty string, so this cannot fail.
    guard let id = try? UserId("resolver") else {
        preconditionFailure(#"UserId("resolver") is non-empty"#)
    }
    return Principal.new(id)
}()

/// Local shadows remote when both planes register the same tool id.
public final class CompoundResolver: @unchecked Sendable {
    public let local: any ToolRegistry
    public let remote: (any ToolRegistry)?
    /// Host permission/sandbox gate for everything dispatched through
    /// this resolver — including tool-calls-tool traffic arriving via
    /// `InnerDispatchForResolver`, which is otherwise the easiest way for
    /// a gated tool to launder a call through an ungated one.
    public let mediation: HubMediation

    public init(
        local: any ToolRegistry,
        mediation: HubMediation,
        remote: (any ToolRegistry)? = nil
    ) {
        self.local = local
        self.mediation = mediation
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
        // Payload bound from declared capabilities. `requiredScopes` is
        // empty because this path has no handshake behind it — the scope
        // check belongs to the transport that called us, and duplicating
        // it here with an invented principal would only look like a gate.
        //
        // Divergence from `resolver.rs:265` (`resolve_and_dispatch`),
        // which dispatches with no bound at all: this port keeps the
        // payload ceiling because `InnerDispatchForResolver` makes the
        // path reachable from tool code.
        if let denied = admitCall(
            principal: resolverPrincipal,
            requiredScopes: [],
            capabilities: resolved.handle.capabilities(),
            args: args
        ) {
            return terminalOnly(Result<TypedToolOutput, ToolError>.failure(denied))
        }
        if let denied = await mediation.admit(
            HubCallRequest(
                toolId: toolId,
                toolCallId: ctx.callId,
                sessionId: sessionId,
                origin: resolved.isLocal ? .local : .remote,
                arguments: args,
                isReadOnly: resolved.handle.capabilities().isReadOnly
            )
        ) {
            return terminalOnly(Result<TypedToolOutput, ToolError>.failure(denied))
        }
        return await resolved.handle.execute(ctx: ctx, args: args)
    }
}

// MARK: - Inner dispatch

/// Resolver-backed `ToolDispatch` for tools that call other tools.
///
/// Holds the resolver by unowned reference pattern via a weak box so the
/// hub can tear down without orphaning cancelable tasks. When the
/// resolver is gone, inner calls fail with `computer_hub_dropped`.
public final class InnerDispatchForResolver: ToolDispatch, @unchecked Sendable {
    private let lock = NSLock()
    private weak var resolver: CompoundResolver?
    public let sessionId: SessionId

    public init(resolver: CompoundResolver, sessionId: SessionId) {
        self.resolver = resolver
        self.sessionId = sessionId
    }

    public func detach() {
        lock.lock()
        resolver = nil
        lock.unlock()
    }

    public func call(
        toolId: ToolId,
        args: JSONValue,
        ctx: ToolCallContext
    ) async -> ToolStream<TypedToolOutput> {
        let r = currentResolver()
        guard let r else {
            return terminalOnly(
                Result<TypedToolOutput, ToolError>.failure(
                    .custom(
                        code: "computer_hub_dropped",
                        detail: "computer hub dropped before inner call could execute"
                    )
                )
            )
        }
        return await r.resolveAndDispatch(
            sessionId: sessionId,
            toolId: toolId,
            args: args,
            ctx: ctx
        )
    }

    private func currentResolver() -> CompoundResolver? {
        lock.lock()
        defer { lock.unlock() }
        return resolver
    }
}
