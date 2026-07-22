// OpenGrokCircuitBreaker.swift
//
// Open Grok — Swift port of `xai-circuit-breaker`.
//
// Sliding-window-with-min-samples circuit breaker plus HTTP status
// disposition (retry policy). Server and client presets, injectable
// clocks, per-key registry isolation, and observer hooks match the Rust
// state machine, including half-open probe abandonment.

import Foundation
import Dispatch
import OpenGrokShared


/// Portable lock over mutable state. Sync `withLock` is safe to call from async.
final class LockHolder<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State
    init(_ state: State) { self.state = state }
    @discardableResult
    func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}

/// Portable monotonic timestamp (nanoseconds since boot).
public struct MonotonicInstant: Sendable, Hashable, Comparable {
    public var nanoseconds: UInt64
    public init(nanoseconds: UInt64) { self.nanoseconds = nanoseconds }
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


// MARK: - Breaker state

/// Tri-state circuit-breaker status.
public enum BreakerState: UInt8, Sendable, Equatable, Hashable, CustomStringConvertible {
    case closed = 0
    case open = 1
    case halfOpen = 2

    public var description: String {
        switch self {
        case .closed: return "closed"
        case .open: return "open"
        case .halfOpen: return "half_open"
        }
    }

    static func fromUInt8(_ value: UInt8) -> BreakerState {
        switch value {
        case 0: return .closed
        case 1: return .open
        case 2: return .halfOpen
        default: return .closed
        }
    }
}

/// Outcome of a wire request fed back via ``CircuitBreaker/record(_:)``.
public enum BreakerOutcome: Sendable, Equatable, Hashable {
    case success
    case failure
}

/// Returned by ``CircuitBreaker/check()`` when the breaker is open or has
/// exhausted half-open probe slots.
public struct BreakerOpenError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Suggested wait before the next attempt.
    public var retryAfter: TimeInterval

    public init(retryAfter: TimeInterval) {
        self.retryAfter = retryAfter
    }

    public var description: String {
        let seconds = retryAfter
        return String(format: "circuit breaker open; retry after %.1fs", seconds)
    }

    /// Bridge into the shared error envelope for cross-boundary propagation.
    public func asEnvelope() -> ErrorEnvelope {
        ErrorEnvelope(
            code: "circuit_breaker_open",
            message: description,
            retryable: true,
            details: [
                "retry_after_ms": .number(
                    .int64(Int64(retryAfter * 1000.0))
                )
            ]
        )
    }
}

// MARK: - Clock

/// Monotonic time source used by the breaker.
public protocol BreakerClock: Sendable {
    func now() -> MonotonicInstant
}

/// Production clock backed by `DispatchTime` uptime.
public struct SystemBreakerClock: BreakerClock, Sendable {
    public init() {}
    public func now() -> MonotonicInstant { MonotonicInstant.now() }
}

/// Controllable clock for deterministic tests.
public final class MockBreakerClock: BreakerClock, @unchecked Sendable {
    private let instant: LockHolder<MonotonicInstant>

    public init(now: MonotonicInstant = MonotonicInstant.now()) {
        self.instant = LockHolder(now)
    }

    public func now() -> MonotonicInstant {
        instant.withLock { $0 }
    }

    /// Advance the mock clock by `duration`.
    public func advance(_ duration: TimeInterval) {
        instant.withLock { $0 = $0.advanced(bySeconds: duration) }
    }
}

// MARK: - Config

/// Default HTTP failure codes that count as breaker failures.
public let defaultBreakerFailureCodes: Set<UInt16> = [429, 500, 502, 503, 504]

/// Tuning knobs for ``CircuitBreaker``.
public struct BreakerConfig: Sendable, Equatable {
    public var windowDuration: TimeInterval
    public var minSamples: Int
    public var errorRateThreshold: Double
    public var openDuration: TimeInterval
    public var halfOpenMaxProbes: Int
    public var failureCodes: Set<UInt16>
    public var enabled: Bool

