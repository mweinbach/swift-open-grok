// ScheduledTaskTests.swift
//
// Golden parity with upstream's `ScheduledTask` tests (`types.rs:340-407`),
// against fixed clocks — upstream constructs with `Utc::now()`; the port
// injects the instant, so the same assertions hold exactly instead of within
// a tolerance.

import Foundation
import Testing
import OpenGrokScheduler

/// 2023-11-14T22:13:20Z — an arbitrary fixed instant, whole seconds so
/// Codable round trips compare equal at millisecond encoding precision.
private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

@Suite("ScheduledTask")
struct ScheduledTaskTests {
    // types.rs:344-351
    @Test("new recurring task has 7 day expiry")
    func recurringTaskHas7DayExpiry() throws {
        let task = ScheduledTask(
            intervalSecs: 300, prompt: "check deploy", recurring: true, durable: false, now: t0
        )
        let expiry = try #require(task.expiresAt)
        #expect(expiry.timeIntervalSince(task.createdAt) == 7 * 86_400)
    }

    // types.rs:353-357
    @Test("new one-shot task has no expiry")
    func oneShotTaskHasNoExpiry() {
        let task = ScheduledTask(
            intervalSecs: 300, prompt: "check deploy", recurring: false, durable: false, now: t0
        )
        #expect(task.expiresAt == nil)
    }

    // types.rs:359-364
    @Test("next fire at uses created at when never fired")
    func nextFireAtUsesCreatedAt() {
        let task = ScheduledTask(
            intervalSecs: 300, prompt: "test", recurring: true, durable: false, now: t0
        )
        #expect(task.nextFireAt() == task.createdAt.addingTimeInterval(300))
    }

    // types.rs:366-373
    @Test("next fire at uses last fired at when present")
    func nextFireAtUsesLastFiredAt() {
        var task = ScheduledTask(
            intervalSecs: 300, prompt: "test", recurring: true, durable: false, now: t0
        )
        let fired = t0.addingTimeInterval(1234)
        task.markFired(at: fired)
        #expect(task.lastFiredAt == fired)
        #expect(task.nextFireAt() == fired.addingTimeInterval(300))
    }

    // types.rs:375-380
    @Test("is expired returns true when past expiry")
    func isExpiredPastExpiry() {
        var task = ScheduledTask(
            intervalSecs: 300, prompt: "test", recurring: true, durable: false, now: t0
        )
        task.expiresAt = t0.addingTimeInterval(-3600)
        #expect(task.isExpired(now: t0))
    }

    // types.rs:382-386, plus the boundary: is_expired uses >=, so the task
    // expires exactly at the deadline instant (types.rs:288).
    @Test("is expired returns false before expiry, true at the instant")
    func isExpiredBeforeExpiry() throws {
        let task = ScheduledTask(
            intervalSecs: 300, prompt: "test", recurring: true, durable: false, now: t0
        )
        #expect(!task.isExpired(now: t0))
        let expiry = try #require(task.expiresAt)
        #expect(task.isExpired(now: expiry))
    }

    // types.rs:388-392
    @Test("is expired returns false for one-shot")
    func isExpiredOneShot() {
        let task = ScheduledTask(
            intervalSecs: 300, prompt: "test", recurring: false, durable: false, now: t0
        )
        #expect(!task.isExpired(now: t0.addingTimeInterval(365 * 86_400)))
    }

    // types.rs:403-407, sharpened to a value golden: the upstream id is the
    // first 12 hex chars of a UUIDv7, i.e. the 48-bit unix-millisecond
    // timestamp — 1_700_000_000_000 ms = 0x018bcfe56800.
    @Test("task id is 12 chars and is the hex millisecond timestamp")
    func taskIdIs12Chars() {
        let task = ScheduledTask(
            intervalSecs: 300, prompt: "test", recurring: true, durable: false, now: t0
        )
        #expect(task.id.count == 12)
        #expect(task.id == "018bcfe56800")
    }

    // types.rs:253-257: fire_immediately backdates created_at by one
    // interval so the first tick is due now; types.rs:269-273: the 7-day
    // expiry stays anchored at now, not the backdated created_at.
    @Test("fire immediately backdates created at so first tick is due")
    func fireImmediatelyBackdates() throws {
        let task = ScheduledTask(
            intervalSecs: 300, prompt: "test", recurring: true, durable: false,
            fireImmediately: true, now: t0
        )
        #expect(task.createdAt == t0.addingTimeInterval(-300))
        #expect(task.nextFireAt() == t0)
        #expect(task.isDue(now: t0))
        let expiry = try #require(task.expiresAt)
        #expect(expiry == t0.addingTimeInterval(7 * 86_400))
    }

    // actor.rs:284 fires on next_fire_at() <= now — due exactly at the
    // boundary instant, not one tick later.
    @Test("is due uses inclusive comparison")
    func isDueInclusive() {
        let task = ScheduledTask(
            intervalSecs: 300, prompt: "test", recurring: true, durable: false, now: t0
        )
        #expect(!task.isDue(now: t0.addingTimeInterval(299)))
        #expect(task.isDue(now: t0.addingTimeInterval(300)))
    }
}

@Suite("ScheduledTask Codable")
struct ScheduledTaskCodableTests {
    // types.rs:394-401 — the legacy-state golden: pre-`recurring` documents
    // decode with recurring=true, durable=false via serde defaults.
    @Test("legacy state defaults recurring and durable fields")
    func legacyStateDefaults() throws {
        let json = Data("""
        {"id":"abc123","intervalSecs":300,"prompt":"check",
         "createdAt":"2026-01-01T00:00:00Z",
         "lastFiredAt":null,"expiresAt":null}
        """.utf8)
        let task = try JSONDecoder().decode(ScheduledTask.self, from: json)
        #expect(task.recurring)
        #expect(!task.durable)
        #expect(!task.foreground)
        #expect(task.lastFiredAt == nil)
        #expect(task.expiresAt == nil)
        #expect(task.lastSubagentId == nil)
        #expect(task.iterationsSinceFresh == 0)
        #expect(!task.chainResetPending)
        // 2026-01-01T00:00:00Z
        #expect(task.createdAt == Date(timeIntervalSince1970: 1_767_225_600))
    }

    @Test("round trip preserves fields at millisecond precision")
    func roundTrip() throws {
        var task = ScheduledTask(
            intervalSecs: 300, prompt: "check deploy", recurring: true, durable: true,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        task.markFired(at: Date(timeIntervalSince1970: 1_700_000_300))
        task.lastSubagentId = "sub-1"
        task.iterationsSinceFresh = 3
        task.chainResetPending = true

        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(ScheduledTask.self, from: data)
        #expect(decoded == task)
    }

    // chrono emits sub-second fractions up to nanoseconds; the decoder must
    // accept any precision, not just the 3 digits ISO8601DateFormatter parses.
    @Test("decodes chrono nanosecond timestamps")
    func decodesNanosecondTimestamps() throws {
        let json = Data("""
        {"id":"abc123","intervalSecs":300,"prompt":"check",
         "createdAt":"2026-01-01T00:00:00.123456789Z"}
        """.utf8)
        let task = try JSONDecoder().decode(ScheduledTask.self, from: json)
        let expected = Date(timeIntervalSince1970: 1_767_225_600.123456789)
        #expect(abs(task.createdAt.timeIntervalSince(expected)) < 0.000001)
    }
}
