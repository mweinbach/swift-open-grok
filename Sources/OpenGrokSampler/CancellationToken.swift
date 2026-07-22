// CancellationToken.swift
//
// Cooperative cancellation for per-request sampling tasks.
// Mirrors Rust `tokio_util::sync::CancellationToken` usage.

import Foundation

/// Cooperative cancellation token shared between the actor and request tasks.
public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        let waiters: [CheckedContinuation<Void, Never>] = {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { return [] }
            cancelled = true
            let w = self.waiters
            self.waiters = []
            return w
        }()
        for w in waiters {
            w.resume()
        }
    }

    /// Suspend until cancelled. Returns immediately if already cancelled.
    public func cancelled() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if cancelled {
                lock.unlock()
                cont.resume()
            } else {
                waiters.append(cont)
                lock.unlock()
            }
        }
    }
}