    public init(
        windowDuration: TimeInterval = TimeInterval(60),
        minSamples: Int = 10,
        errorRateThreshold: Double = 0.5,
        openDuration: TimeInterval = TimeInterval(10),
        halfOpenMaxProbes: Int = 1,
        failureCodes: Set<UInt16> = defaultBreakerFailureCodes,
        enabled: Bool = true
    ) {
        self.windowDuration = windowDuration
        self.minSamples = minSamples
        self.errorRateThreshold = errorRateThreshold
        self.openDuration = openDuration
        self.halfOpenMaxProbes = max(1, halfOpenMaxProbes)
        self.failureCodes = failureCodes
        self.enabled = enabled
    }

    /// Server preset (`min_samples=10`, `error_rate=0.5`, 60s window, 10s open).
    public static func server() -> BreakerConfig {
        BreakerConfig(
            windowDuration: TimeInterval(60),
            minSamples: 10,
            errorRateThreshold: 0.5,
            openDuration: TimeInterval(10),
            halfOpenMaxProbes: 1,
            failureCodes: defaultBreakerFailureCodes,
            enabled: true
        )
    }

    /// Client preset (`min_samples=5`, 60s open duration, failure codes `[401]`).
    public static func client() -> BreakerConfig {
        BreakerConfig(
            windowDuration: TimeInterval(60),
            minSamples: 5,
            errorRateThreshold: 0.5,
            openDuration: TimeInterval(60),
            halfOpenMaxProbes: 1,
            failureCodes: [401],
            enabled: true
        )
    }

    /// Load knobs from `CB_*` environment variables.
    public static func fromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> BreakerConfig {
        fromLookup(prefix: "CB_", get: { environment[$0] })
    }

    /// Load knobs from `<prefix>...` via an injectable lookup.
    public static func fromLookup(
        prefix: String,
        get: (String) -> String?
    ) -> BreakerConfig {
        func key(_ suffix: String) -> String { prefix + suffix }

        let failureCodes: Set<UInt16>
        if let raw = get(key("FAILURE_CODES")) {
            let parsed = parseFailureCodes(raw)
            failureCodes = parsed.isEmpty ? defaultBreakerFailureCodes : parsed
        } else {
            failureCodes = defaultBreakerFailureCodes
        }

        return BreakerConfig(
            windowDuration: TimeInterval(lookupOr(get, key("WINDOW_SECS"), 60)),
            minSamples: lookupOr(get, key("MIN_SAMPLES"), 10),
            errorRateThreshold: lookupOr(get, key("ERROR_RATE_THRESHOLD"), 0.5),
            openDuration: TimeInterval(lookupOr(get, key("OPEN_DURATION_SECS"), 10)),
            halfOpenMaxProbes: max(1, lookupOr(get, key("HALF_OPEN_MAX_PROBES"), 1)),
            failureCodes: failureCodes,
            enabled: lookupOr(get, key("ENABLED"), true)
        )
    }

    /// `true` if `status` is in the configured failure code set.
    public func isFailureStatus(_ status: UInt16) -> Bool {
        failureCodes.contains(status)
    }
}

/// Parse a comma-separated list of status codes; invalid entries are dropped.
public func parseFailureCodes(_ raw: String) -> Set<UInt16> {
    var result = Set<UInt16>()
    for part in raw.split(separator: ",") {
        let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
        if let code = UInt16(trimmed) {
            result.insert(code)
        }
    }
    return result
}

private func lookupOr<T: LosslessStringConvertible>(
    _ get: (String) -> String?,
    _ key: String,
    _ defaultValue: T
) -> T {
    guard let raw = get(key) else { return defaultValue }
    return T(raw) ?? defaultValue
}

// MARK: - Retry policy

/// What a caller should do with a non-2xx HTTP response, by status code.
public enum RetryDisposition: Sendable, Equatable, Hashable {
    /// Transient: retry with backoff (5xx, 429, etc.).
    case retryable
    /// Refresh credentials once, then give up (e.g. 401).
    case authRefresh
    /// Permanent: drop immediately, never retry (e.g. 400/403/404).
    case terminal
}

