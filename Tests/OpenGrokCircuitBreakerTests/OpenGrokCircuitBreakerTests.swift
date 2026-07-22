// OpenGrokCircuitBreakerTests.swift
//
// Rust-derived fixtures for xai-circuit-breaker: state machine, window
// eviction, half-open probes, registry isolation, retry disposition,
// Retry-After parsing, and deterministic jitter.

import Foundation
import Testing
@testable import OpenGrokCircuitBreaker

@Suite("CircuitBreaker state machine")
struct CircuitBreakerStateMachineTests {

    @Test func closedToOpenOnHighErrorRate() throws {
        let cb = CircuitBreaker(config: BreakerConfig(
            minSamples: 2,
            errorRateThreshold: 0.5,
            openDuration: (50 / 1000.0)
        ))
        cb.record(.failure)
        #expect(cb.state() == .closed)
        cb.record(.failure)
        #expect(cb.state() == .open)
    }

    @Test func tripsAtExactThreshold() {
        let cb = CircuitBreaker(config: BreakerConfig(
            minSamples: 2,
            errorRateThreshold: 0.5
        ))
        cb.record(.success)
        cb.record(.failure)
        #expect(cb.state() == .open)
    }

    @Test func doesNotTripBelowThreshold() {
        let cb = CircuitBreaker(config: BreakerConfig(
            minSamples: 3,
            errorRateThreshold: 0.5
        ))
        cb.record(.success)
        cb.record(.failure)
        cb.record(.success)
        #expect(cb.state() == .closed)
    }

    @Test func doesNotTripBelowMinSamples() {
        let cb = CircuitBreaker(config: BreakerConfig(
            minSamples: 5,
            errorRateThreshold: 0.5
        ))
        for _ in 0..<4 { cb.record(.failure) }
        #expect(cb.state() == .closed)
    }

    @Test func openToHalfOpenAfterDuration() throws {
        let clock = MockBreakerClock()
        let cb = CircuitBreaker(
            config: BreakerConfig(minSamples: 1, openDuration: (50 / 1000.0)),
            clock: clock
        )
        cb.record(.failure)
        #expect(cb.state() == .open)
        #expect(throws: BreakerOpenError.self) { try cb.check() }

        clock.advance((70 / 1000.0))
        try cb.check()
        #expect(cb.state() == .halfOpen)
    }

    @Test func halfOpenToClosedOnProbeSuccess() throws {
        let clock = MockBreakerClock()
        let cb = CircuitBreaker(
            config: BreakerConfig(minSamples: 1, openDuration: (50 / 1000.0)),
            clock: clock
        )
        cb.record(.failure)
        clock.advance((70 / 1000.0))
        try cb.check()
        cb.record(.success)
        #expect(cb.state() == .closed)
    }

    @Test func halfOpenToOpenOnProbeFailure() throws {
        let clock = MockBreakerClock()
        let cb = CircuitBreaker(
            config: BreakerConfig(minSamples: 1, openDuration: (50 / 1000.0)),
            clock: clock
        )
        cb.record(.failure)
        clock.advance((70 / 1000.0))
        try cb.check()
        cb.record(.failure)
        #expect(cb.state() == .open)
    }

    @Test func oldSamplesEvictedFromWindow() throws {
        let clock = MockBreakerClock()
        let cb = CircuitBreaker(
            config: BreakerConfig(
                windowDuration: (100 / 1000.0),
                minSamples: 2,
                errorRateThreshold: 0.5,
                openDuration: (50 / 1000.0)
            ),
            clock: clock
        )
        cb.record(.failure)
        cb.record(.failure)
        #expect(cb.state() == .open)

        clock.advance((70 / 1000.0))
        try cb.check()
        cb.record(.success)
        #expect(cb.state() == .closed)

        cb.record(.failure)
        clock.advance((120 / 1000.0))
        cb.record(.success)
        #expect(cb.state() == .closed)
        #expect(cb.errorRate() < 0.01)
    }

    @Test func disabledBreakerAlwaysAllows() throws {
        let cb = CircuitBreaker(config: BreakerConfig(minSamples: 1, enabled: false))
        cb.record(.failure)
        cb.record(.failure)
        try cb.check()
        #expect(cb.state() == .closed)
    }

