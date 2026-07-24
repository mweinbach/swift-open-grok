// Connection.swift
//
// Hub connection pool, reconnect ordering, notification demux binding.

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
    case insecureScheme(url: String)
    case invalidConfig(String)
    case networkError(String)

    public var description: String {
        switch self {
        case .notConnected: return "not connected"
        case .handshakeFailed(let d): return "handshake failed: \(d)"
        case .transport(let d): return "transport: \(d)"
        case .cancelled: return "cancelled"
        case .timeout: return "timeout"
        case .unauthorized(let d): return "unauthorized: \(d)"
        case .insecureScheme(let url): return "insecure scheme for \(url)"
        case .invalidConfig(let d): return "invalid config: \(d)"
        case .networkError(let d): return "network: \(d)"
        }
    }
}

/// Ordered reconnect lifecycle events.
///
/// Observed order for a successful recovery:
/// `disconnected` → `reconnecting(attempt:)`* → `reconnected`.
/// A terminal failure ends with `giveUp`.
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
    case raw(JSONValue)
}

/// Multiplexed hub connection state with demux + reconnect ordering.
public final class HubConnection: @unchecked Sendable {
    public let key: PrincipalKey
    public let demux: Demux
    private let lock = NSLock()
    private var _connected: Bool
    private var reconnectHandlers: [@Sendable (ReconnectEvent) -> Void] = []
    private var notificationHandlers: [@Sendable (HubNotification) -> Void] = []
    private var client: (any ConnectionClient)?
    private var reconnectAttempt: Int = 0
    /// Bound sessions refcounted so the last releaser unregisters.
    private let sessionRefs = RefCountedSet<SessionId>()

    public init(
        key: PrincipalKey,
        client: (any ConnectionClient)? = nil,
        connected: Bool = false,
        demux: Demux = Demux()
    ) {
        self.key = key
        self.client = client
        self._connected = connected
        self.demux = demux
        // Fan demux connection-level notifications into HubNotification.
        demux.onNotification { [weak self] value in
            self?.emit(.raw(value))
            if case .object(let map) = value,
               case .string(let method) = map["method"]
            {
                let params = map["params"] ?? .null
                self?.emit(.custom(method: method, params: params))
            }
        }
    }

    public var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return _connected
    }

    public func markDisconnected(reason: String) {
        lock.lock()
        _connected = false
        reconnectAttempt = 0
        let handlers = reconnectHandlers
        lock.unlock()
        // Fail in-flight waiters on disconnect.
        demux.drainWaiters(error: .networkError(reason))
        demux.drainProgressWaiters()
        for h in handlers { h(.disconnected(reason: reason)) }
    }

    /// Signal an outbound reconnect attempt (ordered after disconnected).
    public func markReconnecting(attempt: Int) {
        lock.lock()
        reconnectAttempt = attempt
        let handlers = reconnectHandlers
        lock.unlock()
        for h in handlers { h(.reconnecting(attempt: attempt)) }
    }

    public func markConnected() {
        lock.lock()
        _connected = true
        reconnectAttempt = 0
        let handlers = reconnectHandlers
        lock.unlock()
        for h in handlers { h(.reconnected) }
    }

    public func markGiveUp(reason: String) {
        lock.lock()
        _connected = false
        let handlers = reconnectHandlers
        lock.unlock()
        for h in handlers { h(.giveUp(reason: reason)) }
    }

    /// Run a reconnect sequence: disconnected → reconnecting* → reconnected|giveUp.
    public func runReconnectSequence(
        attempts: Int,
        succeedOn: Int,
        reason: String = "drop"
    ) {
        markDisconnected(reason: reason)
        for attempt in 1...max(1, attempts) {
            markReconnecting(attempt: attempt)
            if attempt == succeedOn {
                markConnected()
                return
            }
        }
        markGiveUp(reason: "exhausted \(attempts) attempts")
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

    /// Refcount a session bind. Returns true on the 0→1 edge.
    @discardableResult
    public func bindSession(_ sessionId: SessionId) -> Bool {
        let (prev, _) = sessionRefs.increment(sessionId)
        if prev == 0 {
            demux.registerSessionInbox(sessionId)
        }
        return prev == 0
    }

    /// Refcount a session unbind. Returns true when the last holder released.
    @discardableResult
    public func unbindSession(_ sessionId: SessionId) -> Bool {
        if let next = sessionRefs.decrement(sessionId), next == 0 {
            demux.unregisterSessionInbox(sessionId)
            return true
        }
        return false
    }

    public func boundSessionCount() -> Int { sessionRefs.count }
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
        let conn = HubConnection(key: key, connected: true)
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

    public func refCount(for key: PrincipalKey) -> Int {
        lock.lock(); defer { lock.unlock() }
        return connections[key]?.refs ?? 0
    }

    public var connectionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return connections.count
    }
}
