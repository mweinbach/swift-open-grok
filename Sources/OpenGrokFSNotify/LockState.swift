// LockState.swift
//
// Lock-state machine. Pure data + pure transition function. No I/O.
// Port of xai-fsnotify `state.rs`.

import Foundation

/// Drop transient OS events for this window after a head-changing op.
public let cooldownMilliseconds: UInt64 = 500

/// After a lock release, wait this long before declaring the operation complete.
public let settleMilliseconds: UInt64 = 500

/// Diagnostic threshold for a one-time stale-lock warning (seconds).
public let staleLockSeconds: UInt64 = 60

/// Internal lock lifecycle.
public enum LockState: Sendable, Equatable {
    case idle
    case locked(headAtStart: String?, since: Date)
    /// Lock released, operation not yet declared complete. Carries
    /// `headAtStart` and `since` from the first `locked` entry of the merged
    /// operation so re-locks preserve the op-wide HEAD comparison.
    case settling(headAtStart: String?, since: Date, until: Date)
    case cooldown(until: Date)
}

/// Pure transition result from one `drive` step.
public enum LockTransition: Sendable, Equatable {
    case none
    case started
    /// Emitted on settle expiry. Cooldown begins iff `headChanged` is true.
    case completed(headChanged: Bool)
    /// Cooldown timer expired; consumer never sees this — internal only.
    case cooldownEnded
}

/// One step. Pure; mutates `state` from freshly-observed FS facts.
@discardableResult
public func driveLockState(
    _ state: inout LockState,
    lockPresent: Bool,
    headNow: String?,
    now: Date,
    cooldown: TimeInterval
) -> LockTransition {
    switch (state, lockPresent) {
    case (.idle, true), (.cooldown, true):
        state = .locked(headAtStart: headNow, since: now)
        return .started

    case (.settling(let headAtStart, let since, _), true):
        // Same operation resumes: keep op-start HEAD and `since`.
        state = .locked(headAtStart: headAtStart, since: since)
        return .none

    case (.locked(let headAtStart, let since), false):
        state = .settling(
            headAtStart: headAtStart,
            since: since,
            until: now.addingTimeInterval(TimeInterval(settleMilliseconds) / 1000.0)
        )
        return .none

    case (.settling(let headAtStart, _, let until), false) where now >= until:
        let headChanged = headAtStart != headNow
        if headChanged {
            state = .cooldown(until: now.addingTimeInterval(cooldown))
        } else {
            state = .idle
        }
        return .completed(headChanged: headChanged)

    case (.cooldown(let until), false) where now >= until:
        state = .idle
        return .cooldownEnded

    default:
        return .none
    }
}

/// `check` fires once per stale period; resets when the lock releases.
public struct StaleWarn: Sendable {
    private var warned = false

    public init() {}

    public mutating func check(state: LockState, now: Date) -> TimeInterval? {
        switch state {
        case .locked(_, let since), .settling(_, let since, _):
            let elapsed = now.timeIntervalSince(since)
            if !warned && elapsed > TimeInterval(staleLockSeconds) {
                warned = true
                return elapsed
            }
            return nil
        default:
            warned = false
            return nil
        }
    }
}