    @Test func disabledBreakerDoesNotAccumulate() {
        let cb = CircuitBreaker(config: BreakerConfig(minSamples: 1, enabled: false))
        for _ in 0..<100 { cb.record(.failure) }
        #expect(abs(cb.errorRate()) < Double.ulpOfOne)
        #expect(cb.state() == .closed)
    }

    @Test func isFailureStatusMatchesConfiguredCodes() {
        let cb = CircuitBreaker(config: .server())
        for code: UInt16 in [429, 500, 502, 503, 504] {
            #expect(cb.isFailureStatus(code))
        }
        for code: UInt16 in [200, 201, 301, 400, 404, 501] {
            #expect(!cb.isFailureStatus(code))
        }
    }

    @Test func halfOpenProbeExhaustion() throws {
        let clock = MockBreakerClock()
        let cb = CircuitBreaker(
            config: BreakerConfig(
                minSamples: 1,
                openDuration: (50 / 1000.0),
                halfOpenMaxProbes: 1
            ),
            clock: clock
        )
        cb.record(.failure)
        clock.advance((70 / 1000.0))
        try cb.check() // claims the only probe
        #expect(throws: BreakerOpenError.self) { try cb.check() }
    }

    @Test func abandonedProbeReclaim() throws {
        let clock = MockBreakerClock()
        let cb = CircuitBreaker(
            config: BreakerConfig(
                minSamples: 1,
                openDuration: (50 / 1000.0),
                halfOpenMaxProbes: 1
            ),
            clock: clock
        )
        cb.record(.failure)
        clock.advance((70 / 1000.0))
        try cb.check() // claim probe, never record
        // After open_duration, abandoned probe may be reclaimed.
        clock.advance((60 / 1000.0))
        try cb.check()
    }
}

@Suite("BreakerConfig")
struct BreakerConfigTests {
    @Test func parseFailureCodesBasic() {
        #expect(parseFailureCodes("429,500,502,503,504") == [429, 500, 502, 503, 504])
    }

    @Test func parseFailureCodesWithWhitespace() {
        #expect(parseFailureCodes(" 429 , 500 , 502 ") == [429, 500, 502])
    }

    @Test func parseFailureCodesIgnoresInvalid() {
        #expect(parseFailureCodes("429,abc,500,,999999") == [429, 500])
    }

    @Test func parseFailureCodesEmpty() {
        #expect(parseFailureCodes("").isEmpty)
    }

    @Test func fromLookupDefaults() {
        let config = BreakerConfig.fromLookup(prefix: "CB_", get: { _ in nil })
        #expect(config.windowDuration == 60)
        #expect(config.minSamples == 10)
        #expect(abs(config.errorRateThreshold - 0.5) < Double.ulpOfOne)
        #expect(config.openDuration == 10)
        #expect(config.halfOpenMaxProbes == 1)
        #expect(config.failureCodes == defaultBreakerFailureCodes)
        #expect(config.enabled)
    }

    @Test func fromLookupOverrides() {
        let config = BreakerConfig.fromLookup(prefix: "CB_") { key in
            switch key {
            case "CB_WINDOW_SECS": return "120"
            case "CB_MIN_SAMPLES": return "20"
            case "CB_ERROR_RATE_THRESHOLD": return "0.8"
            case "CB_OPEN_DURATION_SECS": return "30"
            case "CB_HALF_OPEN_MAX_PROBES": return "3"
            case "CB_FAILURE_CODES": return "500,503"
            case "CB_ENABLED": return "false"
            default: return nil
            }
        }
        #expect(config.windowDuration == 120)
        #expect(config.minSamples == 20)
        #expect(abs(config.errorRateThreshold - 0.8) < Double.ulpOfOne)
        #expect(config.openDuration == 30)
        #expect(config.halfOpenMaxProbes == 3)
        #expect(config.failureCodes == [500, 503])
        #expect(!config.enabled)
    }

    @Test func clientPreset() {
        let c = BreakerConfig.client()
        #expect(c.minSamples == 5)
        #expect(c.openDuration == 60)
        #expect(c.failureCodes == [401])
    }
}

@Suite("RetryPolicy")
struct RetryPolicyTests {
    @Test func serverShouldRetry() {
        let policy = RetryPolicy.server()
        for code: UInt16 in [429, 500, 502, 503, 504, 501, 520] {
            #expect(policy.shouldRetry(code), "expected \(code) to retry")
        }
        for code: UInt16 in [400, 401, 403, 404, 200] {
            #expect(!policy.shouldRetry(code), "expected \(code) to NOT retry")
        }
        #expect(policy.classify(200) == nil)
    }

