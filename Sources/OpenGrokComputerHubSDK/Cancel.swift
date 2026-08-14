// Cancel.swift
//
// Per-session cancel registry with tombstones + cancel-on-drop.
// Ported from `xai-computer-hub-sdk/src/cancel.rs`.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol

/// Upper bound on outstanding pre-registration tombstones.
public let maxPendingCancelTombstones: Int = 8192

public typealias CancellationToken = OpenGrokShared.CancellationToken

/// Cancels a tool call when the holder is deallocated.
public final class CancelOnDrop: @unchecked Sendable {
    private let token: CancellationToken
    private let lock = NSLock()
    private var armed = true

    public init(token: CancellationToken = CancellationToken()) {
        self.token = token
    }

    public var isCancelled: Bool { token.isCancelled }

    public var cancellationToken: CancellationToken { token }

    public func cancel() { token.cancel() }

    /// Disarm so deinit does not cancel (normal completion path).
    public func disarm() {
        lock.lock()
        armed = false
        lock.unlock()
    }

    deinit {
        lock.lock()
        let should = armed
        lock.unlock()
        if should {
            token.cancel()
        }
    }
}

/// Per-session `tool_call_id → CancellationToken` map plus a pending
/// tombstone set for cancels that land before registration.
public final class CancelRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [ToolCallId: CancellationToken] = [:]
    private var pending: Set<ToolCallId> = []
    private var closed = false

    public init() {}

    /// Register `token` for `callId`. Returns whether the token was
    /// pre-cancelled (tombstone or closed registry).
    @discardableResult
    public func register(callId: ToolCallId, token: CancellationToken) -> Bool {
        lock.lock()
        if closed {
            lock.unlock()
            token.cancel()
            return true
        }
        let pre = pending.remove(callId) != nil
        if pre {
            token.cancel()
        }
        map[callId] = token
        // Re-check closed after insert (teardown race).
        if closed {
            map[callId] = nil
            lock.unlock()
            token.cancel()
            return true
        }
        lock.unlock()
        return pre
    }

    /// Cancel a live call, else tombstone the id. Returns true when a
    /// live token was found and cancelled.
    @discardableResult
    public func cancel(callId: ToolCallId) -> Bool {
        lock.lock()
        if let token = map.removeValue(forKey: callId) {
            lock.unlock()
            token.cancel()
            return true
        }
        if pending.count >= maxPendingCancelTombstones, let first = pending.first {
            pending.remove(first)
        }
        pending.insert(callId)
        lock.unlock()
        return false
    }

    /// Deregister without cancelling (normal completion).
    public func deregister(callId: ToolCallId) {
        lock.lock()
        map[callId] = nil
        lock.unlock()
    }

    public var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    public var liveCount: Int {
        lock.lock(); defer { lock.unlock() }
        return map.count
    }

    public var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }

    /// Drain-and-cancel every live token and close the registry.
    @discardableResult
    public func cancelAll() -> Int {
        lock.lock()
        closed = true
        let tokens = Array(map.values)
        map.removeAll()
        pending.removeAll()
        lock.unlock()
        for t in tokens { t.cancel() }
        return tokens.count
    }
}
