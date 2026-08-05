// AuthRetrySchedule.swift
//
// Wire-credential provenance and the per-turn 401 retry budget.
//
// Ports:
//   * `SentCredential` — `crates/codegen/xai-grok-sampling-types/src/error.rs:88`.
//   * `DualClock` — `crates/codegen/xai-grok-shell/src/util/dual_clock.rs:14`.
//   * `AuthRetrySchedule` / `AuthRetryDecision` —
//     `crates/codegen/xai-grok-shell/src/session/acp_session_impl/auth_retry.rs:43-207`.
//
// Neither type is persisted: `auth.json` carries no provenance or retry
// state at pin 80dff0a9. These are in-memory turn-scoped policy.

import Foundation

/// Wire-credential provenance of a request that failed authentication.
///
/// A 401 for a request that went out with **no** credential header is not
/// evidence against the credential itself, so retry policy must not charge
/// a credential-rejection slot for it. error.rs:88.
public enum SentCredential: String, Sendable, Hashable, Codable {
    /// The request carried a credential; the server rejected it.
    case sent
    /// The request went out with no credential header at all.
    case missing
    /// Provenance unknown (synthesized or legacy errors). Retry policy
    /// treats this like ``sent`` — fail closed toward terminating rather
    /// than retrying forever. error.rs:96.
    case unknown

    public static let `default`: SentCredential = .unknown

    /// Unrecognized values from a newer peer degrade to ``unknown`` instead
    /// of failing the whole containing payload. error.rs:103.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SentCredential(rawValue: raw) ?? .unknown
    }

    /// `SentCredential::from_sent_fragment` (error.rs:118): a captured
    /// credential fragment means a credential was stamped on the wire.
    public static func fromSentFragment(_ fragment: String?) -> SentCredential {
        fragment == nil ? .missing : .sent
    }

    public var isMissing: Bool { self == .missing }
    public var isUnknown: Bool { self == .unknown }
}

/// One instant captured on two clocks, so elapsed time stays honest across
/// a system suspend without trusting the wall clock alone.
///
/// `monotonicSeconds` pauses while the machine sleeps (Darwin
/// `CLOCK_UPTIME_RAW`, Linux `CLOCK_MONOTONIC`), matching Rust's `Instant`;
/// `wallSeconds` advances through sleep but jumps with NTP steps, matching
/// `SystemTime`. Their difference grows by exactly the suspended time.
/// dual_clock.rs:14.
///
/// Seconds are plain `TimeInterval` rather than `Duration` because the
/// package deployment target is macOS 12 and `Duration` needs macOS 13.
public struct DualClock: Sendable, Hashable {
    /// Monotonic; pauses during sleep. Bounds elapsed *awake* time.
    public var monotonicSeconds: TimeInterval
    /// Wall clock; advances through sleep. Bounds elapsed *real* time.
    public var wallSeconds: TimeInterval

    public init(monotonicSeconds: TimeInterval, wallSeconds: TimeInterval) {
        self.monotonicSeconds = monotonicSeconds
        self.wallSeconds = wallSeconds
    }

    /// Suspend-pausing monotonic reading, in seconds.
    public static func monotonicNow() -> TimeInterval {
        var ts = timespec()
        #if canImport(Darwin)
        clock_gettime(CLOCK_UPTIME_RAW, &ts)
        #else
        clock_gettime(CLOCK_MONOTONIC, &ts)
        #endif
        return TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000
    }

    public static func now() -> DualClock {
        DualClock(
            monotonicSeconds: monotonicNow(),
            wallSeconds: Date().timeIntervalSince1970
        )
    }

    /// Elapsed on each clock as `(awake, total)`, each clamped at zero so a
    /// backward jump can never fabricate a suspend. dual_clock.rs:32.
    public func elapsed(to now: DualClock) -> (awake: TimeInterval, total: TimeInterval) {
        (
            max(0, now.monotonicSeconds - monotonicSeconds),
            max(0, now.wallSeconds - wallSeconds)
        )
    }
}

/// Decision for one post-recovery 401. auth_retry.rs:46.
public enum AuthRetryDecision: Sendable, Hashable {
    /// No credential was on the wire, so no slot is charged; resubmit after
    /// the refresh lands. `resubmit` is 1-indexed since the last success.
    case unchargedResubmit(resubmit: UInt32)
    /// Charged one escalating slot: back off `delay`, then resubmit.
    case backoff(attempt: UInt32, delaySeconds: TimeInterval)
    /// Per-incident budget exhausted by credentialed 401s — fail the turn.
    case exhausted
    /// Runaway guard tripped: recovery kept succeeding while the server
    /// rejected `rejections` credential-less requests with no success.
    case runawayGuard(rejections: UInt32)
}

/// Escalating retry budget for 401s that follow a *successful* auth
/// recovery. Per-incident: successes and (capped) suspend boundaries reset
/// it, and only credentialed rejections charge it. auth_retry.rs:74.
public struct AuthRetrySchedule: Sendable {
    /// Consecutive credentialed post-recovery 401s tolerated per incident.
    public static let maxRetries: UInt32 = 3
    /// Uncharged (no-credential) rejections tolerated without an
    /// intervening successful response. auth_retry.rs:96.
    public static let maxUnchargedResubmits: UInt32 = 50
    /// Suspend resets tolerated without an intervening success before the
    /// budget stops resetting and is allowed to exhaust. auth_retry.rs:100.
    public static let maxSuspendResets: UInt32 = 8
    /// Bounded wait for a refresh to land before an uncharged resubmit.
    public static let unchargedRefreshWaitSeconds: TimeInterval = 15
    /// Floor pacing for uncharged resubmits with no refresh to wait on.
    public static let unchargedResubmitFloorSeconds: TimeInterval = 1
    /// Wall-vs-monotonic drift beyond which the machine must have slept.
    public static let suspendDriftMinSeconds: TimeInterval = 30

