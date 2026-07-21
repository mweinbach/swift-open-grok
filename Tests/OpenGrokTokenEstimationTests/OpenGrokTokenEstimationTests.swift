// OpenGrokTokenEstimationTests.swift
//
// Deterministic tests for OpenGrokTokenEstimation, translated from the
// Rust test suite in `crates/codegen/xai-token-estimation/src/lib.rs`.
// These pin the bytes/4 heuristic, the percentage clamps, the rounding
// direction contract, and the strict-boundary `>=` semantics of
// `exceedsThreshold` / `exceedsThresholdWithHeadroom`.

import Testing
import Foundation
@testable import OpenGrokTokenEstimation

@Suite("TokenEstimation")
struct TokenEstimationTests {
    @Test("estimateTokens is bytes over four")
    func estimateTokensIsBytesOverFour() {
        #expect(estimateTokens("") == 0)
        #expect(estimateTokens("abc") == 0)
        #expect(estimateTokens("abcd") == 1)
        #expect(estimateTokens(String(repeating: "x", count: 4000)) == 1000)
    }

    @Test("estimateTokens uses UTF-8 byte length, not scalar count")
    func estimateTokensUsesUTF8Bytes() {
        // "é" is one Unicode scalar but two UTF-8 bytes → 0 tokens.
        #expect(estimateTokens("é") == 0)
        // "😎" is one scalar but four UTF-8 bytes → 1 token.
        #expect(estimateTokens("😎") == 1)
    }

    @Test("estimateChars is inverse")
    func estimateCharsIsInverse() {
        #expect(estimateChars(tokens: 0) == 0)
        #expect(estimateChars(tokens: 1) == 4)
        #expect(estimateChars(tokens: 1000) == 4000)
    }

    @Test("estimateImageTokens uses constant")
    func estimateImageTokensUsesConstant() {
        #expect(estimateImageTokens(imageCount: 0) == 0)
        #expect(estimateImageTokens(imageCount: 1) == IMAGE_TOKEN_ESTIMATE)
        #expect(estimateImageTokens(imageCount: 3) == 3 * IMAGE_TOKEN_ESTIMATE)
    }

    @Test("usagePercentage clamps and handles zero total")
    func usagePercentageClampsAndHandlesZeroTotal() {
        #expect(usagePercentage(used: 0, total: 0) == 0.0)
        #expect(usagePercentage(used: 50, total: 100) == 50.0)
        #expect(usagePercentage(used: 150, total: 100) == 100.0)
        #expect(usagePercentage(used: 100, total: 0) == 0.0)
    }

    @Test("usagePercentageU8 rounds")
    func usagePercentageU8Rounds() {
        #expect(usagePercentageU8(used: 0, total: 100) == 0)
        #expect(usagePercentageU8(used: 50, total: 100) == 50)
        #expect(usagePercentageU8(used: 99, total: 100) == 99)
        // 12_700 / 256_000 = 0.04960... -> 5 after rounding
        #expect(usagePercentageU8(used: 12_700, total: 256_000) == 5)
        #expect(usagePercentageU8(used: 150, total: 100) == 100)
    }

    @Test("usagePercentageU8 rounds half up (boundary contract)")
    func usagePercentageU8RoundsHalfUp() {
        // 85 / 200 = 0.425 → 42.5% rounds half-away-from-zero to 43.
        #expect(usagePercentageU8(used: 85, total: 200) == 43)
        // 7 / 8 = 0.875 → 87.5% rounds to 88.
        #expect(usagePercentageU8(used: 7, total: 8) == 88)
    }

    @Test("usagePercentageTruncatedU8 clamps and handles zero total")
    func usagePercentageTruncatedU8ClampsAndHandlesZeroTotal() {
        #expect(usagePercentageTruncatedU8(used: 0, total: 0) == 0)
        #expect(usagePercentageTruncatedU8(used: 50, total: 100) == 50)
        #expect(usagePercentageTruncatedU8(used: 150, total: 100) == 100)
        // Large values do not overflow because we use saturating multiply.
        #expect(usagePercentageTruncatedU8(used: UInt64.max, total: 1) == 100)
    }

    @Test("usagePercentageTruncatedU8 truncates (does not round)")
    func usagePercentageTruncatedU8TruncatesDoesNotRound() {
        // 85 / 200 = 0.425, truncated -> 42 (rounded would be 43).
        #expect(usagePercentageTruncatedU8(used: 85, total: 200) == 42)
        // 7 / 8 = 0.875, truncated -> 87 (rounded would be 88).
        #expect(usagePercentageTruncatedU8(used: 7, total: 8) == 87)
    }

