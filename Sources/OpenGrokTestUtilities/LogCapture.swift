// LogCapture.swift
//
// Port of `xai-test-utils/src/tracing_capture.rs`. The Rust crate counts
// `tracing` events whose `message` field starts with a registered prefix,
// via a `tracing_subscriber::Layer`. Swift does not yet have an equivalent
// structured logging layer in this port (`OpenGrokTracing` lands in Wave 2),
// so this capture ships a small `TestLogger` protocol + a lock-protected
// counter that test code wires up directly. When `OpenGrokTracing` lands,
// it can conform to `TestLogger` and feed the same counter without breaking
// these tests.
//
// The Rust counter is `Arc<Vec<(&'static str, AtomicUsize)>>` —
// lock-free-atomic, cheap to clone and share. The Swift analog is a final
// class with an `NSLock`-protected `[String: Int]`, marked
// `@unchecked Sendable` so it can be shared across tasks/actors without
// crossing actor isolation at the protocol boundary.

import Foundation

/// A minimal logger protocol that `MessagePrefixCounter` can observe. Test
/// code either calls `record` directly or wraps a richer logger (e.g. the
/// future `OpenGrokTracing` actor) in a conforming adapter.
public protocol TestLogger: Sendable {
    /// Record a single log line. `message` is the formatted text the prefix
    /// counter inspects; `metadata` is reserved for future structured
    /// fields and is ignored by the counter.
    func record(level: TestLogLevel, message: String, metadata: [String: String])
}

/// Log level mirroring the common Rust `tracing` levels.
public enum TestLogLevel: String, Sendable, CaseIterable {
    case trace, debug, info, warn, error
}

/// A `TestLogger` that counts, per registered prefix, the messages whose
/// `message` starts with that prefix. Clones share the counts (the underlying
/// storage is shared via a reference type), so multiple producers can feed
/// one counter.
///
/// `@unchecked Sendable` because all mutable state is guarded by an internal
/// `NSLock`. Mirrors the Rust `Arc<Vec<(&'static str, AtomicUsize)>>` — the
/// counts are concurrent-safe and cheap to share.
public final class MessagePrefixCounter: TestLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int]

    /// Registered prefixes (in registration order, mirroring the Rust Vec).
    public let prefixes: [String]

    public init(prefixes: [String]) {
        self.prefixes = prefixes
        self.counts = Dictionary(uniqueKeysWithValues: prefixes.map { ($0, 0) })
    }

    /// Messages counted so far for `prefix`. Crashes on a prefix that was
    /// never registered — that is a bug in the test, not a zero count
    /// (mirrors the Rust `panic!("prefix not registered with this counter")`).
    public func count(for prefix: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let value = counts[prefix] else {
            fatalError("prefix not registered with this counter: \(prefix)")
        }
        return value
    }

    /// Non-crashing accessor for tests that have already validated the prefix.
    public func countOrNil(_ prefix: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[prefix] ?? 0
    }

    /// Reset all counters to zero (e.g. between sub-tests sharing a counter).
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        for k in counts.keys { counts[k] = 0 }
    }

    public func record(level: TestLogLevel, message: String, metadata: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        for prefix in prefixes where message.hasPrefix(prefix) {
            counts[prefix, default: 0] += 1
        }
    }

    /// The full registered-prefix → count snapshot.
    public func snapshot() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }
}

/// A no-op logger for tests that need a `TestLogger` sink but no counting.
public struct NullTestLogger: TestLogger {
    public init() {}
    public func record(level: TestLogLevel, message: String, metadata: [String: String]) {}
}

/// A `TestLogger` that buffers every message in arrival order, for tests that
/// assert on the exact logged text. `@unchecked Sendable` via internal
/// `NSLock`.
public final class BufferingTestLogger: TestLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [(level: TestLogLevel, message: String)] = []

    public init() {}

    public func record(level: TestLogLevel, message: String, metadata: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append((level, message))
    }

    public func messages() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return buffer.map { $0.message }
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll(keepingCapacity: false)
    }
}