/// Maps an HTTP status code to a ``RetryDisposition``.
public struct RetryPolicy: Sendable, Equatable {
    public var retryable: Set<UInt16>
    public var authRefresh: Set<UInt16>
    public var terminal: Set<UInt16>
    public var defaultDisposition: RetryDisposition

    public init(
        retryable: Set<UInt16> = [],
        authRefresh: Set<UInt16> = [],
        terminal: Set<UInt16> = [],
        defaultDisposition: RetryDisposition
    ) {
        self.retryable = retryable
        self.authRefresh = authRefresh
        self.terminal = terminal
        self.defaultDisposition = defaultDisposition
    }

    /// Classify `status`. Returns `nil` for 2xx (success, not an error).
    public func classify(_ status: UInt16) -> RetryDisposition? {
        if (200..<300).contains(status) {
            return nil
        }
        if authRefresh.contains(status) {
            return .authRefresh
        }
        if terminal.contains(status) {
            return .terminal
        }
        if retryable.contains(status) || (500..<600).contains(status) {
            return .retryable
        }
        return defaultDisposition
    }

    /// `true` iff `status` classifies as ``RetryDisposition/retryable``.
    public func shouldRetry(_ status: UInt16) -> Bool {
        classify(status) == .retryable
    }

    /// Server preset: 429 and any 5xx are retryable; everything else terminal.
    public static func server() -> RetryPolicy {
        RetryPolicy(
            retryable: [429],
            authRefresh: [],
            terminal: [],
            defaultDisposition: .terminal
        )
    }

    /// Client storage/upload preset: 400/403/404 terminal, 401 auth-refresh,
    /// everything else (429, 5xx, unlisted 4xx) retried.
    public static func clientStorage() -> RetryPolicy {
        RetryPolicy(
            retryable: [],
            authRefresh: [401],
            terminal: [400, 403, 404],
            defaultDisposition: .retryable
        )
    }
}

// MARK: - Observer

/// Telemetry hooks for breaker transitions. Implementations must not block.
public protocol BreakerObserver: Sendable {
    func onStateChange(old: BreakerState, new: BreakerState, reason: String)
    func onProbeAdmission(allowed: Bool)
    func onOutcome(_ outcome: BreakerOutcome, status: BreakerState)
}

extension BreakerObserver {
    public func onStateChange(old: BreakerState, new: BreakerState, reason: String) {
        _ = (old, new, reason)
    }
    public func onProbeAdmission(allowed: Bool) { _ = allowed }
    public func onOutcome(_ outcome: BreakerOutcome, status: BreakerState) {
        _ = (outcome, status)
    }
}

/// No-op observer used by default.
public struct NoopBreakerObserver: BreakerObserver, Sendable {
    public init() {}
}

// MARK: - Sliding window

/// Safety cap on sliding window entries (matches Rust `MAX_WINDOW_ENTRIES`).
let maxWindowEntries = 10_000

private struct SlidingWindow {
    private var entries: [(MonotonicInstant, Bool)] = []
    private var failures: Int = 0

    mutating func push(isFailure: Bool, at: MonotonicInstant) {
        if entries.count >= maxWindowEntries {
            let removed = entries.removeFirst()
            if removed.1 { failures -= 1 }
        }
        entries.append((at, isFailure))
        if isFailure { failures += 1 }
    }

    mutating func evict(window: TimeInterval, now: MonotonicInstant) {
        let cutoff = now.advanced(bySeconds: -window)
        while let front = entries.first, front.0 < cutoff {
            let removed = entries.removeFirst()
            if removed.1 { failures -= 1 }
        }
    }

    func errorRate() -> Double {
        guard !entries.isEmpty else { return 0 }
        return Double(failures) / Double(entries.count)
    }

    func sampleCount() -> Int { entries.count }

    mutating func clear() {
        entries.removeAll(keepingCapacity: false)
        failures = 0
    }
}

// MARK: - Circuit breaker

