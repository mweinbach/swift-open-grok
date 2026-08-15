// TerminalProbe.swift
//
// Shared startup terminal-probe primitives from pin
// `xai-grok-pager-render/src/terminal/probe.rs` at 650c1db7.
//
// Pin `write_query` locks the TUI stderr fd and returns false when that fd
// is not a TTY. This port never takes stdin and never locks a process-wide
// stream: adapters write the returned/appended bytes themselves. Cost: a
// concurrent render write can interleave with the query unless the adapter
// serializes. Timed stdin reads stay out of this target (DA2/OSC 11 glue).

import Foundation

// MARK: - Bounds (probe.rs:17-25)

/// Bounds the reply buffer against terminals that stream without a terminator.
/// Pin `MAX_PROBE_RESPONSE` (probe.rs:17).
public let MAX_PROBE_RESPONSE: Int = 256

/// Hard cap on post-deadline consumption of an in-flight reply (probe.rs:21).
public let LATE_REPLY_GRACE_MILLISECONDS: UInt64 = 100

/// Per-byte quiet window during the grace period (probe.rs:25).
public let LATE_REPLY_QUIET_MILLISECONDS: Int32 = 25

// MARK: - Query write (probe.rs:29-42)

/// Append `query` onto `destination`.
///
/// Returns `false` when there is nothing to write. Pin `write_query` also
/// returns false when the TTY write fails; this helper has no fd, so the
/// only failure is an empty query.
public func writeProbeQuery(_ query: [UInt8], into destination: inout [UInt8]) -> Bool {
    guard !query.isEmpty else { return false }
    destination.append(contentsOf: query)
    return true
}

/// Query bytes a caller should write. Identity helper so every probe shares
/// one encoding path instead of inlining literals at each call site.
public func probeQueryBytes(_ query: [UInt8]) -> [UInt8] {
    query
}

// MARK: - Reply accumulation (probe.rs:69, 102)

/// True when the reply buffer has hit `MAX_PROBE_RESPONSE`.
public func probeResponseReachedCap(_ buffer: [UInt8]) -> Bool {
    buffer.count >= MAX_PROBE_RESPONSE
}

/// Stop predicate used by the timed-read path (`probe.rs:69, 102`):
/// size cap or the caller's terminator.
public func shouldStopProbeResponse(
    _ buffer: [UInt8],
    lastByte: UInt8,
    isTerminated: ([UInt8], UInt8) -> Bool
) -> Bool {
    probeResponseReachedCap(buffer) || isTerminated(buffer, lastByte)
}

/// OSC 11 stop predicate (`osc11.rs` `unix_read_with_timeout`): BEL, or
/// 7-bit ST (`ESC \`). Byte-level so a CRLF pair cannot collapse into one
/// Character and skip the `\` of a following ST.
public func probeReplyIsBelOrSevenBitST(_ buffer: [UInt8], lastByte: UInt8) -> Bool {
    if lastByte == 0x07 { return true }
    return buffer.count >= 2
        && buffer[buffer.count - 2] == 0x1B
        && lastByte == 0x5C
}

/// DCS/OSC terminator used by XTVERSION parse: BEL, 7-bit ST (`ESC \`),
/// or 8-bit ST (`0x9C`). The event-loop filter accepts BEL as Ctrl+G
/// (`xt_filter.rs:280-287`); the diagnostics collector also accepts `0x9C`.
public func probeReplyIsDcsTerminated(_ buffer: [UInt8], lastByte: UInt8) -> Bool {
    if lastByte == 0x9C { return true }
    return probeReplyIsBelOrSevenBitST(buffer, lastByte: lastByte)
}
