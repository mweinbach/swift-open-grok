// Primitives.swift
//
// Canonical shared primitive types across Open Grok:
//   - MonotonicInstant (nanosecond timestamp since boot)
//   - LockHolder (thread-safe synchronized state container)
//   - CancellationToken (thread-safe async cancellation token)
//   - DynamicCodingKey (flexible CodingKey for dynamic decoding)

import Foundation
import Dispatch

// MARK: - MonotonicInstant

/// Portable monotonic timestamp (nanoseconds since boot).
public struct MonotonicInstant: Sendable, Equatable, Hashable, Comparable {
    public var nanoseconds: UInt64

    public var uptimeNanoseconds: UInt64 {
        nanoseconds
    }

    public init(nanoseconds: UInt64) {
        self.nanoseconds = nanoseconds
    }

    public init(uptimeNanoseconds: UInt64) {
        self.nanoseconds = uptimeNanoseconds
    }

    public static func now() -> MonotonicInstant {
        MonotonicInstant(nanoseconds: DispatchTime.now().uptimeNanoseconds)
    }

    public static func < (lhs: MonotonicInstant, rhs: MonotonicInstant) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    public func advanced(bySeconds seconds: TimeInterval) -> MonotonicInstant {
        if seconds >= 0 {
            return MonotonicInstant(nanoseconds: nanoseconds &+ UInt64(seconds * 1_000_000_000))
        } else {
            return MonotonicInstant(nanoseconds: nanoseconds &- UInt64((-seconds) * 1_000_000_000))
        }
    }

    public func seconds(until other: MonotonicInstant) -> TimeInterval {
        if other.nanoseconds >= nanoseconds {
            return TimeInterval(other.nanoseconds - nanoseconds) / 1_000_000_000
        }
        return -TimeInterval(nanoseconds - other.nanoseconds) / 1_000_000_000
    }
}

// MARK: - LockHolder

/// Portable lock over mutable state. Sync `withLock` is safe to call from async.
public final class LockHolder<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    public init(_ state: State) {
        self.state = state
    }

    @discardableResult
    public func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}

// MARK: - CancellationToken

/// Cooperative cancellation token shared between actors and async tasks.
public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var handlers: [@Sendable () -> Void] = []

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        let (waitersToResume, handlersToInvoke): ([CheckedContinuation<Void, Never>], [@Sendable () -> Void]) = {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { return ([], []) }
            cancelled = true
            let w = self.waiters
            let h = self.handlers
            self.waiters = []
            self.handlers = []
            return (w, h)
        }()
        for w in waitersToResume {
            w.resume()
        }
        for h in handlersToInvoke {
            h()
        }
    }

    /// Register a synchronous closure to be called when cancelled.
    /// If already cancelled, fires immediately.
    public func onCancel(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
            return
        }
        handlers.append(handler)
        lock.unlock()
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

    /// Throws CancellationError if cancelled.
    public func throwIfCancelled() throws {
        if isCancelled {
            throw CancellationError()
        }
    }

    /// Throws a custom error if cancelled.
    public func throwIfCancelled<E: Error>(_ error: @autoclosure () -> E) throws {
        if isCancelled {
            throw error()
        }
    }
}

// MARK: - DynamicCodingKey

/// A flexible, hashable CodingKey for dynamic dictionary decoding/encoding.
public struct DynamicCodingKey: CodingKey, Hashable, Sendable {
    public var stringValue: String
    public var intValue: Int?

    public init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    public init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }

    public init(_ string: String) {
        self.stringValue = string
        self.intValue = nil
    }

    public init(stringValue: String, intValue: Int? = nil) {
        self.stringValue = stringValue
        self.intValue = intValue
    }
}
