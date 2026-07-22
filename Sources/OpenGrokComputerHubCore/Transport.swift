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
        c.scopes.append(scope)
        return c
    }

    public func withAudience(_ aud: String) -> Principal {
        var c = self
        c.audiences.append(aud)
        return c
    }

    public func hasScope(_ scope: String) -> Bool {
        scopes.contains(scope)
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