/// Cheaply-clonable handle around a shared breaker core.
public final class CircuitBreaker: @unchecked Sendable {
    private struct CoreState {
        var config: BreakerConfig
        var stateRaw: UInt8
        let baseline: MonotonicInstant
        var openedAtMillis: UInt64
        var halfOpenProbes: Int
        var probeClaimedAtMillis: UInt64
        var isOpenFast: Bool
        var window: SlidingWindow
        let clock: any BreakerClock
        var observer: (any BreakerObserver)?
    }

    private let core: LockHolder<CoreState>

    /// Construct a breaker with the system clock and a no-op observer.
    public convenience init(config: BreakerConfig = .server()) {
        self.init(config: config, clock: SystemBreakerClock())
    }

    /// Construct a breaker with an injected clock.
    public init(config: BreakerConfig, clock: any BreakerClock) {
        var cfg = config
        cfg.halfOpenMaxProbes = max(1, cfg.halfOpenMaxProbes)
        self.core = LockHolder(CoreState(
                config: cfg,
                stateRaw: BreakerState.closed.rawValue,
                baseline: clock.now(),
                openedAtMillis: 0,
                halfOpenProbes: 0,
                probeClaimedAtMillis: 0,
                isOpenFast: false,
                window: SlidingWindow(),
                clock: clock,
                observer: nil
            )
        )
    }

    /// Install an observer. First install wins (matches Rust `OnceLock`).
    @discardableResult
    public func withObserver(_ observer: any BreakerObserver) -> CircuitBreaker {
        core.withLock { state in
            if state.observer == nil {
                state.observer = observer
            }
        }
        return self
    }

    /// Consult the breaker before issuing a request.
    public func check() throws {
        try core.withLock { state in
            guard state.config.enabled else { return }
            switch Self.state(of: state) {
            case .closed:
                return
            case .open:
                try Self.checkOpen(&state)
            case .halfOpen:
                try Self.tryHalfOpenProbe(&state)
            }
        }
    }

    /// Record the outcome of a request.
    public func record(_ outcome: BreakerOutcome) {
        core.withLock { state in
            guard state.config.enabled else { return }

            let isFailure = outcome == .failure
            let now = state.clock.now()
            let prev = Self.state(of: state)

            switch prev {
            case .closed:
                state.window.push(isFailure: isFailure, at: now)
                state.window.evict(window: state.config.windowDuration, now: now)
                if state.window.sampleCount() >= state.config.minSamples
                    && state.window.errorRate() >= state.config.errorRateThreshold
                {
                    Self.trip(&state, prev: prev, reason: "trip")
                }
            case .halfOpen:
                if isFailure {
                    Self.trip(&state, prev: prev, reason: "probe_failure")
                } else {
                    Self.close(&state, prev: prev, reason: "probe_success")
                }
            case .open:
                state.window.push(isFailure: isFailure, at: now)
                state.window.evict(window: state.config.windowDuration, now: now)
            }

            let newState = Self.state(of: state)
            // Observer runs after state is visible; implementations must stay cheap.
            state.observer?.onOutcome(outcome, status: newState)
        }
    }

    /// Current authoritative state.
    public func state() -> BreakerState {
        core.withLock { Self.state(of: $0) }
    }

    /// Lock-free-style open check (uses the fast mirror).
    public func isOpen() -> Bool {
        core.withLock { $0.isOpenFast }
    }

    /// Failure rate over the live sliding window.
    public func errorRate() -> Double {
        core.withLock { state in
            let now = state.clock.now()
            state.window.evict(window: state.config.windowDuration, now: now)
            return state.window.errorRate()
        }
    }

    /// `true` if `status` is in the configured failure code set.
    public func isFailureStatus(_ status: UInt16) -> Bool {
        core.withLock { $0.config.isFailureStatus(status) }
    }

    /// Force-transition to half-open for tests (bypasses the open timer).
    public func forceHalfOpen() {
        core.withLock { state in
            let prev = Self.state(of: state)
            state.stateRaw = BreakerState.halfOpen.rawValue
            state.isOpenFast = false
            state.halfOpenProbes = 0
            if prev != .halfOpen {
                state.observer?.onStateChange(old: prev, new: .halfOpen, reason: "force_half_open")
            }
        }
    }

