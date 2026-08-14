// MonitorRateLimiter.swift
//
// Open Grok — Swift port of `xai-grok-tools/src/implementations/grok_build/monitor/rate_limiter.rs`.
//
// Token-bucket rate limiter, suppression tracker, and auto-kill logic for background monitors.

import Foundation

// MARK: - Rate Limiting Constants (`monitor/types.rs`)

/// Token bucket capacity.
public let RATE_LIMIT_CAPACITY: UInt32 = 10

/// Token bucket refill interval in milliseconds.
public let RATE_LIMIT_REFILL_MS: UInt64 = 2_000

/// Auto-kill after this many ms of continuous rate-limit violations.
public let AUTO_KILL_THRESHOLD_MS: UInt64 = 30_000

// MARK: - Rate Limit Outcome (`monitor/rate_limiter.rs:59-67`)

/// Result of processing an event through the rate limiter and suppression tracker.
public enum RateLimitOutcome: Equatable, Sendable {
    /// Event is allowed through. If `catchUpNotice` is present, a suppression
    /// notice should be sent before the event.
    case allowed(catchUpNotice: String?)
    /// Event is suppressed (token bucket empty).
    case suppressed
    /// Monitor should be auto-killed (sustained overload for 30s+).
    case autoKill(message: String)
}

// MARK: - Token Bucket (`monitor/rate_limiter.rs:9-42`)

/// Token bucket rate limiter.
///
/// Starts full at `capacity` tokens. Each `tryConsume()` takes one token.
/// Tokens refill at 1 per `refillIntervalMs`. Thread-safe and Sendable.
public final class TokenBucket: @unchecked Sendable {
    private let lock = NSLock()
    public let capacity: UInt32
    public let refillIntervalMs: UInt64
    private var _tokens: UInt32
    private var _lastRefill: Date

    public init(
        capacity: UInt32 = RATE_LIMIT_CAPACITY,
        refillIntervalMs: UInt64 = RATE_LIMIT_REFILL_MS,
        now: Date = Date()
    ) {
        self.capacity = capacity
        self.refillIntervalMs = refillIntervalMs
        self._tokens = capacity
        self._lastRefill = now
    }

    /// Current available token count.
    public var tokens: UInt32 {
        lock.lock()
        defer { lock.unlock() }
        return _tokens
    }

    /// Try to consume one token. Returns `true` if a token was available.
    public func tryConsume(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let elapsed = max(0, now.timeIntervalSince(_lastRefill))
        if elapsed > 0 && refillIntervalMs > 0 {
            let elapsedMs = UInt64(elapsed * 1_000.0)
            let refills = UInt32(elapsedMs / refillIntervalMs)
            if refills > 0 {
                _tokens = min(_tokens.addingReportingOverflow(refills).partialValue, capacity)
                let addedSec = Double(refillIntervalMs * UInt64(refills)) / 1_000.0
                _lastRefill = _lastRefill.addingTimeInterval(addedSec)
            }
        }

        if _tokens > 0 {
            _tokens -= 1
            return true
        } else {
            return false
        }
    }

    /// Reset token bucket back to full capacity at the given instant.
    public func reset(now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        _tokens = capacity
        _lastRefill = now
    }
}

// MARK: - Suppression Tracker (`monitor/rate_limiter.rs:49-143`)

/// Tracks rate-limit suppression state and auto-kill logic.
///
/// Used alongside `TokenBucket` to detect sustained overload and generate
/// catch-up notices when the rate subsides. Thread-safe and Sendable.
public final class SuppressionTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var _suppressedCount: UInt64 = 0
    private var _lastSuppression: Date?
    private var _suppressionStart: Date?
    private var _killed = false
    private var _killToolName: String

    public init(killToolName: String = "kill_command_or_subagent") {
        self._killToolName = killToolName
    }

    public var suppressedCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _suppressedCount
    }

    public var lastSuppression: Date? {
        lock.lock()
        defer { lock.unlock() }
        return _lastSuppression
    }

    public var suppressionStart: Date? {
        lock.lock()
        defer { lock.unlock() }
        return _suppressionStart
    }

    public var killed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _killed
    }

    public var killToolName: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _killToolName
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _killToolName = newValue
        }
    }

    public func withKillToolName(_ name: String) -> SuppressionTracker {
        self.killToolName = name
        return self
    }

    /// Process a rate-limit decision. Call after `TokenBucket.tryConsume()`.
    public func process(
        tokenAvailable: Bool,
        description: String = "",
        now: Date = Date()
    ) -> RateLimitOutcome {
        lock.lock()
        defer { lock.unlock() }

        if _killed {
            return .suppressed
        }

        if tokenAvailable {
            let catchUp: String?
            if _suppressedCount > 0 {
                let killName = _killToolName.isEmpty ? "kill_command_or_subagent" : _killToolName
                catchUp = "[\(_suppressedCount) events suppressed -- output rate too high. "
                    + "Consider using \(killName) to restart this monitor "
                    + "with a more selective filter.]"
                _suppressedCount = 0

                // Reset suppression start if the burst has subsided
                // (> 3x refill interval since last suppression).
                if let last = _lastSuppression,
                   now.timeIntervalSince(last) > Double(RATE_LIMIT_REFILL_MS * 3) / 1_000.0 {
                    _suppressionStart = nil
                }
            } else {
                catchUp = nil
            }
            return .allowed(catchUpNotice: catchUp)
        } else {
            _suppressedCount += 1
            _lastSuppression = now
            if _suppressionStart == nil {
                _suppressionStart = now
            }

            // Check auto-kill threshold.
            if let start = _suppressionStart {
                let elapsed = max(0, now.timeIntervalSince(start))
                let elapsedMs = UInt64(elapsed * 1_000.0)
                if elapsedMs > AUTO_KILL_THRESHOLD_MS {
                    _killed = true
                    let secs = UInt64(elapsed)
                    return .autoKill(
                        message: "[Monitor stopped -- your script produced too much output "
                            + "(\(_suppressedCount) events suppressed over \(secs)s). "
                            + "Write a new monitor command that filters more aggressively -- "
                            + "pipe through grep --line-buffered, awk, or a wrapper script "
                            + "that only emits the specific events you need.]"
                    )
                }
            }

            return .suppressed
        }
    }

    /// Reset suppression tracking state.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        _suppressedCount = 0
        _lastSuppression = nil
        _suppressionStart = nil
        _killed = false
    }
}

// MARK: - Combined Rate Limiter (`monitor/rate_limiter.rs:145-173`)

/// Combined rate limiter: token bucket + suppression tracker.
public final class MonitorRateLimiter: @unchecked Sendable {
    public let bucket: TokenBucket
    public let suppression: SuppressionTracker

    public init(
        capacity: UInt32 = RATE_LIMIT_CAPACITY,
        refillIntervalMs: UInt64 = RATE_LIMIT_REFILL_MS,
        killToolName: String = "kill_command_or_subagent",
        now: Date = Date()
    ) {
        self.bucket = TokenBucket(capacity: capacity, refillIntervalMs: refillIntervalMs, now: now)
        self.suppression = SuppressionTracker(killToolName: killToolName)
    }

    public func withKillToolName(_ name: String) -> MonitorRateLimiter {
        suppression.killToolName = name
        return self
    }

    /// Process an event. Returns the rate limit decision.
    public func processEvent(description: String = "", now: Date = Date()) -> RateLimitOutcome {
        let available = bucket.tryConsume(now: now)
        return suppression.process(tokenAvailable: available, description: description, now: now)
    }

    public var isKilled: Bool {
        suppression.killed
    }
}
