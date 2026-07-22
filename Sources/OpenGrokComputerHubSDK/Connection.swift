// Connection.swift
//
// Hub connection pool, reconnect, cancel-on-drop, and notification types.

import Foundation
import OpenGrokComputerHubCore
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime

public enum ClientError: Error, Equatable, Sendable, CustomStringConvertible {
    case notConnected
    case handshakeFailed(String)
    case transport(String)
    case cancelled
    case timeout
    case unauthorized(String)

    public var description: String {
        switch self {
        case .notConnected: return "not connected"
        case .handshakeFailed(let d): return "handshake failed: \(d)"
        case .transport(let d): return "transport: \(d)"
        case .cancelled: return "cancelled"
        case .timeout: return "timeout"
        case .unauthorized(let d): return "unauthorized: \(d)"
        }
    }
}

public enum ReconnectEvent: Sendable, Equatable {
    case disconnected(reason: String)
    case reconnecting(attempt: Int)
    case reconnected
    case giveUp(reason: String)
}

public enum HubNotification: Sendable, Equatable {
    case custom(method: String, params: JSONValue)
    case toolProgress(toolCallId: String, body: JSONValue)
    case workspaceEvent(JSONValue)
}

/// Multiplexed hub connection state.
public final class HubConnection: @unchecked Sendable {
    public let key: PrincipalKey
    private let lock = NSLock()
    private var _connected: Bool
    private var reconnectHandlers: [@(ReconnectEvent) -> Void] = []
    private var notificationHandlers: [@(HubNotification) -> Void] = []
    private var client: (any ConnectionClient)?

    public init(key: PrincipalKey, client: (any ConnectionClient)? = nil, connected: Bool = false) {
        self.key = key
        self.client = client
        self._connected = connected
    }

    public var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return _connected
    }

    public func markDisconnected(reason: String) {
        lock.lock()
        _connected = false
        let handlers = reconnectHandlers
        lock.unlock()
        for h in handlers { h(.disconnected(reason: reason)) }
    }

    public func markConnected() {
        lock.lock()
        _connected = true
        let handlers = reconnectHandlers
        lock.unlock()
        for h in handlers { h(.reconnected) }
    }

    public func onReconnect(_ handler: @escaping @Sendable (ReconnectEvent) -> Void) {
        lock.lock()
        reconnectHandlers.append(handler)
        lock.unlock()
    }

    public func onNotification(_ handler: @escaping @Sendable (HubNotification) -> Void) {
        lock.lock()
        notificationHandlers.append(handler)
        lock.unlock()
    }

    public func emit(_ notification: HubNotification) {
        lock.lock()
        let handlers = notificationHandlers
        lock.unlock()
        for h in handlers { h(notification) }
    }

    public func bindClient(_ client: any ConnectionClient) {
        lock.lock()
        self.client = client
        _connected = true
        lock.unlock()
    }

    public func connectionClient() -> (any ConnectionClient)? {
        lock.lock(); defer { lock.unlock() }
        return client
    }
}

/// Refcounted pool of hub connections keyed by principal.
public final class HubConnectionPool: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [PrincipalKey: (conn: HubConnection, refs: Int)] = [:]

    public init() {}

    public func acquire(key: PrincipalKey) -> HubConnection {
        lock.lock()
        defer { lock.unlock() }
        if let existing = connections[key] {
            connections[key] = (existing.conn, existing.refs + 1)
            return existing.conn
        }
        let conn = HubConnection(key: key)
        connections[key] = (conn, 1)
        return conn
    }

    public func release(key: PrincipalKey) {
        lock.lock()
        defer { lock.unlock() }
        guard let existing = connections[key] else { return }
        let next = existing.refs - 1
        if next <= 0 {
            connections.removeValue(forKey: key)
            existing.conn.markDisconnected(reason: "refcount_zero")
        } else {
            connections[key] = (existing.conn, next)
        }
    }
}

/// Cancels a tool call when the holder is deallocated.
public final class CancelOnDrop: Sendable {
    private let token: CancellationToken

    public init(token: CancellationToken = CancellationToken()) {
        self.token = token
    }

    public var isCancelled: Bool { token.isCancelled }

    public func cancel() { token.cancel() }

    deinit {
        token.cancel()
    }
}

/// Simple cancellation token shared across hub call paths.
public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    public func cancel() {
        lock.lock()
        _cancelled = true
        lock.unlock()
    }
}
