// MonotonicTime.swift
//
// macOS 12-compatible monotonic timing primitives for sampler elapsed-time APIs.

import Dispatch
import Foundation

public struct MonotonicDuration: Sendable, Equatable, Hashable, Codable, Comparable {
    public let nanoseconds: UInt64

    public init(nanoseconds: UInt64) {
        self.nanoseconds = nanoseconds
    }

    public static func seconds(_ value: Int64) -> MonotonicDuration {
        guard value > 0 else { return MonotonicDuration(nanoseconds: 0) }
        let seconds = UInt64(value)
        return MonotonicDuration(nanoseconds: seconds > UInt64.max / 1_000_000_000 ? UInt64.max : seconds * 1_000_000_000)
    }

    public static func milliseconds(_ value: Int64) -> MonotonicDuration {
        guard value > 0 else { return MonotonicDuration(nanoseconds: 0) }
        let milliseconds = UInt64(value)
        return MonotonicDuration(nanoseconds: milliseconds > UInt64.max / 1_000_000 ? UInt64.max : milliseconds * 1_000_000)
    }

    public static func microseconds(_ value: Int64) -> MonotonicDuration {
        guard value > 0 else { return MonotonicDuration(nanoseconds: 0) }
        let microseconds = UInt64(value)
        return MonotonicDuration(nanoseconds: microseconds > UInt64.max / 1_000 ? UInt64.max : microseconds * 1_000)
    }

    public var wholeSeconds: UInt64 { nanoseconds / 1_000_000_000 }

    public static func < (lhs: MonotonicDuration, rhs: MonotonicDuration) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    public func adding(_ other: MonotonicDuration) -> MonotonicDuration {
        MonotonicDuration(nanoseconds: nanoseconds > UInt64.max - other.nanoseconds ? UInt64.max : nanoseconds + other.nanoseconds)
    }

    public func sleep() async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

public struct MonotonicInstant: Sendable, Equatable, Hashable, Comparable {
    public let uptimeNanoseconds: UInt64

    public init(uptimeNanoseconds: UInt64) {
        self.uptimeNanoseconds = uptimeNanoseconds
    }

    public static var now: MonotonicInstant {
        MonotonicInstant(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
    }

    public static func < (lhs: MonotonicInstant, rhs: MonotonicInstant) -> Bool {
        lhs.uptimeNanoseconds < rhs.uptimeNanoseconds
    }

    public static func - (lhs: MonotonicInstant, rhs: MonotonicInstant) -> MonotonicDuration {
        MonotonicDuration(nanoseconds: lhs.uptimeNanoseconds >= rhs.uptimeNanoseconds ? lhs.uptimeNanoseconds - rhs.uptimeNanoseconds : 0)
    }
}