    @Test func clientStorageClassify() {
        let policy = RetryPolicy.clientStorage()
        for code: UInt16 in [400, 403, 404] {
            #expect(policy.classify(code) == .terminal)
        }
        #expect(policy.classify(401) == .authRefresh)
        for code: UInt16 in [429, 500, 503, 409, 422] {
            #expect(policy.classify(code) == .retryable)
        }
        #expect(policy.classify(200) == nil)
    }
}

@Suite("Registry")
struct RegistryTests {
    @Test func returnsNoneWhenDisabled() {
        var cfg = BreakerConfig.server()
        cfg.enabled = false
        let reg = CircuitBreakerRegistry(config: cfg)
        #expect(reg.get("endpoint-a") == nil)
    }

    @Test func sameKeySameBreaker() {
        let reg = CircuitBreakerRegistry(config: .server())
        let a = reg.get("endpoint-a")
        let b = reg.get("endpoint-a")
        #expect(a != nil && b != nil)
        // Distinct keys isolate state.
        let c = reg.get("endpoint-b")!
        a!.record(.failure)
        a!.record(.failure)
        a!.record(.failure)
        a!.record(.failure)
        a!.record(.failure)
        a!.record(.failure)
        a!.record(.failure)
        a!.record(.failure)
        a!.record(.failure)
        a!.record(.failure)
        #expect(a!.state() == .open)
        #expect(c.state() == .closed)
    }
}

@Suite("Backoff and Retry-After")
struct BackoffTests {
    @Test func deterministicJitter() {
        let a = retryBackoffWithJitter(retryCount: 1, seed: 42)
        let b = retryBackoffWithJitter(retryCount: 1, seed: 42)
        #expect(a == b)
        // Base 2000ms ±20% → 1600...2400
        let ms = a * 1000.0
        #expect(ms >= 1600 && ms <= 2400)
    }

    @Test func parseRetryAfterSeconds() {
        #expect(parseRetryAfterHeader("3") == 3)
        #expect(parseRetryAfterHeader(" 1.5 ") == 1.5)
        #expect(parseRetryAfterHeader(nil) == nil)
        #expect(parseRetryAfterHeader("not-a-number") == nil)
    }

    @Test func parseRetryAfterHTTPDateFutureAndPast() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"

        let future = formatter.string(from: now.addingTimeInterval(45))
        let past = formatter.string(from: now.addingTimeInterval(-10))
        #expect(abs((parseRetryAfterHeader(future, now: now) ?? -1) - 45) < 0.5)
        // Past dates clamp to zero remaining delay.
        #expect(parseRetryAfterHeader(past, now: now) == 0)
    }

    @Test func parseRetryAfterMalformedDate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(parseRetryAfterHeader("Mon, 99 Foo 9999 99:99:99 GMT", now: now) == nil)
        #expect(parseRetryAfterHeader("totally-not-a-date", now: now) == nil)
        #expect(parseHTTPDate("") == nil)
    }

    @Test func mockWallClockAdvancesDeterministically() {
        let clock = MockWallClock(now: Date(timeIntervalSince1970: 1_000))
        #expect(clock.now().timeIntervalSince1970 == 1_000)
        clock.advance(2.5)
        #expect(clock.now().timeIntervalSince1970 == 1_002.5)
        clock.set(Date(timeIntervalSince1970: 50))
        #expect(clock.now().timeIntervalSince1970 == 50)
    }

    @Test func breakerOpenDisplay() {
        let err = BreakerOpenError(retryAfter: (5300 / 1000.0))
        #expect(err.description == "circuit breaker open; retry after 5.3s")
    }
}

@Suite("Concurrency")
struct ConcurrencyTests {
    @Test func concurrentRecordsDoNotCrash() async {
        let cb = CircuitBreaker(config: BreakerConfig(minSamples: 50, errorRateThreshold: 0.5))
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask {
                    if i % 2 == 0 {
                        cb.record(.failure)
                    } else {
                        cb.record(.success)
                    }
                    _ = try? cb.check()
                    _ = cb.errorRate()
                }
            }
        }
        // Just reach a terminal state without trapping.
        _ = cb.state()
    }
}
