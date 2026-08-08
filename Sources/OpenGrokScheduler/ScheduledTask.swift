// ScheduledTask.swift
//
// Open Grok — Swift port of `ScheduledTask` from
// `xai-grok-tools/src/implementations/grok_build/scheduler/types.rs:203-290`.
//
// Every time-dependent operation takes an explicit `now: Date` instead of
// reading the process clock. That is the injectable-clock seam: the runtime
// slice passes `Date()`, tests pass fixed instants, and next-fire/due/expiry
// math stays deterministic. There is no clock protocol to conform to — a
// `Date` parameter is the whole contract.

import Foundation

/// After this many consecutive fires, a loop restarts from a fresh transcript
/// summary instead of resuming its chain (`types.rs:230`).
public let loopFreshChainEvery: UInt32 = 10

/// Cap on the completion output a fire reports back (`types.rs:232`).
public let loopCompletionOutputCap = 4_000

/// A scheduled recurring task, ported field-for-field from `types.rs:205-228`.
/// Serialized with camelCase keys to match upstream's
/// `#[serde(rename_all = "camelCase")]`, so state written by the Rust
/// implementation decodes here and vice versa.
public struct ScheduledTask: Codable, Equatable, Sendable {
    public var id: String
    public var intervalSecs: UInt64
    public var prompt: String
    public var recurring: Bool
    public var durable: Bool
    public var foreground: Bool
    public var createdAt: Date
    public var lastFiredAt: Date?
    public var expiresAt: Date?
    public var lastSubagentId: String?
    public var iterationsSinceFresh: UInt32
    /// Set when the prompt is patched: the next fire starts a fresh
    /// transcript instead of resuming the old task's. The anchor itself is
    /// kept until then so the in-flight guard can still see a running
    /// iteration. (`types.rs:222-227`)
    public var chainResetPending: Bool

    /// Port of `ScheduledTask::with_fire_immediately` (`types.rs:245-278`);
    /// upstream's `new` is the same call with `fire_immediately: false`
    /// (`types.rs:241-243`), which the default argument mirrors.
    ///
    /// When `fireImmediately` is true, `createdAt` is anchored in the past so
    /// that `nextFireAt() == now`, firing on the first tick
    /// (`types.rs:253-257`). The 7-day expiry for recurring tasks is anchored
    /// at `now`, NOT the backdated `createdAt` (`types.rs:269-273`) — a
    /// fire-immediately task does not lose one interval of lifetime.
    public init(
        intervalSecs: UInt64,
        prompt: String,
        recurring: Bool,
        durable: Bool,
        fireImmediately: Bool = false,
        now: Date
    ) {
        let createdAt = fireImmediately
            ? now.addingTimeInterval(-TimeInterval(intervalSecs))
            : now
        self.id = Self.makeTaskID(now: now)
        self.intervalSecs = intervalSecs
        self.prompt = prompt
        self.recurring = recurring
        self.durable = durable
        self.foreground = false
        self.createdAt = createdAt
        self.lastFiredAt = nil
        self.expiresAt = recurring ? now.addingTimeInterval(7 * 86_400) : nil
        self.lastSubagentId = nil
        self.iterationsSinceFresh = 0
        self.chainResetPending = false
    }

    /// Upstream derives the id as the first 12 hex chars of a UUIDv7 string
    /// with dashes removed (`types.rs:261`). Per RFC 9562, those 12 nibbles
    /// are exactly the 48-bit big-endian unix-millisecond timestamp, so the
    /// id is the creation time in hex — reproduced here from the injected
    /// clock, byte-identical to upstream for the same wall time. Two tasks
    /// created in the same millisecond share an id; that collision is
    /// inherited from upstream, which never dedupes on create.
    static func makeTaskID(now: Date) -> String {
        let ms = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        return String(format: "%012llx", ms & 0xFFFF_FFFF_FFFF)
    }

    /// Next fire time, computed from `lastFiredAt` (or `createdAt` if never
    /// fired). Port of `next_fire_at` (`types.rs:281-284`); pure in the
    /// stored fields, so it takes no clock.
    public func nextFireAt() -> Date {
        (lastFiredAt ?? createdAt).addingTimeInterval(TimeInterval(intervalSecs))
    }

    /// Whether the task is due at `now`. The actor's tick fires tasks with
    /// `next_fire_at() <= now` (`actor.rs:284`); `<=`, not `<`.
    public func isDue(now: Date) -> Bool {
        nextFireAt() <= now
    }

    /// Whether this task has expired (recurring tasks only). Port of
    /// `is_expired` (`types.rs:287-289`): `>=`, so a task expires exactly at
    /// its deadline instant.
    public func isExpired(now: Date) -> Bool {
        if let expiresAt { return now >= expiresAt }
        return false
    }