    // MARK: Private state machine

    private static func state(of core: CoreState) -> BreakerState {
        BreakerState.fromUInt8(core.stateRaw)
    }

    private static func elapsedMillis(_ core: CoreState) -> UInt64 {
        let now = core.clock.now()
        let seconds = max(0, core.baseline.seconds(until: now))
        return UInt64(seconds * 1000.0)
    }

    private static func checkOpen(_ core: inout CoreState) throws {
        let opened = core.openedAtMillis
        let now = elapsedMillis(core)
        let elapsedMs = now &- min(now, opened)
        let elapsed = TimeInterval(elapsedMs) / 1000.0

        if elapsed >= core.config.openDuration {
            if core.stateRaw == BreakerState.open.rawValue {
                core.stateRaw = BreakerState.halfOpen.rawValue
                core.isOpenFast = false
                core.observer?.onStateChange(
                    old: .open,
                    new: .halfOpen,
                    reason: "open_elapsed"
                )
                try tryHalfOpenProbe(&core)
                return
            }
            switch state(of: core) {
            case .closed:
                return
            case .halfOpen:
                try tryHalfOpenProbe(&core)
            case .open:
                let opened2 = core.openedAtMillis
                let now2 = elapsedMillis(core)
                let elapsed2Ms = now2 &- min(now2, opened2)
                let elapsed2 = TimeInterval(elapsed2Ms) / 1000.0
                throw BreakerOpenError(
                    retryAfter: max(0, core.config.openDuration - elapsed2)
                )
            }
            return
        }

        throw BreakerOpenError(
            retryAfter: max(0, core.config.openDuration - elapsed)
        )
    }

    private static func trip(_ core: inout CoreState, prev: BreakerState, reason: String) {
        core.stateRaw = BreakerState.open.rawValue
        core.openedAtMillis = elapsedMillis(core)
        core.halfOpenProbes = 0
        core.isOpenFast = true
        if prev != .open {
            core.observer?.onStateChange(old: prev, new: .open, reason: reason)
        }
    }

    private static func close(_ core: inout CoreState, prev: BreakerState, reason: String) {
        core.stateRaw = BreakerState.closed.rawValue
        core.window.clear()
        core.halfOpenProbes = 0
        core.isOpenFast = false
        if prev != .closed {
            core.observer?.onStateChange(old: prev, new: .closed, reason: reason)
        }
    }

    private static func tryHalfOpenProbe(_ core: inout CoreState) throws {
        let now = elapsedMillis(core)
        let prev = core.halfOpenProbes
        core.halfOpenProbes += 1
        if prev < core.config.halfOpenMaxProbes {
            core.probeClaimedAtMillis = now
            core.observer?.onProbeAdmission(allowed: true)
            return
        }
        core.halfOpenProbes -= 1

        // Abandoned probe reclaim: a claim older than open_duration may be taken.
        let leaseMillis = durationToMillis(core.config.openDuration)
        let claimed = core.probeClaimedAtMillis
        if now &- min(now, claimed) >= leaseMillis {
            core.probeClaimedAtMillis = now
            core.observer?.onProbeAdmission(allowed: true)
            return
        }

        core.observer?.onProbeAdmission(allowed: false)
        let halfOpenBackoff: TimeInterval = 0.05
        let retry = min(halfOpenBackoff, core.config.openDuration)
        throw BreakerOpenError(retryAfter: retry)
    }
}

private func durationToMillis(_ d: TimeInterval) -> UInt64 {
    UInt64(max(0, d) * 1000.0)
}

private func max(_ a: TimeInterval, _ b: TimeInterval) -> TimeInterval {
    a >= b ? a : b
}

private func min(_ a: TimeInterval, _ b: TimeInterval) -> TimeInterval {
    a <= b ? a : b
}

// MARK: - Registry

/// Per-key registry of circuit breakers (one per upstream endpoint, tenant, …).
public final class CircuitBreakerRegistry: @unchecked Sendable {
    private let config: BreakerConfig
    private let breakers: LockHolder<[String: CircuitBreaker]>

