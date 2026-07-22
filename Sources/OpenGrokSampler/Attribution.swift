// Attribution.swift
//
// 401 attribution callback hook for the sampling client.
// Mirrors Rust `attribution.rs`.

import Foundation

/// A logical 401-emitting site inside the sampling client.
public enum SamplingConsumer: String, Sendable, Equatable, Hashable {
    case chatCompletionsStream = "chat_completions_stream"
    case chatCompletions = "chat_completions"
    case responsesStream = "responses_stream"
    case responses = "responses"
    case messagesStream = "messages_stream"
    case messages = "messages"

    /// Stable string identifier for this emit site.
    public var asEndpoint: String { rawValue }
}

/// Maximum prefix length the sampler shares with attribution callbacks.
///
/// Bearers leaving the sampler are 12-character prefixes only — the full
/// credential never crosses this boundary.
public let SENT_BEARER_PREFIX_LEN = 12

/// Hook invoked by ``SamplingClient`` at every 401 response site.
///
/// Implementations must be cheap and non-blocking. They run inside the
/// request's response-handling path.
public protocol Auth401AttributionCallback: Sendable {
    /// Record a 401 attribution event.
    ///
    /// - Parameters:
    ///   - consumer: which endpoint emitted the 401
    ///   - sentBearerPrefix: first ``SENT_BEARER_PREFIX_LEN`` characters of the
    ///     bearer actually sent, or `nil` when no auth header was present
    func record401(consumer: SamplingConsumer, sentBearerPrefix: String?)
}

/// Truncate a bearer/token to the scrubbed prefix shared across the boundary.
public func scrubbedBearerPrefix(_ bearer: String) -> String {
    if bearer.count <= SENT_BEARER_PREFIX_LEN {
        return bearer
    }
    return String(bearer.prefix(SENT_BEARER_PREFIX_LEN))
}
