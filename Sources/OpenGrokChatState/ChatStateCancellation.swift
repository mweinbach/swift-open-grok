// ChatStateCancellation.swift
//
// Sendable cancellation seam for `ChatStateActor`, mirroring
// `tokio_util::sync::CancellationToken` used by the Rust actor spawn/run loop.

import Foundation

/// Cooperative cancellation token for `ChatStateActor`.
///
/// Callers pass a token into `spawn` / `spawnWithPruning` and later call
/// `cancel()` to shut the actor down. The spawn site registers an `onCancel`
/// handler that finishes the command stream; the run loop then drains any
/// remaining buffered commands and completes awaited replies exactly once as
/// actor-dead.
public final class ChatStateCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var onCancelHandlers: [(@Sendable () -> Void)] = []

    public init() {}

    /// Whether `cancel()` has been observed.
    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Register a handler invoked exactly once when cancellation fires.
    /// If the token is already cancelled, the handler runs immediately.
    public func onCancel(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
            return
        }
        onCancelHandlers.append(handler)
        lock.unlock()
    }

    /// Signal cancellation. Idempotent; wakes every waiter and runs handlers
    /// exactly once.
    public func cancel() {
        lock.lock()
        if cancelled {
            lock.unlock()
            return
        }
        cancelled = true
        let pending = waiters
        waiters.removeAll()
        let handlers = onCancelHandlers
        onCancelHandlers.removeAll()
        lock.unlock()
        for waiter in pending {
            waiter.resume()
        }
        for handler in handlers {
            handler()
        }
    }

    /// Suspend until `cancel()` is called. Returns immediately if already cancelled.
    public func waitUntilCancelled() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }
}