    /// Delays are **1s / 2s / 4s**, capped at 10s.
    ///
    /// Rust builds these from `ExponentialBackoff::from_millis(2).factor(500)`
    /// precisely because `from_millis(1000)` would raise 1000 to the attempt
    /// number — 1s, then 16m40s, then 11.57 days of silent hang, a past
    /// field incident (auth_retry.rs:66-72). Spelled out literally here so
    /// the same mistake is not reachable.
    public static let delaySeconds: [TimeInterval] = [1, 2, 4]

    /// Slots charged this incident.
    private var attempt: UInt32 = 0
    /// 401s seen this incident, total and the credentialed subset.
    private var incidentRejections: UInt32 = 0
    private var incidentAuthenticated: UInt32 = 0
    /// Stamped by the incident's first charged 401; cleared by resets.
    private var incidentStarted: DualClock?
    /// Uncharged rejections since the last success (survives suspend resets).
    private var unchargedResubmits: UInt32 = 0
    /// Suspend-triggered resets since the last success.
    private var suspendResets: UInt32 = 0

    public init() {}

    /// Decision for one post-recovery 401. Charges a slot only when the
    /// rejected request carried a credential — or its provenance is unknown,
    /// which fails closed toward terminating. auth_retry.rs:131.
    public mutating func onRecovered401(
        _ credential: SentCredential,
        now: DualClock = .now()
    ) -> AuthRetryDecision {
        if credential.isMissing {
            unchargedResubmits += 1
            if unchargedResubmits > Self.maxUnchargedResubmits {
                return .runawayGuard(rejections: unchargedResubmits)
            }
            return .unchargedResubmit(resubmit: unchargedResubmits)
        }
        if incidentStarted == nil { incidentStarted = now }
        incidentRejections += 1
        if credential == .sent { incidentAuthenticated += 1 }
        guard attempt < Self.maxRetries else { return .exhausted }
        let delay = Self.delaySeconds[Int(attempt)]
        attempt += 1
        return .backoff(attempt: attempt, delaySeconds: delay)
    }

    /// Close the open incident if it spans a suspend (wall elapsed outgrew
    /// awake elapsed by ``suspendDriftMin``): separate wakes are independent
    /// 401 events. Capped at ``maxSuspendResets`` per success-free stretch so
    /// a fault persisting across wakes exhausts instead of retrying forever.
    /// Returns whether a reset happened. auth_retry.rs:172.
    @discardableResult
    public mutating func resetIfIncidentSpansSuspend(
        now: DualClock = .now()
    ) -> Bool {
        guard let started = incidentStarted else { return false }
        guard suspendResets < Self.maxSuspendResets else { return false }
        let (awake, total) = started.elapsed(to: now)
        let suspended = total - awake
        guard suspended >= Self.suspendDriftMinSeconds else { return false }
        let carriedUncharged = unchargedResubmits
        let carriedResets = suspendResets
        self = AuthRetrySchedule()
        unchargedResubmits = carriedUncharged
        suspendResets = carriedResets + 1
        return true
    }

    /// A successful model response ends every open failure narrative.
    /// auth_retry.rs:196.
    public mutating func resetOnSuccess() {
        self = AuthRetrySchedule()
    }

    /// `(rejections, authenticated)` this incident, for the exhaustion
    /// message — so "real credential rejected" and "budget exhausted"
    /// cannot be conflated. auth_retry.rs:202.
    public var incidentCounts: (rejections: UInt32, authenticated: UInt32) {
        (incidentRejections, incidentAuthenticated)
    }

    /// Uncharged rejections since the last successful response.
    public var unchargedRejections: UInt32 { unchargedResubmits }
}

/// Compact `2h3m` / `4m7s` / `12s` rendering for turn-failure messages.
/// `human_duration`, auth_retry.rs:29.
public func humanDuration(seconds: TimeInterval) -> String {
    let totalSecs = UInt64(max(0, seconds.rounded(.down)))
    if totalSecs < 60 { return "\(totalSecs)s" }
    let mins = totalSecs / 60
    if mins < 60 { return "\(mins)m\(totalSecs % 60)s" }
    return "\(mins / 60)h\(mins % 60)m"
}

/// Whether the only way back is a manual `/login`.
///
/// Port of `AuthManager::requires_manual_reauth`
/// (`crates/codegen/xai-grok-shell/src/auth/manager.rs:2191`) as a pure
/// predicate over the manager's live state, so it can be evaluated without
/// restructuring the Swift OAuth flows. `true` for a sticky IdP rejection
/// of the refresh token or no refresh authority at all; `false` for
/// anything that self-heals.
///
/// This is a *live state* query ("can a future refresh succeed?"), not a
/// classification of a terminal error value.
public func requiresManualReauth(
    permanentFailureBlocksUnattendedRetry: Bool,
    hasRefresherAttached: Bool,
    inMemoryTokenIsRefreshable: Bool,
    diskCredentialHasRefreshToken: Bool
) -> Bool {
    if permanentFailureBlocksUnattendedRetry { return true }
    // No refresh authority wired (static-key manager) → nothing can heal an
    // expired credential silently.
    if !hasRefresherAttached { return true }
    // A refreshable in-memory credential (OIDC RT / external binary) or a
    // sibling's RT on disk lets a later refresh succeed without the user.
    return !(inMemoryTokenIsRefreshable || diskCredentialHasRefreshToken)
}
