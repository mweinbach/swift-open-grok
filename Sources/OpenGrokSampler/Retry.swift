// Retry.swift
//
// Pure retry classification, backoff, and decision-making.
// Mirrors Rust `retry.rs`. No I/O.

import Foundation
import OpenGrokSamplingTypes

/// After this many rate-limit (429) retries, escalate to the caller.
public let RATE_LIMIT_RETRY_THRESHOLD: UInt32 = 2

/// Default max retries when no env or model override is set.
public let DEFAULT_MAX_RETRIES: UInt32 = 15

/// Resolve max API retries from an optional env override, model config, or default.
public func resolveMaxRetriesWithEnv(
    envOverride: String?,
    modelMaxRetries: UInt32?
) -> UInt32 {
    if let envOverride, let parsed = UInt32(envOverride) {
        return parsed
    }
    return modelMaxRetries ?? DEFAULT_MAX_RETRIES
}

/// Resolve max API retries: `GROK_MAX_RETRIES` env > model config > default.
public func resolveMaxRetries(modelMaxRetries: UInt32?) -> UInt32 {
    let envOverride = ProcessInfo.processInfo.environment["GROK_MAX_RETRIES"]
    return resolveMaxRetriesWithEnv(envOverride: envOverride, modelMaxRetries: modelMaxRetries)
}

private final class JitterSeq: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        return value
    }
}

private let jitterSeq = JitterSeq()

/// Backoff for doom-loop resamples: near-immediate with a small jitter.
public func doomLoopBackoff(retryCount: UInt32) -> MonotonicDuration {
    var hasher = Hasher()
    hasher.combine(jitterSeq.next())
    hasher.combine(retryCount)
    let h = UInt64(bitPattern: Int64(hasher.finalize()))
    return .milliseconds(Int64(h % 251))
}

/// Exponential backoff (2s, 4s, 8s, ..., capped 30s) with +/-20% jitter.
public func retryBackoffWithJitter(retryCount: UInt32) -> MonotonicDuration {
    let shift = retryCount > 0 ? retryCount - 1 : 0
    let baseMs: UInt64
    if shift >= 63 {
        baseMs = 30_000
    } else {
        baseMs = min(2000 &<< UInt64(shift), 30_000)
    }
    let jitterRange = baseMs / 5
    var hasher = Hasher()
    hasher.combine(jitterSeq.next())
    hasher.combine(retryCount)
    let h = UInt64(bitPattern: Int64(hasher.finalize()))
    let jitter = h % (jitterRange * 2 + 1)
    let ms = baseMs - jitterRange + jitter
    return .milliseconds(Int64(ms))
}

/// What the actor should do next given a sampling error and retry context.
public enum RetryDecision: Sendable {
    /// Retry with exponential backoff.
    case retry(backoff: MonotonicDuration)
    /// Retry honoring Retry-After (or jittered backoff).
    case retryWithBackoff(backoff: MonotonicDuration, isRateLimited: Bool)
    /// Retry after stripping inline images (413 / image processing).
    case retryWithImageStrip
    /// Retry after rebuilding the HTTP client with HTTP/1.1 (first retry).
    case retryWithClientRebuild(backoff: MonotonicDuration)
    /// Emit the error to the session (auth refresh, encrypted-content mismatch).
    case emitToSession(SamplingError)
    /// Fatal: no further retries.
    case fatal(SamplingError)
}

/// Classify a sampling error into a ``RetryDecision``.
///
/// Pure: does not sleep, log, or perform I/O.
public func classifyError(
    _ err: SamplingError,
    retryCount: UInt32,
    maxRetries: UInt32,
    rateLimitThreshold: UInt32
) -> RetryDecision {
    if err.isAuthError {
        return .emitToSession(err)
    }
    if err.isEncryptedContentError {
        return .emitToSession(err)
    }
    if err.isPayloadTooLarge {
        return .retryWithImageStrip
    }
    if err.isImageProcessingError {
        return .retryWithImageStrip
    }
    // Server explicitly said don't retry (x-should-retry: false).
    if err.shouldRetryHeader == false {
        return .fatal(err)
    }
    if err.isContextLengthError {
        return .fatal(err)
    }
    if case .doomLoopDetected = err {
        return .retry(backoff: doomLoopBackoff(retryCount: retryCount + 1))
    }
    if err.isRateLimited {
        let nextAttempt = retryCount + 1
        let effectiveCap = min(maxRetries, rateLimitThreshold)
        if nextAttempt >= effectiveCap {
            return .fatal(err)
        }
        let backoff: MonotonicDuration
        if let secs = err.retryAfter {
            backoff = .seconds(Int64(secs))
        } else {
            backoff = retryBackoffWithJitter(retryCount: nextAttempt)
        }
        return .retryWithBackoff(backoff: backoff, isRateLimited: true)
    }
    if err.isRetryable {
        let nextAttempt = retryCount + 1
        if nextAttempt >= maxRetries {
            return .fatal(err)
        }
        let backoff: MonotonicDuration
        if let secs = err.retryAfter {
            backoff = .seconds(Int64(secs))
        } else {
            backoff = retryBackoffWithJitter(retryCount: nextAttempt)
        }
        if nextAttempt == 1 {
            return .retryWithClientRebuild(backoff: backoff)
        }
        return .retry(backoff: backoff)
    }
    return .fatal(err)
}

/// Build a human-readable, telemetry-friendly description of a sampling error.
public func formatSamplingError(_ err: SamplingError, retryCount: UInt32?) -> String {
    let retryPrefix: String
    if let count = retryCount {
        retryPrefix = "Request failed after \(count) retries. "
    } else {
        retryPrefix = ""
    }

    switch err {
    case .auth(let msg, _):
        return "\(retryPrefix)Authentication failed: \(msg). Please check your API key configuration."
    case .invalidConfiguration(let msg):
        return "\(retryPrefix)Invalid configuration: \(msg). Please check your model settings."
    case .http(let msg):
        return "\(retryPrefix)HTTP request failed: \(msg). This may be a network issue or the API endpoint may be unavailable."
    case .serialization(let msg):
        return "\(retryPrefix)Failed to parse API response: \(msg). This indicates an unexpected response format from the server."
    case .api(let status, let message, _, let retryAfter, _, _):
        var s = "\(retryPrefix)API error (HTTP \(status.code)): \(message)."
        if let retryAfter {
            s += " Retry after \(retryAfter)s."
        }
        return s
    case .eventStreamError(let msg):
        return "\(retryPrefix)Stream transport error: \(msg)."
    case .streamError(let errorType, let message, _):
        return "\(retryPrefix)Stream error (\(errorType)): \(message)."
    case .idleTimeout(let elapsed):
        return "\(retryPrefix)Model idle timeout after \(elapsed)s. The stream stopped producing content."
    case .emptyResponse(let context):
        return "\(retryPrefix)Empty response from model (\(context.reason.asString))."
    case .maxTokensTruncation:
        return "\(retryPrefix)Response truncated by max tokens limit."
    case .doomLoopDetected(let triggers, _):
        return "\(retryPrefix)Doom loop detected (\(triggers.joined(separator: ", ")))."
    }
}
