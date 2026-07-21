// OpenGrokTokenEstimation.swift
//
// Open Grok — Swift port of `xai-token-estimation` (crates/codegen/xai-token-estimation).
//
// Pure shared token-estimation primitives. This module is the single source
// of truth for the bytes/4 heuristic and the derived-display arithmetic that
// `/context`, `/session-info`, the auto-compact gates, the preflight overflow
// check, and every client renderer use to talk about context-window usage.
//
// The crate has no dependencies and no I/O — it is pure arithmetic. The
// Swift port mirrors that exactly: top-level functions on `UInt64`/`UInt8`
// with `@inlinable` hints where the Rust source marks them `#[inline]`.

import Foundation

/// Bytes per token under the rough character-based heuristic.
public let BYTES_PER_TOKEN: UInt64 = 4

/// Per-image approximate token cost when summing low-resolution image patches.
public let IMAGE_TOKEN_ESTIMATE: UInt64 = 765

/// Bytes/4 estimate of a string's token count.
///
/// Mirrors Rust `estimate_tokens(&str) -> u64`:
/// `(s.len() as u64) / BYTES_PER_TOKEN`. Uses UTF-8 byte length to match the
/// Rust `str::len()` (which counts bytes, not scalar values or grapheme
/// clusters).
@inlinable
public func estimateTokens(_ s: String) -> UInt64 {
    UInt64(s.utf8.count) / BYTES_PER_TOKEN
}

/// Bytes/4 estimate of a byte buffer's token count.
@inlinable
public func estimateTokens(bytes: Int) -> UInt64 {
    UInt64(bytes) / BYTES_PER_TOKEN
}

/// Inverse of `estimateTokens`: convert a token budget into a character
/// budget. Used by skill discovery to size text passages against the model's
/// context window.
@inlinable
public func estimateChars(tokens: UInt64) -> UInt64 {
    tokens.multipliedWithOverflowCheck(BYTES_PER_TOKEN)
}

/// Token estimate for `imageCount` images at `IMAGE_TOKEN_ESTIMATE` each.
@inlinable
public func estimateImageTokens(imageCount: UInt64) -> UInt64 {
    imageCount.multipliedWithOverflowCheck(IMAGE_TOKEN_ESTIMATE)
}

/// Usage percentage as `Double`, clamped to `100.0`. Returns `0.0` when
/// `total == 0`.
@inlinable
public func usagePercentage(used: UInt64, total: UInt64) -> Double {
    if total == 0 { return 0.0 }
    let ratio = Double(used) / Double(total) * 100.0
    return min(ratio, 100.0)
}

/// Usage percentage rounded to `UInt8`, clamped to `100`.
///
/// Uses Swift's `.toNearestOrEven` rounding. The Rust source uses
/// `f64::round()`, which is round-half-away-from-zero; for positive values
/// (the only values this helper can produce — `used` and `total` are
/// `u64`) the two strategies agree on the half-boundary `0.5` → `1`, so the
/// half-up contract documented in the Rust tests (`85 / 200 = 42.5` → `43`)
/// is preserved.
@inlinable
public func usagePercentageU8(used: UInt64, total: UInt64) -> UInt8 {
    let pct = usagePercentage(used: used, total: total)
    // `Double.rounded()` defaults to `.toNearestOrEven`. For the half-up
    // contract, use `.awayFromZero` (matches `f64::round()` for positives).
    let rounded = pct.rounded(.awayFromZero)
    // Clamp to 0...100 defensively; usagePercentage already clamps to 100,
    // and negative values are impossible for unsigned inputs.
    if rounded <= 0 { return 0 }
    if rounded >= 100 { return 100 }
    return UInt8(rounded)
}

/// Integer-arithmetic (truncating) usage percentage, clamped to `100`.
///
/// Differs from `usagePercentageU8` in two ways: no `Double` round-trip,
/// and the result is **truncated** (not rounded).
///
/// Returns `UInt8` because the result is bounded to `100`. Saturates on
/// overflow via `multiplyingWithOverflowCheck`.
@inlinable
public func usagePercentageTruncatedU8(used: UInt64, total: UInt64) -> UInt8 {
    if total == 0 { return 0 }
    let scaled = used.multipliedWithOverflowCheck(100) / total
    let clamped = min(scaled, 100)
    return UInt8(clamped)
}

/// `total - used`, saturating at zero. The "free" portion of the context
/// window for `/context` rendering.
@inlinable
public func freeTokens(total: UInt64, used: UInt64) -> UInt64 {
    total.subtractingWithSaturate(used)
}

/// True when `used >= contextWindow * thresholdPercent / 100`. Returns
/// `false` for `contextWindow == 0` so callers do not have to special-case
/// missing windows. Computed in integer arithmetic to match the existing
/// auto-compact gate semantics.
@inlinable
public func exceedsThreshold(used: UInt64, contextWindow: UInt64, thresholdPercent: UInt8) -> Bool {
    if contextWindow == 0 { return false }
    let lhs = used.multipliedWithOverflowCheck(100)
    let rhs = contextWindow.multipliedWithOverflowCheck(UInt64(thresholdPercent))
    return lhs >= rhs
}

/// True when `used * 100 >= contextWindow * thresholdPercent - headroom * 100`,
/// the scaled form of `exceedsThreshold` minus a token headroom.
/// Returns `false` for `contextWindow == 0`.
@inlinable
public func exceedsThresholdWithHeadroom(
    used: UInt64,
    contextWindow: UInt64,
    thresholdPercent: UInt8,
    headroom: UInt64
) -> Bool {
    if contextWindow == 0 { return false }
    let lhs = used.multipliedWithOverflowCheck(100)
    let scaledThreshold = contextWindow.multipliedWithOverflowCheck(UInt64(thresholdPercent))
    let scaledHeadroom = headroom.multipliedWithOverflowCheck(100)
    let rhs = scaledThreshold.subtractingWithSaturate(scaledHeadroom)
    return lhs >= rhs
}

// MARK: - Overflow-safe arithmetic helpers
//
// Rust uses `saturating_mul` / `saturating_sub` on `u64`. Swift's `&*` and
// `&-` provide the wrapping equivalents, but the Rust semantics saturate
// (clamp at the bounds) rather than wrap. These helpers preserve the Rust
// behavior so the strict boundary contracts in the Rust tests hold.
//
// Marked `@usableFromInline` so they can be called from the `@inlinable`
// public functions above without leaking the implementation through the
// module boundary.

internal extension UInt64 {
    /// Saturating multiplication: clamps at `UInt64.max` on overflow.
    @usableFromInline
    func multipliedWithOverflowCheck(_ other: UInt64) -> UInt64 {
        let (product, overflow) = self.multipliedReportingOverflow(by: other)
        return overflow ? UInt64.max : product
    }

    /// Saturating subtraction: clamps at zero on underflow.
    @usableFromInline
    func subtractingWithSaturate(_ other: UInt64) -> UInt64 {
        let (diff, overflow) = self.subtractingReportingOverflow(other)
        return overflow ? 0 : diff
    }
}
