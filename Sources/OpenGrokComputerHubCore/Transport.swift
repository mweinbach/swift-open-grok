// Transport.swift
//
// Object-safe transport trait + Principal. Ported from
// `xai-computer-hub-core/src/transport.rs`.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime

/// Authenticated identity bound to a transport at handshake time.
public struct Principal: Sendable, Equatable, Hashable {
    public var userId: UserId
    public var sessionIds: [SessionId]
    public var scopes: [String]
    public var audiences: [String]

    public init(
        userId: UserId,
        sessionIds: [SessionId] = [],
        scopes: [String] = [],
        audiences: [String] = []
    ) {
        self.userId = userId
        self.sessionIds = sessionIds
        self.scopes = scopes
        self.audiences = audiences
    }

    public static func new(_ userId: UserId) -> Principal {
        Principal(userId: userId)
    }

    public func withSession(_ sessionId: SessionId) -> Principal {
        var c = self
        c.sessionIds.append(sessionId)
        return c
    }

    public func withScope(_ scope: String) -> Principal {
        var c = self
        if !c.scopes.contains(scope) {
            c.scopes.append(scope)
        }
        return c
    }

    public func withAudience(_ aud: String) -> Principal {
        var c = self
        if !c.audiences.contains(aud) {
            c.audiences.append(aud)
        }
        return c
    }

    public func hasScope(_ scope: String) -> Bool {
        scopes.contains(scope)
    }

    /// True when every required scope is present on the principal.
    public func hasAllScopes(_ required: [String]) -> Bool {
        required.allSatisfy { hasScope($0) }
    }

    public func authorizesSession(_ sessionId: SessionId) -> Bool {
        sessionIds.contains(sessionId)
    }
}

/// Object-safe transport for dispatching tool calls.
public protocol HubTransport: Sendable {
    var kind: TransportKind { get }
    func authorize() async throws -> Principal
    func call(
        toolId: ToolId,
        args: JSONValue,
        ctx: ToolCallContext
    ) async -> ToolStream<TypedToolOutput>
}

// MARK: - Capability / bounds helpers

/// Default absolute byte bound for a single tool-call args payload when
/// the tool does not declare `maxFrameBytes`.
public let defaultMaxCallArgsBytes: UInt32 = 4 * 1024 * 1024

/// Estimate UTF-8 size of a JSON value (compact encoding).
public func estimateJSONByteCount(_ value: JSONValue) -> Int {
    guard let data = try? JSONEncoder().encode(value) else {
        return 0
    }
    return data.count
}

/// Capability-scoped admission gate: scope presence + payload bound.
///
/// Returns `nil` when the call is admitted; otherwise a terminal error
/// that must not be silently weakened.
public func admitCall(
    principal: Principal,
    requiredScopes: [String],
    capabilities: ToolCapabilities?,
    args: JSONValue
) -> ToolError? {
    if !requiredScopes.isEmpty, !principal.hasAllScopes(requiredScopes) {
        let missing = requiredScopes.filter { !principal.hasScope($0) }
        return .permissionDenied(
            "missing required scope(s): \(missing.joined(separator: ", "))"
        )
    }
    let limit = capabilities?.maxFrameBytes ?? defaultMaxCallArgsBytes
    let size = estimateJSONByteCount(args)
    if size > Int(limit) {
        return .custom(
            code: "payload_too_large",
            detail: "payload \(size) bytes exceeds limit \(limit)"
        )
    }
    return nil
}
