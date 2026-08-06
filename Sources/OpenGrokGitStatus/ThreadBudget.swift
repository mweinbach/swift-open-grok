// ThreadBudget.swift
//
// Shared helpers for gix/status-style scans under RLIMIT_NPROC.
// Port of xai-gix-status thread budget (exact arithmetic).

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Past 8 produce workers a status scan gains no speed, only spawn pressure.
public let gixStatusHardCap: Int = 8

/// Reserve for non-gix threads.
public let gixStatusOuterReserve: Int = 8

/// Env var for forced dial (`OPENGROK_GIX_STATUS_THREADS`, legacy `GROK_GIX_STATUS_THREADS`).
public let gixStatusThreadsEnv = "OPENGROK_GIX_STATUS_THREADS"
public let gixStatusThreadsEnvLegacy = "GROK_GIX_STATUS_THREADS"

/// Pure produce-worker budget. Always `n >= 1`. Caps at 8; shrinks under tight
/// soft nproc headroom (`headroom < 2` → 1).
public func computeGixStatusThreadLimit(
    cores: Int,
    softNproc: Int?,
    threadsUsed: Int
) -> Int {
    let cores = max(cores, 1)
    var limit = min(cores, gixStatusHardCap)
    if let soft = softNproc {
        let headroom = soft
            .subtractingReportingOverflow(threadsUsed).partialValue
        let headroom2 = max(0, headroom - gixStatusOuterReserve)
        if headroom2 < 2 {
            limit = 1
        } else {
            limit = min(limit, headroom2)
        }
    }
    return max(limit, 1)
}

/// `N >= 1` only; reject `0` and garbage.
public func parseEnvThreadOverride(_ raw: String) -> Int? {
    guard let n = Int(raw), n >= 1 else { return nil }
    // Reject leading/trailing whitespace by requiring exact digit parse
    // without surrounding spaces (matches Rust: " 1" and "1 " → None).
    if String(n) != raw { return nil }
    return n
}

/// Production budget (`n >= 1`). Honours env override for `N >= 1`.
public func computeGixStatusThreadLimit(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Int {
    if let raw = environment[gixStatusThreadsEnv] ?? environment[gixStatusThreadsEnvLegacy],
       let n = parseEnvThreadOverride(raw) {
        return n
    }
    let cores = ProcessInfo.processInfo.activeProcessorCount
    return computeGixStatusThreadLimit(
        cores: cores,
        softNproc: softNprocLimit(),
        threadsUsed: threadsUsed()
    )
}

/// Soft RLIMIT_NPROC on Unix; `nil` elsewhere or on infinity/error.
public func softNprocLimit() -> Int? {
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(Linux)
    var lim = rlimit(rlim_cur: 0, rlim_max: 0)
    // glibc spells the constant `__RLIMIT_NPROC` and makes `RLIMIT_NPROC` a
    // macro alias, which ClangImporter does not surface to Swift.
    #if os(Linux)
    let resource = __rlimit_resource_t(__RLIMIT_NPROC.rawValue)
    #else
    let resource = RLIMIT_NPROC
    #endif
    if getrlimit(resource, &lim) != 0 { return nil }
    // RLIM_INFINITY is a C macro unavailable as a Swift constant on some SDKs;
    // treat the high-bit pattern (~0 >> 1 style / all-bits-set) as unlimited.
    let cur = lim.rlim_cur
    if cur == rlim_t.max || cur == ~rlim_t(0) || cur > rlim_t(Int.max) {
        // On Darwin, RLIM_INFINITY is ((1<<63)-1). Treat that as unlimited too.
        if cur >= (rlim_t(1) << 62) { return nil }
    }
    if cur > rlim_t(Int.max) { return nil }
    return Int(cur)
    #else
    return nil
    #endif
}

/// Best-effort count of threads used by this process.
public func threadsUsed() -> Int {
    #if os(Linux)
    if let status = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) {
        for line in status.split(separator: "\n") {
            if line.hasPrefix("Threads:") {
                let rest = line.dropFirst("Threads:".count)
                    .trimmingCharacters(in: .whitespaces)
                return Int(rest) ?? 1
            }
        }
    }
    return 1
    #else
    return 1
    #endif
}
