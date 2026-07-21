// Stderr.swift
//
// Serialized access to the TUI's stderr writer. Ported from
// xai-grok-shared/src/stderr.rs.
//
// The Rust implementation uses `parking_lot::Mutex` to serialize stderr
// writes and `xai_tty_utils::dup_tui_stderr` to write to the real terminal
// even when fd 2 has been redirected to `/dev/null`. The concrete TTY
// redirection is owned by W2-S4 (OpenGrokTTY / xai-tty-utils).
//
// This file provides:
//   * A `StderrLock` protocol that serializes stderr writes.
//   * A default `FoundationStderrLock` that uses `FileHandle.standardError`.
//   * A `withLockedStderr` helper that executes a closure with exclusive
//     access to the stderr writer.
//
// The TTY-aware stderr redirect (dup of the real terminal fd) is integrated
// by W2-S4; this target defines the locking contract so shared code can
// reference it without importing the TTY target.

import Foundation

/// Protocol for serialized access to the TUI's stderr writer.
///
/// The concrete implementation may write to a dup'd fd that points at the
/// real terminal (bypassing a `/dev/null` redirect on fd 2), or fall back
/// to normal stderr.
public protocol StderrLocking: Sendable {
    /// Execute `body` with exclusive access to the stderr writer.
    func withLockedStderr<T>(_ body: (FileHandle) throws -> T) throws -> T
}

/// Default `StderrLocking` implementation using `FileHandle.standardError`.
///
/// Uses an `NSLock` for serialization. The TTY-aware redirect (W2-S4) can
/// provide a replacement that writes to a dup'd fd pointing at the real
/// terminal.
public final class FoundationStderrLock: StderrLocking, @unchecked Sendable {
    private let lock = NSLock()

    public init() {}

    public func withLockedStderr<T>(_ body: (FileHandle) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        let stderr = FileHandle.standardError
        return try body(stderr)
    }
}

/// A shared default stderr lock instance.
public let defaultStderrLock: FoundationStderrLock = FoundationStderrLock()

/// Execute `body` with exclusive access to the default stderr writer.
///
/// This is the Swift equivalent of Rust's `with_locked_stderr`.
public func withLockedStderr<T>(_ body: (FileHandle) throws -> T) throws -> T {
    try defaultStderrLock.withLockedStderr(body)
}

/// Write data to stderr under the lock.
public func writeStderr(_ data: Data) throws {
    try withLockedStderr { stderr in
        try stderr.write(contentsOf: data)
    }
}

/// Write a string to stderr under the lock.
public func writeStderr(_ string: String) throws {
    try writeStderr(Data(string.utf8))
}