    @Test("freeTokens saturates")
    func freeTokensSaturates() {
        #expect(freeTokens(total: 100, used: 30) == 70)
        #expect(freeTokens(total: 100, used: 100) == 0)
        #expect(freeTokens(total: 100, used: 200) == 0)
    }

    @Test("exceedsThreshold matches integer percentage")
    func exceedsThresholdMatchesIntegerPct() {
        #expect(!exceedsThreshold(used: 50, contextWindow: 100, thresholdPercent: 85))
        #expect(exceedsThreshold(used: 85, contextWindow: 100, thresholdPercent: 85))
        #expect(exceedsThreshold(used: 99, contextWindow: 100, thresholdPercent: 85))
        #expect(!exceedsThreshold(used: 50, contextWindow: 0, thresholdPercent: 85))
    }

    @Test("exceedsThreshold fires on strict boundary (>= semantics)")
    func exceedsThresholdFiresOnStrictBoundary() {
        // At cw=1000, pct=85, `850 * 100 == 1000 * 85` so the gate fires at
        // exactly 850 tokens (one token earlier than a legacy `>` gate).
        #expect(exceedsThreshold(used: 850, contextWindow: 1000, thresholdPercent: 85))
        #expect(!exceedsThreshold(used: 849, contextWindow: 1000, thresholdPercent: 85))
        // Same shape at the 95% threshold.
        #expect(exceedsThreshold(used: 950, contextWindow: 1000, thresholdPercent: 95))
        #expect(!exceedsThreshold(used: 949, contextWindow: 1000, thresholdPercent: 95))
    }

    @Test("exceedsThresholdWithHeadroom with zero headroom matches exceedsThreshold")
    func exceedsThresholdWithHeadroomZeroHeadroomMatchesExceedsThreshold() {
        let windows: [UInt64] = [0, 1, 50, 100, 101, 1024, 100_000, 128_001, 1_000_001]
        let pcts: [UInt8] = [0, 1, 50, 85, 99, 100]
        let useds: [(UInt64)] = [0, 1, 50_000, 100_000, 128_000, 128_001, 500_000, 1_000_000, 5_000_000]
        for cw in windows {
            for pct in pcts {
                for used in useds {
                    let base = exceedsThreshold(used: used, contextWindow: cw, thresholdPercent: pct)
                    let withHeadroom = exceedsThresholdWithHeadroom(
                        used: used, contextWindow: cw, thresholdPercent: pct, headroom: 0
                    )
                    #expect(base == withHeadroom)
                }
            }
        }
    }

    @Test("exceedsThresholdWithHeadroom subtracts headroom")
    func exceedsThresholdWithHeadroomSubtractsHeadroom() {
        // 100K window, 85% threshold = 85_000. Headroom 4_000 -> fires at 81_000.
        #expect(!exceedsThresholdWithHeadroom(used: 80_999, contextWindow: 100_000, thresholdPercent: 85, headroom: 4_000))
        #expect(exceedsThresholdWithHeadroom(used: 81_000, contextWindow: 100_000, thresholdPercent: 85, headroom: 4_000))
    }

    @Test("exceedsThresholdWithHeadroom zero window returns false")
    func exceedsThresholdWithHeadroomZeroWindow() {
        #expect(!exceedsThresholdWithHeadroom(used: 0, contextWindow: 0, thresholdPercent: 85, headroom: 0))
        #expect(!exceedsThresholdWithHeadroom(used: 100, contextWindow: 0, thresholdPercent: 85, headroom: 4_000))
    }

    @Test("exceedsThresholdWithHeadroom saturates when headroom exceeds threshold")
    func exceedsThresholdWithHeadroomHeadroomLargerThanThresholdSaturates() {
        // 100K * 85% = 85_000 (8_500_000 scaled). Headroom 1M tokens scales to
        // 100_000_000 — saturating sub yields 0, so any used fires.
        #expect(exceedsThresholdWithHeadroom(used: 0, contextWindow: 100_000, thresholdPercent: 85, headroom: 1_000_000))
    }

    @Test("Constants match documented values")
    func constantsMatchDocumentedValues() {
        #expect(BYTES_PER_TOKEN == 4)
        #expect(IMAGE_TOKEN_ESTIMATE == 765)
    }
}
