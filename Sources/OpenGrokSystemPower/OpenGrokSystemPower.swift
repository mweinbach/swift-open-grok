// OpenGrokSystemPower.swift
//
// Cross-platform power-inhibition lease contract (W2-S4 bootstrap scaffold).
// macOS uses IOPM assertions, Linux uses inhibitor facilities (systemd-inhibit
// / /proc wakeups), Windows uses SetThreadExecutionState. All three map to one
/// lease protocol.
//
// The owning slice (W2-S4) replaces `BootstrapPowerAdapter` with the real
// platform adapter. Reference: xai-system-power.

import Foundation

/// Power-inhibition errors.
public enum PowerError: Error, Equatable, Sendable {
    case acquireFailed(String)
    case unsupported(String)
    case released
}

/// The kind of power inhibition a lease requests.
public enum PowerLeaseKind: Sendable, Equatable, Codable {
    case preventSystemSleep
    case preventDisplaySleep
}

/// A power-inhibition lease. Releasing (or deinitalizing) the lease restores
/// the prior system power policy.
public protocol PowerLease: AnyObject, Sendable {
    var kind: PowerLeaseKind { get }
    var reason: String { get }
    func release() async
}

/// Power-inhibition adapter.
public protocol PowerAdapter: Sendable {
    func acquire(kind: PowerLeaseKind, reason: String) async throws -> any PowerLease
}

/// Bootstrap adapter that reports `unsupported`. The owning slice (W2-S4)
/// provides the IOPM / Linux inhibitor / SetThreadExecutionState adapter.
public struct BootstrapPowerAdapter: PowerAdapter {
    public init() {}
    public func acquire(kind: PowerLeaseKind, reason: String) async throws -> any PowerLease {
        throw PowerError.unsupported("BootstrapPowerAdapter does not inhibit power; W2-S4 provides the platform adapter.")
    }
}