    public init(config: BreakerConfig) {
        self.config = config
        self.breakers = LockHolder([:])
    }

    /// Returns `nil` if the registry is disabled; otherwise returns (and
    /// lazily creates) the breaker for `key`.
    public func get(_ key: String) -> CircuitBreaker? {
        guard config.enabled else { return nil }
        return breakers.withLock { map in
            if let existing = map[key] {
                return existing
            }
            let created = CircuitBreaker(config: config)
            map[key] = created
            return created
        }
    }
}

// MARK: - Retry backoff helpers

/// Exponential backoff (2s, 4s, 8s, … capped 30s) with ±20% jitter.
///
/// When `seed` is provided, jitter is deterministic for tests.
public func retryBackoffWithJitter(
    retryCount: UInt32,
    seed: UInt64? = nil
) -> TimeInterval {
    let shift = retryCount > 0 ? retryCount - 1 : 0
    let baseMs: UInt64
    if shift >= 63 {
        baseMs = 30_000
    } else {
        baseMs = min(2000 &<< shift, 30_000)
    }
    let jitterRange = baseMs / 5
    let sequence: UInt64
    if let seed {
        sequence = seed &+ UInt64(retryCount)
    } else {
        sequence = UInt64.random(in: 0...UInt64.max)
    }
    let jitter = sequence % (jitterRange * 2 + 1)
    let ms = baseMs - jitterRange + jitter
    return TimeInterval(ms) / 1000.0
}

// MARK: - Wall clock (for HTTP-date Retry-After)

/// Wall-clock source for calendar-date `Retry-After` parsing.
public protocol WallClock: Sendable {
    func now() -> Date
}

/// Production wall clock backed by `Date()`.
public struct SystemWallClock: WallClock, Sendable {
    public init() {}
    public func now() -> Date { Date() }
}

/// Controllable wall clock for deterministic tests.
public final class MockWallClock: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = now
    }

    public func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func set(_ date: Date) {
        lock.lock(); defer { lock.unlock() }
        current = date
    }

    public func advance(_ duration: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(duration)
    }
}

/// Parse an HTTP `Retry-After` header value.
///
/// Supports delta-seconds and IMF-fixdate HTTP-dates. Elapsed/past dates
/// clamp to `0`. Malformed values return `nil`.
///
/// - Parameters:
///   - value: Raw header value.
///   - now: Injectable wall-clock instant used to convert HTTP-dates into
///     a remaining delay. Defaults to the system clock.
public func parseRetryAfterHeader(
    _ value: String?,
    now: Date = Date()
) -> TimeInterval? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    // Delta-seconds (and fractional seconds used by some proxies).
    // Numeric forms never contain letters; HTTP-dates always do.
    let isDeltaSeconds = trimmed.unicodeScalars.allSatisfy {
        CharacterSet.decimalDigits.union(CharacterSet(charactersIn: ".")).contains($0)
    } && trimmed.contains(where: \.isNumber)
    if isDeltaSeconds, let seconds = Double(trimmed), seconds >= 0 {
        return seconds
    }

    // IMF-fixdate / RFC 850 / asctime HTTP-date forms.
    if let date = parseHTTPDate(trimmed) {
        return max(0, date.timeIntervalSince(now))
    }
    return nil
}

/// Parse HTTP-date forms used by `Retry-After` / `Date` headers.
///
/// Preference order matches RFC 9110: IMF-fixdate, then RFC 850, then asctime.
public func parseHTTPDate(_ value: String) -> Date? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let formats = [
        "EEE, dd MMM yyyy HH:mm:ss zzz", // IMF-fixdate
        "EEEE, dd-MMM-yy HH:mm:ss zzz",  // RFC 850
        "EEE MMM d HH:mm:ss yyyy",       // asctime()
    ]
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    for format in formats {
        formatter.dateFormat = format
        if let date = formatter.date(from: trimmed) {
            return date
        }
    }
    // Some servers emit "GMT" with a fixed format; try ISO8601 as a last resort.
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    return iso.date(from: trimmed)
}
