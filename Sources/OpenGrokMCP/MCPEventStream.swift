import Foundation

/// Fan-out channel for MCP lifecycle events and server-pushed notifications.
///
/// Each subscriber retains only its newest events, so a stalled session cannot
/// block a process readability callback or grow without bound.
public final class MCPEventStream: @unchecked Sendable {
    private let lock = NSLock()
    private let bufferLimit: Int
    private var subscriptions: [UUID: AsyncStream<McpClientEvent>.Continuation] = [:]
    private var isFinished = false

    public init(bufferLimit: Int = 256) {
        self.bufferLimit = max(1, bufferLimit)
    }

    public func subscribe() -> AsyncStream<McpClientEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(bufferLimit)) { continuation in
            continuation.onTermination = { [weak self] _ in
                self?.removeSubscription(id)
            }

            lock.lock()
            guard !isFinished else {
                lock.unlock()
                continuation.finish()
                return
            }
            subscriptions[id] = continuation
            lock.unlock()
        }
    }

    public func publish(_ event: McpClientEvent) {
        lock.lock()
        let current = subscriptions.map { ($0.key, $0.value) }
        lock.unlock()

        for (id, continuation) in current {
            if case .terminated = continuation.yield(event) {
                removeSubscription(id)
            }
        }
    }

    public func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let current = Array(subscriptions.values)
        subscriptions.removeAll()
        lock.unlock()

        for continuation in current {
            continuation.finish()
        }
    }

    private func removeSubscription(_ id: UUID) {
        lock.lock()
        subscriptions.removeValue(forKey: id)
        lock.unlock()
    }

    deinit {
        finish()
    }
}

/// Lock-backed because stdio termination/readability callbacks are not actor
/// isolated, while HTTP transport callbacks run on their transport actor.
final class MCPTransportEventEmitter: @unchecked Sendable {
    private struct Target {
        let events: MCPEventStream
        let serverName: String
        let clientID: UInt64
    }

    private let lock = NSLock()
    private var target: Target?
    private var didClose = false

    func configure(_ events: MCPEventStream?, serverName: String, clientID: UInt64) {
        lock.lock()
        if let events {
            target = Target(events: events, serverName: serverName, clientID: clientID)
        } else {
            target = nil
        }
        lock.unlock()
    }

    func notification(_ notification: MCPNotification) {
        guard let target = currentTarget() else { return }

        switch notification.method {
        case "notifications/tools/list_changed":
            target.events.publish(.toolsChanged(server: target.serverName))
        case "notifications/resources/list_changed":
            target.events.publish(.resourcesChanged(server: target.serverName))
        default:
            break
        }
    }

    func initialized(_ response: MCPResponse) {
        if let error = response.error {
            handshakeFailed(error.message)
        } else if let target = currentTarget() {
            target.events.publish(.ready(server: target.serverName))
        }
    }

    func handshakeFailed(_ error: any Error) {
        handshakeFailed(String(describing: error))
    }

    private func handshakeFailed(_ reason: String) {
        guard let target = currentTarget() else { return }
        target.events.publish(.handshakeFailed(server: target.serverName, reason: reason))
    }

    func transportClosed() {
        lock.lock()
        guard !didClose else {
            lock.unlock()
            return
        }
        didClose = true
        let target = self.target
        lock.unlock()

        if let target {
            target.events.publish(.transportClosed(
                server: target.serverName,
                clientId: target.clientID
            ))
        }
    }

    private func currentTarget() -> Target? {
        lock.lock()
        let target = self.target
        lock.unlock()
        return target
    }
}