    /// Record a fire at `now`, re-anchoring the next fire one interval later.
    public mutating func markFired(at now: Date) {
        lastFiredAt = now
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, intervalSecs, prompt, recurring, durable, foreground
        case createdAt, lastFiredAt, expiresAt, lastSubagentId
        case iterationsSinceFresh, chainResetPending
    }

    /// Decode with upstream's serde defaults: `recurring` defaults true
    /// (`types.rs:209,236-238`); `durable`, `foreground`, `lastSubagentId`,
    /// `iterationsSinceFresh`, and `chainResetPending` default to their zero
    /// values; `lastFiredAt`/`expiresAt` are plain optionals. This is what
    /// lets legacy pre-`recurring` state decode as recurring (the
    /// `legacy_state_defaults_recurring_and_durable_fields` golden,
    /// `types.rs:395-401`).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        intervalSecs = try c.decode(UInt64.self, forKey: .intervalSecs)
        prompt = try c.decode(String.self, forKey: .prompt)
        recurring = try c.decodeIfPresent(Bool.self, forKey: .recurring) ?? true
        durable = try c.decodeIfPresent(Bool.self, forKey: .durable) ?? false
        foreground = try c.decodeIfPresent(Bool.self, forKey: .foreground) ?? false
        createdAt = try Self.decodeDate(c, key: .createdAt)
        lastFiredAt = try Self.decodeDateIfPresent(c, key: .lastFiredAt)
        expiresAt = try Self.decodeDateIfPresent(c, key: .expiresAt)
        lastSubagentId = try c.decodeIfPresent(String.self, forKey: .lastSubagentId)
        iterationsSinceFresh = try c.decodeIfPresent(UInt32.self, forKey: .iterationsSinceFresh) ?? 0
        chainResetPending = try c.decodeIfPresent(Bool.self, forKey: .chainResetPending) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(intervalSecs, forKey: .intervalSecs)
        try c.encode(prompt, forKey: .prompt)
        try c.encode(recurring, forKey: .recurring)
        try c.encode(durable, forKey: .durable)
        try c.encode(foreground, forKey: .foreground)
        try c.encode(RFC3339.string(from: createdAt), forKey: .createdAt)
        // chrono serializes Option::None as JSON null and upstream state
        // files carry the explicit nulls, so encode them rather than omitting.
        try c.encode(lastFiredAt.map(RFC3339.string(from:)), forKey: .lastFiredAt)
        try c.encode(expiresAt.map(RFC3339.string(from:)), forKey: .expiresAt)
        try c.encode(lastSubagentId, forKey: .lastSubagentId)
        try c.encode(iterationsSinceFresh, forKey: .iterationsSinceFresh)
        try c.encode(chainResetPending, forKey: .chainResetPending)
    }

    private static func decodeDate(
        _ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys
    ) throws -> Date {
        let raw = try c.decode(String.self, forKey: key)
        guard let date = RFC3339.date(from: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: c,
                debugDescription: "not an RFC 3339 timestamp: \(raw)"
            )
        }
        return date
    }

    private static func decodeDateIfPresent(
        _ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys
    ) throws -> Date? {
        guard let raw = try c.decodeIfPresent(String.self, forKey: key) else { return nil }
        guard let date = RFC3339.date(from: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: c,
                debugDescription: "not an RFC 3339 timestamp: \(raw)"
            )
        }
        return date
    }
}

/// RFC 3339 codec for scheduler timestamps.
///
/// chrono emits variable-precision fractions (up to nanoseconds);
/// `ISO8601DateFormatter` only parses exactly-three-digit fractions, so
/// decoding strips the fraction, parses the whole-second remainder, and adds
/// the fraction back. Encoding emits millisecond precision — `Date` cannot
/// hold nanoseconds anyway, so a Rust→Swift→Rust round trip truncates below
/// the millisecond. That shifts a re-anchored fire by under 1ms, which is
/// noise against a 60s minimum interval; recorded as a divergence regardless.
public enum RFC3339 {
    public static func string(from date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    public static func date(from string: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) { return date }

        guard let dotIndex = string.firstIndex(of: ".") else { return nil }
        let afterDot = string.index(after: dotIndex)
        var digitsEnd = afterDot
        while digitsEnd < string.endIndex, string[digitsEnd].isNumber {
            digitsEnd = string.index(after: digitsEnd)
        }
        guard digitsEnd > afterDot else { return nil }
        let base = String(string[..<dotIndex]) + String(string[digitsEnd...])
        guard let whole = plain.date(from: base),
              let fraction = Double("0.\(string[afterDot..<digitsEnd])")
        else { return nil }
        return whole.addingTimeInterval(fraction)
    }
}
