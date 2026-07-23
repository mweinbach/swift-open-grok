// Metrics.swift
//
// Per-response inference latency metrics. Mirrors Rust `metrics.rs`.

import Foundation

/// Compute percentiles from a non-empty sorted slice of intervals.
///
/// Returns `(p50, p99, max, mean, sum)`.
public func computePercentiles(_ sorted: [UInt64]) -> (p50: UInt64, p99: UInt64, max: UInt64, mean: UInt64, sum: UInt64) {
    precondition(!sorted.isEmpty, "Cannot compute percentiles from empty slice")
    let len = sorted.count
    let p50 = sorted[len / 2]
    let p99Idx = min(max(Int((Double(len) * 0.99).rounded(.up)) - 1, 0), len - 1)
    let p99 = sorted[p99Idx]
    let maxV = sorted[len - 1]
    let sum = sorted.reduce(UInt64(0), +)
    let mean = sum / UInt64(len)
    return (p50, p99, maxV, mean, sum)
}

/// Per-response inference latency metrics computed from chunk timestamps.
public struct InferenceLatencyStats: Codable, Sendable, Equatable, Hashable {
    /// Time to first content token (ms).
    public var timeToFirstTokenMs: UInt64?
    /// Time to last byte / stream end (ms).
    public var timeToLastByteMs: UInt64
    /// Number of content chunks received.
    public var chunkCount: UInt32
    /// Inter-token latency intervals (raw data for session aggregation).
    public var itlIntervalsMs: [UInt64]
    public var itlP50Ms: UInt64?
    public var itlP99Ms: UInt64?
    public var itlMaxMs: UInt64?
    public var itlMeanMs: UInt64?
    /// Total request attempts (`1` = no retries); set by the retry loop on success.
    public var attempts: UInt32

    public init(
        timeToFirstTokenMs: UInt64? = nil,
        timeToLastByteMs: UInt64 = 0,
        chunkCount: UInt32 = 0,
        itlIntervalsMs: [UInt64] = [],
        itlP50Ms: UInt64? = nil,
        itlP99Ms: UInt64? = nil,
        itlMaxMs: UInt64? = nil,
        itlMeanMs: UInt64? = nil,
        attempts: UInt32 = 0
    ) {
        self.timeToFirstTokenMs = timeToFirstTokenMs
        self.timeToLastByteMs = timeToLastByteMs
        self.chunkCount = chunkCount
        self.itlIntervalsMs = itlIntervalsMs
        self.itlP50Ms = itlP50Ms
        self.itlP99Ms = itlP99Ms
        self.itlMaxMs = itlMaxMs
        self.itlMeanMs = itlMeanMs
        self.attempts = attempts
    }

    public enum CodingKeys: String, CodingKey {
        case timeToFirstTokenMs = "time_to_first_token_ms"
        case timeToLastByteMs = "time_to_last_byte_ms"
        case chunkCount = "chunk_count"
        case itlIntervalsMs = "itl_intervals_ms"
        case itlP50Ms = "itl_p50_ms"
        case itlP99Ms = "itl_p99_ms"
        case itlMaxMs = "itl_max_ms"
        case itlMeanMs = "itl_mean_ms"
        case attempts
    }

    /// Compute latency stats from continuous-clock timestamps.
    ///
    /// - Parameters:
    ///   - streamStart: captured before initiating the stream
    ///   - chunkTimestamps: recorded on each content-bearing chunk
    ///   - streamEnd: captured after the stream is fully exhausted
    public static func fromTimestamps(
        streamStart: MonotonicInstant,
        chunkTimestamps: [MonotonicInstant],
        streamEnd: MonotonicInstant
    ) -> InferenceLatencyStats {
        let ttlb = UInt64(max(0, (streamEnd - streamStart).components.seconds * 1000
            + (streamEnd - streamStart).components.attoseconds / 1_000_000_000_000_000))

        if chunkTimestamps.isEmpty {
            return InferenceLatencyStats(timeToLastByteMs: ttlb)
        }

        let ttfbDuration = chunkTimestamps[0] - streamStart
        let ttfb = ttfbDuration.nanoseconds / 1_000_000

        var intervals: [UInt64] = []
        if chunkTimestamps.count >= 2 {
            for i in 1..<chunkTimestamps.count {
                let d = chunkTimestamps[i] - chunkTimestamps[i - 1]
                let ms = d.nanoseconds / 1_000_000
                intervals.append(ms)
            }
        }

        var itlP50: UInt64?
        var itlP99: UInt64?
        var itlMax: UInt64?
        var itlMean: UInt64?
        if !intervals.isEmpty {
            var sorted = intervals
            sorted.sort()
            let p = computePercentiles(sorted)
            itlP50 = p.p50
            itlP99 = p.p99
            itlMax = p.max
            itlMean = p.mean
        }

        return InferenceLatencyStats(
            timeToFirstTokenMs: ttfb,
            timeToLastByteMs: ttlb,
            chunkCount: UInt32(min(chunkTimestamps.count, Int(UInt32.max))),
            itlIntervalsMs: intervals,
            itlP50Ms: itlP50,
            itlP99Ms: itlP99,
            itlMaxMs: itlMax,
            itlMeanMs: itlMean,
            attempts: 0
        )
    }

    /// Convenience using `Date` (wall clock) — primarily for tests and
    /// environments where ContinuousClock is inconvenient.
    public static func fromDates(
        streamStart: Date,
        chunkTimestamps: [Date],
        streamEnd: Date
    ) -> InferenceLatencyStats {
        let ttlb = UInt64(max(0, streamEnd.timeIntervalSince(streamStart) * 1000).rounded())
        if chunkTimestamps.isEmpty {
            return InferenceLatencyStats(timeToLastByteMs: ttlb)
        }
        let ttfb = UInt64(max(0, chunkTimestamps[0].timeIntervalSince(streamStart) * 1000).rounded())
        var intervals: [UInt64] = []
        if chunkTimestamps.count >= 2 {
            for i in 1..<chunkTimestamps.count {
                let ms = UInt64(max(0, chunkTimestamps[i].timeIntervalSince(chunkTimestamps[i - 1]) * 1000).rounded())
                intervals.append(ms)
            }
        }
        var itlP50: UInt64?
        var itlP99: UInt64?
        var itlMax: UInt64?
        var itlMean: UInt64?
        if !intervals.isEmpty {
            var sorted = intervals
            sorted.sort()
            let p = computePercentiles(sorted)
            itlP50 = p.p50
            itlP99 = p.p99
            itlMax = p.max
            itlMean = p.mean
        }
        return InferenceLatencyStats(
            timeToFirstTokenMs: ttfb,
            timeToLastByteMs: ttlb,
            chunkCount: UInt32(min(chunkTimestamps.count, Int(UInt32.max))),
            itlIntervalsMs: intervals,
            itlP50Ms: itlP50,
            itlP99Ms: itlP99,
            itlMaxMs: itlMax,
            itlMeanMs: itlMean,
            attempts: 0
        )
    }
}
