// OpenGrokTTY.swift
//
// TTY capability detection and raw-mode lease contract (W2-S4 bootstrap
// scaffold). macOS/Linux use POSIX termios; Windows uses the Console API.
// Platform-neutral callers consume `TerminalSize`/`TerminalCapability`/
// `RawModeLease` and typed `TTYError.unsupported` rather than conditional code.
//
// Per the plan, same-wave slices do not import another same-wave concrete
// target, so this target defines its own minimal `TerminalSize`/
// `TerminalCapability` value types rather than importing
// `OpenGrokTerminalCore` (W2-S5). The owning slice bridges these at the
// composition layer.
//
// The owning slice (W2-S4) replaces `BootstrapTTYAdapter` with the real
// termios/Console adapter. Reference: xai-tty-utils.

import Foundation
#if os(macOS)
import Darwin
#endif
#if os(Linux)
import Glibc
#endif
// Windows Console API is wired by W2-S4 via #if os(Windows).

/// TTY errors. `unsupported` is returned only for genuine OS capability gaps.
public enum TTYError: Error, Equatable, Sendable {
    case notATTY
    case unsupported(String)
    case ioFailed(String)
}

/// Terminal size as observed by the TTY (local to this target; bridged to the
/// canonical cell-grid size at the composition layer).
public struct TerminalSize: Sendable, Equatable, Codable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) {
        precondition(width >= 0 && height >= 0)
        self.width = width
        self.height = height
    }
}

/// Terminal feature capabilities reported by the TTY adapter.
public struct TerminalCapability: Sendable, Equatable, Codable {
    public var supportsMouse: Bool
    public var supportsAlternateScreen: Bool
    public var supportsHyperlinks: Bool
    public init(supportsMouse: Bool = true, supportsAlternateScreen: Bool = true, supportsHyperlinks: Bool = true) {
        self.supportsMouse = supportsMouse
        self.supportsAlternateScreen = supportsAlternateScreen
        self.supportsHyperlinks = supportsHyperlinks
    }
}

/// A raw-mode lease that restores the previous terminal state on `release()`
/// or when deinited. Restoration must be idempotent and run on normal exit,
/// throw, cancellation, and crash-signal paths.
public protocol RawModeLease: AnyObject, Sendable {
    func release() async
}

/// TTY detection, capability negotiation, raw-mode entry, and read/write.
public protocol TTYAdapter: Sendable {
    /// Identity of the controlled TTY (e.g. `fd:n` or a device path), if any.
    var identifier: String? { get }
    /// Whether the stream is a terminal.
    func isATTY() -> Bool
    /// Current terminal size, if discoverable.
    func size() -> TerminalSize?
    /// Negotiated capabilities.
    func capabilities() -> TerminalCapability
    /// Enter raw mode, returning a lease that restores the prior state.
    func enterRawMode() async throws -> any RawModeLease
    /// Write bytes to the TTY.
    func write(_ data: Data) async throws
}

/// Bootstrap adapter that performs only the dependency-free `isatty` check on
/// POSIX platforms and reports `unsupported` for raw-mode/size/write. The
/// owning slice (W2-S4) replaces this with the full termios/Console adapter.
public struct BootstrapTTYAdapter: TTYAdapter {
    private let fd: Int32
    public init(fd: Int32 = 1) { self.fd = fd }

    public var identifier: String? { "fd:\(fd)" }

    public func isATTY() -> Bool {
        #if os(macOS) || os(Linux)
        return isatty(fd) != 0
        #else
        return false
        #endif
    }

    public func size() -> TerminalSize? { nil }

    public func capabilities() -> TerminalCapability { TerminalCapability() }

    public func enterRawMode() async throws -> any RawModeLease {
        throw TTYError.unsupported("BootstrapTTYAdapter does not implement raw mode; W2-S4 provides the platform adapter.")
    }

    public func write(_ data: Data) async throws {
        throw TTYError.unsupported("BootstrapTTYAdapter does not implement TTY writes; W2-S4 provides the platform adapter.")
    }
}
