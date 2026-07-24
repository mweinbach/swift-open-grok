// RefCount.swift
//
// Generic refcounted-binding helper. Ported from
// `xai-computer-hub-sdk/src/refcount.rs`.

import Foundation

/// Refcounted set keyed by `K`. `increment` returns `(prev, new)`;
/// `decrement` returns the post-decrement count (`0` means removed).
public final class RefCountedSet<K: Hashable>: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [K: UInt64] = [:]

    public init() {}

    /// Increment `key`'s refcount. Returns `(prevCount, newCount)`.
    @discardableResult
    public func increment(_ key: K) -> (UInt64, UInt64) {
        lock.lock()
        defer { lock.unlock() }
        let prev = counts[key] ?? 0
        let next = prev == UInt64.max ? UInt64.max : prev &+ 1
        counts[key] = next
        return (prev, next)
    }

    /// Decrement `key`. Returns post-decrement count, or `nil` if absent.
    @discardableResult
    public func decrement(_ key: K) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard let cur = counts[key] else { return nil }
        let next = cur == 0 ? 0 : cur - 1
        if next == 0 {
            counts[key] = nil
        } else {
            counts[key] = next
        }
        return next
    }

    public func snapshotKeys() -> [K] {
        lock.lock(); defer { lock.unlock() }
        return Array(counts.keys)
    }

    public var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return counts.isEmpty
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return counts.count
    }

    public func count(for key: K) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return counts[key] ?? 0
    }
}
